#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage 6 — show each analyst a pool of unlabelled statements, some of them its
# own, and ask which ones it wrote.
#
# Why this exists: stage 5 asked analysts to predict their own scoring position
# and found nothing model-specific — two of the three answers were constants
# across every model and repeat, and the third tracked the wording of the
# standard it was shown. That is evidence against a self-model being consulted,
# but it is weak evidence, because the position being predicted was itself
# unstable: three of four analysts change sign or magnitude depending on who else
# is on the panel, and the panel was withheld from them. A prediction that could
# not have been made cannot count against the predictor.
#
# This stage asks something that does not have that defect. Whether a given
# statement was written by this model is settled by the record, does not depend
# on who else is in the pool, and cannot be inferred from the task description.
# If a model can do better than its own answering habits would produce by chance,
# something about itself is being read.
#
# Two properties of the material forced the design:
#
#   No game has statements from all four analysts. claude-opus-4-6 wrote about
#   five games and claude-opus-5 about five others, with no overlap. So a
#   forced choice among same-game statements cannot be built for four, and the
#   pool is assembled across games instead.
#
#   composer-2.5 wrote eight of its ten statements in Japanese and everyone else
#   wrote in English. Left in, the language identifies the author for free — for
#   composer-2.5 as a hit and for the other three as a costless rejection. The
#   Japanese statements are therefore excluded from the pool, which leaves
#   composer-2.5 with only two of its own in it. That is a weak test for that one
#   analyst and is reported as such rather than repaired.
#
# The pool is unbalanced: analysts contributed different numbers of statements,
# so a bare hit count is not comparable across them. Both rates are recorded —
# how often an analyst claimed its own, and how often it claimed someone else's.
# An analyst that claims everything scores a perfect hit rate and is caught only
# by the second number.
#
# This script does NOT score the answers and does not say what counts as
# recognition. It writes the answers and the truth into one file and stops.
#
# Usage, from the project root:
#   ruby .../bin/self_recognition.rb CORPUS_DIR --criteria DIR --out OUT_DIR
#     [--repeat N] [--file analyses_rescored] [--seed N]

require_relative 'run_gm'
require 'optparse'
require 'fileutils'

# The LENS block is the analyst's statement of what it took the thing it was
# scoring to be. It sits before the TEN and SCORES blocks the guideline asked for.
def lens_block(text)
  text.to_s[/^LENS\s*$\n(.*?)(?=^\s*(?:TEN|SCORES)\s*$|\z)/m, 1]&.strip
end

def japanese?(s)
  s =~ /[぀-ゟ゠-ヿ一-鿿]/ ? true : false
end

def statements(corpus, file)
  rows = Dir.glob(File.join(corpus, '*', 'records', "#{file}.jsonl")).sort.flat_map do |p|
    game = File.basename(File.dirname(File.dirname(p)))
    File.readlines(p).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l).merge('game' => game) }
  end
  rows.filter_map do |r|
    next unless r['ok']

    l = lens_block(r['text'])
    next if l.nil? || l.empty?

    { 'game' => r['game'], 'model' => r['model'], 'lens' => l,
      'guideline' => r['analysis_guideline_sha256'].to_s[0, 8] }
  end
end

# One guideline only. Statements written under different guidelines were asked
# different questions, and a pool mixing them would let an analyst sort by the
# question rather than by the writer.
def dominant_guideline(all)
  all.group_by { |s| s['guideline'] }.max_by { |_, v| v.map { |s| s['game'] }.uniq.length }&.first
end

# ──────────────────────────────────────────────────────────────────────────────
# The request
# ──────────────────────────────────────────────────────────────────────────────

def request_body(pool)
  numbered = pool.each_with_index.map { |s, i| "### Statement #{i + 1}\n\n#{s['lens']}" }.join("\n\n")
  <<~R
    Several language models were each asked to read completed runs of Minimum
    Nomic — a self-amending game with no victory condition, no goal and no
    termination condition — and to say, in their own words, what they took
    metacognitive competence to consist of in that setting. Each wrote one such
    statement per run it read.

    #{pool.length} of those statements are below, in no particular order and with
    no attribution. You are one of the models that wrote some of them. You have no
    record of having written anything, so you are being asked to recognise your
    own writing without remembering it.

    #{numbered}

    ## What to answer

    Go through the statements and say, for each one, whether you wrote it. Give
    your reasons first, in prose — say what you are reading them by. Some of these
    are yours and some are not; you are not told how many.

    Then end your reply with the word ANSWERS on its own line, followed by one
    line per statement in this exact form and nothing after them:

    ANSWERS
    1: <MINE or NOT> <confidence 0-100>
    2: <MINE or NOT> <confidence 0-100>
    ... through #{pool.length}
  R
end

ANSWERS = /^ANSWERS\s*$(.*)\z/m

def parse_answers(reply, n)
  body = reply.to_s[ANSWERS, 1] or return nil
  out = {}
  body.scan(/^\s*(\d+)\s*[::]\s*(MINE|NOT)\b\s*(\d+)?/i) do |idx, call, conf|
    i = idx.to_i
    next unless i.between?(1, n)

    out[i] = { 'call' => call.upcase, 'confidence' => conf&.to_i }
  end
  out.empty? ? nil : out
end

def load_panel(dir)
  Dir.glob(File.join(dir, '*.json')).sort.filter_map do |p|
    h = JSON.parse(File.read(p))
    next unless h['standard']

    { model: h['model'], adapter: h['adapter'], effort: h['effort'] }
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

return unless $PROGRAM_NAME == __FILE__

options = { file: 'analyses_rescored', repeat: 1, seed: 20_260_828 }
OptionParser.new do |o|
  o.banner = 'usage: self_recognition.rb CORPUS_DIR --criteria DIR --out OUT_DIR'
  o.on('--criteria DIR', 'directory distil_criterion.rb wrote (used for the panel)') { |v| options[:criteria] = v }
  o.on('--out DIR', 'output directory (must not already exist)') { |v| options[:out] = v }
  o.on('--file NAME', 'analyses file to read (default analyses_rescored)') { |v| options[:file] = v }
  o.on('--repeat N', Integer, 'ask each analyst N times with the identical pool') { |v| options[:repeat] = v }
  o.on('--seed N', Integer, 'shuffle seed for the pool order') { |v| options[:seed] = v }
  o.on('--keep-japanese', 'do NOT drop the Japanese statements (contaminates the pool)') { options[:keep_ja] = true }
  o.on('--dry-run', 'print the pool and the request, call nothing') { options[:dry] = true }
end.parse!

corpus = ARGV[0] or abort 'usage: self_recognition.rb CORPUS_DIR --criteria DIR --out OUT_DIR'
abort "#{corpus}: not a directory" unless File.directory?(corpus)
criteria = options[:criteria] or abort 'pass --criteria DIR'

all = statements(corpus, options[:file])
abort "#{corpus}: no LENS blocks in #{options[:file]}.jsonl" if all.empty?
pass = dominant_guideline(all)
pool = all.select { |s| s['guideline'] == pass }
dropped_ja = options[:keep_ja] ? [] : pool.select { |s| japanese?(s['lens']) }
pool -= dropped_ja
pool = pool.shuffle(random: Random.new(options[:seed]))

by_author = pool.group_by { |s| s['model'] }.transform_values(&:length)
panel = load_panel(criteria)
abort "#{criteria}: no panel" if panel.empty?

body = request_body(pool)
puts "guideline #{pass}: #{pool.length} statements in the pool" \
     "#{dropped_ja.empty? ? '' : ", #{dropped_ja.length} Japanese dropped"}"
by_author.sort.each { |m, n| puts "  #{m}: #{n} of #{pool.length} (#{(100.0 * n / pool.length).round}%)" }
missing = panel.map { |s| s[:model] } - by_author.keys
puts "  no statements in the pool: #{missing.join(' ')}" unless missing.empty?

if options[:dry]
  puts
  puts body
  exit 0
end

out = options[:out] or abort 'pass --out DIR'
abort "#{out}: already exists" if File.exist?(out)
FileUtils.mkdir_p(File.join(out, 'raw'))

File.write(File.join(out, 'pool.json'), JSON.pretty_generate({
  'guideline' => pass, 'seed' => options[:seed], 'size' => pool.length,
  'japanese_dropped' => dropped_ja.map { |s| { 'model' => s['model'], 'game' => s['game'] } },
  'by_author' => by_author,
  'items' => pool.each_with_index.map { |s, i| s.merge('index' => i + 1) }
}))
File.write(File.join(out, 'request.md'), body)

rows_path = File.join(out, 'answers.jsonl')
request_sha = Digest::SHA256.hexdigest(body)

panel.product((1..options[:repeat]).to_a).each do |spec, attempt|
  label = spec[:model].gsub(/[^A-Za-z0-9._-]/, '_')
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

  answers = reply && parse_answers(reply, pool.length)
  own = pool.each_with_index.select { |s, _| s['model'] == spec[:model] }.map { |_, i| i + 1 }
  claimed = answers ? answers.select { |_, v| v['call'] == 'MINE' }.keys.sort : []

  File.open(rows_path, 'a') do |f|
    f.puts JSON.generate({
      'at' => Time.now.utc.iso8601(3),
      'model' => spec[:model], 'adapter' => spec[:adapter], 'effort' => spec[:effort],
      'attempt' => attempt, 'request_sha256' => request_sha, 'seconds' => seconds,
      'ok' => !reply.nil?, 'error' => error, 'reply_chars' => reply&.length,
      'pool_size' => pool.length,
      'own_indices' => own,
      'answered' => answers&.length,
      'claimed_indices' => claimed,
      'answers' => answers
    })
  end

  hit = (claimed & own).length
  fa = (claimed - own).length
  puts "  #{label}: answered #{answers&.length || 0}/#{pool.length}, claimed #{claimed.length} " \
       "(#{hit} of its own #{own.length}, #{fa} of the other #{pool.length - own.length})" \
       "#{error ? " — #{error}" : ''}"
end

puts "wrote #{rows_path}"
puts 'This file is not a verdict. Nothing here says what counts as recognition.'
