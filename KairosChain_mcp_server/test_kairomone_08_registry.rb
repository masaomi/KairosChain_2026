# frozen_string_literal: true

# Kairomone 0.8, many individuals (design log/kairomone_core_0_8_design_v0.6_FROZEN_20261023.md,
# Inv 1, M1, M2, M5): the registry, staging and one-step listing, addressing,
# identity and baseline records, the legacy slot served in place and still
# readable by 0.6.1. All data is synthetic and confined to temporary hosts.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'minitest/autorun'
require_relative 'templates/skillsets/kairomone/test/support_08'

class Kairomone08RegistryTest < Minitest::Test
  include Kairomone08Support

  def setup = fresh_host
  def teardown = FileUtils.remove_entry_secure(@host)

  def test_every_new_individual_opens_its_ledger_with_identity_baseline_and_profile
    store = Kairomone::Instance.new(bind: false)
    store.init(dot_id: 'alpha', display_name: 'Alpha')
    assert_equal File.join(File.realpath(@host), 'kairomones', 'alpha'), store.root
    refute File.exist?(File.join(@host, 'kairomone')), '0.8 never creates the legacy slot'
    assert_equal %w[kairomone_identity kairomone_baseline kairomone_profile], types(store)
    identity = Kairomone::Records.of_type(store.chain, 'kairomone_identity').first
    assert_equal({ 'type' => 'kairomone_identity', 'identity' => 'alpha', 'origin' => 'create', 'listing_id' => 'alpha' }, identity)
    assert_equal store.send(:l0_fingerprints), Kairomone::Records.of_type(store.chain, 'kairomone_baseline').first['files']
    sha = Kairomone::Records.of_type(store.chain, 'kairomone_profile').first['sha256']
    assert_equal sha, Digest::SHA256.file(File.join(store.root, "profile/#{sha}.json")).hexdigest
    assert_equal 'Alpha', store.name
  end

  def test_two_individuals_are_isolated
    a = make('alpha')
    b = make('beta')
    b_before = Dir.glob(File.join(b.root, '**/*'), File::FNM_DOTMATCH).select { |f| File.file?(f) }.to_h { |f| [f, File.binread(f)] }
    assert a.create_knowledge(id: 'note', title: 'Alpha note', content: 'Only alpha')[:success]
    assert a.observe(title: 'Alpha seen', content: 'Only alpha L2')[:success]
    b_after = Dir.glob(File.join(b.root, '**/*'), File::FNM_DOTMATCH).select { |f| File.file?(f) }.to_h { |f| [f, File.binread(f)] }
    assert_equal b_before, b_after
    assert_equal 0, b.status[:knowledge][:count]
    assert_equal 60, a.progression_status[:total_xp]
    assert_equal 0, b.progression_status[:total_xp]
  end

  def test_writes_without_a_name_are_refused_when_two_exist_and_reads_list_them
    make('alpha')
    single = tool(:Observe, 'title' => 'One', 'content' => 'Only one listed')
    assert single['success'] && single.dig('kairomone', 'listing_id') == 'alpha', 'with one listed, an omitted name means that one'
    make('beta')
    refused = tool(:Observe, 'title' => 'Which', 'content' => 'No name')
    assert_equal false, refused['success']
    assert_match(/2 Kairomones live on this host/, refused['error'])
    listed = tool(:Status, {})
    assert listed['several']
    assert_equal %w[alpha beta], listed['kairomones'].map { |k| k['listing_id'] }
    named = tool(:Observe, 'kairomone' => 'beta', 'title' => 'Beta', 'content' => 'Named')
    assert_equal({ 'listing_id' => 'beta', 'identity' => 'beta' }, named['kairomone'], 'a write says which individual it changed')
    assert_equal %w[alpha beta], tool(:List, {})['kairomones'].map { |k| k['listing_id'] }
    assert_equal false, tool(:Knowledge, 'kairomone' => 'gamma', 'command' => 'list')['success']
  end

  def test_init_is_the_one_individual_shorthand
    store = Kairomone::Instance.new(bind: false)
    store.init(dot_id: 'alpha', display_name: 'Alpha')
    assert store.init(dot_id: 'alpha', display_name: 'Ignored')[:preserved]
    error = assert_raises(Kairomone::Error) { Kairomone::Instance.new(bind: false).init(dot_id: 'beta', display_name: 'Beta') }
    assert_match(/kairomone_create/, error.message)
    assert_equal ['alpha'], listing
  end

  def test_init_is_refused_on_a_listing_id_used_by_another_identity
    alpha = make('alpha')
    alpha.create_knowledge(id: 'note', title: 'Note', content: 'Body')
    backup = alpha.create_backup
    alpha.restore_backup(file: backup[:file], target_id: 'beta')
    FileUtils.rm_rf(alpha.root)
    assert_equal ['beta'], listing
    error = assert_raises(Kairomone::Error) { Kairomone::Instance.new(bind: false).init(dot_id: 'beta', display_name: 'Beta') }
    assert_match(/another identity \(alpha\)/, error.message)
  end

  def test_an_interrupted_assembly_lists_nothing_and_uses_no_id
    host = Kairomone::Host.new(host_root: @host)
    assert_raises(RuntimeError) do
      host.with_registry_lock do
        host.assemble('alpha') do |staged|
          staged.open_new!(identity: 'alpha', origin: 'create', listing_id: 'alpha', name: 'Alpha')
          raise 'interrupted after the ledger opened'
        end
      end
    end
    assert_empty listing
    assert_empty Dir.children(File.join(@host, 'kairomones/.staging'))
    # A crash leaves a staging directory behind; it is never listed, and the
    # next registry operation removes it.
    leftover = File.join(@host, 'kairomones/.staging/sdeadbeef')
    FileUtils.mkdir_p(File.join(leftover, 'storage'))
    assert_empty listing
    make('alpha')
    refute File.exist?(leftover)
    assert_equal ['alpha'], listing
  end

  def test_an_interrupted_restore_lists_nothing
    alpha = make('alpha')
    alpha.observe(title: 'Seen', content: 'Body')
    backup = alpha.create_backup
    unsigned = JSON.parse(File.binread(backup[:path]))
    unsigned.delete('signature')
    host = Kairomone::Host.new(host_root: @host)
    staged_seen = nil
    # The interruption comes while the archive is assembled in staging (here,
    # at the owner's confirmation of an unsigned copy).
    assert_raises(Kairomone::Error) do
      host.restore(JSON.generate(unsigned), listing_id: 'twin', trust: ->(lines) { staged_seen = lines; raise Kairomone::Error, 'power cut' })
    end
    refute_nil staged_seen
    assert_equal ['alpha'], listing
    assert_empty Dir.children(File.join(@host, 'kairomones/.staging'))
    assert make('twin'), 'the listing ID stays unused'
  end

  def test_staging_cleanup_never_meets_a_live_assembly
    host = Kairomone::Host.new(host_root: @host)
    staged_path = Queue.new
    release = Queue.new
    assembler = Thread.new do
      host.with_registry_lock do
        host.assemble('alpha') do |staged|
          staged.open_new!(identity: 'alpha', origin: 'create', listing_id: 'alpha', name: 'Alpha')
          staged_path << staged.root
          release.pop
        end
      end
    end
    path = staged_path.pop
    other = Thread.new { Kairomone::Host.new(host_root: @host).with_registry_lock { :cleaned } }
    sleep 0.3
    assert other.alive?, 'cleanup waits for the registry lock the assembly holds'
    assert File.directory?(path), 'the staging directory survives while it is assembled'
    release << true
    assembler.join
    assert_equal :cleaned, other.value
    assert_equal ['alpha'], listing
  end

  def test_listing_ids_are_unique_across_the_legacy_slot_and_the_registry
    legacy = KairomoneLegacyFixture.slot!(@host, dot_id: 'old_one', display_name: 'Old one')
    assert_equal ['old_one'], listing
    assert legacy.legacy_slot?
    error = assert_raises(Kairomone::Error) { make('old_one') }
    assert_match(/already listed/, error.message)
    make('fresh')
    assert_equal %w[fresh old_one], listing
  end

  def test_the_legacy_slot_is_served_in_place_and_its_blocks_never_change
    legacy = KairomoneLegacyFixture.slot!(@host, dot_id: 'old_one', display_name: 'Old one')
    # A ledger an earlier Kairomone wrote: one L1 entry recorded by 0.6.1.
    with_061(@host, "s = Kairomone::Instance.new(host_root: host); puts JSON.generate(s.create_knowledge(id: 'early', title: 'Early', content: 'Written by 0.6.1'))")
    before = JSON.parse(File.read(File.join(legacy.root, 'storage/blockchain.json')))
    assert legacy.create_knowledge(id: 'later', title: 'Later', content: 'Written by 0.8')[:success]
    after = JSON.parse(File.read(File.join(legacy.root, 'storage/blockchain.json')))
    assert_equal before, after.first(before.length), 'existing blocks keep their bytes and hashes'
    assert legacy.chain.valid?
    assert_equal 'old_one', legacy.identity
    assert_equal({ listing_id: 'old_one', identity: 'old_one' }, legacy.address)
    assert File.file?(File.join(legacy.root, 'profile.json'))
    refute File.exist?(File.join(@host, 'kairomones', 'old_one'))
  end

  def test_a_legacy_slot_written_by_08_is_still_read_and_backed_up_by_061
    legacy = KairomoneLegacyFixture.slot!(@host, dot_id: 'old_one', display_name: 'Old one')
    legacy.create_knowledge(id: 'note', title: 'Note', content: 'Owner-written L1')
    legacy.observe(title: 'Seen', content: 'Owner-written L2')
    legacy.configure_companion(request_id: 'enable', expected_revision: 0, memory_enabled: true)
    legacy.remember_companion(request_id: 'chat_one', conversation_id: 'cc_one', message_ids: ['m1'], consent_revision: 1,
                              summary: 'The owner likes short answers.', memory_enabled: true)
    growth = legacy.autonomy
    run = growth.run_start(owner_words: 'One cycle', cycles: 1)
    growth.request(run_id: run[:run_id], token: run[:token], request_id: 'cycle', topic: 'Topic')
    claim = growth.claim(run_id: run[:run_id], token: run[:token], worker_id: 'worker')
    excerpt = 'Synthetic excerpt.'
    growth.commit(run_id: run[:run_id], token: run[:token], claim_token: claim['claim_token'],
                  evidence: { 'knowledge' => { 'title' => 'Synthesis', 'content' => 'Synthetic content' }, 'finding' => 'f',
                              'uncertainty' => 'u', 'counterexample' => 'c',
                              'sources' => [{ 'url' => 'https://example.com/a', 'title' => 'Fixture', 'retrieved_at' => Time.now.utc.iso8601,
                                              'excerpt' => excerpt, 'retrieval_reference' => 'fixture', 'excerpt_sha256' => Digest::SHA256.hexdigest(excerpt) }] })
    seen = with_061(@host, <<~RUBY)
      s = Kairomone::Instance.new(host_root: host)
      st = s.status
      b = s.create_backup
      puts JSON.generate('error' => st[:error], 'valid' => st[:integrity][:valid], 'knowledge' => st[:knowledge][:count],
                         'observations' => st[:observations][:count], 'chats' => st[:chat_memory][:count],
                         'dot_id' => st[:profile]['dot_id'], 'backup' => b[:verified])
    RUBY
    assert_nil seen['error']
    assert seen['valid']
    assert_equal 2, seen['knowledge']
    assert_equal 2, seen['observations']
    assert_equal 1, seen['chats']
    assert_equal 'old_one', seen['dot_id']
    assert seen['backup']
  end

  def test_two_061_backups_sharing_an_identity_restore_onto_one_host
    archives = 2.times.map do |n|
      Dir.mktmpdir('kairomone-061-host-') do |old|
        FileUtils.cp_r(File.join(@host, 'skills'), old)
        with_061(old, <<~RUBY)
          s = Kairomone::Instance.new(host_root: host)
          s.init(dot_id: 'masai', display_name: 'MasAI #{n}')
          s.create_knowledge(id: 'note_#{n}', title: "Tab\\there and line\\nbreak #{n}", content: 'Old knowledge #{n}')
          b = s.create_backup
          puts JSON.generate('bytes' => File.binread(b[:path]))
        RUBY
      end['bytes']
    end
    host = Kairomone::Host.new(host_root: @host)
    first = host.restore(archives[0], trust: ->(_lines) { true }, expected_identity: 'masai')
    assert_equal({ listing_id: 'masai', identity: 'masai' }, first[:kairomone])
    assert_raises(Kairomone::Error) { host.restore(archives[1], trust: ->(_lines) { true }) }
    second = host.restore(archives[1], trust: ->(_lines) { true }, listing_id: 'masai_two')
    assert_equal({ listing_id: 'masai_two', identity: 'masai' }, second[:kairomone])
    assert_equal %w[masai masai_two], listing
    twin = Kairomone::Instance.new(host_root: @host, kairomone: 'masai_two')
    assert_equal "Tab\there and line\nbreak 1", twin.read_knowledge(id: 'note_1')[:title], 'stored titles restore as they were'
    restored = Kairomone::Records.of_type(twin.chain, 'kairomone_restored').first
    assert_equal 'owner_confirmed', restored['trust']
    assert_equal 1, restored['archive_version']
    assert_equal 'masai_two', restored['listing_id']
  end
end
