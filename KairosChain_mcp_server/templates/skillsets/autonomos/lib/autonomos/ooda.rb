# frozen_string_literal: true

module Autonomos
  # Shared OODA (Observe-Orient-Decide-Act) logic used by both
  # AutonomosCycle (single mode) and AutonomosLoop (continuous mode).
  # Extracted to avoid .send(:private_method) coupling between tools.
  module Ooda
    def observe(goal_name)
      {
        timestamp: Time.now.iso8601,
        git: ::Autonomos.git_observation,
        previous_cycle: load_previous_cycle,
        chain_events: load_chain_events,
        l2_context: load_l2_context
      }
    end

    def orient(observation, goal_name, feedback)
      goal = load_goal(goal_name)
      goal_hash = Digest::SHA256.hexdigest(goal[:content].to_s)

      orientation = {
        goal_name: goal_name,
        goal_hash: goal_hash,
        goal_summary: extract_goal_summary(goal[:content]),
        gaps: identify_gaps(goal, observation),
        blockers: identify_blockers(observation),
        context: []
      }

      if feedback && !feedback.empty?
        orientation[:context] << "Human feedback: #{feedback}"
      end

      if observation[:previous_cycle]
        orientation[:context] << "Previous cycle (#{observation[:previous_cycle][:cycle_id]}): #{observation[:previous_cycle][:state]}"
      end

      orientation
    end

    def decide(orientation)
      sorted_gaps = orientation[:gaps].sort_by do |g|
        case g[:priority]
        when 'high' then 0
        when 'medium' then 1
        when 'low' then 2
        else 3
        end
      end

      top_gap = sorted_gaps.first
      return { task_id: nil, design_intent: 'No actionable gaps', autoexec_task: nil } unless top_gap

      task_id = "autonomos_#{Time.now.strftime('%Y%m%d_%H%M%S')}"

      # Map gap priority to risk_default.
      # Note: high-priority gaps produce high-risk steps, which will always
      # pause in low/medium mandate budgets. This is intentional policy:
      # high-priority gaps always require human review.
      risk_default = case top_gap[:priority]
                     when 'high' then 'high'
                     when 'low' then 'low'
                     else 'medium'
                     end

      is_setup = top_gap[:type] == 'setup'

      complexity = assess_complexity(top_gap, sorted_gaps, risk_default)

      {
        task_id: task_id,
        design_intent: "Address #{top_gap[:type]}: #{top_gap[:description]}",
        selected_gap: top_gap,
        remaining_gaps: sorted_gaps.size - 1,
        complexity_hint: complexity,
        autoexec_task: {
          task_id: task_id,
          meta: {
            description: top_gap[:description],
            risk_default: risk_default,
            autonomos_cycle: true
          },
          steps: [
            {
              step_id: 'analyze',
              action: "Analyze current state for: #{top_gap[:description]}",
              risk: 'low',
              depends_on: [],
              requires_human_cognition: false
            },
            {
              step_id: 'implement',
              action: "Implement: #{top_gap[:action_hint] || top_gap[:description]}",
              risk: risk_default,
              depends_on: ['analyze'],
              requires_human_cognition: is_setup
            },
            {
              step_id: 'verify',
              action: 'Verify implementation correctness',
              risk: 'low',
              depends_on: ['implement'],
              requires_human_cognition: false
            }
          ]
        }
      }
    end

    def record_intent(cycle_id, goal_name, orientation, proposal)
      return [nil, nil] unless defined?(KairosChain::Chain)

      begin
        chain = KairosChain::Chain.new
        log_entry = JSON.generate({
          _type: 'autonomos_intent',
          cycle_id: cycle_id,
          goal_name: goal_name,
          goal_hash: orientation[:goal_hash],
          gaps_identified: orientation[:gaps].size,
          proposed_task_id: proposal[:task_id],
          design_intent: proposal[:design_intent],
          timestamp: Time.now.iso8601
        })
        block = chain.add_block([log_entry])
        [block&.hash, nil]
      rescue StandardError => e
        warn "[autonomos] Intent recording failed: #{e.message}"
        [nil, e.message]
      end
    end

    def build_cycle_state(cycle_id, goal_name, observation, orientation, proposal, state, existing = nil)
      prior_history = existing ? Array(existing[:state_history]) : []
      created = existing ? existing[:created_at] : Time.now.iso8601

      new_entry = { state: state, at: Time.now.iso8601 }
      {
        cycle_id: cycle_id,
        goal_name: goal_name,
        state: state,
        observation: observation,
        orientation: orientation,
        proposal: proposal,
        created_at: created,
        state_history: prior_history + [new_entry]
      }
    end

    def load_goal(goal_name)
      if defined?(KairosMcp::KnowledgeProvider)
        begin
          provider = KairosMcp::KnowledgeProvider.new(nil)
          result = provider.get(goal_name)
          if result && result[:content]
            return { content: result[:content], found: true }
          end
        rescue StandardError
          # Fall through
        end
      end

      { content: nil, found: false }
    end

    private

    COMPLEX_KEYWORDS = /\b(architect|design|refactor|migrat|restructur|integrat|security|auth)/i

    def assess_complexity(top_gap, sorted_gaps, risk_default)
      signals = []
      signals << 'high_risk' if risk_default == 'high'
      signals << 'many_gaps' if sorted_gaps.size > 3
      signals << 'design_scope' if top_gap[:description]&.match?(COMPLEX_KEYWORDS)

      level = if signals.size >= 2
                'high'
              elsif signals.any?
                'medium'
              else
                'low'
              end

      { level: level, signals: signals }
    end

    def load_previous_cycle
      prev = ::Autonomos::CycleStore.load_latest
      return nil unless prev

      {
        cycle_id: prev[:cycle_id],
        state: prev[:state],
        goal_name: prev[:goal_name],
        evaluation: prev[:evaluation],
        suggested_next: prev.dig(:proposal, :design_intent)
      }
    end

    def load_chain_events
      return [] unless defined?(KairosChain::Chain)

      limit = ::Autonomos.config.fetch('chain_history_limit', 10)
      begin
        chain = KairosChain::Chain.new
        blocks = chain.blocks.last(limit)
        blocks.map do |b|
          {
            index: b.index,
            timestamp: b.timestamp,
            data_summary: b.data.map { |d|
              parsed = JSON.parse(d) rescue {}
              parsed['_type'] || parsed['type'] || 'unknown'
            }
          }
        end
      rescue StandardError
        []
      end
    end

    def load_l2_context
      return nil unless defined?(KairosMcp::ContextManager)

      begin
        ctx_mgr = KairosMcp::ContextManager.new
        sessions = ctx_mgr.list_sessions rescue []
        return nil if sessions.empty?

        latest = sessions.last
        { session_id: latest[:name] || latest[:id], exists: true }
      rescue StandardError
        nil
      end
    end

    def extract_goal_summary(content)
      return 'No goal defined. Set a goal via: knowledge_update(name: "project_goals", content: "...")' unless content

      lines = content.to_s.split("\n").reject { |l| l.strip.start_with?('---') || l.strip.empty? }
      lines.first(10).join("\n")
    end

    def identify_gaps(goal, observation)
      gaps = []

      unless goal[:found]
        gaps << {
          type: 'setup',
          description: 'No project goal defined in L1 knowledge',
          priority: 'high',
          action_hint: 'Set a goal via knowledge_update(name: "project_goals", content: "...")'
        }
        return gaps
      end

      if goal[:content]
        unchecked = goal[:content].scan(/^- \[ \] (.+)$/).flatten
        unchecked.each do |item|
          gaps << {
            type: 'task_gap',
            description: item.strip,
            priority: 'medium',
            action_hint: "Implement: #{item.strip}"
          }
        end
      end

      git = observation[:git]
      if git && git[:git_available]
        modified = Array(git[:status]).select { |s| s.start_with?('M ', ' M') }
        if modified.size > 5
          gaps << {
            type: 'task_gap',
            description: "#{modified.size} uncommitted modified files — consider committing or organizing",
            priority: 'low',
            action_hint: 'Review and commit pending changes'
          }
        end
      end

      gaps
    end

    def identify_blockers(observation)
      blockers = []

      git = observation[:git]
      if git && !git[:git_available]
        blockers << { type: 'environment', description: "Git unavailable: #{git[:reason]}" }
      end

      blockers
    end
  end
end
