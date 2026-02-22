# frozen_string_literal: true

require 'thread'

module Hestia
  module Chain
    module Core
      class BatchProcessor
        attr_reader :queue_size

        def initialize(backend, config, auto_flush: false)
          @backend = backend
          @config = config
          @auto_flush = auto_flush
          @queue = []
          @mutex = Mutex.new
          @last_flush = Time.now.utc
          @stats = { total_enqueued: 0, total_flushed: 0, flush_count: 0 }
        end

        def enqueue(anchor)
          result = nil
          @mutex.synchronize do
            @queue << anchor
            @stats[:total_enqueued] += 1
            result = {
              status: 'enqueued',
              anchor_hash: anchor.anchor_hash,
              queue_size: @queue.size,
              queue_position: @queue.size
            }
          end
          flush! if @auto_flush && should_flush?
          result
        end

        def queue_size
          @mutex.synchronize { @queue.size }
        end

        def empty?
          queue_size.zero?
        end

        def flush!
          anchors_to_submit = nil
          @mutex.synchronize do
            return { status: 'empty', count: 0 } if @queue.empty?
            anchors_to_submit = @queue.dup
            @queue.clear
            @last_flush = Time.now.utc
            @stats[:flush_count] += 1
          end
          result = @backend.submit_anchors(anchors_to_submit)
          @mutex.synchronize { @stats[:total_flushed] += anchors_to_submit.size }
          result.merge(flushed_at: @last_flush.iso8601, count: anchors_to_submit.size)
        rescue StandardError => e
          @mutex.synchronize { @queue = anchors_to_submit + @queue }
          { status: 'error', error: e.message, requeued_count: anchors_to_submit.size }
        end

        def should_flush?
          return false unless @config.batching_enabled?
          @mutex.synchronize do
            return true if @queue.size >= @config.max_batch_size
            elapsed = Time.now.utc - @last_flush
            return true if elapsed >= @config.batch_interval
            false
          end
        end

        def stats
          @mutex.synchronize do
            @stats.merge(
              current_queue_size: @queue.size,
              last_flush: @last_flush.iso8601,
              batching_enabled: @config.batching_enabled?,
              max_batch_size: @config.max_batch_size,
              batch_interval: @config.batch_interval
            )
          end
        end

        def peek(limit: 10)
          @mutex.synchronize do
            @queue.first(limit).map do |anchor|
              {
                anchor_hash: anchor.anchor_hash,
                anchor_type: anchor.anchor_type,
                source_id: anchor.source_id,
                timestamp: anchor.timestamp
              }
            end
          end
        end

        def clear!
          @mutex.synchronize do
            count = @queue.size
            @queue.clear
            count
          end
        end
      end
    end
  end
end
