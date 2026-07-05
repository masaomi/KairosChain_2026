# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        # ACT-4: when the policy proposed a context and the human declined, append a
        # content-free decision record to the operational log, keyed by subject id. An
        # approval writes NO decision record — it is evidenced by the content-attestation
        # entry it produced (via l2_attestation_commit), not duplicated here.
        #
        # A decline is not permanent in effect: an evolved criterion may re-propose, and
        # that is a fresh decision, not a reversal. The record binds no content and no
        # artifact (LED-1), so a declined context may still be freely edited or die.
        class L2AttestationDecline < KairosMcp::Tools::BaseTool
          include ::Synoptis::ToolHelpers

          def name
            'l2_attestation_decline'
          end

          def description
            'Record that a proposed L2 context attestation was declined by the human. Appends a content-free decision record to the operational log (ACT-4). Does not constrain the context.'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[attestation decline constitutive l2 audit]
          end

          def related_tools
            %w[l2_attestation_scan l2_attestation_commit]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                subject: { type: 'string', description: 'The proposed L2 context that was declined, as a context:// URI.' }
              },
              required: %w[subject]
            }
          end

          def call(arguments)
            subject = arguments['subject']
            unless subject
              return text_content(JSON.pretty_generate({ status: 'error', message: 'subject is required' }))
            end

            constitutive_chain.append_decline(subject_id: subject)

            text_content(JSON.pretty_generate({
              status: 'declined',
              subject: subject,
              note: 'A content-free decline was logged. The context is unchanged and may still be edited or allowed to die.'
            }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ status: 'error', message: e.message }))
          end
        end
      end
    end
  end
end
