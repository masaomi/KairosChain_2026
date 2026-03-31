# frozen_string_literal: true

require 'yaml'

module KairosMcp
  module SkillSets
    module Introspection
      # SafetyInspector reports on all active safety mechanisms across layers:
      # - L0: approval_workflow (Kairos DSL)
      # - RBAC: registered Safety policies
      # - Agent: autonomous mode safety gates from agent.yml
      # - Blockchain: chain integrity and block count
      class SafetyInspector
        # Inspect all safety layers and return a structured report.
        #
        # @return [Hash] :layers with 4 sub-keys
        def inspect_safety
          {
            layers: {
              l0_approval_workflow: inspect_approval_workflow,
              runtime_rbac: inspect_rbac_policies,
              agent_safety_gates: inspect_agent_gates,
              blockchain_recording: inspect_blockchain_health
            }
          }
        end

        private

        def inspect_approval_workflow
          if defined?(::Kairos) && ::Kairos.respond_to?(:skill)
            skill = ::Kairos.skill(:approval_workflow)
            {
              present: !skill.nil?,
              version: skill&.respond_to?(:version) ? skill.version : nil,
              status: skill ? 'active' : 'not_loaded'
            }
          else
            { present: false, status: 'kairos_not_available' }
          end
        end

        def inspect_rbac_policies
          names = ::KairosMcp::Safety.registered_policy_names
          {
            registered_count: names.size,
            policies: names,
            multiuser_active: names.include?('can_modify_l0')
          }
        end

        def inspect_agent_gates
          agent_config_path = File.join(::KairosMcp.skillsets_dir, 'agent', 'config', 'agent.yml')
          if File.exist?(agent_config_path)
            config = YAML.safe_load(File.read(agent_config_path)) || {}
            autonomous = config['autonomous'] || {}
            {
              present: true,
              max_cycles: autonomous['max_cycles'],
              timeout: autonomous['timeout'],
              max_llm_calls: autonomous['max_llm_calls'],
              risk_budget: autonomous['risk_budget']
            }
          else
            { present: false, status: 'agent_skillset_not_loaded' }
          end
        rescue StandardError => e
          { present: false, error: e.message }
        end

        def inspect_blockchain_health
          chain = ::KairosMcp::KairosChain::Chain.new
          blocks = chain.chain
          {
            block_count: blocks.size,
            last_recorded: blocks.last&.timestamp&.iso8601,
            integrity: chain.valid?
          }
        rescue StandardError => e
          { block_count: 0, integrity: false, error: e.message }
        end
      end
    end
  end
end
