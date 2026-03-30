# frozen_string_literal: true

require 'securerandom'
require 'yaml'
require 'time'
require 'digest'
require_relative '../lib/agent'

module KairosMcp
  module SkillSets
    module Agent
      module Tools
        class AgentStart < KairosMcp::Tools::BaseTool
          def name
            'agent_start'
          end

          def description
            'Start a new agent session. Creates a mandate, runs OBSERVE, ' \
              'and returns the observation. The session pauses at [observed] state ' \
              'waiting for agent_step(approve) to proceed.'
          end

          def category
            :agent
          end

          def usecase_tags
            %w[agent start session ooda autonomous]
          end

          def related_tools
            %w[agent_step agent_status agent_stop]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                goal_name: {
                  type: 'string',
                  description: 'Name of the goal (must exist as L1 knowledge or L2 context)'
                },
                max_cycles: {
                  type: 'integer',
                  description: 'Maximum OODA cycles (1-10, default: 3)'
                },
                checkpoint_every: {
                  type: 'integer',
                  description: 'Pause for human checkpoint every N cycles (1-3, default: 1)'
                },
                risk_budget: {
                  type: 'string',
                  description: 'Maximum risk level: "low" or "medium" (default: "low")'
                },
                autonomous: {
                  type: 'boolean',
                  description: 'Enable autonomous mode (default: false). ' \
                    'Session starts at [observed] regardless. ' \
                    'Autonomous loop begins on first agent_step(approve).'
                }
              },
              required: ['goal_name']
            }
          end

          def call(arguments)
            goal_name = arguments['goal_name']
            max_cycles = arguments['max_cycles'] || 3
            checkpoint_every = arguments['checkpoint_every'] || 1
            risk_budget = arguments['risk_budget'] || 'low'
            autonomous = arguments['autonomous'] == true

            # Pre-resolve goal content for content-based drift detection hash
            pre_obs = run_observe(goal_name)
            goal_content_for_hash = pre_obs['goal_content'] || goal_name
            goal_hash = Digest::SHA256.hexdigest(goal_content_for_hash)[0..15]

            mandate = ::Autonomos::Mandate.create(
              goal_name: goal_name,
              goal_hash: goal_hash,
              max_cycles: max_cycles,
              checkpoint_every: checkpoint_every,
              risk_budget: risk_budget
            )

            # Build session invocation context from config blacklist
            config = load_config
            ctx = build_session_context(config, mandate[:mandate_id])

            # Create session
            session_id = "agent_#{Time.now.strftime('%Y%m%d_%H%M%S')}_#{SecureRandom.hex(3)}"
            session = Session.new(
              session_id: session_id,
              mandate_id: mandate[:mandate_id],
              goal_name: goal_name,
              invocation_context: ctx,
              config: config,
              autonomous: autonomous
            )

            # OBSERVE: reuse pre-resolved observation (avoids duplicate L2/L1 lookups)
            observation = pre_obs

            session.save_observation(observation)
            session.update_state('observed')
            session.save

            result = {
              'status' => 'ok',
              'session_id' => session_id,
              'mandate_id' => mandate[:mandate_id],
              'state' => 'observed',
              'autonomous' => autonomous,
              'observation' => observation
            }

            # Advisory: suggest permission mode for autonomous operation
            result['permission_advisory'] = permission_advisory_message

            text_content(JSON.generate(result))
          rescue ArgumentError => e
            text_content(JSON.generate({ 'status' => 'error', 'error' => e.message }))
          rescue StandardError => e
            text_content(JSON.generate({ 'status' => 'error', 'error' => "#{e.class}: #{e.message}" }))
          end

          private

          def load_config
            config_path = File.join(__dir__, '..', 'config', 'agent.yml')
            if File.exist?(config_path)
              YAML.safe_load(File.read(config_path)) || {}
            else
              { 'phases' => {}, 'tool_blacklist' => %w[agent_* autonomos_*] }
            end
          end

          def build_session_context(config, mandate_id)
            KairosMcp::InvocationContext.new(
              blacklist: config['tool_blacklist'] || %w[agent_* autonomos_*],
              mandate_id: mandate_id
            )
          end

          def permission_advisory_message
            <<~MSG.strip
              This agent session will execute tools autonomously.
              For smoother operation, consider adjusting your permission mode:

              1. Normal (default) — ask for each command. Safest, but interrupts flow.
              2. Auto-allow — pre-approved commands only. Balanced.
                 Configure in .claude/settings.local.json permissions.allow array.
              3. Auto-accept — allow everything. Fastest for trusted tasks.
                 Run /permissions and select auto mode, or start with --dangerously-skip-permissions.

              Recommendation: For implementation + multi-LLM review workflows, auto-allow
              with ruby/codex/agent commands pre-approved provides the best balance.
            MSG
          end

          def run_observe(goal_name)
            # Gather observation data without LLM
            observation = { 'goal_name' => goal_name, 'timestamp' => Time.now.iso8601 }

            # Load environment data via Autonomos::Ooda
            if defined?(::Autonomos::Ooda)
              begin
                helper = Class.new { include ::Autonomos::Ooda }.new
                ooda_obs = helper.observe(goal_name)
                observation.merge!(ooda_obs.transform_keys(&:to_s)) if ooda_obs.is_a?(Hash)
              rescue StandardError => e
                observation['ooda_error'] = e.message
              end
            end

            # Load goal content from L2/L1 so Orient has context to analyze
            begin
              if defined?(::Autonomos::Ooda)
                helper = Class.new { include ::Autonomos::Ooda }.new
                goal = helper.load_goal(goal_name)
              else
                goal = load_goal_fallback(goal_name)
              end
              if goal && goal[:found]
                observation['goal_content'] = goal[:content]
                observation['goal_source'] = goal[:source].to_s
              end
            rescue StandardError => e
              observation['goal_load_error'] = e.message
            end

            observation
          end

          def load_goal_fallback(goal_name)
            # Direct L2/L1 lookup when Autonomos::Ooda is unavailable
            if defined?(KairosMcp::ContextManager)
              ctx_mgr = KairosMcp::ContextManager.new
              ctx_mgr.list_sessions.each do |session|
                entry = ctx_mgr.get_context(session[:session_id], goal_name)
                if entry && entry.respond_to?(:content) && entry.content && !entry.content.strip.empty?
                  return { content: entry.content, found: true, source: :l2 }
                end
              end
            end
            if defined?(KairosMcp::KnowledgeProvider)
              provider = KairosMcp::KnowledgeProvider.new(nil)
              result = provider.get(goal_name)
              if result && result[:content] && !result[:content].strip.empty?
                return { content: result[:content], found: true, source: :l1 }
              end
            end
            { content: nil, found: false }
          rescue StandardError
            { content: nil, found: false }
          end
        end
      end
    end
  end
end
