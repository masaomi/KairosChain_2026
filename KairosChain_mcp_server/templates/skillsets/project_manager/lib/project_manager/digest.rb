# frozen_string_literal: true

require 'time'

require 'project_manager/parsed_time'

module ProjectManager
  # Session-start digest computation (§5 of the frozen design).
  #
  # Buckets:
  # - due:           temporal commitments now due or approaching
  # - awaiting_gate: items paused pending a human decision
  # - dormant:       important items with a stale last-meaningful-touch marker,
  #                  split into :neglected vs :waiting (legitimately blocked /
  #                  awaiting-gate items are surfaced as "still waiting", not as
  #                  neglect — v0.5 §5 disambiguation)
  #
  # Consumers (secretary at session start, Web UI later) are inhabitant concerns;
  # this class only computes the data.
  class Digest
    DEFAULTS = { 'approaching_days' => 7, 'dormancy_days' => 14 }.freeze

    def initialize(store, config = {})
      @store = store
      # The container is guarded before its contents. pm.yml presents `digest:`
      # with two threshold lines under it, so `digest: 14` is a likelier operator
      # typo than a bad threshold, and it used to raise one level above the guard
      # that exists to absorb exactly that mistake. Guarding the values and not
      # the thing that holds them left the promise unkept.
      @config = DEFAULTS.merge(config.is_a?(Hash) ? config : {})
      DEFAULTS.each_key { |k| @config[k] = whole_days(@config[k], DEFAULTS[k]) }
    end

    def compute(now: Time.now)
      open_items = @store.items.reject { |i| %w[done dropped].include?(i['status']) }

      due      = due_bucket(open_items, now)
      gate     = open_items.select { |i| i['status'] == 'awaiting_gate' }
      dormant  = dormant_buckets(open_items, now)

      uncovered = open_items - (due | gate | dormant[:neglected] | dormant[:waiting])

      {
        generated_at: now.utc.iso8601,
        due: due.map { |i| summarize(i, now) },
        awaiting_gate: gate.map { |i| summarize(i, now) },
        dormant_neglected: dormant[:neglected].map { |i| summarize(i, now) },
        dormant_waiting: dormant[:waiting].map { |i| summarize(i, now) },
        uncovered_count: uncovered.size,
        uncovered_stale: stale(uncovered, now).map { |i| summarize(i, now) },
        # Deprecated alias for uncovered_count. The name is wrong: the number mixes
        # work that is genuinely fine with work nobody is watching. Kept so existing
        # consumers do not break; read uncovered_count instead.
        healthy_count: uncovered.size,
        open_count: open_items.size
      }
    end

    private

    # Items outside every bucket that have nonetheless gone untouched past the
    # dormancy threshold. Dormancy proper is computed at high salience only, so
    # without this list a normal- or low-salience item is stale-invisible however
    # long it has sat. Returned in full and oldest first: naming a fixed top-N
    # would omit the same items every day forever, because untouched items advance
    # in lockstep. Id breaks a tie in days so the order is stable, never to cut one.
    #
    # The predicate is the store's own, minus the salience restriction the dormant
    # buckets add. Reimplementing the comparison here would split the definition of
    # "stale enough to name" in two, and an item sitting exactly on the threshold
    # would fall out of dormant_neglected without landing in this list.
    def stale(items, now)
      items.select { |i| dormant?(i, now) }
           .sort_by { |i| [-(days_since(i['touched_at'], now) || 0), i['id'].to_s] }
    end

    # The store's dormancy predicate with this digest's threshold bound in. The
    # unreadable-marker guard lives in the store, not here — see
    # ProjectManager.parse_time for why it may not live at a call site. Every
    # dormancy question in this class goes through this one method, including the
    # high-salience one, so a bad marker cannot take a bucket down either.
    def dormant?(item, now)
      @store.dormant?(item, dormancy_days: @config['dormancy_days'], now: now)
    end

    # An unreadable deadline means the item has no deadline the digest can act
    # on: it leaves this bucket and falls through to uncovered, where it is named
    # once it goes stale. That is the safe direction — the item becomes visible
    # rather than taking every bucket down with it.
    #
    # Sorting on the parsed time rather than the raw string matters for the same
    # reason it matters that the parse happens at all: two deadlines written with
    # different offsets compare wrongly as text.
    def due_bucket(items, now)
      horizon = now + (@config['approaching_days'] * 86_400)
      items.filter_map { |i| [i, ProjectManager.parse_time(i['due'])] if i['due'] }
           .select { |(_, due)| due && due <= horizon }
           .sort_by { |(i, due)| [due, i['id'].to_s] }
           .map(&:first)
    end

    # pm.yml is the one file an operator is invited to edit, and `skillset
    # upgrade` deliberately never overwrites it, so a value left blank or written
    # in quotes must not take the digest down. It falls back to the default the
    # same way an unreadable timestamp falls back to absent: the reader keeps
    # working and the operator sees a report rather than an error string.
    #
    # The coercion itself lives in ProjectManager.whole_number, which documents
    # why it lists the exception classes it does.
    def whole_days(value, default)
      ProjectManager.whole_number(value) || default
    end

    def dormant_buckets(items, now)
      dormant = items.select { |i| i['salience'] == 'high' && dormant?(i, now) }
      waiting, neglected = dormant.partition do |i|
        i['status'] == 'awaiting_gate' || @store.blocked?(i)
      end
      { neglected: neglected, waiting: waiting }
    end

    def summarize(item, now)
      {
        id: item['id'],
        project_id: item['project_id'],
        title: item['title'],
        status: item['status'],
        salience: item['salience'],
        due: item['due'],
        assignee: item['assignee'],
        blocked_on: (item['deps'] || []).reject { |d| d['resolved'] }.map { |d| "#{d['kind']}:#{d['ref']}" },
        # The raw marker travels with the derived figure so the consumer can tell
        # the two ways days_since_touch goes missing apart. No marker at all and
        # a marker that cannot be read are different facts about the store, and
        # the secretary is required to word them differently; without this field
        # both arrive as the same absence and it would have to guess.
        touched_at: item['touched_at'],
        days_since_touch: days_since(item['touched_at'], now)
      }.compact
    end

    def days_since(touched_at, now)
      touched = ProjectManager.parse_time(touched_at)
      return nil if touched.nil?

      ((now - touched) / 86_400).floor
    end
  end
end
