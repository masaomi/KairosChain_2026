# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module SkillsetExchange
      module Tools
        class SkillsetAcquire < KairosMcp::Tools::BaseTool
          def name
            'skillset_acquire'
          end

          def description
            'Acquire a SkillSet from a Meeting Place and install it locally (Phase 3 -- not yet implemented).'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting acquire skillset exchange install]
          end

          def related_tools
            %w[skillset_browse skillset_deposit meeting_connect]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                name: { type: 'string', description: 'SkillSet name to acquire' },
                depositor_id: { type: 'string', description: 'Optional depositor ID for disambiguation' },
                force: { type: 'boolean', description: 'Force re-install over existing (default: false)' }
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
