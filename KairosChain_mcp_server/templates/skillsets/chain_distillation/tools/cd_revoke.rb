# frozen_string_literal: true

require 'json'
require_relative '../lib/chain_distillation/recorder'

module KairosMcp
  module SkillSets
    module ChainDistillation
      module Tools
        # Revocation as a recorded act (design v0.5 CD-6): keyed to the
        # certificate identity, effective across the entire source chain.
        # The chain record is the authoritative channel; carrier mirroring
        # is §8 wiring and never runs the other way.
        class CdRevoke < KairosMcp::Tools::BaseTool
          def name
            'cd_revoke'
          end

          def description
            'Revoke a chain-distillation certificate by identity (recorded on the source chain; chain-authoritative).'
          end

          def category
            :chain
          end

          def input_schema
            {
              type: 'object',
              properties: {
                certificate_identity: { type: 'string', description: 'The certificate identity to revoke' },
                reason: {
                  type: 'string',
                  enum: %w[superseded defective withdrawn other],
                  description: 'Recorded revocation reason (closed vocabulary — chain records carry identifiers, never free text)'
                }
              },
              required: %w[certificate_identity reason]
            }
          end

          def call(arguments)
            args = arguments.is_a?(Hash) ? arguments : {}
            identity = args['certificate_identity'].to_s
            return text_content(JSON.generate(status: 'error', error: 'certificate_identity required')) if identity.empty?
            result = Recorder.record_revocation(
              certificate_identity: identity,
              reason: args['reason'].to_s
            )
            text_content(JSON.generate(status: 'revoked', certificate_identity: identity,
                                       block_index: result[:block_index]))
          end
        end
      end
    end
  end
end
