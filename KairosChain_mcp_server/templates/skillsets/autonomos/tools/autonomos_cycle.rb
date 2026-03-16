# frozen_string_literal: true

require 'securerandom'

module KairosMcp
  module SkillSets
    module Autonomos
      module Tools
        class AutonomosCycle < KairosMcp::Tools::BaseTool
          def name
            'autonomos_cycle'
          end

          def description
            'Run one autonomous project cycle: observe current state (git, L2, chain), ' \
              'orient against L1 project goals (gap analysis), and decide the next task ' \
              '(as autoexec-compatible JSON). Returns a proposal for human review. ' \
              'After human approves and autoexec executes, call autonomos_reflect to complete the cycle.'
          end

          def category
            :autonomos
          end

          def usecase_tags
            %w[autonomos cycle autonomous agent ooda observe orient decide]
          end

          def related_tools
            %w[autonomos_reflect autonomos_status autoexec_plan autoexec_run]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                goal_name: {
                  type: 'string',
                  description: 'L1 knowledge name holding project goal (default: "project_goals")'
                },
                feedback: {
                  type: 'string',
                  description: 'Human feedback or new perspective from a previous cycle. ' \
                    'Appended to cycle context — does not modify goals.'
                },
                cycle_id: {
                  type: 'string',
                  description: 'Resume an interrupted cycle by ID (optional)'
                }
              }
            }
          end

          def call(arguments)
            ensure_loaded!

            goal_name = arguments['goal_name'] || ::Autonomos.config.fetch('default_goal_name', 'project_goals')
            feedback = arguments['feedback']
            resuming = !arguments['cycle_id'].nil?
            cycle_id = arguments['cycle_id'] || ::Autonomos::CycleStore.generate_cycle_id

            # If resuming, load existing state to preserve history
            existing_state = resuming ? ::Autonomos::CycleStore.load(cycle_id) : nil
            if resuming && existing_state.nil?
              return text_content(JSON.pretty_generate({
                error: "Cycle '#{cycle_id}' not found for resume",
                hint: 'Omit cycle_id to start a new cycle'
              }))
            end

            # 1. Acquire cycle lock
            lock_acquired = false
            begin
              ::Autonomos::CycleStore.acquire_lock(cycle_id)
              lock_acquired = true

              # 2. Observe
              observation = observe(goal_name)

              # 3. Orient
              orientation = orient(observation, goal_name, feedback)

              # 4. Check for no-action (goal achieved or no gaps)
              if orientation[:gaps].empty?
                state = build_cycle_state(cycle_id, goal_name, observation, orientation, nil, 'no_action', existing_state)
                ::Autonomos::CycleStore.save(cycle_id, state)
                return text_content(JSON.pretty_generate({
                  cycle_id: cycle_id,
                  state: 'no_action',
                  message: 'No actionable gaps found. Goal may be achieved or needs refinement.',
                  observation: observation,
                  orientation: orientation
                }))
              end

              # 5. Decide: generate autoexec proposal
              proposal = decide(orientation)

              # 6. Record INTENT on chain (two-phase commit, phase 1)
              intent_ref, intent_error = record_intent(cycle_id, goal_name, orientation, proposal)

              # 7. Save cycle state (preserve history if resuming)
              state = build_cycle_state(cycle_id, goal_name, observation, orientation, proposal, 'decided', existing_state)
              state[:intent_ref] = intent_ref
              ::Autonomos::CycleStore.save(cycle_id, state)

              # 8. Build response
              response = {
                cycle_id: cycle_id,
                state: 'decided',
                observation: observation,
                orientation: orientation,
                proposal: proposal,
                intent_ref: intent_ref,
                next_steps: [
                  'Review the proposal above',
                  "If approved, run: autoexec_plan(task_json: '#{JSON.generate(proposal[:autoexec_task])}')",
                  "After autoexec completes: autonomos_reflect(cycle_id: \"#{cycle_id}\", execution_result: \"...\")",
                  "If rejected: autonomos_reflect(cycle_id: \"#{cycle_id}\", skip_reason: \"...\")"
                ]
              }
              response[:feedback_incorporated] = true if feedback && !feedback.empty?
              response[:chain_warning] = "Intent recording failed: #{intent_error}" if intent_error

              text_content(JSON.pretty_generate(response))
            ensure
              ::Autonomos::CycleStore.release_lock if lock_acquired
            end
          rescue ::Autonomos::DependencyError => e
            text_content(JSON.pretty_generate({ error: e.message }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message, type: e.class.name }))
          end

          private

          def ensure_loaded!
            ::Autonomos.load! unless ::Autonomos.loaded?
          end

          # --- Observe Phase ---

          def observe(goal_name)
            obs = {
              timestamp: Time.now.iso8601,
              git: ::Autonomos.git_observation,
              previous_cycle: load_previous_cycle,
              chain_events: load_chain_events,
              l2_context: load_l2_context
            }
            obs
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

          # --- Orient Phase ---

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

            # Extract checklist items from goal content
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

            # Git-based gaps
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

          # --- Decide Phase ---

          def decide(orientation)
            # Select highest priority gap
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

            # Map gap priority to risk_default
            risk_default = case top_gap[:priority]
                           when 'high' then 'high'
                           when 'low' then 'low'
                           else 'medium'
                           end

            # Setup gaps require human cognition (goal-setting is a human act)
            is_setup = top_gap[:type] == 'setup'

            {
              task_id: task_id,
              design_intent: "Address #{top_gap[:type]}: #{top_gap[:description]}",
              selected_gap: top_gap,
              remaining_gaps: sorted_gaps.size - 1,
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
                    action: "Verify implementation correctness",
                    risk: 'low',
                    depends_on: ['implement'],
                    requires_human_cognition: false
                  }
                ]
              }
            }
          end

          # --- Chain Recording ---

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
            # Preserve state_history and created_at from previous state when resuming
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
        end
      end
    end
  end
end
