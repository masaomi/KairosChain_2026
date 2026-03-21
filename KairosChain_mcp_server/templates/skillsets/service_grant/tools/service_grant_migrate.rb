# frozen_string_literal: true

require 'json'
require 'digest'

module KairosMcp
  module SkillSets
    module ServiceGrantTools
      class ServiceGrantMigrate < KairosMcp::Tools::BaseTool
        def name
          'service_grant_migrate'
        end

        def description
          'Run database migrations for Service Grant SkillSet (owner only)'
        end

        def input_schema
          {
            type: 'object',
            properties: {
              command: {
                type: 'string',
                description: 'Command: status (show pending), run (apply), dry_run (preview)',
                enum: %w[status run dry_run]
              }
            },
            required: ['command']
          }
        end

        def call(arguments)
          unless @safety&.can_manage_grants?
            return format_result({ error: 'forbidden', message: 'Owner role required' })
          end

          unless defined?(::ServiceGrant) && ::ServiceGrant.loaded?
            return format_result({ error: 'Service Grant SkillSet is not loaded' })
          end

          command = arguments['command']
          pool = ::ServiceGrant.pg_pool

          migrations = load_migrations
          applied = applied_migrations(pool)
          pending = migrations.reject { |m| applied.include?(m[:version]) }

          result = case command
                   when 'status'
                     {
                       command: 'status',
                       applied: applied.size,
                       pending: pending.map { |m| m[:version] },
                       total_pending: pending.size
                     }

                   when 'dry_run'
                     {
                       command: 'dry_run',
                       would_apply: pending.map { |m|
                         { version: m[:version], checksum: m[:checksum],
                           preview: m[:sql].lines.first(5).join }
                       },
                       total_would_apply: pending.size,
                       note: 'No changes applied. Use command=run to apply.'
                     }

                   when 'run'
                     if pending.empty?
                       { command: 'run', status: 'up_to_date', applied: 0 }
                     else
                       applied_now = run_migrations(pool, pending)
                       { command: 'run', status: 'success',
                         applied: applied_now.size,
                         versions: applied_now }
                     end

                   else
                     { error: "Unknown command: #{command}" }
                   end

          format_result(result)
        rescue StandardError => e
          format_result({ error: "#{e.class}: #{e.message}" })
        end

        private

        def load_migrations
          migrations_dir = File.join(File.dirname(__FILE__), '..', 'migrations')
          return [] unless Dir.exist?(migrations_dir)

          Dir.glob(File.join(migrations_dir, '*.sql')).sort.map do |path|
            sql = File.read(path)
            version = File.basename(path, '.sql')
            { version: version, sql: sql, checksum: Digest::SHA256.hexdigest(sql) }
          end
        end

        def applied_migrations(pool)
          # Ensure system_migrations table exists
          pool.exec_params(<<~SQL, [])
            CREATE TABLE IF NOT EXISTS system_migrations (
              version     TEXT PRIMARY KEY,
              checksum    TEXT,
              applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
          SQL

          result = pool.exec_params("SELECT version FROM system_migrations ORDER BY version", [])
          result.map { |r| r['version'] }
        rescue StandardError
          []
        end

        def run_migrations(pool, pending)
          applied = []

          # Advisory lock to prevent concurrent migrations
          pool.with_connection do |conn|
            conn.exec("SELECT pg_advisory_lock(42_000_001)")
            begin
              pending.each do |migration|
                conn.exec("BEGIN")
                conn.exec(migration[:sql])
                conn.exec_params(
                  "INSERT INTO system_migrations (version, checksum) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                  [migration[:version], migration[:checksum]]
                )
                conn.exec("COMMIT")
                applied << migration[:version]
              end
            rescue StandardError => e
              conn.exec("ROLLBACK") rescue nil
              raise
            ensure
              conn.exec("SELECT pg_advisory_unlock(42_000_001)") rescue nil
            end
          end

          applied
        end

        def format_result(data)
          [{ type: 'text', text: JSON.pretty_generate(data) }]
        end
      end
    end
  end
end
