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
    require 'service_grant/ip_rate_tracker'
    require 'service_grant/grant_manager'
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

# === Phase 2A Tests ===

class TestPlaceMiddlewareErrorMapping < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/place_middleware'
  end

  def test_rate_limit_error_returns_429
    store = MockSessionStoreToken.new('abcd' * 16)
    checker = MockRateLimitChecker.new
    mw = ServiceGrant::PlaceMiddleware.new(access_checker: checker, session_store: store)
    result = mw.check(peer_id: 'p1', action: 'write', service: 'mp')
    assert_equal 429, result[:status]
    assert_equal 'rate_limited', result[:error]
  end

  def test_pg_unavailable_returns_503
    store = MockSessionStoreToken.new('abcd' * 16)
    checker = MockPgDownChecker.new
    mw = ServiceGrant::PlaceMiddleware.new(access_checker: checker, session_store: store)
    result = mw.check(peer_id: 'p1', action: 'write', service: 'mp')
    assert_equal 503, result[:status]
    assert_equal 'service_unavailable', result[:error]
  end

  def test_token_based_pubkey_resolution
    store = MockSessionStoreToken.new('abcd' * 16)
    checker = MockPassCheckerFull.new
    mw = ServiceGrant::PlaceMiddleware.new(access_checker: checker, session_store: store)
    result = mw.check(peer_id: 'p1', action: 'browse', service: 'mp', auth_token: 'tok123')
    assert_nil result  # allowed
  end

  def test_remote_ip_forwarded_to_checker
    store = MockSessionStoreToken.new('abcd' * 16)
    checker = MockIpCapturingChecker.new
    mw = ServiceGrant::PlaceMiddleware.new(access_checker: checker, session_store: store)
    mw.check(peer_id: 'p1', action: 'browse', service: 'mp', remote_ip: '10.0.0.1')
    assert_equal '10.0.0.1', checker.last_remote_ip
  end

  class MockSessionStoreToken
    def initialize(hash) = @hash = hash
    def pubkey_hash_for(_peer_id) = @hash
    def pubkey_hash_for_token(_token) = @hash
  end

  class MockPassCheckerFull
    def check_access(**_kwargs) = nil
  end

  class MockRateLimitChecker
    def check_access(**_kwargs)
      raise ServiceGrant::RateLimitError, "Too many"
    end
  end

  class MockPgDownChecker
    def check_access(**_kwargs)
      raise ServiceGrant::PgUnavailableError, "PG down"
    end
  end

  class MockIpCapturingChecker
    attr_reader :last_remote_ip
    def check_access(**kwargs)
      @last_remote_ip = kwargs[:remote_ip]
      nil
    end
  end
end

class TestAccessCheckerInsufficientTrust < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/access_checker'
  end

  def test_insufficient_trust_raises
    trust_scorer = ->(pubkey_hash) { 0.05 }
    gm = MockGrantManagerTrust.new
    ut = MockUsageTrackerTrust.new
    pr = MockPlanRegistryTrust.new
    cm = MockCycleManagerTrust.new
    checker = ServiceGrant::AccessChecker.new(
      grant_manager: gm, usage_tracker: ut,
      plan_registry: pr, cycle_manager: cm,
      trust_scorer: trust_scorer
    )
    err = assert_raises(ServiceGrant::AccessDeniedError) do
      checker.check_access(pubkey_hash: 'abc', action: 'write', service: 'svc')
    end
    assert_equal :insufficient_trust, err.reason
  end

  class MockGrantManagerTrust
    def ensure_grant(_h, service:, remote_ip: nil)
      { suspended: false, plan: 'free', first_seen_at: Time.now - 600 }
    end
    def in_cooldown?(_g) = false
  end

  class MockUsageTrackerTrust
    def try_consume(_h, service:, action:, plan:) = true
  end

  class MockPlanRegistryTrust
    def gated_action?(_s, _a) = true
    def write_action?(_s, _a) = false
    def trust_requirement(_s, _p, _a) = 0.1
    def action_for_tool(_s, t) = t
  end

  class MockCycleManagerTrust
    def current_cycle_end(_s) = Time.now.utc + 86_400
  end
end

class TestClientIpResolver < Minitest::Test
  def setup
    require 'service_grant/client_ip_resolver'
  end

  def test_prefers_x_real_ip
    resolver = ServiceGrant::ClientIpResolver.new
    env = { 'HTTP_X_REAL_IP' => '1.2.3.4', 'REMOTE_ADDR' => '10.0.0.1' }
    assert_equal '1.2.3.4', resolver.resolve(env)
  end

  def test_falls_back_to_remote_addr
    resolver = ServiceGrant::ClientIpResolver.new
    env = { 'REMOTE_ADDR' => '10.0.0.1' }
    assert_equal '10.0.0.1', resolver.resolve(env)
  end

  def test_custom_header
    resolver = ServiceGrant::ClientIpResolver.new('header' => 'X-Forwarded-For')
    env = { 'HTTP_X_FORWARDED_FOR' => '5.5.5.5', 'REMOTE_ADDR' => '10.0.0.1' }
    assert_equal '5.5.5.5', resolver.resolve(env)
  end

  def test_nil_env_values
    resolver = ServiceGrant::ClientIpResolver.new
    env = {}
    assert_nil resolver.resolve(env)
  end
end

class TestExtractRouteSegment < Minitest::Test
  def test_simple_route
    assert_equal 'deposit', extract('/place/v1/deposit')
  end

  def test_nested_route
    assert_equal 'browse', extract('/place/v1/board/browse')
  end

  def test_parameterized_keys
    assert_equal 'keys', extract('/place/v1/keys/agent-xyz-123')
  end

  def test_parameterized_skill_content
    assert_equal 'skill_content', extract('/place/v1/skill_content/sk-456')
  end

  def test_agents
    assert_equal 'agents', extract('/place/v1/agents')
  end

  private

  def extract(path)
    # Replicate PlaceRouter#extract_route_segment logic
    route_action_map = {
      'deposit' => 'deposit_skill', 'browse' => 'browse',
      'skill_content' => 'browse', 'needs' => 'browse',
      'agents' => 'browse', 'keys' => 'browse',
      'acquire' => 'acquire_skill', 'unregister' => 'unregister'
    }
    segments = path.sub('/place/v1/', '').split('/')
    candidate = segments.last || ''
    route_action_map.key?(candidate) ? candidate : (segments.first || '')
  end
end

# === Phase 2A-back Tests ===

class TestTrustIdentity < Minitest::Test
  def setup
    synoptis_lib = File.expand_path('../../synoptis/lib', __dir__)
    $LOAD_PATH.unshift(synoptis_lib) unless $LOAD_PATH.include?(synoptis_lib)
    require 'synoptis/trust_identity'
  end

  def test_canonical
    assert_equal 'agent://abc123', Synoptis::TrustIdentity.canonical('abc123')
  end

  def test_canonical_already_prefixed
    assert_equal 'agent://abc123', Synoptis::TrustIdentity.canonical('agent://abc123')
  end

  def test_extract_pubkey_hash
    assert_equal 'abc123', Synoptis::TrustIdentity.extract_pubkey_hash('agent://abc123')
  end

  def test_extract_raw_hash_legacy
    hash64 = 'a' * 64
    assert_equal hash64, Synoptis::TrustIdentity.extract_pubkey_hash(hash64)
  end

  def test_extract_non_agent_returns_nil
    assert_nil Synoptis::TrustIdentity.extract_pubkey_hash('short_string')
    assert_nil Synoptis::TrustIdentity.extract_pubkey_hash('skill://genomics')
  end

  def test_normalize
    hash64 = 'a' * 64
    assert_equal "agent://#{hash64}", Synoptis::TrustIdentity.normalize(hash64)
    assert_equal "agent://#{hash64}", Synoptis::TrustIdentity.normalize("agent://#{hash64}")
  end

  def test_nil_handling
    assert_nil Synoptis::TrustIdentity.canonical(nil)
    assert_nil Synoptis::TrustIdentity.extract_pubkey_hash(nil)
  end

  def test_non_agent_ref_unchanged
    # Non-agent refs (skill://, knowledge/*, etc.) must NOT be normalized to agent://
    assert_equal 'skill://genomics_pipeline', Synoptis::TrustIdentity.normalize('skill://genomics_pipeline')
    assert_equal 'knowledge/test_skill', Synoptis::TrustIdentity.normalize('knowledge/test_skill')
    assert_equal 'place://meeting1', Synoptis::TrustIdentity.normalize('place://meeting1')
  end

  def test_agent_ref_detected
    hash64 = 'a' * 64
    assert Synoptis::TrustIdentity.agent_ref?(hash64)
    assert Synoptis::TrustIdentity.agent_ref?("agent://#{hash64}")
    refute Synoptis::TrustIdentity.agent_ref?('skill://genomics')
    refute Synoptis::TrustIdentity.agent_ref?('short_hash')
  end
end

class TestTrustScorerAntiCollusion < Minitest::Test
  def setup
    synoptis_lib = File.expand_path('../../synoptis/lib', __dir__)
    $LOAD_PATH.unshift(synoptis_lib) unless $LOAD_PATH.include?(synoptis_lib)
    require 'set'
    require 'synoptis/trust_identity'
    require 'synoptis/trust_scorer'
  end

  def test_pure_cartel_quality_near_zero
    # 3 agents in a closed clique: A attests B, B attests C, C attests A
    # No external attestation → attestation weight = 0.0 → quality_weighted ≈ 0
    # Other dimensions (freshness, diversity, velocity) still contribute,
    # so overall score won't be zero, but quality should be near zero.
    registry = MockAttestationRegistry.new([
      mock_proof('agent://aaa', 'agent://bbb'),
      mock_proof('agent://bbb', 'agent://ccc'),
      mock_proof('agent://ccc', 'agent://aaa'),
    ])
    scorer = Synoptis::TrustScorer.new(registry: registry, config: { anti_collusion: { enabled: true } })
    result = scorer.calculate('agent://aaa')
    # Quality dimension should be near 0 (attestation from zero-weight attesters)
    assert result[:details][:quality] < 0.05, "Cartel quality should be near 0, got #{result[:details][:quality]}"
  end

  def test_agent_with_external_attestation_scores_higher
    # A has attestation from B (internal) and X (external with own external sources)
    registry = MockAttestationRegistry.new([
      mock_proof('agent://aaa', 'agent://bbb'),  # B attests A
      mock_proof('agent://aaa', 'agent://xxx'),  # X attests A
      mock_proof('agent://xxx', 'agent://yyy'),  # Y attests X (X has external source)
    ])
    scorer = Synoptis::TrustScorer.new(registry: registry, config: { anti_collusion: { enabled: true } })
    result_a = scorer.calculate('agent://aaa')
    # A should have non-zero bridge score because X has external trust
    assert result_a[:details][:bridge] > 0.0, "Bridge score should be positive with external attester"
  end

  def test_bootstrap_policy_floor
    # Single agent with one self-attestation, no external
    registry = MockAttestationRegistry.new([
      mock_proof('agent://aaa', 'agent://aaa'),  # self-attestation
    ])
    scorer = Synoptis::TrustScorer.new(registry: registry, config: { anti_collusion: { enabled: true } })
    result = scorer.calculate('agent://aaa')
    # Self-attestation only → quality_weighted should use floor = 0.0 (no external)
    # Bridge score = 0.0 (no attesters with external sources)
    assert result[:details][:quality] < 0.05, "Self-only quality should be near 0, got #{result[:details][:quality]}"
    assert_equal 0.0, result[:details][:bridge]
  end

  def test_revoked_proofs_excluded_from_graph
    registry = MockAttestationRegistry.new(
      [mock_proof('agent://aaa', 'agent://bbb', proof_id: 'p1')],
      revoked: ['p1']
    )
    scorer = Synoptis::TrustScorer.new(registry: registry, config: { anti_collusion: { enabled: true } })
    result = scorer.calculate('agent://aaa')
    assert_equal 0, result[:active_count]
    assert_equal 0.0, result[:score]
  end

  private

  def mock_proof(subject, attester, proof_id: nil)
    MockProof.new(
      subject_ref: subject, attester_id: attester,
      proof_id: proof_id || "proof_#{rand(100000)}",
      timestamp: Time.now.utc.iso8601
    )
  end

  MockProof = Struct.new(:subject_ref, :attester_id, :proof_id, :timestamp,
                          :evidence, :merkle_root, :signature, :actor_role,
                          keyword_init: true) do
    def expired? = false
  end

  class MockAttestationRegistry
    def initialize(proofs, revoked: [])
      @proofs = proofs
      @revoked = Set.new(revoked)
    end

    def list_proofs(filter: {})
      result = @proofs.dup
      result = result.select { |p| p.subject_ref == filter[:subject_ref] } if filter[:subject_ref]
      result = result.select { |p| p.attester_id == filter[:attester_ref] } if filter[:attester_ref]
      result
    end

    def revoked?(proof_id)
      @revoked.include?(proof_id)
    end
  end
end
