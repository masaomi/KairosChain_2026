# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'kairomone'
require 'minitest/autorun'
require 'tmpdir'
require 'open3'

# Kairomone 0.8 (design log/kairomone_core_0_8_design_v0.6_FROZEN_20261023.md):
# a restore makes a separate listed individual (a writable twin under
# target_id) instead of a read-only copy (Inv 1, M15); an archive whose
# checksums were recomputed loses this host's signature, so the library path
# refuses it, and the terminal path still refuses its invalid profession; the
# 0.6 lifetime budget (growth configure) is gone and the CLI starts a run
# instead, with no limit on cycles (Inv 2, M6).
class KairomoneProgressionTest < Minitest::Test
  def setup
    @host = Dir.mktmpdir('kairomone-progression-')
    KairosMcp.data_dir = @host
    @store = Kairomone::Instance.new
    @store.init(dot_id: 'test_dot', display_name: 'Test')
  end

  def teardown
    FileUtils.remove_entry(@host)
  end

  def observe(id, body)
    @store.observe(id: id, title: id, content: body)
  end

  def knowledge(id, body)
    @store.create_knowledge(id: id, title: id, content: body)
  end

  def test_initial_unselected_and_level_one
    snapshot = @store.status
    assert_equal 1, snapshot[:progression][:level]
    assert_equal 0, snapshot[:progression][:total_xp]
    assert_nil snapshot[:profession][:selected_id]
    assert_equal 'generalist', snapshot[:profession][:effective_id]
    refute File.exist?(File.join(@store.root, 'profession.json'))
  end

  def test_unique_content_not_ids_titles_or_retries_rewards_xp
    observe('one', 'same body')
    assert observe('one', 'same body')[:preserved]
    observe('two', 'same body')
    assert_equal 10, @store.progression_status[:total_xp]
    knowledge('three', 'same body')
    knowledge('four', 'same body')
    assert_equal 50, @store.progression_status[:total_xp]
    assert_equal 1, @store.progression_status[:unique_l1]
    assert_equal 0, @store.progression_status[:unique_l2]
    assert_raises(Kairomone::Error) { observe('one', 'different') }
  end

  def test_current_data_only_and_no_credit_for_unverified_knowledge
    knowledge('one', 'first')
    assert_equal 50, @store.progression_status[:total_xp]
    path = File.join(@store.root, 'knowledge/one/one.md')
    File.write(path, File.read(path).sub('first', 'tampered'))
    assert_equal 0, @store.progression_status[:total_xp]
    observe('two', 'second')
    assert_equal 10, @store.progression_status[:total_xp]
    FileUtils.remove_entry(File.join(@store.root, 'context/kairomone/two'))
    assert_equal 0, @store.progression_status[:total_xp]
  end

  def test_level_cap_and_threshold_math
    result = Kairomone::Progression.calculate(l1_fingerprints: (1..1000).map(&:to_s), l2_fingerprints: [])
    assert_equal 999, result[:level]
    assert_nil result[:xp_for_next_level]
    assert_equal 0, result[:xp_to_next_level]
    result = Kairomone::Progression.calculate(l1_fingerprints: [], l2_fingerprints: %w[a b])
    assert_equal 2, result[:level]
    assert_equal 0, result[:xp_into_level]
  end

  def test_explicit_profession_unlock_selection_and_persistence
    assert_raises(Kairomone::Error) { @store.select_profession(id: 'researcher') }
    assert_raises(Kairomone::Error) { @store.select_profession(id: '../researcher') }
    knowledge('one', 'first')
    knowledge('two', 'second')
    assert_equal 6, @store.progression_status[:level]
    result = @store.select_profession(id: 'researcher')
    assert result[:success]
    assert_equal 'researcher', result[:profession][:effective_id]
    assert_equal 0.5, result[:profession][:learning_bias][:max_topic_fraction]
    refute_empty result[:profession][:learning_bias][:topics]
    before = File.binread(File.join(@store.root, 'profession.json'))
    assert @store.select_profession(id: 'researcher')[:preserved]
    assert_equal before, File.binread(File.join(@store.root, 'profession.json'))
    assert_equal 'researcher', Kairomone::Instance.new.profession_status[:selected_id]
    FileUtils.remove_entry(File.join(@store.root, 'knowledge/two'))
    assert_equal 'researcher', @store.profession_status[:selected_id]
    assert_equal 'generalist', @store.profession_status[:effective_id]
  end

  def test_backup_restore_profession_and_legacy_absence
    @store.select_profession(id: 'generalist')
    backup = @store.create_backup
    @store.restore_backup(file: backup[:file], target_id: 'recovered')
    restored = Kairomone::Instance.new(kairomone: 'recovered')
    assert_equal 'generalist', restored.profession_status[:selected_id]
    before = File.binread(File.join(@store.root, 'profession.json'))
    File.delete(File.join(restored.root, 'profession.json'))
    assert_nil restored.profession_status[:selected_id], 'the twin is a separate individual'
    assert_equal before, File.binread(File.join(@store.root, 'profession.json'))
    File.delete(File.join(@store.root, 'profession.json'))
    legacy = @store.create_backup
    @store.restore_backup(file: legacy[:file], target_id: 'legacy')
    assert_nil Kairomone::Instance.new(kairomone: 'legacy').profession_status[:selected_id]
  end

  def test_invalid_profession_blocks_status_and_backup
    File.write(File.join(@store.root, 'profession.json'), '{"schema_version":1,"selected_id":"admin","selected_at":"2026-10-13T00:00:00Z"}')
    assert_match(/Invalid profession/, @store.status[:error])
    assert_raises(Kairomone::Error) { @store.create_backup }
  end

  def test_recomputed_checksum_does_not_bypass_profession_validation
    @store.select_profession(id: 'generalist')
    archive = @store.create_backup
    path = File.join(@store.root, 'backups', archive[:file])
    data = JSON.parse(File.read(path))
    entry = data['files'].find { |file| file['path'] == 'profession.json' }
    contents = JSON.generate(schema_version: 1, selected_id: 'unknown', selected_at: '2026-10-13T00:00:00Z')
    entry.merge!('content_base64' => Base64.strict_encode64(contents), 'size' => contents.bytesize, 'sha256' => Digest::SHA256.hexdigest(contents))
    data['manifest_sha256'] = Digest::SHA256.hexdigest(JSON.generate(data['files'].map { |file| file.slice('path', 'size', 'sha256') }))
    File.write(path, JSON.generate(data))
    assert_raises(Kairomone::Error) { @store.restore_backup(file: archive[:file], target_id: 'bad') }
    confirmed = false
    error = assert_raises(Kairomone::Error) do
      Kairomone::Host.new.restore(File.binread(path), trust: ->(_lines) { confirmed = true }, listing_id: 'bad')
    end
    assert_match(/Invalid profession/, error.message)
    refute confirmed, 'refused before the owner is asked'
    refute File.exist?(File.join(@host, 'kairomones/bad'))
  end
  def test_cli_profession_and_growth_configuration_roundtrip
    cli = File.expand_path('templates/skillsets/kairomone/scripts/kairomone.rb', __dir__)
    # A run starts only under a host L0 equal to the baseline: this host gets
    # its L0 before its individual is made.
    FileUtils.rm_rf(Dir.children(@host).map { |c| File.join(@host, c) })
    FileUtils.mkdir_p(File.join(@host, 'skills'))
    File.write(File.join(@host, 'skills/kairos.md'), '# synthetic philosophy')
    @store = Kairomone::Instance.new(bind: false)
    @store.init(dot_id: 'test_dot', display_name: 'Test')
    invoke = lambda do |*args|
      stdout, stderr, process = Open3.capture3({ 'KAIROS_DATA_DIR' => @host }, RbConfig.ruby, cli, *args)
      assert process.success?, "CLI failed: #{stdout} #{stderr}"
      JSON.parse(stdout)
    end
    result = invoke.call('profession', 'select', '--id', 'generalist')
    assert_equal 'generalist', result.dig('profession', 'selected_id')
    stdout, = Open3.capture3({ 'KAIROS_DATA_DIR' => @host }, RbConfig.ruby, cli, 'growth', 'configure')
    assert_match(/run-start/, JSON.parse(stdout)['error'])
    result = invoke.call('growth', 'run-start', '--owner-words', 'Grow twelve times', '--cycles', '12')
    assert_equal 12, result.dig('stop', 'cycles')
    result = invoke.call('growth', 'run-status')
    assert result['live']
    assert_equal 12, result['remaining_cycles']
    assert_nil result['cycle_limit']
    result = invoke.call('status')
    assert_equal 999, result.dig('progression', 'level_cap')
    assert_equal 0, result.dig('autonomy', 'used_cycles')
  end

end
