# frozen_string_literal: true

# v3.24.3: pure unit tests for MainState.compute_alive — table-driven
# coverage of all 4 branches plus threshold boundaries. No worker fork,
# no thread, no filesystem.

require 'minitest/autorun'
require_relative '../lib/multi_llm_review/main_state'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      class TestMainStateAlive < Minitest::Test
        THRESHOLD = 360.0

        # branch 1: counter advanced
        def test_counter_advanced_is_alive
          assert_equal true,
            MainState.compute_alive(5, 4, 0, nil, 100.0, THRESHOLD)
          assert_equal true,
            MainState.compute_alive(5, 4, 2, 50.0, 1000.0, THRESHOLD)
        end

        # branch 2: in-call, recent (counter unchanged)
        def test_in_flight_within_threshold_is_alive
          # oldest_ts = 100, now = 100 + 359 = 459 → diff 359 < 360
          assert_equal true,
            MainState.compute_alive(5, 5, 1, 100.0, 459.0, THRESHOLD)
        end

        def test_in_flight_at_threshold_boundary_is_dead
          # oldest_ts = 100, now = 100 + 360 = 460 → diff 360 NOT < 360
          assert_equal false,
            MainState.compute_alive(5, 5, 1, 100.0, 460.0, THRESHOLD)
        end

        def test_in_flight_past_threshold_is_dead
          # oldest_ts = 100, now = 100 + 361
          assert_equal false,
            MainState.compute_alive(5, 5, 1, 100.0, 461.0, THRESHOLD)
        end

        # branch 3: in-call but oldest_ts nil (defensive — unreachable in
        # practice because snapshot is mutex-atomic)
        def test_in_flight_with_nil_ts_is_alive
          assert_equal true,
            MainState.compute_alive(5, 5, 1, nil, 1000.0, THRESHOLD)
        end

        # branch 4: idle
        def test_idle_no_progress_is_dead
          assert_equal false,
            MainState.compute_alive(5, 5, 0, nil, 1000.0, THRESHOLD)
        end

        # Counter advance dominates threshold check
        def test_counter_advanced_overrides_stale_ts
          # Even if oldest_ts is way past threshold, counter advance => alive.
          assert_equal true,
            MainState.compute_alive(6, 5, 1, 100.0, 9999.0, THRESHOLD)
        end

        # First iteration of pulse loop: last_counter = -1, counter = 0,
        # in_flight = 0, ts = nil. Worker just spawned, no calls yet.
        # Counter advanced from -1 to 0 → alive=true.
        def test_first_iteration_with_zero_counter
          assert_equal true,
            MainState.compute_alive(0, -1, 0, nil, 0.0, THRESHOLD)
        end

        # last_counter == counter == 0, in_flight==0, ts nil → idle, dead
        def test_second_iteration_no_calls_yet
          assert_equal false,
            MainState.compute_alive(0, 0, 0, nil, 5.0, THRESHOLD)
        end

        # Custom threshold (e.g. lower for testing)
        def test_custom_threshold
          # threshold=10, oldest 100, now 109 → diff 9 < 10 → alive
          assert_equal true,
            MainState.compute_alive(5, 5, 1, 100.0, 109.0, 10.0)
          # threshold=10, oldest 100, now 110 → diff 10 NOT < 10 → dead
          assert_equal false,
            MainState.compute_alive(5, 5, 1, 100.0, 110.0, 10.0)
        end
      end
    end
  end
end
