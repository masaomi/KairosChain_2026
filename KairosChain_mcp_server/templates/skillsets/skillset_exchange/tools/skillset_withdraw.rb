# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module SkillsetExchange
      module Tools
        class SkillsetWithdraw < KairosMcp::Tools::BaseTool
          def name
            'skillset_withdraw'
          end

          def description
            'Withdraw a previously deposited SkillSet from a Meeting Place (Phase 3 -- not yet implemented).'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting withdraw skillset exchange remove]
          end

          def related_tools
            %w[skillset_deposit skillset_browse meeting_connect]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                name: { type: 'string', description: 'SkillSet name to withdraw' },
                reason: { type: 'string', description: 'Reason for withdrawal (recorded on chain)' }
              },
              required: ['name']
            }
          end

          def call(_arguments)
            text_content('Not yet implemented. Coming in Phase 3.')
          end
        end
      end
    end
  end
end
