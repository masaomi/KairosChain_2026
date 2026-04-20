# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require 'zlib'

require_relative 'canonical'

module KairosMcp
  class Daemon
    # WAL — Write-Ahead Log for the DECIDE→ACT boundary.
    #
    # Design (v0.2 §5):
    #   * Per-mandate append-only JSON-lines file at
    #     .kairos/wal/{mandate_id}.wal.jsonl
    #   * Every record is fsync'd after write. Parent directory is fsync'd on
    #     file creation [CF-6] so the newly created inode is durable.
    #   * Covered ops:
    #       - plan_commit    : entire DECIDE-phase plan with hashed steps
    #       - append         : pending step (idem_key computed)
    #       - transition     : pending → executing → completed | failed | needs_review
    #       - plan_finalize  : plan end of life (succeeded / failed / abandoned)
    #   * Recovery (Daemon#recover_from_wal!) parses the file, rebuilds plan
    #     records, and uses `IdempotencyCheck` on every non-finalized step.
    #
    # Crash-safety invariants:
    #   I1. Once `commit_plan` returns, the plan is durable (fsync + dir fsync).
    #   I2. Once a transition mark_* returns, the transition is durable (fsync).
    #   I3. Appends are strictly ordered under @mutex; concurrent callers cannot
    #       interleave partial JSON lines.
    #
    # NOTE on macOS: `IO#fsync` on HFS+/APFS flushes to the device driver but
    # does not guarantee platter persistence (only `fcntl F_FULLFSYNC` does).
    # We accept that trade-off; callers that need stronger guarantees on macOS
    # should enable `fsync = full` at the filesystem layer.
    class WAL
      # StepEntry — in-memory representation of a single step rebuilt from WAL.
      # `finalized?` gates recovery: finalized steps are not re-processed.
      StepEntry = Struct.new(
        :step_id, :plan_id, :tool, :params_hash,
        :pre_hash, :expected_post_hash,
        :idem_key, :status,
        :observed_pre_hash, :post_hash, :result_hash,
        :error_class, :error_msg,
        :recovered, :evidence,
        keyword_init: true
      ) do
        FINALIZED = %w[completed failed abandoned].freeze

        def finalized?
          FINALIZED.include?(status)
        end

        def pending?
          status.nil? || status == 'pending'
        end
      end

      # PlanRecord — one plan_commit + its step descendants + its plan_finalize.
      PlanRecord = Struct.new(
        :plan_id, :mandate_id, :cycle, :plan_hash,
        :steps, :finalized, :finalize_status, :finalize_reason,
        keyword_init: true
      )

      attr_reader :path

      # Open (or create) a WAL file. Guarantees parent-directory fsync on
      # first creation so the new inode is crash-durable [CF-6].
      def self.open(path:)
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir)
        is_new = !File.exist?(path)
        wal = new(path)
        fsync_dir(dir) if is_new
        wal
      end

      # Best-effort directory fsync. Not all platforms support it; EINVAL on
      # a few filesystems (FAT32) is fine to swallow.
      def self.fsync_dir(dir)
        d = File.open(dir)
        begin
          d.fsync
        rescue Errno::EINVAL, Errno::EACCES, NotImplementedError
          # Directory fsync not supported here; best effort.
        ensure
          d.close
        end
      end

      def initialize(path)
        @path = path
        @mutex = Mutex.new
        @file = File.open(path, 'a')
        @file.binmode
      end

      # ---------------------------------------------------------------- PLAN

      # Record an entire DECIDE-phase plan. `steps` is an Array of Hashes with
      # keys :step_id, :tool, :params_hash, :pre_hash, :expected_post_hash.
      # Additional keys are preserved (best-effort) so callers can annotate.
      def commit_plan(plan_id:, mandate_id:, cycle:, steps:)
        canonical_steps = steps.map { |s| normalize_step(s) }
        append(
          op: 'plan_commit',
          plan_id: plan_id,
          mandate_id: mandate_id,
          cycle: cycle,
          plan_hash: Canonical.sha256_json(canonical_steps),
          steps: canonical_steps
        )
      end

      def finalize_plan(plan_id, status: 'succeeded')
        append(
          op: 'plan_finalize',
          plan_id: plan_id,
          status: status
        )
      end

      def mark_plan_abandoned(plan_id, reason:)
        append(
          op: 'plan_finalize',
          plan_id: plan_id,
          status: 'abandoned',
          reason: reason
        )
      end

      # ---------------------------------------------------------------- STEP

      def append_pending(step_id:, plan_id:, idem_key:)
        append(
          op: 'append',
          step_id: step_id,
          plan_id: plan_id,
          idem_key: idem_key,
          status: 'pending'
        )
      end

      def mark_executing(step_id, pre_hash:)
        append(
          op: 'transition',
          step_id: step_id,
          status: 'executing',
          pre_hash: pre_hash
        )
      end

      def mark_completed(step_id, post_hash:, result_hash:, recovered: false, evidence: nil)
        entry = {
          op: 'transition',
          step_id: step_id,
          status: 'completed',
          post_hash: post_hash,
          result_hash: result_hash
        }
        entry[:recovered] = true if recovered
        entry[:evidence] = evidence unless evidence.nil?
        append(entry)
      end

      def mark_failed(step_id, error_class:, error_msg:)
        append(
          op: 'transition',
          step_id: step_id,
          status: 'failed',
          error_class: error_class,
          error_msg: error_msg.to_s[0, 500]
        )
      end

      def mark_needs_review(step_id, reason: nil, evidence: nil)
        entry = {
          op: 'transition',
          step_id: step_id,
          status: 'needs_review'
        }
        entry[:reason] = reason unless reason.nil?
        entry[:evidence] = evidence unless evidence.nil?
        append(entry)
      end

      def mark_reset_to_pending(step_id)
        append(
          op: 'transition',
          step_id: step_id,
          status: 'pending',
          reset: true
        )
      end

      # ---------------------------------------------------------------- READ

      # Parse the WAL file and return every PlanRecord, in order of commit.
      def plans
        parse_all
      end

      # Subset: plans lacking a plan_finalize marker. These are what recovery
      # must reconcile.
      def plans_not_finalized
        parse_all.reject { |p| p.finalized }
      end

      # ---------------------------------------------------------------- FILE

      def flush
        @mutex.synchronize do
          next if @file.nil? || @file.closed?

          @file.flush
          @file.fsync
        end
      end

      def close
        @mutex.synchronize do
          next if @file.nil? || @file.closed?

          @file.close
          @file = nil
        end
      end

      # Compress the WAL file to `dest` (defaults to "<path>.gz") and remove
      # the original. Used after a mandate completes and its plan history has
      # been archived elsewhere.
      #
      # Returns the destination path.
      def archive(to: nil)
        close
        dest = to || "#{@path}.gz"
        Zlib::GzipWriter.open(dest) do |gz|
          File.open(@path, 'rb') { |src| IO.copy_stream(src, gz) }
        end
        self.class.fsync_dir(File.dirname(dest))
        File.unlink(@path) if File.exist?(@path)
        dest
      end

      # True iff the WAL file is open.
      def open?
        !@file.nil? && !@file.closed?
      end

      private

      def append(entry)
        payload = entry.merge(ts: iso_now)
        line = "#{JSON.generate(payload)}\n"
        @mutex.synchronize do
          raise IOError, "WAL closed: #{@path}" if @file.nil? || @file.closed?

          @file.write(line)
          @file.fsync
        end
      end

      def iso_now
        Time.now.utc.iso8601(3)
      end

      # Keep only recognized step-descriptor keys so the WAL schema stays
      # tight. Unknown keys are dropped rather than silently accepted.
      def normalize_step(step)
        h = step.is_a?(Hash) ? indifferent(step) : {}
        {
          step_id: h[:step_id],
          tool: h[:tool],
          params_hash: h[:params_hash],
          pre_hash: h[:pre_hash],
          expected_post_hash: h[:expected_post_hash]
        }
      end

      def indifferent(hash)
        hash.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
      end

      # Rebuild PlanRecord list from disk. Cheap enough for recovery sizes
      # (one mandate per file, typically ≤ dozens of steps).
      def parse_all
        plans = {}
        step_index = {}

        return [] unless File.exist?(@path)

        File.foreach(@path) do |raw|
          line = raw.strip
          next if line.empty?

          entry = begin
            JSON.parse(line)
          rescue JSON::ParserError
            # Torn / half-written tail line from a crash: skip, don't abort.
            next
          end

          apply_entry!(entry, plans, step_index)
        end

        plans.values
      end

      def apply_entry!(entry, plans, step_index)
        case entry['op']
        when 'plan_commit'
          steps = (entry['steps'] || []).map do |s|
            step = StepEntry.new(
              step_id: s['step_id'],
              plan_id: entry['plan_id'],
              tool: s['tool'],
              params_hash: s['params_hash'],
              pre_hash: s['pre_hash'],
              expected_post_hash: s['expected_post_hash']
            )
            step_index[s['step_id']] = step
            step
          end
          plans[entry['plan_id']] = PlanRecord.new(
            plan_id: entry['plan_id'],
            mandate_id: entry['mandate_id'],
            cycle: entry['cycle'],
            plan_hash: entry['plan_hash'],
            steps: steps,
            finalized: false,
            finalize_status: nil,
            finalize_reason: nil
          )
        when 'append'
          step = step_index[entry['step_id']]
          if step
            step.status   = entry['status'] || step.status
            step.idem_key = entry['idem_key'] if entry['idem_key']
          else
            # R1-01 fix: orphan step — plan_commit was torn/missing.
            # Create a synthetic orphan plan so recovery can detect it.
            orphan_plan_id = entry['plan_id'] || "__orphan_#{entry['step_id']}"
            unless plans[orphan_plan_id]
              plans[orphan_plan_id] = PlanRecord.new(
                plan_id: orphan_plan_id,
                mandate_id: entry['mandate_id'] || 'unknown',
                cycle: entry['cycle'],
                plan_hash: nil,
                steps: [],
                finalized: false,
                finalize_status: nil,
                finalize_reason: 'orphan_steps_detected'
              )
            end
            step = StepEntry.new(
              step_id: entry['step_id'],
              plan_id: orphan_plan_id,
              tool: entry['tool'],
              params_hash: entry['params_hash']
            )
            step.status   = entry['status'] || 'pending'
            step.idem_key = entry['idem_key'] if entry['idem_key']
            step_index[entry['step_id']] = step
            plans[orphan_plan_id].steps << step
          end
        when 'transition'
          step = step_index[entry['step_id']]
          return unless step

          step.status             = entry['status'] if entry['status']
          step.observed_pre_hash  = entry['pre_hash']     if entry['pre_hash']
          step.post_hash          = entry['post_hash']    if entry['post_hash']
          step.result_hash        = entry['result_hash']  if entry['result_hash']
          step.error_class        = entry['error_class']  if entry['error_class']
          step.error_msg          = entry['error_msg']    if entry['error_msg']
          step.recovered          = entry['recovered']    if entry.key?('recovered')
          step.evidence           = entry['evidence']     if entry['evidence']
        when 'plan_finalize'
          pr = plans[entry['plan_id']]
          return unless pr

          pr.finalized       = true
          pr.finalize_status = entry['status']
          pr.finalize_reason = entry['reason']
        end
      end
    end
  end
end
