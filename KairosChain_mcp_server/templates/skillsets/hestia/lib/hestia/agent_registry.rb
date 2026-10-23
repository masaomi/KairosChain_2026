# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'
require 'time'

module Hestia
  # AgentRegistry manages registered agents at this Meeting Place, and the
  # binding of each agent id to its public key.
  #
  # Registration (presence) and binding are separate: an agent entry comes and
  # goes with registration and heartbeat expiry, while a binding, once made, is
  # never changed or removed by a request or by fade-out — only by the operator
  # editing the bindings file with the Place stopped. Clients trust and track
  # peers by id, so an id must keep meaning after its owner disconnects.
  #
  # Bindings live in their own file, written atomically and only when a binding
  # is created; heartbeats never rewrite it. A bindings file that cannot be read
  # or parsed stops the Place rather than being taken for an empty table.
  #
  # Self-registration support for 主客未分 (subject-object undifferentiated).
  class AgentRegistry
    DEFAULT_REGISTRY_PATH = 'storage/agent_registry.json'
    DEFAULT_BINDING_RATE_PER_HOUR = 60

    # Raised when the bindings file cannot be read, parsed or written.
    class BindingStoreError < StandardError; end

    Agent = Struct.new(
      :id, :name, :url, :capabilities, :public_key,
      :is_self, :registered_at, :last_heartbeat, :visited_places,
      :description, :scope,
      keyword_init: true
    )

    attr_reader :agents

    # @param bindings_path [String, nil] Persistent bindings file. nil keeps
    #   bindings in memory only (unit use); the Place always passes a path.
    # @param require_bindings_file [Boolean] Refuse to start when the bindings
    #   file is missing (the Place sets this when other persisted state exists).
    def initialize(registry_path: nil, config: {}, bindings_path: nil, require_bindings_file: false)
      @registry_path = registry_path || DEFAULT_REGISTRY_PATH
      @bindings_path = bindings_path
      @agents = {}
      @bindings = {}
      @binding_times = []
      @mutex = Mutex.new
      @config = config
      @binding_rate = (config['binding_rate_per_hour'] || DEFAULT_BINDING_RATE_PER_HOUR).to_i
      load_bindings(require_file: require_bindings_file) if @bindings_path
      load_registry
    end

    # Register an agent at this Meeting Place.
    #
    # When public_key is given it is compared with, or becomes, the id's
    # binding (compare-and-bind under the registry mutex). A key that differs
    # from the binding changes nothing and returns status 'key_mismatch'.
    # A new binding is persisted before anything else is written; a failed
    # write raises BindingStoreError and registers nothing.
    #
    # @return [Hash] { status: 'registered'|'updated'|'key_mismatch'|
    #   'invalid_key'|'binding_rate_exceeded', agent_id: }
    def register(id:, name:, capabilities: nil, public_key: nil, url: nil, is_self: false,
                 visited_places: [], description: nil, scope: nil)
      now = Time.now.utc.iso8601
      @mutex.synchronize do
        if public_key
          bind_result = bind_locked(id, public_key, rate_limited: !is_self)
          return bind_result.merge(agent_id: id) if bind_result

          public_key = @bindings[id][:public_key]
        end

        existing = @agents[id]
        if existing
          # Update existing registration
          existing.name = name
          existing.capabilities = capabilities if capabilities
          existing.public_key = public_key if public_key
          existing.url = url if url
          existing.last_heartbeat = now
          existing.visited_places = visited_places unless visited_places.empty?
          existing.description = description if description
          existing.scope = scope if scope
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
          visited_places: visited_places,
          description: description,
          scope: scope
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

    # Unregister an agent. The id's binding is kept.
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

    # The key bound to an id, or nil when the id is unbound.
    def bound_key(id)
      @mutex.synchronize { @bindings[id]&.dig(:public_key) }
    end

    def bound_ids
      @mutex.synchronize { @bindings.keys }
    end

    # Get an agent's public key: its binding, which outlives registration, so
    # signatures still verify after the agent fades out.
    #
    # @param id [String] Agent ID
    # @return [String, nil] Public key PEM or nil
    def public_key_for(id)
      @mutex.synchronize { @bindings[id]&.dig(:public_key) || @agents[id]&.public_key }
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

    # Compare-and-bind, called with @mutex held.
    # @return [Hash, nil] a refusal, or nil when the key is (now) bound to id
    def bind_locked(id, public_key, rate_limited:)
      return { status: 'invalid_id' } unless ::MMP::RegistrationProof::AGENT_ID_PATTERN.match?(id.to_s)

      canonical = ::MMP::RegistrationProof.canonical_pem(public_key)
      return { status: 'invalid_key' } unless canonical

      bound = @bindings[id]
      if bound
        return nil if ::MMP::RegistrationProof.same_key?(bound[:public_key], canonical)

        return { status: 'key_mismatch' }
      end

      if rate_limited
        prune_binding_times
        if @binding_times.size >= @binding_rate
          return { status: 'binding_rate_exceeded', retry_after: (@binding_times.first + 3600 - Time.now.to_f).ceil }
        end
      end

      entry = { public_key: canonical, bound_at: Time.now.utc.iso8601 }
      persist_bindings(@bindings.merge(id => entry))
      @bindings[id] = entry
      @binding_times << Time.now.to_f if rate_limited
      nil
    end

    def prune_binding_times
      cutoff = Time.now.to_f - 3600
      @binding_times.shift while @binding_times.first && @binding_times.first < cutoff
    end

    def agent_to_h(agent)
      h = {
        id: agent.id,
        name: agent.name,
        url: agent.url,
        capabilities: agent.capabilities,
        is_self: agent.is_self,
        registered_at: agent.registered_at,
        last_heartbeat: agent.last_heartbeat,
        visited_places: agent.visited_places
      }
      h[:description] = agent.description if agent.description
      h[:scope] = agent.scope if agent.scope
      h
    end

    # Load bindings. Anything other than a readable JSON object of
    # id => { "public_key" => PEM } with acceptable keys raises
    # BindingStoreError, so the Place does not start on a damaged file.
    def load_bindings(require_file:)
      unless File.exist?(@bindings_path)
        if require_file
          raise BindingStoreError,
                "Bindings file #{@bindings_path} is missing but other Meeting Place state exists. " \
                'Restore it, or create it (an empty {} is enough) to confirm starting without bindings.'
        end
        return
      end

      data = JSON.parse(File.read(@bindings_path))
      raise BindingStoreError, "Bindings file #{@bindings_path} must hold a JSON object" unless data.is_a?(Hash)

      data.each do |id, entry|
        unless ::MMP::RegistrationProof::AGENT_ID_PATTERN.match?(id) && entry.is_a?(Hash)
          raise BindingStoreError, "Bindings file #{@bindings_path}: malformed entry #{id.inspect}"
        end

        canonical = ::MMP::RegistrationProof.canonical_pem(entry['public_key'])
        raise BindingStoreError, "Bindings file #{@bindings_path}: unusable public key for #{id}" unless canonical

        @bindings[id] = { public_key: canonical, bound_at: entry['bound_at'] }
      end
    rescue JSON::ParserError, SystemCallError, IOError => e
      raise BindingStoreError, "Bindings file #{@bindings_path} cannot be read: #{e.message}"
    end

    # Write the whole table atomically; raise on failure so no session is
    # issued on a binding that is not on disk.
    def persist_bindings(table)
      return unless @bindings_path

      temp = nil
      FileUtils.mkdir_p(File.dirname(@bindings_path))
      data = table.transform_values { |e| { 'public_key' => e[:public_key], 'bound_at' => e[:bound_at] } }
      temp = "#{@bindings_path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
      File.open(temp, 'w') do |f|
        f.write(JSON.pretty_generate(data))
        f.flush
        f.fsync
      end
      File.rename(temp, @bindings_path)
    rescue SystemCallError, IOError => e
      File.unlink(temp) if temp && File.exist?(temp)
      raise BindingStoreError, "Bindings file #{@bindings_path} cannot be written: #{e.message}"
    end

    def load_registry
      @mutex.synchronize do
        if File.exist?(@registry_path)
          data = JSON.parse(File.read(@registry_path), symbolize_names: true)
          (data[:agents] || []).each do |a|
            # With a persistent bindings store, an entry without a binding is
            # not loaded: its key was never saved, and a registered id must
            # have a binding.
            next if @bindings_path && !@bindings.key?(a[:id])

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
