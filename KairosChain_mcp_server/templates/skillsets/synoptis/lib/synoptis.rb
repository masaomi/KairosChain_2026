# frozen_string_literal: true

require_relative 'synoptis/proof_envelope'
require_relative 'synoptis/verifier'
require_relative 'synoptis/attestation_engine'
require_relative 'synoptis/revocation_manager'
require_relative 'synoptis/registry/file_registry'
require_relative 'synoptis/challenge_manager'
require_relative 'synoptis/trust_scorer'
require_relative 'synoptis/tool_helpers'
require_relative 'synoptis/transport/base_transport'
require_relative 'synoptis/transport/mmp_transport'
require_relative 'synoptis/transport/hestia_transport'
require_relative 'synoptis/transport/local_transport'

module Synoptis
  SYNOPTIS_ACTIONS = %w[
    attestation_request
    attestation_response
    attestation_revoke
    challenge_create
    challenge_respond
  ].freeze

  class << self
    def load!(config: {})
      register_mmp_handlers
      @config = config
      @loaded = true
    end

    def loaded?
      @loaded == true
    end

    def config
      @config || {}
    end

    def unload!
      unregister_mmp_handlers
      @loaded = false
      @config = nil
    end

    private

    def register_mmp_handlers
      return unless defined?(::MMP::Protocol)

      SYNOPTIS_ACTIONS.each do |action|
        MMP::Protocol.register_handler(action) do |msg_data, protocol_instance|
          handle_mmp_message(action, msg_data, protocol_instance)
        end
      end
    end

    def unregister_mmp_handlers
      return unless defined?(::MMP::Protocol)

      SYNOPTIS_ACTIONS.each do |action|
        MMP::Protocol.unregister_handler(action)
      end
    end

    def handle_mmp_message(action, msg_data, _protocol_instance)
      authenticated_peer = msg_data[:_authenticated_peer_id]

      case action
      when 'attestation_request'
        { status: 'received', action: action, from: authenticated_peer || msg_data[:from],
          message: 'Attestation request received. Process via attestation tools.' }
      when 'attestation_response'
        { status: 'received', action: action, from: authenticated_peer || msg_data[:from],
          message: 'Attestation response received.' }
      when 'attestation_revoke'
        { status: 'received', action: action, from: authenticated_peer || msg_data[:from],
          message: 'Revocation notice received.' }
      when 'challenge_create'
        { status: 'received', action: action, from: authenticated_peer || msg_data[:from],
          message: 'Challenge received.' }
      when 'challenge_respond'
        { status: 'received', action: action, from: authenticated_peer || msg_data[:from],
          message: 'Challenge response received.' }
      else
        { status: 'error', action: action, message: "Unknown Synoptis action: #{action}" }
      end
    end
  end
end
