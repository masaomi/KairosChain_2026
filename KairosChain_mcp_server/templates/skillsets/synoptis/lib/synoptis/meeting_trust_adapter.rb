# frozen_string_literal: true

require 'time'

module Synoptis
  # Fetches raw data from a connected Meeting Place and prepares it for
  # TrustScorer v2 computation. All trust computation remains client-side;
  # this adapter only handles data retrieval, signature verification, and caching.
  #
  # Core principle: Meeting Place provides facts; trust is a local cognitive act.
  class MeetingTrustAdapter
    DEFAULT_CACHE_TTL = 300 # 5 minutes

    def initialize(place_client:, crypto: nil, config: {})
      @client = place_client
      @crypto = crypto
      @cache = {}
      @cache_ttl = config.fetch('cache_ttl', config.fetch(:cache_ttl, DEFAULT_CACHE_TTL))
      @remote_signal_discount = config.fetch('remote_signal_discount',
                                             config.fetch(:remote_signal_discount, 0.5))
    end

    attr_reader :remote_signal_discount

    # Fetch skill data for trust scoring. Uses preview_skill for full attestation data.
    # Returns nil if Meeting Place is not connected or skill not found.
    def fetch_skill_data(skill_id, owner: nil)
      cache_key = "skill:#{skill_id}:#{owner}"
      cached = get_cache(cache_key)
      return cached if cached

      result = @client.preview_skill(skill_id: skill_id, owner: owner, first_lines: 0)
      return nil unless result && !result[:error]

      set_cache(cache_key, result)
      result
    rescue StandardError
      nil
    end

    # Fetch all deposited skills (with attestations) visible on the Meeting Place.
    # For depositor trust, we filter by owner_agent_id client-side.
    def fetch_all_skills
      cache_key = 'all_skills'
      cached = get_cache(cache_key)
      return cached if cached

      result = @client.browse(type: 'deposited_skill', limit: 50)
      return [] unless result

      skills = result[:entries] || result[:skills] || []
      set_cache(cache_key, skills)
      skills
    rescue StandardError
      []
    end

    # Fetch skills for a specific depositor from cached browse results.
    # Server uses :agent_id; meeting_browse tool maps to :owner_agent_id.
    # We check both for compatibility.
    def fetch_depositor_skills(agent_id)
      all = fetch_all_skills
      all.select { |s| owner_of(s) == agent_id }
    end

    # Extract owner agent ID from skill data, handling both server and tool formats.
    def owner_of(skill_data)
      skill_data[:owner_agent_id] || skill_data[:agent_id] || skill_data[:depositor_id]
    end

    # Verify an attestation signature client-side.
    # Returns true if: no signature present (accepted with discount), or signature valid.
    # Returns false only if signature is present but verification fails.
    def verify_attestation_signature(attestation)
      return true unless attestation[:has_signature]
      return true unless @crypto # No crypto available — accept with discount

      # Meeting Place browse only exposes has_signature (boolean),
      # not the full signature material. For browse-derived attestations,
      # we accept them with a discount applied at the scoring layer.
      # Full verification requires preview_skill which includes signed_payload.
      if attestation[:signature] && attestation[:signed_payload]
        @crypto.verify_signature(
          attestation[:signed_payload],
          attestation[:signature],
          attestation[:attester_public_key]
        )
      else
        true # Browse-level: accept, scoring layer applies discount
      end
    rescue StandardError
      false
    end

    # Check if the Meeting Place client is connected.
    def connected?
      return false unless @client

      status = @client.session_status
      status && (status[:connected] || status['connected'])
    rescue StandardError
      false
    end

    private

    def get_cache(key)
      entry = @cache[key]
      return nil unless entry
      return nil if Time.now - entry[:at] > @cache_ttl

      entry[:data]
    end

    def set_cache(key, data)
      @cache[key] = { data: data, at: Time.now }
    end
  end
end
