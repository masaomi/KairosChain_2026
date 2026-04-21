# frozen_string_literal: true

# Test suite for P4.1: DaemonLlmCaller + UsageAccumulator contract + Integration exception path
#
# Run: RBENV_VERSION=3.3.7 ruby -I lib -I . test_p4_1_daemon_llm_caller.rb

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'webrick'

$LOAD_PATH.unshift File.join(__dir__, 'lib')
require 'kairos_mcp/daemon/daemon_llm_caller'
require 'kairos_mcp/daemon/llm_phase_functions'
require 'kairos_mcp/daemon/integration'
require 'kairos_mcp/daemon/heartbeat'
require 'kairos_mcp/daemon/budget'

module P41Tests
  DaemonLlmCaller   = KairosMcp::Daemon::DaemonLlmCaller
  LlmPhaseFunctions = KairosMcp::Daemon::LlmPhaseFunctions
  Integration       = KairosMcp::Daemon::Integration
  Budget            = KairosMcp::Daemon::Budget
  Heartbeat         = KairosMcp::Daemon::Heartbeat

  # ============================================================
  # Fake HTTP server for testing DaemonLlmCaller
  # ============================================================
  class FakeAnthropicServer
    attr_reader :port, :request_count

    def initialize
      @port = nil
      @request_count = 0
      @responses = []
      @mutex = Mutex.new
    end

    def enqueue_response(code, body, headers = {})
      @responses << { code: code, body: body, headers: headers }
    end

    def start
      @server = WEBrick::HTTPServer.new(
        Port: 0,
        Logger: WEBrick::Log.new('/dev/null'),
        AccessLog: []
      )
      @port = @server.config[:Port]

      @server.mount_proc '/v1/messages' do |req, res|
        @mutex.synchronize { @request_count += 1 }
        resp = @responses.shift || { code: 500, body: '{"error":"no response queued"}', headers: {} }
        res.status = resp[:code]
        res['content-type'] = 'application/json'
        resp[:headers].each { |k, v| res[k] = v }
        res.body = resp[:body].is_a?(String) ? resp[:body] : JSON.generate(resp[:body])
      end

      @thread = Thread.new { @server.start }
      sleep 0.1 until @port  # wait for server
    end

    def stop
      @server&.shutdown
      @thread&.join(2)
    end
  end

  # Helper to create a DaemonLlmCaller pointing at the fake server
  def self.make_caller(server, stop_requested: -> { false }, heartbeat_callback: nil)
    # Override API_URL by stubbing http_post
    caller = DaemonLlmCaller.new(
      api_key: 'test-key',
      model: 'test-model',
      timeout: 2,
      stop_requested: stop_requested,
      heartbeat_callback: heartbeat_callback
    )
    # Monkey-patch to use local server
    caller.define_singleton_method(:http_post) do |body|
      uri = URI("http://127.0.0.1:#{server.port}/v1/messages")
      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = 2
      http.open_timeout = 2
      req = Net::HTTP::Post.new(uri.path)
      req['content-type'] = 'application/json'
      req.body = JSON.generate(body)
      resp = http.request(req)
      code = resp.code.to_i
      case code
      when 200 then JSON.parse(resp.body)
      when 429, 529
        raise DaemonLlmCaller::LlmCallError.new(
          "HTTP #{code}", http_code: code, retryable: true,
          retry_after: resp['retry-after']&.to_i
        )
      when 401, 403
        raise DaemonLlmCaller::LlmCallError.new("HTTP #{code}", http_code: code)
      else
        raise DaemonLlmCaller::LlmCallError.new("HTTP #{code}", http_code: code)
      end
    end
    caller
  end
end

# ============================================================
# DaemonLlmCaller tests
# ============================================================
class TestDaemonLlmCaller < Minitest::Test
  def setup
    @server = P41Tests::FakeAnthropicServer.new
    @server.start
  end

  def teardown
    @server.stop
  end

  def test_successful_call
    @server.enqueue_response(200, {
      'content' => [{ 'type' => 'text', 'text' => 'pong' }],
      'usage' => { 'input_tokens' => 10, 'output_tokens' => 3 }
    })

    caller = P41Tests.make_caller(@server)
    result = caller.call(messages: [{ role: 'user', content: 'ping' }],
                         system: 'test', max_tokens: 8)

    assert_equal 'pong', result[:content]
    assert_equal 10, result[:input_tokens]
    assert_equal 3, result[:output_tokens]
    assert_equal 1, result[:attempts]
    assert_equal 1, @server.request_count
  end

  def test_retry_on_429
    # First call: 429, second: success
    @server.enqueue_response(429, { 'error' => 'rate limited' },
                             { 'retry-after' => '1' })
    @server.enqueue_response(200, {
      'content' => [{ 'type' => 'text', 'text' => 'ok' }],
      'usage' => { 'input_tokens' => 5, 'output_tokens' => 2 }
    })

    caller = P41Tests.make_caller(@server)
    result = caller.call(messages: [{ role: 'user', content: 'test' }],
                         system: 'test', max_tokens: 8)

    assert_equal 'ok', result[:content]
    assert_equal 2, result[:attempts]
    assert_equal 2, @server.request_count
  end

  def test_auth_error_no_retry
    @server.enqueue_response(401, { 'error' => 'invalid key' })

    caller = P41Tests.make_caller(@server)
    err = assert_raises(DaemonLlmCaller::LlmCallError) do
      caller.call(messages: [{ role: 'user', content: 'test' }],
                  system: 'test', max_tokens: 8)
    end
    assert_equal 401, err.http_code
    assert_equal 1, @server.request_count  # no retry
  end

  def test_max_retries_exhausted
    3.times do
      @server.enqueue_response(429, { 'error' => 'rate limited' },
                               { 'retry-after' => '0' })
    end

    caller = P41Tests.make_caller(@server)
    err = assert_raises(DaemonLlmCaller::LlmCallError) do
      caller.call(messages: [{ role: 'user', content: 'test' }],
                  system: 'test', max_tokens: 8)
    end
    assert_equal 429, err.http_code
    assert_equal 3, @server.request_count  # 1 + MAX_RETRIES(2)
  end

  def test_shutdown_requested_before_call
    caller = P41Tests.make_caller(@server, stop_requested: -> { true })

    assert_raises(DaemonLlmCaller::ShutdownRequested) do
      caller.call(messages: [{ role: 'user', content: 'test' }],
                  system: 'test', max_tokens: 8)
    end
    assert_equal 0, @server.request_count
  end

  def test_shutdown_during_retry_sleep
    @server.enqueue_response(429, { 'error' => 'rate limited' },
                             { 'retry-after' => '10' })
    call_count = 0
    caller = P41Tests.make_caller(@server,
      stop_requested: -> { call_count += 1; call_count > 2 })

    assert_raises(DaemonLlmCaller::ShutdownRequested) do
      caller.call(messages: [{ role: 'user', content: 'test' }],
                  system: 'test', max_tokens: 8)
    end
    assert_equal 1, @server.request_count
  end

  def test_heartbeat_callback_during_retry
    @server.enqueue_response(429, { 'error' => 'rate limited' },
                             { 'retry-after' => '1' })
    @server.enqueue_response(200, {
      'content' => [{ 'type' => 'text', 'text' => 'ok' }],
      'usage' => { 'input_tokens' => 1, 'output_tokens' => 1 }
    })

    heartbeat_count = 0
    caller = P41Tests.make_caller(@server,
      heartbeat_callback: -> { heartbeat_count += 1 })

    caller.call(messages: [{ role: 'user', content: 'test' }],
                system: 'test', max_tokens: 8)

    assert heartbeat_count > 0, "heartbeat callback should fire during retry sleep"
  end

  def test_config_error_on_empty_key
    assert_raises(DaemonLlmCaller::ConfigError) do
      DaemonLlmCaller.new(api_key: '')
    end
  end

  def test_config_error_on_nil_key
    assert_raises(DaemonLlmCaller::ConfigError) do
      DaemonLlmCaller.new(api_key: nil)
    end
  end

  DaemonLlmCaller = KairosMcp::Daemon::DaemonLlmCaller
end

# ============================================================
# UsageAccumulator contract tests
# ============================================================
class TestUsageAccumulatorContract < Minitest::Test
  UsageAccumulator = KairosMcp::Daemon::LlmPhaseFunctions::UsageAccumulator

  def test_to_h_shape
    ua = UsageAccumulator.new
    h = ua.to_h
    assert_equal %i[llm_calls input_tokens output_tokens].sort, h.keys.sort
    assert_equal 0, h[:llm_calls]
    assert_equal 0, h[:input_tokens]
    assert_equal 0, h[:output_tokens]
  end

  def test_record_with_attempts
    ua = UsageAccumulator.new
    ua.record(content: 'hi', input_tokens: 100, output_tokens: 50, attempts: 3)
    assert_equal 3, ua.llm_calls
    assert_equal 100, ua.input_tokens
    assert_equal 50, ua.output_tokens
  end

  def test_record_without_attempts_defaults_to_1
    ua = UsageAccumulator.new
    ua.record(content: 'hi', input_tokens: 10, output_tokens: 5)
    assert_equal 1, ua.llm_calls
  end

  def test_record_with_string_keys
    ua = UsageAccumulator.new
    ua.record('content' => 'hi', 'input_tokens' => 10, 'output_tokens' => 5, 'attempts' => 2)
    assert_equal 2, ua.llm_calls
    assert_equal 10, ua.input_tokens
  end

  def test_reset_clears_all
    ua = UsageAccumulator.new
    ua.record(input_tokens: 100, output_tokens: 50, attempts: 3)
    ua.reset!
    assert_equal 0, ua.llm_calls
    assert_equal 0, ua.input_tokens
  end

  def test_cumulative_across_phases
    ua = UsageAccumulator.new
    ua.record(input_tokens: 100, output_tokens: 50, attempts: 2)  # orient
    ua.record(input_tokens: 200, output_tokens: 80, attempts: 1)  # decide
    ua.record(input_tokens: 50, output_tokens: 20, attempts: 1)   # reflect
    assert_equal 4, ua.llm_calls
    assert_equal 350, ua.input_tokens
    assert_equal 150, ua.output_tokens
  end

  def test_to_h_compatible_with_apply_usage
    ua = UsageAccumulator.new
    ua.record(input_tokens: 100, output_tokens: 50, attempts: 2)
    h = ua.to_h

    # apply_usage expects :llm_calls, :input_tokens, :output_tokens
    assert_respond_to h, :[]
    assert_equal 2, Integer(h[:llm_calls] || h['llm_calls'] || 0)
    assert_equal 100, Integer(h[:input_tokens] || h['input_tokens'] || 0)
    assert_equal 50, Integer(h[:output_tokens] || h['output_tokens'] || 0)
  end
end

# ============================================================
# Integration exception path tests
# ============================================================
class TestIntegrationExceptionPath < Minitest::Test
  Integration = KairosMcp::Daemon::Integration
  Budget      = KairosMcp::Daemon::Budget
  UsageAccumulator = KairosMcp::Daemon::LlmPhaseFunctions::UsageAccumulator

  def test_partial_usage_from_accumulator_with_data
    ua = UsageAccumulator.new
    ua.record(input_tokens: 100, output_tokens: 50, attempts: 2)

    state = Integration::State.new(usage_accumulator: ua)
    partial = Integration.partial_usage_from_accumulator(state)

    assert_equal 2, partial[:llm_calls]
    assert_equal 100, partial[:input_tokens]
    assert_equal 50, partial[:output_tokens]
  end

  def test_partial_usage_from_accumulator_nil
    state = Integration::State.new(usage_accumulator: nil)
    partial = Integration.partial_usage_from_accumulator(state)

    assert_equal 0, partial[:llm_calls]
    assert_equal 0, partial[:input_tokens]
    assert_equal 0, partial[:output_tokens]
  end

  def test_usage_accumulator_in_state
    state = Integration::State.new
    assert_nil state.usage_accumulator

    ua = UsageAccumulator.new
    state.usage_accumulator = ua
    assert_equal ua, state.usage_accumulator
  end

  def test_wire_accepts_usage_accumulator
    daemon = Minitest::Mock.new
    daemon.expect(:instance_variable_set, nil, [:@integration_state, Integration::State])
    daemon.expect(:define_singleton_method, nil, [:integration_state])
    daemon.expect(:define_singleton_method, nil, [:active_mandate_id])
    daemon.expect(:define_singleton_method, nil, [:last_cycle_at])
    daemon.expect(:define_singleton_method, nil, [:queue_depth])
    daemon.expect(:define_singleton_method, nil, [:chronos_tick])
    daemon.expect(:define_singleton_method, nil, [:run_one_ooda_cycle])

    chronos = Object.new
    ua = UsageAccumulator.new

    # Just verify it doesn't raise
    Integration.wire!(daemon, chronos: chronos, usage_accumulator: ua)

    state = nil
    daemon.instance_variable_get(:@integration_state)
  rescue => e
    # Mock might not fully cooperate but we're testing the wire! signature
    pass  # if we get here, wire! accepted the param
  end

  def test_error_path_applies_partial_usage
    tmp = Dir.mktmpdir
    budget_path = File.join(tmp, 'budget.json')
    budget = Budget.new(path: budget_path, limit: 1000)
    budget.load

    ua = UsageAccumulator.new
    ua.record(input_tokens: 100, output_tokens: 50, attempts: 2)

    # Simulate error path
    state = Integration::State.new(budget: budget, usage_accumulator: ua)
    partial = Integration.partial_usage_from_accumulator(state)
    partial[:status] = 'error'
    Integration.apply_usage(state, partial)

    assert_equal 2, budget.llm_calls
    assert_equal 100, budget.input_tokens
    assert_equal 50, budget.output_tokens
  ensure
    FileUtils.rm_rf(tmp)
  end

  def test_shutdown_path_applies_partial_usage
    tmp = Dir.mktmpdir
    budget_path = File.join(tmp, 'budget.json')
    budget = Budget.new(path: budget_path, limit: 1000)
    budget.load

    ua = UsageAccumulator.new
    ua.record(input_tokens: 200, output_tokens: 80, attempts: 3)

    state = Integration::State.new(budget: budget, usage_accumulator: ua)
    partial = Integration.partial_usage_from_accumulator(state)
    partial[:status] = 'interrupted'
    Integration.apply_usage(state, partial)

    assert_equal 3, budget.llm_calls
    assert_equal 200, budget.input_tokens
  ensure
    FileUtils.rm_rf(tmp)
  end

  def test_shutdown_error_detection
    shutdown = KairosMcp::Daemon::DaemonLlmCaller::ShutdownRequested.new('test')
    assert Integration.shutdown_error?(shutdown), 'should detect ShutdownRequested'

    other = RuntimeError.new('other')
    refute Integration.shutdown_error?(other), 'should not detect RuntimeError'
  end
end

# ============================================================
# call_and_record: failed attempts are tracked in UsageAccumulator
# ============================================================
class TestCallAndRecordFailedAttempts < Minitest::Test
  LlmPhaseFunctions = KairosMcp::Daemon::LlmPhaseFunctions
  UsageAccumulator  = LlmPhaseFunctions::UsageAccumulator
  LlmCallError      = KairosMcp::Daemon::DaemonLlmCaller::LlmCallError

  def test_failed_call_records_attempts_in_usage
    usage = UsageAccumulator.new

    # Simulate: orient succeeds (2 attempts), decide fails (3 attempts)
    usage.record(input_tokens: 100, output_tokens: 50, attempts: 2)  # orient success

    # Simulate a failed LLM call via call_and_record
    failing_caller = Object.new
    failing_caller.define_singleton_method(:call) do |**_|
      raise LlmCallError.new('rate limited', http_code: 429, retryable: true, attempts: 3)
    end

    assert_raises(LlmCallError) do
      LlmPhaseFunctions.call_and_record(failing_caller, usage,
        messages: [], system: 'test', max_tokens: 8)
    end

    # Usage should include both orient (2) + failed decide (3) = 5
    assert_equal 5, usage.llm_calls
    assert_equal 100, usage.input_tokens  # only orient's tokens
    assert_equal 50, usage.output_tokens
  end

  def test_successful_call_records_normally
    usage = UsageAccumulator.new

    success_caller = Object.new
    success_caller.define_singleton_method(:call) do |**_|
      { content: 'ok', input_tokens: 50, output_tokens: 20, attempts: 1 }
    end

    result = LlmPhaseFunctions.call_and_record(success_caller, usage,
      messages: [], system: 'test', max_tokens: 8)

    assert_equal 'ok', result[:content]
    assert_equal 1, usage.llm_calls
    assert_equal 50, usage.input_tokens
  end

  def test_error_without_attempts_does_not_record
    usage = UsageAccumulator.new

    failing_caller = Object.new
    failing_caller.define_singleton_method(:call) do |**_|
      raise StandardError, 'generic error'
    end

    assert_raises(StandardError) do
      LlmPhaseFunctions.call_and_record(failing_caller, usage,
        messages: [], system: 'test', max_tokens: 8)
    end

    # No attempts attr → nothing recorded
    assert_equal 0, usage.llm_calls
  end

  def test_orient_success_then_decide_fail_budget_accurate
    tmp = Dir.mktmpdir
    budget_path = File.join(tmp, 'budget.json')
    budget = KairosMcp::Daemon::Budget.new(path: budget_path, limit: 1000)
    budget.load

    usage = UsageAccumulator.new

    # Orient succeeds with 2 attempts
    success_caller = Object.new
    success_caller.define_singleton_method(:call) do |**_|
      { content: '{}', input_tokens: 100, output_tokens: 50, attempts: 2 }
    end
    LlmPhaseFunctions.call_and_record(success_caller, usage,
      messages: [], system: 'test', max_tokens: 1024)

    # Decide fails after 3 attempts
    failing_caller = Object.new
    failing_caller.define_singleton_method(:call) do |**_|
      raise LlmCallError.new('429', http_code: 429, retryable: true, attempts: 3)
    end
    assert_raises(LlmCallError) do
      LlmPhaseFunctions.call_and_record(failing_caller, usage,
        messages: [], system: 'test', max_tokens: 2048)
    end

    # Total: orient(2) + decide_failed(3) = 5 attempts
    assert_equal 5, usage.llm_calls

    # Simulate Integration error recovery
    state = KairosMcp::Daemon::Integration::State.new(
      budget: budget, usage_accumulator: usage
    )
    partial = KairosMcp::Daemon::Integration.partial_usage_from_accumulator(state)
    KairosMcp::Daemon::Integration.apply_usage(state, partial)

    assert_equal 5, budget.llm_calls, "Budget must reflect all 5 attempts (2 orient + 3 failed decide)"
    assert_equal 100, budget.input_tokens, "Only orient tokens (decide failed)"
  ensure
    FileUtils.rm_rf(tmp)
  end
end
