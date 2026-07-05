# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        # ACT-1 + LED-2b + §Kinds: withdraw a subject's current attestation by APPENDING a
        # revocation-withdrawal entry that references the head entry it withdraws. Never an
        # edit — the withdrawal is recorded, so "what was claimed, and that it was later
        # withdrawn" survives (LED-2).
        #
        # Like a content-attestation, appending a revocation-withdrawal requires human
        # approval (ACT-1): `approved: true` two-call. ACT-3: echo expected_target_ref from
        # the proposal so a concurrent append cannot silently redirect the withdrawal.
        class L2AttestationRevoke < KairosMcp::Tools::BaseTool
          include ::Synoptis::ToolHelpers

          def name
            'l2_attestation_revoke'
          end

          def description
            'Withdraw a subject\'s current constitutive attestation by appending a revocation-withdrawal entry (references the head it withdraws; commits no digest/content). Requires approved: true; without it, returns the proposal and writes nothing (ACT-1).'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[attestation revoke withdrawal constitutive l2 audit]
          end

          def related_tools
            %w[l2_attestation_commit l2_attestation_view l2_attestation_scan]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                subject: { type: 'string', description: 'The L2 context whose current attestation is to be withdrawn, as a context:// URI.' },
                approved: { type: 'boolean', description: 'Human approval. Must be true to append. Omitted/false returns the proposal without writing.' },
                expected_target_ref: { type: 'string', description: 'ACT-3: the entry_id the approval expects to withdraw (from the proposal). If the head moved, the append is refused.' }
              },
              required: %w[subject]
            }
          end

          def call(arguments)
            subject = arguments['subject']
            unless subject
              return text_content(JSON.pretty_generate({ status: 'error', message: 'subject is required' }))
            end

            head = constitutive_chain.current_head(subject)
            unless head
              return text_content(JSON.pretty_generate({
                status: 'error',
                subject: subject,
                message: 'Nothing to withdraw: the subject has no live attestation (never attested or already withdrawn).'
              }))
            end
            target_ref = head[:entry_id]

            unless arguments['approved'] == true
              return text_content(JSON.pretty_generate({
                status: 'pending_approval',
                subject: subject,
                target_ref: target_ref,
                note: 'Re-call with approved: true and expected_target_ref to append the withdrawal. Nothing was written.'
              }))
            end

            if arguments.key?('expected_target_ref') && arguments['expected_target_ref'] != target_ref
              return text_content(JSON.pretty_generate({
                status: 'target_moved',
                subject: subject,
                approved_target_ref: arguments['expected_target_ref'],
                current_target_ref: target_ref,
                note: 'The subject head moved since approval. Re-approve against the current head.'
              }))
            end

            entry = ::Synoptis::Constitutive::RevocationWithdrawalEntry.new(
              subject_id: subject,
              target_ref: target_ref,
              moment: Time.now.utc.iso8601
            )
            constitutive_chain.append_revocation_withdrawal(entry)

            text_content(JSON.pretty_generate({
              status: 'withdrawn',
              entry: entry.to_h,
              entry_hash: entry.entry_hash
            }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ status: 'error', message: e.message }))
          end
        end
      end
    end
  end
end
