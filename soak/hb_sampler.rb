#!/usr/bin/env ruby
# frozen_string_literal: true

# hb_sampler.rb — External heartbeat sampler for G1/G2 soak tests.
#
# Design (Phase 4 v0.3 §2.1):
#   Reads .kairos/run/heartbeat.json (single atomic JSON) and appends
#   a timestamped sample to a CSV file. Run via launchd StartInterval:2.
#   Independent of the daemon — measures heartbeat gap externally.
#
# Usage:
#   ruby soak/hb_sampler.rb <heartbeat_path> <csv_path>

require 'json'
require 'time'

hb_path  = ARGV[0] || '.kairos/run/heartbeat.json'
csv_path = ARGV[1] || '/tmp/kairos-soak-g1/hb_samples.csv'

begin
  raw = File.read(hb_path)
  data = JSON.parse(raw)
  ts_str = data['ts']
  ts = Time.parse(ts_str).to_f
  File.open(csv_path, 'a') { |f| f.puts "#{Time.now.to_f},#{ts}" }
rescue Errno::ENOENT
  # Daemon not yet started — heartbeat file doesn't exist yet
rescue JSON::ParserError => e
  File.open(csv_path, 'a') { |f| f.puts "#{Time.now.to_f},ERROR:json_parse:#{e.message[0..50]}" }
rescue StandardError => e
  File.open(csv_path, 'a') { |f| f.puts "#{Time.now.to_f},ERROR:#{e.class}:#{e.message[0..50]}" }
end
