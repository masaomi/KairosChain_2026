# frozen_string_literal: true

require 'yaml'
require 'set'
require 'time'

module KairosMcp
  module SkillSets
    module Dream
      class Scanner
        JACCARD_THRESHOLD = 0.5

        def initialize(config: {})
          @config = config
          scan_config = config.fetch('scan', {})
          archive_config = config.fetch('archive', {})
          @min_recurrence = scan_config.fetch('min_recurrence', 3)
          @max_candidates = scan_config.fetch('max_candidates', 5)
          @staleness_days = archive_config.fetch('staleness_threshold_days', 90)
          @skip_archived = scan_config.fetch('skip_archived', true)
        end

        # Main scan entry point.
        #
        # @param scope [String] 'l2', 'l1', or 'all'
        # @param since_session [String, nil] Only scan sessions after this ID
        # @param include_archive_candidates [Boolean] Whether to detect stale L2
        # @return [Hash] Structured scan result
        def scan(scope: 'l2', since_session: nil, include_archive_candidates: true)
          result = {
            scope: scope,
            scanned_at: Time.now.iso8601,
            promotion_candidates: [],
            consolidation_candidates: [],
            archive_candidates: [],
            health_summary: {}
          }

          if %w[l2 all].include?(scope)
            scan_l2(result, since_session: since_session,
                            include_archive_candidates: include_archive_candidates)
          end

          if %w[l1 all].include?(scope)
            scan_l1(result)
          end

          result
        end

        private

        # ---------------------------------------------------------------
        # L2 scanning
        # ---------------------------------------------------------------

        def scan_l2(result, since_session: nil, include_archive_candidates: true)
          all_contexts = load_all_l2_contexts(since_session: since_session)

          # Partition: live contexts vs archived stubs
          live, archived = all_contexts.partition { |c| c[:status] != 'soft-archived' }

          # Promotion candidates: tag co-occurrence across sessions
          sessions_tags = build_sessions_tags(live)
          result[:promotion_candidates] = detect_promotion_candidates(sessions_tags)

          # Consolidation candidates: name token overlap
          result[:consolidation_candidates] = detect_consolidation_candidates(live)

          # Archive candidates: stale L2 contexts
          if include_archive_candidates
            result[:archive_candidates] = detect_stale_l2(live)
          end

          # Health summary
          result[:health_summary].merge!(
            total_l2: all_contexts.size,
            total_live: live.size,
            total_archived: archived.size,
            sessions_scanned: sessions_tags.keys.size
          )
        end

        # Load all L2 contexts via ContextManager.
        #
        # @return [Array<Hash>] context metadata hashes
        def load_all_l2_contexts(since_session: nil)
          cm = context_manager
          return [] unless cm

          contexts = []
          sessions = cm.list_sessions

          sessions.each do |session|
            sid = session[:session_id]
            next if since_session && sid <= since_session

            session_contexts = cm.list_contexts_in_session(sid)
            session_contexts.each do |ctx|
              md_path = context_md_path(sid, ctx[:name])
              next unless md_path && File.exist?(md_path)

              content = File.read(md_path)
              tags = extract_tags(content)
              status = extract_status(content)
              mtime = File.mtime(md_path)

              contexts << {
                session_id: sid,
                name: ctx[:name],
                path: md_path,
                tags: tags,
                status: status,
                mtime: mtime,
                size_bytes: File.size(md_path)
              }
            end
          end

          contexts
        end

        # Build a mapping of session_id => { context_name => [tags] }
        def build_sessions_tags(contexts)
          result = Hash.new { |h, k| h[k] = {} }
          contexts.each do |ctx|
            result[ctx[:session_id]][ctx[:name]] = ctx[:tags]
          end
          result
        end

        # Detect tags that recur across min_recurrence+ distinct sessions.
        #
        # @param sessions_tags [Hash] { session_id => { context_name => [tags] } }
        # @return [Array<Hash>] promotion candidate hashes
        def detect_promotion_candidates(sessions_tags)
          tag_sessions = Hash.new { |h, k| h[k] = Set.new }

          sessions_tags.each do |session_id, contexts|
            session_tags = contexts.values.flatten.uniq
            session_tags.each do |tag|
              tag_sessions[tag] << session_id
            end
          end

          candidates = tag_sessions
                       .select { |_tag, sids| sids.size >= @min_recurrence }
                       .sort_by { |_tag, sids| -sids.size }
                       .first(@max_candidates)
                       .map do |tag, sids|
            {
              tag: tag,
              session_count: sids.size,
              sessions: sids.to_a,
              signal: 'tag_recurrence',
              strength: sids.size.to_f / @min_recurrence
            }
          end

          candidates
        end

        # Detect context pairs with high name-token overlap (Jaccard).
        #
        # @param contexts [Array<Hash>] live contexts
        # @return [Array<Hash>] consolidation candidate pairs
        def detect_consolidation_candidates(contexts)
          # Deduplicate by name (same name across sessions = same concept)
          unique_names = contexts.map { |c| c[:name] }.uniq
          candidates = []

          unique_names.combination(2).each do |name_a, name_b|
            sim = jaccard_similarity(name_a, name_b)
            next unless sim >= JACCARD_THRESHOLD

            candidates << {
              names: [name_a, name_b],
              jaccard: sim.round(3),
              signal: 'name_overlap'
            }
          end

          candidates.sort_by { |c| -c[:jaccard] }.first(@max_candidates)
        end

        # Detect stale L2 contexts by mtime.
        #
        # @param contexts [Array<Hash>] live contexts
        # @return [Array<Hash>] archive candidate hashes
        def detect_stale_l2(contexts)
          now = Time.now
          threshold = @staleness_days * 86_400

          contexts.select { |ctx| (now - ctx[:mtime]) > threshold }
                  .sort_by { |ctx| ctx[:mtime] }
                  .first(@max_candidates)
                  .map do |ctx|
            days_stale = ((now - ctx[:mtime]) / 86_400).to_i
            {
              name: ctx[:name],
              session_id: ctx[:session_id],
              path: ctx[:path],
              days_stale: days_stale,
              mtime: ctx[:mtime].iso8601,
              size_bytes: ctx[:size_bytes],
              signal: 'l2_staleness'
            }
          end
        end

        # ---------------------------------------------------------------
        # L1 scanning
        # ---------------------------------------------------------------

        def scan_l1(result)
          kp = knowledge_provider
          return unless kp

          l1_skills = kp.list
          l1_names = l1_skills.map { |s| s[:name] }

          # Collect all L2 tags from live contexts
          all_l2_tags = collect_all_l2_tags

          # L1 skills not referenced in any L2 tag
          stale_l1 = l1_names.reject { |name| all_l2_tags.include?(name) }

          result[:health_summary].merge!(
            total_l1: l1_names.size,
            stale_l1: stale_l1,
            stale_l1_count: stale_l1.size
          )
        end

        # Collect the union of all tags from live L2 contexts.
        def collect_all_l2_tags
          cm = context_manager
          return Set.new unless cm

          tags = Set.new
          cm.list_sessions.each do |session|
            cm.list_contexts_in_session(session[:session_id]).each do |ctx|
              md_path = context_md_path(session[:session_id], ctx[:name])
              next unless md_path && File.exist?(md_path)

              content = File.read(md_path)
              status = extract_status(content)
              next if status == 'soft-archived'

              extract_tags(content).each { |t| tags << t }
            end
          end
          tags
        end

        # ---------------------------------------------------------------
        # Helpers
        # ---------------------------------------------------------------

        def extract_tags(content)
          if content =~ /\A---\n(.*?)\n---/m
            yaml = YAML.safe_load($1, permitted_classes: [Symbol]) rescue {}
            Array(yaml['tags'] || yaml[:tags])
          else
            []
          end
        end

        def extract_status(content)
          if content =~ /\A---\n(.*?)\n---/m
            yaml = YAML.safe_load($1, permitted_classes: [Symbol]) rescue {}
            yaml['status'] || yaml[:status]
          end
        end

        def jaccard_similarity(name_a, name_b)
          tokens_a = name_a.split('_').to_set
          tokens_b = name_b.split('_').to_set
          intersection = (tokens_a & tokens_b).size.to_f
          union = (tokens_a | tokens_b).size.to_f
          union > 0 ? intersection / union : 0.0
        end

        def context_md_path(session_id, name)
          dir = context_dir
          return nil unless dir

          File.join(dir, session_id, name, "#{name}.md")
        end

        def context_dir
          if defined?(KairosMcp) && KairosMcp.respond_to?(:context_dir)
            KairosMcp.context_dir
          else
            File.join(Dir.pwd, '.kairos', 'context')
          end
        end

        def context_manager
          return nil unless defined?(KairosMcp::ContextManager)

          KairosMcp::ContextManager.new
        end

        def knowledge_provider
          return nil unless defined?(KairosMcp::KnowledgeProvider)

          KairosMcp::KnowledgeProvider.new
        end
      end
    end
  end
end
