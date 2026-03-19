# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module ServiceGrantTools
      class ServiceGrantManage < KairosMcp::Tools::BaseTool
        def name
          'service_grant_manage'
        end

        def description
          'Manage service grants: upgrade/downgrade plans, suspend/unsuspend grants (owner only)'
        end

        def input_schema
          {
            type: 'object',
            properties: {
              command: {
                type: 'string',
                description: 'Command: upgrade_plan, suspend, unsuspend, get_grant, list_orphaned',
                enum: %w[upgrade_plan suspend unsuspend get_grant list_orphaned]
              },
              pubkey_hash: {
                type: 'string',
                description: 'Target pubkey_hash (hex, 64 chars)'
              },
              service: {
                type: 'string',
                description: 'Service name'
              },
              plan: {
                type: 'string',
                description: 'New plan name (for upgrade_plan)'
              },
              reason: {
                type: 'string',
                description: 'Suspension reason (for suspend)'
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
          gm = ::ServiceGrant.grant_manager

          result = case command
                   when 'upgrade_plan'
                     require_params!(arguments, 'pubkey_hash', 'service', 'plan')
                     gm.upgrade_plan(
                       arguments['pubkey_hash'],
                       service: arguments['service'],
                       new_plan: arguments['plan']
                     )
                     { command: 'upgrade_plan', status: 'success',
                       pubkey_hash: arguments['pubkey_hash'],
                       service: arguments['service'],
                       new_plan: arguments['plan'] }

                   when 'suspend'
                     require_params!(arguments, 'pubkey_hash', 'service', 'reason')
                     gm.suspend_grant(
                       arguments['pubkey_hash'],
                       service: arguments['service'],
                       reason: arguments['reason']
                     )
                     { command: 'suspend', status: 'success',
                       pubkey_hash: arguments['pubkey_hash'],
                       service: arguments['service'] }

                   when 'unsuspend'
                     require_params!(arguments, 'pubkey_hash', 'service')
                     gm.unsuspend_grant(
                       arguments['pubkey_hash'],
                       service: arguments['service']
                     )
                     { command: 'unsuspend', status: 'success',
                       pubkey_hash: arguments['pubkey_hash'],
                       service: arguments['service'] }

                   when 'get_grant'
                     require_params!(arguments, 'pubkey_hash', 'service')
                     grant = gm.get_grant(
                       arguments['pubkey_hash'],
                       service: arguments['service']
                     )
                     if grant
                       { command: 'get_grant', grant: grant }
                     else
                       { command: 'get_grant', grant: nil,
                         message: 'No grant found for this pubkey_hash and service' }
                     end

                   when 'list_orphaned'
                     orphaned = gm.grants_with_unknown_plans(::ServiceGrant.plan_registry)
                     { command: 'list_orphaned', orphaned_grants: orphaned,
                       count: orphaned.size,
                       note: orphaned.empty? ? 'No orphaned grants.' :
                         'These grants have plans not in current config. Access is BLOCKED.' }

                   else
                     { error: "Unknown command: #{command}" }
                   end

          format_result(result)
        rescue ::ServiceGrant::PlanNotFoundError, ::ServiceGrant::ConfigValidationError => e
          format_result({ error: e.message })
        rescue StandardError => e
          format_result({ error: "#{e.class}: #{e.message}" })
        end

        private

        def require_params!(arguments, *keys)
          missing = keys.select { |k| arguments[k].nil? || arguments[k].to_s.empty? }
          unless missing.empty?
            raise ArgumentError, "Missing required parameters: #{missing.join(', ')}"
          end
        end

        def format_result(data)
          [{ type: 'text', text: JSON.pretty_generate(data) }]
        end
      end
    end
  end
end
