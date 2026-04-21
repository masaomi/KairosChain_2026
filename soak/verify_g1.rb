#!/usr/bin/env ruby
# frozen_string_literal: true

# verify_g1.rb — G1 (8h) soak verification script.
#
# Design (Phase 4 v0.3 §2.5):
#   Reads soak artifacts and checks G1 acceptance criteria.
#
# Usage:
#   ruby soak/verify_g1.rb [soak_dir]
#
# Exit: 0 = PASS, 1 = FAIL

require 'json'
require 'time'
require 'csv'

SOAK_DIR = ARGV[0] || '/tmp/kairos-soak-g1'
LOG_DIR  = File.join(ENV['HOME'] || '~', 'Library', 'Logs', 'kairos')

results = { pass: true, checks: {} }

# ------------------------------------------------------------------ 1. Crashes
err_log_path = File.join(LOG_DIR, 'daemon.err.log')
if File.exist?(err_log_path)
  err_log = File.read(err_log_path)
  fatal_count = err_log.lines.count { |l| l.match?(/FATAL|crash|abort/i) }
else
  fatal_count = 0
end
crash_pass = fatal_count == 0
results[:checks][:crashes] = { value: fatal_count, threshold: 0, pass: crash_pass }
results[:pass] = false unless crash_pass
puts "1. Crashes: #{fatal_count} (threshold: 0) — #{crash_pass ? 'PASS' : 'FAIL'}"

# ------------------------------------------------------------------ 2. Heartbeat gap p99
hb_csv = File.join(SOAK_DIR, 'hb_samples.csv')
if File.exist?(hb_csv)
  samples = []
  CSV.foreach(hb_csv) do |row|
    next if row[1]&.start_with?('ERROR')
    next unless row[0] && row[1]
    samples << [row[0].to_f, row[1].to_f]
  end

  # Compute gaps between consecutive DIFFERENT heartbeat timestamps
  hb_gaps = samples.each_cons(2).map { |a, b| b[1] - a[1] }.select { |g| g > 0 }

  if hb_gaps.size > 10
    sorted = hb_gaps.sort
    p99_idx = [(sorted.size * 0.99).ceil - 1, 0].max
    p99 = sorted[p99_idx]
  elsif samples.size > 10 && hb_gaps.empty?
    # P1-fix: All gaps are 0 → heartbeat timestamp never changed → daemon stuck
    p99 = Float::INFINITY
  else
    p99 = -1
  end
else
  p99 = -1
end
hb_pass = p99 > 0 && p99 < 60
results[:checks][:heartbeat_p99] = { value: (p99 == Float::INFINITY ? 'stuck' : p99.round(2)), threshold: 60, pass: hb_pass }
results[:pass] = false if p99 != -1 && !hb_pass  # stuck daemon = FAIL, not SKIP
if p99 == Float::INFINITY
  puts "2. Heartbeat gap p99: STUCK (daemon heartbeat never updated) — FAIL"
elsif p99 > 0
  puts "2. Heartbeat gap p99: #{p99.round(2)}s (threshold: 60s) — #{hb_pass ? 'PASS' : 'FAIL'}"
else
  puts "2. Heartbeat gap p99: insufficient data — SKIP"
end

# ------------------------------------------------------------------ 3. Budget usage
budget_path = File.join(SOAK_DIR, '.kairos', 'state', 'budget.json')
if File.exist?(budget_path)
  budget = JSON.parse(File.read(budget_path))
  calls = budget['llm_calls'] || 0
  limit = budget['limit'] || '?'
  puts "3. Budget: #{calls}/#{limit} calls"
  results[:checks][:budget] = { llm_calls: calls, limit: limit }
else
  puts '3. Budget: file not found'
end

# ------------------------------------------------------------------ 4. WAL files
wal_dir = File.join(SOAK_DIR, '.kairos', 'wal')
if Dir.exist?(wal_dir)
  wal_count = Dir.glob(File.join(wal_dir, '*.wal.jsonl')).size
  puts "4. WAL files: #{wal_count}"
  results[:checks][:wal_files] = wal_count
else
  puts '4. WAL: directory not found'
end

# ------------------------------------------------------------------ 5. LLM cost estimate
if File.exist?(budget_path)
  budget = JSON.parse(File.read(budget_path))
  input_tokens = budget['input_tokens'] || 0
  output_tokens = budget['output_tokens'] || 0
  # Sonnet 4.6 pricing: $3/MTok input, $15/MTok output (approx)
  cost = (input_tokens * 3.0 / 1_000_000) + (output_tokens * 15.0 / 1_000_000)
  cost_pass = cost <= 5.0
  puts "5. Estimated LLM cost: $#{cost.round(4)} (threshold: $5.00) — #{cost_pass ? 'PASS' : 'FAIL'}"
  results[:checks][:cost] = { value: cost.round(4), threshold: 5.0, pass: cost_pass }
  results[:pass] = false unless cost_pass
end

# ------------------------------------------------------------------ Overall
puts "\n#{'-' * 40}"
puts "G1 VERDICT: #{results[:pass] ? 'PASS' : 'FAIL'}"
puts JSON.pretty_generate(results) if ARGV.include?('--json')
exit(results[:pass] ? 0 : 1)
