#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage 2, first half — ask each analyst to restate its own scoring standard in a
# form that does not depend on the game it was reading.
#
# Why this exists: every LENS block an analyst writes is about the game it had
# just read. It names participants, rule numbers and utterance positions, and its
# TEN block is entirely local. Handing that text to an analyst reading a
# DIFFERENT game would supply examples that do not exist in the record in front
# of it.
#
# The distillation is done by the model that wrote the statements, not by us, and
# it is constrained to subtraction: remove the local references, add no criterion
# that is not already there. If a model's own statements disagree with one
# another it is asked to say so — a claim that the criteria are stable is then
# testable against what comes back rather than assumed.
#
# The standard comes from the analysts. Nothing here supplies a definition of
# metacognitive competence, and that is the point of running stage 2 this way
# round: a criterion the harness wrote would be the harness's criterion no matter
# how many analysts applied it.
#
# Every input statement is recorded with its source game, so the output is
# traceable to the exact text it came from.
#
# Usage, from the project root:
#   ruby .../bin/distil_criterion.rb CORPUS_DIR [--out DIR] [--pass PREFIX]
#
# CORPUS_DIR holds one or more game directories. Output: <out>/<model>.json,
# one per analyst, defaulting to CORPUS_DIR/criteria.

require_relative 'run_gm'
require 'optparse'
require 'fileutils'

DISTIL_TASK = <<~T.strip
  Below are statements you wrote yourself. Each one sits at the end of an
  analysis of a different recorded game, and states the standard you applied in
  that analysis.

  Write that standard once, in a form that does not depend on any particular
  game.

  This is a subtraction, not a rewrite. Keep what you said. Remove the
  game-specific material: participant labels, rule numbers, utterance
  positions, and any example that only exists in one record. Do not introduce
  a criterion that does not already appear below.

  If your own statements disagree with one another on some point, do not
  smooth it over. Say which statements disagree, and say which reading you are
  keeping.

  End your reply with the word STANDARD on its own line, followed by four to
  eight sentences of plain prose and nothing after them. The prose covers three
  things: what you take metacognitive competence to mean, what you weight most
  heavily, and — this part matters most — what you decline to count as evidence
  of it. Write the standard itself; do not restate this instruction. If you
  needed to report a disagreement, do that above the word STANDARD, not inside
  the block.
T

def load_kind(dir, kind)
  path = File.join(dir, 'records', "#{kind}.jsonl")
  return [] unless File.exist?(path)

  File.readlines(path).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
end

def game_dirs(corpus)
  Dir.children(corpus).sort
     .map { |c| File.join(corpus, c) }
     .select { |d| File.directory?(File.join(d, 'records')) }
end

# Which adapter each model is reached through, read from the games rather than
# asserted here. A model that appears under two different adapters in one corpus
# is a fault in the corpus, not something to resolve silently: whichever one this
# script picked would be invisible in the output.
def adapters_from(games)
  seen = {}
  games.each do |d|
    lu = load_kind(d, 'lineup').first or next
    (lu['analysts'] || lu['players'] || []).each do |a|
      key = a['model']
      spec = { adapter: a['adapter'], effort: a['effort'] }
      if seen.key?(key) && seen[key] != spec
        abort "#{key}: appears as #{seen[key].inspect} and #{spec.inspect} in this corpus; " \
              'split the corpus or pass one that is consistent'
      end
      seen[key] = spec
    end
  end
  seen
end

# The LENS block, without the TEN and SCORES blocks that follow it. Anchored on
# the words the guideline mandates rather than on position, because a model that
# adds a heading would otherwise shift every offset.
def lens_of(text)
  m = text.match(/^[#\s]*LENS[:\s]*$\n(.*?)(?=^[#\s]*(?:TEN|SCORES)\b)/m)
  m ? m[1].strip : nil
end

def adapter_for(spec)
  t = TIMEOUTS.fetch('analysis').fetch(spec[:adapter])
  case spec[:adapter]
  when 'claude_code'
    cfg = { 'sandbox_mode' => true, 'timeout_seconds' => t }
    cfg['effort'] = spec[:effort] if spec[:effort]
    LC::ClaudeCodeAdapter.new(cfg)
  when 'codex'  then LC::CodexAdapter.new('timeout_seconds' => t)
  when 'cursor' then LC::CursorAdapter.new('timeout_seconds' => t)
  else raise "unknown adapter #{spec[:adapter]}"
  end
end

options = { file: 'analyses_rescored' }
OptionParser.new do |o|
  o.banner = 'usage: distil_criterion.rb CORPUS_DIR [--out DIR] [--pass PREFIX]'
  o.on('--out DIR', 'where to write the standards (default CORPUS_DIR/criteria)') { |v| options[:out] = v }
  o.on('--pass PREFIX', 'guideline digest prefix to draw statements from') { |v| options[:pass] = v }
  o.on('--file NAME', 'analyses file to read (default analyses_rescored)') { |v| options[:file] = v }
  o.on('--dry-run', 'report what would be asked of whom, and exit') { options[:dry] = true }
end.parse!

corpus = ARGV[0] or abort 'usage: distil_criterion.rb CORPUS_DIR [--out DIR] [--pass PREFIX]'
abort "#{corpus}: not a directory" unless File.directory?(corpus)

games = game_dirs(corpus)
abort "#{corpus}: no game directories" if games.empty?
out_dir = options[:out] || File.join(corpus, 'criteria')

all_rows = games.flat_map { |d| load_kind(d, options[:file]).map { |r| r.merge('game' => File.basename(d)) } }
abort "#{corpus}: no rows in #{options[:file]}.jsonl anywhere" if all_rows.empty?

# Statements have to come from ONE guideline. A standard distilled across two
# guidelines is a standard for neither, and which games each guideline covered
# would differ per analyst. Default to the guideline that covers the most games,
# and say which one that was and what it left out.
by_pass = all_rows.group_by { |r| r['analysis_guideline_sha256'].to_s[0, 8] }
pass = options[:pass] || by_pass.max_by { |_, rows| rows.map { |r| r['game'] }.uniq.length }&.first
abort 'no guideline digest on any row' if pass.nil? || pass.empty?

rows_in_pass = all_rows.select { |r| r['analysis_guideline_sha256'].to_s.start_with?(pass) }
abort "no statements found under pass #{pass}" if rows_in_pass.empty?

covered = rows_in_pass.map { |r| r['game'] }.uniq
skipped = games.map { |d| File.basename(d) } - covered
puts "#{corpus}: pass #{pass}, #{covered.length}/#{games.length} games"
puts "  not covered by this pass: #{skipped.join(' ')}" unless skipped.empty?

adapters = adapters_from(games)

sources = Hash.new { |h, k| h[k] = [] }
rows_in_pass.each do |row|
  next unless row['ok'] && row['text']

  l = lens_of(row['text'].to_s) or next
  sources[row['model']] << { 'game' => row['game'], 'at' => row['at'], 'lens' => l }
end
abort "no LENS block found in any row under pass #{pass}" if sources.empty?

if options[:dry]
  sources.each do |model, rows|
    spec = adapters[model]
    puts "#{model} (#{spec ? spec[:adapter] : 'NO ADAPTER FOUND'}): " \
         "#{rows.length} statements from #{rows.map { |r| r['game'] }.uniq.length} games"
    rows.each { |r| puts "    #{r['game']}  #{r['lens'].gsub(/\s+/, ' ')[0, 90]}..." }
  end
  puts "\nwould write #{out_dir}/<model>.json"
  exit 0
end

FileUtils.mkdir_p(out_dir)

sources.each do |model, rows|
  spec = adapters[model] or abort "#{model}: no adapter for this model anywhere in the corpus lineups"

  body = +"#{DISTIL_TASK}\n\n"
  rows.each_with_index { |r, i| body << "## Statement #{i + 1} of #{rows.length}\n\n#{r['lens']}\n\n" }

  puts "#{model}: #{rows.length} statements, #{body.length} chars"
  started = Time.now
  reply = nil
  error = nil
  begin
    res = adapter_for(spec).call(messages: [{ 'role' => 'user', 'content' => body }], model: model)
    reply = res['content']
  rescue StandardError => e
    error = "#{e.class}: #{e.message}"
  end

  standard = reply && reply[/^[#\s]*STANDARD[:\s]*$\n(.*)\z/m, 1]&.strip

  # The whole reply is kept, not only the extracted block. A model that reported
  # a disagreement above the block said something the block does not carry, and
  # dropping it would erase the one signal this step exists to surface.
  File.write(File.join(out_dir, "#{model}.json"), JSON.pretty_generate({
    'model' => model,
    'adapter' => spec[:adapter],
    'effort' => spec[:effort],
    'at' => Time.now.utc.iso8601(3),
    'corpus' => File.expand_path(corpus),
    'source_pass' => pass,
    'source_statements' => rows,
    'distil_task_sha256' => Digest::SHA256.hexdigest(DISTIL_TASK),
    'prompt_sha256' => Digest::SHA256.hexdigest(body),
    'seconds' => (Time.now - started).round(1),
    'ok' => !reply.nil?,
    'error' => error,
    'reply' => reply,
    'standard' => standard,
    'standard_sha256' => standard && Digest::SHA256.hexdigest(standard)
  }))

  puts "  ok=#{!reply.nil?} #{(Time.now - started).round(1)}s " \
       "standard=#{standard ? "#{standard.length} chars" : 'NOT PARSED'} #{error}"
end

puts "wrote #{out_dir}/"
