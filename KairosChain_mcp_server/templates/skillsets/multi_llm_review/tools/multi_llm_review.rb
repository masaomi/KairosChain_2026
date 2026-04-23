# frozen_string_literal: true

require 'json'
require 'yaml'
require 'time'
require_relative '../lib/multi_llm_review/prompt_builder'
require_relative '../lib/multi_llm_review/consensus'
require_relative '../lib/multi_llm_review/dispatcher'
require_relative '../lib/multi_llm_review/pending_state'
require_relative '../lib/multi_llm_review/persona_assembly'

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
                },
                orchestrator_model: {
                  type: %w[string null],
                  description: 'Self-referential model identifier of the calling orchestrator ' \
                    '(e.g., "claude-opus-4-7"). Used by exclude/delegate strategies to ' \
                    'identify the roster entry corresponding to the caller. Claude Code ' \
                    'orchestrators should read the model ID from their own system prompt.'
                },
                orchestrator_strategy: {
                  type: 'string',
                  enum: %w[exclude subprocess delegate],
                  description: 'How to handle the orchestrator-matching reviewer. ' \
                    '"exclude" (default): drop the matching reviewer entirely. ' \
                    '"subprocess": treat like any other reviewer (spawn fresh claude -p). ' \
                    '"delegate": two-call protocol — subprocess reviewers run synchronously, ' \
                    'orchestrator runs persona-based Agent Team review in its own context, ' \
                    'then submits results via multi_llm_review_collect with the returned token.',
                  default: 'exclude'
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
            base_rule = arguments['convergence_rule_override'] ||
                        config['convergence_rule'] || '3/4 APPROVE'
            min_quorum = config['min_quorum'] || 2

            # Self-referential orchestrator strategy:
            #   exclude    - drop matching reviewer (back-compat default)
            #   subprocess - keep matching reviewer as a normal subprocess
            #   delegate   - drop matching reviewer here; orchestrator submits
            #                its persona team review later via collect.
            orchestrator_model = arguments['orchestrator_model']
            strategy = arguments['orchestrator_strategy'] || 'exclude'
            reviewers, partitioned_count = partition_for_strategy(
              reviewers, orchestrator_model, strategy, config
            )
            convergence_rule = if arguments['convergence_rule_override']
                                 base_rule
                               elsif strategy == 'exclude' && partitioned_count > 0
                                 config['convergence_rule_after_exclusion'] || base_rule
                               else
                                 base_rule
                               end

            # Best-effort GC of expired pending tokens on every call.
            # Errors are logged to STDERR; they do not fail the tool call.
            begin
              PendingState.cleanup_expired!
            rescue StandardError => e
              warn "[multi_llm_review] cleanup_expired failed: #{e.class}: #{e.message}"
            end

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

            # Delegate strategy: don't compute final consensus here. Persist
            # subprocess results to pending state and return a delegation manifest
            # so the orchestrator can submit its persona team review via collect.
            if strategy == 'delegate' && partitioned_count > 0
              return delegate_response(
                raw_results: raw_results,
                arguments: arguments,
                config: config,
                orchestrator_model: orchestrator_model,
                convergence_rule: convergence_rule,
                min_quorum: min_quorum,
                review_round: review_round,
                complexity: complexity
              )
            end

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
              'llm_calls' => raw_results.count { |r| r[:status] == :success },
              'orchestrator_model' => orchestrator_model,
              'orchestrator_strategy' => strategy,
              'excluded_reviewers' => (strategy == 'exclude' ? partitioned_count : 0)
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

          # Drop reviewers whose model exactly matches the orchestrator's
          # model. Returns [filtered_reviewers, excluded_count].
          # No-op when orchestrator_model is nil/empty or the config flag
          # exclude_orchestrator_model is false.
          def exclude_orchestrator(reviewers, orchestrator_model, config)
            return [reviewers, 0] if orchestrator_model.nil? ||
                                     orchestrator_model.to_s.empty?
            return [reviewers, 0] unless config.fetch('exclude_orchestrator_model', true)

            kept = reviewers.reject do |r|
              (r[:model] || r['model']).to_s == orchestrator_model.to_s
            end
            [kept, reviewers.size - kept.size]
          end

          # Partition roster according to orchestrator_strategy.
          #   exclude    - same as exclude_orchestrator (drop matching).
          #   subprocess - keep all reviewers; matching becomes a normal subprocess.
          #   delegate   - drop matching reviewer here (orchestrator submits later via collect).
          # Returns [reviewers_to_dispatch, partitioned_count].
          def partition_for_strategy(reviewers, orchestrator_model, strategy, config)
            case strategy
            when 'subprocess'
              [reviewers, 0]
            when 'delegate'
              return [reviewers, 0] if orchestrator_model.nil? ||
                                       orchestrator_model.to_s.empty?
              kept = reviewers.reject do |r|
                (r[:model] || r['model']).to_s == orchestrator_model.to_s
              end
              [kept, reviewers.size - kept.size]
            else # 'exclude' (default)
              exclude_orchestrator(reviewers, orchestrator_model, config)
            end
          end

          # Build the delegation manifest response. Persists subprocess results
          # to pending state under a UUID v4 token; orchestrator then submits
          # its persona team review via multi_llm_review_collect.
          def delegate_response(raw_results:, arguments:, config:, orchestrator_model:,
                                convergence_rule:, min_quorum:, review_round:, complexity:)
            # Validate orchestrator_model charset/length early (defense in
            # depth — partition_for_strategy also guards empty/nil).
            begin
              PersonaAssembly.validate_orchestrator_model!(orchestrator_model)
            rescue ArgumentError => e
              return text_content(JSON.generate({
                'status' => 'error',
                'error' => e.message
              }))
            end

            # If no subprocess reviewers remain after excluding the orchestrator
            # (e.g., roster has only the orchestrator's model), delegate mode
            # degenerates to "just the orchestrator's persona team" which
            # defeats the multi-model purpose. Fail fast.
            if raw_results.empty?
              return text_content(JSON.generate({
                'status' => 'error',
                'error' => 'orchestrator_strategy=delegate requires at least one non-orchestrator reviewer; roster is empty after exclusion'
              }))
            end

            # If all subprocess reviewers errored out, fail Call 1 instead of
            # writing pending state — there's nothing useful for collect to merge.
            successful = raw_results.count { |r| r[:status] == :success }
            if successful == 0
              return text_content(JSON.generate({
                'status' => 'error',
                'error' => 'all subprocess reviewers failed',
                'subprocess_failures' => raw_results.map { |r|
                  {
                    'role_label' => r[:role_label],
                    'error_class' => (r[:error].is_a?(Hash) ? r[:error]['type'] || r[:error][:type] : nil),
                    'error_message' => (r[:error].is_a?(Hash) ? r[:error]['message'] || r[:error][:message] : r[:error].to_s),
                    'elapsed_seconds' => r[:elapsed_seconds]
                  }
                }
              }))
            end

            deadline_secs = config.dig('delegation', 'collect_deadline_seconds') || 600
            now = Time.now
            token = PendingState.generate_token

            PendingState.write(token, {
              'token' => token,
              'created_at' => now.iso8601,
              'collect_deadline' => (now + deadline_secs).iso8601,
              'review_type' => arguments['review_type'],
              'artifact_name' => arguments['artifact_name'],
              'review_round' => review_round,
              'complexity' => complexity,
              'orchestrator_model' => orchestrator_model,
              'convergence_rule' => convergence_rule,
              'min_quorum' => min_quorum,
              'subprocess_results' => raw_results.map { |r| serialize_review(r) },
              'collected' => false
            })

            text_content(JSON.generate({
              'status' => 'delegation_pending',
              'collect_token' => token,
              'delegation' => {
                'instruction' => 'Run persona-based review using your Agent tool. ' \
                  "Choose #{PersonaAssembly::MIN_PERSONAS}-#{PersonaAssembly::MAX_PERSONAS} " \
                  'personas appropriate to the artifact and review_type. ' \
                  'Submit findings via multi_llm_review_collect with the collect_token below.',
                'review_type' => arguments['review_type'],
                'persona_count_min' => PersonaAssembly::MIN_PERSONAS,
                'persona_count_max' => PersonaAssembly::MAX_PERSONAS
              },
              'subprocess_done' => successful,
              'subprocess_total' => raw_results.size,
              'must_collect_by' => (now + deadline_secs).iso8601,
              'orchestrator_model' => orchestrator_model
            }))
          end

          # Convert a Dispatcher review hash to JSON-safe form for pending state.
          def serialize_review(r)
            {
              'role_label' => r[:role_label],
              'provider' => r[:provider],
              'model' => r[:model],
              'raw_text' => r[:raw_text],
              'elapsed_seconds' => r[:elapsed_seconds],
              'error' => r[:error],
              'status' => r[:status].to_s
            }
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
