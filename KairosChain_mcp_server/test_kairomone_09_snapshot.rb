# frozen_string_literal: true

# Kairomone 0.9, the snapshot's public subset (design
# log/kairomone_0_9_screens_and_generated_growth_design_v0.2_20261102.md,
# Inv 10, N6, data half): Instance#status_public carries what the individual
# publicly is — name, accepted drawings, level, stage, profession name and
# lineage names, counts — and, for each own growth entry, its L1 title, the
# evidence's synthesis and finding, the subjects its record names and its
# source URLs. Never a request or its topic, the direction, the lean, a skill,
# chat, an owner-written or received entry, a retrieval reference, a waiting
# drawing; every text is checked as it is assembled and one that fails is
# left out and counted as withheld. At most the newest 30 drawings and 100
# cycles. All data is synthetic and confined to temporary hosts.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'minitest/autorun'
require_relative 'templates/skillsets/kairomone/test/support_09'

class Kairomone09SnapshotTest < Minitest::Test
  include Kairomone09Support

  KEYS = %w[schema product version generated_at name level stage drawing drawings profession counts cycles withheld].freeze
  CYCLE_KEYS = %w[subjects title synthesis finding sources].freeze

  def secret_rich
    store = create
    store.configure_companion(request_id: 'dir', expected_revision: 0, direction: { 'preset' => 'custom', 'text' => 'SECRET-DIRECTION' })
    store.configure_companion(request_id: 'mem', expected_revision: 1, memory_enabled: true)
    store.remember_companion(request_id: 'chat', conversation_id: 'cc_one', message_ids: ['m1'], consent_revision: 2,
                             summary: 'SECRET-CHAT about the garden', memory_enabled: true)
    one_cycle(store, 'moss', subjects: %w[botany ecology], topic: 'SECRET-TOPIC about my health', title: 'Moss holds water',
                             content: 'Moss can hold many times its weight in water.', finding: 'Peat moss holds the most.',
                             url: 'https://example.com/moss', reference: 'SECRET-RETRIEVAL /tmp/fetched.html')
    store.create_knowledge(id: 'diary', title: 'SECRET-OWNER-NOTE', content: 'SECRET-OWNER-BODY')
    lean(store, 'lean', 'SECRET-LEAN-WORDS', %w[astronomy])
    source = store.skill_material[:own_growth_entries].first.slice('entry_id', 'sha256')
    store.accept_skill(proposal: store.propose_skill(skill: { 'name' => 'SECRET-SKILL', 'description' => 'SECRET-SKILL-TEXT', 'methods' => %w[quantify],
                                                              'focus' => [], 'source' => source })[:proposal])
    store.accept_art(proposal: store.propose_art(svg: Kairomone::Art::EGG.sub('Kairomone egg', 'Accepted drawing'), form: 'A mossy egg')[:proposal])
    store.propose_art(svg: Kairomone::Art::EGG.sub('Kairomone egg', 'SECRET-WAITING drawing'), form: 'SECRET-WAITING-FORM')
    store
  end

  def test_the_snapshot_carries_the_public_subset_and_nothing_else
    store = secret_rich
    snap = store.status_public
    assert_equal KEYS.sort, snap.keys.sort
    assert_equal ['Momo', 'kairomone-snapshot-1', 0], snap.values_at('name', 'schema', 'withheld')
    assert_equal Kairomone::Vocabulary.stage(store.progression_status[:level]).slice('id', 'en', 'ja'), snap['stage']
    assert_equal store.progression_status[:level], snap['level']
    cycle = snap['cycles'].first
    assert_equal CYCLE_KEYS.sort, cycle.keys.sort
    assert_equal ['Moss holds water', 'Moss can hold many times its weight in water.', 'Peat moss holds the most.', ['https://example.com/moss']],
                 cycle.values_at('title', 'synthesis', 'finding', 'sources')
    assert_equal %w[botany ecology], cycle['subjects'].map { |s| s['id'] }
    assert_equal({ 'lifetime_cycles' => 1, 'learned_sources' => 1, 'own_growth_l1' => 1, 'own_growth_l2' => 1 }, snap['counts'])
    assert_equal ['drawing', 'A mossy egg'], snap['drawing'].values_at('shown', 'form')
    assert_equal [['A mossy egg', false]], snap['drawings'].map { |d| d.values_at('form', 'missing') }
    text = JSON.generate(snap)
    %w[SECRET-TOPIC SECRET-DIRECTION SECRET-CHAT SECRET-OWNER SECRET-LEAN SECRET-SKILL SECRET-RETRIEVAL SECRET-WAITING Evidence\ SHA-256
       retrieval astronomy growth_moss].each do |secret|
      refute_includes text, secret
    end
    waiting = Base64.strict_encode64(Kairomone::Art::EGG.sub('Kairomone egg', 'SECRET-WAITING drawing'))
    refute_includes text, waiting, 'no waiting drawing'
    refute_includes text, store.root, 'no local path'
  end

  def test_a_text_that_fails_the_check_is_left_out_and_counted
    store = create
    one_cycle(store, 'paths', finding: 'Saved to /Users/someone/notes.txt', url: 'https://example.com/a?access_token=abcdef123456')
    one_cycle(store, 'home', content: 'See ~/research for more', title: 'file:///etc/hosts title')
    one_cycle(store, 'clean', finding: 'A clean finding', url: 'https://example.org/clean')
    snap = store.status_public
    by_id = snap['cycles'] # newest first: clean, home, paths
    assert_equal ['A clean finding', ['https://example.org/clean']], by_id[0].values_at('finding', 'sources')
    paths = by_id[2]
    assert_nil paths['finding']
    assert_equal [], paths['sources']
    home = by_id[1]
    assert_equal [nil, nil], home.values_at('title', 'synthesis')
    assert_equal 4, snap['withheld']
    assert_equal 2, snap['counts']['learned_sources'], 'a withheld source is not counted'
    refute_includes JSON.generate(snap), '/Users/'
    refute_includes JSON.generate(snap), 'access_token'
  end

  def test_received_and_inherited_entries_are_not_shown
    a = create('alpha')
    one_cycle(a, 'moss', title: 'Moss holds water')
    out = a.exchange_export(file_sha256: a.exchange_preview(include: %w[learned])[:file_sha256])
    FileUtils.mkdir_p(File.join(@host, 'kairomone-inbox'))
    FileUtils.cp(out[:path], File.join(@host, 'kairomone-inbox', out[:file]))
    Kairomone::Host.new.import_exchange(file: out[:file], listing_id: 'copy')
    copy = Kairomone::Instance.new(host_root: @host, kairomone: 'copy').status_public
    assert_equal [[], 0], [copy['cycles'], copy['counts']['own_growth_l1']]
    refute_includes JSON.generate(copy), 'Moss holds water'
  end

  def test_a_06_cycle_is_shown_by_its_evidence_and_a_profession_by_name
    legacy = KairomoneLegacyFixture.slot!(@host, dot_id: 'old_one', display_name: 'Old one')
    with_061(@host, <<~'RUBY')
      excerpt = 'Synthetic excerpt for a 0.6.1 cycle.'
      evidence = { 'knowledge' => { 'title' => 'Old synthesis', 'content' => 'What 0.6 learned' },
                   'finding' => 'Old finding', 'uncertainty' => 'u', 'counterexample' => 'c',
                   'sources' => [{ 'url' => 'https://example.com/old', 'title' => 'Fixture', 'retrieved_at' => '2026-10-01T00:00:00Z',
                                   'excerpt' => excerpt, 'retrieval_reference' => 'fixture', 'excerpt_sha256' => Digest::SHA256.hexdigest(excerpt) }] }
      s = Kairomone::Instance.new(host_root: host)
      g = s.autonomy
      g.configure(max_cycles: 10, already_used: 0)
      g.request(request_id: 'old_cycle', topic: 'SECRET old topic', resume: true)
      c = g.claim(worker_id: 'old_worker', lease_seconds: 900)
      g.commit(claim_token: c['claim_token'], evidence: evidence)
      puts JSON.generate(ok: true)
    RUBY
    select_06(legacy, 'generalist')
    snap = legacy.status_public
    assert_equal [{ 'subjects' => [], 'title' => 'Old synthesis', 'synthesis' => 'What 0.6 learned', 'finding' => 'Old finding',
                    'sources' => ['https://example.com/old'] }], snap['cycles']
    assert_equal({ 'name' => 'Generalist', 'lineage' => [] }, snap['profession'])
    assert_equal 'Old one', snap['name']
    refute_includes JSON.generate(snap), 'SECRET old topic'
  end

  def test_at_most_the_newest_thirty_drawings_and_hundred_cycles
    store = create
    31.times do |i|
      store.accept_art(proposal: store.propose_art(svg: Kairomone::Art::EGG.sub('Kairomone egg', "D#{i}"), form: "Form #{i}")[:proposal])
    end
    one_cycle(store, 'real')
    snap = store.status_public
    assert_equal 30, snap['drawings'].length
    assert_equal ['Form 1', 'Form 30'], [snap['drawings'].first['form'], snap['drawings'].last['form']], 'the newest thirty, in order'
    real = store.own_growth[:cycles].first
    cycles = (0..100).map { |i| real.merge('request_id' => "c#{i}") }
    store.define_singleton_method(:own_growth) { |*| { cycles: cycles, unknown: nil } }
    snap = store.status_public
    assert_equal 100, snap['cycles'].length
    assert_equal 101, snap['counts']['lifetime_cycles']
  end

  def test_unknown_lifetime_and_no_profession_read_as_absent
    store = create
    store.define_singleton_method(:own_growth) { |*| { cycles: [], unknown: 'the ledger is unreadable' } }
    snap = store.status_public
    assert_nil snap['counts']['lifetime_cycles']
    assert_equal({ 'name' => nil, 'lineage' => [] }, snap['profession'])
    assert_equal 'egg', snap['drawing']['shown']
    assert_match(%r{\Adata:image/svg\+xml;base64,}, snap['drawing']['data_uri'])
  end
end
