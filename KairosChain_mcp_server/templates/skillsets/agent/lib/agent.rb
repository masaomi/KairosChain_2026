# frozen_string_literal: true

# Agent SkillSet 1.0 (design log/agent_skillset_rebuild_design_v0.5.1_20261020.md).
# The host session is the only body; this SkillSet supplies the plan, the
# stand-in, the guard (host hooks), the journal and the report check.
require_relative 'agent/service'

module KairosMcp
  module SkillSets
    module Agent
      # Builds the Service for an MCP tool call inside the server process.
      module Boot
        module_function

        def service(tool)
          data_dir = KairosMcp.data_dir
          paths = Paths.new(data_dir)
          invoke = lambda do |name, args|
            out = tool.invoke_tool(name, args)
            JSON.parse(Array(out).first[:text])
          end
          chain = lambda do |logs|
            KairosMcp::KairosChain::Chain.new.add_block(logs).index
          end
          stand_in_factory = lambda do |_run, policy|
            require File.join(data_dir, 'skillsets', 'llm_client', 'tools', 'llm_call')
            StandIn.new(policy: policy, instruction_mode: InstructionMode.load(data_dir),
                        llm: StandIn.default_llm(KairosMcp::SkillSets::LlmClient::Tools::LlmCall))
          end
          Service.new(paths: paths, project_root: File.dirname(File.expand_path(data_dir)),
                      stand_in_factory: stand_in_factory, invoke: invoke, chain: chain, home: Dir.home)
        end
      end
    end
  end
end
