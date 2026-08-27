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
#   ruby test/mutation_check_readable_gate.rb           # full sweep
#   ruby test/mutation_check_readable_gate.rb 'B\\d+'    # rows whose label matches
#
# A label filter narrows the sweep to the rows named; the summary line then
# says FILTERED so a narrowed run can never be mistaken for a full one. The
# per-mutation suite run stops at the first file with a red — the question
# per row is binary — and the hook's own test file runs first, which is where
# a readable_gate mutation reds if it reds at all.
#
require 'fileutils'
require 'tmpdir'
require 'open3'
require 'rbconfig'

SKILLSET_ROOT = File.dirname(__dir__)

MUTATIONS = [
  ['M3  the recheck does not wait',
   %q{      attempts = rechecked ? RECHECK_POLL_ATTEMPTS : POLL_ATTEMPTS},
   %q{      attempts = rechecked ? 1 : POLL_ATTEMPTS}],
  ['M6  the rec= column is dropped from the log',
   %q{      detail += "\trec=#{record_id[0, 8]}" if record_id.is_a?(String) && !record_id.empty?},
   %q{      detail += ''}],
  ['M7  the recheck blocks as well as the first read',
   %q{      if !failures.empty? && !rechecked && cfg.blocking},
   %q{      if !failures.empty? && cfg.blocking}],

  # --- which record is the marker, and how long it is waited for ------------
  ['M9  the recheck budget is cut from 40 attempts to 15',
   %q{    RECHECK_POLL_ATTEMPTS = 40},
   %q{    RECHECK_POLL_ATTEMPTS = 15}],
  ['M10 rec= logs the whole uuid instead of the first 8 characters',
   %q{      detail += "\trec=#{record_id[0, 8]}" if record_id.is_a?(String) && !record_id.empty?},
   %q{      detail += "\trec=#{record_id}" if record_id.is_a?(String) && !record_id.empty?}],
  # M11 and M12 were here. Round 5 merged turn_marker's predicate with
  # any_marker?'s into one method, so M34 and M35 now cover both call sites
  # where these covered one. Retired rather than duplicated.

  # --- the shape settled on 2026-08-21 after two review rounds ---------------
  ['M16 the no-verdict banner is not emitted at all',
   %q{        emit('systemMessage' => "#{cfg.banner_prefix} (recheck): NOT RUN — #{reason}#{tail}") if rechecked},
   %q{        nil}],
  ['M17 the banner quotes a fixed number instead of the budget it spent',
   %q{        budget = format('%.1f', RECHECK_POLL_ATTEMPTS * POLL_DELAY)},
   %q{        budget = '1.5'}],
  ['M27 HOOK_TIMEOUT drifts from the limit the compiler declares',
   %q{    HOOK_TIMEOUT = 10.0},
   %q{    HOOK_TIMEOUT = 20.0}],
  # M28 and M30 were the margin mutations against the old constant (1.0). The
  # 2026-08-27 bound redesign moved the margin to 0.5 and pinned it by
  # equality, and B14/B15 below carry both directions against the new value.
  # Retired rather than retargeted: keeping two rows per direction would
  # double-count one anchor.

  # --- round 3: the instrument the design reads its own evidence through -----
  ['M22 the waited token stops telling a wait from no wait',
   %q{        waited = attempt.zero? ? 'ok' : 'ok-after-wait'},
   %q{        waited = 'ok-after-wait'}],
  ['M26 the unreadable exit spends the whole budget instead of returning at once',
   %q{        rows = tail_records(transcript_path)
        return [nil, 'unreadable', nil] if rows.nil?},
   %q{        rows = tail_records(transcript_path)
        if rows.nil?
          sleep(POLL_DELAY)
          next
        end}],
  ['M31 the recheck budget grows instead of shrinking',
   %q{    RECHECK_POLL_ATTEMPTS = 40},
   %q{    RECHECK_POLL_ATTEMPTS = 95}],
  ['M32 the first read waits a third as long',
   %q{    POLL_ATTEMPTS = 15},
   %q{    POLL_ATTEMPTS = 5}],
  ['M39 the log swaps the headings and tables columns',
   %q{          "\tlines=%d\theadings=%d\ttables=%d\tdiagrams=%d\tunglossed=%s",
          metrics['lines'], metrics['headings'], metrics['tables'], metrics['diagrams'],},
   %q{          "\tlines=%d\theadings=%d\ttables=%d\tdiagrams=%d\tunglossed=%s",
          metrics['lines'], metrics['tables'], metrics['headings'], metrics['diagrams'],}],
  ['M42 the unreadable exit polls before giving up',
   %q{        rows = tail_records(transcript_path)
        return [nil, 'unreadable', nil] if rows.nil?},
   %q{        rows = tail_records(transcript_path)
        if rows.nil?
          sleep(POLL_DELAY * 15)
          return [nil, 'unreadable', nil]
        end}],
  ['M43 the whitespace guard is deleted',
   %q{      if text.nil? || text.strip.empty?},
   %q{      if text.nil?}],

  # --- round 5's own seam: the clock is wired through main, and the wiring is
  # what a helper's unit fixtures do not reach. A reviewer invented 20 of these
  # against the round-5 tree and 14 survived; 8 were in this seam alone.
  # M44 through M50 were the clock seam and are gone with it, for the reason
  # given at M19 above. M44 and M45 are the two the round-5 review named as
  # half-witnessed — the fixture drove the first read only — and that debt is
  # carried into the bound's own design rather than left here as a mutation with
  # no code to mutate.
  ['M52 stop_hook_active is read as a strict boolean',
   %q{      rechecked = payload['stop_hook_active'] ? true : false},
   %q{      rechecked = payload['stop_hook_active'] == true}],
  ['M55 the operator-facing block reason stops reading the constant',
   %q{          "#{own_block_reason(cfg)}" \\},
   %q{          "Your last message violates: #{cfg.mode_name}" \\}],
  # M57 was "the block reason carries the unscrubbed mode name". It survived the
  # 2026-08-26 run, and the reason was not a gap in the suite: emit scrubs every
  # string in the payload on the way out, so scrubbing again inside the block
  # reason changed nothing that could be observed. The redundant scrub was
  # deleted rather than pinned. What is left to pin is emit's own scrub, which
  # is now the only one on that path.
  ['M57 emit stops scrubbing on the way out',
   %q{      puts JSON.generate(payload.transform_values { |v| v.is_a?(String) ? v.scrub : v })},
   %q{      puts JSON.generate(payload)}],
  ['M40 the first read borrows the recheck\'s give-up name',
   %q{      return [nil, 'race-timeout', nil] unless rechecked},
   %q{      return [nil, 'awaiting-rewrite', nil] unless rechecked}],
  ['M41 the first read borrows a recheck-only give-up name',
   %q{          return [nil, 'no-assistant-record', nil] if newest.nil?},
   %q{          return [nil, 'blocked-record-gone', nil] if newest.nil?}],

  # --- the carry-over note: what the recheck starts from ---------------------
  #
  # Replaces the twenty-five mutations that aimed at the marker walk. Their
  # anchors went with it on 2026-08-26; a mutation whose anchor is not in the
  # source is not a passing mutation, it is an absent one, and the harness
  # reports it as ANCHOR NOT FOUND rather than counting it killed.
  ['N1  the recheck ignores the note and takes the newest record',
   %q{          index = index_of_uuid(rows, blocked_uuid)},
   %q{          index = -1}],
  ['N2  the walk starts at the blocked record instead of after it',
   %q{      i = rows.length - 1
      while i > index
        row = rows[i]
        return [text_of(row), row['uuid']] if row.is_a?(Hash) && row['type'] == 'assistant'},
   %q{      i = rows.length - 1
      while i >= index
        row = rows[i]
        return [text_of(row), row['uuid']] if row.is_a?(Hash) && row['type'] == 'assistant'}],
  # --- what round 1 of the conformance review found --------------------------
  #
  # N26 is the one a whole 47-mutation run and ten unusable-note fixtures walked
  # past: every one of them used a note that could be deleted. The reviewer that
  # found it did so by reading the code, not by running the suite.
  ['N26 a note that cannot be deleted is used anyway',
   %q{      begin
        File.unlink(path)
      rescue StandardError
        return [nil, 'nonote-unspent']
      end},
   %q{      begin
        File.unlink(path)
      rescue StandardError
        nil
      end}],
  ['N27 the note key is the caller\'s spelling rather than the absolute path',
   %q{      File.expand_path(transcript_path.to_s)},
   %q{      transcript_path.to_s}],
  ['N28 the stale banner asserts age for a note stamped in the future',
   %q{            "this gate's record of what it blocked is not from this turn: it is either more " \\},
   %q{            "this gate's record of what it blocked is more than " \\}],
  # Retargeted after round 1. It used to mutate the rescue arm, which is now
  # N26's job; this one deletes the attempt itself, so the two are distinct:
  # N3 never tries, N26 tries and ignores the failure.
  ['N3  the note is read and no delete is even attempted',
   %q{        File.unlink(path)},
   %q{        path},
   ],
  ['N4  the staleness bound is not applied at all',
   %q{      return [nil, 'nonote-stale'] unless age >= -1.0 && age <= NOTE_TTL_SECONDS},
   %q{      return [nil, 'nonote-stale'] unless age >= -1.0 || age <= NOTE_TTL_SECONDS}],
  ['N5  a note stamped in the future is accepted',
   %q{      return [nil, 'nonote-stale'] unless age >= -1.0 && age <= NOTE_TTL_SECONDS},
   %q{      return [nil, 'nonote-stale'] unless age <= NOTE_TTL_SECONDS}],
  ['N6  the note lifetime grows by an order of magnitude',
   %q{    NOTE_TTL_SECONDS = 300.0},
   %q{    NOTE_TTL_SECONDS = 3000.0}],
  ['N7  the note is not checked against the transcript it names',
   %q{      return [nil, 'nonote-mismatch'] unless data['transcript'] == note_key_path(transcript_path).scrub},
   %q{      return [nil, 'nonote-mismatch'] if false}],
  ['N8  the note is not checked against the mode that wrote it',
   %q{      return [nil, 'nonote-mismatch'] unless data['mode'] == cfg.mode_name.to_s.scrub},
   %q{      return [nil, 'nonote-mismatch'] if false}],
  ['N9  an empty blocked_uuid is accepted',
   %q{      return [nil, 'nonote-mismatch'] unless uuid.is_a?(String) && !uuid.empty?},
   %q{      return [nil, 'nonote-mismatch'] unless uuid.is_a?(String)}],
  ['N10 a note whose stamp is not a number is accepted',
   %q{      return [nil, 'nonote-mismatch'] unless at.is_a?(Numeric)},
   %q{      at = 0.0 unless at.is_a?(Numeric)}],
  ['N11 a note that cannot be parsed is treated as usable',
   %q{      data = begin
        JSON.parse(raw)
      rescue StandardError
        return [nil, 'nonote-mismatch']
      end},
   %q{      data = begin
        JSON.parse(raw)
      rescue StandardError
        { 'transcript' => transcript_path.to_s.scrub, 'mode' => cfg.mode_name.to_s.scrub,
          'blocked_uuid' => 'AAA', 'at' => Time.now.to_f }
      end}],
  ['N12 the note file name is built from the mode name instead of a digest',
   %q{      key = Digest::SHA256.hexdigest("#{note_key_path(transcript_path)}\0#{cfg.mode_name}")[0, 32]},
   %q{      key = "#{File.basename(transcript_path)}-#{cfg.mode_name}"}],
  ['N13 the note file name drops the transcript, so all sessions share one',
   %q{      key = Digest::SHA256.hexdigest("#{note_key_path(transcript_path)}\0#{cfg.mode_name}")[0, 32]},
   %q{      key = Digest::SHA256.hexdigest(cfg.mode_name.to_s)[0, 32]}],
  ['N14 the note file name drops the mode, so two modes share one',
   %q{      key = Digest::SHA256.hexdigest("#{note_key_path(transcript_path)}\0#{cfg.mode_name}")[0, 32]},
   %q{      key = Digest::SHA256.hexdigest(transcript_path.to_s)[0, 32]}],
  ['N15 the writer stops scrubbing the mode name the reader scrubs',
   %q{          'mode' => cfg.mode_name.to_s.scrub,},
   %q{          'mode' => cfg.mode_name.to_s,}],
  ['N16 a failed note write is silent',
   %q{        note(cfg, "NOTE-WRITE-FAILED: #{failure}") if failure},
   %q{        note(cfg, "NOTE-WRITE-FAILED: #{failure}") if false}],
  ['N17 a failed note write stops the block',
   %q{        failure = write_note(payload.fetch('transcript_path', ''), cfg, record_id)
        note(cfg, "NOTE-WRITE-FAILED: #{failure}") if failure},
   %q{        failure = write_note(payload.fetch('transcript_path', ''), cfg, record_id)
        if failure
          note(cfg, "NOTE-WRITE-FAILED: #{failure}")
          out.delete('decision')
        end}],
  # Retargeted after round 2: the no-uuid return now spends the leftover first,
  # so the anchor moved with it. The mutation is unchanged in spirit.
  ['N18 write_note records a uuid it was not given',
   %q{      return spend_stale_note(path, 'no uuid to record') if uuid.nil? || uuid.to_s.empty?},
   %q{      uuid = 'unknown' if uuid.nil? || uuid.to_s.empty?}],
  ['N19 the note is written whole rather than renamed into place',
   %q{      File.rename(tmp, path)},
   %q{      FileUtils.cp(tmp, path)}],
  ['N20 the blocked record being outside the window spends the whole budget',
   %q{          return [nil, 'blocked-record-gone', nil] if index.nil?},
   %q{          if index.nil?
            sleep(POLL_DELAY)
            next
          end}],
  ['N21 the give-up for a missing blocked record borrows the wait name',
   %q{          return [nil, 'blocked-record-gone', nil] if index.nil?},
   %q{          return [nil, 'awaiting-rewrite', nil] if index.nil?}],
  ['N22 the last resort walks oldest-first',
   %q{    def deep_after_index(rows, index)
      i = rows.length - 1
      while i > index},
   %q{    def deep_after_index(rows, index)
      i = index + 1
      while i < rows.length}],
  ['N23 the last resort never finds the rewrite it is the last resort for',
   %q{          return [text, row['uuid']] if text},
   %q{          return [text, row['uuid']] if text && false}],
  ['N24 the wait is pre-empted: a text-less rewrite is stepped over at once',
   %q{        return [text_of(row), row['uuid']] if row.is_a?(Hash) && row['type'] == 'assistant'},
   %q{        if row.is_a?(Hash) && row['type'] == 'assistant' && text_of(row)
          return [text_of(row), row['uuid']]
        end}],
  ['N25 the note is taken again on every poll instead of once',
   %q{      blocked_uuid = nil
      if rechecked
        blocked_uuid, why_not = take_note(transcript_path, cfg)},
   %q{      blocked_uuid = nil
      if rechecked
        blocked_uuid, why_not = take_note(transcript_path, cfg)
        blocked_uuid, why_not = take_note(transcript_path, cfg) if blocked_uuid},
   ],

  # --- what round 2 of the conformance review found --------------------------
  #
  # A leftover note from an interrupted turn is valid on its face, so a block
  # whose own note write fails must spend it — otherwise the recheck reads the
  # leftover and judges the message this turn just blocked. One seat of six
  # found it, by composing two declared behaviours (the 11.7% unconsumed-note
  # population and the no-uuid write failure) that every fixture had exercised
  # only in isolation.
  ['N29 the spend is a no-op that still reports success',
   %q{    def spend_stale_note(path, reason)
      File.unlink(path)},
   %q{    def spend_stale_note(path, reason)
      return reason if path
      File.unlink(path)}],
  ['N30 the no-uuid failure path stops spending the leftover',
   %q{      return spend_stale_note(path, 'no uuid to record') if uuid.nil? || uuid.to_s.empty?},
   %q{      return 'no uuid to record' if uuid.nil? || uuid.to_s.empty?}],
  ['N31 the write\'s exception path stops spending the leftover',
   %q{        spend_stale_note(path, "#{e.class}: #{e.message}")},
   %q{        "#{e.class}: #{e.message}"}],

  # --- what round 3 of the conformance review found --------------------------
  #
  # Unspendability is not stable: a directory that refuses the unlink at block
  # time and permits it again before the recheck let the recheck spend the
  # leftover this block had failed to delete. Three of five verifying contexts
  # reached the same window independently. The truncation fallback is what
  # closes it; this deletes the fallback and the window reopens.
  ['N32 the truncation fallback is deleted, so a lifted window revives the leftover',
   %q{    rescue StandardError
      begin
        File.open(path, File::WRONLY | File::TRUNC | File::NOFOLLOW).close
        "#{reason}; a stale note could not be deleted and was emptied instead"
      rescue StandardError => e
        "#{reason}; a stale note could not be deleted (#{e.class})"
      end
    end},
   %q{    rescue StandardError => e
      "#{reason}; a stale note could not be deleted (#{e.class})"
    end}],

  # --- what round 4 of the conformance review found --------------------------
  #
  # The truncation is a write through a name in operator space. Two seats
  # planted a symlink at the note key, made the directory unwritable so the
  # unlink fails, and watched the old File.write empty a file outside the notes
  # directory. This restores that write; the fix's NOFOLLOW is what it deletes.
  ['N33 the truncation follows a symlink to whatever it names',
   %q{        File.open(path, File::WRONLY | File::TRUNC | File::NOFOLLOW).close},
   %q{        File.write(path, '')}],

  # --- the measurement bound: the seam and its witnesses (design v0.7 §5-12) --
  #
  # Every mutation here is paired with the fixture the design names as its
  # killer; the pairing is the §5-12 table, and anchor verification before a
  # sweep is what keeps it honest. Mutations that unbound a runaway make the
  # affected fixtures run to run_script's 30s outer kill, so those rows cost
  # minutes each in a sweep — declared, not accidental.
  ['B1  the floor predicate is loosened to <= 0',
   %q{      raise MeasureTimeout if remaining < MIN_TIMEOUT},
   %q{      raise MeasureTimeout if remaining <= 0}],
  ['B2  the raise (floor included) is deleted',
   %q{      raise MeasureTimeout if remaining < MIN_TIMEOUT},
   %q{      # raise deleted}],
  ['B3  the floor constant is lowered into the silent-nil window',
   %q{    MIN_TIMEOUT = 0.001},
   %q{    MIN_TIMEOUT = 1.0e-12}],
  ['B4  the floor constant is raised, quietly shrinking every budget',
   %q{    MIN_TIMEOUT = 0.001},
   %q{    MIN_TIMEOUT = 1.0}],
  ['B5  the grant is never armed',
   %q{      Regexp.timeout = remaining
      begin},
   %q{      begin}],
  ['B6  the TimeoutError-to-MeasureTimeout mapping is deleted',
   %q{      rescue Regexp::TimeoutError
        raise MeasureTimeout},
   %q{      rescue Regexp::TimeoutError
        raise}],
  ['B7  the clock read is dropped from the remaining computation',
   %q{      remaining = deadline - monotonic},
   %q{      remaining = deadline}],
  ['B8  each_match reverts to matching before the seam checks',
   %q{      while pos <= string.length && (m = bounded_match(regexp, string, pos, deadline))
        yield m},
   %q{      while pos <= string.length && (m = regexp.match(string, pos))
        raise MeasureTimeout if deadline && monotonic > deadline
        yield m}],
  ['B19 the seam inlines the clock, putting it beyond the floor fixture stub',
   %q{      remaining = deadline - monotonic},
   %q{      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)}],
  # Five bypass targets, three dedicated rows: specimen and shorthand have no
  # independent seam call site — both reach bounded_match only through
  # each_match's single call — so their bypass IS the each_match reversion,
  # which is B8. B10-B12 carry the three families with call sites of their own.
  ['B9  the announce call drops its deadline argument',
   %q{      announced = !(cfg.announce && bounded_match(cfg.announce, first, 0, deadline)).nil?},
   %q{      announced = !(cfg.announce && bounded_match(cfg.announce, first, 0, nil)).nil?}],
  ['B10 the announce match bypasses the seam entirely',
   %q{      announced = !(cfg.announce && bounded_match(cfg.announce, first, 0, deadline)).nil?},
   %q{      announced = !(cfg.announce && cfg.announce.match(first)).nil?}],
  ['B11 the gloss after-operand bypasses the seam',
   %q{              if cfg.gloss && !(bounded_match(cfg.gloss, after, 0, deadline) ||
                                bounded_match(cfg.gloss, nxt, 0, deadline))},
   %q{              if cfg.gloss && !(cfg.gloss.match(after) ||
                                bounded_match(cfg.gloss, nxt, 0, deadline))}],
  ['B12 the gloss nxt-operand bypasses the seam behind the short-circuit',
   %q{              if cfg.gloss && !(bounded_match(cfg.gloss, after, 0, deadline) ||
                                bounded_match(cfg.gloss, nxt, 0, deadline))},
   %q{              if cfg.gloss && !(bounded_match(cfg.gloss, after, 0, deadline) ||
                                cfg.gloss.match(nxt))}],
  ['B13 the deadline is recomputed at the measurement call instead of main head',
   %q{        metrics, failures = measure_bounded(text, cfg, deadline)},
   %q{        metrics, failures = measure_bounded(text, cfg, deadline_for(monotonic))}],
  ['B14 the margin collapses to zero',
   %q{    HOOK_TIMEOUT_MARGIN = 0.5},
   %q{    HOOK_TIMEOUT_MARGIN = 0.0}],
  ['B15 the margin swallows half the budget',
   %q{    HOOK_TIMEOUT_MARGIN = 0.5},
   %q{    HOOK_TIMEOUT_MARGIN = 5.0}],
  ['B16 the report path loses the nil-deadline passthrough',
   %q{      return regexp.match(string, pos) if deadline.nil?

      remaining = deadline - monotonic},
   %q{      remaining = deadline - monotonic}],
  ['B17 the revocation is deleted, so a grant outlives its match',
   %q{      Regexp.timeout = remaining
      begin
        regexp.match(string, pos)
      ensure
        Regexp.timeout = nil
      end},
   %q{      Regexp.timeout = remaining
      regexp.match(string, pos)}],
  ['B18 the revocation is demoted to a trailing statement, leaking on the cut exit',
   %q{      Regexp.timeout = remaining
      begin
        regexp.match(string, pos)
      ensure
        Regexp.timeout = nil
      end},
   %q{      Regexp.timeout = remaining
      m = regexp.match(string, pos)
      Regexp.timeout = nil
      m}],
].freeze

def run_suite(root, early_exit: true)
  files = Dir[File.join(root, 'test', 'test_*.rb')].sort
  # The hook's own suite first: a readable_gate mutation reds there if it reds
  # at all, and the early exit below then skips the unrelated files.
  files = files.partition { |f| File.basename(f) == 'test_readable_gate.rb' }.flatten
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
    break if early_exit && bad.positive?
  end
  [runs, bad, unparseable, files.length]
end

exit_code = 0
label_filter = ARGV[0] && Regexp.new(ARGV[0])
selected = label_filter ? MUTATIONS.select { |l, _, _| l.match?(label_filter) } : MUTATIONS
if label_filter
  puts format('FILTERED sweep: %d of %d rows match %s — NOT a full sweep',
              selected.length, MUTATIONS.length, label_filter.inspect)
end

Dir.mktmpdir do |tmp|
  root = File.join(tmp, File.basename(SKILLSET_ROOT))
  FileUtils.cp_r(SKILLSET_ROOT, root)
  hook = File.join(root, 'hooks', 'readable_gate.rb')
  pristine = File.read(hook)

  runs, bad, unparseable, nfiles = run_suite(root, early_exit: false)
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
  selected.each do |label, from, to|
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
  scope = label_filter ? "FILTERED #{selected.length} of #{MUTATIONS.length}" : MUTATIONS.length.to_s
  puts "killed #{killed}/#{scope}, survived #{survived}, anchor-not-found #{not_applied}"
  exit_code = 1 if survived.positive? || not_applied.positive?
end

exit exit_code
