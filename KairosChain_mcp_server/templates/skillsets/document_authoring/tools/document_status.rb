# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'
require 'yaml'
require_relative '../lib/document_authoring'

module KairosMcp
  module SkillSets
    module DocumentAuthoring
      module Tools
        class DocumentStatus < KairosMcp::Tools::BaseTool
          def name
            'document_status'
          end

          def description
            'Show draft file inventory: list existing document files in a directory ' \
              'with word counts and modification times. Non-recursive scan.'
          end

          def category
            :utility
          end

          def usecase_tags
            %w[document status inventory draft progress]
          end

          def related_tools
            %w[write_section resource_read]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                output_dir: {
                  type: 'string',
                  description: 'Directory to scan for draft files (e.g., "grant_draft/"). Non-recursive.'
                }
              },
              required: %w[output_dir]
            }
          end

          def call(arguments)
            config = load_config
            output_dir = arguments['output_dir']

            base_dir = resolve_base_dir(config)
            validated_dir = PathValidator.validate_dir!(output_dir, base_dir)

            unless File.directory?(validated_dir)
              return text_content(JSON.generate({
                'output_dir' => output_dir,
                'sections' => [],
                'total_word_count' => 0,
                'total_sections' => 0,
                'note' => 'Directory does not exist'
              }))
            end

            # Non-recursive scan for allowed extensions
            extensions = config['allowed_output_extensions'] || PathValidator::ALLOWED_EXTENSIONS
            patterns = extensions.map { |ext| File.join(validated_dir, "*#{ext}") }
            files = patterns.flat_map { |p| Dir.glob(p) }.sort

            # Skip symlinks to prevent reading outside workspace
            files = files.reject { |f| File.symlink?(f) }

            max_files = config['max_status_files'] || 50
            truncated = files.size > max_files
            files = files.first(max_files)

            sections = files.map do |filepath|
              content = File.read(filepath)
              {
                'file' => File.basename(filepath),
                'word_count' => content.split.size,
                'modified' => File.mtime(filepath).utc.iso8601
              }
            rescue StandardError => e
              {
                'file' => File.basename(filepath),
                'error' => e.message
              }
            end

            total_words = sections.sum { |s| s['word_count'] || 0 }

            text_content(JSON.generate({
              'output_dir' => output_dir,
              'sections' => sections,
              'total_word_count' => total_words,
              'total_sections' => sections.size,
              'truncated' => truncated
            }))
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
        end
      end
    end
  end
end
