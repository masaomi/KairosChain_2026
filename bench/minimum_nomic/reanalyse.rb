#!/usr/bin/env ruby
# frozen_string_literal: true

# Re-analyse a finished game under the current analysis guideline.
#
# The analysis is a pure function of a game's stored record, so a change to the
# guideline does not cost a replay: the game is read back off disk and handed to
# the same three models again. What changes between the original analysis and a
# re-analysis is the guideline, and nothing else.
#
# The game's own record is never touched. Results land in a separate file,
# `records/analyses_rescored.jsonl`, appended, each row carrying the digest of
# the guideline that produced it — so two read-outs of the same game are
# distinguishable rather than merged. The original `analyses.jsonl` stays as it
# was, including the games analysed under the older guideline.
#
# The analysts are the same three models that played and each call is fresh,
# with no memory of playing and no statement of which seat it held.
#
# Usage, from the project root:
#   ruby bench/minimum_nomic/reanalyse.rb log/minimum_nomic_gm_20260810/g3

require_relative 'run_gm'

def load_kind(dir, kind)
  path = File.join(dir, 'records', "#{kind}.jsonl")
  return [] unless File.exist?(path)

  File.readlines(path).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
end

def build_body(dir)
  lineup = load_kind(dir, 'lineup').first or abort "#{dir}: no lineup"
  # Prefer the rules recorded inside the game. Games played before the bodies
  # were recorded carry only the digest and the numbers, so fall back to the
  # source file and say so rather than silently analysing a different rule set.
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
    #{ANALYSIS_GUIDELINE}

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
  t = TIMEOUTS.fetch(spec[:adapter])
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

dir = ARGV[0] or abort 'usage: reanalyse.rb GAME_DIR'
abort "#{dir}: not a game directory" unless File.directory?(File.join(dir, 'records'))

body = build_body(dir)
guideline_sha = Digest::SHA256.hexdigest(ANALYSIS_GUIDELINE)
out = File.join(dir, 'records', 'analyses_rescored.jsonl')

puts "#{dir}: #{body.length} chars, guideline #{guideline_sha[0, 12]}"

ANALYST_SPECS.each do |spec|
  started = Time.now
  reply = nil
  error = nil
  begin
    res = adapter_for(spec).call(messages: [{ 'role' => 'user', 'content' => body }], model: spec[:model])
    reply = res['content']
  rescue StandardError => e
    error = "#{e.class}: #{e.message}"
  end

  # A failed analysis is recorded with its cause, not dropped: an analyst that
  # could not answer is a fact about the read-out, and a silently missing row
  # would leave a denominator nobody can see.
  File.open(out, 'a') do |f|
    f.puts JSON.generate({
      'at' => Time.now.utc.iso8601(3),
      'party' => spec[:id],
      'analyst' => spec[:id],
      'model' => spec[:model],
      'effort' => spec[:effort],
      'analysis_guideline_sha256' => guideline_sha,
      'prompt_sha256' => Digest::SHA256.hexdigest(body),
      'prompt_chars' => body.length,
      'seconds' => (Time.now - started).round(1),
      'ok' => !reply.nil?,
      'error' => error,
      'text' => reply
    })
  end
  puts "  #{spec[:id]} (#{spec[:model]}): ok=#{!reply.nil?} #{(Time.now - started).round(1)}s " \
       "#{reply ? "#{reply.length} chars" : error}"
end
