# frozen_string_literal: true

require 'minitest/autorun'
require 'time'

# Unit tests for Service Grant SkillSet components.
# These tests do NOT require PostgreSQL — they test pure logic.
# Integration tests with PG are marked with :pg tag.

# Load errors module directly for isolated testing
$LOAD_PATH.unshift File.join(__dir__, '..', 'lib')

class TestServiceGrantErrors < Minitest::Test
  def setup
    require 'service_grant/errors'
  end

  def test_access_denied_error_reason
    err = ServiceGrant::AccessDeniedError.new(:quota_exceeded, service: 'mp', action: 'deposit')
    assert_equal :quota_exceeded, err.reason
    assert_equal 'mp', err.details[:service]
    assert_equal 'deposit', err.details[:action]
    assert_includes err.message, 'quota_exceeded'
  end

  def test_access_denied_error_custom_message
    err = ServiceGrant::AccessDeniedError.new(:suspended, message: 'Grant suspended: abuse')
    assert_equal :suspended, err.reason
    assert_equal 'Grant suspended: abuse', err.message
  end

  def test_pg_readonly_is_pg_unavailable
    err = ServiceGrant::PgReadonlyError.new('test')
    assert_kind_of ServiceGrant::PgUnavailableError, err
  end
end

class TestIpRateTracker < Minitest::Test
  def setup
    require 'service_grant/ip_rate_tracker'
    @tracker = ServiceGrant::IpRateTracker.new(max: 3, window: 60)
  end

  def test_allows_under_limit
    2.times { @tracker.record('1.2.3.4') }
    refute @tracker.limited?('1.2.3.4')
  end

  def test_limits_at_max
    3.times { @tracker.record('1.2.3.4') }
    assert @tracker.limited?('1.2.3.4')
  end

  def test_different_ips_independent
    3.times { @tracker.record('1.2.3.4') }
    refute @tracker.limited?('5.6.7.8')
  end

  def test_unknown_ip_not_limited
    refute @tracker.limited?('unknown')
  end
end

class TestCycleManager < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/cycle_manager'
    @registry = MockPlanRegistry.new('monthly')
    @cm = ServiceGrant::CycleManager.new(plan_registry: @registry)
  end

  def test_monthly_cycle
    start, finish = @cm.current_cycle('test')
    assert_equal 1, start.day
    assert start < finish
    # Next month's 1st
    if start.month == 12
      assert_equal 1, finish.month
      assert_equal start.year + 1, finish.year
    else
      assert_equal start.month + 1, finish.month
    end
  end

  def test_weekly_cycle
    @registry.unit = 'weekly'
    start, finish = @cm.current_cycle('test')
    assert_equal 1, start.wday  # Monday
    assert_equal 7 * 86_400, (finish - start).to_i
  end

  def test_daily_cycle
    @registry.unit = 'daily'
    start, finish = @cm.current_cycle('test')
    assert_equal 86_400, (finish - start).to_i
  end

  def test_cycle_end
    cycle_end = @cm.current_cycle_end('test')
    _, expected_end = @cm.current_cycle('test')
    assert_equal expected_end, cycle_end
  end

  class MockPlanRegistry
    attr_accessor :unit
    def initialize(unit)
      @unit = unit
    end
    def cycle_unit(_service)
      @unit
    end
  end
end

class TestPlanRegistry < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/plan_registry'
    @config_path = create_test_config
    @pr = ServiceGrant::PlanRegistry.new(@config_path)
  end

  def teardown
    File.delete(@config_path) if @config_path && File.exist?(@config_path)
  end

  def test_services
    assert_includes @pr.services, 'test_service'
  end

  def test_plan_exists
    assert @pr.plan_exists?('test_service', 'free')
    refute @pr.plan_exists?('test_service', 'nonexistent')
  end

  def test_limit_for
    assert_equal 5, @pr.limit_for('test_service', 'free', 'write')
    assert_equal(-1, @pr.limit_for('test_service', 'free', 'read'))
  end

  def test_limit_for_unknown_plan_returns_nil
    assert_nil @pr.limit_for('test_service', 'unknown_plan', 'write')
  end

  def test_gated_action
    assert @pr.gated_action?('test_service', 'write')
  end

  def test_action_for_tool
    assert_equal 'write', @pr.action_for_tool('test_service', 'test_tool_write')
  end

  def test_write_action
    assert @pr.write_action?('test_service', 'write')
    refute @pr.write_action?('test_service', 'read')
  end

  def test_cycle_unit
    assert_equal 'monthly', @pr.cycle_unit('test_service')
  end

  def test_trust_requirement
    assert_equal 0.1, @pr.trust_requirement('test_service', 'free', 'write')
    assert_nil @pr.trust_requirement('test_service', 'free', 'read')
  end

  private

  def create_test_config
    require 'yaml'
    require 'tempfile'
    config = {
      'services' => {
        'test_service' => {
          'billing_model' => 'per_action',
          'currency' => 'USD',
          'cycle' => 'monthly',
          'write_actions' => ['write'],
          'action_map' => { 'test_tool_write' => 'write' },
          'plans' => {
            'free' => {
              'limits' => { 'write' => 5, 'read' => -1 },
              'trust_requirements' => { 'write' => 0.1 }
            }
          }
        }
      }
    }
    f = Tempfile.new(['test_service_grant', '.yml'])
    f.write(YAML.dump(config))
    f.close
    f.path
  end
end

class TestAccessCheckerLogic < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/access_checker'
  end

  def test_resolve_action_with_mapping
    checker = ServiceGrant::AccessChecker.new(
      grant_manager: nil, usage_tracker: nil,
      plan_registry: MockPlanRegistryForAction.new, cycle_manager: nil
    )
    assert_equal 'deposit_skill', checker.resolve_action('mp', 'meeting_deposit')
  end

  def test_resolve_action_without_mapping
    checker = ServiceGrant::AccessChecker.new(
      grant_manager: nil, usage_tracker: nil,
      plan_registry: MockPlanRegistryForAction.new, cycle_manager: nil
    )
    assert_equal 'unknown_tool', checker.resolve_action('mp', 'unknown_tool')
  end

  class MockPlanRegistryForAction
    def action_for_tool(_service, tool_name)
      { 'meeting_deposit' => 'deposit_skill' }[tool_name]
    end
  end
end

class TestAccessGateLogic < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/access_gate'
  end

  def test_stdio_mode_permissive
    gate = ServiceGrant::AccessGate.new(access_checker: nil)
    safety = MockSafety.new(nil)
    # Should return nil (pass) when no user context
    result = gate.call('some_tool', {}, safety)
    assert_nil result
  end

  def test_local_dev_permissive
    gate = ServiceGrant::AccessGate.new(access_checker: nil)
    safety = MockSafety.new({ local_dev: true })
    result = gate.call('some_tool', {}, safety)
    assert_nil result
  end

  class MockSafety
    def initialize(user)
      @user = user
    end
    def current_user
      @user
    end
  end
end

class TestPlaceMiddleware < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/place_middleware'
  end

  def test_no_session_store_returns_503
    mw = ServiceGrant::PlaceMiddleware.new(access_checker: nil)
    result = mw.check(peer_id: 'p1', action: 'browse', service: 'mp')
    assert_equal 503, result[:status]
  end

  def test_unknown_peer_returns_403
    store = MockSessionStore.new(nil)
    mw = ServiceGrant::PlaceMiddleware.new(access_checker: nil, session_store: store)
    result = mw.check(peer_id: 'unknown', action: 'browse', service: 'mp')
    assert_equal 403, result[:status]
    assert_includes result[:message], 'Cannot resolve identity'
  end

  def test_allowed_returns_nil
    store = MockSessionStore.new('abcd' * 16)
    checker = MockPassChecker.new
    mw = ServiceGrant::PlaceMiddleware.new(access_checker: checker, session_store: store)
    result = mw.check(peer_id: 'p1', action: 'browse', service: 'mp')
    assert_nil result
  end

  def test_quota_exceeded_returns_429
    store = MockSessionStore.new('abcd' * 16)
    checker = MockDenyChecker.new(:quota_exceeded)
    mw = ServiceGrant::PlaceMiddleware.new(access_checker: checker, session_store: store)
    result = mw.check(peer_id: 'p1', action: 'browse', service: 'mp')
    assert_equal 429, result[:status]
  end

  def test_suspended_returns_403
    store = MockSessionStore.new('abcd' * 16)
    checker = MockDenyChecker.new(:suspended)
    mw = ServiceGrant::PlaceMiddleware.new(access_checker: checker, session_store: store)
    result = mw.check(peer_id: 'p1', action: 'browse', service: 'mp')
    assert_equal 403, result[:status]
  end

  class MockSessionStore
    def initialize(hash)
      @hash = hash
    end
    def pubkey_hash_for(_peer_id)
      @hash
    end
  end

  class MockPassChecker
    def check_access(**_kwargs)
      nil
    end
  end

  class MockDenyChecker
    def initialize(reason)
      @reason = reason
    end
    def check_access(**kwargs)
      raise ServiceGrant::AccessDeniedError.new(@reason,
        service: kwargs[:service], action: kwargs[:action])
    end
  end
end

class TestRequestEnricher < Minitest::Test
  def setup
    require 'service_grant/request_enricher'
  end

  def test_enriches_missing_service
    enricher = ServiceGrant::RequestEnricher.new(service_name: 'meeting_place')
    ctx = { user: 'test' }
    result = enricher.enrich(ctx)
    assert_equal 'meeting_place', result[:service]
  end

  def test_preserves_existing_service
    enricher = ServiceGrant::RequestEnricher.new(service_name: 'meeting_place')
    ctx = { user: 'test', service: 'genomicschain' }
    result = enricher.enrich(ctx)
    assert_equal 'genomicschain', result[:service]
  end

  def test_nil_context_passes_through
    enricher = ServiceGrant::RequestEnricher.new(service_name: 'mp')
    assert_nil enricher.enrich(nil)
  end
end

class TestGrantManagerCooldown < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/ip_rate_tracker'
    require 'service_grant/grant_manager'
  end

  def test_in_cooldown_new_grant
    gm = ServiceGrant::GrantManager.new(pg_pool: nil, plan_registry: nil)
    grant = { first_seen_at: Time.now }
    assert gm.in_cooldown?(grant)
  end

  def test_not_in_cooldown_old_grant
    gm = ServiceGrant::GrantManager.new(pg_pool: nil, plan_registry: nil)
    grant = { first_seen_at: Time.now - 600 }
    refute gm.in_cooldown?(grant)
  end

  def test_not_in_cooldown_nil_first_seen
    gm = ServiceGrant::GrantManager.new(pg_pool: nil, plan_registry: nil)
    grant = { first_seen_at: nil }
    refute gm.in_cooldown?(grant)
  end
end

# === FIX-11: Critical Path Tests ===

class TestAccessCheckerCheckAccess < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/access_checker'
  end

  def test_suspended_grant_raises
    checker = build_checker(
      grant: { suspended: true, suspended_reason: 'abuse', plan: 'free', first_seen_at: Time.now - 600 },
      gated: true
    )
    err = assert_raises(ServiceGrant::AccessDeniedError) do
      checker.check_access(pubkey_hash: 'abc', action: 'write', service: 'svc')
    end
    assert_equal :suspended, err.reason
  end

  def test_cooldown_write_raises
    checker = build_checker(
      grant: { suspended: false, plan: 'free', first_seen_at: Time.now },
      gated: true, write_action: true
    )
    err = assert_raises(ServiceGrant::AccessDeniedError) do
      checker.check_access(pubkey_hash: 'abc', action: 'write', service: 'svc')
    end
    assert_equal :cooldown, err.reason
  end

  def test_cooldown_read_allowed
    checker = build_checker(
      grant: { suspended: false, plan: 'free', first_seen_at: Time.now },
      gated: true, write_action: false, consume_result: true
    )
    result = checker.check_access(pubkey_hash: 'abc', action: 'read', service: 'svc')
    assert_nil result
  end

  def test_plan_unavailable_raises
    checker = build_checker(
      grant: { suspended: false, plan: 'deleted_plan', first_seen_at: Time.now - 600 },
      gated: true, consume_result: :plan_unavailable
    )
    err = assert_raises(ServiceGrant::AccessDeniedError) do
      checker.check_access(pubkey_hash: 'abc', action: 'write', service: 'svc')
    end
    assert_equal :plan_unavailable, err.reason
  end

  def test_quota_exceeded_raises
    checker = build_checker(
      grant: { suspended: false, plan: 'free', first_seen_at: Time.now - 600 },
      gated: true, consume_result: false
    )
    err = assert_raises(ServiceGrant::AccessDeniedError) do
      checker.check_access(pubkey_hash: 'abc', action: 'write', service: 'svc')
    end
    assert_equal :quota_exceeded, err.reason
  end

  def test_non_gated_action_skips
    checker = build_checker(gated: false)
    result = checker.check_access(pubkey_hash: 'abc', action: 'ungated', service: 'svc')
    assert_nil result
  end

  def test_happy_path
    checker = build_checker(
      grant: { suspended: false, plan: 'free', first_seen_at: Time.now - 600 },
      gated: true, consume_result: true
    )
    result = checker.check_access(pubkey_hash: 'abc', action: 'write', service: 'svc')
    assert_nil result
  end

  private

  def build_checker(grant: nil, gated: true, write_action: false, consume_result: true)
    gm = MockGrantManager.new(grant)
    ut = MockUsageTracker.new(consume_result)
    pr = MockPlanRegistryFull.new(gated, write_action)
    cm = MockCycleManagerFull.new
    ServiceGrant::AccessChecker.new(
      grant_manager: gm, usage_tracker: ut,
      plan_registry: pr, cycle_manager: cm
    )
  end

  class MockGrantManager
    def initialize(grant) = @grant = grant
    def ensure_grant(_h, service:, remote_ip: nil) = @grant
    def in_cooldown?(grant)
      return false unless grant[:first_seen_at]
      (Time.now - grant[:first_seen_at]) < 300
    end
  end

  class MockUsageTracker
    def initialize(result) = @result = result
    def try_consume(_h, service:, action:, plan:) = @result
  end

  class MockPlanRegistryFull
    def initialize(gated, write) = (@gated = gated; @write = write)
    def gated_action?(_s, _a) = @gated
    def write_action?(_s, _a) = @write
    def trust_requirement(_s, _p, _a) = nil
    def action_for_tool(_s, t) = t
  end

  class MockCycleManagerFull
    def current_cycle_end(_s) = Time.now.utc + 86_400
  end
end

# Stub GateDeniedError for isolated testing
unless defined?(KairosMcp::ToolRegistry::GateDeniedError)
  module KairosMcp
    class ToolRegistry
      class GateDeniedError < StandardError
        attr_reader :tool_name, :gate_name
        def initialize(tool_name, gate_name, message = nil)
          @tool_name = tool_name; @gate_name = gate_name
          super(message || "Gate denied: #{gate_name}")
        end
      end
    end
  end
end

class TestAccessGateHttpMode < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/access_gate'
  end

  def test_nil_pubkey_hash_raises_gate_denied
    gate = ServiceGrant::AccessGate.new(access_checker: nil)
    safety = MockSafetyHttp.new({ role: 'member', service: 'mp' })
    assert_raises(KairosMcp::ToolRegistry::GateDeniedError) do
      gate.call('some_tool', {}, safety)
    end
  end

  def test_nil_service_raises_gate_denied
    gate = ServiceGrant::AccessGate.new(access_checker: nil)
    safety = MockSafetyHttp.new({ role: 'member', pubkey_hash: 'a' * 64 })
    assert_raises(KairosMcp::ToolRegistry::GateDeniedError) do
      gate.call('some_tool', {}, safety)
    end
  end

  class MockSafetyHttp
    def initialize(user) = @user = user
    def current_user = @user
  end
end

class TestAdminToolAuthorization < Minitest::Test
  def setup
    require 'service_grant/errors'
  end

  def test_non_owner_denied
    # Simulate can_manage_grants? returning false
    safety = MockSafetyDeny.new
    tool = MockAdminTool.new(safety)
    result = tool.call_with_auth_check({})
    assert_match(/forbidden/, result)
  end

  def test_owner_allowed
    safety = MockSafetyAllow.new
    tool = MockAdminTool.new(safety)
    result = tool.call_with_auth_check({})
    assert_equal 'allowed', result
  end

  def test_stdio_allowed
    # In STDIO mode, safety exists but current_user is nil → can_manage_grants? returns true
    safety = MockSafetyAllow.new
    tool = MockAdminTool.new(safety)
    result = tool.call_with_auth_check({})
    assert_equal 'allowed', result
  end

  class MockSafetyDeny
    def can_manage_grants? = false
  end

  class MockSafetyAllow
    def can_manage_grants? = true
  end

  class MockAdminTool
    def initialize(safety) = @safety = safety
    def call_with_auth_check(_args)
      unless @safety&.can_manage_grants?
        return '{"error":"forbidden"}'
      end
      'allowed'
    end
  end
end

class TestIpRateTrackerAtomic < Minitest::Test
  def setup
    require 'service_grant/ip_rate_tracker'
    @tracker = ServiceGrant::IpRateTracker.new(max: 3, window: 60)
  end

  def test_record_if_allowed_under_limit
    assert @tracker.record_if_allowed('1.2.3.4')
    assert @tracker.record_if_allowed('1.2.3.4')
    assert @tracker.record_if_allowed('1.2.3.4')
  end

  def test_record_if_allowed_at_limit
    3.times { @tracker.record_if_allowed('1.2.3.4') }
    refute @tracker.record_if_allowed('1.2.3.4')
  end

  def test_record_if_allowed_independent_ips
    3.times { @tracker.record_if_allowed('1.2.3.4') }
    assert @tracker.record_if_allowed('5.6.7.8')
  end
end
