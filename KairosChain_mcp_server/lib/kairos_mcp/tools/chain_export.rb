# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../skills_config'

module KairosMcp
  module Tools
    class ChainExport < BaseTool
      def name
        'chain_export'
      end

      def description
        'Export data from SQLite database to human-readable files (blockchain.json, action_log.jsonl, knowledge_meta.json). Only works when using SQLite backend.'
      end

      def category
        :chain
      end

      def usecase_tags
        %w[export backup sqlite files blockchain]
      end

      def examples
        [
          {
            title: 'Export to default directory',
            code: 'chain_export()'
          },
          {
            title: 'Export to custom directory',
            code: 'chain_export(output_dir: "/path/to/export")'
          }
        ]
      end

      def related_tools
        %w[chain_import chain_status]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            output_dir: {
              type: 'string',
              description: 'Directory to export files to. Defaults to storage/export/'
            }
          }
        }
      end

      def call(arguments)
        # Check if SQLite backend is enabled
        unless SkillsConfig.storage_backend_sqlite?
          return text_content("Error: chain_export only works with SQLite backend. Current backend: #{SkillsConfig.storage_backend}")
        end

        require_relative '../storage/exporter'

        sqlite_config = SkillsConfig.sqlite_config
        db_path = File.expand_path(sqlite_config['path'] || 'storage/kairos.db', base_dir)
        output_dir = arguments['output_dir'] || File.expand_path('storage/export', base_dir)

        # Check if database exists
        unless File.exist?(db_path)
          return text_content("Error: SQLite database not found at #{db_path}")
        end

        # Perform export
        result = Storage::Exporter.export(db_path: db_path, output_dir: output_dir)

        if result[:error]
          return text_content("Export failed: #{result[:error]}")
        end

        output = <<~OUTPUT
          Export completed successfully!

          Output directory: #{output_dir}
          
          Exported:
          - Blocks: #{result[:blocks]}
          - Action logs: #{result[:action_logs]}
          - Knowledge metadata: #{result[:knowledge_meta]}

          Files created:
          - blockchain.json
          - action_log.jsonl
          - knowledge_meta.json
          - manifest.json
        OUTPUT

        text_content(output)
      end

      private

      def base_dir
        KairosMcp.data_dir
      end
    end
  end
end
