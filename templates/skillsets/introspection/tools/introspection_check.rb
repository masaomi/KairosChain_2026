# frozen_string_literal: true

require 'json'
require 'yaml'

module KairosMcp
  module SkillSets
    module Introspection
      module Tools
        # Full self-inspection tool combining health, blockchain, and safety domains.
        # Produces a consolidated report with recommendations.
        class IntrospectionCheck < ::KairosMcp::Tools::BaseTool
          def name
            'introspection_check'
          end

          def description
            'Full self-inspection: knowledge health scores, blockchain integrity, ' \
            'and safety mechanism visibility. Uses Synoptis TrustScorer when available.'
          end

          def category
            :introspection
          end

          def usecase_tags
            %w[health blockchain safety introspection maintenance]
          end

          def related_tools
            %w[introspection_health introspection_safety chain_verify]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                domains: {
                  type: 'array',
                  items: { type: 'string', enum: %w[health blockchain safety] },
                  description: 'Domains to inspect (default: all)'
                },
                format: {
                  type: 'string',
                  enum: %w[markdown json],
                  description: 'Output format (default: markdown)'
                }
              }
            }
          end

          def call(arguments)
            domains = arguments['domains'] || %w[health blockchain safety]
            fmt = arguments['format'] || 'markdown'

            report = { inspected_at: Time.now.iso8601 }

            if domains.include?('health')
              report[:health] = health_scorer.score_l1
            end

            if domains.include?('blockchain')
              report[:blockchain] = check_blockchain
            end

            if domains.include?('safety')
              report[:safety] = safety_inspector.inspect_safety
            end

            report[:recommendations] = build_recommendations(report)

            if fmt == 'json'
              text_content(JSON.pretty_generate(report))
            else
              text_content(format_markdown(report))
            end
          end

          private

          def health_scorer
            @health_scorer ||= HealthScorer.new(
              user_context: @safety&.current_user,
              config: load_config
            )
          end

          def safety_inspector
            @safety_inspector ||= SafetyInspector.new
          end

          def check_blockchain
            chain = ::KairosMcp::KairosChain::Chain.new
            valid = chain.valid?
            blocks = chain.chain
            {
              valid: valid,
              block_count: blocks.size,
              latest_timestamp: blocks.last&.timestamp&.iso8601,
              status: valid ? 'healthy' : 'INTEGRITY_FAILURE'
            }
          rescue StandardError => e
            { valid: false, error: e.message, status: 'error' }
          end

          def build_recommendations(report)
            recs = []

            # Low health scores
            if report[:health]
              report[:health][:entries]&.each do |entry|
                if entry[:health_score] < 0.4
                  recs << {
                    priority: 'medium',
                    target: entry[:name],
                    message: "Low health score (#{entry[:health_score]}). Consider updating or adding attestations."
                  }
                end
              end
            end

            # Blockchain issues
            if report[:blockchain] && !report[:blockchain][:valid]
              recs << { priority: 'critical', target: 'blockchain', message: 'Blockchain integrity check failed.' }
            end

            # Safety gaps
            if report[:safety]
              unless report.dig(:safety, :layers, :l0_approval_workflow, :present)
                recs << { priority: 'high', target: 'approval_workflow', message: 'L0 approval workflow not loaded.' }
              end
            end

            recs
          end

          def load_config
            config_path = File.join(
              ::KairosMcp.skillsets_dir, 'introspection', 'config', 'introspection.yml'
            )
            return {} unless File.exist?(config_path)
            YAML.safe_load(File.read(config_path)) || {}
          rescue StandardError
            {}
          end

          def format_markdown(report)
            lines = []
            lines << "# Introspection Report"
            lines << ""
            lines << "**Inspected at**: #{report[:inspected_at]}"
            lines << ""

            if report[:health]
              lines << "## Knowledge Health"
              lines << ""
              lines << "- **Overall health**: #{report[:health][:overall_health]}"
              lines << "- **Entry count**: #{report[:health][:entry_count]}"
              lines << "- **TrustScorer available**: #{report[:health][:trust_scorer_available]}"
              lines << ""

              if report[:health][:entries]&.any?
                lines << "| Name | Health | Trust | Staleness | Attestations |"
                lines << "|------|--------|-------|-----------|--------------|"
                report[:health][:entries].each do |e|
                  lines << "| #{e[:name]} | #{e[:health_score]} | #{e[:trust_score]} | #{e[:staleness_score]} | #{e[:attestation_count]} |"
                end
                lines << ""
              end
            end

            if report[:blockchain]
              lines << "## Blockchain"
              lines << ""
              lines << "- **Valid**: #{report[:blockchain][:valid]}"
              lines << "- **Block count**: #{report[:blockchain][:block_count]}"
              lines << "- **Latest timestamp**: #{report[:blockchain][:latest_timestamp] || 'N/A'}"
              lines << "- **Status**: #{report[:blockchain][:status]}"
              lines << ""
            end

            if report[:safety]
              lines << "## Safety Mechanisms"
              lines << ""
              report[:safety][:layers]&.each do |layer_name, layer_data|
                lines << "### #{layer_name}"
                layer_data.each { |k, v| lines << "- **#{k}**: #{v}" }
                lines << ""
              end
            end

            if report[:recommendations]&.any?
              lines << "## Recommendations"
              lines << ""
              report[:recommendations].each do |rec|
                lines << "- [#{rec[:priority].upcase}] **#{rec[:target]}**: #{rec[:message]}"
              end
              lines << ""
            end

            lines.join("\n")
          end
        end
      end
    end
  end
end
