# frozen_string_literal: true

require 'kairos_mcp/storage/postgresql_backend'

module Echoria
  # Adapter layer between Echoria (Rails) and KairosChain core.
  #
  # Uses KairosMcp::Storage::PostgresqlBackend with tenant_id = echo.id
  # for blockchain operations and action logging. Echoria-specific data
  # (conversations, story sessions) remains in ActiveRecord models.
  #
  class KairosBridge
    attr_reader :echo, :backend

    def initialize(echo)
      @echo = echo
      @backend = self.class.backend_for(echo.id)
    rescue StandardError => e
      Rails.logger.error("[KairosBridge] Failed to initialize: #{e.message}")
      @backend = nil
    end

    # Add data to the blockchain for this Echo
    def add_to_chain(data)
      return false unless @backend

      blocks = @backend.all_blocks
      previous = blocks.last

      block_data = build_block(data, previous, blocks.length)
      @backend.save_block(block_data)

      record_action("add_block", details: { type: data[:type] })
      block_data
    end

    # Record a skill evolution on the blockchain
    def record_skill(skill_id, content, layer)
      add_to_chain(
        type: "skill_record",
        skill_id: skill_id,
        content: content,
        layer: layer
      )
      record_action("record_skill", skill_id: skill_id, layer: layer)
    end

    # Record an action in the KairosChain action log
    def record_action(action, skill_id: nil, layer: nil, details: {})
      return false unless @backend

      @backend.record_action(
        timestamp: Time.current.iso8601,
        action: action,
        skill_id: skill_id,
        layer: layer,
        details: details.merge(echo_id: @echo.id)
      )
    end

    # Get action history from KairosChain
    def action_history(limit: 100)
      return [] unless @backend
      @backend.action_history(limit: limit)
    end

    # Get all blockchain blocks for this Echo
    def chain_blocks
      return [] unless @backend
      @backend.all_blocks
    end

    # Save knowledge metadata via KairosChain
    def save_knowledge(name, content_hash:, description: nil, tags: [])
      return false unless @backend

      @backend.save_knowledge_meta(name,
        content_hash: content_hash,
        description: description,
        tags: tags
      )
      record_action("save_knowledge", details: { name: name, tags: tags })
    end

    # Get knowledge metadata
    def get_knowledge(name)
      return nil unless @backend
      @backend.get_knowledge_meta(name)
    end

    # List all knowledge for this Echo
    def list_knowledge
      return [] unless @backend
      @backend.list_knowledge_meta
    end

    # Verify blockchain integrity for this Echo
    def verify_chain
      blocks = chain_blocks
      return true if blocks.empty?

      blocks.each_cons(2).all? do |prev_block, block|
        block[:previous_hash] == prev_block[:hash]
      end
    end

    # Whether the KairosChain backend is available
    def available?
      @backend&.ready? || false
    end

    # Create a backend instance scoped to a specific echo_id
    def self.backend_for(echo_id)
      KairosMcp::Storage::PostgresqlBackend.new(
        host: db_config[:host],
        port: db_config[:port],
        dbname: db_config[:database],
        user: db_config[:username],
        password: db_config[:password],
        tenant_id: echo_id.to_s
      )
    end

    # Extract DB connection params from Rails config
    def self.db_config
      @db_config ||= begin
        config = ActiveRecord::Base.connection_db_config.configuration_hash
        {
          host: config[:host] || 'localhost',
          port: config[:port] || 5432,
          database: config[:database],
          username: config[:username],
          password: config[:password]
        }
      end
    end

    private

    def build_block(data, previous_block, index)
      timestamp = Time.current.iso8601
      payload = data.merge(echo_id: @echo.id, timestamp: timestamp)
      previous_hash = previous_block ? previous_block[:hash] : "0" * 64
      merkle_root = compute_merkle_root(payload)
      hash = compute_hash(index, timestamp, payload, previous_hash, merkle_root)

      {
        index: index,
        timestamp: timestamp,
        data: payload,
        previous_hash: previous_hash,
        merkle_root: merkle_root,
        hash: hash
      }
    end

    def compute_merkle_root(data)
      require 'digest'
      Digest::SHA256.hexdigest(data.to_json)
    end

    def compute_hash(index, timestamp, data, previous_hash, merkle_root)
      require 'digest'
      Digest::SHA256.hexdigest("#{index}#{timestamp}#{data.to_json}#{previous_hash}#{merkle_root}")
    end
  end
end
