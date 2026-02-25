require_relative 'base_tool'
require_relative '../dsl_skills_provider'

module KairosMcp
  module Tools
    class DefinitionVerify < BaseTool
      def name
        'definition_verify'
      end

      def description
        'Verify a skill\'s definition nodes against structural constraints. Reports which conditions pass, fail, or require human judgment.'
      end

      def category
        :skills
      end

      def usecase_tags
        %w[verify definition AST constraint check validation]
      end

      def examples
        [
          {
            title: 'Verify core_safety definition',
            code: 'definition_verify(skill_id: "core_safety")'
          }
        ]
      end

      def related_tools
        %w[definition_decompile definition_drift skills_dsl_get]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            skill_id: {
              type: 'string',
              description: 'The skill ID to verify'
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
          return text_content("## Verification: #{skill_id}\n\nThis skill has no definition block. Verification requires a structural definition layer.\n\nUse `skills_dsl_get` to view the skill's content layer.")
        end

        require_relative '../dsl_ast/ast_engine'
        report = DslAst::AstEngine.verify(skill)

        output = "## Verification Report: #{skill_id}\n\n"
        s = report.summary
        output += "**Summary**: #{s[:passed]} passed, #{s[:failed]} failed, #{s[:unknown]} unknown, #{s[:human_required]} human-required (#{s[:total]} total)\n\n"

        report.results.each do |r|
          icon = if !r.evaluable
                   "\u{1f9d1}" # human emoji
                 elsif r.satisfied == true
                   "\u{2705}" # check mark
                 elsif r.satisfied == false
                   "\u{274c}" # cross
                 else
                   "\u{2753}" # question mark
                 end
          output += "#{icon} **#{r.node_type}** `#{r.node_name}` — #{r.detail}\n"
        end

        if report.all_deterministic_passed?
          output += "\n**Status**: All deterministic constraints satisfied."
        else
          output += "\n**Status**: Some constraints not satisfied or not evaluable."
        end

        unless report.human_required.empty?
          output += "\n\n### Human Judgment Required\n"
          report.human_required.each do |r|
            output += "- `#{r.node_name}`: #{r.detail}\n"
          end
        end

        text_content(output)
      end
    end
  end
end
