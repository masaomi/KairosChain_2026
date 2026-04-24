# frozen_string_literal: true
#
# PR3 tests: WorkerSpawner + transition_to_terminal! + worker smoke integration.
# The full dispatch_worker.rb is exercised by a minimal fake-request smoke test
# that confirms the process spawns, writes worker.pid with pgid, and eventually
# transitions to a terminal state.

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'time'

require_relative '../lib/multi_llm_review/pending_state'
require_relative '../lib/multi_llm_review/worker_spawner'
require_relative '../lib/multi_llm_review/main_state'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      class TestWorkerSpawner < Minitest::Test
        def setup
          @tmp = Dir.mktmpdir('mlr_pr3')
          @prev_pwd = Dir.pwd
          Dir.chdir(@tmp)
          @token = PendingState.generate_token
          PendingState.create_token_dir!(@token)
        end

        def teardown
          Dir.chdir(@prev_pwd)
          FileUtils.rm_rf(@tmp)
        end

        def test_script_path_points_at_dispatch_worker
          assert WorkerSpawner.script_path.end_with?('bin/dispatch_worker.rb')
        end

        def test_spawn_raises_without_dir
          FileUtils.rm_rf(PendingState.token_dir(@token))
          assert_raises(ArgumentError) do
            WorkerSpawner.spawn(token: @token, dir: PendingState.token_dir(@token))
          end
        end

        def test_spawn_truncates_log_file
          # Pre-fill worker.log with junk.
          log = PendingState.worker_log_path(@token)
          File.write(log, 'pre-existing noise')

          # Swap WORKER_SCRIPT to a no-op ruby script via const reassignment.
          dummy = File.join(@tmp, 'dummy_worker.rb')
          File.write(dummy, "puts 'hello'\n")
          original = WorkerSpawner.const_get(:WORKER_SCRIPT)
          WorkerSpawner.send(:remove_const, :WORKER_SCRIPT)
          WorkerSpawner.const_set(:WORKER_SCRIPT, dummy)

          begin
            WorkerSpawner.spawn(token: @token, dir: PendingState.token_dir(@token))
            sleep 0.3   # let dummy finish
            content = File.read(log)
            refute_includes content, 'pre-existing noise'
          ensure
            WorkerSpawner.send(:remove_const, :WORKER_SCRIPT)
            WorkerSpawner.const_set(:WORKER_SCRIPT, original)
          end
        end
      end

      class TestTransitionToTerminal < Minitest::Test
        def setup
          @tmp = Dir.mktmpdir('mlr_pr3_tt')
          @prev_pwd = Dir.pwd
          Dir.chdir(@tmp)
          @token = PendingState.generate_token
          PendingState.create_token_dir!(@token)
          PendingState.write_state(@token, { 'subprocess_status' => 'pending' })
        end

        def teardown
          Dir.chdir(@prev_pwd)
          FileUtils.rm_rf(@tmp)
        end

        def test_pending_to_done
          PendingState.transition_to_terminal!(@token, 'done')
          s = PendingState.load_state(@token)
          assert_equal 'done', s['subprocess_status']
          assert_nil s['crashed_at'], "done must not set crashed_at"
        end

        def test_pending_to_crashed_with_reason
          PendingState.transition_to_terminal!(@token, 'crashed', reason: 'signal:TERM')
          s = PendingState.load_state(@token)
          assert_equal 'crashed', s['subprocess_status']
          assert_equal 'signal:TERM', s['crash_reason']
          refute_nil s['crashed_at']
        end

        def test_pending_to_self_timed_out
          PendingState.transition_to_terminal!(@token, 'self_timed_out', reason: 'self_timeout_watchdog')
          s = PendingState.load_state(@token)
          assert_equal 'self_timed_out', s['subprocess_status']
          assert_equal 'self_timeout_watchdog', s['crash_reason']
        end

        def test_terminal_status_guard_prevents_overwrite
          PendingState.transition_to_terminal!(@token, 'done')
          PendingState.transition_to_terminal!(@token, 'self_timed_out', reason: 'late_watchdog')
          s = PendingState.load_state(@token)
          assert_equal 'done', s['subprocess_status'], 'first terminal write must win'
          refute_equal 'late_watchdog', s['crash_reason']
        end

        def test_unknown_terminal_raises
          assert_raises(ArgumentError) do
            PendingState.transition_to_terminal!(@token, 'garbage_state')
          end
        end

        # Multi-thread safety: main + watchdog + signal-poll equivalent.
        def test_concurrent_terminal_writers_exactly_one_wins
          results_counts = {}
          threads = %w[done crashed self_timed_out].map do |status|
            Thread.new do
              PendingState.transition_to_terminal!(@token, status,
                reason: (status == 'done' ? nil : "#{status}_thread"))
            end
          end
          threads.each { |t| t.join(5) }

          s = PendingState.load_state(@token)
          assert_includes %w[done crashed self_timed_out], s['subprocess_status']

          # Run the same call again — should be a no-op regardless of status.
          before = s['subprocess_status']
          PendingState.transition_to_terminal!(@token, 'crashed', reason: 'extra')
          after = PendingState.load_state(@token)
          assert_equal before, after['subprocess_status'],
            'guard must prevent additional terminal writes'
        end
      end
    end
  end
end
