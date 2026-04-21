# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'time'

require_relative 'canonical'

module KairosMcp
  class Daemon
    # Planner — converts a Chronos FiredEvent into a plan for WAL commit.
    #
    # Design (v0.2 P3.0):
    #   One plan per cycle. Each OODA phase becomes a WAL step with a
    #   content-addressed params_hash, plus pre/expected-post hashes that
    #   let WAL recovery idempotency-check each step on restart.
    #
    # Why 5 steps (observe/orient/decide/act/reflect):
    #   The CognitiveLoop semantics map 1:1 onto these phases. Making each
    #   phase a WAL step gives crash recovery the finest granularity the
    #   loop currently distinguishes. If future CognitiveLoop variants add
    #   or collapse phases, the Planner is where that change lives — the
    #   WAL contract remains unchanged.
    module Planner
      OODA_PHASES = %w[observe orient decide act reflect].freeze

      module_function

      # Build a plan for a single cycle of a fired event.
      #
      # @param fired_event [#name, #fired_at, #mandate] a FiredEvent.
      # @param cycle [Integer] 1-based cycle counter.
      # @param plan_id [String, nil] override for testing.
      # @return [Hash] { plan_id:, cycle:, steps: [ { step_id:, tool:,
      #   params_hash:, pre_hash:, expected_post_hash: }, ... ] }
      def plan_from_fired_event(fired_event, cycle: 1, plan_id: nil)
        cycle = Integer(cycle)
        raise ArgumentError, 'cycle must be positive' unless cycle.positive?

        pid = plan_id || generate_plan_id(fired_event)
        name = event_name(fired_event)

        steps = OODA_PHASES.each_with_index.map do |phase, idx|
          build_step(phase: phase, idx: idx, cycle: cycle, plan_id: pid, mandate_name: name)
        end

        { plan_id: pid, cycle: cycle, steps: steps }
      end

      # Canonical step id for a phase within a cycle. Exposed as a helper
      # so WalPhaseRecorder can derive the same ids without re-planning.
      def step_id_for(phase, cycle)
        format('%s_%03d', phase.to_s, Integer(cycle))
      end

      # ---------------------------------------------------------------- helpers

      def build_step(phase:, idx:, cycle:, plan_id:, mandate_name:)
        params = {
          phase:        phase,
          order:        idx,
          cycle:        cycle,
          plan_id:      plan_id,
          mandate_name: mandate_name
        }
        {
          step_id:            step_id_for(phase, cycle),
          tool:               "ooda.#{phase}",
          params_hash:        Canonical.sha256_json(params),
          pre_hash:           Canonical.sha256_json(phase_marker(phase, cycle, 'pre')),
          expected_post_hash: Canonical.sha256_json(phase_marker(phase, cycle, 'post'))
        }
      end

      def phase_marker(phase, cycle, state)
        { phase: phase, cycle: cycle, state: state }
      end

      def event_name(fired_event)
        return fired_event.name.to_s if fired_event.respond_to?(:name) && fired_event.name
        'unnamed_event'
      end

      # plan_id is deterministic on (name, fired_at) when both are present,
      # otherwise falls back to a random suffix so distinct calls never
      # collide. Determinism matters for recovery — the same event fired
      # twice with the same timestamp should resolve to the same plan.
      def generate_plan_id(fired_event)
        name     = event_name(fired_event)
        fired_at = fired_event.respond_to?(:fired_at) ? fired_event.fired_at : nil
        if fired_at && !fired_at.to_s.empty?
          digest = Digest::SHA256.hexdigest("#{name}|#{fired_at}")
          "plan_#{digest[0, 12]}"
        else
          "plan_#{name}_#{SecureRandom.hex(4)}"
        end
      end
    end
  end
end
