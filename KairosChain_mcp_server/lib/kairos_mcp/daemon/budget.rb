# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'date'
require 'time'

module KairosMcp
  class Daemon
    # Budget — daily LLM usage ledger (P2.8).
    #
    # Design (v0.2 P2.8):
    #   * One file, .kairos/state/budget.json, tracks calls and tokens
    #     consumed today against a configurable daily limit.
    #   * `record_usage` increments counters. `exceeded?` gates further
    #     OODA cycles. `reset_if_new_day!` rolls the counter over at
    #     midnight in daemon-local TZ.
    #
    # The "limit" is on call count (not tokens) because call-level
    # throttling is what the daemon actually needs: a single run-away
    # cognitive loop is bounded by calls-per-day, not tokens-per-day.
    # Token counters are kept for observability.
    #
    # Atomicity:
    #   Writes use tmp → rename. A crash mid-write leaves the previous
    #   ledger intact.
    #
    # Thread safety:
    #   Budget is meant to be consulted from the daemon's single event
    #   loop thread. Concurrent callers must synchronize externally.
    class Budget
      DEFAULT_PATH  = '.kairos/state/budget.json'
      DEFAULT_LIMIT = 10_000 # calls/day

      attr_reader :path, :limit

      # @param path  [String] absolute path to budget.json
      # @param limit [Integer] daily call ceiling
      # @param clock [#call, nil] returns current Time
      def initialize(path: DEFAULT_PATH, limit: DEFAULT_LIMIT, clock: nil)
        @path  = path
        @limit = Integer(limit)
        @clock = clock || -> { Time.now }
        @data  = nil
      end

      # Load existing ledger from disk, or initialize a fresh one for today.
      # Returns self so callers can chain: Budget.new(...).load(path).
      def load(path = nil)
        @path = path if path
        @data = read_file || fresh_record
        # Guard: if the file exists but is for a previous day, roll it over.
        reset_if_new_day!
        self
      end

      def data
        @data ||= fresh_record
        @data
      end

      def llm_calls
        data['llm_calls']
      end

      def input_tokens
        data['input_tokens']
      end

      def output_tokens
        data['output_tokens']
      end

      def date
        data['date']
      end

      # Increment usage counters. Does NOT save — save explicitly after a
      # logical unit of work completes (so partial saves are rare).
      def record_usage(input_tokens: 0, output_tokens: 0, calls: 1)
        d = data
        d['llm_calls']     += Integer(calls)
        d['input_tokens']  += Integer(input_tokens)
        d['output_tokens'] += Integer(output_tokens)
        d
      end

      # True iff llm_calls has met or exceeded the configured daily limit.
      def exceeded?
        data['llm_calls'] >= @limit
      end

      # If today's date differs from the ledger's date, zero the counters
      # and stamp the new date. Returns true if a reset occurred.
      def reset_if_new_day!
        today = current_date_str
        d = data
        return false if d['date'] == today

        d['date']          = today
        d['llm_calls']     = 0
        d['input_tokens']  = 0
        d['output_tokens'] = 0
        true
      end

      # Atomic write (tmp → rename).
      def save
        FileUtils.mkdir_p(File.dirname(@path))
        tmp = "#{@path}.tmp.#{$$}"
        begin
          File.open(tmp, 'w', 0o600) do |f|
            f.write(JSON.generate(data))
            f.flush
            begin
              f.fsync
            rescue StandardError
              # best-effort
            end
          end
          File.rename(tmp, @path)
          true
        ensure
          begin
            File.unlink(tmp) if tmp && File.exist?(tmp)
          rescue StandardError
            # cleanup must not raise
          end
        end
      end

      # ---------------------------------------------------------------- private

      private

      def read_file
        return nil unless File.exist?(@path)

        raw = JSON.parse(File.read(@path))
        return nil unless raw.is_a?(Hash)

        # Normalize: missing keys default; keep limit from config not file
        # (the config is authoritative for limits — the file is a usage
        # ledger, not a policy store).
        {
          'date'          => (raw['date'] || current_date_str).to_s,
          'llm_calls'     => Integer(raw['llm_calls']     || 0),
          'input_tokens'  => Integer(raw['input_tokens']  || 0),
          'output_tokens' => Integer(raw['output_tokens'] || 0),
          'limit'         => @limit
        }
      rescue StandardError
        nil
      end

      def fresh_record
        {
          'date'          => current_date_str,
          'llm_calls'     => 0,
          'input_tokens'  => 0,
          'output_tokens' => 0,
          'limit'         => @limit
        }
      end

      def current_date_str
        t = @clock.call
        t.respond_to?(:strftime) ? t.strftime('%Y-%m-%d') : Date.today.iso8601
      end
    end
  end
end
