#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for Phase 2 P2.6: Credentials (scoped secret store, redaction).
# Usage: ruby test_credentials.rb

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'tmpdir'
require 'fileutils'
require 'yaml'

require 'kairos_mcp/daemon/credentials'

$pass = 0
$fail = 0

def assert(description, &block)
  result = block.call
  if result
    $pass += 1
    puts "  PASS: #{description}"
  else
    $fail += 1
    puts "  FAIL: #{description}"
  end
rescue StandardError => e
  $fail += 1
  puts "  FAIL: #{description} (#{e.class}: #{e.message})"
  puts "    #{e.backtrace.first(3).join("\n    ")}" if ENV['VERBOSE']
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

# ENV save/restore helper — tests must never leak secrets into the parent shell.
def with_env(overrides)
  saved = {}
  overrides.each_key { |k| saved[k] = ENV[k] }
  overrides.each { |k, v| ENV[k] = v }
  yield
ensure
  saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

def write_secrets(dir, secrets)
  path = File.join(dir, 'secrets.yml')
  File.write(path, YAML.dump('secrets' => secrets))
  path
end

# Minimal stub logger to capture keychain warnings.
class StubLogger
  attr_reader :warnings
  def initialize; @warnings = []; end
  def warn(msg); @warnings << msg; end
  def info(_msg); end
end

# =========================================================================
# 1. Loading secrets.yml
# =========================================================================

section 'Credentials — loading secrets.yml'

assert('load returns self for chaining') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'API_KEY', 'source' => 'env', 'env_var' => 'API_KEY',
        'scoped_to' => ['llm_call'] }
    ])
    c = KairosMcp::Daemon::Credentials.new
    c.load(path).equal?(c)
  end
end

assert('load parses secret_names from yaml') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'A', 'source' => 'env', 'env_var' => 'A_ENV', 'scoped_to' => ['*'] },
      { 'name' => 'B', 'source' => 'env', 'env_var' => 'B_ENV', 'scoped_to' => ['*'] }
    ])
    c = KairosMcp::Daemon::Credentials.new.load(path)
    c.secret_names.sort == %w[A B]
  end
end

assert('load of missing secrets.yml yields empty credentials (no crash)') do
  c = KairosMcp::Daemon::Credentials.new
  c.load('/nonexistent/path/secrets.yml')
  c.secret_names.empty? && c.fetch_for('anything').empty?
end

assert('load of empty secrets.yml yields empty credentials') do
  Dir.mktmpdir do |d|
    path = File.join(d, 'secrets.yml')
    File.write(path, "secrets: []\n")
    c = KairosMcp::Daemon::Credentials.new.load(path)
    c.secret_names.empty?
  end
end

assert('all_patterns returns unique scoped_to patterns') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'A', 'source' => 'env', 'env_var' => 'A', 'scoped_to' => %w[llm_call llm_configure] },
      { 'name' => 'B', 'source' => 'env', 'env_var' => 'B', 'scoped_to' => ['llm_call'] }
    ])
    c = KairosMcp::Daemon::Credentials.new.load(path)
    c.all_patterns.sort == %w[llm_call llm_configure]
  end
end

# =========================================================================
# 2. fetch_for — scope enforcement
# =========================================================================

section 'Credentials — fetch_for scope enforcement'

assert('fetch_for returns only scoped secrets (exact name)') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'ANTHROPIC_API_KEY', 'source' => 'env', 'env_var' => 'T_ANT',
        'scoped_to' => %w[llm_call llm_configure] },
      { 'name' => 'GITHUB_TOKEN', 'source' => 'env', 'env_var' => 'T_GH',
        'scoped_to' => ['safe_git_push'] }
    ])
    with_env('T_ANT' => 'sk-test-ant', 'T_GH' => 'ghp-test-gh') do
      c = KairosMcp::Daemon::Credentials.new.load(path)
      out = c.fetch_for('llm_call')
      out.keys.sort == ['ANTHROPIC_API_KEY'] && out['ANTHROPIC_API_KEY'] == 'sk-test-ant'
    end
  end
end

assert('fetch_for supports glob pattern (safe_http_*)') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'GITHUB_TOKEN', 'source' => 'env', 'env_var' => 'T_GH',
        'scoped_to' => ['safe_http_*', 'safe_git_push'] }
    ])
    with_env('T_GH' => 'ghp-xxx') do
      c = KairosMcp::Daemon::Credentials.new.load(path)
      c.fetch_for('safe_http_get')['GITHUB_TOKEN'] == 'ghp-xxx' &&
        c.fetch_for('safe_http_post')['GITHUB_TOKEN'] == 'ghp-xxx'
    end
  end
end

assert('fetch_for returns empty for non-matching tool') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'ANTHROPIC_API_KEY', 'source' => 'env', 'env_var' => 'T_ANT',
        'scoped_to' => ['llm_call'] }
    ])
    with_env('T_ANT' => 'sk-test') do
      c = KairosMcp::Daemon::Credentials.new.load(path)
      c.fetch_for('safe_http_get').empty?
    end
  end
end

assert('fetch_for with empty scoped_to exposes secret to NO tools') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'SECRET', 'source' => 'env', 'env_var' => 'T_SEC',
        'scoped_to' => [] }
    ])
    with_env('T_SEC' => 'value') do
      c = KairosMcp::Daemon::Credentials.new.load(path)
      c.fetch_for('llm_call').empty? &&
        c.fetch_for('safe_http_get').empty? &&
        c.fetch_for('*').empty?
    end
  end
end

assert('fetch_for with missing scoped_to exposes secret to NO tools') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'SECRET', 'source' => 'env', 'env_var' => 'T_SEC' }
    ])
    with_env('T_SEC' => 'value') do
      c = KairosMcp::Daemon::Credentials.new.load(path)
      c.fetch_for('anything').empty?
    end
  end
end

assert('fetch_for accepts Symbol tool_name') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'K', 'source' => 'env', 'env_var' => 'T_K', 'scoped_to' => ['llm_call'] }
    ])
    with_env('T_K' => 'v') do
      c = KairosMcp::Daemon::Credentials.new.load(path)
      c.fetch_for(:llm_call)['K'] == 'v'
    end
  end
end

assert('fetch_for omits secrets with unresolved (nil) values') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'PRESENT', 'source' => 'env', 'env_var' => 'T_PRES', 'scoped_to' => ['t'] },
      { 'name' => 'ABSENT',  'source' => 'env', 'env_var' => 'T_ABS_NEVER', 'scoped_to' => ['t'] }
    ])
    ENV.delete('T_ABS_NEVER')
    with_env('T_PRES' => 'here') do
      c = KairosMcp::Daemon::Credentials.new.load(path)
      out = c.fetch_for('t')
      out.keys == ['PRESENT']
    end
  end
end

# =========================================================================
# 3. Source types
# =========================================================================

section 'Credentials — source types'

assert('env source reads from ENV') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'K', 'source' => 'env', 'env_var' => 'T_ENV_SRC', 'scoped_to' => ['t'] }
    ])
    with_env('T_ENV_SRC' => 'env-value') do
      c = KairosMcp::Daemon::Credentials.new.load(path)
      c.fetch_for('t')['K'] == 'env-value'
    end
  end
end

assert('env source returns nothing when ENV var missing (no crash)') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'K', 'source' => 'env', 'env_var' => 'T_MISSING_XYZ', 'scoped_to' => ['t'] }
    ])
    ENV.delete('T_MISSING_XYZ')
    c = KairosMcp::Daemon::Credentials.new.load(path)
    c.fetch_for('t').empty?
  end
end

assert('file source reads from disk (trimmed)') do
  Dir.mktmpdir do |d|
    secret_file = File.join(d, 'token.txt')
    File.write(secret_file, "file-secret-42\n")
    path = write_secrets(d, [
      { 'name' => 'TK', 'source' => 'file', 'file_path' => secret_file, 'scoped_to' => ['t'] }
    ])
    c = KairosMcp::Daemon::Credentials.new.load(path)
    c.fetch_for('t')['TK'] == 'file-secret-42'
  end
end

assert('file source returns nothing when file is missing (no crash)') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'TK', 'source' => 'file', 'file_path' => '/no/such/file',
        'scoped_to' => ['t'] }
    ])
    c = KairosMcp::Daemon::Credentials.new.load(path)
    c.fetch_for('t').empty?
  end
end

assert('keychain source returns nil and logs a warning') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'KC', 'source' => 'keychain', 'scoped_to' => ['t'] }
    ])
    logger = StubLogger.new
    c = KairosMcp::Daemon::Credentials.new(logger: logger).load(path)
    c.fetch_for('t').empty? && logger.warnings.any? { |w| w.include?('keychain') }
  end
end

assert('unknown source type yields no value (not an exception)') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'K', 'source' => 'mystery', 'scoped_to' => ['t'] }
    ])
    c = KairosMcp::Daemon::Credentials.new.load(path)
    c.fetch_for('t').empty?
  end
end

# =========================================================================
# 4. reload!
# =========================================================================

section 'Credentials — reload!'

assert('reload! picks up changes to secrets.yml') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'A', 'source' => 'env', 'env_var' => 'T_A', 'scoped_to' => ['t'] }
    ])
    with_env('T_A' => 'v1', 'T_B' => 'v2') do
      c = KairosMcp::Daemon::Credentials.new.load(path)
      before = c.secret_names.sort
      # Overwrite secrets.yml with a different set.
      File.write(path, YAML.dump('secrets' => [
        { 'name' => 'A', 'source' => 'env', 'env_var' => 'T_A', 'scoped_to' => ['t'] },
        { 'name' => 'B', 'source' => 'env', 'env_var' => 'T_B', 'scoped_to' => ['t'] }
      ]))
      c.reload!
      before == ['A'] && c.secret_names.sort == %w[A B] && c.fetch_for('t')['B'] == 'v2'
    end
  end
end

assert('reload! re-resolves ENV values (value update)') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'K', 'source' => 'env', 'env_var' => 'T_K_RELOAD', 'scoped_to' => ['t'] }
    ])
    with_env('T_K_RELOAD' => 'old') do
      c = KairosMcp::Daemon::Credentials.new.load(path)
      first = c.fetch_for('t')['K']
      ENV['T_K_RELOAD'] = 'new'
      c.reload!
      first == 'old' && c.fetch_for('t')['K'] == 'new'
    end
  end
end

assert('reload! without prior load is a no-op') do
  c = KairosMcp::Daemon::Credentials.new
  c.reload!
  c.secret_names.empty?
end

# =========================================================================
# 5. redact
# =========================================================================

section 'Credentials — redact'

assert('redact replaces a single known secret value') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'K', 'source' => 'env', 'env_var' => 'T_RED1', 'scoped_to' => ['t'] }
    ])
    with_env('T_RED1' => 'sk-super-secret-42') do
      c = KairosMcp::Daemon::Credentials.new.load(path)
      out = c.redact('Authorization: Bearer sk-super-secret-42 trailing')
      !out.include?('sk-super-secret-42') && out.include?('***REDACTED***')
    end
  end
end

assert('redact handles multiple secrets in one string') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'A', 'source' => 'env', 'env_var' => 'T_MA', 'scoped_to' => ['t'] },
      { 'name' => 'B', 'source' => 'env', 'env_var' => 'T_MB', 'scoped_to' => ['t'] }
    ])
    with_env('T_MA' => 'AAA-111', 'T_MB' => 'BBB-222') do
      c = KairosMcp::Daemon::Credentials.new.load(path)
      out = c.redact('key=AAA-111 token=BBB-222')
      !out.include?('AAA-111') && !out.include?('BBB-222') &&
        out.scan('***REDACTED***').size == 2
    end
  end
end

assert('redact handles nil without crashing') do
  c = KairosMcp::Daemon::Credentials.new
  c.redact(nil).nil?
end

assert('redact handles empty string without crashing') do
  c = KairosMcp::Daemon::Credentials.new
  c.redact('') == ''
end

assert('redact is a no-op when no secrets loaded') do
  c = KairosMcp::Daemon::Credentials.new
  c.redact('nothing to redact here') == 'nothing to redact here'
end

assert('redact skips nil / empty secret values (does not mass-replace)') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'K', 'source' => 'env', 'env_var' => 'T_ABSENT_XX', 'scoped_to' => ['t'] }
    ])
    ENV.delete('T_ABSENT_XX')
    c = KairosMcp::Daemon::Credentials.new.load(path)
    # Empty string must NOT be substituted across the whole string.
    c.redact('some log line') == 'some log line'
  end
end

assert('redact prefers longer secret when one is a substring of another') do
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'SHORT', 'source' => 'env', 'env_var' => 'T_S', 'scoped_to' => ['t'] },
      { 'name' => 'LONG',  'source' => 'env', 'env_var' => 'T_L', 'scoped_to' => ['t'] }
    ])
    with_env('T_S' => 'abc', 'T_L' => 'abcdef') do
      c = KairosMcp::Daemon::Credentials.new.load(path)
      out = c.redact('value=abcdef end')
      # 'abcdef' becomes REDACTED as a whole; 'abc' should not leave 'def' behind.
      !out.include?('abc') && !out.include?('def')
    end
  end
end

assert('redact also masks secrets that are NOT scoped to any tool') do
  # Even if a secret is never handed out, its value must still be scrubbed
  # from log output — scope controls *distribution*, not *sensitivity*.
  Dir.mktmpdir do |d|
    path = write_secrets(d, [
      { 'name' => 'UNSCOPED', 'source' => 'env', 'env_var' => 'T_UNSCOPED',
        'scoped_to' => [] }
    ])
    with_env('T_UNSCOPED' => 'should-not-leak') do
      c = KairosMcp::Daemon::Credentials.new.load(path)
      c.fetch_for('anything').empty? &&
        c.redact('log: should-not-leak ok').include?('***REDACTED***')
    end
  end
end

# =========================================================================
# Summary
# =========================================================================

puts "\n#{'=' * 60}"
puts "Results: #{$pass} passed, #{$fail} failed"
puts '=' * 60
exit($fail.zero? ? 0 : 1)
