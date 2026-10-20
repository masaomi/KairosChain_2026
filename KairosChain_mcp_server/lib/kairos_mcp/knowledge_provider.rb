# frozen_string_literal: true

require 'digest'
require 'json'
require 'fileutils'
require 'yaml'
require 'securerandom'
require_relative 'anthropic_skill_parser'
require_relative 'path_containment'
require_relative 'skillset_manager'
require_relative 'kairos_chain/chain'
require_relative 'kairos_chain/landed_probe'
require_relative 'l1_history'
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

      # C2: store the body before the file write and before the chain record
      refusal = keep_bodies!(content)
      return refusal if refusal

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

      # C2: both bodies kept before anything is written or recorded
      refusal = keep_bodies!(prev_content, new_content)
      return refusal if refusal

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

      # C2: keep the previous body before the directory goes away
      refusal = keep_bodies!(prev_content)
      return refusal if refusal

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

    # C3: return an entry to a body already kept in history
    def restore(name, content_hash, reason: nil)
      unless content_hash.to_s.match?(L1History::HASH_PATTERN)
        return { success: false, error: "invalid content hash: #{content_hash}" }
      end

      # A quarantine left by an interrupted erasure is settled first, so a body
      # whose erasure is on the chain is not restored from its quarantine.
      settle_quarantine!

      # The body must be present before anything else is decided
      body = history_store.retrievable?(content_hash) ? history_store.fetch(content_hash) : nil
      return { success: false, error: "body not retrievable: #{content_hash}" } if body.nil?

      skill = get(name)

      if skill
        return not_owned(name) unless owned?(skill)

        prev_content = File.read(skill.md_file_path)
        prev_hash = Digest::SHA256.hexdigest(prev_content)
        if prev_hash == content_hash
          return { success: false, error: "#{name} already holds the content of hash #{content_hash}" }
        end

        # C2: previous body and restored body, both before the write
        refusal = keep_bodies!(prev_content, body)
        return refusal if refusal

        tracked_action = 'update'
      else
        # Same name checks as create, in the same order (safe_segment first:
        # it is the check that tolerates a non-String argument).
        unless PathContainment.safe_segment?(name)
          return { success: false, error: "Invalid knowledge name #{name.inspect}: not a single path segment" }
        end
        return { success: false, error: "Invalid knowledge name '#{name}': reserved by the knowledge store" } if reserved_name?(name)

        skill_dir = File.join(@knowledge_dir, name)
        unless PathContainment.contained?(@knowledge_dir, skill_dir)
          return { success: false, error: "Invalid knowledge name '#{name}': resolves outside the knowledge directory" }
        end
        return { success: false, error: "Knowledge '#{name}' already exists" } if File.exist?(skill_dir)

        refusal = keep_bodies!(body)
        return refusal if refusal

        prev_hash = nil
        tracked_action = 'create'
      end

      # restore_id makes the record unique, so the landed check below finds
      # this restore and not an identical one made in the same second.
      entry = hash_reference_entry(
        name: name,
        action: 'restore',
        prev_hash: prev_hash,
        next_hash: content_hash,
        reason: "returned to content of hash #{content_hash}#{reason ? ": #{reason}" : ''}",
        extra: { restored_from: content_hash, restore_id: SecureRandom.hex(8) }
      )
      mark = KairosChain::LandedProbe.mark(storage_backend: storage_backend)
      status = nil
      error = nil
      attempted = false

      # Undo touches the live file only while it holds the restored bytes. A
      # write that never took effect, or content a same-name writer has put
      # there since, is not this restore's to undo.
      live_md = skill ? skill.md_file_path : File.join(skill_dir, "#{name}.md")
      holds_restored = lambda do
        File.file?(live_md) && Digest::SHA256.hexdigest(File.binread(live_md)) == content_hash
      rescue StandardError
        false
      end

      # The live write sits inside the guarded region, so no interrupt can fall
      # between the write and the ensure that undoes it.
      begin
        restored_skill = if skill
                           AnthropicSkillParser.update(skill.base_path, body)
                         else
                           AnthropicSkillParser.create(@knowledge_dir, name, body)
                         end
        attempted = true
        status, error = append_entry(entry, mark)
      ensure
        # In ensure, so an interrupt or a thread kill cannot leave the live
        # entry changed without its record. A record that is on the chain
        # stands whatever add_block raised; any other answer, including an
        # unknown one, puts the live entry back exactly as it was: an entry
        # that already existed gets its previous body written back, one that
        # was recreated here is removed again -- provided it still holds what
        # this restore wrote.
        begin
          status ||= KairosChain::LandedProbe.status(mark, entry, storage_backend: storage_backend) if attempted
        ensure
          if status != :landed && holds_restored.call
            if skill
              AnthropicSkillParser.update(skill.base_path, prev_content)
            else
              FileUtils.rm_rf(skill_dir)
            end
          end
        end
      end

      unless status == :landed
        return { success: false, error: "restore not recorded (#{error&.message || status}); entry left as it was" }
      end

      # After the record, and outside it: a metadata failure is reported but
      # never undoes a restore the chain already holds.
      update_knowledge_meta(name, content_hash)
      update_vector_index(name, body, restored_skill)
      track_pending_change(layer: 'L1', action: tracked_action, skill_id: name, reason: reason)

      {
        success: true,
        name: name,
        action: 'restore',
        content_hash: content_hash,
        restored_from: content_hash
      }
    end

    # C3: every body this entry has pointed at, in chain order
    def history(name)
      # Settled first, so `retrievable` below reflects what the chain records.
      settle_quarantine!
      chain = KairosChain::Chain.new(storage_backend: storage_backend)
      # L1: start inactive; only an l1_history_activation record flips this.
      active = false
      rows = []

      chain.chain.each do |block|
        Array(block.data).each do |raw|
          record = begin
            JSON.parse(raw, symbolize_names: true)
          rescue JSON::ParserError, TypeError
            nil
          end
          next unless record.is_a?(Hash)

          case record[:type]
          when 'l1_history_activation'
            # Activation threads forward from the block that declared it
            flag = record.key?(:active) ? record[:active] : record[:enabled]
            active = (flag == true || flag == 'true')
          when 'knowledge_update'
            next unless record[:knowledge_id] == name && record[:next_hash]

            rows << {
              index: block.index,
              timestamp: record[:timestamp],
              action: record[:action],
              next_hash: record[:next_hash],
              retrievable: begin
                history_store.retrievable?(record[:next_hash])
              rescue ArgumentError
                false
              end,
              recorded_while_active: active
            }
          end
        end
      end

      rows
    end

    # C4: drop one stored body; the chain keeps the fact of the removal
    def erase_body(name, content_hash, reason:)
      if reason.nil? || reason.to_s.strip.empty?
        return { success: false, error: 'a reason is required' }
      end
      unless content_hash.to_s.match?(L1History::HASH_PATTERN)
        return { success: false, error: "invalid content hash: #{content_hash}" }
      end
      # Nothing was ever stored; checked before the lock, which would create
      # the store root.
      unless File.directory?(history_store.root)
        return { success: false, error: "body not stored: #{content_hash}" }
      end

      # The checks, the quarantine and the record run under one lock, so a
      # second erasure cannot settle this one's quarantine as a leftover while
      # its record is still being appended.
      history_store.with_erase_lock do
        settle_quarantine!(locked: true)

        # E3: live content blocks the erasure. Judged per directory, so an entry
        # whose directory name differs from its declared name is still seen.
        live = live_directories_for_body(content_hash)
        unless live.empty?
          return { success: false,
                   error: "body is live content in: #{live.sort.join(', ')}" }
        end

        # E2: the hash must be cited by a knowledge_update of this entry, and by
        # no other entry. A hash cited elsewhere is a body shared between entries,
        # and erasing it would remove the other entry's history too.
        citing = knowledge_ids_citing_body(content_hash)
        unless citing.include?(name)
          return { success: false,
                   error: "#{name} never pointed at this body: #{content_hash}" }
        end
        shared_with = (citing - [name]).sort
        unless shared_with.empty?
          return { success: false,
                   error: "body is shared with: #{shared_with.join(', ')}" }
        end

        unless history_store.retrievable?(content_hash)
          return { success: false, error: "body not stored: #{content_hash}" }
        end

        # E1: quarantine first, append second. Nothing is removed until the
        # erasure record is on the chain. The record carries the quarantine's
        # erase id, which is what lets a leftover quarantine be matched to
        # exactly this record later.
        # The mark is taken before the quarantine, so the only step between the
        # quarantine and the guarded region below is building the record. A
        # quarantine orphaned there anyway is settled by settle_quarantine!.
        mark = KairosChain::LandedProbe.mark(storage_backend: storage_backend)
        erase_id = history_store.begin_erase(content_hash)
        return { success: false, error: "body not stored: #{content_hash}" } unless erase_id

        entry = {
          type: 'l1_body_erasure',
          layer: 'L1',
          knowledge_id: name,
          content_hash: content_hash,
          erase_id: erase_id,
          reason: reason,
          timestamp: Time.now.iso8601
        }.to_json
        status = nil
        error = nil
        settled = true

        begin
          status, error = append_entry(entry, mark)
        ensure
          # In ensure, so an interrupt cannot leave a quarantine behind without
          # deciding it. Landed: drop the bytes. Known absent: put them back.
          # Unknown: leave the quarantine; settle_quarantine! decides it from the
          # chain once the chain can be read.
          begin
            status ||= KairosChain::LandedProbe.status(mark, entry, storage_backend: storage_backend)
          ensure
            begin
              case status
              when :landed then history_store.commit_erase(content_hash, erase_id)
              when :absent then history_store.abort_erase(content_hash, erase_id)
              end
            rescue StandardError => e
              # The quarantine stays and is settled on the next history access.
              warn "[l1_history] quarantine #{erase_id} left for settling: #{e.message}"
              settled = false
            end
          end
        end

        case status
        when :landed
          { success: true, name: name, content_hash: content_hash, erased: settled }
        when :absent
          { success: false, error: "erasure not recorded, body kept: #{error&.message}" }
        else
          { success: false,
            error: "erasure outcome unknown (#{error&.message}); the body stays quarantined " \
                   'and is settled from the chain on the next history access' }
        end
      end
    end

    # Settle quarantines an interrupted erasure left behind (L1History
    # #reconcile_quarantine!). Cheap when there are none: the chain is read only
    # when a quarantine exists. Takes the erase lock unless the caller holds it.
    private def settle_quarantine!(locked: false)
      return if history_store.quarantined.empty?
      return history_store.reconcile_quarantine!(recorded_erase_ids) if locked

      history_store.with_erase_lock { history_store.reconcile_quarantine!(recorded_erase_ids) }
    end

    # Erase ids in l1_body_erasure records on the chain; nil when the chain
    # cannot be read, which leaves every quarantine undecided.
    private def recorded_erase_ids
      chain = KairosChain::Chain.new(storage_backend: storage_backend)
      return [] if chain.load_state == :absent
      return nil unless chain.load_state == :readable

      chain.chain.each_with_object([]) do |block, ids|
        Array(block.data).each do |raw|
          record = begin
            JSON.parse(raw.to_s)
          rescue JSON::ParserError
            nil
          end
          next unless record.is_a?(Hash) && record['type'] == 'l1_body_erasure' && record['erase_id']

          ids << record['erase_id']
        end
      end
    rescue StandardError
      nil
    end

    # E3 helper. Every entry directory whose current body hashes to
    # content_hash blocks the erasure: the main knowledge dir and every external
    # knowledge dir a SkillSet registered, as `list` exposes them. Each
    # directory is parsed on its own and never looked up by its declared name,
    # which is what let a directory whose name differs slip past the old guard.
    # A directory that cannot be parsed is skipped rather than treated as a
    # match.
    private def live_directories_for_body(content_hash)
      candidates = skill_dirs.map { |dir| [dir, File.basename(dir)] }
      @external_dirs.each do |ext|
        external_skill_dirs(ext[:dir], only: ext[:only]).each do |dir|
          candidates << [dir, "#{ext[:source]}:#{File.basename(dir)}"]
        end
      end

      candidates.each_with_object([]) do |(dir, label), found|
        begin
          skill = AnthropicSkillParser.parse(dir)
          path = skill && skill.md_file_path
          next unless path && File.exist?(path)

          found << label if Digest::SHA256.hexdigest(File.read(path)) == content_hash
        rescue StandardError
          next
        end
      end
    end

    # E2 helper. The knowledge ids whose knowledge_update records cite this hash
    # as the body before or after the update. Each block's data is an array of
    # JSON strings; an unparsable entry is skipped rather than fatal.
    private def knowledge_ids_citing_body(content_hash)
      ids = []
      KairosChain::Chain.new(storage_backend: storage_backend).chain.each do |block|
        data = block.respond_to?(:data) ? block.data : block['data']
        Array(data).each do |raw|
          record = begin
            JSON.parse(raw.to_s)
          rescue StandardError
            nil
          end
          next unless record.is_a?(Hash)
          next unless record['type'] == 'knowledge_update'
          next unless [record['prev_hash'], record['next_hash']].include?(content_hash)

          ids << record['knowledge_id'] if record['knowledge_id']
        end
      end
      ids.uniq
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

      # C2: `content` is the body being archived; keep it before the move
      refusal = keep_bodies!(content)
      return refusal if refusal

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

      # C2: read the archived body while it is still at the archived path
      archived_body = File.read(AnthropicSkillParser.parse(archived_path).md_file_path)
      refusal = keep_bodies!(archived_body)
      return refusal if refusal

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

    # Memoized body store
    def history_store
      @history_store ||= L1History.new(@knowledge_dir)
    end

    # C2: store every body whose hash enters the chain, before any write.
    # nil = nothing to refuse (stored, or history inactive); hash = refusal.
    def keep_bodies!(*bodies)
      unless defined?(@history_active)
        if L1History.enabled?
          begin
            FileUtils.mkdir_p(history_store.root)
          rescue StandardError => e
            # L2: no store root means nothing may be appended; stay unmemoized
            # so a later write retries.
            return { success: false, error: "history store unavailable: #{e.message}" }
          end
        end

        @history_active = begin
          history_store.sync_activation!(KairosChain::Chain.new(storage_backend: storage_backend))
        rescue StandardError => e
          # Chain unwritable: warn and fall back; never block L1 writes on activation
          warn "[l1_history] activation sync failed: #{e.message}"
          L1History.enabled?
        end
      end
      return nil unless @history_active

      bodies.compact.each do |body|
        begin
          history_store.store(body)
        rescue StandardError => e
          return { success: false, error: "history store failed: #{e.message}" }
        end
      end

      nil
    end

    # Record a knowledge_update. A failed append is warned about and the caller
    # continues (restore, which must undo its write, appends on its own path).
    def record_hash_reference(name:, action:, prev_hash:, next_hash:, reason:, extra: {})
      entry = hash_reference_entry(name: name, action: action, prev_hash: prev_hash,
                                   next_hash: next_hash, reason: reason, extra: extra)
      status, error = append_entry(entry, KairosChain::LandedProbe.mark(storage_backend: storage_backend))
      unless status == :landed
        # Log but don't fail if blockchain recording fails
        warn "Failed to record to blockchain: #{error&.message || status}"
        return
      end

      update_knowledge_meta(name, next_hash)
    end

    def hash_reference_entry(name:, action:, prev_hash:, next_hash:, reason:, extra: {})
      {
        type: 'knowledge_update',
        layer: 'L1',
        knowledge_id: name,
        action: action,
        prev_hash: prev_hash,
        next_hash: next_hash,
        reason: reason,
        timestamp: Time.now.iso8601
      }.merge(extra).to_json
    end

    # Append one entry. => [status, error]. status is :landed when add_block
    # returned, or when it raised but the entry is on the chain after `mark`
    # (LandedProbe); otherwise :absent or :unknown, with the StandardError that
    # add_block raised. An exception that is not a StandardError propagates;
    # a caller that must undo something on failure probes again in its ensure.
    def append_entry(entry, mark)
      KairosChain::Chain.new(storage_backend: storage_backend).add_block([entry])
      [:landed, nil]
    rescue StandardError => e
      [KairosChain::LandedProbe.status(mark, entry, storage_backend: storage_backend), e]
    end

    # SQLite keeps knowledge metadata beside the chain. Runs only after the
    # record landed, and a failure here never reaches the record's caller: the
    # chain already holds the change.
    def update_knowledge_meta(name, next_hash)
      return unless storage_backend.backend_type == :sqlite

      if next_hash
        skill = get(name)
        storage_backend.save_knowledge_meta(name, {
          content_hash: next_hash,
          version: skill&.version,
          description: skill&.description,
          tags: skill&.tags
        })
      else
        storage_backend.delete_knowledge_meta(name)
      end
    rescue StandardError => e
      warn "[KnowledgeProvider] Recorded; knowledge metadata update failed: #{e.message}"
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
