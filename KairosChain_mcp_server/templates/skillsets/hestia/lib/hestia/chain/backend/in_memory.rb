# frozen_string_literal: true

require_relative 'base'

module Hestia
  module Chain
    module Backend
      class InMemory < Base
        def initialize(config)
          super
          @anchors = {}
          @mutex = Mutex.new
          @created_at = Time.now.utc
        end

        def submit_anchor(anchor)
          validate_anchor!(anchor)
          hash = normalize_hash(anchor.anchor_hash)

          @mutex.synchronize do
            if @anchors.key?(hash)
              return {
                status: 'exists',
                anchor_hash: hash,
                message: 'Anchor already exists'
              }
            end

            @anchors[hash] = {
              anchor_hash: hash,
              anchor_type: anchor.anchor_type,
              source_id: anchor.source_id,
              data_hash: anchor.data_hash,
              participants: anchor.participants,
              metadata: anchor.metadata,
              timestamp: anchor.timestamp,
              previous_anchor_ref: anchor.previous_anchor_ref,
              stored_at: Time.now.utc.iso8601
            }
          end

          { status: 'submitted', anchor_hash: hash, backend: 'in_memory' }
        end

        def verify_anchor(anchor_hash)
          hash = normalize_hash(anchor_hash)
          @mutex.synchronize do
            anchor = @anchors[hash]
            if anchor
              { exists: true, anchor_hash: hash, anchor_type: anchor[:anchor_type], timestamp: anchor[:timestamp] }
            else
              { exists: false, anchor_hash: hash }
            end
          end
        end

        def get_anchor(anchor_hash)
          hash = normalize_hash(anchor_hash)
          @mutex.synchronize { @anchors[hash]&.dup }
        end

        def list_anchors(limit: 100, anchor_type: nil, since: nil)
          @mutex.synchronize do
            anchors = @anchors.values
            anchors = anchors.select { |a| a[:anchor_type] == anchor_type } if anchor_type
            if since
              since_time = Time.parse(since)
              anchors = anchors.select { |a| Time.parse(a[:timestamp]) >= since_time }
            end
            anchors.sort_by { |a| a[:timestamp] }.reverse.first(limit)
          end
        end

        def backend_type
          :in_memory
        end

        def ready?
          true
        end

        def stats
          @mutex.synchronize do
            types = @anchors.values.group_by { |a| a[:anchor_type] }
            super.merge(
              total_anchors: @anchors.size,
              anchors_by_type: types.transform_values(&:count),
              created_at: @created_at.iso8601
            )
          end
        end

        def clear!
          @mutex.synchronize do
            count = @anchors.size
            @anchors.clear
            count
          end
        end

        def count
          @mutex.synchronize { @anchors.size }
        end
      end
    end
  end
end
