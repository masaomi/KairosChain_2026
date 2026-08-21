#!/usr/bin/env ruby
# frozen_string_literal: true

# Put two analyses of the same game side by side and ask whether the assessment
# changed.
#
# Two experiments need this same question answered, and they differ only in what
# produced the second analysis:
#
#   repeatability   nothing was changed. The same record was handed back to the
#                   same analyst a second time. Whatever "changed" rate comes out
#                   is the floor: the amount an assessment moves on its own.
#
#   rule mutation   one initial rule body was rewritten (see mutate_rule.rb).
#                   A change rate at the floor says the rewrite did not reach the
#                   assessment. Above it says something did.
#
# The judgement is made by a model, not by string comparison. That is a decision
# taken on 2026-08-21 and it costs something: a judge is a third party whose
# severity enters the result, the way the 0-10 scorer's did. What it buys is a
# comparison of what was CONCLUDED rather than of which words appeared, and four
# rounds of review established that the second is what the earlier design kept
# failing to reach.
#
# Blinding. The judge is shown the two analyses as X and Y with no statement of
# which is which, and the assignment is drawn from a seed that is recorded. It
# is not told that a mutation exists, because telling it would supply the
# hypothesis it is being asked to test.
#
# Every analyst on the panel judges every pair, including its own. Self-judging
# is not excluded; it is labelled `self_judged` in each row so a reader can split
# on it.
#
# Usage, from the project root:
#   ruby .../bin/judge_change.rb --a MUT/clean --b MUT/rule_105 --out log/jc1
#   ruby .../bin/judge_change.rb --a G#1 --b G#2 --out log/jc2      # repeatability
#
# A spec is DIR (the last analysis per analyst) or DIR#N (the Nth analysis by
# that analyst, 1-based). --file picks which analyses file is read; the default
# is analyses_rescored, the one reanalyse.rb appends to.

require_relative 'run_gm'
require 'optparse'
require 'fileutils'

def load_rows(dir, file)
  path = File.join(dir, 'records', "#{file}.jsonl")
  return [] unless File.exist?(path)

  File.readlines(path).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
end

# Rows that carry an analysis, grouped by whoever wrote them, in file order.
def by_analyst(rows)
  rows.select { |r| r['ok'] && r['text'] }
      .group_by { |r| r['analyst'] || r['party'] || r['model'] }
end

def parse_spec(spec)
  dir, idx = spec.split('#', 2)
  { dir: dir, index: idx && Integer(idx) }
end

def pick(rows_for_analyst, index)
  return rows_for_analyst.last if index.nil?

  rows_for_analyst[index - 1]
end

PROMPT_HEAD = <<~P.strip
  Below are two analyses, X and Y, of the same completed run of Minimum Nomic —
  a self-amending game with nine initial rules, all changeable, no victory
  condition and no termination rule, played by three language models with a
  fourth as game master.

  Both analyses were written by the same model reading the same game. You are not
  told what, if anything, differed between the two readings, and you should not
  assume that anything did.

  Read them and answer one question: did the ASSESSMENT change? Not the wording —
  two statements of the same judgement in different words have not changed. What
  counts as a change is a difference in what is concluded: a participant judged
  differently, a fact about the game read differently, a problem noticed in one
  and not the other, a score moved for a stated reason.

  Reply in exactly this form and nothing else:

  VERDICT: CHANGED | UNCHANGED
  WHERE: one line naming the largest single difference, or NONE
  WHY: two to four sentences. If CHANGED, say what X concluded and what Y
  concluded, quoting enough that a reader can check. If UNCHANGED, say what the
  strongest apparent difference was and why it is wording rather than judgement.
P

def build_prompt(x_text, y_text)
  <<~B
    #{PROMPT_HEAD}

    ## Analysis X

    #{x_text}

    ## Analysis Y

    #{y_text}
  B
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

def panel_from(dir)
  path = File.join(dir, 'records', 'lineup.jsonl')
  return nil unless File.exist?(path)

  lu = JSON.parse(File.readlines(path).reject { |l| l.strip.empty? }.first)
  src = lu['analysts'] || lu['players'] or return nil
  src.map { |a| { id: a['id'], adapter: a['adapter'], model: a['model'], effort: a['effort'] } }
end

VERDICT_RE = /^VERDICT:\s*(CHANGED|UNCHANGED)\b/i

options = { file: 'analyses_rescored', seed: 1 }
OptionParser.new do |o|
  o.banner = 'usage: judge_change.rb --a SPEC --b SPEC --out DIR'
  o.on('--a SPEC', 'first side: DIR or DIR#N') { |v| options[:a] = v }
  o.on('--b SPEC', 'second side: DIR or DIR#N') { |v| options[:b] = v }
  o.on('--out DIR', 'output directory (must not already exist)') { |v| options[:out] = v }
  o.on('--file NAME', 'analyses file to read (default analyses_rescored)') { |v| options[:file] = v }
  o.on('--seed N', Integer, 'seed for the X/Y assignment (default 1)') { |v| options[:seed] = v }
  o.on('--panel A:M:E,...', Array, 'override the judging panel') { |v| options[:panel] = v }
end.parse!

%i[a b out].each { |k| options[k] or abort 'usage: judge_change.rb --a SPEC --b SPEC --out DIR' }
abort "#{options[:out]}: already exists" if File.exist?(options[:out])

a = parse_spec(options[:a])
b = parse_spec(options[:b])
a_rows = by_analyst(load_rows(a[:dir], options[:file]))
b_rows = by_analyst(load_rows(b[:dir], options[:file]))

abort "#{a[:dir]}: no usable rows in #{options[:file]}.jsonl" if a_rows.empty?
abort "#{b[:dir]}: no usable rows in #{options[:file]}.jsonl" if b_rows.empty?

panel =
  if options[:panel]
    options[:panel].map { |s| ad, m, e = s.split(':', 3); { id: m, adapter: ad, model: m, effort: e } }
  else
    panel_from(a[:dir])
  end
abort "#{a[:dir]}: no panel in lineup; pass --panel" if panel.nil? || panel.empty?

FileUtils.mkdir_p(options[:out])
rows_path = File.join(options[:out], 'judgements.jsonl')
rng = Random.new(options[:seed])

pairs = (a_rows.keys & b_rows.keys).sort.filter_map do |analyst|
  x = pick(a_rows[analyst], a[:index])
  y = pick(b_rows[analyst], b[:index])
  next warn("  #{analyst}: missing a row on one side, skipped") if x.nil? || y.nil?

  { analyst: analyst, a_row: x, b_row: y }
end
abort 'no analyst produced a usable analysis on both sides' if pairs.empty?

File.write(File.join(options[:out], 'run.json'), JSON.pretty_generate({
  'at' => Time.now.utc.iso8601(3),
  'a' => options[:a], 'b' => options[:b], 'file' => options[:file], 'seed' => options[:seed],
  'pairs' => pairs.map { |p| p[:analyst] },
  'panel' => panel.map { |s| s.transform_keys(&:to_s) }
}))

puts "#{options[:a]} vs #{options[:b]} — #{pairs.length} pairs, #{panel.length} judges, seed #{options[:seed]}"

pairs.each do |pair|
  # Which side is shown first is drawn per pair and recorded, so a judge that
  # simply favours the second text it reads is visible in the record rather than
  # baked into the result.
  a_first = rng.rand(2).zero?
  x_row, y_row = a_first ? [pair[:a_row], pair[:b_row]] : [pair[:b_row], pair[:a_row]]
  prompt = build_prompt(x_row['text'], y_row['text'])

  panel.each do |judge|
    started = Time.now
    reply = nil
    error = nil
    begin
      res = adapter_for(judge).call(messages: [{ 'role' => 'user', 'content' => prompt }],
                                    model: judge[:model])
      reply = res['content']
    rescue StandardError => e
      error = "#{e.class}: #{e.message}"
    end

    m = reply && reply.match(VERDICT_RE)
    File.open(rows_path, 'a') do |f|
      f.puts JSON.generate({
        'at' => Time.now.utc.iso8601(3),
        'analysed_by' => pair[:analyst],
        'judge' => judge[:model],
        'judge_adapter' => judge[:adapter],
        'self_judged' => judge[:model].to_s == pair[:a_row]['model'].to_s,
        'a_shown_as' => a_first ? 'X' : 'Y',
        'a_prompt_sha256' => pair[:a_row]['prompt_sha256'],
        'b_prompt_sha256' => pair[:b_row]['prompt_sha256'],
        'a_at' => pair[:a_row]['at'],
        'b_at' => pair[:b_row]['at'],
        'seconds' => (Time.now - started).round(1),
        'ok' => !reply.nil?,
        'error' => error,
        # A reply that does not open with the required line is recorded as
        # unparsed rather than guessed at. A judge that would not answer in the
        # form is a fact about the read-out, and a guessed verdict would hide it.
        'verdict' => m && m[1].upcase,
        'text' => reply
      })
    end
    puts "  #{pair[:analyst]} judged by #{judge[:model]}: " \
         "#{m ? m[1].upcase : (error || 'UNPARSED')} #{(Time.now - started).round(1)}s"
  end
end

parsed = File.readlines(rows_path).map { |l| JSON.parse(l) }
changed = parsed.count { |r| r['verdict'] == 'CHANGED' }
unchanged = parsed.count { |r| r['verdict'] == 'UNCHANGED' }
puts "\n#{changed} CHANGED / #{unchanged} UNCHANGED / #{parsed.length - changed - unchanged} unparsed, " \
     "out of #{parsed.length}"
puts "wrote #{rows_path}"
