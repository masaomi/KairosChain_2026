# frozen_string_literal: true

require 'time'
require 'securerandom'

require_relative 'canonical'

module KairosMcp
  class Daemon
    # MandateFactory — builds a mandate Hash conforming to the
    # Autonomos::Mandate contract from a Chronos FiredEvent.
    #
    # Design (v0.2 P3.0):
    #   The factory is a pure function: FiredEvent + plan_id → Hash.
    #   Persistence (Autonomos::Mandate.save) is orchestrated by the caller
    #   and must happen AFTER the plan is committed to WAL (write-ahead
    #   semantics: the plan is durable before the mandate exists).
    #
    # Contract — the returned Hash satisfies Autonomos::Mandate shape:
    #   :mandate_id, :goal_name, :goal_hash, :max_cycles, :checkpoint_every,
    #   :risk_budget, :status, :cycles_completed, :consecutive_errors,
    #   :cycle_history, :last_proposal, :last_cycle_id,
    #   :recent_gap_descriptions, :created_at, :updated_at.
    #
    # Extra P3.0 bookkeeping fields added alongside (not required by
    # Autonomos but useful for introspection):
    #   :plan_id, :source, :project_scope, :fired_at.
    #
    # Validation bounds (mirrors Autonomos::Mandate.validate_params!):
    #   max_cycles       ∈ 1..10
    #   checkpoint_every ∈ 1..3 and ≤ max_cycles
    #   risk_budget      ∈ {"low","medium"}
    #
    # Chronos defaults (max_cycles=50) intentionally exceed those bounds;
    # we clamp here rather than raise so that a misconfigured schedule can
    # still fire — the mandate just runs with the clamped ceiling.
    module MandateFactory
      VALID_RISK_BUDGETS = %w[low medium].freeze
      MAX_CYCLES_RANGE   = (1..10).freeze
      CHECKPOINT_RANGE   = (1..3).freeze

      module_function

      # Build a mandate Hash for a fired event.
      #
      # @param fired_event [#name, #schedule, #mandate, #fired_at] a
      #   Chronos::FiredEvent (Struct) or duck-typed equivalent.
      # @param plan_id [String] the plan id (owned by Planner).
      # @param now [Time, nil] injectable clock for tests.
      # @return [Hash] mandate Hash suitable for Autonomos::Mandate.save.
      def build(fired_event, plan_id:, now: nil)
        raise ArgumentError, 'plan_id is required' if plan_id.nil? || plan_id.to_s.empty?

        src = source_mandate(fired_event)
        iso_now = (now || Time.now.utc).iso8601

        goal  = extract_goal(src, fired_event)
        max_c = clamp_integer(src[:max_cycles] || src['max_cycles'], MAX_CYCLES_RANGE, default: 3)
        cp    = clamp_integer(src[:checkpoint_every] || src['checkpoint_every'],
                              CHECKPOINT_RANGE, default: 1)
        cp    = [cp, max_c].min
        risk  = normalize_risk(src[:risk_budget] || src['risk_budget'])

        {
          mandate_id:              derive_mandate_id(plan_id),
          plan_id:                 plan_id.to_s,
          goal_name:               goal,
          goal_hash:               Canonical.sha256(goal),
          max_cycles:              max_c,
          checkpoint_every:        cp,
          risk_budget:             risk,
          status:                  'created',
          cycles_completed:        0,
          consecutive_errors:      0,
          cycle_history:           [],
          last_proposal:           nil,
          last_cycle_id:           nil,
          recent_gap_descriptions: [],
          source:                  (src[:source] || src['source'] ||
                                    "chronos:#{event_name(fired_event)}"),
          project_scope:           (src[:project_scope] || src['project_scope']),
          fired_at:                (fired_event.respond_to?(:fired_at) ? fired_event.fired_at : nil),
          created_at:              iso_now,
          updated_at:              iso_now
        }
      end

      # ---------------------------------------------------------------- helpers

      def source_mandate(fired_event)
        m = fired_event.respond_to?(:mandate) ? fired_event.mandate : nil
        m.is_a?(Hash) ? m : {}
      end

      def event_name(fired_event)
        return fired_event.name.to_s if fired_event.respond_to?(:name) && fired_event.name
        'unnamed_event'
      end

      def extract_goal(src, fired_event)
        (src[:goal] || src['goal'] ||
          (src[:name] || src['name']) ||
          event_name(fired_event)).to_s
      end

      def clamp_integer(value, range, default:)
        n = Integer(value) rescue default
        [[n, range.min].max, range.max].min
      end

      def normalize_risk(value)
        s = value.to_s
        VALID_RISK_BUDGETS.include?(s) ? s : 'low'
      end

      # Deterministic mandate id derived from plan_id. Keeps the two ids
      # linked one-to-one so recovery can pair them without a side table.
      def derive_mandate_id(plan_id)
        "mnd_#{plan_id}"
      end
    end
  end
end
