# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module Multiuser
      module Tools
        class MultiuserMigrate < KairosMcp::Tools::BaseTool
      def name
        'multiuser_migrate'
      end

      def description
        'Run database migrations for Multiuser SkillSet: status, run, dry_run (owner only)'
      end

      def input_schema
        {
          type: 'object',
          properties: {
            command: {
              type: 'string',
              description: 'Command: status (show pending migrations), run (apply), dry_run (preview)',
              enum: %w[status run dry_run]
            }
          },
          required: ['command']
        }
      end

      def call(arguments)
        unless defined?(Multiuser) && Multiuser.loaded?
          return format_result({ error: 'Multiuser SkillSet is not loaded' })
        end

        command = arguments['command']
        tm = Multiuser.tenant_manager

        result = case command
                 when 'status'
                   tenants = tm.list_tenants
                   status = tenants.map do |schema|
                     { schema: schema, pending: tm.pending_migrations(schema) }
                   end
                   {
                     command: 'status',
                     tenants: status,
                     total_pending: status.sum { |s| s[:pending].size }
                   }
                 when 'dry_run'
                   tenants = tm.list_tenants
                   preview = tenants.map do |schema|
                     pending = tm.pending_migrations(schema)
                     { schema: schema, would_apply: pending }
                   end
                   {
                     command: 'dry_run',
                     preview: preview,
                     total_would_apply: preview.sum { |p| p[:would_apply].size },
                     note: 'No changes applied. Use command=run to apply.'
                   }
                 when 'run'
                   results = tm.migrate_all
                   {
                     command: 'run',
                     results: results,
                     total_applied: results.values.sum(&:size)
                   }
                 else
                   { error: "Unknown command: #{command}" }
                 end

        format_result(result)
      rescue => e
        format_result({ error: "#{e.class}: #{e.message}" })
      end

      private

      def format_result(data)
        [{ type: 'text', text: JSON.pretty_generate(data) }]
      end
        end
      end
    end
  end
end
