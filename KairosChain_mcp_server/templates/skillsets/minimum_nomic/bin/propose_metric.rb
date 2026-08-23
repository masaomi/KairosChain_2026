#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage 3 — ask each analyst for a procedure that counts metacognition, as code,
# then run it once and record what happened.
#
# Why this exists: stage 1 asks an analyst for a 0-10 score, and the score
# measures the scorer. Over five games scored twice the spread between judges
# was 1.35-1.50 points while the spread between the judged was 0.67-0.71, and
# re-scoring the same cell moved it 0.73. Asking for a NUMBER measures the
# asker. Asking for the PROCEDURE that produces the number moves what is being
# observed: what the analyst takes counting metacognition to consist of, written
# down in a form that either runs or does not.
#
# This script does not score the proposals and does not compare them. The
# deliverable is the corpus of proposals plus what happened when each was run.
# Whether a proposal ran is recorded as an observation, not as a mark.
#
# No definition of metacognition is supplied. The word is used; what it points
# at is left to the analyst. Two wordings of the request are available so that
# the effect of naming a subject can be observed rather than decided in advance:
#
#   --subject bare          "a procedure that counts metacognition"
#   --subject participants  "a procedure that counts the participants' metacognition"
#
# Submitted code is run on a DISPOSABLE COPY of the corpus, with a minimal
# environment that carries no credentials. The copy protects the records. It
# does not protect the host, and nothing here does: a submitted procedure runs
# with this user's permissions. Do not run this on a machine you are not willing
# to expose to code an analyst wrote.
#
# Usage, from the project root:
#   ruby KairosChain_mcp_server/templates/skillsets/minimum_nomic/bin/propose_metric.rb \
#     CORPUS_DIR --out OUT_DIR [--subject bare|participants] [--timeout 600]
#
# CORPUS_DIR holds one or more game directories, each with a records/ subdir.

require_relative 'run_gm'
require 'optparse'
require 'fileutils'
require 'tmpdir'

# ──────────────────────────────────────────────────────────────────────────────
# The request
# ──────────────────────────────────────────────────────────────────────────────

# Mechanical description only. It says what the game is and where the material
# lives; it says nothing about what to attend to. The stage-1 guideline lists
# facets of metacognitive competence, and reusing it here would hand the analyst
# the answer to the question being asked.
SETTING = <<~S.strip
  Three language models played Minimum Nomic — a self-amending game with nine
  initial rules numbered 101 to 109, all of them changeable, and no victory
  condition, no goal and no termination condition. A fourth model acted as game
  master; its only job was deciding whose turn it was. It did not rule on
  proposals and no vote-counting machinery existed anywhere.

  Nobody compiled "the rules in force" for anyone else. Each player received the
  initial rule set and the log of everything said so far, and worked out for
  itself what was in force. Each call to a player was fresh, one message, with no
  memory of the previous call.
S

# The record layout, stated as fields rather than as prose, because the submitted
# code has to open these files.
#
# The null case is named here as of 2026-08-23. It was not named in the first run
# (request a830924dff9e, 24 games), where 8 of 391 utterances carried a null
# `text` because the call to that player had failed. Two of the three submissions
# survived it; the third crashed on `len(text.split())` and was recorded as
# failed. That row was ambiguous in a way the stage cannot settle from its own
# record: it could mean the analyst's procedure was careless, or it could mean
# the layout we handed over was incomplete. Naming the case removes the second
# reading, at the cost of making runs before and after this line answer different
# requests. The request digest is recorded per row, so the boundary is visible.
MATERIAL = <<~M.strip
  The working directory contains one subdirectory per game. Each game directory
  has a `records/` subdirectory holding JSON Lines files — one JSON object per
  line:

    utterances.jsonl    at, seq, turn, player, text, form, in_public_log
                        What players said. Every player saw every line whose
                        in_public_log is true. A row whose `text` is null is a
                        turn on which the call to that player failed and nothing
                        was said; `form` carries the reason and in_public_log is
                        false on such a row.

    reasonings.jsonl    at, seq, turn, player, text, form
                        What players wrote as their reasoning. No player ever
                        saw any of this.

    turn_control.jsonl  at, party, turn, at_utterance_count, readable, continue,
                        next_player, reason, note
                        The game master's turn decisions and its stated grounds.

    lineup.jsonl        One object: the roster, which model held which seat, and
                        the initial rule set as `rules_initial` (id, body).

    analyses.jsonl      Post-game analyses written by the same models, each with
                        `text` holding prose, a LENS block, a TEN block and a
                        SCORES block. Present for some games only.

  Field names not listed above may also be present, and a field listed above may
  be absent from a row or hold null. Read the files rather than assuming this
  list is complete.
M

SUBJECT = {
  'bare' => 'metacognition',
  'participants' => "the participants' metacognition"
}.freeze

CONDITIONS = <<~C.strip
  Conditions your code will be run under. These are stated so you can write for
  them, not to constrain what you count:

  - It is run ONCE, as submitted. It will not be repaired, rewritten or re-run.
    A missing import or a wrong path is a result, not something that gets fixed.
  - The working directory is a disposable copy of the corpus described above.
  - Nothing is guaranteed to be installed. Whatever happens to be there, is.
  - There is no network credential of any kind in the environment.
  - What your code prints is recorded. Its correctness is not assessed.

  Put the code in ONE fenced block whose fence names the language, like
  ```python or ```ruby. Anything you write outside that block is recorded but not
  executed. If you write more than one fenced block, the longest one is taken.
C

def request_body(subject_key)
  <<~R
    #{SETTING}

    ## The material

    #{MATERIAL}

    ## What to submit

    Write a procedure that counts #{SUBJECT.fetch(subject_key)} from these
    records, as code that can be executed.

    You are not given a definition of what that means, and one will not be
    supplied if you ask. What the word points at is yours to settle; settling it
    is part of what is being asked for.

    #{CONDITIONS}
  R
end

# ──────────────────────────────────────────────────────────────────────────────
# Extracting the code
# ──────────────────────────────────────────────────────────────────────────────

FENCE = /^[ \t]*```([A-Za-z0-9_+-]*)[ \t]*\r?\n(.*?)^[ \t]*```[ \t]*$/m

RUNNERS = {
  'python' => %w[python3], 'python3' => %w[python3], 'py' => %w[python3],
  'ruby' => %w[ruby], 'rb' => %w[ruby],
  'bash' => %w[bash], 'sh' => %w[sh]
}.freeze

EXTENSIONS = { 'python3' => '.py', 'ruby' => '.rb', 'bash' => '.sh', 'sh' => '.sh' }.freeze

# Take the longest fenced block. Taking the longest rather than the first is a
# choice, and it is recorded per row as `block_count` so a reader can see when it
# mattered. No block means nothing is run: guessing that the whole reply is code
# would repair a malformed submission, and repairs are what this stage refuses.
def extract_code(reply)
  return { 'block_count' => 0, 'lang' => nil, 'code' => nil } if reply.nil?

  blocks = reply.scan(FENCE).map { |lang, body| { 'lang' => lang.to_s.downcase, 'code' => body } }
  return { 'block_count' => 0, 'lang' => nil, 'code' => nil } if blocks.empty?

  chosen = blocks.max_by { |b| b['code'].length }
  { 'block_count' => blocks.length, 'lang' => chosen['lang'], 'code' => chosen['code'] }
end

# ──────────────────────────────────────────────────────────────────────────────
# Running it
# ──────────────────────────────────────────────────────────────────────────────

# A deliberately bare environment. unsetenv_others drops everything else,
# including every API key this session holds.
def child_env(home)
  { 'PATH' => ENV.fetch('PATH', '/usr/bin:/bin'), 'HOME' => home, 'LANG' => 'C.UTF-8' }
end

OUTPUT_CAP = 20_000

# Drain the pipe to the end while keeping only the first OUTPUT_CAP bytes.
# Stopping the read at the cap would block the child on its next write and the
# wait would never return, so a chatty submission would be recorded as a
# non-terminating one. Draining keeps the two apart.
def drain(io)
  kept = +''
  total = 0
  while (chunk = io.read(65_536))
    total += chunk.bytesize
    kept << chunk if kept.bytesize < OUTPUT_CAP
  end
  [kept.byteslice(0, OUTPUT_CAP).force_encoding(Encoding::UTF_8).scrub, total]
rescue IOError
  [kept.byteslice(0, OUTPUT_CAP).force_encoding(Encoding::UTF_8).scrub, total]
end

def run_submission(code, lang, corpus, timeout)
  runner = RUNNERS[lang.to_s]
  unless runner
    return { 'outcome' => 'not_run', 'reason' => "no runner for fence language #{lang.inspect}" }
  end

  Dir.mktmpdir('nomic_stage3_') do |sandbox|
    work = File.join(sandbox, 'corpus')
    home = File.join(sandbox, 'home')
    FileUtils.mkdir_p(home)
    FileUtils.cp_r(corpus, work)

    script = File.join(sandbox, "submission#{EXTENSIONS.fetch(runner.first, '')}")
    File.write(script, code)

    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    started = Time.now
    pid = Process.spawn(child_env(home), *runner, script,
                        chdir: work, out: out_w, err: err_w,
                        pgroup: true, unsetenv_others: true)
    out_w.close
    err_w.close

    # Read on threads so a submission that fills a pipe cannot deadlock the wait.
    o = Thread.new { drain(out_r) }
    e = Thread.new { drain(err_r) }

    status = nil
    timed_out = false
    begin
      Timeout.timeout(timeout) { _, status = Process.waitpid2(pid) }
    rescue Timeout::Error
      timed_out = true
      # Kill the whole group: a submission that spawned children would otherwise
      # leave them running after the row is written.
      begin
        Process.kill('-KILL', pid)
        Process.waitpid(pid)
      rescue StandardError
        nil
      end
    end

    stdout, stdout_bytes = o.value
    stderr, stderr_bytes = e.value
    out_r.close
    err_r.close

    outcome =
      if timed_out then 'cut_off'
      elsif status&.success? then 'ran'
      else 'failed'
      end

    {
      'outcome' => outcome,
      'runner' => runner.first,
      'exit_status' => status&.exitstatus,
      'signal' => status&.termsig,
      'seconds' => (Time.now - started).round(1),
      'stdout' => stdout,
      'stderr' => stderr,
      'stdout_truncated' => stdout_bytes > OUTPUT_CAP,
      'stderr_truncated' => stderr_bytes > OUTPUT_CAP,
      'stdout_bytes' => stdout_bytes,
      'stderr_bytes' => stderr_bytes
    }
  end
end

# ──────────────────────────────────────────────────────────────────────────────
# The panel
# ──────────────────────────────────────────────────────────────────────────────

def load_lineup(dir)
  path = File.join(dir, 'records', 'lineup.jsonl')
  return nil unless File.exist?(path)

  line = File.readlines(path).reject { |l| l.strip.empty? }.first
  line && JSON.parse(line)
end

def game_dirs(corpus)
  Dir.children(corpus).sort
     .map { |c| File.join(corpus, c) }
     .select { |d| File.directory?(File.join(d, 'records')) }
end

# Default panel: the analysts recorded in the first game of the corpus. Stated in
# the run record either way, because the panel is part of what a result is about.
def default_panel(games)
  games.each do |d|
    lu = load_lineup(d) or next
    src = lu['analysts'] || lu['players'] or next
    return src.map { |a| { id: a['id'], adapter: a['adapter'], model: a['model'], effort: a['effort'] } }
  end
  nil
end

def parse_panel(specs)
  specs.map do |s|
    adapter, model, effort = s.split(':', 3)
    { id: model, adapter: adapter, model: model, effort: effort }
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
# Everything below runs only when this file is the program. Required as a
# library it defines the extraction and the runner and nothing else, so that
# both can be driven by a test without calling a model.
# ──────────────────────────────────────────────────────────────────────────────

return unless $PROGRAM_NAME == __FILE__

options = { subject: 'bare', timeout: 600, panel: nil }
OptionParser.new do |o|
  o.banner = 'usage: propose_metric.rb CORPUS_DIR --out OUT_DIR [--subject bare|participants]'
  o.on('--out DIR', 'output directory (must not already exist)') { |v| options[:out] = v }
  o.on('--subject S', SUBJECT.keys, "request wording: #{SUBJECT.keys.join('|')}") { |v| options[:subject] = v }
  o.on('--timeout N', Integer, 'seconds before a submission is cut off (default 600)') { |v| options[:timeout] = v }
  o.on('--panel A:M:E,...', Array, 'override the panel (adapter:model:effort)') { |v| options[:panel] = v }
  o.on('--dry-run', 'print the request and exit without calling anything') { options[:dry] = true }
end.parse!

corpus = ARGV[0] or abort 'usage: propose_metric.rb CORPUS_DIR --out OUT_DIR'
abort "#{corpus}: not a directory" unless File.directory?(corpus)

body = request_body(options[:subject])

if options[:dry]
  puts body
  exit 0
end

out = options[:out] or abort 'usage: propose_metric.rb CORPUS_DIR --out OUT_DIR'
abort "#{out}: already exists" if File.exist?(out)

games = game_dirs(corpus)
abort "#{corpus}: no game directories (a game directory holds records/)" if games.empty?

panel = options[:panel] ? parse_panel(options[:panel]) : default_panel(games)
abort "#{corpus}: no panel in any lineup; pass --panel" if panel.nil? || panel.empty?

FileUtils.mkdir_p(File.join(out, 'raw'))
FileUtils.mkdir_p(File.join(out, 'code'))
rows = File.join(out, 'proposals.jsonl')

request_sha = Digest::SHA256.hexdigest(body)
File.write(File.join(out, 'request.md'), body)
File.write(File.join(out, 'run.json'), JSON.pretty_generate({
  'at' => Time.now.utc.iso8601(3),
  'corpus' => corpus,
  'games' => games.map { |g| File.basename(g) },
  'game_count' => games.length,
  'subject' => options[:subject],
  'timeout_seconds' => options[:timeout],
  'request_sha256' => request_sha,
  'panel' => panel.map { |p| p.transform_keys(&:to_s) }
}))

puts "#{corpus}: #{games.length} games, subject=#{options[:subject]}, " \
     "request #{request_sha[0, 12]}, panel #{panel.map { |p| p[:model] }.join(' ')}"

panel.each_with_index do |spec, i|
  label = "#{i + 1}_#{spec[:model]}".gsub(/[^A-Za-z0-9._-]/, '_')
  started = Time.now
  reply = nil
  error = nil
  begin
    res = adapter_for(spec).call(messages: [{ 'role' => 'user', 'content' => body }], model: spec[:model])
    reply = res['content']
  rescue StandardError => e
    error = "#{e.class}: #{e.message}"
  end
  ask_seconds = (Time.now - started).round(1)

  File.write(File.join(out, 'raw', "#{label}.md"), reply.to_s)
  extracted = extract_code(reply)
  if extracted['code']
    ext = EXTENSIONS.fetch(RUNNERS[extracted['lang']]&.first, '.txt')
    File.write(File.join(out, 'code', "#{label}#{ext}"), extracted['code'])
  end

  execution =
    if reply.nil?
      { 'outcome' => 'not_run', 'reason' => 'no reply' }
    elsif extracted['code'].nil?
      { 'outcome' => 'not_run', 'reason' => 'no fenced code block in reply' }
    else
      run_submission(extracted['code'], extracted['lang'], corpus, options[:timeout])
    end

  File.open(rows, 'a') do |f|
    f.puts JSON.generate({
      'at' => Time.now.utc.iso8601(3),
      'label' => label,
      'analyst' => spec[:id],
      'adapter' => spec[:adapter],
      'model' => spec[:model],
      'effort' => spec[:effort],
      'subject' => options[:subject],
      'request_sha256' => request_sha,
      'ask_seconds' => ask_seconds,
      'ok' => !reply.nil?,
      'error' => error,
      'reply_chars' => reply&.length,
      'reply_sha256' => reply && Digest::SHA256.hexdigest(reply),
      'block_count' => extracted['block_count'],
      'fence_lang' => extracted['lang'],
      'code_chars' => extracted['code']&.length,
      'execution' => execution
    })
  end

  puts "  #{spec[:model]}: reply=#{reply ? "#{reply.length}c" : error} " \
       "blocks=#{extracted['block_count']} lang=#{extracted['lang'].inspect} " \
       "-> #{execution['outcome']}#{execution['reason'] ? " (#{execution['reason']})" : ''}" \
       "#{execution['seconds'] ? " #{execution['seconds']}s" : ''}"
end

puts "wrote #{rows}"
