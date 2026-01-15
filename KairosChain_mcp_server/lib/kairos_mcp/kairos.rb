require_relative 'dsl_skills_provider'
require_relative 'version_manager'
require_relative 'skills_config'
require_relative 'action_log'

module KairosMcp
  # Kairos: Global self-reference module for skills
  module Kairos
    class << self
      # Get all loaded skills
      def skills
        provider.skills
      end

      # Find a specific skill by ID
      def skill(id)
        skills.find { |s| s.id == id.to_sym }
      end

      # Reload skills from disk (clear cache)
      def reload!
        @provider = nil
      end

      # Get version history for a specific skill
      def history(skill_id = nil)
        if skill_id
          SkillHistory.for(skill_id)
        else
          VersionManager.list_versions
        end
      end

      # Get current configuration
      def config
        SkillsConfig.load
      end

      # Check if evolution is enabled
      def evolution_enabled?
        SkillsConfig.evolution_enabled?
      end

      # Get action log history
      def action_history(limit: 50)
        ActionLog.history(limit: limit)
      end

      private

      def provider
        @provider ||= DslSkillsProvider.new
      end
    end
  end

  # SkillHistory: Retrieves version history for skills
  class SkillHistory
    def self.for(skill_id)
      versions = VersionManager.list_versions
      # Return all versions (in the future, we could track per-skill changes)
      versions.map do |v|
        {
          filename: v[:filename],
          created: v[:created],
          reason: v[:reason]
        }
      end
    end

    def self.latest_snapshot
      versions = VersionManager.list_versions
      versions.first
    end

    def self.count
      VersionManager.list_versions.size
    end
  end
end

# Make Kairos available at top level for use in skills.rb
Kairos = KairosMcp::Kairos unless defined?(Kairos)
