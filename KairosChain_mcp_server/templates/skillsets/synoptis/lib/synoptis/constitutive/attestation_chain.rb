# frozen_string_literal: true

require 'time'

module Synoptis
  module Constitutive
    # Two dedicated append-only stores on Synoptis's FileRegistry chain machinery
    # (design v0.9, LED-5). Neither is the Meta Ledger:
    #
    #   - l2_attestation      content-attestation entries; human-approved (ACT-1)
    #   - l2_operational_log  trigger + decline records; telemetry, not approved (ACT-4/5)
    #
    # Both inherit FileRegistry's append-only + hash-chain (_prev_entry_hash) discipline
    # — the bank-ledger integrity model (LED-2a): lines are only ever appended, never
    # rewritten. The two stores are distinct files, so a judgment-bearing entry and a
    # telemetry record never share one line definition (the recurring taxonomy defect
    # the design closed via §Kinds).
    class AttestationChain
      LEDGER = :l2_attestation
      OPLOG  = :l2_operational_log

      def initialize(registry:)
        @registry = registry
      end

      # ACT-1: append an approved content-attestation entry to the ledger. A first
      # attestation carries no target_ref; a supersession carries the entry_id of the
      # entry it supersedes (LED-2b).
      def append_content_attestation(entry)
        @registry.append(LEDGER, entry.to_h)
      end

      # ACT-1: append an approved revocation-withdrawal entry to the ledger. It withdraws
      # the referenced target entry (§Kinds); it is itself append-only (LED-2), so the
      # withdrawal is recorded, not an erasure.
      def append_revocation_withdrawal(entry)
        @registry.append(LEDGER, entry.to_h)
      end

      def entries
        @registry.read(LEDGER)
      end

      def entries_for(subject_id)
        entries.select { |e| e[:subject_id] == subject_id }
      end

      # The current "head" of a subject: the fold (LED-2b, §11) over its entries'
      # target references. Walking in append order, a content-attestation (first or
      # supersession) becomes the head; a revocation-withdrawal that targets the current
      # head clears it. Returns the head entry hash, or nil if the subject has never been
      # attested or its latest attestation has been withdrawn.
      #
      # Ordering rule (fixed here per §11): a revocation-withdrawal only clears the head
      # when it targets the current head; a withdrawal of an already-superseded (non-head)
      # entry is recorded but does not change the head.
      def current_head(subject_id)
        head = nil
        entries_for(subject_id).each do |e|
          case e[:kind]
          when 'content_attestation'
            head = e
          when 'revocation_withdrawal'
            head = nil if head && e[:target_ref] == head[:entry_id]
          end
        end
        head
      end

      # A human-readable fold of a subject's trajectory: current status + full history.
      def current_state(subject_id)
        history = entries_for(subject_id)
        head = current_head(subject_id)
        status =
          if history.empty? then 'none'
          elsif head.nil? then 'withdrawn'
          else 'attested'
          end
        { subject_id: subject_id, status: status, head: head, history: history }
      end

      # ACT-5: telemetry that the criterion fired and surfaced N proposals. Subject-free
      # and content-free, so it neither indexes L2 (LED-4) nor records a per-context
      # verdict (ACT-4). `source` names which trigger point fired (manual /
      # orchestrator_session_end / session_end_hook), so the "at least one defined trigger
      # point" of ACT-5 is distinguishable in the operational log.
      def append_trigger(surfaced_count:, source: 'manual', moment: nil)
        @registry.append(OPLOG, {
          record: 'trigger',
          source: source,
          surfaced_count: surfaced_count,
          moment: moment || Time.now.utc.iso8601
        })
      end

      # ACT-4: telemetry that a proposed subject was declined. Content-free, keyed by
      # subject id only. An approval writes NO decision record — it is evidenced by the
      # content-attestation entry it produced.
      def append_decline(subject_id:, moment: nil)
        @registry.append(OPLOG, {
          record: 'decision',
          decision: 'declined',
          subject_id: subject_id,
          moment: moment || Time.now.utc.iso8601
        })
      end

      def oplog
        @registry.read(OPLOG)
      end

      def verify_chain(type = LEDGER)
        @registry.verify_chain(type)
      end
    end
  end
end
