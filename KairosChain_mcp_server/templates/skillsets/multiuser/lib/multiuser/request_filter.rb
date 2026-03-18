# frozen_string_literal: true

module Multiuser
  module RequestFilter
    # Resolve user_context to include tenant_schema.
    # Called by Protocol.apply_all_filters(user_context).
    def self.apply(user_context)
      return user_context unless user_context && Multiuser.loaded?

      username = user_context[:user]
      return user_context unless username

      user_record = Multiuser.user_registry&.find(username)
      return user_context unless user_record

      user_context.merge(
        tenant_schema: user_record['tenant_schema'],
        display_name: user_record['display_name']
      )
    end
  end
end
