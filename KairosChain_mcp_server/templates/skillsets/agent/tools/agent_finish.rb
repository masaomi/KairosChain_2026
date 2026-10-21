# frozen_string_literal: true

require 'json'
require_relative '../lib/agent'

module KairosMcp
  module SkillSets
    module Agent
      module Tools
        class AgentFinish < KairosMcp::Tools::BaseTool
          def name
            'agent_finish'
          end

          def description
            "Finish a run: requires every phase ended by its check or closure (or the run ended), and the layered-deck report at log/agent_runs/<run_id>/deck.html built by a subagent and complete against the journal. Records the run's end on the chain and opens the merge item."
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
                run_id: { type: 'string', description: 'Run id.' }
              },
              required: ['run_id']
            }
          end

          def call(arguments)
            text_content(JSON.generate(Boot.service(self).finish(arguments)))
          rescue StandardError => e
            text_content(JSON.generate('status' => 'error', 'error' => "#{e.class}: #{e.message[0, 300]}"))
          end
        end
      end
    end
  end
end
