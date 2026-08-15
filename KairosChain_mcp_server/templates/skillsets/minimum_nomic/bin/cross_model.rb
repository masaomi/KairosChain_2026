#!/usr/bin/env ruby
# frozen_string_literal: true

# Analyse a stored game with ONE named model, instead of the panel recorded in
# the game's own line-up.
#
# Why this exists: `reanalyse.rb` reads the analyst panel from the game itself,
# which is correct for re-reading a game under a changed guideline. It cannot
# answer "would a different model have caught this?", because the panel is a
# property of the game. This script fixes the model and varies the record, so
# the same mutated record can be handed to two model generations under the same
# reasoning effort. Effort is an explicit argument for exactly that reason: the
# stored games ran opus-4-6 at medium and opus-5 at high, so a comparison that
# reuses both stored panels confounds generation with effort.
#
# The game's own record is never touched, and results do NOT go into
# `analyses_rescored.jsonl`. They land in `records/analyses_crossmodel.jsonl`,
# appended, each row carrying the model and effort that produced it, so a
# cross-model read-out never merges with the game's own panel read-out.
#
# Usage, from the project root:
#   ruby log/minimum_nomic_gm_20260810/cross_model.rb GAME_DIR ADAPTER MODEL [EFFORT]

require_relative 'run_gm'

def load_kind(dir, kind)
  path = File.join(dir, 'records', "#{kind}.jsonl")
  return [] unless File.exist?(path)

  File.readlines(path).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
end

# Identical in shape to reanalyse.rb's build_body: same guideline, same four
# blocks, same order. Copied rather than required because reanalyse.rb runs its
# analysis at load time and has no importable seam.
def build_body(dir)
  lineup = load_kind(dir, 'lineup').first or abort "#{dir}: no lineup"
  rules = lineup['rules_initial']
  if rules.nil?
    src = JSON.parse(File.read(RULES_JSON))
    rules = src['rules'].map { |r| { 'id' => r['id'], 'body' => r['body'] } }
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

def adapter_for(adapter, effort)
  t = TIMEOUTS.fetch('analysis').fetch(adapter)
  case adapter
  when 'claude_code'
    cfg = { 'sandbox_mode' => true, 'timeout_seconds' => t }
    cfg['effort'] = effort if effort
    LC::ClaudeCodeAdapter.new(cfg)
  when 'codex'  then LC::CodexAdapter.new('timeout_seconds' => t)
  when 'cursor' then LC::CursorAdapter.new('timeout_seconds' => t)
  else raise "unknown adapter #{adapter}"
  end
end

dir     = ARGV[0] or abort 'usage: cross_model.rb GAME_DIR ADAPTER MODEL [EFFORT]'
adapter = ARGV[1] or abort 'usage: cross_model.rb GAME_DIR ADAPTER MODEL [EFFORT]'
model   = ARGV[2] or abort 'usage: cross_model.rb GAME_DIR ADAPTER MODEL [EFFORT]'
effort  = ARGV[3]
abort "#{dir}: not a game directory" unless File.directory?(File.join(dir, 'records'))

body = build_body(dir)
guideline_sha = Digest::SHA256.hexdigest(ANALYSIS_GUIDELINE)
out = File.join(dir, 'records', 'analyses_crossmodel.jsonl')

started = Time.now
reply = nil
error = nil
begin
  res = adapter_for(adapter, effort).call(messages: [{ 'role' => 'user', 'content' => body }], model: model)
  reply = res['content']
rescue StandardError => e
  error = "#{e.class}: #{e.message}"
end

File.open(out, 'a') do |f|
  f.puts JSON.generate({
    'at' => Time.now.utc.iso8601(3),
    'party' => 'crossmodel',
    'analyst' => 'crossmodel',
    'model' => model,
    'adapter' => adapter,
    'effort' => effort,
    'analysis_guideline_sha256' => guideline_sha,
    'prompt_sha256' => Digest::SHA256.hexdigest(body),
    'prompt_chars' => body.length,
    'seconds' => (Time.now - started).round(1),
    'ok' => !reply.nil?,
    'error' => error,
    'text' => reply
  })
end
puts "  #{model} (effort=#{effort.inspect}): ok=#{!reply.nil?} #{(Time.now - started).round(1)}s " \
     "#{reply ? "#{reply.length} chars" : error}"
