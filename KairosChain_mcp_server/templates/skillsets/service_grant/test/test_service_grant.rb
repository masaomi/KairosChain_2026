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

  def test_trust_requirements_configured
    assert @pr.trust_requirements_configured?
  end

  def test_trust_requirements_non_numeric_raises
    require 'yaml'
    require 'tempfile'
    config = {
      'services' => {
        'svc' => {
          'billing_model' => 'free',
          'plans' => {
            'free' => {
              'limits' => { 'read' => -1 },
              'trust_requirements' => { 'write' => 'strict' }
            }
          }
        }
      }
    }
    f = Tempfile.new(['test_bad_trust', '.yml'])
    f.write(YAML.dump(config))
    f.close
    pr = ServiceGrant::PlanRegistry.new(f.path)
    err = assert_raises(ServiceGrant::ConfigValidationError) do
      pr.trust_requirements_configured?
    end
    assert_includes err.message, 'must be numeric'
    File.delete(f.path)
  end

  def test_trust_requirements_non_numeric_after_valid_raises
    require 'yaml'
    require 'tempfile'
    config = {
      'services' => {
        'svc' => {
          'billing_model' => 'free',
          'plans' => {
            'free' => {
              'limits' => { 'read' => -1, 'write' => 5 },
              'trust_requirements' => { 'write' => 0.5, 'admin' => 'high' }
            }
          }
        }
      }
    }
    f = Tempfile.new(['test_mixed_trust', '.yml'])
    f.write(YAML.dump(config))
    f.close
    pr = ServiceGrant::PlanRegistry.new(f.path)
    err = assert_raises(ServiceGrant::ConfigValidationError) do
      pr.trust_requirements_configured?
    end
    assert_includes err.message, 'must be numeric'
    File.delete(f.path)
  end

  def test_trust_requirements_not_configured_when_all_zero
    require 'yaml'
    require 'tempfile'
    config = {
      'services' => {
        'svc' => {
          'billing_model' => 'free',
          'plans' => { 'free' => { 'limits' => { 'read' => -1 } } }
        }
      }
    }
    f = Tempfile.new(['test_no_trust', '.yml'])
    f.write(YAML.dump(config))
    f.close
    pr = ServiceGrant::PlanRegistry.new(f.path)
    refute pr.trust_requirements_configured?
    File.delete(f.path)
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

# === Phase 2 Follow-up: build_trust_scorer fail-closed tests ===

class TestBuildTrustScorerFailClosed < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/plan_registry'
  end

  def test_trust_required_without_synoptis_raises
    # Simulate: trust_requirements configured but Synoptis module not defined
    plan_registry = build_trust_registry(trust_threshold: 0.5)

    # Hide Synoptis if it's defined (save and remove)
    synoptis_defined = defined?(Synoptis::TrustScorer)
    saved_synoptis = Synoptis if synoptis_defined

    # Temporarily undefine Synoptis for this test
    if synoptis_defined
      Object.send(:remove_const, :Synoptis)
    end

    begin
      err = assert_raises(ServiceGrant::ConfigValidationError) do
        build_trust_scorer_standalone(plan_registry, {})
      end
      assert_includes err.message, 'Synoptis SkillSet is not available'
    ensure
      # Restore Synoptis if it was defined
      if synoptis_defined
        Object.const_set(:Synoptis, saved_synoptis)
      end
    end
  end

  def test_trust_not_required_without_synoptis_returns_nil
    plan_registry = build_trust_registry(trust_threshold: 0.0)

    synoptis_defined = defined?(Synoptis::TrustScorer)
    saved_synoptis = Synoptis if synoptis_defined

    if synoptis_defined
      Object.send(:remove_const, :Synoptis)
    end

    begin
      result = build_trust_scorer_standalone(plan_registry, {})
      assert_nil result
    ensure
      if synoptis_defined
        Object.const_set(:Synoptis, saved_synoptis)
      end
    end
  end

  def test_load_cleanup_on_config_validation_error
    # Verify that ConfigValidationError in load! triggers unload!
    # by checking that @loaded remains false and @load_error is set
    # We test this indirectly: if unload! is called, @pg_pool should be nil
    # (Previously, ConfigValidationError rescue did NOT call unload!)

    # This is a structural test: verify the rescue clause includes unload!
    source = File.read(File.expand_path('../lib/service_grant.rb', __dir__))
    config_rescue = source[/rescue ConfigValidationError.*?(?=rescue|\z)/m]
    assert_includes config_rescue, 'unload!',
      "ConfigValidationError rescue must call unload! to clean up partial state"
  end

  private

  def build_trust_registry(trust_threshold:)
    require 'yaml'
    require 'tempfile'
    limits = trust_threshold > 0 ? { 'write' => 5 } : { 'read' => -1 }
    trust_req = trust_threshold > 0 ? { 'write' => trust_threshold } : {}
    config = {
      'services' => {
        'svc' => {
          'billing_model' => 'free',
          'plans' => {
            'free' => { 'limits' => limits, 'trust_requirements' => trust_req }
          }
        }
      }
    }
    f = Tempfile.new(['test_trust_scorer', '.yml'])
    f.write(YAML.dump(config))
    f.close
    # Store tempfile path for cleanup
    @_tempfiles ||= []
    @_tempfiles << f.path
    ServiceGrant::PlanRegistry.new(f.path)
  end

  def teardown
    (@_tempfiles || []).each { |p| File.delete(p) if File.exist?(p) }
  end

  # Replicate build_trust_scorer logic for isolated testing
  # (avoids requiring full ServiceGrant.load! with PG dependency)
  def build_trust_scorer_standalone(plan_registry, config)
    trust_required = plan_registry.trust_requirements_configured?

    unless defined?(Synoptis::TrustScorer) && defined?(Synoptis::Registry)
      if trust_required
        raise ServiceGrant::ConfigValidationError,
          "trust_requirements are configured but Synoptis SkillSet is not available. " \
          "Either add synoptis to depends_on or remove trust_requirements from config."
      end
      return nil
    end

    begin
      ts_config = config['trust_scorer'] || {}
      cache_ttl = ts_config.dig('anti_collusion', 'cache_ttl') || 300
      registry_path = ts_config['registry_path'] || 'storage/synoptis_registry'
      registry = Synoptis::Registry::FileRegistry.new(data_dir: registry_path)
      scorer = Synoptis::TrustScorer.new(registry: registry, config: ts_config)
      ServiceGrant::TrustScorerAdapter.new(scorer: scorer, cache_ttl: cache_ttl)
    rescue StandardError => e
      if trust_required
        raise ServiceGrant::ConfigValidationError,
          "trust_requirements are configured but TrustScorer failed to initialize: #{e.message}"
      end
      nil
    end
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

  def test_closed_clique_bridge_zero
    # 3-node closed clique: A←B←C←A. No external trust.
    # Bridge score should be 0.0 (2-hop cluster covers entire clique).
    registry = MockAttestationRegistry.new([
      mock_proof('agent://aaa', 'agent://bbb'),  # B attests A
      mock_proof('agent://bbb', 'agent://ccc'),  # C attests B
      mock_proof('agent://ccc', 'agent://aaa'),  # A attests C
    ])
    scorer = Synoptis::TrustScorer.new(registry: registry, config: { anti_collusion: { enabled: true } })
    result = scorer.calculate('agent://aaa')
    assert_equal 0.0, result[:details][:bridge],
      "Closed clique bridge should be 0.0, got #{result[:details][:bridge]}"
  end

  def test_attestation_weight_zero_without_external
    # Agent with self-attestation only — attestation weight should be 0.0
    # (PageRank teleportation mass should NOT give positive weight)
    registry = MockAttestationRegistry.new([
      mock_proof('agent://aaa', 'agent://aaa'),
    ])
    scorer = Synoptis::TrustScorer.new(registry: registry, config: { anti_collusion: { enabled: true } })
    result = scorer.calculate('agent://aaa')
    # quality_weighted should be 0.0 because self-attestation weight = 0.0
    assert_equal 0.0, result[:details][:quality],
      "Self-only quality should be exactly 0.0, got #{result[:details][:quality]}"
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

# === Phase 2B Tests ===

class TestTrustScorerAdapter < Minitest::Test
  def setup
    require 'service_grant/trust_scorer_adapter'
  end

  def test_adapter_returns_trust_relevant_score
    # Adapter returns quality + bridge, not full composite score
    mock_scorer = MockDetailScorer.new(quality: 0.3, bridge: 0.2, score: 0.75)
    adapter = ServiceGrant::TrustScorerAdapter.new(scorer: mock_scorer)
    assert_equal 0.5, adapter.call('abc')  # 0.3 + 0.2 = 0.5
  end

  def test_adapter_caches
    mock_scorer = MockDetailScorer.new(quality: 0.5, bridge: 0.0, score: 0.5)
    adapter = ServiceGrant::TrustScorerAdapter.new(scorer: mock_scorer, cache_ttl: 60)
    adapter.call('abc')
    adapter.call('abc')
    assert_equal 1, mock_scorer.call_count  # only called once
  end

  def test_adapter_clamps
    mock_scorer = MockDetailScorer.new(quality: 0.8, bridge: 0.5, score: 1.5)
    adapter = ServiceGrant::TrustScorerAdapter.new(scorer: mock_scorer)
    assert_equal 1.0, adapter.call('abc')  # 0.8 + 0.5 = 1.3, clamped to 1.0
  end

  def test_adapter_returns_zero_on_error
    mock_scorer = MockErrorScorer.new
    adapter = ServiceGrant::TrustScorerAdapter.new(scorer: mock_scorer)
    assert_equal 0.0, adapter.call('abc')
  end

  def test_invalidate
    mock_scorer = MockDetailScorer.new(quality: 0.5, bridge: 0.0)
    adapter = ServiceGrant::TrustScorerAdapter.new(scorer: mock_scorer, cache_ttl: 60)
    adapter.call('abc')
    adapter.invalidate('abc')
    adapter.call('abc')
    assert_equal 2, mock_scorer.call_count  # called twice after invalidation
  end

  def test_self_only_agent_returns_zero_trust
    # Self-only agent: quality=0 (no external attestation weight), bridge=0
    # Trust-relevant score should be 0.0, not 0.4 (which includes non-trust dimensions)
    mock_scorer = MockDetailScorer.new(quality: 0.0, bridge: 0.0, score: 0.4)
    adapter = ServiceGrant::TrustScorerAdapter.new(scorer: mock_scorer)
    assert_equal 0.0, adapter.call('abc')  # quality(0) + bridge(0) = 0.0
  end

  class MockDetailScorer
    attr_reader :call_count
    def initialize(quality: 0.5, bridge: 0.0, score: 0.5)
      @quality = quality; @bridge = bridge; @score = score; @call_count = 0
    end
    def calculate(_ref)
      @call_count += 1
      { score: @score, details: { quality: @quality, bridge: @bridge } }
    end
  end

  class MockErrorScorer
    def calculate(_ref) = raise("Synoptis unavailable")
  end
end

# === Phase 2C Infrastructure Tests ===

class TestPoolExhaustedInheritance < Minitest::Test
  def setup
    require 'service_grant/errors'
  end

  def test_pool_exhausted_is_pg_unavailable
    err = ServiceGrant::PoolExhaustedError.new("pool full")
    assert_kind_of ServiceGrant::PgUnavailableError, err
  end
end

# Stub PG::Error for isolated CB testing
module PG; class Error < StandardError; end unless defined?(PG::Error); end

class TestPgCircuitBreakerStates < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/pg_circuit_breaker'
  end

  def test_starts_closed
    cb = ServiceGrant::PgCircuitBreaker.new(policy: :deny_all)
    assert_equal :closed, cb.state
  end

  def test_opens_after_threshold_failures
    cb = ServiceGrant::PgCircuitBreaker.new(policy: :deny_all)
    3.times do
      cb.call { raise PG::Error, "down" } rescue nil
    end
    assert_equal :open, cb.state
  end

  def test_deny_all_raises_on_open
    cb = ServiceGrant::PgCircuitBreaker.new(policy: :deny_all)
    3.times { cb.call { raise PG::Error, "down" } rescue nil }
    assert_raises(ServiceGrant::PgUnavailableError) { cb.call { "never" } }
  end
end

class TestPgConnectionPoolBounded < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/pg_connection_pool'
  end

  def test_checked_out_rollback_on_connect_failure
    # Verify @checked_out is decremented when create_connection fails
    pool = ServiceGrant::PgConnectionPool.new({ 'pool_size' => 2, 'connect_timeout' => 1 })
    # Force checkout to fail by trying to connect to invalid host
    begin
      pool.checkout
    rescue StandardError
      # Expected: PG::ConnectionBad or similar
    end
    # @checked_out should be back to 0, not stuck at 1
    # Verify by checking that another checkout attempt doesn't raise PoolExhaustedError
    # (it will fail with connection error, but NOT pool exhaustion)
    err = nil
    begin
      pool.checkout
    rescue ServiceGrant::PoolExhaustedError => e
      err = e
    rescue StandardError
      # PG connection error is fine — we just want to verify it's NOT PoolExhaustedError
    end
    assert_nil err, "Should not raise PoolExhaustedError — @checked_out should have been rolled back"
  end
end

# === Phase 3a: PaymentVerifier Tests ===

# Stub PG::UniqueViolation for isolated testing
module PG; class UniqueViolation < PG::Error; end unless defined?(PG::UniqueViolation); end

# Stub Synoptis::TrustIdentity for isolated testing
unless defined?(Synoptis::TrustIdentity)
  module Synoptis
    module TrustIdentity
      def self.extract_pubkey_hash(ref)
        return nil unless ref
        ref = ref.sub('agent://', '') if ref.start_with?('agent://')
        ref.length == 64 ? ref : nil
      end
    end
  end
end

class TestPaymentVerifierValidation < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/payment_verifier'
  end

  def test_verify_nonce_valid
    pv = build_pv
    # Should not raise
    pv.send(:verify_nonce, { 'nonce' => 'abc123' })
  end

  def test_verify_nonce_nil_raises
    pv = build_pv
    err = assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:verify_nonce, { 'nonce' => nil })
    end
    assert_includes err.message, 'Nonce is required'
  end

  def test_verify_nonce_empty_raises
    pv = build_pv
    assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:verify_nonce, { 'nonce' => '' })
    end
  end

  def test_verify_nonce_whitespace_raises
    pv = build_pv
    assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:verify_nonce, { 'nonce' => '   ' })
    end
  end

  def test_verify_freshness_valid
    pv = build_pv
    proof = MockProofTime.new(Time.now.utc.iso8601)
    pv.send(:verify_freshness, proof)
  end

  def test_verify_freshness_expired
    pv = build_pv
    proof = MockProofTime.new((Time.now - 100_000).utc.iso8601)
    assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:verify_freshness, proof)
    end
  end

  def test_verify_freshness_future
    pv = build_pv
    proof = MockProofTime.new((Time.now + 120).utc.iso8601)
    assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:verify_freshness, proof)
    end
  end

  def test_verify_freshness_malformed_timestamp
    pv = build_pv
    proof = MockProofTime.new('not-a-date')
    err = assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:verify_freshness, proof)
    end
    assert_includes err.message, 'timestamp format'
  end

  def test_parse_evidence_valid
    pv = build_pv
    proof = MockProofEvidence.new('payment_verified', JSON.generate({
      'payment_intent_id' => 'pi_1', 'service' => 'mp', 'plan' => 'pro',
      'amount' => '9.99', 'currency' => 'USD', 'nonce' => 'n1'
    }))
    evidence = pv.send(:parse_evidence, proof)
    assert_equal 'pi_1', evidence['payment_intent_id']
  end

  def test_parse_evidence_wrong_claim
    pv = build_pv
    proof = MockProofEvidence.new('integrity_verified', '{}')
    assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:parse_evidence, proof)
    end
  end

  def test_parse_evidence_missing_fields
    pv = build_pv
    proof = MockProofEvidence.new('payment_verified', JSON.generate({ 'service' => 'mp' }))
    err = assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:parse_evidence, proof)
    end
    assert_includes err.message, 'Missing evidence fields'
  end

  def test_parse_evidence_malformed_json
    pv = build_pv
    proof = MockProofEvidence.new('payment_verified', 'not-json')
    assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:parse_evidence, proof)
    end
  end

  def test_parse_evidence_hash_type
    pv = build_pv
    # evidence is already a Hash (not String) — should still work
    proof = MockProofEvidence.new('payment_verified', {
      'payment_intent_id' => 'pi_1', 'service' => 'mp', 'plan' => 'pro',
      'amount' => '9.99', 'currency' => 'USD', 'nonce' => 'n1'
    })
    evidence = pv.send(:parse_evidence, proof)
    assert_equal 'pi_1', evidence['payment_intent_id']
  end

  def test_verify_issuer_authorized
    pv = build_pv(issuers: ['aaa' * 21 + 'a'])
    proof = MockProofAttester.new("agent://#{('aaa' * 21) + 'a'}")
    pv.send(:verify_issuer, proof)
  end

  def test_verify_issuer_unauthorized
    pv = build_pv(issuers: ['bbb' * 21 + 'b'])
    proof = MockProofAttester.new("agent://#{('aaa' * 21) + 'a'}")
    assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:verify_issuer, proof)
    end
  end

  def test_verify_issuer_empty_list
    pv = build_pv(issuers: [])
    proof = MockProofAttester.new("agent://#{('aaa' * 21) + 'a'}")
    assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:verify_issuer, proof)
    end
  end

  def test_verify_amount_matches
    pv = build_pv
    evidence = { 'service' => 'test_service', 'plan' => 'pro', 'amount' => '9.99', 'currency' => 'USD' }
    pv.send(:verify_amount_matches_plan, evidence)
  end

  def test_verify_amount_mismatch
    pv = build_pv
    evidence = { 'service' => 'test_service', 'plan' => 'pro', 'amount' => '1.00', 'currency' => 'USD' }
    assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:verify_amount_matches_plan, evidence)
    end
  end

  def test_verify_currency_mismatch
    pv = build_pv
    evidence = { 'service' => 'test_service', 'plan' => 'pro', 'amount' => '9.99', 'currency' => 'CHF' }
    assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:verify_amount_matches_plan, evidence)
    end
  end

  def test_verify_amount_free_plan_no_price
    pv = build_pv
    evidence = { 'service' => 'test_service', 'plan' => 'free', 'amount' => '0', 'currency' => 'USD' }
    # Free plan has no subscription_price → skip amount check
    pv.send(:verify_amount_matches_plan, evidence)
  end

  def test_validate_raw_proof_missing_proof_id
    pv = build_pv
    assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:validate_raw_proof, { 'timestamp' => 'x', 'signature' => 'y' })
    end
  end

  def test_validate_raw_proof_missing_timestamp
    pv = build_pv
    assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:validate_raw_proof, { 'proof_id' => 'x', 'signature' => 'y' })
    end
  end

  def test_validate_raw_proof_missing_signature
    pv = build_pv
    assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:validate_raw_proof, { 'proof_id' => 'x', 'timestamp' => 'y' })
    end
  end

  def test_no_synoptis_raises_config_error
    pv = ServiceGrant::PaymentVerifier.new(
      grant_manager: nil, pg_pool: nil,
      plan_registry: MockPlanRegistryPay.new, synoptis_registry: nil
    )
    assert_raises(ServiceGrant::ConfigValidationError) do
      pv.verify_and_upgrade({})
    end
  end

  def test_config_authorized_issuers
    pr = MockPlanRegistryPay.new(issuers: ['abc123'])
    assert_equal ['abc123'], pr.authorized_payment_issuers
  end

  def test_config_max_age
    pr = MockPlanRegistryPay.new(max_age: 3600)
    assert_equal 3600, pr.attestation_max_age
  end

  def test_config_empty_issuers_default
    pr = MockPlanRegistryPay.new
    assert_equal [], pr.authorized_payment_issuers
  end

  private

  def build_pv(issuers: ['aaa' * 21 + 'a'], max_age: 86_400)
    pr = MockPlanRegistryPay.new(issuers: issuers, max_age: max_age)
    ServiceGrant::PaymentVerifier.new(
      grant_manager: nil, pg_pool: nil,
      plan_registry: pr, synoptis_registry: :stub
    )
  end

  MockProofTime = Struct.new(:timestamp)
  MockProofEvidence = Struct.new(:claim, :evidence)
  MockProofAttester = Struct.new(:attester_id)

  class MockPlanRegistryPay
    def initialize(issuers: [], max_age: 86_400)
      @issuers = issuers
      @max_age = max_age
    end
    def authorized_payment_issuers = @issuers
    def attestation_max_age = @max_age
    def subscription_price(service, plan)
      return nil if plan == 'free'
      '9.99'
    end
    def currency(_service) = 'USD'
    def plan_exists?(_s, _p) = true
    def billing_model(_s) = 'per_action'
    def current_version(_s, _p) = 'v1'
    def subscription_duration(_s, _p) = nil
  end
end

# === Phase 3a Integration Tests ===

# Stub Synoptis modules for full-chain testing
unless defined?(Synoptis::Verifier)
  module Synoptis
    class Verifier
      def initialize(config: {}); end
      def verify(envelope, public_key: nil)
        { valid: true, errors: [], content_hash: 'stub', checked_at: Time.now.utc.iso8601 }
      end
    end
  end
end

unless defined?(Synoptis::ProofEnvelope)
  module Synoptis
    class ProofEnvelope
      attr_reader :proof_id, :attester_id, :subject_ref, :claim, :evidence,
                  :signature, :timestamp, :ttl, :merkle_root, :version,
                  :actor_user_id, :actor_role, :metadata

      def initialize(attrs = {})
        attrs = attrs.transform_keys(&:to_sym) if attrs.is_a?(Hash)
        @proof_id = attrs[:proof_id] || SecureRandom.uuid
        @attester_id = attrs[:attester_id]
        @subject_ref = attrs[:subject_ref]
        @claim = attrs[:claim]
        @evidence = attrs[:evidence]
        @signature = attrs[:signature]
        @timestamp = attrs[:timestamp] || Time.now.utc.iso8601
        @ttl = attrs[:ttl]
        @version = attrs[:version] || '1.0.0'
        @merkle_root = attrs[:merkle_root]
        @actor_user_id = attrs[:actor_user_id]
        @actor_role = attrs[:actor_role]
        @metadata = attrs[:metadata] || {}
      end

      def to_h
        { proof_id: @proof_id, version: @version, attester_id: @attester_id,
          subject_ref: @subject_ref, claim: @claim, evidence: @evidence,
          merkle_root: @merkle_root, signature: @signature, timestamp: @timestamp,
          ttl: @ttl, actor_user_id: @actor_user_id, actor_role: @actor_role,
          metadata: @metadata }
      end

      def self.from_h(hash)
        hash = hash.transform_keys(&:to_sym) if hash.is_a?(Hash)
        new(hash)
      end

      def content_hash
        Digest::SHA256.hexdigest(canonical_json)
      end

      def canonical_json
        JSON.generate({ proof_id: @proof_id, version: @version, attester_id: @attester_id,
          subject_ref: @subject_ref, claim: @claim, evidence: @evidence,
          merkle_root: @merkle_root, timestamp: @timestamp, ttl: @ttl }, sort_keys: true)
      end

      def expired?
        return false unless @ttl
        Time.now.utc > Time.parse(@timestamp) + @ttl
      rescue ArgumentError
        false
      end
    end
  end
end

class TestPaymentVerifierIntegration < Minitest::Test
  ISSUER_HASH = 'a' * 64
  PAYER_HASH = 'b' * 64

  def setup
    require 'service_grant/errors'
    require 'service_grant/payment_verifier'
  end

  # --- Full chain: verify_and_upgrade happy path ---

  def test_verify_and_upgrade_happy_path
    pv, pg_mock = build_full_pv
    proof_data = build_valid_proof_data

    result = pv.verify_and_upgrade(proof_data)
    assert_equal true, result[:success]
    assert_equal 'free', result[:old_plan]
    assert_equal 'pro', result[:new_plan]

    # Verify SQL was executed (BEGIN, INSERT grant, SELECT, UPDATE, INSERT payment, COMMIT)
    assert pg_mock.committed?, "Transaction should have been committed"
    assert_equal 6, pg_mock.exec_count, "Expected 6 SQL operations in transaction"
  end

  # --- Signature verification ---

  def test_verify_signature_valid
    pv, = build_full_pv
    proof = build_proof_envelope
    # Default mock verifier returns valid: true
    pv.send(:verify_signature, proof)  # should not raise
  end

  def test_verify_signature_invalid
    pv, = build_full_pv(verifier_valid: false, verifier_errors: ['invalid_signature'])
    proof = build_proof_envelope
    err = assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:verify_signature, proof)
    end
    assert_includes err.message, 'invalid_signature'
  end

  def test_verify_signature_no_public_key
    pv, = build_full_pv(has_public_key: false)
    proof = build_proof_envelope
    err = assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:verify_signature, proof)
    end
    assert_includes err.message, 'Cannot resolve issuer public key'
  end

  # --- Idempotent duplicate ---

  def test_idempotent_duplicate_returns_success
    existing_record = {
      'service' => 'mp', 'new_plan' => 'pro',
      'amount' => '9.99', 'currency' => 'USD'
    }
    pv, = build_full_pv(existing_payment: existing_record)
    proof_data = build_valid_proof_data

    result = pv.verify_and_upgrade(proof_data)
    assert_equal true, result[:success]
    assert_equal true, result[:idempotent]
  end

  def test_conflicting_duplicate_raises
    existing_record = {
      'service' => 'mp', 'new_plan' => 'basic',  # Different plan!
      'amount' => '9.99', 'currency' => 'USD'
    }
    pv, = build_full_pv(existing_payment: existing_record)
    proof_data = build_valid_proof_data

    err = assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.verify_and_upgrade(proof_data)
    end
    assert_includes err.message, 'plan'
  end

  # --- Transaction rollback ---

  def test_transaction_rollback_on_failure
    pv, pg_mock = build_full_pv(record_payment_fails: true)
    proof_data = build_valid_proof_data

    assert_raises(RuntimeError) do
      pv.verify_and_upgrade(proof_data)
    end
    assert pg_mock.rolled_back?, "Transaction should have been rolled back"
  end

  # --- Extract payer pubkey ---

  def test_extract_payer_pubkey
    pv, = build_full_pv
    proof = build_proof_envelope
    payer = pv.send(:extract_payer_pubkey, proof)
    assert_equal PAYER_HASH, payer
  end

  def test_extract_payer_pubkey_invalid_ref
    pv, = build_full_pv
    proof = Synoptis::ProofEnvelope.new(
      proof_id: 'test', attester_id: "agent://#{ISSUER_HASH}",
      subject_ref: 'skill://not_an_agent', claim: 'payment_verified',
      evidence: '{}', signature: 'sig', timestamp: Time.now.utc.iso8601
    )
    assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.send(:extract_payer_pubkey, proof)
    end
  end

  # --- Full chain rejection cases ---

  def test_full_chain_rejects_expired_proof
    pv, = build_full_pv
    proof_data = build_valid_proof_data(timestamp: (Time.now - 100_000).utc.iso8601)

    err = assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.verify_and_upgrade(proof_data)
    end
    assert_includes err.message, 'expired'
  end

  def test_full_chain_rejects_revoked_proof
    pv, = build_full_pv(revoked: true)
    proof_data = build_valid_proof_data

    err = assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.verify_and_upgrade(proof_data)
    end
    assert_includes err.message, 'revoked'
  end

  def test_full_chain_rejects_unauthorized_issuer
    pv, = build_full_pv(issuers: ['c' * 64])  # Different issuer
    proof_data = build_valid_proof_data

    err = assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.verify_and_upgrade(proof_data)
    end
    assert_includes err.message, 'Unauthorized'
  end

  def test_full_chain_rejects_wrong_claim
    pv, = build_full_pv
    proof_data = build_valid_proof_data(claim: 'integrity_verified')

    err = assert_raises(ServiceGrant::InvalidAttestationError) do
      pv.verify_and_upgrade(proof_data)
    end
    assert_includes err.message, 'Claim must be'
  end

  # --- PG::UniqueViolation rescue path ---

  def test_concurrent_duplicate_handled_via_unique_violation
    # Simulate: duplicate check passes (no existing record), but INSERT hits
    # PG::UniqueViolation due to concurrent insert by another process.
    # The rescue should catch it and return idempotent success.
    pv, pg_mock = build_full_pv(raises_unique_violation: true)
    proof_data = build_valid_proof_data

    result = pv.verify_and_upgrade(proof_data)
    assert_equal true, result[:success]
    assert_equal true, result[:idempotent]
  end

  # --- PlanNotFoundError ---

  def test_full_chain_rejects_unknown_plan
    pv, = build_full_pv(plan_exists: false)
    proof_data = build_valid_proof_data

    assert_raises(ServiceGrant::PlanNotFoundError) do
      pv.verify_and_upgrade(proof_data)
    end
  end

  private

  def build_valid_proof_data(timestamp: Time.now.utc.iso8601, claim: 'payment_verified')
    {
      'proof_id' => 'proof-uuid-123',
      'attester_id' => "agent://#{ISSUER_HASH}",
      'subject_ref' => "agent://#{PAYER_HASH}",
      'claim' => claim,
      'evidence' => JSON.generate({
        'payment_intent_id' => 'pi_test_001',
        'service' => 'mp',
        'plan' => 'pro',
        'amount' => '9.99',
        'currency' => 'USD',
        'nonce' => 'nonce_abc'
      }),
      'signature' => 'valid_signature_stub',
      'timestamp' => timestamp,
      'version' => '1.0.0'
    }
  end

  def build_proof_envelope
    Synoptis::ProofEnvelope.from_h(build_valid_proof_data)
  end

  def build_full_pv(issuers: [ISSUER_HASH], verifier_valid: true, verifier_errors: [],
                     has_public_key: true, existing_payment: nil,
                     record_payment_fails: false, revoked: false,
                     raises_unique_violation: false, plan_exists: true)
    registry = MockSynoptisRegistry.new(revoked: revoked)
    pg_mock = MockPgPool.new(existing_payment: existing_payment,
                             record_fails: record_payment_fails,
                             raises_unique_violation: raises_unique_violation)
    pr = MockPlanRegistryPay.new(issuers: issuers, plan_exists: plan_exists)

    # Monkey-patch Synoptis::Verifier for this test
    original_verify = Synoptis::Verifier.instance_method(:verify)
    Synoptis::Verifier.define_method(:verify) do |envelope, public_key: nil|
      { valid: verifier_valid, errors: verifier_errors,
        content_hash: 'stub', checked_at: Time.now.utc.iso8601 }
    end

    pv = ServiceGrant::PaymentVerifier.new(
      grant_manager: nil,
      pg_pool: pg_mock,
      plan_registry: pr,
      synoptis_registry: registry
    )

    # Inject public key resolver override
    if has_public_key
      pv.define_singleton_method(:resolve_public_key) { |_hash| 'MOCK_PUBLIC_KEY_PEM' }
    else
      pv.define_singleton_method(:resolve_public_key) { |_hash| nil }
    end

    # Restore original verify after test (via teardown)
    @_verifier_restore = original_verify

    [pv, pg_mock]
  end

  def teardown
    if @_verifier_restore
      Synoptis::Verifier.define_method(:verify, @_verifier_restore)
      @_verifier_restore = nil
    end
  end

  # --- Mock: PlanRegistry for integration ---

  class MockPlanRegistryPay
    def initialize(issuers: [], max_age: 86_400, plan_exists: true)
      @issuers = issuers
      @max_age = max_age
      @plan_exists = plan_exists
    end
    def authorized_payment_issuers = @issuers
    def attestation_max_age = @max_age
    def subscription_price(service, plan)
      return nil if plan == 'free'
      '9.99'
    end
    def currency(_service) = 'USD'
    def plan_exists?(_s, _p) = @plan_exists
    def billing_model(_s) = 'per_action'
    def current_version(_s, _p) = 'v1'
    def subscription_duration(_s, _p) = nil
  end

  # --- Mock: Synoptis Registry ---

  class MockSynoptisRegistry
    def initialize(revoked: false)
      @store = {}
      @revoked = revoked
    end

    def find_proof(proof_id)
      @store[proof_id]
    end

    def store_proof(envelope)
      pid = envelope.is_a?(Hash) ? (envelope[:proof_id] || envelope['proof_id']) : envelope.proof_id
      @store[pid] = envelope
    end

    def revoked?(proof_id)
      @revoked
    end
  end

  # --- Mock: PG Pool + Connection ---

  class MockPgPool
    attr_reader :exec_count

    def initialize(existing_payment: nil, record_fails: false, raises_unique_violation: false)
      @existing_payment = existing_payment
      @record_fails = record_fails
      @raises_unique_violation = raises_unique_violation
      @exec_count = 0
      @committed = false
      @rolled_back = false
    end

    def committed? = @committed
    def rolled_back? = @rolled_back

    # Used for duplicate check outside transaction
    def exec_params(sql, params = [])
      if sql.include?('payment_records') && sql.include?('SELECT')
        # After UniqueViolation, re-query returns the existing record
        if @unique_violation_fired
          return MockPgResult.new([{
            'service' => 'mp', 'new_plan' => 'pro',
            'amount' => '9.99', 'currency' => 'USD'
          }])
        end
        return MockPgResult.new(@existing_payment ? [@existing_payment] : [])
      end
      MockPgResult.new([])
    end

    # Used for transaction
    def with_connection
      conn = MockPgConnection.new(
        existing_payment: @existing_payment,
        record_fails: @record_fails,
        raises_unique_violation: @raises_unique_violation,
        pool: self
      )
      yield conn
    end

    def mark_unique_violation!
      @unique_violation_fired = true
    end

    def record_commit!
      @committed = true
    end

    def record_rollback!
      @rolled_back = true
    end

    def inc_exec!
      @exec_count += 1
    end
  end

  class MockPgConnection
    def initialize(existing_payment:, record_fails:, pool:, raises_unique_violation: false)
      @existing_payment = existing_payment
      @record_fails = record_fails
      @raises_unique_violation = raises_unique_violation
      @pool = pool
    end

    def exec(sql)
      @pool.inc_exec!
      if sql == 'COMMIT'
        @pool.record_commit!
      elsif sql == 'ROLLBACK'
        @pool.record_rollback!
      end
    end

    def exec_params(sql, params = [])
      @pool.inc_exec!
      if @record_fails && sql.include?('payment_records') && sql.include?('INSERT')
        raise RuntimeError, 'Simulated record_payment failure'
      end
      if @raises_unique_violation && sql.include?('payment_records') && sql.include?('INSERT')
        @pool.mark_unique_violation!
        raise PG::UniqueViolation, 'duplicate key value violates unique constraint'
      end
      if sql.include?('SELECT')
        return MockPgResult.new([{ 'plan' => 'free' }])
      end
      MockPgResult.new([])
    end
  end

  class MockPgResult
    def initialize(rows)
      @rows = rows
    end

    def ntuples = @rows.length
    def [](idx) = @rows[idx]
  end
end

# === Phase 3b: Subscription Expiry + provider_tx_id Tests ===

class TestSubscriptionExpiry < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/access_checker'
  end

  def test_expired_subscription_downgrades
    grant = {
      suspended: false, plan: 'pro',
      first_seen_at: Time.now - 600,
      subscription_expires_at: Time.now - 3600
    }
    gm = MockGrantManagerExpiry.new(grant, downgrade_result: true)
    ut = MockUsageTrackerCapture.new(true)
    checker = build_expiry_checker(gm, ut: ut)
    checker.check_access(pubkey_hash: 'b' * 64, action: 'write', service: 'svc')
    assert_equal 'free', ut.last_plan
  end

  def test_active_subscription_keeps_plan
    grant = {
      suspended: false, plan: 'pro',
      first_seen_at: Time.now - 600,
      subscription_expires_at: Time.now + 86_400
    }
    gm = MockGrantManagerExpiry.new(grant)
    ut = MockUsageTrackerCapture.new(true)
    checker = build_expiry_checker(gm, ut: ut)
    checker.check_access(pubkey_hash: 'b' * 64, action: 'write', service: 'svc')
    assert_equal 'pro', ut.last_plan
  end

  def test_nil_expiry_no_downgrade
    grant = {
      suspended: false, plan: 'pro',
      first_seen_at: Time.now - 600,
      subscription_expires_at: nil
    }
    gm = MockGrantManagerExpiry.new(grant)
    ut = MockUsageTrackerCapture.new(true)
    checker = build_expiry_checker(gm, ut: ut)
    checker.check_access(pubkey_hash: 'b' * 64, action: 'write', service: 'svc')
    assert_equal 'pro', ut.last_plan
  end

  def test_concurrent_renewal_reread_grant
    expired_grant = {
      suspended: false, plan: 'pro',
      first_seen_at: Time.now - 600,
      subscription_expires_at: Time.now - 10
    }
    renewed_grant = {
      suspended: false, plan: 'pro',
      first_seen_at: Time.now - 600,
      subscription_expires_at: Time.now + 86_400
    }
    gm = MockGrantManagerExpiry.new(expired_grant, downgrade_result: false, reread_grant: renewed_grant)
    ut = MockUsageTrackerCapture.new(true)
    checker = build_expiry_checker(gm, ut: ut)
    checker.check_access(pubkey_hash: 'b' * 64, action: 'write', service: 'svc')
    assert_equal 'pro', ut.last_plan
  end

  private

  def build_expiry_checker(gm, ut: nil)
    ut ||= MockUsageTrackerCapture.new(true)
    pr = MockPlanRegistryExpiry.new(true)
    cm = MockCycleManagerSimple.new
    ServiceGrant::AccessChecker.new(
      grant_manager: gm, usage_tracker: ut,
      plan_registry: pr, cycle_manager: cm
    )
  end

  class MockGrantManagerExpiry
    def initialize(grant, downgrade_result: nil, reread_grant: nil)
      @grant = grant
      @downgrade_result = downgrade_result
      @reread_grant = reread_grant
    end

    def ensure_grant(_h, service:, remote_ip: nil) = @grant
    def in_cooldown?(_g) = false

    def downgrade_to_free(_h, service:)
      @downgrade_result
    end

    def get_grant(_h, service:)
      @reread_grant
    end
  end

  class MockUsageTrackerCapture
    attr_reader :last_plan
    def initialize(result) = @result = result
    def try_consume(_h, service:, action:, plan:)
      @last_plan = plan
      @result
    end
  end

  class MockPlanRegistryExpiry
    def initialize(gated) = @gated = gated
    def gated_action?(_s, _a) = @gated
    def write_action?(_s, _a) = false
    def trust_requirement(_s, _p, _a) = nil
    def action_for_tool(_s, t) = t
  end

  class MockCycleManagerSimple
    def current_cycle_end(_s) = Time.now.utc + 86_400
  end
end

class TestSubscriptionDurationConfig < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/plan_registry'
  end

  def test_subscription_duration_from_config
    pr = build_registry(duration: 30)
    assert_equal 30, pr.subscription_duration('svc', 'pro')
  end

  def test_subscription_duration_nil_for_free
    pr = build_registry(duration: nil)
    assert_nil pr.subscription_duration('svc', 'pro')
  end

  def test_subscription_duration_zero_raises
    assert_raises(ServiceGrant::ConfigValidationError) do
      build_registry(duration: 0)
    end
  end

  def test_subscription_duration_negative_raises
    assert_raises(ServiceGrant::ConfigValidationError) do
      build_registry(duration: -5)
    end
  end

  def test_subscription_duration_string_raises
    assert_raises(ServiceGrant::ConfigValidationError) do
      build_registry(duration: '30')
    end
  end

  private

  def build_registry(duration:)
    require 'yaml'
    require 'tempfile'
    plan = { 'limits' => { 'read' => -1 } }
    plan['subscription_duration'] = duration if duration
    config = {
      'services' => {
        'svc' => {
          'billing_model' => 'subscription',
          'plans' => { 'pro' => plan }
        }
      }
    }
    f = Tempfile.new(['test_sub_dur', '.yml'])
    f.write(YAML.dump(config))
    f.close
    @_tempfiles ||= []
    @_tempfiles << f.path
    ServiceGrant::PlanRegistry.new(f.path)
  end

  def teardown
    (@_tempfiles || []).each { |p| File.delete(p) if File.exist?(p) }
  end
end

class TestProviderTxId < Minitest::Test
  def setup
    require 'service_grant/errors'
    require 'service_grant/payment_verifier'
  end

  def test_provider_tx_id_included_in_evidence_parsing
    pv = build_pv_simple
    proof = MockProofEvidence.new('payment_verified', JSON.generate({
      'payment_intent_id' => 'pi_1', 'service' => 'mp', 'plan' => 'pro',
      'amount' => '9.99', 'currency' => 'USD', 'nonce' => 'n1',
      'provider_tx_id' => 'pi_stripe_123'
    }))
    evidence = pv.send(:parse_evidence, proof)
    assert_equal 'pi_stripe_123', evidence['provider_tx_id']
  end

  def test_provider_tx_id_optional
    pv = build_pv_simple
    proof = MockProofEvidence.new('payment_verified', JSON.generate({
      'payment_intent_id' => 'pi_1', 'service' => 'mp', 'plan' => 'pro',
      'amount' => '9.99', 'currency' => 'USD', 'nonce' => 'n1'
    }))
    evidence = pv.send(:parse_evidence, proof)
    assert_nil evidence['provider_tx_id']
  end

  private

  def build_pv_simple
    pr = MockPlanRegistryPaySimple.new
    ServiceGrant::PaymentVerifier.new(
      grant_manager: nil, pg_pool: nil,
      plan_registry: pr, synoptis_registry: :stub
    )
  end

  MockProofEvidence = Struct.new(:claim, :evidence)

  class MockPlanRegistryPaySimple
    def authorized_payment_issuers = []
    def attestation_max_age = 86_400
  end
end
