# frozen_string_literal: true

require 'yaml'

module KairosMcp
  module SkillSets
    module Introspection
      # HealthScorer calculates health scores for L1 knowledge entries.
      #
      # When Synoptis TrustScorer is available, health is a weighted composite
      # of trust score (70%) and staleness score (30%). When TrustScorer is
      # unavailable (Synoptis not loaded), health equals staleness only.
      #
      # Staleness is computed from File.mtime of the knowledge .md file,
      # decaying linearly over a configurable threshold (default 180 days).
      class HealthScorer
        TRUST_WEIGHT = 0.70
        STALENESS_WEIGHT = 0.30

        def initialize(user_context: nil, config: {})
          @user_context = user_context
          @config = config
          @trust_scorer = build_trust_scorer
        end

        # Score all L1 knowledge entries.
        #
        # @return [Hash] :overall_health, :entry_count, :trust_scorer_available, :entries
        def score_l1
          provider = ::KairosMcp::KnowledgeProvider.new(nil, user_context: @user_context)
          summaries = provider.list

          scored = summaries.map { |summary| score_entry_from_summary(summary, provider) }
                           .sort_by { |e| e[:health_score] }

          overall = scored.empty? ? 0.0 : (scored.sum { |e| e[:health_score] } / scored.size).round(4)

          {
            overall_health: overall,
            entry_count: scored.size,
            trust_scorer_available: !@trust_scorer.nil?,
            entries: scored
          }
        end

        # Score a single L1 knowledge entry by name.
        #
        # @param name [String] Knowledge entry name
        # @return [Hash] :entry or :error
        def score_single(name)
          provider = ::KairosMcp::KnowledgeProvider.new(nil, user_context: @user_context)
          entry = provider.get(name)
          return { error: "Knowledge '#{name}' not found" } unless entry

          {
            entry: score_entry_from_skill_entry(entry),
            trust_scorer_available: !@trust_scorer.nil?
          }
        end

        private

        # Score from a summary hash (from provider.list).
        # Must call provider.get(name) to obtain SkillEntry with md_file_path.
        def score_entry_from_summary(summary, provider)
          skill_entry = provider.get(summary[:name])
          if skill_entry
            score_entry_from_skill_entry(skill_entry)
          else
            # Fallback: no SkillEntry found (shouldn't happen normally)
            {
              name: summary[:name],
              health_score: 0.5,
              trust_score: 0.0,
              trust_details: {},
              attestation_count: 0,
              staleness_score: 0.5,
              tags: summary[:tags]
            }
          end
        end

        # Score from a SkillEntry object (has md_file_path).
        def score_entry_from_skill_entry(entry)
          trust = if @trust_scorer
                    @trust_scorer.calculate("knowledge://#{entry.name}")
                  else
                    { score: 0.0, details: {}, attestation_count: 0, active_count: 0 }
                  end

          staleness = calculate_staleness(entry)

          # When TrustScorer unavailable, health = staleness only
          health = if @trust_scorer
                     (trust[:score] * TRUST_WEIGHT + staleness * STALENESS_WEIGHT).round(4)
                   else
                     staleness.round(4)
                   end

          {
            name: entry.name,
            health_score: health,
            trust_score: trust[:score],
            trust_details: trust[:details],
            attestation_count: trust[:attestation_count] || 0,
            staleness_score: staleness.round(4),
            tags: entry.tags
          }
        end

        # Calculate staleness score from file modification time.
        # Returns 1.0 for freshly modified, decays to 0.0 over threshold days.
        def calculate_staleness(entry)
          md_path = entry.respond_to?(:md_file_path) ? entry.md_file_path : nil
          return 0.5 unless md_path && File.exist?(md_path)

          age_days = (Time.now - File.mtime(md_path)) / 86400.0
          threshold = @config.dig('introspection', 'health', 'staleness_days') || 180
          [1.0 - (age_days / threshold.to_f), 0.0].max
        rescue StandardError
          0.5
        end

        def build_trust_scorer
          return nil unless defined?(::Synoptis::TrustScorer)
          registry = ::Synoptis::Registry::FileRegistry.new(
            storage_dir: File.join(::KairosMcp.storage_dir, 'synoptis')
          )
          ::Synoptis::TrustScorer.new(registry: registry)
        rescue StandardError
          nil
        end
      end
    end
  end
end
