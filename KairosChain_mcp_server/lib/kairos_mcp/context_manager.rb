# frozen_string_literal: true

require 'fileutils'
require 'yaml'
require_relative 'anthropic_skill_parser'
require_relative 'context_graph'
require_relative 'path_containment'
require_relative '../kairos_mcp'

module KairosMcp
  # ContextManager: Manages L2 (context layer) skills in Anthropic format
  #
  # L2 characteristics:
  # - Temporary context and hypotheses
  # - No blockchain recording (free modification)
  # - Session-based organization
  #
  class ContextManager
    def initialize(context_dir = nil, user_context: nil)
      context_dir ||= KairosMcp.context_dir(user_context: user_context)
      @context_dir = context_dir
      @user_context = user_context
      FileUtils.mkdir_p(@context_dir)
    end

    # List all active sessions
    #
    # @return [Array<Hash>] List of session info
    def list_sessions
      session_dirs.map do |dir|
        session_id = File.basename(dir)
        contexts = list_contexts_in_session(session_id)
        {
          session_id: session_id,
          context_count: contexts.size,
          created_at: File.ctime(dir),
          modified_at: File.mtime(dir)
        }
      end.sort_by { |s| s[:modified_at] }.reverse
    end

    # List all contexts in a session
    #
    # @param session_id [String] Session ID
    # @return [Array<Hash>] List of context summaries
    def list_contexts_in_session(session_id)
      return [] unless segments?(session_id)

      session_dir = File.join(@context_dir, session_id)
      return [] unless contained?(session_dir)
      return [] unless File.directory?(session_dir)

      context_dirs(session_dir).map do |dir|
        skill = AnthropicSkillParser.parse(dir)
        next unless skill

        {
          name: skill.name,
          description: skill.description,
          has_scripts: skill.has_scripts?,
          has_assets: skill.has_assets?,
          has_references: skill.has_references?
        }
      end.compact
    end

    # Get a specific context
    #
    # @param session_id [String] Session ID
    # @param name [String] Context name
    # @return [AnthropicSkillParser::SkillEntry, nil] The context entry or nil
    def get_context(session_id, name)
      return nil unless segments?(session_id, name)

      context_dir = File.join(@context_dir, session_id, name)
      return nil unless contained?(context_dir)
      return nil unless File.directory?(context_dir)

      AnthropicSkillParser.parse(context_dir)
    end

    # Save a context (create or update)
    #
    # @param session_id [String] Session ID
    # @param name [String] Context name
    # @param content [String] Full content including YAML frontmatter
    # @param create_subdirs [Boolean] Whether to create scripts/assets/references
    # @return [Hash] Result with success status
    def save_context(session_id, name, content, create_subdirs: false)
      validate_relations_in_content!(content)

      session_dir = File.join(@context_dir, session_id)
      context_dir = File.join(session_dir, name)

      # Checked before mkdir_p, so neither value can create a directory outside
      # the store. Both guards are needed: containment bounds the composed leaf,
      # and the segment check bounds session_dir and the second join the parser
      # performs on `name` — paths this method never composes itself.
      unless segments?(session_id, name) && contained?(context_dir)
        return { success: false, error: "Invalid session_id/name: '#{session_id}/#{name}' resolves outside the context directory" }
      end

      FileUtils.mkdir_p(session_dir)

      if File.directory?(context_dir)
        # Update existing
        skill = AnthropicSkillParser.update(context_dir, content)
        { success: true, action: 'updated', context: skill.to_h }
      else
        # Create new
        skill = AnthropicSkillParser.create(session_dir, name, content, create_subdirs: create_subdirs)
        { success: true, action: 'created', context: skill.to_h }
      end
    rescue ContextGraph::Error => e
      { success: false, error: "#{e.class.name.split('::').last}: #{e.message}" }
    rescue StandardError => e
      { success: false, error: e.message }
    end

    # Parse the incoming content's frontmatter, and if it carries relations[]
    # (Context Graph Phase 1), enforce the v2.1 §1.1 schema rules and
    # path-containment guard. Pure validation — does not mutate content.
    #
    # @raise ContextGraph::* on any violation
    def validate_relations_in_content!(content)
      return unless content.is_a?(String)

      m = content.match(/\A---\r?\n(.+?)\r?\n---\r?\n/m)
      return unless m

      begin
        front = YAML.safe_load(m[1], permitted_classes: [Symbol, Date, Time]) || {}
      rescue StandardError => e
        raise ContextGraph::InvalidFrontmatterError, "frontmatter parse failed: #{e.message}"
      end

      relations = front['relations'] || front[:relations]
      return if relations.nil?

      ContextGraph.validate_relations!(relations)

      # For each target, run the path-containment guard. PathEscape and
      # SymlinkRejected are hard fails on the write path. ENOENT (dangling)
      # is allowed (forward references are part of L2-evidential ontology).
      relations.each do |item|
        target = item['target'] || item[:target]
        ContextGraph.resolve_target(target, @context_dir)
      end
    end

    # Delete a context
    #
    # @param session_id [String] Session ID
    # @param name [String] Context name
    # @return [Hash] Result with success status
    def delete_context(session_id, name)
      context_dir = File.join(@context_dir, session_id, name)

      # rm_rf below: containment is checked first so a traversing name cannot
      # delete a tree outside the context store.
      unless segments?(session_id, name) && contained?(context_dir) && File.directory?(context_dir)
        return { success: false, error: "Context '#{name}' not found in session '#{session_id}'" }
      end

      FileUtils.rm_rf(context_dir)
      { success: true, deleted: name }
    end

    # Delete an entire session
    #
    # @param session_id [String] Session ID
    # @return [Hash] Result with success status
    def delete_session(session_id)
      session_dir = File.join(@context_dir, session_id)

      unless segments?(session_id) && contained?(session_dir) && File.directory?(session_dir)
        return { success: false, error: "Session '#{session_id}' not found" }
      end

      contexts_count = context_dirs(session_dir).size
      FileUtils.rm_rf(session_dir)
      { success: true, deleted: session_id, contexts_deleted: contexts_count }
    end

    # Create a subdirectory (scripts, assets, or references)
    #
    # @param session_id [String] Session ID
    # @param name [String] Context name
    # @param subdir [String] Subdirectory name ('scripts', 'assets', or 'references')
    # @return [Hash] Result with success status and path
    def create_subdir(session_id, name, subdir)
      valid_subdirs = %w[scripts assets references]
      unless valid_subdirs.include?(subdir)
        return { success: false, error: "Invalid subdir. Must be one of: #{valid_subdirs.join(', ')}" }
      end

      context_dir = File.join(@context_dir, session_id, name)
      unless segments?(session_id, name) && contained?(context_dir) && File.directory?(context_dir)
        return { success: false, error: "Context '#{name}' not found in session '#{session_id}'" }
      end

      subdir_path = File.join(context_dir, subdir)
      unless contained?(subdir_path)
        return { success: false, error: "Invalid subdir '#{subdir}': resolves outside the context directory" }
      end

      # mkdir_p raises Errno::EEXIST when the name is taken by a dangling
      # symlink, and this method's contract is a result hash, not an exception.
      FileUtils.mkdir_p(subdir_path)
      { success: true, path: subdir_path }
    rescue SystemCallError => e
      { success: false, error: "Could not create subdir '#{subdir}': #{e.message}" }
    end

    # Generate a unique session ID
    #
    # @param prefix [String] Optional prefix for the session ID
    # @return [String] Generated session ID
    def generate_session_id(prefix: 'session')
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      random = SecureRandom.hex(4)
      "#{prefix}_#{timestamp}_#{random}"
    end

    # List scripts in a context
    #
    # @param session_id [String] Session ID
    # @param name [String] Context name
    # @return [Array<Hash>] List of script info
    def list_scripts(session_id, name)
      context = get_context(session_id, name)
      return [] unless context

      AnthropicSkillParser.list_scripts(context)
    end

    # List assets in a context
    #
    # @param session_id [String] Session ID
    # @param name [String] Context name
    # @return [Array<Hash>] List of asset info
    def list_assets(session_id, name)
      context = get_context(session_id, name)
      return [] unless context

      AnthropicSkillParser.list_assets(context)
    end

    private

    # True if a path built from a caller-supplied session_id / name still
    # resolves inside the context store.
    def contained?(path)
      PathContainment.contained?(@context_dir, path)
    end

    # True if every caller-supplied value names one directory.
    #
    # Containment alone is not enough here: "." and ".." resolve back onto the
    # store root, which is inside it, so a delete addressed that way would take
    # the whole store. A session id and a context name are always one level.
    def segments?(*values)
      values.all? { |v| PathContainment.safe_segment?(v) }
    end

    def session_dirs
      Dir[File.join(@context_dir, '*')].select { |f| File.directory?(f) }
    end

    # Listing follows Dir entries, so a child that is a symlink out of the store
    # would otherwise be enumerated and parsed as if it were a context.
    def context_dirs(session_dir)
      Dir[File.join(session_dir, '*')].select { |f| File.directory?(f) && contained?(f) }
    end
  end
end
