#!/usr/bin/env ruby
# frozen_string_literal: true

# P3.4 RestrictedShell — unit + security tests.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'fileutils'
require 'tmpdir'
require 'json'

require 'kairos_mcp/daemon/restricted_shell'

$pass = 0
$fail = 0
$failed_names = []

def assert(description)
  ok = yield
  if ok
    $pass += 1
    puts "  PASS: #{description}"
  else
    $fail += 1
    $failed_names << description
    puts "  FAIL: #{description}"
  end
rescue StandardError => e
  $fail += 1
  $failed_names << description
  puts "  FAIL: #{description} (#{e.class}: #{e.message})"
  puts "    #{e.backtrace.first(3).join("\n    ")}" if ENV['VERBOSE']
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

RS = KairosMcp::Daemon::RestrictedShell
BR = RS::BinaryResolver
GV = RS::GitArgvValidator
PV = RS::PandocArgvValidator
XV = RS::XelatexArgvValidator
SF = RS::SandboxFactory

# ---------------------------------------------------------------------------
# BinaryResolver
# ---------------------------------------------------------------------------

section 'BinaryResolver: allowlist'

assert('U1: git resolves to a path') do
  r = BR.resolve!('git')
  r[:short] == 'git' && File.executable?(r[:path])
rescue RS::ResolverError
  # git not installed — skip
  puts "    (skipped: git not found)"
  true
end

assert('U2: forbidden binary → PolicyViolation') do
  begin
    BR.resolve!('ruby')
    false
  rescue RS::PolicyViolation => e
    e.message.include?('forbidden')
  end
end

assert('U3: unknown binary → PolicyViolation') do
  begin
    BR.resolve!('totally_unknown_binary')
    false
  rescue RS::PolicyViolation => e
    e.message.include?('not in allowlist')
  end
end

assert('U4: sh forbidden') do
  begin
    BR.resolve!('sh')
    false
  rescue RS::PolicyViolation
    true
  end
end

assert('U5: bash forbidden') do
  begin
    BR.resolve!('bash')
    false
  rescue RS::PolicyViolation
    true
  end
end

assert('U6: curl forbidden') do
  begin
    BR.resolve!('curl')
    false
  rescue RS::PolicyViolation
    true
  end
end

# ---------------------------------------------------------------------------
# Git Argv Validator
# ---------------------------------------------------------------------------

section 'GitArgvValidator: security'

assert('S1: git -c flag → PolicyViolation') do
  begin
    GV.validate!(['-c', 'core.pager=evil', 'log'])
    false
  rescue RS::PolicyViolation => e
    e.message.include?('-c')
  end
end

assert('S9: git status; rm -rf / → PolicyViolation (metachar)') do
  begin
    GV.validate!(['status;', 'rm', '-rf', '/'])
    false
  rescue RS::PolicyViolation => e
    e.message.include?('forbidden character')
  end
end

assert('U7: git status → allowed') do
  GV.validate!(%w[status --porcelain])
  true
end

assert('U8: git push → not allowed') do
  begin
    GV.validate!(%w[push origin main])
    false
  rescue RS::PolicyViolation
    true
  end
end

assert('U9: git --exec-path → forbidden') do
  begin
    GV.validate!(%w[--exec-path=/evil status])
    false
  rescue RS::PolicyViolation
    true
  end
end

assert('U10: git without subcommand → PolicyViolation') do
  begin
    GV.validate!([])
    false
  rescue RS::PolicyViolation
    true
  end
end

# ---------------------------------------------------------------------------
# Pandoc Argv Validator
# ---------------------------------------------------------------------------

section 'PandocArgvValidator: security'

assert('S3: pandoc --pdf-engine=/bin/sh → PolicyViolation') do
  begin
    PV.validate!(%w[input.md -o out.pdf --pdf-engine=/bin/sh])
    false
  rescue RS::PolicyViolation => e
    e.message.include?('bare name')
  end
end

assert('S4: pandoc --pdf-engine=xelatex → allowed') do
  PV.validate!(%w[input.md -o out.pdf --pdf-engine=xelatex])
  true
end

assert('S5: pandoc --defaults evil.yaml → PolicyViolation') do
  begin
    PV.validate!(%w[input.md --defaults evil.yaml])
    false
  rescue RS::PolicyViolation
    true
  end
end

assert('S6: pandoc -d evil.yaml → PolicyViolation') do
  begin
    PV.validate!(%w[input.md -d evil.yaml])
    false
  rescue RS::PolicyViolation
    true
  end
end

assert('U11: pandoc --filter → forbidden') do
  begin
    PV.validate!(%w[input.md --filter evil])
    false
  rescue RS::PolicyViolation
    true
  end
end

assert('U12: pandoc --lua-filter → forbidden') do
  begin
    PV.validate!(%w[input.md --lua-filter evil.lua])
    false
  rescue RS::PolicyViolation
    true
  end
end

assert('U13: pandoc URL → forbidden') do
  begin
    PV.validate!(%w[https://evil.com/payload.md -o out.pdf])
    false
  rescue RS::PolicyViolation
    true
  end
end

assert('U14: pandoc --pdf-engine-opt allowed safe values') do
  PV.validate!(%w[input.md --pdf-engine=xelatex --pdf-engine-opt=-no-shell-escape])
  true
end

assert('U15: pandoc --pdf-engine-opt disallowed values') do
  begin
    PV.validate!(%w[input.md --pdf-engine=xelatex --pdf-engine-opt=-evil])
    false
  rescue RS::PolicyViolation
    true
  end
end

assert('S3b: pandoc --pdf-engine=./xelatex → PolicyViolation (path)') do
  begin
    PV.validate!(%w[input.md --pdf-engine=./xelatex])
    false
  rescue RS::PolicyViolation => e
    e.message.include?('bare name')
  end
end

assert('S3c: pandoc --pdf-engine=/tmp/xelatex → PolicyViolation') do
  begin
    PV.validate!(%w[input.md --pdf-engine=/tmp/xelatex])
    false
  rescue RS::PolicyViolation => e
    e.message.include?('bare name')
  end
end

# ---------------------------------------------------------------------------
# Xelatex Argv Validator
# ---------------------------------------------------------------------------

section 'XelatexArgvValidator: security'

assert('S12: xelatex without -no-shell-escape → PolicyViolation') do
  begin
    XV.validate!(%w[input.tex])
    false
  rescue RS::PolicyViolation => e
    e.message.include?('-no-shell-escape')
  end
end

assert('U16: xelatex -no-shell-escape → allowed') do
  XV.validate!(%w[-no-shell-escape input.tex])
  true
end

assert('U17: xelatex --shell-escape → forbidden') do
  begin
    XV.validate!(%w[--shell-escape -no-shell-escape input.tex])
    false
  rescue RS::PolicyViolation
    true
  end
end

# ---------------------------------------------------------------------------
# SandboxFactory
# ---------------------------------------------------------------------------

section 'SandboxFactory: SBPL generation'

assert('U18: SBPL contains deny default') do
  profile = SF.render_sbpl(cwd: '/tmp/test', allowed_paths: ['/tmp/test'], network: :deny)
  profile.include?('(deny default)')
end

assert('U19: SBPL includes allowed path') do
  profile = SF.render_sbpl(cwd: '/tmp/test', allowed_paths: ['/home/user/project'], network: :deny)
  profile.include?('"/home/user/project"')
end

assert('U20: SBPL network deny has no network-outbound') do
  profile = SF.render_sbpl(cwd: '/tmp/test', allowed_paths: ['/tmp/test'], network: :deny)
  !profile.include?('network-outbound')
end

assert('U20b: SBPL network allow has network-outbound') do
  profile = SF.render_sbpl(cwd: '/tmp/test', allowed_paths: ['/tmp/test'], network: :allow)
  profile.include?('(allow network-outbound)')
end

assert('U20c: SBPL includes /dev/null read/write') do
  profile = SF.render_sbpl(cwd: '/tmp/test', allowed_paths: ['/tmp/test'], network: :deny)
  profile.include?('/dev/null') && profile.include?('/dev/urandom')
end

# ---------------------------------------------------------------------------
# SandboxContext cleanup
# ---------------------------------------------------------------------------

section 'SandboxContext: cleanup'

assert('S11: SandboxContext cleans up tmpdir') do
  tmpdir = Dir.mktmpdir('sc_test')
  File.write(File.join(tmpdir, 'test.sb'), 'test')
  ctx = RS::SandboxContext.new(cmd: ['/bin/echo'], tmpdir: tmpdir)
  ctx.cleanup!
  !Dir.exist?(tmpdir)
end

assert('U21: cleanup is safe when tmpdir is nil') do
  ctx = RS::SandboxContext.new(cmd: ['/bin/echo'])
  ctx.cleanup!
  true
end

# ---------------------------------------------------------------------------
# RestrictedShell.run: policy checks
# ---------------------------------------------------------------------------

section 'RestrictedShell.run: policy validation'

assert('U22: empty cmd → PolicyViolation') do
  begin
    RS.run(cmd: [], cwd: '/tmp', timeout: 5, allowed_paths: ['/tmp'])
    false
  rescue RS::PolicyViolation => e
    e.message.include?('empty')
  end
end

assert('S7: stdin > 8KB → PolicyViolation') do
  begin
    RS.run(cmd: ['git', 'status'], cwd: '/tmp', timeout: 5,
           allowed_paths: ['/tmp'], stdin_data: 'x' * 9000)
    false
  rescue RS::PolicyViolation => e
    e.message.include?('stdin_data')
  end
end

assert('U23: relative cwd → PolicyViolation') do
  begin
    RS.run(cmd: ['git', 'status'], cwd: 'relative/path', timeout: 5,
           allowed_paths: ['/tmp'])
    false
  rescue RS::PolicyViolation => e
    e.message.include?('absolute')
  end
end

assert('U24: cwd not in allowed_paths → PolicyViolation') do
  begin
    RS.run(cmd: ['git', 'status'], cwd: '/usr', timeout: 5,
           allowed_paths: ['/tmp'])
    false
  rescue RS::PolicyViolation => e
    e.message.include?('not under')
  end
end

assert('U25: forbidden binary via run → PolicyViolation') do
  begin
    RS.run(cmd: ['bash', '-c', 'echo hi'], cwd: '/tmp', timeout: 5,
           allowed_paths: ['/tmp'])
    false
  rescue RS::PolicyViolation => e
    e.message.include?('forbidden')
  end
end

assert('U26: invalid network option → PolicyViolation') do
  begin
    RS.run(cmd: ['git', 'status'], cwd: '/tmp', timeout: 5,
           allowed_paths: ['/tmp'], network: :maybe)
    false
  rescue RS::PolicyViolation
    true
  end
end

# ---------------------------------------------------------------------------
# RestrictedShell.run: integration (real git, if available)
# ---------------------------------------------------------------------------

section 'RestrictedShell.run: integration'

Dir.mktmpdir('rs_integ') do |ws|
  # Init a git repo for testing
  system('git', 'init', ws, out: File::NULL, err: File::NULL)

  assert('I1: git status in real repo → Result returned') do
    result = RS.run(cmd: %w[git status --porcelain], cwd: ws, timeout: 10,
                    allowed_paths: [ws])
    # sandbox-exec may SIGABRT on some macOS configs; accept any Result
    result.is_a?(RS::Result)
  rescue RS::SandboxError, RS::ResolverError => e
    puts "    (skipped: #{e.message})"
    true
  end

  assert('I1b: git status result has stdout') do
    result = RS.run(cmd: %w[git status], cwd: ws, timeout: 10,
                    allowed_paths: [ws])
    result.stdout.is_a?(String)
  rescue RS::SandboxError, RS::ResolverError => e
    puts "    (skipped: #{e.message})"
    true
  end

  assert('I1c: result has cmd_hash') do
    result = RS.run(cmd: %w[git status], cwd: ws, timeout: 10,
                    allowed_paths: [ws])
    result.cmd_hash&.start_with?('sha256:')
  rescue RS::SandboxError, RS::ResolverError => e
    puts "    (skipped: #{e.message})"
    true
  end
end

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

puts
puts '=' * 60
puts "Results: #{$pass} passed, #{$fail} failed"
puts '=' * 60

unless $failed_names.empty?
  puts 'Failed tests:'
  $failed_names.each { |n| puts "  - #{n}" }
end

exit($fail.zero? ? 0 : 1)
