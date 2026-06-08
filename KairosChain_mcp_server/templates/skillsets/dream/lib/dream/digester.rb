# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'yaml'
require 'json'
require 'time'
require 'date'

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
        LOCK_FILE = '.dream_digest_lock'

        class IdentifierError < StandardError; end

        def initialize(config: {})
          @config = config || {}
        end

        # Build a content-addressed snapshot + generation directive for a topic. (I2/I6/I7)
        #
        # The citable universe (I6) is fixed here, as an INPUT, either explicitly via `sources`
        # or — wiring dream_scan detection into the digest — by resolving every live fragment
        # carrying `from_tag`. Explicit sources take precedence; from_tag is the auto path.
        #
        # @param topic [String]
        # @param sources [Array<Hash>] each: {"layer"=>"l2"|"l1", "session_id"=>.., "name"=>..}
        # @param from_tag [String, nil] resolve sources = all live fragments carrying this tag
        # @param include_l1 [Boolean] when resolving from_tag, also include L1 entries tagged with it
        # @param directive_id [String, nil]
        # @return [Hash] { topic:, snapshot: [...], access_bound:, directive:, directive_id:, status:, resolved_from: }
        def package(topic:, sources: nil, from_tag: nil, include_l1: true, directive_id: nil)
          resolved_from = nil
          src = Array(sources)
          if src.empty? && from_tag
            src = resolve_sources_by_tag(from_tag, include_l1: include_l1)
            resolved_from = "tag:#{from_tag}"
          end

          read_set = build_read_set(src)
          {
            topic: topic,
            directive_id: directive_id || default_directive_id,
            snapshot: read_set,
            access_bound: access_bound(read_set),
            directive: generation_directive(topic, read_set),
            resolved_from: resolved_from,
            status: read_set.empty? ? 'no_sources' : 'needs_content'
          }
        end

        # Resolve the citation set from a tag (dream_scan -> dream_digest wiring). (I6 input)
        # Returns live (non-archived) L2 contexts carrying the tag, plus tagged L1 entries.
        #
        # @param tag [String]
        # @param include_l1 [Boolean]
        # @return [Array<Hash>] source descriptors for #build_read_set
        def resolve_sources_by_tag(tag, include_l1: true)
          out = []
          cm = context_manager
          if cm
            cm.list_sessions.each do |session|
              sid = session[:session_id]
              cm.list_contexts_in_session(sid).each do |ctx|
                path = File.join(context_dir, sid, ctx[:name], "#{ctx[:name]}.md")
                next unless File.exist?(path)

                content = File.read(path)
                next if frontmatter_value(content, 'status') == 'soft-archived' # don't cite stubs as live
                next unless tag_match?(frontmatter_tags(content), tag)

                out << { 'layer' => 'l2', 'session_id' => sid, 'name' => ctx[:name] }
              end
            end
          end

          if include_l1 && (kp = knowledge_provider)
            kp.list.each do |entry|
              next unless tag_match?(Array(entry[:tags]), tag)

              out << { 'layer' => 'l1', 'name' => entry[:name] }
            end
          end
          out
        end

        # Persist an LLM-generated digest with provenance. (I1/I4/I8/I10)
        #
        # @param topic [String]
        # @param snapshot [Array<Hash>] the READ set from #package (citable universe, I6)
        # @param content [String] LLM-generated narrative (cites only snapshot sources)
        # @param directive_id [String]
        # @return [Hash] { success:, topic:, output_hash:, provenance_count:, access_bound:, path: }
        def write(topic:, snapshot:, content:, directive_id: nil, resolved_from: nil)
          slug = slugify(topic)
          raise 'empty topic slug' if slug.empty?
          raise 'no provenance: refusing to emit a sourceless digest (I4)' if Array(snapshot).empty?
          raise 'empty content' if content.nil? || content.strip.empty?

          # Re-derive the snapshot from the CURRENT sources rather than trusting the caller's
          # hashes/access (I4 provenance integrity, I9 access bound cannot be spoofed). The
          # caller's snapshot only fixes WHICH sources are citable (I6); hashes/access are ours.
          read_set = build_read_set(sources_from_provenance(snapshot))
          raise 'no resolvable sources at write time (I4)' if read_set.empty?

          effective_directive = directive_id || default_directive_id
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
            'directive_id' => effective_directive,
            'access_bound' => bound, # I9
            'output_hash' => output_hash,
            'provenance' => read_set.map { |s| s.slice('layer', 'ref', 'content_hash') }
          }
          frontmatter['resolved_from'] = resolved_from if resolved_from

          dir = topic_dir(topic)
          FileUtils.mkdir_p(dir)
          path = File.join(dir, "#{slug}.md")
          body = "---\n#{YAML.dump(frontmatter).sub(/\A---\n/, '')}---\n\n#{content.strip}\n"

          with_topic_lock(dir) do
            guard_slug_collision!(path, topic) # I10: never silently overwrite a different topic
            tmp = "#{path}.#{Process.pid}.#{rand(1 << 32).to_s(16)}.tmp" # unique per writer (I3)
            File.write(tmp, body)
            File.rename(tmp, path) # POSIX atomic
          end

          {
            success: true,
            topic: topic,
            path: path,
            output_hash: output_hash,
            directive_id: effective_directive,
            provenance: read_set.map { |s| s.slice('layer', 'ref', 'content_hash') },
            provenance_count: read_set.size,
            access_bound: bound,
            generated_at: generated_at
          }
        end

        # Read a digest with staleness annotations. (I5)
        #
        # @return [Hash] { found:, topic:, content:, stale:, drifted:, access_bound:, age_days:, ... }
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
            age_days: age_days(meta['generated_at']),
            directive_id: meta['directive_id'],
            resolved_from: meta['resolved_from'],
            provenance_count: Array(meta['provenance']).size,
            drifted: drift,
            stale: !drift.empty?
          }
        end

        # Sweep all digests for staleness + age. Schedulable health view. (I5 + freshness)
        # The EXTERNAL trigger (cron / Claude Code hook / autonomous loop) is a separate layer;
        # this method only reports — it does not regenerate or schedule anything itself.
        #
        # @param stale_after_days [Integer, nil] also flag digests older than this as 'aged'
        # @return [Array<Hash>] one entry per digest, sorted stale-first then oldest-first
        def sweep(stale_after_days: nil)
          list.map do |slug|
            r = read(topic: slug)
            next nil unless r[:found]

            aged = stale_after_days && r[:age_days] && r[:age_days] >= stale_after_days
            {
              topic: slug,
              stale: r[:stale],
              drifted_count: Array(r[:drifted]).size,
              age_days: r[:age_days],
              aged: !!aged,
              needs_refresh: r[:stale] || !!aged,
              access_bound: r[:access_bound],
              generated_at: r[:generated_at]
            }
          end.compact.sort_by { |e| [e[:needs_refresh] ? 0 : 1, -(e[:age_days] || 0)] }
        end

        # Produce a FRESH regeneration package for an existing digest, faithfully from its
        # recorded provenance re-read at current content (I6: same citable universe, new content).
        # Returns a package-shaped hash for the LLM to regenerate, then #write. Re-synthesis of a
        # DERIVED view — never an overwrite of sources (I1/I5).
        #
        # @param topic [String]
        # @return [Hash] package-shaped { topic:, snapshot:, directive:, dropped:, status:, ... }
        def refresh(topic:)
          existing = read(topic: topic)
          return { found: false, topic: topic } unless existing[:found]

          path = File.join(topic_dir(topic), "#{slugify(topic)}.md")
          prior_prov = Array(extract_frontmatter(File.read(path))['provenance'])
          sources = sources_from_provenance(prior_prov)

          read_set = build_read_set(sources)
          resolved_refs = read_set.map { |s| s['ref'] }
          dropped = prior_prov.map { |p| stringify(p)['ref'] } - resolved_refs

          {
            found: true,
            topic: topic,
            directive_id: existing[:directive_id] || default_directive_id,
            snapshot: read_set,
            access_bound: access_bound(read_set),
            directive: generation_directive(topic, read_set),
            dropped: dropped, # sources no longer resolvable, omitted per I4
            resolved_from: existing[:resolved_from], # carry origin forward across refresh
            prior_age_days: existing[:age_days],
            status: read_set.empty? ? 'no_sources' : 'needs_content'
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
          seen = {}
          Array(sources).each_with_object([]) do |s, acc|
            layer = (s['layer'] || s[:layer] || 'l2').to_s.downcase
            path = source_path(layer, s)
            next unless path && File.exist?(path)

            content = safe_read(path)
            next if content.nil? # unreadable -> treat as unresolvable (I4 drop), do not raise

            ref = source_ref(layer, s)
            key = "#{layer}|#{ref}"
            next if seen[key] # dedup: a source cited twice contributes one provenance entry

            seen[key] = true
            acc << {
              'layer' => layer,
              'ref' => ref,
              'path' => path,
              'content_hash' => Digest::SHA256.hexdigest(content),
              'access' => extract_access(content)
            }
          end
        end

        # Reconstruct source descriptors from recorded provenance / a package snapshot (for
        # #refresh and #write). Reads only layer + ref, so caller-supplied hashes are never trusted.
        def sources_from_provenance(provenance)
          Array(provenance).filter_map do |p|
            h = stringify(p)
            case h['layer']
            when 'l2'
              sid, name = h['ref'].to_s.split('/', 2)
              next nil unless sid && name

              { 'layer' => 'l2', 'session_id' => sid, 'name' => name }
            when 'l1'
              { 'layer' => 'l1', 'name' => h['ref'] }
            end
          end
        end

        # Whole days since an ISO8601 timestamp (nil if unparseable). Time.now is fine in the gem.
        def age_days(iso)
          return nil if iso.nil? || iso.to_s.empty?

          ((Time.now - Time.parse(iso.to_s)) / 86_400).floor
        rescue StandardError
          nil
        end

        def drifted_sources(provenance)
          Array(provenance).filter_map do |p|
            h = stringify(p)
            path = path_for_ref(h['layer'], h['ref'])
            content = (path && File.exist?(path)) ? safe_read(path) : nil
            current = content && Digest::SHA256.hexdigest(content)
            # A missing/unreadable source, or a hash mismatch, is drift (I5).
            if current.nil? || current != h['content_hash']
              reason = path.nil? || content.nil? ? 'missing' : 'hash_changed'
              { 'ref' => h['ref'], 'reason' => reason }
            end
          end
        end

        # Read a file, returning nil on any I/O error instead of raising (callers treat nil as
        # unresolvable / missing — keeps package/read/refresh from throwing out of the Digester).
        def safe_read(path)
          File.read(path)
        rescue StandardError
          nil
        end

        # ---- Access bound (I9) ----------------------------------------------------

        # Most restrictive access label among the READ set. v0.1 reads a `visibility`/`access`
        # frontmatter key if present; absent it, defaults to 'default'. Full ACL enforcement
        # (live re-evaluation, principal binding) is a §11 / implementation-review mechanism.
        ACCESS_ORDER = { 'private' => 3, 'restricted' => 2, 'default' => 1, 'public' => 0 }.freeze

        def access_bound(read_set)
          labels = Array(read_set).map { |s| (s['access'] || s[:access] || 'default').to_s }
          labels << 'default' if labels.empty?
          # Unknown labels are treated as MOST restrictive (fail-closed), never downgraded.
          max_known = ACCESS_ORDER.values.max
          labels.max_by { |l| ACCESS_ORDER.fetch(l, max_known) }
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

        # Serialize same-topic writes (I3-style integrity): concurrent generations of the same
        # topic must not clobber each other. Unlike a global lock, this is per-topic-dir.
        def with_topic_lock(dir)
          FileUtils.mkdir_p(dir)
          lock_path = File.join(dir, LOCK_FILE)
          File.open(lock_path, File::CREAT | File::RDWR) do |f|
            f.flock(File::LOCK_EX)
            begin
              yield
            ensure
              f.flock(File::LOCK_UN)
            end
          end
        end

        # I10: a digest file is per-topic. Same topic overwriting itself is regeneration (allowed);
        # a DIFFERENT topic mapping to the same slug must fail loudly, never silently overwrite.
        def guard_slug_collision!(path, topic)
          return unless File.exist?(path)

          existing = extract_frontmatter(safe_read(path).to_s)['topic']
          return if existing.nil? || existing == topic

          raise IdentifierError,
                "slug collision: topic #{topic.inspect} and existing #{existing.inspect} " \
                "both map to #{File.basename(path)}; rename one."
        end

        def source_path(layer, s)
          case layer
          when 'l2'
            l2_path(s['session_id'] || s[:session_id], s['name'] || s[:name])
          when 'l1'
            l1_path(s['name'] || s[:name])
          end
        end

        def path_for_ref(layer, ref)
          case layer
          when 'l2'
            # name cannot contain '/' (safe_seg?), so split is unambiguous.
            sid, name = ref.to_s.split('/', 2)
            l2_path(sid, name)
          when 'l1'
            l1_path(ref)
          end
        end

        def l2_path(sid, name)
          return nil unless safe_seg?(sid) && safe_seg?(name)

          confine(context_dir, File.join(context_dir, sid, name, "#{name}.md"))
        end

        def l1_path(name)
          return nil unless safe_seg?(name)

          dir_form  = confine(knowledge_dir, File.join(knowledge_dir, name, "#{name}.md"))
          flat_form = confine(knowledge_dir, File.join(knowledge_dir, "#{name}.md"))
          return nil unless dir_form && flat_form

          File.exist?(dir_form) ? dir_form : flat_form
        end

        # Reject identifiers that could escape the data tree or break the "sid/name" ref split.
        def safe_seg?(value)
          s = value.to_s
          return false if s.empty?
          return false if s.include?('/') || s.include?('\\') || s.include?("\0")
          return false if ['.', '..'].include?(s)

          true
        end

        # Return path only if it stays within base after expansion; else nil (defense in depth).
        def confine(base, path)
          b = File.expand_path(base)
          p = File.expand_path(path)
          (p == b || p.start_with?("#{b}#{File::SEPARATOR}")) ? p : nil
        end

        def source_ref(layer, s)
          case layer
          when 'l2' then "#{s['session_id'] || s[:session_id]}/#{s['name'] || s[:name]}"
          when 'l1' then (s['name'] || s[:name]).to_s
          end
        end

        # ---- Env helpers ----------------------------------------------------------

        # The .kairos data root. KairosMcp exposes `data_dir` (context_dir/knowledge_dir hang off
        # it); `kairos_dir` is NOT a real accessor, so data_dir is the correct, test-isolatable base.
        def kairos_dir
          if defined?(KairosMcp) && KairosMcp.respond_to?(:data_dir) && KairosMcp.data_dir
            KairosMcp.data_dir
          elsif defined?(KairosMcp) && KairosMcp.respond_to?(:kairos_dir)
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
            # Permit Time/Date: a digest's generated_at (or a hand-edited timestamp) may load as
            # Time; without this the whole frontmatter would silently fail to parse and drop to {}.
            YAML.safe_load($1, permitted_classes: [Symbol, Time, Date]) || {}
          else
            {}
          end
        rescue StandardError
          {}
        end

        def frontmatter_tags(content)
          meta = extract_frontmatter(content)
          Array(meta['tags'] || meta[:tags])
        end

        def frontmatter_value(content, key)
          meta = extract_frontmatter(content)
          meta[key] || meta[key.to_sym]
        end

        # Tag match tolerant to hyphen/underscore variants (mirrors Scanner normalization).
        def tag_match?(tags, tag)
          norm = ->(t) { t.to_s.downcase.tr('-', '_') }
          target = norm.call(tag)
          Array(tags).any? { |t| norm.call(t) == target }
        end

        def context_manager
          return nil unless defined?(KairosMcp::ContextManager)

          KairosMcp::ContextManager.new
        end

        def knowledge_provider
          return nil unless defined?(KairosMcp::KnowledgeProvider)

          KairosMcp::KnowledgeProvider.new
        end

        def stringify(hash)
          (hash || {}).each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
        end
      end
    end
  end
end
