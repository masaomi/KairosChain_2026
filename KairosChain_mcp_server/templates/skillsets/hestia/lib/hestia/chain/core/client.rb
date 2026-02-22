# frozen_string_literal: true

require_relative 'anchor'
require_relative 'config'
require_relative 'batch_processor'
require_relative '../backend/base'

module Hestia
  module Chain
    module Core
      class Client
        attr_reader :config, :backend

        def initialize(config: nil, backend: nil)
          @config = case config
                    when Config then config
                    when Hash then Config.new(config)
                    else Config.new
                    end
          @backend = backend || Backend::Base.create(@config)
          @batch_processor = BatchProcessor.new(@backend, @config, auto_flush: false)
        end

        def submit(anchor, async: false)
          validate_anchor!(anchor)
          return { status: 'disabled', message: 'HestiaChain is disabled' } unless @config.enabled?
          if async && @config.batching_enabled?
            @batch_processor.enqueue(anchor)
          else
            @backend.submit_anchor(anchor)
          end
        end

        def verify(anchor_hash)
          @backend.verify_anchor(anchor_hash)
        end

        def get(anchor_hash)
          @backend.get_anchor(anchor_hash)
        end

        def list(limit: 100, anchor_type: nil, since: nil)
          @backend.list_anchors(limit: limit, anchor_type: anchor_type, since: since)
        end

        def flush_batch!
          @batch_processor.flush!
        end

        def batch_queue_size
          @batch_processor.queue_size
        end

        def backend_type
          @backend.backend_type
        end

        def status
          {
            enabled: @config.enabled?,
            backend: backend_type,
            backend_ready: @backend.ready?,
            batching_enabled: @config.batching_enabled?,
            batch_queue_size: @batch_processor.queue_size
          }
        end

        def stats
          {
            client: status,
            backend: @backend.stats,
            batch_processor: @batch_processor.stats
          }
        end

        def anchor(anchor_type:, source_id:, data:, **options)
          data_hash = case data
                      when String then Digest::SHA256.hexdigest(data)
                      when Hash then Digest::SHA256.hexdigest(data.to_json)
                      else raise ArgumentError, "Data must be String or Hash"
                      end
          anchor_obj = Anchor.new(
            anchor_type: anchor_type,
            source_id: source_id,
            data_hash: data_hash,
            **options
          )
          submit(anchor_obj, async: options.delete(:async) || false)
        end

        def inspect
          "#<Hestia::Chain::Client backend=#{backend_type} enabled=#{@config.enabled?}>"
        end

        private

        def validate_anchor!(anchor)
          return if anchor.is_a?(Anchor)
          raise ArgumentError, "Expected Hestia::Chain::Core::Anchor, got #{anchor.class}"
        end
      end
    end
  end
end
