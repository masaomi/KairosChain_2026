# frozen_string_literal: true

require 'time'

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
      @config = DEFAULTS.merge(config || {})
    end

    def compute(now: Time.now)
      open_items = @store.items.reject { |i| %w[done dropped].include?(i['status']) }

      due      = due_bucket(open_items, now)
      gate     = open_items.select { |i| i['status'] == 'awaiting_gate' }
      dormant  = dormant_buckets(open_items, now)

      {
        generated_at: now.utc.iso8601,
        due: due.map { |i| summarize(i, now) },
        awaiting_gate: gate.map { |i| summarize(i, now) },
        dormant_neglected: dormant[:neglected].map { |i| summarize(i, now) },
        dormant_waiting: dormant[:waiting].map { |i| summarize(i, now) },
        healthy_count: open_items.size - (due | gate | dormant[:neglected] | dormant[:waiting]).size,
        open_count: open_items.size
      }
    end

    private

    def due_bucket(items, now)
      horizon = now + (@config['approaching_days'] * 86_400)
      items.select { |i| i['due'] && Time.parse(i['due']) <= horizon }
           .sort_by { |i| i['due'] }
    end

    def dormant_buckets(items, now)
      dormant = items.select do |i|
        i['salience'] == 'high' &&
          @store.dormant?(i, dormancy_days: @config['dormancy_days'], now: now)
      end
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
        blocked_on: item['deps'].reject { |d| d['resolved'] }.map { |d| "#{d['kind']}:#{d['ref']}" },
        days_since_touch: days_since(item['touched_at'], now)
      }.compact
    end

    def days_since(touched_at, now)
      return nil if touched_at.nil?

      ((now - Time.parse(touched_at)) / 86_400).floor
    end
  end
end
