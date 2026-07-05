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

      # ACT-1: append an approved content-attestation entry to the ledger.
      def append_content_attestation(entry)
        @registry.append(LEDGER, entry.to_h)
      end

      def entries
        @registry.read(LEDGER)
      end

      # ACT-5: telemetry that the criterion fired and surfaced N proposals. Subject-free
      # and content-free, so it neither indexes L2 (LED-4) nor records a per-context
      # verdict (ACT-4).
      def append_trigger(surfaced_count:, moment: nil)
        @registry.append(OPLOG, {
          record: 'trigger',
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
