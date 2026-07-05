# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        # ACT-1: appending a content-attestation entry requires human approval on every
        # path (the `approved: true` two-call pattern, workflow-level, no crypto — the
        # same posture L0/L1 use, LED-6).
        #
        # Slice 2 adds supersession + ACT-3 binding:
        #   - If the subject already has a live attestation (a current head), a new commit
        #     is a SUPERSESSION: it commits the head's entry_id as target_ref (LED-2b,
        #     §Kinds). The first attestation about a subject carries no target_ref.
        #   - ACT-3: approval binds the exact fields committed. The proposal (call without
        #     approved) returns the digest and the target it would supersede; the approving
        #     call should echo them back as expected_digest / expected_target_ref. If the
        #     live content changed (digest moved) or the head moved (a concurrent append)
        #     between proposal and approval, the append does NOT proceed silently — the
        #     mismatch surfaces and the human re-approves.
        class L2AttestationCommit < KairosMcp::Tools::BaseTool
          include ::Synoptis::ToolHelpers

          def name
            'l2_attestation_commit'
          end

          def description
            'Append one human-approved content-attestation for an L2 context to the constitutive attestation ledger. A re-attestation of an already-attested subject is a supersession (commits the superseded entry as target_ref). Requires approved: true; without it, returns the proposal and writes nothing (ACT-1). Echo expected_digest/expected_target_ref from the proposal to bind approval (ACT-3).'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[attestation commit supersession constitutive l2 approve audit]
          end

          def related_tools
            %w[l2_attestation_scan l2_attestation_decline l2_attestation_revoke l2_attestation_view]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                subject: { type: 'string', description: 'The L2 context to attest, as a context:// URI.' },
                approved: { type: 'boolean', description: 'Human approval. Must be true to append. Omitted/false returns the proposal without writing.' },
                expected_digest: { type: 'string', description: 'ACT-3: the digest approved (from the proposal). If it no longer matches the live content, the append is refused.' },
                expected_target_ref: { type: %w[string null], description: 'ACT-3: the entry_id the approval expects to supersede (from the proposal), or null for a first attestation. If the head moved, the append is refused.' }
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

            head = constitutive_chain.current_head(subject)
            target_ref = head && head[:entry_id]
            supersession = !target_ref.nil?

            unless arguments['approved'] == true
              return text_content(JSON.pretty_generate({
                status: 'pending_approval',
                subject: subject,
                is_supersession: supersession,
                target_ref: target_ref,
                content_state: state,
                note: supersession ?
                  'Re-call with approved: true, expected_digest, expected_target_ref to append a supersession of the current head. Nothing was written.' :
                  'Re-call with approved: true (echo expected_digest) to append the first attestation. Nothing was written.'
              }))
            end

            # ACT-3 binding: refuse to append silently if what was approved no longer holds.
            if arguments.key?('expected_digest') && arguments['expected_digest'] != state[:digest]
              return text_content(JSON.pretty_generate({
                status: 'digest_mismatch',
                subject: subject,
                approved_digest: arguments['expected_digest'],
                current_digest: state[:digest],
                note: 'The live content changed since approval. Re-approve the new state (a fresh entry).'
              }))
            end
            if arguments.key?('expected_target_ref') && arguments['expected_target_ref'] != target_ref
              return text_content(JSON.pretty_generate({
                status: 'target_moved',
                subject: subject,
                approved_target_ref: arguments['expected_target_ref'],
                current_target_ref: target_ref,
                note: 'The subject head moved since approval (a concurrent append). Re-approve against the current head.'
              }))
            end

            entry = ::Synoptis::Constitutive::ContentAttestationEntry.new(
              subject_id: subject,
              digest: state[:digest],
              digest_alg: state[:digest_alg],
              moment: Time.now.utc.iso8601,
              target_ref: target_ref
            )
            constitutive_chain.append_content_attestation(entry)

            text_content(JSON.pretty_generate({
              status: supersession ? 'superseded' : 'attested',
              is_supersession: supersession,
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
