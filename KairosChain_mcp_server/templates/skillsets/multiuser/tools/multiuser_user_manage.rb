# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module Multiuser
      module Tools
        class MultiuserUserManage < KairosMcp::Tools::BaseTool
      def name
        'multiuser_user_manage'
      end

      def description
        'Manage users in Multiuser mode: list, create, delete, update_role (owner only)'
      end

      def input_schema
        {
          type: 'object',
          properties: {
            command: {
              type: 'string',
              description: 'Command: list, create, delete, update_role',
              enum: %w[list create delete update_role]
            },
            username: {
              type: 'string',
              description: 'Username (required for create, delete, update_role)'
            },
            role: {
              type: 'string',
              description: 'Role: owner, member, guest (for create and update_role)',
              enum: %w[owner member guest]
            },
            display_name: {
              type: 'string',
              description: 'Display name (optional, for create)'
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
        actor = @safety&.current_user&.dig(:user) || 'system'
        registry = Multiuser.user_registry

        result = case command
                 when 'list'
                   { users: registry.list }
                 when 'create'
                   username = arguments['username']
                   return format_result({ error: 'username is required' }) unless username

                   role = arguments['role'] || 'member'
                   display_name = arguments['display_name']
                   user = registry.register(username, role: role, display_name: display_name, actor: actor)

                   config = KairosMcp::SkillsConfig.load['http'] || {}
                   store = KairosMcp::Auth::TokenStore.create(
                     backend: config['token_backend'],
                     store_path: config['token_store']
                   )
                   token = store.create(
                     user: username, role: role, issued_by: actor
                   )

                   {
                     status: 'created',
                     user: user,
                     token: {
                       raw_token: token[:raw_token],
                       expires_at: token[:expires_at],
                       note: 'Save this token securely. It cannot be retrieved again.'
                     }
                   }
                 when 'delete'
                   username = arguments['username']
                   return format_result({ error: 'username is required' }) unless username
                   registry.delete(username, actor: actor)
                 when 'update_role'
                   username = arguments['username']
                   role = arguments['role']
                   return format_result({ error: 'username and role are required' }) unless username && role
                   registry.update_role(username, role, actor: actor)
                 else
                   { error: "Unknown command: #{command}" }
                 end

        format_result(result)
      rescue ArgumentError => e
        format_result({ error: e.message })
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
