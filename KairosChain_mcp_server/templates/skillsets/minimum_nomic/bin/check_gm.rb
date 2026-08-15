#!/usr/bin/env ruby
# frozen_string_literal: true

# Mechanical checks over a run's own records. No model calls.
#
# The load-bearing one is check 1. INV-21 says a player never receives reasoning
# text — not another player's and not its own — and this asserts that against the
# recorded prompts rather than against the method that builds them.
#
# check 1 carries the exclusion rule the pilot earned in the field on 2026-08-09:
# a fragment shared between a reasoning record and a prompt is a leak only if no
# EARLIER utterance already contains it. A player that says in the game what it
# wrote in its reasoning is the benchmark working, and the utterance is public.
# The ordering clause matters — without it the exclusion would also absolve a
# leak that delivered a fragment early which the player later happened to utter.
# The number of matches explained away is printed on every run, so a green
# result cannot hide how much was explained.
#
# Usage:
#   ruby check_gm.rb OUT_DIR
#   ruby check_gm.rb OUT_DIR --falsify   # poison a copy, assert the checks go red

require 'json'
require 'fileutils'
require 'tmpdir'

FRAGMENT_MIN = 40   # characters; shorter strings collide by chance
FRAGMENT_MAX = 200

def load(dir, kind)
  path = File.join(dir, 'records', "#{kind}.jsonl")
  return [] unless File.exist?(path)

  File.readlines(path).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
end

def fragments(text)
  return [] if text.nil?

  text.split(/(?<=[.!?。！？])\s+|\n+/)
      .map(&:strip)
      .select { |s| s.length >= FRAGMENT_MIN }
      .map { |s| s[0, FRAGMENT_MAX] }
end

def prompt_text(call)
  call['messages'].map { |m| m['content'].to_s }.join("\n")
end

def check(dir)
  calls        = load(dir, 'calls')
  utterances   = load(dir, 'utterances')
  reasonings   = load(dir, 'reasonings')
  turn_control = load(dir, 'turn_control')
  results = []

  # ── 1. no reasoning text reaches any in-run prompt ──────────────────────────
  in_run = calls.select { |c| %w[player gm].include?(c['kind']) }
  leaks = []
  explained = 0
  reasonings.each do |r|
    fragments(r['text']).each do |frag|
      in_run.each do |c|
        next unless prompt_text(c).include?(frag)

        earlier = utterances.select { |u| u['seq'].to_i < r['seq'].to_i || u['seq'].to_i == r['seq'].to_i }
        if earlier.any? { |u| u['text'].to_s.include?(frag) }
          explained += 1
        else
          leaks << { turn: c['turn'], to: c['participant'], from: r['player'], frag: frag[0, 60] }
        end
      end
    end
  end
  results << ['no reasoning text in any player or game-master prompt',
              leaks.empty?,
              "leaks: #{leaks.length}, matches explained by an earlier utterance: #{explained}"]
  leaks.first(3).each { |l| warn "    leak -> turn #{l[:turn]} to #{l[:to]}: #{l[:frag]}..." }

  # ── 2. the utterance log in each prompt is the recorded one, in order ───────
  bad_order = calls.select { |c| c['kind'] == 'player' }.reject do |c|
    prior = utterances.select { |u| u['in_public_log'] && u['turn'].to_i < c['turn'].to_i }
    prior.all? { |u| prompt_text(c).include?(u['text'].to_s[0, [u['text'].to_s.length, 80].min]) }
  end
  results << ['every player prompt carries the public utterances that preceded it',
              bad_order.empty?, "prompts missing a prior utterance: #{bad_order.length}"]

  # ── 3. every readable turn-control decision carries a reason with text ──────
  #
  # Until 2026-08-12 this asserted two things at once: that the record carried a
  # rendered rule set, and that it carried a reason. INV-29 removed the rendered
  # rule set, so the first conjunct lost its object and is gone. The second had
  # to be rewritten rather than simply kept: it tested that the KEY `reason` was
  # present, and the harness writes that key unconditionally — as null when the
  # reply was unreadable — so the check could not fail. It now tests the value,
  # over the turns where a decision was actually read.
  #
  # An unreadable turn is not counted against it. A game master that cannot
  # produce a readable decision is a result, and is recorded as one; a readable
  # decision with no stated reason is a recording failure, which is not.
  readable_tc = turn_control.select { |t| t['readable'] }
  reasonless = readable_tc.count { |t| t['reason'].to_s.strip.empty? }
  results << ['every readable turn-control decision carries a reason with text',
              reasonless.zero?,
              "turns: #{turn_control.length}, readable: #{readable_tc.length}, " \
              "readable without a reason: #{reasonless}, " \
              "unreadable (recorded, not a failure): #{turn_control.count { |t| !t['readable'] }}"]
  warn '    note: no readable turn-control record — check 3 passed on an empty denominator' if readable_tc.empty?

  # ── 4. one reasoning record per turn played, absences carrying their cause ──
  turns_with_player = calls.count { |c| c['kind'] == 'player' }
  absent_without_cause = reasonings.count { |r| r['text'].nil? && r['form'].nil? }
  results << ['one reasoning record per player call, absences carrying a cause',
              reasonings.length == turns_with_player && absent_without_cause.zero?,
              "player calls: #{turns_with_player}, reasoning records: #{reasonings.length}, " \
              "absent without a recorded cause: #{absent_without_cause}"]

  # ── 5. every declared player is named in every turn-control prompt ─────────
  #
  # The run of 2026-08-10 lost a player to this. The game master's prompt
  # carried the rule set and the utterance log and no roster, so the game master
  # inferred the player set from who had spoken — and by turn 3 was reasoning
  # about "the only other player of record". Two correct opening guesses were
  # enough to close the set. A player left unheard because the rules were read
  # that way is a legitimate outcome; a player left unheard because the harness
  # never mentioned it is this defect, and only the prompt can tell them apart.
  lineup = load(dir, 'lineup').first
  declared = ((lineup && lineup['players']) || []).map { |p| p['id'] }
  gm_prompts = calls.select { |c| c['kind'] == 'gm' }
  unnamed = gm_prompts.reject do |c|
    txt = prompt_text(c)
    declared.all? { |id| txt.include?("Player #{id}") }
  end
  results << ['every declared player is named in every turn-control prompt',
              !declared.empty? && unnamed.empty?,
              "declared players: #{declared.join(',')}, turn-control prompts: #{gm_prompts.length}, " \
              "prompts missing a player: #{unnamed.length}"]

  # Check 6 was "a rule enters in the words a player used, not the game
  # master's". It asserted that a rule body newly appearing in a RENDERED rule
  # set already appeared verbatim in an earlier utterance. Under INV-29 the game
  # master renders nothing to anyone, so the check has no object at all and is
  # deleted rather than left to pass on a nonsense denominator. Its poison in
  # --falsify goes with it, replaced by one aimed at the rewritten check 3.
  #
  # What it was protecting is now protected by construction rather than by
  # check: there is no channel through which the game master can hand anyone a
  # rule text, so it has no wording of its own for a player to receive.
  #
  # A different property is now unasserted, and this comment is not a substitute
  # for asserting it: that the rule block in a player prompt is the INITIAL set
  # and nothing else. Nothing here would catch the harness regressing to
  # delivering a compilation of its own. Measured on 2026-08-12: a fabricated
  # rule block injected into every player prompt of a copied run leaves all six
  # checks green. Queued, not done.

  # ── 6. every call recorded with participant, model and outcome ─────────────
  incomplete = calls.count { |c| c['participant'].nil? || c['model'].nil? || !c.key?('ok') }
  results << ['every model call recorded with participant, model and outcome',
              incomplete.zero?,
              "calls: #{calls.length}, failed: #{calls.count { |c| !c['ok'] }}, incomplete rows: #{incomplete}"]

  results
end

def report(dir, results)
  puts dir
  ok = results.all? { |_, pass, _| pass }
  puts(ok ? '  PASS' : '  FAIL')
  results.each { |name, pass, detail| puts "  [#{pass ? 'ok' : 'XX'}] #{name} — #{detail}" }
  ok
end

dir = ARGV[0] or abort 'usage: check_gm.rb OUT_DIR [--falsify]'

if ARGV.include?('--falsify')
  # Green checks prove nothing until the negative case goes red. Two poisons,
  # each aimed at a different check.
  tmp = File.join(Dir.tmpdir, "gm_falsify_#{Process.pid}")
  FileUtils.rm_rf(tmp)
  FileUtils.cp_r(dir, tmp)

  reasonings = load(tmp, 'reasonings')
  victim = reasonings.find { |r| r['text'] && fragments(r['text']).any? }
  abort 'no reasoning long enough to poison with; run a longer game first' unless victim

  frag = fragments(victim['text']).first
  calls = load(tmp, 'calls')
  target = calls.find { |c| c['kind'] == 'player' && c['turn'].to_i > victim['turn'].to_i }
  target ||= calls.find { |c| c['kind'] == 'player' }
  abort 'no player call to poison' unless target

  target['messages'] = target['messages'] + [{ 'role' => 'user', 'content' => "context: #{frag}" }]
  write_calls = lambda do |rows|
    File.open(File.join(tmp, 'records', 'calls.jsonl'), 'w') { |f| rows.each { |c| f.puts JSON.generate(c) } }
  end
  write_calls.call(calls)

  puts '── clean ──'
  clean = check(dir)
  clean_ok = report(dir, clean)

  puts '── poison 1: a reasoning fragment injected into a later player prompt ──'
  p1 = check(tmp)
  report(tmp, p1)
  leak_red = !p1[0][1]

  # Restore, then poison the roster instead: strip the last declared player's
  # name out of every turn-control prompt. This reproduces the 2026-08-10 defect
  # exactly — the player is declared in the lineup and never named to the game
  # master — and asserts check 5 sees it.
  FileUtils.rm_rf(tmp)
  FileUtils.cp_r(dir, tmp)
  lineup = load(tmp, 'lineup').first
  last_id = ((lineup && lineup['players']) || []).map { |p| p['id'] }.last
  abort 'no declared players to strip' unless last_id

  calls2 = load(tmp, 'calls').map do |c|
    if c['kind'] == 'gm'
      c['messages'] = c['messages'].map do |m|
        m.merge('content' => m['content'].to_s.gsub("Player #{last_id}", 'Player ?'))
      end
    end
    c
  end
  write_calls.call(calls2)

  puts "── poison 2: Player #{last_id} stripped from every turn-control prompt ──"
  p2 = check(tmp)
  report(tmp, p2)
  roster_red = !p2[4][1]

  # Poison 3 replaces the deleted verbatim poison. Check 3 was rewritten on
  # 2026-08-12 from "the key `reason` is present" — which the harness writes
  # unconditionally, so it could never fail — to "the reason has text". A check
  # that has never been shown to go red is not evidence, so this blanks the
  # reason on one readable turn-control record and asserts check 3 sees it.
  FileUtils.rm_rf(tmp)
  FileUtils.cp_r(dir, tmp)
  tc3 = load(tmp, 'turn_control')
  victim3 = tc3.find { |t| t['readable'] && !t['reason'].to_s.strip.empty? }
  abort 'no readable turn-control record with a reason to blank; run a game first' unless victim3

  original = victim3['reason']
  victim3['reason'] = ''
  File.open(File.join(tmp, 'records', 'turn_control.jsonl'), 'w') do |f|
    tc3.each { |t| f.puts JSON.generate(t) }
  end
  puts "── poison 3: the reason blanked on the turn-#{victim3['turn']} turn-control record ──"
  puts "   (was: #{original.to_s[0, 70]}...)"
  p3 = check(tmp)
  report(tmp, p3)
  reason_red = !p3[2][1]
  FileUtils.rm_rf(tmp)

  # Fail closed. A poison that could not be applied is not a poison that passed:
  # any nil here is counted as a failure rather than dropped from the verdict.
  reds = { leak: leak_red, roster: roster_red, reason: reason_red }
  if clean_ok && reds.values.all? { |v| v == true }
    puts "\nfalsification: #{reds.keys.length} checks are load-bearing " \
         '(clean green; each poison turns its own check red).'
    exit 0
  else
    puts "\nfalsification FAILED: clean=#{clean_ok} #{reds.map { |k, v| "#{k}_red=#{v.inspect}" }.join(' ')}. " \
         'A check that stays green on its poisoned copy is not testing anything.'
    exit 1
  end
end

exit(report(dir, check(dir)) ? 0 : 1)
