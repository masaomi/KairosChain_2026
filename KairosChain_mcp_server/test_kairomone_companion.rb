# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'kairomone'
require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require_relative 'templates/skillsets/kairomone/test/legacy_fixture'

# Kairomone 0.8 (design log/kairomone_core_0_8_design_v0.6_FROZEN_20261023.md):
# companion settings are those of an individual made before 0.8 here, so the
# fixture builds that legacy slot as 0.6.1's init left it (M1: 0.8 never
# creates one; Inv 1, Inv 4: it keeps working in place and its direction and
# personality stay in force), on a host with L0 so a run can start. A restore
# makes a separate, writable listed twin (Inv 1, M15) instead of a read-only
# copy; a move to a fresh host copies the archive key. Direction is captured
# per request inside an owner-started run (Inv 2, M6).
class KairomoneCompanionTest < Minitest::Test
  def setup
    @host = Dir.mktmpdir('kairomone-companion-')
    KairosMcp.data_dir = @host
    FileUtils.mkdir_p(File.join(@host, 'skills'))
    File.write(File.join(@host, 'skills/kairos.md'), '# synthetic philosophy')
    @store = KairomoneLegacyFixture.slot!(@host, dot_id: 'fixed_id', display_name: 'Original')
  end
  def teardown
    FileUtils.remove_entry(@host)
  end
  def enable
    @store.configure_companion(request_id: 'enable', expected_revision: 0, memory_enabled: true)
  end
  def remember(**overrides)
    @store.remember_companion(**{ request_id: 'summary_one', conversation_id: 'conversation_one', message_ids: ['message_one'], consent_revision: 1, summary: 'The owner prefers concise examples.', memory_enabled: true }.merge(overrides))
  end
  def test_legacy_profile_unchanged_lazy_migration_and_fixed_identity
    profile = File.binread(File.join(@store.root, 'profile.json'))
    assert_equal false, @store.companion_status[:companion]['memory_enabled']
    refute File.exist?(File.join(@store.root, 'companion/state.json'))
    @store.observe(id: 'legacy', title: 'Legacy', content: 'Prior observation')
    @store.create_knowledge(id: 'verified', title: 'Verified', content: 'Prior knowledge')
    before = @store.progression_status
    changed = @store.configure_companion(request_id: 'rename', expected_revision: 0, display_name: 'Named Kairomon', direction: { 'preset' => 'research', 'text' => 'Read primary sources' })
    assert_equal 'fixed_id', changed[:companion]['dot_id']
    assert_equal 'Named Kairomon', changed[:companion]['display_name']
    assert_equal before, @store.progression_status
    assert_equal profile, File.binread(File.join(@store.root, 'profile.json'))
    assert_equal 1, changed[:companion]['history'].length
    assert @store.configure_companion(request_id: 'rename', expected_revision: 0, display_name: 'Named Kairomon', direction: { 'preset' => 'research', 'text' => 'Read primary sources' })[:preserved]
    assert_raises(Kairomone::Error) { @store.configure_companion(request_id: 'rename', expected_revision: 0, display_name: 'Other') }
    assert_raises(Kairomone::Error) { @store.configure_companion(request_id: 'stale', expected_revision: 0, display_name: 'Other') }
  end
  def test_consent_dedup_zero_xp_and_no_raw_chat
    assert_raises(Kairomone::Error) { remember }
    enable
    assert_raises(Kairomone::Error) { remember(memory_enabled: false) }
    assert_raises(Kairomone::Error) { remember(consent_revision: 0) }
    @store.observe(id: 'legacy', title: 'Legacy', content: 'Old observation')
    before = @store.progression_status
    result = remember
    assert_equal false, result[:xp_eligible]
    assert_equal 'kairomone_chat', result[:session]
    assert remember[:preserved]
    remember(request_id: 'summary_two', summary: 'In conversation the owner preferred concise examples.')
    assert_equal before, @store.progression_status
    assert_equal 2, @store.status[:chat_memory][:count]
    assert_equal 1, @store.observation_entries.length
    state = File.read(File.join(@store.root, 'companion/state.json'))
    refute_includes state, 'The owner prefers concise examples.'
    assert_raises(Kairomone::Error) { remember(summary: 'Different text') }
    @store.configure_companion(request_id: 'disable', expected_revision: 1, memory_enabled: false)
    assert_raises(Kairomone::Error) { remember }
    assert @store.companion_context(query: 'examples')[:references].any? { |r| r[:source] == 'chat_summary' }
  end
  def test_chat_copy_does_not_award_xp_and_preexisting_content_keeps_credit
    enable
    remember
    @store.observe(id: 'copied_l2', title: 'Copied', content: 'The owner prefers concise examples.')
    assert_equal 0, @store.progression_status[:total_xp]
    @store.create_knowledge(id: 'copied_l1', title: 'Copied', content: 'The owner prefers concise examples.')
    assert_equal 0, @store.progression_status[:total_xp]
    @store.observe(id: 'prior', title: 'Prior', content: 'Existing original observation')
    before = @store.progression_status
    remember(request_id: 'prior_summary', summary: 'Existing original observation')
    assert_equal before, @store.progression_status
    remember(request_id: 'crlf', summary: "Apples\r\npreferred.")
    @store.observe(id: 'crlf_copy', title: 'Copied', content: "Apples\r\npreferred.")
    assert_equal before, @store.progression_status
  end

  def test_context_provenance_and_bounds
    enable; result = remember
    @store.create_knowledge(id: 'verified', title: 'Examples', content: 'Concise examples backed by sources')
    ctx = @store.companion_context(query: 'concise', limit: 2)
    assert_equal 2, ctx[:references].length
    assert_equal 'fixed_id', ctx[:companion]['dot_id']
    assert ctx[:references].all? { |r| r[:sha256].match?(/\A[0-9a-f]{64}\z/) && r[:version] && r[:content].bytesize <= 6000 }
    path = File.join(@store.root, "context/kairomone_chat/#{result[:id]}/#{result[:id]}.md")
    File.write(path, File.read(path).sub('concise examples', 'fabricated secrets'))
    assert_raises(Kairomone::Error) { @store.companion_context(query: 'examples') }
    assert @store.status[:error]
  end
  def test_backup_restore_and_restored_write_denied
    enable; remember
    backup = @store.create_backup
    assert backup[:verified]
    @store.restore_backup(file: backup[:file], target_id: 'copy')
    restored = Kairomone::Instance.new(host_root: @host, kairomone: 'copy')
    assert_equal @store.companion_status, restored.companion_status
    assert_equal 1, restored.status[:chat_memory][:count]
    assert_equal 0, restored.progression_status[:total_xp]
    original = @store.companion_status
    restored.configure_companion(request_id: 'twin_only', expected_revision: 1, display_name: 'Twin')
    assert_equal original, @store.companion_status, 'the twin is a separate individual'
    Dir.mktmpdir('companion-new-') do |fresh|
      FileUtils.cp_r(File.join(@host, 'kairomone-keys'), fresh) # the owner copies the archive key
      FileUtils.mkdir_p(File.join(fresh, 'kairomone-inbox'))
      FileUtils.cp(backup[:path], File.join(fresh, 'kairomone-inbox', backup[:file]))
      active = Kairomone::Instance.new(host_root: fresh)
      assert active.restore_new(file: backup[:file], dot_id: 'fixed_id')[:success]
      assert_equal @store.companion_status, active.companion_status
      assert_equal 1, active.status[:chat_memory][:count]
    end
  end
  def test_reserved_write_recovery_and_secret_rejection
    enable
    assert_raises(Kairomone::Error) { remember(summary: 'api_key=supersecret') }
    assert_equal 0, @store.companion_status[:companion]['memory_count']
    result = remember
    state_path = File.join(@store.root, 'companion/state.json')
    state = JSON.parse(File.read(state_path)); state['memories']['summary_one']['state'] = 'reserved'
    File.write(state_path, JSON.generate(state))
    assert_raises(Kairomone::Error) { @store.create_backup }
    assert remember[:preserved]
    assert_equal 0, @store.progression_status[:total_xp]
    state = JSON.parse(File.read(state_path)); state['memories'] = {}
    File.write(state_path, JSON.generate(state))
    assert_raises(Kairomone::Error) { @store.companion_context(query: 'examples') }
  end
  def test_pending_receipt_recovery_after_settings_change_never_rewrites_summary
    enable; result = remember
    path = File.join(@store.root, 'companion/state.json')
    state = JSON.parse(File.read(path)); state['memories']['summary_one']['state'] = 'reserved'
    File.write(path, JSON.generate(state))
    @store.configure_companion(request_id: 'disable_pending', expected_revision: 1, memory_enabled: false)
    assert_raises(Kairomone::Error) { remember }
    recovered = @store.recover_companion_memory(request_id: 'summary_one')
    assert_equal 'completed', recovered[:state]
    assert_equal false, recovered[:canonical_write_performed]
    assert @store.create_backup[:verified]
    state = JSON.parse(File.read(path)); state['memories']['summary_one']['state'] = 'reserved'
    File.write(path, JSON.generate(state))
    File.unlink(File.join(@store.root, 'context/kairomone_chat', result[:id], result[:id] + '.md'))
    assert_equal 'cancelled', @store.recover_companion_memory(request_id: 'summary_one')[:state]
    assert @store.create_backup[:verified]
    assert @store.recover_companion_memory(request_id: 'summary_one')[:preserved]
  end

  def test_capacity_independent_revocation_and_no_reenable_on_retry
    enable
    @store.revoke_companion_memory
    assert_equal false, @store.companion_status[:companion]['memory_enabled']
    assert_raises(Kairomone::Error) { remember }
    enable # exact replay must not clear revocation
    assert_equal false, @store.companion_status[:companion]['memory_enabled']
    @store.configure_companion(request_id: 'renamed', expected_revision: 1, display_name: 'New')
    assert_equal false, @store.companion_status[:companion]['memory_enabled']
    @store.configure_companion(request_id: 'reenable', expected_revision: 2, memory_enabled: true)
    assert_equal true, @store.companion_status[:companion]['memory_enabled']
    @store.revoke_companion_memory
    backup = @store.create_backup
    @store.restore_backup(file: backup[:file], target_id: 'revoked')
    assert_equal false, Kairomone::Instance.new(host_root: @host, kairomone: 'revoked').companion_status[:companion]['memory_enabled']
  end

  def test_direction_is_captured_for_new_request_not_retroactively
    run = @store.autonomy.run_start(owner_words: 'Fixture run', cycles: 5)
    step = { run_id: run[:run_id], token: run[:token] }
    @store.autonomy.request(**step, request_id: 'cycle_one', topic: 'Evidence')
    first = @store.autonomy.status['queue']['companion']
    assert_equal 0, first['revision']
    @store.configure_companion(request_id: 'direction', expected_revision: 0, direction: { 'preset' => 'research', 'text' => 'New topic' })
    assert_equal first, @store.autonomy.status['queue']['companion']
    assert @store.autonomy.request(**step, request_id: 'cycle_one', topic: 'Evidence')['preserved']
    @store.autonomy.run_stop(reason: 'Fixture stop')
    run = @store.autonomy.run_start(owner_words: 'Fixture run two', cycles: 5)
    @store.autonomy.request(run_id: run[:run_id], token: run[:token], request_id: 'cycle_two', topic: 'New evidence')
    assert_equal 1, @store.autonomy.status['queue']['companion']['revision']
    assert_equal 'New topic', @store.autonomy.status['queue']['companion']['direction']['text']
  end

  def test_json_stdin_cli_and_unknown_field
    cli = File.expand_path('templates/skillsets/kairomone/scripts/kairomone.rb', __dir__)
    out, _err, status = Open3.capture3({ 'KAIROS_DATA_DIR' => @host }, RbConfig.ruby, cli, 'companion', 'configure', '--json-stdin', stdin_data: JSON.generate(request_id: 'cli', expected_revision: 0, display_name: 'CLI name'))
    assert status.success?, out
    assert_equal 'CLI name', JSON.parse(out).dig('companion', 'display_name')
    assert_equal 'fixed_id', @store.companion_status[:companion]['dot_id']
    bad, _err, result = Open3.capture3({ 'KAIROS_DATA_DIR' => @host }, RbConfig.ruby, cli, 'companion', 'configure', '--json-stdin', stdin_data: '{private_secret')
    refute result.success?
    refute_includes bad, 'private_secret'
    assert_raises(ArgumentError) { @store.configure_companion(request_id: 'x', expected_revision: 1, dot_id: 'changed') }
  end
end
