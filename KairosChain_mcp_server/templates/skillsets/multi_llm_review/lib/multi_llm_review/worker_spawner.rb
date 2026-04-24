# frozen_string_literal: true

require 'fileutils'
require 'rbconfig'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Spawns the detached OS worker process that runs subprocess reviewers
      # in parallel with orchestrator persona Agents (v0.3 Phase 11.5).
      #
      # Uses Process.spawn(pgroup: true, close_others: true) + Process.detach
      # to produce a process that:
      #   - survives MCP server restart (F10/F11)
      #   - does not leak MCP stdio FDs (R1 F-J)
      #   - is reapable by WorkerReaper via -pgid (F-PGID)
      #
      # The worker itself calls Process.setsid on first line (v0.3.2 §2.1)
      # to guarantee session-leader status on both Linux and macOS.
      module WorkerSpawner
        WORKER_SCRIPT = File.expand_path('../../bin/dispatch_worker.rb', __dir__)

        module_function

        def script_path
          WORKER_SCRIPT
        end

        # @param token [String]
        # @param dir [String] token directory (already created by Phase 1)
        # @return [Integer] spawned PID
        def spawn(token:, dir:)
          raise ArgumentError, "missing worker dir: #{dir}" unless Dir.exist?(dir)
          raise ArgumentError, "worker script not found: #{WORKER_SCRIPT}" \
            unless File.exist?(WORKER_SCRIPT)

          log_path = File.join(dir, 'worker.log')
          File.write(log_path, '')   # truncate-on-spawn

          env = {
            'KAIROS_PROJECT_ROOT' => Dir.pwd,
            'BUNDLE_GEMFILE' => ENV['BUNDLE_GEMFILE']
          }.compact

          # NOTE: we do NOT pass `pgroup: true` here. The worker itself calls
          # Process.setsid as its first operation (see bin/dispatch_worker.rb).
          # setsid fails with EPERM if the caller is already a process group
          # leader — which it would be if pgroup:true had made it one. By
          # leaving pgroup unset, the worker inherits our pgid long enough
          # for setsid to succeed and create a new session+pgroup.
          # (R1-impl P0 from codex 5.5.)
          pid = Process.spawn(
            env,
            RbConfig.ruby, WORKER_SCRIPT, token,
            chdir: Dir.pwd,
            out: [log_path, 'a'],
            err: [log_path, 'a'],
            in: :close,
            close_others: true
          )
          Process.detach(pid)
          pid
        end
      end
    end
  end
end
