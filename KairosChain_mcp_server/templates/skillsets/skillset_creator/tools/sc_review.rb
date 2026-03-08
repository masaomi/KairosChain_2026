# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module SkillsetCreator
      module Tools
        class ScReview < KairosMcp::Tools::BaseTool
          def name
            'sc_review'
          end

          def description
            'Generate structured review prompts for multi-LLM review or Persona Assembly review ' \
              'of SkillSet designs and implementations. This tool generates prompts — it does NOT ' \
              'execute reviews autonomously. For multi_llm mode, copy the output to other AI apps.'
          end

          def input_schema
            {
              type: 'object',
              properties: {
                command: {
                  type: 'string',
                  enum: %w[design_review implementation_review],
                  description: 'design_review: review prompt for design document. ' \
                               'implementation_review: review prompt for SkillSet code.'
                },
                target_path: {
                  type: 'string',
                  description: 'Path to design document (for design_review) or SkillSet directory (for implementation_review)'
                },
                review_mode: {
                  type: 'string',
                  enum: %w[multi_llm persona_assembly],
                  description: 'multi_llm: self-contained prompt for other AI apps. ' \
                               'persona_assembly: structured prompt for same-session evaluation.'
                },
                focus_areas: {
                  type: 'array',
                  items: { type: 'string' },
                  description: 'Specific areas to focus review on (optional; defaults provided)'
                },
                personas: {
                  type: 'array',
                  items: { type: 'string' },
                  description: 'Persona names for persona_assembly mode (default: kairos, pragmatic, skeptic)'
                },
                include_claude_md: {
                  type: 'boolean',
                  description: 'Include CLAUDE.md principles in review context (default: true for design_review)'
                }
              },
              required: %w[command target_path review_mode]
            }
          end

          def category
            :meta
          end

          def usecase_tags
            %w[skillset review multi-llm persona-assembly meta]
          end

          def related_tools
            %w[sc_design sc_scaffold kc_evaluate]
          end

          def call(arguments)
            command = arguments['command']
            target_path = arguments['target_path']
            review_mode = arguments['review_mode']

            return text_content('Error: target_path does not exist.') unless File.exist?(target_path)

            case command
            when 'design_review'
              generate_design_review(target_path, review_mode, arguments)
            when 'implementation_review'
              generate_implementation_review(target_path, review_mode, arguments)
            else
              text_content(JSON.pretty_generate({ error: "Unknown command: #{command}" }))
            end
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message, backtrace: e.backtrace&.first(3) }))
          end

          private

          def generate_design_review(target_path, review_mode, arguments)
            content = File.read(target_path, encoding: 'UTF-8')
            focus_areas = arguments['focus_areas']
            include_claude_md = arguments.fetch('include_claude_md', true)

            prompt = case review_mode
                     when 'multi_llm'
                       ::SkillsetCreator::ReviewTemplates.design_review_multi_llm(
                         document_content: content,
                         focus_areas: focus_areas,
                         include_claude_md: include_claude_md
                       )
                     when 'persona_assembly'
                       personas = arguments['personas']
                       ::SkillsetCreator::ReviewTemplates.design_review_persona_assembly(
                         document_content: content,
                         personas: personas,
                         focus_areas: focus_areas
                       )
                     end

            text_content(prompt)
          end

          def generate_implementation_review(target_path, review_mode, arguments)
            unless File.directory?(target_path)
              return text_content('Error: target_path must be a directory for implementation_review.')
            end

            file_listing = generate_file_listing(target_path)
            key_files_content = ::SkillsetCreator::ReviewTemplates.collect_key_files(target_path)
            focus_areas = arguments['focus_areas']
            include_claude_md = arguments.fetch('include_claude_md', true)

            prompt = case review_mode
                     when 'multi_llm'
                       ::SkillsetCreator::ReviewTemplates.implementation_review_multi_llm(
                         file_listing: file_listing,
                         key_files_content: key_files_content,
                         focus_areas: focus_areas,
                         include_claude_md: include_claude_md
                       )
                     when 'persona_assembly'
                       personas = arguments['personas']
                       ::SkillsetCreator::ReviewTemplates.implementation_review_persona_assembly(
                         file_listing: file_listing,
                         key_files_content: key_files_content,
                         personas: personas,
                         focus_areas: focus_areas
                       )
                     end

            text_content(prompt)
          end

          def generate_file_listing(dir)
            files = Dir[File.join(dir, '**', '*')].select { |f| File.file?(f) }.sort
            files.map { |f| f.sub("#{dir}/", '') }.join("\n")
          end
        end
      end
    end
  end
end
