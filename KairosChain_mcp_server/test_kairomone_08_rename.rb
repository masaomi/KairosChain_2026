# frozen_string_literal: true

# Kairomone 0.8, the rename and the release (design log/kairomone_core_0_8_design_v0.6_FROZEN_20261023.md,
# handoff phase 11, M2, M13): what was called a dot is a Kairomone in the
# tools, the CLI, the guide, the plugin rules and the console; the names a
# dot had (dot_id, --dot-id) are still read; the guide carries the interval
# recipe; the version is 0.8.0. All data is synthetic and confined to
# temporary hosts.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'minitest/autorun'
require_relative 'templates/skillsets/kairomone/test/support_08'

class Kairomone08RenameTest < Minitest::Test
  include Kairomone08Support

  PACKAGE = File.expand_path('templates/skillsets/kairomone', __dir__)
  CLI = File.join(PACKAGE, 'scripts/kairomone.rb')
  # Where the shipped text may still say "dot": naming what it was called.
  OLDER_NAME = /called (?:a )?"?dots?"? before 0\.8|older name|dot_id|--dot-id|dot's knowledge files|hosted-dot/

  def setup = fresh_host
  def teardown = FileUtils.remove_entry_secure(@host)

  def cli(*args)
    out, err, status = Open3.capture3({ 'KAIROS_DATA_DIR' => @host }, RbConfig.ruby, '-I', File.expand_path('lib', __dir__), CLI, *args)
    [JSON.parse(out), status.success?, err]
  end

  def test_init_takes_kairomone_id_and_still_reads_dot_id
    made = tool('Init', { 'kairomone_id' => 'momo', 'display_name' => 'Momo' })
    assert made['success'], made.inspect
    again = tool('Init', { 'dot_id' => 'momo', 'display_name' => 'Momo' })
    assert again['preserved'], 'the older name names the same Kairomone'
    both = tool('Init', { 'kairomone_id' => 'momo', 'dot_id' => 'other', 'display_name' => 'Momo' })
    assert_match(/not both/, both['error'])
    none = tool('Init', { 'display_name' => 'Momo' })
    assert_match(/kairomone_id is required/, none['error'])
  end

  def test_the_cli_takes_the_new_names_and_the_older_one
    result, ok, err = cli('init', '--kairomone-id', 'momo', '--name', 'Momo')
    assert ok, err
    assert result['initialized'], result.inspect
    result, = cli('init', '--dot-id', 'momo', '--name', 'Momo')
    assert result['preserved'], result.inspect
  end

  def test_restore_new_takes_identity_and_still_reads_dot_id
    alpha = make('alpha')
    backup = alpha.create_backup
    inbox = File.join(@host, 'kairomone-inbox')
    FileUtils.mkdir_p(inbox)
    FileUtils.cp(File.join(alpha.root, 'backups', backup[:file]), inbox)
    result = tool('Backup', { 'command' => 'restore_new', 'file' => backup[:file], 'identity' => 'alpha', 'target_id' => 'copy' })
    assert result['success'], result.inspect
    older = tool('Backup', { 'command' => 'restore_new', 'file' => backup[:file], 'dot_id' => 'alpha', 'target_id' => 'copy2' })
    assert older['success'], older.inspect
    assert_equal %w[alpha copy copy2], listing
  end

  def test_the_shipped_text_says_kairomone
    files = Dir[File.join(PACKAGE, '{plugin,knowledge,docs}/**/*.md')] + [File.join(PACKAGE, 'assets/console.html'), File.join(PACKAGE, 'assets/README.md'),
                                                                         File.join(PACKAGE, 'tools/kairomone_tools.rb'), CLI]
    left = files.flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, i|
        next unless line.match?(/\bdots?\b|\bdot's\b/i)
        next if line.match?(OLDER_NAME)

        "#{file.delete_prefix(PACKAGE)}:#{i + 1}: #{line.strip[0, 120]}"
      end
    end
    assert_empty left
  end

  def test_the_guide_carries_the_interval_recipe
    guide = File.read(File.join(PACKAGE, 'knowledge/kairomone_guide/kairomone_guide.md'))
    recipe = guide.lines.find { |l| l.include?('/loop ') } or flunk 'no /loop line in the guide'
    %w[kairomone=<listing_id> run_id=<run_id> token=<token>].each { |part| assert_includes recipe, part }
    assert_match(/run_status .*first; if this_run\.live is false, report this_run\.ended and ask the owner to end this loop/, recipe)
  end

  def test_the_version_is_0_8_0_everywhere_it_is_stated
    assert_equal '0.8.0', Kairomone::VERSION
    assert_equal '0.8.0', JSON.parse(File.read(File.join(PACKAGE, 'skillset.json')))['version']
    assert_match(/^version: '0\.8\.0'$/, File.read(File.join(PACKAGE, 'knowledge/kairomone_guide/kairomone_guide.md')))
  end
end
