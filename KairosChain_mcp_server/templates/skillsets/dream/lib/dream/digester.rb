# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'yaml'
require 'json'
require 'time'

module KairosMcp
  module SkillSets
    module Dream
      # Digester — generates and reads dream_digest derived views.
      #
      # Implements the frozen design (dream_digest_design_v0.4):
      #   - I1/I8/I10: digests live in a NON-CANONICAL derived tier, per-topic, never authoritative.
      #   - I2/I7: generation captures a content-addressed snapshot of the entire READ set.
      #   - I4: provenance references the snapshot; an empty topic emits no digest.
      #   - I5: post-generation source drift is labelled (stale), never corrected.
      #   - I6: the snapshot fixes the citable universe as INPUT (the LLM phrases, it does not select).
      #   - I9: the access bound is the most restrictive among ALL read sources (bound computed
      #         and recorded here; full enforcement mechanism is deferred to §11 / implementation review).
      #
      # Synthesis CONTENT is generated outside this class (by an LLM), mirroring dream_propose:
      #   #package builds the snapshot + a contradiction-preserving directive;
      #   #write persists LLM-provided content with provenance;
      #   #read returns content with staleness annotations.
      class Digester
        DIGEST_DIR_NAME = 'dream/digest'

        def initialize(config: {})
          @config = config || {}
        end

        # Build a content-addressed snapshot + generation directive for a topic. (I2/I6/I7)
        #
        # @param topic [String]
        # @param sources [Array<Hash>] each: {"layer"=>"l2"|"l1", "session_id"=>.., "name"=>..}
        # @param directive_id [String, nil]
        # @return [Hash] { topic:, snapshot: [...], access_bound:, directive:, directive_id:, status: }
        def package(topic:, sources:, directive_id: nil)
          read_set = build_read_set(sources)
          {
            topic: topic,
            directive_id: directive_id || default_directive_id,
            snapshot: read_set,
            access_bound: access_bound(read_set),
            directive: generation_directive(topic, read_set),
            status: read_set.empty? ? 'no_sources' : 'needs_content'
          }
        end

        # Persist an LLM-generated digest with provenance. (I1/I4/I8/I10)
        #
        # @param topic [String]
        # @param snapshot [Array<Hash>] the READ set from #package (citable universe, I6)
        # @param content [String] LLM-generated narrative (cites only snapshot sources)
        # @param directive_id [String]
        # @return [Hash] { success:, topic:, output_hash:, provenance_count:, access_bound:, path: }
        def write(topic:, snapshot:, content:, directive_id: nil)
          raise 'empty topic slug' if slugify(topic).empty?
          raise 'no provenance: refusing to emit a sourceless digest (I4)' if Array(snapshot).empty?
          raise 'empty content' if content.nil? || content.strip.empty?

          read_set = normalize_snapshot(snapshot)
          output_hash = Digest::SHA256.hexdigest(content)
          bound = access_bound(read_set)
          generated_at = Time.now.utc.iso8601

          frontmatter = {
            'topic' => topic,
            'kind' => 'dream_digest',
            'status' => 'fresh',
            'derived' => true, # I1: never a source of truth
            'authoritative' => false, # I8
            'generated_at' => generated_at,
            'directive_id' => directive_id || default_directive_id,
            'access_bound' => bound, # I9
            'output_hash' => output_hash,
            'provenance' => read_set.map { |s| s.slice('layer', 'ref', 'content_hash') }
          }

          dir = topic_dir(topic)
          FileUtils.mkdir_p(dir)
          path = File.join(dir, "#{slugify(topic)}.md")
          body = "---\n#{YAML.dump(frontmatter).sub(/\A---\n/, '')}---\n\n#{content.strip}\n"
          tmp = "#{path}.tmp"
          File.write(tmp, body)
          File.rename(tmp, path) # POSIX atomic

          {
            success: true,
            topic: topic,
            path: path,
            output_hash: output_hash,
            provenance_count: read_set.size,
            access_bound: bound,
            generated_at: generated_at
          }
        end

        # Read a digest with staleness annotations. (I5)
        #
        # @return [Hash] { found:, topic:, content:, stale:, drifted:, access_bound:, ... }
        def read(topic:)
          path = File.join(topic_dir(topic), "#{slugify(topic)}.md")
          return { found: false, topic: topic } unless File.exist?(path)

          raw = File.read(path)
          meta = extract_frontmatter(raw)
          body = raw.sub(/\A---\n.*?\n---\n/m, '').strip

          drift = drifted_sources(meta['provenance'] || [])
          {
            found: true,
            topic: topic,
            path: path,
            content: body,
            access_bound: meta['access_bound'],
            generated_at: meta['generated_at'],
            directive_id: meta['directive_id'],
            provenance_count: Array(meta['provenance']).size,
            drifted: drift,
            stale: !drift.empty?
          }
        end

        # Staleness check without returning full content. (I5)
        def staleness(topic:)
          r = read(topic: topic)
          return { found: false, topic: topic } unless r[:found]

          { found: true, topic: topic, stale: r[:stale], drifted: r[:drifted],
            provenance_count: r[:provenance_count] }
        end

        # List existing digests.
        def list
          base = digest_base
          return [] unless Dir.exist?(base)

          Dir.children(base).select { |c| Dir.exist?(File.join(base, c)) }.sort
        end

        private

        # ---- READ set / snapshot --------------------------------------------------

        def build_read_set(sources)
          Array(sources).filter_map do |s|
            layer = (s['layer'] || s[:layer] || 'l2').to_s.downcase
            path = source_path(layer, s)
            next nil unless path && File.exist?(path)

            content = File.read(path)
            {
              'layer' => layer,
              'ref' => source_ref(layer, s),
              'path' => path,
              'content_hash' => Digest::SHA256.hexdigest(content),
              'access' => extract_access(content)
            }
          end
        end

        # Re-resolve a snapshot passed back into #write (path may be absent).
        def normalize_snapshot(snapshot)
          Array(snapshot).map do |s|
            h = stringify(s)
            h['path'] ||= path_for_ref(h['layer'], h['ref'])
            h
          end
        end

        def drifted_sources(provenance)
          Array(provenance).filter_map do |p|
            h = stringify(p)
            path = path_for_ref(h['layer'], h['ref'])
            current = (path && File.exist?(path)) ? Digest::SHA256.hexdigest(File.read(path)) : nil
            # A missing source or a hash mismatch is drift (I5).
            if current.nil? || current != h['content_hash']
              { 'ref' => h['ref'], 'reason' => current.nil? ? 'missing' : 'hash_changed' }
            end
          end
        end

        # ---- Access bound (I9) ----------------------------------------------------

        # Most restrictive access label among the READ set. v0.1 reads a `visibility`/`access`
        # frontmatter key if present; absent it, defaults to 'default'. Full ACL enforcement
        # (live re-evaluation, principal binding) is a §11 / implementation-review mechanism.
        ACCESS_ORDER = { 'private' => 3, 'restricted' => 2, 'default' => 1, 'public' => 0 }.freeze

        def access_bound(read_set)
          labels = Array(read_set).map { |s| (s['access'] || s[:access] || 'default').to_s }
          labels << 'default' if labels.empty?
          labels.max_by { |l| ACCESS_ORDER.fetch(l, 1) }
        end

        def extract_access(content)
          meta = extract_frontmatter(content)
          (meta['visibility'] || meta['access'] || 'default').to_s
        end

        # ---- Generation directive (I3/I6) -----------------------------------------

        def generation_directive(topic, read_set)
          refs = read_set.map { |s| s['ref'] }.join(', ')
          <<~DIRECTIVE
            Synthesize a narrative DIGEST for topic "#{topic}" from the source set below.

            HARD CONSTRAINTS (do not violate):
            - Cite ONLY these sources; do not introduce facts not grounded in them (I6 citable universe): #{refs}
            - Every assertion must be traceable to at least one source; drop anything you cannot ground (I4).
            - When sources DISAGREE, do NOT pick a winner and do NOT merge into one claim.
              Surface the disagreement as coexisting positions with an inline annotation
              (e.g. "Source A holds X; Source B holds Y; unresolved.") (I3, flat-annotation grade).
            - This is a DERIVED overview, never authoritative; it must read as a projection of the
              fragments, not as a new source of truth (I1).

            Output: prose only (no YAML frontmatter — the tool adds provenance).
          DIRECTIVE
        end

        def default_directive_id
          'dream_digest.synthesis.v1'
        end

        # ---- Paths ----------------------------------------------------------------

        def digest_base
          File.join(kairos_dir, DIGEST_DIR_NAME)
        end

        def topic_dir(topic)
          File.join(digest_base, slugify(topic))
        end

        def source_path(layer, s)
          case layer
          when 'l2'
            sid = s['session_id'] || s[:session_id]
            name = s['name'] || s[:name]
            return nil unless sid && name

            File.join(context_dir, sid, name, "#{name}.md")
          when 'l1'
            l1_path(s['name'] || s[:name])
          end
        end

        def path_for_ref(layer, ref)
          case layer
          when 'l2'
            sid, name = ref.to_s.split('/', 2)
            return nil unless sid && name

            File.join(context_dir, sid, name, "#{name}.md")
          when 'l1'
            l1_path(ref)
          end
        end

        def l1_path(name)
          return nil unless name

          dir_form = File.join(knowledge_dir, name, "#{name}.md")
          flat_form = File.join(knowledge_dir, "#{name}.md")
          File.exist?(dir_form) ? dir_form : flat_form
        end

        def source_ref(layer, s)
          case layer
          when 'l2' then "#{s['session_id'] || s[:session_id]}/#{s['name'] || s[:name]}"
          when 'l1' then (s['name'] || s[:name]).to_s
          end
        end

        # ---- Env helpers ----------------------------------------------------------

        def kairos_dir
          if defined?(KairosMcp) && KairosMcp.respond_to?(:kairos_dir)
            KairosMcp.kairos_dir
          else
            File.join(Dir.pwd, '.kairos')
          end
        end

        def context_dir
          if defined?(KairosMcp) && KairosMcp.respond_to?(:context_dir)
            KairosMcp.context_dir
          else
            File.join(kairos_dir, 'context')
          end
        end

        def knowledge_dir
          if defined?(KairosMcp) && KairosMcp.respond_to?(:knowledge_dir)
            KairosMcp.knowledge_dir
          else
            File.join(kairos_dir, 'knowledge')
          end
        end

        # ---- Misc -----------------------------------------------------------------

        def slugify(topic)
          topic.to_s.downcase.strip.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        end

        def extract_frontmatter(content)
          if content =~ /\A---\n(.*?)\n---/m
            YAML.safe_load($1, permitted_classes: [Symbol]) || {}
          else
            {}
          end
        rescue StandardError
          {}
        end

        def stringify(hash)
          (hash || {}).each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
        end
      end
    end
  end
end
