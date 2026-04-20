# frozen_string_literal: true

require 'thread'
require 'securerandom'

module KairosMcp
  class Daemon
    # Thread-safe command mailbox (CF-2).
    #
    # Design rationale (design v0.2 §3.1 / CommandMailbox):
    # - HTTP server threads (producers) enqueue command Hashes.
    # - The single event-loop thread (consumer) drains them at the top of
    #   each tick via `drain`.
    # - Built on top of ::Queue so enqueue is non-blocking and lock-free
    #   from the caller's perspective; drain is bounded and non-blocking.
    class CommandMailbox
      # Sentinel types for well-known commands. SkillSets may introduce
      # new types freely — the mailbox itself is type-agnostic.
      COMMAND_TYPES = %i[reload shutdown status_dump custom].freeze
      DEFAULT_MAX_SIZE = 10_000

      attr_reader :max_size, :dropped_count

      # CF-6 fix: bounded capacity with drop-newest overflow policy.
      def initialize(max_size: DEFAULT_MAX_SIZE)
        @queue = ::Queue.new
        @max_size = max_size
        @dropped_count = 0
      end

      # Enqueue a command. Returns the assigned command_id (UUID),
      # or nil if the mailbox is full (drop-newest policy).
      #
      # @param type [Symbol, String] command kind (e.g. :reload, :shutdown)
      # @param payload [Hash] arbitrary structured payload for the consumer
      # @return [String, nil] command_id or nil if dropped
      def enqueue(type, payload = {})
        raise ArgumentError, 'type required' if type.nil?

        if @queue.size >= @max_size
          @dropped_count += 1
          return nil
        end

        command_id = SecureRandom.uuid
        entry = {
          id: command_id,
          type: type.to_sym,
          payload: payload || {},
          enqueued_at: Time.now.utc
        }
        @queue << entry
        command_id
      end

      # Drain up to `max` commands from the queue without blocking.
      # Returns an Array of command entries (may be empty).
      #
      # @param max [Integer] maximum number of commands to pop this call
      # @return [Array<Hash>]
      def drain(max: 32)
        drained = []
        max.times do
          break if @queue.empty?
          begin
            drained << @queue.pop(true) # non_block
          rescue ThreadError
            # Queue became empty between empty? and pop — done.
            break
          end
        end
        drained
      end

      # Number of queued commands not yet drained.
      def size
        @queue.size
      end

      def empty?
        @queue.empty?
      end

      # Drop all queued commands. Used during shutdown to avoid leaking
      # references; not part of the normal operating protocol.
      def clear
        @queue.clear
      end
    end
  end
end
