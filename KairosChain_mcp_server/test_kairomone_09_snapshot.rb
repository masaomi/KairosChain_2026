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
# left out and counted as withheld — file: only as a word of its own, and
# secrets URLs commonly carry; a source address is shown as scheme, host and
# path, never its query or fragment. At most the newest 30 drawings and 100
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

  # "file:" is a local path only as a word of its own.
  def test_the_file_check_is_at_a_word_boundary
    snapshot = Kairomone::Snapshot
    ['The user profile: a short note', 'Dockerfile: base image', 'A makefile:target rule'].each do |text|
      assert snapshot.public_text?(text), text
    end
    ['file:///etc/hosts', 'see FILE:/tmp/x', '(file:notes.txt)', 'a file: path'].each do |text|
      refute snapshot.public_text?(text), text
    end
  end

  # A source address is shown as scheme, host and path: its query can carry
  # the words a search was made of, or a token. An address carrying a secret
  # a URL commonly holds is left out whole, as is any text carrying one.
  def test_source_addresses_drop_query_and_fragment_and_url_secrets_are_withheld
    store = create
    one_cycle(store, 'search', url: 'https://search.example.com/results/page?q=my+private+topic&lang=en')
    one_cycle(store, 'signed', url: 'https://bucket.s3.amazonaws.com/r.pdf?X-Amz-Credential=AKIAIOSFODNN7EXAMPLE&X-Amz-Signature=abcdef0123456789')
    one_cycle(store, 'token', url: 'https://example.com/doc?token=abcdef123456', finding: 'The bot answered as xoxb-1234567890-abcdefghij')
    snap = store.status_public
    token, signed, search = snap['cycles'] # newest first
    assert_equal ['https://search.example.com/results/page'], search['sources']
    refute_includes JSON.generate(snap), 'private+topic', 'no query reaches the page'
    assert_equal [[], [], nil], [signed['sources'], token['sources'], token['finding']]
    assert_equal 3, snap['withheld']
    assert_equal 1, snap['counts']['learned_sources']
    text = JSON.generate(snap)
    %w[X-Amz AKIA token= xoxb].each { |secret| refute_includes text, secret }

    snapshot = Kairomone::Snapshot
    assert_equal 'https://example.org/a/b', snapshot.public_url('https://example.org/a/b#section-2')
    assert_equal 'https://example.org:8443/x', snapshot.public_url('https://user:pw@example.org:8443/x?y=1')
    assert_equal 'https://example.org', snapshot.public_url('https://example.org?q=1')
    ['javascript:alert(1)', 'not a url at all', 'https://example.com/a?access_token=abcdef123456', 'https://example.com/a?sig=abc123',
     'https://example.com/a?api_key=abc123', 'https://example.com/a?X-Goog-Signature=abc', 'file:///etc/hosts', nil].each do |url|
      assert_nil snapshot.public_url(url), url.inspect
    end
    ['ghs_abcdefghijklmnopqrstuvwxyz0123', 'AIzaSyA1234567890abcdefghijklmnopqrstuv', 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmn',
     'xoxp-1234567890-abcdef'].each { |token_text| refute snapshot.public_text?("Found #{token_text} here"), token_text }
    ['A design note', 'The author=Ada field', 'Tokens are words', 'monkey business'].each { |plain| assert snapshot.public_text?(plain), plain }
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
    assert_equal({ 'chosen' => true, 'name' => 'Generalist', 'lineage' => [] }, snap['profession'])
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
    assert_equal({ 'chosen' => false, 'name' => nil, 'lineage' => [] }, snap['profession'], 'no profession yet')
    assert_equal 'egg', snap['drawing']['shown']
    assert_match(%r{\Adata:image/svg\+xml;base64,}, snap['drawing']['data_uri'])
  end

  # The page tells "no profession yet" from a profession whose name failed
  # the check by chosen.
  def test_a_profession_whose_name_fails_is_chosen_without_a_name
    store = create
    store.define_singleton_method(:profession_status) do |*|
      { current: { id: 'x' }, name: 'Keeper of /home/someone', lineage: [{ id: 'p', name: 'Parent' }, { id: 'q', name: 'password: hunter22' }] }
    end
    snap = store.status_public
    assert_equal({ 'chosen' => true, 'name' => nil, 'lineage' => ['Parent'] }, snap['profession'])
    assert_equal 2, snap['withheld']
  end

  # A drawing's stage reaches the page as the names the vocabulary holds (for
  # a drawing recorded before 0.9, which the page labels by stage); a stage
  # the vocabulary does not hold is never passed as text.
  def test_drawing_stages_are_names_and_a_crafted_stage_is_dropped
    store = create
    old = Kairomone::Art::EGG.sub('Kairomone egg', 'An 0.8 drawing')
    odd = Kairomone::Art::EGG.sub('Kairomone egg', 'A crafted record')
    store.send(:with_lock) do
      [[old, 'hatchling'], [odd, 'SECRET-STAGE <b>']].each do |svg, stage|
        sha = Digest::SHA256.hexdigest(svg)
        Kairomone::Paths.write(store.root, "art/#{sha}.svg", svg)
        Kairomone::Records.append!(store.chain, [{ 'type' => 'kairomone_art', 'sha256' => sha, 'origin' => 'import', 'stage' => stage }], -> { store.chain })
      end
    end
    grow_to(store, 10)
    store.accept_art(proposal: store.propose_art(svg: FORM_SVG, form: 'A fox at ten')[:proposal])
    snap = store.status_public
    old_d, odd_d, new_d = snap['drawings']
    assert_equal [{ 'id' => 'hatchling', 'en' => 'Hatchling', 'ja' => '幼体' }, nil], old_d.values_at('stage', 'level'), 'a 0.8 drawing by its stage only'
    refute odd_d.key?('stage')
    refute_includes JSON.generate(snap), 'SECRET-STAGE'
    level = store.progression_status[:level]
    assert_equal [level, Kairomone::Vocabulary.milestone(level), 'A fox at ten', false], new_d.values_at('level', 'milestone', 'form', 'missing')
    assert_equal 'hatchling', new_d.dig('stage', 'id')
  end

  FORM_SVG = Kairomone::Art::EGG.sub('Kairomone egg', 'A fox at ten')

  # This host's own directory is a local path wherever it lives (here a
  # temporary directory the markers alone would miss).
  def test_the_host_directory_is_a_local_path
    store = create
    one_cycle(store, 'stored', content: "Kept under #{store.root}/notes", finding: "See #{store.host_root.delete_prefix('/private')}/x")
    snap = store.status_public
    assert_equal [nil, nil], snap['cycles'].first.values_at('synthesis', 'finding')
    assert_equal 2, snap['withheld']
    assert_equal [], Kairomone::Snapshot.local_roots('/data'), 'a one-segment root would match public addresses'
    assert_equal ['/srv/kairos'], Kairomone::Snapshot.local_roots('/srv/kairos')
    assert_equal ['/private/var/folders/x', '/var/folders/x'], Kairomone::Snapshot.local_roots('/private/var/folders/x')
    assert Kairomone::Snapshot.public_text?('https://example.org/data/report'), 'an address is not refused for its path'
  end
end
