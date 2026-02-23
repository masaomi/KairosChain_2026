# frozen_string_literal: true

require_relative '../core/config'
require_relative '../backend/base'

module Hestia
  module Chain
    module Migration
      class Migrator
        attr_reader :from_backend, :to_backend

        def initialize(from_backend:, to_backend:)
          @from_backend = from_backend
          @to_backend = to_backend
          @stats = initialize_stats
        end

        def dry_run
          source_anchors = fetch_source_anchors
          existing = count_existing_in_destination(source_anchors)
          {
            status: 'dry_run',
            source_backend: @from_backend.backend_type,
            destination_backend: @to_backend.backend_type,
            total_in_source: source_anchors.size,
            already_in_destination: existing,
            would_migrate: source_anchors.size - existing
          }
        end

        def migrate(batch_size: 50, skip_existing: true, progress_callback: nil)
          @stats = initialize_stats
          @stats[:started_at] = Time.now.utc.iso8601
          source_anchors = fetch_source_anchors

          source_anchors.each_slice(batch_size).with_index do |batch, batch_index|
            migrate_batch(batch, skip_existing: skip_existing)
            progress_callback&.call(
              batch: batch_index + 1,
              total_batches: (source_anchors.size.to_f / batch_size).ceil,
              migrated: @stats[:migrated],
              skipped: @stats[:skipped],
              failed: @stats[:failed]
            )
          end

          @stats[:completed_at] = Time.now.utc.iso8601
          @stats[:duration_seconds] = Time.parse(@stats[:completed_at]) - Time.parse(@stats[:started_at])
          @stats[:status] = @stats[:failed].zero? ? 'completed' : 'completed_with_errors'
          @stats.dup
        end

        def verify(sample_size: 100)
          source_anchors = fetch_source_anchors
          sample = source_anchors.sample([sample_size, source_anchors.size].min)
          verified = 0
          missing = []

          sample.each do |anchor|
            result = @to_backend.verify_anchor(anchor[:anchor_hash])
            if result[:exists]
              verified += 1
            else
              missing << anchor[:anchor_hash]
            end
          end

          {
            status: 'verified',
            sample_size: sample.size,
            verified: verified,
            missing: missing.size,
            missing_hashes: missing.first(10),
            verification_rate: sample.empty? ? 100.0 : (verified.to_f / sample.size * 100).round(2)
          }
        end

        def stats
          @stats.dup
        end

        private

        def initialize_stats
          {
            status: 'pending',
            source_backend: @from_backend.backend_type,
            destination_backend: @to_backend.backend_type,
            total: 0,
            migrated: 0,
            skipped: 0,
            failed: 0,
            errors: []
          }
        end

        def fetch_source_anchors
          case @from_backend
          when Backend::Private
            @from_backend.export_all.values
          else
            @from_backend.list_anchors(limit: 100_000)
          end
        end

        def count_existing_in_destination(anchors)
          existing = 0
          anchors.each do |anchor|
            hash = anchor[:anchor_hash] || anchor['anchor_hash']
            result = @to_backend.verify_anchor(hash)
            existing += 1 if result[:exists]
          end
          existing
        end

        def migrate_batch(batch, skip_existing:)
          batch.each { |anchor_data| migrate_single_anchor(anchor_data, skip_existing: skip_existing) }
        end

        def migrate_single_anchor(anchor_data, skip_existing:)
          @stats[:total] += 1
          data = normalize_anchor_data(anchor_data)
          hash = data[:anchor_hash]

          if skip_existing
            existing = @to_backend.verify_anchor(hash)
            if existing[:exists]
              @stats[:skipped] += 1
              return
            end
          end

          anchor = Core::Anchor.new(
            anchor_type: data[:anchor_type],
            source_id: data[:source_id],
            data_hash: data[:data_hash],
            participants: data[:participants],
            metadata: data[:metadata],
            timestamp: data[:timestamp],
            previous_anchor_ref: data[:previous_anchor_ref]
          )

          result = @to_backend.submit_anchor(anchor)
          if result[:status] == 'submitted' || result[:status] == 'exists'
            @stats[:migrated] += 1
          else
            @stats[:failed] += 1
            @stats[:errors] << { anchor_hash: hash, error: result[:error] || result[:message] }
          end
        rescue StandardError => e
          @stats[:failed] += 1
          @stats[:errors] << { anchor_hash: anchor_data[:anchor_hash], error: e.message }
        end

        def normalize_anchor_data(data)
          data.is_a?(Hash) ? data.transform_keys(&:to_sym) : data.to_h.transform_keys(&:to_sym)
        end
      end
    end
  end
end
