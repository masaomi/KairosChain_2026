# frozen_string_literal: true

require 'json'
require 'fileutils'

module KairosMcp
  module SkillSets
    module Agent
      class Session
        attr_reader :session_id, :mandate_id, :goal_name, :invocation_context,
                    :state, :cycle_number, :config

        def initialize(session_id:, mandate_id:, goal_name:, invocation_context:, config:)
          @session_id = session_id
          @mandate_id = mandate_id
          @goal_name = goal_name
          @invocation_context = invocation_context
          @config = config
          @state = 'created'
          @cycle_number = 0
          @snapshots = []
        end

        # Per-phase budget configuration.
        # Returns defaults if the phase is not configured.
        def phase_config(phase_name)
          phases = @config['phases'] || {}
          phase = phases[phase_name.to_s] || {}
          {
            max_llm_calls: phase['max_llm_calls'] || 10,
            max_tool_calls: phase['max_tool_calls'] || 20,
            max_repair_attempts: phase['max_repair_attempts'] || 3
          }
        end

        # Record LLM snapshot for auditability.
        # Appends to in-memory array and persists to llm_snapshots.jsonl.
        def record_snapshot(snapshot)
          return unless snapshot

          @snapshots << snapshot
          snapshots_path = File.join(session_dir, 'llm_snapshots.jsonl')
          File.open(snapshots_path, 'a') { |f| f.puts(JSON.generate(snapshot)) }
        end

        def update_state(new_state)
          @state = new_state
        end

        def increment_cycle
          @cycle_number += 1
        end

        # Persist decision_payload for the proposed→ACT transition.
        def save_decision(decision_payload)
          File.write(decision_path, JSON.pretty_generate(decision_payload))
        end

        # Load the last saved decision_payload.
        def load_decision
          return nil unless File.exist?(decision_path)
          JSON.parse(File.read(decision_path))
        rescue JSON::ParserError
          nil
        end

        # Persist observation for ORIENT continuity.
        def save_observation(observation)
          File.write(observation_path, JSON.pretty_generate(observation))
        end

        # Load the last observation.
        def load_observation
          return nil unless File.exist?(observation_path)
          JSON.parse(File.read(observation_path))
        rescue JSON::ParserError
          nil
        end

        # Persist session state to disk.
        def save
          data = {
            session_id: @session_id, mandate_id: @mandate_id,
            goal_name: @goal_name, state: @state, cycle_number: @cycle_number,
            config: @config,
            invocation_context: @invocation_context.to_h
          }
          File.write(state_path, JSON.pretty_generate(data))
        end

        # Load a session from disk.
        # InvocationContext is reconstructed from saved policy fields.
        # depth and root_invocation_id are intentionally NOT persisted —
        # a resumed session is a new invocation chain, not a continuation
        # of the previous call stack.
        def self.load(session_id)
          dir = storage_path("agent_sessions/#{session_id}")
          path = File.join(dir, 'session.json')
          return nil unless File.exist?(path)

          data = JSON.parse(File.read(path), symbolize_names: false)
          ctx = KairosMcp::InvocationContext.from_h(data['invocation_context'])

          session = new(
            session_id: data['session_id'],
            mandate_id: data['mandate_id'],
            goal_name: data['goal_name'],
            invocation_context: ctx,
            config: data['config']
          )
          session.instance_variable_set(:@state, data['state'])
          session.instance_variable_set(:@cycle_number, data['cycle_number'] || 0)
          session
        end

        # List active session IDs.
        def self.list_active
          dir = storage_path('agent_sessions')
          return [] unless File.directory?(dir)

          Dir.children(dir).filter_map do |session_id|
            s = load(session_id)
            s if s && !%w[terminated].include?(s.state)
          rescue StandardError
            nil
          end
        end

        private

        def session_dir
          dir = self.class.storage_path("agent_sessions/#{@session_id}")
          FileUtils.mkdir_p(dir)
          dir
        end

        def state_path
          File.join(session_dir, 'session.json')
        end

        def decision_path
          File.join(session_dir, 'decision_payload.json')
        end

        def observation_path
          File.join(session_dir, 'observation.json')
        end

        # Resolve storage path via Autonomos if available, else fallback.
        def self.storage_path(subpath)
          if defined?(Autonomos) && Autonomos.respond_to?(:storage_path)
            Autonomos.storage_path(subpath)
          else
            path = File.join('.kairos', 'storage', subpath)
            FileUtils.mkdir_p(path)
            path
          end
        end
      end
    end
  end
end
