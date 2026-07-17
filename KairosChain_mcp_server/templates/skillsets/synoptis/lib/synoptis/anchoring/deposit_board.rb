# frozen_string_literal: true

require_relative 'log'
require_relative 'write_path'
require_relative 'containment'
require 'digest'
require 'json'
require 'fileutils'

module Synoptis
  module Anchoring
    # The unified deposit board layer (BRD-1/3/4; unified_deposit_board_design_v0.3).
    #
    # An anchor is one point on the deposit spectrum: a **content-by-reference**
    # deposit — the board holds only a digest and a locator, the bytes live in
    # Zenodo (or an opt-in origin). A skill is the other point (content-by-value);
    # that path is unchanged and not implemented here. This layer wraps the ANC-1
    # anchor Log as the by-reference kind's storage (no double-storage — the
    # anchor entry_hash IS the deposit id) and adds two board-level surfaces:
    #
    #   - a uniform deposit *record view* over the anchor entry (BRD-1); the
    #     content-availability kind is by_reference, fixed at deposit and immutable
    #     (there is no method to change a deposit's kind — a change of kind is a
    #     new deposit);
    #   - an append-only *attestation* registry (BRD-3): bounded, content-inert,
    #     signed peer claims about a deposit. The board never verifies a deposit on
    #     an attestation's behalf and never aggregates attestations into a score,
    #     rank, or trust signal — there is deliberately no such method.
    #
    # Retrieval (BRD-4) is best-effort and never load-bearing: a deposit's proof
    # value (digest + moment + attestations) is self-contained and survives a
    # dead, slow, or absent pointer.
    class DepositBoard
      class Unauthenticated < WritePath::Unauthenticated; end
      class UnauthorizedAttestationWithdrawal < StandardError; end

      AVAILABILITY_KIND = :by_reference
      EMPTY = [].freeze

      # A uniform deposit record view (BRD-1). Frozen: the availability kind is
      # not mutable through this object.
      Deposit = Struct.new(
        :deposit_id, :availability_kind, :depositor, :digest, :digest_algorithm,
        :canonicalization, :retrieval_pointer, :discovery_metadata, :moment,
        :withdrawn, :provenance, :attestations,
        keyword_init: true
      )

      def initialize(log:, attestation_store_path:, budget: nil)
        @log = log
        @operator_id = log.operator_id
        @budget = budget
        @store_path = attestation_store_path
        @mutex = Mutex.new
        @attestations = []
        @by_id = {}
        @for_deposit = Hash.new { |h, k| h[k] = [] }
        @withdrawals_for = Hash.new { |h, k| h[k] = [] }
        load_store
      end

      # Create a content-by-reference deposit (BRD-1). The bytes are never taken;
      # only the digest and an optional safe-scheme retrieval pointer (BRD-4).
      # The depositor is bound to the authenticated principal (ANC-5).
      def deposit_by_reference(principal:, digest:, source_id:, anchor_type: 'generic',
                               retrieval_pointer: nil, discovery_metadata: {}, moment: nil)
        writer = WritePath.new(log: @log, principal: principal, budget: @budget)
        entry = writer.deposit(
          digest: digest,
          anchor_type: anchor_type,
          source_id: source_id,
          external_reference: retrieval_pointer,
          metadata: discovery_metadata,
          moment: moment
        )
        get(entry.entry_hash)
      end

      # Uniform record view over a deposit id (the anchor entry_hash).
      def get(deposit_id)
        entry = @log.get(deposit_id.to_s)
        return nil unless entry && entry.anchor?

        view = @log.view(entry.entry_hash)
        withdrawn = view['withdrawn']
        body = view['body']
        Deposit.new(
          deposit_id: entry.entry_hash,
          availability_kind: AVAILABILITY_KIND,
          depositor: entry.depositor,
          digest: entry.digest,
          digest_algorithm: body['digest_algorithm'],
          canonicalization: body['canonicalization'],
          # BRD-4: pointer is suppressed once the deposit is withdrawn (ANC-1),
          # but the proof value below does not depend on it.
          retrieval_pointer: withdrawn ? nil : body['external_reference'],
          discovery_metadata: withdrawn ? nil : body['metadata'],
          moment: body['moment'],
          withdrawn: withdrawn,
          provenance: [{ 'event' => 'deposited', 'entry_hash' => entry.entry_hash,
                         'digest' => entry.digest, 'depositor' => entry.depositor,
                         'moment' => body['moment'], 'position' => entry.position }],
          attestations: attestations_for(entry.entry_hash)
        ).freeze
      end

      # Discovery: every by-reference deposit, uniform (BRD-1). No ranking.
      def list
        @log.entries.select(&:anchor?).map { |e| get(e.entry_hash) }
      end

      # BRD-3: append a bounded, content-inert, signed peer claim about a deposit.
      # Any authenticated peer may attest to any deposit (unilateral). The claim is
      # bound to a specific digest so a later content change cannot silently make
      # it vouch for different bytes (correspondence-staleness, §11).
      def attest(deposit_id:, principal:, claim_type:, bound_digest: nil,
                 reference: nil, note: nil, moment: nil)
        require_authenticated!(principal)
        deposit_id = deposit_id.to_s
        entry = @log.get(deposit_id)
        raise ArgumentError, "Unknown deposit: #{deposit_id}" unless entry && entry.anchor?

        bound = Entry.normalize_digest(bound_digest || entry.digest)
        # The claim must be bound to THIS deposit's digest (correspondence-
        # staleness, §11): a caller-supplied bound_digest that names other bytes
        # would let an attester assert correspondence for a foreign digest.
        if bound != entry.digest
          raise Containment::ContainmentError.new(:attestation_digest_mismatch,
                                                  'bound_digest must equal the deposit digest')
        end
        Containment.validate_attestation!(claim_type: claim_type, note: note,
                                          reference: reference, bound_digest: bound)

        # ANC-9 / BRD-3: attestation writes share the availability budget.
        budgeted(principal.peer_id) do
        @mutex.synchronize do
          record = {
            'kind' => 'attestation',
            'deposit_id' => deposit_id,
            'attester' => principal.peer_id.to_s,
            'claim_type' => claim_type.to_s,
            'bound_digest' => bound,
            'reference' => reference,
            'note' => note,
            'moment' => moment || Time.now.utc.iso8601
          }
          record['attestation_id'] = content_id(record)
          commit(record)
        end
        end
      end

      # Raw attestations on a deposit (BRD-3: NO aggregation, NO score). A
      # withdrawn attestation is returned marked withdrawn, not removed.
      # Synchronized: writers mutate the indices under @mutex, so reads must too.
      def attestations_for(deposit_id)
        @mutex.synchronize { attestations_for_unlocked(deposit_id) }
      end

      # BRD-3 append-only withdrawal (mirrors ANC-1): authority is the attester or
      # the operator; anyone else is rejected at write time.
      def withdraw_attestation(attestation_id:, principal:, reason: nil, moment: nil)
        require_authenticated!(principal)
        Containment.validate_inert_text!(reason, field: 'withdrawal reason',
                                                 max: Containment::MAX_REASON_LENGTH)
        attestation_id = attestation_id.to_s
        budgeted(principal.peer_id) do
        @mutex.synchronize do
          target = @by_id[attestation_id]
          raise ArgumentError, "Unknown attestation: #{attestation_id}" unless target

          withdrawer = principal.peer_id.to_s
          authorized = withdrawer == target['attester'] || (@operator_id && withdrawer == @operator_id)
          unless authorized
            raise UnauthorizedAttestationWithdrawal,
                  "#{withdrawer} may not withdraw attestation #{attestation_id}"
          end

          record = {
            'kind' => 'withdrawal',
            'target' => attestation_id,
            'withdrawer' => withdrawer,
            'reason' => reason,
            'moment' => moment || Time.now.utc.iso8601
          }
          record['attestation_id'] = content_id(record)
          commit(record)
        end
        end
      end

      private

      def attestations_for_unlocked(deposit_id)
        deposit_id = deposit_id.to_s
        @for_deposit.fetch(deposit_id, EMPTY).map do |i|
          rec = @attestations[i].dup
          rec['withdrawn'] = !@withdrawals_for.fetch(rec['attestation_id'], EMPTY).empty?
          rec
        end
      end

      # ANC-9: reserve budget before the write; refund on failure.
      def budgeted(identity)
        return yield unless @budget

        @budget.charge!(identity)
        begin
          yield
        rescue StandardError
          @budget.refund!(identity)
          raise
        end
      end

      def require_authenticated!(principal)
        return if principal.respond_to?(:verified?) && principal.verified?

        raise Unauthenticated, 'attestation requires a verified Meeting Place peer identity'
      end

      # Mutate memory, then persist; roll the append back if the durable write
      # fails, so a caller told the write failed cannot have it resurrected.
      def commit(record)
        append(record)
        begin
          save_store
        rescue StandardError
          unappend_last!(record)
          raise
        end
        record
      end

      def append(record)
        i = @attestations.size
        @attestations << record
        @by_id[record['attestation_id']] = record
        if record['kind'] == 'attestation'
          @for_deposit[record['deposit_id']] << i
        elsif record['kind'] == 'withdrawal'
          @withdrawals_for[record['target']] << i
        end
      end

      def unappend_last!(record)
        @attestations.pop
        @by_id.delete(record['attestation_id'])
        if record['kind'] == 'attestation'
          @for_deposit[record['deposit_id']].pop
        elsif record['kind'] == 'withdrawal'
          @withdrawals_for[record['target']].pop
        end
      end

      def content_id(record)
        Digest::SHA256.hexdigest(Entry.canonical_json(record.reject { |k, _| k == 'attestation_id' }))
      end

      def load_store
        return unless File.exist?(@store_path)

        raw = JSON.parse(File.read(@store_path))
        (raw['attestations'] || []).each { |rec| append(rec) }
      rescue StandardError
        # Corrupt store: degrade to empty rather than crash on load; reset every
        # index so a partial load leaves no dangling references.
        @attestations = []
        @by_id = {}
        @for_deposit = Hash.new { |h, k| h[k] = [] }
        @withdrawals_for = Hash.new { |h, k| h[k] = [] }
      end

      def save_store
        FileUtils.mkdir_p(File.dirname(@store_path))
        data = {
          'metadata' => { 'updated_at' => Time.now.utc.iso8601, 'count' => @attestations.size },
          'attestations' => @attestations
        }
        temp = "#{@store_path}.tmp"
        File.write(temp, JSON.pretty_generate(data))
        File.rename(temp, @store_path)
      end
    end
  end
end
