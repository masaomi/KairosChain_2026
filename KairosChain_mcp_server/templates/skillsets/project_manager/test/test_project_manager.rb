# frozen_string_literal: true

# Design-constraint tests for the project_manager SkillSet (design v0.5 FROZEN).
# Each test names the invariant it verifies. Run from the skillset root:
#   ruby -Ilib test/test_project_manager.rb

require 'minitest/autorun'
require 'tmpdir'
require 'time'

# Stub the gem module so lib loads without the kairos-chain gem (unit scope).
module KairosMcp
  def self.data_dir = Dir.tmpdir
end

module KairosMcp
  module Tools
    class BaseTool
      def text_content(str) = str
    end
  end
end

require 'project_manager/store'
require 'project_manager/digest'
require 'project_manager/tool_helpers'
require 'json'
load File.expand_path('../tools/pm_digest.rb', __dir__)

class TestProjectManagerStore < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = ProjectManager::Store.new(path: File.join(@dir, 'store.json'))
    @now = Time.utc(2026, 7, 8, 12, 0, 0)
    @prj = @store.register_project(name: 'test project', now: @now)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # INV-PM-7: a routine (operator-meaningful) write advances the marker.
  def test_meaningful_write_advances_marker
    item = @store.add_item(project_id: @prj['id'], title: 'a', now: @now)
    later = @now + 86_400
    updated = @store.update_item(item['id'], { 'status' => 'active' }, now: later)
    assert_equal later.utc.iso8601, updated['touched_at']
  end

  # INV-PM-7: a mechanical (bulk/migration) write does NOT advance the marker.
  def test_mechanical_write_does_not_advance_marker
    item = @store.add_item(project_id: @prj['id'], title: 'a', now: @now)
    original = item['touched_at']
    @store.update_item(item['id'], { 'notes' => 'bulk reformat' }, now: @now + 86_400, mechanical: true)
    assert_equal original, @store.fetch_item(item['id'])['touched_at']
  end

  # INV-PM-6: migration seeding carries the source's own recency (carry, not restamp).
  def test_seeding_carries_source_timestamp
    carried = (@now - 30 * 86_400).utc.iso8601
    item = @store.add_item(project_id: @prj['id'], title: 'migrated', now: @now,
                           mechanical: true, touched_at: carried)
    assert_equal carried, item['touched_at']
  end

  # v0.5 §11 default: a markerless source seeds without a marker and the item is
  # non-dormant until its first meaningful touch.
  def test_markerless_seed_is_non_dormant
    item = @store.add_item(project_id: @prj['id'], title: 'markerless', now: @now, mechanical: true)
    assert_nil item['touched_at']
    refute @store.dormant?(item, dormancy_days: 14, now: @now + 365 * 86_400)
    # first meaningful touch starts the clock
    @store.update_item(item['id'], { 'status' => 'active' }, now: @now)
    assert @store.dormant?(@store.fetch_item(item['id']), dormancy_days: 14, now: @now + 15 * 86_400)
  end

  # INV-PM-7: dormancy is derived from the marker and the threshold.
  def test_dormancy_derivation
    item = @store.add_item(project_id: @prj['id'], title: 'a', now: @now)
    refute @store.dormant?(item, dormancy_days: 14, now: @now + 13 * 86_400)
    assert @store.dormant?(item, dormancy_days: 14, now: @now + 15 * 86_400)
  end

  # INV-PM-7: blocking deps are {item, world_event} only; world-event deps are
  # operator-cleared via resolve_dep.
  def test_blocking_dependency_lifecycle
    item = @store.add_item(project_id: @prj['id'], title: 'a', now: @now)
    @store.add_dep(item['id'], kind: 'world_event', ref: 'sequencing run #42', now: @now)
    assert @store.blocked?(@store.fetch_item(item['id']))
    @store.resolve_dep(item['id'], ref: 'sequencing run #42', now: @now)
    refute @store.blocked?(@store.fetch_item(item['id']))
    assert_raises(ArgumentError) { @store.add_dep(item['id'], kind: 'agent', ref: 'x') }
  end

  # INV-PM-6: a dep added during migration seeding (mechanical) must not restamp
  # the carried marker — found in first real seeding (2026-07-09).
  def test_mechanical_add_dep_does_not_advance_marker
    carried = (@now - 20 * 86_400).utc.iso8601
    item = @store.add_item(project_id: @prj['id'], title: 'seeded with dep', now: @now,
                           mechanical: true, touched_at: carried)
    @store.add_dep(item['id'], kind: 'world_event', ref: 'GmbH incorporation',
                   now: @now, mechanical: true)
    assert_equal carried, @store.fetch_item(item['id'])['touched_at']
    # a normal (operator) add_dep still advances
    @store.add_dep(item['id'], kind: 'world_event', ref: 'second', now: @now)
    assert_equal @now.utc.iso8601, @store.fetch_item(item['id'])['touched_at']
  end

  # INV-PM-7: lifecycle includes awaiting_gate; invalid statuses/salience rejected.
  def test_schema_validation
    item = @store.add_item(project_id: @prj['id'], title: 'a', now: @now)
    @store.update_item(item['id'], { 'status' => 'awaiting_gate' })
    assert_equal 'awaiting_gate', @store.fetch_item(item['id'])['status']
    assert_raises(ArgumentError) { @store.update_item(item['id'], { 'status' => 'review_round' }) }
    assert_raises(ArgumentError) { @store.update_item(item['id'], { 'salience' => 'ember' }) }
    assert_raises(ArgumentError) { @store.update_item(item['id'], { 'sprint' => '3' }) }
  end

  # INV-PM-6: single authoritative store persists and reloads identically.
  def test_store_persistence
    item = @store.add_item(project_id: @prj['id'], title: 'persisted', now: @now, salience: 'high')
    reloaded = ProjectManager::Store.new(path: @store.path)
    assert_equal item, reloaded.fetch_item(item['id'])
  end

  # Query is read-only: filtering never advances any marker.
  def test_query_filters_and_is_readonly
    a = @store.add_item(project_id: @prj['id'], title: 'a', now: @now, salience: 'high')
    @store.add_item(project_id: @prj['id'], title: 'b', now: @now,
                    due: (@now + 3 * 86_400).utc.iso8601)
    before = @store.fetch_item(a['id'])['touched_at']
    assert_equal 1, @store.query(salience: 'high').size
    assert_equal 1, @store.query(due_within_days: 7, now: @now).size
    assert_equal 2, @store.query(project_id: @prj['id']).size
    assert_equal before, @store.fetch_item(a['id'])['touched_at']
  end

  # The deadline filter reads the same unvalidated caller-supplied string the
  # digest does, so it needs the same guard. One unreadable value must not make
  # every deadline query return an error instead of results.
  def test_query_deadline_filter_tolerates_unreadable_deadlines
    @store.add_item(project_id: @prj['id'], title: 'bad', now: @now, due: 'next tuesdayish')
    @store.add_item(project_id: @prj['id'], title: 'integer', mechanical: true,
                    touched_at: @now.utc.iso8601, due: 20_260_701)
    @store.add_item(project_id: @prj['id'], title: 'good', now: @now,
                    due: (@now + 3 * 86_400).utc.iso8601)

    assert_equal ['good'], @store.query(due_within_days: 7, now: @now).map { |i| i['title'] }
  end

  # Time.parse raises three different classes, and enumerating only two is how the
  # first version of the shared guard was still broken. RangeError comes out of
  # Date._parse when a numeric field exceeds C int range, and pm_item can write it.
  def test_parse_time_absorbs_every_reachable_failure
    ['2026-13-99', 'whenever', '', '2026-01-01T00:00:3000000000', '2147483648pm',
     '2026-3000000000-01', 20_260_701, {}, [], true].each do |bad|
      assert_nil ProjectManager.parse_time(bad), "expected nil for #{bad.inspect}"
    end
    assert_nil ProjectManager.parse_time(nil)
    refute_nil ProjectManager.parse_time('2026-07-08T12:00:00Z')
  end

  # The same values must not break the two store paths that read a timestamp.
  def test_store_paths_absorb_out_of_range_timestamps
    huge = @store.add_item(project_id: @prj['id'], title: 'huge marker',
                           mechanical: true, touched_at: '2026-01-01T00:00:3000000000')
    @store.add_item(project_id: @prj['id'], title: 'huge due', now: @now,
                    due: '2026-01-01T00:00:3000000000')
    @store.add_item(project_id: @prj['id'], title: 'good', now: @now,
                    due: (@now + 3 * 86_400).utc.iso8601)

    refute @store.dormant?(huge, dormancy_days: 14, now: @now)
    assert_equal ['good'], @store.query(due_within_days: 7, now: @now).map { |i| i['title'] }
  end

  # pm.yml presents `digest:` with the thresholds nested under it, so `digest: 14`
  # is a likelier typo than a bad threshold — and it used to raise one level above
  # the guard written to absorb exactly that mistake.
  def test_unusable_config_container_falls_back_to_defaults
    @store.add_item(project_id: @prj['id'], title: 'ember',
                    now: @now - 20 * 86_400, salience: 'high')

    [14, 'hello', true, [1], Float::NAN].each do |bad|
      result = ProjectManager::Digest.new(@store, bad).compute(now: @now)
      assert_equal ['ember'], result[:dormant_neglected].map { |i| i[:title] },
                   "digest: #{bad.inspect} should behave as the defaults"
    end
  end

  # secretary.md gained a rule for a marker dated in the future; the digest has to
  # actually produce the negative figure that rule is about.
  def test_future_marker_yields_a_negative_days_figure
    item = @store.add_item(project_id: @prj['id'], title: 'future marker',
                           mechanical: true, touched_at: (@now + 10 * 86_400).utc.iso8601)
    @store.update_item(item['id'], { 'status' => 'awaiting_gate' }, mechanical: true)

    digest = ProjectManager::Digest.new(@store, 'dormancy_days' => 14, 'approaching_days' => 7)
    entry = digest.compute(now: @now)[:awaiting_gate].first
    assert_equal(-10, entry[:days_since_touch])
    refute @store.dormant?(item, dormancy_days: 14, now: @now), 'and it is never dormant'
  end

  # A quoted threshold is the case the coercion exists to accept, and base 10 is
  # what stops "014" from silently becoming 12.
  def test_quoted_threshold_is_read_in_base_ten
    assert_equal 14, ProjectManager.whole_number('014')
    assert_equal 14, ProjectManager.whole_number('14')
    assert_nil ProjectManager.whole_number('0x10')
    assert_nil ProjectManager.whole_number(Float::INFINITY)
    assert_nil ProjectManager.whole_number(Float::NAN)
    assert_nil ProjectManager.whole_number(nil)
  end

  # The day window reaches arithmetic rather than Time.parse, so it needs the
  # same discipline. An unusable window means no window, not a failed query.
  def test_query_tolerates_an_unusable_day_window
    @store.add_item(project_id: @prj['id'], title: 'a', now: @now,
                    due: (@now + 3 * 86_400).utc.iso8601)
    @store.add_item(project_id: @prj['id'], title: 'b', now: @now)

    ['7', 7, nil].each do |good|
      expected = good.nil? ? 2 : 1
      assert_equal expected, @store.query(due_within_days: good, now: @now).size,
                   "window #{good.inspect}"
    end
    ['soon', true, Float::NAN, {}].each do |bad|
      assert_equal 2, @store.query(due_within_days: bad, now: @now).size,
                   "unusable window #{bad.inspect} filters nothing"
    end
  end

  # Dormancy is asked at the store, so the guard belongs at the store. A call-site
  # guard is re-acquired by the next caller.
  def test_dormant_tolerates_unreadable_markers_at_the_source
    bad = @store.add_item(project_id: @prj['id'], title: 'bad marker',
                          mechanical: true, touched_at: '2026-13-99')
    numeric = @store.add_item(project_id: @prj['id'], title: 'numeric marker',
                              mechanical: true, touched_at: 20_260_701)

    refute @store.dormant?(bad, dormancy_days: 14, now: @now)
    refute @store.dormant?(numeric, dormancy_days: 14, now: @now)
  end

  # Assignee is a bare optional slot (unset in the single-operator case).
  def test_assignee_slot
    item = @store.add_item(project_id: @prj['id'], title: 'a', now: @now)
    assert_nil item['assignee']
    @store.update_item(item['id'], { 'assignee' => 'postdoc_x' })
    assert_equal 1, @store.query(assignee: 'postdoc_x').size
  end

  # INV-PM-3 wiring surface: project provenance accepts attestation references.
  def test_project_provenance
    @store.add_project_provenance(@prj['id'], { 'kind' => 'attestation', 'ref' => 'att_123' })
    assert_equal 'att_123', @store.fetch_project(@prj['id'])['provenance'].first['ref']
  end
end

class TestProjectManagerDigest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = ProjectManager::Store.new(path: File.join(@dir, 'store.json'))
    @now = Time.utc(2026, 7, 8, 12, 0, 0)
    @prj = @store.register_project(name: 'p', now: @now)
    @digest = ProjectManager::Digest.new(@store, 'dormancy_days' => 14, 'approaching_days' => 7)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # §5: due bucket catches approaching commitments; done/dropped excluded.
  def test_due_bucket
    @store.add_item(project_id: @prj['id'], title: 'due soon', now: @now,
                    due: (@now + 2 * 86_400).utc.iso8601)
    @store.add_item(project_id: @prj['id'], title: 'far', now: @now,
                    due: (@now + 60 * 86_400).utc.iso8601)
    done = @store.add_item(project_id: @prj['id'], title: 'done', now: @now,
                           due: (@now + 1 * 86_400).utc.iso8601)
    @store.update_item(done['id'], { 'status' => 'done' })
    result = @digest.compute(now: @now)
    assert_equal ['due soon'], result[:due].map { |i| i[:title] }
  end

  # §5 (v0.5): dormant-but-important splits into neglected vs legitimately waiting.
  def test_dormant_split_neglected_vs_waiting
    old = @now - 30 * 86_400
    @store.add_item(project_id: @prj['id'], title: 'neglected ember', now: old, salience: 'high')
    blocked = @store.add_item(project_id: @prj['id'], title: 'waiting on world', now: old, salience: 'high')
    @store.add_dep(blocked['id'], kind: 'world_event', ref: 'reagent', now: old)
    gated = @store.add_item(project_id: @prj['id'], title: 'gated', now: old, salience: 'high')
    @store.update_item(gated['id'], { 'status' => 'awaiting_gate' }, now: old)
    # low-salience dormant item does not surface
    @store.add_item(project_id: @prj['id'], title: 'low', now: old, salience: 'low')

    result = @digest.compute(now: @now)
    assert_equal ['neglected ember'], result[:dormant_neglected].map { |i| i[:title] }
    assert_equal %w[waiting\ on\ world gated].sort,
                 result[:dormant_waiting].map { |i| i[:title] }.sort
  end

  # §5: awaiting_gate items surface regardless of dormancy.
  def test_awaiting_gate_bucket
    fresh = @store.add_item(project_id: @prj['id'], title: 'fresh gate', now: @now)
    @store.update_item(fresh['id'], { 'status' => 'awaiting_gate' }, now: @now)
    result = @digest.compute(now: @now)
    assert_equal ['fresh gate'], result[:awaiting_gate].map { |i| i[:title] }
  end

  # Deadline-free high-salience items surface via dormancy (the Keep-Fire ember
  # case that a deadline-only digest would miss).
  def test_deadline_free_items_surface
    old = @now - 20 * 86_400
    @store.add_item(project_id: @prj['id'], title: 'ember no deadline', now: old, salience: 'high')
    result = @digest.compute(now: @now)
    assert_empty result[:due]
    assert_equal ['ember no deadline'], result[:dormant_neglected].map { |i| i[:title] }
    assert result[:dormant_neglected].first[:days_since_touch] >= 14
  end

  # Ordinary Happiness: the digest counts what fell into no bucket, not only problems.
  # healthy_count is retained as a deprecated alias of uncovered_count.
  def test_uncovered_count
    @store.add_item(project_id: @prj['id'], title: 'fine', now: @now)
    result = @digest.compute(now: @now)
    assert_equal 1, result[:uncovered_count]
    assert_equal 1, result[:healthy_count]
    assert_equal 1, result[:open_count]
    assert_empty result[:uncovered_stale]
  end

  # An item outside every bucket is named once it passes the dormancy threshold,
  # whatever its salience — the hole a count alone left open (itm_e1db3e51).
  def test_uncovered_stale_names_items_below_high_salience
    @store.add_item(project_id: @prj['id'], title: 'fresh', now: @now, salience: 'normal')
    @store.add_item(project_id: @prj['id'], title: 'buried normal',
                    now: @now - 40 * 86_400, salience: 'normal')
    @store.add_item(project_id: @prj['id'], title: 'buried low',
                    now: @now - 90 * 86_400, salience: 'low')

    result = @digest.compute(now: @now)

    assert_empty result[:dormant_neglected], 'dormancy proper stays high-salience only'
    assert_equal 3, result[:uncovered_count]
    # Oldest first, and every stale item named — not a fixed top-N.
    assert_equal ['buried low', 'buried normal'],
                 result[:uncovered_stale].map { |i| i[:title] }
    assert_equal 90, result[:uncovered_stale].first[:days_since_touch]
  end

  # The list and the dormant buckets must share one threshold. An item sitting
  # exactly on it belongs to neither — not to the bucket it just missed, and not
  # to a list the secretary attaches no next step to.
  def test_uncovered_stale_threshold_matches_store_dormancy
    exact = @store.add_item(project_id: @prj['id'], title: 'exactly at threshold',
                            now: @now - 14 * 86_400, salience: 'normal')
    past = @store.add_item(project_id: @prj['id'], title: 'one day past',
                           now: @now - 15 * 86_400, salience: 'normal')

    refute @store.dormant?(exact, dormancy_days: 14, now: @now)
    assert @store.dormant?(past, dormancy_days: 14, now: @now)

    result = @digest.compute(now: @now)
    assert_equal ['one day past'], result[:uncovered_stale].map { |i| i[:title] }
    assert_equal 2, result[:uncovered_count], 'the boundary item is still counted'
  end

  # A markerless or unparseable last-touch marker must not be read as zero days,
  # and must not take the whole digest down with it. Before uncovered_stale
  # existed, only high-salience items ever reached Time.parse.
  def test_uncovered_stale_survives_bad_touch_markers
    @store.add_item(project_id: @prj['id'], title: 'markerless',
                    mechanical: true, touched_at: nil, salience: 'low')
    @store.add_item(project_id: @prj['id'], title: 'malformed',
                    mechanical: true, touched_at: '2026-13-99', salience: 'low')
    # pm_item writes a caller-supplied touched_at through without validation, so
    # the value need not even be a String. Time.parse answers that with TypeError,
    # not ArgumentError.
    @store.add_item(project_id: @prj['id'], title: 'not a string',
                    mechanical: true, touched_at: 20_260_701, salience: 'low')

    zero_threshold = ProjectManager::Digest.new(@store, 'dormancy_days' => 0,
                                                        'approaching_days' => 7)
    [@digest, zero_threshold].each do |digest|
      result = digest.compute(now: @now)
      assert_empty result[:uncovered_stale].map { |i| i[:title] }
      assert_equal 3, result[:uncovered_count], 'all three are still counted'
    end
  end

  # The same guard must cover the high-salience path. A bad marker there used to
  # reach Store#dormant? unguarded and take every bucket down with it.
  def test_bad_touch_marker_on_high_salience_item_does_not_break_buckets
    @store.add_item(project_id: @prj['id'], title: 'malformed high',
                    mechanical: true, touched_at: '2026-13-99', salience: 'high')
    @store.add_item(project_id: @prj['id'], title: 'ember',
                    now: @now - 40 * 86_400, salience: 'high')

    result = @digest.compute(now: @now)
    assert_equal ['ember'], result[:dormant_neglected].map { |i| i[:title] }
    assert_equal 1, result[:uncovered_count]
    assert_empty result[:uncovered_stale]
  end

  # Store#blocked? is reached only for dormant high-salience items, a path the
  # summarize-side deps guard does not cover.
  def test_missing_deps_key_on_dormant_high_salience_item
    @store.add_item(project_id: @prj['id'], title: 'ember no deps',
                    now: @now - 40 * 86_400, salience: 'high')
    @store.items.each { |i| i.delete('deps') }

    result = @digest.compute(now: @now)
    assert_equal ['ember no deps'], result[:dormant_neglected].map { |i| i[:title] }
  end

  # "All, not top-N" is the reason this list exists, so the fixture must be long
  # enough that a plausible truncation would show. Two entries cannot detect one.
  def test_uncovered_stale_names_all_not_a_top_n
    titles = (1..5).map { |n| "buried #{n}" }
    titles.each_with_index do |t, idx|
      @store.add_item(project_id: @prj['id'], title: t,
                      now: @now - (90 - idx * 10) * 86_400, salience: 'low')
    end

    result = @digest.compute(now: @now)
    assert_equal titles, result[:uncovered_stale].map { |i| i[:title] }
    assert_equal 5, result[:uncovered_stale].size
  end

  # Items nobody touches advance in lockstep, so ties are the normal case, not an
  # edge one. Id orders a tie; it must never be used to drop one.
  def test_uncovered_stale_breaks_ties_by_id_without_dropping_any
    same_day = @now - 40 * 86_400
    added = 3.times.map do |n|
      @store.add_item(project_id: @prj['id'], title: "tied #{n}", now: same_day, salience: 'low')
    end
    # Generated ids are random, so insertion order would sometimes already be
    # sorted and the assertion would pass without a tie-break. Pin them to a
    # deliberately unsorted insertion order instead.
    added.zip(%w[itm_ccc itm_aaa itm_bbb]).each { |item, id| item['id'] = id }

    result = @digest.compute(now: @now)
    assert_equal %w[itm_aaa itm_bbb itm_ccc], result[:uncovered_stale].map { |i| i[:id] }
    assert_equal [40], result[:uncovered_stale].map { |i| i[:days_since_touch] }.uniq
  end

  # summarize now runs over uncovered items too, so a record without deps must
  # not raise where it previously was never summarized.
  def test_uncovered_stale_survives_missing_deps_key
    @store.add_item(project_id: @prj['id'], title: 'no deps key',
                    now: @now - 40 * 86_400, salience: 'low')
    @store.items.each { |i| i.delete('deps') }

    result = @digest.compute(now: @now)
    assert_equal ['no deps key'], result[:uncovered_stale].map { |i| i[:title] }
    assert_empty result[:uncovered_stale].first[:blocked_on]
  end

  # A bucketed item is never also reported as uncovered.
  # No marker and an unreadable marker are different facts about the store, and
  # the secretary must word them differently, so the digest has to let it tell.
  def test_summarize_distinguishes_absent_from_unreadable_marker
    absent = @store.add_item(project_id: @prj['id'], title: 'no marker',
                             mechanical: true, touched_at: nil)
    unreadable = @store.add_item(project_id: @prj['id'], title: 'bad marker',
                                 mechanical: true, touched_at: '2026-13-99')
    [absent, unreadable].each { |i| @store.update_item(i['id'], { 'status' => 'awaiting_gate' }, mechanical: true) }

    gate = @digest.compute(now: @now)[:awaiting_gate].to_h { |i| [i[:title], i] }

    refute gate['no marker'].key?(:touched_at), 'no marker at all'
    refute gate['no marker'].key?(:days_since_touch)
    assert_equal '2026-13-99', gate['bad marker'][:touched_at], 'the marker is there'
    refute gate['bad marker'].key?(:days_since_touch), 'but it cannot be read'
  end

  # The deadline bucket claims a stable order, and equal instants are reachable
  # now that it sorts on the parsed time rather than the text.
  def test_due_bucket_breaks_equal_deadlines_by_id
    same = '2026-07-09T00:00:00Z'
    added = 3.times.map do |n|
      @store.add_item(project_id: @prj['id'], title: "due #{n}", now: @now,
                      due: n == 1 ? '2026-07-09T09:00:00+09:00' : same)
    end
    added.zip(%w[itm_ccc itm_aaa itm_bbb]).each { |item, id| item['id'] = id }

    result = @digest.compute(now: @now)
    assert_equal %w[itm_aaa itm_bbb itm_ccc], result[:due].map { |i| i[:id] }
  end

  # pm.yml is operator-owned and upgrade never repairs it, so a blank or quoted
  # threshold must fall back rather than replace the report with an error.
  def test_unusable_config_values_fall_back_to_defaults
    @store.add_item(project_id: @prj['id'], title: 'ember',
                    now: @now - 20 * 86_400, salience: 'high')

    # .inf and .nan are what YAML gives for an operator typo, and Integer answers
    # them with FloatDomainError — a RangeError, not the two classes the first
    # version of this guard listed.
    [nil, 'fourteen', {}, [], Float::INFINITY, -Float::INFINITY, Float::NAN, true].each do |bad|
      digest = ProjectManager::Digest.new(@store, 'dormancy_days' => bad,
                                                  'approaching_days' => bad)
      result = digest.compute(now: @now)
      assert_equal ['ember'], result[:dormant_neglected].map { |i| i[:title] },
                   "dormancy_days #{bad.inspect} should behave as 14"
    end
  end

  # A bad marker on an item that IS bucketed reaches summarize, a path the
  # uncovered_stale guard never covers. Reporting a fabricated "0 days" would be
  # worse than reporting nothing: it reads as touched today.
  def test_bucketed_item_with_bad_marker_reports_no_days_and_does_not_raise
    markerless = @store.add_item(project_id: @prj['id'], title: 'markerless gate',
                                 mechanical: true, touched_at: nil)
    @store.update_item(markerless['id'], { 'status' => 'awaiting_gate' }, mechanical: true)
    @store.add_item(project_id: @prj['id'], title: 'integer marker due',
                    mechanical: true, touched_at: 20_260_701,
                    due: (@now + 2 * 86_400).utc.iso8601)

    result = @digest.compute(now: @now)

    gate = result[:awaiting_gate].first
    due = result[:due].first
    assert_equal 'markerless gate', gate[:title]
    assert_equal 'integer marker due', due[:title]
    refute gate.key?(:days_since_touch), 'a missing marker is absent, never 0'
    refute due.key?(:days_since_touch), 'an unparseable marker is absent, never 0'
  end

  # "Never includes one already in a bucket" must hold for every bucket, not only
  # the dormant one. An old item with a near deadline belongs to due, once.
  def test_uncovered_excludes_due_and_gate_items
    old = @now - 40 * 86_400
    @store.add_item(project_id: @prj['id'], title: 'old but due', now: old,
                    due: (@now + 2 * 86_400).utc.iso8601, salience: 'low')
    gated = @store.add_item(project_id: @prj['id'], title: 'old and gated', now: old, salience: 'low')
    @store.update_item(gated['id'], { 'status' => 'awaiting_gate' }, now: old)

    result = @digest.compute(now: @now)

    assert_equal ['old but due'], result[:due].map { |i| i[:title] }
    assert_equal ['old and gated'], result[:awaiting_gate].map { |i| i[:title] }
    assert_equal 0, result[:uncovered_count], 'neither is counted a second time'
    assert_empty result[:uncovered_stale]
  end

  # A deadline is caller-supplied and unvalidated, exactly like the touch marker.
  # An unreadable one must not take the digest down; the item simply has no
  # deadline the digest can act on, and falls through to uncovered where it is
  # named once stale. Guarding the marker and not its twin would have left the
  # same defect standing one method away.
  def test_unreadable_due_does_not_break_the_digest
    old = @now - 40 * 86_400
    %w[2026-13-99 whenever].each_with_index do |bad, n|
      @store.add_item(project_id: @prj['id'], title: "bad due #{n}", now: old,
                      due: bad, salience: 'low')
    end
    @store.add_item(project_id: @prj['id'], title: 'integer due', mechanical: true,
                    touched_at: (@now - 40 * 86_400).utc.iso8601, due: 20_260_701)
    @store.add_item(project_id: @prj['id'], title: 'real deadline', now: @now,
                    due: (@now + 2 * 86_400).utc.iso8601)

    result = @digest.compute(now: @now)

    assert_equal ['real deadline'], result[:due].map { |i| i[:title] }
    assert_equal 3, result[:uncovered_count], 'the three unreadable deadlines fall through'
    assert_equal ['bad due 0', 'bad due 1', 'integer due'].sort,
                 result[:uncovered_stale].map { |i| i[:title] }.sort
  end

  # Deadlines written with different offsets compare wrongly as text.
  def test_due_bucket_sorts_by_parsed_time_not_raw_string
    # 2026-07-09T00:00+09:00 is 2026-07-08T15:00Z, so it falls due BEFORE the Z
    # one — but as text it sorts after it. Raw-string order puts them backwards.
    @store.add_item(project_id: @prj['id'], title: 'earlier', now: @now,
                    due: '2026-07-09T00:00:00+09:00')
    @store.add_item(project_id: @prj['id'], title: 'later', now: @now,
                    due: '2026-07-08T20:00:00Z')

    result = ProjectManager::Digest.new(@store, 'dormancy_days' => 14, 'approaching_days' => 30)
                                   .compute(now: @now)
    assert_equal %w[earlier later], result[:due].map { |i| i[:title] }
  end

  # pm_item update deletes any field passed as nil, title included, so an entry
  # can arrive without one. It must still be reportable rather than a bare id.
  def test_uncovered_stale_entry_can_lack_a_title
    @store.add_item(project_id: @prj['id'], title: 'will lose its title',
                    now: @now - 40 * 86_400, salience: 'low')
    @store.items.each { |i| i.delete('title') }

    result = @digest.compute(now: @now)
    entry = result[:uncovered_stale].first
    refute entry.key?(:title), 'a deleted title is absent, never invented'
    assert entry[:id], 'the id is still there to act on'
    assert_equal 40, entry[:days_since_touch]
  end

  def test_uncovered_excludes_bucketed_items
    old = @now - 40 * 86_400
    @store.add_item(project_id: @prj['id'], title: 'ember', now: old, salience: 'high')
    # dormant_waiting is a bucket too, and it is the one an author is likeliest to
    # forget in the subtraction because it is reached through a partition.
    blocked = @store.add_item(project_id: @prj['id'], title: 'waiting on world',
                              now: old, salience: 'high')
    @store.add_dep(blocked['id'], kind: 'world_event', ref: 'reagent', now: old)

    result = @digest.compute(now: @now)
    assert_equal ['ember'], result[:dormant_neglected].map { |i| i[:title] }
    assert_equal ['waiting on world'], result[:dormant_waiting].map { |i| i[:title] }
    assert_equal 0, result[:uncovered_count], 'neither dormant bucket leaks into uncovered'
    assert_empty result[:uncovered_stale]
  end
end

# The tool is the only path an agent actually takes, and it builds the config
# container itself. Guarding Digest was not enough: the tool wrote overrides into
# a scalar `digest:` one step upstream of that guard. These drive the real
# PmDigest#call rather than Digest directly.
class TestPmDigestToolConfigPath < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = ProjectManager::Store.new(path: File.join(@dir, 'store.json'))
    @now = Time.utc(2026, 7, 8, 12, 0, 0)
    prj = @store.register_project(name: 'p', now: @now)
    @store.add_item(project_id: prj['id'], title: 'ember',
                    now: @now - 40 * 86_400, salience: 'high')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def tool(pm_config_value)
    t = KairosMcp::SkillSets::ProjectManagerSkillSet::Tools::PmDigest.allocate
    store = @store
    t.define_singleton_method(:pm_config) { pm_config_value }
    t.define_singleton_method(:pm_store) { store }
    t
  end

  # pm.yml presents `digest:` with the thresholds nested under it, so a scalar
  # there is a plausible typo — and it is exactly what used to raise.
  def test_scalar_digest_key_survives_an_override_argument
    [14, 'hello', true, [1], nil].each do |bad|
      out = JSON.parse(tool({ 'digest' => bad }).call({ 'dormancy_days' => 3 }))
      refute out.key?('error'), "digest: #{bad.inspect} produced #{out['error'].inspect}"
      assert_equal 1, out['dormant_neglected'].size
    end
  end

  # And the level above it: pm.yml itself not being a mapping.
  def test_non_mapping_pm_config_survives
    [42, 'nonsense', [1], nil].each do |bad|
      out = JSON.parse(tool(bad).call({}))
      refute out.key?('error'), "pm_config #{bad.inspect} produced #{out['error'].inspect}"
      assert_equal 1, out['dormant_neglected'].size
    end
  end

  # A usable config must still be honoured, not silently discarded by the guard.
  def test_usable_config_is_still_read
    out = JSON.parse(tool({ 'digest' => { 'dormancy_days' => 100 } }).call({}))
    assert_empty out['dormant_neglected'], 'a 100-day threshold hides a 40-day ember'
    out = JSON.parse(tool({ 'digest' => { 'dormancy_days' => 100 } }).call({ 'dormancy_days' => 3 }))
    assert_equal 1, out['dormant_neglected'].size, 'and an override still wins'
  end
end

load File.expand_path('../tools/pm_item.rb', __dir__)

# Attention record (2026-08-07). The record exists to calibrate the cheap
# automatic numbers — length, elapsed — against the one direct measurement, the
# operator's own report. Every test here defends that pairing or the honesty of
# a number that would otherwise be averaged later.
class TestProjectManagerAttention < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, 'store.json')
    @store = ProjectManager::Store.new(path: @path)
    @now = Time.utc(2026, 8, 7, 12, 0, 0)
    @prj = @store.register_project(name: 'p', now: @now)
    @item = @store.add_item(project_id: @prj['id'], title: 'a', now: @now)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_entry_appends_and_keeps_the_operator_report_verbatim
    @store.add_attention(@item['id'], kind: 'review', lines: 148, grasp: 'unclear', now: @now)
    @store.add_attention(@item['id'], kind: 'decide', lines: 62, grasp: 'once', now: @now)
    entries = @store.fetch_item(@item['id'])['attention']
    assert_equal 2, entries.size
    assert_equal %w[unclear once], entries.map { |e| e['grasp'] }
    assert_equal [148, 62], entries.map { |e| e['lines'] }
  end

  def test_invalid_kind_and_grasp_are_refused
    assert_raises(ArgumentError) { @store.add_attention(@item['id'], kind: 'skim', now: @now) }
    assert_raises(ArgumentError) { @store.add_attention(@item['id'], kind: 'read', grasp: 'tired', now: @now) }
  end

  # Declining to answer is evidence of load. Dropping it as missing data would
  # bias the record toward the occasions the operator had energy to spare.
  def test_no_answer_is_stored_as_a_value
    @store.add_attention(@item['id'], kind: 'read', grasp: 'no_answer', now: @now)
    assert_equal 'no_answer', @store.fetch_item(@item['id'])['attention'].first['grasp']
  end

  # The marker means the work moved. Measuring the audience is not the work moving.
  def test_attention_write_does_not_advance_the_marker
    before = @store.fetch_item(@item['id'])['touched_at']
    @store.add_attention(@item['id'], kind: 'decide', grasp: 'once', now: @now + 86_400)
    assert_equal before, @store.fetch_item(@item['id'])['touched_at']
  end

  def test_since_touch_measures_from_the_marker
    entry = @store.add_attention(@item['id'], kind: 'decide', grasp: 'once', now: @now + (26 * 3600))
    assert_in_delta 26.0, entry['since_touch_h'], 0.05
  end

  # A duration nobody can trust is worse than an admitted gap: it gets averaged.
  def test_unreadable_marker_yields_no_duration_rather_than_a_fabricated_one
    @store.update_item(@item['id'], { 'notes' => 'x' }, now: @now)
    @store.fetch_item(@item['id'])['touched_at'] = 'not a time'
    entry = @store.add_attention(@item['id'], kind: 'read', grasp: 'once', now: @now)
    refute entry.key?('since_touch_h')
  end

  # Append-only: the array is not reachable through the ordinary attribute path.
  def test_attention_cannot_be_overwritten_through_update
    @store.add_attention(@item['id'], kind: 'read', grasp: 'once', now: @now)
    assert_raises(ArgumentError) { @store.update_item(@item['id'], { 'attention' => [] }) }
    assert_equal 1, @store.fetch_item(@item['id'])['attention'].size
  end

  def test_entries_carry_their_item_and_honour_a_window
    other = @store.add_item(project_id: @prj['id'], title: 'b', now: @now)
    @store.add_attention(@item['id'], kind: 'read', grasp: 'once', now: @now)
    @store.add_attention(other['id'], kind: 'decide', grasp: 'reread', now: @now + 7200)
    all = @store.attention_entries
    assert_equal [@item['id'], other['id']], all.map { |e| e['item_id'] }
    assert_equal 1, @store.attention_entries(since: @now + 3600).size
  end

  # An unreadable timestamp excludes the entry from a windowed call instead of
  # taking the call down, the discipline parse_time exists for.
  def test_unreadable_entry_timestamp_does_not_break_a_windowed_read
    @store.add_attention(@item['id'], kind: 'read', grasp: 'once', now: @now)
    @store.fetch_item(@item['id'])['attention'].first['at'] = 'not a time'
    assert_empty @store.attention_entries(since: @now - 3600)
    assert_equal 1, @store.attention_entries.size
  end

  # Asked-and-unanswered must stay distinguishable from never-asked.
  def test_unanswered_capacity_is_a_record_with_no_number
    assert_empty @store.attention_days
    @store.declare_capacity(declared: nil, now: @now)
    day = @store.attention_days.first
    assert_equal '2026-08-07', day['date']
    assert_nil day['declared']
    @store.declare_capacity(declared: 3, now: @now)
    assert_equal 3, @store.attention_days.first['declared']
  end

  def test_malformed_capacity_date_is_refused_rather_than_becoming_a_key
    assert_raises(ArgumentError) { @store.declare_capacity(declared: 3, date: 'yesterday') }
    assert_empty @store.attention_days
  end

  # A store written before attention existed has no such key.
  def test_a_store_from_before_attention_still_loads_and_accepts_a_declaration
    legacy = File.join(@dir, 'legacy.json')
    File.write(legacy, JSON.generate({ 'version' => 1, 'projects' => {}, 'items' => {} }))
    store = ProjectManager::Store.new(path: legacy)
    assert_empty store.attention_days
    store.declare_capacity(declared: 2, now: @now)
    assert_equal 2, ProjectManager::Store.new(path: legacy).attention_days.first['declared']
  end

  def test_tool_records_both_shapes
    tool = KairosMcp::SkillSets::ProjectManagerSkillSet::Tools::PmItem.new
    tool.define_singleton_method(:pm_store) { @injected }
    tool.instance_variable_set(:@injected, @store)

    out = JSON.parse(tool.call({ 'command' => 'attention', 'id' => @item['id'],
                                 'att_kind' => 'review', 'lines' => 148, 'grasp' => 'unclear' }))
    assert_equal 'unclear', out['grasp']

    out = JSON.parse(tool.call({ 'command' => 'capacity', 'declared' => 3, 'date' => '2026-08-07' }))
    assert_equal 3, out['declared']

    out = JSON.parse(tool.call({ 'command' => 'attention', 'id' => @item['id'], 'att_kind' => 'skim' }))
    assert_match(/invalid attention kind/, out['error'])
  end
end

# The write side (2026-08-18). Every guard in this SkillSet used to sit on the
# reading side — parse_time, whole_number, the config containers — and a value
# that cannot be turned into JSON walked straight past all of them. Generation
# failed before File.write, so the file survived and @data did not: the bad value
# stayed in memory and every later save failed identically, which read to the
# caller as one error and to the store as a permanent refusal to record anything.
class TestProjectManagerStoreWriteGuard < Minitest::Test
  # Valid Ruby strings and numbers that JSON cannot represent. Both arrive
  # through ordinary tool arguments; neither is caught by the status/salience
  # enum checks, which are the only write-side validation that existed.
  LONE_SURROGATE = "bad\xED\xA0\x80title".dup.force_encoding('UTF-8')

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, 'store.json')
    @store = ProjectManager::Store.new(path: @path)
    @now = Time.utc(2026, 8, 18, 12, 0, 0)
    @prj = @store.register_project(name: 'p', now: @now)
    @kept = @store.add_item(project_id: @prj['id'], title: 'kept', now: @now)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def on_disk
    JSON.parse(File.read(@path))
  end

  def test_an_unwritable_title_is_refused_rather_than_written
    assert_raises(JSON::GeneratorError) do
      @store.add_item(project_id: @prj['id'], title: LONE_SURROGATE, now: @now)
    end
  end

  # The defect proper: not that the bad write failed, but that every good write
  # after it failed too, on disk and in memory, without anything saying so.
  def test_the_store_still_accepts_writes_after_a_refused_one
    begin
      @store.add_item(project_id: @prj['id'], title: LONE_SURROGATE, now: @now)
    rescue JSON::GeneratorError
      nil
    end

    later = @store.add_item(project_id: @prj['id'], title: 'written after', now: @now)
    assert_equal 'written after', @store.fetch_item(later['id'])['title']
    assert_equal 2, on_disk['items'].size, 'the good writes reached disk'
    assert_equal %w[kept written\ after].sort,
                 on_disk['items'].values.map { |i| i['title'] }.sort
  end

  # A refused write must not survive in memory either, or a reader counts items
  # that were never recorded — which is how the digest reported phantom work.
  def test_a_refused_write_leaves_nothing_behind_in_memory
    begin
      @store.add_item(project_id: @prj['id'], title: LONE_SURROGATE, now: @now)
    rescue JSON::GeneratorError
      nil
    end

    assert_equal 1, @store.items.size
    assert_equal 'kept', @store.items.first['title']
    refute_includes @store.items.map { |i| i['title'] }, LONE_SURROGATE
  end

  # Infinity reaches JSON through any numeric field and fails generation the same
  # way. Different value, same path, so it must be refused by the same guard
  # rather than by a check written for strings.
  def test_an_unrepresentable_number_is_refused_the_same_way
    assert_raises(JSON::GeneratorError) do
      @store.update_item(@kept['id'], { 'notes' => Float::INFINITY }, now: @now)
    end
    assert_equal 1, @store.items.size
    @store.update_item(@kept['id'], { 'notes' => 'fine' }, now: @now)
    assert_equal 'fine', on_disk['items'][@kept['id']]['notes']
  end

  # Rolling back restores @committed, which advances only after a write finishes.
  # An earlier write that had been accepted must therefore survive the rollback of
  # a later refused one.
  def test_rollback_does_not_discard_an_earlier_accepted_write
    @store.update_item(@kept['id'], { 'salience' => 'high' }, now: @now)
    begin
      @store.add_item(project_id: @prj['id'], title: LONE_SURROGATE, now: @now)
    rescue JSON::GeneratorError
      nil
    end
    assert_equal 'high', @store.fetch_item(@kept['id'])['salience']
    assert_equal 'high', on_disk['items'][@kept['id']]['salience']
  end

  # A failure after generation — no space, a read-only directory, a rename that
  # cannot complete — leaves the same poisoned @data as a generation failure did.
  # Guarding only generation would let a write reported as failed reappear in the
  # next successful save.
  def test_a_failure_after_generation_rolls_back_too
    File.chmod(0o500, @dir)
    begin
      assert_raises(SystemCallError) do
        @store.add_item(project_id: @prj['id'], title: 'never written', now: @now)
      end
    ensure
      File.chmod(0o700, @dir)
    end

    assert_equal 1, @store.items.size, 'the refused write stayed in memory'
    refute_includes @store.items.map { |i| i['title'] }, 'never written'
    @store.add_item(project_id: @prj['id'], title: 'after', now: @now)
    assert_equal %w[after kept], on_disk['items'].values.map { |i| i['title'] }.sort
  end

  # Rollback restores from an in-memory copy of the last written state, not from
  # the file. Re-reading would fail exactly when it is needed most — a store.json
  # that has become unreadable would leave the bad value in place and wedge the
  # process, which is the defect this guard exists to remove.
  def test_rollback_survives_an_unreadable_file_on_disk
    File.write(@path, 'not json at all')
    begin
      @store.add_item(project_id: @prj['id'], title: LONE_SURROGATE, now: @now)
    rescue JSON::GeneratorError
      nil
    end
    assert_equal 1, @store.items.size
    assert_equal 'kept', @store.items.first['title']
  end

  # Honest boundary, pinned so it cannot be quietly claimed otherwise: rollback
  # drops everything in memory since the last successful save, and the fetch_*
  # methods hand out the live hash, so an edit written straight into one is
  # dropped as well. Go through a mutator to keep a change.
  def test_an_edit_written_straight_into_a_returned_record_is_discarded
    @store.fetch_item(@kept['id'])['assignee'] = 'written behind the mutators'
    begin
      @store.add_item(project_id: @prj['id'], title: LONE_SURROGATE, now: @now)
    rescue JSON::GeneratorError
      nil
    end
    refute @store.fetch_item(@kept['id']).key?('assignee'),
           'the direct edit survived a rollback the comment says discards it'
  end

  # The guard sits in save, not in the item attribute path, so writes that never
  # touch an item attribute are covered too.
  def test_a_project_name_is_covered_by_the_same_guard
    assert_raises(JSON::GeneratorError) do
      @store.update_project(@prj['id'], { 'name' => LONE_SURROGATE }, now: @now)
    end
    assert_equal 'p', @store.fetch_project(@prj['id'])['name']
    @store.update_project(@prj['id'], { 'name' => 'renamed' }, now: @now)
    assert_equal 'renamed', on_disk['projects'][@prj['id']]['name']
  end
end

load File.expand_path('../tools/pm_record.rb', __dir__)

# pm.yml is the only file an operator is invited to edit and `skillset upgrade`
# never repairs it, so a bad edit is permanent. safe_load_file is strict and the
# raise landed above every guard the tools carry, so one stray tab returned an
# error from every pm tool at once.
class TestPmConfigReadGuard < Minitest::Test
  # Ordinary edits, each measured to raise a different Psych error.
  BAD_YAML = {
    'tab indent' => "digest:\n\tapproaching_days: 7\n",
    'unclosed quote' => "digest:\n  approaching_days: 'oops\n",
    'bare date' => "when: 2026-08-18\n",
    'anchor and alias' => "a: &x 1\nb: *x\n",
    'symbol' => "k: :sym\n"
  }.freeze

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, 'pm.yml')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # A fresh host each time: pm_config memoises, which is the point of it.
  def host(write: nil)
    File.write(@path, write) unless write.nil?
    path = @path
    obj = Object.new
    obj.extend(ProjectManager::ToolHelpers)
    obj.define_singleton_method(:pm_config_path) { path }
    obj
  end

  def test_an_unreadable_file_falls_back_to_defaults_instead_of_raising
    BAD_YAML.each do |label, body|
      h = host(write: body)
      assert_equal({}, h.pm_config, "#{label} did not fall back")
      refute_nil h.pm_config_error, "#{label} fell back without saying why"
    end
  end

  # Falling back silently would hand the operator thresholds nobody chose and
  # call them settings. The reason has to name the failure, not just exist.
  def test_the_reason_names_the_failure
    assert_match(/Psych::SyntaxError/, host(write: BAD_YAML['tab indent']).pm_config_error)
    assert_match(/Psych::DisallowedClass/, host(write: BAD_YAML['bare date']).pm_config_error)
  end

  # A document that parses but is not a mapping breaks the first caller that
  # subscripts it — pm_record has no guard of its own.
  def test_a_non_mapping_document_is_coerced_and_reported
    ['just a string', "- 1\n- 2\n", '42'].each do |body|
      h = host(write: body)
      assert_equal({}, h.pm_config, "#{body.inspect} was not coerced")
      refute_nil h.pm_config_error, "#{body.inspect} was coerced silently"
    end
  end

  def test_an_absent_or_empty_file_is_not_a_failure
    assert_equal({}, host.pm_config)
    assert_nil host.pm_config_error, 'an absent file is the documented default'

    # All three parse to nil, so emptiness is recognised by the parse result and
    # nothing else has to be exempted from the non-mapping report.
    ['', "\n", "# only a comment\n"].each do |body|
      h = host(write: body)
      assert_equal({}, h.pm_config)
      assert_nil h.pm_config_error, "#{body.inspect} is the operator saying \"no settings\""
    end
  end

  # `false` parses, is not a mapping, and is not emptiness. Exempting it would
  # hand back defaults with nothing said — the failure this guard exists to stop.
  def test_a_literal_false_is_reported_rather_than_read_as_emptiness
    h = host(write: "false\n")
    assert_equal({}, h.pm_config)
    refute_nil h.pm_config_error, 'literal false was swallowed as "no settings"'
    assert_match(/FalseClass/, h.pm_config_error)
  end

  # The guard must not eat a good file: the shipped pm.yml has to survive it.
  def test_a_usable_file_is_read_and_reports_nothing
    h = host(write: "digest:\n  dormancy_days: 30\nrecord_ttl_seconds: 99\n")
    assert_equal 30, h.pm_config['digest']['dormancy_days']
    assert_equal 99, h.pm_config['record_ttl_seconds']
    assert_nil h.pm_config_error
  end

  def test_the_shipped_pm_yml_is_readable
    shipped = File.expand_path('../config/pm.yml', __dir__)
    h = host
    h.define_singleton_method(:pm_config_path) { shipped }
    assert_nil h.pm_config_error, 'the file this SkillSet ships must pass its own guard'
    assert_equal 14, h.pm_config['digest']['dormancy_days']
  end

  # The tool is the path an agent actually takes. It must answer, and it must
  # carry the reason rather than presenting defaults as the operator's settings.
  def test_the_digest_tool_answers_and_carries_the_reason
    dir = Dir.mktmpdir
    store = ProjectManager::Store.new(path: File.join(dir, 'store.json'))
    prj = store.register_project(name: 'p', now: Time.utc(2026, 8, 18))
    store.add_item(project_id: prj['id'], title: 'ember',
                   now: Time.utc(2026, 8, 18) - (40 * 86_400), salience: 'high')

    File.write(@path, BAD_YAML['tab indent'])
    path = @path
    t = KairosMcp::SkillSets::ProjectManagerSkillSet::Tools::PmDigest.allocate
    t.define_singleton_method(:pm_config_path) { path }
    t.define_singleton_method(:pm_store) { store }

    out = JSON.parse(t.call({}))
    refute out.key?('error'), "an unreadable pm.yml still took the tool down: #{out['error'].inspect}"
    assert_equal 1, out['dormant_neglected'].size, 'the defaults still produced a digest'
    assert_match(/Psych::SyntaxError/, out['config_error'].to_s)
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_the_digest_tool_says_nothing_when_the_file_is_fine
    dir = Dir.mktmpdir
    store = ProjectManager::Store.new(path: File.join(dir, 'store.json'))
    store.register_project(name: 'p', now: Time.utc(2026, 8, 18))

    File.write(@path, "digest:\n  dormancy_days: 14\n")
    path = @path
    t = KairosMcp::SkillSets::ProjectManagerSkillSet::Tools::PmDigest.allocate
    t.define_singleton_method(:pm_config_path) { path }
    t.define_singleton_method(:pm_store) { store }

    out = JSON.parse(t.call({}))
    refute out.key?('config_error'), 'a healthy file must not be reported as ignored'
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  # pm_record reads the record ttl from the same file, and its records are meant
  # to be permanent. A silent default there would tell an operator who shortened
  # the ttl that their value was applied when it was not.
  def record_tool(store)
    path = @path
    t = KairosMcp::SkillSets::ProjectManagerSkillSet::Tools::PmRecord.allocate
    t.define_singleton_method(:pm_config_path) { path }
    t.define_singleton_method(:pm_store) { store }
    t.define_singleton_method(:issue_attestation) { |_project, _args| { proof_id: 'proof_1' } }
    t
  end

  def test_the_record_tool_carries_the_reason
    dir = Dir.mktmpdir
    store = ProjectManager::Store.new(path: File.join(dir, 'store.json'))
    prj = store.register_project(name: 'p', now: Time.utc(2026, 8, 18))

    File.write(@path, BAD_YAML['bare date'])
    out = JSON.parse(record_tool(store).call({ 'project_id' => prj['id'],
                                               'action' => 'shipped', 'summary' => 's' }))
    refute out.key?('error'), "an unreadable pm.yml took pm_record down: #{out['error'].inspect}"
    assert_equal true, out['recorded']
    assert_match(/Psych::DisallowedClass/, out['config_error'].to_s)
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_the_record_tool_says_nothing_when_the_file_is_fine
    dir = Dir.mktmpdir
    store = ProjectManager::Store.new(path: File.join(dir, 'store.json'))
    prj = store.register_project(name: 'p', now: Time.utc(2026, 8, 18))

    File.write(@path, "record_ttl_seconds: 99\n")
    out = JSON.parse(record_tool(store).call({ 'project_id' => prj['id'],
                                               'action' => 'shipped', 'summary' => 's' }))
    refute out.key?('config_error'), 'a healthy file must not be reported as ignored'
  ensure
    FileUtils.remove_entry(dir) if dir
  end
end
