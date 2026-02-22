# frozen_string_literal: true

module Hestia
  # SkillBoard aggregates skills from registered agents.
  #
  # DEE design principles:
  # - Returns raw catalog — NO compatibility judgments
  # - Random sample (max N), NOT sorted by any metric (D3)
  # - NO ranking, scoring, or "recommended agents" (D5)
  # - Each agent decides compatibility locally
  class SkillBoard
    DEFAULT_MAX_RESULTS = 50

    def initialize(registry:)
      @registry = registry
    end

    # Browse available skills across all registered agents.
    #
    # Returns a random sample of skills — never sorted by popularity,
    # recency, or any metric. This prevents large Places from having
    # visibility advantage over small ones.
    #
    # @param type [String, nil] Filter by skill type/format
    # @param search [String, nil] Text search in skill names
    # @param tags [Array<String>, nil] Filter by tags
    # @param limit [Integer] Max results (default 50, random sample)
    # @return [Hash] Board listing
    def browse(type: nil, search: nil, tags: nil, limit: DEFAULT_MAX_RESULTS)
      all_entries = collect_all_entries

      # Apply filters
      entries = all_entries
      entries = entries.select { |e| e[:format] == type } if type
      entries = entries.select { |e| e[:name].downcase.include?(search.downcase) } if search
      if tags && !tags.empty?
        entries = entries.select do |e|
          entry_tags = e[:tags] || []
          tags.any? { |t| entry_tags.include?(t) }
        end
      end

      # Random sample — DEE principle: no ordering bias
      sampled = entries.size > limit ? entries.sample(limit) : entries.shuffle

      {
        entries: sampled,
        total_available: entries.size,
        returned: sampled.size,
        sampling: entries.size > limit ? 'random_sample' : 'all_shuffled',
        agents_contributing: sampled.map { |e| e[:agent_id] }.uniq.size
      }
    end

    private

    def collect_all_entries
      agents = @registry.list(include_self: true)
      entries = []

      agents.each do |agent|
        skills = agent[:capabilities]
        next unless skills.is_a?(Hash)

        skill_formats = skills[:skill_formats] || skills['skill_formats'] || []
        supported = skills[:supported_actions] || skills['supported_actions'] || []

        # Each agent contributes their capability info as board entries
        entries << {
          agent_id: agent[:id],
          agent_name: agent[:name],
          name: agent[:name],
          format: 'agent',
          capabilities: supported,
          skill_formats: skill_formats,
          is_self: agent[:is_self],
          tags: [],
          registered_at: agent[:registered_at]
        }
      end

      entries
    end
  end
end
