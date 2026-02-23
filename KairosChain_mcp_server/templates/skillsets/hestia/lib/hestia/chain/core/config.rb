# frozen_string_literal: true

require 'yaml'

module Hestia
  module Chain
    module Core
      class Config
        DEFAULT_CONFIG = {
          'enabled' => true,
          'backend' => 'in_memory',
          'batching' => {
            'enabled' => false,
            'interval_seconds' => 3600,
            'max_batch_size' => 100
          },
          'in_memory' => {},
          'private' => {
            'storage_path' => 'storage/hestia_anchors.json',
            'max_anchors' => 100_000
          }
        }.freeze

        attr_reader :config

        def initialize(config = {})
          @config = deep_merge(DEFAULT_CONFIG, stringify_keys(config))
        end

        def self.load(path: nil)
          if path && File.exist?(path)
            yaml_content = File.read(path)
            full_config = YAML.safe_load(yaml_content, permitted_classes: [Symbol]) || {}
            new(full_config)
          else
            new({})
          end
        end

        def enabled?
          @config['enabled'] == true
        end

        def backend
          @config['backend']
        end

        def batching_enabled?
          @config.dig('batching', 'enabled') == true
        end

        def batch_interval
          @config.dig('batching', 'interval_seconds') || 3600
        end

        def max_batch_size
          @config.dig('batching', 'max_batch_size') || 100
        end

        def backend_config(backend_name = nil)
          name = backend_name || backend
          @config[name] || {}
        end

        def dig(*keys)
          @config.dig(*keys.map(&:to_s))
        end

        def [](key)
          @config[key.to_s]
        end

        def to_h
          @config.dup
        end

        def inspect
          "#<Hestia::Chain::Config backend=#{backend} enabled=#{enabled?}>"
        end

        private

        def deep_merge(base, override)
          base.merge(override) do |_key, old_val, new_val|
            if old_val.is_a?(Hash) && new_val.is_a?(Hash)
              deep_merge(old_val, new_val)
            else
              new_val
            end
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
