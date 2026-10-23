# frozen_string_literal: true

# Kairomone 0.8, what run D's third review round left on exchange and fusion
# (design log/kairomone_core_0_8_design_v0.6_FROZEN_20261023.md, Inv 3, Inv 4,
# Inv 8, Inv 9, M11, M14): bulk writes do not read the ledger once per entry;
# a preview refuses a file an import would refuse; received content is its own
# kind; exporter and importer run one evidence check under a named renderer;
# received evidence is bounded; profession lineage survives exchange and
# fusion; a kept fusion entry is cited, not written out again; the child keeps
# where its entries came from; holds over the bound are refused, not cut;
# received drawings keep their stage; plans expire by age; a fusion retry finds
# its child; under a locked L2 no received piece is kept; preview pages are
# read one at a time. All data is synthetic and confined to temporary hosts.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'minitest/autorun'
require_relative 'templates/skillsets/kairomone/test/support_08'

# Counts ledger passes made while a block runs on this thread.
module Kairomone08LedgerPasses
  def latest_l1_hashes(ledger)
    Thread.current[:kairomone_passes] += 1 if Thread.current[:kairomone_passes]
    super
  end
end
Kairomone::Instance.prepend(Kairomone08LedgerPasses)

class Kairomone08ExchangeFollowupsTest < Minitest::Test
  include Kairomone08Support

  PROFILE = { 'name' => 'Momo', 'kind' => 'animal', 'kind_label' => 'Fox', 'appearance' => 'A small round fox',
              'personality' => %w[curious], 'voice' => 'Soft', 'interests' => %w[stories] }.freeze
  CHILD = { 'name' => 'Pip', 'kind' => 'imaginary', 'kind_label' => 'Mossling', 'appearance' => 'A tiny moss sprite',
            'personality' => %w[gentle], 'voice' => 'Bright', 'interests' => %w[gardens] }.freeze
  CRAFT = { 'description' => 'Learns from the living world', 'focus' => %w[ecology botany],
            'habits' => { 'sources' => 'primary', 'depth' => 'deep', 'reflection' => 'narrative', 'stance' => 'practical' } }.freeze

  def setup = fresh_host
  def teardown = FileUtils.remove_entry_secure(@host)

  def create(id, template = 'researcher')
    Kairomone::Host.new.create(listing_id: id, profile: PROFILE.merge('name' => id.capitalize), profession: { 'template' => template },
                               material_kind: 'free_text')
    Kairomone::Instance.new(host_root: @host, kairomone: id)
  end

  def evidence(content = 'What the cycle learned')
    excerpt = 'Synthetic excerpt.'
    { 'knowledge' => { 'title' => 'Synthesis', 'content' => content }, 'finding' => 'f', 'uncertainty' => 'u', 'counterexample' => 'c',
      'sources' => [{ 'url' => 'https://example.com/a', 'title' => 'Fixture', 'retrieved_at' => Time.now.utc.iso8601,
                      'excerpt' => excerpt, 'retrieval_reference' => 'fixture', 'excerpt_sha256' => Digest::SHA256.hexdigest(excerpt) }] }
  end

  def one_cycle(store, id)
    growth = store.autonomy
    run = growth.run_start(owner_words: 'One cycle', cycles: 1)
    step = { run_id: run[:run_id], token: run[:token] }
    growth.request(**step, request_id: id, topic: 'A topic')
    claim = growth.claim(**step, worker_id: 'worker')
    growth.commit(**step, claim_token: claim['claim_token'], evidence: evidence)
  end

  def export_and_place(store, include:)
    out = store.exchange_export(file_sha256: store.exchange_preview(include: include)[:file_sha256])
    FileUtils.mkdir_p(File.join(@host, 'kairomone-inbox'))
    FileUtils.cp(out[:path], File.join(@host, 'kairomone-inbox', out[:file]))
    out[:file]
  end

  def rewrite(file)
    path = File.join(@host, 'kairomone-inbox', file)
    doc = JSON.parse(File.read(path))
    yield doc
    doc['manifest_sha256'] = Kairomone::Exchange.manifest(doc)
    File.write(path, Kairomone::Exchange.bytes(doc))
  end

  def import(file, id) = Kairomone::Host.new.import_exchange(file: file, listing_id: id)

  def passes
    Thread.current[:kairomone_passes] = 0
    yield
    Thread.current[:kairomone_passes]
  ensure
    Thread.current[:kairomone_passes] = nil
  end

  # Two parents and a plan keeping beta's fern by citation and merging alpha's tea.
  def propose(child = 'pip')
    host = Kairomone::Host.new
    material = host.fusion_material(parents: %w[alpha beta])
    entries = material[:items].select { |i| i['item'] == 'entry' }.to_h { |e| [[e['parent'], e['id']], e] }
    plan = [{ 'id' => 'fern', 'mode' => 'keep', 'sources' => [{ 'parent' => 'beta', 'entry_id' => 'fern', 'sha256' => entries[%w[beta fern]]['sha256'] }] },
            { 'id' => 'tea', 'title' => 'Tea', 'content' => 'Green tea, steamed.', 'mode' => 'merge',
              'sources' => [{ 'parent' => 'alpha', 'entry_id' => 'tea', 'sha256' => entries[%w[alpha tea]]['sha256'] }] }]
    host.fusion_propose(parents: %w[alpha beta], child: child, profile: CHILD, entries: plan, heads: material[:heads],
                        candidates: %w[Gardener Herbalist Forager].map { |n| CRAFT.merge('name' => n) })
  end

  def parents
    a = create('alpha')
    a.create_knowledge(id: 'tea', title: 'Tea notes', content: 'Green tea is steamed.')
    b = create('beta', 'builder')
    b.create_knowledge(id: 'fern', title: 'Ferns', content: 'Ferns spread by spores.')
    [a, b]
  end

  def test_an_import_reads_the_ledger_a_fixed_number_of_times_whatever_it_carries
    counts = [3, 12].map do |n|
      store = create("src#{n}")
      n.times { |i| store.create_knowledge(id: "note_#{i}", title: "Note #{i}", content: "Note #{i} of #{n}") }
      file = export_and_place(store, include: %w[owner_written])
      passes { import(file, "dst#{n}") }
    end
    assert_equal counts.first, counts.last, "ledger passes for 3 and 12 entries: #{counts.inspect}"
  end

  def test_a_preview_refuses_a_file_an_import_would_refuse
    store = create('momo')
    Kairomone::Exchange::PIECES_MAX.succ.times do |i|
      svg = Kairomone::Art::EGG.sub('rx="34"', "rx=\"#{i + 1}\"")
      store.accept_art(proposal: store.propose_art(svg: svg)[:proposal])
    end
    error = assert_raises(Kairomone::Error) { store.exchange_preview(include: %w[owner_written]) }
    assert_match(/An import would refuse this file .*at most 64 professions and 64 drawings/, error.message)
    refute Dir.exist?(File.join(@host, 'kairomone-previews')) && Dir.children(File.join(@host, 'kairomone-previews')).any?
  end

  def test_received_content_is_its_own_kind
    store = create('momo')
    store.create_knowledge(id: 'tea', title: 'Tea notes', content: 'Green tea is steamed.')
    import(export_and_place(store, include: %w[owner_written]), 'copy')
    copy = Kairomone::Instance.new(host_root: @host, kairomone: 'copy')
    copy.create_knowledge(id: 'mine', title: 'Mine', content: 'Written by the copy\'s owner.')
    first = copy.exchange_preview(include: %w[owner_written])
    assert_equal ['mine'], first[:items].select { |i| i['item'] == 'entry' }.map { |i| i['id'] }
    assert_equal [%w[tea received]], first[:items].select { |i| i['item'] == 'left_out' }.map { |i| i.values_at('id', 'kind') }
    both = copy.exchange_preview(include: %w[owner_written received])
    assert_equal [%w[mine owner_written], %w[tea received]], both[:items].select { |i| i['item'] == 'entry' }.map { |i| i.values_at('id', 'kind') }
  end

  def test_the_exporter_leaves_out_what_the_importer_would_refuse
    store = create('momo')
    one_cycle(store, 'moss')
    path = File.join(store.root, 'context/kairomone/growth_moss/growth_moss.md')
    # The evidence still has its kind, but its body no longer matches its hash.
    File.write(path, File.read(path).sub('"finding": "f"', '"finding": "changed"'))
    first = store.exchange_preview(include: %w[learned])
    left = first[:items].find { |i| i['item'] == 'left_out' }
    assert_equal 'growth_moss', left['id']
    assert_match(/does not match its hash, so an importer could not check it/, left['reason'])
  end

  def test_a_file_from_another_renderer_or_with_oversized_evidence_is_refused
    store = create('momo')
    one_cycle(store, 'moss')
    file = export_and_place(store, include: %w[learned])
    rewrite(file) { |doc| doc['renderer'] = 'growth-body-0' }
    assert_match(/rendered by growth-body-0/, assert_raises(Kairomone::Error) { import(file, 'copy') }.message)
    rewrite(file) do |doc|
      doc['renderer'] = Kairomone::Autonomy::KNOWLEDGE_RENDERER
      doc['entries'].first['evidence']['evidence']['knowledge']['content'] = 'x' * 20_000
    end
    assert_match(/not what a cycle accepts/, assert_raises(Kairomone::Error) { import(file, 'copy') }.message)
    refute_includes listing, 'copy'
  end

  def test_profession_lineage_survives_fusion_and_exchange
    a, b = parents
    Kairomone::Host.new.fusion_accept(plan: propose[:plan], candidate: 0)
    child = Kairomone::Instance.new(host_root: @host, kairomone: 'pip')
    lineage = child.profession_status[:lineage]
    assert_equal [a, b].map { |p| p.profession_status[:current][:id] }, lineage.first(2).map { |l| l[:id] }, 'both parents, not only the first'
    refute(lineage.any? { |l| l[:name] == '(absent)' }, lineage.inspect)
    import(export_and_place(child, include: []), 'heir')
    heir = Kairomone::Instance.new(host_root: @host, kairomone: 'heir')
    sent = child.profession_status[:current][:id]
    proposal = heir.proposals[:proposals].find { |p| p['kind'] == 'profession' && p.dig('piece', 'name') == 'Gardener' }
    assert proposal, heir.proposals.inspect
    assert heir.accept_profession(proposal: proposal['proposal'])[:accepted]
    assert_equal sent, heir.profession_status[:current][:id], 'the received profession keeps its sha256'
    assert_equal 'import', Kairomone::Records.of_type(heir.chain, 'kairomone_profession').last['origin']
    assert_equal lineage, heir.profession_status[:lineage]
  end

  def test_a_received_profession_that_does_not_match_its_sha256_waits_nowhere
    _a, _b = parents
    Kairomone::Host.new.fusion_accept(plan: propose[:plan], candidate: 0)
    child = Kairomone::Instance.new(host_root: @host, kairomone: 'pip')
    file = export_and_place(child, include: [])
    rewrite(file) { |doc| doc['pieces']['professions'].first['description'] = 'Changed on the way' }
    result = import(file, 'heir')
    assert(result[:skipped].any? { |s| s['kind'] == 'profession' && s['reason'].include?('sha256') }, result[:skipped].inspect)
  end

  def test_a_kept_entry_is_cited_and_the_child_keeps_where_its_entries_came_from
    parents
    host = Kairomone::Host.new
    light = host.fusion_material(parents: %w[alpha beta], bodies: false)
    entry = light[:items].find { |i| i['item'] == 'entry' }
    refute entry.key?('body')
    assert entry['bytes'].positive?
    summary = propose
    fern = summary[:items].find { |i| i['item'] == 'child_entry' && i['id'] == 'fern' }
    assert_equal %w[Ferns Ferns\ spread\ by\ spores.], fern.values_at('title', 'content'), 'title and body copied from the source'
    host.fusion_accept(plan: summary[:plan], candidate: 0)
    child = Kairomone::Instance.new(host_root: @host, kairomone: 'pip')
    record = Kairomone::Records.of_type(child.chain, 'kairomone_lineage').first
    kept = JSON.parse(File.read(File.join(child.root, 'lineage', "#{record['entries_sha256']}.json")))
    assert_equal [summary[:plan], %w[fern tea]], [kept['plan_sha256'], kept['entries'].map { |e| e['id'] }]
    assert_equal [{ 'parent' => 'beta', 'entry_id' => 'fern' }], kept['entries'].first['sources'].map { |s| s.slice('parent', 'entry_id') }
    assert_includes child.send(:backup_paths), "lineage/#{record['entries_sha256']}.json"
  end

  def test_holds_over_the_bound_are_refused_not_cut
    many = Array.new(300) { |i| Digest::SHA256.hexdigest("held #{i}") }
    sources_of = { 'a' => { 'x' => { 'sha256' => 'a' * 64, 'identity' => 'b' * 64, 'holds' => many, 'title' => 'X', 'body' => 'X body' } } }
    entries = [{ 'id' => 'x', 'mode' => 'keep', 'sources' => [{ 'parent' => 'a', 'entry_id' => 'x', 'sha256' => 'a' * 64 }] }]
    error = assert_raises(Kairomone::Error) { Kairomone::Host.new.send(:fusion_plan_entries!, entries, sources_of) }
    assert_match(/would hold 301 identities, over the 256/, error.message)
  end

  def test_received_drawings_wait_for_the_stage_they_answered
    store = create('momo')
    store.accept_art(proposal: store.propose_art(svg: Kairomone::Art::EGG)[:proposal])
    2.times { |i| store.create_knowledge(id: "n#{i}", title: "N#{i}", content: "Note #{i}") }
    later = Kairomone::Art::EGG.sub('rx="34"', 'rx="30"')
    store.accept_art(proposal: store.propose_art(svg: later)[:proposal])
    import(export_and_place(store, include: []), 'copy')
    copy = Kairomone::Instance.new(host_root: @host, kairomone: 'copy')
    waiting = copy.proposals[:proposals].select { |p| p['kind'] == 'art' && p['state'] == 'waiting' }
    assert_equal %w[egg hatchling], waiting.map { |p| p['stage'] }.sort, copy.proposals.inspect
  end

  def test_a_fusion_plan_expires_by_age_and_a_retry_finds_its_child
    parents
    summary = propose
    path = File.join(@host, 'kairomone-fusion', "#{summary[:plan]}.json")
    File.utime(Time.now - 8 * 24 * 3600, Time.now - 8 * 24 * 3600, path)
    assert_match(/expired/, assert_raises(Kairomone::Error) { Kairomone::Host.new.fusion_summary(plan: summary[:plan]) }.message)
    summary = propose('sprout')
    first = Kairomone::Host.new.fusion_accept(plan: summary[:plan], candidate: 0)
    again = Kairomone::Host.new.fusion_accept(plan: summary[:plan], candidate: 0)
    assert_equal [true, first[:kairomone]], [again[:preserved], again[:kairomone]]
  end

  def test_under_a_locked_l2_an_import_keeps_no_received_piece
    store = create('momo')
    store.create_knowledge(id: 'tea', title: 'Tea notes', content: 'Green tea is steamed.')
    file = export_and_place(store, include: %w[owner_written])
    File.write(File.join(@host, 'skills/config.yml'), { 'layers' => { 'L1' => { 'enabled' => true, 'mutable' => true }, 'L2' => { 'enabled' => true, 'mutable' => false } } }.to_yaml)
    result = import(file, 'copy')
    assert_equal [], result[:received]
    assert_match(/locks L2/, result[:skipped].first['reason'])
    copy = Kairomone::Instance.new(host_root: @host, kairomone: 'copy')
    refute Dir.exist?(File.join(copy.root, 'proposals')) && Dir.children(File.join(copy.root, 'proposals')).any?
    assert_equal 1, copy.status[:knowledge][:count], 'the knowledge still comes in'
  end

  def test_preview_pages_are_read_one_at_a_time_and_checked
    store = create('momo')
    3.times { |i| store.create_knowledge(id: "long_#{i}", title: "Long #{i}", content: "#{i} " + ('x' * 15_000)) }
    first = store.exchange_preview(include: %w[owner_written])
    assert_operator first[:pages], :>=, 2
    File.delete(File.join(@host, 'kairomone-previews', "#{first[:file_sha256]}.file"))
    assert store.exchange_preview(file_sha256: first[:file_sha256], page: 2)[:items].any?, 'a page does not need the whole file'
    File.write(File.join(@host, 'kairomone-previews', "#{first[:file_sha256]}.p2.json"), '[]')
    assert_match(/does not match its sha256/, assert_raises(Kairomone::Error) { store.exchange_preview(file_sha256: first[:file_sha256], page: 2) }.message)
  end
end
