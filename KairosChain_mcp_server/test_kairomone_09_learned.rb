# frozen_string_literal: true

# Kairomone 0.9, learned subjects and lifetime cycles (design
# log/kairomone_0_9_screens_and_generated_growth_design_v0.2_20261102.md,
# "own growth entry", Inv 4, N3): a request declares 1-3 subjects, which the
# request entry and the completed record carry; learned subjects are counted
# over own growth entries and re-resolved through the vocabulary when read;
# lifetime cycles count, by one test for every generation, the cycles whose
# L1 is an own growth entry — never an abandoned intent, a failed or expired
# 0.6 claim or the 0.6 claim counter — and what cannot be established is
# reported as unknown. All data is synthetic and confined to temporary hosts.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'minitest/autorun'
require_relative 'templates/skillsets/kairomone/test/support_09'

class Kairomone09LearnedTest < Minitest::Test
  include Kairomone09Support

  EVIDENCE_061 = <<~'RUBY'
    evidence = lambda do |n|
      excerpt = "Synthetic excerpt for a 0.6.1 cycle #{n}."
      { 'knowledge' => { 'title' => "Old synthesis #{n}", 'content' => "Synthesis an earlier Kairomone stored #{n}" },
        'finding' => 'Old finding', 'uncertainty' => 'Old uncertainty', 'counterexample' => 'Old counterexample',
        'sources' => [{ 'url' => "https://example.com/old#{n}", 'title' => 'Fixture', 'retrieved_at' => '2026-10-01T00:00:00Z',
                        'excerpt' => excerpt, 'retrieval_reference' => 'fixture', 'excerpt_sha256' => Digest::SHA256.hexdigest(excerpt) }] }
    end
  RUBY

  def test_a_request_declares_one_to_three_vocabulary_subjects
    store = create
    growth = store.autonomy
    run = growth.run_start(owner_words: 'One', cycles: 1)
    step = { run_id: run[:run_id], token: run[:token] }
    [nil, [], %w[geology botany zoology ecology], %w[not_a_subject], %w[geology geology], 'geology', [42]].each do |subjects|
      assert_raises(Kairomone::Error, subjects.inspect) { growth.request(**step, request_id: 'one', topic: 'Rocks', subjects: subjects) }
    end
    queued = growth.request(**step, request_id: 'one', topic: 'Rocks', subjects: %w[geology volcanology])
    assert_equal %w[geology volcanology], queued.dig('queue', 'subjects')
    assert growth.request(**step, request_id: 'one', topic: 'Rocks', subjects: %w[geology volcanology])['preserved']
    assert_raises(Kairomone::Error, 'a retry with other subjects is another request') { growth.request(**step, request_id: 'one', topic: 'Rocks', subjects: %w[geology]) }
    claim = growth.claim(**step, worker_id: 'worker')['claim_token']
    growth.commit(**step, claim_token: claim, evidence: evidence)
    assert_equal %w[geology volcanology], records(store, 'kairomone_growth_completed').last['subjects']
    body = JSON.parse(store.context_manager.get_context('kairomone', 'growth_one').content)
    assert_equal %w[geology volcanology], body.dig('request', 'subjects'), 'the request entry carries them'
    tool_refused = tool(:Growth, 'command' => 'request', 'run_id' => run[:run_id], 'token' => run[:token], 'request_id' => 'two', 'topic' => 'T')
    assert_match(/subjects/, tool_refused['error'])
  end

  def test_learned_subjects_are_counted_over_own_growth_entries_top_twelve
    store = create
    one_cycle(store, 'a', subjects: %w[geology botany])
    one_cycle(store, 'b', subjects: %w[botany])
    one_cycle(store, 'c', subjects: %w[astronomy])
    learned = store.status[:growth]['learned_subjects']
    assert_equal [['botany', 2], ['astronomy', 1], ['geology', 1]], learned.map { |l| [l['id'], l['count']] }
    assert_equal '植物学', learned.first['ja']
    # An edited growth entry is no longer an own growth entry: its subjects stop counting.
    path = File.join(store.root, 'knowledge/growth_b/growth_b.md')
    File.write(path, File.read(path).sub('Learned in b', 'Edited'))
    assert_equal [['astronomy', 1], ['botany', 1], ['geology', 1]], store.status[:growth]['learned_subjects'].map { |l| [l['id'], l['count']] }
    %w[d e f g h].each_with_index do |id, i|
      subjects = [%w[physics chemistry biology], %w[ecology genetics evolution], %w[zoology history music], %w[poetry art law], %w[ethics logic]][i]
      one_cycle(store, id, subjects: subjects)
    end
    assert_equal 12, store.status[:growth]['learned_subjects'].length, 'the top twelve'
    growth = store.autonomy
    run = growth.run_start(owner_words: 'One', cycles: 1)
    context = growth.request(run_id: run[:run_id], token: run[:token], request_id: 'next', topic: 'T', subjects: %w[geology])['queue']['context']
    assert_equal store.status[:growth]['learned_subjects'], context['learned'], 'the request context carries the learned names with counts'
  end

  def test_learned_subjects_are_re_resolved_through_the_vocabulary_when_read
    store = create
    one_cycle(store, 'a', subjects: %w[geology botany])
    Kairomone::Vocabulary.subjects
    cache = Kairomone::Vocabulary.instance_variable_get(:@cache)
    original = cache['subjects.json']
    memo = Kairomone::Vocabulary.instance_variable_get(:@subjects)
    reduced = original['subjects'].reject { |s| %w[geology botany].include?(s['id']) }
    cache['subjects.json'] = original.merge('subjects' => reduced, 'aliases' => { 'geology' => 'earth_science' })
    Kairomone::Vocabulary.instance_variable_set(:@subjects, nil)
    assert_equal [['earth_science', 1]], store.status[:growth]['learned_subjects'].map { |l| [l['id'], l['count']] },
                 'a retired ID reads as its successor and an ID the vocabulary no longer holds is dropped'
  ensure
    cache['subjects.json'] = original if cache
    Kairomone::Vocabulary.instance_variable_set(:@subjects, memo)
  end

  def test_an_abandoned_intent_is_not_a_cycle
    store = create
    one_cycle(store, 'kept')
    growth = store.autonomy
    run = growth.run_start(owner_words: 'One', cycles: 1)
    step = { run_id: run[:run_id], token: run[:token] }
    growth.request(**step, request_id: 'lost', topic: 'T', subjects: %w[botany])
    claim = growth.claim(**step, worker_id: 'worker')['claim_token']
    store.define_singleton_method(:growth_write!) { |*| raise Kairomone::Error, 'Injected disk failure' }
    assert_raises(Kairomone::Error) { growth.commit(**step, claim_token: claim, evidence: evidence(content: 'Never landed')) }
    store.singleton_class.remove_method(:growth_write!)
    growth.run_stop
    assert_equal %w[kept lost], records(store, 'kairomone_growth_completed').map { |r| r['request_id'] }, 'the intent is on the ledger'
    status = store.status[:growth]
    assert_equal [1, nil], status.values_at('lifetime_cycles', 'lifetime_unknown')
    assert_equal ['geology'], status['learned_subjects'].map { |l| l['id'] }, 'its subjects count nowhere'
  end

  def test_lifetime_cycles_count_completed_06_cycles_never_its_claim_counter
    legacy = KairomoneLegacyFixture.slot!(@host, dot_id: 'old_one', display_name: 'Old one')
    used = with_061(@host, <<~RUBY)
      #{EVIDENCE_061}
      s = Kairomone::Instance.new(host_root: host)
      g = s.autonomy
      g.configure(max_cycles: 10, already_used: 3)
      g.request(request_id: 'failed', topic: 'Failed topic', max_cycles: 10, already_used: 3, resume: true)
      c = g.claim(worker_id: 'old_worker', lease_seconds: 900)
      g.fail(claim_token: c['claim_token'], reason: 'No sources')
      g.request(request_id: 'done', topic: 'Done topic', max_cycles: 10, already_used: 3, resume: true)
      c = g.claim(worker_id: 'old_worker', lease_seconds: 900)
      g.commit(claim_token: c['claim_token'], evidence: evidence.call(1))
      g.request(request_id: 'expired', topic: 'Expired topic', max_cycles: 10, already_used: 3, resume: true)
      g.claim(worker_id: 'old_worker', lease_seconds: 1)
      sleep 1.2
      puts JSON.generate(g.status)
    RUBY
    assert_equal 6, used['used_cycles'], '0.6 counted three declared cycles and three claims'
    status = legacy.status[:growth]
    assert_equal [1, nil], status.values_at('lifetime_cycles', 'lifetime_unknown'), 'one 0.6 cycle completed'
    assert_equal 6, status.dig('legacy_budget', 'used_cycles'), 'the 0.6 budget stays a record beside it'
    one_cycle(legacy, 'new_one', subjects: %w[geology])
    assert_equal 2, legacy.status[:growth]['lifetime_cycles']
    assert_equal %w[growth_done growth_new_one], legacy.skill_material[:own_growth_entries].map { |e| e['entry_id'] }.sort
    assert_includes legacy.own_growth_entries, ['L2', 'growth_done']
    # Its L2 no longer rebuilds from the evidence hash the 0.6 state recorded:
    # the L2 is no longer its own; the L1, bound by its ledger record, still is.
    evidence_path = File.join(legacy.root, 'context/kairomone/growth_done/growth_done.md')
    File.write(evidence_path, File.read(evidence_path).sub('Old finding', 'Edited finding'))
    refute_includes legacy.own_growth_entries, ['L2', 'growth_done']
    assert_equal 2, legacy.status[:growth]['lifetime_cycles']
    # A 0.6 L1 no longer what its cycle recorded is not counted.
    path = File.join(legacy.root, 'knowledge/growth_done/growth_done.md')
    File.write(path, File.read(path).sub('Synthesis an earlier Kairomone stored 1', 'Changed'))
    assert_equal 1, legacy.status[:growth]['lifetime_cycles']
  end

  def test_a_cycle_record_counts_only_while_its_entry_holds_the_hash_it_recorded
    store = create
    store.create_knowledge(id: 'growth_named', title: 'Named', content: 'Owner-written under a growth-like ID')
    store.observe(id: 'growth_named', title: 'Named evidence', content: 'Owner-written L2')
    l1 = Digest::SHA256.hexdigest(File.binread(File.join(store.root, 'knowledge/growth_named/growth_named.md')))
    l2 = Digest::SHA256.hexdigest(File.binread(File.join(store.root, 'context/kairomone/growth_named/growth_named.md')))
    intent = lambda do |request_id, l1_sha|
      { 'type' => 'kairomone_growth_completed', 'request_id' => request_id, 'run_id' => 'run_20261102T000000Z_00000000', 'created_at' => Time.now.utc.iso8601,
        'evidence_sha256' => 'd' * 64, 'l1_id' => 'growth_named', 'l2_id' => 'growth_named', 'l1_identity' => 'e' * 64, 'l2_identity' => 'f' * 64,
        'l1_sha256' => l1_sha, 'l2_sha256' => l2, 'subjects' => %w[botany], 'methods_applied' => [] }
    end
    store.send(:with_lock) { Kairomone::Records.append!(store.chain, [intent.call('other_hash', 'a' * 64)], -> { store.chain }) }
    assert_equal 0, store.status[:growth]['lifetime_cycles'], 'a recorded entry with another hash is not that cycle\'s'
    store.send(:with_lock) { Kairomone::Records.append!(store.chain, [intent.call('this_hash', l1)], -> { store.chain }) }
    assert_equal 1, store.status[:growth]['lifetime_cycles']
  end

  def test_what_cannot_be_established_is_reported_as_unknown
    legacy = KairomoneLegacyFixture.slot!(@host, dot_id: 'old_one', display_name: 'Old one')
    one_cycle(legacy, 'new_one')
    File.write(File.join(legacy.root, 'growth/state.json'), '{"schema_version": 1, "unexpected": true}')
    status = legacy.status[:growth]
    assert_nil status['lifetime_cycles']
    assert_equal 1, status.dig('lifetime_unknown', 'at_least')
    assert_match(/0\.6 growth state cannot be read/, status.dig('lifetime_unknown', 'reason'))
    state = { 'schema_version' => 1, 'max_cycles' => 10, 'initial_used' => 0, 'used_cycles' => 1, 'stopped' => true, 'queue' => nil,
              'active_claim' => nil, 'requests' => { 'odd' => { 'state' => 'completed', 'result' => 'not a result' } }, 'last_result' => nil,
              'stop_reason' => nil }
    File.write(File.join(legacy.root, 'growth/state.json'), JSON.generate(state))
    status = legacy.status[:growth]
    assert_nil status['lifetime_cycles'], 'a completed 0.6 request whose result cannot be read is not guessed'
    assert_match(/without a readable result/, status.dig('lifetime_unknown', 'reason'))
  end

  def test_received_and_owner_written_entries_are_not_cycles
    a = create('alpha')
    one_cycle(a, 'moss')
    a.create_knowledge(id: 'growth_fake', title: 'Named like growth', content: 'Owner-written')
    assert_equal 1, a.status[:growth]['lifetime_cycles']
    out = a.exchange_export(file_sha256: a.exchange_preview(include: %w[learned owner_written])[:file_sha256])
    FileUtils.mkdir_p(File.join(@host, 'kairomone-inbox'))
    FileUtils.cp(out[:path], File.join(@host, 'kairomone-inbox', out[:file]))
    Kairomone::Host.new.import_exchange(file: out[:file], listing_id: 'copy')
    copy = Kairomone::Instance.new(host_root: @host, kairomone: 'copy')
    assert_equal 2, copy.list_knowledge[:items].length
    assert_equal [0, []], copy.status[:growth].values_at('lifetime_cycles', 'learned_subjects'), 'a copy learned nothing itself'
  end
end
