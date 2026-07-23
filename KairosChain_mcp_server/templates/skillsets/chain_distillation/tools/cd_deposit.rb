# frozen_string_literal: true

require 'json'
require_relative '../lib/chain_distillation/depositor'
require_relative '../lib/chain_distillation/carrier_wiring'

module KairosMcp
  module SkillSets
    module ChainDistillation
      module Tools
        # Certified-distillate deposit (design slice 2 FROZEN, CD-7..CD-11):
        # admission (binding + revoked-at-judgment where source-local) ->
        # guard-judged cd_deposit crossing -> SkillSet-layout package with
        # certificate.json -> exchange delegation (consumed unchanged) ->
        # carrier exposure marker.
        class CdDeposit < KairosMcp::Tools::BaseTool
          def name
            'cd_deposit'
          end

          def description
            'Deposit a certified distillate through the exchange (CD-7..CD-11). Guard-judged outward crossing; declines without an active regime, on binding mismatch, or on a locally revoked certificate.'
          end

          def category
            :chain
          end

          def related_tools
            %w[cd_distill cd_verify cd_revoke skillset_deposit skillset_withdraw]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                certificate: { type: 'object', description: 'The provenance certificate issued by cd_distill' },
                distillate_json: { type: 'string', description: 'Canonical distillate content (as returned by cd_distill)' },
                skillset_name: { type: 'string', description: 'Package name for the distributed SkillSet (lowercase snake_case)' },
                description: { type: 'string', description: 'Optional listing description' }
              },
              required: %w[certificate distillate_json skillset_name]
            }
          end

          def call(arguments)
            args = arguments.is_a?(Hash) ? arguments : {}
            # No wiring here: issuance-side wiring belongs to cd_distill,
            # and admission must be free of global side effects (impl
            # review R3 — a pre-admission wire! mutated the carrier seam
            # and created registry directories before any verdict). The
            # Depositor consults the carrier registry read-only until the
            # crossing approves.
            result = Depositor.deposit(
              certificate: args['certificate'],
              distillate_json: args['distillate_json'].to_s,
              skillset_name: args['skillset_name'],
              description: args['description'],
              safety: @safety
            )
            text_content(JSON.generate(result))
          rescue Distiller::Declined => e
            text_content(e.message)
          end
        end
      end
    end
  end
end
