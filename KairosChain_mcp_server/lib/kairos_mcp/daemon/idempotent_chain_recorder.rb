# frozen_string_literal: true

require 'json'
require 'fileutils'

module KairosMcp
  class Daemon
    # IdempotentChainRecorder — wraps chain_record with proposal_id-based
    # idempotency and retry logic.
    #
    # Design (P3.2 v0.2 §6.3-6.4, M7):
    #   - Uses proposal_id as externally-supplied idempotency key.
    #   - Tracks recorded proposal_ids in a local ledger file.
    #   - Retries up to MAX_RETRIES on failure, then pauses mandate.
    #   - Pending chain records survive daemon restart via ledger.
    class IdempotentChainRecorder
      MAX_RETRIES = 3

      # @param chain_tool [#call] callable: (args) → result (the actual chain_record)
      # @param ledger_path [String] path to the idempotency ledger
      # @param logger [Object, nil]
      def initialize(chain_tool:, ledger_path:, logger: nil)
        @chain_tool  = chain_tool
        @ledger_path = ledger_path
        @logger      = logger
        @recorded    = load_ledger
        @pending     = []  # Array of { proposal_id:, payload:, retries: }
        @exhausted   = []  # proposal_ids that exceeded MAX_RETRIES
      end

      # Record a code_edit to the blockchain. Idempotent by proposal_id.
      #
      # @param payload [Hash] must contain :proposal_id
      # @return [Hash] { status: 'recorded'|'duplicate'|'pending_retry'|'failed', ... }
      def record(payload)
        proposal_id = payload[:proposal_id] || payload['proposal_id']
        raise ArgumentError, 'proposal_id required' if proposal_id.to_s.empty?

        # Idempotency check
        if @recorded.include?(proposal_id)
          return { status: 'duplicate', proposal_id: proposal_id }
        end

        attempt_record(proposal_id, payload)
      end

      # Retry any pending records (call at cycle start or periodic tick).
      # @return [Array<Hash>] results for each retry attempt
      def retry_pending
        results = []
        remaining = []

        @pending.each do |entry|
          result = attempt_record(entry[:proposal_id], entry[:payload],
                                  retry_count: entry[:retries])
          results << result
          case result[:status]
          when 'pending_retry'
            remaining << entry.merge(retries: entry[:retries] + 1)
          when 'failed'
            @exhausted << entry[:proposal_id]
          end
        end

        @pending = remaining
        results
      end

      # Number of pending (failed) chain records.
      def pending_count
        @pending.size
      end

      # True if any record has exhausted retries.
      def has_failures?
        !@exhausted.empty?
      end

      private

      def attempt_record(proposal_id, payload, retry_count: 0)
        if retry_count >= MAX_RETRIES
          log(:error, "chain_record_exhausted proposal=#{proposal_id} retries=#{MAX_RETRIES}")
          return { status: 'failed', proposal_id: proposal_id,
                   error: "max retries (#{MAX_RETRIES}) exhausted" }
        end

        begin
          result = @chain_tool.call(payload)
          @recorded << proposal_id
          save_ledger
          log(:info, "chain_record_ok proposal=#{proposal_id}")
          { status: 'recorded', proposal_id: proposal_id, tx: result }
        rescue StandardError => e
          log(:warn, "chain_record_failed proposal=#{proposal_id} retry=#{retry_count} error=#{e.message}")
          # Queue for retry if not already queued
          unless @pending.any? { |p| p[:proposal_id] == proposal_id }
            @pending << { proposal_id: proposal_id, payload: payload, retries: retry_count + 1 }
          end
          { status: 'pending_retry', proposal_id: proposal_id, error: e.message }
        end
      end

      def load_ledger
        return Set.new unless File.file?(@ledger_path)
        Set.new(JSON.parse(File.read(@ledger_path)))
      rescue StandardError
        Set.new
      end

      def save_ledger
        FileUtils.mkdir_p(File.dirname(@ledger_path))
        tmp = "#{@ledger_path}.tmp"
        File.open(tmp, 'w', 0o600) { |f| f.write(JSON.generate(@recorded.to_a)) }
        File.rename(tmp, @ledger_path)
      rescue StandardError => e
        log(:warn, "ledger_save_failed: #{e.message}")
      end

      def log(level, msg)
        return unless @logger && @logger.respond_to?(level)
        @logger.public_send(level, msg)
      rescue StandardError
        # never crash on logging
      end
    end
  end
end
