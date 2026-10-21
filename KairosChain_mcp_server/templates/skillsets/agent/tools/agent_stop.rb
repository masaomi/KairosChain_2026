# frozen_string_literal: true

require 'json'
require_relative '../lib/agent'

module KairosMcp
  module SkillSets
    module Agent
      module Tools
        class AgentStop < KairosMcp::Tools::BaseTool
          def name
            'agent_stop'
          end

          def description
            'Stop a run. It still ends with a report: build the deck, then call agent_finish.'
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
                reason: { type: 'string', description: 'Why.' }
              },
              required: ['run_id']
            }
          end

          def call(arguments)
            text_content(JSON.generate(Boot.service(self).stop(arguments)))
          rescue StandardError => e
            text_content(JSON.generate('status' => 'error', 'error' => "#{e.class}: #{e.message[0, 300]}"))
          end
        end
      end
    end
  end
end
