# frozen_string_literal: true

# Phase 1 Step 1.3 tests — AttachAuth + NonceCache
# (24/7 v0.4 §2.6 + §12 backlog B2/B10 + R5 rerun TOCTOU/thread-safety).

require 'minitest/autorun'

ROOT = File.expand_path('../../../../..', __dir__)
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'daemon_runtime/attach_auth'

DR = KairosMcp::SkillSets::DaemonRuntime

class TestNonceCache < Minitest::Test
  def setup
    @now = Time.at(1_000_000)
    @cache = DR::NonceCache.new(clock: -> { @now })
  end

  def test_fresh_nonce_recorded
    assert @cache.check_and_record('n1', ttl: 60)
    assert @cache.seen?('n1')
  end

  def test_replay_rejected
    @cache.check_and_record('n1', ttl: 60)
    refute @cache.check_and_record('n1', ttl: 60)
  end

  def test_expired_nonce_can_be_reused
    @cache.check_and_record('n1', ttl: 60)
    @now += 120
    assert @cache.check_and_record('n1', ttl: 60),
           'expired nonce must be accepted as fresh'
  end

  def test_seen_returns_false_for_expired
    @cache.check_and_record('n1', ttl: 60)
    @now += 120
    refute @cache.seen?('n1')
  end

  def test_cap_evicts_oldest
    cache = DR::NonceCache.new(max_entries: 3, clock: -> { @now })
    %w[a b c d e].each { |n| cache.check_and_record(n, ttl: 3600) }
    assert_equal 3, cache.size
    refute cache.seen?('a')
    refute cache.seen?('b')
    assert cache.seen?('c')
    assert cache.seen?('e')
  end

  def test_check_and_record_is_atomic_under_threads
    cache = DR::NonceCache.new
    successes = Array.new(50) do
      Thread.new { cache.check_and_record('shared', ttl: 60) }
    end.map(&:value)
    assert_equal 1, successes.count(true),
                 'exactly one thread must win the atomic check-and-record'
  end
end

class TestCanonicalRequest < Minitest::Test
  def base_args
    { method: 'POST', path: '/attach', body: 'hello',
      timestamp: '1000000', nonce: 'abc' }
  end

  def test_builds_nul_delimited_payload_with_length_prefix
    bytes = DR::AttachAuth.canonical_request(**base_args)
    parts = bytes.split("\x00".b)
    assert_equal 'POST', parts[0]
    assert_equal '/attach', parts[1]
    assert_equal '1000000', parts[2]
    assert_equal 'abc', parts[3]
    assert_equal '5', parts[4]  # length prefix of body 'hello'
    assert_equal 'hello', parts[5]
  end

  def test_boundary_collision_prevented
    # POST + /foo + body 'bar' vs POST + /fooba + body 'r' — pre-delimiter
    # implementations collided. Now they must hash differently because the
    # length prefix and NUL boundaries shift.
    a = DR::AttachAuth.canonical_request(method: 'POST', path: '/foo',
                                         body: 'bar', timestamp: '1', nonce: 'n')
    b = DR::AttachAuth.canonical_request(method: 'POST', path: '/fooba',
                                         body: 'r', timestamp: '1', nonce: 'n')
    refute_equal a, b
  end

  def test_binary_body_with_nul_does_not_forge_boundary
    # Body contains NUL; length prefix makes parsing unambiguous so the
    # attacker cannot fake a trailing field.
    a = DR::AttachAuth.canonical_request(method: 'POST', path: '/x',
                                         body: "ab\x00cd", timestamp: '1', nonce: 'n')
    b = DR::AttachAuth.canonical_request(method: 'POST', path: '/x',
                                         body: 'abcd', timestamp: '1', nonce: 'n')
    refute_equal a, b
  end

  def test_nul_in_method_raises_autherror_not_runtimeerror
    # B10: must be AuthError (401 path), never RuntimeError (500).
    err = assert_raises(DR::AuthError) do
      DR::AttachAuth.canonical_request(method: "GE\x00T", path: '/', body: '',
                                       timestamp: '1', nonce: 'n')
    end
    assert_equal 'malformed', err.code
  end

  def test_nul_in_path_raises_autherror
    assert_raises(DR::AuthError) do
      DR::AttachAuth.canonical_request(method: 'GET', path: "/x\x00y", body: '',
                                       timestamp: '1', nonce: 'n')
    end
  end

  def test_nul_in_nonce_raises_autherror
    assert_raises(DR::AuthError) do
      DR::AttachAuth.canonical_request(method: 'GET', path: '/', body: '',
                                       timestamp: '1', nonce: "n\x00x")
    end
  end
end

class TestVerify < Minitest::Test
  SECRET = 'test-secret'

  def setup
    @now = Time.at(1_700_000_000)
    @cache = DR::NonceCache.new(clock: -> { @now })
  end

  def signed(overrides = {})
    args = { method: 'POST', path: '/attach', body: 'hi',
             timestamp: @now.to_i.to_s, nonce: 'nonce-123' }.merge(overrides)
    mac = DR::AttachAuth.sign(SECRET, **args)
    [args, mac]
  end

  def test_valid_request_verifies
    args, mac = signed
    assert DR::AttachAuth.verify!(SECRET, header_mac: mac, nonce_cache: @cache,
                                  now: @now, **args)
  end

  def test_replay_detected_after_successful_verify
    args, mac = signed
    DR::AttachAuth.verify!(SECRET, header_mac: mac, nonce_cache: @cache,
                           now: @now, **args)
    err = assert_raises(DR::AuthError) do
      DR::AttachAuth.verify!(SECRET, header_mac: mac, nonce_cache: @cache,
                             now: @now, **args)
    end
    assert_equal 'nonce_replay', err.code
  end

  def test_bad_mac_does_not_poison_nonce_cache
    # R5 P1 (Codex): nonce recorded before HMAC verification let
    # unauthenticated requests poison the cache. Must NOT happen now.
    args, _mac = signed
    bad_mac = '0' * 64

    assert_raises(DR::AuthError) do
      DR::AttachAuth.verify!(SECRET, header_mac: bad_mac, nonce_cache: @cache,
                             now: @now, **args)
    end
    refute @cache.seen?(args[:nonce]),
           'nonce cache must not be touched when HMAC fails'

    # A legit caller with the same nonce must still succeed afterwards.
    good_mac = DR::AttachAuth.sign(SECRET, **args)
    assert DR::AttachAuth.verify!(SECRET, header_mac: good_mac, nonce_cache: @cache,
                                  now: @now, **args)
  end

  def test_timestamp_skew_rejected
    args, mac = signed(timestamp: (@now.to_i - 120).to_s)
    err = assert_raises(DR::AuthError) do
      DR::AttachAuth.verify!(SECRET, header_mac: mac, nonce_cache: @cache,
                             now: @now, **args)
    end
    assert_equal 'timestamp_skew', err.code
  end

  def test_non_integer_timestamp_raises_autherror_not_argumenterror
    # B2: bare ArgumentError would escape as 500. Must be AuthError.
    args = { method: 'POST', path: '/x', body: '', timestamp: 'not-a-number',
             nonce: 'n' }
    err = assert_raises(DR::AuthError) do
      DR::AttachAuth.verify!(SECRET, header_mac: 'whatever',
                             nonce_cache: @cache, now: @now, **args)
    end
    assert_equal 'timestamp_invalid', err.code
  end

  def test_nil_timestamp_raises_autherror
    args = { method: 'POST', path: '/x', body: '', timestamp: nil, nonce: 'n' }
    assert_raises(DR::AuthError) do
      DR::AttachAuth.verify!(SECRET, header_mac: 'whatever',
                             nonce_cache: @cache, now: @now, **args)
    end
  end

  def test_tampered_body_fails
    args, mac = signed
    tampered = args.merge(body: 'hi!')
    err = assert_raises(DR::AuthError) do
      DR::AttachAuth.verify!(SECRET, header_mac: mac, nonce_cache: @cache,
                             now: @now, **tampered)
    end
    assert_equal 'hmac_mismatch', err.code
  end

  def test_wrong_secret_fails
    args, _mac = signed
    mac = DR::AttachAuth.sign('other-secret', **args)
    err = assert_raises(DR::AuthError) do
      DR::AttachAuth.verify!(SECRET, header_mac: mac, nonce_cache: @cache,
                             now: @now, **args)
    end
    assert_equal 'hmac_mismatch', err.code
  end

  def test_negative_timestamp_rejected
    # R1 P2 (4.7): `.abs` was masking negative timestamps.
    args = { method: 'POST', path: '/x', body: '', timestamp: '-1', nonce: 'n' }
    err = assert_raises(DR::AuthError) do
      DR::AttachAuth.verify!(SECRET, header_mac: 'whatever',
                             nonce_cache: @cache, now: @now, **args)
    end
    assert_equal 'timestamp_invalid', err.code
  end

  def test_zero_timestamp_rejected
    args = { method: 'POST', path: '/x', body: '', timestamp: '0', nonce: 'n' }
    err = assert_raises(DR::AuthError) do
      DR::AttachAuth.verify!(SECRET, header_mac: 'whatever',
                             nonce_cache: @cache, now: @now, **args)
    end
    assert_equal 'timestamp_invalid', err.code
  end

  def test_mac_length_mismatch_does_not_raise
    # secure_compare guard: header_mac of different byte length must return
    # false (not raise) — fixed_length_secure_compare requires equal sizes.
    args, _mac = signed
    err = assert_raises(DR::AuthError) do
      DR::AttachAuth.verify!(SECRET, header_mac: 'short',
                             nonce_cache: @cache, now: @now, **args)
    end
    assert_equal 'hmac_mismatch', err.code
  end
end
