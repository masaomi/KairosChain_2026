#!/usr/bin/env ruby
# frozen_string_literal: true

# Guard track Stage A probes (design v0.3.1 FROZEN, §5 Slice 1 acceptance):
# no-spec-halt, tamper halt, discrimination (non-conforming act must FAIL),
# pass path, fail-closed spec validation, evidence read from driver position.
# Usage: ruby test_agent_verdict.rb

require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../lib/agent/verdict'

V = KairosMcp::SkillSets::Agent::Verdict

$pass = 0
$fail = 0

def assert(description)
  result = yield
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
end

def assert_raises(description, klass)
  yield
  $fail += 1
  puts "  FAIL: #{description} (no exception raised)"
rescue klass
  $pass += 1
  puts "  PASS: #{description}"
end

Dir.mktmpdir('verdict_session_') do |session_dir|
  Dir.mktmpdir('verdict_scratch_') do |scratch|
    puts '== Fail-closed pinning (AGT-4/AGT-6) =='
    assert_raises('nil material refused', V::SpecError) { V.pin!(session_dir, nil) }
    assert_raises('empty acceptance refused (no spec means no gated act)', V::SpecError) do
      V.pin!(session_dir, { 'acceptance' => [] })
    end
    assert_raises('unknown check type refused at pin time', V::SpecError) do
      V.pin!(session_dir, { 'acceptance' => [{ 'type' => 'llm_judgment' }] })
    end
    assert_raises('undeclarable layer surface refused at pin time (AGT-5)', V::SpecError) do
      V.pin!(session_dir, { 'acceptance' => [{ 'type' => 'manifest_not_empty' }],
                            'layer_surface' => ['chain'] })
    end

    puts '== No-spec halt (AGT-6) =='
    v = V.judge(session_dir, {})
    assert('judge without pinned spec HALTs, never passes') { v['verdict'] == V::HALT }

    puts '== Pin + pass path =='
    sha = V.pin!(session_dir, {
      'acceptance' => [
        { 'type' => 'file_exists', 'path' => 'out/result.txt' },
        { 'type' => 'file_contains', 'path' => 'out/result.txt', 'substring' => 'DONE' },
        { 'type' => 'manifest_not_empty' }
      ],
      'layer_surface' => ['l1']
    })
    assert('pin returns content hash') { sha.is_a?(String) && sha.length == 64 }
    FileUtils.mkdir_p(File.join(scratch, 'out'))
    File.write(File.join(scratch, 'out', 'result.txt'), 'work DONE')
    evidence = { 'scratch_dir' => scratch, 'manifest' => ['out/result.txt'] }
    v = V.judge(session_dir, evidence)
    assert('conforming act PASSes') { v['verdict'] == V::PASS }
    assert('constant-key verdict shape') { %w[verdict checks spec_sha256 reason].all? { |k| v.key?(k) } }
    assert('verdict carries the pinned hash') { v['spec_sha256'] == sha }

    puts '== Discrimination (non-conforming act must FAIL) =='
    File.write(File.join(scratch, 'out', 'result.txt'), 'work INCOMPLETE')
    v = V.judge(session_dir, evidence)
    assert('non-conforming act FAILs — the gate distinguishes') { v['verdict'] == V::FAIL }
    assert('failing check is named') do
      v['checks'].any? { |c| c['type'] == 'file_contains' && c['result'] == V::FAIL }
    end

    puts '== Evidence provenance (driver position, AGT-3) =='
    v = V.judge(session_dir, { 'manifest' => ['out/result.txt'] }) # no scratch_dir
    assert('file checks without scratch evidence FAIL, not pass') { v['verdict'] == V::FAIL }
    v = V.judge(session_dir, 'scratch_dir' => scratch, 'manifest' => [])
    assert('empty manifest fails manifest_not_empty') { v['verdict'] == V::FAIL }

    puts '== Path escape in spec checks =='
    V.pin!(session_dir, { 'acceptance' => [{ 'type' => 'file_exists', 'path' => '../../etc/hosts' }] })
    v = V.judge(session_dir, evidence)
    assert('path escaping scratch cannot pass') { v['verdict'] == V::FAIL }

    puts '== Tamper halt (spec hash mismatch, AGT-6) =='
    V.pin!(session_dir, { 'acceptance' => [{ 'type' => 'manifest_not_empty' }] })
    spec_path = File.join(session_dir, V::SPEC_FILE)
    File.write(spec_path, File.read(spec_path).sub('manifest_not_empty', 'file_exists'))
    v = V.judge(session_dir, evidence)
    assert('tampered spec HALTs') { v['verdict'] == V::HALT }
    assert('halt reason names tamper') { v['reason'].include?('tamper') }

    puts '== In-process route evidence (execution_completed) =='
    V.pin!(session_dir, { 'acceptance' => [{ 'type' => 'execution_completed' }] })
    v = V.judge(session_dir, { 'execution_summary' => 'completed' })
    assert('driver-observed completed execution PASSes') { v['verdict'] == V::PASS }
    v = V.judge(session_dir, { 'execution_summary' => 'failed' })
    assert('driver-observed failed execution FAILs') { v['verdict'] == V::FAIL }
    v = V.judge(session_dir, {})
    assert('absent execution evidence FAILs, not passes') { v['verdict'] == V::FAIL }
  end
end

puts
puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
