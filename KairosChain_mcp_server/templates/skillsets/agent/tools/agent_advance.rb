# frozen_string_literal: true

require 'json'
require_relative '../lib/agent'

module KairosMcp
  module SkillSets
    module Agent
      module Tools
        class AgentAdvance < KairosMcp::Tools::BaseTool
          def name
            'agent_advance'
          end

          def description
            "Advance the current phase: the SkillSet checks a produced design, re-runs the pinned tests itself (confined), or dispatches/collects a review round and has the stand-in label the seats' findings. Call when the phase's work is ready; call again to collect a running review."
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
                phase: { type: 'string', description: 'The current phase name (optional).' }
              },
              required: ['run_id']
            }
          end

          def call(arguments)
            text_content(JSON.generate(Boot.service(self).advance(arguments)))
          rescue StandardError => e
            text_content(JSON.generate('status' => 'error', 'error' => "#{e.class}: #{e.message[0, 300]}"))
          end
        end
      end
    end
  end
end
