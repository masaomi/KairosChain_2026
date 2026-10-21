# frozen_string_literal: true

require 'digest'

require 'json'
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

        # agent 1.0 (design v0.5.1): the gates are the adopted policy (the
        # operator's mandate) and the run guard's hooks, not agent.yml.
        def inspect_agent_gates
          agent_dir = File.join(::KairosMcp.skillsets_dir, 'agent')
          return { present: false, status: 'agent_skillset_not_installed' } unless File.directory?(agent_dir)

          meta = JSON.parse(File.read(File.join(agent_dir, 'skillset.json'))) rescue {}
          adoptions = File.join(::KairosMcp.storage_dir, 'agent', 'policy_adoptions.jsonl')
          last = File.exist?(adoptions) ? (JSON.parse(File.readlines(adoptions).last.to_s) rescue nil) : nil
          # Adopted only while a policy file's bytes still match the adopted
          # digest (as agent_start requires); an edited file is not adopted.
          digests = Dir.glob(File.join(agent_dir, 'config', 'policies', '*.rb')).map { |f| Digest::SHA256.file(f).hexdigest }
          current = last && digests.include?(last['digest'].to_s)
          {
            present: true,
            version: meta['version'],
            adopted_policy: current ? "#{last['name']} #{last['digest'].to_s[0, 12]}" : nil,
            adoption_stale: last && !current ? "#{last['name']} #{last['digest'].to_s[0, 12]} (file changed since adoption)" : nil,
            run_guard_hooks: File.exist?(File.join(agent_dir, 'plugin', 'hooks.json')),
            # 0.x files outside the instance that an upgrade does not remove; a
            # personal skill named agent can shadow the project's 1.0 SKILL.md.
            legacy_user_files: [File.expand_path('~/.claude/skills/agent/SKILL.md'),
                                File.expand_path('~/.claude/agents/agent-monitor.md')]
                               .select { |f| File.exist?(f) && File.read(f).match?(/OODA|agent_cycle|cognitive_loop|agent-monitor|0\.\d+\.\d+/) },
            legacy_config_present: File.exist?(File.join(agent_dir, 'config', 'agent.yml'))
          }
        rescue StandardError => e
          { present: false, error: e.message }
        end

        def inspect_blockchain_health
          chain = ::KairosMcp::KairosChain::Chain.new
          blocks = chain.chain

          # block_count and last_recorded only carry meaning when the ledger's
          # state is :readable; the state itself is the load-bearing field.
          {
            state: chain.load_state,
            block_count: blocks.size,
            last_recorded: blocks.last&.timestamp&.iso8601,
            integrity: chain.valid?
          }
        rescue StandardError => e
          { state: :error, block_count: 0, integrity: false, error: e.message }
        end
      end
    end
  end
end
