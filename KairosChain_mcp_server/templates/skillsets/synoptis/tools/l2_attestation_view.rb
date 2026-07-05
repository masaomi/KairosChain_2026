# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        # Read-only: the current fold of a subject's attestation trajectory (LED-2b, §11).
        # Returns the status (none / attested / withdrawn), the current head entry, and the
        # full append-only history. Writes nothing.
        class L2AttestationView < KairosMcp::Tools::BaseTool
          include ::Synoptis::ToolHelpers

          def name
            'l2_attestation_view'
          end

          def description
            'Show the current constitutive-attestation state of an L2 subject: status (none/attested/withdrawn), the current head entry, and the full append-only history (first attestation, supersessions, withdrawals). Read-only.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[attestation view history constitutive l2 audit]
          end

          def related_tools
            %w[l2_attestation_commit l2_attestation_revoke l2_attestation_scan]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                subject: { type: 'string', description: 'The L2 context to inspect, as a context:// URI.' }
              },
              required: %w[subject]
            }
          end

          def call(arguments)
            subject = arguments['subject']
            unless subject
              return text_content(JSON.pretty_generate({ status: 'error', message: 'subject is required' }))
            end

            state = constitutive_chain.current_state(subject)
            text_content(JSON.pretty_generate({
              subject: subject,
              status: state[:status],
              head: state[:head],
              history_length: state[:history].length,
              history: state[:history]
            }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ status: 'error', message: e.message }))
          end
        end
      end
    end
  end
end
