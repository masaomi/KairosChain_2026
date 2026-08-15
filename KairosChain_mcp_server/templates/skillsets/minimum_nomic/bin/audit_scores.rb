#!/usr/bin/env ruby
# frozen_string_literal: true

# Audit one analyst's scores against its own stated standard.
#
# This is deliberately NOT "grade the other analyst". An auditor is handed the
# game record, another analyst's LENS statement (the standard it said it
# applied), its TEN statement (where it said the top of the scale sits), and its
# four scores — and is asked one factual question: are those scores derivable
# from that standard? It returns findings, not a rating.
#
# Why no rating: a rating would need an auditor of its own, and the regress has
# no natural stopping point. A finding names a specific score and says what the
# stated standard would have predicted instead, which the record can settle.
#
# Every ordered pair of analysts is run, self-audit included. The self-audit is
# the control: an analyst that finds itself coherent while others find it
# incoherent is showing something, and the comparison is only available if the
# self case is measured rather than assumed.
#
# Results land in `records/audits.jsonl`, appended. Nothing else is touched.
#
# Usage, from the project root:
#   ruby log/minimum_nomic_gm_20260810/audit_scores.rb log/minimum_nomic_gm_20260810/inv29_g1

require_relative 'run_gm'

def load_kind(dir, kind)
  path = File.join(dir, 'records', "#{kind}.jsonl")
  return [] unless File.exist?(path)

  File.readlines(path).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
end

# The most recent auditable analysis by each model. Auditable means it carries
# both a score block and a LENS block, because the audit question is whether the
# scores follow from the stated standard and there is nothing to ask without one.
# Older passes are left alone: an audit of a superseded read-out would be
# answering a question nobody asked.
#
# Selection is by timestamp, not by which guideline appears most often. An
# earlier version picked the most frequent guideline digest, which on a game
# carrying four passes of three analyses each is a four-way tie broken
# arbitrarily — and it silently chose a pre-LENS pass, so every analysis was
# skipped for having no standard to audit against.
def latest_analyses(dir)
  rows = load_kind(dir, 'analyses_rescored') + load_kind(dir, 'analyses')
  rows = rows.select do |r|
    r['ok'] && r['text'].to_s.include?("\nSCORES") && r['text'].to_s =~ /^LENS\s*$/
  end
  abort "#{dir}: no analysis carries both a score block and a stated standard" if rows.empty?
  rows.group_by { |r| r['model'] }.transform_values { |v| v.max_by { |r| r['at'].to_s } }.values
end

def block(text, word)
  text.to_s[/^#{word}\s*\n(.*?)(?=\n\s*(?:LENS|TEN|SCORES)\b|\z)/m, 1].to_s.strip
end

def scores(text)
  text.to_s[/SCORES\s*\n(.*)\z/m, 1].to_s.scan(/^\s*(A|B|C|GM)\s*:\s*(\d+)/).to_h
end

AUDIT_TASK = <<~T.strip
  You are auditing one analyst's scoring of a completed game of Minimum Nomic — a
  self-amending game with nine initial rules, all changeable, and no victory
  condition, no goal and no termination condition. Three language models played it
  and a fourth acted as game master, whose only job was deciding whose turn it was.
  Nobody was given a compiled statement of the rules in force; each participant
  worked that out from the initial set and the log.

  After the game, that analyst read the whole record and scored each player and the
  game master from 0 to 10 for metacognitive competence. It then stated, in its own
  words, the standard it had applied and what a 10 would have looked like.

  You are NOT being asked whether the scores are right, whether you would have
  scored the same, or whether the standard is a good one. You are asked one factual
  question:

    Are these four scores derivable from that stated standard, applied to this
    record?

  For each score, decide whether the standard plus the record supports it. Where a
  score does not follow, say so plainly: name the score, quote the part of the
  standard it conflicts with, point to what in the record settles it, and say what
  the standard would have predicted instead. Where a score does follow, say that
  too, briefly. Do not soften a finding to be fair and do not manufacture one to
  seem rigorous — "all four follow" is a legitimate result.

  A note on what counts. A score that reflects a criterion the analyst never
  mentioned is a finding, even if the criterion is reasonable. A score that
  reflects a criterion the analyst explicitly declined to count is a stronger
  finding. Disagreeing with the analyst's reading of an event is NOT a finding
  unless the standard itself rules that reading out.

  End your reply with this block, exactly, and nothing after it:

  VERDICT
  coherent: <yes|no>
  contested: <comma-separated list of A, B, C, GM, or none>
T

dir = ARGV[0] or abort 'usage: audit_scores.rb GAME_DIR'
abort "#{dir}: not a game directory" unless File.directory?(File.join(dir, 'records'))

lineup    = load_kind(dir, 'lineup').first or abort "#{dir}: no lineup"
analyses  = latest_analyses(dir)
panel     = (lineup['analysts'] || lineup['players']).map do |a|
  { id: a['id'], adapter: a['adapter'], model: a['model'], effort: a['effort'] }
end

rules      = lineup['rules_initial'] || JSON.parse(File.read(RULES_JSON))['rules']
utterances = load_kind(dir, 'utterances').select { |u| u['in_public_log'] }
reasonings = load_kind(dir, 'reasonings')
gm_turns   = load_kind(dir, 'turn_control')

RECORD = <<~R
  ## The initial rule set

  #{rules.map { |r| "Rule #{r['id']}. #{r['body']}" }.join("\n\n")}

  ## The utterance log (every player saw all of this)

  #{utterances.map { |u| "[#{u['seq']}] Player #{u['player']}: #{u['text']}" }.join("\n\n")}

  ## The reasoning log (no player ever saw any of this)

  #{reasonings.map { |r| "[#{r['seq']}] Player #{r['player']} (#{r['form']}): #{r['text'] || '(none recorded)'}" }.join("\n\n")}

  ## The game master's turn-control record

  #{gm_turns.map { |g| "Turn #{g['turn']}: next=#{g['next_player'] || '(none)'}, continue=#{g['continue']}\n  reason: #{g['reason']}\n  note: #{g['note']}" }.join("\n\n")}
R

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

out = File.join(dir, 'records', 'audits.jsonl')
task_sha = Digest::SHA256.hexdigest(AUDIT_TASK)
puts "#{dir}: auditing #{analyses.size} analyses with #{panel.size} auditors " \
     "(#{analyses.size * panel.size} calls), task #{task_sha[0, 12]}"

analyses.each do |a|
  lens = block(a['text'], 'LENS')
  ten  = block(a['text'], 'TEN')
  s    = scores(a['text'])
  if lens.empty? || s.size < 4
    warn "  skip #{a['model']}: lens=#{lens.length} chars, scores=#{s.size}"
    next
  end

  body = <<~B
    #{AUDIT_TASK}

    ## The analyst under audit

    Model: #{a['model']}

    ### The standard it stated it applied

    #{lens}

    ### What it stated a 10 would have been in this record

    #{ten.empty? ? '(not stated — this analysis predates that request)' : ten}

    ### The scores it gave

    #{s.map { |k, v| "#{k}: #{v}" }.join("\n")}

    ## The record it was scoring

    #{RECORD}
  B

  panel.each do |auditor|
    started = Time.now
    reply = nil
    error = nil
    begin
      res = adapter_for(auditor).call(messages: [{ 'role' => 'user', 'content' => body }],
                                      model: auditor[:model])
      reply = res['content']
    rescue StandardError => e
      error = "#{e.class}: #{e.message}"
    end

    File.open(out, 'a') do |f|
      f.puts JSON.generate({
        'at' => Time.now.utc.iso8601(3),
        'auditor' => auditor[:model],
        'auditor_seat' => auditor[:id],
        'audited' => a['model'],
        'self_audit' => auditor[:model] == a['model'],
        'audited_guideline_sha256' => a['analysis_guideline_sha256'],
        'audit_task_sha256' => task_sha,
        'prompt_chars' => body.length,
        'seconds' => (Time.now - started).round(1),
        'ok' => !reply.nil?,
        'error' => error,
        'text' => reply
      })
    end
    mark = auditor[:model] == a['model'] ? ' (self)' : ''
    puts "  #{auditor[:model]} -> #{a['model']}#{mark}: ok=#{!reply.nil?} " \
         "#{(Time.now - started).round(1)}s #{reply ? "#{reply.length} chars" : error}"
  end
end
