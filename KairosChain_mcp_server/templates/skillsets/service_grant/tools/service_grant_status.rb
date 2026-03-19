# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module ServiceGrantTools
      class ServiceGrantStatus < KairosMcp::Tools::BaseTool
        def name
          'service_grant_status'
        end

        def description
          'Check Service Grant status: PostgreSQL connection, own grant info, usage summary'
        end

        def input_schema
          {
            type: 'object',
            properties: {
              service: {
                type: 'string',
                description: 'Service name to check (default: all services with grants)'
              }
            },
            required: []
          }
        end

        def call(arguments)
          unless defined?(::ServiceGrant) && ::ServiceGrant.loaded?
            error_info = defined?(::ServiceGrant) ? ::ServiceGrant.load_error : nil
            diagnosis = error_info || { type: 'not_installed', message: 'Service Grant SkillSet is not installed.' }

            return format_result({
              enabled: false,
              error_type: diagnosis[:type],
              message: diagnosis[:message]
            })
          end

          pool = ::ServiceGrant.pg_pool
          pg_ok = begin
            pool.with_connection { |c| c.exec("SELECT 1") }
            true
          rescue StandardError
            false
          end

          result = {
            enabled: true,
            postgresql: { connected: pg_ok },
            services: ::ServiceGrant.plan_registry.services
          }

          # Show caller's own grant info if pubkey_hash available
          pubkey_hash = caller_pubkey_hash
          if pubkey_hash && pg_ok
            service_filter = arguments['service']
            services = service_filter ? [service_filter] : ::ServiceGrant.plan_registry.services
            grants = []

            services.each do |svc|
              grant = ::ServiceGrant.grant_manager.get_grant(pubkey_hash, service: svc)
              next unless grant

              usage = ::ServiceGrant.usage_tracker.usage_summary(pubkey_hash, service: svc)
              grants << {
                service: svc,
                plan: grant[:plan],
                suspended: grant[:suspended],
                first_seen_at: grant[:first_seen_at]&.iso8601,
                last_active_at: grant[:last_active_at]&.iso8601,
                usage: usage
              }
            end

            result[:my_grants] = grants
          end

          format_result(result)
        rescue StandardError => e
          format_result({ error: "#{e.class}: #{e.message}" })
        end

        private

        def caller_pubkey_hash
          @safety&.current_user&.dig(:pubkey_hash)
        end

        def format_result(data)
          [{ type: 'text', text: JSON.pretty_generate(data) }]
        end
      end
    end
  end
end
