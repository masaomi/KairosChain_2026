# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'
require 'time'

require 'project_manager/parsed_time'

module ProjectManager
  # Single authoritative store for project/task state (INV-PM-6).
  #
  # Meaningful-touch discipline (INV-PM-7): every mutating operation advances the
  # item's last-meaningful-touch marker (touched_at) UNLESS the caller declares the
  # write mechanical (bulk/migration/seeding). Seeding may carry an explicit
  # touched_at from the migration source (INV-PM-6: carry, not restamp). An item
  # from a markerless source seeds with touched_at = nil and is treated as
  # non-dormant until its first meaningful touch (v0.5 §11 seeding default).
  class Store
    PROJECT_STATUSES = %w[active paused done abandoned].freeze
    ITEM_STATUSES    = %w[open active awaiting_gate done dropped].freeze
    SALIENCE_LEVELS  = %w[low normal high].freeze
    DEP_KINDS        = %w[item world_event].freeze

    # What the operator was asked to spend attention on, for one closed judgment.
    ATTENTION_KINDS = %w[decide read review].freeze
    # The operator's own report of what that judgment cost to understand.
    # no_answer is a value, not a gap: declining to answer is itself evidence of
    # load, and dropping it as missing data would bias the record toward the
    # occasions the operator had energy to spare.
    GRASP_LEVELS    = %w[once reread unclear no_answer].freeze

    attr_reader :path

    def initialize(path: nil)
      @path = path || default_path
      @data = load_data
      # The last state known to be writable, kept as generated JSON. A rollback
      # restores from this rather than re-reading the file, so it cannot fail the
      # way the write it undoes did — a store.json that has meanwhile become
      # unreadable would otherwise leave the rollback with nothing to restore and
      # the offending value still in place.
      @committed = JSON.generate(@data)
    end

    def default_path
      File.join(KairosMcp.data_dir, 'pm', 'store.json')
    end

    # --- Projects ---

    def register_project(name:, notes: nil, now: Time.now)
      id = generate_id('prj')
      @data['projects'][id] = {
        'id' => id, 'name' => name, 'status' => 'active',
        'notes' => notes, 'provenance' => [],
        'created_at' => now.utc.iso8601, 'touched_at' => now.utc.iso8601
      }.compact
      save
      @data['projects'][id]
    end

    def update_project(id, attrs, now: Time.now)
      prj = fetch_project(id)
      if attrs.key?('status') && !PROJECT_STATUSES.include?(attrs['status'])
        raise ArgumentError, "invalid project status: #{attrs['status']} (#{PROJECT_STATUSES.join('/')})"
      end

      %w[name status notes].each { |k| prj[k] = attrs[k] if attrs.key?(k) }
      prj['touched_at'] = now.utc.iso8601
      save
      prj
    end

    def add_project_provenance(id, entry)
      prj = fetch_project(id)
      (prj['provenance'] ||= []) << entry
      save
      prj
    end

    def projects
      @data['projects'].values
    end

    def fetch_project(id)
      @data['projects'][id] or raise ArgumentError, "unknown project: #{id}"
    end

    # --- Items ---

    # mechanical: true marks a bulk/migration write — it does NOT advance the
    # marker. touched_at (ISO8601) may be supplied by seeding to carry the source's
    # own recency signal; if the source is markerless, touched_at stays nil.
    def add_item(project_id:, title:, now: Time.now, mechanical: false, touched_at: nil, **attrs)
      fetch_project(project_id)
      id = generate_id('itm')
      item = {
        'id' => id, 'project_id' => project_id, 'title' => title,
        'status' => 'open', 'deps' => [], 'provenance' => [],
        'created_at' => now.utc.iso8601,
        'touched_at' => mechanical ? touched_at : now.utc.iso8601
      }
      apply_item_attrs(item, attrs)
      @data['items'][id] = item
      save
      item
    end

    def update_item(id, attrs, now: Time.now, mechanical: false)
      item = fetch_item(id)
      apply_item_attrs(item, attrs)
      item['touched_at'] = now.utc.iso8601 unless mechanical
      save
      item
    end

    def add_dep(id, kind:, ref:, note: nil, now: Time.now, mechanical: false)
      raise ArgumentError, "invalid dep kind: #{kind} (#{DEP_KINDS.join('/')})" unless DEP_KINDS.include?(kind)

      item = fetch_item(id)
      item['deps'] << { 'kind' => kind, 'ref' => ref, 'note' => note, 'resolved' => false }.compact
      item['touched_at'] = now.utc.iso8601 unless mechanical
      save
      item
    end

    # World-event deps are operator-cleared, not system-resolved (INV-PM-7).
    def resolve_dep(id, ref:, now: Time.now)
      item = fetch_item(id)
      dep = item['deps'].find { |d| d['ref'] == ref && !d['resolved'] }
      raise ArgumentError, "no unresolved dep with ref: #{ref}" unless dep

      dep['resolved'] = true
      item['touched_at'] = now.utc.iso8601
      save
      item
    end

    def add_item_provenance(id, entry, now: Time.now, mechanical: false)
      item = fetch_item(id)
      item['provenance'] << entry
      item['touched_at'] = now.utc.iso8601 unless mechanical
      save
      item
    end

    # --- Attention ---
    #
    # One entry per closed judgment: the operator was shown something, and
    # decided. The proxies (lines, elapsed) are worth nothing on their own — they
    # acquire meaning only paired with `grasp`, which is the operator's own
    # report. That pairing is the whole design: it calibrates the cheap automatic
    # numbers against the one direct measurement, and it keeps the agent that
    # produced the output from grading its own legibility.
    #
    # This write does NOT advance the marker. The marker means the work moved;
    # an observation about the reader is not the work moving, and letting it
    # advance would make an item look tended when only its audience was measured.
    #
    # since_touch_h is the gap from the last meaningful touch, not a gate
    # duration. The two coincide only when nothing touched the item between the
    # gate opening and this write — so record the entry BEFORE the status update
    # that closes the item, or the number collapses to zero.
    def add_attention(id, kind:, lines: nil, grasp: nil, now: Time.now)
      raise ArgumentError, "invalid attention kind: #{kind} (#{ATTENTION_KINDS.join('/')})" unless ATTENTION_KINDS.include?(kind)
      unless grasp.nil? || GRASP_LEVELS.include?(grasp)
        raise ArgumentError, "invalid grasp: #{grasp} (#{GRASP_LEVELS.join('/')})"
      end

      item = fetch_item(id)
      entry = {
        'at' => now.utc.iso8601, 'kind' => kind,
        'lines' => ProjectManager.whole_number(lines),
        'grasp' => grasp,
        'since_touch_h' => hours_since_touch(item, now)
      }.compact
      (item['attention'] ||= []) << entry
      save
      entry
    end

    # The operator's declaration of how many judgments the day has room for.
    # Only the declaration is stored; how many actually closed is derived, the
    # same discipline dormancy follows — a stored count would drift the moment
    # an entry was added or an item removed.
    #
    # A record with declared = nil means the question was asked and not answered,
    # which is distinguishable from never having been asked (no record at all).
    def declare_capacity(declared:, date: nil, now: Time.now)
      key = date || now.utc.strftime('%Y-%m-%d')
      raise ArgumentError, "invalid date: #{key} (expected YYYY-MM-DD)" unless key.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      record = {
        'date' => key,
        'declared' => declared.nil? ? nil : ProjectManager.whole_number(declared),
        'recorded_at' => now.utc.iso8601
      }
      @data['attention_days'][key] = record
      save
      record
    end

    def attention_days
      @data['attention_days'].values
    end

    # Every attention entry across all items, each carrying the item it came
    # from, newest last. `since` accepts a Time; an unreadable stored timestamp
    # excludes the entry from a windowed call rather than taking the call down.
    def attention_entries(since: nil)
      items.flat_map do |item|
        (item['attention'] || []).map do |e|
          e.merge('item_id' => item['id'], 'project_id' => item['project_id'])
        end
      end.select do |e|
        next true if since.nil?

        at = ProjectManager.parse_time(e['at'])
        at && at >= since
      end.sort_by { |e| e['at'].to_s }
    end

    def items
      @data['items'].values
    end

    def fetch_item(id)
      @data['items'][id] or raise ArgumentError, "unknown item: #{id}"
    end

    def blocked?(item)
      (item['deps'] || []).any? { |d| !d['resolved'] }
    end

    # Dormancy is derived, never stored (INV-PM-7). A markerless item (nil
    # touched_at, from a markerless migration source) is non-dormant until its
    # first meaningful touch.
    # An unreadable marker is treated the same as a markerless item: non-dormant.
    # The guard belongs here rather than at the call site, because a call site
    # guard is re-acquired by the next caller — see ProjectManager.parse_time.
    def dormant?(item, dormancy_days:, now: Time.now)
      touched = ProjectManager.parse_time(item['touched_at'])
      return false if touched.nil?

      touched < now - (dormancy_days * 86_400)
    end

    def query(project_id: nil, status: nil, salience: nil, assignee: nil,
              blocked: nil, due_within_days: nil, now: Time.now)
      result = items
      result = result.select { |i| i['project_id'] == project_id } if project_id
      result = result.select { |i| i['status'] == status } if status
      result = result.select { |i| i['salience'] == salience } if salience
      result = result.select { |i| i['assignee'] == assignee } if assignee
      result = result.select { |i| blocked?(i) == blocked } unless blocked.nil?
      if due_within_days
        # The window is a caller value too, and it reaches arithmetic rather than
        # Time.parse. A string or a boolean from an unvalidated tool surface would
        # take the whole query down for the same reason a bad marker used to; an
        # unusable window means no window, so the filter does not run.
        days = ProjectManager.whole_number(due_within_days)
        return result if days.nil?

        horizon = now + (days * 86_400)
        # An unreadable deadline is no deadline, so the item drops out of a
        # deadline filter instead of taking the whole query down with it.
        result = result.select do |i|
          due = ProjectManager.parse_time(i['due'])
          due && due <= horizon
        end
      end
      result
    end

    private

    ITEM_ATTR_KEYS = %w[title status salience due review_at assignee notes extra].freeze

    def apply_item_attrs(item, attrs)
      attrs = attrs.transform_keys(&:to_s)
      unknown = attrs.keys - ITEM_ATTR_KEYS
      raise ArgumentError, "unknown item attrs: #{unknown.join(', ')}" unless unknown.empty?

      if attrs.key?('status') && !ITEM_STATUSES.include?(attrs['status'])
        raise ArgumentError, "invalid item status: #{attrs['status']} (#{ITEM_STATUSES.join('/')})"
      end
      if attrs.key?('salience') && !attrs['salience'].nil? && !SALIENCE_LEVELS.include?(attrs['salience'])
        raise ArgumentError, "invalid salience: #{attrs['salience']} (#{SALIENCE_LEVELS.join('/')})"
      end

      attrs.each { |k, v| v.nil? ? item.delete(k) : item[k] = v }
    end

    # An unreadable or absent marker yields nil rather than a fabricated
    # duration, for the reason parsed_time exists: a number nobody can trust is
    # worse than an admitted gap, and this one would be averaged later.
    def hours_since_touch(item, now)
      touched = ProjectManager.parse_time(item['touched_at'])
      return nil if touched.nil?

      ((now - touched) / 3600.0).round(1)
    end

    def generate_id(prefix)
      "#{prefix}_#{SecureRandom.hex(4)}"
    end

    def load_data
      return empty_data unless File.exist?(@path)

      # A store written before attention existed has no such key, and every
      # reader here would meet nil. Filling it on load rather than at each use
      # keeps the guard in one place, the same reason parse_time is not a call-site
      # guard.
      parsed = JSON.parse(File.read(@path))
      parsed.is_a?(Hash) ? empty_data.merge(parsed) : empty_data
    end

    def empty_data
      { 'version' => 1, 'projects' => {}, 'items' => {}, 'attention_days' => {} }
    end

    # The whole write is one unit — generation, mkdir, write, rename. Any failure
    # restores the last state that reached disk and re-raises, so a caller reports
    # a refused write instead of losing one. Before this, a value JSON cannot
    # represent stayed in @data and every later save failed identically, so the
    # store silently accepted nothing while each caller saw only its own error.
    #
    # Rollback discards everything in memory since the last successful save.
    # Store's own mutators each end in save, so that is normally just the
    # offending write — but `items`, `projects` and the fetch_* methods hand out
    # the live hashes, and an edit written straight into one of those is discarded
    # too. Records returned by this class are for reading; go through a mutator to
    # keep a change.
    #
    # The guard belongs here rather than in apply_item_attrs: every writer passes
    # through save, and an attribute-level check would leave project names,
    # provenance entries and attention records unguarded.
    #
    # Two residuals, both raised in review and both left open because no current
    # caller can reach them. Read these before adding a caller that does.
    #
    # 1. Rollback rebuilds @data, so a record handed out earlier by items,
    #    projects or fetch_* is detached from the store afterwards: reads from it
    #    go stale and writes into it reach nothing. Of the three tools that hold
    #    a returned record, only pm_record holds one across a save, and it uses
    #    the id string alone. A caller that keeps a record and edits it after a
    #    refused write would need this to restore in place instead.
    # 2. JSON.parse(@committed) is assumed to succeed. It does, because
    #    @committed is only ever assigned the output of a generate that already
    #    round-tripped, and tool arguments arrive parsed from JSON so no object
    #    with its own to_json can enter. A value reaching @data from Ruby rather
    #    than from a tool could break that.
    def save
      json = nil
      begin
        json = JSON.pretty_generate(@data)
        FileUtils.mkdir_p(File.dirname(@path))
        tmp = "#{@path}.tmp"
        File.write(tmp, json)
        File.rename(tmp, @path)
      rescue StandardError
        @data = JSON.parse(@committed)
        raise
      end
      @committed = json
    end
  end
end
