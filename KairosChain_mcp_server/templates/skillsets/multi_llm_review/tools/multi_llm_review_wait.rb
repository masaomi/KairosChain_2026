# frozen_string_literal: true

require 'json'
require 'time'
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
        # tool-chain checkpoint that surfaces structural status (ready,
        # crashed, exhausted) with explicit next_action recovery hints, so
        # the LLM can choose the right next step deterministically.
        #
        # Status enum (R10):
        #   ready                  — subprocess_results.json present, proceed to collect
        #   still_pending          — max_wait elapsed, worker healthy, may call wait again
        #   crashed                — worker terminal failure (with reason)
        #   unknown_token          — token dir missing (never existed or GC'd)
        #   already_collected      — collected.json present, retrieve cached payload
        #   past_collect_deadline  — token alive but past deadline; collect would reject
        class MultiLlmReviewWait < KairosMcp::Tools::BaseTool
          # Per-call hard cap on max_wait_seconds (R7).
          MAX_WAIT_HARD_CAP_DEFAULT = 1800

          # Default streak limit before still_pending escalates to crashed (R7).
          STILL_PENDING_STREAK_LIMIT_DEFAULT = 3

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
                    'Default from config (delegation.parallel.wait_max_default_seconds). ' \
                    'Hard cap 1800 (delegation.parallel.wait_max_hard_cap_seconds).'
                }
              },
              required: %w[collect_token]
            }
          end

          def call(arguments)
            token = arguments['collect_token'].to_s
            unless PendingState.valid_token?(token)
              return text_content(JSON.generate({
                'status' => 'unknown_token',
                'collect_token' => token,
                'elapsed_seconds' => 0.0,
                'next_action' => next_action_redispatch(
                  'Token format invalid. Re-run multi_llm_review to start a new dispatch.'
                )
              }))
            end

            cfg = config_parallel
            default_max  = (cfg['wait_max_default_seconds'] || 600).to_i
            hard_cap     = (cfg['wait_max_hard_cap_seconds'] || MAX_WAIT_HARD_CAP_DEFAULT).to_i
            poll_int     = (cfg['wait_poll_interval_seconds'] || 1.0).to_f
            streak_limit = (cfg['wait_still_pending_streak_limit'] ||
                            STILL_PENDING_STREAK_LIMIT_DEFAULT).to_i

            requested_max = (arguments['max_wait_seconds'] || default_max).to_i
            requested_max = hard_cap if requested_max > hard_cap
            requested_max = 1 if requested_max < 1

            # 1. already_collected check (collected.json present) — before any
            #    deadline / token-dir checks so a successful collect always
            #    returns deterministically even after deadline expiry.
            if File.exist?(safe_path { PendingState.collected_path(token) })
              return reply('already_collected', token, 0.0,
                next_action: next_action_collect_replay(token,
                  'Collect already completed for this token. Call multi_llm_review_collect ' \
                  'to retrieve the cached final consensus (idempotent replay).'))
            end

            # 2. unknown_token check (state.json missing).
            state = PendingState.load_state(token)
            if state.nil?
              return reply('unknown_token', token, 0.0,
                next_action: next_action_redispatch(
                  'Token not found (never existed or already garbage-collected). ' \
                  'Re-run multi_llm_review to start a new dispatch.'))
            end

            # 3. past_collect_deadline early exit (collect would reject anyway).
            deadline = (Time.iso8601(state['collect_deadline']) rescue nil)
            if deadline && Time.now > deadline
              return reply('past_collect_deadline', token, 0.0,
                subprocess_total: state['subprocess_total'] ||
                                  (PendingState.load_request(token)&.dig('reviewers')&.size),
                next_action: next_action_redispatch(
                  'Token deadline elapsed. multi_llm_review_collect would reject. ' \
                  'Re-run multi_llm_review to start a new dispatch.'))
            end

            # 4. Cap max_wait by remaining deadline (R7) so we never block
            #    longer than the useful lifetime of the token.
            if deadline
              remaining = (deadline - Time.now).to_i
              requested_max = remaining if remaining < requested_max
              requested_max = 1 if requested_max < 1
            end

            # 5. Streak guard: if still_pending was returned too many times in
            #    a row, escalate to crashed/wait_exhausted.
            streak = (state['wait_still_pending_streak'] || 0).to_i
            if streak >= streak_limit
              return reply('crashed', token, 0.0,
                crashed_reason: 'wait_exhausted',
                still_pending_streak: streak,
                next_action: next_action_redispatch(
                  "still_pending streak reached limit (#{streak_limit}). Worker may be " \
                  'wedged or pathologically slow. Re-run multi_llm_review.'))
            end

            # 6. Delegate to existing WaitForWorker for the actual polling.
            outcome = WaitForWorker.wait(token, {
              max_wait_seconds: requested_max,
              poll_interval_seconds: poll_int,
              startup_grace_seconds: cfg['startup_grace_seconds'] || 30,
              heartbeat_stale_threshold_seconds: cfg['heartbeat_stale_threshold_seconds'] || 15
            })

            translate_outcome(token, outcome, streak, requested_max, state)
          rescue StandardError => e
            warn "[multi_llm_review_wait] INTERNAL ERROR: #{e.class}: #{e.message}"
            warn e.backtrace.first(10).join("\n") if e.backtrace
            text_content(JSON.generate({
              'status' => 'error',
              'error_class' => 'internal',
              'error' => "#{e.class}: #{e.message}",
              'collect_token' => arguments['collect_token']
            }))
          end

          private

          def translate_outcome(token, outcome, prior_streak, requested_max, state)
            elapsed = (outcome[:elapsed] || requested_max).to_f
            subprocess_total = state['subprocess_total'] ||
                               PendingState.load_request(token)&.dig('reviewers')&.size

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
                  'Re-run multi_llm_review to start a new dispatch.'))
            when :timeout
              new_streak = prior_streak + 1
              persist_streak(token, new_streak)
              reply('still_pending', token, elapsed,
                subprocess_total: subprocess_total,
                still_pending_streak: new_streak,
                next_action: next_action_wait(token,
                  "Worker still healthy after #{requested_max}s. Call multi_llm_review_wait " \
                  "again with the same token (streak #{new_streak}/#{(state.dig('wait_still_pending_streak_limit') || STILL_PENDING_STREAK_LIMIT_DEFAULT)})."))
            else
              reply('crashed', token, elapsed,
                crashed_reason: "unknown_outcome:#{outcome[:status]}",
                subprocess_total: subprocess_total,
                next_action: next_action_redispatch(
                  'Worker reported an unexpected outcome. Re-run multi_llm_review.'))
            end
          end

          def reply(status, token, elapsed, **fields)
            payload = {
              'status' => status,
              'collect_token' => token,
              'elapsed_seconds' => elapsed.round(3)
            }
            payload['subprocess_done']        = fields[:subprocess_done] if fields.key?(:subprocess_done)
            payload['subprocess_total']       = fields[:subprocess_total] if fields.key?(:subprocess_total)
            payload['crashed_reason']         = fields[:crashed_reason] if fields.key?(:crashed_reason)
            payload['still_pending_streak']   = fields[:still_pending_streak] if fields.key?(:still_pending_streak)
            payload['next_action']            = fields[:next_action] if fields.key?(:next_action)
            text_content(JSON.generate(payload))
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

          # Streak persistence via PendingState.update_state (atomic RMW).
          def persist_streak(token, n)
            PendingState.update_state(token) do |state|
              next nil unless state
              state['wait_still_pending_streak'] = n
              state
            end
          rescue StandardError
            # Best-effort. Streak loss = orchestrator gets one more retry,
            # acceptable degradation.
          end

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
          rescue StandardError
            # Best-effort.
          end

          def safe_path
            yield
          rescue StandardError
            '/dev/null/never_exists'
          end

          def config_parallel
            return {} unless self.class.const_defined?(:CONFIG_PATH) || true
            path = File.expand_path('../config/multi_llm_review.yml', __dir__)
            return {} unless File.exist?(path)
            cfg = YAML.safe_load_file(path, permitted_classes: [Symbol], aliases: true)
            (cfg.dig('delegation', 'parallel') || {}).to_h
          rescue StandardError
            {}
          end
        end
      end
    end
  end
end
