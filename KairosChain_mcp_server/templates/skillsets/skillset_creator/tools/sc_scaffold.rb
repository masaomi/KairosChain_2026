# frozen_string_literal: true

require 'fileutils'
require 'json'

module KairosMcp
  module SkillSets
    module SkillsetCreator
      module Tools
        class ScScaffold < KairosMcp::Tools::BaseTool
          def name
            'sc_scaffold'
          end

          def description
            'Generate a complete SkillSet directory structure with skeleton files. ' \
              'Use preview to see structure without creating files, or generate to create them. ' \
              'output_path is REQUIRED for generate (will NOT default to templates directory).'
          end

          def input_schema
            {
              type: 'object',
              properties: {
                command: {
                  type: 'string',
                  enum: %w[generate preview],
                  description: 'generate: create files on disk. preview: show structure without creating.'
                },
                skillset_name: {
                  type: 'string',
                  description: 'Name of the SkillSet (snake_case, e.g. my_skillset)'
                },
                tools: {
                  type: 'array',
                  items: { type: 'string' },
                  description: 'Tool names to scaffold (e.g. [my_tool, another_tool])'
                },
                knowledge: {
                  type: 'array',
                  items: { type: 'string' },
                  description: 'Knowledge names to scaffold'
                },
                has_config: {
                  type: 'boolean',
                  description: 'Include config/ directory (default: true)'
                },
                depends_on: {
                  type: 'array',
                  items: { type: 'string' },
                  description: 'Dependency SkillSet names'
                },
                has_plugin: {
                  type: 'boolean',
                  description: 'Include plugin/ directory with SKILL.md for Claude Code integration (default: false)'
                },
                output_path: {
                  type: 'string',
                  description: 'Absolute path for output directory. REQUIRED for generate command.'
                }
              },
              required: %w[command skillset_name]
            }
          end

          def category
            :meta
          end

          def usecase_tags
            %w[skillset scaffold generator meta]
          end

          def related_tools
            %w[sc_design sc_review]
          end

          def call(arguments)
            command = arguments['command']
            skillset_name = arguments['skillset_name']
            tools = arguments['tools'] || []
            knowledge = arguments['knowledge'] || []
            has_config = arguments.fetch('has_config', true)
            depends_on = arguments['depends_on'] || []
            has_plugin = arguments.fetch('has_plugin', false)

            case command
            when 'preview'
              tree = ::SkillsetCreator::ScaffoldGenerator.preview(
                name: skillset_name,
                tools: tools,
                knowledge: knowledge,
                has_config: has_config,
                depends_on: depends_on,
                has_plugin: has_plugin
              )
              text_content("## SkillSet Structure Preview\n\n```\n#{tree}\n```\n\nUse command='generate' with output_path to create these files.")

            when 'generate'
              output_path = arguments['output_path']
              return text_content('Error: output_path is required for generate command.') unless output_path && !output_path.empty?

              created = ::SkillsetCreator::ScaffoldGenerator.generate(
                name: skillset_name,
                output_path: output_path,
                tools: tools,
                knowledge: knowledge,
                has_config: has_config,
                depends_on: depends_on,
                has_plugin: has_plugin
              )

              result = {
                status: 'success',
                skillset_name: skillset_name,
                output_directory: File.join(output_path, skillset_name),
                created_files: created.map { |f| f.sub("#{output_path}/", '') },
                next_steps: [
                  'Edit skillset.json: update description, author, provides',
                  'Implement tool logic in tools/*.rb',
                  'Write knowledge content in knowledge/**/*.md',
                  'Test: kairos-chain skillset install (from SkillSet directory)',
                  'If knowledge_creator is available: kc_evaluate on bundled knowledge'
                ]
              }

              text_content(JSON.pretty_generate(result))
            else
              text_content(JSON.pretty_generate({ error: "Unknown command: #{command}" }))
            end
          rescue ArgumentError => e
            text_content(JSON.pretty_generate({ error: e.message }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message, backtrace: e.backtrace&.first(3) }))
          end
        end
      end
    end
  end
end
