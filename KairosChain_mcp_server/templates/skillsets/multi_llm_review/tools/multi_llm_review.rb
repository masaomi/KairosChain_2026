# frozen_string_literal: true

require 'json'
require 'yaml'
require_relative '../lib/multi_llm_review/prompt_builder'
require_relative '../lib/multi_llm_review/consensus'
require_relative '../lib/multi_llm_review/dispatcher'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      module Tools
        class MultiLlmReview < KairosMcp::Tools::BaseTool
          def name
            'multi_llm_review'
          end

          def description
            'Run a parallel multi-LLM review on an artifact. Dispatches to N configured ' \
              'reviewers, collects verdicts, and returns consensus with aggregated findings.'
          end

          def category
            :review
          end

          def usecase_tags
            %w[review multi-llm consensus quality]
          end

          def related_tools
            %w[llm_call llm_status]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                artifact_content: {
                  type: 'string',
                  description: 'Full text of the artifact to review'
                },
                artifact_name: {
                  type: 'string',
                  description: 'Identifier for the artifact (e.g., "design_v0.3")'
                },
                review_type: {
                  type: 'string',
                  enum: %w[design implementation fix_plan document],
                  description: 'Type of review to perform'
                },
                review_round: {
                  type: 'integer',
                  description: 'Review round number (1-based, default 1)',
                  default: 1
                },
                prior_findings: {
                  type: 'array',
                  description: 'Findings from prior round to verify as resolved (optional)',
                  items: { type: 'object' }
                },
                review_context: {
                  type: 'string',
                  enum: %w[independent project_aware],
                  description: 'Whether reviewers should see project context. ' \
                    'Default: independent (prevents contamination bias).',
                  default: 'independent'
                },
                reviewers_override: {
                  type: 'array',
                  description: 'Override reviewer roster from config (optional). ' \
                    'Each entry: {provider, model, role_label}',
                  items: { type: 'object' }
                },
                convergence_rule_override: {
                  type: 'string',
                  description: 'Override convergence rule (e.g., "3/4 APPROVE")'
                },
                max_concurrent_override: {
                  type: 'integer',
                  description: 'Override max concurrent reviewers (default from config)'
                },
                timeout_seconds_override: {
                  type: 'integer',
                  description: 'Override dispatch timeout in seconds (default from config)'
                },
                complexity: {
                  type: 'string',
                  enum: %w[auto low medium high critical],
                  description: 'Review complexity level. Controls reviewer effort via effort_map in config. ' \
                    'auto (default) = derive from review_type + artifact size. ' \
                    'critical = security-critical, maximum effort.',
                  default: 'auto'
                }
              },
              required: %w[artifact_content artifact_name review_type]
            }
          end

          def call(arguments)
            config = load_review_config
            reviewers = resolve_reviewers(arguments, config)
            review_context = arguments['review_context'] ||
                             config['default_review_context'] || 'independent'
            review_round = arguments['review_round'] || 1
            convergence_rule = arguments['convergence_rule_override'] ||
                               config['convergence_rule'] || '3/4 APPROVE'
            min_quorum = config['min_quorum'] || 2

            # Auto-detect complexity + apply effort_map to reviewers
            complexity = resolve_complexity(arguments, config)
            reviewers = apply_effort_map(reviewers, complexity, config)

            # Build prompts
            system_prompt = PromptBuilder.build_system_prompt(
              arguments['review_type'],
              review_context: review_context
            )

            prior_findings = symbolize_findings(arguments['prior_findings'])
            messages = PromptBuilder.build_messages(
              artifact_content: arguments['artifact_content'],
              artifact_name: arguments['artifact_name'],
              review_type: arguments['review_type'],
              review_round: review_round,
              prior_findings: prior_findings
            )

            # Dispatch to all reviewers (argument overrides take precedence)
            max_concurrent = arguments['max_concurrent_override'] ||
                             config['max_concurrent'] || 2
            timeout_secs = arguments['timeout_seconds_override'] ||
                           config['timeout_seconds'] || 300

            dispatcher = Dispatcher.new(
              self,
              timeout_seconds: timeout_secs,
              max_concurrent: max_concurrent
            )

            # @invocation_context may be nil for direct MCP calls (no parent tool).
            # BaseTool#invoke_tool handles nil by creating a default InvocationContext.
            raw_results = dispatcher.dispatch(
              reviewers, messages, system_prompt,
              context: @invocation_context,
              review_context: review_context
            )

            # Compute consensus
            consensus = Consensus.aggregate(raw_results, convergence_rule,
                                            min_quorum: min_quorum)

            payload = {
              'status' => 'ok',
              'verdict' => consensus[:verdict],
              'convergence' => hash_to_string_keys(consensus[:convergence]),
              'reviews' => consensus[:reviews].map { |r|
                {
                  'role_label' => r[:role_label],
                  'provider' => r[:provider],
                  'model' => r[:model],
                  'verdict' => r[:verdict],
                  'elapsed_seconds' => r[:elapsed_seconds],
                  'error' => r[:error],
                  'raw_text_length' => r[:raw_text].to_s.length
                }
              },
              'aggregated_findings' => consensus[:aggregated_findings].map { |f|
                hash_to_string_keys(f)
              },
              'review_round' => review_round,
              'review_type' => arguments['review_type'],
              'artifact_name' => arguments['artifact_name'],
              'complexity' => complexity,
              'llm_calls' => raw_results.count { |r| r[:status] == :success }
            }

            text_content(JSON.generate(payload))
          rescue StandardError => e
            text_content(JSON.generate({
              'status' => 'error',
              'error' => "#{e.class}: #{e.message}"
            }))
          end

          private

          def load_review_config
            config_path = File.join(__dir__, '..', 'config', 'multi_llm_review.yml')
            if File.exist?(config_path)
              YAML.safe_load(File.read(config_path), permitted_classes: [Symbol]) || {}
            else
              default_config
            end
          end

          def default_config
            {
              'convergence_rule' => '3/4 APPROVE',
              'min_quorum' => 2,
              'timeout_seconds' => 300,
              'max_concurrent' => 2,
              'reviewers' => [
                { 'provider' => 'claude_code', 'role_label' => 'claude_team' },
                { 'provider' => 'codex', 'role_label' => 'codex' },
                { 'provider' => 'cursor', 'role_label' => 'cursor' }
              ]
            }
          end

          # Resolve complexity: explicit arg > auto-detection.
          def resolve_complexity(arguments, config)
            explicit = arguments['complexity']
            return explicit if explicit && explicit != 'auto'

            auto_cfg = config['auto_complexity'] || {}
            review_type = arguments['review_type'].to_s
            artifact_size = arguments['artifact_content'].to_s.length
            small = auto_cfg['small_artifact_chars'] || 500
            large = auto_cfg['large_artifact_chars'] || 5000

            # review_type overrides take precedence
            return auto_cfg['document_review_type'] || 'low' if review_type == 'document'
            return auto_cfg['design_review_type'] || 'high' if review_type == 'design'

            # Size-based detection for implementation/fix_plan
            return 'low' if artifact_size <= small
            return 'high' if artifact_size > large
            'medium'
          end

          # Apply complexity → effort_map: override each reviewer's effort
          # based on their provider. If no mapping exists, keep roster default.
          def apply_effort_map(reviewers, complexity, config)
            effort_map = config.dig('effort_map', complexity) || {}
            return reviewers if effort_map.empty?

            reviewers.map do |r|
              provider = (r[:provider] || r['provider']).to_s
              mapped = effort_map[provider]
              if mapped
                r.merge(effort: mapped)
              else
                r
              end
            end
          end

          def resolve_reviewers(arguments, config)
            if arguments['reviewers_override'] && !arguments['reviewers_override'].empty?
              arguments['reviewers_override'].map { |r| symbolize_keys(r) }
            else
              (config['reviewers'] || default_config['reviewers']).map { |r| symbolize_keys(r) }
            end
          end

          def symbolize_keys(hash)
            hash.transform_keys(&:to_sym)
          end

          def symbolize_findings(findings)
            return nil unless findings.is_a?(Array)
            findings.map { |f| f.transform_keys(&:to_sym) }
          end

          def hash_to_string_keys(hash)
            return hash unless hash.is_a?(Hash)
            hash.transform_keys(&:to_s)
          end

        end
      end
    end
  end
end
