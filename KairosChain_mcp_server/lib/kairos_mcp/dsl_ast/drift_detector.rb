# frozen_string_literal: true

require_relative '../skill_contexts'

module KairosMcp
  module DslAst
    # Drift item representing a single discrepancy between content and definition
    DriftItem = Struct.new(:direction, :severity, :description, :node_name, keyword_init: true)

    # Report of all detected drifts for a skill
    DriftReport = Struct.new(:skill_id, :items, :coverage_ratio, :timestamp, keyword_init: true) do
      def drifted?
        !items.empty?
      end

      def errors
        items.select { |i| i.severity == :error }
      end

      def warnings
        items.select { |i| i.severity == :warning }
      end

      def infos
        items.select { |i| i.severity == :info }
      end

      def summary
        {
          total: items.size,
          errors: errors.size,
          warnings: warnings.size,
          info: infos.size,
          coverage_ratio: coverage_ratio
        }
      end
    end

    # Deterministic content <-> definition drift detection
    # No LLM usage — keyword matching and structural analysis only.
    # NOTE: Drift thresholds and policies may become a SkillSet in Phase 3.
    class DriftDetector
      # Keywords that indicate structural assertions in natural language content
      ASSERTION_KEYWORDS = %w[must required always never shall mandatory].freeze

      # Detect drift between content and definition layers
      # @param skill [KairosMcp::SkillsDsl::Skill] the skill to analyze
      # @return [DriftReport]
      def self.detect(skill)
        items = []
        content = skill.content || ""
        definition = skill.definition
        content_lower = content.downcase

        # No definition => no drift analysis possible
        unless definition && definition.nodes && !definition.nodes.empty?
          return DriftReport.new(
            skill_id: skill.id,
            items: [],
            coverage_ratio: nil,
            timestamp: Time.now.iso8601
          )
        end

        # Check 1: definition nodes reflected in content (definition_orphaned)
        covered_count = 0
        definition.nodes.each do |node|
          if node_reflected_in_content?(node, content_lower)
            covered_count += 1
          else
            items << DriftItem.new(
              direction: :definition_orphaned,
              severity: :warning,
              description: "Definition node '#{node.name}' (#{node.type}) has no corresponding mention in content",
              node_name: node.name
            )
          end
        end

        # Check 2: content assertions not covered by definition (content_uncovered)
        uncovered = content_assertions_not_covered(content, definition)
        uncovered.each do |assertion|
          items << DriftItem.new(
            direction: :content_uncovered,
            severity: :info,
            description: "Content assertion \"#{assertion}\" not covered by any definition node",
            node_name: nil
          )
        end

        # Coverage ratio: proportion of definition nodes reflected in content
        total_nodes = definition.nodes.size
        ratio = total_nodes > 0 ? covered_count.to_f / total_nodes : 1.0

        DriftReport.new(
          skill_id: skill.id,
          items: items,
          coverage_ratio: ratio.round(2),
          timestamp: Time.now.iso8601
        )
      end

      private

      # Check if a definition node's name or key options appear in the content
      def self.node_reflected_in_content?(node, content_lower)
        # Convert node name from snake_case to words for matching
        name_words = node.name.to_s.split('_')

        # Check if any name word appears in content
        name_match = name_words.any? { |word| content_lower.include?(word.downcase) }
        return true if name_match

        # Also check key option values
        opts = node.options || {}
        opts.each_value do |v|
          next unless v.is_a?(String)
          return true if content_lower.include?(v.downcase)
        end

        false
      end

      # Find content lines with assertion keywords not covered by any definition node
      def self.content_assertions_not_covered(content, definition)
        uncovered = []
        node_keywords = collect_node_keywords(definition)

        content.each_line do |line|
          stripped = line.strip
          next if stripped.empty?
          next if stripped.start_with?('#', '|', '-') # Skip headers, tables, list markers that are structural

          # Check if this line contains an assertion keyword
          line_lower = stripped.downcase
          has_assertion = ASSERTION_KEYWORDS.any? { |kw| line_lower.include?(kw) }
          next unless has_assertion

          # Check if any definition node keyword appears in this line
          covered = node_keywords.any? { |kw| line_lower.include?(kw) }
          unless covered
            # Truncate long lines
            display = stripped.length > 80 ? "#{stripped[0..77]}..." : stripped
            uncovered << display
          end
        end

        uncovered
      end

      # Collect searchable keywords from all definition nodes
      def self.collect_node_keywords(definition)
        keywords = []

        definition.nodes.each do |node|
          # Add name parts
          node.name.to_s.split('_').each { |w| keywords << w.downcase }

          # Add option values that are strings
          (node.options || {}).each_value do |v|
            case v
            when String
              v.split(/\s+/).each { |w| keywords << w.downcase if w.length > 3 }
            when Symbol
              keywords << v.to_s.downcase
            end
          end
        end

        keywords.uniq
      end
    end
  end
end
