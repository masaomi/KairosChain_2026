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
          return format_result({
            enabled: false,
            message: 'Multiuser SkillSet is not loaded. Check config/multiuser.yml and ensure pg gem is installed.'
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
