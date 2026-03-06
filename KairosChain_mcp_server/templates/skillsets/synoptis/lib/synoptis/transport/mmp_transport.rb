# frozen_string_literal: true

module Synoptis
  module Transport
    # Delivers Synoptis messages via MMP PeerManager.
    # Uses send_message (which includes Bearer token after Phase 0b fix).
    class MMPTransport < BaseTransport
      def initialize(config: {}, workspace_root: nil, data_dir: nil)
        super(config: config)
        @workspace_root = workspace_root
        @data_dir = data_dir
      end

      def available?
        defined?(::MMP::PeerManager) && defined?(::MMP::Identity)
      end

      def send_attestation(peer_id:, envelope:)
        send_mmp_message(peer_id, {
          action: 'attestation_response',
          payload: envelope.to_h
        })
      end

      def send_revocation(peer_id:, revocation:)
        send_mmp_message(peer_id, {
          action: 'attestation_revoke',
          payload: revocation
        })
      end

      def send_challenge(peer_id:, challenge:)
        send_mmp_message(peer_id, {
          action: 'challenge_create',
          payload: challenge
        })
      end

      def send_challenge_response(peer_id:, response:)
        send_mmp_message(peer_id, {
          action: 'challenge_respond',
          payload: response
        })
      end

      private

      def send_mmp_message(peer_id, message)
        pm = resolve_peer_manager
        return { status: 'error', message: 'PeerManager not available' } unless pm

        message[:from] = resolve_identity_id
        message[:timestamp] = Time.now.utc.iso8601

        result = pm.send_message(peer_id, message)
        if result
          { status: 'sent', peer_id: peer_id, action: message[:action] }
        else
          { status: 'error', message: "Failed to deliver to peer #{peer_id}" }
        end
      end

      def resolve_peer_manager
        return nil unless available?

        identity = MMP::Identity.new(
          workspace_root: @workspace_root || resolve_workspace_root,
          config: mmp_config
        )
        MMP::PeerManager.new(
          identity: identity,
          config: mmp_config,
          data_dir: @data_dir || resolve_data_dir
        )
      rescue StandardError => e
        warn "[Synoptis::MMPTransport] PeerManager init failed: #{e.message}"
        nil
      end

      def resolve_identity_id
        identity = MMP::Identity.new(
          workspace_root: @workspace_root || resolve_workspace_root,
          config: mmp_config
        )
        identity.instance_id
      rescue StandardError
        'unknown'
      end

      def mmp_config
        return ::MMP.load_config if defined?(::MMP) && ::MMP.respond_to?(:load_config)
        {}
      end

      def resolve_workspace_root
        defined?(::KairosMcp) ? KairosMcp.data_dir : Dir.pwd
      end

      def resolve_data_dir
        defined?(::KairosMcp) ? KairosMcp.data_dir : Dir.pwd
      end
    end
  end
end
