# frozen_string_literal: true

require 'digest'
require 'fileutils'
require_relative 'anthropic_skill_parser'
require_relative 'kairos_chain/chain'
require_relative 'vector_search/provider'

module KairosMcp
  # KnowledgeProvider: Manages L1 (knowledge layer) skills in Anthropic format
  #
  # L1 characteristics:
  # - Project-specific universal knowledge
  # - Hash-only blockchain recording
  # - Lightweight modification constraints
  #
  class KnowledgeProvider
    KNOWLEDGE_DIR = File.expand_path('../../knowledge', __dir__)
    KNOWLEDGE_INDEX_PATH = File.expand_path('../../storage/embeddings/knowledge', __dir__)

    def initialize(knowledge_dir = KNOWLEDGE_DIR, vector_search_enabled: true)
      @knowledge_dir = knowledge_dir
      @vector_search_enabled = vector_search_enabled
      @vector_search = nil
      @index_built = false
      FileUtils.mkdir_p(@knowledge_dir)
    end

    # List all knowledge skills
    #
    # @return [Array<Hash>] List of knowledge skill summaries
    def list
      skill_dirs.map do |dir|
        skill = AnthropicSkillParser.parse(dir)
        next unless skill

        {
          name: skill.name,
          description: skill.description,
          version: skill.version,
          tags: skill.tags,
          has_scripts: skill.has_scripts?,
          has_assets: skill.has_assets?,
          has_references: skill.has_references?
        }
      end.compact
    end

    # Get a specific knowledge skill by name
    #
    # @param name [String] Skill name
    # @return [AnthropicSkillParser::SkillEntry, nil] The skill entry or nil
    def get(name)
      skill_dir = File.join(@knowledge_dir, name)
      return nil unless File.directory?(skill_dir)

      AnthropicSkillParser.parse(skill_dir)
    end

    # Create a new knowledge skill
    #
    # @param name [String] Skill name
    # @param content [String] Full content including YAML frontmatter
    # @param reason [String] Reason for creation
    # @param create_subdirs [Boolean] Whether to create scripts/assets/references
    # @return [Hash] Result with success status and skill info
    def create(name, content, reason: nil, create_subdirs: false)
      skill_dir = File.join(@knowledge_dir, name)
      
      if File.exist?(skill_dir)
        return { success: false, error: "Knowledge '#{name}' already exists" }
      end

      skill = AnthropicSkillParser.create(@knowledge_dir, name, content, create_subdirs: create_subdirs)
      
      # Record hash reference to blockchain
      content_hash = Digest::SHA256.hexdigest(content)
      record_hash_reference(
        name: name,
        action: 'create',
        prev_hash: nil,
        next_hash: content_hash,
        reason: reason || "Create knowledge: #{name}"
      )

      # Update vector search index
      update_vector_index(name, content, skill)

      { success: true, skill: skill.to_h, hash: content_hash }
    end

    # Update an existing knowledge skill
    #
    # @param name [String] Skill name
    # @param new_content [String] New content including YAML frontmatter
    # @param reason [String] Reason for update
    # @return [Hash] Result with success status
    def update(name, new_content, reason: nil)
      skill = get(name)
      unless skill
        return { success: false, error: "Knowledge '#{name}' not found" }
      end

      # Calculate hashes
      prev_content = File.read(skill.md_file_path)
      prev_hash = Digest::SHA256.hexdigest(prev_content)
      next_hash = Digest::SHA256.hexdigest(new_content)

      if prev_hash == next_hash
        return { success: false, error: "No changes detected" }
      end

      # Update the file
      updated_skill = AnthropicSkillParser.update(skill.base_path, new_content)

      # Record hash reference to blockchain
      record_hash_reference(
        name: name,
        action: 'update',
        prev_hash: prev_hash,
        next_hash: next_hash,
        reason: reason || "Update knowledge: #{name}"
      )

      # Update vector search index
      update_vector_index(name, new_content, updated_skill)

      { success: true, skill: updated_skill.to_h, prev_hash: prev_hash, next_hash: next_hash }
    end

    # Delete a knowledge skill
    #
    # @param name [String] Skill name
    # @param reason [String] Reason for deletion
    # @return [Hash] Result with success status
    def delete(name, reason: nil)
      skill = get(name)
      unless skill
        return { success: false, error: "Knowledge '#{name}' not found" }
      end

      # Calculate hash before deletion
      prev_content = File.read(skill.md_file_path)
      prev_hash = Digest::SHA256.hexdigest(prev_content)

      # Delete the directory
      FileUtils.rm_rf(skill.base_path)

      # Record hash reference to blockchain
      record_hash_reference(
        name: name,
        action: 'delete',
        prev_hash: prev_hash,
        next_hash: nil,
        reason: reason || "Delete knowledge: #{name}"
      )

      # Remove from vector search index
      remove_from_vector_index(name)

      { success: true, deleted: name, prev_hash: prev_hash }
    end

    # List scripts in a knowledge skill
    #
    # @param name [String] Skill name
    # @return [Array<Hash>] List of script info
    def list_scripts(name)
      skill = get(name)
      return [] unless skill

      AnthropicSkillParser.list_scripts(skill)
    end

    # List assets in a knowledge skill
    #
    # @param name [String] Skill name
    # @return [Array<Hash>] List of asset info
    def list_assets(name)
      skill = get(name)
      return [] unless skill

      AnthropicSkillParser.list_assets(skill)
    end

    # List references in a knowledge skill
    #
    # @param name [String] Skill name
    # @return [Array<Hash>] List of reference info
    def list_references(name)
      skill = get(name)
      return [] unless skill

      AnthropicSkillParser.list_references(skill)
    end

    # Search knowledge skills by query
    #
    # @param query [String] Search query
    # @param max_results [Integer] Maximum number of results
    # @param semantic [Boolean] Force semantic search if available
    # @return [Array<Hash>] Matching skills
    def search(query, max_results = 5, semantic: nil)
      use_semantic = semantic.nil? ? @vector_search_enabled : semantic
      
      if use_semantic && vector_search.semantic?
        semantic_search(query, max_results)
      else
        regex_search(query, max_results)
      end
    end

    # Get vector search status
    #
    # @return [Hash] Status information
    def vector_search_status
      {
        enabled: @vector_search_enabled,
        semantic_available: VectorSearch.available?,
        index_built: @index_built,
        document_count: vector_search.count
      }
    end

    # Rebuild the vector search index
    #
    # @return [Boolean] Success status
    def rebuild_index
      documents = skill_dirs.filter_map do |dir|
        skill = AnthropicSkillParser.parse(dir)
        next unless skill

        content = File.read(skill.md_file_path) rescue ''
        {
          id: skill.name,
          text: build_searchable_text(skill, content),
          metadata: {
            description: skill.description,
            tags: skill.tags,
            version: skill.version
          }
        }
      end

      result = vector_search.rebuild(documents)
      @index_built = result
      result
    end

    private

    def vector_search
      @vector_search ||= VectorSearch.create(index_path: KNOWLEDGE_INDEX_PATH)
    end

    def ensure_index_built
      return if @index_built
      rebuild_index
    end

    def semantic_search(query, max_results)
      ensure_index_built

      results = vector_search.search(query, k: max_results)

      results.filter_map do |result|
        skill = get(result[:id])
        next unless skill

        {
          name: skill.name,
          description: skill.description,
          version: skill.version,
          tags: skill.tags,
          has_scripts: skill.has_scripts?,
          has_assets: skill.has_assets?,
          has_references: skill.has_references?,
          score: result[:score]
        }
      end
    end

    def regex_search(query, max_results)
      pattern = Regexp.new(query, Regexp::IGNORECASE)

      list.select do |skill|
        skill[:name]&.match?(pattern) ||
          skill[:description]&.match?(pattern) ||
          skill[:tags]&.any? { |t| t.match?(pattern) }
      end.first(max_results)
    end

    def build_searchable_text(skill, content)
      parts = [
        skill.name,
        skill.description,
        skill.tags&.join(' '),
        content
      ].compact

      parts.join("\n\n")
    end

    def update_vector_index(name, content, skill)
      return unless @vector_search_enabled

      text = build_searchable_text(skill, content)
      metadata = {
        description: skill.description,
        tags: skill.tags,
        version: skill.version
      }

      vector_search.add(name, text, metadata: metadata)
      vector_search.save
    rescue StandardError => e
      warn "[KnowledgeProvider] Failed to update vector index: #{e.message}"
    end

    def remove_from_vector_index(name)
      return unless @vector_search_enabled

      vector_search.remove(name)
      vector_search.save
    rescue StandardError => e
      warn "[KnowledgeProvider] Failed to remove from vector index: #{e.message}"
    end

    def skill_dirs
      Dir[File.join(@knowledge_dir, '*')].select { |f| File.directory?(f) }
    end

    def record_hash_reference(name:, action:, prev_hash:, next_hash:, reason:)
      chain = KairosChain::Chain.new
      chain.add_block([{
        type: 'knowledge_update',
        layer: 'L1',
        knowledge_id: name,
        action: action,
        prev_hash: prev_hash,
        next_hash: next_hash,
        reason: reason,
        timestamp: Time.now.iso8601
      }.to_json])
    rescue StandardError => e
      # Log but don't fail if blockchain recording fails
      warn "Failed to record to blockchain: #{e.message}"
    end
  end
end
