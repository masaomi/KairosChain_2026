# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'set'
require 'base64'
require 'zlib'
require 'rubygems/package'
require 'rubygems/requirement'
require 'rubygems/version'
require_relative 'skillset'
require_relative '../kairos_mcp'

module KairosMcp
  # Manages SkillSet plugins in .kairos/skillsets/
  #
  # Handles discovery, loading, dependency resolution, enable/disable state,
  # and layer-aware governance (blockchain recording, RAG indexing).
  class SkillSetManager
    SAFE_NAME_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/
    MAX_NAME_LENGTH = 64

    attr_reader :skillsets_dir

    def initialize(skillsets_dir: nil)
      @skillsets_dir = skillsets_dir || KairosMcp.skillsets_dir
      @config_path = File.join(@skillsets_dir, 'config.yml')
      @config = load_config
    end

    # All discovered SkillSets (enabled and disabled)
    def all_skillsets
      discover_skillsets
    end

    # Only enabled SkillSets, sorted by dependency order
    def enabled_skillsets
      enabled = discover_skillsets.select { |ss| enabled?(ss.name) }
      sort_by_dependencies(enabled)
    end

    # Check if a SkillSet is enabled
    def enabled?(name)
      ss_config = @config.dig('skillsets', name.to_s)
      return true unless ss_config # Default: enabled if no explicit config

      ss_config['enabled'] != false
    end

    # Enable a SkillSet
    def enable(name)
      skillset = find_skillset(name)
      raise ArgumentError, "SkillSet '#{name}' not found" unless skillset

      check_dependencies!(skillset)

      set_config(name, 'enabled', true)
      record_skillset_event(skillset, 'enable')
      { success: true, name: name, layer: skillset.layer }
    end

    # Disable a SkillSet
    def disable(name)
      skillset = find_skillset(name)
      raise ArgumentError, "SkillSet '#{name}' not found" unless skillset

      # L0 SkillSets require human approval to disable
      if skillset.layer == :L0
        return { success: false, error: "L0 SkillSet '#{name}' requires human approval to disable", requires_approval: true }
      end

      check_dependents!(name)

      set_config(name, 'enabled', false)
      record_skillset_event(skillset, 'disable')
      { success: true, name: name }
    end

    # Install a SkillSet from a local path.
    # With force: true, replaces an existing SkillSet (preserves config/ files).
    def install(source_path, layer_override: nil, force: false)
      source_path = File.expand_path(source_path)
      raise ArgumentError, "Source path not found: #{source_path}" unless File.directory?(source_path)

      temp_skillset = Skillset.new(source_path)
      raise ArgumentError, "Invalid SkillSet: missing required fields" unless temp_skillset.valid?
      validate_skillset_name!(temp_skillset.name)

      dest = File.join(@skillsets_dir, temp_skillset.name)
      if File.directory?(dest)
        if force
          # Preserve user config files before replacing
          config_dir = File.join(dest, 'config')
          saved_configs = {}
          if File.directory?(config_dir)
            Dir.glob(File.join(config_dir, '*')).each do |f|
              saved_configs[File.basename(f)] = File.read(f)
            end
          end

          FileUtils.rm_rf(dest)

          # Copy new version
          FileUtils.cp_r(source_path, dest)

          # Restore user configs
          unless saved_configs.empty?
            FileUtils.mkdir_p(File.join(dest, 'config'))
            saved_configs.each do |name, content|
              File.write(File.join(dest, 'config', name), content)
            end
          end
        else
          raise ArgumentError, "SkillSet '#{temp_skillset.name}' already installed at #{dest}. Use --force to reinstall."
        end
      else
        FileUtils.mkdir_p(@skillsets_dir)
        FileUtils.cp_r(source_path, dest)
      end

      installed = Skillset.new(dest)
      installed.layer = layer_override if layer_override

      if layer_override
        set_config(installed.name, 'layer_override', layer_override.to_s)
      end

      set_config(installed.name, 'enabled', true)
      record_skillset_event(installed, force ? 'reinstall' : 'install')

      { success: true, name: installed.name, version: installed.version, layer: installed.layer, path: dest }
    end

    # Check for available SkillSet upgrades from gem templates.
    # Also detects NEW SkillSets in templates that are not yet installed.
    #
    # @return [Array<Hash>] List of upgradable/new skillsets with version info
    def upgrade_check
      results = []
      templates_dir = File.join(KairosMcp.gem_root, 'templates', 'skillsets')
      return results unless File.directory?(templates_dir)

      installed_names = all_skillsets.map(&:name)

      # Check existing installed SkillSets for upgrades
      all_skillsets.each do |installed|
        template_path = File.join(templates_dir, installed.name)
        next unless File.directory?(template_path)

        template_ss = Skillset.new(template_path)
        next unless template_ss.valid?

        installed_ver = Gem::Version.new(installed.version)
        template_ver = Gem::Version.new(template_ss.version)

        changed_files = diff_files(template_path, installed.path)

        if template_ver > installed_ver || changed_files.any?
          results << {
            name: installed.name,
            installed_version: installed.version,
            available_version: template_ss.version,
            version_bump: template_ver > installed_ver,
            changed_files: changed_files,
            new_skillset: false
          }
        end
      end

      # Detect NEW SkillSets in templates not yet installed
      Dir.children(templates_dir).sort.each do |name|
        template_path = File.join(templates_dir, name)
        next unless File.directory?(template_path)
        next if installed_names.include?(name)

        template_ss = Skillset.new(template_path)
        next unless template_ss.valid?

        results << {
          name: name,
          installed_version: nil,
          available_version: template_ss.version,
          description: template_ss.description,
          version_bump: false,
          changed_files: [],
          new_skillset: true
        }
      end

      results
    end

    # Apply SkillSet upgrades from gem templates.
    # Handles both upgrades (existing) and new installs.
    #
    # @param names [Array<String>, nil] specific names to upgrade/install, or nil for all
    # @return [Array<Hash>] results
    def upgrade_apply(names: nil)
      upgrades = upgrade_check
      upgrades = upgrades.select { |u| names.include?(u[:name]) } if names

      results = []
      upgrades.each do |info|
        template_path = File.join(KairosMcp.gem_root, 'templates', 'skillsets', info[:name])

        if info[:new_skillset]
          # Install new SkillSet from template
          result = install(template_path)
          results << { name: info[:name], from: nil, to: info[:available_version],
                       action: 'installed', files_updated: 0 }
        else
          # Upgrade existing: copy changed files
          dest = File.join(@skillsets_dir, info[:name])
          info[:changed_files].each do |rel_path|
            src = File.join(template_path, rel_path)
            dst = File.join(dest, rel_path)
            FileUtils.mkdir_p(File.dirname(dst))
            FileUtils.cp(src, dst) if File.exist?(src)
          end

          installed = Skillset.new(dest)
          record_skillset_event(installed, 'upgrade')
          results << { name: info[:name], from: info[:installed_version], to: info[:available_version],
                       action: 'upgraded', files_updated: info[:changed_files].size }
        end
      end

      results
    end

    # List all available SkillSets from gem templates with install status.
    #
    # @return [Array<Hash>] list with name, version, description, installed status
    def available_skillsets
      templates_dir = File.join(KairosMcp.gem_root, 'templates', 'skillsets')
      return [] unless File.directory?(templates_dir)

      installed_map = all_skillsets.each_with_object({}) { |ss, h| h[ss.name] = ss }

      Dir.children(templates_dir).sort.filter_map do |name|
        template_path = File.join(templates_dir, name)
        next unless File.directory?(template_path)

        template_ss = Skillset.new(template_path)
        next unless template_ss.valid?

        installed = installed_map[name]
        {
          name: name,
          available_version: template_ss.version,
          description: template_ss.description,
          installed: !installed.nil?,
          installed_version: installed&.version,
          enabled: installed ? enabled?(name) : false,
          upgrade_available: installed ? Gem::Version.new(template_ss.version) > Gem::Version.new(installed.version) : false
        }
      end
    end

    # Remove a SkillSet
    def remove(name)
      skillset = find_skillset(name)
      raise ArgumentError, "SkillSet '#{name}' not found" unless skillset

      if skillset.layer == :L0
        return { success: false, error: "L0 SkillSet '#{name}' requires human approval to remove", requires_approval: true }
      end

      check_dependents!(name)
      record_skillset_event(skillset, 'remove')

      FileUtils.rm_rf(skillset.path)
      remove_config(name)

      { success: true, name: name }
    end

    # Package a knowledge-only SkillSet as a Base64-encoded tar.gz archive
    def package(name)
      skillset = find_skillset(name)
      raise ArgumentError, "SkillSet '#{name}' not found" unless skillset
      raise SecurityError, "Only knowledge-only SkillSets can be packaged for exchange" unless skillset.knowledge_only?

      tar_gz = create_tar_gz(skillset.path, skillset.name)
      {
        name: skillset.name,
        version: skillset.version,
        layer: skillset.layer.to_s,
        description: skillset.description,
        content_hash: skillset.content_hash,
        file_list: skillset.file_list,
        archive_base64: Base64.strict_encode64(tar_gz),
        packaged_at: Time.now.utc.iso8601
      }
    end

    # Install a SkillSet from a Base64-encoded tar.gz archive.
    # With force: true, replaces an existing SkillSet (preserves config/ files).
    def install_from_archive(archive_data, layer_override: nil, force: false)
      archive_data = symbolize_keys(archive_data)
      name = archive_data[:name]
      raise ArgumentError, "Archive missing 'name'" unless name
      validate_skillset_name!(name)
      raise ArgumentError, "Archive missing 'archive_base64'" unless archive_data[:archive_base64]

      dest = File.join(@skillsets_dir, name)
      if File.directory?(dest) && !force
        raise ArgumentError, "SkillSet '#{name}' already installed at #{dest}. Use force: true to reinstall."
      end

      Dir.mktmpdir('kairos_ss_install') do |tmpdir|
        tar_gz_data = Base64.strict_decode64(archive_data[:archive_base64])
        extract_tar_gz(tar_gz_data, tmpdir)

        extracted = File.join(tmpdir, name)
        raise ArgumentError, "Archive does not contain expected directory '#{name}'" unless File.directory?(extracted)

        temp_skillset = Skillset.new(extracted)
        raise ArgumentError, "Invalid SkillSet: missing required fields" unless temp_skillset.valid?

        unless temp_skillset.name == name
          raise ArgumentError, "Archive name mismatch: declared '#{name}' but skillset.json contains '#{temp_skillset.name}'"
        end

        unless temp_skillset.knowledge_only?
          raise SecurityError, "Refusing to install SkillSet with executable code (tools/ or lib/) from archive"
        end

        if archive_data[:content_hash]
          actual_hash = temp_skillset.content_hash
          unless actual_hash == archive_data[:content_hash]
            raise SecurityError, "Content hash mismatch: expected #{archive_data[:content_hash]}, got #{actual_hash}"
          end
        end

        # Force reinstall: stage in temp dir (already done above), then atomic swap
        if File.directory?(dest) && force
          # Preserve user config files
          config_dir = File.join(dest, 'config')
          saved_configs = {}
          if File.directory?(config_dir)
            Dir.glob(File.join(config_dir, '*')).each do |f|
              saved_configs[File.basename(f)] = File.read(f) if File.file?(f)
            end
          end

          # Atomic swap: remove old, move new into place
          FileUtils.rm_rf(dest)
          FileUtils.cp_r(extracted, dest)

          # Restore preserved config
          unless saved_configs.empty?
            FileUtils.mkdir_p(File.join(dest, 'config'))
            saved_configs.each do |fname, content|
              File.write(File.join(dest, 'config', fname), content)
            end
          end
        else
          FileUtils.mkdir_p(@skillsets_dir)
          FileUtils.cp_r(extracted, dest)
        end

        installed = Skillset.new(dest)
        installed.layer = layer_override if layer_override

        set_config(installed.name, 'layer_override', layer_override.to_s) if layer_override
        set_config(installed.name, 'enabled', true)
        record_skillset_event(installed, force ? 'reinstall_from_archive' : 'install_from_archive')

        { success: true, name: installed.name, version: installed.version,
          layer: installed.layer, path: dest, content_hash: installed.content_hash }
      end
    end

    # Check if a SkillSet's dependencies can be satisfied locally.
    # Returns a structured result (does NOT raise).
    #
    # @param skillset [Skillset] A Skillset object (from archive or installed)
    # @return [Hash] { satisfiable:, missing:, version_mismatch:, disabled: }
    def check_installable_dependencies(skillset)
      result = { satisfiable: true, missing: [], version_mismatch: [], disabled: [] }
      skillset.depends_on_with_versions.each do |dep|
        installed = find_skillset(dep[:name])
        if installed.nil?
          result[:satisfiable] = false
          result[:missing] << dep[:name]
          next
        end

        unless enabled?(dep[:name])
          result[:disabled] << dep[:name]
        end

        next unless dep[:version]

        begin
          requirement = Gem::Requirement.new(*dep[:version].split(',').map(&:strip))
          unless requirement.satisfied_by?(Gem::Version.new(installed.version))
            result[:satisfiable] = false
            result[:version_mismatch] << {
              name: dep[:name],
              required: dep[:version],
              installed: installed.version
            }
          end
        rescue Gem::Requirement::BadRequirementError
          result[:satisfiable] = false
          result[:version_mismatch] << {
            name: dep[:name],
            required: dep[:version],
            installed: installed.version,
            error: 'invalid version constraint'
          }
        end
      end
      result
    end

    # Get info about a specific SkillSet
    def info(name)
      skillset = find_skillset(name)
      return nil unless skillset

      skillset.to_h.merge(enabled: enabled?(name))
    end

    # Find a SkillSet by name
    def find_skillset(name)
      all_skillsets.find { |ss| ss.name == name.to_s }
    end

    private

    # Compare files between template and installed SkillSet
    def diff_files(template_path, installed_path)
      changed = []
      Dir.glob(File.join(template_path, '**', '*')).each do |src|
        next if File.directory?(src)
        rel = src.sub("#{template_path}/", '')
        dst = File.join(installed_path, rel)

        if !File.exist?(dst)
          changed << rel
        elsif Digest::SHA256.file(src).hexdigest != Digest::SHA256.file(dst).hexdigest
          changed << rel
        end
      end
      changed
    end

    # Validate SkillSet name against safe pattern
    def validate_skillset_name!(name)
      raise ArgumentError, "SkillSet name cannot be empty" if name.nil? || name.to_s.strip.empty?
      raise ArgumentError, "SkillSet name too long (max #{MAX_NAME_LENGTH}): #{name}" if name.length > MAX_NAME_LENGTH
      unless SAFE_NAME_PATTERN.match?(name)
        raise ArgumentError, "Invalid SkillSet name '#{name}': must match #{SAFE_NAME_PATTERN.source}"
      end
    end

    # Discover all SkillSets in the skillsets directory
    def discover_skillsets
      return [] unless File.directory?(@skillsets_dir)

      Dir[File.join(@skillsets_dir, '*')].select { |d|
        File.directory?(d) && File.exist?(File.join(d, 'skillset.json'))
      }.filter_map { |d|
        ss = Skillset.new(d)
        # Apply layer override from config
        override = @config.dig('skillsets', ss.name, 'layer_override')
        ss.layer = override.to_sym if override
        ss if ss.valid?
      }
    end

    # Topological sort by depends_on
    def sort_by_dependencies(skillsets)
      name_map = skillsets.each_with_object({}) { |ss, h| h[ss.name] = ss }
      sorted = []
      visited = Set.new
      temp = Set.new

      visit = lambda do |ss|
        return if visited.include?(ss.name)
        return if temp.include?(ss.name) # circular dependency, skip

        temp.add(ss.name)
        ss.depends_on.each do |dep|
          visit.call(name_map[dep]) if name_map[dep]
        end
        temp.delete(ss.name)
        visited.add(ss.name)
        sorted << ss
      end

      skillsets.each { |ss| visit.call(ss) }
      sorted
    end

    # Verify all dependencies of a SkillSet are installed and enabled
    # Supports version constraints via depends_on_with_versions
    def check_dependencies!(skillset)
      skillset.depends_on_with_versions.each do |dep|
        installed = find_skillset(dep[:name])
        raise ArgumentError, "Missing dependency: #{dep[:name]}" unless installed
        raise ArgumentError, "Dependency not enabled: #{dep[:name]}" unless enabled?(dep[:name])

        # Version constraint check (Gem::Requirement compatible)
        if dep[:version]
          requirement = Gem::Requirement.new(*dep[:version].split(',').map(&:strip))
          installed_ver = Gem::Version.new(installed.version)
          unless requirement.satisfied_by?(installed_ver)
            raise ArgumentError,
              "Dependency version mismatch: #{dep[:name]} #{installed.version} " \
              "does not satisfy \"#{dep[:version]}\""
          end
        end
      end
    end

    # Verify no other enabled SkillSet depends on this one
    def check_dependents!(name)
      dependents = enabled_skillsets.select { |ss| ss.depends_on.include?(name.to_s) }
      return if dependents.empty?

      names = dependents.map(&:name).join(', ')
      raise ArgumentError, "Cannot disable/remove '#{name}': required by #{names}"
    end

    # Record a SkillSet lifecycle event to blockchain based on layer
    def record_skillset_event(skillset, action, reason: nil)
      blockchain_mode = blockchain_mode_for(skillset.layer)
      return if blockchain_mode == :none

      require_relative 'kairos_chain/chain'
      chain = KairosChain::Chain.new

      record = {
        type: 'skillset_event',
        layer: skillset.layer.to_s,
        skillset_name: skillset.name,
        skillset_version: skillset.version,
        action: action,
        content_hash: skillset.content_hash,
        reason: reason,
        timestamp: Time.now.iso8601
      }

      if blockchain_mode == :full
        record[:file_hashes] = skillset.all_file_hashes
      end

      chain.add_block([record.to_json])
    rescue StandardError => e
      warn "[SkillSetManager] Failed to record event to blockchain: #{e.message}"
    end

    def blockchain_mode_for(layer)
      case layer
      when :L0 then :full
      when :L1 then :hash_only
      when :L2 then :none
      else :none
      end
    end

    # Create a tar.gz archive from a directory, wrapping contents in a named folder
    def create_tar_gz(source_dir, archive_name)
      io = StringIO.new
      Zlib::GzipWriter.wrap(io) do |gz|
        Gem::Package::TarWriter.new(gz) do |tar|
          Dir[File.join(source_dir, '**', '*')].sort.each do |full_path|
            relative = full_path.sub("#{source_dir}/", '')
            stat = File.stat(full_path)

            if File.directory?(full_path)
              tar.mkdir("#{archive_name}/#{relative}", stat.mode)
            else
              content = File.binread(full_path)
              tar.add_file_simple("#{archive_name}/#{relative}", stat.mode, content.bytesize) do |tio|
                tio.write(content)
              end
            end
          end
        end
      end
      io.string
    end

    # Extract a tar.gz archive into target_dir with path traversal protection
    def extract_tar_gz(tar_gz_data, target_dir)
      target_dir = File.expand_path(target_dir)
      io = StringIO.new(tar_gz_data)
      Zlib::GzipReader.wrap(io) do |gz|
        Gem::Package::TarReader.new(gz) do |tar|
          tar.each do |entry|
            # Reject symlinks and hard links
            next if entry.header.typeflag == '2' # symlink
            next if entry.header.typeflag == '1' # hard link

            dest = File.expand_path(File.join(target_dir, entry.full_name))
            unless dest.start_with?(target_dir + '/') || dest == target_dir
              raise SecurityError, "Path traversal detected in archive: #{entry.full_name}"
            end

            if entry.directory?
              FileUtils.mkdir_p(dest)
            elsif entry.file?
              FileUtils.mkdir_p(File.dirname(dest))
              File.binwrite(dest, entry.read)
            end
          end
        end
      end
    end

    def symbolize_keys(hash)
      return hash unless hash.is_a?(Hash)

      hash.each_with_object({}) do |(k, v), result|
        result[k.to_sym] = v
      end
    end

    # Config management
    def load_config
      return { 'skillsets' => {} } unless File.exist?(@config_path)

      YAML.safe_load(File.read(@config_path)) || { 'skillsets' => {} }
    rescue StandardError
      { 'skillsets' => {} }
    end

    def save_config
      FileUtils.mkdir_p(File.dirname(@config_path))
      File.write(@config_path, @config.to_yaml)
    end

    def set_config(name, key, value)
      @config['skillsets'] ||= {}
      @config['skillsets'][name.to_s] ||= {}
      @config['skillsets'][name.to_s][key.to_s] = value
      save_config
    end

    def remove_config(name)
      @config['skillsets']&.delete(name.to_s)
      save_config
    end
  end
end
