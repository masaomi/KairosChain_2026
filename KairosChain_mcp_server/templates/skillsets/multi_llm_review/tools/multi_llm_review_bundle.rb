# frozen_string_literal: true

require 'json'
require 'yaml'
require_relative '../lib/multi_llm_review/build_review_bundle'
require_relative '../lib/multi_llm_review/observer_set'
require_relative '../lib/multi_llm_review/sanitizer'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      module Tools
        # Phase 12 §3.4 — bundle-only tool. Returns ready-to-paste per-reviewer prompts
        # WITHOUT dispatching to LLMs. Used by Agent Gate 5.5a (L0 human-checkpoint path)
        # and by anyone who wants to run multi-LLM review externally.
        #
        # Shares BuildReviewBundle helper with multi_llm_review (single source of truth).
        class MultiLlmReviewBundle < KairosMcp::Tools::BaseTool
          def name
            'multi_llm_review_bundle'
          end

          def description
            'Build a multi-LLM review prompt bundle without dispatching. ' \
              'Returns per-reviewer prompts + aggregation instructions + integrity hashes ' \
              'for external/human-driven review (e.g., L0 human-checkpoint).'
          end

          def category
            :review
          end

          def usecase_tags
            %w[review bundle prompt human-handoff]
          end

          def related_tools
            %w[multi_llm_review chain_record]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                artifact_content: {
                  type: 'string',
                  description: 'Full text of the artifact to be reviewed'
                },
                artifact_name: {
                  type: 'string',
                  description: 'Identifier for the artifact'
                },
                review_type: {
                  type: 'string',
                  enum: %w[design implementation fix_plan document],
                  description: 'Type of review the bundle targets'
                },
                review_context: {
                  type: 'string',
                  enum: %w[independent project_aware],
                  default: 'independent',
                  description: 'Whether reviewers should see project context'
                },
                review_round: {
                  type: 'integer',
                  default: 1,
                  description: 'Review round number (1-based)'
                },
                prior_findings: {
                  type: 'array',
                  items: { type: 'object' },
                  description: 'Findings from prior round to verify as resolved (optional)'
                },
                escalate: {
                  type: 'boolean',
                  description: 'Include the reserve observers declared in config ' \
                    '(escalation_reviewers) in the bundle. Default false.',
                  default: false
                }
              },
              required: %w[artifact_content artifact_name review_type]
            }
          end

          def call(arguments)
            config = load_review_config

            # INV-E1: refused here for the same reason the dispatch tool
            # refuses it. Silently ignoring it would leave a stale caller
            # believing it had chosen the observers.
            if arguments['reviewers_override']
              return text_content(JSON.generate(
                'status' => 'error',
                'bundle_schema_version' => BuildReviewBundle::SCHEMA_VERSION,
                'error' => 'reviewers_override was removed: the reviewer roster is ' \
                           'canonical in config and cannot be replaced per call. ' \
                           'To include the reserve observers, set escalate: true.'
              ))
            end

            begin
              reviewers = resolve_reviewers(arguments, config)
            rescue ObserverSet::RosterError => e
              return text_content(JSON.generate(
                'status' => 'error',
                'bundle_schema_version' => BuildReviewBundle::SCHEMA_VERSION,
                'error' => e.message
              ))
            end

            if reviewers.empty?
              return text_content(JSON.generate(
                'status' => 'error',
                'bundle_schema_version' => BuildReviewBundle::SCHEMA_VERSION,
                'error' => 'no reviewers configured'
              ))
            end

            bundle = BuildReviewBundle.build(
              artifact_content: arguments['artifact_content'].to_s,
              artifact_name:    arguments['artifact_name'].to_s,
              review_type:      arguments['review_type'].to_s,
              reviewers:        reviewers,
              review_context:   arguments['review_context'] || 'independent',
              review_round:     arguments['review_round'] || 1,
              prior_findings:   arguments['prior_findings'],
              config:           config
            )

            response = BuildReviewBundle.envelope(bundle)
            text_content(JSON.generate(response))
          rescue StandardError => e
            text_content(JSON.generate(
              'status' => 'error',
              'bundle_schema_version' => BuildReviewBundle::SCHEMA_VERSION,
              'error' => "bundle build failed: #{e.class.name}: #{e.message}"
            ))
          end

          private

          def load_review_config
            config_path = File.join(__dir__, '..', 'config', 'multi_llm_review.yml')
            if File.exist?(config_path)
              YAML.safe_load(File.read(config_path), permitted_classes: [Symbol]) || {}
            else
              {}
            end
          end

          # INV-E1 covers this path too. A bundle names which observers a
          # human is to hand the artifact to, so letting the caller supply that
          # list would split the canonical set exactly as the dispatch path
          # would — the fact that the running happens by hand does not make the
          # roster less canonical.
          def resolve_reviewers(arguments, config)
            list = (config['reviewers'] || []).dup
            list += (config['escalation_reviewers'] || []) if arguments['escalate']
            slots = list.map { |r| r.transform_keys(&:to_sym) }
            # INV-E5 applies to a slot a human will run by hand just as much as
            # to one this process spawns: a slot that does not name its model
            # sends the human to whatever the CLI defaults to.
            ObserverSet.validate_slots!(slots) unless slots.empty?
            slots
          end
        end
      end
    end
  end
end
