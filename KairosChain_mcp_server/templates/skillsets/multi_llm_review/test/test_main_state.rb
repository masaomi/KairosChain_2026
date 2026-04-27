# frozen_string_literal: true

# v3.24.3: per-thread MainState concurrency tests. Covers the per-thread
# Hash invariants that fix the v0.3.2 single-ts process-global race
# (incident token 5b75ff8c-..., 2026-04-27).

require 'minitest/autorun'
require_relative '../lib/multi_llm_review/main_state'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      class TestMainStateConcurrency < Minitest::Test
        def setup
          MainState.reset!
        end

        # T1 enter, T2 enter, T1 exit. Verify oldest_ts becomes T2's ts
        # (not stuck at T1's). This is the exact scenario that v0.3.2 broke
        # under: T1.exit cleared the single global ts while T2 was still
        # in-call.
        def test_oldest_ts_advances_when_first_enter_exits
          enter_order = Queue.new
          can_exit_t1 = Queue.new
          can_exit_t2 = Queue.new

          t1_ts = nil
          t2_ts = nil

          t1 = Thread.new do
            MainState.with_call do
              # capture our ts via snapshot
              _, _, oldest_ts = MainState.snapshot
              t1_ts = oldest_ts
              enter_order << :t1
              can_exit_t1.pop  # wait for main to release
            end
          end

          # Wait for t1 to enter
          assert_equal :t1, enter_order.pop

          t2 = Thread.new do
            MainState.with_call do
              enter_order << :t2
              can_exit_t2.pop
            end
          end

          # Wait for t2 to enter
          assert_equal :t2, enter_order.pop

          # Both in flight. Capture snapshot.
          _, in_flight, oldest_ts_both = MainState.snapshot
          assert_equal 2, in_flight
          assert_equal t1_ts, oldest_ts_both, 'oldest_ts is T1 (earliest enter)'

          # Now grab T2's ts before T1 exits
          # Since T2 entered after T1, T2's ts > T1's ts.
          # After T1 exits, oldest_ts must become T2's ts.

          can_exit_t1 << :go
          t1.join

          _, in_flight_after, oldest_ts_after = MainState.snapshot
          assert_equal 1, in_flight_after, 'T2 still in-flight'
          refute_nil oldest_ts_after
          assert oldest_ts_after > t1_ts,
            "oldest_ts must advance past T1's anchor after T1 exits " \
            "(was #{t1_ts}, now #{oldest_ts_after})"

          can_exit_t2 << :go
          t2.join

          # Both exited
          counter, in_flight_final, oldest_ts_final = MainState.snapshot
          assert_equal 2, counter
          assert_equal 0, in_flight_final
          assert_nil oldest_ts_final
        end

        # 4 threads cycling enter/exit 250 times each = 1000 total cycles.
        # Verifies counter and ts_by_thread stay consistent under contention.
        def test_concurrent_with_call_stress
          srand(20260427)  # deterministic seed
          n_threads = 4
          cycles_per_thread = 250
          start_at = Time.now

          threads = n_threads.times.map do
            Thread.new do
              cycles_per_thread.times do
                MainState.with_call { }
              end
            end
          end
          threads.each(&:join)

          elapsed = Time.now - start_at
          assert elapsed < 10, "stress test took #{elapsed.round(2)}s, budget 10s"

          counter, in_flight, oldest_ts = MainState.snapshot
          assert_equal n_threads * cycles_per_thread, counter
          assert_equal 0, in_flight, 'ts_by_thread leaked entries'
          assert_nil oldest_ts
        end

        # If with_call raises mid-block across many threads, ts_by_thread
        # must still be cleaned for every thread.
        def test_concurrent_with_call_exception_cleanup
          n_threads = 4
          threads = n_threads.times.map do |i|
            Thread.new do
              begin
                MainState.with_call { raise "boom from thread #{i}" }
              rescue StandardError
                # expected
              end
            end
          end
          threads.each(&:join)

          counter, in_flight, oldest_ts = MainState.snapshot
          assert_equal n_threads, counter, 'counter bumps even on exception'
          assert_equal 0, in_flight, 'ts_by_thread must be cleaned on exception'
          assert_nil oldest_ts
        end

        # bump_counter! is racy with concurrent with_call but must not
        # corrupt ts_by_thread or under-count counter.
        def test_bump_counter_concurrent_with_with_call
          n_threads = 4
          n_bumps = 100
          n_cycles = 100

          bump_threads = n_threads.times.map do
            Thread.new { n_bumps.times { MainState.bump_counter! } }
          end
          call_threads = n_threads.times.map do
            Thread.new { n_cycles.times { MainState.with_call { } } }
          end
          (bump_threads + call_threads).each(&:join)

          counter, in_flight, oldest_ts = MainState.snapshot
          assert_equal n_threads * (n_bumps + n_cycles), counter
          assert_equal 0, in_flight
          assert_nil oldest_ts
        end
      end
    end
  end
end
