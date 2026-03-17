# frozen_string_literal: true

module Autonomos
  # Handles the Reflect phase: evaluates execution results, saves learnings,
  # records outcome on chain (two-phase commit, phase 2).
  class Reflector
    def initialize(cycle_id, execution_result: nil, feedback: nil, skip_reason: nil)
      @cycle_id = cycle_id
      @execution_result = execution_result
      @feedback = feedback
      @skip_reason = skip_reason
    end

    def reflect
      cycle = CycleStore.load(@cycle_id)
      unless cycle
        return { error: "Cycle '#{@cycle_id}' not found" }
      end

      unless cycle[:state] == 'decided'
        return {
          error: "Cycle '#{@cycle_id}' is in state '#{cycle[:state]}', expected 'decided'",
          hint: 'Run autonomos_cycle first to create a cycle, then execute via autoexec before reflecting'
        }
      end

      # 1. Determine evaluation (check failure/partial BEFORE success to avoid
      #    false positives like "done incorrectly" matching 'success')
      evaluation = if @skip_reason
                     'skipped'
                   elsif @execution_result.nil? || @execution_result.to_s.empty?
                     'unknown'
                   elsif @execution_result.to_s.match?(/\b(fail(ed|ure)?|errors?|crash|broke|broken|abort(ed)?)\b/i)
                     'failed'
                   elsif @execution_result.to_s.match?(/\b(partial|some|incomplete|half|mixed)\b/i)
                     'partial'
                   elsif @execution_result.to_s.match?(/\b(success|completed|passed|done)\b/i)
                     'success'
                   else
                     'unknown'
                   end

      # 2. Build learnings
      learnings = build_learnings(cycle, evaluation)

      # 3. Save learnings to L2 context
      l2_name = save_to_l2(cycle, learnings, evaluation)

      # 4. Check for L1 promotion candidate
      l1_candidate = check_l1_promotion(cycle)

      # 5. Build suggested next direction
      suggested_next = build_suggested_next(cycle, evaluation)

      # 6. Record OUTCOME on chain (two-phase commit, phase 2)
      chain_ref, chain_error = record_outcome(cycle, evaluation, learnings, l2_name)

      # 7. Persist evaluation, learnings, and state transition in a single save
      cycle[:evaluation] = evaluation
      cycle[:learnings] = learnings
      cycle[:suggested_next] = suggested_next
      cycle[:l2_saved] = l2_name
      cycle[:chain_outcome_ref] = chain_ref
      cycle[:state] = 'reflected'
      cycle[:state_history] ||= []
      cycle[:state_history] << { state: 'reflected', at: Time.now.iso8601 }
      CycleStore.save(@cycle_id, cycle)

      result = {
        cycle_id: @cycle_id,
        evaluation: evaluation,
        learnings: learnings,
        l2_saved: l2_name,
        suggested_next: suggested_next,
        chain_ref: chain_ref
      }
      result[:l1_promotion_candidate] = l1_candidate if l1_candidate
      result[:skip_reason] = @skip_reason if @skip_reason
      result[:chain_warning] = "Outcome recording failed: #{chain_error}" if chain_error
      result[:human_feedback_incorporated] = true if @feedback && !@feedback.empty?
      result
    end

    private

    def build_learnings(cycle, evaluation)
      learnings = []
      learnings << "Goal: #{cycle[:goal_name]}"
      learnings << "Proposed task: #{cycle.dig(:proposal, :task_id) || 'unknown'}"
      learnings << "Design intent: #{cycle.dig(:proposal, :design_intent) || 'not recorded'}"
      learnings << "Evaluation: #{evaluation}"
      learnings << "Execution result: #{@execution_result}" if @execution_result
      learnings << "Human feedback: #{@feedback}" if @feedback && !@feedback.empty?
      learnings << "Skip reason: #{@skip_reason}" if @skip_reason
      learnings
    end

    def save_to_l2(cycle, learnings, evaluation)
      return nil unless defined?(KairosMcp::ContextManager)

      l2_name = "autonomos_reflect_#{@cycle_id}"
      # Use YAML.dump for frontmatter to prevent injection via goal_name etc.
      frontmatter = YAML.dump({
        'type' => 'autonomos_reflection',
        'cycle_id' => @cycle_id.to_s,
        'goal_name' => cycle[:goal_name].to_s,
        'evaluation' => evaluation.to_s,
        'timestamp' => Time.now.iso8601
      }).sub(/\A---\n/, '') # YAML.dump prepends "---\n", we add our own
      gaps_list = Array(cycle.dig(:orientation, :gaps)).map { |g|
        g.is_a?(Hash) ? "- #{g[:description] || g[:type]}" : "- #{g}"
      }.join("\n")
      content = <<~MD
        ---
        #{frontmatter.strip}
        ---

        # Autonomos Reflection: #{@cycle_id}

        ## Learnings
        #{learnings.map { |l| "- #{l}" }.join("\n")}

        ## Orientation Gaps (from cycle)
        #{gaps_list}

        ## Suggested Next
        #{cycle.dig(:proposal, :design_intent) || 'No specific direction'}
      MD

      begin
        ctx_mgr = KairosMcp::ContextManager.new
        session_id = ctx_mgr.generate_session_id(prefix: 'autonomos')
        result = ctx_mgr.save_context(session_id, l2_name, content)
        if result.is_a?(Hash) && result[:success] == false
          warn "[autonomos] L2 save failed: #{result[:error]}"
          return nil
        end
        l2_name
      rescue StandardError => e
        warn "[autonomos] L2 save failed: #{e.message}"
        nil
      end
    end

    def check_l1_promotion(cycle)
      # Check if this goal has been reflected on 3+ times — candidate for L1 pattern
      cycles = CycleStore.list(limit: 50)
      goal_name = cycle[:goal_name]
      same_goal_cycles = cycles.select { |c| c[:goal_name] == goal_name && c[:state] == 'reflected' }

      if same_goal_cycles.size >= 3
        {
          pattern: "Goal '#{goal_name}' has #{same_goal_cycles.size} reflected cycles",
          suggestion: "Consider promoting recurring patterns to L1 knowledge via knowledge_update"
        }
      end
    end

    def build_suggested_next(cycle, evaluation)
      case evaluation
      when 'success'
        "Task completed successfully. Review remaining gaps from orientation and start next cycle."
      when 'partial'
        "Partial success. Consider re-running autonomos_cycle to address remaining gaps."
      when 'failed'
        "Task failed. Review execution results, adjust approach, and re-run autonomos_cycle."
      when 'skipped'
        "Task was skipped (#{@skip_reason}). Re-run autonomos_cycle for a new proposal."
      else
        "Re-run autonomos_cycle to continue project execution."
      end
    end

    def record_outcome(cycle, evaluation, learnings, l2_name)
      return [nil, nil] unless defined?(KairosChain::Chain)

      begin
        chain = KairosChain::Chain.new
        log_entry = JSON.generate({
          _type: 'autonomos_outcome',
          cycle_id: @cycle_id,
          intent_ref: cycle[:intent_ref],
          goal_name: cycle[:goal_name],
          evaluation: evaluation,
          learnings_count: learnings.size,
          l2_saved: l2_name,
          timestamp: Time.now.iso8601
        })
        block = chain.add_block([log_entry])
        [block&.hash, nil]
      rescue StandardError => e
        warn "[autonomos] Outcome recording failed: #{e.message}"
        [nil, e.message]
      end
    end
  end
end
