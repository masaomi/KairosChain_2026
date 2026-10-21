# frozen_string_literal: true

require 'json'
require_relative '../lib/agent'

module KairosMcp
  module SkillSets
    module Agent
      module Tools
        class AgentItems < KairosMcp::Tools::BaseTool
          def name
            'agent_items'
          end

          def description
            "Operator items and decisions of a run. Actions: list; alert (raise a hazard — key exposure, chain corruption, data loss, wrong published output — the stand-in rules on it; a fatal one ends the run); adopt_policy (after the operator typed 'adopt policy <name> <8 hex>'); confirm / correct / resolve (only after the operator's own typed words name the decision or item id; what a phase waits on changes only with a decision read in those words: freeze | more_rounds | review_whole | accept_test_change | accept_failing | restore_test_command | send_back)."
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
                action: { type: 'string', description: 'list | alert | adopt_policy | confirm | correct | resolve' },
                ref: { type: 'string', description: 'Decision (D#) or item (I#) id for confirm/correct/resolve.' },
                text: { type: 'string', description: 'Hazard text for alert.' },
                policy: { type: 'string', description: 'Policy name for adopt_policy.' },
                decision: { type: 'string', description: 'freeze (end a review or check left open; its open P0s are carried) | more_rounds (more rounds for that review) | review_whole (a diff above the size limit) | accept_test_change | accept_failing (a test failing on the base commit too) | restore_test_command (a plan_parameters item) | send_back (a provisional closure). The operator\'s words must say it.' },
                rounds: { type: 'integer', description: 'For decision more_rounds: how many more rounds.' }
              },
              required: []
            }
          end

          def call(arguments)
            text_content(JSON.generate(Boot.service(self).items(arguments)))
          rescue StandardError => e
            text_content(JSON.generate('status' => 'error', 'error' => "#{e.class}: #{e.message[0, 300]}"))
          end
        end
      end
    end
  end
end
