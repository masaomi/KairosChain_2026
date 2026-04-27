# frozen_string_literal: true

require 'json'
require 'time'
require 'yaml'
require_relative '../lib/multi_llm_review/pending_state'
require_relative '../lib/multi_llm_review/wait_for_worker'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      module Tools
        # Phase 1.5 of the orchestrator delegation protocol.
        #
        # Optional blocking gate that orchestrator can call AFTER spawning
        # persona Agent reviews and BEFORE multi_llm_review_collect. Server
        # polls the detached worker's state and returns when subprocess
        # reviewers complete (or earlier on terminal conditions).
        #
        # Without this tool, orchestrator can still call collect directly —
        # collect's own internal polling covers worker completion. wait is a
        # tool-chain checkpoint that surfaces structural status with explicit
        # next_action recovery hints, so the LLM can choose the right next
        # step deterministically.
        #
        # Status enum:
        #   ready                  — subprocess_results.json present, proceed to collect
        #   still_pending          — max_wait elapsed, worker healthy, may call wait again
        #   crashed                — worker terminal failure or internal error (with reason)
        #   unknown_token          — token dir missing (never existed or GC'd)
        #   already_collected      — collected.json present, retrieve cached payload
        #   past_collect_deadline  — token alive but past deadline; collect would reject
        #
        # Internal exceptions are mapped to `crashed` (reason: internal_error)
        # to keep the public response strictly inside the declared enum.
        class MultiLlmReviewWait < KairosMcp::Tools::BaseTool
          MAX_WAIT_HARD_CAP_DEFAULT       = 1800
          STILL_PENDING_STREAK_LIMIT_DEFAULT = 3
          DEFAULT_MAX_WAIT_SECONDS        = 600
          DEFAULT_POLL_INTERVAL_SECONDS   = 1.0

          def name
            'multi_llm_review_wait'
          end

          def description
            'Phase 1.5 — block until subprocess reviewers complete for a delegated ' \
              'multi_llm_review token. Optional but recommended: call after spawning ' \
              'persona Agent reviews and before multi_llm_review_collect. Returns ' \
              'a status enum with a next_action recovery hint for every status.'
          end

          def category
            :review
          end

          def usecase_tags
            %w[review multi-llm wait blocking polling]
          end

          def related_tools
            %w[multi_llm_review multi_llm_review_collect]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                collect_token: {
                  type: 'string',
                  description: 'UUID v4 token returned by multi_llm_review delegation_pending'
                },
                max_wait_seconds: {
                  type: 'integer',
                  description: 'Server-side blocking duration cap in seconds. ' \
                    'Default from config (delegation.parallel.wait_max_default_seconds = 600). ' \
                    'Hard cap from config (delegation.parallel.wait_max_hard_cap_seconds = 1800).'
                }
              },
              required: %w[collect_token]
            }
          end

          def call(arguments)
            token = (arguments.is_a?(Hash) ? arguments['collect_token'] : nil).to_s

            unless PendingState.valid_token?(token)
              return reply_unknown_token(token,
                'Token format invalid. Re-run multi_llm_review to start a new dispatch.')
            end

            cfg          = load_config_parallel
            default_max  = (cfg['wait_max_default_seconds'] || DEFAULT_MAX_WAIT_SECONDS).to_i
            hard_cap     = (cfg['wait_max_hard_cap_seconds'] || MAX_WAIT_HARD_CAP_DEFAULT).to_i
            poll_int     = (cfg['wait_poll_interval_seconds'] || DEFAULT_POLL_INTERVAL_SECONDS).to_f
            streak_limit = (cfg['wait_still_pending_streak_limit'] ||
                            STILL_PENDING_STREAK_LIMIT_DEFAULT).to_i

            requested_max = (arguments['max_wait_seconds'] || default_max).to_i
            requested_max = hard_cap if requested_max > hard_cap
            requested_max = 1 if requested_max < 1

            # 1. already_collected — check first so a successful collect always
            #    returns deterministically even after deadline expiry.
            collected_path = PendingState.collected_path(token)
            if File.exist?(collected_path)
              return reply('already_collected', token, 0.0,
                next_action: next_action_collect_replay(token,
                  'Collect already completed for this token. Call multi_llm_review_collect ' \
                  'to retrieve the cached final consensus (idempotent replay).'))
            end

            # 2. ready check BEFORE streak guard (Bug #6 from v3.24.0 review).
            #    If subprocess_results.json is already on disk, return ready
            #    regardless of streak — the worker finished, completion wins.
            results_path = PendingState.subprocess_results_path(token)
            if File.exist?(results_path)
              return reply_ready_from_results_file(token, results_path)
            end

            # 3. unknown_token — state.json missing.
            state = PendingState.load_state(token)
            if state.nil?
              return reply_unknown_token(token,
                'Token not found (never existed or already garbage-collected). ' \
                'Re-run multi_llm_review to start a new dispatch.')
            end

            # 4. Detect malformed collect_deadline (Bug #7) — return crashed
            #    with a clear reason rather than silently skipping the check.
            deadline = nil
            if state['collect_deadline']
              deadline = (Time.iso8601(state['collect_deadline']) rescue :malformed)
              if deadline == :malformed
                return reply('crashed', token, 0.0,
                  crashed_reason: 'malformed_state',
                  next_action: next_action_redispatch(
                    'state.json has malformed collect_deadline. The token is unrecoverable; ' \
                    're-run multi_llm_review.'))
              end
            end

            # 5. past_collect_deadline early exit — collect would reject anyway.
            if deadline && Time.now > deadline
              return reply('past_collect_deadline', token, 0.0,
                subprocess_total: subprocess_total_from(state, token),
                next_action: next_action_redispatch(
                  'Token deadline elapsed. multi_llm_review_collect would reject. ' \
                  'Re-run multi_llm_review.'))
            end

            # 6. Cap max_wait by remaining deadline. If <1s remaining, return
            #    past_collect_deadline directly (Bug from v3.24.0 review:
            #    previously clamped to 1 and entered WaitForWorker pointlessly).
            if deadline
              remaining_f = deadline - Time.now
              if remaining_f <= 0
                return reply('past_collect_deadline', token, 0.0,
                  subprocess_total: subprocess_total_from(state, token),
                  next_action: next_action_redispatch(
                    'Token deadline elapsed. Re-run multi_llm_review.'))
              end
              # Ceil rather than floor so the wait can actually run up to the
              # deadline. The post-wait revalidation in translate_outcome
              # catches any overshoot (Bug #4 defense-in-depth).
              remaining = remaining_f.ceil
              requested_max = remaining if remaining < requested_max
            end

            # 7. Streak guard — runs AFTER ready check (Bug #6 fix).
            current_streak = state['wait_still_pending_streak'].to_i
            if current_streak >= streak_limit
              return reply('crashed', token, 0.0,
                crashed_reason: 'wait_exhausted',
                still_pending_streak: current_streak,
                next_action: next_action_redispatch(
                  "still_pending streak reached limit (#{current_streak}/#{streak_limit}). " \
                  'Worker may be wedged or pathologically slow. Re-run multi_llm_review.'))
            end

            # 8. Delegate to existing WaitForWorker for the actual polling.
            outcome = WaitForWorker.wait(token, {
              max_wait_seconds: requested_max,
              poll_interval_seconds: poll_int,
              startup_grace_seconds: cfg['startup_grace_seconds'] || 30,
              heartbeat_stale_threshold_seconds: cfg['heartbeat_stale_threshold_seconds'] || 15
            })

            translate_outcome(token, outcome, requested_max, streak_limit, deadline)
          rescue StandardError => e
            warn "[multi_llm_review_wait] INTERNAL ERROR: #{e.class}: #{e.message}"
            warn e.backtrace.first(10).join("\n") if e.backtrace
            # Map internal errors to declared enum (Bug #5: previously returned
            # status: 'error' which was outside the documented 6 statuses).
            safe_token = (arguments.is_a?(Hash) ? arguments['collect_token'] : nil).to_s
            reply('crashed', safe_token, 0.0,
              crashed_reason: 'internal_error',
              next_action: next_action_redispatch(
                "Internal error (#{e.class}). Re-run multi_llm_review."))
          end

          private

          def translate_outcome(token, outcome, requested_max, streak_limit, deadline_at_entry)
            # WaitForWorker returns :elapsed for ready, :waited_seconds for
            # timeout. Use the first non-nil so still_pending and crashed
            # paths report real wait time, not 0.0.
            elapsed = (outcome[:elapsed] || outcome[:waited_seconds] || 0.0).to_f
            subprocess_total = subprocess_total_from(PendingState.load_state(token), token)

            case outcome[:status]
            when :ready
              reset_streak(token)
              done = (outcome[:results].is_a?(Array) ? outcome[:results].size : nil) ||
                     subprocess_total
              reply('ready', token, elapsed,
                subprocess_done: done,
                subprocess_total: subprocess_total,
                next_action: next_action_collect(token,
                  'Subprocess reviewers complete. Submit your persona Agent findings to ' \
                  'multi_llm_review_collect to compute the final consensus.'))
            when :crashed
              reset_streak(token)
              reply('crashed', token, elapsed,
                crashed_reason: outcome[:reason] || 'crashed',
                subprocess_total: subprocess_total,
                next_action: next_action_redispatch(
                  "Worker terminated abnormally (#{outcome[:reason] || 'crashed'}). " \
                  'Re-run multi_llm_review.'))
            when :timeout
              # Post-wait deadline revalidation (Bug #4 fix). The deadline
              # may have elapsed during the blocking wait; if so, return
              # past_collect_deadline rather than still_pending. Use >= so
              # the boundary case (Time.now == deadline) is treated as past.
              if deadline_at_entry && Time.now >= deadline_at_entry
                return reply('past_collect_deadline', token, elapsed,
                  subprocess_total: subprocess_total,
                  next_action: next_action_redispatch(
                    'Deadline elapsed during wait. Re-run multi_llm_review.'))
              end

              # Atomic increment via PendingState.update_state RMW (Bug #2).
              # The block reads the current persisted streak and writes
              # current+1 in one transaction, so concurrent waiters cannot
              # both read the same N and both write N+1.
              new_streak = nil
              PendingState.update_state(token) do |st|
                next nil unless st
                new_streak = st['wait_still_pending_streak'].to_i + 1
                st['wait_still_pending_streak'] = new_streak
                st
              end
              new_streak ||= 1

              reply('still_pending', token, elapsed,
                subprocess_total: subprocess_total,
                still_pending_streak: new_streak,
                next_action: next_action_wait(token,
                  "Worker still healthy after #{requested_max}s. Call multi_llm_review_wait " \
                  "again with the same token (streak #{new_streak}/#{streak_limit})."))
            else
              reply('crashed', token, elapsed,
                crashed_reason: "unknown_outcome:#{outcome[:status]}",
                subprocess_total: subprocess_total,
                next_action: next_action_redispatch(
                  'Worker reported an unexpected outcome. Re-run multi_llm_review.'))
            end
          end

          def reply_ready_from_results_file(token, results_path)
            data = PendingState.load_subprocess_results(token)
            done = (data && data['results'].is_a?(Array)) ? data['results'].size : nil
            elapsed = (data && data['elapsed_seconds'].to_f) || 0.0
            reset_streak(token)
            reply('ready', token, elapsed,
              subprocess_done: done,
              subprocess_total: subprocess_total_from(PendingState.load_state(token), token) || done,
              next_action: next_action_collect(token,
                'Subprocess reviewers complete. Submit your persona Agent findings to ' \
                'multi_llm_review_collect to compute the final consensus.'))
          end

          def reply_unknown_token(token, purpose)
            reply('unknown_token', token, 0.0,
              next_action: next_action_redispatch(purpose))
          end

          def reply(status, token, elapsed, **fields)
            payload = {
              'status' => status,
              'collect_token' => token,
              'elapsed_seconds' => elapsed.to_f.round(3)
            }
            payload['subprocess_done']      = fields[:subprocess_done] if fields.key?(:subprocess_done)
            payload['subprocess_total']     = fields[:subprocess_total] if fields.key?(:subprocess_total)
            payload['crashed_reason']       = fields[:crashed_reason] if fields.key?(:crashed_reason)
            payload['still_pending_streak'] = fields[:still_pending_streak] if fields.key?(:still_pending_streak)
            payload['next_action']          = fields[:next_action] if fields.key?(:next_action)
            text_content(JSON.generate(payload))
          end

          def subprocess_total_from(state, token)
            return state['subprocess_total'] if state.is_a?(Hash) && state['subprocess_total']
            req = PendingState.load_request(token) rescue nil
            req&.dig('reviewers')&.size
          end

          def next_action_collect(token, purpose)
            {
              'tool' => 'multi_llm_review_collect',
              'args' => {
                'collect_token' => token,
                'orchestrator_reviews' => '<persona findings array, 2-4 entries>'
              },
              'purpose' => purpose
            }
          end

          def next_action_collect_replay(token, purpose)
            {
              'tool' => 'multi_llm_review_collect',
              'args' => { 'collect_token' => token },
              'purpose' => purpose
            }
          end

          def next_action_wait(token, purpose)
            {
              'tool' => 'multi_llm_review_wait',
              'args' => { 'collect_token' => token },
              'purpose' => purpose
            }
          end

          def next_action_redispatch(purpose)
            {
              'tool' => 'multi_llm_review',
              'args' => '<original arguments>',
              'purpose' => purpose
            }
          end

          # Atomic streak reset via update_state RMW. Errors are logged (not
          # silently swallowed — Bug #8) so genuine PendingState failures
          # surface in stderr.
          def reset_streak(token)
            PendingState.update_state(token) do |state|
              next nil unless state
              if state['wait_still_pending_streak'].to_i.positive?
                state['wait_still_pending_streak'] = 0
                state
              else
                nil
              end
            end
          rescue StandardError => e
            warn "[multi_llm_review_wait] reset_streak failed: #{e.class}: #{e.message}"
          end

          # Load the delegation.parallel config block. v3.24.0 had a dead-code
          # bug here (`unless ... || true` always true → always returned {}).
          # v3.24.1 removes the dead guard and explicitly requires 'yaml' at
          # the top of the file.
          def load_config_parallel
            path = File.expand_path('../config/multi_llm_review.yml', __dir__)
            return {} unless File.exist?(path)
            cfg = YAML.safe_load_file(path, permitted_classes: [Symbol], aliases: true)
            (cfg.dig('delegation', 'parallel') || {}).to_h
          rescue StandardError => e
            warn "[multi_llm_review_wait] config load failed: #{e.class}: #{e.message}"
            {}
          end
        end
      end
    end
  end
end
