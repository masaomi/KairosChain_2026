# frozen_string_literal: true

module Hestia
  module Chain
    module Backend
      class Base
        attr_reader :config

        def initialize(config)
          @config = config
        end

        def submit_anchor(anchor)
          raise NotImplementedError, "#{self.class}#submit_anchor must be implemented"
        end

        def submit_anchors(anchors)
          results = anchors.map { |anchor| submit_anchor(anchor) }
          {
            status: 'submitted',
            count: results.size,
            anchor_hashes: results.map { |r| r[:anchor_hash] },
            results: results
          }
        end

        def verify_anchor(anchor_hash)
          raise NotImplementedError, "#{self.class}#verify_anchor must be implemented"
        end

        def get_anchor(anchor_hash)
          raise NotImplementedError, "#{self.class}#get_anchor must be implemented"
        end

        def list_anchors(limit: 100, anchor_type: nil, since: nil)
          raise NotImplementedError, "#{self.class}#list_anchors must be implemented"
        end

        def backend_type
          raise NotImplementedError, "#{self.class}#backend_type must be implemented"
        end

        def ready?
          raise NotImplementedError, "#{self.class}#ready? must be implemented"
        end

        def stats
          { backend_type: backend_type, ready: ready? }
        end

        def self.create(config)
          case config.backend
          when 'in_memory'
            require_relative 'in_memory'
            InMemory.new(config)
          when 'private'
            require_relative 'private'
            Private.new(config)
          else
            raise ArgumentError, "Unknown backend type: #{config.backend}. " \
                                 "Valid types: in_memory, private"
          end
        end

        protected

        def normalize_hash(hash)
          hash.to_s.downcase.sub(/\A0x/, '')
        end

        def validate_anchor!(anchor)
          return if anchor.is_a?(Hestia::Chain::Core::Anchor)
          raise ArgumentError, "Expected Hestia::Chain::Core::Anchor, got #{anchor.class}"
        end
      end
    end
  end
end
