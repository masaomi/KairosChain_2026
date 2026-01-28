require_relative 'base_tool'
require_relative '../safe_evolver'

module KairosMcp
  module Tools
    class SkillsEvolve < BaseTool
      def name
        'skills_evolve'
      end

      def description
        'Propose and apply changes to Skills DSL definitions. Runs L0 auto-check and records changes to KairosChain.'
      end

      def category
        :skills
      end

      def usecase_tags
        %w[evolve modify L0 meta-skill change propose apply blockchain]
      end

      def examples
        [
          {
            title: 'Propose a change',
            code: 'skills_evolve(command: "propose", skill_id: "my_skill", definition: "skill :my_skill do ... end", reason: "Add new feature")'
          },
          {
            title: 'Apply with approval',
            code: 'skills_evolve(command: "apply", skill_id: "my_skill", definition: "...", approved: true)'
          },
          {
            title: 'Add new skill',
            code: 'skills_evolve(command: "add", skill_id: "new_skill", definition: "...", approved: true)'
          }
        ]
      end

      def related_tools
        %w[skills_rollback skills_dsl_list skills_dsl_get chain_history]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            command: {
              type: 'string',
              description: 'Command: "propose", "apply", "add", or "reset"',
              enum: ['propose', 'apply', 'add', 'reset']
            },
            skill_id: {
              type: 'string',
              description: 'ID of the skill to modify or add'
            },
            definition: {
              type: 'string',
              description: 'New skill definition (Ruby DSL code)'
            },
            reason: {
              type: 'string',
              description: 'Reason for the change (documented for traceability)'
            },
            approved: {
              type: 'boolean',
              description: 'Set to true to approve the change (when human approval is required)'
            }
          }
        }
      end

      def call(arguments)
        command = arguments['command'] || 'propose'
        skill_id = arguments['skill_id']
        definition = arguments['definition']
        reason = arguments['reason']
        approved = arguments['approved'] || false

        case command
        when 'propose'
          return text_content("Error: skill_id and definition are required") unless skill_id && definition
          
          result = SafeEvolver.propose(skill_id: skill_id, new_definition: definition, reason: reason)
          format_result(result, show_checks: true)

        when 'apply'
          return text_content("Error: skill_id and definition are required") unless skill_id && definition
          
          result = SafeEvolver.apply(skill_id: skill_id, new_definition: definition, approved: approved)
          format_result(result)

        when 'add'
          return text_content("Error: skill_id and definition are required") unless skill_id && definition
          
          result = SafeEvolver.add_skill(skill_id: skill_id, definition: definition, approved: approved)
          format_result(result)

        when 'reset'
          SafeEvolver.reset_session!
          text_content("Evolution session counter reset.")

        else
          text_content("Unknown command: #{command}")
        end
      end

      private

      def format_result(result, show_checks: false)
        output = ""
        
        if result[:success]
          output = "✅ SUCCESS\n\n"
          output += "Message: #{result[:message]}\n" if result[:message]
        else
          output = "❌ FAILED\n\n"
          output += "Error: #{result[:error]}\n"
          output += "\nNote: This change requires human approval. Set approved=true to confirm.\n" if result[:pending]
        end
        
        # Show auto-check results if available
        if show_checks && result[:auto_check]
          output += format_auto_check(result[:auto_check])
        end
        
        output += "\nPreview:\n```ruby\n#{result[:preview]}\n```" if result[:preview]
        
        text_content(output)
      end
      
      def format_auto_check(check_result)
        output = "\n" + "=" * 60 + "\n"
        output += "📋 L0 AUTO-CHECK REPORT\n"
        output += "=" * 60 + "\n\n"
        
        output += "#{check_result[:summary]}\n\n"
        
        # Group checks by category
        checks_by_category = (check_result[:checks] || []).group_by { |c| c[:category] }
        
        checks_by_category.each do |category, checks|
          output += "### #{category}\n"
          checks.each do |check|
            status = case check[:passed]
                     when true then "✅"
                     when false then "❌"
                     when :unknown then "⚠️"
                     else "❓"
                     end
            output += "#{status} #{check[:item]}\n"
            output += "   #{check[:detail]}\n"
          end
          output += "\n"
        end
        
        if check_result[:human_review_needed] && check_result[:human_review_needed] > 0
          output += "-" * 60 + "\n"
          output += "⚠️  #{check_result[:human_review_needed]} item(s) require HUMAN verification.\n"
          output += "    Review the ⚠️ items above before approving.\n"
          output += "-" * 60 + "\n"
        end
        
        output
      end
    end
  end
end
