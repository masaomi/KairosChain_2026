# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'
require 'rbconfig'
require 'time'

module KairosMcp
  module SkillSets
    module Agent
      # Interruption resilience Slice A-2 (design v0.3.1 FROZEN, INV-A1).
      #
      # StepDelegation carries the resumable handle for a step whose execution
      # continues under server-side ownership after the initiating call
      # returns. The delegated worker is a thin bootstrap that re-enters the
      # SAME gated agent_step path (AdvanceGate, Slice A-1), so every
      # correctness invariant — serialization, anchored at-most-once, intent
      # bracket — is inherited rather than re-implemented. This is the
      # delegate → wait → collect shape the review SkillSet already runs in
      # production, transplanted.
      #
      # Concurrency (impl review R1): delegation-start sits OUTSIDE the
      # AdvanceGate advance.lock, so it takes its OWN per-session lock
      # (delegation.lock) to serialize open/status-mutating operations. Two
      # locks never nest in the same thread — the tool holds delegation.lock
      # only to open the handle and returns; the detached worker separately
      # takes advance.lock inside its gated call. The recorded issue-anchor is
      # injected into the worker's call args so a re-entry is ALWAYS anchored:
      # even if two workers somehow coexist, the second replays the first's
      # committed outcome instead of double-executing.
      #
      # Files (in the session dir):
      #   delegation.lock       — flock serializing delegation-start
      #   delegation.json       — the handle: token, worker call args (anchor
      #                           injected), issue_anchor, spawn metadata
      #   delegation.heartbeat  — touched by the live worker every 2s
      #   delegation_result.json— the worker's final response, tagged with the
      #                           issue_anchor it belongs to
      class StepDelegation
        LOCK_FILE      = 'delegation.lock'
        PENDING_FILE   = 'delegation.json'
        HEARTBEAT_FILE = 'delegation.heartbeat'
        RESULT_FILE    = 'delegation_result.json'
        LOG_FILE       = 'delegation_worker.log'

        HEARTBEAT_INTERVAL_SECONDS        = 2
        HEARTBEAT_STALE_THRESHOLD_SECONDS = 15
        STARTUP_GRACE_SECONDS             = 30
        # Wall-clock ceiling for a delegated step; past it the worker exits so
        # a hung gated call cannot hold the advance lock forever (a dead
        # process releases its flock). Generous: real steps are LLM-bound.
        WORKER_SELF_TIMEOUT_SECONDS       = 1500

        WORKER_SCRIPT = File.expand_path('../../bin/agent_step_worker.rb', __dir__)

        def initialize(session_dir)
          @dir = session_dir
          FileUtils.mkdir_p(@dir)
        end

        def pending
          JSON.parse(File.read(pending_path))
        rescue Errno::ENOENT, JSON::ParserError
          nil
        end

        def result
          JSON.parse(File.read(result_path))
        rescue Errno::ENOENT, JSON::ParserError
          nil
        end

        # 'ready' | 'still_pending' | 'crashed' | 'none'
        # 'ready' requires the result to belong to the CURRENT pending handle
        # (matching issue_anchor) OR the handle to be already cleared — a stale
        # result from a prior step whose handle has been replaced never masks a
        # fresh delegation.
        def status
          res = result
          cur = pending
          if res
            return 'ready' if cur.nil? || res['issue_anchor'] == cur['issue_anchor']
          end
          return 'none' unless cur

          if File.exist?(heartbeat_path)
            age = Time.now - File.mtime(heartbeat_path)
            return age <= HEARTBEAT_STALE_THRESHOLD_SECONDS ? 'still_pending' : 'crashed'
          end

          spawned = begin
            Time.parse(cur['spawned_at'])
          rescue StandardError
            nil
          end
          return 'crashed' unless spawned

          (Time.now - spawned) <= STARTUP_GRACE_SECONDS ? 'still_pending' : 'crashed'
        end

        # Opens (or re-joins) the handle for one delegated step, serialized
        # under delegation.lock. issue_anchor is the AdvanceGate current_anchor
        # at delegation time; it is BOTH recorded for dedup AND injected into
        # the worker's call args so the re-entry is anchored.
        #
        # Returns one of:
        #   [:ready, token]      — a finished, uncollected result for this
        #                          exact issue_anchor already exists
        #   [:existing, token]   — a live worker for this issue_anchor is
        #                          already running; no second spawn
        #   [:opened, token]     — a fresh handle was written; caller spawns
        def open_handle(recorded_args, issue_anchor)
          with_lock do
            res = result
            if res && res['issue_anchor'] == issue_anchor
              return [:ready, res.dig('outcome', 'step_token') || pending&.dig('step_token')]
            end

            cur = pending
            if cur && cur['issue_anchor'] == issue_anchor && live_pending?(cur)
              return [:existing, cur['step_token']]
            end

            # Fresh delegation: clear any stale result/heartbeat and write the
            # new handle. The issue_anchor is injected into the worker args.
            FileUtils.rm_f(result_path)
            FileUtils.rm_f(heartbeat_path)
            token = SecureRandom.uuid
            worker_args = recorded_args.merge('anchor' => issue_anchor)
            atomic_write(pending_path, JSON.pretty_generate(
              'step_token'   => token,
              'arguments'    => worker_args,
              'issue_anchor' => issue_anchor,
              'spawned_at'   => Time.now.utc.iso8601
            ))
            [:opened, token]
          end
        end

        # ---- worker side ----

        def touch_heartbeat
          FileUtils.touch(heartbeat_path)
        end

        # Tags the result with the issue_anchor of the handle it completes, so
        # status/open_handle can tell a fresh result from a stale one.
        def write_result(response_hash)
          issue_anchor = pending&.dig('issue_anchor')
          payload = { 'issue_anchor' => issue_anchor, 'outcome' => response_hash }
          atomic_write(result_path, JSON.pretty_generate(payload))
        end

        def clear_pending
          FileUtils.rm_f(pending_path)
          FileUtils.rm_f(heartbeat_path)
        end

        # Consume a collected result so a later delegated step is not masked by
        # it (collect-once). Under the lock to avoid racing a fresh open.
        def clear_result
          with_lock { FileUtils.rm_f(result_path) }
        end

        # ---- spawn ----

        # Spawns the detached worker (same discipline as the review SkillSet's
        # WorkerSpawner: no pgroup here — the worker calls setsid itself; MCP
        # FDs closed; the server's effective data_dir is propagated so the
        # worker resolves the SAME .kairos even under `--data-dir`).
        # On spawn failure the handle is rolled back so it does not linger as
        # a phantom still_pending. KAIROS_AGENT_WORKER_CMD overrides argv for
        # tests. Returns the pid, or raises after rolling back.
        def spawn_worker(session_id)
          log = File.join(@dir, LOG_FILE)
          File.write(log, '')

          env = {
            'KAIROS_PROJECT_ROOT' => Dir.pwd,
            'KAIROS_SERVER_LIB'   => server_lib_dir,
            'KAIROS_DATA_DIR'     => resolved_data_dir,
            'BUNDLE_GEMFILE'      => ENV['BUNDLE_GEMFILE']
          }.compact

          argv = if ENV['KAIROS_AGENT_WORKER_CMD']
                   ENV['KAIROS_AGENT_WORKER_CMD'].split(' ') + [session_id, @dir]
                 else
                   [RbConfig.ruby, WORKER_SCRIPT, session_id, @dir]
                 end

          pid = Process.spawn(env, *argv,
                              chdir: Dir.pwd,
                              in: :close, out: log, err: log,
                              close_others: true)
          Process.detach(pid)
          pid
        rescue StandardError => e
          clear_pending
          raise e
        end

        def self.worker_self_timeout_seconds
          WORKER_SELF_TIMEOUT_SECONDS
        end

        private

        # A pending handle whose worker is not (yet) declared crashed.
        def live_pending?(_cur)
          %w[still_pending].include?(status)
        end

        def with_lock
          File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |f|
            f.flock(File::LOCK_EX)
            begin
              yield
            ensure
              f.flock(File::LOCK_UN)
            end
          end
        end

        # The server's effective data dir, so the worker resolves the SAME
        # .kairos even when the server was launched with --data-dir (which sets
        # KairosMcp.data_dir programmatically without exporting an env var).
        def resolved_data_dir
          if defined?(KairosMcp) && KairosMcp.respond_to?(:data_dir)
            KairosMcp.data_dir
          else
            ENV['KAIROS_DATA_DIR']
          end
        rescue StandardError
          ENV['KAIROS_DATA_DIR']
        end

        # The lib dir the running server loaded kairos_mcp from, so the worker
        # bootstraps against the same code regardless of install shape.
        def server_lib_dir
          feature = $LOADED_FEATURES.grep(%r{/kairos_mcp/tool_registry\.rb\z}).first ||
                    $LOADED_FEATURES.grep(%r{/kairos_mcp/tools/base_tool\.rb\z}).first
          return File.expand_path('../..', feature) if feature

          # Repo/template fallback: templates/skillsets/agent/lib/agent -> up to
          # KairosChain_mcp_server/lib. Unreached in a live server (the grep
          # succeeds); harmless for the gem case where the worker's own
          # require resolves kairos_mcp from the gem load path.
          File.expand_path('../../../../../lib', __dir__)
        end

        def atomic_write(path, content)
          tmp = "#{path}.tmp.#{Process.pid}.#{Thread.current.object_id}"
          File.write(tmp, content)
          File.rename(tmp, path)
        end

        def lock_path      = File.join(@dir, LOCK_FILE)
        def pending_path   = File.join(@dir, PENDING_FILE)
        def heartbeat_path = File.join(@dir, HEARTBEAT_FILE)
        def result_path    = File.join(@dir, RESULT_FILE)
      end
    end
  end
end
