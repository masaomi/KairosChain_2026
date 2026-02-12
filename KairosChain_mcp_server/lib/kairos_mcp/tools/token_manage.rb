# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../action_log'

module KairosMcp
  module Tools
    # TokenManage: MCP tool for managing Bearer tokens
    #
    # Commands:
    #   create  - Create a new token for a user
    #   revoke  - Revoke a user's active tokens
    #   list    - List all tokens (without showing token values)
    #   rotate  - Revoke old token and create new one for a user
    #
    # Phase 1: All authenticated users can manage tokens.
    # Phase 2: Only 'owner' role can manage tokens (enforced by Safety).
    #
    class TokenManage < BaseTool
      def name
        'token_manage'
      end

      def description
        'Manage Bearer tokens for HTTP authentication. Create, revoke, list, or rotate tokens for team members.'
      end

      def category
        :utility
      end

      def usecase_tags
        %w[auth token security HTTP team management]
      end

      def examples
        [
          {
            title: 'Create a member token',
            code: 'token_manage(command: "create", user: "alice", role: "member")'
          },
          {
            title: 'Create a short-lived token',
            code: 'token_manage(command: "create", user: "ci_bot", role: "guest", expires_in: "24h")'
          },
          {
            title: 'List active tokens',
            code: 'token_manage(command: "list")'
          },
          {
            title: 'Rotate a token',
            code: 'token_manage(command: "rotate", user: "alice")'
          },
          {
            title: 'Revoke a token',
            code: 'token_manage(command: "revoke", user: "alice")'
          }
        ]
      end

      def related_tools
        %w[chain_history chain_status]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            command: {
              type: 'string',
              description: 'Command: "create", "revoke", "list", or "rotate"',
              enum: %w[create revoke list rotate]
            },
            user: {
              type: 'string',
              description: 'Target username (required for create, revoke, rotate)'
            },
            role: {
              type: 'string',
              description: 'Role for new token: "owner", "member", or "guest" (default: "member")',
              enum: %w[owner member guest]
            },
            expires_in: {
              type: 'string',
              description: 'Token expiry: "90d" (default), "24h", "7d", "never"'
            }
          },
          required: ['command']
        }
      end

      def call(arguments)
        command = arguments['command']
        user = arguments['user']
        role = arguments['role'] || 'member'
        expires_in = arguments['expires_in']

        # Get current user context from safety (set by Protocol in HTTP mode)
        current_user = @safety&.current_user

        case command
        when 'create'
          handle_create(user, role, expires_in, current_user)
        when 'revoke'
          handle_revoke(user, current_user)
        when 'list'
          handle_list
        when 'rotate'
          handle_rotate(user, current_user)
        else
          text_content("Unknown command: #{command}")
        end
      rescue ArgumentError => e
        text_content("Error: #{e.message}")
      rescue StandardError => e
        text_content("Error: #{e.message}")
      end

      private

      def handle_create(user, role, expires_in, current_user)
        return text_content("Error: 'user' is required for create") unless user

        issued_by = current_user&.fetch(:user, nil) || 'unknown'

        result = token_store.create(
          user: user,
          role: role,
          issued_by: issued_by,
          expires_in: expires_in
        )

        # Record to action log (token hash only, never raw token)
        record_action('token_created', {
          user: user,
          role: role,
          issued_by: issued_by,
          expires_at: result['expires_at'],
          token_hash_prefix: result['token_hash'][0, 8]
        })

        output = <<~TEXT
          Token created successfully.

          User:    #{result['user']}
          Role:    #{result['role']}
          Token:   #{result['raw_token']}
          Expires: #{result['expires_at'] || 'never'}

          IMPORTANT: Store this token securely. It will NOT be shown again.

          Cursor mcp.json configuration:
          {
            "mcpServers": {
              "kairos": {
                "url": "http://<server-host>:<port>/mcp",
                "headers": {
                  "Authorization": "Bearer #{result['raw_token']}"
                }
              }
            }
          }
        TEXT

        text_content(output)
      end

      def handle_revoke(user, current_user)
        return text_content("Error: 'user' is required for revoke") unless user

        count = token_store.revoke(user: user)

        issued_by = current_user&.fetch(:user, nil) || 'unknown'
        record_action('token_revoked', {
          user: user,
          revoked_by: issued_by,
          count: count
        })

        if count > 0
          text_content("Revoked #{count} token(s) for user '#{user}'.")
        else
          text_content("No active tokens found for user '#{user}'.")
        end
      end

      def handle_list
        tokens = token_store.list(include_revoked: false)

        if tokens.empty?
          return text_content("No active tokens found.")
        end

        output = "Active tokens (#{tokens.size}):\n\n"
        tokens.each do |t|
          status = t[:expired] ? 'EXPIRED' : 'active'
          output += "  - #{t[:user]} (#{t[:role]})\n"
          output += "    Status: #{status}\n"
          output += "    Issued: #{t[:issued_at]} by #{t[:issued_by]}\n"
          output += "    Expires: #{t[:expires_at] || 'never'}\n\n"
        end

        text_content(output)
      end

      def handle_rotate(user, current_user)
        return text_content("Error: 'user' is required for rotate") unless user

        issued_by = current_user&.fetch(:user, nil) || 'unknown'

        result = token_store.rotate(user: user, issued_by: issued_by)

        record_action('token_rotated', {
          user: user,
          rotated_by: issued_by,
          expires_at: result['expires_at'],
          token_hash_prefix: result['token_hash'][0, 8]
        })

        output = <<~TEXT
          Token rotated for user '#{user}'.
          Old token(s) have been revoked.

          New Token: #{result['raw_token']}
          Expires:   #{result['expires_at'] || 'never'}

          IMPORTANT: Update the client configuration with the new token.
        TEXT

        text_content(output)
      end

      def token_store
        @token_store ||= begin
          require_relative '../auth/token_store'
          Auth::TokenStore.new
        end
      end

      def record_action(action, details)
        ActionLog.record(
          action: action,
          skill_id: nil,
          details: details.merge(timestamp: Time.now.iso8601)
        )
      end
    end
  end
end
