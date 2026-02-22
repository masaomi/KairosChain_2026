# frozen_string_literal: true

require 'time'

module Hestia
  # HeartbeatManager handles TTL-based agent expiry.
  #
  # When an agent's last_heartbeat exceeds the TTL, they are marked
  # as faded and an ObservationLog is recorded (DEE: fade-out as
  # first-class outcome, not failure).
  #
  # D2: On TTL expiry → ObservationLog(type: 'faded') → trust_anchor
  # D5: NO heartbeat penalty — missed heartbeat = TTL expiry only
  class HeartbeatManager
    DEFAULT_TTL_SECONDS = 3600  # 1 hour

    def initialize(registry:, trust_anchor: nil, ttl_seconds: DEFAULT_TTL_SECONDS, observer_id: nil)
      @registry = registry
      @trust_anchor = trust_anchor
      @ttl_seconds = ttl_seconds
      @observer_id = observer_id
    end

    # Check all agents and expire those past TTL.
    #
    # @return [Hash] Result with expired agent IDs
    def check_all
      now = Time.now.utc
      agents = @registry.list(include_self: false)
      expired = []

      agents.each do |agent|
        next if agent[:is_self]

        last = begin
                 Time.parse(agent[:last_heartbeat])
               rescue StandardError
                 Time.at(0)
               end

        if (now - last) > @ttl_seconds
          record_fadeout(agent)
          @registry.unregister(agent[:id])
          expired << agent[:id]
        end
      end

      { checked: agents.size, expired: expired, expired_count: expired.size }
    end

    # Record a heartbeat for an agent (extends their TTL).
    #
    # @param agent_id [String] Agent ID
    def touch(agent_id)
      @registry.heartbeat(agent_id)
    end

    # Get TTL status for an agent.
    #
    # @param agent_id [String] Agent ID
    # @return [Hash, nil] TTL info
    def ttl_status(agent_id)
      agent = @registry.get(agent_id)
      return nil unless agent

      last = begin
               Time.parse(agent[:last_heartbeat])
             rescue StandardError
               Time.at(0)
             end
      elapsed = Time.now.utc - last
      remaining = [@ttl_seconds - elapsed, 0].max

      {
        agent_id: agent_id,
        last_heartbeat: agent[:last_heartbeat],
        elapsed_seconds: elapsed.to_i,
        remaining_seconds: remaining.to_i,
        expired: remaining <= 0
      }
    end

    private

    # Record a fade-out observation on HestiaChain.
    # DEE: "Fade-out as first-class outcome"
    def record_fadeout(agent)
      return unless @trust_anchor && @observer_id

      require 'digest'
      interaction_hash = Digest::SHA256.hexdigest(
        "fadeout:#{agent[:id]}:#{agent[:last_heartbeat]}:#{Time.now.utc.iso8601}"
      )

      observation = Chain::Protocol::ObservationLog.new(
        observer_id: @observer_id,
        observed_id: agent[:id],
        interaction_hash: interaction_hash,
        observation_type: 'faded',
        interpretation: {
          reason: 'ttl_expired',
          last_heartbeat: agent[:last_heartbeat],
          ttl_seconds: @ttl_seconds
        }
      )

      @trust_anchor.submit(observation.to_anchor)
    rescue StandardError => e
      $stderr.puts "[HeartbeatManager] Failed to record fadeout: #{e.message}"
    end
  end
end
