# frozen_string_literal: true

module Multiuser
  module AuthorizationGate
    TOOL_NAMES_ALLOWING_GUEST = %w[
      hello_world chain_status chain_history chain_verify
      skills_list skills_get skills_dsl_list skills_dsl_get
      knowledge_list knowledge_get resource_list resource_read
      tool_guide multiuser_status attestation_list attestation_verify
      trust_query context_save
    ].freeze

    TOOL_NAMES_REQUIRING_OWNER = %w[
      skills_evolve instructions_update token_manage
      multiuser_user_manage multiuser_migrate system_upgrade
      chain_import chain_export
    ].freeze

    # Gate check: default-deny for guest, owner-only for admin tools.
    # Called by ToolRegistry.run_gates(tool_name, arguments, safety).
    def self.check(tool_name, arguments, safety)
      user = safety.current_user
      return unless user

      role = user[:role]
      return if role == 'owner'

      if role == 'guest'
        unless TOOL_NAMES_ALLOWING_GUEST.include?(tool_name)
          raise KairosMcp::ToolRegistry::GateDeniedError.new(
            tool_name, role, "#{tool_name} is not available for guest role"
          )
        end
      end

      if TOOL_NAMES_REQUIRING_OWNER.include?(tool_name)
        raise KairosMcp::ToolRegistry::GateDeniedError.new(
          tool_name, role, "#{tool_name} requires owner role"
        )
      end
    end
  end
end
