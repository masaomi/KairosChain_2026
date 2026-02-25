require_relative 'base_tool'
require_relative '../dsl_skills_provider'

module KairosMcp
  module Tools
    class DefinitionDrift < BaseTool
      def name
        'definition_drift'
      end

      def description
        'Detect drift between a skill\'s content (natural language) and definition (structural AST). Identifies uncovered assertions and orphaned nodes.'
      end

      def category
        :skills
      end

      def usecase_tags
        %w[drift detection content definition consistency analysis]
      end

      def examples
        [
          {
            title: 'Check drift for core_safety',
            code: 'definition_drift(skill_id: "core_safety")'
          }
        ]
      end

      def related_tools
        %w[definition_verify definition_decompile skills_dsl_get]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            skill_id: {
              type: 'string',
              description: 'The skill ID to check for drift'
            }
          },
          required: ['skill_id']
        }
      end

      def call(arguments)
        skill_id = arguments['skill_id']
        return text_content("Error: skill_id is required") unless skill_id && !skill_id.empty?

        provider = DslSkillsProvider.new
        skill = provider.get_skill(skill_id)

        unless skill
          available = provider.list_skills.map { |s| s[:id] }.join(', ')
          return text_content("Skill '#{skill_id}' not found. Available: #{available}")
        end

        unless skill.definition
          return text_content("## Drift Report: #{skill_id}\n\nThis skill has no definition block. Drift detection requires both content and definition layers.")
        end

        require_relative '../dsl_ast/drift_detector'
        report = DslAst::DriftDetector.detect(skill)

        output = "## Drift Report: #{skill_id}\n\n"

        s = report.summary
        output += "**Coverage Ratio**: #{(report.coverage_ratio * 100).round(0)}% of definition nodes reflected in content\n"
        output += "**Issues**: #{s[:errors]} errors, #{s[:warnings]} warnings, #{s[:info]} info (#{s[:total]} total)\n\n"

        if report.drifted?
          report.items.each do |item|
            icon = case item.severity
                   when :error   then "\u{274c}"
                   when :warning then "\u{26a0}\u{fe0f}"
                   when :info    then "\u{2139}\u{fe0f}"
                   end
            direction_label = case item.direction
                              when :content_uncovered   then "Content > Definition"
                              when :definition_orphaned then "Definition > Content"
                              when :value_mismatch      then "Value Mismatch"
                              end
            output += "#{icon} [#{direction_label}] #{item.description}\n"
          end
        else
          output += "No drift detected. Content and definition layers are aligned."
        end

        text_content(output)
      end
    end
  end
end
