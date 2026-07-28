# frozen_string_literal: true

require 'json'
require 'yaml'
require 'time'
require_relative '../lib/multi_llm_review/prompt_builder'
require_relative '../lib/multi_llm_review/consensus'
require_relative '../lib/multi_llm_review/dispatcher'
require 'fileutils'
require_relative '../lib/multi_llm_review/pending_state'
require_relative '../lib/multi_llm_review/persona_assembly'
require_relative '../lib/multi_llm_review/worker_spawner'
require_relative '../lib/multi_llm_review/feedback_formatter'
require_relative '../lib/multi_llm_review/sanitizer'
require_relative '../lib/multi_llm_review/build_review_bundle'
require_relative '../lib/multi_llm_review/observer_set'
require_relative '../lib/multi_llm_review/review_serializer'

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

          # Phase 1.5 — Capability Boundary canonical example.
          # multi_llm_review depends on:
          #   - subprocess CLIs (claude_cli, codex_cli, cursor_cli) for advisory reviewers
          #   - harness-specific Agent tool (Claude Code) for the persona unanimity gate
          # The persona Agent path IS the blocking gate (Anthropic unanimity doctrine);
          # subprocess advisory degrades gracefully but the gate path is harness_specific.
          def harness_requirement
            {
              tier: :harness_assisted,
              requires_externals: %i[claude_cli codex_cli cursor_cli],
              requires_harness_features: [
                {
                  feature: :agent_tool,
                  target_harness: :claude_code,
                  used_for: 'persona unanimity gate (Anthropic doctrine, blocking gate)',
                  degrades_to: 'direct API persona invocation (Phase 2+ candidate)'
                }
              ],
              fallback_chain: [
                { path: 'claude_code_agent_personas', tier: :harness_specific,
                  target_harness: :claude_code,
                  condition: 'running under Claude Code with Agent tool available' },
                { path: 'direct_api_personas', tier: :harness_assisted,
                  condition: 'API credentials configured for direct LLM calls' },
                { path: 'manual_suggestion', tier: :core,
                  condition: 'always available; KairosChain provides procedure, human executes' }
              ],
              acknowledgment: 'multi_llm_review primary value (persona unanimity gate) is harness-coupled; this declaration makes that explicit per Acknowledgment invariant'
            }
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
                escalate: {
                  type: 'boolean',
                  description: 'Add the reserve observers declared in config ' \
                    '(escalation_reviewers) for this call only. Use for artifacts the ' \
                    'caller judges hard enough to be worth extra observers; difficulty ' \
                    'is the caller\'s judgement, not this tool\'s. Adding observers ' \
                    'raises the required agreement, since the rule is a ratio. ' \
                    'Default false.',
                  default: false
                },
                persona_model: {
                  type: %w[string null],
                  description: 'Model the caller will actually run its persona team on, ' \
                    'when that differs from the caller itself (e.g. a Fable 5 session ' \
                    'spawning Opus 5 personas). The roster slot matching this model is ' \
                    'occupied by the persona result instead of being dispatched. ' \
                    'Omit when the persona runs on the calling model — the ' \
                    'orchestrator_model declaration then stands in this position. ' \
                    'This value is recorded as a declaration and is never verified: ' \
                    'the persona runs outside this system and cannot be observed from it.'
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
                collect_deadline_seconds_override: {
                  type: 'integer',
                  description: 'Override how long the orchestrator has to call ' \
                    'multi_llm_review_collect before the pending token expires ' \
                    '(default from config: delegation.collect_deadline_seconds). ' \
                    'In the async/parallel path, the effective deadline is also ' \
                    'auto-extended to cover the worker self_timeout plus a poll margin, ' \
                    'so raising timeout_seconds_override alone no longer leaves the ' \
                    'collect deadline shorter than the worker lifespan.'
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
                    '(e.g., "claude-opus-5"). Pass the bare ID — strip any context ' \
                    'suffix such as "[1m]", which the roster comparison rejects. ' \
                    'Used by exclude/delegate strategies to ' \
                    'identify the roster entry corresponding to the caller. Claude Code ' \
                    'orchestrators should read the model ID from their own system prompt.'
                },
                orchestrator_strategy: {
                  type: 'string',
                  enum: %w[exclude subprocess delegate],
                  description: 'How to handle the orchestrator-matching reviewer. ' \
                    '"delegate" (default): two-call protocol — subprocess reviewers run ' \
                    'in a detached worker (parallel with orchestrator persona Agent Team), ' \
                    'then results are submitted via multi_llm_review_collect. ' \
                    '"exclude": drop the matching reviewer entirely (legacy default). ' \
                    '"subprocess": treat like any other reviewer (spawn fresh claude -p). ' \
                    'Config key: default_orchestrator_strategy in multi_llm_review.yml.',
                  default: 'delegate'
                },
                parallel: {
                  type: 'boolean',
                  description: 'v0.3.0: when strategy=delegate, run subprocess reviewers ' \
                    'in a DETACHED WORKER process so orchestrator persona reviewers can ' \
                    'run in parallel (wall-clock ~30% faster). Default true (from config). ' \
                    'Set false for v0.2.x synchronous behavior.'
                }
              },
              required: %w[artifact_content artifact_name review_type]
            }
          end

          def call(arguments)
            config = load_review_config

            # INV-E1: the canonical set is not replaceable from the caller
            # side. The argument that used to allow it is gone; a call that
            # still carries it is refused rather than silently ignored, so a
            # stale runbook fails loudly instead of reviewing against a roster
            # nobody can see.
            if arguments['reviewers_override']
              return text_content(JSON.generate({
                'status' => 'error',
                'error' => 'reviewers_override was removed: the reviewer roster is ' \
                           'canonical in config and cannot be replaced per call. ' \
                           'To add observers for a hard artifact, set escalate: true ' \
                           '(config key: escalation_reviewers).'
              }))
            end

            begin
              reviewers = resolve_reviewers(arguments, config)
            rescue ObserverSet::RosterError => e
              return text_content(JSON.generate({
                'status' => 'error', 'error' => e.message
              }))
            end
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
            # Default strategy resolves from (1) explicit arg, (2) config, (3) 'delegate'.
            # Rationale: same-model persona review still surfaces findings subprocess
            # reviewers miss — LLM metacognition is structurally limited, so self-review
            # is net-positive. Flip from v0.3.x 'exclude' default after empirical
            # validation across Phase 11.5 / Phase 12 design reviews.
            strategy = arguments['orchestrator_strategy'] ||
                       config['default_orchestrator_strategy'] ||
                       'delegate'

            # INV-P2 is implemented in ObserverSet. `orchestrator_strategy`
            # survives as the way the caller expresses the two choices the
            # invariant leaves to it: whether its own slot should run anyway
            # in a fresh context ("subprocess"), and whether its declaration
            # should stand in the persona position at all ("exclude" suppresses
            # that fallback, so no persona is convened and the run is single
            # phase).
            persona_model = arguments['persona_model']
            escalate = arguments['escalate'] ? true : false

            # The two legacy strategies keep their published meanings.
            # "subprocess" buys a fresh context on the caller's own model: the
            # slot runs, and no persona is convened unless one was declared
            # outright. "exclude" drops the slot and convenes nothing. Only the
            # default lets the caller's declaration stand in the persona
            # position, which is the INV-P2 fallback.
            separate_context = (strategy == 'subprocess')
            # Declared-ness is emptiness, not truthiness: "" is truthy in Ruby,
            # so a caller passing an empty persona_model under a single-phase
            # strategy convened a persona anyway and got delegation_pending
            # where both legacy strategies promise a verdict. ObserverSet reads
            # the same declaration through present/1, and the two must agree
            # about what counts as declared.
            convene_persona = if persona_model.to_s.strip.empty?
                                strategy != 'exclude' && strategy != 'subprocess'
                              else
                                true
                              end

            # The key predates this change and gated the "exclude" strategy
            # only — the delegate path never consulted it. Widening its reach
            # now would move the denominator under a config nobody edited, so
            # it keeps exactly the scope it had.
            if strategy == 'exclude' && !config.fetch('exclude_orchestrator_model', true)
              separate_context = true
            end

            begin
              observers = ObserverSet.build(
                roster: reviewers,
                escalation: config['escalation_reviewers'],
                escalate: escalate,
                persona_model: persona_model,
                orchestrator_model: orchestrator_model,
                separate_context: separate_context,
                convene_persona: convene_persona
              )
            rescue ObserverSet::RosterError => e
              return text_content(JSON.generate({
                'status' => 'error', 'error' => e.message
              }))
            end

            reviewers = observers.dispatch
            persona_convened = observers.persona[:convened]
            # The post-exclusion rule is part of the "exclude" contract and is
            # still honoured. Removing it would have moved a shipped gate
            # without any caller asking for it.
            #
            # It asks whether the denominator actually shrank, not which
            # reason fired. Asking the reason lowered the bar in a run that
            # lost nothing: under "exclude" with a persona declared on a model
            # no slot names, the caller's slot leaves and an independent
            # persona answers in the set, so the observer count is unchanged
            # and the eased rule applied to a full roster.
            convergence_rule = if arguments['convergence_rule_override']
                                 base_rule
                               elsif strategy == 'exclude' && observers.observers_lost.positive?
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

            # PR3 DRY: dispatch path uses BuildReviewBundle.build_canonical_prompts
            # (shared with multi_llm_review_bundle tool). Same sanitization, same
            # framing, same prompt wording for both paths. Contract: identical
            # input → identical bundle (verified by test_build_review_bundle).
            prior_findings = symbolize_findings(arguments['prior_findings'])
            canonical = BuildReviewBundle.build_canonical_prompts(
              artifact_content: arguments['artifact_content'],
              artifact_name: arguments['artifact_name'],
              review_type: arguments['review_type'],
              review_context: review_context,
              review_round: review_round,
              prior_findings: prior_findings
            )
            system_prompt = canonical[:system_prompt]
            messages = canonical[:messages]

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

            # v0.3.0 parallel async path: spawn detached worker, return token
            # immediately so orchestrator can run persona Agents concurrently.
            parallel_cfg = config.dig('delegation', 'parallel') || {}
            parallel_default = parallel_cfg.fetch('default', true)
            parallel_flag = arguments.key?('parallel') ? arguments['parallel'] : parallel_default
            if persona_convened && parallel_flag
              return delegate_response_async(
                reviewers: reviewers, messages: messages, system_prompt: system_prompt,
                arguments: arguments, config: config,
                orchestrator_model: orchestrator_model, observers: observers,
                convergence_rule: convergence_rule, min_quorum: min_quorum,
                review_round: review_round, complexity: complexity,
                review_context: review_context,
                max_concurrent: max_concurrent, timeout_secs: timeout_secs,
                parallel_cfg: parallel_cfg
              )
            end

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
            if persona_convened
              return delegate_response(
                raw_results: raw_results,
                arguments: arguments,
                config: config,
                orchestrator_model: orchestrator_model,
                observers: observers,
                convergence_rule: convergence_rule,
                min_quorum: min_quorum,
                review_round: review_round,
                complexity: complexity
              )
            end

            # Compute consensus
            consensus = Consensus.aggregate(
              raw_results, convergence_rule,
              min_quorum: min_quorum,
              excluded_slots: observers.excluded,
              escalation: escalation_record(observers)
            )

            findings_string_keys = consensus[:aggregated_findings].map { |f| hash_to_string_keys(f) }
            sanitized_findings = findings_string_keys.map do |f|
              f.merge('issue' => Sanitizer.sanitize_finding_text(f['issue']))
            end
            feedback_text =
              case consensus[:verdict]
              when 'APPROVE' then nil
              when 'INSUFFICIENT'
                FeedbackFormatter.build_insufficient(consensus[:convergence][:reason] || 'quorum not met')
              else
                FeedbackFormatter.build(sanitized_findings)
              end

            payload = {
              'status' => 'ok',
              'verdict_schema_version' => BuildReviewBundle::VERDICT_SCHEMA_VERSION,
              'feedback_text_schema_version' => FeedbackFormatter::SCHEMA_VERSION,
              'verdict' => consensus[:verdict],
              'feedback_text' => feedback_text,
              'convergence' => hash_to_string_keys(consensus[:convergence]),
              'reviews' => consensus[:reviews].map { |r| ReviewSerializer.payload_row(r) },
              'aggregated_findings' => sanitized_findings,
              'review_round' => review_round,
              'review_type' => arguments['review_type'],
              'artifact_name' => arguments['artifact_name'],
              'complexity' => complexity,
              'llm_calls' => raw_results.count { |r| r[:status] == :success },
              'orchestrator_model' => orchestrator_model,
              'orchestrator_strategy' => strategy,
              'excluded_reviewers' => observers.excluded.size
            }

            # Phase 1.5 — Acknowledgment invariant: articulate which fallback path
            # was actually taken during this invocation. Subprocess reviewers may
            # be present but the persona unanimity gate path is harness_specific
            # (Claude Code Agent tool). When strategy='delegate', the orchestrator
            # delegates to its own harness for personas — that is the harness_specific
            # path. When subprocess-only ran, the path is harness_assisted.
            payload['harness_assistance_used'] = build_acknowledgment(persona_convened, raw_results)

            text_content(JSON.generate(payload))
          rescue StandardError => e
            text_content(JSON.generate({
              'status' => 'error',
              'error' => "#{e.class}: #{e.message}"
            }))
          end

          private

          # Phase 1.5 — articulate which fallback_chain path actually ran.
          # Returns Hash with path_taken/tier_actually_used/target_harness/acknowledgment.
          # Keyed on whether a persona was actually convened, not on the
          # strategy name: a run can name the default strategy and still
          # convene nothing (no declarations at all), and claiming the gate ran
          # in that case is a declaration the record cannot support.
          def build_acknowledgment(persona_convened, raw_results)
            successful_subprocess = raw_results.count { |r| r[:status] == :success }
            if persona_convened
              {
                'path_taken' => 'claude_code_agent_personas',
                'tier_actually_used' => 'harness_specific',
                'target_harness' => 'claude_code',
                'subprocess_reviewers_succeeded' => successful_subprocess,
                'acknowledgment' => 'orchestrator delegated persona reviews to its own harness (Claude Code Agent tool); subprocess CLIs ran in parallel as advisory. Anthropic unanimity gate path is harness-coupled.'
              }
            elsif successful_subprocess > 0
              {
                'path_taken' => 'subprocess_only',
                'tier_actually_used' => 'harness_assisted',
                'subprocess_reviewers_succeeded' => successful_subprocess,
                'acknowledgment' => 'subprocess CLI reviewers ran (advisory); persona unanimity gate path was NOT exercised this invocation.'
              }
            else
              {
                'path_taken' => 'manual_suggestion',
                'tier_actually_used' => 'core',
                'acknowledgment' => 'no harness path succeeded; KairosChain returns review with reduced reviewer set or guidance for manual review.'
              }
            end
          end

          def config_path
            File.expand_path(File.join(__dir__, '..', 'config', 'multi_llm_review.yml'))
          end

          # A missing file yields an empty config rather than a substitute one.
          # What that costs is decided one caller down, where the roster is
          # resolved and the absence can be reported with the file to look at.
          def load_review_config
            return {} unless File.exist?(config_path)

            YAML.safe_load(File.read(config_path), permitted_classes: [Symbol]) || {}
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

          # A token whose directory this call owns. UUID collision retry
          # (EEXIST on Dir.mkdir per PendingState§token_dir); both delegation
          # paths need it, and the one that open-coded it is the one that
          # ended up not creating the directory at all.
          def create_token_dir!
            10.times do
              token = PendingState.generate_token
              begin
                PendingState.create_token_dir!(token)
                return token
              rescue Errno::EEXIST
                next
              end
            end
            raise 'could not generate unique token dir after 10 attempts'
          end

          # The directory exists before the state is written, so a failed write
          # leaves a token whose directory is there and whose state is not.
          # load_state then returns nil and collect answers
          # `expired_or_unknown_token` — telling the caller its token ran out
          # when in fact this call never finished creating it. Removing the
          # directory makes the failure be the failure it was.
          # `ensure` rather than `rescue StandardError`: an Interrupt during a
          # long delegation is the realistic way this fails, and it is not a
          # StandardError. The cleanup's own failure is swallowed so it cannot
          # replace the exception that caused it — losing the real error to a
          # read-only filesystem would be the second-worst outcome after
          # losing the token.
          def with_token_dir
            token = create_token_dir!
            done = false
            begin
              yield token
              done = true
            ensure
              unless done
                begin
                  FileUtils.rm_rf(PendingState.token_dir(token))
                rescue StandardError => e
                  warn "[multi_llm_review] token dir cleanup failed: #{e.class}: #{e.message}"
                end
              end
            end
            token
          end

          # INV-E4: whether this run was escalated, and by whom, belongs in the
          # record even when the answer is "it was not". "slots" is what the
          # container offered; "dispatched" is what it actually added, and the
          # two differ whenever a reserve slot was taken over by the persona or
          # dropped as the caller's own. Recording only the offer let a reader
          # count an observer that never answered.
          def escalation_record(observers)
            {
              # "requested" is what the caller asked for, "escalated" whether
              # the container had anything to give, "slots" what it offered and
              # "dispatched" what actually ran. Collapsing these lost the case
              # that matters most: a caller escalating against an empty or
              # misspelt container recorded identically to one that never asked.
              'requested' => observers.escalation_requested,
              'escalated' => observers.escalated,
              'slots' => observers.escalation_labels,
              'dispatched' => observers.escalation_dispatched
            }
          end

          # Roster partitioning moved to ObserverSet (INV-P2). The two helpers
          # that used to live here decided the same slot from two places, which
          # is how the caller-equals-persona case became ambiguous; the set is
          # now built in one pass with explicit precedence.

          # Build the delegation manifest response. Persists subprocess results
          # to pending state under a UUID v4 token; orchestrator then submits
          # its persona team review via multi_llm_review_collect.
          def delegate_response(raw_results:, arguments:, config:, orchestrator_model:,
                                observers:, convergence_rule:, min_quorum:,
                                review_round:, complexity:)
            # Validate the model that will actually stand in the persona
            # position — which is the persona declaration when there is one,
            # and the caller's own declaration otherwise. Validating the caller
            # unconditionally made the documented "declare only persona_model"
            # case fail on a nil that INV-P2 permits.
            begin
              PersonaAssembly.validate_orchestrator_model!(observers.persona[:model])
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

            deadline_secs = arguments['collect_deadline_seconds_override'] ||
                            config.dig('delegation', 'collect_deadline_seconds') || 1800
            now = Time.now
            # Written in the same layout as the parallel path. It used to be
            # written as a single legacy file, and collect takes its lock on a
            # file inside the token directory — so for every synchronous
            # delegation the lock was silently skipped and two collects on one
            # token could both run consensus and both write the cache. The
            # storage layout is not what decides whether a run is serialised.
            token = with_token_dir do |t|
            PendingState.write_state(t, {
              'token' => t,
              'created_at' => now.iso8601,
              'collect_deadline' => (now + deadline_secs).iso8601,
              'review_type' => arguments['review_type'],
              'artifact_name' => arguments['artifact_name'],
              'review_round' => review_round,
              'complexity' => complexity,
              'orchestrator_model' => orchestrator_model,
              # INV-P1 / INV-E4: the persona model is a declaration, and the
              # slots that never ran are part of how the denominator came out.
              # Both have to survive into collect, which is where the record is
              # finally written.
              # The strategy that actually ran, so collect does not report a
              # constant. `strategy` itself is call-local, so it is re-derived
              # from the same two sources the call body used.
              'orchestrator_strategy' => arguments['orchestrator_strategy'] ||
                                         config['default_orchestrator_strategy'] || 'delegate',
              'persona_model' => observers.persona[:model],
              'persona_independent' => observers.persona[:independent],
              'excluded_slots' => observers.excluded.map { |e| hash_to_string_keys(e) },
              'escalation' => escalation_record(observers),
              'convergence_rule' => convergence_rule,
              'min_quorum' => min_quorum,
              # Stated rather than left to collect's legacy default, now that
              # this path looks like the parallel one from the outside.
              'parallel' => false,
              'subprocess_results' => raw_results.map { |r| serialize_review(r) },
              'collected' => false
            })

              # Phase 2 flocks this file; it exists here for the same reason it
              # exists on the parallel path. Inside the block, so that a token
              # directory without its lock is not left behind either.
              FileUtils.touch(PendingState.collect_lock_path(t))
            end

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

          # v0.3.0 parallel delegation path (Phase 11.5).
          # Writes request.json + state.json (with self_timeout_at) + spawns
          # a detached worker that runs dispatcher.dispatch in parallel with
          # the orchestrator's persona Agent reviews. Returns a delegation
          # manifest immediately (~50ms).
          def delegate_response_async(reviewers:, messages:, system_prompt:,
                                      arguments:, config:, orchestrator_model:, observers:,
                                      convergence_rule:, min_quorum:, review_round:,
                                      complexity:, review_context:,
                                      max_concurrent:, timeout_secs:, parallel_cfg:)
            begin
              PersonaAssembly.validate_orchestrator_model!(observers.persona[:model])
            rescue ArgumentError => e
              return text_content(JSON.generate({ 'status' => 'error', 'error' => e.message }))
            end

            if reviewers.empty?
              return text_content(JSON.generate({
                'status' => 'error',
                'error' => 'delegate+parallel requires at least one non-orchestrator reviewer; roster is empty after exclusion'
              }))
            end

            deadline_secs = arguments['collect_deadline_seconds_override'] ||
                            config.dig('delegation', 'collect_deadline_seconds') || 1800
            multiplier = parallel_cfg['worker_self_timeout_multiplier'] || 1.5
            floor      = parallel_cfg['worker_self_timeout_floor_seconds'] || 60
            poll_interval = parallel_cfg['poll_interval_seconds'] || 0.5
            now = Time.now
            worker_lifespan_secs = (timeout_secs * multiplier + floor).to_f
            self_timeout_at = (now + worker_lifespan_secs).iso8601

            # Auto-extend collect_deadline to cover the worker's self_timeout plus
            # a polling margin. Without this, raising timeout_seconds_override alone
            # leaves the orchestrator's submission window shorter than the worker
            # lifespan — the collect token expires while the worker is still healthy.
            # Only kicks in for the async path; sync delegate_response has no worker.
            min_deadline_secs = (worker_lifespan_secs + (poll_interval * 20)).ceil
            deadline_secs = [deadline_secs.to_i, min_deadline_secs].max

            # Same rollback as the synchronous path. Round 8 found this one
            # still bare: the helper existed, the synchronous caller used it,
            # and the default delegation shape — this one, which writes three
            # files and spawns a process — did not. A fix applied to one of two
            # callers is the shape that keeps recurring here.
            token = with_token_dir do |t|
            PendingState.write_request(t, {
              'token' => t,
              'reviewers' => reviewers.map { |r| r.transform_keys(&:to_s) },
              'system_prompt' => system_prompt,
              'messages' => messages,
              'review_context' => review_context,
              'timeout_seconds' => timeout_secs,
              'max_concurrent' => max_concurrent,
              'spawned_at' => now.iso8601
            })

            PendingState.write_state(t, {
              'schema_version' => 4,
              'token' => t,
              'created_at' => now.iso8601,
              'collect_deadline' => (now + deadline_secs).iso8601,
              'review_type' => arguments['review_type'],
              'artifact_name' => arguments['artifact_name'],
              'review_round' => review_round,
              'complexity' => complexity,
              'orchestrator_model' => orchestrator_model,
              # INV-P1 / INV-E4: the persona model is a declaration, and the
              # slots that never ran are part of how the denominator came out.
              # Both have to survive into collect, which is where the record is
              # finally written.
              # The strategy that actually ran, so collect does not report a
              # constant. `strategy` itself is call-local, so it is re-derived
              # from the same two sources the call body used.
              'orchestrator_strategy' => arguments['orchestrator_strategy'] ||
                                         config['default_orchestrator_strategy'] || 'delegate',
              'persona_model' => observers.persona[:model],
              'persona_independent' => observers.persona[:independent],
              'excluded_slots' => observers.excluded.map { |e| hash_to_string_keys(e) },
              'escalation' => escalation_record(observers),
              'convergence_rule' => convergence_rule,
              'min_quorum' => min_quorum,
              'parallel' => true,
              'subprocess_status' => 'pending',
              'crash_reason' => nil,
              'crashed_at' => nil,
              'self_timeout_at' => self_timeout_at
            })

            # Ensure collect.lock exists for Phase 2's flock.
            FileUtils.touch(PendingState.collect_lock_path(t))
            end

            begin
              WorkerSpawner.spawn(token: token, dir: PendingState.token_dir(token))
            rescue StandardError => e
              return text_content(JSON.generate({
                'status' => 'error',
                'error_class' => 'internal',
                'error' => "worker spawn failed: #{e.class}: #{e.message}"
              }))
            end

            text_content(JSON.generate({
              'status' => 'delegation_pending',
              'collect_token' => token,
              'parallel' => true,
              'delegation' => {
                'instruction' => 'Run persona-based review using your Agent tool. ' \
                  "Choose #{PersonaAssembly::MIN_PERSONAS}-#{PersonaAssembly::MAX_PERSONAS} " \
                  'personas appropriate to the artifact and review_type. ' \
                  'Then call multi_llm_review_wait, then multi_llm_review_collect.',
                'review_type' => arguments['review_type'],
                'persona_count_min' => PersonaAssembly::MIN_PERSONAS,
                'persona_count_max' => PersonaAssembly::MAX_PERSONAS
              },
              'subprocess_status' => 'pending',
              'subprocess_total' => reviewers.size,
              'must_collect_by' => (now + deadline_secs).iso8601,
              'orchestrator_model' => orchestrator_model,
              # next_action hint (R1, R8): MCP does not enforce ordering, but
              # the LLM is highly likely to follow this hint. Calling wait is
              # optional — collect alone still works via its internal polling —
              # but wait surfaces structural completion deterministically.
              'next_action' => {
                'tool' => 'multi_llm_review_wait',
                'args' => { 'collect_token' => token, 'max_wait_seconds' => 600 },
                'purpose' => 'Phase 1.5: block until subprocess reviewers complete. Call ' \
                  'AFTER spawning persona Agent reviews, BEFORE multi_llm_review_collect. ' \
                  'Optional but strongly recommended for deterministic recovery hints.'
              }
            }))
          end

          # Convert a Dispatcher review hash to JSON-safe form for pending state.
          def serialize_review(r)
            ReviewSerializer.serialize(r)
          end

          # INV-E1: config is the only source. There is deliberately no
          # argument that can substitute for it, and no built-in roster to fall
          # back to either — a fallback roster is a second canonical set, and
          # the one that used to live here named three slots with no model,
          # which INV-E5 forbids. It could therefore only ever produce a refusal
          # naming reviewers the operator had never configured. A missing or
          # empty roster is a deployment fault and says so, with the file to
          # look at.
          def resolve_reviewers(_arguments, config)
            entries = config['reviewers']
            if !entries.is_a?(Array) || entries.empty?
              raise ObserverSet::RosterError,
                    'no reviewer roster is configured; the canonical set lives in ' \
                    "#{config_path} under the key \"reviewers\", and this tool has " \
                    'no built-in roster to fall back to'
            end

            entries.map { |r| symbolize_keys(r) }
          end

          def symbolize_keys(hash)
            hash = coerce_to_hash(hash)
            hash.transform_keys(&:to_sym)
          end

          def symbolize_findings(findings)
            return nil unless findings.is_a?(Array)
            findings.map { |f| coerce_to_hash(f).transform_keys(&:to_sym) }
          end

          def hash_to_string_keys(hash)
            return hash unless hash.is_a?(Hash)
            hash.transform_keys(&:to_s)
          end

          def coerce_to_hash(obj)
            return obj if obj.is_a?(Hash)
            return JSON.parse(obj) if obj.is_a?(String)
            obj
          rescue JSON::ParserError
            { '_raw' => obj.to_s }
          end

        end
      end
    end
  end
end
