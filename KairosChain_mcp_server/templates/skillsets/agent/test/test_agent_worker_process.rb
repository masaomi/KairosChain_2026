#!/usr/bin/env ruby
# frozen_string_literal: true

# Real-process probes for bin/agent_step_worker.rb (second defect bundle,
# 2026-09-02; ledger: L2 agent_3_77_0_field_defects, "未修正" section).
#
# Every test starts the SHIPPED worker script as a child process. Only the
# gated call is replaced: KAIROS_SERVER_LIB points at a directory holding a
# fake kairos_mcp/tool_registry.rb whose behaviour is chosen through
# KAIROS_TEST_WORKER_MODE, so each exit path the worker can take is driven for
# real — bootstrap failure, supersession, pre-call signal, normal completion,
# uncaught error, stall bound, hard cap, and (D6) a signal that lands DURING
# the gated call. Timing is compressed through the existing stall / hard-cap
# env knobs plus the watchdog tick override. The setsid-failure path is the
# one exit this harness cannot reach (Process.setsid fails only for a process
# group leader, which a freshly spawned child never is).
#
# Reads the SHIPPED template copies, not the instance copies under .kairos.
# Usage: ruby test_agent_worker_process.rb   (from the project root)

require 'minitest/autorun'
require 'json'
require 'fileutils'
require 'tmpdir'
require 'rbconfig'
require_relative '../lib/agent/step_delegation'

WorkerDelegation = KairosMcp::SkillSets::Agent::StepDelegation
WORKER_SCRIPT = File.expand_path('../bin/agent_step_worker.rb', __dir__)

# The stand-in for the server lib the worker bootstraps. It runs INSIDE the
# worker process. Two modes act at require time (before the worker's
# supersession guard / pre-call signal check); the rest act inside call_tool.
FAKE_REGISTRY_SOURCE = <<~'RUBY'
  # frozen_string_literal: true
  require 'json'

  session_dir = ENV.fetch('KAIROS_TEST_SESSION_DIR')
  case ENV['KAIROS_TEST_WORKER_MODE'].to_s
  when 'supersede_at_require'
    path = File.join(session_dir, 'delegation.json')
    handle = JSON.parse(File.read(path))
    handle['step_token'] = 'someone-else'
    File.write(path, JSON.generate(handle))
  when 'term_at_require'
    Process.kill('TERM', Process.pid)
    sleep 0.3 # let the trap run before the worker reaches its pre-call check
  end

  module KairosMcp
    class ToolRegistry
      def call_tool(_name, _args)
        dir = ENV.fetch('KAIROS_TEST_SESSION_DIR')
        File.write(File.join(dir, 'in_call.marker'), Process.pid.to_s)
        case ENV['KAIROS_TEST_WORKER_MODE'].to_s
        when 'raise'
          raise 'boom from fake registry'
        when /\Asleep:(\d+)\z/
          # Loop rather than one sleep: a trapped signal may cut a sleep short,
          # and the D6 probe needs the call to keep running after the signal.
          deadline = Time.now + Regexp.last_match(1).to_i
          sleep 0.1 while Time.now < deadline
        when /\Abusy:(\d+)\z/
          # Keep the session dir ACTIVE (a real write every 0.2 s) so only the
          # hard cap can fire, never the stall bound.
          deadline = Time.now + Regexp.last_match(1).to_i
          activity = File.join(dir, 'activity.txt')
          while Time.now < deadline
            File.write(activity, Time.now.to_f.to_s)
            sleep 0.2
          end
        end
        [{ type: 'text', text: JSON.generate({ 'status' => 'ok', 'state' => 'proposed' }) }]
      end
    end
  end
RUBY

class TestWorkerProcess < Minitest::Test
  def setup
    @root = Dir.mktmpdir('worker_proc_')
    @session_dir = File.join(@root, 'session')
    @fake_lib = File.join(@root, 'fake_lib')
    FileUtils.mkdir_p(File.join(@fake_lib, 'kairos_mcp'))
    File.write(File.join(@fake_lib, 'kairos_mcp', 'tool_registry.rb'), FAKE_REGISTRY_SOURCE)
    File.write(File.join(@fake_lib, 'kairos_mcp', 'plugin_projector.rb'),
               "module KairosMcp; module PluginProjector; end; end\n")
    @delegation = WorkerDelegation.new(@session_dir)
    _how, @token = @delegation.open_handle({ 'action' => 'approve' }, '0:observed:0', 'approve')
    @pid = nil
  end

  def teardown
    if @pid
      begin
        Process.kill('KILL', @pid)
        Process.waitpid(@pid)
      rescue Errno::ESRCH, Errno::ECHILD
        # already gone
      end
    end
    FileUtils.remove_entry(@root)
  end

  # ---- helpers ----

  def spawn_worker(mode, extra_env = {}, script: WORKER_SCRIPT)
    log = File.join(@root, 'worker.log') # OUTSIDE the session dir: not activity
    env = {
      'KAIROS_SERVER_LIB'        => @fake_lib,
      'KAIROS_TEST_WORKER_MODE'  => mode,
      'KAIROS_TEST_SESSION_DIR'  => @session_dir,
      'KAIROS_PROJECT_ROOT'      => nil,
      'KAIROS_DATA_DIR'          => nil,
      'KAIROS_WORKER_STALL_SECONDS'         => nil,
      'KAIROS_WORKER_TIMEOUT_SECONDS'       => nil,
      'KAIROS_WORKER_WATCHDOG_TICK_SECONDS' => nil
    }.merge(extra_env)
    @pid = Process.spawn(env, RbConfig.ruby, script, 'sid-1', @session_dir,
                         in: :close, out: log, err: log)
  end

  def wait_exit(timeout: 30)
    deadline = Time.now + timeout
    loop do
      done, status = Process.waitpid2(@pid, Process::WNOHANG)
      if done
        @pid = nil
        return status
      end
      flunk "worker did not exit within #{timeout}s; log:\n#{worker_log}" if Time.now > deadline
      sleep 0.1
    end
  end

  def wait_until(what, timeout: 10)
    deadline = Time.now + timeout
    until yield
      flunk "timed out waiting for #{what}; log:\n#{worker_log}" if Time.now > deadline
      sleep 0.05
    end
  end

  def worker_log
    File.read(File.join(@root, 'worker.log'))
  rescue StandardError
    ''
  end

  def exit_record
    @delegation.worker_exit
  end

  # ---- exit paths ----

  def test_normal_completion_writes_result_and_normal_record
    spawn_worker('normal')
    status = wait_exit
    assert_equal 0, status.exitstatus, worker_log
    rec = exit_record
    assert_equal 'normal', rec['exit_class']
    assert_equal @token, rec['step_token']
    refute rec.key?('signals_during_call')
    res = @delegation.result
    assert_equal @token, res['step_token']
    assert_equal 'proposed', res['outcome']['state']
    assert_equal 'ready', @delegation.status
  end

  def test_uncaught_error_writes_error_result_and_uncaught_record
    spawn_worker('raise')
    status = wait_exit
    assert_equal 1, status.exitstatus, worker_log
    rec = exit_record
    assert_equal 'uncaught', rec['exit_class']
    assert_match(/boom from fake registry/, rec['error'])
    assert_equal @token, rec['step_token']
    assert_equal 'error', @delegation.result['outcome']['status']
  end

  def test_superseded_handle_exits_without_running_or_writing_a_result
    spawn_worker('supersede_at_require')
    status = wait_exit
    assert_equal 0, status.exitstatus, worker_log
    rec = exit_record
    assert_equal 'superseded', rec['exit_class']
    assert_equal @token, rec['step_token'], 'record is tagged with the worker\'s OWN boot identity'
    assert_equal 'someone-else', rec['current_token']
    assert_nil @delegation.result
    refute File.exist?(File.join(@session_dir, 'in_call.marker')), 'the gated call must not have run'
  end

  def test_signal_before_the_gated_call_exits_130_with_a_record_and_no_result
    spawn_worker('term_at_require')
    status = wait_exit
    assert_equal 130, status.exitstatus, worker_log
    rec = exit_record
    assert_equal 'trapped_signal', rec['exit_class']
    assert_equal 'before_gated_call', rec['phase']
    assert_equal ['TERM'], rec['signals']
    assert_nil @delegation.result
    refute File.exist?(File.join(@session_dir, 'in_call.marker'))
  end

  def test_bootstrap_failure_leaves_a_hand_written_record_and_an_error_result
    # Same script text, relocated beside a lib whose step_delegation cannot load.
    bin_dir = File.join(@root, 'relocated', 'bin')
    lib_dir = File.join(@root, 'relocated', 'lib', 'agent')
    FileUtils.mkdir_p(bin_dir)
    FileUtils.mkdir_p(lib_dir)
    relocated = File.join(bin_dir, 'agent_step_worker.rb')
    FileUtils.cp(WORKER_SCRIPT, relocated)
    File.write(File.join(lib_dir, 'step_delegation.rb'), "raise LoadError, 'boom at bootstrap'\n")

    spawn_worker('normal', {}, script: relocated)
    status = wait_exit
    assert_equal 1, status.exitstatus, worker_log
    rec = exit_record
    assert_equal 'bootstrap_failure', rec['exit_class']
    assert_equal @token, rec['step_token']
    assert_match(/boom at bootstrap/, rec['error'])
    res = @delegation.result
    assert_equal 'error', res['outcome']['status']
    assert_match(/worker bootstrap failed/, res['outcome']['error'])
  end

  # ---- watchdog: the two bounds, each firing for real ----

  def test_stall_bound_fires_when_the_session_dir_goes_silent
    spawn_worker('sleep:30', { 'KAIROS_WORKER_STALL_SECONDS' => '1',
                               'KAIROS_WORKER_TIMEOUT_SECONDS' => '600',
                               'KAIROS_WORKER_WATCHDOG_TICK_SECONDS' => '1' })
    status = wait_exit(timeout: 15)
    assert_equal 124, status.exitstatus, worker_log
    rec = exit_record
    assert_equal 'self_timeout_stalled', rec['exit_class']
    assert_equal @token, rec['step_token']
    assert_operator rec['silent_seconds'], :>, 1
    assert_operator rec['elapsed_seconds'], :<, 30, 'the hard cap did not fire; the stall bound did'
    assert_nil @delegation.result, 'a watchdog exit is never a result'
  end

  def test_hard_cap_fires_even_while_the_session_dir_stays_active
    spawn_worker('busy:30', { 'KAIROS_WORKER_STALL_SECONDS' => '600',
                              'KAIROS_WORKER_TIMEOUT_SECONDS' => '2',
                              'KAIROS_WORKER_WATCHDOG_TICK_SECONDS' => '1' })
    status = wait_exit(timeout: 15)
    assert_equal 124, status.exitstatus, worker_log
    rec = exit_record
    assert_equal 'self_timeout_hard_cap', rec['exit_class']
    assert_operator rec['elapsed_seconds'], :>, 2
    assert_operator rec['silent_seconds'], :<=, 1, 'activity kept the stall clock fresh; only the cap could fire'
    assert_nil @delegation.result
  end

  # ---- D6: a signal that lands DURING the gated call ----

  def test_signal_during_the_gated_call_is_recorded_and_the_call_finishes
    spawn_worker('sleep:6')
    wait_until('the gated call to start') { File.exist?(File.join(@session_dir, 'in_call.marker')) }
    sleep 0.3
    Process.kill('TERM', @pid)

    wait_until('the interim trapped_signal record', timeout: 5) do
      rec = exit_record
      rec && rec['exit_class'] == 'trapped_signal'
    end
    interim = exit_record
    assert_equal 'during_gated_call', interim['phase']
    assert_equal ['TERM'], interim['signals']
    assert_equal @token, interim['step_token']
    assert_nil @delegation.result, 'the interim record is not a result and the call is still running'

    status = wait_exit(timeout: 20)
    assert_equal 0, status.exitstatus, worker_log
    final = exit_record
    assert_equal 'normal', final['exit_class']
    assert_equal ['TERM'], final['signals_during_call']
    assert_equal 'proposed', @delegation.result['outcome']['state']
  end
end
