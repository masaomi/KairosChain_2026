#!/usr/bin/env ruby
# frozen_string_literal: true

# Generic readable-output gate. Ships with KairosChain; carries no mode content.
#
# Every threshold, pattern, and message is supplied by a config file written by
# the instruction mode. This file is the machinery; the mode is the content. The
# core enforces that a declared norm is checkable, never what the norm says.
#
# Usage (as a Claude Code Stop hook):
#     readable_gate.rb --config <path/to/gate_config.json>
#     stdin  : Stop-hook JSON {transcript_path, stop_hook_active, ...}
#     stdout : {"systemMessage": ...} and, on first failure, decision=block
#     exit   : always 0 — a gate fault must never wedge a session
#
# Offline calibration:
#     readable_gate.rb --config <cfg> --report <transcript.jsonl>...
#
# Ruby, not Python, since 2026-08-12. KairosChain is a Ruby harness and this is
# the only part of it that was not. The port removed two things rather than
# reproducing them: the SIGALRM alarm that bounded measurement, which was
# Unix-only and is now Regexp.timeout, and the interpreter-discovery shim, which
# existed only to find a python3.

require 'digest'
require 'fileutils'
require 'json'

module KairosHookProjector
  module ReadableGate
    TAIL_BYTES = 512 * 1024
    POLL_ATTEMPTS = 15
    POLL_DELAY = 0.1
    # The recheck waits longer than the first read, because it is waiting for a
    # whole rewrite rather than for the tail of a record already being written.
    # Bounded well under the hook's own timeout; the turn it lengthens is one
    # that already spent a full regeneration.
    RECHECK_POLL_ATTEMPTS = 40
    # This gate's own block reason opens with this, followed by the mode's name.
    # Operator-facing text only. Until 2026-08-26 it was also the recheck's
    # evidence: the gate read it back out of the transcript to tell its own
    # block from another Stop hook's, because Claude Code prefaces every
    # blocking Stop hook with one shared string. That mechanism is gone — the
    # gate now records what it blocked instead of inferring it — so changing
    # this wording no longer costs a single verdict.
    OWN_BLOCK_REASON = 'Your last message violates '
    # Where the carry-over note lives: a directory beside the log, so the
    # operator controls its location through log_path and no second config key
    # exists to disagree with the first. A mode that declares no log declares no
    # note either, and so has no recheck verdicts — the same trade the log
    # already makes.
    NOTE_DIR_NAME = 'readable_gate_notes'
    # How long a note may sit unclaimed before the recheck refuses it. Measured
    # over this instance's live log, 2026-08-26: of 240 blocks, 212 drew a
    # recheck at a median of 17.0s, a 99th percentile of 43.0s and a maximum of
    # 109.0s. This is about 2.75x that maximum. The other 28 (11.7%) drew no
    # recheck at all — interrupted turns — and are exactly what this bound and
    # the consume-on-read in take_note are for.
    NOTE_TTL_SECONDS = 300.0
    # Claude Code's limit on how long a Stop hook may run, declared twice
    # outside this file: in `.claude/settings.json` and in this SkillSet's
    # `lib/mode_hooks_compiler.rb`. Named here because this file spends two
    # budgets in sequence and neither knows about the other. A hook killed at
    # the limit emits nothing at all — no verdict, no banner, no log line — so
    # the gate stops enforcing and the measurement loses rows, both silently.
    HOOK_TIMEOUT = 10.0
    # Held back from the pair for interpreter start-up and for the poll's own
    # overhead. Measured 2026-08-22 on Ruby 3.4.10: 0.030s for the first read's
    # 15 tail reads, 0.075s for the recheck's 40 plus turn_marker, and roughly
    # 0.3s more for interpreter start-up. An earlier version of this line said
    # 0.2-0.6s for the poll alone, which the shipped code cannot reproduce.
    #
    # Round 5 measured start-up itself at a median 0.033s through the projected
    # `sh -c ruby …` form, so 1.0 is about thirty times what it holds back. Left
    # as it stands: the value is the measurement bound's, and the bound is no
    # longer part of this design. See docs/drafts on the bound.
    HOOK_TIMEOUT_MARGIN = 1.0
    # What is left for measurement once the recheck has spent its budget. A mode
    # asking for more than this is honoured up to here and no further: the
    # alternative is a mode file being able to silence the gate by arithmetic.
    #
    # A constant, and wrong in a way that is known and recorded: it charges a
    # first read for the four seconds only a recheck spends. Rounds 4 and 5
    # replaced it twice — one ceiling per read, then a clock read at the top of
    # main — and round 5's review falsified both, the second because a bound
    # applied per match bounds the number this file quotes and not the time it
    # spends. The bound is therefore carved out of this design and carried in
    # its own, and this line is back to the shape shipped since 6d7fe02.
    MEASURE_TIMEOUT_CEILING =
      HOOK_TIMEOUT - HOOK_TIMEOUT_MARGIN - (RECHECK_POLL_ATTEMPTS * POLL_DELAY)

    # Built from single-quoted strings so that `#{` in a pattern stays literal
    # rather than becoming interpolation, and anchored with \A because Python's
    # re.match anchored at position 0 and Ruby's match does not.
    FENCE = Regexp.new('\A\s*```')
    HEADING = Regexp.new('\A#{1,6}\s+\S')
    TABLE_SEP = Regexp.new('\A\s*\|?[\s:|-]*-[\s:|-]*\|[\s:|-]*\z')

    DEFAULTS = {
      'max_lines' => nil,
      'max_headings' => nil,
      'max_tables' => nil,
      # The first floor rather than a cap: a long explanation carrying no
      # diagram is what the rule is about. Off unless the mode names a number,
      # like every other threshold here.
      'diagram_required_over_lines' => nil,
      'announce_patterns' => [],
      'shorthand_patterns' => [],
      'gloss_patterns' => [],
      'specimen_patterns' => [],
      'vocab_min_lines' => 1,
      'blocking' => true,
      # A mode-supplied pattern with nested quantifiers backtracks without
      # bound: one such pattern had not returned after two minutes on a
      # 74-character line, burning the hook's whole budget every turn. Ruby
      # bounds each match with Regexp.timeout; the deadline in measure() keeps
      # the total bounded too, which is what the Python SIGALRM did.
      'measure_timeout_seconds' => 5,
      'log_max_bytes' => 1024 * 1024,
      'banner_prefix' => 'gate',
      # nil, and pinned here, because nil is what note() reads as "this mode
      # declared no log". Every other value — including the empty string — is a
      # declaration the gate is obliged to attempt and to complain about when it
      # cannot honour it.
      'log_path' => nil
    }.freeze

    INT_KEYS = %w[max_lines max_headings max_tables diagram_required_over_lines
                  vocab_min_lines measure_timeout_seconds log_max_bytes].freeze
    LIST_KEYS = %w[announce_patterns shorthand_patterns gloss_patterns
                   specimen_patterns].freeze
    # log_path is deliberately absent. It was added here once, and the cost was
    # that `"log_path": null` — the key's own shipped default — became a fatal
    # config error that turned a blocking gate into NOT RUN on every turn. A
    # log the gate cannot write is a fault in the log, not in the mode's ability
    # to state thresholds, so it is diagnosed where the write happens and
    # reported in the banner without disabling enforcement.
    STR_KEYS = %w[banner_prefix rewrite_instruction section mode_name].freeze

    class MeasureTimeout < StandardError; end

    # A mode's gate parameters. Nothing here is decided by the core.
    #
    # Every value is type-checked here rather than where it is used. A mode that
    # writes `"max_lines": "60"` used to crash the gate on every turn with an
    # uncaught error and a non-zero exit — no verdict, no log line, and the
    # operator's only symptom was a hook that had stopped working. Problems are
    # collected, not raised: the caller reports them and lets the turn through.
    class Config
      attr_reader :problems, :path, :mode_name, :mode_version, :section,
                  :max_lines, :max_headings, :max_tables, :diagram_over_lines,
                  :vocab_min_lines,
                  :blocking, :banner_prefix, :rewrite_instruction, :log_path,
                  :announce, :shorthand, :gloss, :specimen, :measure_timeout,
                  :log_max_bytes

      def initialize(raw, path)
        @problems = []
        unless raw.is_a?(Hash)
          @problems << "config is #{describe(raw)}, expected an object"
          raw = {}
        end
        raw = checked(raw)

        merged = DEFAULTS.merge(raw)
        @path = path
        @mode_name = raw.fetch('mode_name', '?')
        @mode_version = raw.fetch('mode_version', '?')
        @section = raw.fetch('section', '')
        @max_lines = merged['max_lines']
        @max_headings = merged['max_headings']
        @max_tables = merged['max_tables']
        @diagram_over_lines = merged['diagram_required_over_lines']
        @vocab_min_lines = merged['vocab_min_lines']
        # Declared by the mode, written into this config by the compiler, and
        # honoured here. A mode that declares blocking:false gets the verdict
        # reported and the turn left alone.
        @blocking = merged['blocking'] ? true : false
        @banner_prefix = merged['banner_prefix']
        # From raw, not merged: nil means the mode declared none, and nil is
        # what suppresses the instruction line.
        @rewrite_instruction = raw['rewrite_instruction']
        @log_path = merged['log_path']
        @announce = compile_any(merged['announce_patterns'])
        @shorthand = merged['shorthand_patterns'].map { |p| Regexp.new(p) }
        @gloss = compile_any(merged['gloss_patterns'])
        # Spans where a token is being exhibited rather than used — a specimen
        # list. Text explaining the vocabulary rule has to name the shapes it
        # governs, and naming them is not using them.
        @specimen = merged['specimen_patterns'].map { |p| Regexp.new(p) }
        # Clamped, not rejected: a mode that asks for 6 seconds gets what fits
        # rather than a refusal it cannot act on. 4 seconds of recheck poll plus
        # 6 of measurement is 10.4 against a 10-second hook limit, and the hook
        # dies with no output, so the gate would silently stop enforcing for
        # exactly the modes whose patterns are expensive enough to need the time.
        requested = merged['measure_timeout_seconds']
        @measure_timeout =
          if requested.is_a?(Numeric) && requested > MEASURE_TIMEOUT_CEILING
            MEASURE_TIMEOUT_CEILING
          else
            requested
          end
        @log_max_bytes = merged['log_max_bytes']
      end

      private

      def describe(value)
        case value
        when nil then 'null'
        when true, false then 'boolean'
        when Array then 'list'
        when String then 'string'
        when Integer, Float then 'number'
        else value.class.name.downcase
        end
      end

      # Drop every value whose type the gate cannot use, and say which.
      def checked(raw)
        out = {}
        raw.each do |key, value|
          if INT_KEYS.include?(key) &&
             (!value.is_a?(Integer) || value.is_a?(TrueClass) || value.is_a?(FalseClass))
            # "a number" is imprecise — every value here is rejected unless it
            # is an Integer, so a mode writing 5.0 is told its number is not a
            # number. It stays imprecise on purpose. The first read is held
            # byte-for-byte to 366f3fc wherever 366f3fc produced output at all,
            # and this string is output: improving it changes the banner and the
            # log line a first read emits for every mistyped threshold. A round
            # 3 advisory asked for the wording; the pass condition outranks it.
            @problems << "#{key} is #{describe(value)}, expected a number"
            next
          end
          if LIST_KEYS.include?(key)
            unless value.is_a?(Array) && value.all?(String)
              @problems << "#{key} must be a list of strings"
              next
            end
            bad = false
            value.each do |pattern|
              Regexp.new(pattern)
            rescue RegexpError => e
              @problems << "#{key} contains an invalid regex: #{e.message}"
              bad = true
              break
            end
            out[key] = value unless bad
            next
          end
          if STR_KEYS.include?(key) && !value.is_a?(String)
            @problems << "#{key} is #{describe(value)}, expected a string"
            next
          end
          out[key] = value
        end
        out
      end

      def compile_any(patterns)
        return nil if patterns.nil? || patterns.empty?

        Regexp.new(patterns.map { |p| "(?:#{p})" }.join('|'))
      end
    end

    module_function

    def load_config(path)
      Config.new(JSON.parse(File.read(path, encoding: 'UTF-8')), path)
    end

    # --- transcript reading --------------------------------------------------

    def keep_record(rows, line)
      row = begin
        JSON.parse(line)
      rescue StandardError
        return
      end
      # A line that parses to a non-object is as unusable as one that does not
      # parse, and dropping it here is what makes it impossible for a consumer
      # to call a hash method on it. Guarding each consumer instead left the
      # caller of text_of unguarded, and a bare scalar on the newest line raised
      # out of the fail-open path.
      return unless row.is_a?(Hash)

      rows << row
    end

    def tail_records(transcript_path)
      blob = begin
        File.open(transcript_path, 'rb') do |fh|
          size = fh.size
          truncated = size > TAIL_BYTES
          fh.seek(truncated ? size - TAIL_BYTES : 0)
          [fh.read.to_s.force_encoding('UTF-8').scrub, truncated]
        end
      rescue StandardError
        return nil
      end
      lines = blob[0].split("\n")
      # Only a seeked-past head is a partial line. A whole file has none.
      lines = lines[1..] if blob[1] && lines.length > 1
      rows = []
      lines.each do |line|
        line = line.strip
        next if line.empty?

        keep_record(rows, line)
      end
      rows
    end

    def all_records(path)
      # Whole-file read. The tail limit exists for the hot path, not for
      # calibration — truncating here would silently shrink the denominator.
      rows = []
      begin
        File.foreach(path, encoding: 'UTF-8') do |line|
          line = line.scrub.strip
          next if line.empty?

          keep_record(rows, line)
        end
      rescue StandardError
        return []
      end
      rows
    end

    def text_of(row)
      # Every level is guarded. The readers deliberately tolerate malformed
      # lines, so a record with a null message, a content list holding
      # non-objects, or a text value that is not a string reaches here, and
      # assuming shape after tolerating its absence raised out of the
      # fail-open path.
      return nil unless row.is_a?(Hash)

      message = row['message']
      return nil unless message.is_a?(Hash)

      content = message.fetch('content', [])
      return content.empty? ? nil : content if content.is_a?(String)
      return nil unless content.is_a?(Array)

      parts = content.select { |c| c.is_a?(Hash) && c['type'] == 'text' }
                     .map { |c| c['text'] }
      joined = parts.grep(String).reject(&:empty?).join("\n")
      joined.empty? ? nil : joined
    end

    # The opening of the block reason the operator sees. One reader now, where
    # there were two: the recheck used to read this same string back out of the
    # transcript, and keeping the two in step was a standing hazard because a
    # divergence was silent and cost every recheck verdict.
    #
    # It used to scrub the mode name here as well. That was load-bearing while
    # the recheck compared this string against the transcript — the transcript
    # holds the scrubbed form, because emit scrubs on the way out — and it is
    # not any more: emit is now the only consumer, so scrubbing twice changes
    # nothing. Removed rather than kept, because a line that cannot fail is a
    # line no mutation can pin: the 2026-08-26 run reported exactly that,
    # replacing the scrub with the raw name and finding all 122 tests green.
    def own_block_reason(cfg)
      "#{OWN_BLOCK_REASON}#{cfg.mode_name}"
    end

    # --- the carry-over note -------------------------------------------------
    #
    # The recheck's whole problem is telling the rewrite from the message that
    # was blocked. Until 2026-08-26 it was solved by reading Claude Code's block
    # feedback back out of the transcript. That string is Claude Code's preface
    # to *every* blocking Stop hook, so the gate had to guess which markers were
    # its own, and the guessing is what six rounds of review kept breaking: the
    # last attempt — step over a foreign marker rather than stop at it — removed
    # the only thing bounding the walk to one turn, and made the gate judge a
    # previous turn's rewrite a second time.
    #
    # The gate does not have to guess. At the moment it blocks it already knows
    # which record it judged; it writes that down and reads it back. What was an
    # inference over a shared string becomes a fact this gate alone can write.
    #
    # The note is per session and per mode, lives beside the log, and is
    # consumed on read.

    # The note's path, or nil when the mode declares no log and therefore no
    # place to put one.
    #
    # The file name is a digest and nothing else. mode_name is operator-supplied
    # and defaults to '?', so any name built from it directly is a path the
    # operator can steer — `../` and a NUL among them. A digest cannot be
    # steered, and the readable values go inside the file instead, where they
    # also serve as the collision check.
    def note_path(transcript_path, cfg)
      dir = note_dir(cfg)
      return nil if dir.nil?

      key = Digest::SHA256.hexdigest("#{note_key_path(transcript_path)}\0#{cfg.mode_name}")[0, 32]
      File.join(dir, "#{key}.json")
    rescue StandardError
      nil
    end

    # The transcript's identity, not its spelling. The design says the digest is
    # taken over the absolute path; hashing whatever the caller wrote means the
    # same file reached by two spellings yields two notes, so a turn blocked
    # through a relative path and rechecked through an absolute one loses its
    # verdict. Round 1's review named this. Expansion is also what the note's
    # stored `transcript` field is compared against, so both sides agree.
    def note_key_path(transcript_path)
      File.expand_path(transcript_path.to_s)
    rescue StandardError
      transcript_path.to_s
    end

    def note_dir(cfg)
      return nil if cfg.log_path.nil?

      log = File.expand_path(cfg.log_path)
      File.join(File.dirname(log), NOTE_DIR_NAME)
    rescue StandardError
      nil
    end

    # Records which assistant record this gate just blocked. Returns nil on
    # success and a reason string on failure; never raises, and never changes
    # what the first read emits. A block that cannot be written down still
    # blocks — the cost is one recheck verdict, not a wedged turn.
    #
    # Written to a temporary name and renamed, so a reader can never see a
    # half-written note. The pid is in the temporary name because two modes'
    # gates can run against one session at the same moment.
    def write_note(transcript_path, cfg, uuid)
      return 'no uuid to record' if uuid.nil? || uuid.to_s.empty?

      path = note_path(transcript_path, cfg)
      return nil if path.nil? # no log declared: not a failure, a declared absence

      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(
        tmp,
        JSON.generate(
          'transcript' => note_key_path(transcript_path).scrub,
          'mode' => cfg.mode_name.to_s.scrub,
          'blocked_uuid' => uuid.to_s.scrub,
          'at' => Time.now.to_f
        )
      )
      File.rename(tmp, path)
      nil
    rescue StandardError => e
      "#{e.class}: #{e.message}"
    end

    # [uuid this gate blocked, nil] or [nil, why not].
    #
    # Deletes the note before using it. A note that is read and left in place
    # can be read again by a later turn, and later turns are not hypothetical:
    # 28 of 240 blocks in the 2026-08-26 measurement drew no recheck at all, so
    # an unconsumed note outlives its turn about one time in nine.
    #
    # transcript and mode are compared as well as the digest that named the
    # file, because a digest collision or a reused file must not be resolved
    # silently in favour of judging something.
    #
    # Scrubbed on both sides: write_note scrubs, so a mode whose name carries a
    # byte that is not valid UTF-8 would otherwise never match its own note.
    def take_note(transcript_path, cfg)
      path = note_path(transcript_path, cfg)
      return [nil, 'nonote'] if path.nil?

      raw = begin
        File.read(path)
      rescue StandardError
        return [nil, 'nonote']
      end

      # A note that could not be deleted has not been consumed, and using it
      # anyway is the one thing consume-on-read exists to prevent: it stays on
      # disk and the next recheck reads it again. Round 1's review drove exactly
      # that — a notes directory that permits reading and forbids unlinking gave
      # two RECHECK-PASS rows naming the same record, which is the invariant this
      # whole design exists to hold. The comment that stood here said a note that
      # cannot be deleted must not be reused; the code went on to reuse it.
      #
      # Refusing is fail-closed in the direction this gate already leans: a
      # recheck never blocks, so declining costs one log line, while reusing
      # costs the invariant.
      begin
        File.unlink(path)
      rescue StandardError
        return [nil, 'nonote-unspent']
      end

      data = begin
        JSON.parse(raw)
      rescue StandardError
        return [nil, 'nonote-mismatch']
      end
      return [nil, 'nonote-mismatch'] unless data.is_a?(Hash)
      return [nil, 'nonote-mismatch'] unless data['transcript'] == note_key_path(transcript_path).scrub
      return [nil, 'nonote-mismatch'] unless data['mode'] == cfg.mode_name.to_s.scrub

      at = data['at']
      return [nil, 'nonote-mismatch'] unless at.is_a?(Numeric)

      # A note from the future is as unusable as one from too far back: both
      # mean the clock this note was stamped against is not the one being read.
      age = Time.now.to_f - at
      return [nil, 'nonote-stale'] unless age >= -1.0 && age <= NOTE_TTL_SECONDS

      uuid = data['blocked_uuid']
      return [nil, 'nonote-mismatch'] unless uuid.is_a?(String) && !uuid.empty?

      [uuid, nil]
    end

    # Where the blocked record sits in the window, or nil when it is not in the
    # window at all. Not in the window means the transcript outgrew the tail
    # read since the block; there is nothing to wait for, so the recheck says so
    # rather than measuring whatever it can reach.
    def index_of_uuid(rows, uuid)
      rows.index { |row| row.is_a?(Hash) && row['uuid'] == uuid }
    end

    # The newest assistant record after `index`, whether or not it carries text
    # yet. nil while none has landed.
    #
    # Position does the work the already-judged exclusion used to do: everything
    # at or before `index` is the blocked message or older, so a record found
    # here cannot be one a verdict has already named.
    #
    # A rewrite that is mid-write shows up here as text-less and is waited for,
    # rather than stepped over in favour of whatever text lies beneath it: a
    # rewrite that calls a tool writes a short preamble first, and stepping over
    # reaches the preamble while the answer is still being written. That cost is
    # reachable from the code, not measured — an earlier version of this comment
    # gave it as an observation and round 3 could not reproduce it.
    def newest_after_index(rows, index)
      i = rows.length - 1
      while i > index
        row = rows[i]
        return [text_of(row), row['uuid']] if row.is_a?(Hash) && row['type'] == 'assistant'

        i -= 1
      end
      nil
    end

    # The newest text-bearing assistant record after `index`, stepping over
    # records that carry none. Used only once the budget is spent.
    #
    # Over the 3,248 transcripts and 170 real blocks of the 2026-08-21 scan, a
    # completed rewrite sitting beneath a newer text-less record occurred 0
    # times, so this shape must not pre-empt the wait. It is kept as a last
    # resort because if the shape ever does occur, the alternative is the same
    # skipped verdict this reaches past.
    def deep_after_index(rows, index)
      i = rows.length - 1
      while i > index
        row = rows[i]
        if row.is_a?(Hash) && row['type'] == 'assistant'
          text = text_of(row)
          return [text, row['uuid']] if text
        end

        i -= 1
      end
      nil
    end

    # The newest assistant record, whether or not it carries text yet, or nil
    # when the transcript holds none. The first read's rule, unchanged since
    # before 2026-08-20.
    #
    # The recheck no longer falls back to it. It used to, when no marker was
    # found, and that fallback was the defect: the newest record a recheck
    # reaches is the message this turn has just blocked.
    def newest_assistant(rows)
      row = rows.reverse_each.find { |r| r['type'] == 'assistant' }
      row && [text_of(row), row['uuid']]
    end

    # Text of the turn's final assistant message, with the flush race handled.
    #
    # One response is written as several records (thinking, text, tool_use) at
    # different times. At Stop time the `text` record may not have landed yet,
    # so the newest assistant record is often thinking-only. Wait for the text
    # rather than judging an earlier message from the same turn.
    #
    # On a recheck that wait never engaged, and that was the original defect:
    # the blocked message is still the newest record carrying text, so it
    # satisfied the "has text" test immediately and was judged a second time.
    # Measured over one instance's first 768 log records, 140 of 140 rechecks
    # took the newest record without ever waiting, and 110 of 140 reported
    # metrics identical to the verdict that had just blocked.
    #
    # The recheck now starts from the note this gate wrote when it blocked, so
    # "which record was already judged" is read rather than inferred, and
    # everything the recheck considers lies strictly after it.
    #
    # `cfg` is required and not defaulted. It carries the log path the note is
    # derived from, and an optional argument whose absence silently disables the
    # mechanism is the shape round 5 caught in the measurement bound: three unit
    # fixtures on the helper, none on the wiring, and dropping the argument at
    # the call site left the whole suite green.
    def last_assistant_text(transcript_path, cfg, rechecked)
      blocked_uuid = nil
      if rechecked
        blocked_uuid, why_not = take_note(transcript_path, cfg)
        # No usable note means this gate did not block this turn, or blocked a
        # turn that was then abandoned. Either way it has no verdict of its own
        # for a rewrite to be measured against, and a recheck never blocks, so
        # refusing to judge costs the operator nothing but the log line.
        return [nil, why_not, nil] if blocked_uuid.nil?
      end

      attempts = rechecked ? RECHECK_POLL_ATTEMPTS : POLL_ATTEMPTS
      attempts.times do |attempt|
        rows = tail_records(transcript_path)
        return [nil, 'unreadable', nil] if rows.nil?

        waited = attempt.zero? ? 'ok' : 'ok-after-wait'

        if rechecked
          index = index_of_uuid(rows, blocked_uuid)
          # Stable across polls: the blocked record was written before the
          # block, so if it is not in the window now it will not appear by
          # waiting. Returning here rather than spending the budget.
          return [nil, 'blocked-record-gone', nil] if index.nil?

          found = newest_after_index(rows, index)
          return [found[0], waited, found[1]] if found && found[0]
        else
          newest = newest_assistant(rows)
          return [nil, 'no-assistant-record', nil] if newest.nil?
          return [newest[0], waited, newest[1]] if newest[0]
        end
        sleep(POLL_DELAY)
      end

      return [nil, 'race-timeout', nil] unless rechecked

      # The recheck's budget is spent with the note in hand and no rewrite
      # visible above the blocked record. One last pass that steps over
      # text-less records, then the named give-up.
      rows = tail_records(transcript_path)
      return [nil, 'unreadable', nil] if rows.nil?

      index = index_of_uuid(rows, blocked_uuid)
      return [nil, 'blocked-record-gone', nil] if index.nil?

      found = deep_after_index(rows, index)
      return [found[0], 'ok-after-wait-deep', found[1]] if found

      [nil, 'awaiting-rewrite', nil]
    end

    # --- measurement ---------------------------------------------------------

    # The deadline reaches here because one pattern can produce many matches on
    # one line, and the specimen scan runs its own patterns before the shorthand
    # loop is entered at all. Bounding only the shorthand loop, which is what the
    # first fix did, left both of those unbounded — the same invariant-as-an-AND
    # with one half done that this work keeps producing.
    def each_match(regexp, string, deadline = nil)
      pos = 0
      while pos <= string.length && (m = regexp.match(string, pos))
        raise MeasureTimeout if deadline && monotonic > deadline

        yield m
        pos = m.end(0) > m.begin(0) ? m.end(0) : m.begin(0) + 1
      end
    end

    def specimen_spans(line, cfg, deadline = nil)
      spans = []
      cfg.specimen.each do |pattern|
        raise MeasureTimeout if deadline && monotonic > deadline

        each_match(pattern, line, deadline) { |m| spans << [m.begin(0), m.end(0)] }
      end
      spans
    end

    # measure() under a wall-clock bound.
    #
    # Two bounds, because they catch different things. Regexp.timeout stops one
    # pattern that backtracks without returning. The deadline inside measure
    # stops many patterns that each return slowly — which is what the Python
    # SIGALRM bounded, and what a per-operation limit alone would not.
    def measure_bounded(text, cfg)
      return measure(text, cfg, nil) unless cfg.measure_timeout

      previous = Regexp.timeout
      Regexp.timeout = cfg.measure_timeout
      begin
        measure(text, cfg, monotonic + cfg.measure_timeout)
      rescue Regexp::TimeoutError
        raise MeasureTimeout
      ensure
        Regexp.timeout = previous
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Pure. [metrics, failures]. The whole judgement lives here.
    def measure(text, cfg, deadline = nil)
      raw = text.split("\n", -1)

      prose = []
      diagrams = 0
      in_fence = false
      raw.each do |line|
        if FENCE.match(line)
          # Openings only. A fenced block is what a diagram is made of here, and
          # counting both ends would report every diagram twice.
          diagrams += 1 unless in_fence
          in_fence = !in_fence
          next
        end
        prose << line unless in_fence
      end

      headings = prose.count { |l| HEADING.match(l) }
      tables = prose.count { |l| TABLE_SEP.match(l) }

      first = raw.find { |l| !l.strip.empty? } || ''
      announced = !(cfg.announce && cfg.announce.match(first)).nil?

      seen = {}
      unglossed = []
      if !cfg.shorthand.empty? && prose.length >= cfg.vocab_min_lines
        prose.each_with_index do |line, i|
          # No per-line check. There was one here, and round 3 showed nothing
          # could falsify it: the specimen scan and the loop between patterns
          # both read the clock, and one of them runs before anything on a line
          # can be slow. An unfalsifiable guard is not defence, it is a claim,
          # so it is deleted rather than given a test that cannot fail.
          nxt = i + 1 < prose.length ? prose[i + 1] : ''
          spans = specimen_spans(line, cfg, deadline)
          cfg.shorthand.each do |pattern|
            # Per pattern, not only per line. Regexp.timeout bounds one match,
            # so a line carrying n patterns could overshoot the deadline by
            # n times that bound while the clock was read only once, between
            # lines. The check above still stands: it catches a line whose
            # specimen scan alone is what runs long.
            raise MeasureTimeout if deadline && monotonic > deadline

            each_match(pattern, line, deadline) do |m|
              tok = m.size > 1 ? m[1] : m[0]
              next if tok.nil? || seen.key?(tok)
              # exhibited, not used — and not "first use"
              next if spans.any? { |s, e| s <= m.begin(0) && m.end(0) <= e }

              seen[tok] = true
              after = line[m.end(0)..] || ''
              if cfg.gloss && !(cfg.gloss.match(after) || cfg.gloss.match(nxt))
                unglossed << tok
              end
            end
          end
        end
      end

      metrics = {
        'lines' => prose.length,
        'headings' => headings,
        'tables' => tables,
        'diagrams' => diagrams,
        'announced' => announced,
        'unglossed' => unglossed
      }

      failures = []
      if cfg.max_lines && metrics['lines'] > cfg.max_lines && !announced
        failures << format(
          'LENGTH: %d lines (cap %d) with no announcement in the first line.',
          metrics['lines'], cfg.max_lines
        )
      end
      if cfg.max_headings && headings > cfg.max_headings
        failures << format('HEADINGS: %d (cap %d).', headings, cfg.max_headings)
      end
      if cfg.max_tables && tables > cfg.max_tables
        failures << format('TABLES: %d (cap %d).', tables, cfg.max_tables)
      end
      # A floor, and the announcement does not clear it: announcing that a
      # message is long says nothing about whether prose was the right carrier
      # for what is in it.
      if cfg.diagram_over_lines && metrics['lines'] > cfg.diagram_over_lines && diagrams.zero?
        failures << format(
          'DIAGRAM: %d lines of prose and no diagram (floor applies over %d).',
          metrics['lines'], cfg.diagram_over_lines
        )
      end
      unless unglossed.empty?
        failures << "VOCABULARY: first use without an inline gloss: #{unglossed.join(', ')}."
      end
      [metrics, failures]
    end

    # --- reporting -----------------------------------------------------------

    # Append-only record of every invocation. Diagnosis depends on this.
    #
    # Returns nil when the record landed or when no log was declared, and a
    # short reason when the write failed. The caller puts that reason in the
    # banner: a swallowed write failure is the whole defect this method used to
    # have — an empty-string or directory log_path left the gate blocking and
    # passing exactly as normal while nothing was ever recorded, so the
    # operator's onboarding week produced no data and no complaint.
    def note(cfg, verdict, metrics = nil, record_id = nil)
      # nil alone means "no log declared". false, 0 and "" are declarations the
      # gate cannot honour, and each has to reach the rescue below to be named.
      return if cfg.log_path.nil?

      stamp = Time.now.strftime('%Y-%m-%dT%H:%M:%S')
      detail = ''
      # Which record the verdict is about. Without it the log cannot answer the
      # one question the fix above turns on — whether two verdicts in a row were
      # about the same message — and it is also how a first read that grabbed a
      # stale record becomes diagnosable rather than merely suspected.
      detail += "\trec=#{record_id[0, 8]}" if record_id.is_a?(String) && !record_id.empty?
      if metrics
        detail += format(
          "\tlines=%d\theadings=%d\ttables=%d\tdiagrams=%d\tunglossed=%s",
          metrics['lines'], metrics['headings'], metrics['tables'], metrics['diagrams'],
          metrics['unglossed'].empty? ? '-' : metrics['unglossed'].join(',')
        )
      end
      path = File.expand_path(cfg.log_path)
      parent = File.dirname(path)
      # mkdir_p: two sessions ending at once both reach here, and the loser used
      # to lose its record to a swallowed already-exists error.
      FileUtils.mkdir_p(parent) unless parent.empty? || File.directory?(parent)
      # One line per turn with no bound grows without limit. Rotate rather than
      # truncate so the run that crossed the bound is still readable.
      # file?, not exist?: a directory has an on-disk size too, and with the
      # bound at or below it the rename moved the operator's directory to
      # <path>.1 and let a regular file take its name — silently, because the
      # append then succeeded. A directory now skips rotation and falls through
      # to the append, where EISDIR is rescued and named in the banner.
      if cfg.log_max_bytes && File.file?(path) && File.size(path) > cfg.log_max_bytes
        # Check-then-act: two gates crossing the bound together both decide to
        # rotate, and the loser's rename fails. Rescued here rather than by the
        # method-level rescue below, which would swallow the append along with
        # it — the record is the point of this method, the rotation is
        # housekeeping. Whichever process rotated first, the append still lands.
        begin
          File.rename(path, "#{path}.1")
        rescue SystemCallError
          nil
        end
      end
      File.open(path, 'a', encoding: 'UTF-8') do |fh|
        fh.write("#{stamp}\t#{cfg.mode_name}\t#{verdict}#{detail}\n")
      end
      nil
    rescue StandardError => e
      # Bounded because it travels into the banner every turn, and a rescued
      # message can carry a path of any length. Scrubbed first because it can
      # carry the declared path's own bytes: a log_path holding a byte invalid
      # as UTF-8 lands here as an EILSEQ whose message embeds it verbatim,
      # String#tr raised on that inside this very rescue, and the gate died out
      # of main with exit 0 and nothing on either stream — no banner, no
      # verdict, no block. The output-boundary scrub in emit() cannot reach
      # this: the raise happened before any output was assembled.
      reason = "#{e.class}: #{e.message}".scrub.tr("\n", ' ')
      reason.length > 120 ? "#{reason[0, 117]}..." : reason
    end

    # One phrasing wherever a write failure surfaces, so the normal banner and
    # the two NOT RUN lines cannot drift into saying it differently.
    def log_note(log_failure)
      "log not written: #{log_failure}"
    end

    def banner(cfg, verdict, metrics, failures, rechecked, log_failure = nil)
      shape = format('%d lines / %d headings / %d tables / %d diagrams',
                     metrics['lines'], metrics['headings'], metrics['tables'],
                     metrics['diagrams'])
      notes = []
      notes << failures.map { |f| f.split(':').first }.join(' / ') unless failures.empty?
      notes << log_note(log_failure) if log_failure
      tail = notes.empty? ? '' : " — #{notes.join('; ')}"
      scope = if rechecked
                ' (recheck, not blocking)'
              elsif !cfg.blocking
                ' (advisory)'
              else
                ''
              end
      "#{cfg.banner_prefix}#{scope}: #{verdict} (#{shape})#{tail}"
    end

    # The gate's one output seam: all three emitted objects pass through here,
    # and their values are strings. Scrubbed at this boundary because every
    # config-sourced string funnels into it — mode_name and section through the
    # block reason, banner_prefix and the problem list through every banner, a
    # rescued write failure through log_note — and a byte invalid as UTF-8 in
    # any of them made JSON.generate raise, which the top-level rescue turned
    # into exit 0 with empty stdout: no banner, no verdict, no block. Round 13
    # measured that silence from a bad log_path on this tree and from a bad
    # mode_name on the pre-repair tree too, so the scrub sits where the routes
    # converge rather than at whichever source the last repair happened to
    # touch. Invalid sequences become U+FFFD; nothing else changes.
    def emit(payload)
      puts JSON.generate(payload.transform_values { |v| v.is_a?(String) ? v.scrub : v })
    end

    def report(cfg, paths)
      paths.each do |path|
        all_records(path).each do |row|
          next unless row['type'] == 'assistant'

          text = text_of(row)
          next unless text

          m, f = measure(text, cfg, nil)
          puts format("%s\tlines=%d\theadings=%d\ttables=%d\tFAIL=%s",
                      path, m['lines'], m['headings'], m['tables'],
                      f.empty? ? '-' : f.map { |x| x.split(':').first }.join(','))
        end
      end
    end

    # --- entry point ---------------------------------------------------------

    def parse_args(argv)
      config = nil
      report_paths = nil
      i = 0
      while i < argv.length
        case argv[i]
        when '--config'
          config = argv[i + 1]
          i += 2
        when '--report'
          report_paths = []
          i += 1
          while i < argv.length && !argv[i].start_with?('--')
            report_paths << argv[i]
            i += 1
          end
        else
          i += 1
        end
      end
      [config, report_paths]
    end

    def main(argv = ARGV, stdin = $stdin)
      config_path, report_paths = parse_args(argv)
      if config_path.nil?
        # Zero, not two. The header two hundred lines up says the exit status is
        # always zero because a gate fault must never wedge a session, and this
        # was the one path that said otherwise — reached by anyone who adds the
        # executable to a Stop hook by hand and forgets the argument, and
        # reached before stdin is read, so the once-per-turn brake never applies
        # either. The complaint goes to stderr, where the operator can see it.
        warn 'readable_gate: --config is required; not run'
        return 0
      end

      cfg = begin
        load_config(config_path)
      rescue StandardError
        return 0 # a broken config must not wedge the session
      end

      if report_paths
        report(cfg, report_paths)
        return 0
      end

      unless cfg.problems.empty?
        # A mode whose declaration the gate cannot use is told so, and the turn
        # goes through. Enforcing half a config would be worse than enforcing
        # none, and crashing tells the operator nothing.
        lost = note(cfg, "SKIP-bad-config: #{cfg.problems.join('; ')}")
        emit(
          'systemMessage' => "#{cfg.banner_prefix}: NOT RUN — #{cfg.problems.join('; ')}" +
                             (lost ? "; #{log_note(lost)}" : '')
        )
        return 0
      end

      payload = begin
        JSON.parse(stdin.read)
      rescue StandardError
        note(cfg, 'SKIP-bad-stdin')
        return 0
      end
      payload = {} unless payload.is_a?(Hash)

      # A turn is blocked at most once. The rewrite is still measured and
      # reported, so its outcome is visible; it is simply never blocked again.
      rechecked = payload['stop_hook_active'] ? true : false

      text, why, record_id =
        last_assistant_text(payload.fetch('transcript_path', ''), cfg, rechecked)
      if text.nil? || text.strip.empty?
        lost = note(cfg, "SKIP-#{why}")
        # Every recheck that produces no verdict says so on screen. Naming only
        # the two expected reasons left the others silent, and the ones it left
        # out are live: a transcript momentarily unreadable, and a rewrite whose
        # text is whitespace after the fallback found it. Both spent the budget
        # and told the operator nothing. A first read keeps its old silence —
        # there the turn goes out regardless and the log is the right place.
        budget = format('%.1f', RECHECK_POLL_ATTEMPTS * POLL_DELAY)
        tail = lost ? "; #{log_note(lost)}" : ''
        reason =
          case why
          when 'awaiting-rewrite'
            "the rewrite had not been recorded within #{budget}s"
          when 'nonote'
            'this gate did not block this turn — another Stop hook did — so it has no ' \
            'verdict of its own to measure a rewrite against'
          when 'nonote-stale'
            # Both halves of the age test land here, and an earlier version of
            # this sentence asserted the older one for both — a note stamped
            # ahead of the clock was reported as "more than 300s old", which is
            # the opposite of true. Round 1's review named it.
            "this gate's record of what it blocked is not from this turn: it is either more " \
            "than #{NOTE_TTL_SECONDS.round}s old, and so belongs to an earlier turn that was " \
            'interrupted, or it is stamped ahead of the clock reading it'
          when 'nonote-unspent'
            "this gate's record of what it blocked could not be deleted, so it could not be " \
            'used: a record that survives being read would be read again on a later turn. ' \
            'Check that the notes directory beside the log is writable'
          when 'nonote-mismatch'
            "this gate's record of what it blocked did not match this session, so it was " \
            'not used'
          when 'blocked-record-gone'
            'the message this gate blocked is no longer in the part of the transcript that ' \
            'was read'
          when 'unreadable'
            'the transcript could not be read'
          else
            "nothing measurable was found (#{why})"
          end
        emit('systemMessage' => "#{cfg.banner_prefix} (recheck): NOT RUN — #{reason}#{tail}") if rechecked
        return 0
      end

      begin
        metrics, failures = measure_bounded(text, cfg)
      rescue MeasureTimeout
        lost = note(cfg, 'SKIP-measure-timeout')
        emit(
          'systemMessage' =>
            "#{cfg.banner_prefix}: NOT RUN — measurement exceeded #{cfg.measure_timeout}s; " \
            "check the mode's patterns for unbounded backtracking" +
            (lost ? "; #{log_note(lost)}" : '')
        )
        return 0
      end

      verdict = failures.empty? ? 'PASS' : 'FAIL'
      lost = note(cfg, "#{rechecked ? 'RECHECK-' : ''}#{verdict}-#{why}", metrics, record_id)

      out = { 'systemMessage' => banner(cfg, verdict, metrics, failures, rechecked, lost) }
      if !failures.empty? && !rechecked && cfg.blocking
        out['decision'] = 'block'
        instruction = cfg.rewrite_instruction.to_s
        out['reason'] =
          "#{own_block_reason(cfg)}" \
          "#{cfg.section.to_s.empty? ? '' : " #{cfg.section}"}:\n- " +
          failures.join("\n- ") +
          (instruction.empty? ? '' : "\n\n#{instruction}")

        # Written before the block is emitted, so the note exists by the time
        # Claude Code can act on the block. A failure here is logged and the
        # turn is still blocked: enforcement does not depend on the note, only
        # the recheck's verdict does.
        failure = write_note(payload.fetch('transcript_path', ''), cfg, record_id)
        note(cfg, "NOTE-WRITE-FAILED: #{failure}") if failure
      end
      emit(out)
      0
    end
  end
end

if $PROGRAM_NAME == __FILE__
  code = begin
    KairosHookProjector::ReadableGate.main
  rescue StandardError, SystemStackError
    # Nothing this script can fail at is worth wedging a session over.
    0
  end
  exit code
end
