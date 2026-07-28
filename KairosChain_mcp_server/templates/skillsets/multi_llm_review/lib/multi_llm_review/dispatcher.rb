# frozen_string_literal: true

require 'thread'
require 'json'
require 'securerandom'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Parallel dispatcher for multi-LLM review calls.
      #
      # Uses a Queue-based result collection with a global deadline,
      # a semaphore for concurrency limiting, and cooperative cancellation
      # (no Thread.kill). Each subprocess is tracked via SafeSubprocess
      # dispatch_id for cleanup on timeout.
      class Dispatcher
        def initialize(tool_invoker, timeout_seconds: 300, max_concurrent: 2)
          @invoker = tool_invoker
          @timeout = timeout_seconds
          @max_concurrent = max_concurrent
        end

        # Dispatch review prompts to all configured reviewers in parallel.
        #
        # @param reviewers [Array<Hash>] each with :provider, :model, :role_label
        # @param messages [Array<Hash>] prompt messages for llm_call
        # @param system_prompt [String] system prompt for llm_call
        # @param context [InvocationContext] for invoke_tool
        # @param review_context [String] 'independent' or 'project_aware'
        # @return [Array<Hash>] results indexed by reviewer position
        def dispatch(reviewers, messages, system_prompt, context:,
                     review_context: 'independent')
          dispatch_id = SecureRandom.hex(8)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
          results = Array.new(reviewers.size)
          result_queue = Queue.new

          # Semaphore for concurrency limit
          semaphore = Queue.new
          @max_concurrent.times { semaphore << :ticket }

          threads = reviewers.each_with_index.map do |reviewer, idx|
            Thread.new do
              Thread.current[:cancelled] = false
              ticket = semaphore.pop  # blocks until slot available

              if Thread.current[:cancelled]
                result_queue << [idx, build_skip(reviewer, 'cancelled_before_start')]
                semaphore << ticket
                next
              end

              t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              begin
                llm_args = build_llm_args(reviewer, messages, system_prompt,
                                          dispatch_id, review_context)
                raw = @invoker.invoke_tool('llm_call', llm_args, context: context)
                parsed = JSON.parse(raw.map { |b| b[:text] || b['text'] }.compact.join)

                if parsed['status'] == 'error'
                  result_queue << [idx, build_error(reviewer, parsed['error'], t0)]
                else
                  result_queue << [idx, build_success(reviewer, parsed, t0)]
                end
              rescue StandardError => e
                result_queue << [idx, build_error(reviewer, {
                  'type' => e.class.name, 'message' => e.message
                }, t0)]
              ensure
                semaphore << ticket
              end
            end
          end

          # Collect results with global deadline
          collected = 0
          while collected < reviewers.size
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if remaining <= 0
              # Cancel remaining threads cooperatively
              threads.each { |t| t[:cancelled] = true unless t.status == false }
              # Wake semaphore-blocked threads
              reviewers.size.times { semaphore << :cancel_sentinel }
              # Drain queue (non-blocking)
              loop do
                entry = result_queue.pop(true) rescue nil
                break unless entry
                i, result = entry
                results[i] = result
                collected += 1
              end
              # Mark uncollected as timed out
              reviewers.each_with_index do |r, i|
                next if results[i]
                results[i] = build_skip(r, 'dispatch_timeout')
              end
              break
            end

            # Queue#pop(timeout:) returns nil on timeout (Ruby 3.2+)
            entry = result_queue.pop(timeout: [remaining, 1.0].min)
            if entry.nil?
              next  # timeout tick, re-check deadline
            end
            i, result = entry
            results[i] = result
            collected += 1
          end

          # Kill in-flight subprocesses from this dispatch
          kill_dispatch_pids(dispatch_id)

          # Wait for threads to finish naturally.
          # v0.3.1 meta-review bug #1 fix: during this cleanup the main thread
          # was silent for up to ~10s × N, which let MAIN_STATE.counter stall,
          # the worker's pulse thread to stop touching worker.tick, and Phase 2
          # to false-positive heartbeat_stale. Bump the counter here so the
          # pulse observes progress during the join loop. Works as a no-op
          # in non-worker contexts (MainState simply not required).
          threads.each do |t|
            loop do
              break if t.join(1)
              bump_main_state_counter
            end
          end
          bump_main_state_counter   # final bump after all joined

          results
        end

        private

        def bump_main_state_counter
          return unless defined?(KairosMcp::SkillSets::MultiLlmReview::MainState)
          # v3.24.3: counter-only bump. exit_call! is private; bump_counter!
          # is the public counter-only progress signal (does not touch
          # ts_by_thread).
          KairosMcp::SkillSets::MultiLlmReview::MainState.bump_counter!
        rescue StandardError
          nil
        end

        public

        private

        def build_llm_args(reviewer, messages, system_prompt, dispatch_id,
                           review_context)
          provider = reviewer[:provider] || reviewer['provider']
          model = reviewer[:model] || reviewer['model']

          args = {
            'messages' => messages,
            'system' => system_prompt,
            'provider_override' => provider
          }
          args['model'] = model if model

          # Per-reviewer effort override. The value comes from config; the
          # 2026-04-29 policy keeps reviewers at their default effort because
          # evaluator quality is effort-independent.
          effort = reviewer[:effort] || reviewer['effort']
          args['effort'] = effort if effort

          # Per-reviewer transport backend (codex: "cli" default | "mcp"). Opt-in.
          backend = reviewer[:backend] || reviewer['backend']
          args['backend'] = backend if backend

          # Pass dispatch_id and sandbox_mode to llm_call for adapter config.
          args['dispatch_id'] = dispatch_id
          args['sandbox_mode'] = true if review_context == 'independent'

          args
        end

        def build_success(reviewer, llm_response, t0)
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
          declared = reviewer[:model] || reviewer['model']
          # INV-E5. Some transports report the model that actually answered;
          # others return plain text and cannot. Where the report exists it is
          # taken and any divergence from the slot's own definition is made
          # visible; where it does not, the record says so rather than passing
          # the request off as an observation.
          observed = llm_response.dig('response', 'model_observed')
          observed = nil if observed.to_s.strip.empty?

          {
            role_label: reviewer[:role_label] || reviewer['role_label'] || reviewer[:provider],
            provider: llm_response['provider'] || reviewer[:provider],
            model: declared || llm_response.dig('response', 'model'),
            model_declared: declared,
            model_observed: observed,
            model_source: observed ? 'observed' : 'declared',
            model_divergence: observed && declared && observed != declared,
            raw_text: llm_response.dig('response', 'content') || '',
            elapsed_seconds: elapsed.round(1),
            error: nil,
            status: :success,
            # v0.3.1 meta-review bug #2 fix (codex 5.5): preserve usage for F-USR
            # replay. CallRouter.perform returns {'usage' => {...}} at top-level;
            # dropping it here broke Prop #2 consumption-loop closure.
            usage: llm_response['usage']
          }
        end

        # INV-E4: a slot that failed still has an identity, and the record has
        # to say which slot left the denominator. Omitting the model here made
        # a transport failure anonymous in the composition.
        def build_error(reviewer, err, t0)
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
          {
            role_label: reviewer[:role_label] || reviewer['role_label'] || reviewer[:provider],
            provider: reviewer[:provider] || reviewer['provider'],
            model: reviewer[:model] || reviewer['model'],
            model_declared: reviewer[:model] || reviewer['model'],
            model_source: 'declared',
            elapsed_seconds: elapsed.round(1),
            error: err,
            status: :error
          }
        end

        def build_skip(reviewer, reason)
          {
            role_label: reviewer[:role_label] || reviewer['role_label'] || reviewer[:provider],
            provider: reviewer[:provider] || reviewer['provider'],
            model: reviewer[:model] || reviewer['model'],
            model_declared: reviewer[:model] || reviewer['model'],
            model_source: 'declared',
            elapsed_seconds: 0,
            error: { 'type' => 'skip', 'message' => reason },
            status: :skip
          }
        end

        def kill_dispatch_pids(dispatch_id)
          if defined?(KairosMcp::SkillSets::LlmClient::SafeSubprocess)
            KairosMcp::SkillSets::LlmClient::SafeSubprocess.kill_pids_for_dispatch(dispatch_id)
          end
        rescue StandardError
          nil
        end
      end
    end
  end
end
