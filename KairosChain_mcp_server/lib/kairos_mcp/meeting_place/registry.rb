# frozen_string_literal: true

require 'securerandom'
require 'time'
require 'net/http'
require 'uri'

module KairosMcp
  module MeetingPlace
    # Registry manages connected agents in the Meeting Place.
    # Agents register when they arrive and are automatically removed on timeout.
    #
    # Cleanup strategies:
    # 1. TTL-based: Agents are removed if not seen within TTL_SECONDS
    # 2. On-demand: When fetching an agent, optionally ping to verify alive
    # 3. Manual: Admin can force cleanup of dead agents
    class Registry
      DEFAULT_TTL_SECONDS = 300  # 5 minutes
      CLEANUP_INTERVAL = 60     # 1 minute
      PING_TIMEOUT = 3          # 3 seconds for ping

      Agent = Struct.new(:id, :name, :description, :scope, :capabilities, :endpoint, :registered_at, :last_seen, :metadata, :ping_failures, keyword_init: true)

      def initialize(ttl_seconds: DEFAULT_TTL_SECONDS, verify_on_get: false, max_ping_failures: 3)
        @agents = {}
        @ttl_seconds = ttl_seconds
        @verify_on_get = verify_on_get      # On-demand verification
        @max_ping_failures = max_ping_failures
        @mutex = Mutex.new
      end

      # Register a new agent or update existing
      def register(agent_data)
        @mutex.synchronize do
          # Support both 'id' and 'agent_id' keys for compatibility
          id = agent_data[:id] || agent_data['id'] || 
               agent_data[:agent_id] || agent_data['agent_id'] || 
               generate_agent_id
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
            metadata: agent_data[:metadata] || agent_data['metadata'] || {},
            ping_failures: 0
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
      # @param agent_id [String] Agent ID
      # @param verify [Boolean] If true, ping the agent to verify it's alive
      def get(agent_id, verify: nil)
        should_verify = verify.nil? ? @verify_on_get : verify
        
        @mutex.synchronize do
          agent = @agents[agent_id]
          return nil unless agent
          return nil if expired?(agent)

          # On-demand verification
          if should_verify && agent.endpoint
            if ping_agent_unsafe(agent)
              agent.last_seen = Time.now.utc
              agent.ping_failures = 0
            else
              agent.ping_failures = (agent.ping_failures || 0) + 1
              if agent.ping_failures >= @max_ping_failures
                @agents.delete(agent_id)
                return nil
              end
            end
          end

          agent_to_hash(agent)
        end
      end

      # List all active agents
      # @param filters [Hash] Filter options (:scope, :capability)
      # @param verify [Boolean] If true, ping each agent to verify alive (slower but accurate)
      def list(filters: {}, verify: false)
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

          # On-demand verification (optional, can be slow)
          if verify
            result = result.select do |agent|
              if agent.endpoint
                alive = ping_agent_unsafe(agent)
                if alive
                  agent.last_seen = Time.now.utc
                  agent.ping_failures = 0
                  true
                else
                  agent.ping_failures = (agent.ping_failures || 0) + 1
                  if agent.ping_failures >= @max_ping_failures
                    @agents.delete(agent.id)
                  end
                  false
                end
              else
                true  # No endpoint, can't verify
              end
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
            newest_registration: @agents.values.map(&:registered_at).max&.iso8601,
            ttl_seconds: @ttl_seconds,
            verify_on_get: @verify_on_get
          }
        end
      end

      # Force cleanup of all dead agents (ping each one)
      # @return [Hash] Cleanup result with removed agents
      def cleanup_dead_agents
        removed = []
        
        @mutex.synchronize do
          @agents.each do |agent_id, agent|
            next unless agent.endpoint
            
            unless ping_agent_unsafe(agent)
              removed << { id: agent_id, name: agent.name, endpoint: agent.endpoint }
              @agents.delete(agent_id)
            end
          end
        end
        
        {
          removed_count: removed.size,
          removed_agents: removed,
          remaining_count: @agents.size
        }
      end

      # Remove agents older than specified seconds
      # @param older_than_seconds [Integer] Remove agents not seen within this time
      # @return [Hash] Cleanup result
      def cleanup_stale(older_than_seconds:)
        removed = []
        cutoff = Time.now.utc - older_than_seconds
        
        @mutex.synchronize do
          @agents.each do |agent_id, agent|
            if agent.last_seen < cutoff
              removed << { id: agent_id, name: agent.name, last_seen: agent.last_seen.iso8601 }
              @agents.delete(agent_id)
            end
          end
        end
        
        {
          removed_count: removed.size,
          removed_agents: removed,
          remaining_count: @agents.size,
          cutoff_time: cutoff.iso8601
        }
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

      # Ping agent's health endpoint (must be called with mutex NOT held for network I/O)
      # Note: Called "unsafe" because it should only be called when mutex is already held
      # but the actual HTTP request happens outside the critical section concern
      def ping_agent_unsafe(agent)
        return false unless agent.endpoint
        
        begin
          uri = URI.parse("#{agent.endpoint}/health")
          http = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = PING_TIMEOUT
          http.read_timeout = PING_TIMEOUT
          http.use_ssl = uri.scheme == 'https'
          
          response = http.get(uri.path)
          response.is_a?(Net::HTTPSuccess)
        rescue StandardError
          false
        end
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
          metadata: agent.metadata,
          ping_failures: agent.ping_failures || 0
        }
      end
    end
  end
end
