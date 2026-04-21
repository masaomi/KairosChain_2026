# frozen_string_literal: true

require_relative 'active_observe'
require_relative 'task_dag'
require_relative 'wal_phase_recorder'
require_relative 'code_gen_phase_handler'

module KairosMcp
  class Daemon
    # OodaCycleRunner — the single callable that Integration.wire! receives
    # as its cycle_runner: parameter.
    #
    # Design (P3.5 v0.1 §2):
    #   Orchestrates OBSERVE→ORIENT→DECIDE→ACT→REFLECT using all P3.x components.
    #   No global state — all collaborators injected at construction.
    #   Returns the shape Integration expects:
    #     { status:, llm_calls:, input_tokens:, output_tokens: }
    class OodaCycleRunner
      PAUSED_STATUS = 'paused_awaiting_approval'

      def initialize(
        workspace_root:,
        safety:,
        invoker:,
        active_observe:,
        orient_fn:,
        decide_fn:,
        reflect_fn:,
        code_gen_phase_handler:,
        chain_recorder:,
        shell:,
        wal_factory:,
        logger: nil
      )
        @ws       = workspace_root
        @safety   = safety
        @invoker  = invoker
        @observe  = active_observe
        @orient   = orient_fn
        @decide   = decide_fn
        @reflect  = reflect_fn
        @cg_handler = code_gen_phase_handler
        @chain    = chain_recorder
        @shell    = shell
        @wal_factory = wal_factory
        @logger   = logger
        # NOTE: @usage counters are stubbed at zero in P3.5 validation.
        # Real LLM usage tracking will be wired when orient_fn/decide_fn
        # are connected to CognitiveLoop (which reports usage per call).
        @usage    = { llm_calls: 0, input_tokens: 0, output_tokens: 0 }
      end

      # @param mandate [Hash]
      # @return [Hash] { status:, llm_calls:, input_tokens:, output_tokens:, phases: }
      def call(mandate)
        @usage = { llm_calls: 0, input_tokens: 0, output_tokens: 0 }

        # Flush any pending chain records (always, including resume paths)
        @chain.retry_pending

        # Step 0: Check for pending proposal resume
        resolved = @cg_handler.resume_if_pending
        case resolved
        when nil
          # No pending proposal — proceed with full cycle
        when :still_pending
          return result_hash('paused', phases: [])
        when Hash
          # F1 fix: Open WAL for resume path
          mandate_id = mandate[:id] || mandate['id'] || 'unknown'
          wal = @wal_factory.call(mandate_id)
          cycle = (mandate[:cycles_completed] || mandate['cycles_completed'] || 0) + 1
          recorder = WalPhaseRecorder.new(wal: wal, cycle: cycle)
          begin
            if resolved[:status] == 'applied'
              maybe_run_post_commit(mandate, resolved)
              # F3 fix: chain recording already done by CodeGenAct — don't duplicate
              run_reflect(resolved, mandate, recorder)
              return result_hash('ok', phases: [:resume, :reflect])
            else
              run_reflect(resolved, mandate, recorder)
              return result_hash(resolved[:status], phases: [:resume, :reflect])
            end
          ensure
            wal.close rescue nil if wal.respond_to?(:close)
          end
        end

        # Open WAL
        mandate_id = mandate[:id] || mandate['id'] || 'unknown'
        wal = @wal_factory.call(mandate_id)
        cycle = (mandate[:cycles_completed] || mandate['cycles_completed'] || 0) + 1
        recorder = WalPhaseRecorder.new(wal: wal, cycle: cycle)

        begin
          # Step 1: OBSERVE
          observation = run_observe(mandate, recorder)

          # Step 2: ORIENT
          orient_output = run_orient(observation, mandate, recorder)

          # Step 3: DECIDE
          decision = run_decide(orient_output, mandate, recorder)

          # Step 4: ACT
          act_result = run_act(decision, mandate, recorder)

          if act_result[:status] == PAUSED_STATUS
            return result_hash('paused', phases: [:observe, :orient, :decide, :act],
                               proposal_id: act_result[:proposal_id])
          end

          # Post-commit shell (git add/commit)
          maybe_run_post_commit(mandate, act_result, decision: decision)

          # Chain recording handled by CodeGenAct internally (no duplication)

          # Step 5: REFLECT
          run_reflect(act_result, mandate, recorder)

          result_hash('ok', phases: [:observe, :orient, :decide, :act, :reflect])
        ensure
          wal.close rescue nil if wal.respond_to?(:close)
        end
      end

      private

      def run_observe(mandate, recorder)
        recorder.around_phase(:observe) do
          @observe.observe(mandate, tool_invoker: @invoker)
        end
      end

      def run_orient(observation, mandate, recorder = nil)
        phase_body = -> { @orient.call(observation, mandate) }
        if recorder
          recorder.around_phase(:orient) { phase_body.call }
        else
          phase_body.call
        end
      end

      def run_decide(orient_output, mandate, recorder = nil)
        phase_body = -> { @decide.call(orient_output, mandate) }
        if recorder
          recorder.around_phase(:decide) { phase_body.call }
        else
          phase_body.call
        end
      end

      def run_act(decision, mandate, recorder)
        recorder.around_phase(:act) do
          action = decision[:action] || decision['action'] || 'noop'
          case action
          when 'code_edit'
            @cg_handler.handle_act(decision, mandate)
          when 'noop', 'read_only'
            { status: 'noop' }
          else
            { status: 'unsupported', action: action }
          end
        end
      end

      def run_reflect(act_result, mandate, recorder = nil)
        phase_body = -> { @reflect.call(act_result, mandate) }
        if recorder
          recorder.around_phase(:reflect) { phase_body.call }
        else
          phase_body.call
        end
      end

      def maybe_run_post_commit(mandate, act_result, decision: nil)
        return unless act_result[:status] == 'applied'

        # Get post_commit from decision or mandate
        post_commit = decision&.dig(:post_commit, :shell) ||
                      decision&.dig('post_commit', 'shell') ||
                      mandate.dig(:post_commit, :shell) ||
                      mandate.dig('post_commit', 'shell')
        return if post_commit.nil? || post_commit.empty?

        act_result[:shell_steps] = []
        post_commit.each do |argv|
          result = @shell.call(
            cmd: argv,
            cwd: @ws,
            timeout: 15,
            allowed_paths: [@ws],
            network: :deny
          )
          act_result[:shell_steps] << {
            cmd_hash: result.cmd_hash,
            status: result.status,
            success: result.success?
          }
          unless result.success?
            log(:warn, "post_commit shell failed: #{argv.inspect} status=#{result.status}")
          end
        end
      end

      def result_hash(status, phases: [], proposal_id: nil)
        h = {
          status: status,
          llm_calls: @usage[:llm_calls],
          input_tokens: @usage[:input_tokens],
          output_tokens: @usage[:output_tokens],
          phases: phases
        }
        h[:proposal_id] = proposal_id if proposal_id
        h
      end

      def log(level, msg)
        return unless @logger && @logger.respond_to?(level)
        @logger.public_send(level, msg)
      rescue StandardError
        # never crash on logging
      end
    end
  end
end
