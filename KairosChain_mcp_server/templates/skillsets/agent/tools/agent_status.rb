# frozen_string_literal: true

require 'json'
require_relative '../lib/agent'

module KairosMcp
  module SkillSets
    module Agent
      module Tools
        class AgentStatus < KairosMcp::Tools::BaseTool
          def name
            'agent_status'
          end

          def description
            "Show a run's position, next instruction, open operator items and phases; with report_material, the journal summary the report subagent builds the layered deck from. Without run_id: adopted policy, available policies and runs."
          end

          def category
            :agent
          end

          def usecase_tags
            %w[agent run autonomous]
          end

          def related_tools
            %w[agent_start agent_status agent_advance agent_items agent_finish agent_stop]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                run_id: { type: 'string', description: 'Run id.' },
                report_material: { type: 'boolean', description: 'Include the material for the report deck.' }
              },
              required: []
            }
          end

          def call(arguments)
            text_content(JSON.generate(Boot.service(self).status(arguments)))
          rescue StandardError => e
            text_content(JSON.generate('status' => 'error', 'error' => "#{e.class}: #{e.message[0, 300]}"))
          end
        end
      end
    end
  end
end
