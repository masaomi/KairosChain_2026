# frozen_string_literal: true

require 'json'
require 'time'
require_relative '../lib/multi_llm_review/consensus'
require_relative '../lib/multi_llm_review/pending_state'
require_relative '../lib/multi_llm_review/persona_assembly'
require_relative '../lib/multi_llm_review/review_serializer'
require_relative '../lib/multi_llm_review/wait_for_worker'
require_relative '../lib/multi_llm_review/worker_reaper'
require_relative '../lib/multi_llm_review/feedback_formatter'
require_relative '../lib/multi_llm_review/sanitizer'
require_relative '../lib/multi_llm_review/build_review_bundle'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      module Tools
        # Phase 2 of the orchestrator delegation protocol.
        #
        # Receives the orchestrator's persona team review (assembled in the
        # caller's own context via Agent tool), merges it with the subprocess
        # reviewer results persisted by Phase 1, and runs Consensus to produce
        # the final verdict.
        #
        # Idempotency: a second collect with the same token returns the cached
        # final result rather than re-running consensus.
        class MultiLlmReviewCollect < KairosMcp::Tools::BaseTool
          def name
            'multi_llm_review_collect'
          end

          def description
            'Submit orchestrator-side persona team review to complete a delegated ' \
              'multi_llm_review. Use this only after multi_llm_review returned ' \
              'status="delegation_pending" with a collect_token. Provide the persona ' \
              "reviews (recommended #{PersonaAssembly::RECOMMENDED_MIN_PERSONAS}-" \
              "#{PersonaAssembly::MAX_PERSONAS}; each: persona, verdict, findings, " \
              'reasoning). A submission smaller than what was convened — including ' \
              'empty — is accepted; the shortfall moves the seat out of the ' \
              'denominator with its cause on the record.'
          end

          def category
            :review
          end

          def usecase_tags
            %w[review multi-llm consensus delegation]
          end

          def related_tools
            %w[multi_llm_review]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                collect_token: {
                  type: 'string',
                  description: 'UUID v4 token returned by multi_llm_review when ' \
                    'orchestrator_strategy="delegate" was used.'
                },
                orchestrator_reviews: {
                  type: 'array',
                  description: "Persona team review results (#{PersonaAssembly::MIN_PERSONAS}-" \
                    "#{PersonaAssembly::MAX_PERSONAS} entries). Each: " \
                    '{persona: string, verdict: APPROVE|REVISE|REJECT, ' \
                    'findings: [{severity, issue}, ...], reasoning: string}',
                  items: {
                    type: 'object',
                    properties: {
                      persona: { type: 'string' },
                      verdict: { type: 'string', enum: %w[APPROVE REVISE REJECT] },
                      reasoning: { type: 'string' },
                      findings: {
                        type: 'array',
                        items: { type: 'object' }
                      }
                    },
                    required: %w[persona verdict]
                  },
                  minItems: PersonaAssembly::MIN_PERSONAS,
                  maxItems: PersonaAssembly::MAX_PERSONAS
                },
                # Read by call_locked since the parallel path existed, and
                # unreachable that whole time: a caller sends what the schema
                # declares, so an argument absent from it is an argument nobody
                # can pass. Declared here rather than deleted because the case
                # it exists for is real — a slow roster outruns the configured
                # wait and the whole round is lost to a timeout the caller
                # could see coming.
                collect_max_wait_seconds: {
                  type: 'integer',
                  description: 'Override how long this call waits for the ' \
                    'subprocess worker to finish before reporting a timeout ' \
                    '(default from config: delegation.parallel.' \
                    'collect_max_wait_seconds). Only used on the parallel path.'
                }
              },
              required: %w[collect_token orchestrator_reviews]
            }
          end

          def call(arguments)
            token = arguments['collect_token']
            unless PendingState.valid_token?(token)
              return text_content(JSON.generate({
                'status' => 'error',
                'error' => 'invalid collect_token format (expected UUID v4)'
              }))
            end

            begin
              PendingState.cleanup_expired!(skip_token: token)
            rescue StandardError => e
              warn "[multi_llm_review_collect] cleanup_expired failed: #{e.class}: #{e.message}"
            end

            # v0.3.0 parallel path: flock the token dir's collect.lock so two
            # concurrent collects serialize (F-IDP). Missing token falls
            # through flock (no lock file) to idempotent replay / missing branch.
            lock_path = PendingState.collect_lock_path(token) rescue nil
            if lock_path && File.exist?(File.dirname(lock_path))
              File.open(lock_path, File::RDWR | File::CREAT) do |lock|
                lock.flock(File::LOCK_EX)
                return call_locked(token, arguments)
              end
            else
              # Legacy v0.2.x single-file or missing token: no lock, proceed.
              return call_locked(token, arguments)
            end
          rescue ArgumentError, KeyError, TypeError => e
            text_content(JSON.generate({
              'status' => 'error',
              'error_class' => 'validation',
              'error' => "#{e.class}: #{e.message}"
            }))
          rescue StandardError => e
            warn "[multi_llm_review_collect] INTERNAL ERROR: #{e.class}: #{e.message}"
            warn e.backtrace.first(10).join("\n") if e.backtrace
            text_content(JSON.generate({
              'status' => 'error',
              'error_class' => 'internal',
              'error' => "#{e.class}: #{e.message}"
            }))
          end

          def call_locked(token, arguments)
            # Idempotent replay via collected.json (v0.3) — check FIRST inside
            # the flock so a concurrent second caller sees the committed cache.
            collected_path = PendingState.collected_path(token) rescue nil
            if collected_path && File.exist?(collected_path)
              cached = PendingState.load_collected(token)
              if cached && cached['final_payload']
                payload = cached['final_payload'].dup
                payload['idempotent_replay'] = true
                return text_content(JSON.generate(payload))
              end
            end

            # A run already reduced to its trace, or abandoned with a terminal
            # note, is not collectible — and saying "expired_or_unknown" about
            # it would repeat the false-cause shape INV-R4 forbids. The note
            # says what actually happened; this answer relays it.
            reaped_path = PendingState.reaped_path(token) rescue nil
            if reaped_path && File.exist?(reaped_path)
              reaped = begin
                JSON.parse(File.read(reaped_path))
              rescue StandardError
                {}
              end
              return text_content(JSON.generate({
                'status' => 'terminated_run',
                'collect_token' => token,
                'reason' => reaped['reason'],
                'reaped_at' => reaped['reaped_at']
              }.compact))
            end

            state = PendingState.load_state(token)
            if state.nil?
              # Distinguish corrupt legacy single-file from simply-missing so
              # v0.2.3 tests pass (test_corrupt_state_returns_internal_error).
              legacy_path = File.join(PendingState.root_dir, "#{token}.json")
              if File.exist?(legacy_path)
                return text_content(JSON.generate({
                  'status' => 'error',
                  'error_class' => 'internal',
                  'error' => 'pending state file is corrupt',
                  'collect_token' => token
                }))
              end
              return text_content(JSON.generate({
                'status' => 'expired_or_unknown_token',
                'collect_token' => token
              }))
            end

            # v0.2.x legacy idempotent replay (inline cache in state).
            if state['collected'] && state['final_payload']
              cached = state['final_payload'].dup
              cached['idempotent_replay'] = true
              return text_content(JSON.generate(cached))
            end

            # Deadline check
            deadline = (Time.iso8601(state['collect_deadline']) rescue nil)
            if deadline && Time.now > deadline
              return text_content(JSON.generate({
                'status' => 'expired_or_unknown_token',
                'collect_token' => token,
                'reason' => 'past collect_deadline'
              }))
            end

            reviews = arguments['orchestrator_reviews']
            begin
              # INV-P1: the persona entry is labelled with the model the caller
              # declared it would run on, which may differ from the caller
              # itself. Older tokens carry no such declaration, so the caller
              # model stands in — the same fallback INV-P2 states.
              orchestrator_entry = PersonaAssembly.assemble(
                reviews, state['persona_model'] || state['orchestrator_model']
              )
            rescue ArgumentError => e
              # INV-R1/R4: the refusal is an event on the accepting side, and
              # it is recorded by the system — facts and cause, never the
              # refused body. Under the v0.3 directory layout this runs inside
              # collect.lock's flock; a v0.2.x legacy single-file token has no
              # directory to lock on its first refusal, so that append runs
              # unlocked (atomic write, lost-update window only — declared
              # residual). The token survives the refusal; the corrected
              # submission collects, reads the sidecar, and the refusal
              # appears in the run's final record.
              begin
                PendingState.append_refusal(token, {
                  'refused_at' => Time.now.iso8601,
                  'stage' => 'persona_validation',
                  'reason' => e.message.to_s[0, 200],
                  'submission_count' => (reviews.respond_to?(:size) ? reviews.size : nil)
                }.compact)
              rescue StandardError => sidecar_err
                warn "[multi_llm_review_collect] refusal sidecar write failed: " \
                     "#{sidecar_err.class}: #{sidecar_err.message}"
              end
              return text_content(JSON.generate({
                'status' => 'error',
                'error' => "invalid orchestrator_reviews: #{e.message}"
              }))
            end

            # Resolve subprocess_results: v0.3 parallel → WaitForWorker;
            # v0.2.x legacy (or parallel=false) → inline state['subprocess_results'].
            parallel = state['parallel']
            parallel = false if parallel.nil?      # legacy default (R1-K)

            subprocess_entries = nil
            if parallel == false
              subprocess_entries = (state['subprocess_results'] || []).map do |r|
                deserialize_review(r)
              end
            else
              outcome = WaitForWorker.wait(token, {
                max_wait_seconds: arguments['collect_max_wait_seconds'] ||
                                  config_parallel_key('collect_max_wait_seconds', 420),
                poll_interval_seconds: config_parallel_key('poll_interval_seconds', 0.5),
                startup_grace_seconds: config_parallel_key('startup_grace_seconds', 30),
                heartbeat_stale_threshold_seconds: config_parallel_key('heartbeat_stale_threshold_seconds', 15)
              })
              case outcome[:status]
              when :ready
                subprocess_entries = outcome[:results].map { |r| deserialize_review(r) }
              when :crashed
                return text_content(JSON.generate({
                  'status' => 'subprocess_worker_crashed',
                  'collect_token' => token,
                  'reason' => outcome[:reason],
                  'pid' => outcome[:pid],
                  'heartbeat_age' => outcome[:heartbeat_age],
                  'log_tail' => outcome[:log_tail].to_s
                }))
              when :timeout
                reaper_outcome = WorkerReaper.terminate!(token, outcome[:pid], outcome[:pgid])
                if %i[terminated killed already_dead].include?(reaper_outcome)
                  begin
                    File.open(PendingState.gc_eligible_path(token),
                              File::CREAT | File::EXCL | File::WRONLY) { }
                  rescue Errno::EEXIST
                    # Idempotent: prior collect already created the marker.
                  rescue StandardError => e
                    warn "[multi_llm_review_collect] gc.eligible write: #{e.class}: #{e.message}"
                  end
                end
                return text_content(JSON.generate({
                  'status' => 'worker_timeout',
                  'collect_token' => token,
                  'waited_seconds' => outcome[:waited_seconds],
                  'pid' => outcome[:pid],
                  'reaper_outcome' => reaper_outcome.to_s,
                  'log_tail' => outcome[:log_tail].to_s
                }))
              end
            end

            all_reviews = subprocess_entries + [orchestrator_entry]

            consensus = Consensus.aggregate(
              all_reviews,
              state['convergence_rule'] || '3/4 APPROVE',
              # INV-E2 reaches every observer, the persona included: a persona
              # submission that carries verdicts and nothing else leaves the
              # denominator exactly as a subprocess reply would. The rule takes
              # no parameter, so there is nothing here for a stale pending state
              # to carry a different answer for.
              min_quorum: state['min_quorum'] || 2,
              excluded_slots: symbolize_excluded(state['excluded_slots']),
              escalation: state['escalation']
            )

            # llm_calls counts actual LLM invocations (subprocess reviewers).
            # The synthetic orchestrator team entry is not a distinct LLM call
            # — the orchestrator ran N persona sub-agents that are attributed
            # separately by persona_count.
            actual_llm_calls = subprocess_entries.count { |r| r[:status] == :success }

            findings_string_keys = consensus[:aggregated_findings].map { |f| hash_to_string_keys(f) }
            sanitized_findings = findings_string_keys.map do |f|
              f.merge('issue' => Sanitizer.sanitize_finding_text(f['issue']))
            end
            feedback_text =
              case consensus[:reference_verdict]
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
              # INV-R2: a reference value, not the run's conclusion. The run is
              # closed by the operator's declaration, outside this record.
              'reference_verdict' => consensus[:reference_verdict],
              'feedback_text' => feedback_text,
              'convergence' => hash_to_string_keys(consensus[:convergence]),
              'reviews' => consensus[:reviews].map { |r| ReviewSerializer.payload_row(r) },
              'aggregated_findings' => sanitized_findings,
              'review_round' => state['review_round'],
              'review_type' => state['review_type'],
              'artifact_name' => state['artifact_name'],
              'complexity' => state['complexity'],
              'llm_calls' => actual_llm_calls,
              'persona_count' => reviews.size,
              'orchestrator_model' => state['orchestrator_model'],
              # The constant was a lie whenever a persona was convened under a
              # strategy other than the default — which an explicit persona
              # declaration makes possible.
              'orchestrator_strategy' => state['orchestrator_strategy'] || 'delegate',
              'persona_model' => state['persona_model'],
              'run_token' => token
            }
            # INV-R6: what the run intended to pass, when it was declared.
            payload['review_spec'] = state['review_spec'] if state['review_spec']
            # INV-R3/R4: the declared convened count beside the submitted one
            # (persona_count above), so a shortfall is readable as their
            # difference. Omitted when nothing was declared.
            if state['persona_count_declared']
              payload['persona_count_declared'] = state['persona_count_declared']
            end
            # INV-R1/R4: submissions refused at the acceptance gate before this
            # one, readable from the same run's record. Omitted when none.
            refusals = PendingState.load_refusals(token)
            payload['refused_submissions'] = refusals unless refusals.empty?

            # v0.3 path: cache via collected.json sidecar (never touches
            # state.json → preserves single-writer invariant §6.3).
            if parallel
              collected_ok = false
              begin
                PendingState.write_collected(token, {
                  'schema_version' => 1,
                  'token' => token,
                  'collected_at' => Time.now.iso8601,
                  'final_payload' => payload
                })
                collected_ok = true
              rescue StandardError => e
                warn "[multi_llm_review_collect] collected write failed: #{e.class}: #{e.message}"
              end

              # F-USR: replay usage ONLY after collected.json committed.
              # If write failed, skip replay — a retry will hit the non-replay
              # path and get a fresh chance; idempotent replay (collected.json
              # exists) short-circuits further usage calls. This prevents
              # double-counting on retries (PR4 R1-impl P1 from codex 5.5).
              if collected_ok
                subprocess_entries.each do |r|
                  next unless r[:usage]
                  begin
                    if defined?(KairosMcp::SkillSets::LlmClient::Tools::UsageTracker)
                      KairosMcp::SkillSets::LlmClient::Tools::UsageTracker.record(r[:usage])
                    end
                  rescue StandardError => e
                    warn "[multi_llm_review_collect] UsageTracker skipped: #{e.class}: #{e.message}"
                  end
                end
              end
            else
              # Non-parallel path: the cache lives inline in the state, and —
              # since v0.7 — in collected.json as well. The sidecar is what
              # pins the directory against cleanup by filename and what the
              # idempotent replay reads first; the inline copy is kept for
              # pre-v0.7 readers of state.json. Written before the state so a
              # crash between the two leaves the stronger record, and the
              # cleanup pin also reads the completion fact from state.json
              # itself, so neither copy alone is load-bearing.
              begin
                PendingState.write_collected(token, {
                  'schema_version' => 1,
                  'token' => token,
                  'collected_at' => Time.now.iso8601,
                  'final_payload' => payload
                })
              rescue StandardError => e
                warn "[multi_llm_review_collect] collected write failed: #{e.class}: #{e.message}"
              end

              state['collected'] = true
              state['collected_at'] = Time.now.iso8601
              state['final_payload'] = payload
              begin
                # Written back where it was read from. load_state prefers the
                # token directory and falls back to the legacy single file, so
                # writing the legacy file for a token that has a directory
                # hides the cache from the next call and the replay that
                # idempotency depends on never fires.
                if File.exist?(PendingState.state_path(token))
                  PendingState.write_state(token, state)
                else
                  PendingState.write(token, state)
                end
              rescue StandardError => e
                warn "[multi_llm_review_collect] cache write failed: #{e.class}: #{e.message}"
              end
            end

            text_content(JSON.generate(payload))
          end

          private

          def config_parallel_key(key, default)
            @cfg ||= begin
              p = File.expand_path('../config/multi_llm_review.yml', __dir__)
              require 'yaml'
              File.exist?(p) ? (YAML.safe_load(File.read(p)) || {}) : {}
            end
            (@cfg.dig('delegation', 'parallel', key) || default)
          end

          def deserialize_review(h)
            ReviewSerializer.deserialize(h)
          end

          # Pending state is JSON, so the slots that never ran come back with
          # string keys; Consensus reads them symbolised like everything else.
          def symbolize_excluded(entries)
            (entries || []).map do |e|
              e.is_a?(Hash) ? e.transform_keys(&:to_sym) : e
            end
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
