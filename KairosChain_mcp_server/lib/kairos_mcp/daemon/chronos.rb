# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'time'

module KairosMcp
  class Daemon
    # Chronos — the daemon's time-driven scheduler (P2.4).
    #
    # Design reference: v0.2 §4.
    #
    # Responsibilities:
    #   1. Load schedules from `.kairos/config/schedules.yml`.
    #   2. Maintain `chronos_state.yml` atomically with two timestamps per
    #      schedule: `last_fire_at` (actual fire) and `last_evaluated_at`
    #      (last due-evaluation window boundary). These are intentionally
    #      separated [FIX: CF-10] so that:
    #        (a) A fresh boot does not treat un-fired history as "due now".
    #        (b) The skip policy cannot miscount by 1.
    #   3. On each `tick(now)`, count the cron occurrences in the window
    #      (last_evaluated_at, now] and apply the per-schedule `missed_policy`:
    #        - skip             : fire once, log the rest
    #        - catch_up_once    : fire once regardless of the missed count
    #        - catch_up_bounded : fire up to `max_catch_up_runs`, drop the
    #          rest; if the backlog is older than `stale_after`, drop it
    #          entirely and fire exactly once to mark recovery [FIX: CF-3].
    #   4. Offer an in-memory mandate queue with concurrency enforcement
    #      (queue / allow / reject) — daemon integration pops from it.
    #
    # Crash-safety:
    #   * State writes use tmp+rename+dir-fsync [FIX: CF-13]. A torn write
    #     leaves either the previous state or the new state intact — never
    #     a half-written YAML.
    #   * An exception inside one schedule's evaluation does NOT prevent
    #     later schedules from being evaluated (per-schedule rescue).
    #
    # Timezone handling:
    #   * Per-schedule `timezone:` is applied via ENV['TZ'] swap around
    #     `Time#getlocal`. This is safe in the daemon's single-threaded
    #     event loop. Tests should not rely on the system TZ.
    #   * DST caveat: during fall-back, the same wall-clock minute occurs
    #     twice in real time; a per-minute iterator will count both.
    #     This matches neither strict "fire once per wall minute" nor
    #     strict "fire once per real minute" — but is consistent with
    #     how many simple cron implementations behave.
    #
    # This class is intentionally standalone: no coupling to Safety, Mandate,
    # or Autonomos. Daemon integration wires those together.
    class Chronos
      DEFAULT_SCHEDULES_PATH = '.kairos/config/schedules.yml'
      DEFAULT_STATE_PATH     = '.kairos/chronos_state.yml'
      DEFAULT_STALE_AFTER    = 48 * 3600          # 48h
      DEFAULT_MAX_CATCH_UP   = 5
      DEFAULT_MAX_CYCLES     = 50

      # A fired event — `tick` returns an array of these; the daemon will
      # feed each one to `enqueue_mandate`.
      FiredEvent = Struct.new(:name, :schedule, :mandate, :fired_at, keyword_init: true)

      # Log entries (in-memory; caller persists to structured log if needed).
      MissedEntry = Struct.new(:name, :count, :reason, :at, keyword_init: true)
      StaleDrop   = Struct.new(:name, :dropped_count, :at, keyword_init: true)
      Rejection   = Struct.new(:name, :reason, :at, keyword_init: true)

      attr_reader :schedules, :state, :queue,
                  :missed_log, :stale_drops, :rejection_log

      # ------------------------------------------------------------ lifecycle

      # @param schedules_path [String] path to schedules.yml
      # @param state_path     [String] path to chronos_state.yml
      # @param logger         [#info, #warn, #error, nil]
      # @param clock          [#call, nil] returns current Time (for tests)
      # @param schedules      [Array<Hash>, nil] inline schedules (skips file)
      def initialize(schedules_path: nil, state_path: nil, logger: nil,
                     clock: nil, schedules: nil)
        @schedules_path = schedules_path || DEFAULT_SCHEDULES_PATH
        @state_path     = state_path     || DEFAULT_STATE_PATH
        @logger         = logger
        @clock          = clock || -> { Time.now }
        @boot_time      = @clock.call

        @schedules = schedules ? schedules.map { |s| symbolize(s) } : load_schedules
        @state     = load_state

        @queue            = []
        @running_mandates = []
        @missed_log       = []
        @stale_drops      = []
        @rejection_log    = []
      end

      # Public: does a (possibly absent) state file exist for a schedule?
      def state_for(name)
        @state['schedules'][name.to_s] || {}
      end

      # ------------------------------------------------------------------ tick

      # Evaluate every schedule against `now`. Returns an Array of
      # FiredEvent objects (may be empty).
      #
      # Order: schedules are evaluated in the order they appear in schedules.yml.
      # State is persisted iff any schedule fired OR any state timestamp changed
      # since load — to avoid fsync storms on idle ticks we only persist when
      # something changed.
      def tick(now = nil)
        now ||= @clock.call
        fired = []
        state_dirty = false

        @schedules.each do |sched|
          # Codex-R1 fix #3: guard against malformed schedule entries
          # (e.g. scalar instead of hash) before any method call.
          begin
            next unless sched.is_a?(Hash) && enabled?(sched)
            state_dirty = true if evaluate_schedule(sched, now, fired)
          rescue StandardError => e
            log(:error, 'chronos_schedule_eval_failed',
                name: (sched.is_a?(Hash) ? sched[:name] : sched.inspect),
                error: "#{e.class}: #{e.message}")
          end
        end

        persist_state_atomic if state_dirty
        fired
      end

      # ------------------------------------------------------------ queue/conc.

      # Apply concurrency policy and either push the mandate onto the queue,
      # reject it, or log it. Returns :queued | :rejected.
      #
      # The `allow` policy still pushes to the queue — it is the daemon's
      # dispatcher that decides whether to start immediately or queue. The
      # `allow`-with-same-scope case is treated like `queue`.
      def enqueue_mandate(event)
        sched    = event[:schedule]
        mandate  = event[:mandate]
        name     = sched[:name]
        policy   = (sched[:concurrency] || 'queue').to_s

        case policy
        when 'queue'
          @queue << mandate
          :queued
        when 'allow'
          # Codex-R1 fix #1: same-project_scope overlap → queue; different scope → immediate
          if running_conflicts?(name, sched[:project_scope])
            @queue << mandate
            :queued
          else
            # Different project_scope or no conflict → allow concurrent
            @queue.unshift(mandate)  # priority position for immediate dispatch
            :queued
          end
        when 'reject'
          # Codex-R1 fix #1: reject checks both name AND project_scope
          if running_with_name?(name) || running_with_scope?(sched[:project_scope])
            @rejection_log << Rejection.new(name: name,
                                            reason: 'already_running',
                                            at: @clock.call.iso8601)
            log(:warn, 'chronos_mandate_rejected', name: name)
            :rejected
          else
            @queue << mandate
            :queued
          end
        else
          raise ArgumentError, "unknown concurrency policy: #{policy.inspect}"
        end
      end

      # Codex-R1 fix #2: roll back last_fire_at if enqueue was rejected.
      # Call this after enqueue_mandate returns :rejected.
      def rollback_fire(schedule_name)
        st = @state.dig('schedules', schedule_name.to_s)
        return unless st && st['_tentative_fire_at']
        st.delete('last_fire_at') if st['last_fire_at'] == st['_tentative_fire_at']
        st.delete('_tentative_fire_at')
        persist_state_atomic
      end

      # Pops the next mandate from the queue. Returns nil if empty.
      def pop_queued
        @queue.shift
      end

      # Daemon tells us which mandates are currently running so concurrency
      # decisions work. Entries must be Hashes with :id and :name.
      def register_running(mandate)
        @running_mandates << mandate
      end

      def unregister_running(mandate_id)
        @running_mandates.reject! { |m| m[:id] == mandate_id }
      end

      # Raw path to the persisted state file (for tests / status dumps).
      def state_path
        @state_path
      end

      # --------------------------------------------------------------- private

      private

      def enabled?(sched)
        sched[:enabled] != false
      end

      # Returns true if state was mutated (so the caller should persist).
      def evaluate_schedule(sched, now, fired)
        name  = sched[:name].to_s
        st    = (@state['schedules'][name] ||= {})

        last_eval = st['last_evaluated_at'] ? Time.parse(st['last_evaluated_at']) : @boot_time
        last_fire = st['last_fire_at']      ? Time.parse(st['last_fire_at'])      : nil

        due_count = Cron.count_occurrences(
          sched[:cron],
          from: last_eval,
          to:   now,
          tz:   sched[:timezone]
        )

        fired_this_tick = 0
        if due_count.positive?
          fired_this_tick = apply_missed_policy(sched, due_count, now, last_fire, fired)
        end

        st['last_evaluated_at'] = now.iso8601
        # Codex-R1 fix #2: last_fire_at is set tentatively here but may be
        # rolled back by confirm_or_rollback_fire if concurrency rejects the mandate.
        if fired_this_tick.positive?
          st['_tentative_fire_at'] = now.iso8601
          st['last_fire_at'] = now.iso8601
        end
        begin
          nxt = Cron.next_occurrence(sched[:cron], after: now, tz: sched[:timezone])
          st['next_fire_at'] = nxt&.iso8601
        rescue StandardError
          # Don't let next-occurrence failures block persistence.
        end

        true
      end

      # Implements skip / catch_up_once / catch_up_bounded.
      # Returns the number of fires emitted.
      def apply_missed_policy(sched, due_count, now, last_fire, fired)
        policy = (sched[:missed_policy] || 'skip').to_s
        case policy
        when 'skip'
          # Fire once, log the rest as "missed".
          emit_fire(sched, now, fired)
          @missed_log << MissedEntry.new(name: sched[:name], count: due_count - 1,
                                         reason: 'skip_policy',
                                         at: now.iso8601) if due_count > 1
          1
        when 'catch_up_once'
          emit_fire(sched, now, fired)
          if due_count > 1
            @missed_log << MissedEntry.new(name: sched[:name], count: due_count - 1,
                                           reason: 'catch_up_once',
                                           at: now.iso8601)
          end
          1
        when 'catch_up_bounded'
          cap       = Integer(sched[:max_catch_up_runs] || DEFAULT_MAX_CATCH_UP)
          stale_sec = parse_duration(sched[:stale_after]) || DEFAULT_STALE_AFTER
          effective = [due_count, cap].min

          # If the backlog is older than stale_sec, treat as "recovery from long
          # downtime": fire exactly once as a marker and drop the rest.
          if last_fire && (now - last_fire) > stale_sec
            @stale_drops << StaleDrop.new(name: sched[:name],
                                          dropped_count: due_count - 1,
                                          at: now.iso8601)
            effective = 1
          end

          effective.times { emit_fire(sched, now, fired) }
          if due_count > effective
            @missed_log << MissedEntry.new(name: sched[:name],
                                           count: due_count - effective,
                                           reason: 'catch_up_bounded_cap',
                                           at: now.iso8601)
          end
          effective
        else
          raise ArgumentError, "unknown missed_policy: #{policy.inspect}"
        end
      end

      def emit_fire(sched, now, fired)
        mandate = build_mandate_from_schedule(sched, now)
        fired << FiredEvent.new(
          name: sched[:name],
          schedule: sched,
          mandate: mandate,
          fired_at: now.iso8601
        )
      end

      # Translate a schedule's :mandate section into a mandate-like hash.
      # Real Mandate::create_for_daemon is invoked by the daemon; Chronos
      # is infrastructure and stays decoupled.
      def build_mandate_from_schedule(sched, fired_at)
        m = sched[:mandate] || {}
        {
          name:             sched[:name].to_s,
          source:           "chronos:#{sched[:name]}",
          mode:             'daemon',
          goal:             (m[:goal] || sched[:name]).to_s,
          max_cycles:       Integer(m[:max_cycles] || DEFAULT_MAX_CYCLES),
          checkpoint_every: Integer(m[:checkpoint_every] || 10),
          risk_budget:      (m[:risk_budget] || 'low').to_s,
          project_scope:    sched[:project_scope],
          fired_at:         fired_at.iso8601
        }
      end

      # Concurrency predicates ----------------------------------------------

      def running_with_name?(name)
        @running_mandates.any? { |m| m[:name].to_s == name.to_s }
      end

      # Codex-R1 fix #1: check if any running mandate shares the same project_scope
      def running_with_scope?(project_scope)
        return false if project_scope.nil? || project_scope.to_s.empty?
        @running_mandates.any? { |m| m[:project_scope].to_s == project_scope.to_s }
      end

      def running_conflicts?(name, project_scope)
        @running_mandates.any? do |m|
          m[:name].to_s == name.to_s && m[:project_scope] == project_scope
        end
      end

      # State I/O ------------------------------------------------------------

      def load_schedules
        return [] unless File.exist?(@schedules_path)

        raw = YAML.safe_load(File.read(@schedules_path), permitted_classes: [Symbol]) || {}
        list = raw['schedules'] || raw[:schedules] || []
        list.map { |h| symbolize(h) }
      rescue StandardError => e
        log(:error, 'chronos_schedules_load_failed',
            path: @schedules_path, error: "#{e.class}: #{e.message}")
        []
      end

      def load_state
        default = { 'schedules' => {} }
        return default unless File.exist?(@state_path)

        raw = YAML.safe_load(File.read(@state_path), permitted_classes: [Symbol]) || {}
        # Normalize to a hash-of-hashes keyed by string name.
        scheds = raw['schedules'] || raw[:schedules] || {}
        normalized = {}
        scheds.each do |k, v|
          normalized[k.to_s] = (v || {}).transform_keys(&:to_s)
        end
        { 'schedules' => normalized }
      rescue StandardError => e
        log(:warn, 'chronos_state_load_failed',
            path: @state_path, error: "#{e.class}: #{e.message}")
        default
      end

      # [FIX: CF-13] Atomic write: tmp → fsync → rename → dir fsync.
      def persist_state_atomic
        FileUtils.mkdir_p(File.dirname(@state_path))
        tmp = "#{@state_path}.tmp.#{$$}"
        File.open(tmp, 'w', 0o600) do |f|
          f.write(YAML.dump(@state))
          f.flush
          f.fsync
        end
        File.rename(tmp, @state_path)
        fsync_dir(File.dirname(@state_path))
      rescue StandardError => e
        log(:error, 'chronos_state_persist_failed',
            path: @state_path, error: "#{e.class}: #{e.message}")
        begin
          File.unlink(tmp) if tmp && File.exist?(tmp)
        rescue StandardError
          # best effort
        end
        raise
      end

      def fsync_dir(dir)
        d = File.open(dir)
        begin
          d.fsync
        rescue Errno::EINVAL, Errno::EACCES, NotImplementedError
          # Directory fsync not supported here — best effort.
        ensure
          d.close
        end
      end

      # Utility --------------------------------------------------------------

      def symbolize(h)
        return h unless h.is_a?(Hash)

        h.each_with_object({}) do |(k, v), acc|
          acc[k.to_sym] = v.is_a?(Hash) ? v.transform_keys(&:to_sym) : v
        end
      end

      def parse_duration(v)
        return nil if v.nil?
        return Integer(v) if v.is_a?(Numeric)

        s = v.to_s.strip
        if (m = s.match(/\A(\d+)\s*([smhdSMHD])\z/))
          n = Integer(m[1])
          case m[2].downcase
          when 's' then n
          when 'm' then n * 60
          when 'h' then n * 3600
          when 'd' then n * 86_400
          end
        else
          Integer(s)
        end
      rescue ArgumentError
        nil
      end

      def log(level, event, **details)
        return unless @logger

        if @logger.respond_to?(level)
          @logger.public_send(level, event, source: 'chronos', details: details)
        end
      rescue StandardError
        # Logging must not raise.
      end

      # ===================================================================
      # Cron module — 5-field cron parser and evaluator.
      #
      # Fields (standard cron):
      #   minute (0-59), hour (0-23), day-of-month (1-31),
      #   month (1-12), day-of-week (0-6, 0=Sunday)
      #
      # Supported syntax per field:
      #   *            — any value
      #   N            — exact value
      #   N-M          — inclusive range
      #   N,M,O        — list of values
      #   */N          — every N (starting from field minimum)
      #   N-M/S        — every S in N..M
      #
      # Standard dom/dow OR semantics:
      #   Both restricted  → fire if EITHER matches.
      #   One wildcard     → fire iff the other matches.
      #   Both wildcard    → fire if all other fields match.
      # ===================================================================
      module Cron
        FIELDS = %i[minute hour mday month wday].freeze
        RANGES = {
          minute: 0..59,
          hour:   0..23,
          mday:   1..31,
          month:  1..12,
          wday:   0..6
        }.freeze

        module_function

        # Parse a 5-field cron string into { field => SortedSet of ints }.
        # Raises ArgumentError on malformed input.
        def parse(expr)
          parts = expr.to_s.strip.split(/\s+/)
          unless parts.size == 5
            raise ArgumentError, "cron must have 5 fields, got #{parts.size}: #{expr.inspect}"
          end

          FIELDS.each_with_index.each_with_object({}) do |(field, i), acc|
            acc[field] = parse_field(parts[i], RANGES[field], field)
          end
        end

        def parse_field(spec, range, field_name)
          spec = spec.to_s.strip
          raise ArgumentError, "empty field #{field_name}" if spec.empty?

          return range.to_a if spec == '*'

          values = []
          spec.split(',').each do |item|
            values.concat(parse_item(item, range, field_name))
          end
          result = values.sort.uniq
          result.each do |v|
            unless range.cover?(v)
              raise ArgumentError,
                    "cron value #{v} out of range for #{field_name} (#{range})"
            end
          end
          result
        end

        def parse_item(item, range, field_name)
          case item
          when /\A\*\/(\d+)\z/
            step = Integer(Regexp.last_match(1))
            raise ArgumentError, "step must be positive in #{field_name}" if step <= 0

            range.step(step).to_a
          when /\A(\d+)-(\d+)\/(\d+)\z/
            a = Integer(Regexp.last_match(1))
            b = Integer(Regexp.last_match(2))
            step = Integer(Regexp.last_match(3))
            raise ArgumentError, "step must be positive in #{field_name}" if step <= 0
            raise ArgumentError, "range #{a}-#{b} inverted in #{field_name}" if a > b

            (a..b).step(step).to_a
          when /\A(\d+)-(\d+)\z/
            a = Integer(Regexp.last_match(1))
            b = Integer(Regexp.last_match(2))
            raise ArgumentError, "range #{a}-#{b} inverted in #{field_name}" if a > b

            (a..b).to_a
          when /\A(\d+)\z/
            [Integer(Regexp.last_match(1))]
          else
            raise ArgumentError, "malformed cron item #{item.inspect} in #{field_name}"
          end
        end

        # Returns true iff `time` matches `cron_spec`. `time` should be in
        # the target timezone already (see `with_tz`).
        def matches?(cron_spec, time)
          return false unless cron_spec[:minute].include?(time.min)
          return false unless cron_spec[:hour].include?(time.hour)
          return false unless cron_spec[:month].include?(time.month)

          dom_wild = cron_spec[:mday] == RANGES[:mday].to_a
          dow_wild = cron_spec[:wday] == RANGES[:wday].to_a
          dom_ok   = cron_spec[:mday].include?(time.mday)
          dow_ok   = cron_spec[:wday].include?(time.wday)

          if dom_wild && dow_wild
            true
          elsif dom_wild
            dow_ok
          elsif dow_wild
            dom_ok
          else
            dom_ok || dow_ok
          end
        end

        # Count cron occurrences in the half-open window (from, to].
        #
        # Uses a per-minute iterator — trivially fast for realistic windows
        # (48h = 2880 iterations). If `from >= to`, returns 0.
        def count_occurrences(expr, from:, to:, tz: nil)
          cron = parse(expr)
          return 0 if from >= to

          # Start at the first minute strictly after `from`.
          start_epoch = ((from.to_i / 60) + 1) * 60
          end_epoch   = (to.to_i / 60) * 60
          return 0 if start_epoch > end_epoch

          count = 0
          with_tz(tz) do
            t = to_tz_time(start_epoch, tz)
            while t.to_i <= end_epoch
              count += 1 if matches?(cron, t)
              t += 60
            end
          end
          count
        end

        # Returns the next Time at or after `after + 1 minute` that matches.
        # Returns nil if none within ~2 years (safety ceiling against bad
        # cron expressions that will never match).
        def next_occurrence(expr, after:, tz: nil)
          cron = parse(expr)
          start_epoch = ((after.to_i / 60) + 1) * 60
          max_iter    = 366 * 24 * 60 * 2 # ~2 years of minutes

          with_tz(tz) do
            t = to_tz_time(start_epoch, tz)
            max_iter.times do
              return t if matches?(cron, t)

              t += 60
            end
          end
          nil
        end

        # True if `tz` should be treated as UTC (nil, empty, or "UTC").
        def utc_tz?(tz)
          tz = tz.to_s.strip if tz.is_a?(String)
          tz.nil? || tz == '' || tz == 'UTC'
        end

        # Build a Time at `epoch` expressed in `tz`. For UTC we force `.utc`
        # so the system TZ (via `getlocal`) cannot leak in.
        def to_tz_time(epoch, tz)
          t = Time.at(epoch)
          utc_tz?(tz) ? t.utc : t.getlocal
        end

        # Run a block with ENV['TZ'] set. Safe in single-threaded code;
        # the daemon event loop never runs concurrently, and tests use
        # explicit TZ or UTC. If `tz` is nil/empty/UTC, no swap occurs —
        # the caller must still use `to_tz_time` so that the UTC branch
        # actually produces a UTC Time rather than a system-local one.
        def with_tz(tz)
          if utc_tz?(tz)
            yield
          else
            old = ENV['TZ']
            begin
              ENV['TZ'] = tz.to_s
              yield
            ensure
              ENV['TZ'] = old
            end
          end
        end
      end
    end
  end
end
