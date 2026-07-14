# frozen_string_literal: true

require 'securerandom'

module Autonomos
  # Manages mandate lifecycle for continuous mode.
  # A mandate is the human's pre-authorization for a bounded loop.
  class Mandate
    VALID_STATUSES = %w[
      created active
      paused_at_checkpoint paused_risk_exceeded paused_goal_drift
      terminated interrupted
    ].freeze

    TERMINATION_REASONS = %w[
      goal_achieved max_cycles_reached error_threshold
      loop_detected interrupted
    ].freeze

    RISK_BUDGETS = %w[low medium].freeze

    # Deterministic tool -> risk map. The per-step `risk` in a proposal is assigned by
    # the DECIDE model and is therefore non-deterministic: identical read-only work was
    # observed to be labelled `medium` in one run and `low` in another, making the risk
    # gate fire inconsistently. For KNOWN tools this map is authoritative (it both floors
    # AND caps the model's label), so read-only/drafting tools are always `low` and
    # destructive/shell tools are always `high` regardless of how the model labelled them.
    # Unknown tools fall back to the model-assigned risk (then `low`).
    TOOL_RISK = {
      # read-only / in-place drafting into working files → low
      'resource_read' => 'low', 'resource_list' => 'low',
      'knowledge_get' => 'low', 'knowledge_list' => 'low', 'skills_list' => 'low',
      'skills_get' => 'low', 'context_save' => 'low', 'document_status' => 'low',
      'write_section' => 'low', 'llm_call' => 'low', 'safe_file_read' => 'low',
      'safe_file_list' => 'low', 'chain_status' => 'low', 'chain_verify' => 'low',
      # durable / L0-L1 / external-effect writes → medium
      'chain_record' => 'medium', 'safe_file_write' => 'medium', 'safe_file_edit' => 'medium',
      'safe_file_copy' => 'medium', 'knowledge_update' => 'medium',
      'instructions_update' => 'medium', 'skills_promote' => 'medium',
      'safe_http_get' => 'medium', 'safe_http_post' => 'medium', 'safe_git_commit' => 'medium',
      # destructive / shell / irreversible-external → high
      'Bash' => 'high', 'safe_file_delete' => 'high', 'safe_git_push' => 'high'
    }.freeze

    class LockError < StandardError; end

    class << self
      def create(goal_name:, goal_hash:, max_cycles:, checkpoint_every:, risk_budget:)
        validate_params!(max_cycles, checkpoint_every, risk_budget)

        mandate_id = generate_id
        mandate = {
          mandate_id: mandate_id,
          goal_name: goal_name,
          goal_hash: goal_hash,
          max_cycles: max_cycles,
          checkpoint_every: checkpoint_every,
          risk_budget: risk_budget,
          status: 'created',
          cycles_completed: 0,
          consecutive_errors: 0,
          cycle_history: [],
          last_proposal: nil,
          last_cycle_id: nil,
          recent_gap_descriptions: [],
          created_at: Time.now.iso8601,
          updated_at: Time.now.iso8601
        }

        save(mandate_id, mandate)
        mandate
      end

      def load(mandate_id)
        validate_id!(mandate_id)
        path = mandate_path(mandate_id)
        return nil unless File.exist?(path)

        JSON.parse(File.read(path), symbolize_names: true)
      end

      # Alias for clarity when reloading inside with_lock
      def reload(mandate_id)
        load(mandate_id)
      end

      def save(mandate_id, mandate)
        validate_id!(mandate_id)
        path = mandate_path(mandate_id)
        mandate[:updated_at] = Time.now.iso8601
        # Atomic write via tmp+rename
        tmp = "#{path}.tmp.#{$$}.#{Thread.current.object_id}"
        File.write(tmp, JSON.pretty_generate(mandate))
        File.rename(tmp, path)
      end

      # Single-writer lock for autonomous batch execution.
      # Yields the loaded mandate; caller must use reload() to refresh after internal saves.
      def with_lock(mandate_id)
        validate_id!(mandate_id)
        lock_path = mandate_path(mandate_id) + '.lock'
        File.open(lock_path, File::CREAT | File::RDWR) do |f|
          unless f.flock(File::LOCK_EX | File::LOCK_NB)
            raise LockError, "Mandate #{mandate_id} is locked by another process"
          end
          begin
            mandate = load(mandate_id)
            yield mandate
          ensure
            f.flock(File::LOCK_UN)
          end
        end
      end

      def update_status(mandate_id, new_status)
        mandate = load(mandate_id)
        return nil unless mandate

        unless VALID_STATUSES.include?(new_status)
          raise ArgumentError, "Invalid status: #{new_status}. Valid: #{VALID_STATUSES.join(', ')}"
        end

        mandate[:status] = new_status
        save(mandate_id, mandate)
        mandate
      end

      def record_cycle(mandate_id, cycle_id:, evaluation:, proposal: nil)
        mandate = load(mandate_id)
        return nil unless mandate

        mandate[:cycles_completed] += 1
        mandate[:cycle_history] << {
          cycle_id: cycle_id,
          evaluation: evaluation,
          completed_at: Time.now.iso8601
        }

        if %w[failed unknown].include?(evaluation)
          mandate[:consecutive_errors] += 1
        else
          mandate[:consecutive_errors] = 0
        end

        mandate[:last_proposal] = proposal
        save(mandate_id, mandate)
        mandate
      end

      def check_termination(mandate)
        if mandate[:cycles_completed] >= mandate[:max_cycles]
          return 'max_cycles_reached'
        end

        if mandate[:consecutive_errors] >= 2
          return 'error_threshold'
        end

        nil
      end

      def checkpoint_due?(mandate)
        return false if mandate[:cycles_completed].zero?

        (mandate[:cycles_completed] % mandate[:checkpoint_every]).zero?
      end

      def loop_detected?(current_proposal, recent_gap_descriptions)
        return false unless current_proposal

        current_desc = current_proposal.dig(:selected_gap, :description)
        return false unless current_desc

        recent = Array(recent_gap_descriptions)
        return false if recent.empty?

        # Normalize numbers to prevent interpolated counts from defeating detection
        # e.g. "6 uncommitted files" and "7 uncommitted files" both become "N uncommitted files"
        normalize = ->(s) { s.to_s.gsub(/\d+/, 'N') }
        current_norm = normalize.call(current_desc)
        recent_norm = recent.map { |d| normalize.call(d) }

        # Consecutive same-gap detection (A→A)
        return true if recent_norm.last == current_norm

        # Oscillation detection (A→B→A pattern) with 3-step window
        if recent_norm.size >= 2
          window = recent_norm.last(2) + [current_norm]
          return true if window[0] == window[2] && window[0] != window[1]
        end

        false
      end

      def risk_exceeds_budget?(proposal, risk_budget)
        return false unless proposal && proposal[:autoexec_task]

        steps = proposal[:autoexec_task][:steps] || []
        steps.any? do |step|
          risk = effective_risk(step)
          case risk_budget
          when 'low'
            %w[medium high].include?(risk)
          when 'medium'
            risk == 'high'
          else
            false
          end
        end
      end

      # Resolve a step's risk deterministically: the tool map wins for known tools
      # (both raising and lowering the model's label), otherwise the model-assigned
      # risk is used, defaulting to 'low'.
      def effective_risk(step)
        tool = step[:tool_name] || step['tool_name']
        TOOL_RISK[tool] || step[:risk] || 'low'
      end

      def list_active
        mandates_dir = Autonomos.storage_path('mandates')
        files = Dir.glob(File.join(mandates_dir, '*.json'))
        files.filter_map do |path|
          m = JSON.parse(File.read(path), symbolize_names: true)
          m if %w[created active paused_at_checkpoint paused_risk_exceeded paused_goal_drift].include?(m[:status])
        rescue JSON::ParserError
          nil
        end
      end

      private

      def generate_id
        "mnd_#{Time.now.strftime('%Y%m%d_%H%M%S')}_#{SecureRandom.hex(3)}"
      end

      def mandate_path(mandate_id)
        mandates_dir = Autonomos.storage_path('mandates')
        File.join(mandates_dir, "#{mandate_id}.json")
      end

      def validate_id!(mandate_id)
        unless mandate_id.to_s.match?(/\A[\w\-]+\z/)
          raise ArgumentError, 'Invalid mandate_id: must contain only word characters and hyphens'
        end
      end

      def validate_params!(max_cycles, checkpoint_every, risk_budget)
        unless (1..10).cover?(max_cycles.to_i)
          raise ArgumentError, "max_cycles must be 1-10, got: #{max_cycles}"
        end

        unless (1..3).cover?(checkpoint_every.to_i)
          raise ArgumentError, "checkpoint_every must be 1-3, got: #{checkpoint_every}"
        end

        if checkpoint_every.to_i > max_cycles.to_i
          raise ArgumentError, "checkpoint_every (#{checkpoint_every}) must be <= max_cycles (#{max_cycles})"
        end

        unless RISK_BUDGETS.include?(risk_budget.to_s)
          raise ArgumentError, "risk_budget must be one of: #{RISK_BUDGETS.join(', ')}"
        end
      end
    end
  end
end
