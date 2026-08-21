#!/usr/bin/env ruby
# Mutation check for readable_gate.
#
# A green suite proves nothing until something has tried to break the code and
# the suite noticed. Each entry below rewrites one line of the hook and asserts
# that at least one test goes red. A SURVIVED row means the behaviour it names
# is not witnessed by any test, however many assertions surround it.
#
# Why this file lives in the SkillSet rather than beside a review record: the
# first round of this check was written to a scratch directory and was gone by
# the time anyone tried to reproduce it, so the evidence for "the falsification
# is real" could not be re-derived. The generator is the artifact worth keeping;
# its output is reproducible from it.
#
# Runs against a COPY of the whole SkillSet in a temp directory. The repository
# copy may be a live Stop hook, and must never be left mutated even briefly.
# The harness is this SkillSet's own suite, unmodified: `SCRIPT` in the test
# files resolves from `__dir__`, so the copied tests drive the copied hook.
#
#   ruby test/mutation_check_readable_gate.rb
#
require 'fileutils'
require 'tmpdir'
require 'open3'
require 'rbconfig'

SKILLSET_ROOT = File.dirname(__dir__)

MUTATIONS = [
  # --- the recheck's target: what it measures the second time ----------------
  ['M1  recheck ignores the marker and takes the newest record',
   %q{          marker = turn_marker(rows)},
   %q{          marker = nil}],
  ['M2  the already-judged record is not excluded (inside the budget)',
   %q{        return [text_of(row), row['uuid']] if row['type'] == 'assistant' && !judged?(row, judged)},
   %q{        return [text_of(row), row['uuid']] if row['type'] == 'assistant'}],
  ['M3  the recheck does not wait',
   %q{      attempts = rechecked ? RECHECK_POLL_ATTEMPTS : POLL_ATTEMPTS},
   %q{      attempts = rechecked ? 1 : POLL_ATTEMPTS}],
  ['M4  the no-marker exit claims there is no assistant record at all',
   %q{      newest_assistant(rows) ? [nil, 'nomarker', nil] : [nil, 'no-assistant-record-nomarker', nil]},
   %q{      [nil, 'no-assistant-record-nomarker', nil]}],
  ['M5  the -nomarker suffix is dropped',
   %q{      newest_assistant(rows) ? [nil, 'nomarker', nil] : [nil, 'no-assistant-record-nomarker', nil]},
   %q{      newest_assistant(rows) ? [nil, 'awaiting-rewrite', nil] : [nil, 'no-assistant-record', nil]}],
  ['M6  the rec= column is dropped from the log',
   %q{      detail += "\trec=#{record_id[0, 8]}" if record_id.is_a?(String) && !record_id.empty?},
   %q{      detail += ''}],
  ['M7  the recheck blocks as well as the first read',
   %q{      if !failures.empty? && !rechecked && cfg.blocking},
   %q{      if !failures.empty? && cfg.blocking}],

  # --- which record is the marker, and how long it is waited for ------------
  ['M8  an earlier turn\'s marker is accepted as this turn\'s',
   %q{          return text.start_with?(BLOCK_MARKER) ? i : nil if text.is_a?(String)},
   %q{          return i if text.is_a?(String) && text.start_with?(BLOCK_MARKER)}],
  ['M9  the recheck budget is cut from 40 attempts to 15',
   %q{    RECHECK_POLL_ATTEMPTS = 40},
   %q{    RECHECK_POLL_ATTEMPTS = 15}],
  ['M10 rec= logs the whole uuid instead of the first 8 characters',
   %q{      detail += "\trec=#{record_id[0, 8]}" if record_id.is_a?(String) && !record_id.empty?},
   %q{      detail += "\trec=#{record_id}" if record_id.is_a?(String) && !record_id.empty?}],
  ['M11 any record type may be a marker, not only user',
   "        if row['type'] == 'user'\n          text = text_of(row)",
   "        if row['type']\n          text = text_of(row)"],
  ['M12 a record that merely mentions the wording counts as a marker',
   %q{          return text.start_with?(BLOCK_MARKER) ? i : nil if text.is_a?(String)},
   %q{          return text.include?(BLOCK_MARKER) ? i : nil if text.is_a?(String)}],

  # --- the shape settled on 2026-08-21 after two review rounds ---------------
  ['M13 no marker means judge the newest record anyway',
   %q{      newest_assistant(rows) ? [nil, 'nomarker', nil] : [nil, 'no-assistant-record-nomarker', nil]},
   "      n = newest_assistant(rows)\n" \
   "      return [nil, 'no-assistant-record-nomarker', nil] if n.nil?\n" \
   "      n[0] ? [n[0], 'ok-after-wait-nomarker', n[1]] : [nil, 'nomarker', nil]"],
  ['M14 the deep walk pre-empts the wait instead of outliving it',
   %q{        return [text_of(row), row['uuid']] if row['type'] == 'assistant' && !judged?(row, judged)},
   "        if row['type'] == 'assistant' && !judged?(row, judged)\n" \
   "          t = text_of(row)\n" \
   "          return [t, row['uuid']] if t\n" \
   "        end"],
  ['M15 the nil-judged guard reverted to a plain inequality',
   %q{      judged && row['uuid'] == judged},
   %q{      row['uuid'] == judged}],

  # --- what round 2 found no mutation could reach ---------------------------
  ['M16 the no-verdict banner is not emitted at all',
   %q{        emit('systemMessage' => "#{cfg.banner_prefix} (recheck): NOT RUN — #{reason}#{tail}") if rechecked},
   %q{        nil}],
  ['M17 the banner quotes a fixed number instead of the budget it spent',
   %q{        budget = format('%.1f', RECHECK_POLL_ATTEMPTS * POLL_DELAY)},
   %q{        budget = '1.5'}],
  ['M18 the deep walk never finds the rewrite it is the last resort for',
   "    def deep_after(rows, index, judged)\n      i = rows.length - 1",
   "    def deep_after(rows, index, judged)\n      return nil\n      i = rows.length - 1"],
  ['M19 a mode may ask for more measurement time than the hook has left',
   %q{          if requested.is_a?(Numeric) && requested > MEASURE_TIMEOUT_CEILING},
   %q{          if false}]
].freeze

def run_suite(root)
  files = Dir[File.join(root, 'test', 'test_*.rb')].sort
  runs = 0
  bad = 0
  unparseable = []
  files.each do |f|
    out, err, st = Open3.capture3(RbConfig.ruby, f)
    tail = "#{out}\n#{err}"
    if (m = tail.match(/(\d+) runs, \d+ assertions, (\d+) failures, (\d+) errors/))
      runs += m[1].to_i
      bad += m[2].to_i + m[3].to_i
    else
      unparseable << File.basename(f)
      bad += 1 unless st.success?
    end
  end
  [runs, bad, unparseable, files.length]
end

exit_code = 0

Dir.mktmpdir do |tmp|
  root = File.join(tmp, File.basename(SKILLSET_ROOT))
  FileUtils.cp_r(SKILLSET_ROOT, root)
  hook = File.join(root, 'hooks', 'readable_gate.rb')
  pristine = File.read(hook)

  runs, bad, unparseable, nfiles = run_suite(root)
  puts format('BASELINE (unmutated copy): %d test files, %d runs, %d failures+errors%s',
              nfiles, runs, bad, unparseable.empty? ? '' : " [unparseable: #{unparseable.join(', ')}]")
  puts
  if bad.positive?
    puts 'The suite is not green before mutation; every result below is meaningless.'
    exit_code = 1
  end

  killed = 0
  survived = 0
  not_applied = 0
  MUTATIONS.each do |label, from, to|
    unless pristine.include?(from)
      not_applied += 1
      puts format('%-70s  ANCHOR NOT FOUND', label)
      next
    end
    mutated = pristine.sub(from, to)
    raise "mutation #{label} was a no-op" if mutated == pristine

    File.write(hook, mutated)
    r, b, u, = run_suite(root)
    File.write(hook, pristine)
    if b.positive?
      killed += 1
      verdict = 'KILLED'
    else
      survived += 1
      verdict = 'SURVIVED'
    end
    puts format('%-70s  %-9s %3d failures/errors over %d runs%s',
                label, verdict, b, r, u.empty? ? '' : " [unparseable: #{u.join(', ')}]")
  end

  puts
  puts "source restored byte-identical: #{File.read(hook) == pristine}"
  puts "killed #{killed}/#{MUTATIONS.length}, survived #{survived}, anchor-not-found #{not_applied}"
  exit_code = 1 if survived.positive? || not_applied.positive?
end

exit exit_code
