# frozen_string_literal: true

require 'json'
require_relative '../lib/chain_distillation/certificate'
require_relative '../lib/chain_distillation/distiller'

module KairosMcp
  module SkillSets
    module ChainDistillation
      module Tools
        # Verifier-side certificate check (design v0.5 CD-2/CD-6; slice-1
        # exercisable form of the §8 verifier toolset). With source-chain
        # access, grounding / revocation / predecessor-citation are
        # checked; without it, only the certificate-local checks run and
        # the trusted-status claims remain trusted, as disclosed.
        class CdVerify < KairosMcp::Tools::BaseTool
          def name
            'cd_verify'
          end

          def description
            'Verify a chain-distillation provenance certificate: vocabulary bound, status table, grounding against the cited CD-6 record, revocation, and predecessor-citation obligation.'
          end

          def category
            :chain
          end

          def input_schema
            {
              type: 'object',
              properties: {
                certificate: { type: 'object', description: 'The certificate to verify' },
                distillate_json: { type: 'string', description: 'Canonical distillate content (optional, enables the distillate commitment check)' },
                use_chain: { type: 'boolean', description: 'Check against the local source chain (default true)' }
              },
              required: %w[certificate]
            }
          end

          def call(arguments)
            args = arguments.is_a?(Hash) ? arguments : {}
            use_chain = args['use_chain'] != false
            result = Certificate.verify(
              args['certificate'],
              chain_entries: use_chain ? Distiller.chain_entries : nil,
              chain_hashes: use_chain ? Distiller.chain_block_hashes : nil,
              distillate_json: args['distillate_json']
            )
            text_content(JSON.generate(result))
          end
        end
      end
    end
  end
end
