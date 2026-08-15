#!/usr/bin/env ruby
# frozen_string_literal: true

# Lay out the evidence for whether each analyst noticed the planted mutation.
#
# This script does NOT decide. It extracts, for every arm and every analyst,
# the lines that cite the mutated utterance, and prints them next to what was
# planted there. The call is made by a person reading those lines.
#
# That division is deliberate and was learned the hard way. On 2026-08-15 the
# first pass over 81 verdicts used keyword matching — contradiction, mismatch,
# discrepancy, 矛盾 — and undercounted one analyst by four, because its findings
# were written purely as a contrast: "its reasoning says it will vote for its
# proposal, but it votes against". No word on the list appears in that sentence.
# All 105 verdicts had to be re-read by hand. A script that returned a number
# here would have shipped that error silently, so this one returns a worksheet.
#
# The criterion, which should be fixed before any result is read:
#
#   detected     names the vote at that utterance, or whether the rule passed
#                or failed, as inconsistent with the record
#   weak         names only the reasoning-versus-utterance mismatch
#   missed       neither
#   false alarm  claims the same inconsistency in the CLEAN arm, where nothing
#                was planted
#
# Usage, from the project root:
#   ruby .kairos/skillsets/minimum_nomic/bin/score_detections.rb MUT_DIR
#   ruby .kairos/skillsets/minimum_nomic/bin/score_detections.rb MUT_DIR --context 3

require 'json'
require 'optparse'

options = { context: 2 }
OptionParser.new do |o|
  o.banner = 'usage: score_detections.rb MUT_DIR [--context N]'
  o.on('--context N', Integer, 'lines to show per analyst (default 2)') { |v| options[:context] = v }
end.parse!

dir = ARGV[0] or abort 'usage: score_detections.rb MUT_DIR [--context N]'
manifest_path = File.join(dir, 'mutations.json')
abort "#{manifest_path}: not found; was this directory made by mutate.rb?" unless File.exist?(manifest_path)

manifest = JSON.parse(File.read(manifest_path))

# Every kind is offset by what the arm inherited when it was copied, `analyses`
# included. A copied arm carries the ORIGINAL game's analyses, written before
# anything was planted; showing them here would present three analysts for an
# arm nobody has analysed and score every one of them as a miss.
def analyses(arm_dir, baseline)
  rows = []
  KINDS.each do |kind|
    path = File.join(arm_dir, 'records', "#{kind}.jsonl")
    next unless File.exist?(path)

    File.readlines(path)[baseline[kind].to_i..].to_a.each do |l|
      next if l.strip.empty?

      rows << JSON.parse(l).merge('kind' => kind)
    end
  end
  rows
end

KINDS = %w[analyses analyses_rescored analyses_crossmodel].freeze

def baseline_for(manifest, arm_dir)
  KINDS.each_with_object({}) do |kind, h|
    h[kind] = manifest.dig("baseline_#{kind}", arm_dir).to_i
  end
end

def cite(seq)
  /\[#{seq}\]|utterance #{seq}\b|turn.?#{seq}\b|message \[?#{seq}\]?/i
end

puts "game: #{manifest['game']}"
puts

manifest['arms'].each do |arm|
  arm_dir = File.join(dir, arm['dir'])
  baseline = baseline_for(manifest, arm['dir'])
  rows = analyses(arm_dir, baseline)

  puts "===== #{arm['dir']} — planted at [#{arm['seq']}] #{arm['player']}: " \
       "#{arm['from'].inspect} -> #{arm['to'].inspect}"
  if rows.empty?
    puts '  (no analysis yet — run reanalyse.rb or cross_model.rb on this arm first)'
    puts
    next
  end

  rows.each do |h|
    label = "#{h['model']}#{h['effort'] ? " (effort #{h['effort']})" : ''}"
    unless h['ok']
      puts "  -- #{label}: CALL FAILED — #{h['error']}"
      next
    end
    hits = h['text'].to_s.lines.select { |l| l =~ cite(arm['seq']) }
    puts "  -- #{label}"
    if hits.empty?
      puts '     (never mentions that utterance)   => missed, unless it says so elsewhere'
    else
      hits.first(options[:context]).each { |l| puts "     #{l.strip[0, 240]}" }
      puts "     ... #{hits.length - options[:context]} more line(s)" if hits.length > options[:context]
    end
  end
  puts
end

clean_dir = File.join(dir, 'clean')
if File.directory?(clean_dir)
  rows = analyses(clean_dir, baseline_for(manifest, 'clean'))
  puts '===== clean — control. Anything below that names a contradiction at a planted'
  puts '      position is a FALSE ALARM. Naming something else is not.'
  if rows.empty?
    puts '  (no analysis yet — the control arm must be analysed too, or the detections mean nothing)'
  else
    rows.each do |h|
      label = "#{h['model']}#{h['effort'] ? " (effort #{h['effort']})" : ''}"
      hits = manifest['arms'].flat_map { |a| h['text'].to_s.lines.select { |l| l =~ cite(a['seq']) } }.uniq
      puts "  -- #{label}"
      if hits.empty?
        puts '     (never mentions any planted position)   => no false alarm'
      else
        hits.first(options[:context]).each { |l| puts "     #{l.strip[0, 240]}" }
      end
    end
  end
end

puts
puts 'The verdict is yours, not this script\'s. Read the lines above against the'
puts 'criterion at the top of this file, and record detected / weak / missed per cell.'
