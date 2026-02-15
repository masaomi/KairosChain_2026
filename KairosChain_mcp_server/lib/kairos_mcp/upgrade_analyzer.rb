# frozen_string_literal: true

require 'digest'
require 'yaml'
require_relative '../kairos_mcp'

module KairosMcp
  # UpgradeAnalyzer: 3-way hash comparison for safe template migration
  #
  # Compares three versions of each template file:
  #   1. Original (hash stored in .kairos_meta.yml at init time)
  #   2. Current  (user's version in the data directory)
  #   3. New      (latest template shipped with the gem)
  #
  # Classification patterns:
  #   Pattern 0 (unchanged):       user == original, new == original
  #   Pattern 1 (auto_updatable):  user == original, new != original
  #   Pattern 2 (user_modified):   user != original, new == original
  #   Pattern 3 (conflict):        user != original, new != original
  #
  class UpgradeAnalyzer
    PATTERNS = {
      unchanged: 'No changes needed',
      auto_updatable: 'Safe to auto-update (user has not modified)',
      user_modified: 'User has modified, template unchanged (keep user version)',
      conflict: 'Both user and template changed (requires merge/review)'
    }.freeze

    attr_reader :results, :meta, :has_meta

    def initialize
      @templates_dir = KairosMcp.templates_dir
      @data_dir = KairosMcp.data_dir
      @meta = load_meta
      @has_meta = File.exist?(KairosMcp.meta_path)
      @results = {}
    end

    # Analyze all template files and classify each
    #
    # @return [Hash] analysis results keyed by template name
    def analyze
      @results = {}

      KairosMcp::TEMPLATE_FILES.each do |template_name, accessor|
        @results[template_name] = analyze_file(template_name, accessor)
      end

      @results
    end

    # Get the installed gem version
    def gem_version
      KairosMcp::VERSION
    end

    # Get the version recorded in .kairos_meta.yml
    def meta_version
      @meta['kairos_mcp_version']
    end

    # Check if an upgrade is needed (version mismatch)
    def upgrade_needed?
      return true unless @has_meta
      meta_version != gem_version
    end

    # Summary counts by pattern
    def summary
      counts = Hash.new(0)
      @results.each_value { |r| counts[r[:pattern]] += 1 }
      counts
    end

    # Get files by pattern
    def files_by_pattern(pattern)
      @results.select { |_, r| r[:pattern] == pattern }
    end

    private

    def load_meta
      path = KairosMcp.meta_path
      if File.exist?(path)
        YAML.safe_load(File.read(path)) || {}
      else
        {}
      end
    rescue => e
      $stderr.puts "[KairosChain] Warning: Failed to load .kairos_meta.yml: #{e.message}"
      {}
    end

    def analyze_file(template_name, accessor)
      user_path = KairosMcp.send(accessor)
      new_template_path = File.join(@templates_dir, template_name)

      result = {
        template_name: template_name,
        file_type: KairosMcp::TEMPLATE_FILE_TYPES[template_name] || :unknown,
        user_path: user_path,
        new_template_path: new_template_path,
        user_exists: File.exist?(user_path),
        new_exists: File.exist?(new_template_path)
      }

      # If user file doesn't exist, it's a new file from the template
      unless result[:user_exists]
        result[:pattern] = :auto_updatable
        result[:action] = 'Copy new template (file does not exist in data directory)'
        return result
      end

      # If new template doesn't exist, skip (shouldn't happen normally)
      unless result[:new_exists]
        result[:pattern] = :unchanged
        result[:action] = 'Skip (template no longer exists in gem)'
        return result
      end

      # Compute hashes
      original_hash = @meta.dig('template_hashes', template_name)
      current_hash = file_hash(user_path)
      new_hash = file_hash(new_template_path)

      result[:original_hash] = original_hash
      result[:current_hash] = current_hash
      result[:new_hash] = new_hash

      # Without meta file, treat all existing files as potential conflicts
      unless original_hash
        if current_hash == new_hash
          result[:pattern] = :unchanged
          result[:action] = 'No changes (files are identical)'
        else
          result[:pattern] = :conflict
          result[:action] = 'Cannot determine origin (no .kairos_meta.yml) — review required'
          result[:no_meta] = true
        end
        return result
      end

      # 3-way comparison
      user_modified = (current_hash != original_hash)
      template_changed = (new_hash != original_hash)

      if !user_modified && !template_changed
        result[:pattern] = :unchanged
        result[:action] = 'No changes needed'
      elsif !user_modified && template_changed
        result[:pattern] = :auto_updatable
        result[:action] = 'Safe to auto-update (user has not modified this file)'
      elsif user_modified && !template_changed
        result[:pattern] = :user_modified
        result[:action] = 'Keep user version (template has not changed)'
      else
        # Both modified — classify by file type
        result[:pattern] = :conflict
        result[:action] = conflict_action(template_name, result[:file_type])
      end

      result
    end

    def conflict_action(template_name, file_type)
      case file_type
      when :config_yaml
        "Structural YAML merge (add new keys, preserve user values)"
      when :l0_dsl
        "Generate skills_evolve proposal (requires human approval + blockchain record)"
      when :l0_doc
        "Show diff only (L0 document — manual review recommended)"
      else
        "Manual review required"
      end
    end

    def file_hash(path)
      "sha256:#{Digest::SHA256.file(path).hexdigest}"
    end
  end
end
