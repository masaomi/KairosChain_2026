module Echoria
  class KairosBridge
    def initialize(echo)
      @echo = echo
      @chain = initialize_chain
      @knowledge_provider = initialize_knowledge_provider
    end

    def add_to_chain(data)
      block_data = {
        type: data[:type],
        echo_id: @echo.id,
        timestamp: Time.current.iso8601,
        payload: data
      }

      @chain.add_block(block_data)
      record_action("add_block", block_data)
    end

    def record_skill(skill_id, content, layer)
      skill_data = {
        type: "skill_record",
        skill_id: skill_id,
        content: content,
        layer: layer,
        timestamp: Time.current.iso8601
      }

      @chain.add_block(skill_data)
      record_action("record_skill", skill_data)
    end

    def get_knowledge(name)
      knowledge = EchoKnowledge.find_by(echo_id: @echo.id, name: name, is_archived: false)
      knowledge&.content
    end

    def search_knowledge(query)
      EchoKnowledge.where(echo_id: @echo.id, is_archived: false)
                    .where("content ILIKE ?", "%#{query}%")
                    .pluck(:name, :content)
                    .map { |name, content| { name: name, content: content } }
    end

    def save_knowledge(name, content, description: nil, tags: [])
      EchoKnowledge.find_or_create_by!(echo_id: @echo.id, name: name) do |knowledge|
        knowledge.content = content
        knowledge.description = description
        knowledge.tags = tags
      end

      record_action("save_knowledge", { name: name, tags: tags })
    end

    def get_action_history(limit: 100)
      EchoActionLog.where(echo_id: @echo.id)
                    .order(timestamp: :desc)
                    .limit(limit)
                    .map { |log| { action: log.action, skill_id: log.skill_id, details: log.details, timestamp: log.timestamp } }
    end

    def chain_blocks
      @chain.blocks
    end

    private

    def initialize_chain
      storage_backend = KairosChain::PostgresBackend.new(@echo.id)
      KairosMcp::KairosChain::Chain.new(storage_backend)
    rescue StandardError => e
      Rails.logger.error("Failed to initialize KairosChain: #{e.message}")
      # Return a mock chain that doesn't fail
      MockChain.new
    end

    def initialize_knowledge_provider
      KairosMcp::KnowledgeProvider.new(storage_backend: KairosChain::PostgresBackend.new(@echo.id))
    rescue StandardError => e
      Rails.logger.error("Failed to initialize KnowledgeProvider: #{e.message}")
      MockKnowledgeProvider.new
    end

    def record_action(action, details = {})
      EchoActionLog.create(
        echo_id: @echo.id,
        timestamp: Time.current,
        action: action,
        details: details
      )
    end
  end

  # Mock classes for graceful fallback if KairosChain unavailable
  class MockChain
    def add_block(data)
      Rails.logger.warn("MockChain: add_block called with #{data.inspect}")
      true
    end

    def blocks
      []
    end
  end

  class MockKnowledgeProvider
    def search(query)
      []
    end
  end

  # PostgreSQL Storage Backend for KairosChain
  class PostgresBackend
    def initialize(echo_id)
      @echo_id = echo_id
    end

    def load_blocks
      EchoBlock.where(echo_id: @echo_id).order(:block_index).map do |block|
        {
          index: block.block_index,
          timestamp: block.timestamp,
          data: block.data,
          previous_hash: block.previous_hash,
          hash: block.hash,
          merkle_root: block.merkle_root
        }
      end
    end

    def save_block(block_data)
      EchoBlock.create!(
        echo_id: @echo_id,
        block_index: block_data[:index],
        timestamp: block_data[:timestamp],
        data: block_data[:data],
        previous_hash: block_data[:previous_hash],
        hash: block_data[:hash],
        merkle_root: block_data[:merkle_root]
      )
      true
    rescue ActiveRecord::RecordNotUnique
      false
    end

    def record_action(action, skill_id, layer, details)
      EchoActionLog.create!(
        echo_id: @echo_id,
        timestamp: Time.current,
        action: action,
        skill_id: skill_id,
        layer: layer,
        details: details
      )
    end

    def action_history(limit = 100)
      EchoActionLog.where(echo_id: @echo_id)
                    .order(timestamp: :desc)
                    .limit(limit)
    end

    def save_knowledge_meta(name, metadata)
      EchoKnowledge.find_or_create_by!(echo_id: @echo_id, name: name) do |knowledge|
        knowledge.description = metadata[:description]
        knowledge.tags = metadata[:tags]
        knowledge.content = metadata[:content] || ""
      end
    end

    def get_knowledge_meta(name)
      knowledge = EchoKnowledge.find_by(echo_id: @echo_id, name: name)
      knowledge ? knowledge.slice(:name, :description, :tags, :content_hash, :version) : nil
    end

    def list_knowledge_meta
      EchoKnowledge.where(echo_id: @echo_id, is_archived: false).map do |knowledge|
        { name: knowledge.name, description: knowledge.description, tags: knowledge.tags }
      end
    end

    def delete_knowledge_meta(name)
      knowledge = EchoKnowledge.find_by(echo_id: @echo_id, name: name)
      knowledge&.archive!
      true
    end
  end
end
