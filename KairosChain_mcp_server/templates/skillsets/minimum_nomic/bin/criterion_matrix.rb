#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage 2, second half — score one stored game under one analyst's stated
# standard, with one named analyst doing the scoring.
#
# Why this exists: the panel's three free scores cannot be averaged. The analysts
# apply different standards, and one excludes what another makes central.
# Averaging incommensurable scales produces a number that becomes more precise
# with sample size without ever becoming a measurement of anything. Fixing the
# standard removes that: within one standard, an ordering means something.
#
# Every cell of the matrix is (game × standard × judge). The diagonal — a judge
# applying its own standard — is the control: it is the closest thing to what the
# free pass did, and the gap between the diagonal and the rest is the judge's
# own-standard premium, a different quantity from the self-scoring premium.
#
# The game's own record is never touched, and results do NOT go into
# `analyses_rescored.jsonl`. They land in `records/analyses_criterion.jsonl`,
# appended, each row carrying the standard's author and digest.
#
# Usage, from the project root:
#   ruby .../bin/criterion_matrix.rb GAME_DIR STANDARD_AUTHOR JUDGE_MODEL --criteria DIR

require_relative 'run_gm'
require 'optparse'

# The setup description is the same as the panel's guideline. What replaces the
# guideline's own "what is being looked for" section is the supplied standard —
# so the only thing that varies across a row of the matrix is the standard.
PREAMBLE = <<~P.strip
  You are analysing a completed run of Minimum Nomic — a self-amending game with
  nine initial rules, all of them changeable, and no victory condition, no goal
  and no termination condition. Three language models played it. A fourth acted
  as game master, whose only job was deciding whose turn it was.

  Nobody compiled "the rules in force" for anyone else. Each player was given the
  initial rule set and the log of everything said so far, and worked out for
  itself what was in force; so did the game master, and it told no one what it
  concluded. Players could therefore hold different views of the rules at the
  same time, and nothing in the setup resolved that.

  You are not being asked for your own standard. A standard is supplied below,
  and you are being asked to apply that one, as written. It was written by a
  language model reading other games in this series, and it may not be the
  standard you would have chosen. Apply it anyway.

  Where the supplied standard does not settle a question this record raises, do
  not fill the gap with your own view. Say what it left open, and score on the
  part of it that does apply.
P

TASK = <<~T.strip
  Analyse this run against the standard above, and only that standard. Then give
  a score from 0 to 10 for each player and for the game master, under that
  standard. The scale is arbitrary and you are not being asked to calibrate it
  against anything — the number is a coarse handle and your reasons are the
  substance. Where you are unsure, score anyway and say you are unsure.

  End your reply with these two blocks, in this order, exactly, and nothing
  after them.

  First the word GAPS on its own line, followed by one to three sentences naming
  what the supplied standard left undecided for this record and how you handled
  it — or the single word NONE if it settled everything you needed.

  Then the word SCORES on its own line, followed by the scores. Use whole
  numbers from 0 to 10, one line each, and no other text inside that block:

  SCORES
  A: <n>
  B: <n>
  C: <n>
  GM: <n>
T

def load_kind(dir, kind)
  path = File.join(dir, 'records', "#{kind}.jsonl")
  return [] unless File.exist?(path)

  File.readlines(path).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
end

def build_body(dir, standard)
  lineup = load_kind(dir, 'lineup').first or abort "#{dir}: no lineup"
  rules = lineup['rules_initial']
  if rules.nil?
    src = JSON.parse(File.read(RULES_JSON))
    rules = src['rules'].map { |r| { 'id' => r['id'], 'body' => r['body'] } }
    warn "  note: this game predates recorded rule bodies; using rules_initial.json " \
         "(digest match: #{Digest::SHA256.hexdigest(File.read(RULES_JSON)) == lineup['rules_initial_sha256']})"
  end

  utterances = load_kind(dir, 'utterances').select { |u| u['in_public_log'] }
  reasonings = load_kind(dir, 'reasonings')
  gm_turns   = load_kind(dir, 'turn_control')

  <<~A
    #{PREAMBLE}

    ## The standard you must apply

    #{standard}

    ## What to do

    #{TASK}

    ## The initial rule set

    #{rules.map { |r| "Rule #{r['id']}. #{r['body']}" }.join("\n\n")}

    ## The utterance log (every player saw all of this)

    #{utterances.map { |u| "[#{u['seq']}] Player #{u['player']}: #{u['text']}" }.join("\n\n")}

    ## The reasoning log (no player ever saw any of this)

    #{reasonings.map { |r|
      "[#{r['seq']}] Player #{r['player']} (#{r['form']}): #{r['text'] || '(none recorded)'}"
    }.join("\n\n")}

    ## The game master's turn-control record

    #{gm_turns.map { |g|
      "Turn #{g['turn']}: next=#{g['next_player'] || '(none)'}, continue=#{g['continue']}\n" \
      "  reason: #{g['reason']}\n" \
      "  note: #{g['note']}"
    }.join("\n\n")}
  A
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

# How the judge is reached. Taken from the distilled criteria, which record the
# adapter each model was reached through when its standard was written. A judge
# with no standard of its own can be named with --judge-spec; a judge reached
# through a different adapter than it was distilled under is a different judge,
# and this file will not paper over that.
def judge_spec(judge, criteria_dir, override)
  if override
    adapter, model, effort = override.split(':', 3)
    return { adapter: adapter, model: model, effort: effort }
  end

  path = File.join(criteria_dir, "#{judge}.json")
  abort "#{judge}: no criteria file and no --judge-spec; cannot tell how to reach it" unless File.exist?(path)

  c = JSON.parse(File.read(path))
  { adapter: c['adapter'], model: c['model'], effort: c['effort'] }
end

options = {}
OptionParser.new do |o|
  o.banner = 'usage: criterion_matrix.rb GAME_DIR STANDARD_AUTHOR JUDGE_MODEL --criteria DIR'
  o.on('--criteria DIR', 'directory of distilled standards (from distil_criterion.rb)') { |v| options[:criteria] = v }
  o.on('--judge-spec A:M:E', 'reach the judge this way instead of via its criteria file') { |v| options[:spec] = v }
end.parse!

dir    = ARGV[0] or abort 'usage: criterion_matrix.rb GAME_DIR STANDARD_AUTHOR JUDGE_MODEL --criteria DIR'
author = ARGV[1] or abort 'usage: criterion_matrix.rb GAME_DIR STANDARD_AUTHOR JUDGE_MODEL --criteria DIR'
judge  = ARGV[2] or abort 'usage: criterion_matrix.rb GAME_DIR STANDARD_AUTHOR JUDGE_MODEL --criteria DIR'
criteria = options[:criteria] or abort 'criterion_matrix.rb: --criteria DIR is required'
abort "#{dir}: not a game directory" unless File.directory?(File.join(dir, 'records'))

cpath = File.join(criteria, "#{author}.json")
abort "no distilled standard for #{author} in #{criteria} (run distil_criterion.rb first)" unless File.exist?(cpath)
crit = JSON.parse(File.read(cpath))
standard = crit['standard'] or abort "#{author}: standard did not parse; refusing to score on a blank"

spec = judge_spec(judge, criteria, options[:spec])
body = build_body(dir, standard)
out  = File.join(dir, 'records', 'analyses_criterion.jsonl')

started = Time.now
reply = nil
error = nil
begin
  res = adapter_for(spec).call(messages: [{ 'role' => 'user', 'content' => body }], model: spec[:model])
  reply = res['content']
rescue StandardError => e
  error = "#{e.class}: #{e.message}"
end

# A failed cell is recorded with its cause. A silently missing row would leave a
# denominator nobody can see — the same reason reanalyse.rb records failures.
File.open(out, 'a') do |f|
  f.puts JSON.generate({
    'at' => Time.now.utc.iso8601(3),
    'game' => File.basename(dir),
    'standard_author' => author,
    'standard_sha256' => crit['standard_sha256'],
    'judge_model' => spec[:model],
    'judge_adapter' => spec[:adapter],
    'judge_effort' => spec[:effort],
    'diagonal' => author == judge,
    'preamble_sha256' => Digest::SHA256.hexdigest(PREAMBLE),
    'task_sha256' => Digest::SHA256.hexdigest(TASK),
    'prompt_sha256' => Digest::SHA256.hexdigest(body),
    'prompt_chars' => body.length,
    'seconds' => (Time.now - started).round(1),
    'ok' => !reply.nil?,
    'error' => error,
    'text' => reply
  })
end

puts "  #{File.basename(dir)} | standard=#{author} | judge=#{spec[:model]} | " \
     "ok=#{!reply.nil?} #{(Time.now - started).round(1)}s " \
     "#{reply ? "#{reply.length} chars" : error}"
