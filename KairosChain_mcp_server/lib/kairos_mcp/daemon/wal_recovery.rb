# frozen_string_literal: true

require 'fileutils'

require_relative 'wal'

module KairosMcp
  class Daemon
    # WalRecovery — boot-time reconciliation of a WAL directory.
    #
    # Design (v0.2 P3.0):
    #   On daemon startup, each `<mandate_id>.wal.jsonl` in `wal_dir` may
    #   contain steps that were marked `executing` but never transitioned
    #   to `completed` / `failed` because the process crashed mid-phase.
    #   Recovery resets those steps back to `pending` so the cycle
    #   runner's idempotency check can re-execute them safely.
    #
    # What recovery does NOT do:
    #   * It does not replay steps itself — that's the cycle runner's job.
    #   * It does not delete WAL files. Finalized plans are archived
    #     elsewhere (WAL#archive).
    #   * It does not touch steps whose plan is already finalized.
    #
    # Return value:
    #   Integer — total number of steps reset to pending across all files.
    #   Useful both for tests and for the daemon's boot log line.
    module WalRecovery
      WAL_GLOB = '*.wal.jsonl'

      module_function

      # Reset every `executing` step in `wal_dir` back to `pending`.
      # Returns the total reset count. A missing or empty directory
      # returns 0 without raising — recovery on a clean boot is a no-op.
      def recover_from_wal!(wal_dir, logger = nil)
        return 0 if wal_dir.nil? || wal_dir.to_s.empty?
        return 0 unless Dir.exist?(wal_dir)

        total = 0
        Dir.glob(File.join(wal_dir, WAL_GLOB)).sort.each do |path|
          total += recover_file!(path, logger)
        end

        logger&.info('wal_recovery_complete',
                     source: 'wal_recovery',
                     details: { wal_dir: wal_dir, reset_count: total })
        total
      end

      # Recover a single WAL file. Isolated so one corrupt file can't
      # block recovery of the rest of the directory.
      def recover_file!(path, logger = nil)
        wal = KairosMcp::Daemon::WAL.open(path: path)
        count = 0
        begin
          wal.plans_not_finalized.each do |plan|
            plan.steps.each do |step|
              next unless step.status == 'executing'

              wal.mark_reset_to_pending(step.step_id)
              count += 1
              logger&.info('wal_recovery_reset_step',
                           source: 'wal_recovery',
                           details: {
                             path:     path,
                             plan_id:  plan.plan_id,
                             step_id:  step.step_id
                           })
            end
          end
        ensure
          wal.close
        end
        count
      rescue StandardError => e
        logger&.error('wal_recovery_file_failed',
                      source: 'wal_recovery',
                      details: {
                        path:  path,
                        error: "#{e.class}: #{e.message}"
                      })
        0
      end
    end
  end
end
