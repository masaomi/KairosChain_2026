# frozen_string_literal: true

require 'digest'
require 'fileutils'
require_relative 'anthropic_skill_parser'
require_relative 'kairos_chain/chain'

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

    def initialize(knowledge_dir = KNOWLEDGE_DIR)
      @knowledge_dir = knowledge_dir
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
    # @return [Array<Hash>] Matching skills
    def search(query, max_results = 5)
      pattern = Regexp.new(query, Regexp::IGNORECASE)

      list.select do |skill|
        skill[:name]&.match?(pattern) ||
          skill[:description]&.match?(pattern) ||
          skill[:tags]&.any? { |t| t.match?(pattern) }
      end.first(max_results)
    end

    private

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
