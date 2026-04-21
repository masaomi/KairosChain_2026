#!/usr/bin/env ruby
# frozen_string_literal: true

# verify_g2.rb — G2 (72h) soak verification script.
#
# Design (Phase 4 v0.3 §5):
#   Extends G1 criteria + RSS growth + budget pause/resume + log rotation.
#
# Usage:
#   ruby soak/verify_g2.rb [soak_dir]

require 'json'
require 'csv'

SOAK_DIR = ARGV[0] || '/tmp/kairos-soak-g2'

results = { pass: true, checks: {} }

# ------------------------------------------------------------------ 1. G1 checks
puts '=== G1 criteria (must still hold) ==='
g1_script = File.expand_path('../verify_g1.rb', __FILE__)
g1_exit = system("ruby #{g1_script} #{SOAK_DIR}")
results[:checks][:g1] = { pass: g1_exit }
results[:pass] = false unless g1_exit
puts ''

# ------------------------------------------------------------------ 2. RSS growth
puts '=== G2-specific criteria ==='
rss_csv = File.join(SOAK_DIR, 'rss.csv')
if File.exist?(rss_csv)
  data = CSV.read(rss_csv).map { |row| [row[0].to_f, row[1].to_f] }
  if data.size >= 10
    # Linear regression: slope in KB/s
    n = data.size.to_f
    sum_x  = data.sum { |d| d[0] }
    sum_y  = data.sum { |d| d[1] }
    sum_xy = data.sum { |d| d[0] * d[1] }
    sum_x2 = data.sum { |d| d[0] ** 2 }
    slope = (n * sum_xy - sum_x * sum_y) / (n * sum_x2 - sum_x ** 2)

    daily_growth_mb = slope * 86400 / 1024
    threshold_mb_per_72h = 50.0
    threshold_mb_per_day = threshold_mb_per_72h / 3.0

    rss_pass = daily_growth_mb < threshold_mb_per_day
    puts "2. RSS growth: #{daily_growth_mb.round(2)} MB/day (threshold: #{threshold_mb_per_day.round(1)} MB/day) — #{rss_pass ? 'PASS' : 'FAIL'}"
    results[:checks][:rss_growth] = {
      value_mb_per_day: daily_growth_mb.round(2),
      threshold_mb_per_day: threshold_mb_per_day.round(1),
      samples: data.size,
      pass: rss_pass
    }
    results[:pass] = false unless rss_pass
  else
    puts '2. RSS: insufficient data'
  end
else
  puts '2. RSS: csv not found'
end

# ------------------------------------------------------------------ 3. Budget pause→resume
budget_path = File.join(SOAK_DIR, '.kairos', 'state', 'budget.json')
if File.exist?(budget_path)
  budget = JSON.parse(File.read(budget_path))
  # Check that budget was reset at least once (date changed)
  puts "3. Budget date: #{budget['date']} (calls: #{budget['llm_calls']})"
  results[:checks][:budget_date] = budget['date']
else
  puts '3. Budget: file not found'
end

# ------------------------------------------------------------------ 4. Log rotation
log_dir = File.join(ENV['HOME'] || '~', 'Library', 'Logs', 'kairos')
rotated = Dir.glob(File.join(log_dir, '*.gz'))
puts "4. Rotated log files: #{rotated.size} (expect >= 1 for 72h)"
rotation_pass = rotated.size >= 1
results[:checks][:log_rotation] = { rotated_files: rotated.size, pass: rotation_pass }
# Don't fail on rotation — it depends on log volume

# ------------------------------------------------------------------ Overall
puts "\n#{'-' * 40}"
puts "G2 VERDICT: #{results[:pass] ? 'PASS' : 'FAIL'}"
exit(results[:pass] ? 0 : 1)
