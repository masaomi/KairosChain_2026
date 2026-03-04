# frozen_string_literal: true

# MMP Protocol action registration for Synoptis SkillSet
# Registers attestation-related actions with MMP::Protocol
# so that P2P attestation messages are recognized by action_supported?
module Synoptis
  module Hooks
    ATTESTATION_ACTIONS = %w[
      attestation_request
      attestation_evidence
      attestation_proof
      attestation_revoke
      attestation_challenge
      attestation_response
      attestation_list
    ].freeze

    def self.register_mmp_actions!
      return unless defined?(MMP::Protocol) && MMP::Protocol.respond_to?(:register_actions)

      MMP::Protocol.register_actions(ATTESTATION_ACTIONS)
    end
  end
end
