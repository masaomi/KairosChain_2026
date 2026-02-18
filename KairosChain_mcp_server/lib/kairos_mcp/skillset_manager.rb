# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'set'
require_relative 'skillset'
require_relative '../kairos_mcp'

module KairosMcp
  # Manages SkillSet plugins in .kairos/skillsets/
  #
  # Handles discovery, loading, dependency resolution, enable/disable state,
  # and layer-aware governance (blockchain recording, RAG indexing).
  class SkillSetManager
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

    # Install a SkillSet from a local path
    def install(source_path, layer_override: nil)
      source_path = File.expand_path(source_path)
      raise ArgumentError, "Source path not found: #{source_path}" unless File.directory?(source_path)

      temp_skillset = Skillset.new(source_path)
      raise ArgumentError, "Invalid SkillSet: missing required fields" unless temp_skillset.valid?

      dest = File.join(@skillsets_dir, temp_skillset.name)
      if File.directory?(dest)
        raise ArgumentError, "SkillSet '#{temp_skillset.name}' already installed at #{dest}"
      end

      FileUtils.mkdir_p(@skillsets_dir)
      FileUtils.cp_r(source_path, dest)

      installed = Skillset.new(dest)
      installed.layer = layer_override if layer_override

      if layer_override
        set_config(installed.name, 'layer_override', layer_override.to_s)
      end

      set_config(installed.name, 'enabled', true)
      record_skillset_event(installed, 'install')

      { success: true, name: installed.name, version: installed.version, layer: installed.layer, path: dest }
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
    def check_dependencies!(skillset)
      missing = skillset.depends_on.reject { |dep| find_skillset(dep) && enabled?(dep) }
      return if missing.empty?

      raise ArgumentError, "Missing or disabled dependencies: #{missing.join(', ')}"
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
