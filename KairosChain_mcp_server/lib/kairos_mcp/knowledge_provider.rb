# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'yaml'
require_relative 'anthropic_skill_parser'
require_relative 'path_containment'
require_relative 'skillset_manager'
require_relative 'kairos_chain/chain'
require_relative 'vector_search/provider'
require_relative '../kairos_mcp'

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
    # Main knowledge directory (constitutively-recorded L1). Exposed so callers
    # can distinguish main-dir knowledge from read-only external SkillSet
    # knowledge, e.g. to scope INV-A correspondence checks to recorded artifacts.
    attr_reader :knowledge_dir

    ARCHIVED_DIR = '.archived'
    ARCHIVE_META_FILE = '.archive_meta.yml'
    # Backup directories created by upgrade flow (`.bak.<timestamp>`).
    # Loader must skip these — they may contain old/broken frontmatter.
    BACKUP_DIR_PATTERN = /(?:^|\.)bak(?:\.|$)/.freeze

    # Initialize the KnowledgeProvider
    #
    # @param knowledge_dir [String] Path to knowledge directory
    # @param vector_search_enabled [Boolean] Enable vector search
    # @param storage_backend [Storage::Backend, nil] Storage backend to use
    # @param include_skillset_knowledge [Boolean] Register knowledge dirs declared
    #   by enabled SkillSets. Default true; pass false to build a provider scoped
    #   strictly to the main knowledge dir.
    def initialize(knowledge_dir = nil, vector_search_enabled: true, storage_backend: nil,
                   user_context: nil, include_skillset_knowledge: true)
      knowledge_dir ||= KairosMcp.knowledge_dir(user_context: user_context)
      @knowledge_dir = knowledge_dir
      @user_context = user_context
      @vector_search_enabled = vector_search_enabled
      @storage_backend = storage_backend
      @vector_search = nil
      @index_built = false
      @external_dirs = []
      FileUtils.mkdir_p(@knowledge_dir)
      register_skillset_knowledge_dirs if include_skillset_knowledge
    end

    # Register an external knowledge directory (e.g. from a SkillSet)
    # Knowledge is read-only from external dirs; no merge into the main dir.
    #
    # @param dir [String] Absolute path to the container directory holding entry
    #   subdirectories (e.g. `<skillset>/knowledge`), not an entry directory itself
    # @param source [String] Identifier for the source (e.g. "skillset:mmp")
    # @param layer [Symbol] Layer governance (:L0, :L1, :L2)
    # @param index [Boolean] Whether to include in vector search index
    # @param only [Array<String>, nil] Entry names to expose. nil exposes every
    #   subdirectory. Passing the declared set keeps undeclared knowledge shipped
    #   inside a SkillSet from becoming visible as L1 by proximity alone.
    #
    # Idempotent by directory: registering the same dir twice (e.g. once from the
    # SkillSet manifest at construction, once from a SkillSet that also registers
    # itself) keeps the first registration rather than duplicating list entries.
    def add_external_dir(dir, source:, layer: :L1, index: true, only: nil)
      return unless File.directory?(dir)

      absolute = File.expand_path(dir)
      return if @external_dirs.any? { |ext| ext[:dir] == absolute }

      @external_dirs << {
        dir: absolute, source: source, layer: layer, index: index,
        only: only && Array(only).map { |n| File.basename(n.to_s) }
      }
      @index_built = false if index # Invalidate index when new indexed dir added
    end

    # Get the storage backend type
    # @return [Symbol] :file or :sqlite
    def storage_type
      storage_backend.backend_type
    end

    # List all knowledge skills (including those from external SkillSet dirs)
    #
    # @return [Array<Hash>] List of knowledge skill summaries
    def list
      results = skill_dirs.map do |dir|
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

      # Include knowledge from external directories (SkillSets)
      @external_dirs.each do |ext|
        external_skill_dirs(ext[:dir], only: ext[:only]).each do |dir|
          skill = AnthropicSkillParser.parse(dir)
          next unless skill

          results << {
            name: skill.name,
            description: skill.description,
            version: skill.version,
            tags: skill.tags,
            has_scripts: skill.has_scripts?,
            has_assets: skill.has_assets?,
            has_references: skill.has_references?,
            source: ext[:source],
            layer: ext[:layer]
          }
        end
      end

      results
    end

    # Get a specific knowledge skill by name
    # Searches main knowledge dir first, then external SkillSet dirs
    #
    # @param name [String] Skill name
    # @return [AnthropicSkillParser::SkillEntry, nil] The skill entry or nil
    def get(name)
      return nil unless PathContainment.safe_segment?(name)
      return nil if reserved_name?(name)

      skill_dir = File.join(@knowledge_dir, name)
      if PathContainment.contained?(@knowledge_dir, skill_dir) && File.directory?(skill_dir)
        return AnthropicSkillParser.parse(skill_dir)
      end

      # Search external directories
      @external_dirs.each do |ext|
        next if ext[:only] && !ext[:only].include?(name)

        ext_skill_dir = File.join(ext[:dir], name)
        next unless PathContainment.contained?(ext[:dir], ext_skill_dir)

        return AnthropicSkillParser.parse(ext_skill_dir) if File.directory?(ext_skill_dir)
      end

      nil
    end

    # Create a new knowledge skill
    #
    # @param name [String] Skill name
    # @param content [String] Full content including YAML frontmatter
    # @param reason [String] Reason for creation
    # @param create_subdirs [Boolean] Whether to create scripts/assets/references
    # @return [Hash] Result with success status and skill info
    def create(name, content, reason: nil, create_subdirs: false)
      # Checked BEFORE the join: File.join raises TypeError on a non-String, so
      # a malformed argument would escape as an exception instead of the
      # structured refusal every other caller of this method expects.
      unless PathContainment.safe_segment?(name)
        return { success: false, error: "Invalid knowledge name #{name.inspect}: not a single path segment" }
      end

      if reserved_name?(name)
        return { success: false, error: "Invalid knowledge name '#{name}': reserved by the knowledge store" }
      end

      skill_dir = File.join(@knowledge_dir, name)
      unless PathContainment.contained?(@knowledge_dir, skill_dir)
        return { success: false, error: "Invalid knowledge name '#{name}': resolves outside the knowledge directory" }
      end

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
      return not_owned(name) unless owned?(skill)

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
      return not_owned(name) unless owned?(skill)

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

    # Rebuild the vector search index (includes indexed external dirs)
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

      # Include external dirs that have indexing enabled
      @external_dirs.select { |ext| ext[:index] }.each do |ext|
        external_skill_dirs(ext[:dir], only: ext[:only]).each do |dir|
          skill = AnthropicSkillParser.parse(dir)
          next unless skill

          content = File.read(skill.md_file_path) rescue ''
          documents << {
            id: "#{ext[:source]}:#{skill.name}",
            text: build_searchable_text(skill, content),
            metadata: {
              description: skill.description,
              tags: skill.tags,
              version: skill.version,
              source: ext[:source]
            }
          }
        end
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
      return not_owned(name) unless owned?(skill)

      # Check if already archived
      if archived?(name)
        return { success: false, error: "Knowledge '#{name}' is already archived" }
      end

      # Create archive directory
      archived_dir = File.join(@knowledge_dir, ARCHIVED_DIR)
      FileUtils.mkdir_p(archived_dir)

      # The archive root is itself a path this method did not choose. If
      # `.archived` is a symlink out of the store, asking containment against it
      # asks about the wrong root — the predicate answers truthfully about a
      # directory nobody meant, and the move carries L1 knowledge outside.
      # Every path below is therefore bounded by @knowledge_dir.
      return archive_root_escaped unless PathContainment.contained?(@knowledge_dir, archived_dir)

      # Calculate hash before moving
      content = File.read(skill.md_file_path)
      content_hash = Digest::SHA256.hexdigest(content)

      dest_path = File.join(archived_dir, name)
      meta_path = File.join(dest_path, ARCHIVE_META_FILE)

      # Both the move destination AND the metadata file are checked. The
      # metadata write is a separate target from base_path, so ownership of the
      # entry says nothing about it: a symlink named .archive_meta.yml inside an
      # entry this provider legitimately owns would otherwise carry an
      # attacker-supplied reason to any file this process can write.
      unless PathContainment.contained?(@knowledge_dir, dest_path) &&
             PathContainment.contained?(@knowledge_dir, meta_path)
        return { success: false, error: "Invalid knowledge name '#{name}': archive destination resolves outside the knowledge directory" }
      end

      FileUtils.mv(skill.base_path, dest_path)

      # Re-checked after the move: the entry that just arrived may itself carry
      # a .archive_meta.yml symlink, which only becomes a path under dest_path
      # once it is there.
      unless PathContainment.contained?(dest_path, meta_path)
        FileUtils.rm_f(meta_path)
      end

      # Create archive metadata file
      meta = {
        'archived_at' => Time.now.iso8601,
        'archived_reason' => reason,
        'superseded_by' => superseded_by,
        'original_path' => skill.base_path,
        'content_hash' => content_hash
      }
      File.write(meta_path, meta.to_yaml)

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
      unless PathContainment.safe_segment?(name)
        return { success: false, error: "Invalid knowledge name '#{name}': not a single path segment" }
      end

      if reserved_name?(name)
        return { success: false, error: "Invalid knowledge name '#{name}': reserved by the knowledge store" }
      end

      archived_root = File.join(@knowledge_dir, ARCHIVED_DIR)
      archived_path = File.join(archived_root, name)
      active_path = File.join(@knowledge_dir, name)
      archived_meta = File.join(archived_path, ARCHIVE_META_FILE)
      active_meta = File.join(active_path, ARCHIVE_META_FILE)

      # The archive root is a path this method did not choose. If `.archived` is
      # a symlink out of the store, containment asked against it would answer
      # about the wrong root and this move would bring an arbitrary outside
      # directory in as L1 knowledge. Every path below is bounded by
      # @knowledge_dir, not by the archive root.
      return archive_root_escaped unless PathContainment.contained?(@knowledge_dir, archived_root)

      unless File.directory?(archived_path) && PathContainment.contained?(@knowledge_dir, archived_path)
        return { success: false, error: "Archived knowledge '#{name}' not found" }
      end

      # Every path this method reads, moves or deletes — not just the two ends.
      unless PathContainment.contained?(@knowledge_dir, active_path) &&
             PathContainment.contained?(archived_path, archived_meta) &&
             PathContainment.contained?(@knowledge_dir, active_meta)
        return { success: false, error: "Invalid knowledge name '#{name}': resolves outside the knowledge directory" }
      end

      # Check if active knowledge with same name exists
      if File.directory?(active_path)
        return { success: false, error: "Active knowledge '#{name}' already exists. Rename or delete it first." }
      end

      # Read archive metadata
      meta_file = archived_meta
      meta = File.exist?(meta_file) ? YAML.safe_load(File.read(meta_file)) : {}

      # Move back to active
      FileUtils.mv(archived_path, active_path)

      # Remove archive metadata file. Re-checked after the move for the same
      # reason as in #archive: the entry may carry a symlink by that name, and
      # rm_f would follow it.
      FileUtils.rm_f(active_meta) if PathContainment.contained?(active_path, active_meta)

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
      return [] unless PathContainment.contained?(@knowledge_dir, archived_dir)

      Dir[File.join(archived_dir, '*')].select do |f|
        File.directory?(f) && PathContainment.contained?(@knowledge_dir, f)
      end.map do |dir|
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
      return nil unless PathContainment.safe_segment?(name)

      archived_root = File.join(@knowledge_dir, ARCHIVED_DIR)
      archived_path = File.join(archived_root, name)
      return nil unless File.directory?(archived_path) && PathContainment.contained?(archived_root, archived_path)

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
      return false unless PathContainment.safe_segment?(name)

      archived_root = File.join(@knowledge_dir, ARCHIVED_DIR)
      archived_path = File.join(archived_root, name)
      File.directory?(archived_path) && PathContainment.contained?(archived_root, archived_path)
    end

    # Names the store keeps for itself.
    #
    # `.archived` is where archived entries live; accepted as an ordinary entry
    # name it can be claimed on a fresh store before the archive directory first
    # exists, and a later delete of that "entry" removes the whole archive while
    # being recorded as the deletion of one entry.
    #
    # BACKUP_DIR_PATTERN is the store's other self-reservation: `skill_dirs`
    # and `external_skill_dirs` filter those names out of every enumeration, so
    # an entry created under one is recorded on the chain and retrievable by
    # name while being invisible to `knowledge_list` and to audit.
    #
    # Any directory name this store manages for itself belongs here. If another
    # is introduced, add it — the filters that hide it and this predicate have
    # to name the same set.
    def reserved_name?(name)
      return false unless name.is_a?(String)

      name == ARCHIVED_DIR || backup_dir?(name)
    end

    # True if this provider owns the entry, i.e. it lives inside the store this
    # provider writes to.
    #
    # Public because a caller that has to choose between updating and creating
    # needs the answer: resolvability is not write authority, and deciding by
    # `get` alone sends an update at an entry this provider will refuse.
    #
    # `get` deliberately searches external SkillSet directories after the main
    # store — that is how shipped knowledge is read (see the note on
    # add_external_dir: external knowledge is read-only). The mutators used to
    # inherit that reach and acted on whatever `get` had resolved, so an
    # ordinary name with no ".." and no symlink in it rewrote, moved or removed
    # files belonging to an installed SkillSet. Read authority and write
    # authority are different scopes; this is where they part.
    def owned?(skill)
      base = skill.respond_to?(:base_path) ? skill.base_path : nil
      return false unless base

      PathContainment.contained?(@knowledge_dir, base)
    end

    # The refusal names the diagnosis and the remedy. `owned?` is source-
    # agnostic — add_external_dir accepts any directory and any source label —
    # so the message says where the entry is, not what kind of thing owns it.
    def not_owned(name)
      { success: false,
        error: "Knowledge '#{name}' lives outside this store and is read-only here. " \
               "To keep a local version, create it under this instance's knowledge directory instead of updating it in place." }
    end

    def archive_root_escaped
      { success: false,
        error: "The archive directory (#{ARCHIVED_DIR}) resolves outside the knowledge directory; refusing to move anything through it" }
    end

    private

    # Register the knowledge directories declared by every enabled SkillSet.
    #
    # `knowledge_dirs` in skillset.json is the single declaration of what a
    # SkillSet contributes to L1. Resolving it here — instead of relying on each
    # SkillSet to register itself during load! — keeps the declaration
    # load-bearing for every provider instance, including the short-lived ones
    # tools build per call. Without this, knowledge bundled with a SkillSet is
    # write-only: present on disk, declared in the manifest, and unreachable by
    # name.
    #
    # `knowledge_dirs` declares individual entry directories, while an external
    # registration covers a container of entries. Declared entries are therefore
    # grouped by their container and exposed via `only:`, so that knowledge a
    # SkillSet ships but does not declare stays invisible — proximity on disk is
    # not a declaration.
    #
    # Failure is isolated per SkillSet and overall: a malformed manifest or an
    # unreadable directory degrades to "that SkillSet contributes no knowledge",
    # never to a broken knowledge layer.
    def register_skillset_knowledge_dirs
      manager = SkillSetManager.new

      manager.enabled_skillsets.each do |skillset|
        skillset.knowledge_dirs.group_by { |dir| File.dirname(dir) }.each do |container, entries|
          add_external_dir(container,
                           source: "skillset:#{skillset.name}",
                           layer: skillset.layer,
                           index: skillset.index_knowledge?,
                           only: entries.map { |e| File.basename(e) })
        end
      rescue StandardError => e
        warn "[KnowledgeProvider] Skipped knowledge dirs for SkillSet '#{skillset.name}': #{e.message}"
      end
    rescue StandardError => e
      warn "[KnowledgeProvider] SkillSet knowledge registration skipped: #{e.message}"
    end

    def vector_search
      @vector_search ||= VectorSearch.create(index_path: KairosMcp.knowledge_index_path)
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

    # Enumeration is filtered by containment for the same reason the reads are.
    # Without it `list`, `search` and `rebuild_index` parse and read entries that
    # `get` refuses, so out-of-store content reaches tool output and the vector
    # index while the read path reports it as absent. ContextManager#context_dirs
    # was given this filter; L1 was left without it.
    def skill_dirs
      Dir[File.join(@knowledge_dir, '*')].select do |f|
        File.directory?(f) &&
          File.basename(f) != ARCHIVED_DIR &&
          !backup_dir?(f) &&
          PathContainment.contained?(@knowledge_dir, f)
      end
    end

    # List subdirectories in an external knowledge dir
    def external_skill_dirs(dir, only: nil)
      return [] unless File.directory?(dir)

      dirs = Dir[File.join(dir, '*')].select do |f|
        File.directory?(f) && !backup_dir?(f) && PathContainment.contained?(dir, f)
      end
      return dirs unless only

      dirs.select { |f| only.include?(File.basename(f)) }
    end

    # Detect upgrade backup directories (`.bak.<timestamp>`, `<name>.bak.<timestamp>`).
    # These are produced by `kairos-chain upgrade` and may contain stale/broken frontmatter
    # from prior gem versions; loader must not scan them.
    def backup_dir?(path)
      basename = File.basename(path)
      basename.match?(BACKUP_DIR_PATTERN)
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
        service = StateCommit::CommitService.new(user_context: @user_context)
        service.check_and_auto_commit
      end
    rescue StandardError => e
      # Log but don't fail if state commit tracking fails
      warn "[KnowledgeProvider] Failed to track pending change: #{e.message}"
    end
  end
end
