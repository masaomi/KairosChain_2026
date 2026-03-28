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

            # Create mandate via Autonomos
            goal_hash = Digest::SHA256.hexdigest(goal_name)[0..15]
            mandate = Autonomos::Mandate.create(
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
              config: config
            )

            # OBSERVE (no LLM — direct Ruby)
            observation = run_observe(goal_name)

            session.update_state('observed')
            session.save

            text_content(JSON.generate({
              'status' => 'ok',
              'session_id' => session_id,
              'mandate_id' => mandate[:mandate_id],
              'state' => 'observed',
              'observation' => observation
            }))
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

          def run_observe(goal_name)
            # Gather observation data without LLM
            observation = { 'goal_name' => goal_name, 'timestamp' => Time.now.iso8601 }

            # Try to load goal from L2/L1
            if defined?(Autonomos::Ooda)
              begin
                helper = Class.new { include Autonomos::Ooda }.new
                ooda_obs = helper.observe(goal_name)
                observation.merge!(ooda_obs.transform_keys(&:to_s)) if ooda_obs.is_a?(Hash)
              rescue StandardError => e
                observation['ooda_error'] = e.message
              end
            end

            observation
          end
        end
      end
    end
  end
end
