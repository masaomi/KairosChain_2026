# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module KnowledgeCreator
      module Tools
        class KcEvaluate < KairosMcp::Tools::BaseTool
          def name
            'kc_evaluate'
          end

          def description
            'Generate structured evaluation prompts for L1 knowledge quality assessment. ' \
              'This tool generates Persona Assembly prompts — it does NOT execute evaluation autonomously. ' \
              'Commands: evaluate (quality evaluation), analyze (structural pattern analysis), criteria (show criteria).'
          end

          def input_schema
            {
              type: 'object',
              properties: {
                command: {
                  type: 'string',
                  enum: %w[evaluate analyze criteria],
                  description: 'evaluate: generate quality evaluation prompt. ' \
                               'analyze: generate pattern analysis prompt. ' \
                               'criteria: show quality criteria.'
                },
                target_name: {
                  type: 'string',
                  description: 'L1 knowledge name to evaluate'
                },
                personas: {
                  type: 'array',
                  items: { type: 'string' },
                  description: 'Persona names for evaluation (default: evaluator, guardian, pragmatic)'
                },
                assembly_mode: {
                  type: 'string',
                  enum: %w[oneshot discussion],
                  description: 'Assembly mode (default: oneshot)'
                },
                save_result: {
                  type: 'boolean',
                  description: 'Include save instruction in prompt for L2 context (default: true)'
                }
              },
              required: %w[command target_name]
            }
          end

          def category
            :meta
          end

          def usecase_tags
            %w[knowledge quality evaluation persona-assembly meta]
          end

          def related_tools
            %w[kc_compare knowledge_get knowledge_list skills_promote]
          end

          def call(arguments)
            command = arguments['command']
            target_name = arguments['target_name']

            case command
            when 'evaluate'
              generate_evaluation(target_name, arguments)
            when 'analyze'
              generate_analysis(target_name, arguments)
            when 'criteria'
              show_criteria
            else
              text_content(JSON.pretty_generate({ error: "Unknown command: #{command}" }))
            end
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message, backtrace: e.backtrace&.first(3) }))
          end

          private

          def generate_evaluation(target_name, arguments)
            target = load_target(target_name)
            return text_content("Knowledge '#{target_name}' not found. Use knowledge_list to see available knowledge.") unless target

            personas = arguments['personas']
            mode = arguments['assembly_mode'] || 'oneshot'
            save_result = arguments.fetch('save_result', true)

            prompt = ::KnowledgeCreator::AssemblyTemplates.evaluation_prompt(
              target_name: target_name,
              target_content: target[:content],
              personas: personas,
              mode: mode
            )

            if save_result
              prompt += <<~SAVE_INSTRUCTION

                ---
                ### Save Instruction
                After completing the evaluation above, save the result to L2 context:
                ```
                context_save(name: "kc_eval_#{target_name}_#{Time.now.strftime('%Y%m%d')}", content: "<your evaluation output>")
                ```
                This is a save instruction — please call context_save as a follow-up tool call.
              SAVE_INSTRUCTION
            end

            text_content(prompt)
          end

          def generate_analysis(target_name, arguments)
            target = load_target(target_name)
            return text_content("Knowledge '#{target_name}' not found.") unless target

            creation_guide = load_target('creation_guide')

            prompt = ::KnowledgeCreator::AssemblyTemplates.analysis_prompt(
              target_name: target_name,
              target_content: target[:content],
              creation_guide_content: creation_guide&.dig(:content)
            )

            text_content(prompt)
          end

          def show_criteria
            criteria = load_target('quality_criteria')
            if criteria
              text_content(criteria[:content])
            else
              text_content('quality_criteria knowledge not found. Ensure knowledge_creator SkillSet is properly installed.')
            end
          end

          def load_target(knowledge_name)
            provider = ::KnowledgeCreator.provider(user_context: @safety&.current_user)
            skill = provider.get(knowledge_name)
            return nil unless skill

            content = if skill.respond_to?(:md_file_path) && File.exist?(skill.md_file_path)
                        File.read(skill.md_file_path, encoding: 'UTF-8')
                      elsif skill.respond_to?(:content)
                        skill.content
                      else
                        skill.to_s
                      end

            { name: knowledge_name, content: content, skill: skill }
          end
        end
      end
    end
  end
end
