# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'yaml'
require_relative '../lib/document_authoring'

module KairosMcp
  module SkillSets
    module DocumentAuthoring
      module Tools
        class WriteSection < KairosMcp::Tools::BaseTool
          def name
            'write_section'
          end

          def description
            'Write a document section using LLM generation with L1/L2 context injection. ' \
              'Designed for grant applications, papers, reports — any structured document. ' \
              'Integrates with Agent OODA via autoexec internal_execute.'
          end

          def category
            :utility
          end

          def usecase_tags
            %w[document writing grant paper section llm generation]
          end

          def related_tools
            %w[document_status llm_call resource_read knowledge_get]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                section_name: {
                  type: 'string',
                  description: 'Section identifier (e.g., "research_significance", "methodology")'
                },
                instructions: {
                  type: 'string',
                  description: 'Writing instructions for the LLM (what to write, tone, focus)'
                },
                output_file: {
                  type: 'string',
                  description: 'Relative path for output (e.g., "grant_draft/02_significance.md"). ' \
                    'Resolved relative to workspace root.'
                },
                context_sources: {
                  type: 'array',
                  items: { type: 'string' },
                  description: 'Resource URIs for context injection. ' \
                    'Uses platform URI scheme: "knowledge://{name}" or "context://{session}/{name}"'
                },
                max_words: {
                  type: 'integer',
                  description: 'Approximate word limit (default: from config, typically 500)'
                },
                language: {
                  type: 'string',
                  description: 'Output language (default: "en"). E.g., "en", "ja", "de".'
                },
                append_mode: {
                  type: 'boolean',
                  description: 'If true, append to existing file instead of overwriting (default: false)'
                },
                invocation_context_json: {
                  type: 'string',
                  description: 'Serialized InvocationContext for policy inheritance (optional, used by autoexec)'
                }
              },
              required: %w[section_name instructions output_file]
            }
          end

          def call(arguments)
            config = load_config

            # Runtime dependency check
            unless tool_exists?('llm_call')
              return text_content(JSON.generate({
                'error' => 'llm_client SkillSet not loaded — llm_call tool not found in registry'
              }))
            end

            section_name = arguments['section_name']
            instructions = arguments['instructions']
            output_file = arguments['output_file']
            context_sources = arguments['context_sources'] || []
            max_words = arguments['max_words'] || config['max_words_default'] || 500
            language = arguments['language'] || 'en'
            append_mode = arguments['append_mode'] == true

            # Resolve InvocationContext
            inv_ctx = build_invocation_context(arguments['invocation_context_json'])

            # Resolve workspace root
            base_dir = resolve_base_dir(config)

            # Validate output path (symlink-safe)
            max_size = append_mode ? nil : config['max_output_file_size_bytes']
            allowed_ext = config['allowed_output_extensions'] || PathValidator::ALLOWED_EXTENSIONS
            validated_path = PathValidator.validate!(
              output_file, base_dir,
              allowed_extensions: allowed_ext,
              max_file_size: max_size
            )

            # Append mode size check: current + estimated output
            if append_mode && File.exist?(validated_path)
              max_total = config['max_output_file_size_bytes'] || 1_048_576
              estimated_append = max_words * 7  # ~7 bytes per word
              if File.size(validated_path) + estimated_append > max_total
                return text_content(JSON.generate({
                  'error' => "Append would exceed max file size (#{max_total} bytes)"
                }))
              end
            end

            # Assemble context
            assembler = ContextAssembler.new(
              self,
              max_chars_per_source: config['max_context_chars'] || 4000,
              max_total_chars: config['max_total_context_chars'] || 16_000,
              max_sources: config['max_context_sources'] || 10
            )
            ctx_result = assembler.assemble(context_sources, context: inv_ctx)

            # Write section
            writer = SectionWriter.new(self, config)
            result = writer.write(
              section_name: section_name,
              instructions: instructions,
              context_text: ctx_result[:text],
              output_file: validated_path,
              max_words: max_words,
              language: language,
              append_mode: append_mode,
              invocation_context: inv_ctx
            )

            # Enrich result with context info
            if result['status'] == 'ok'
              result['context_sources_loaded'] = ctx_result[:loaded]
              result['context_sources_failed'] = ctx_result[:failed]
              result['context_warnings'] = ctx_result[:warnings] unless ctx_result[:warnings].empty?
            end

            text_content(JSON.generate(result))
          rescue ArgumentError => e
            text_content(JSON.generate({ 'error' => e.message }))
          rescue StandardError => e
            text_content(JSON.generate({ 'error' => "#{e.class}: #{e.message}" }))
          end

          private

          def load_config
            config_path = File.join(__dir__, '..', 'config', 'document_authoring.yml')
            if File.exist?(config_path)
              YAML.safe_load(File.read(config_path)) || {}
            else
              {}
            end
          end

          def resolve_base_dir(config)
            base = if @safety&.respond_to?(:safe_root)
                     @safety.safe_root
                   else
                     Dir.pwd
                   end

            if config['output_base_dir']
              dir = File.expand_path(config['output_base_dir'], base)
              FileUtils.mkdir_p(dir) unless File.directory?(dir)
              dir
            else
              base
            end
          end

          def build_invocation_context(json_str)
            return nil if json_str.nil? || json_str.to_s.strip.empty?

            KairosMcp::InvocationContext.from_json(json_str)
          rescue JSON::ParserError, StandardError => e
            # Fail-closed: if context was provided but is malformed, use a
            # restrictive empty-whitelist context rather than nil (permissive)
            KairosMcp::InvocationContext.new(whitelist: [])
          end

          def tool_exists?(tool_name)
            @registry&.list_tools&.any? { |t| t[:name] == tool_name }
          end
        end
      end
    end
  end
end
