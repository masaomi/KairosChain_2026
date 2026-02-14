# frozen_string_literal: true

require 'json'
require 'digest'
require 'securerandom'
require 'time'
require 'fileutils'

module KairosMcp
  module Auth
    # TokenStore: Manages Bearer tokens for HTTP authentication
    #
    # Stores SHA256 hashes of tokens (never raw tokens).
    # Supports file-based (JSON) storage. SQLite support can be added later
    # by extending Storage::Backend.
    #
    # Token lifecycle:
    #   1. --init-admin generates the first owner token (CLI)
    #   2. owner uses token_manage tool to create/revoke/rotate tokens
    #   3. Tokens expire after configured period (default: 90 days)
    #
    # Token data structure:
    #   {
    #     token_hash: "sha256...",
    #     user: "username",
    #     role: "owner" | "member" | "guest",
    #     issued_at: "2026-02-12T10:00:00Z",
    #     expires_at: "2026-05-13T10:00:00Z" | nil,
    #     issued_by: "username" | "system",
    #     status: "active" | "revoked"
    #   }
    #
    # Roles (Phase 1: all roles available, authorization enforced in Phase 2):
    #   - owner:  Full access, can manage tokens
    #   - member: Standard team access (Phase 2: L1/L2 write, L0 read)
    #   - guest:  Limited access (Phase 2: read-only, own L2 only)
    #
    class TokenStore
      VALID_ROLES = %w[owner member guest].freeze
      TOKEN_PREFIX = 'kc_'
      DEFAULT_EXPIRY_DAYS = 90

      attr_reader :store_path

      def initialize(store_path = nil)
        @store_path = store_path || default_store_path
        @tokens = load_tokens
      end

      # Generate a new token for a user
      #
      # @param user [String] Username
      # @param role [String] Role: "owner", "member", or "guest"
      # @param issued_by [String] Who issued this token
      # @param expires_in [String, nil] Expiry duration: "90d", "24h", "never", or nil (default)
      # @return [Hash] { raw_token:, token_hash:, user:, role:, ... }
      def create(user:, role: 'member', issued_by: 'system', expires_in: nil)
        validate_role!(role)
        validate_user!(user)

        raw_token = generate_token
        token_hash = hash_token(raw_token)
        now = Time.now

        expires_at = calculate_expiry(now, expires_in)

        entry = {
          'token_hash' => token_hash,
          'user' => user,
          'role' => role,
          'issued_at' => now.iso8601,
          'expires_at' => expires_at&.iso8601,
          'issued_by' => issued_by,
          'status' => 'active'
        }

        @tokens << entry
        save_tokens

        entry.merge('raw_token' => raw_token)
      end

      # Verify a raw token and return user info
      #
      # @param raw_token [String] The Bearer token to verify
      # @return [Hash, nil] User info if valid, nil if invalid/expired/revoked
      def verify(raw_token)
        token_hash = hash_token(raw_token)
        entry = find_by_hash(token_hash)

        return nil unless entry
        return nil if entry['status'] != 'active'
        return nil if expired?(entry)

        {
          user: entry['user'],
          role: entry['role'],
          issued_at: entry['issued_at'],
          expires_at: entry['expires_at']
        }
      end

      # Revoke a user's token(s)
      #
      # @param user [String] Username whose tokens to revoke
      # @return [Integer] Number of tokens revoked
      def revoke(user:)
        count = 0
        @tokens.each do |entry|
          if entry['user'] == user && entry['status'] == 'active'
            entry['status'] = 'revoked'
            count += 1
          end
        end

        save_tokens if count > 0
        count
      end

      # Rotate a user's token (revoke old, create new)
      #
      # @param user [String] Username
      # @param issued_by [String] Who is rotating
      # @return [Hash] New token info
      def rotate(user:, issued_by: 'system')
        old_entry = @tokens.find { |e| e['user'] == user && e['status'] == 'active' }
        role = old_entry ? old_entry['role'] : 'member'
        expires_in = nil

        if old_entry && old_entry['expires_at']
          # Preserve the same expiry duration
          original_issued = Time.parse(old_entry['issued_at'])
          original_expires = Time.parse(old_entry['expires_at'])
          duration_seconds = (original_expires - original_issued).to_i
          expires_in = "#{duration_seconds / 86400}d"
        end

        revoke(user: user)
        create(user: user, role: role, issued_by: issued_by, expires_in: expires_in)
      end

      # List all tokens (without hashes, for display)
      #
      # @param include_revoked [Boolean] Include revoked tokens
      # @return [Array<Hash>] Token summaries
      def list(include_revoked: false)
        entries = @tokens
        entries = entries.select { |e| e['status'] == 'active' } unless include_revoked

        entries.map do |entry|
          {
            user: entry['user'],
            role: entry['role'],
            status: entry['status'],
            issued_at: entry['issued_at'],
            expires_at: entry['expires_at'],
            issued_by: entry['issued_by'],
            expired: expired?(entry)
          }
        end
      end

      # Check if any tokens exist
      #
      # @return [Boolean]
      def empty?
        @tokens.empty? || @tokens.none? { |e| e['status'] == 'active' }
      end

      # Reload tokens from disk
      def reload!
        @tokens = load_tokens
      end

      private

      def default_store_path
        require_relative '../../kairos_mcp'
        KairosMcp.token_store_path
      end

      def generate_token
        "#{TOKEN_PREFIX}#{SecureRandom.hex(32)}"
      end

      def hash_token(raw_token)
        Digest::SHA256.hexdigest(raw_token)
      end

      def find_by_hash(token_hash)
        @tokens.find { |e| e['token_hash'] == token_hash }
      end

      def expired?(entry)
        return false if entry['expires_at'].nil?

        Time.parse(entry['expires_at']) < Time.now
      end

      def calculate_expiry(from, expires_in)
        return nil if expires_in == 'never'

        expires_in ||= "#{DEFAULT_EXPIRY_DAYS}d"

        case expires_in
        when /\A(\d+)d\z/
          from + ($1.to_i * 86400)
        when /\A(\d+)h\z/
          from + ($1.to_i * 3600)
        when /\A(\d+)m\z/
          from + ($1.to_i * 60)
        else
          from + (DEFAULT_EXPIRY_DAYS * 86400)
        end
      end

      def validate_role!(role)
        unless VALID_ROLES.include?(role)
          raise ArgumentError, "Invalid role: #{role}. Must be one of: #{VALID_ROLES.join(', ')}"
        end
      end

      def validate_user!(user)
        if user.nil? || user.strip.empty?
          raise ArgumentError, 'User cannot be blank'
        end

        unless user.match?(/\A[a-zA-Z0-9_\-\.]+\z/)
          raise ArgumentError, 'User must contain only alphanumeric characters, underscores, hyphens, and dots'
        end
      end

      def load_tokens
        return [] unless File.exist?(@store_path)

        data = JSON.parse(File.read(@store_path))
        data['tokens'] || []
      rescue JSON::ParserError, StandardError => e
        warn "[KairosChain] Failed to load tokens: #{e.message}"
        []
      end

      def save_tokens
        FileUtils.mkdir_p(File.dirname(@store_path))

        data = {
          'version' => 1,
          'updated_at' => Time.now.iso8601,
          'tokens' => @tokens
        }

        File.write(@store_path, JSON.pretty_generate(data))
      end
    end
  end
end
