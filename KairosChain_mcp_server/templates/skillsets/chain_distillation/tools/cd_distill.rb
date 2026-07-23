# frozen_string_literal: true

require 'json'
require_relative '../lib/chain_distillation/distiller'

module KairosMcp
  module SkillSets
    module ChainDistillation
      module Tools
        # Certified distillation (design v0.5 slice 1): designation ->
        # guard-judged distillate crossing -> CD-6 record -> certificate
        # finalization -> guard-judged certificate crossing -> release.
        class CdDistill < KairosMcp::Tools::BaseTool
          def name
            'cd_distill'
          end

          def description
            'Distill designated source-chain records into a distillate with a provenance certificate (CD-1..CD-6). Requires an active confidentiality-guard regime; declines otherwise.'
          end

          def category
            :chain
          end

          def input_schema
            {
              type: 'object',
              properties: {
                designation: {
                  type: 'array', items: { type: 'integer' },
                  description: 'Source-chain record indices the distillation names as input (closed-world)'
                },
                distillate: {
                  type: 'object',
                  description: 'The distilled SkillSet content to package and release'
                },
                attester_id: {
                  type: 'string',
                  description: 'Attester identifier for the carrier envelope (optional; defaults to chain_distillation)'
                }
              },
              required: %w[designation distillate]
            }
          end

          def call(arguments)
            args = arguments.is_a?(Hash) ? arguments : {}
            result = Distiller.distill(
              designation: args['designation'],
              distillate: args['distillate'],
              safety: @safety,
              attester_id: args['attester_id']
            )
            text_content(JSON.generate(
              status: 'distilled',
              certificate: result[:certificate],
              record_block_index: result[:record_block_index]
            ))
          rescue Distiller::Declined => e
            text_content(e.message)
          end
        end
      end
    end
  end
end
