# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module KnowledgeCreator
      module Tools
        class KcCompare < KairosMcp::Tools::BaseTool
          def name
            'kc_compare'
          end

          def description
            'Generate a Persona Assembly prompt for blind A/B comparison of two knowledge versions. ' \
              'Use for L2→L1 promotion readiness, L1 revision comparison, or duplicate merge decisions. ' \
              'This tool generates comparison prompts — it does NOT execute comparison autonomously.'
          end

          def input_schema
            {
              type: 'object',
              properties: {
                command: {
                  type: 'string',
                  enum: %w[compare],
                  description: 'compare: generate blind comparison prompt'
                },
                version_a_name: { type: 'string', description: 'Name of version A knowledge' },
                version_a_layer: { type: 'string', enum: %w[L1 L2], description: 'Layer of version A' },
                version_a_session_id: { type: 'string', description: 'Session ID (required if version_a_layer is L2)' },
                version_b_name: { type: 'string', description: 'Name of version B knowledge' },
                version_b_layer: { type: 'string', enum: %w[L1 L2], description: 'Layer of version B' },
                version_b_session_id: { type: 'string', description: 'Session ID (required if version_b_layer is L2)' },
                blind: {
                  type: 'boolean',
                  description: 'Anonymize as Version A / Version B (default: true)'
                },
                personas: {
                  type: 'array',
                  items: { type: 'string' },
                  description: 'Persona names (default: kairos, pragmatic, skeptic)'
                }
              },
              required: %w[command version_a_name version_a_layer version_b_name version_b_layer]
            }
          end

          def category
            :meta
          end

          def usecase_tags
            %w[knowledge comparison version promotion meta]
          end

          def related_tools
            %w[kc_evaluate knowledge_get context_save]
          end

          def call(arguments)
            return text_content(JSON.pretty_generate({ error: 'Only compare command is supported' })) unless arguments['command'] == 'compare'

            version_a = load_version(
              arguments['version_a_name'],
              arguments['version_a_layer'],
              arguments['version_a_session_id']
            )
            return text_content("Version A '#{arguments['version_a_name']}' not found in #{arguments['version_a_layer']}.") unless version_a

            version_b = load_version(
              arguments['version_b_name'],
              arguments['version_b_layer'],
              arguments['version_b_session_id']
            )
            return text_content("Version B '#{arguments['version_b_name']}' not found in #{arguments['version_b_layer']}.") unless version_b

            blind = arguments.fetch('blind', true)
            personas = arguments['personas']

            prompt = ::KnowledgeCreator::AssemblyTemplates.comparison_prompt(
              version_a_content: version_a[:content],
              version_b_content: version_b[:content],
              blind: blind,
              personas: personas
            )

            text_content(prompt)
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message, backtrace: e.backtrace&.first(3) }))
          end

          private

          def load_version(name, layer, session_id = nil)
            case layer
            when 'L1'
              load_l1(name)
            when 'L2'
              load_l2(name, session_id)
            end
          end

          def load_l1(name)
            provider = ::KnowledgeCreator.provider(user_context: @safety&.current_user)
            skill = provider.get(name)
            return nil unless skill

            content = if skill.respond_to?(:md_file_path) && File.exist?(skill.md_file_path)
                        File.read(skill.md_file_path, encoding: 'UTF-8')
                      elsif skill.respond_to?(:content)
                        skill.content
                      else
                        skill.to_s
                      end

            { name: name, layer: 'L1', content: content }
          end

          def load_l2(name, session_id)
            return nil unless defined?(KairosMcp::ContextManager)

            cm = KairosMcp::ContextManager.new(nil, user_context: @safety&.current_user)
            ctx = if session_id
                    cm.load_context(session_id: session_id, name: name)
                  else
                    cm.find_context(name: name)
                  end
            return nil unless ctx

            content = ctx.respond_to?(:content) ? ctx.content : ctx.to_s
            { name: name, layer: 'L2', content: content }
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
