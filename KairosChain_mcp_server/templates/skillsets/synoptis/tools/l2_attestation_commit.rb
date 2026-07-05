# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        # ACT-1: appending a content-attestation entry requires human approval on every
        # path. This is a workflow-level, human-in-the-loop confirmation (the `approved:
        # true` two-call pattern, as with skills_evolve / skills_audit archive) — the same
        # posture L0/L1 use, no cryptographic consent signal (LED-6).
        #
        #   - Called WITHOUT approved:true  -> returns the proposal (subject + content
        #     state), writes NOTHING.
        #   - Called WITH approved:true     -> appends exactly one content-attestation
        #     entry (subject_id, digest, moment) to the l2_attestation chain.
        #
        # The digest is SHA256 of the subject's actual persisted bytes at commit time
        # (LED-3); the moment is the append moment. (ACT-3 approval-to-digest binding and
        # supersession arrive with Slice 2; Slice 1 recomputes at commit and attests the
        # current bytes.)
        class L2AttestationCommit < KairosMcp::Tools::BaseTool
          include ::Synoptis::ToolHelpers

          def name
            'l2_attestation_commit'
          end

          def description
            'Append one human-approved content-attestation (subject, digest, moment) for an L2 context to the constitutive attestation ledger. Requires approved: true; without it, returns the proposal and writes nothing (ACT-1).'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[attestation commit constitutive l2 approve audit]
          end

          def related_tools
            %w[l2_attestation_scan l2_attestation_decline]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                subject: { type: 'string', description: 'The L2 context to attest, as a context:// URI (e.g. "context://<session>/<name>").' },
                approved: { type: 'boolean', description: 'Human approval. Must be true to append. Omitted/false returns the proposal without writing.' }
              },
              required: %w[subject]
            }
          end

          def call(arguments)
            subject = arguments['subject']
            unless subject
              return text_content(JSON.pretty_generate({ status: 'error', message: 'subject is required' }))
            end

            state = ::Synoptis::Constitutive::SubjectRef.content_state(subject, context_dir: context_root)
            unless state[:exists]
              return text_content(JSON.pretty_generate({
                status: 'error', message: 'Subject content does not exist; cannot attest absent content.', subject: subject
              }))
            end

            unless arguments['approved'] == true
              return text_content(JSON.pretty_generate({
                status: 'pending_approval',
                subject: subject,
                content_state: state,
                note: 'Re-call with approved: true to append this content-attestation. Nothing was written.'
              }))
            end

            entry = ::Synoptis::Constitutive::ContentAttestationEntry.new(
              subject_id: subject,
              digest: state[:digest],
              digest_alg: state[:digest_alg],
              moment: Time.now.utc.iso8601
            )
            constitutive_chain.append_content_attestation(entry)

            text_content(JSON.pretty_generate({
              status: 'attested',
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
