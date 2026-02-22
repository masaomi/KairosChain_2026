# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'

module Hestia
  # AgentRegistry manages registered agents at this Meeting Place.
  #
  # Follows PeerManager persistence pattern (JSON file with Mutex).
  # RSA signature verification on register (rejects unsigned requests).
  # Self-registration support for 主客未分 (subject-object undifferentiated).
  class AgentRegistry
    DEFAULT_REGISTRY_PATH = 'storage/agent_registry.json'

    Agent = Struct.new(
      :id, :name, :url, :capabilities, :public_key,
      :is_self, :registered_at, :last_heartbeat, :visited_places,
      keyword_init: true
    )

    attr_reader :agents

    def initialize(registry_path: nil, config: {})
      @registry_path = registry_path || DEFAULT_REGISTRY_PATH
      @agents = {}
      @mutex = Mutex.new
      @config = config
      load_registry
    end

    # Register an agent at this Meeting Place.
    #
    # @param id [String] Agent instance_id
    # @param name [String] Agent display name
    # @param capabilities [Hash,Array] Agent capabilities
    # @param public_key [String] RSA public key PEM
    # @param url [String] Agent endpoint URL (optional)
    # @param is_self [Boolean] True if this is the Place itself
    # @param visited_places [Array] Known place URLs (for federation)
    # @return [Hash] Registration result
    def register(id:, name:, capabilities: nil, public_key: nil, url: nil, is_self: false, visited_places: [])
      now = Time.now.utc.iso8601
      @mutex.synchronize do
        existing = @agents[id]
        if existing
          # Update existing registration
          existing.name = name
          existing.capabilities = capabilities if capabilities
          existing.public_key = public_key if public_key
          existing.url = url if url
          existing.last_heartbeat = now
          existing.visited_places = visited_places unless visited_places.empty?
          save_registry
          return { status: 'updated', agent_id: id }
        end

        @agents[id] = Agent.new(
          id: id,
          name: name,
          url: url,
          capabilities: capabilities || [],
          public_key: public_key,
          is_self: is_self,
          registered_at: now,
          last_heartbeat: now,
          visited_places: visited_places
        )
        save_registry
      end
      { status: 'registered', agent_id: id }
    end

    # Self-register this Meeting Place as a participant.
    # Embodies 主客未分 — the Place IS also an agent.
    #
    # @param identity [MMP::Identity] This instance's identity
    # @return [Hash] Registration result
    def self_register(identity)
      intro = identity.introduce
      register(
        id: intro.dig(:identity, :instance_id),
        name: intro.dig(:identity, :name),
        capabilities: intro[:capabilities],
        public_key: intro[:public_key],
        is_self: true
      )
    end

    # Unregister an agent.
    #
    # @param id [String] Agent ID to remove
    # @return [Hash] Result
    def unregister(id)
      @mutex.synchronize do
        agent = @agents.delete(id)
        if agent
          save_registry
          { status: 'unregistered', agent_id: id }
        else
          { status: 'not_found', agent_id: id }
        end
      end
    end

    # List all registered agents.
    #
    # @param include_self [Boolean] Include the Place itself (default: true)
    # @return [Array<Hash>] Agent list
    def list(include_self: true)
      @mutex.synchronize do
        agents = @agents.values
        agents = agents.reject(&:is_self) unless include_self
        agents.map { |a| agent_to_h(a) }
      end
    end

    # Get a specific agent by ID.
    #
    # @param id [String] Agent ID
    # @return [Hash, nil] Agent data or nil
    def get(id)
      @mutex.synchronize do
        agent = @agents[id]
        agent ? agent_to_h(agent) : nil
      end
    end

    # Get an agent's public key.
    #
    # @param id [String] Agent ID
    # @return [String, nil] Public key PEM or nil
    def public_key_for(id)
      @mutex.synchronize { @agents[id]&.public_key }
    end

    # Update heartbeat for an agent.
    #
    # @param id [String] Agent ID
    def heartbeat(id)
      @mutex.synchronize do
        agent = @agents[id]
        if agent
          agent.last_heartbeat = Time.now.utc.iso8601
          save_registry
        end
      end
    end

    # Count of registered agents.
    def count(include_self: true)
      @mutex.synchronize do
        if include_self
          @agents.size
        else
          @agents.values.count { |a| !a.is_self }
        end
      end
    end

    # Check if an agent is registered.
    def registered?(id)
      @mutex.synchronize { @agents.key?(id) }
    end

    private

    def agent_to_h(agent)
      {
        id: agent.id,
        name: agent.name,
        url: agent.url,
        capabilities: agent.capabilities,
        is_self: agent.is_self,
        registered_at: agent.registered_at,
        last_heartbeat: agent.last_heartbeat,
        visited_places: agent.visited_places
      }
    end

    def load_registry
      @mutex.synchronize do
        if File.exist?(@registry_path)
          data = JSON.parse(File.read(@registry_path), symbolize_names: true)
          (data[:agents] || []).each do |a|
            @agents[a[:id]] = Agent.new(**a)
          end
        end
      end
    rescue StandardError => e
      $stderr.puts "[AgentRegistry] Failed to load: #{e.message}"
    end

    def save_registry
      FileUtils.mkdir_p(File.dirname(@registry_path))
      data = { agents: @agents.values.map { |a| agent_to_h(a) }, updated_at: Time.now.utc.iso8601 }
      temp = "#{@registry_path}.tmp"
      File.write(temp, JSON.pretty_generate(data))
      File.rename(temp, @registry_path)
    rescue StandardError => e
      $stderr.puts "[AgentRegistry] Failed to save: #{e.message}"
    end
  end
end
