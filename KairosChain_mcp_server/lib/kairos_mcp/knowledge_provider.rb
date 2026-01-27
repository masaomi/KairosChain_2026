# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'yaml'
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
  # - Folder-based archiving (.archived/ directory)
  #
  # Storage:
  # - Content (*.md files): Always stored in files for human readability
  # - Metadata: Stored in files (default) or SQLite (when sqlite backend enabled)
  # - Blockchain: Uses the configured storage backend
  #
  class KnowledgeProvider
    KNOWLEDGE_DIR = File.expand_path('../../knowledge', __dir__)
    KNOWLEDGE_INDEX_PATH = File.expand_path('../../storage/embeddings/knowledge', __dir__)
    ARCHIVED_DIR = '.archived'
    ARCHIVE_META_FILE = '.archive_meta.yml'

    # Initialize the KnowledgeProvider
    #
    # @param knowledge_dir [String] Path to knowledge directory
    # @param vector_search_enabled [Boolean] Enable vector search
    # @param storage_backend [Storage::Backend, nil] Storage backend to use
    def initialize(knowledge_dir = KNOWLEDGE_DIR, vector_search_enabled: true, storage_backend: nil)
      @knowledge_dir = knowledge_dir
      @vector_search_enabled = vector_search_enabled
      @storage_backend = storage_backend
      @vector_search = nil
      @index_built = false
      FileUtils.mkdir_p(@knowledge_dir)
    end

    # Get the storage backend type
    # @return [Symbol] :file or :sqlite
    def storage_type
      storage_backend.backend_type
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

      # Track pending change for state commit
      track_pending_change(layer: 'L1', action: 'create', skill_id: name, reason: reason)

      { success: true, skill: skill.to_h, hash: content_hash, next_hash: content_hash }
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

      # Track pending change for state commit
      track_pending_change(layer: 'L1', action: 'update', skill_id: name, reason: reason)

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

      # Track pending change for state commit
      track_pending_change(layer: 'L1', action: 'delete', skill_id: name, reason: reason)

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

    # =========================================================================
    # Archive Operations (Folder-based)
    # =========================================================================

    # Archive a knowledge skill (move to .archived/ directory)
    #
    # @param name [String] Skill name
    # @param reason [String] Reason for archiving
    # @param superseded_by [String, nil] Name of the knowledge that supersedes this one
    # @return [Hash] Result with success status
    def archive(name, reason:, superseded_by: nil)
      skill = get(name)
      unless skill
        return { success: false, error: "Knowledge '#{name}' not found" }
      end

      # Check if already archived
      if archived?(name)
        return { success: false, error: "Knowledge '#{name}' is already archived" }
      end

      # Create archive directory
      archived_dir = File.join(@knowledge_dir, ARCHIVED_DIR)
      FileUtils.mkdir_p(archived_dir)

      # Calculate hash before moving
      content = File.read(skill.md_file_path)
      content_hash = Digest::SHA256.hexdigest(content)

      # Move to archive
      dest_path = File.join(archived_dir, name)
      FileUtils.mv(skill.base_path, dest_path)

      # Create archive metadata file
      meta = {
        'archived_at' => Time.now.iso8601,
        'archived_reason' => reason,
        'superseded_by' => superseded_by,
        'original_path' => skill.base_path,
        'content_hash' => content_hash
      }
      File.write(File.join(dest_path, ARCHIVE_META_FILE), meta.to_yaml)

      # Record to blockchain
      record_hash_reference(
        name: name,
        action: 'archive',
        prev_hash: content_hash,
        next_hash: nil,
        reason: reason
      )

      # Remove from vector search index
      remove_from_vector_index(name)

      # Track pending change for state commit (archive = demotion)
      track_pending_change(layer: 'L1', action: 'archive', skill_id: name, reason: reason)

      { success: true, archived: name, path: dest_path, hash: content_hash }
    rescue StandardError => e
      { success: false, error: "Archive failed: #{e.message}" }
    end

    # Unarchive a knowledge skill (restore from .archived/ directory)
    #
    # @param name [String] Skill name
    # @param reason [String] Reason for unarchiving
    # @return [Hash] Result with success status
    def unarchive(name, reason:)
      archived_path = File.join(@knowledge_dir, ARCHIVED_DIR, name)

      unless File.directory?(archived_path)
        return { success: false, error: "Archived knowledge '#{name}' not found" }
      end

      # Check if active knowledge with same name exists
      active_path = File.join(@knowledge_dir, name)
      if File.directory?(active_path)
        return { success: false, error: "Active knowledge '#{name}' already exists. Rename or delete it first." }
      end

      # Read archive metadata
      meta_file = File.join(archived_path, ARCHIVE_META_FILE)
      meta = File.exist?(meta_file) ? YAML.safe_load(File.read(meta_file)) : {}

      # Move back to active
      FileUtils.mv(archived_path, active_path)

      # Remove archive metadata file
      FileUtils.rm_f(File.join(active_path, ARCHIVE_META_FILE))

      # Parse the restored skill
      skill = AnthropicSkillParser.parse(active_path)
      content = File.read(skill.md_file_path)
      content_hash = Digest::SHA256.hexdigest(content)

      # Record to blockchain
      record_hash_reference(
        name: name,
        action: 'unarchive',
        prev_hash: meta['content_hash'],
        next_hash: content_hash,
        reason: reason
      )

      # Update vector search index
      update_vector_index(name, content, skill)

      # Track pending change for state commit
      track_pending_change(layer: 'L1', action: 'unarchive', skill_id: name, reason: reason)

      { success: true, unarchived: name, path: active_path, hash: content_hash }
    rescue StandardError => e
      { success: false, error: "Unarchive failed: #{e.message}" }
    end

    # List all archived knowledge skills
    #
    # @return [Array<Hash>] List of archived knowledge summaries
    def list_archived
      archived_dir = File.join(@knowledge_dir, ARCHIVED_DIR)
      return [] unless File.directory?(archived_dir)

      Dir[File.join(archived_dir, '*')].select { |f| File.directory?(f) }.map do |dir|
        skill = AnthropicSkillParser.parse(dir)
        meta_file = File.join(dir, ARCHIVE_META_FILE)
        meta = File.exist?(meta_file) ? YAML.safe_load(File.read(meta_file)) : {}

        {
          name: skill&.name || File.basename(dir),
          description: skill&.description,
          archived_at: meta['archived_at'],
          archived_reason: meta['archived_reason'],
          superseded_by: meta['superseded_by'],
          content_hash: meta['content_hash']
        }
      end
    end

    # Get a specific archived knowledge skill
    #
    # @param name [String] Skill name
    # @return [Hash, nil] Archived skill info or nil
    def get_archived(name)
      archived_path = File.join(@knowledge_dir, ARCHIVED_DIR, name)
      return nil unless File.directory?(archived_path)

      skill = AnthropicSkillParser.parse(archived_path)
      return nil unless skill

      meta_file = File.join(archived_path, ARCHIVE_META_FILE)
      meta = File.exist?(meta_file) ? YAML.safe_load(File.read(meta_file)) : {}

      {
        skill: skill.to_h,
        archived_at: meta['archived_at'],
        archived_reason: meta['archived_reason'],
        superseded_by: meta['superseded_by'],
        content_hash: meta['content_hash']
      }
    end

    # Check if a knowledge skill is archived
    #
    # @param name [String] Skill name
    # @return [Boolean] True if archived
    def archived?(name)
      archived_path = File.join(@knowledge_dir, ARCHIVED_DIR, name)
      File.directory?(archived_path)
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
      Dir[File.join(@knowledge_dir, '*')].select do |f|
        File.directory?(f) && File.basename(f) != ARCHIVED_DIR
      end
    end

    def record_hash_reference(name:, action:, prev_hash:, next_hash:, reason:)
      chain = KairosChain::Chain.new(storage_backend: storage_backend)
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

      # If using SQLite backend, also update knowledge metadata
      if storage_backend.backend_type == :sqlite
        meta = {
          content_hash: next_hash,
          version: get(name)&.version,
          description: get(name)&.description,
          tags: get(name)&.tags
        }
        storage_backend.save_knowledge_meta(name, meta) if next_hash
        storage_backend.delete_knowledge_meta(name) unless next_hash
      end
    rescue StandardError => e
      # Log but don't fail if blockchain recording fails
      warn "Failed to record to blockchain: #{e.message}"
    end

    def storage_backend
      @storage_backend ||= default_storage_backend
    end

    def default_storage_backend
      require_relative 'storage/backend'
      Storage::Backend.default
    end

    # Track pending change for state commit auto-commit
    def track_pending_change(layer:, action:, skill_id:, reason: nil)
      return unless SkillsConfig.state_commit_enabled?

      require_relative 'state_commit/pending_changes'
      require_relative 'state_commit/commit_service'

      StateCommit::PendingChanges.add(
        layer: layer,
        action: action,
        skill_id: skill_id,
        reason: reason
      )

      # Check if auto-commit should be triggered
      if SkillsConfig.state_commit_auto_enabled?
        service = StateCommit::CommitService.new
        service.check_and_auto_commit
      end
    rescue StandardError => e
      # Log but don't fail if state commit tracking fails
      warn "[KnowledgeProvider] Failed to track pending change: #{e.message}"
    end
  end
end
