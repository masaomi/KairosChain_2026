# frozen_string_literal: true

require 'yaml'
require 'date'
require 'time'

module KairosMcp
  module SkillSets
    module Dream
      # SuccessionIndex — the succession edges declared by the L2 nodes under one context root,
      # read from disk when the index is built.
      #
      # dream_digest design v0.13:
      #   - I3:  succession is read from a declared edge. Nothing here infers one from a date, a
      #          wording, or a mark kept outside relations[]; nothing here composes edges.
      #   - I13: an edge is held by the node that replaces. It is valid when it carries grounds
      #          and its formal target exists; the two conditions are the core's
      #          (ContextGraph.succession_edge_failures), evaluated here at build time.
      #   - I5:  the READ set of a digest is closed under these edges (#close). A node that cannot
      #          be parsed cannot be shown to hold no edge, so it is reported (#unparseable).
      #
      # The context root is the reading principal's: a node outside it is absent from the index.
      class SuccessionIndex
        class UnsupportedCoreError < StandardError; end

        Edge = Struct.new(:holder, :type, :target, :target_ref, :part, :grounds, :failures, keyword_init: true) do
          def valid?
            failures.empty?
          end

          # The target for display: a formal target as written; anything else quoted, so text a
          # node put in its target cannot pass for a line of whatever lists the edge.
          def shown_target
            target_ref ? target : target.inspect
          end

          # As the declaring node wrote it; grounds and references are not resolved.
          def to_h
            h = { 'holder' => holder, 'type' => type, 'target' => shown_target, 'valid' => valid? }
            h['part'] = part unless part.nil?
            h['grounds'] = grounds unless grounds.nil?
            h['failures'] = failures.map(&:to_s) unless valid?
            h
          end
        end

        # Every L2 node file under a context root: yields (session_id, name, path), in a stable
        # order. A path that leaves the root (through a symlink) is not a node of this root.
        def self.each_node(context_root)
          return unless context_root && Dir.exist?(context_root)

          root_real = File.realpath(context_root)
          Dir.children(context_root).sort.each do |sid|
            sdir = File.join(context_root, sid)
            next unless segment?(sid) && File.directory?(sdir)

            Dir.children(sdir).sort.each do |name|
              next unless segment?(name)

              path = File.join(sdir, name, "#{name}.md")
              next unless File.file?(path)

              real = begin
                File.realpath(path)
              rescue SystemCallError
                nil
              end
              yield sid, name, path if real&.start_with?("#{root_real}#{File::SEPARATOR}")
            end
          end
        end

        def self.segment?(value)
          s = value.to_s
          !s.empty? && !s.include?('/') && !s.include?('\\') && !s.include?("\0") && s != '.' && s != '..'
        end

        attr_reader :unparseable, :node_count

        def initialize(context_root)
          unless defined?(KairosMcp::ContextGraph) && KairosMcp::ContextGraph.respond_to?(:succession_edge_failures)
            raise UnsupportedCoreError, 'this core does not define succession edges (ContextGraph.succession_edge_failures)'
          end

          @context_root = context_root
          @edges_by_holder = {}
          @holders_by_target = {}
          @unparseable = []
          @node_count = 0
          @complete = true
          scan
        end

        # False when the store could not be enumerated in full: a closure built from this index
        # was then not built in full either.
        def complete?
          @complete
        end

        # Succession edges the node declares, valid or not.
        def edges_of(ref)
          @edges_by_holder.fetch(ref, [])
        end

        # Nodes that declare a succession edge targeting the node, valid or not.
        def holders_of(ref)
          @holders_by_target.fetch(ref, [])
        end

        # The smallest set that contains `refs`, every node holding a succession edge whose
        # target is a member, and the target of each member's valid succession edge.
        # Order: `refs` first, then members in the order the closure reaches them.
        def close(refs)
          members = refs.uniq
          seen = members.to_h { |r| [r, true] }
          queue = members.dup
          until queue.empty?
            ref = queue.shift
            reached = holders_of(ref) + edges_of(ref).select(&:valid?).map(&:target_ref)
            reached.each do |r|
              next if seen[r]

              seen[r] = true
              members << r
              queue << r
            end
          end
          members
        end

        private

        def scan
          self.class.each_node(@context_root) do |sid, name, path|
            @node_count += 1
            ref = "#{sid}/#{name}"
            relations_of(ref, path).each { |item| record(ref, item) }
          end
        rescue SystemCallError
          @complete = false
        end

        def record(ref, item)
          return unless KairosMcp::ContextGraph.succession_edge?(item)

          target = item['target'] || item[:target]
          parsed = KairosMcp::ContextGraph.parse_target(target)
          edge = Edge.new(
            holder: ref,
            type: (item['type'] || item[:type]).to_s,
            target: target,
            target_ref: parsed && "#{parsed[:sid]}/#{parsed[:name]}",
            part: item['part'] || item[:part],
            grounds: item['grounds'] || item[:grounds],
            failures: KairosMcp::ContextGraph.succession_edge_failures(item, @context_root)
          )
          (@edges_by_holder[ref] ||= []) << edge
          (@holders_by_target[edge.target_ref] ||= []) << ref if edge.target_ref
        end

        # The node's relations[] items, or [] when it declares none. A node whose relations
        # cannot be read is recorded as unparseable and yields [].
        def relations_of(ref, path)
          content = begin
            File.read(path, encoding: 'UTF-8')
          rescue SystemCallError, IOError
            return unparseable!(ref, 'unreadable')
          end
          return unparseable!(ref, 'not valid UTF-8') unless content.valid_encoding?

          m = content.match(/\A---\r?\n(.*?)\r?\n---/m)
          return [] unless m

          front = begin
            YAML.safe_load(m[1], permitted_classes: [Symbol, Date, Time])
          rescue StandardError => e
            return unparseable!(ref, "frontmatter does not parse (#{e.class.name.split('::').last})")
          end
          return [] unless front.is_a?(Hash)

          rels = front['relations'] || front[:relations]
          return [] if rels.nil?
          return unparseable!(ref, 'relations is not a list') unless rels.is_a?(Array)

          schema = front['relations_schema'] || front[:relations_schema]
          return unparseable!(ref, "unknown relations_schema #{schema.inspect}") if schema && schema != 1

          rels
        end

        def unparseable!(ref, reason)
          @unparseable << { 'ref' => ref, 'reason' => reason }
          []
        end
      end
    end
  end
end
