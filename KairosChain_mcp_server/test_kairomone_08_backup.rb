# frozen_string_literal: true

# Kairomone 0.8, backup and restore (design log/kairomone_core_0_8_design_v0.6_FROZEN_20261023.md,
# Inv 1, M15, option A): one path set, completeness, the host archive key,
# signed restores through MCP and the library, other archives only at a
# terminal after their free text is shown. All data is synthetic and confined
# to temporary hosts.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'minitest/autorun'
require 'stringio'
require 'pty'
require_relative 'templates/skillsets/kairomone/test/support_08'

class Kairomone08BackupTest < Minitest::Test
  include Kairomone08Support

  CLI = File.expand_path('templates/skillsets/kairomone/scripts/kairomone.rb', __dir__)

  def setup = fresh_host
  def teardown = FileUtils.remove_entry_secure(@host)

  # What profile acceptance (phase 4) does: the piece, then its record.
  def accept_profile(store, name)
    store.send(:with_lock) do
      sha = store.send(:write_piece, 'profile', Kairomone::Profile.initial(name: name, origin: 'proposal'))
      Kairomone::Records.append!(store.chain, [{ 'type' => 'kairomone_profile', 'sha256' => sha, 'origin' => 'fixture' }], -> { store.chain })
      sha
    end
  end

  def archive_of(backup) = JSON.parse(File.read(backup[:path]))

  def resign(archive, key = File.binread(File.join(@host, 'kairomone-keys/archive.key')))
    archive['manifest_sha256'] = Kairomone::Instance.manifest_hash(archive['files'])
    archive['signature'] = { 'algorithm' => 'HMAC-SHA256', 'key_sha256' => Kairomone::ArchiveKey.fingerprint(key),
                             'value' => Kairomone::ArchiveKey.sign(key, archive['manifest_sha256']) }
    archive
  end

  def entry(path, bytes)
    { 'path' => path, 'size' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes), 'content_base64' => Base64.strict_encode64(bytes) }
  end

  def files_of(root)
    Dir.glob(File.join(root, '**/*'), File::FNM_DOTMATCH).select { |f| File.file?(f) }
       .to_h { |f| [f.delete_prefix(root + '/'), File.binread(f)] }
  end

  def remember(store, request_id, summary)
    unless store.companion_status[:companion]['memory_enabled']
      store.configure_companion(request_id: 'enable', expected_revision: store.companion_status[:companion]['revision'], memory_enabled: true)
    end
    store.remember_companion(request_id: request_id, conversation_id: 'cc_one', message_ids: ['m1'],
                             consent_revision: store.companion_status[:companion]['revision'], summary: summary, memory_enabled: true)
  end

  def test_an_08_individual_with_profile_versions_round_trips
    alpha = make('alpha', 'Alpha')
    first = alpha.current_profile_piece[:sha256]
    second = accept_profile(alpha, 'Alpha renamed')
    alpha.create_knowledge(id: 'note', title: 'Note', content: 'Owner-written L1')
    alpha.observe(title: 'Seen', content: 'Owner-written L2')
    remember(alpha, 'chat', 'A consented summary.')
    backup = alpha.create_backup
    assert backup[:verified] && backup[:signed_by_this_host] && backup[:version] == 2
    paths = archive_of(backup)['files'].map { |f| f['path'] }
    assert_includes paths, "profile/#{first}.json"
    assert_includes paths, "profile/#{second}.json"
    refute paths.any? { |p| p.start_with?('backups/', 'exports/') || p.include?('.lock') || p.include?('.tmp-') }
    result = alpha.restore_backup(file: backup[:file], target_id: 'twin')
    assert_equal 'signed', result[:trust]
    twin = Kairomone::Instance.new(host_root: @host, kairomone: 'twin')
    source = files_of(alpha.root).reject { |p, _| p.start_with?('backups/', 'exports/', 'growth/.lock') || p.end_with?('.lock') }
    copy = files_of(twin.root).reject { |p, _| p.end_with?('.lock') }
    (source.keys - ['storage/blockchain.json']).each { |p| assert_equal source[p], copy[p], p }
    assert_equal second, twin.current_profile_piece[:sha256]
    assert_equal 'Alpha renamed', twin.name
    assert_equal alpha.progression_status, twin.progression_status
  end

  def test_a_version_2_archive_missing_an_accepted_piece_is_refused
    alpha = make('alpha')
    sha = accept_profile(alpha, 'Second version')
    archive = archive_of(alpha.create_backup)
    archive['files'].reject! { |f| f['path'] == "profile/#{sha}.json" }
    FileUtils.mkdir_p(File.join(@host, 'kairomone-inbox'))
    File.write(File.join(@host, 'kairomone-inbox/short.kairomone.json'), JSON.generate(resign(archive)))
    error = assert_raises(Kairomone::Error) do
      Kairomone::Host.new.restore(File.binread(File.join(@host, 'kairomone-inbox/short.kairomone.json')), trust: :signed, listing_id: 'short')
    end
    assert_match(/lacks accepted pieces/, error.message)
    assert_equal ['alpha'], listing
  end

  def test_a_backup_with_an_absent_accepted_piece_is_refused_until_it_is_recorded_missing
    alpha = make('alpha')
    sha = alpha.current_profile_piece[:sha256]
    File.delete(File.join(alpha.root, "profile/#{sha}.json"))
    error = assert_raises(Kairomone::Error) { alpha.create_backup }
    assert_match(/accepted pieces are absent \(profile #{sha[0, 12]}\)/, error.message)
    out = StringIO.new
    refused = alpha.record_missing_interactive(pieces: [{ kind: 'profile', sha256: sha }], reason: 'Lost in a disk failure',
                                               tty_in: StringIO.new("nope\n"), tty_out: out, nonce: 'k7m3xp')
    refute refused[:recorded]
    assert_raises(Kairomone::Error) { alpha.create_backup }
    recorded = alpha.record_missing_interactive(pieces: [{ kind: 'profile', sha256: sha }], reason: 'Lost in a disk failure',
                                                tty_in: StringIO.new("k7m3xp\n"), tty_out: out, nonce: 'k7m3xp')
    assert recorded[:recorded]
    assert_includes out.string, "lost profile #{sha}"
    backup = alpha.create_backup
    assert backup[:verified]
    twin = alpha.restore_backup(file: backup[:file], target_id: 'twin')
    assert twin[:success]
    restored = Kairomone::Instance.new(host_root: @host, kairomone: 'twin')
    assert_equal false, restored.profile['profile_present'], 'without a current profile it is an egg under its listing ID'
    assert_equal 'twin', restored.name
  end

  def test_a_version_1_archive_of_an_08_touched_legacy_individual_restores_and_its_next_backup_too
    legacy = KairomoneLegacyFixture.slot!(@host, dot_id: 'old_one', display_name: 'Old one')
    sha = accept_profile(legacy, 'Old one, renamed in 0.8')
    legacy.create_knowledge(id: 'note', title: 'Note', content: 'Written by 0.8')
    bytes = with_061(@host, "s = Kairomone::Instance.new(host_root: host); b = s.create_backup; puts JSON.generate('bytes' => File.binread(b[:path]))")['bytes']
    assert_equal 1, JSON.parse(bytes)['version']
    refute JSON.parse(bytes)['files'].any? { |f| f['path'].start_with?('profile/') }, '0.6.1 carries what it knows'
    assert_raises(Kairomone::Error) { Kairomone::Host.new.restore(bytes, trust: :signed, listing_id: 'old_copy') }
    shown = nil
    result = Kairomone::Host.new.restore(bytes, trust: ->(lines) { shown = lines; true }, listing_id: 'old_copy')
    assert_equal [{ 'kind' => 'profile', 'sha256' => sha }], result[:missing]
    assert(shown.any? { |l| l.include?('Accepted pieces this archive lacks') })
    copy = Kairomone::Instance.new(host_root: @host, kairomone: 'old_copy')
    assert_equal 'Old one', copy.name, 'it falls back to the schema-1 profile'
    assert_equal 'old_one', copy.identity
    next_backup = copy.create_backup
    assert next_backup[:verified] && next_backup[:version] == 2
    assert copy.restore_backup(file: next_backup[:file], target_id: 'old_copy_two')[:success]
  end

  def test_an_archive_with_a_file_outside_the_path_set_is_refused
    alpha = make('alpha')
    archive = archive_of(alpha.create_backup)
    %w[exports/status.html backups/x.kairomone.json storage/blockchain.json.lock l1_history/state.json].each do |outside|
      tampered = resign(Marshal.load(Marshal.dump(archive)).tap { |a| a['files'] << entry(outside, 'x') })
      error = assert_raises(Kairomone::Error) { Kairomone::Host.new.restore(JSON.generate(tampered), trust: :signed, listing_id: 'bad') }
      assert_match(/Forbidden/, error.message)
    end
    assert_equal ['alpha'], listing
  end

  def test_a_host_with_a_ledger_lock_and_a_stale_temporary_file_backs_up_and_restores
    alpha = make('alpha')
    alpha.observe(title: 'Seen', content: 'Body')
    File.write(File.join(alpha.root, 'storage/blockchain.json.tmp-deadbeefdeadbeef'), 'half a ledger')
    File.write(File.join(alpha.root, 'growth.json.tmp-0000'), 'stale')
    assert File.exist?(File.join(alpha.root, 'storage/blockchain.json.lock'))
    backup = alpha.create_backup
    paths = archive_of(backup)['files'].map { |f| f['path'] }
    refute paths.any? { |p| p.include?('.tmp-') || p.end_with?('.lock') }
    assert alpha.restore_backup(file: backup[:file], target_id: 'twin')[:success]
    refute File.exist?(File.join(@host, 'kairomones/twin/storage/blockchain.json.tmp-deadbeefdeadbeef'))
  end

  def test_the_mcp_restore_refuses_an_unsigned_or_foreign_signed_archive
    alpha = make('alpha')
    archive = archive_of(alpha.create_backup)
    inbox = File.join(@host, 'kairomone-inbox')
    FileUtils.mkdir_p(inbox)
    unsigned = Marshal.load(Marshal.dump(archive)).tap { |a| a.delete('signature') }
    File.write(File.join(inbox, 'unsigned.kairomone.json'), JSON.generate(unsigned))
    File.write(File.join(inbox, 'foreign.kairomone.json'), JSON.generate(resign(Marshal.load(Marshal.dump(archive)), SecureRandom.random_bytes(32))))
    File.write(File.join(inbox, 'own.kairomone.json'), JSON.generate(archive))
    %w[unsigned foreign].each do |name|
      result = tool(:Backup, 'command' => 'restore_new', 'file' => "#{name}.kairomone.json", 'dot_id' => 'alpha', 'target_id' => "#{name}_copy")
      assert_equal false, result['success'], name
      assert_match(/not signed with this host's archive key/, result['error'])
    end
    assert_equal ['alpha'], listing
    result = tool(:Backup, 'command' => 'restore_new', 'file' => 'own.kairomone.json', 'dot_id' => 'alpha', 'target_id' => 'own_copy')
    assert result['success'], result.inspect
    assert_equal %w[alpha own_copy], listing
  end

  def test_the_terminal_restore_shows_the_free_text_and_proceeds_only_on_the_typed_code
    alpha = make('alpha', 'Alpha')
    alpha.configure_companion(request_id: 'set', expected_revision: 0, personality: 'Speaks in haiku',
                              direction: { 'preset' => 'custom', 'text' => 'Only gardening' })
    alpha.create_knowledge(id: 'owned', title: 'An owner-written title', content: 'Body')
    remember(alpha, 'chat', 'Talked about tomatoes.')
    archive = archive_of(alpha.create_backup)
    archive.delete('signature') # as from another machine
    Dir.mktmpdir('kairomone-08-terminal-') do |other|
      FileUtils.cp_r(File.join(@host, 'skills'), other)
      FileUtils.mkdir_p(File.join(other, 'kairomone-inbox'))
      File.write(File.join(other, 'kairomone-inbox/moved.kairomone.json'), JSON.generate(archive))
      at_tty = lambda do |answer|
        output = +''
        PTY.spawn({ 'KAIROS_DATA_DIR' => other }, RbConfig.ruby, '-I', File.expand_path('lib', __dir__), CLI,
                  'backup', 'restore-new', '--file', 'moved.kairomone.json', '--dot-id', 'alpha') do |reader, writer, pid|
          begin
            output << reader.readpartial(4096) until output =~ /Type (\w{6}) to restore/
            writer.puts(answer.call(Regexp.last_match(1)))
            loop { output << reader.readpartial(4096) }
          rescue Errno::EIO, EOFError
            nil
          end
          Process.wait(pid)
        end
        output
      end
      cancelled = at_tty.call(->(_code) { 'wrong' })
      %w[Speaks\ in\ haiku Only\ gardening An\ owner-written\ title Chat\ summaries:\ 1 Conversation\ summary not\ signed\ by\ this\ host].each do |text|
        assert_includes cancelled, text
      end
      assert_includes cancelled, 'Cancelled. Nothing was restored.'
      assert_empty Kairomone::Host.new(host_root: other).listing
      restored = at_tty.call(->(code) { code })
      assert_includes restored, '"trust": "owner_confirmed"'
      assert_equal ['alpha'], Kairomone::Host.new(host_root: other).listing.map { |l| l[:listing_id] }
    end
  end

  def test_the_terminal_summary_shows_entries_named_like_growth_that_no_cycle_recorded
    alpha = make('alpha')
    alpha.create_knowledge(id: 'growth_hidden', title: 'Text the archive author wants unseen', content: 'Body')
    one = alpha.create_backup
    archive = archive_of(one)
    archive.delete('signature')
    shown = nil
    Kairomone::Host.new.restore(JSON.generate(archive), trust: ->(lines) { shown = lines; false }, listing_id: 'copy') rescue nil
    assert(shown.any? { |l| l.include?('Text the archive author wants unseen') }, shown.inspect)
  end

  def test_restore_new_takes_a_target_id_when_the_identity_is_listed
    alpha = make('alpha')
    backup = alpha.create_backup
    FileUtils.mkdir_p(File.join(@host, 'kairomone-inbox'))
    FileUtils.cp(backup[:path], File.join(@host, 'kairomone-inbox', backup[:file]))
    refused = tool(:Backup, 'command' => 'restore_new', 'file' => backup[:file], 'dot_id' => 'alpha')
    assert_match(/already listed/, refused['error'])
    restored = tool(:Backup, 'command' => 'restore_new', 'file' => backup[:file], 'dot_id' => 'alpha', 'target_id' => 'alpha_copy')
    assert restored['success'], restored.inspect
    assert_equal({ 'listing_id' => 'alpha_copy', 'identity' => 'alpha' }, restored['kairomone'])
    assert_match(/Name a target_id/, tool(:Backup, 'kairomone' => 'alpha', 'command' => 'restore', 'file' => backup[:file])['error'])
  end

  def test_the_terminal_prompts_hold_no_lock_while_the_owner_reads
    alpha = make('alpha')
    sha = alpha.current_profile_piece[:sha256]
    File.delete(File.join(alpha.root, "profile/#{sha}.json"))
    free = lambda do |lock|
      Thread.new { lock.call }.join(2) ? true : false
    end
    answer = Object.new
    other = Kairomone::Instance.new(host_root: @host, kairomone: 'alpha')
    answer.define_singleton_method(:gets) do
      raise 'the growth lock was held during the prompt' unless free.call(-> { other.autonomy.synchronize { nil } })
      raise 'the instance lock was held during the prompt' unless free.call(-> { other.send(:with_lock) { nil } })
      "k7m3xp\n"
    end
    assert alpha.record_missing_interactive(pieces: [{ kind: 'profile', sha256: sha }], reason: 'Lost', tty_in: answer,
                                            tty_out: StringIO.new, nonce: 'k7m3xp')[:recorded]
    archive = archive_of(alpha.create_backup)
    archive.delete('signature')
    registry_free = nil
    confirm = lambda do |_lines|
      registry_free = free.call(-> { Kairomone::Host.new(host_root: @host).with_registry_lock { nil } })
      true
    end
    assert Kairomone::Host.new.restore(JSON.generate(archive), trust: confirm, listing_id: 'copy')[:success]
    assert registry_free, 'the registry lock was free while the owner read the summary'
  end
end
