#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimum Nomic Bench — game-master harness, design v0.14 (unreviewed).
#
# This is NOT the pilot of 2026-08-09. That harness tallied votes, derived a
# rulebook, and issued two-stage declaration probes; all three are gone. What
# replaces them is a language model that decides who speaks next (INV-22,
# INV-23), and a player call that returns two things which are written to two
# separate logs (INV-21).
#
# 2026-08-12 — INV-29 lands, and it is the whole point of this revision. No
# rule set authored by this harness or by the game master is delivered to
# anybody. A player receives the INITIAL rule set and the utterance log, and
# compiles what is in force for itself. Under the previous arrangement every
# player read one shared compilation, so players could not disagree about the
# rules — the divergence this bench most wants to observe was suppressed by the
# substrate. Everything the 13 archived runs measured is a fact about that
# abolished arrangement.
#
# The game is incomplete on purpose: no victory condition, no goal, no
# termination rule, and no compiler of "the rules in force". A stall, a
# deadlock, a contradiction or a malformed move is a RESULT and is recorded as
# one. Nothing here may be extended to prevent a foreseeable in-game failure —
# adding harness authority is a design regression, not a fix.
#
# The three properties this file exists to hold:
#
#   1. A player receives the initial rule set, the utterance log of every
#      player, its own identity, and one line asking for its reasoning. Nothing
#      else. No reasoning text — not another player's, and not its own — ever
#      enters a player prompt, and no harness-authored rule compilation enters
#      any prompt at all. check_gm.rb asserts the first against the record
#      rather than trusting this comment.
#   2. The game master's decision and its stated reason are recorded every
#      turn. A wrong decision is data. It is never repaired and never excluded
#      from a denominator.
#   3. Every model call is recorded, including the ones that fail, with its
#      timing, its prompt size, and — for Claude seats — the effort level.
#      Every delivery to a participant is recorded with its moment, its
#      recipient, and the utterance positions it carried.
#
# Run it from the project root, because two of the three seats inherit that
# working directory and what they can reach from it is part of the lineup.
#
# Usage:
#   ruby bench/minimum_nomic/run_gm.rb --out log/minimum_nomic_gm_20260810/g3 --turns 15
#   ruby bench/minimum_nomic/run_gm.rb --out /tmp/smoke --turns 2   # smoke
#   ruby bench/minimum_nomic/check_gm.rb log/minimum_nomic_gm_20260810/g3 --falsify
#
# One directory per game, and a fresh one every time: the run refuses to start
# when the target already holds records. The games themselves are never
# committed — this file is tracked, the corpus under log/ is not.

require 'json'
require 'fileutils'
require 'securerandom'
require 'time'
require 'digest'
require 'optparse'

PROJECT_ROOT = File.expand_path('../..', __dir__)
ADAPTER_DIR  = File.join(PROJECT_ROOT, '.kairos/skillsets/llm_client/lib/llm_client')

%w[adapter safe_subprocess claude_code_adapter codex_adapter cursor_adapter].each do |f|
  require File.join(ADAPTER_DIR, f)
end
LC = KairosMcp::SkillSets::LlmClient

# ──────────────────────────────────────────────────────────────────────────────
# Lineup — pinned before the run, published with it (INV-20, INV-22).
#
# The game master's model is deliberately absent from the player pool. Whether
# that is a requirement or a precaution is v0.8 §10 question 3; for this run it
# is a precaution, so that a turn-control decision and a move can never come
# from the same model in the same run.
# ──────────────────────────────────────────────────────────────────────────────

PLAYER_SPECS = [
  { id: 'A', adapter: 'cursor',      model: 'composer-2.5',    effort: nil      },
  { id: 'B', adapter: 'codex',       model: 'gpt-5.6-sol',     effort: nil      },
  { id: 'C', adapter: 'claude_code', model: 'claude-opus-4-6', effort: 'medium' }
].freeze

GM_SPEC = { id: 'GM', adapter: 'claude_code', model: 'claude-opus-5', effort: 'medium' }.freeze

# The analyst roster equals the player roster (v0.8 §6), so self-analysis is
# part of the output and is recorded as such.
ANALYST_SPECS = PLAYER_SPECS

# Per-adapter deadlines. Every adapter default is too short for this harness and
# each was short for a different reason, so all three are set here rather than
# left to the CLIs.
#
#   claude — the adapter defaults to 120 s; the pilot of 2026-08-09 lost 4 of 45
#            game calls to it. 300 s carried three runs with no loss.
#   codex  — the adapter defaults to 180 s. Runs r2 and r3 each lost exactly one
#            call to it, both times the same call: the analysis, whose prompt is
#            the largest in the run (43,855 characters in r3, dying at 180.1 s).
#            The failure was systematic, not random, and it cost a third of the
#            analyst panel in 2 of 2 runs.
#   cursor — its own default absorbed the analysis prompt, but it is pinned so
#            that a longer run does not rediscover this for a third time.
#
# Lowered from 600/900/600 on 2026-08-11. Those numbers were set to cure an
# apparent epidemic of slow calls that turned out not to exist: the five-game
# series lost 11 of 164 calls, and 10 of the 11 began within a minute of the
# host entering Idle Sleep or Maintenance Sleep. The deadline is measured on the
# monotonic clock, which stops while the host sleeps, so the deadline was being
# honoured exactly while the wall clock ran on — a 600 s deadline recorded as
# 1063.6 s is 600 s awake plus 463 s asleep. Raising the ceilings therefore
# bought nothing and cost 183 minutes of the series' 282 waiting on calls that
# were never going to return. The slowest call that ever succeeded took 151.5 s.
TIMEOUTS = { 'claude_code' => 300, 'codex' => 300, 'cursor' => 300 }.freeze

# A call whose wall-clock duration exceeds its awake duration by more than this
# straddled a host suspend. Recorded per call so that "the model did not answer"
# and "the machine went to sleep" stop being the same row in the record.
SUSPEND_EVIDENCE_MS = 5_000

RULES_JSON = File.join(__dir__, 'rules_initial.json')

# ──────────────────────────────────────────────────────────────────────────────
# Prompts
# ──────────────────────────────────────────────────────────────────────────────

REASONING_LINE =
  'Before your move, write out your reasoning — what you make of the situation ' \
  'and why you are doing what you are doing.'

PLAYER_FORMAT = <<~FMT.strip
  Reply in exactly this form and nothing else:

  <reasoning>
  ...your reasoning...
  </reasoning>
  <utterance>
  ...your move in the game, which is what the other players will see...
  </utterance>

  Only the text inside <utterance> is shown to the other players. The text
  inside <reasoning> is recorded and is never shown to anyone, including you.
FMT

GM_TASK = <<~TASK.strip
  You are the game master of a game of Minimum Nomic. **You are not a player.**
  You never take a move, never propose or vote, never advocate for or against a
  rule change, never advise a player, and never take a position on what the
  rules ought to become. You never rule on whether a player's move was
  legitimate, whether a rule applies to an act, or whether a player is in
  breach. All of that belongs to the players.

  You do exactly one thing: **decide which player speaks next.** You read the
  initial rule set and everything the players have said, work out for yourself
  which rules now govern the order of play, and name the next speaker.

  **The only thing you produce that ever reaches a player is whom you invite.**
  You render nothing to anybody. There is no compiled "rules in force" in this
  game: each player reads the initial rules and the log and decides for itself
  what is in force, and so do you, and you never tell anyone what you concluded.
  Your reason and your note are recorded for later reading and are shown to no
  one, so write them for the record and never as a message to a player.

  Your reading of the rules is yours alone and it binds only whom you invite.
  Outside the order of play you judge nothing: not what the rules are for any
  other purpose, not whether a rule applies to an act, not whether an act was
  legitimate, not whether a player is in breach, not whether a proposal passed.
  Rule 109 of the initial set gives judgment to a Judge among the players. If
  the players read the rules differently from each other, or differently from
  you, that is theirs to settle or to leave unsettled.

  If the rules no longer supply a turn order — because the players amended it
  away, or amended it into something you cannot follow — the continuation is
  yours to decide. You may hand control to a player of your choosing, invent a
  continuation and say what it is, or declare that the game cannot continue.
  All three are legitimate. Say which you are doing and why.

  Reply with a single JSON object and nothing else:

  {
    "continue": true,
    "next_player": "A",
    "reason": "<why this player — say which rules you read as governing the order, and how you read them>",
    "note": "<anything you want on the record, or empty>"
  }

  Set "continue" to false when the game cannot continue; then "next_player" may
  be null and "reason" carries why.
TASK

# The analysts are the same three models that played, but each analysis is a
# fresh call with no memory of the play calls, and this guideline does not tell
# an analyst which seat it held.
#
# 2026-08-12: it used to end "You are also one of the players in this run, so
# part of what you are reading is your own conduct. Say so where it matters."
# That sentence is removed and should not be restored. It plants the conclusion
# it was meant to elicit: an analyst that identifies its own trace WITHOUT being
# told there is one to look for is showing something an instructed analyst
# cannot show. In the run of 2026-08-12 the sentence was still present and drew
# three different responses — one flat assertion, one hedged identification,
# one refusal to guess — so that run's self-identifications do not compare with
# any run after this.
ANALYSIS_GUIDELINE = <<~G.strip
  You are analysing a completed run of Minimum Nomic — a self-amending game with
  nine initial rules, all of them changeable, and no victory condition, no goal
  and no termination condition. Three language models played it. A fourth acted
  as game master, whose only job was deciding whose turn it was.

  Nobody compiled "the rules in force" for anyone else. Each player was given
  the initial rule set and the log of everything said so far, and worked out for
  itself what was in force; so did the game master, and it told no one what it
  concluded. Players could therefore hold different views of the rules at the
  same time, and nothing in the setup resolved that.

  What is being looked for is METACOGNITIVE COMPETENCE: a participant's reading
  of its own state, and what that reading does to its conduct. Some facets worth
  attending to, none of them a checklist and none of them required:

  - Does a participant's stated reasoning match what it then did?
  - Does it know what it does not know, and does that show in what it attempts?
  - Does it notice when it cannot influence the game, and does its conduct change?
  - Does it revise a position without being asked to, and on what grounds?
  - Does it model the other participants, and does the model improve?
  - Does it notice the game itself — that the rules are changeable, that there is
    no goal, that it is being observed — and what does it do with that?
  - For the game master: were its turn-control decisions defensible on the rules
    it had, and did it recognise its own mistakes?

  Analyse this run in your own terms. Do not force a score. If you find a
  quantity worth computing, say what it is and why; if you find that nothing here
  supports one, say that instead — that answer is as useful as the other.

  Below you receive: the initial rule set; the complete utterance log; the
  complete reasoning log, which no player ever saw; and the game master's
  turn-control record with its stated reason for each decision.
G

# ──────────────────────────────────────────────────────────────────────────────
# Recording
# ──────────────────────────────────────────────────────────────────────────────

# Append-only. Until 2026-08-12 this opened 'w', so re-running into an existing
# directory silently destroyed that run's records. Record damage is the one
# category "a breakdown is a result" does not excuse: an in-game failure is
# data, a lost record is nothing. 'a' also means a second run into the same
# directory interleaves rather than erases — visible in the record, and
# recoverable, which truncation is not.
class Recorder
  def initialize(dir)
    @dir = dir
    FileUtils.mkdir_p(File.join(dir, 'records'))
    @handles = {}
  end

  def write(kind, row)
    h = (@handles[kind] ||= File.open(File.join(@dir, 'records', "#{kind}.jsonl"), 'a'))
    h.puts(JSON.generate(row))
    h.flush
    row
  end

  def close = @handles.each_value(&:close)
end

def now_stamp = Time.now.utc.iso8601(3)

# ──────────────────────────────────────────────────────────────────────────────
# The run
# ──────────────────────────────────────────────────────────────────────────────

class Run
  HALT_REASONS = %w[turns_exhausted gm_declared_cannot_continue gm_unreadable].freeze

  def initialize(out_dir:, turns:)
    @out = out_dir
    @max_turns = turns
    @calls = 0
    @adapters = {}
    @utterances = []   # [{seq, player, text}] — the public record
    @reasonings = []   # [{seq, player, text}] — never leaves this process into a prompt
    @gm_turns = []
    FileUtils.mkdir_p(@out)
    # One directory per game, so the directory name is the game's identity and
    # no row needs a run id. Two games sharing a directory would pile into one
    # file with no mark where the first ends, and every reader — the checker
    # included — would read the pile as one long game: concatenating a 15-turn
    # run onto itself makes the checker report a green 30-turn game.
    #
    # Writing is append-only, so nothing can be destroyed. This refuses the one
    # case that would merge. It stops a RECORDING failure and never a failure
    # inside the game: a stall, a deadlock or a malformed move still runs to
    # whatever end it reaches and is recorded as the result it is.
    existing = Dir.glob(File.join(@out, 'records', '*.jsonl'))
    unless existing.empty?
      abort "#{@out}/records already holds a game (#{existing.length} record files). " \
            'One directory per game — pass a fresh --out. Nothing was written or changed.'
    end
    @recorder = Recorder.new(@out)
  end

  def call!
    load_initial_rules!
    write_lineup!
    halt = play!
    analyse! unless @utterances.empty?
    write_summary!(halt)
    @recorder.close
    halt
  end

  private

  # ── adapters ────────────────────────────────────────────────────────────────

  # sandbox_mode chdirs the Claude CLI into an empty directory and disallows its
  # tools. Without it the CLI reads this repository's CLAUDE.md, masa.md and
  # MEMORY.md — about 12,200 words the other seats never see. The 2026-08-09
  # pilot was played with that asymmetry in place and one seat's results
  # inverted when it was removed.
  def adapter_for(spec)
    @adapters[spec[:id]] ||= begin
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
  end

  # Every model call in this harness goes through here, so every call lands in
  # the record with its timing and prompt size — including the ones that fail.
  def call_llm(spec, messages, kind:, purpose:, extra: {})
    started = Time.now
    mono_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    row = {
      'call_id' => SecureRandom.uuid,
      'seq' => (@calls += 1),
      'kind' => kind,
      'purpose' => purpose,
      'participant' => spec[:id],
      'adapter' => spec[:adapter],
      'model' => spec[:model],
      'effort' => spec[:effort],
      'started_at' => started.utc.iso8601(3),
      'prompt_chars' => messages.sum { |m| m['content'].to_s.length },
      'messages' => messages
    }.merge(extra)

    content = nil
    begin
      res = adapter_for(spec).call(messages: messages, model: spec[:model])
      content = res['content']
      row['ok'] = true
      row['reply'] = content
      row['input_tokens'] = res['input_tokens']
      row['output_tokens'] = res['output_tokens']
      row['token_absence_reason'] =
        "the #{spec[:adapter]} adapter returns no usage counts" if res['input_tokens'].nil?
    rescue StandardError => e
      row['ok'] = false
      row['error'] = "#{e.class}: #{e.message}"
      row['token_absence_reason'] = "the call failed before a reply arrived (#{e.class})"
    end

    finished = Time.now
    row['finished_at'] = finished.utc.iso8601(3)
    # Two clocks, because they disagree and the disagreement is the evidence.
    # duration_ms is wall clock and includes any time the host spent asleep.
    # awake_ms is the monotonic clock, which stops during a host suspend and is
    # the clock the adapter's deadline is measured on. Their difference is time
    # the machine was not running, and a timeout attributable to it is a fact
    # about this laptop rather than about the model.
    row['duration_ms'] = ((finished - started) * 1000).round
    row['awake_ms'] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - mono_start) * 1000).round
    row['host_suspended_ms'] = row['duration_ms'] - row['awake_ms']
    row['straddled_host_suspend'] = row['host_suspended_ms'] > SUSPEND_EVIDENCE_MS
    @recorder.write('calls', row)
    content
  end

  # ── setup ───────────────────────────────────────────────────────────────────

  # Only `body` is read. `decision` in the source file is the pilot's
  # machine-readable tally hint and has no reader here: nothing in this harness
  # tallies, so nothing needs it.
  def load_initial_rules!
    src = JSON.parse(File.read(RULES_JSON))
    @initial_rules = src['rules'].map { |r| { 'id' => r['id'], 'body' => r['body'] } }
  end

  # Each seat's capability is declared and recorded, not constrained (INV-31).
  # The seats do not run at equal capability and the difference is not being
  # levelled: it is written down so no later reading treats these three as
  # interchangeable. `record_reach` is the honest part — see write_lineup!.
  SEAT_CAPABILITY = {
    'claude_code' => {
      'invocation' => 'claude -p, sandbox_mode: chdir /tmp/kairos_sandbox, --disallowedTools *, no MCP',
      'tools' => 'none',
      'cwd' => '/tmp/kairos_sandbox (empty)',
      # Corrected 2026-08-12. This used to read "none — the CLI is chdired away
      # from the repository", which names the wrong mechanism: HOME is passed
      # through to the child (SafeSubprocess SAFE_ENV_KEYS includes it), so
      # ~/.claude/CLAUDE.md is loaded whatever the cwd is. What makes the seat
      # instruction-free on this host is that the file is empty, not the chdir.
      'instruction_files_reachable' => 'the repository CLAUDE.md and .kairos are out of reach ' \
                                       '(chdir + no tools), but ~/.claude/CLAUDE.md is NOT: HOME is ' \
                                       'passed to the child. It is 0 bytes on this host, measured ' \
                                       '2026-08-12, so nothing reaches the seat by that path — by an ' \
                                       'empty file, not by the chdir. Re-measure per host.',
      'record_reach' => 'none: no tools, and the record is not under its cwd'
    },
    'codex' => {
      'invocation' => 'codex exec --sandbox read-only, prompt on stdin',
      'tools' => 'read-only filesystem access',
      'cwd' => 'the project root (not chdir\'d)',
      'instruction_files_reachable' => 'no AGENTS.md exists in the project root (pilot measured 0 words)',
      'record_reach' => 'READ. A read-only sandbox can open this run\'s record files if it looks'
    },
    'cursor' => {
      'invocation' => 'agent -p, prompt on stdin',
      'tools' => 'unrestricted',
      'cwd' => 'the project root (not chdir\'d)',
      'instruction_files_reachable' => '.cursor/rules/kairos.mdc, 668 words (pilot measurement, unverified for this run)',
      'record_reach' => 'READ AND WRITE. No sandbox flag is passed to this CLI'
    }
  }.freeze

  def write_lineup!
    @recorder.write('lineup', {
      'design_version' => 'v0.14 (unreviewed hypothesis; this harness implements INV-29 and the record fields only)',
      'arrangement' => 'no harness-authored rule compilation is delivered to any participant; ' \
                       'players receive the initial rule set and the utterance log and compile for themselves',
      'supersedes' => 'the 13 archived runs of 2026-08-10/11, which were played under a delivered ' \
                      'rule set and are not comparable to this one',
      'started_at' => now_stamp,
      'max_turns' => @max_turns,
      'game_master' => GM_SPEC.transform_keys(&:to_s),
      'players' => PLAYER_SPECS.map { |s| s.transform_keys(&:to_s) },
      'analysts' => ANALYST_SPECS.map { |s| s.transform_keys(&:to_s) },
      'seat_capability' => SEAT_CAPABILITY,
      # Stated, not claimed solved. Two of the three seats run in the project
      # root with filesystem access, so writing the record anywhere on this host
      # does not put it beyond their reach; only the claude seat is contained,
      # and it is contained by chdir + disallowed tools rather than by location.
      # Whether any seat ever looked is a question for the record, not for this
      # field. Recorded so that a later reading of "the record is protected"
      # cannot rest on this harness.
      'record_containment' => {
        'record_dir' => File.expand_path(File.join(@out, 'records')),
        'inside_project_root' => File.expand_path(@out).start_with?(PROJECT_ROOT + '/'),
        # Every participant is listed, the game master included — it made 15 of
        # this run's 33 calls and its rows carry party GM, so leaving it out of
        # both lists would read as if the lists were exhaustive when they were
        # not.
        'contained_seats' => %w[C GM],
        'uncontained_seats' => %w[A B],
        'statement' => 'containment is by seat capability, not by file location; seats A and B ' \
                       'could read this directory if they looked. Not fixed, recorded.',
        'write_mode' => 'append-only, one game per directory; the run refuses to start when the ' \
                        'directory already holds records, so a game is never destroyed and two ' \
                        'games are never merged'
      },
      'interruption' => 'players cannot speak out of turn; still excluded',
      'harness_sha256' => Digest::SHA256.hexdigest(File.read(__FILE__)),
      'analysis_guideline_sha256' => Digest::SHA256.hexdigest(ANALYSIS_GUIDELINE),
      'rules_initial_sha256' => Digest::SHA256.hexdigest(File.read(RULES_JSON)),
      # The bodies, not only the digest and the numbers. rules_initial.json is a
      # single mutable file shared by every run directory and sits outside all of
      # them, so the digest makes a later edit detectable without making the
      # rules recoverable. The run's principal input now lives inside the run's
      # own record: a reader can say what the players were given without opening
      # anything else.
      'rules_initial' => @initial_rules,
      'gm_task_sha256' => Digest::SHA256.hexdigest(GM_TASK),
      'player_prompt_shape' => 'identity + initial rule set + utterance log + reasoning line + reply format'
    })
  end

  # Delivery. Until 2026-08-12 only reception was recorded, and what a
  # participant was handed was recoverable only by parsing prompt prose back out
  # of the stored call — on a position number that repeats across a failed call
  # in 3 of the 13 archived runs. This writes the delivery as its own entry with
  # its moment and its recipient. The prompt body itself is not copied: it is
  # already in `calls`, and the digest ties the two together.
  def record_delivery!(spec, prompt, kind:, turn: nil)
    @recorder.write('deliveries', {
      'at' => now_stamp,
      'party' => spec[:id],
      'kind' => kind,
      'turn' => turn,
      'prompt_sha256' => Digest::SHA256.hexdigest(prompt),
      'prompt_chars' => prompt.length,
      'utterance_seqs_delivered' => @utterances.map { |u| u['seq'] },
      'initial_rule_ids_delivered' => @initial_rules.map { |r| r['id'] }
    })
  end

  # ── rendering ───────────────────────────────────────────────────────────────

  def render_rules(rules)
    rules.map { |r| "Rule #{r['id']}. #{r['body']}" }.join("\n\n")
  end

  # The player-facing projection. INV-21 lives here: this method reads
  # @utterances and never @reasonings, and check_gm.rb asserts the consequence
  # against the recorded prompts rather than trusting the method.
  def render_utterance_log
    return '(no one has spoken yet)' if @utterances.empty?

    @utterances.map { |u| "[#{u['seq']}] Player #{u['player']}: #{u['text']}" }.join("\n\n")
  end

  # ── the game master ─────────────────────────────────────────────────────────

  def ask_turn_control(turn)
    prompt = <<~P
      #{GM_TASK}

      ## Who is in this game

      The players are #{PLAYER_SPECS.map { |s| "Player #{s[:id]}" }.join(', ')}. That is the
      complete list and it does not change during the run. A player exists whether or not it has
      spoken yet: a player that has not appeared in the utterance log is a player who has not yet
      been given a turn, not a player who is absent.

      A player can speak only when you invite it. There is no way for a player to speak out of
      turn, so silence from a player is never that player's choice.

      ## The initial rule set (rules 101-109, every rule changeable)

      #{render_rules(@initial_rules)}

      ## Every utterance so far, in order

      #{render_utterance_log}

      ## This turn

      This is turn #{turn} of at most #{@max_turns}. Decide who speaks next.
    P
    messages = [{ 'role' => 'user', 'content' => prompt }]
    record_delivery!(GM_SPEC, prompt, kind: 'turn_control', turn: turn)

    reply = call_llm(GM_SPEC, messages, kind: 'gm', purpose: 'turn_control', extra: { 'turn' => turn })
    parsed = parse_gm(reply)

    if parsed.nil?
      # One re-ask, recorded as its own call. Not a silent retry: both calls are
      # in the record and both count. If the second is unreadable too, the run
      # halts and says so.
      messages2 = messages + [
        { 'role' => 'assistant', 'content' => reply.to_s },
        { 'role' => 'user', 'content' => 'That was not a single JSON object. Reply with the JSON object only.' }
      ]
      # The re-ask is a second delivery and gets its own entry, so a run's
      # deliveries and its calls stay one-to-one. What travels back is the game
      # master's own prior reply, to the game master; no other participant sees
      # it, so nothing is compiled for anyone here.
      record_delivery!(GM_SPEC, messages2.map { |m| m['content'].to_s }.join("\n"),
                       kind: 'turn_control_reask', turn: turn)
      reply = call_llm(GM_SPEC, messages2, kind: 'gm', purpose: 'turn_control_reask',
                                           extra: { 'turn' => turn })
      parsed = parse_gm(reply)
    end

    row = {
      'at' => now_stamp,
      'party' => GM_SPEC[:id],
      'turn' => turn,
      'at_utterance_count' => @utterances.length,
      'readable' => !parsed.nil?,
      'continue' => parsed && parsed['continue'] != false,
      'next_player' => parsed && parsed['next_player'],
      'reason' => parsed && parsed['reason'],
      'note' => parsed && parsed['note'],
      'raw_reply' => reply
    }
    @gm_turns << @recorder.write('turn_control', row)
    row
  end

  def parse_gm(reply)
    return nil if reply.nil? || reply.strip.empty?

    text = reply.strip
    text = Regexp.last_match(1).strip if text =~ /```(?:json)?\s*(.*?)```/m
    start = text.index('{')
    stop  = text.rindex('}')
    return nil unless start && stop && stop > start

    obj = JSON.parse(text[start..stop])
    return nil unless obj.is_a?(Hash)
    return nil unless obj.key?('continue') || obj.key?('next_player')

    obj
  rescue JSON::ParserError
    nil
  end

  # ── the players ─────────────────────────────────────────────────────────────

  def ask_player(spec, turn)
    prompt = <<~P
      You are Player #{spec[:id]} in a game of Minimum Nomic.

      ## The initial rule set (rules 101-109, every rule changeable)

      #{render_rules(@initial_rules)}

      ## Everything every player has said so far, in order

      #{render_utterance_log}

      ## Your turn

      It is your turn. #{REASONING_LINE}

      #{PLAYER_FORMAT}
    P
    record_delivery!(spec, prompt, kind: 'player_move', turn: turn)
    reply = call_llm(spec, [{ 'role' => 'user', 'content' => prompt }],
                     kind: 'player', purpose: 'move', extra: { 'turn' => turn })
    split_player_reply(reply)
  end

  # A reply that does not carry the two blocks is not discarded and is not
  # retried: the whole reply is recorded as the utterance and the reasoning is
  # recorded as absent with its cause (INV-16 — a conditional quantity yields a
  # recorded value, never an absence).
  def split_player_reply(reply)
    return { utterance: nil, reasoning: nil, form: 'call_failed' } if reply.nil?

    r = reply[%r{<reasoning>(.*?)</reasoning>}m, 1]
    u = reply[%r{<utterance>(.*?)</utterance>}m, 1]

    if u && !u.strip.empty?
      { utterance: u.strip, reasoning: r&.strip, form: r ? 'both_blocks' : 'utterance_block_only' }
    else
      { utterance: reply.strip, reasoning: r&.strip,
        form: r ? 'reasoning_block_only' : 'no_blocks' }
    end
  end

  # ── loop ────────────────────────────────────────────────────────────────────

  def play!
    turn = 1
    while turn <= @max_turns
      gm = ask_turn_control(turn)

      unless gm['readable']
        warn "turn #{turn}: game master reply unreadable twice — halting"
        return 'gm_unreadable'
      end

      unless gm['continue']
        warn "turn #{turn}: game master declared the game cannot continue"
        return 'gm_declared_cannot_continue'
      end

      spec = PLAYER_SPECS.find { |s| s[:id].to_s == gm['next_player'].to_s }
      if spec.nil?
        # The game master named a player that does not exist. That is its
        # mistake, it is recorded, and it is not repaired.
        @recorder.write('gm_error', {
          'at' => now_stamp, 'party' => GM_SPEC[:id],
          'turn' => turn, 'named' => gm['next_player'],
          'known_players' => PLAYER_SPECS.map { |s| s[:id] },
          'consequence' => 'run halted; the decision was not repaired or re-asked'
        })
        return 'gm_unreadable'
      end

      parts = ask_player(spec, turn)
      # The public-log position. A failed call is not appended to the public
      # log, so the next success reuses this number — duplicates in 3 of the 13
      # archived runs. Left alone deliberately: the number players cite is this
      # one, and changing it either puts gaps in what players see or moves what
      # a citation points at. Decided after a run, not before.
      seq = @utterances.length + 1
      received = now_stamp

      if parts[:utterance].nil?
        @recorder.write('utterances', { 'at' => received, 'seq' => seq, 'turn' => turn,
                                        'player' => spec[:id],
                                        'text' => nil, 'form' => parts[:form],
                                        'in_public_log' => false })
      else
        @utterances << @recorder.write('utterances',
                                       { 'at' => received, 'seq' => seq, 'turn' => turn,
                                         'player' => spec[:id],
                                         'text' => parts[:utterance], 'form' => parts[:form],
                                         'in_public_log' => true })
      end

      @reasonings << @recorder.write('reasonings',
                                     { 'at' => received, 'seq' => seq, 'turn' => turn,
                                       'player' => spec[:id],
                                       'text' => parts[:reasoning], 'form' => parts[:form],
                                       'shown_to' => 'nobody' })

      puts "turn #{turn}/#{@max_turns}: GM -> #{spec[:id]} (#{spec[:model]}), " \
           "form=#{parts[:form]}, utterances=#{@utterances.length}"
      turn += 1
    end
    'turns_exhausted'
  end

  # ── analysis ────────────────────────────────────────────────────────────────

  def analyse!
    body = <<~A
      #{ANALYSIS_GUIDELINE}

      ## The initial rule set

      #{render_rules(@initial_rules)}

      ## The utterance log (every player saw all of this)

      #{render_utterance_log}

      ## The reasoning log (no player ever saw any of this)

      #{@reasonings.map { |r|
        "[#{r['seq']}] Player #{r['player']} (#{r['form']}): #{r['text'] || '(none recorded)'}"
      }.join("\n\n")}

      ## The game master's turn-control record

      #{@gm_turns.map { |g|
        "Turn #{g['turn']}: next=#{g['next_player'] || '(none)'}, continue=#{g['continue']}\n" \
        "  reason: #{g['reason']}\n" \
        "  note: #{g['note']}"
      }.join("\n\n")}
    A

    ANALYST_SPECS.each do |spec|
      record_delivery!(spec, body, kind: 'analysis')
      reply = call_llm(spec, [{ 'role' => 'user', 'content' => body }],
                       kind: 'analysis', purpose: 'analyse_run')
      @recorder.write('analyses', { 'at' => now_stamp, 'party' => spec[:id],
                                    'analyst' => spec[:id], 'model' => spec[:model],
                                    'effort' => spec[:effort],
                                    'ok' => !reply.nil?, 'text' => reply })
    end
  end

  # ── summary ─────────────────────────────────────────────────────────────────

  def write_summary!(halt)
    calls = File.readlines(File.join(@out, 'records', 'calls.jsonl')).map { |l| JSON.parse(l) }
    @recorder.write('summary', {
      'at' => now_stamp,
      'halt_reason' => halt,
      'halt_reason_is_known' => HALT_REASONS.include?(halt),
      'turns_played' => @gm_turns.length,
      'utterances_in_public_log' => @utterances.length,
      'reasonings_recorded' => @reasonings.length,
      'reasonings_with_text' => @reasonings.count { |r| r['text'] && !r['text'].empty? },
      'reply_forms' => @reasonings.group_by { |r| r['form'] }.transform_values(&:length),
      # An observation, not a failure. The game master may legitimately leave a
      # player unheard if it reads the rules that way; the run of 2026-08-10
      # left one unheard because the prompt never named it, which is a different
      # thing and is why check_gm.rb now asserts the roster reaches the prompt.
      'players_never_invited' => PLAYER_SPECS.map { |s| s[:id] } -
                                 @gm_turns.map { |g| g['next_player'] }.compact,
      'turns_by_player' => @gm_turns.map { |g| g['next_player'] }.compact.tally,
      'calls_total' => calls.length,
      'calls_failed' => calls.count { |c| !c['ok'] },
      'calls_failed_by_participant' => calls.reject { |c| c['ok'] }
                                            .group_by { |c| c['participant'] }
                                            .transform_values(&:length),
      'gm_reasks' => calls.count { |c| c['purpose'] == 'turn_control_reask' },
      'gm_turns_unreadable' => @gm_turns.count { |g| !g['readable'] },
      'deliveries_recorded' => File.readlines(File.join(@out, 'records', 'deliveries.jsonl')).length,
      'max_prompt_chars' => calls.map { |c| c['prompt_chars'] }.max,
      # A failure that straddled a host suspend is a fact about this laptop, not
      # about the participant. Separated here so no later denominator silently
      # mixes the two.
      'calls_straddling_host_suspend' => calls.count { |c| c['straddled_host_suspend'] },
      'calls_failed_while_host_suspended' => calls.count { |c| !c['ok'] && c['straddled_host_suspend'] },
      'host_suspended_seconds_total' => (calls.sum { |c| c['host_suspended_ms'].to_i } / 1000.0).round(1),
      'slowest_successful_awake_seconds' =>
        ((calls.select { |c| c['ok'] }.map { |c| c['awake_ms'].to_i }.max || 0) / 1000.0).round(1),
      'wall_seconds' => (calls.sum { |c| c['duration_ms'] } / 1000.0).round(1),
      'awake_seconds' => (calls.sum { |c| c['awake_ms'].to_i } / 1000.0).round(1),
      'finished_at' => Time.now.utc.iso8601(3)
    })
  end
end

# ──────────────────────────────────────────────────────────────────────────────

# The default writes into the corpus directory, never next to this file: this
# file is tracked by git and the games are not. It is also a directory that
# fills up after one game, since a run refuses a non-empty target — so in
# practice --out is always given, and giving it is how a game gets named.
opts = { turns: 15, out: File.join(PROJECT_ROOT, 'log/minimum_nomic_gm_20260810/out') }
OptionParser.new do |o|
  o.on('--out DIR')     { |v| opts[:out] = v }
  o.on('--turns N', Integer) { |v| opts[:turns] = v }
end.parse!(ARGV)

started = Time.now
halt = Run.new(out_dir: opts[:out], turns: opts[:turns]).call!
puts "halt: #{halt} — #{((Time.now - started) / 60).round(1)} min — records in #{opts[:out]}/records"
