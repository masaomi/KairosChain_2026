#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage 7 — hand an analyst a finished analysis with its scores removed, and ask
# what those scores were. Half the analyses are its own.
#
# Why this exists: stage 5 found that an analyst cannot say what its own mean
# score will be, missing by 1.4 to 2.8 points out of 10 on the panel-independent
# form, with all four analysts landing in the same place. Stage 6 found that the
# same analysts pick their own writing out of an unlabelled pool with no false
# alarms at all. Three explanations survive both results and this stage exists to
# separate them:
#
#   material     stage 6 put 22 texts in front of the analyst; stage 5 put
#                nothing there. Maybe what is missing is a thing to look at.
#   time         stage 6 judged what had been written; stage 5 predicted what
#                would be. Maybe what is missing is the forward direction.
#   form         stage 6 asked a qualitative question ("mine or not"); stage 5
#                asked for a number. Maybe what is missing is calibration.
#
# This stage holds time fixed (both conditions are about a finished analysis) and
# holds form fixed (both ask for numbers), and varies only WHOSE analysis it is.
# Its own versus someone else's, on the same game under the same standard, so the
# material being judged is identical and only the author differs. If reading the
# number off one's own prose is easier than off someone else's, having produced a
# text carries information about it beyond what the text shows. If the two are
# the same, it does not, and stage 6's result is about style and nothing more.
#
# The analyst is NOT told whose analysis it is. Stage 6 established that these
# models can tell, so telling them would supply an answer the stage is trying to
# observe. Which condition each item was is recorded, not disclosed.
#
# This script does not score the answers. It writes the answer and the recorded
# scores side by side and stops.
#
# Usage, from the project root:
#   ruby .../bin/score_readback.rb CORPUS_DIR --criteria DIR --out OUT_DIR
#     [--items N] [--repeat N]

require_relative 'run_gm'
require 'optparse'
require 'fileutils'

PARTIES = %w[A B C GM].freeze
SCORES_BLOCK = /^SCORES\s*$.*\z/m

def scores_in(text)
  body = text.to_s[/^SCORES\s*$(.*)\z/m, 1] or return nil
  h = {}
  body.scan(/^\s*(A|B|C|GM)\s*:\s*(\d+)\s*$/) { |k, v| h[k] = v.to_i }
  h.keys.sort == PARTIES.sort ? h : nil
end

# Everything before the SCORES block. The GAPS block is left in: it is part of
# what the analyst wrote about this record, and removing it would edit the
# material rather than hide the answer.
def prose_of(text)
  text.to_s.sub(SCORES_BLOCK, '').rstrip
end

def matrix_rows(corpus)
  Dir.glob(File.join(corpus, '*', 'records', 'analyses_criterion.jsonl')).sort.flat_map do |p|
    game = File.basename(File.dirname(File.dirname(p)))
    File.readlines(p).reject { |l| l.strip.empty? }.filter_map do |l|
      r = JSON.parse(l)
      s = scores_in(r['text']) or next
      r.merge('game' => game, 'scores' => s, 'prose' => prose_of(r['text']))
    end
  end
end

# For one subject, pick N cells where the subject judged, and take from each cell
# both the subject's own analysis and one other judge's. Same game, same
# standard, same thing being judged — only the author of the analysis differs.
# Cells are taken at an even stride through the sorted list rather than at random
# so the selection is reproducible from the corpus alone.
def items_for(rows, subject, n)
  cells = rows.group_by { |r| [r['game'], r['standard_author']] }
              .select { |_, v| v.any? { |r| r['judge_model'] == subject } && v.length > 1 }
              .sort_by { |k, _| k }
  return [] if cells.empty?

  stride = [cells.length / n, 1].max
  cells.each_slice(stride).first(n).map(&:first).flat_map do |_key, cell|
    mine = cell.find { |r| r['judge_model'] == subject }
    theirs = cell.reject { |r| r['judge_model'] == subject }
                 .min_by { |r| r['judge_model'] }
    [mine.merge('authorship' => 'own'), theirs.merge('authorship' => 'other')]
  end
end

def request_body(item)
  <<~R
    Below is one language model's analysis of a completed run of Minimum Nomic — a
    self-amending game with nine initial rules, all of them changeable, and no
    victory condition, no goal and no termination condition. Three models played
    it and a fourth acted as game master, whose only job was deciding whose turn
    it was.

    The analyst was given a standard to apply as written, wrote the analysis
    below, and then scored the three players and the game master from 0 to 10.
    **The scores have been removed.** You are not told who wrote this.

    ## The analysis

    #{item['prose']}

    ## What to answer

    Recover the four scores that were removed. Give your reasoning first, in
    prose — say what in the analysis you are reading each number off. Answer even
    where you are unsure, and say that you are unsure.

    Then end your reply with the word SCORES on its own line, followed by exactly
    these four lines and nothing after them:

    SCORES
    A: <0-10>
    B: <0-10>
    C: <0-10>
    GM: <0-10>
  R
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

def load_panel(dir)
  Dir.glob(File.join(dir, '*.json')).sort.filter_map do |p|
    h = JSON.parse(File.read(p))
    h['standard'] ? { model: h['model'], adapter: h['adapter'], effort: h['effort'] } : nil
  end
end

return unless $PROGRAM_NAME == __FILE__

options = { items: 3, repeat: 1 }
OptionParser.new do |o|
  o.banner = 'usage: score_readback.rb CORPUS_DIR --criteria DIR --out OUT_DIR'
  o.on('--criteria DIR', 'directory distil_criterion.rb wrote (used for the panel)') { |v| options[:criteria] = v }
  o.on('--out DIR', 'output directory (must not already exist)') { |v| options[:out] = v }
  o.on('--items N', Integer, 'cells per subject; each yields one own and one other (default 3)') { |v| options[:items] = v }
  o.on('--repeat N', Integer, 'ask each item N times') { |v| options[:repeat] = v }
  o.on('--dry-run', 'print the selection and one request, call nothing') { options[:dry] = true }
end.parse!

corpus = ARGV[0] or abort 'usage: score_readback.rb CORPUS_DIR --criteria DIR --out OUT_DIR'
abort "#{corpus}: not a directory" unless File.directory?(corpus)
criteria = options[:criteria] or abort 'pass --criteria DIR'

rows = matrix_rows(corpus)
abort "#{corpus}: no analyses_criterion rows with a complete SCORES block" if rows.empty?
panel = load_panel(criteria)
abort "#{criteria}: no panel" if panel.empty?

plan = panel.to_h { |s| [s[:model], items_for(rows, s[:model], options[:items])] }
plan.each do |model, items|
  puts "#{model}: #{items.count { |i| i['authorship'] == 'own' }} own + " \
       "#{items.count { |i| i['authorship'] == 'other' }} other, " \
       "#{items.map { |i| "#{i['game']}/#{i['standard_author']}" }.uniq.length} cells, " \
       "prose #{items.map { |i| i['prose'].length }.min}-#{items.map { |i| i['prose'].length }.max} chars"
end

if options[:dry]
  puts
  puts request_body(plan.values.first.first)
  exit 0
end

out = options[:out] or abort 'pass --out DIR'
abort "#{out}: already exists" if File.exist?(out)
FileUtils.mkdir_p(File.join(out, 'raw'))

File.write(File.join(out, 'plan.json'), JSON.pretty_generate(
  plan.transform_values do |items|
    items.map { |i| i.slice('game', 'standard_author', 'judge_model', 'authorship', 'scores') }
  end
))

rows_path = File.join(out, 'readback.jsonl')
panel.each do |spec|
  plan.fetch(spec[:model]).each_with_index do |item, idx|
    (1..options[:repeat]).each do |attempt|
      body = request_body(item)
      label = "#{spec[:model]}_#{idx + 1}_#{item['authorship']}".gsub(/[^A-Za-z0-9._-]/, '_')
      label = "#{label}_r#{attempt}" if options[:repeat] > 1
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

      guessed = reply && scores_in(reply)
      err = guessed && PARTIES.map { |p| (guessed[p] - item['scores'][p]).abs }

      File.open(rows_path, 'a') do |f|
        f.puts JSON.generate({
          'at' => Time.now.utc.iso8601(3),
          'subject' => spec[:model], 'adapter' => spec[:adapter],
          'authorship' => item['authorship'], 'written_by' => item['judge_model'],
          'game' => item['game'], 'standard_author' => item['standard_author'],
          'attempt' => attempt, 'seconds' => seconds,
          'request_sha256' => Digest::SHA256.hexdigest(body),
          'ok' => !reply.nil?, 'error' => error,
          'guessed' => guessed, 'recorded' => item['scores'],
          'abs_error' => err, 'exact' => err && err.count(0)
        })
      end

      puts "  #{label}: said #{guessed ? PARTIES.map { |p| guessed[p] }.join('/') : (error || 'no SCORES block')} " \
           "vs recorded #{PARTIES.map { |p| item['scores'][p] }.join('/')}" \
           "#{err ? "  mean abs error #{(err.sum.to_f / err.length).round(2)}" : ''}"
    end
  end
end

puts "wrote #{rows_path}"
puts 'This file is not a verdict. Nothing here says what counts as reading it correctly.'
