# frozen_string_literal: true

require_relative 'base'
require 'json'
require 'fileutils'

module Hestia
  module Chain
    module Backend
      class Private < Base
        DEFAULT_STORAGE_PATH = 'storage/hestia_anchors.json'
        DEFAULT_MAX_ANCHORS = 100_000
        STORAGE_VERSION = '1.0'

        def initialize(config)
          super
          @storage_path = config.backend_config['storage_path'] || DEFAULT_STORAGE_PATH
          @max_anchors = config.backend_config['max_anchors'] || DEFAULT_MAX_ANCHORS
          @mutex = Mutex.new
          @data = nil
          load_storage
        end

        def submit_anchor(anchor)
          validate_anchor!(anchor)
          hash = normalize_hash(anchor.anchor_hash)

          @mutex.synchronize do
            if @data['anchors'].key?(hash)
              return { status: 'exists', anchor_hash: hash, message: 'Anchor already exists' }
            end
            if @data['anchors'].size >= @max_anchors
              return { status: 'error', anchor_hash: hash, message: "Maximum anchor limit reached (#{@max_anchors})" }
            end

            @data['anchors'][hash] = {
              'anchor_hash' => hash,
              'anchor_type' => anchor.anchor_type,
              'source_id' => anchor.source_id,
              'data_hash' => anchor.data_hash,
              'participants' => anchor.participants,
              'metadata' => anchor.metadata,
              'timestamp' => anchor.timestamp,
              'previous_anchor_ref' => anchor.previous_anchor_ref,
              'stored_at' => Time.now.utc.iso8601
            }
            @data['metadata']['updated_at'] = Time.now.utc.iso8601
            @data['metadata']['anchor_count'] = @data['anchors'].size
            save_storage
          end

          { status: 'submitted', anchor_hash: hash, backend: 'private', storage_path: @storage_path }
        end

        def verify_anchor(anchor_hash)
          hash = normalize_hash(anchor_hash)
          @mutex.synchronize do
            anchor = @data['anchors'][hash]
            if anchor
              { exists: true, anchor_hash: hash, anchor_type: anchor['anchor_type'], timestamp: anchor['timestamp'] }
            else
              { exists: false, anchor_hash: hash }
            end
          end
        end

        def get_anchor(anchor_hash)
          hash = normalize_hash(anchor_hash)
          @mutex.synchronize do
            anchor = @data['anchors'][hash]
            return nil unless anchor
            symbolize_keys(anchor)
          end
        end

        def list_anchors(limit: 100, anchor_type: nil, since: nil)
          @mutex.synchronize do
            anchors = @data['anchors'].values
            anchors = anchors.select { |a| a['anchor_type'] == anchor_type } if anchor_type
            if since
              since_time = Time.parse(since)
              anchors = anchors.select { |a| Time.parse(a['timestamp']) >= since_time }
            end
            anchors.sort_by { |a| a['timestamp'] }.reverse.first(limit).map { |a| symbolize_keys(a) }
          end
        end

        def backend_type
          :private
        end

        def ready?
          @data && @data['anchors'].is_a?(Hash)
        end

        def stats
          @mutex.synchronize do
            types = @data['anchors'].values.group_by { |a| a['anchor_type'] }
            super.merge(
              total_anchors: @data['anchors'].size,
              max_anchors: @max_anchors,
              storage_path: @storage_path,
              anchors_by_type: types.transform_values(&:count)
            )
          end
        end

        def count
          @mutex.synchronize { @data['anchors'].size }
        end

        def export_all
          @mutex.synchronize do
            @data['anchors'].transform_values { |a| symbolize_keys(a) }
          end
        end

        def import_anchors(anchors, overwrite: false)
          imported = 0
          skipped = 0
          @mutex.synchronize do
            anchors.each do |hash, data|
              hash = normalize_hash(hash)
              if @data['anchors'].key?(hash) && !overwrite
                skipped += 1
                next
              end
              @data['anchors'][hash] = stringify_keys(data)
              imported += 1
            end
            @data['metadata']['updated_at'] = Time.now.utc.iso8601
            @data['metadata']['anchor_count'] = @data['anchors'].size
            save_storage
          end
          { status: 'completed', imported: imported, skipped: skipped, total: @data['anchors'].size }
        end

        private

        def load_storage
          @mutex.synchronize do
            if File.exist?(@storage_path)
              content = File.read(@storage_path)
              @data = JSON.parse(content)
            else
              initialize_storage
            end
          end
        rescue JSON::ParserError
          initialize_storage
        end

        def initialize_storage
          @data = {
            'metadata' => {
              'version' => STORAGE_VERSION,
              'created_at' => Time.now.utc.iso8601,
              'updated_at' => Time.now.utc.iso8601,
              'anchor_count' => 0
            },
            'anchors' => {}
          }
          save_storage
        end

        def save_storage
          FileUtils.mkdir_p(File.dirname(@storage_path))
          content = JSON.pretty_generate(@data)
          temp_path = "#{@storage_path}.tmp"
          File.write(temp_path, content)
          File.rename(temp_path, @storage_path)
        end

        def symbolize_keys(hash)
          return hash unless hash.is_a?(Hash)
          hash.each_with_object({}) do |(key, value), result|
            result[key.to_sym] = value.is_a?(Hash) ? symbolize_keys(value) : value
          end
        end

        def stringify_keys(hash)
          return hash unless hash.is_a?(Hash)
          hash.each_with_object({}) do |(key, value), result|
            result[key.to_s] = value.is_a?(Hash) ? stringify_keys(value) : value
          end
        end
      end
    end
  end
end
