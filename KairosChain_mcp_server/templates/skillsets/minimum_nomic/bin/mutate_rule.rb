#!/usr/bin/env ruby
# frozen_string_literal: true

# Rewrite the body of exactly one initial rule in a copy of a finished game.
#
# The sibling `mutate.rb` reverses a vote. This one changes what a rule SAYS.
# The difference is what the analyst has to do to catch it: a reversed vote
# contradicts the tally the players themselves kept, while a rewritten rule
# contradicts how every player subsequently behaved. The second is a wider,
# slower contradiction, and whether an analyst reaches it is the question.
#
# Only the rule set carried in `lineup.jsonl` is edited. That is the set an
# analyst is shown as "the initial rule set", so one substitution there is the
# whole mutation — the utterances, the reasonings and the turn-control record
# stay exactly as they were, still describing conduct under the ORIGINAL rule.
# The record of what players were actually handed at the time (`calls.jsonl`,
# `deliveries.jsonl`) is likewise untouched, so a reader who opens it can still
# recover the truth. That is deliberate: the mutation is a lie in one place, not
# a rewritten history.
#
# What it refuses. It will not overwrite an output directory, it aborts unless
# exactly one substitution was made, and it rejects a replacement that leaves a
# visible scar in the sentence. The scar list here is thinner than the vote one
# and catches only doubled function words and stranded prepositions; a
# replacement that is grammatical but stylistically odd will pass. Read the
# printed before/after rather than trusting the check.
#
# A control arm is written unchanged. Without it a reported contradiction cannot
# be told from a confabulated one — across 35 planted vote mutations the control
# arms produced zero false alarms, and that is what made those detections
# evidence.
#
# Usage, from the project root:
#   ruby .../bin/mutate_rule.rb GAME_DIR --out MUT_DIR [--rule 105]
#
# Then analyse both arms and compare them:
#   ruby .../bin/reanalyse.rb    MUT_DIR/clean
#   ruby .../bin/reanalyse.rb    MUT_DIR/rule_105
#   ruby .../bin/judge_change.rb --a MUT_DIR/clean --b MUT_DIR/rule_105

require 'json'
require 'fileutils'
require 'optparse'

# One substitution per rule, written out rather than generated. A generated flip
# ("swap any quantity word") cannot be checked by reading, and this file's whole
# claim is that the caller can read what was planted before believing a result.
#
# Each entry reverses the rule's operative content while keeping the sentence
# shape: the replacement occupies the same grammatical slot as what it replaces.
SUBSTITUTIONS = {
  103 => { from: 'clockwise order', to: 'counter-clockwise order' },
  105 => { from: 'the vote is unanimous among the players',
           to: 'the vote is a simple majority among the players' },
  106 => { from: 'shall begin with 201', to: 'shall begin with 301' },
  107 => { from: 'exactly one vote', to: 'exactly two votes' },
  108 => { from: 'the lowest ordinal number', to: 'the highest ordinal number' },
  109 => { from: 'the player preceding the one moving',
           to: 'the player following the one moving' }
}.freeze

# Doubled function words and stranded prepositions. This is a smaller net than
# the vote mutator's, and it is stated as such: it catches the damage these six
# substitutions could plausibly do and nothing wider.
SCARS = [
  /\b(the|a|an|of|is|are|to|in)\s+\1\b/i,
  /\bvotes\s+is\b/i,
  /\bvote\s+are\b/i,
  /\s{2,}/
].freeze

def load_lineup_lines(dir)
  path = File.join(dir, 'records', 'lineup.jsonl')
  abort "#{dir}: no lineup.jsonl" unless File.exist?(path)

  File.readlines(path).reject { |l| l.strip.empty? }
end

# Which rules the public log actually leans on. A rule nobody cited leaves no
# downstream conduct to contradict, so mutating it plants a lie with nothing to
# catch it against — the arm would be indistinguishable from the control by
# construction, and a miss would say nothing about the analyst.
def cited_rules(dir)
  path = File.join(dir, 'records', 'utterances.jsonl')
  return [] unless File.exist?(path)

  text = File.readlines(path).reject { |l| l.strip.empty? }
             .map { |l| JSON.parse(l)['text'].to_s }.join("\n")
  text.scan(/\bRules?\s+(\d{3})\b/).flatten.map(&:to_i).tally
end

options = {}
OptionParser.new do |o|
  o.banner = 'usage: mutate_rule.rb GAME_DIR --out MUT_DIR [--rule 105]'
  o.on('--out DIR', 'output directory (must not already exist)') { |v| options[:out] = v }
  o.on('--rule N', Integer, "which initial rule (#{SUBSTITUTIONS.keys.join(', ')})") { |v| options[:rule] = v }
end.parse!

game = ARGV[0] or abort 'usage: mutate_rule.rb GAME_DIR --out MUT_DIR [--rule 105]'
out  = options[:out] or abort 'usage: mutate_rule.rb GAME_DIR --out MUT_DIR [--rule 105]'
abort "#{game}: not a game directory" unless File.directory?(File.join(game, 'records'))
abort "#{out}: already exists; a mutation set is never written over" if File.exist?(out)

lines = load_lineup_lines(game)
lineup = JSON.parse(lines.first)
rules = lineup['rules_initial']
abort "#{game}: lineup carries no rules_initial; this game predates recorded rule bodies" if rules.nil?

citations = cited_rules(game)

# Default: the most-cited rule that has a substitution. Most-cited rather than
# lowest-numbered, because the amount of conduct the lie has to contradict is
# the whole point of choosing one rule over another.
target =
  if options[:rule]
    options[:rule]
  else
    SUBSTITUTIONS.keys.max_by { |id| citations.fetch(id, 0) }
  end

sub = SUBSTITUTIONS[target] or
  abort "rule #{target}: no substitution defined (have: #{SUBSTITUTIONS.keys.join(', ')})"

row = rules.find { |r| r['id'].to_i == target } or
  abort "rule #{target}: not in this game's initial set"

occurrences = row['body'].scan(sub[:from]).length
abort "rule #{target}: expected 1 occurrence of #{sub[:from].inspect}, found #{occurrences}" unless occurrences == 1

mutated_body = row['body'].sub(sub[:from], sub[:to])
scar = SCARS.find { |s| mutated_body =~ s }
abort "rule #{target}: replacement leaves a scar (#{scar.inspect}) in #{mutated_body.inspect}" if scar

FileUtils.mkdir_p(out)
FileUtils.cp_r(game, File.join(out, 'clean'))
puts "#{out}/clean — control, unchanged"

arm = File.join(out, "rule_#{target}")
FileUtils.cp_r(game, arm)

mutated_lineup = JSON.parse(lines.first)
hit = mutated_lineup['rules_initial'].find { |r| r['id'].to_i == target }
hit['body'] = mutated_body
File.write(File.join(arm, 'records', 'lineup.jsonl'),
           ([JSON.generate(mutated_lineup)] + lines[1..].map(&:strip)).join("\n") + "\n")

# Re-read what was written and check the substitution landed once and only once,
# rather than trusting the in-memory edit. A copy is cheap; a silently unmutated
# arm scored as a miss is not.
written = JSON.parse(File.readlines(File.join(arm, 'records', 'lineup.jsonl')).first)
back = written['rules_initial'].find { |r| r['id'].to_i == target }
abort "rule #{target}: written arm does not carry the mutation" unless back['body'] == mutated_body
differing = written['rules_initial'].reject.with_index { |r, i| r['body'] == rules[i]['body'] }
abort "rule #{target}: #{differing.length} rule bodies differ, expected 1" unless differing.length == 1

manifest = {
  'game' => File.expand_path(game),
  'kind' => 'rule_body',
  'arms' => [{ 'dir' => "rule_#{target}", 'rule' => target,
               'from' => sub[:from], 'to' => sub[:to],
               'citations_in_public_log' => citations.fetch(target, 0),
               'body_before' => row['body'], 'body_after' => mutated_body }],
  'citations' => citations
}
%w[analyses analyses_rescored analyses_crossmodel].each do |kind|
  manifest["baseline_#{kind}"] = Dir.glob(File.join(out, '*')).each_with_object({}) do |d, h|
    next unless File.directory?(d)

    f = File.join(d, 'records', "#{kind}.jsonl")
    h[File.basename(d)] = File.exist?(f) ? File.readlines(f).size : 0
  end
end
File.write(File.join(out, 'mutations.json'), JSON.pretty_generate(manifest))

puts "#{arm} — Rule #{target}, cited #{citations.fetch(target, 0)}x in the public log"
puts "  before: #{row['body']}"
puts "  after : #{mutated_body}"
puts "\n#{out}/mutations.json — what was planted where"
puts "next: reanalyse.rb both arms, then judge_change.rb --a #{out}/clean --b #{arm}"
