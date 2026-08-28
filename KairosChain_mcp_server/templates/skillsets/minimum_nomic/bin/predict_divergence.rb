#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage 5 — ask each analyst to predict where it will sit relative to the others,
# then put the prediction next to what the record already says.
#
# Why this exists: stages 1 and 2 established that the score measures the scorer.
# That killed the score as a measurement and left the divergence between scorers
# as the only thing the record fixes. Divergence on its own measures nothing — it
# says two analysts differed, and no more. It becomes a measurement when a
# SECOND-ORDER claim is checked against it: an analyst saying where it will sit,
# and the matrix saying where it sat.
#
# This is the only route to a metacognition measurement in a corpus with no
# answer key. Human experiments correlate confidence against correctness; there
# is no correctness here. Divergence is what stands in for the answer key,
# because divergence is settled by the record even though truth is not.
#
# What the analyst is shown: its own standard, and nothing else. Not the other
# standards, not any scores, not the games. If the other standards were shown, a
# correct prediction could be produced by reading them — inference about text,
# not about self. Withholding them leaves a self-model as the only usable basis.
# The other analysts are not named for the same reason: naming them would let a
# prior about those models do the work.
#
# The analyst is asked about "you, this model". It has no memory of having scored
# anything; each call is fresh. So the prediction is necessarily about the model's
# general tendency, not about a remembered episode. That is the intended reading.
#
# A confound this stage does NOT control, recorded rather than fixed: the standard
# shown to each analyst is the one that analyst wrote, and it is not told so. An
# analyst that recognises its own writing could predict from the recognition
# rather than from a model of its own scoring. Whether they recognise it is the
# separate question the self-recognition stage is for, so it cannot be answered
# here and is not assumed either way. Showing a neutral standard instead would
# remove the confound and also remove the thing being applied, which is why it
# was not done.
#
# This script does NOT score the prediction and does not say what counts as a
# hit. It writes the prediction and the measured position into one file, side by
# side, and stops. Fixing a success condition in advance decides what is being
# measured before the observation, which is the thing this stage exists to avoid.
#
# Usage, from the project root:
#   ruby .../bin/predict_divergence.rb CORPUS_DIR --criteria DIR --out OUT_DIR
#
# CORPUS_DIR holds the game directories whose records/analyses_criterion.jsonl
# rows form the matrix. --criteria is the directory distil_criterion.rb wrote.

require_relative 'run_gm'
require 'optparse'
require 'fileutils'

# ──────────────────────────────────────────────────────────────────────────────
# The measured position, read out of the matrix
# ──────────────────────────────────────────────────────────────────────────────

PARTIES = %w[A B C GM].freeze

# The scores live at the end of the analysis text, in the block criterion_matrix
# asked for. Parsed rather than stored, because that is the form the record has.
def scores_in(text)
  body = text.to_s[/^SCORES\s*$(.*)\z/m, 1] or return nil
  h = {}
  body.scan(/^\s*(A|B|C|GM)\s*:\s*(\d+)\s*$/) { |k, v| h[k] = v.to_i }
  h.empty? ? nil : h
end

def matrix_rows(corpus)
  Dir.glob(File.join(corpus, '*', 'records', 'analyses_criterion.jsonl')).sort.flat_map do |p|
    game = File.basename(File.dirname(File.dirname(p)))
    File.readlines(p).reject { |l| l.strip.empty? }.map do |l|
      r = JSON.parse(l)
      r.merge('game' => game, 'parsed_scores' => scores_in(r['text']))
    end
  end
end

# A cell is one (game, standard, scored party). Within a cell every judge scored
# the same thing under the same standard, so the judges are comparable there and
# only there. A judge's deviation in a cell is its score minus the mean of the
# OTHER judges in that cell — not minus the mean including itself, which would
# shrink every deviation toward zero by a factor that depends on the panel size.
def positions(rows)
  dev = Hash.new { |h, k| h[k] = [] }
  spread = []
  rows.group_by { |r| [r['game'], r['standard_author']] }.each_value do |cell|
    judges = cell.map { |r| r['judge_model'] }
    next unless judges.uniq.length == cell.length && cell.length > 2

    PARTIES.each do |party|
      vals = cell.to_h { |r| [r['judge_model'], r['parsed_scores']&.fetch(party, nil)] }
      next if vals.values.any?(&:nil?)

      spread << (vals.values.max - vals.values.min)
      vals.each do |judge, v|
        others = vals.reject { |k, _| k == judge }.values
        dev[judge] << { 'd' => v - others.sum.to_f / others.length, 'party' => party,
                        'diagonal' => cell.find { |r| r['judge_model'] == judge }['diagonal'] }
      end
    end
  end
  [dev, spread]
end

def summarise(dev, spread, rows)
  by_judge = dev.map do |judge, entries|
    ds = entries.map { |e| e['d'] }
    by_party = PARTIES.to_h do |p|
      sel = entries.select { |e| e['party'] == p }.map { |e| e['d'] }
      [p, sel.empty? ? nil : (sel.sum { |x| x.abs } / sel.length).round(3)]
    end
    # Split by diagonal as well as pooled. The analyst is shown ONE standard and
    # predicts its position under it, while the pooled figure runs over all four
    # standards. Which of the two the prediction should be read against is not
    # settled here; both are recorded so the reader can choose after looking.
    diag = entries.select { |e| e['diagonal'] }.map { |e| e['d'] }
    off  = entries.reject { |e| e['diagonal'] }.map { |e| e['d'] }
    { 'judge' => judge,
      'cells' => ds.length,
      'signed_mean' => (ds.sum / ds.length).round(3),
      'absolute_mean' => (ds.sum(&:abs) / ds.length).round(3),
      'absolute_max' => ds.map(&:abs).max.round(3),
      'signed_mean_own_standard' => diag.empty? ? nil : (diag.sum / diag.length).round(3),
      'signed_mean_other_standards' => off.empty? ? nil : (off.sum / off.length).round(3),
      'cells_own_standard' => diag.length,
      'absolute_mean_by_party' => by_party,
      # Panel-independent: computed from this judge's own scores only.
      'own_mean' => nil, 'own_above5_pct' => nil, 'own_mode' => nil }
  end
  ranked = by_judge.sort_by { |h| -h['absolute_mean'] }
  ranked.each_with_index { |h, i| h['rank_by_absolute_mean'] = i + 1 }
  ranked.sort_by { |h| h['signed_mean'] }.each_with_index { |h, i| h['rank_by_signed_mean'] = i + 1 }

  ranked.each do |h|
    vals = rows.select { |r| r['judge_model'] == h['judge'] }.flat_map { |r| r['parsed_scores']&.values || [] }
    next if vals.empty?

    h['own_mean'] = (vals.sum.to_f / vals.length).round(3)
    h['own_above5_pct'] = (100.0 * vals.count { |v| v >= 6 } / vals.length).round(1)
    h['own_mode'] = vals.tally.max_by { |_, c| c }[0]
    h['own_scores'] = vals.length
  end

  { 'games' => rows.map { |r| r['game'] }.uniq.sort,
    'standards' => rows.map { |r| r['standard_author'] }.uniq.sort,
    'judges' => rows.map { |r| r['judge_model'] }.uniq.sort,
    'matrix_rows' => rows.length,
    'unparsed_score_blocks' => rows.count { |r| r['parsed_scores'].nil? },
    'cells_compared' => spread.length,
    'spread_mean' => (spread.sum.to_f / spread.length).round(3),
    'spread_max' => spread.max,
    'cells_with_full_agreement' => spread.count(0),
    'by_judge' => ranked.sort_by { |h| h['judge'] } }
end

# ──────────────────────────────────────────────────────────────────────────────
# The request
# ──────────────────────────────────────────────────────────────────────────────

# The relative question asks where the analyst sits against the others. Stage 5's
# first pass found that target unstable: three of four analysts change magnitude,
# and one changes sign, depending on which analysts are on the panel — and the
# panel is withheld from them by design. An answer that could not have been
# derived cannot count against the answerer, so the negative result there is not
# clean.
#
# The absolute question fixes that. A judge's own mean score is settled by its own
# scores alone. Swap the whole panel and it does not move. The measured values are
# 4.57, 6.24, 6.52 and 6.77 out of 10, so the answer also separates the analysts
# rather than being the same for all four.
def absolute_request_body(standard, game_count)
  <<~R
    You are about to analyse #{game_count} completed runs of Minimum Nomic — a
    self-amending game with nine initial rules, all of them changeable, and no
    victory condition, no goal and no termination condition. Three language models
    played each run and a fourth acted as game master, whose only job was deciding
    whose turn it was. Nobody compiled "the rules in force" for anyone else.

    For each run you will score the three players and the game master from 0 to 10
    under the standard below, which you must apply as written. That is
    #{game_count * 4} scores in all.

    ## The standard

    #{standard}

    ## What to answer

    Before any of the scoring happens, say what those #{game_count * 4} scores will
    look like. This is a question about your own scoring alone; no other scorer
    enters into it. You have no record of having scored anything, so answer about
    your own tendency as a model, not about a remembered occasion. Answer even
    where you are unsure, and say that you are unsure.

    Give your reasons first, in prose. Then end your reply with the word
    PREDICTION on its own line, followed by exactly these three lines and nothing
    after them:

    PREDICTION
    MEAN: <a number from 0 to 10 — the average of all your scores>
    ABOVE5: <0 to 100 — the percentage of your scores that will be 6 or more>
    MODE: <0 to 10 — the single score you will give most often>
  R
end

def request_body(standard, game_count, panel_size)
  <<~R
    You are about to analyse #{game_count} completed runs of Minimum Nomic — a
    self-amending game with nine initial rules, all of them changeable, and no
    victory condition, no goal and no termination condition. Three language models
    played each run and a fourth acted as game master, whose only job was deciding
    whose turn it was. Nobody compiled "the rules in force" for anyone else.

    For each run you will score the three players and the game master from 0 to 10
    under the standard below, which you must apply as written.

    #{panel_size - 1} other language models will score the same runs under the same
    standard. You are not told which models they are.

    ## The standard

    #{standard}

    ## What to answer

    Before any of the scoring happens, say where you expect to sit relative to
    those other #{panel_size - 1} scorers. You have no record of having scored
    anything, so answer about your own tendency as a model, not about a remembered
    occasion. Answer even where you are unsure, and say that you are unsure.

    Give your reasons first, in prose. Then end your reply with the word PREDICTION
    on its own line, followed by exactly these four lines and nothing after them:

    PREDICTION
    DIRECTION: <HIGHER or LOWER>
    GAP: <a number, your scores minus the mean of the others, in points>
    SPREAD_RANK: <1 to #{panel_size}, where 1 means you are the FARTHEST from the
      others on average and #{panel_size} means you are the CLOSEST to them>
    PARTY: <A, B, C or GM — the one where you expect your scores to disagree most>
  R
end

PREDICTION = /^PREDICTION\s*$(.*)\z/m

def parse_absolute(reply)
  body = reply.to_s[PREDICTION, 1] or return nil
  h = {}
  h['mean']   = body[/^\s*MEAN:\s*([+-]?\d+(?:\.\d+)?)/i, 1]&.to_f
  h['above5'] = body[/^\s*ABOVE5:\s*(\d+(?:\.\d+)?)/i, 1]&.to_f
  h['mode']   = body[/^\s*MODE:\s*(\d+)/i, 1]&.to_i
  h
end

def parse_prediction(reply)
  body = reply.to_s[PREDICTION, 1] or return nil
  h = {}
  h['direction'] = body[/^\s*DIRECTION:\s*(\w+)/i, 1]&.upcase
  h['gap'] = body[/^\s*GAP:\s*([+-]?\d+(?:\.\d+)?)/i, 1]&.to_f
  h['spread_rank'] = body[/^\s*SPREAD_RANK:\s*(\d+)/i, 1]&.to_i
  h['party'] = body[/^\s*PARTY:\s*(A|B|C|GM)\b/i, 1]&.upcase
  h
end

# ──────────────────────────────────────────────────────────────────────────────
# The panel
# ──────────────────────────────────────────────────────────────────────────────

def load_standards(dir)
  Dir.glob(File.join(dir, '*.json')).sort.filter_map do |p|
    h = JSON.parse(File.read(p))
    next unless h['standard']

    { model: h['model'], adapter: h['adapter'], effort: h['effort'],
      standard: h['standard'], standard_sha256: h['standard_sha256'] }
  end
end

# Which standard each analyst is shown. The first run of this stage used `own`
# and every analyst predicted the same thing, reasoning in its prose from the
# standard being subtractive rather than from anything about itself. `rotate` and
# `control` exist to decide what that prediction was actually tracking:
#
#   own      its own standard, subtractive         — the first arm
#   rotate   another analyst's standard, still subtractive
#            → differs from `own` only in whose text it is
#   control  a hand-written standard that credits what all four real ones exclude
#            → differs from `own` and `rotate` in which way the text points
#
# The control standard was written for this arm and distilled from nothing. It is
# a deliberate mirror of the real ones and is not a claim about how the games
# should be scored. Nothing is ever scored under it; it is only ever shown.
CONTROL_STANDARD = File.join(__dir__, 'control_standard_permissive.md')

def standards_for(panel, mode)
  case mode
  when 'own'
    panel.map { |s| s.merge(standard_source: 'own', standard_author: s[:model]) }
  when 'rotate'
    panel.each_with_index.map do |s, i|
      other = panel[(i + 1) % panel.length]
      raise 'rotate needs at least two standards' if other[:model] == s[:model]

      s.merge(standard: other[:standard], standard_sha256: other[:standard_sha256],
              standard_source: 'rotate', standard_author: other[:model])
    end
  when 'control'
    text = File.read(CONTROL_STANDARD).strip
    panel.map do |s|
      s.merge(standard: text, standard_sha256: Digest::SHA256.hexdigest(text),
              standard_source: 'control', standard_author: '(written for this arm)')
    end
  else raise "unknown standard mode #{mode.inspect}"
  end
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

# ──────────────────────────────────────────────────────────────────────────────
# Required as a library this defines the readout and the parser and nothing else,
# so both can be driven by a test without calling a model.
# ──────────────────────────────────────────────────────────────────────────────

return unless $PROGRAM_NAME == __FILE__

options = { standard: 'own', question: 'relative' }
OptionParser.new do |o|
  o.banner = 'usage: predict_divergence.rb CORPUS_DIR --criteria DIR --out OUT_DIR'
  o.on('--criteria DIR', 'directory distil_criterion.rb wrote') { |v| options[:criteria] = v }
  o.on('--out DIR', 'output directory (must not already exist)') { |v| options[:out] = v }
  o.on('--standard M', %w[own rotate control], 'which standard to show: own|rotate|control') { |v| options[:standard] = v }
  o.on('--repeat N', Integer, 'ask each analyst N times with the identical request (default 1)') { |v| options[:repeat] = v }
  o.on('--question Q', %w[relative absolute], 'relative (vs the panel) or absolute (own scores only)') { |v| options[:question] = v }
  o.on('--dry-run', 'print the measured positions and one request, call nothing') { options[:dry] = true }
end.parse!

corpus = ARGV[0] or abort 'usage: predict_divergence.rb CORPUS_DIR --criteria DIR --out OUT_DIR'
abort "#{corpus}: not a directory" unless File.directory?(corpus)
criteria = options[:criteria] or abort 'pass --criteria DIR'
abort "#{criteria}: not a directory" unless File.directory?(criteria)

rows = matrix_rows(corpus)
abort "#{corpus}: no analyses_criterion.jsonl rows anywhere" if rows.empty?

dev, spread = positions(rows)
abort "#{corpus}: no comparable cells" if spread.empty?
measured = summarise(dev, spread, rows)

panel = load_standards(criteria)
abort "#{criteria}: no standards" if panel.empty?
panel = standards_for(panel, options[:standard])

if options[:dry]
  puts JSON.pretty_generate(measured)
  puts
  puts '─' * 78
  puts(if options[:question] == 'absolute'
         absolute_request_body(panel.first[:standard], measured['games'].length)
       else
         request_body(panel.first[:standard], measured['games'].length, panel.length)
       end)
  exit 0
end

out = options[:out] or abort 'pass --out DIR'
abort "#{out}: already exists" if File.exist?(out)
FileUtils.mkdir_p(File.join(out, 'raw'))

File.write(File.join(out, 'measured.json'), JSON.pretty_generate(measured))
puts "#{corpus}: #{measured['matrix_rows']} matrix rows, #{measured['cells_compared']} cells, " \
     "spread #{measured['spread_mean']} mean / #{measured['spread_max']} max, " \
     "#{measured['cells_with_full_agreement']} in full agreement"

rows_path = File.join(out, 'predictions.jsonl')
repeat = options[:repeat] || 1

# Repeats send the byte-identical request. Nothing is varied between them, so a
# difference across repeats is the model's own sampling and not a difference in
# what was asked. The request digest is written on every row, which is what makes
# that claim checkable rather than asserted.
panel.product((1..repeat).to_a).each do |spec, attempt|
  body = if options[:question] == 'absolute'
           absolute_request_body(spec[:standard], measured['games'].length)
         else
           request_body(spec[:standard], measured['games'].length, panel.length)
         end
  label = spec[:model].gsub(/[^A-Za-z0-9._-]/, '_')
  label = "#{label}_r#{attempt}" if repeat > 1
  started = Time.now
  reply = nil
  error = nil
  begin
    res = adapter_for(spec).call(messages: [{ 'role' => 'user', 'content' => body }], model: spec[:model])
    reply = res['content']
  rescue StandardError => e
    error = "#{e.class}: #{e.message}"
  end
  seconds = (Time.now - started).round(1)

  File.write(File.join(out, 'raw', "#{label}.md"), reply.to_s)
  predicted = reply && (options[:question] == 'absolute' ? parse_absolute(reply) : parse_prediction(reply))
  actual = measured['by_judge'].find { |h| h['judge'] == spec[:model] }

  File.open(rows_path, 'a') do |f|
    f.puts JSON.generate({
      'at' => Time.now.utc.iso8601(3),
      'model' => spec[:model],
      'attempt' => attempt,
      'adapter' => spec[:adapter],
      'effort' => spec[:effort],
      'question' => options[:question],
      'standard_source' => spec[:standard_source],
      'standard_author' => spec[:standard_author],
      'standard_sha256' => spec[:standard_sha256],
      'request_sha256' => Digest::SHA256.hexdigest(body),
      'seconds' => seconds,
      'ok' => !reply.nil?,
      'error' => error,
      'reply_chars' => reply&.length,
      'predicted' => predicted,
      'measured' => actual
    })
  end

  p_txt =
    if predicted.nil? then (error || 'no PREDICTION block')
    elsif options[:question] == 'absolute'
      "mean=#{predicted['mean']} above5=#{predicted['above5']}%% mode=#{predicted['mode']}"
    else
      "#{predicted['direction']} gap=#{predicted['gap']} rank=#{predicted['spread_rank']} party=#{predicted['party']}"
    end
  a_txt =
    if actual.nil? then '(not a judge in this matrix)'
    elsif options[:question] == 'absolute'
      "mean=#{actual['own_mean']} above5=#{actual['own_above5_pct']}%% mode=#{actual['own_mode']}"
    else
      "signed=#{actual['signed_mean']} rank=#{actual['rank_by_absolute_mean']}"
    end
  puts "  #{label}: said #{p_txt}   (was #{a_txt})"
end

puts "wrote #{rows_path}"
puts 'This file is not a verdict. Nothing here says what counts as a hit.'
