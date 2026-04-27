# frozen_string_literal: true
#
# PR1 tests for v0.3.0 Phase 11.5 parallelization foundation:
#   - PendingState directory-based layout
#   - MainState ordering invariant
#   - cleanup_expired! walks both layouts

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'time'
require_relative '../lib/multi_llm_review/pending_state'
require_relative '../lib/multi_llm_review/main_state'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      class TestPendingStateV3 < Minitest::Test
        def setup
          @tmp = Dir.mktmpdir('mlr_pr1')
          @prev_pwd = Dir.pwd
          Dir.chdir(@tmp)
          @token = PendingState.generate_token
        end

        def teardown
          Dir.chdir(@prev_pwd)
          FileUtils.rm_rf(@tmp)
        end

        # ── Paths ──────────────────────────────────────────────────────

        def test_token_dir_uses_dir_pwd
          # token_dir uses Dir.pwd, which on macOS may resolve /var → /private/var
          # before the tmp dir is realpath'd. Compare against Dir.pwd-based expected.
          expected = File.join(Dir.pwd, '.kairos', 'multi_llm_review', 'pending', @token)
          assert_equal expected, PendingState.token_dir(@token)
        end

        def test_all_path_helpers_are_inside_token_dir
          dir = PendingState.token_dir(@token)
          %i[state_path collected_path gc_eligible_path request_path
             subprocess_results_path worker_pid_path worker_heartbeat_path
             worker_tick_path worker_log_path collect_lock_path].each do |m|
            path = PendingState.public_send(m, @token)
            assert path.start_with?(dir), "#{m} should live inside token_dir"
          end
        end

        def test_invalid_token_raises_on_token_dir
          assert_raises(ArgumentError) { PendingState.token_dir('not-a-uuid') }
        end

        # ── create_token_dir! ──────────────────────────────────────────

        def test_create_token_dir_idempotent_root_mkdir_p
          PendingState.create_token_dir!(@token)
          assert Dir.exist?(PendingState.token_dir(@token))
        end

        def test_create_token_dir_raises_eexist_on_collision
          PendingState.create_token_dir!(@token)
          assert_raises(Errno::EEXIST) { PendingState.create_token_dir!(@token) }
        end

        # ── Atomic writers + loaders ───────────────────────────────────

        def test_write_state_and_load_state_roundtrip
          PendingState.create_token_dir!(@token)
          data = { 'schema_version' => 4, 'token' => @token, 'subprocess_status' => 'pending' }
          PendingState.write_state(@token, data)
          loaded = PendingState.load_state(@token)
          assert_equal 'pending', loaded['subprocess_status']
          assert_equal 4, loaded['schema_version']
        end

        def test_write_collected_and_load_collected
          PendingState.create_token_dir!(@token)
          payload = { 'verdict' => 'APPROVE' }
          PendingState.write_collected(@token, { 'collected_at' => Time.now.iso8601, 'final_payload' => payload })
          assert_equal 'APPROVE', PendingState.load_collected(@token)['final_payload']['verdict']
        end

        def test_write_worker_pid_fields_preserved
          PendingState.create_token_dir!(@token)
          PendingState.write_worker_pid(@token, {
            'pid' => 42, 'pgid' => 7, 'spawned_at' => Time.now.iso8601, 'ruby_version' => '3.3.7'
          })
          pid_info = PendingState.load_worker_pid(@token)
          assert_equal 42, pid_info['pid']
          assert_equal 7, pid_info['pgid']
          assert_equal '3.3.7', pid_info['ruby_version']
        end

        def test_atomic_write_leaves_no_tmp_file_on_success
          PendingState.create_token_dir!(@token)
          PendingState.write_state(@token, { 'a' => 1 })
          tmps = Dir.glob(File.join(PendingState.token_dir(@token), '*.tmp.*'))
          assert_empty tmps, "no .tmp.* should remain after atomic write"
        end

        def test_load_state_returns_nil_when_missing
          assert_nil PendingState.load_state(@token)
        end

        def test_load_json_transient_returns_nil_on_parse_error
          PendingState.create_token_dir!(@token)
          File.write(PendingState.state_path(@token), 'not valid json {{{')
          assert_nil PendingState.load_state(@token)
        end

        # ── Legacy back-compat (v0.2.x single-file) ────────────────────

        def test_load_state_falls_back_to_legacy_single_file
          FileUtils.mkdir_p(PendingState.root_dir)
          legacy_path = File.join(PendingState.root_dir, "#{@token}.json")
          File.write(legacy_path, JSON.generate({
            'token' => @token,
            'collect_deadline' => (Time.now + 600).iso8601,
            'subprocess_results' => [{ 'role_label' => 'x' }]
          }))
          loaded = PendingState.load_state(@token)
          refute_nil loaded
          # Missing 'parallel' key should default to false (legacy = synchronous).
          assert_equal false, loaded['parallel']
        end

        def test_legacy_load_still_reads_existing_api
          FileUtils.mkdir_p(PendingState.root_dir)
          PendingState.write(@token, { 'k' => 'v' })
          assert_equal 'v', PendingState.load(@token)['k']
        end

        # ── update_state RMW ──────────────────────────────────────────

        def test_update_state_yields_and_persists
          PendingState.create_token_dir!(@token)
          PendingState.write_state(@token, { 'subprocess_status' => 'pending' })
          PendingState.update_state(@token) do |s|
            s['subprocess_status'] = 'done'
            s
          end
          assert_equal 'done', PendingState.load_state(@token)['subprocess_status']
        end

        def test_update_state_returns_nil_when_state_missing
          assert_nil PendingState.update_state(@token) { |s| s }
        end

        # ── cleanup_expired! — directory layout ────────────────────────

        def test_cleanup_keeps_dir_with_fresh_heartbeat
          PendingState.create_token_dir!(@token)
          PendingState.write_state(@token, {
            'collect_deadline' => (Time.now - 60).iso8601   # already past
          })
          FileUtils.touch(PendingState.worker_heartbeat_path(@token))

          result = PendingState.cleanup_expired!(heartbeat_stale_threshold_seconds: 15)
          assert_equal 0, result[:removed]
          assert Dir.exist?(PendingState.token_dir(@token)), 'dir should survive with fresh heartbeat'
        end

        def test_cleanup_removes_dir_with_stale_heartbeat_past_deadline
          PendingState.create_token_dir!(@token)
          PendingState.write_state(@token, {
            'collect_deadline' => (Time.now - 60).iso8601
          })
          heartbeat = PendingState.worker_heartbeat_path(@token)
          FileUtils.touch(heartbeat)
          # Force mtime into the past.
          old = Time.now - 30
          File.utime(old, old, heartbeat)

          result = PendingState.cleanup_expired!(heartbeat_stale_threshold_seconds: 15)
          assert_equal 1, result[:removed]
          refute Dir.exist?(PendingState.token_dir(@token))
        end

        def test_cleanup_respects_gc_eligible_even_with_fresh_heartbeat
          PendingState.create_token_dir!(@token)
          PendingState.write_state(@token, {
            'collect_deadline' => (Time.now - 60).iso8601
          })
          FileUtils.touch(PendingState.worker_heartbeat_path(@token))
          File.open(PendingState.gc_eligible_path(@token), 'w') { }

          result = PendingState.cleanup_expired!
          assert_equal 1, result[:removed]
        end

        def test_cleanup_reaps_self_timed_out_status
          PendingState.create_token_dir!(@token)
          PendingState.write_state(@token, {
            'collect_deadline' => (Time.now - 60).iso8601,
            'subprocess_status' => 'self_timed_out'
          })
          # heartbeat fresh — should STILL be reaped
          FileUtils.touch(PendingState.worker_heartbeat_path(@token))

          result = PendingState.cleanup_expired!
          assert_equal 1, result[:removed]
        end

        def test_cleanup_pins_dir_by_collected_json
          PendingState.create_token_dir!(@token)
          PendingState.write_state(@token, {
            'collect_deadline' => (Time.now - 7200).iso8601
          })
          PendingState.write_collected(@token, {
            'collected_at' => (Time.now - 10).iso8601, 'final_payload' => {}
          })

          result = PendingState.cleanup_expired!(retain_collected_seconds: 3600)
          assert_equal 0, result[:removed], 'recently collected dir should be pinned'
          assert Dir.exist?(PendingState.token_dir(@token))
        end

        def test_cleanup_removes_collected_dir_past_retain_window
          PendingState.create_token_dir!(@token)
          PendingState.write_state(@token, {
            'collect_deadline' => (Time.now - 7200).iso8601
          })
          PendingState.write_collected(@token, {
            'collected_at' => (Time.now - 7200).iso8601, 'final_payload' => {}
          })

          result = PendingState.cleanup_expired!(retain_collected_seconds: 3600)
          assert_equal 1, result[:removed]
        end

        def test_cleanup_skip_token
          PendingState.create_token_dir!(@token)
          PendingState.write_state(@token, { 'collect_deadline' => (Time.now - 60).iso8601 })
          FileUtils.touch(PendingState.worker_heartbeat_path(@token))
          File.utime(Time.now - 30, Time.now - 30, PendingState.worker_heartbeat_path(@token))

          result = PendingState.cleanup_expired!(skip_token: @token, heartbeat_stale_threshold_seconds: 15)
          assert_equal 0, result[:removed]
          assert Dir.exist?(PendingState.token_dir(@token))
        end

        def test_cleanup_legacy_single_file_respected
          FileUtils.mkdir_p(PendingState.root_dir)
          legacy = File.join(PendingState.root_dir, "#{@token}.json")
          File.write(legacy, JSON.generate({
            'collect_deadline' => (Time.now - 60).iso8601
          }))

          result = PendingState.cleanup_expired!
          assert_equal 1, result[:removed]
          refute File.exist?(legacy)
        end

        def test_cleanup_removes_orphan_tmp_files
          PendingState.create_token_dir!(@token)
          tmp = File.join(PendingState.token_dir(@token), 'state.json.tmp.99999.abcd')
          File.write(tmp, '...')
          File.utime(Time.now - 7200, Time.now - 7200, tmp)

          PendingState.cleanup_expired!
          refute File.exist?(tmp)
        end

        # ── Security / path traversal ─────────────────────────────────

        def test_load_state_rejects_invalid_token_without_file_access
          # Must NOT escape root_dir via a crafted token.
          assert_nil PendingState.load_state('../etc/passwd')
          assert_nil PendingState.load_state('')
          assert_nil PendingState.load_state(nil) rescue nil
        end

        # ── dir_reapable malformed state.json ─────────────────────────

        def test_dir_reapable_falls_back_to_mtime_when_deadline_unparseable
          PendingState.create_token_dir!(@token)
          # state.json exists but collect_deadline is garbage
          PendingState.write_state(@token, { 'subprocess_status' => 'pending' })
          # Age the dir past stale_no_deadline_seconds
          old = Time.now - 90_000
          File.utime(old, old, PendingState.token_dir(@token))

          result = PendingState.cleanup_expired!(stale_no_deadline_seconds: 86_400)
          assert_equal 1, result[:removed], 'malformed deadline should not pin dir forever'
        end

        # ── Concurrent write race ─────────────────────────────────────

        def test_concurrent_write_state_no_torn_json_no_leftover_tmp
          PendingState.create_token_dir!(@token)
          threads = 4.times.map do |i|
            Thread.new do
              10.times { |n| PendingState.write_state(@token, { 'i' => i, 'n' => n }) }
            end
          end
          threads.each { |t| t.join(5) }
          # Final file must parse cleanly.
          data = PendingState.load_state(@token)
          refute_nil data, 'final state.json must be parseable after concurrent writes'
          assert_kind_of Integer, data['i']
          # No .tmp.* should remain.
          tmps = Dir.glob(File.join(PendingState.token_dir(@token), '*.tmp.*'))
          assert_empty tmps
        end

        # ── update_state mutex ────────────────────────────────────────

        def test_update_state_serializes_concurrent_callers
          PendingState.create_token_dir!(@token)
          PendingState.write_state(@token, { 'counter' => 0 })
          threads = 4.times.map do
            Thread.new do
              10.times do
                PendingState.update_state(@token) do |s|
                  s['counter'] = (s['counter'] || 0) + 1
                  s
                end
              end
            end
          end
          threads.each { |t| t.join(10) }
          final = PendingState.load_state(@token)
          # With mutex serialization: every increment lands. 4×10=40 total.
          assert_equal 40, final['counter'],
            'STATE_MUTEX should prevent lost updates across threads'
        end
      end

      # ── MainState (v3.24.3 per-thread invariants) ───────────────────
      # Replaces v0.3.2 C3b ordering tests. v3.24.3 uses Mutex-bracketed
      # per-thread ts_by_thread Hash; the prior "counter-before-ts" ordering
      # invariant no longer applies (Mutex provides atomicity). Tests now
      # cover: snapshot 3-tuple shape, with_call ensure semantics, private
      # enter_call!/exit_call!, and bump_counter! semantics. Comprehensive
      # parallel-thread coverage is in test_main_state.rb.

      class TestMainState < Minitest::Test
        def setup
          MainState.reset!
        end

        def test_initial_snapshot_is_idle
          counter, in_flight, oldest_ts = MainState.snapshot
          assert_equal 0, counter
          assert_equal 0, in_flight
          assert_nil oldest_ts
        end

        def test_with_call_brackets_counter_and_ts
          before, in_flight_before, ts_before = MainState.snapshot
          assert_equal 0, in_flight_before
          assert_nil ts_before

          ts_during_block = nil
          MainState.with_call do
            _c, in_flight, oldest_ts = MainState.snapshot
            ts_during_block = oldest_ts
            assert_equal 1, in_flight
            refute_nil oldest_ts
          end

          counter, in_flight, oldest_ts = MainState.snapshot
          assert_equal before + 1, counter, 'with_call must bump counter on exit'
          assert_equal 0, in_flight
          assert_nil oldest_ts, 'ts must be cleared after with_call returns'
          assert_kind_of Float, ts_during_block
        end

        def test_with_call_ensures_cleanup_on_exception
          assert_raises(RuntimeError) do
            MainState.with_call { raise 'boom' }
          end
          counter, in_flight, oldest_ts = MainState.snapshot
          assert_equal 1, counter, 'counter still bumps on exception (ensure)'
          assert_equal 0, in_flight, 'ts_by_thread must be cleaned on exception'
          assert_nil oldest_ts
        end

        def test_bump_counter_does_not_touch_ts_by_thread
          before_counter, before_in_flight, _ = MainState.snapshot
          MainState.bump_counter!
          counter, in_flight, oldest_ts = MainState.snapshot
          assert_equal before_counter + 1, counter
          assert_equal before_in_flight, in_flight, 'bump_counter! must not touch ts_by_thread'
          assert_nil oldest_ts
        end

        def test_enter_call_is_private
          assert_raises(NoMethodError) { MainState.enter_call! }
        end

        def test_exit_call_is_private
          assert_raises(NoMethodError) { MainState.exit_call! }
        end

        def test_reset_clears_all_state
          MainState.with_call { } # bumps counter to 1
          MainState.reset!
          counter, in_flight, oldest_ts = MainState.snapshot
          assert_equal 0, counter
          assert_equal 0, in_flight
          assert_nil oldest_ts
        end
      end
    end
  end
end
