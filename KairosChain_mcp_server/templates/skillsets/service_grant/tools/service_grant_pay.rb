# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module ServiceGrantTools
      class ServiceGrantPay < KairosMcp::Tools::BaseTool
        def name
          'service_grant_pay'
        end

        def description
          'Process a payment attestation and upgrade the payer\'s plan'
        end

        def input_schema
          {
            type: 'object',
            properties: {
              proof_envelope: {
                type: 'object',
                description: 'Full Synoptis ProofEnvelope JSON as transmitted by Payment Agent'
              }
            },
            required: %w[proof_envelope]
          }
        end

        def call(args)
          unless ServiceGrant.payment_verifier
            return format_result({ error: 'service_unavailable',
                                   message: 'Payment verification not configured' })
          end

          result = ServiceGrant.payment_verifier.verify_and_upgrade(args['proof_envelope'])
          format_result(result)
        rescue ServiceGrant::InvalidAttestationError => e
          log_payment_error(e, args['proof_envelope'])
          format_result({ error: 'invalid_attestation', message: safe_error_message(e) })
        rescue ServiceGrant::PlanNotFoundError => e
          format_result({ error: 'plan_not_found', message: safe_error_message(e) })
        rescue ServiceGrant::ConfigValidationError
          format_result({ error: 'service_unavailable', message: 'Payment verification unavailable' })
        end

        private

        def safe_error_message(error)
          @safety&.current_user ? 'Payment verification failed' : error.message
        end

        def log_payment_error(error, envelope)
          proof_id = envelope&.dig('proof_id') || 'unknown'
          warn "[ServiceGrant] Payment verification failed: #{error.message} (proof_id: #{proof_id})"
        end
      end
    end
  end
end
