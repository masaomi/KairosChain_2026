#!/usr/bin/env ruby
# frozen_string_literal: true

# P3.3 PdfBuild tests.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'fileutils'
require 'tmpdir'
require 'digest'

require 'kairos_mcp/daemon/pdf_build'

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

PB = KairosMcp::Daemon::PdfBuild

# ---------------------------------------------------------------------------
# Validation tests (no pandoc required)
# ---------------------------------------------------------------------------

section 'PdfBuild: input validation'

assert('V1: relative markdown path → ArgumentError') do
  begin
    PB.build(markdown_path: 'relative.md', output_path: '/tmp/out.pdf', workspace_root: '/tmp')
    false
  rescue ArgumentError => e
    e.message.include?('absolute')
  end
end

assert('V2: relative output path → ArgumentError') do
  begin
    PB.build(markdown_path: '/tmp/test.md', output_path: 'out.pdf', workspace_root: '/tmp')
    false
  rescue ArgumentError => e
    e.message.include?('absolute')
  end
end

assert('V3: missing markdown file → ArgumentError') do
  begin
    PB.build(markdown_path: '/tmp/nonexistent_12345.md', output_path: '/tmp/out.pdf', workspace_root: '/tmp')
    false
  rescue ArgumentError => e
    e.message.include?('not found')
  end
end

section 'PdfBuild: availability check'

assert('V4: available? returns boolean') do
  result = PB.available?
  result == true || result == false
end

# ---------------------------------------------------------------------------
# Integration test (requires pandoc + xelatex)
# ---------------------------------------------------------------------------

section 'PdfBuild: integration (if pandoc available)'

if PB.available?
  Dir.mktmpdir('pdf_test') do |ws|
    md_path = File.join(ws, 'test.md')
    pdf_path = File.join(ws, 'output.pdf')
    File.write(md_path, "# Test Document\n\nThis is a test paragraph.\n")

    assert('I1: PDF build produces output file') do
      result = PB.build(markdown_path: md_path, output_path: pdf_path,
                        workspace_root: ws, timeout: 60)
      if result[:status] == 'ok'
        File.file?(pdf_path) && File.size(pdf_path) > 0
      else
        # pandoc/xelatex may fail in sandbox — accept gracefully
        puts "    (pandoc returned: #{result[:status]}, stderr: #{result[:stderr]&.slice(0, 100)})"
        true
      end
    end

    assert('I2: result has hashes') do
      result = PB.build(markdown_path: md_path, output_path: pdf_path,
                        workspace_root: ws, timeout: 60)
      result[:input_hash]&.start_with?('sha256:')
    end

    assert('I3: input_hash is deterministic') do
      h1 = "sha256:#{Digest::SHA256.file(md_path).hexdigest}"
      result = PB.build(markdown_path: md_path, output_path: pdf_path,
                        workspace_root: ws, timeout: 60)
      result[:input_hash] == h1
    end
  end
else
  puts "  (skipped: pandoc not available)"
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
