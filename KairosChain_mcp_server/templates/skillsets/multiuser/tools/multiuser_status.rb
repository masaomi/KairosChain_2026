# frozen_string_literal: true

module KairosMcp
  module Tools
    class MultiuserStatus < BaseTool
      def name
        'multiuser_status'
      end

      def description
        'Check Multiuser SkillSet status: PostgreSQL connection, tenant count, user count, migration status'
      end

      def input_schema
        {
          type: 'object',
          properties: {},
          required: []
        }
      end

      def call(_arguments)
        unless defined?(Multiuser) && Multiuser.loaded?
          error_info = defined?(Multiuser) ? Multiuser.load_error : nil
          diagnosis = if error_info
                        error_info
                      else
                        { type: 'not_installed', message: 'Multiuser SkillSet is not installed.' }
                      end

          return format_result({
            enabled: false,
            error_type: diagnosis[:type],
            message: diagnosis[:message],
            help: case diagnosis[:type]
                  when 'pg_gem_missing'
                    'Install the pg gem: gem install pg (requires PostgreSQL client library libpq)'
                  when 'pg_server_unavailable'
                    'Install and start PostgreSQL server, then check host/port in config/multiuser.yml'
                  when 'pg_error'
                    'Check database name, user, and password in config/multiuser.yml'
                  else
                    'Run: kairos-chain skillset install templates/skillsets/multiuser'
                  end
          })
        end

        pool = Multiuser.pool
        pg_ok = begin
          pool.with_connection { |c| c.exec("SELECT 1") }
          true
        rescue
          false
        end

        tenants = Multiuser.tenant_manager.list_tenants rescue []
        user_count = Multiuser.user_registry.count rescue 0

        format_result({
          enabled: true,
          postgresql: {
            connected: pg_ok,
            host: pool.config['host'] || pool.config[:host] || 'localhost',
            port: pool.config['port'] || pool.config[:port] || 5432,
            dbname: pool.config['dbname'] || pool.config[:dbname] || 'kairoschain'
          },
          tenants: {
            count: tenants.size,
            schemas: tenants
          },
          users: {
            count: user_count
          }
        })
      end

      private

      def format_result(data)
        [{ type: 'text', text: JSON.pretty_generate(data) }]
      end
    end
  end
end
