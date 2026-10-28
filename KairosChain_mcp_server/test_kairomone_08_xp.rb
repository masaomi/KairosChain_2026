# frozen_string_literal: true

# Kairomone 0.8, XP identity (design log/kairomone_core_0_8_design_v0.6_FROZEN_20261023.md,
# Inv 3, M5): identity records on the ledger, the 0.6 rule and its backfill,
# the chat-receipt rule, not-counted entries and what they hold. All data is
# synthetic and confined to temporary hosts.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'minitest/autorun'
require_relative 'templates/skillsets/kairomone/test/support_08'

class Kairomone08XpTest < Minitest::Test
  include Kairomone08Support

  def setup = fresh_host
  def teardown = FileUtils.remove_entry_secure(@host)

  EVIDENCE_061 = <<~'RUBY'
    excerpt = 'Synthetic excerpt for a 0.6.1 cycle.'
    evidence = { 'knowledge' => { 'title' => 'Old synthesis', 'content' => 'Synthesis an earlier Kairomone stored' },
                 'finding' => 'Old finding', 'uncertainty' => 'Old uncertainty', 'counterexample' => 'Old counterexample',
                 'sources' => [{ 'url' => 'https://example.com/old', 'title' => 'Fixture', 'retrieved_at' => '2026-10-01T00:00:00Z',
                                 'excerpt' => excerpt, 'retrieval_reference' => 'fixture', 'excerpt_sha256' => Digest::SHA256.hexdigest(excerpt) }] }
  RUBY

  def evidence(content: 'Synthetic content', finding: 'f')
    excerpt = 'Synthetic excerpt.'
    { 'knowledge' => { 'title' => 'Synthesis', 'content' => content }, 'finding' => finding, 'uncertainty' => 'u', 'counterexample' => 'c',
      'sources' => [{ 'url' => 'https://example.com/a', 'title' => 'Fixture', 'retrieved_at' => Time.now.utc.iso8601,
                      'excerpt' => excerpt, 'retrieval_reference' => 'fixture', 'excerpt_sha256' => Digest::SHA256.hexdigest(excerpt) }] }
  end

  def one_cycle(store, id, payload = evidence)
    growth = store.autonomy
    run = growth.run_start(owner_words: 'One cycle', cycles: 1)
    step = { run_id: run[:run_id], token: run[:token] }
    growth.request(**step, request_id: id, topic: 'Topic')
    claim = growth.claim(**step, worker_id: 'worker')
    growth.commit(**step, claim_token: claim['claim_token'], evidence: payload)
  end

  # Entries an earlier Kairomone wrote carry no identity records: their XP is
  # the 0.6 rule's, and the first 0.8 write records it without changing it.
  def test_xp_is_equal_before_and_after_the_legacy_identity_migration
    legacy = KairomoneLegacyFixture.slot!(@host, dot_id: 'old_one', display_name: 'Old one')
    xp_061 = with_061(@host, <<~RUBY)
      #{EVIDENCE_061}
      s = Kairomone::Instance.new(host_root: host)
      s.observe(id: 'shared_l2', title: 'Shared', content: 'Same words in L2 and L1')
      s.create_knowledge(id: 'shared_l1', title: 'Shared', content: 'Same words in L2 and L1')
      s.observe(id: 'held', title: 'Held', content: 'Content the chat summary repeats')
      s.configure_companion(request_id: 'enable', expected_revision: 0, memory_enabled: true)
      s.remember_companion(request_id: 'held_chat', conversation_id: 'cc_one', message_ids: ['m1'], consent_revision: 1, summary: 'Content the chat summary repeats', memory_enabled: true)
      s.remember_companion(request_id: 'new_chat', conversation_id: 'cc_one', message_ids: ['m2'], consent_revision: 1, summary: 'Content only the chat brought', memory_enabled: true)
      g = s.autonomy
      g.configure(max_cycles: 10, already_used: 0)
      g.request(request_id: 'old_cycle', topic: 'Old topic', resume: true)
      c = g.claim(worker_id: 'old_worker', lease_seconds: 900)
      g.commit(claim_token: c['claim_token'], evidence: evidence)
      puts JSON.generate(s.progression_status)
    RUBY
    before = legacy.progression_status
    assert_equal xp_061['total_xp'], before[:total_xp], '0.8 reads a 0.6.1 individual at 0.6.1\'s level'
    assert_equal %w[0.6\ rule], legacy.xp_basis.map { |b| b['source'] }.uniq
    # A growth pair normalised by the 0.6 growth state:
    growth_l1 = legacy.xp_basis.find { |b| b['id'] == 'growth_old_cycle' && b['layer'] == 'L1' }
    assert_equal Kairomone::Progression.fingerprint('Synthesis an earlier Kairomone stored'), growth_l1['identity']
    legacy.observe(id: 'trigger', title: 'Trigger', content: 'The first 0.8 write')
    after = legacy.progression_status
    assert_equal before[:total_xp] + 10, after[:total_xp]
    assert_equal ['record'], legacy.xp_basis.map { |b| b['source'] }.uniq, 'the first 0.8 write recorded every identity'
    File.delete(File.join(legacy.root, 'growth/state.json'))
    assert_equal after[:total_xp], legacy.progression_status[:total_xp], 'recorded identities no longer depend on the 0.6 growth state'
  end

  def test_a_cancelled_receipt_that_brought_new_content_still_excludes_it
    store = make('alpha')
    store.configure_companion(request_id: 'enable', expected_revision: 0, memory_enabled: true)
    result = store.remember_companion(request_id: 'chat', conversation_id: 'cc_one', message_ids: ['m1'], consent_revision: 1,
                                      summary: 'Only the conversation said this.', memory_enabled: true)
    path = File.join(store.root, 'companion/state.json')
    state = JSON.parse(File.read(path))
    state['memories']['chat']['state'] = 'reserved'
    File.write(path, JSON.generate(state))
    File.delete(File.join(store.root, "context/kairomone_chat/#{result[:id]}/#{result[:id]}.md"))
    Dir.rmdir(File.join(store.root, "context/kairomone_chat/#{result[:id]}"))
    assert_equal 'cancelled', store.recover_companion_memory(request_id: 'chat')[:state]
    store.observe(title: 'Copied', content: 'Only the conversation said this.')
    assert_equal 0, store.progression_status[:total_xp]
  end

  def test_an_identity_record_for_a_refused_write_never_counts
    store = make('alpha')
    store.define_singleton_method(:write_l2_raw!) { |*_args| raise Kairomone::Error, 'Injected L2 disk failure' }
    assert_raises(Kairomone::Error) { store.observe(id: 'lost', title: 'Lost', content: 'Never written') }
    store.singleton_class.remove_method(:write_l2_raw!)
    recorded = Kairomone::Records.of_type(store.chain, 'kairomone_xp').flat_map { |r| r['entries'] }
    assert_equal ['lost'], recorded.map { |e| e['id'] }, 'the record was appended before the write'
    assert_equal 0, store.progression_status[:total_xp]
    assert store.observe(id: 'lost', title: 'Lost', content: 'Written now, differently')[:success]
    assert_equal 10, store.progression_status[:total_xp]
  end

  def test_a_pending_l1_adds_nothing
    store = make('alpha')
    failing = Class.new(Kairomone::AtomicLedgerBackend) do
      def save_all_blocks(blocks)
        last = blocks.last
        data = last.is_a?(Hash) ? (last[:data] || last['data']) : last.data
        raise KairosMcp::Storage::Error, 'simulated failure' if Array(data).any? { |d| d.include?('"knowledge_update"') }
        super
      end
    end.new(storage_dir: File.join(store.root, 'storage'), blockchain_file: File.join(store.root, 'storage/blockchain.json'),
            action_log_file: File.join(store.root, 'storage/action_log.jsonl'))
    pending = Kairomone::Instance.new(host_root: @host, kairomone: 'alpha', backend: failing)
    result = pending.create_knowledge(id: 'pending', title: 'Pending', content: 'Unrecorded')
    assert result[:pending]
    assert_equal 0, store.progression_status[:total_xp]
  end

  def test_a_growth_l1_is_never_present_without_its_evidence
    store = make('alpha')
    store.define_singleton_method(:write_l2_raw!) { |*_args| raise Kairomone::Error, 'Injected L2 disk failure' }
    assert_raises(Kairomone::Error) { one_cycle(store, 'first') }
    store.singleton_class.remove_method(:write_l2_raw!)
    assert_equal 0, store.status[:knowledge][:count]
    assert_equal 0, store.status[:observations][:count]
  end

  def test_the_same_content_committed_later_counts_once
    store = make('alpha')
    one_cycle(store, 'first')
    xp = store.progression_status[:total_xp]
    assert_equal 60, xp
    one_cycle(store, 'second')
    assert_equal xp, store.progression_status[:total_xp]
    assert_equal 2, store.status[:knowledge][:count]
  end

  # What an inherited or received not-counted entry holds — its own identity
  # and the identities of the sources it keeps excluded — counts nowhere, for
  # as long as that entry is present. (Fusion and import write such entries;
  # here they are written through the same record and write path.)
  def inherit(store, id, content, holds)
    raw = store.send(:document, id, "Inherited #{id}", content, 'L1', Time.now.utc.iso8601)
    store.send(:with_lock) do
      store.send(:record_identities!, [store.send(:xp_entry, 'L1', id, Kairomone::Progression.fingerprint(content), raw, counted: false, holds: holds)])
      store.send(:write_l1_raw, id, raw, 'Fixture inheritance')
    end
  end

  def test_a_not_counted_entry_excludes_what_it_holds_while_present
    store = make('alpha')
    store.create_knowledge(id: 'own', title: 'Own', content: 'Learned by this individual')
    assert_equal 50, store.progression_status[:total_xp]
    inherit(store, 'inherited', 'Merged from parents', [Kairomone::Progression.fingerprint('Learned by this individual')])
    assert_equal 0, store.progression_status[:total_xp], 'the held source identity counts nowhere'
    FileUtils.rm_rf(File.join(store.root, 'knowledge/inherited'))
    assert_equal 50, store.progression_status[:total_xp], 'a record whose entry is absent holds nothing'
  end

  def test_relearning_a_kept_inherited_growth_entry_adds_no_l1_xp
    store = make('alpha')
    inherit(store, 'inherited', 'Synthetic content', [])
    assert_equal 0, store.progression_status[:total_xp]
    one_cycle(store, 'relearn')
    progression = store.progression_status
    assert_equal 0, progression[:unique_l1], 'the relearned synthesis is the inherited identity'
    assert_equal 10, progression[:total_xp], 'its evidence is new L2 content'
  end

  def test_a_legacy_individuals_direction_and_personality_stay_in_force
    KairomoneLegacyFixture.slot!(@host, dot_id: 'old_one', display_name: 'Old one')
    with_061(@host, <<~RUBY)
      s = Kairomone::Instance.new(host_root: host)
      puts JSON.generate(s.configure_companion(request_id: 'set', expected_revision: 0, personality: 'Gentle and curious',
                                               direction: { 'preset' => 'research', 'text' => 'Primary sources first' }))
    RUBY
    legacy = Kairomone::Instance.new(host_root: @host)
    companion = legacy.companion_status[:companion]
    assert_equal 'Gentle and curious', companion['personality']
    assert_equal({ 'preset' => 'research', 'text' => 'Primary sources first' }, companion['direction'])
    run = legacy.autonomy.run_start(owner_words: 'One', cycles: 1)
    queued = legacy.autonomy.request(run_id: run[:run_id], token: run[:token], request_id: 'directed', topic: 'Topic')['queue']
    assert_equal 'Primary sources first', queued.dig('companion', 'direction', 'text')
  end
end
