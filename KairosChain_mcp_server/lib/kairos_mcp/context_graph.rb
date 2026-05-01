# frozen_string_literal: true

require 'date'
require 'fileutils'
require 'securerandom'
require 'time'
require 'yaml'

module KairosMcp
  # ContextGraph: Phase 1 minimal mapping for L2 informed_by edges.
  #
  # Design reference: docs/drafts/context_graph_l2_mapping_design_v2.1.md
  #
  # Responsibilities:
  #   - target string parse (TARGET_RE)
  #   - resolve_target: path containment + symlink rejection (security)
  #   - relations array validation (shape + type whitelist)
  #
  # Non-responsibilities (by design, L2-evidential):
  #   - durability invariants (write serialization, fsync sequence) — not L2's job
  #   - semantic validation (whether informed_by claim is true) — defer to traverser
  #   - edges.jsonl cache — Phase 2 if observation justifies
  module ContextGraph
    # Recognized edge types in Phase 1. Unknown types are accepted on write
    # (forward-compat) but skipped on traverse.
    KNOWN_TYPES = %w[informed_by].freeze

    # Target canonical regex (v2.1 §2). Permissive enough to reference both
    # canonical session_ids (session_<8>_<6>_<8hex>) and the human-readable
    # forms already on disk (e.g. coaching_insights_20260327, received_skills).
    # Leading char restricted to [A-Za-z0-9_] to forbid dot/hyphen path tricks.
    TARGET_RE = /\Av1:(?<sid>[A-Za-z0-9_][A-Za-z0-9_.\-]{0,127})\/(?<name>[A-Za-z0-9_][A-Za-z0-9_.\-]{0,127})\z/.freeze

    # YAML value types permitted inside relations[] items.
    # Anything outside this set is rejected on write to keep YAML.dump
    # output free of anchors/aliases that downstream non-safe loaders
    # could exploit.
    SAFE_VALUE_TYPES = [
      String, Integer, Float, TrueClass, FalseClass, NilClass,
      Hash, Array, Time, Date
    ].freeze

    DEFAULT_MAX_DEPTH = 3

    # Error hierarchy. All inherit from a single base so callers can
    # rescue ContextGraph::Error to surface uniformly.
    class Error < StandardError; end
    class MalformedTargetError < Error; end
    class MalformedRelationsError < Error; end
    class UnsafeRelationValueError < Error; end
    class PathEscapeError < Error; end
    class SymlinkRejectedError < Error; end
    class PathResolutionError < Error; end
    class InvalidFrontmatterError < Error; end

    module_function

    # Parse a target string into {sid, name}. Returns nil on mismatch.
    def parse_target(target_str)
      return nil unless target_str.is_a?(String)

      m = TARGET_RE.match(target_str)
      return nil unless m

      { sid: m[:sid], name: m[:name] }
    end

    # Resolve target to an on-disk file path with full security checks.
    #
    # @param target_str [String] e.g. "v1:session_xxx/name"
    # @param context_root [String] absolute path to L2 context root
    # @return [Hash] { path: String|nil, status: :ok|:dangling }
    # @raise MalformedTargetError, PathEscapeError, SymlinkRejectedError, PathResolutionError
    def resolve_target(target_str, context_root)
      parsed = parse_target(target_str)
      raise MalformedTargetError, "target does not match canonical form: #{target_str.inspect}" unless parsed

      root_real = begin
        File.realpath(context_root)
      rescue Errno::ENOENT
        # context_root itself is missing — treat as resolution failure
        raise PathResolutionError, "context_root does not exist: #{context_root}"
      end

      candidate = File.join(root_real, parsed[:sid], parsed[:name], "#{parsed[:name]}.md")

      # Symlink rejection BEFORE realpath: lstat does not follow links, so
      # if the final component is a symlink we reject it here without
      # leaking the symlink's target into containment evaluation.
      lst = begin
        File.lstat(candidate)
      rescue Errno::ENOENT
        # Forward reference: target file does not exist yet.
        verify_dangling_containment(candidate, root_real)
        return { path: nil, status: :dangling }
      rescue SystemCallError => e
        raise PathResolutionError, "fs error stat'ing #{target_str}: #{e.message}"
      end

      raise SymlinkRejectedError, "target final component is a symlink: #{candidate}" if lst.symlink?

      resolved = begin
        File.realpath(candidate)
      rescue SystemCallError => e
        raise PathResolutionError, "fs error resolving #{target_str}: #{e.message}"
      end

      sep = File::SEPARATOR
      unless resolved == root_real || resolved.start_with?(root_real + sep)
        raise PathEscapeError, "resolved path escapes context_root: #{resolved}"
      end

      { path: resolved, status: :ok }
    end

    # Validate a relations[] array on the write path. Mutates nothing.
    # Returns nil on success, raises on the first violation.
    #
    # Rules (v2.1 §1.1, §4.2):
    #   - relations is Array
    #   - each item is Hash with String type and String target
    #   - target matches TARGET_RE
    #   - all values are SAFE_VALUE_TYPES (recursively)
    def validate_relations!(relations)
      raise MalformedRelationsError, 'relations must be an Array' unless relations.is_a?(Array)

      relations.each_with_index do |item, idx|
        raise MalformedRelationsError, "relations[#{idx}] must be a Hash" unless item.is_a?(Hash)

        type = item['type'] || item[:type]
        target = item['target'] || item[:target]

        raise MalformedRelationsError, "relations[#{idx}] missing 'type'" if type.nil?
        raise MalformedRelationsError, "relations[#{idx}] missing 'target'" if target.nil?
        raise MalformedRelationsError, "relations[#{idx}].type must be String" unless type.is_a?(String)
        raise MalformedRelationsError, "relations[#{idx}].target must be String" unless target.is_a?(String)
        raise MalformedTargetError, "relations[#{idx}].target does not match canonical form: #{target.inspect}" unless TARGET_RE.match?(target)

        item.each do |k, v|
          assert_safe_value!(v, "relations[#{idx}].#{k}")
        end
      end

      nil
    end

    # Recursively check that a value tree contains only SAFE_VALUE_TYPES.
    def assert_safe_value!(value, location)
      case value
      when Hash
        value.each do |k, v|
          assert_safe_value!(k, "#{location}.<key>")
          assert_safe_value!(v, "#{location}.#{k}")
        end
      when Array
        value.each_with_index { |v, i| assert_safe_value!(v, "#{location}[#{i}]") }
      else
        return if SAFE_VALUE_TYPES.any? { |t| value.is_a?(t) }

        raise UnsafeRelationValueError,
              "unsafe value type #{value.class} at #{location} (allowed: #{SAFE_VALUE_TYPES.map(&:name).join(', ')})"
      end
    end

    # Atomic write: create tempfile in same directory, write, rename.
    # Replaces target with full content. Crash mid-write leaves target
    # either pre- or post-rename (never truncated).
    #
    # @param target_path [String] file to replace
    # @param content [String] full file content
    def atomic_write(target_path, content)
      dir = File.dirname(target_path)
      FileUtils.mkdir_p(dir) unless File.directory?(dir)

      tempname = "#{File.basename(target_path)}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
      temp_path = File.join(dir, tempname)

      begin
        File.write(temp_path, content)
        File.rename(temp_path, target_path)
      ensure
        File.delete(temp_path) if File.exist?(temp_path)
      end
    end

    # Check that the parent directory of a missing target stays inside root.
    # Used for the dangling (ENOENT) branch.
    def verify_dangling_containment(candidate, root_real)
      # Walk up until we find an existing ancestor
      ancestor = candidate
      until File.exist?(ancestor)
        parent = File.dirname(ancestor)
        break if parent == ancestor # reached fs root
        ancestor = parent
      end

      return unless File.exist?(ancestor)

      ancestor_real = File.realpath(ancestor)
      sep = File::SEPARATOR
      return if ancestor_real == root_real || ancestor_real.start_with?(root_real + sep)

      raise PathEscapeError, "dangling target's nearest ancestor escapes context_root: #{ancestor_real}"
    end

    # BFS traverse informed_by edges starting from (start_sid, start_name).
    #
    # @param start_sid [String]
    # @param start_name [String]
    # @param context_root [String]
    # @param max_depth [Integer]
    # @return [Hash] { root:, nodes: [...], warnings: [...] }
    def traverse_informed_by(start_sid:, start_name:, context_root:, max_depth: DEFAULT_MAX_DEPTH)
      root_target = "v1:#{start_sid}/#{start_name}"
      result = { root: root_target, nodes: [], warnings: [] }
      visited = {}

      queue = [[root_target, 0]]

      until queue.empty?
        target, depth = queue.shift
        next if visited.key?(target)

        visited[target] = true

        node = visit_node(target, context_root, result[:warnings])
        node[:depth] = depth
        result[:nodes] << node

        next if node[:status] != :ok
        next if depth >= max_depth

        outgoing = read_relations(node[:path], result[:warnings])
        outgoing.each do |edge|
          next unless edge['type'] == 'informed_by' || edge[:type] == 'informed_by'
          edge_target = edge['target'] || edge[:target]
          next unless edge_target.is_a?(String)
          next if visited.key?(edge_target)

          queue << [edge_target, depth + 1]
        end
      end

      result
    end

    # Visit one node: resolve, classify status. Returns node hash.
    def visit_node(target, context_root, warnings)
      resolved = resolve_target(target, context_root)
      if resolved[:status] == :dangling
        return { target: target, status: :dangling, reason: nil, path: nil }
      end

      { target: target, status: :ok, reason: nil, path: resolved[:path] }
    rescue MalformedTargetError => e
      warnings << "skip #{target}: malformed (#{e.message})"
      { target: target, status: :skipped, reason: 'malformed', path: nil }
    rescue PathResolutionError => e
      warnings << "skip #{target}: path_resolution (#{e.message})"
      { target: target, status: :skipped, reason: 'path_resolution', path: nil }
      # PathEscapeError and SymlinkRejectedError intentionally NOT caught:
      # those are hard fails on both write and read paths (v2.1 §3.1).
    end

    # Read a node's relations[] for traversal. Returns [] on any read-side
    # issue (parse fail, missing schema, unknown schema), appending a warning.
    def read_relations(md_path, warnings)
      return [] unless md_path && File.exist?(md_path)

      content = File.read(md_path, encoding: 'UTF-8')
      m = content.match(/\A---\r?\n(.+?)\r?\n---\r?\n/m)
      return [] unless m

      begin
        front = YAML.safe_load(m[1], permitted_classes: [Symbol, Date, Time]) || {}
      rescue StandardError => e
        warnings << "skip relations of #{md_path}: parse_failed (#{e.message})"
        return []
      end

      schema_v = front['relations_schema'] || front[:relations_schema]
      if schema_v && schema_v != 1
        warnings << "skip relations of #{md_path}: unknown_schema_version=#{schema_v.inspect}"
        return []
      end

      rels = front['relations'] || front[:relations]
      return [] unless rels.is_a?(Array)

      rels
    end
  end
end
