require_relative 'base_tool'
require_relative '../safe_evolver'

module KairosMcp
  module Tools
    class SkillsEvolve < BaseTool
      def name
        'skills_evolve'
      end

      def description
        'Propose and apply changes to Skills DSL definitions. Automatically records changes to KairosChain.'
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
        approved = arguments['approved'] || false

        case command
        when 'propose'
          return text_content("Error: skill_id and definition are required") unless skill_id && definition
          
          result = SafeEvolver.propose(skill_id: skill_id, new_definition: definition)
          format_result(result)

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

      def format_result(result)
        if result[:success]
          output = "SUCCESS\n\n"
          output += "Message: #{result[:message]}\n" if result[:message]
          output += "\nPreview:\n```ruby\n#{result[:preview]}\n```" if result[:preview]
          text_content(output)
        else
          output = "FAILED\n\n"
          output += "Error: #{result[:error]}\n"
          output += "\nNote: This change requires human approval. Set approved=true to confirm." if result[:pending]
          text_content(output)
        end
      end
    end
  end
end
