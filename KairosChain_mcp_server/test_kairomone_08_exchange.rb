# frozen_string_literal: true

# Kairomone 0.8, exchange (design log/kairomone_core_0_8_design_v0.6_FROZEN_20261023.md,
# Inv 1, Inv 3, Inv 4, Inv 8, M11): the file written is the one previewed;
# only chosen content goes in; carried evidence has no request; chat
# memories, growth state, backups, the ledger, the direction and material
# never go in; an import is a new individual with a new identity that records
# every piece received and the manifest; the exporter does not change. All
# data is synthetic and confined to temporary hosts.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'minitest/autorun'
require_relative 'templates/skillsets/kairomone/test/support_08'

class Kairomone08ExchangeTest < Minitest::Test
  include Kairomone08Support

  PROFILE = { 'name' => 'Momo', 'kind' => 'animal', 'kind_label' => 'Fox', 'appearance' => 'A small round fox',
              'personality' => %w[curious], 'voice' => 'Soft', 'interests' => %w[stories] }.freeze

  def setup = fresh_host
  def teardown = FileUtils.remove_entry_secure(@host)

  def create(id = 'momo')
    Kairomone::Host.new.create(listing_id: id, profile: PROFILE, profession: { 'template' => 'researcher' }, material_kind: 'free_text')
    Kairomone::Instance.new(host_root: @host, kairomone: id)
  end

  def evidence(content = 'What the cycle learned')
    excerpt = 'Synthetic excerpt.'
    { 'knowledge' => { 'title' => 'Synthesis', 'content' => content }, 'finding' => 'f', 'uncertainty' => 'u', 'counterexample' => 'c',
      'sources' => [{ 'url' => 'https://example.com/a', 'title' => 'Fixture', 'retrieved_at' => Time.now.utc.iso8601,
                      'excerpt' => excerpt, 'retrieval_reference' => 'fixture', 'excerpt_sha256' => Digest::SHA256.hexdigest(excerpt) }] }
  end

  def one_cycle(store, id, content = 'What the cycle learned')
    growth = store.autonomy
    run = growth.run_start(owner_words: 'One cycle', cycles: 1)
    step = { run_id: run[:run_id], token: run[:token] }
    growth.request(**step, request_id: id, topic: 'Secret topic words')
    claim = growth.claim(**step, worker_id: 'worker')
    growth.commit(**step, claim_token: claim['claim_token'], evidence: evidence(content))
  end

  # A Kairomone with an owner-written entry, a learned one, a chat summary, a
  # direction and a drawing.
  def rich
    store = create
    store.create_knowledge(id: 'tea', title: 'Tea notes', content: 'Green tea is steamed.')
    one_cycle(store, 'moss')
    store.configure_companion(request_id: 'dir', expected_revision: 0, direction: { 'preset' => 'custom', 'text' => 'Only gardening secrets' })
    store.configure_companion(request_id: 'mem', expected_revision: 1, memory_enabled: true)
    store.remember_companion(request_id: 'chat', conversation_id: 'cc_one', message_ids: ['m1'], consent_revision: 2,
                             summary: 'A private chat about the garden', memory_enabled: true)
    store.accept_art(proposal: store.propose_art(svg: Kairomone::Art::EGG)[:proposal])
    store
  end

  def all_pages(store, **args)
    first = store.exchange_preview(**args)
    items = first[:items] + (2..first[:pages]).flat_map { |n| store.exchange_preview(**args, page: n)[:items] }
    [first, items]
  end

  def export_and_place(store, include: %w[learned owner_written])
    preview = store.exchange_preview(include: include)
    out = store.exchange_export(file_sha256: preview[:file_sha256])
    FileUtils.mkdir_p(File.join(@host, 'kairomone-inbox'))
    FileUtils.cp(out[:path], File.join(@host, 'kairomone-inbox', out[:file]))
    [preview, out]
  end

  def test_the_written_file_is_the_one_previewed
    store = rich
    preview, out = export_and_place(store)
    assert_equal preview[:file_sha256], Digest::SHA256.file(out[:path]).hexdigest
    assert_match(%r{/kairomone-outbox/momo-\d{8}T\d{6}Z-[0-9a-f]{8}\.kairomone-exchange\.json\z}, out[:path])
    assert_raises(Kairomone::Error) { store.exchange_export(file_sha256: preview[:file_sha256]) }
  end

  def test_a_moved_ledger_head_refuses_the_write
    store = rich
    preview = store.exchange_preview(include: %w[owner_written])
    store.create_knowledge(id: 'later', title: 'Later', content: 'Written after the preview')
    error = assert_raises(Kairomone::Error) { store.exchange_export(file_sha256: preview[:file_sha256]) }
    assert_match(/changed since the preview/, error.message)
    refute Dir.exist?(File.join(@host, 'kairomone-outbox')) && Dir.glob(File.join(@host, 'kairomone-outbox', '*.json')).any?
  end

  def test_an_entry_changed_on_disk_since_the_preview_refuses_the_write
    store = rich
    preview = store.exchange_preview(include: %w[owner_written])
    path = File.join(store.root, 'knowledge/tea/tea.md')
    File.write(path, File.read(path).sub('steamed', 'roasted'))
    error = assert_raises(Kairomone::Error) { store.exchange_export(file_sha256: preview[:file_sha256]) }
    assert_match(/no longer rebuilds/, error.message)
  end

  def test_only_chosen_content_goes_in_and_never_the_private_parts
    store = rich
    first, items = all_pages(store, include: %w[owner_written])
    assert_equal ['tea'], items.select { |i| i['item'] == 'entry' }.map { |i| i['id'] }
    assert_equal ['growth_moss'], first[:left_out][:entries].map { |e| e['id'] }
    _preview, out = export_and_place(store, include: %w[learned owner_written])
    text = File.read(out[:path])
    doc = JSON.parse(text)
    assert_equal %w[growth_moss tea], doc['entries'].map { |e| e['id'] }
    %w[Only\ gardening\ secrets A\ private\ chat Secret\ topic\ words free_text kairomone_chat blockchain runs.json].each do |never|
      refute_includes text, never
    end
    learned = doc['entries'].find { |e| e['id'] == 'growth_moss' }
    assert_equal %w[evidence evidence_sha256 kind l1_id], learned['evidence'].keys.sort, 'carried evidence has no request'
    assert_equal [{ 'id' => 'growth_moss', 'layer' => 'L1' }, { 'id' => 'growth_moss', 'layer' => 'L2' }, { 'id' => 'tea', 'layer' => 'L1' }],
                 doc['xp_basis'].map { |b| b.slice('id', 'layer') }
    assert_equal 'Momo', doc['pieces']['profile']['name']
    refute doc['pieces']['profile'].key?('origin'), 'no material hash'
    assert_equal 1, doc['pieces']['art'].length
  end

  def test_an_import_is_a_new_individual_that_records_what_it_received
    store = rich
    before = { chain: store.chain.latest_block.hash, files: Dir.glob(File.join(store.root, '**', '*')).sort.map { |f| [f, File.file?(f) ? Digest::SHA256.file(f).hexdigest : nil] } }
    level = store.progression_status
    _preview, out = export_and_place(store)
    after = { chain: store.chain.latest_block.hash, files: Dir.glob(File.join(store.root, '**', '*')).sort.map { |f| [f, File.file?(f) ? Digest::SHA256.file(f).hexdigest : nil] } }
    assert_equal before, after, 'the exporter does not change'

    result = Kairomone::Host.new.import_exchange(file: out[:file], listing_id: 'copy')
    assert result[:imported], result.inspect
    copy = Kairomone::Instance.new(host_root: @host, kairomone: 'copy')
    assert_equal 'copy', copy.identity
    assert_equal 'import', Kairomone::Records.of_type(copy.chain, 'kairomone_identity').first['origin']
    refute_empty Kairomone::Records.of_type(copy.chain, 'kairomone_baseline')
    received = Kairomone::Records.of_type(copy.chain, 'kairomone_received').last
    assert_equal JSON.parse(File.read(out[:path]))['manifest_sha256'], received['manifest_sha256']
    assert_equal %w[art profession profile], received['pieces'].map { |p| p['kind'] }.uniq.sort
    lineage = Kairomone::Records.of_type(copy.chain, 'kairomone_lineage').last
    assert_equal ['exchange', 'momo'], [lineage['kind'], lineage['sources'].first['identity']]
    # The copy has exactly the level its carried content gives: the chat
    # summary stayed behind, and so did its XP.
    assert_equal level[:unique_l1], copy.progression_status[:unique_l1]
    assert_equal level[:level], copy.progression_status[:level]
    # Received pieces wait; the copy is an egg under its listing ID.
    assert_equal 'copy', copy.name
    refute copy.profile['profile_present']
    assert_equal [], Kairomone::Records.of_type(copy.chain, 'kairomone_profile'), 'no profile is in force before the owner accepts one'
    assert_equal 'egg', copy.art_get[:shown]
    waiting = copy.proposals[:proposals].select { |p| p['state'] == 'waiting' }.map { |p| p['kind'] }.sort
    assert_equal %w[art profession profile], waiting
    profile = copy.proposals[:proposals].find { |p| p['kind'] == 'profile' }['proposal']
    copy.accept_profile(proposal: profile)
    assert_equal 'Momo', copy.name
    profession = copy.proposals[:proposals].find { |p| p['kind'] == 'profession' && p['state'] == 'waiting' }['proposal']
    assert copy.accept_profession(proposal: profession)[:accepted]
  end

  def test_a_copy_of_a_copy_keeps_its_level
    store = rich
    _preview, out = export_and_place(store)
    Kairomone::Host.new.import_exchange(file: out[:file], listing_id: 'copy')
    copy = Kairomone::Instance.new(host_root: @host, kairomone: 'copy')
    preview = copy.exchange_preview(include: %w[learned owner_written])
    again = copy.exchange_export(file_sha256: preview[:file_sha256])
    assert_equal %w[learned owner_written], JSON.parse(File.read(again[:path]))['entries'].map { |e| e['kind'] }
    FileUtils.cp(again[:path], File.join(@host, 'kairomone-inbox', again[:file]))
    Kairomone::Host.new.import_exchange(file: again[:file], listing_id: 'second')
    second = Kairomone::Instance.new(host_root: @host, kairomone: 'second')
    assert_equal copy.progression_status[:level], second.progression_status[:level]
    body = KairosMcp::KnowledgeProvider.new(nil).get(second.transplant_knowledge(id: 'growth_moss')[:host_name]).content
    assert_includes body, 'Origin: received by exchange from Kairomone copy'
  end

  def test_received_knowledge_is_outside_content_when_transplanted
    store = rich
    _preview, out = export_and_place(store, include: %w[owner_written])
    Kairomone::Host.new.import_exchange(file: out[:file], listing_id: 'copy')
    copy = Kairomone::Instance.new(host_root: @host, kairomone: 'copy')
    body = KairosMcp::KnowledgeProvider.new(nil).get(copy.transplant_knowledge(id: 'tea')[:host_name]).content
    assert body.start_with?("> #{Kairomone::Instance::TRANSPLANT_NOTICE}"), body
    assert_includes body, 'Origin: received by exchange from Kairomone momo'
  end

  def test_an_import_refuses_a_file_whose_identity_does_not_match_its_content
    store = rich
    _preview, out = export_and_place(store, include: %w[owner_written])
    inbox = File.join(@host, 'kairomone-inbox', out[:file])
    doc = JSON.parse(File.read(inbox))
    doc['entries'].first['content'] = 'Something else entirely'
    doc['manifest_sha256'] = Kairomone::Exchange.manifest(doc)
    File.write(inbox, Kairomone::Exchange.bytes(doc))
    error = assert_raises(Kairomone::Error) { Kairomone::Host.new.import_exchange(file: out[:file], listing_id: 'copy') }
    assert_match(/does not match its content/, error.message)
    refute_includes listing, 'copy', 'nothing listed and no ID used'
    doc['entries'].first['content'] = 'Green tea is steamed.'
    File.write(inbox, Kairomone::Exchange.bytes(doc))
    error = assert_raises(Kairomone::Error) { Kairomone::Host.new.import_exchange(file: out[:file], listing_id: 'copy') }
    assert_match(/manifest/, error.message)
  end

  def test_a_tampered_growth_entry_is_refused
    store = rich
    _preview, out = export_and_place(store, include: %w[learned])
    inbox = File.join(@host, 'kairomone-inbox', out[:file])
    original = JSON.parse(File.read(inbox))
    autonomy = store.autonomy
    forge = lambda do |rehash: false, body: false|
      doc = JSON.parse(JSON.generate(original))
      entry = doc['entries'].first
      entry['evidence']['evidence']['knowledge']['content'] = 'Forged synthesis'
      digest = Digest::SHA256.hexdigest(JSON.generate(entry['evidence']['evidence']))
      entry['evidence']['evidence_sha256'] = digest if rehash
      entry['content'] = autonomy.send(:knowledge_body, entry['evidence']['evidence'], digest) if body
      doc['manifest_sha256'] = Kairomone::Exchange.manifest(doc)
      File.write(inbox, Kairomone::Exchange.bytes(doc))
      assert_raises(Kairomone::Error) { Kairomone::Host.new.import_exchange(file: out[:file], listing_id: 'copy') }.message
    end
    assert_match(/does not match its hash/, forge.call)
    assert_match(/not what its evidence says/, forge.call(rehash: true))
    assert_match(/does not match its evidence/, forge.call(rehash: true, body: true))
    refute_includes listing, 'copy'
  end

  def test_the_tool_previews_exports_and_imports
    rich
    preview = tool('Exchange', { 'command' => 'preview', 'include' => %w[owner_written] })
    assert preview['success'], preview['error']
    out = tool('Exchange', { 'command' => 'export', 'kairomone' => 'momo', 'file_sha256' => preview['file_sha256'] })
    assert out['exported'], out.inspect
    FileUtils.mkdir_p(File.join(@host, 'kairomone-inbox'))
    FileUtils.cp(out['path'], File.join(@host, 'kairomone-inbox', out['file']))
    imported = tool('Exchange', { 'command' => 'import', 'file' => out['file'], 'kairomone' => 'copy' })
    assert imported['imported'], imported.inspect
  end
end
