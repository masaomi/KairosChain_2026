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
      # Files (in the session dir):
      #   delegation.json       — the handle: token, recorded call arguments,
      #                           anchor at issue, spawn metadata
      #   delegation.heartbeat  — touched by the live worker every 2s
      #   delegation_result.json— the worker's final response (same JSON the
      #                           inline call would have returned)
      class StepDelegation
        PENDING_FILE   = 'delegation.json'
        HEARTBEAT_FILE = 'delegation.heartbeat'
        RESULT_FILE    = 'delegation_result.json'
        LOG_FILE       = 'delegation_worker.log'

        HEARTBEAT_INTERVAL_SECONDS      = 2
        HEARTBEAT_STALE_THRESHOLD_SECONDS = 15
        STARTUP_GRACE_SECONDS           = 30

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

        # Opens the handle for one delegated step. Idempotent at the
        # delegation-start level (INV-A3): a live pending delegation for the
        # same action+anchor returns the existing token instead of spawning a
        # second worker; a crashed one is replaced. A leftover result from a
        # previous delegation is cleared when a new handle opens.
        #
        # Returns [token, 'opened'|'existing'].
        def open_handle(arguments, anchor)
          current = pending
          if current && %w[still_pending].include?(status) &&
             current['arguments'] == arguments && current['anchor'] == anchor
            return [current['step_token'], 'existing']
          end

          FileUtils.rm_f(result_path)
          FileUtils.rm_f(heartbeat_path)
          token = SecureRandom.uuid
          atomic_write(pending_path, JSON.pretty_generate(
            'step_token' => token,
            'arguments'  => arguments,
            'anchor'     => anchor,
            'spawned_at' => Time.now.utc.iso8601
          ))
          [token, 'opened']
        end

        # 'ready' | 'still_pending' | 'crashed' | 'none'
        def status
          return 'ready' if File.exist?(result_path)

          current = pending
          return 'none' unless current

          if File.exist?(heartbeat_path)
            age = Time.now - File.mtime(heartbeat_path)
            return age <= HEARTBEAT_STALE_THRESHOLD_SECONDS ? 'still_pending' : 'crashed'
          end

          spawned = begin
            Time.parse(current['spawned_at'])
          rescue StandardError
            nil
          end
          return 'crashed' unless spawned

          (Time.now - spawned) <= STARTUP_GRACE_SECONDS ? 'still_pending' : 'crashed'
        end

        # ---- worker side ----

        def touch_heartbeat
          FileUtils.touch(heartbeat_path)
        end

        def write_result(response_hash)
          atomic_write(result_path, JSON.pretty_generate(response_hash))
        end

        def clear_pending
          FileUtils.rm_f(pending_path)
          FileUtils.rm_f(heartbeat_path)
        end

        # ---- spawn ----

        # Spawns the detached worker (same discipline as the review
        # SkillSet's WorkerSpawner: no pgroup here — the worker calls setsid
        # itself; stdio to a rotating-enough log; MCP FDs closed).
        # KAIROS_AGENT_WORKER_CMD overrides the command line for tests.
        def spawn_worker(session_id)
          log = File.join(@dir, LOG_FILE)
          File.write(log, '')

          env = {
            'KAIROS_PROJECT_ROOT' => Dir.pwd,
            'KAIROS_SERVER_LIB'   => server_lib_dir,
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
        end

        private

        # The lib dir the running server loaded kairos_mcp from, so the
        # worker bootstraps against the same code regardless of install shape
        # (repo checkout vs gem).
        def server_lib_dir
          feature = $LOADED_FEATURES.grep(%r{kairos_mcp/tool_registry\.rb\z}).first ||
                    $LOADED_FEATURES.grep(%r{kairos_mcp/tools/base_tool\.rb\z}).first
          return File.expand_path('../..', feature) if feature

          File.expand_path('../../../../../lib', __dir__)
        end

        def atomic_write(path, content)
          tmp = "#{path}.tmp.#{Process.pid}.#{Thread.current.object_id}"
          File.write(tmp, content)
          File.rename(tmp, path)
        end

        def pending_path   = File.join(@dir, PENDING_FILE)
        def heartbeat_path = File.join(@dir, HEARTBEAT_FILE)
        def result_path    = File.join(@dir, RESULT_FILE)
      end
    end
  end
end
