# frozen_string_literal: true

require_relative 'chain/core/config'
require_relative 'chain/backend/base'
require_relative 'chain/migration/migrator'

module Hestia
  # ChainMigrator wraps the Hestia::Chain::Migration::Migrator
  # for use within the SkillSet. Provides stage-aware migration
  # between backends (in_memory → private → testnet → mainnet).
  #
  # Phase 4A supports: Stage 0 (in_memory) → Stage 1 (private)
  # Stages 2+ require external dependencies (eth gem, RPC endpoints).
  class ChainMigrator
    STAGES = {
      0 => { name: 'in_memory', description: 'In-memory (development/testing)' },
      1 => { name: 'private', description: 'Private JSON file storage' },
      2 => { name: 'public_testnet', description: 'Public testnet (Base Sepolia)' },
      3 => { name: 'public_mainnet', description: 'Public mainnet (Base/Ethereum)' }
    }.freeze

    STAGE_NAMES = STAGES.transform_values { |v| v[:name] }.freeze

    attr_reader :current_stage

    def initialize(current_backend:)
      @current_backend = current_backend
      @current_stage = detect_stage(current_backend)
    end

    # Get status of current chain and available migrations
    def status
      {
        current_stage: @current_stage,
        current_backend: STAGES[@current_stage],
        available_migrations: available_migrations,
        total_anchors: count_anchors
      }
    end

    # Perform migration to the next stage
    #
    # @param target_stage [Integer] Target stage number
    # @param dry_run [Boolean] If true, only report what would be migrated
    # @param storage_path [String] Storage path for private backend
    # @return [Hash] Migration result
    def migrate(target_stage:, dry_run: false, storage_path: nil)
      validate_migration!(target_stage)

      target_config = build_target_config(target_stage, storage_path: storage_path)
      target_backend = Chain::Backend::Base.create(target_config)

      migrator = Chain::Migration::Migrator.new(
        from_backend: @current_backend,
        to_backend: target_backend
      )

      if dry_run
        migrator.dry_run
      else
        result = migrator.migrate
        verify_result = migrator.verify
        result.merge(verification: verify_result)
      end
    end

    private

    def detect_stage(backend)
      case backend.backend_type
      when :in_memory then 0
      when :private then 1
      when :public_testnet then 2
      when :public_mainnet then 3
      else 0
      end
    end

    def available_migrations
      migrations = []
      next_stage = @current_stage + 1
      if next_stage <= 1  # Only stage 0→1 is self-contained in Phase 4A
        migrations << {
          from: @current_stage,
          to: next_stage,
          from_name: STAGES[@current_stage][:name],
          to_name: STAGES[next_stage][:name],
          self_contained: true,
          prerequisites: []
        }
      elsif next_stage <= 3
        prereqs = case next_stage
                  when 2 then ['eth gem installed', 'RPC URL configured', 'Contract deployed on testnet']
                  when 3 then ['Testnet validation complete', 'Mainnet RPC URL', 'Mainnet contract deployed']
                  end
        migrations << {
          from: @current_stage,
          to: next_stage,
          from_name: STAGES[@current_stage][:name],
          to_name: STAGES[next_stage][:name],
          self_contained: false,
          prerequisites: prereqs
        }
      end
      migrations
    end

    def validate_migration!(target_stage)
      unless STAGES.key?(target_stage)
        raise ArgumentError, "Invalid target stage: #{target_stage}. Valid: #{STAGES.keys.join(', ')}"
      end

      if target_stage <= @current_stage
        raise ArgumentError, "Cannot migrate backwards. Current stage: #{@current_stage}, target: #{target_stage}"
      end

      if target_stage > @current_stage + 1
        raise ArgumentError, "Cannot skip stages. Current: #{@current_stage}, target: #{target_stage}. Next available: #{@current_stage + 1}"
      end

      if target_stage >= 2
        raise ArgumentError, "Stage #{target_stage} (#{STAGES[target_stage][:name]}) requires external dependencies not yet available"
      end
    end

    def build_target_config(target_stage, storage_path: nil)
      config_hash = { 'backend' => STAGES[target_stage][:name] }
      if target_stage == 1
        config_hash['private'] = { 'storage_path' => storage_path || 'storage/hestia_anchors.json' }
      end
      Chain::Core::Config.new(config_hash)
    end

    def count_anchors
      @current_backend.list_anchors(limit: 100_000).size
    rescue StandardError
      0
    end
  end
end
