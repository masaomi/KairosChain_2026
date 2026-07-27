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

require 'project_manager/store'
require 'project_manager/digest'

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

  # Ordinary Happiness: the digest reports healthy counts, not only problems.
  def test_healthy_count
    @store.add_item(project_id: @prj['id'], title: 'healthy', now: @now)
    result = @digest.compute(now: @now)
    assert_equal 1, result[:healthy_count]
    assert_equal 1, result[:open_count]
  end
end
