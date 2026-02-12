# frozen_string_literal: true

require_relative 'token_store'

module KairosMcp
  module Auth
    # Authenticator: Verifies HTTP requests using Bearer tokens
    #
    # Extracts the Bearer token from the Authorization header,
    # verifies it against the TokenStore, and returns user context.
    #
    # Usage:
    #   auth = Authenticator.new(token_store)
    #   user_context = auth.authenticate(env)
    #   # => { user: "masa", role: "owner", ... } or nil
    #
    class Authenticator
      # @param token_store [TokenStore] Token store instance
      def initialize(token_store)
        @token_store = token_store
      end

      # Authenticate a Rack request
      #
      # @param env [Hash] Rack environment hash
      # @return [Hash, nil] User context if authenticated, nil otherwise
      def authenticate(env)
        raw_token = extract_bearer_token(env)
        return nil unless raw_token

        @token_store.verify(raw_token)
      end

      # Authenticate and return a result object with error details
      #
      # @param env [Hash] Rack environment hash
      # @return [AuthResult] Result with success/failure details
      def authenticate!(env)
        raw_token = extract_bearer_token(env)

        unless raw_token
          return AuthResult.new(
            success: false,
            error: 'missing_token',
            message: 'Authorization header with Bearer token is required'
          )
        end

        user_context = @token_store.verify(raw_token)

        if user_context
          AuthResult.new(success: true, user_context: user_context)
        else
          AuthResult.new(
            success: false,
            error: 'invalid_token',
            message: 'Invalid, expired, or revoked token'
          )
        end
      end

      private

      # Extract Bearer token from Authorization header
      #
      # Supports: "Bearer kc_xxxxx" format
      #
      # @param env [Hash] Rack environment
      # @return [String, nil] Raw token or nil
      def extract_bearer_token(env)
        auth_header = env['HTTP_AUTHORIZATION']
        return nil unless auth_header

        match = auth_header.match(/\ABearer\s+(.+)\z/i)
        match ? match[1].strip : nil
      end
    end

    # AuthResult: Structured authentication result
    class AuthResult
      attr_reader :user_context, :error, :message

      def initialize(success:, user_context: nil, error: nil, message: nil)
        @success = success
        @user_context = user_context
        @error = error
        @message = message
      end

      def success?
        @success
      end

      def failed?
        !@success
      end
    end
  end
end
