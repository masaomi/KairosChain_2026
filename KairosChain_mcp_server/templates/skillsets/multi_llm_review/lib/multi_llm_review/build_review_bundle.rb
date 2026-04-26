# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'prompt_builder'
require_relative 'sanitizer'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Single source of truth for assembling per-reviewer prompt bundles.
      #
      # Phase 12 §3.4. Used by both:
      #   - multi_llm_review (dispatch path) — to build the prompts that are sent to LLMs
      #   - multi_llm_review_bundle (no-dispatch path) — to return the bundle to caller
      #     for external/human-driven review
      #
      # Identical inputs → identical bundles. Contract test asserts this.
      class BuildReviewBundle
        SCHEMA_VERSION = 1

        # Phase 12 §3.10: dispatch + collect responses include this version on
        # the verdict shape itself (separate from feedback_text_schema_version,
        # which lives in FeedbackFormatter). Bumped independently when verdict
        # JSON contract changes (e.g., new field, semantic redefinition).
        VERDICT_SCHEMA_VERSION = 1

        # @param artifact_content [String] sanitized at boundary; raw passthrough is caller responsibility
        # @param artifact_name [String]
        # @param review_type [String] design|implementation|fix_plan|document
        # @param reviewers [Array<Hash>] resolved roster (provider, model, role_label, ...)
        # @param review_context [String]
        # @param review_round [Integer]
        # @param prior_findings [Array<Hash>, nil]
        # @param config [Hash] multi_llm_review.yml contents (for hashing)
        # @return [Hash] canonical bundle
        def self.build(artifact_content:, artifact_name:, review_type:, reviewers:,
                       review_context: 'independent', review_round: 1,
                       prior_findings: nil, config: {})
          # PR1 review fix: sanitize artifact_content at the boundary so reviewer
          # LLM prompts cannot be hijacked by adversarial artifacts containing
          # </artifact> or fullwidth/case-variant delimiters. Same path serves
          # both dispatch and bundle tools (single source of truth for sanitization).
          artifact_content = Sanitizer.sanitize_artifact(artifact_content)

          per_reviewer = reviewers.map do |r|
            {
              'role_label'    => r[:role_label] || r['role_label'],
              'provider'      => r[:provider]   || r['provider'],
              'model'         => r[:model]      || r['model'],
              'system_prompt' => PromptBuilder.build_system_prompt(
                                   review_type, review_context: review_context
                                 ),
              'prompt'        => render_user_message(
                                   artifact_content: artifact_content,
                                   artifact_name: artifact_name,
                                   review_type: review_type,
                                   review_round: review_round,
                                   prior_findings: prior_findings
                                 )
            }
          end

          {
            'per_reviewer_prompts'   => per_reviewer,
            'aggregation_instructions' => aggregation_instructions(review_type, review_round),
            'convergence_rule'       => config['convergence_rule'] || '3/4 APPROVE',
            'reviewer_roster_hash'   => roster_hash(reviewers),
            'config_hash'            => config_hash(config)
          }
        end

        # Wrap a built bundle in the response envelope (with bundle_hash + size).
        # Used by multi_llm_review_bundle tool.
        def self.envelope(bundle)
          canonical = canonical_json(bundle)
          {
            'status'                => 'ok',
            'bundle_schema_version' => SCHEMA_VERSION,
            'bundle_hash'           => "sha256:#{Digest::SHA256.hexdigest(canonical)}",
            'bundle'                => bundle,
            'size_bytes'            => canonical.bytesize,
            'error'                 => nil
          }
        end

        # Canonical JSON for hashing (sorted keys, no whitespace).
        def self.canonical_json(obj)
          JSON.generate(deep_sort(obj))
        end

        def self.deep_sort(obj)
          case obj
          when Hash
            # Coerce keys to strings before sort so Symbol/String mixed Hashes
            # (which can happen when config keeps strings but reviewers use
            # symbols) don't raise ArgumentError on `Symbol <=> String`.
            obj.transform_keys(&:to_s).sort.to_h.transform_values { |v| deep_sort(v) }
          when Array
            obj.map { |v| deep_sort(v) }
          else
            obj
          end
        end

        def self.roster_hash(reviewers)
          canonical = JSON.generate(reviewers.map do |r|
            { 'provider'   => r[:provider]   || r['provider'],
              'model'      => r[:model]      || r['model'],
              'role_label' => r[:role_label] || r['role_label'] }
          end)
          "sha256:#{Digest::SHA256.hexdigest(canonical)}"
        end

        def self.config_hash(config)
          relevant = config.slice(
            'convergence_rule', 'min_quorum', 'convergence_rule_after_exclusion',
            'exclude_orchestrator_model', 'default_orchestrator_strategy', 'effort_map'
          )
          "sha256:#{Digest::SHA256.hexdigest(canonical_json(relevant))}"
        end

        def self.render_user_message(artifact_content:, artifact_name:, review_type:,
                                     review_round:, prior_findings:)
          msgs = PromptBuilder.build_messages(
            artifact_content: artifact_content,
            artifact_name: artifact_name,
            review_type: review_type,
            review_round: review_round,
            prior_findings: prior_findings
          )
          # build_messages returns array of { role:, content: } — bundle_tool emits as single string
          msgs.map { |m| m[:content] || m['content'] }.compact.join("\n")
        end

        def self.aggregation_instructions(review_type, review_round)
          <<~INST.strip
            After collecting all reviewer responses, aggregate as follows:
            1. Parse each response for verdict {APPROVE, REVISE, REJECT}.
            2. Apply convergence rule (e.g., 3/N APPROVE → APPROVE; otherwise REVISE).
            3. Merge findings, sorted by severity (P0 first), de-dup by issue text.
            4. For round #{review_round} #{review_type} reviews, prior findings should be verified as CLOSED/NEEDS_MORE_WORK/REOPENED.
          INST
        end
      end
    end
  end
end
