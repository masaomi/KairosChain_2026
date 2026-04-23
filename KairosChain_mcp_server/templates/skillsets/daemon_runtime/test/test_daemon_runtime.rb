# frozen_string_literal: true

# Phase 1 Step 1.2 tests — daemon_runtime SkillSet scaffold
# (24/7 v0.4 §2.4 MainLoopSupervisor, §2.7 SignalCoordinator, §2.2 LifecycleHook).

require 'minitest/autorun'
require 'timeout'

ROOT = File.expand_path('../../../../..', __dir__)
$LOAD_PATH.unshift File.join(ROOT, 'KairosChain_mcp_server', 'lib')
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'kairos_mcp'
require 'kairos_mcp/lifecycle_hook'
require 'kairos_mcp/signal_handle'
require 'daemon_runtime'

DR = KairosMcp::SkillSets::DaemonRuntime

class TestSignalCoordinator < Minitest::Test
  def setup
    @sc = DR::SignalCoordinator.new
  end

  def teardown
    @sc.stop
  end

  def test_initial_state_is_clean
    refute @sc.shutdown_requested?
    refute @sc.diagnostic_requested?
    refute @sc.reload_requested?
  end

  def test_trap_signal_term_sets_shutdown
    @sc.trap_signal('TERM')
    wait_for { @sc.shutdown_requested? }
    assert @sc.shutdown_requested?
  end

  def test_trap_signal_int_sets_shutdown
    @sc.trap_signal('INT')
    wait_for { @sc.shutdown_requested? }
    assert @sc.shutdown_requested?
  end

  def test_usr2_sets_diagnostic_only
    @sc.trap_signal('USR2')
    wait_for { @sc.diagnostic_requested? }
    assert @sc.diagnostic_requested?
    refute @sc.shutdown_requested?
  end

  def test_hup_sets_reload_only
    @sc.trap_signal('HUP')
    wait_for { @sc.reload_requested? }
    assert @sc.reload_requested?
    refute @sc.shutdown_requested?
  end

  def test_clear_reload_toggles_off
    @sc.trap_signal('HUP')
    wait_for { @sc.reload_requested? }
    @sc.clear_reload!
    refute @sc.reload_requested?
  end

  def test_unknown_signal_ignored
    @sc.trap_signal('WINCH')
    sleep 0.05
    refute @sc.shutdown_requested?
    refute @sc.diagnostic_requested?
    refute @sc.reload_requested?
  end

  def test_wait_or_tick_returns_immediately_on_shutdown
    @sc.trap_signal('TERM')
    wait_for { @sc.shutdown_requested? }
    elapsed = measure { @sc.wait_or_tick(2.0) }
    assert elapsed < 0.2, "wait_or_tick blocked despite shutdown (#{elapsed}s)"
  end

  def test_wait_or_tick_respects_timeout_when_idle
    elapsed = measure { @sc.wait_or_tick(0.1) }
    assert_in_delta 0.1, elapsed, 0.15
  end

  def test_stop_is_idempotent
    @sc.stop
    @sc.stop  # must not raise
    assert true
  end

  def test_stop_is_thread_safe_under_contention
    # R1 P2 (4.7): @stopped was not mutex-guarded; two concurrent stops
    # could both pass the guard and double-close.
    sc = DR::SignalCoordinator.new
    threads = Array.new(8) { Thread.new { sc.stop } }
    threads.each(&:join)
    assert true  # no exception raised — guard works
  end

  def test_pipe_full_drop_does_not_lose_shutdown
    # R1 P1 (Codex): dropped bytes under pipe-full must not lose the
    # shutdown request. Simulate by pre-filling the pipe before a
    # TERM signal so write_nonblock hits WaitWritable.
    sc = DR::SignalCoordinator.new
    # Spam many signals to overflow the internal pipe; at least one of
    # them must still surface shutdown via the latch.
    200.times { sc.trap_signal('TERM') }
    wait_for { sc.shutdown_requested? }
    assert sc.shutdown_requested?
  ensure
    sc&.stop
  end

  private

  def wait_for(timeout: 1.0)
    deadline = Time.now + timeout
    until yield
      return if Time.now > deadline
      sleep 0.01
    end
  end

  def measure
    t0 = Time.now
    yield
    Time.now - t0
  end
end

class TestMainLoopSupervisor < Minitest::Test
  class FakeSignal
    attr_accessor :shutdown, :reload, :diagnostic

    def initialize
      @shutdown = false
      @reload = false
      @diagnostic = false
      @ticks = 0
    end

    def shutdown_requested?;   @shutdown;   end
    def reload_requested?;     @reload;     end
    def diagnostic_requested?; @diagnostic; end
    def clear_reload!;     @reload     = false; end
    def clear_diagnostic!; @diagnostic = false; end
    def wait_or_tick(_s); @ticks += 1; end
  end

  def test_supervise_exits_when_shutdown_is_set_immediately
    sig = FakeSignal.new
    sig.shutdown = true
    sup = DR::MainLoopSupervisor.new(tick_interval: 0.01)
    sup.supervise(signal: sig)
    assert_equal 0, sup.iterations
  end

  def test_supervise_runs_iterations_until_shutdown
    sig = FakeSignal.new
    counter = 0
    hook = -> {
      counter += 1
      sig.shutdown = true if counter >= 3
    }
    sup = DR::MainLoopSupervisor.new(tick_interval: 0.0)
    sup.supervise(signal: sig, hook_chain: hook)
    assert_equal 3, sup.iterations
    assert_equal 3, counter
  end

  def test_supervise_honors_reload_and_clears_it
    sig = FakeSignal.new
    sig.reload = true
    iter = 0
    hook = -> {
      iter += 1
      sig.shutdown = true if iter >= 1
    }
    sup = DR::MainLoopSupervisor.new(tick_interval: 0.0)
    sup.supervise(signal: sig, hook_chain: hook)
    assert_equal 1, sup.reloads
    refute sig.reload_requested?
  end

  def test_supervise_honors_diagnostic_and_clears_it
    sig = FakeSignal.new
    sig.diagnostic = true
    iter = 0
    hook = -> {
      iter += 1
      sig.shutdown = true if iter >= 1
    }
    sup = DR::MainLoopSupervisor.new(tick_interval: 0.0)
    sup.supervise(signal: sig, hook_chain: hook)
    assert_equal 1, sup.diagnostics
    refute sig.diagnostic_requested?
  end
end

class TestMainLoopLifecycleHook < Minitest::Test
  def test_is_registered_lifecycle_hook
    assert DR::MainLoop.include?(KairosMcp::LifecycleHook)
  end

  def test_run_main_loop_returns_when_bootstrap_signals_shutdown
    ml = DR::MainLoop.new
    signal = KairosMcp::SignalHandle.new
    result = nil
    thread = Thread.new do
      result = ml.run_main_loop(registry: :fake_registry,
                                signal: signal,
                                tick_interval: 0.02)
    end

    sleep 0.1
    signal.request_shutdown

    Timeout.timeout(3) { thread.join }
    assert_kind_of Hash, result
    assert_kind_of Integer, result[:iterations]
  end

  def test_bridge_forwards_reload_and_diagnostic
    # R1 P1 (3-voice): reload and diagnostic must actually reach the
    # supervisor via the bridge when the Bootstrap SignalHandle is
    # flipped (as bin/kairos-chain-daemon does for HUP/USR2).
    ml = DR::MainLoop.new
    signal = KairosMcp::SignalHandle.new
    result = nil
    thread = Thread.new do
      result = ml.run_main_loop(registry: :fake_registry,
                                signal: signal,
                                tick_interval: 0.02)
    end

    signal.request_reload
    signal.request_diagnostic
    sleep 0.6  # allow bridge poll (BRIDGE_POLL_SEC=0.2) + supervise tick
    signal.request_shutdown

    Timeout.timeout(3) { thread.join }
    assert_operator result[:reloads], :>=, 1,
      "expected reload to be forwarded; got #{result.inspect}"
    assert_operator result[:diagnostics], :>=, 1,
      "expected diagnostic to be forwarded; got #{result.inspect}"
  end
end
