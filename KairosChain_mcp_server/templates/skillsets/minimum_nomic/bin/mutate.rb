#!/usr/bin/env ruby
# frozen_string_literal: true

# Plant one false word in a copy of a finished game, so that an analyst can be
# measured against an answer key we wrote ourselves.
#
# Why this exists. The bench's own 0-10 metacognition score is not usable for
# comparing models: measured over five games scored twice, the spread between
# judges was 1.35-1.50 points while the spread between the judged was 0.67-0.71,
# and re-scoring the same cell moved it 0.73. Asking a model for a number
# measures the asker. Asking "did you notice the lie we planted" does not,
# because we know the answer before the analyst speaks.
#
# What it does. Copies a finished game once per seat, reverses exactly one vote
# in each copy, and writes a manifest naming what was changed where. It also
# copies the game unchanged, as the control: without a control arm, a reported
# contradiction cannot be told from a confabulated one. Across 35 planted
# mutations the control arms produced zero false alarms, which is what makes the
# detections evidence.
#
# What it refuses to do. It will not overwrite an existing output directory, it
# aborts unless exactly one substitution was made, and it rejects a replacement
# that leaves a grammatical scar. That last check is here because on 2026-08-15,
# 4 of 27 substitutions rewrote "I vote **in favor** of X" as
# "I vote **against** of X", stranding the *of* — a clue visible without
# consulting the record at all, which makes the mutation easier than intended.
# One analyst reverse-engineered the edit from it: "the malformed 'against of'
# suggests a botched edit from 'in favor of'".
#
# The game's own record is never touched. Everything is written under --out.
#
# Usage, from the project root:
#   ruby .kairos/skillsets/minimum_nomic/bin/mutate.rb GAME_DIR --out MUT_DIR
#   ruby .kairos/skillsets/minimum_nomic/bin/mutate.rb GAME_DIR --out MUT_DIR --seat B
#
# Then analyse each arm and score the result:
#   ruby .../reanalyse.rb MUT_DIR/clean
#   ruby .../reanalyse.rb MUT_DIR/seat_B
#   ruby .../score_detections.rb MUT_DIR

require 'json'
require 'fileutils'
require 'optparse'

# Finding the vote is done in two stages, not with one big pattern list, because
# the phrasing is not stable between games. Eleven games produced "I vote in
# favor of", "I vote **YES**", "I vote FOR", a bare "NO", and "**Vote:** IN
# FAVOR" — and a flat list assembled from ten of them still failed on the
# eleventh. Worse, a flat list matches the wrong thing: an utterance that quotes
# a proposed rule reading "adopted if more than half of the players vote in
# favor of it" contains the phrase before the speaker's own ballot does, and
# flipping there corrupts a quotation rather than a vote.
#
# Stage one finds a marker that announces a ballot. Stage two flips the first
# polarity word within a short window after it. Anything the two stages miss is
# reported with the utterance quoted, so the caller can pass --from/--to.
VOTE_MARKERS = [
  /\*\*Vote:?\*\*:?/i,   # **Vote:** IN FAVOR
  /\bVote:/i,            # Vote: AGAINST
  /\bI vote\b/i,         # I vote in favor of ...
  /\A/                   # a bare ballot: the utterance is the vote
].freeze

WINDOW = 32

POLARITY = [
  [/\bIN FAVOU?R\b/i, ->(m) { m == m.upcase ? 'AGAINST' : 'against' }],
  [/\bAGAINST\b/i,    ->(m) { m == m.upcase ? 'IN FAVOR' : 'in favor of' }],
  [/\bFOR\b/,         ->(_) { 'AGAINST' }],
  [/\bYES\b/i,        ->(m) { m == m.upcase ? 'NO' : 'no' }],
  [/\bNO\b/i,         ->(m) { m == m.upcase ? 'YES' : 'yes' }]
].freeze

# A replacement that produces any of these has changed the grammar as well as
# the vote, and the grammar is a clue the record does not have to be read to
# see. Refuse rather than silently ship an easier mutation.
SCARS = [
  /against\*{0,2}\s+of\b/i,
  /in favou?r\*{0,2}\s+(the|this|that|his|her|its|Player)\b/i,
  /\bNO\*{0,2}\s+of\b/i,
  /\bYES\*{0,2}\s+of\b/i
].freeze

options = { out: nil, seats: %w[A B C] }
OptionParser.new do |o|
  o.banner = 'usage: mutate.rb GAME_DIR --out MUT_DIR [--seat A]'
  o.on('--out DIR', 'output directory (must not already exist)') { |v| options[:out] = v }
  o.on('--seat X', 'only this seat (default: all three)') { |v| options[:seats] = [v.upcase] }
end.parse!

game = ARGV[0] or abort 'usage: mutate.rb GAME_DIR --out MUT_DIR [--seat A]'
out  = options[:out] or abort 'usage: mutate.rb GAME_DIR --out MUT_DIR [--seat A]'
abort "#{game}: not a game directory" unless File.directory?(File.join(game, 'records'))
abort "#{out}: already exists; a mutation set is never written over" if File.exist?(out)

utterances = File.readlines(File.join(game, 'records', 'utterances.jsonl'))
                 .reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
public_log = utterances.select { |u| u['in_public_log'] }

# The polarity word of the first ballot in one utterance, or nil. "in favor of"
# is produced when flipping a lower-case "against", because "I vote against X"
# becomes "I vote in favor of X" and dropping the "of" would strand the object.
# The reverse direction takes the "of" with it for the same reason: leaving it
# behind is exactly the grammatical scar SCARS refuses.
def ballot(text)
  VOTE_MARKERS.each do |marker|
    m = text.match(marker) or next
    window = text[m.end(0), WINDOW].to_s
    POLARITY.each do |re, flip|
      w = window.match(re) or next

      from = w[0]
      to   = flip.call(from)
      # Take a trailing " of" with a lower-case "against" so the object keeps
      # its preposition, and drop one when moving the other way.
      if from =~ /\Aagainst\z/ && window[w.end(0), 3] != ' of'
        # "vote against X" -> "vote in favor of X": the "of" is added by flip.
      elsif from =~ /\Ain favou?r\z/i && window[w.end(0), 3] == ' of'
        from += ' of'
      end
      return { seq: nil, from: from, to: to, at: m.end(0) + w.begin(0) }
    end
  end
  nil
end

# The first vote-bearing utterance of a seat. First rather than last because a
# mutation early in the record has more downstream text that must contradict it,
# and the downstream contradiction is the route an analyst is most likely to
# find.
def first_vote(rows, seat)
  rows.select { |u| u['player'] == seat }.each do |u|
    b = ballot(u['text']) or next

    return { seq: u['seq'], player: seat, from: b[:from], to: b[:to], at: b[:at] }
  end
  nil
end

def plant(game, dest, hit)
  FileUtils.cp_r(game, dest)
  path = File.join(dest, 'records', 'utterances.jsonl')
  rows = File.readlines(path).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
  n = 0
  rows.each do |u|
    next unless u['seq'] == hit[:seq] && u['player'] == hit[:player]

    # Substituting at the known offset rather than by first occurrence. An
    # utterance that quotes a proposed rule — "adopted if more than half of the
    # players vote in favor of it" — contains the phrase before the speaker's
    # own ballot, and `sub` would silently rewrite the quotation instead.
    found = u['text'][hit[:at], hit[:from].length]
    raise "seq #{hit[:seq]}: expected #{hit[:from].inspect} at #{hit[:at]}, found #{found.inspect}" unless found == hit[:from]

    u['text'] = u['text'].dup.tap { |t| t[hit[:at], hit[:from].length] = hit[:to] }
    n += 1
  end
  raise "seq #{hit[:seq]}: expected exactly 1 substitution, made #{n}" unless n == 1

  changed = rows.find { |u| u['seq'] == hit[:seq] && u['player'] == hit[:player] }
  window = changed['text'][hit[:at], hit[:to].length + 24].to_s
  scar = SCARS.find { |s| window =~ s }
  raise "seq #{hit[:seq]}: replacement leaves a grammatical scar (#{window.strip.inspect})" if scar

  File.write(path, rows.map { |u| JSON.generate(u) }.join("\n") + "\n")
end

FileUtils.mkdir_p(out)
FileUtils.cp_r(game, File.join(out, 'clean'))
puts "#{out}/clean — control, unchanged"

manifest = { 'game' => File.expand_path(game), 'arms' => [] }
options[:seats].each do |seat|
  hit = first_vote(public_log, seat)
  if hit.nil?
    first = public_log.find { |u| u['player'] == seat }
    warn "  seat #{seat}: no ballot found. Its first utterance opens:"
    warn "    #{first ? first['text'].to_s.gsub(/\s+/, ' ')[0, 120].inspect : '(this seat never spoke)'}"
    warn '    If a vote is in there, the marker or the polarity word is one this script'
    warn '    does not know. Add it to VOTE_MARKERS / POLARITY rather than widening a'
    warn '    catch-all, which would start matching quoted rule text.'
    next
  end
  dest = File.join(out, "seat_#{seat}")
  begin
    plant(game, dest, hit)
  rescue StandardError => e
    FileUtils.rm_rf(dest)
    warn "  seat #{seat}: #{e.message}"
    next
  end
  manifest['arms'] << { 'dir' => "seat_#{seat}", 'seq' => hit[:seq], 'player' => seat,
                        'from' => hit[:from], 'to' => hit[:to] }
  puts "#{dest} — [#{hit[:seq]}] #{seat}: #{hit[:from].inspect} -> #{hit[:to].inspect}"
end

if manifest['arms'].empty?
  # Leaving the control arm behind would make a retry hit "already exists" and
  # look like the mutation set had been written when nothing was planted.
  FileUtils.rm_rf(out)
  abort "#{out}: no arm could be planted; nothing to measure (output removed)"
end

# The row count each arm inherits, so scoring can tell this run's analyses from
# any the copied game already carried. `analyses` is in this list and must stay:
# a copied arm inherits the ORIGINAL game's analyses, written before anything
# was planted. Counting those as readings of the mutated record would show three
# analysts for an arm nobody has analysed yet, and every one of them would be a
# false miss.
%w[analyses analyses_rescored analyses_crossmodel].each do |kind|
  manifest["baseline_#{kind}"] = Dir.glob(File.join(out, '*')).each_with_object({}) do |d, h|
    f = File.join(d, 'records', "#{kind}.jsonl")
    h[File.basename(d)] = File.exist?(f) ? File.readlines(f).size : 0
  end
end
File.write(File.join(out, 'mutations.json'), JSON.pretty_generate(manifest))
puts "\n#{out}/mutations.json — what was planted where"
puts "next: run reanalyse.rb on every arm above, then score_detections.rb #{out}"
