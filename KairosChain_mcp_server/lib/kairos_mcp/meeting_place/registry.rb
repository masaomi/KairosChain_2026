# frozen_string_literal: true

require 'securerandom'
require 'time'

module KairosMcp
  module MeetingPlace
    # Registry manages connected agents in the Meeting Place.
    # Agents register when they arrive and are automatically removed on timeout.
    class Registry
      DEFAULT_TTL_SECONDS = 300  # 5 minutes
      CLEANUP_INTERVAL = 60     # 1 minute

      Agent = Struct.new(:id, :name, :description, :scope, :capabilities, :endpoint, :registered_at, :last_seen, :metadata, keyword_init: true)

      def initialize(ttl_seconds: DEFAULT_TTL_SECONDS)
        @agents = {}
        @ttl_seconds = ttl_seconds
        @mutex = Mutex.new
      end

      # Register a new agent or update existing
      def register(agent_data)
        @mutex.synchronize do
          id = agent_data[:id] || agent_data['id'] || generate_agent_id
          now = Time.now.utc

          agent = Agent.new(
            id: id,
            name: agent_data[:name] || agent_data['name'] || 'Unknown',
            description: agent_data[:description] || agent_data['description'] || '',
            scope: agent_data[:scope] || agent_data['scope'] || 'general',
            capabilities: agent_data[:capabilities] || agent_data['capabilities'] || {},
            endpoint: agent_data[:endpoint] || agent_data['endpoint'],
            registered_at: @agents[id]&.registered_at || now,
            last_seen: now,
            metadata: agent_data[:metadata] || agent_data['metadata'] || {}
          )

          @agents[id] = agent
          { agent_id: id, registered_at: agent.registered_at.iso8601, status: 'registered' }
        end
      end

      # Update last_seen timestamp (heartbeat)
      def heartbeat(agent_id)
        @mutex.synchronize do
          agent = @agents[agent_id]
          return nil unless agent

          agent.last_seen = Time.now.utc
          { agent_id: agent_id, last_seen: agent.last_seen.iso8601, status: 'active' }
        end
      end

      # Unregister an agent
      def unregister(agent_id)
        @mutex.synchronize do
          agent = @agents.delete(agent_id)
          return nil unless agent

          { agent_id: agent_id, status: 'unregistered', was_registered_for: (Time.now.utc - agent.registered_at).to_i }
        end
      end

      # Get agent by ID
      def get(agent_id)
        @mutex.synchronize do
          agent = @agents[agent_id]
          return nil unless agent

          agent_to_hash(agent)
        end
      end

      # List all active agents
      def list(filters: {})
        @mutex.synchronize do
          cleanup_expired

          result = @agents.values

          # Filter by scope
          if filters[:scope]
            result = result.select { |a| a.scope == filters[:scope] }
          end

          # Filter by capability
          if filters[:capability]
            result = result.select do |a|
              caps = a.capabilities[:supported_actions] || a.capabilities['supported_actions'] || []
              caps.include?(filters[:capability])
            end
          end

          result.map { |a| agent_to_hash(a) }
        end
      end

      # Count of active agents
      def count
        @mutex.synchronize do
          cleanup_expired
          @agents.size
        end
      end

      # Check if agent is registered
      def registered?(agent_id)
        @mutex.synchronize do
          @agents.key?(agent_id) && !expired?(@agents[agent_id])
        end
      end

      # Get statistics
      def stats
        @mutex.synchronize do
          cleanup_expired

          scopes = @agents.values.group_by(&:scope).transform_values(&:count)
          
          {
            total_agents: @agents.size,
            by_scope: scopes,
            oldest_registration: @agents.values.map(&:registered_at).min&.iso8601,
            newest_registration: @agents.values.map(&:registered_at).max&.iso8601
          }
        end
      end

      private

      def generate_agent_id
        "agent_#{SecureRandom.hex(8)}"
      end

      def expired?(agent)
        Time.now.utc - agent.last_seen > @ttl_seconds
      end

      def cleanup_expired
        @agents.delete_if { |_id, agent| expired?(agent) }
      end

      def agent_to_hash(agent)
        {
          id: agent.id,
          name: agent.name,
          description: agent.description,
          scope: agent.scope,
          capabilities: agent.capabilities,
          endpoint: agent.endpoint,
          registered_at: agent.registered_at.iso8601,
          last_seen: agent.last_seen.iso8601,
          metadata: agent.metadata
        }
      end
    end
  end
end
