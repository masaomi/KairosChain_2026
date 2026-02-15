# frozen_string_literal: true

require 'yaml'

module KairosMcp
  # ConfigMerger: Structural YAML merge for config files
  #
  # Merges new template values into user-modified config files:
  #   - New keys (only in template) → added with default values
  #   - User-only keys (only in user file) → preserved
  #   - Shared keys → user's value is kept
  #   - Nested hashes → recursively merged
  #   - Arrays → user's version is kept (no element-level merge)
  #
  # This ensures config upgrades add new features without overwriting
  # user customizations.
  #
  class ConfigMerger
    # Merge new template config into user config
    #
    # @param user_config [Hash] User's current config
    # @param new_config [Hash] New template config from gem
    # @return [Hash] Merged config
    def self.merge(user_config, new_config)
      new(user_config, new_config).merge
    end

    # Preview what would change without applying
    #
    # @param user_config [Hash] User's current config
    # @param new_config [Hash] New template config from gem
    # @return [Hash] Diff report with :added, :kept, :unchanged keys
    def self.preview(user_config, new_config)
      new(user_config, new_config).preview
    end

    def initialize(user_config, new_config)
      @user = user_config || {}
      @new = new_config || {}
    end

    # Perform the merge
    #
    # @return [Hash] Merged result
    def merge
      deep_merge(@user, @new)
    end

    # Generate a diff preview
    #
    # @return [Hash] with :added, :removed_from_template, :user_customized, :unchanged
    def preview
      diff = {
        added: [],           # Keys in new but not in user (will be added)
        user_customized: [], # Keys where user has different value (user value kept)
        unchanged: [],       # Keys with same value in both
        user_only: []        # Keys only in user config (preserved)
      }

      collect_diff(@user, @new, [], diff)
      diff
    end

    private

    # Deep merge: new_hash provides defaults, base_hash values take priority
    #
    # For hash values: recursively merge
    # For non-hash values: keep base (user) value
    # For keys only in new_hash: add them
    def deep_merge(base, overlay)
      result = base.dup

      overlay.each do |key, new_value|
        if result.key?(key)
          if result[key].is_a?(Hash) && new_value.is_a?(Hash)
            # Recursively merge nested hashes
            result[key] = deep_merge(result[key], new_value)
          else
            # Keep user's value (don't override)
            # result[key] stays as-is
          end
        else
          # New key from template — add it
          result[key] = deep_copy(new_value)
        end
      end

      result
    end

    # Collect diff information recursively
    def collect_diff(user_hash, new_hash, path, diff)
      all_keys = (user_hash.keys + new_hash.keys).uniq

      all_keys.each do |key|
        current_path = path + [key]
        path_str = current_path.join('.')

        in_user = user_hash.key?(key)
        in_new = new_hash.key?(key)

        if in_user && in_new
          user_val = user_hash[key]
          new_val = new_hash[key]

          if user_val.is_a?(Hash) && new_val.is_a?(Hash)
            # Recurse into nested hashes
            collect_diff(user_val, new_val, current_path, diff)
          elsif user_val == new_val
            diff[:unchanged] << path_str
          else
            diff[:user_customized] << {
              path: path_str,
              user_value: user_val,
              template_value: new_val
            }
          end
        elsif in_user && !in_new
          diff[:user_only] << path_str
        else
          diff[:added] << {
            path: path_str,
            value: new_hash[key]
          }
        end
      end
    end

    # Deep copy a value to avoid sharing references
    def deep_copy(value)
      case value
      when Hash
        value.each_with_object({}) { |(k, v), h| h[k] = deep_copy(v) }
      when Array
        value.map { |v| deep_copy(v) }
      else
        value
      end
    end
  end
end
