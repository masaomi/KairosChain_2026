# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Dream
      module Tools
        class DreamScan < KairosMcp::Tools::BaseTool
          def name
            'dream_scan'
          end

          def description
            'Scan L2 contexts for recurring patterns, staleness, and consolidation opportunities. ' \
              'Returns promotion candidates, archive candidates, and a knowledge health summary.'
          end

          def category
            :knowledge
          end

          def usecase_tags
            %w[dream scan pattern consolidation promotion staleness health]
          end

          def related_tools
            %w[dream_propose dream_archive dream_recall knowledge_list context_save]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                scope: {
                  type: 'string',
                  enum: %w[l2 l1 all],
                  description: 'Scan scope: l2 (contexts only), l1 (knowledge health), all (both). Default: l2'
                },
                since_session: {
                  type: 'string',
                  description: 'Only scan sessions after this session ID (lexicographic comparison)'
                },
                include_archive_candidates: {
                  type: 'boolean',
                  description: 'Whether to detect stale L2 contexts for archival. Default: true'
                },
                include_l1_dedup: {
                  type: 'boolean',
                  description: 'Check promotion candidates against existing L1 knowledge to mark duplicates. Default: true'
                }
              },
              required: []
            }
          end

          def call(arguments)
            config = load_dream_config
            scanner = KairosMcp::SkillSets::Dream::Scanner.new(config: config)

            scan_result = scanner.scan(
              scope: arguments['scope'] || config.dig('scan', 'default_scope') || 'l2',
              since_session: arguments['since_session'],
              include_archive_candidates: arguments.fetch('include_archive_candidates', true),
              include_l1_dedup: arguments.fetch('include_l1_dedup', true)
            )

            # Record findings on blockchain if non-empty
            record_findings(scan_result) if has_findings?(scan_result)

            text_content(format_output(scan_result))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message, backtrace: e.backtrace&.first(5) }))
          end

          private

          def load_dream_config
            candidates = [
              dream_user_config_path,
              dream_template_config_path
            ].compact

            path = candidates.find { |p| File.exist?(p) }
            return {} unless path

            YAML.safe_load(File.read(path), permitted_classes: [Symbol]) || {}
          end

          def dream_user_config_path
            if defined?(KairosMcp) && KairosMcp.respond_to?(:kairos_dir)
              File.join(KairosMcp.kairos_dir, 'skillsets', 'dream', 'config', 'dream.yml')
            else
              File.join(Dir.pwd, '.kairos', 'skillsets', 'dream', 'config', 'dream.yml')
            end
          end

          def dream_template_config_path
            File.expand_path('../../config/dream.yml', __dir__)
          end

          def has_findings?(scan_result)
            scan_result[:promotion_candidates]&.any? ||
              scan_result[:consolidation_candidates]&.any? ||
              scan_result[:archive_candidates]&.any?
          end

          def record_findings(scan_result)
            return unless defined?(KairosMcp::KairosChain::Chain)

            chain = KairosMcp::KairosChain::Chain.new
            chain.add_block([{
              type: 'dream_scan_findings',
              scope: scan_result[:scope],
              promotion_count: scan_result[:promotion_candidates]&.size || 0,
              consolidation_count: scan_result[:consolidation_candidates]&.size || 0,
              archive_count: scan_result[:archive_candidates]&.size || 0,
              health_summary: scan_result[:health_summary],
              scanned_at: scan_result[:scanned_at]
            }.to_json])
          rescue StandardError => e
            # Log but don't fail if blockchain recording fails
            warn "[DreamScan] Failed to record to blockchain: #{e.message}"
          end

          def format_output(scan_result)
            lines = []
            lines << "## Dream Scan Results"
            lines << ""
            lines << "**Scope**: #{scan_result[:scope]}"
            lines << "**Scanned at**: #{scan_result[:scanned_at]}"
            lines << ""

            # Promotion candidates
            promo = scan_result[:promotion_candidates] || []
            lines << "### Promotion Candidates (#{promo.size})"
            if promo.empty?
              lines << "_No recurring patterns detected._"
            else
              promo.each do |c|
                dedup_marker = c[:already_in_l1] ? " [already in L1: #{c[:l1_match]}]" : ''
                confidence_str = c[:confidence] ? " (confidence: #{c[:confidence]})" : ''
                lines << "- **#{c[:tag]}**: #{c[:session_count]} sessions (strength: #{c[:strength].round(2)})#{confidence_str}#{dedup_marker}"
              end
            end
            lines << ""

            # Consolidation candidates
            consol = scan_result[:consolidation_candidates] || []
            lines << "### Consolidation Candidates (#{consol.size})"
            if consol.empty?
              lines << "_No name overlaps detected._"
            else
              consol.each do |c|
                lines << "- **#{c[:names].join(' + ')}**: Jaccard #{c[:jaccard]}"
              end
            end
            lines << ""

            # Archive candidates
            archive = scan_result[:archive_candidates] || []
            lines << "### Archive Candidates (#{archive.size})"
            if archive.empty?
              lines << "_No stale contexts detected._"
            else
              archive.each do |c|
                lines << "- **#{c[:name]}** (#{c[:session_id]}): #{c[:days_stale]} days stale, #{c[:size_bytes]} bytes"
              end
            end
            lines << ""

            # Health summary
            health = scan_result[:health_summary] || {}
            lines << "### Health Summary"
            health.each do |k, v|
              display_val = v.is_a?(Array) ? v.join(', ') : v.to_s
              lines << "- **#{k}**: #{display_val}"
            end

            lines.join("\n")
          end
        end
      end
    end
  end
end
