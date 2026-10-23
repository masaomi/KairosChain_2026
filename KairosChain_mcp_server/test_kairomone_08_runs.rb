# frozen_string_literal: true

# Kairomone 0.8, growth runs (design log/kairomone_core_0_8_design_v0.6_FROZEN_20261023.md,
# Inv 2, M6): a run the owner started is the only place autonomy exists; it
# ends once; the operator policy is counted for the whole host. All data is
# synthetic and confined to temporary hosts. run_status(run_id:) reports the
# named run under this_run and leaves the top-level fields to the run that is
# live now (run A review: one key with two meanings).
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'minitest/autorun'
require 'stringio'
require_relative 'templates/skillsets/kairomone/test/support_08'

class Kairomone08RunsTest < Minitest::Test
  include Kairomone08Support

  def setup
    fresh_host
    @now = Time.utc(2026, 10, 23, 12)
    @store = make('alpha')
  end

  def teardown = FileUtils.remove_entry_secure(@host)

  def growth(store = @store) = Kairomone::Autonomy.new(instance: store, clock: -> { @now })

  def evidence
    excerpt = 'Synthetic excerpt.'
    { 'knowledge' => { 'title' => 'Synthesis', 'content' => "Synthetic content #{SecureRandom.hex(4)}" }, 'finding' => 'f',
      'uncertainty' => 'u', 'counterexample' => 'c',
      'sources' => [{ 'url' => 'https://example.com/a', 'title' => 'Fixture', 'retrieved_at' => (@now - 60).iso8601,
                      'excerpt' => excerpt, 'retrieval_reference' => 'fixture', 'excerpt_sha256' => Digest::SHA256.hexdigest(excerpt) }] }
  end

  def start(cycles: nil, end_at: nil, store: @store)
    run = growth(store).run_start(owner_words: 'Synthetic owner words', cycles: cycles, end_at: end_at)
    { run_id: run[:run_id], token: run[:token] }
  end

  def claim_one(step, id, lease: 900, store: @store)
    growth(store).request(**step, request_id: id, topic: "Topic #{id}")
    growth(store).claim(**step, worker_id: 'worker', lease_seconds: lease)['claim_token']
  end

  def run_records(store = @store) = Kairomone::Records.of_type(store.chain, 'kairomone_run')
  def ends(store = @store) = run_records(store).select { |r| r['action'] == 'end' }.map { |r| r['reason'] }

  def write_policy(body)
    FileUtils.mkdir_p(File.join(@host, 'kairomone-policy'))
    File.write(File.join(@host, 'kairomone-policy/policy.json'), body)
  end

  def test_no_claim_before_the_start_record_is_on_the_ledger
    failing = Class.new(Kairomone::AtomicLedgerBackend) do
      def save_all_blocks(blocks)
        last = blocks.last
        data = last.is_a?(Hash) ? (last[:data] || last['data']) : last.data
        raise KairosMcp::Storage::Error, 'simulated failure' if Array(data).any? { |d| d.include?('"kairomone_run"') }
        super
      end
    end.new(storage_dir: File.join(@store.root, 'storage'), blockchain_file: File.join(@store.root, 'storage/blockchain.json'),
            action_log_file: File.join(@store.root, 'storage/action_log.jsonl'))
    blocked = Kairomone::Instance.new(host_root: @host, kairomone: 'alpha', backend: failing)
    assert_raises(Kairomone::Error) { growth(blocked).run_start(owner_words: 'Start', cycles: 1) }
    refute growth.status['live']
    refute File.exist?(File.join(@store.root, 'growth/runs.json'))
    assert_empty run_records
  end

  def test_a_session_without_the_token_cannot_step
    step = start(cycles: 2)
    [nil, 'f' * 48, 'not a token'].each do |token|
      assert_raises(Kairomone::Error) { growth.request(run_id: step[:run_id], token: token, request_id: 'one', topic: 'Topic') }
    end
    claim_token = claim_one(step, 'one')
    assert_raises(Kairomone::Error) { growth.heartbeat(run_id: step[:run_id], token: 'f' * 48, claim_token: claim_token) }
    assert_raises(Kairomone::Error) { growth.commit(run_id: step[:run_id], token: 'f' * 48, claim_token: claim_token, evidence: evidence) }
    assert growth.status['live'], 'a wrong token does not end the run'
    assert_equal 'completed', growth.commit(**step, claim_token: claim_token, evidence: evidence)['state']
  end

  def test_a_one_cycle_run_commits_and_ends
    step = start(cycles: 1)
    token = claim_one(step, 'one')
    assert_equal 'completed', growth.commit(**step, claim_token: token, evidence: evidence)['state']
    refute growth.status['live']
    assert_equal %w[start end], run_records.map { |r| r['action'] }
    assert_equal ['count_reached'], ends
    assert_equal 'Synthetic owner words', run_records.first['owner_words']
    assert_equal({ 'cycles' => 1, 'end_at' => nil }, run_records.first['stop'])
    assert_equal @store.effective_l0_baseline[:baseline], run_records.first['baseline']
  end

  def test_a_count_of_n_admits_n_lets_the_last_finish_and_then_records_the_end
    step = start(cycles: 3)
    2.times do |i|
      token = claim_one(step, "cycle_#{i}")
      growth.commit(**step, claim_token: token, evidence: evidence)
    end
    last = claim_one(step, 'cycle_2')
    assert growth.status['live'], 'the run is live while its last admitted cycle is open'
    assert_raises(Kairomone::Error) { growth.request(**step, request_id: 'cycle_3', topic: 'One too many') }
    assert_empty ends
    assert_equal 'completed', growth.commit(**step, claim_token: last, evidence: evidence)['state']
    assert_equal ['count_reached'], ends
    assert_equal 3, @store.status[:knowledge][:count]
  end

  def test_the_owners_stop_refuses_an_in_flight_commit_and_records_the_end
    step = start(cycles: 5)
    token = claim_one(step, 'one')
    Kairomone::Instance.new(host_root: @host, kairomone: 'alpha').autonomy.run_stop(reason: 'Enough for today')
    assert_raises(Kairomone::Error) { growth.commit(**step, claim_token: token, evidence: evidence) }
    assert_equal ['owner_stop'], ends
    assert_equal 'Enough for today', run_records.last['detail']
    assert_equal 0, @store.status[:knowledge][:count]
  end

  def test_the_end_time_refuses_an_in_flight_commit_and_no_lease_passes_it
    step = start(end_at: (@now + 120).iso8601)
    token = claim_one(step, 'one', lease: 900)
    assert_equal (@now + 120).iso8601, growth.status['active_claim']['expires_at'], 'the lease ends with the run'
    @now += 121
    assert_raises(Kairomone::Error) { growth.commit(**step, claim_token: token, evidence: evidence) }
    assert_equal ['end_time'], ends
    assert_equal 'expired', growth.status['last_result']['state']
  end

  def test_a_host_l0_change_refuses_an_in_flight_commit_and_a_rebaseline_does_not_revive_the_run
    step = start(cycles: 5)
    token = claim_one(step, 'one')
    File.write(File.join(@host, 'skills/kairos.md'), '# synthetic philosophy v2')
    error = assert_raises(Kairomone::Error) { growth.commit(**step, claim_token: token, evidence: evidence) }
    assert_match(/Host L0 differs/, error.message)
    assert_equal ['host_l0_changed'], ends
    assert_raises(Kairomone::Error) { growth.run_start(owner_words: 'Again', cycles: 1) }
    out = StringIO.new
    assert @store.rebaseline_l0_interactive(tty_in: StringIO.new("k7m3xp\n"), tty_out: out, reason: 'synthetic upgrade', nonce: 'k7m3xp')[:recorded]
    assert_includes out.string, 'Kairomone: alpha'
    assert_raises(Kairomone::Error) { growth.request(**step, request_id: 'two', topic: 'Revived?') }
    refute growth.status['live']
    assert_equal ['host_l0_changed'], ends
    fresh = start(cycles: 1)
    refute_equal step[:run_id], fresh[:run_id], 'a new run needs the owner\'s words again'
  end

  def test_an_interrupted_run_start_gets_its_end_recorded
    orphan = { 'type' => 'kairomone_run', 'run_id' => 'run_20261023T115900Z_0badf00d', 'action' => 'start',
               'stop' => { 'cycles' => 1, 'end_at' => nil }, 'owner_words' => 'Interrupted', 'baseline' => {}, 'at' => (@now - 60).iso8601 }
    Kairomone::Records.append!(@store.chain, [orphan], -> { @store.chain })
    status = growth.run_status
    refute status['live']
    assert_equal ['interrupted_start'], ends
    assert_equal 'run_20261023T115900Z_0badf00d', run_records.last['run_id']
    growth.run_status
    assert_equal ['interrupted_start'], ends, 'the end is recorded once'
  end

  def test_a_restore_ends_live_runs_and_the_policy_count_is_not_lowered
    write_policy(JSON.generate('max_claims' => 3, 'window' => 'lifetime'))
    step = start(cycles: 10)
    2.times { |i| growth.fail(**step, claim_token: claim_one(step, "used_#{i}"), reason: 'fixture') }
    backup = @store.create_backup
    @store.restore_backup(file: backup[:file], target_id: 'twin')
    twin = Kairomone::Instance.new(host_root: @host, kairomone: 'twin')
    assert_equal ['restored'], ends(twin)
    assert growth.status['live'], 'the source keeps its run'
    twin_step = start(cycles: 10, store: twin)
    growth(twin).fail(**twin_step, claim_token: claim_one(twin_step, 'third', store: twin), reason: 'fixture')
    error = assert_raises(Kairomone::Error) { claim_one(twin_step, 'fourth', store: twin) }
    assert_match(/admits 3 claims per lifetime/, error.message)
    assert_equal ['restored', 'policy'], ends(twin)
    FileUtils.rm_rf(twin.root)
    assert_raises(Kairomone::Error) { claim_one(step, 'after_delete') }
    assert_equal 3, JSON.parse(File.read(File.join(@host, 'kairomone-policy/counter.json')))['counts']['lifetime'], 'refused claims are not counted; admitted ones never come back'
  end

  def test_a_month_window_counts_per_month
    write_policy(JSON.generate('max_claims' => 1, 'window' => 'month'))
    step = start(cycles: 10)
    growth.fail(**step, claim_token: claim_one(step, 'october'), reason: 'fixture')
    assert_raises(Kairomone::Error) { claim_one(step, 'october_two') }
    @now = Time.utc(2026, 11, 2, 12)
    step = start(cycles: 10)
    assert claim_one(step, 'november')
  end

  def test_an_unreadable_policy_refuses_every_claim
    write_policy('{not json')
    step = start(cycles: 10)
    error = assert_raises(Kairomone::Error) { claim_one(step, 'one') }
    assert_match(/present but unreadable/, error.message)
    assert_equal ['policy'], ends
    write_policy(JSON.generate('max_claims' => 'ten', 'window' => 'month'))
    step = start(cycles: 10)
    assert_raises(Kairomone::Error) { claim_one(step, 'two') }
  end

  def test_more_than_ten_cycles_succeed_without_a_policy
    step = start(cycles: 11)
    11.times do |i|
      token = claim_one(step, "cycle_#{i}")
      payload = evidence
      payload['knowledge']['content'] = "Distinct synthesis #{i}"
      payload['finding'] = "Distinct finding #{i}"
      assert_equal 'completed', growth.commit(**step, claim_token: token, evidence: payload)['state']
    end
    assert_equal 11, @store.status[:knowledge][:count]
    assert_equal 11 * 60, @store.progression_status[:total_xp]
    assert_equal ['count_reached'], ends
    assert_nil growth.status['cycle_limit']
  end

  def test_runs_json_stays_bounded_over_1200_cycles
    step = start(cycles: 1200)
    1200.times do |i|
      growth.fail(**step, claim_token: claim_one(step, "c#{i}"), reason: 'fixture')
      @now += 1
    end
    state = JSON.parse(File.read(File.join(@store.root, 'growth/runs.json')))
    assert_operator state['requests'].length, :<=, Kairomone::Autonomy::REQUESTS_KEEP
    assert_operator File.size(File.join(@store.root, 'growth/runs.json')), :<, 64 * 1024
    assert_equal ['count_reached'], ends
    assert_equal 1200, state['ended'].last['claims']
  end

  def test_an_end_time_without_a_zone_is_refused
    ['2026-10-23T18:00:00', '2026-10-24', '2026-10-23 18:00:00+02:00', '2026-10-23T18:00+02:00'].each do |value|
      error = assert_raises(Kairomone::Error) { growth.run_start(owner_words: 'Until tonight', end_at: value) }
      assert_match(/with a zone/, error.message)
    end
    assert start(end_at: '2026-10-23T15:00:00+02:00')
    assert_equal '2026-10-23T13:00:00Z', run_records.first.dig('stop', 'end_at')
  end

  def test_an_unreadable_counter_refuses_nothing_without_a_policy
    FileUtils.mkdir_p(File.join(@host, 'kairomone-policy'))
    File.write(File.join(@host, 'kairomone-policy/counter.json'), '{broken')
    step = start(cycles: 2)
    assert claim_one(step, 'one'), 'absent policy means unlimited, whatever the counter says'
    assert_equal '{broken', File.read(File.join(@host, 'kairomone-policy/counter.json')), 'the count is never rewritten lower'
    assert growth.status['live']
    write_policy(JSON.generate('max_claims' => 10, 'window' => 'lifetime'))
    step2 = start(cycles: 2, store: make('beta'))
    error = assert_raises(Kairomone::Error) { claim_one(step2, 'two', store: Kairomone::Instance.new(host_root: @host, kairomone: 'beta')) }
    assert_match(/counter is unreadable/, error.message)
  end

  def test_a_restore_records_the_live_runs_claims_only_on_that_run
    orphan = { 'type' => 'kairomone_run', 'run_id' => 'run_20261023T115900Z_0badf00d', 'action' => 'start',
               'stop' => { 'cycles' => 1, 'end_at' => nil }, 'owner_words' => 'Interrupted', 'baseline' => {}, 'at' => (@now - 60).iso8601 }
    step = start(cycles: 5)
    claim_one(step, 'one')
    Kairomone::Records.append!(@store.chain, [orphan], -> { @store.chain })
    backup = @store.create_backup
    @store.restore_backup(file: backup[:file], target_id: 'twin')
    twin = Kairomone::Instance.new(host_root: @host, kairomone: 'twin')
    ended = run_records(twin).select { |r| r['action'] == 'end' }.to_h { |r| [r['run_id'], r] }
    assert_equal 1, ended[step[:run_id]]['claims']
    refute ended['run_20261023T115900Z_0badf00d'].key?('claims')
    assert_equal 'interrupted', growth(twin).status['last_result']['state']
  end

  def test_a_claim_that_cannot_be_recorded_is_not_counted
    write_policy(JSON.generate('max_claims' => 5, 'window' => 'lifetime'))
    step = start(cycles: 3)
    growth.request(**step, request_id: 'orphaned', topic: 'Topic')
    path = File.join(@store.root, 'growth/runs.json')
    state = JSON.parse(File.read(path))
    state['requests'] = []
    File.write(path, JSON.generate(state))
    assert_raises(Kairomone::Error) { growth.claim(**step, worker_id: 'worker') }
    refute File.exist?(File.join(@host, 'kairomone-policy/counter.json')), 'nothing was counted'
  end

  def test_a_commit_that_passed_its_checks_writes_both_entries
    step = start(end_at: (@now + 600).iso8601)
    token = claim_one(step, 'one')
    clock = -> { @now }
    bump = -> { @now += 1200 }
    @store.define_singleton_method(:growth_write!) do |layer, id, raw|
      result = super(layer, id, raw)
      bump.call if layer == 'L2' # the end time passes between the two writes
      result
    end
    assert_equal 'completed', Kairomone::Autonomy.new(instance: @store, clock: clock).commit(**step, claim_token: token, evidence: evidence)['state']
    assert_equal 1, @store.status[:knowledge][:count]
    assert_equal 1, @store.status[:observations][:count]
  end

  def test_run_status_answers_for_a_named_run
    first = start(cycles: 1)
    growth.run_stop(reason: 'Done')
    second = start(cycles: 1)
    named = growth.run_status(run_id: first[:run_id])
    assert_equal({ 'run_id' => first[:run_id], 'live' => false, 'ended' => 'owner_stop', 'ended_at' => named['this_run']['ended_at'] }, named['this_run'])
    assert named['live'], 'the top-level state still describes the run that is live now'
    assert growth.run_status(run_id: second[:run_id])['this_run']['live']
    assert_nil growth.run_status(run_id: 'run_20200101T000000Z_00000000')['this_run']['ended']
  end
end
