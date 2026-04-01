#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================================
# Place Extension Mechanism Test (Phase 1)
# ============================================================================
# Tests the PlaceRouter extension registry, dispatch, action resolution,
# Skillset#place_extensions, install_from_archive force, and
# check_installable_dependencies.
#
# Usage:
#   RBENV_VERSION=3.3.7 ruby -I KairosChain_mcp_server/lib \
#     KairosChain_mcp_server/test_place_extension_mechanism.rb
# ============================================================================

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/skillset'
require 'kairos_mcp/skillset_manager'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'
require 'base64'
require 'zlib'
require 'rubygems/package'
require 'stringio'

$pass_count = 0
$fail_count = 0
$section_pass = 0
$section_fail = 0

def assert(msg)
  result = yield
  if result
    puts "  PASS: #{msg}"
    $pass_count += 1
    $section_pass += 1
  else
    puts "  FAIL: #{msg}"
    $fail_count += 1
    $section_fail += 1
  end
rescue StandardError => e
  puts "  FAIL: #{msg} (#{e.class}: #{e.message})"
  $fail_count += 1
  $section_fail += 1
end

def section(title)
  puts ''
  puts '=' * 60
  puts "SECTION: #{title}"
  puts '=' * 60
  $section_pass = 0
  $section_fail = 0
  yield
  puts "  -- #{$section_pass} passed, #{$section_fail} failed"
rescue StandardError => e
  puts "  SECTION ERROR: #{e.message}"
  puts e.backtrace.first(3).join("\n")
  $fail_count += 1
end

# ============================================================================
# Helper: create a minimal knowledge-only SkillSet in a temp dir
# ============================================================================
def create_knowledge_skillset(parent_dir, name:, version: '1.0.0', depends_on: [],
                              place_extensions: nil, tags: nil)
  ss_dir = File.join(parent_dir, name)
  FileUtils.mkdir_p(File.join(ss_dir, 'knowledge', "#{name}_topic"))

  metadata = {
    'name' => name,
    'version' => version,
    'description' => "Test SkillSet: #{name}",
    'author' => 'Test',
    'layer' => 'L2',
    'depends_on' => depends_on,
    'provides' => [name],
    'tool_classes' => [],
    'knowledge_dirs' => ["knowledge/#{name}_topic"]
  }
  metadata['place_extensions'] = place_extensions if place_extensions
  metadata['tags'] = tags if tags

  File.write(File.join(ss_dir, 'skillset.json'), JSON.pretty_generate(metadata))
  File.write(
    File.join(ss_dir, 'knowledge', "#{name}_topic", "#{name}_topic.md"),
    "# #{name}\n\nTest content for #{name}.\n"
  )
  ss_dir
end

# Helper: create tar.gz archive from directory
def create_tar_gz(source_dir, archive_name)
  io = StringIO.new
  Zlib::GzipWriter.wrap(io) do |gz|
    Gem::Package::TarWriter.new(gz) do |tar|
      Dir[File.join(source_dir, '**', '*')].sort.each do |full_path|
        relative = full_path.sub("#{source_dir}/", '')
        stat = File.stat(full_path)
        if File.directory?(full_path)
          tar.mkdir("#{archive_name}/#{relative}", stat.mode)
        else
          content = File.binread(full_path)
          tar.add_file_simple("#{archive_name}/#{relative}", stat.mode, content.bytesize) do |tio|
            tio.write(content)
          end
        end
      end
    end
  end
  io.string
end

# Helper: create archive_data hash for install_from_archive
def package_skillset(ss_dir, name)
  tar_gz = create_tar_gz(ss_dir, name)
  ss = KairosMcp::Skillset.new(ss_dir)
  {
    name: name,
    version: ss.version,
    archive_base64: Base64.strict_encode64(tar_gz),
    content_hash: ss.content_hash
  }
end

# ============================================================================
# Stub PlaceRouter for testing (avoid loading full Hestia dependencies)
# ============================================================================
# We load PlaceRouter's extension-related methods by evaluating just the
# relevant code. Since the full Hestia module may not be loadable in test,
# we create a minimal stub that mirrors the production code.

class StubPlaceRouter
  attr_reader :extensions, :started

  JSON_HEADERS = { 'Content-Type' => 'application/json' }.freeze

  ROUTE_ACTION_MAP = {
    'deposit'       => 'deposit_skill',
    'browse'        => 'browse',
    'acquire'       => 'acquire_skill',
  }.freeze

  def initialize
    @extensions = []
    @extension_action_map = {}
    @started = true
  end

  def register_extension(extension, route_action_map: {})
    return if @extensions.any? { |e| e.class == extension.class }

    @extensions << extension
    @extension_action_map.merge!(route_action_map)
  end

  def resolve_action(route_segment)
    ROUTE_ACTION_MAP[route_segment] || @extension_action_map[route_segment] || route_segment
  end

  def dispatch_extensions(env, peer_id:)
    @extensions.each do |ext|
      result = ext.call(env, peer_id: peer_id)
      return result if result
    end
    nil
  end

  def json_response(status, body)
    [status, JSON_HEADERS, [body.to_json]]
  end
end

# Stub extension for testing
class TestExtensionA
  attr_reader :router

  def initialize(router)
    @router = router
  end

  def call(env, peer_id:)
    path = env['PATH_INFO']
    if path == '/place/v1/test_endpoint'
      return [200, { 'Content-Type' => 'application/json' },
              [{ handled_by: 'TestExtensionA', peer_id: peer_id }.to_json]]
    end
    nil # unhandled paths
  end
end

class TestExtensionB
  def initialize(router); end

  def call(env, peer_id:)
    path = env['PATH_INFO']
    if path == '/place/v1/other_endpoint'
      [200, { 'Content-Type' => 'application/json' },
       [{ handled_by: 'TestExtensionB', peer_id: peer_id }.to_json]]
    end
  end
end

# ============================================================================
# Section 1: PlaceRouter Extension Registration
# ============================================================================
section('1. PlaceRouter Extension Registration') do
  router = StubPlaceRouter.new

  assert('extensions empty initially') { router.extensions.empty? }

  ext_a = TestExtensionA.new(router)
  router.register_extension(ext_a, route_action_map: { 'test_endpoint' => 'test_action' })

  assert('extension registered') { router.extensions.size == 1 }
  assert('extension is TestExtensionA') { router.extensions.first.is_a?(TestExtensionA) }

  # Idempotent re-register
  ext_a2 = TestExtensionA.new(router)
  router.register_extension(ext_a2, route_action_map: { 'test_endpoint' => 'test_action' })
  assert('idempotent: still 1 extension after re-register') { router.extensions.size == 1 }

  # Different class can register
  ext_b = TestExtensionB.new(router)
  router.register_extension(ext_b, route_action_map: { 'other_endpoint' => 'other_action' })
  assert('second extension registered') { router.extensions.size == 2 }
end

# ============================================================================
# Section 2: Extension Dispatch After Auth
# ============================================================================
section('2. Extension Dispatch After Auth') do
  router = StubPlaceRouter.new
  ext_a = TestExtensionA.new(router)
  router.register_extension(ext_a, route_action_map: { 'test_endpoint' => 'test_action' })

  # Mock env for handled path
  env = { 'PATH_INFO' => '/place/v1/test_endpoint', 'REQUEST_METHOD' => 'GET' }
  result = router.dispatch_extensions(env, peer_id: 'agent-001')

  assert('extension handles known path') { !result.nil? }
  assert('returns 200 status') { result[0] == 200 }

  body = JSON.parse(result[2].first)
  assert('response includes peer_id') { body['peer_id'] == 'agent-001' }
  assert('response identifies handler') { body['handled_by'] == 'TestExtensionA' }

  # Unknown path returns nil
  env_unknown = { 'PATH_INFO' => '/place/v1/unknown', 'REQUEST_METHOD' => 'GET' }
  result_unknown = router.dispatch_extensions(env_unknown, peer_id: 'agent-001')
  assert('unknown path returns nil') { result_unknown.nil? }
end

# ============================================================================
# Section 3: resolve_action Checks Extension Action Map
# ============================================================================
section('3. resolve_action Extension Action Map') do
  router = StubPlaceRouter.new

  # Built-in action
  assert('built-in: deposit -> deposit_skill') { router.resolve_action('deposit') == 'deposit_skill' }
  assert('built-in: browse -> browse') { router.resolve_action('browse') == 'browse' }

  # Unknown segment before extension registration
  assert('unknown segment returns segment') { router.resolve_action('skillset_deposit') == 'skillset_deposit' }

  # Register extension action map
  ext = TestExtensionA.new(router)
  router.register_extension(ext, route_action_map: {
    'skillset_deposit' => 'deposit_skill',
    'skillset_browse' => 'browse'
  })

  assert('extension: skillset_deposit -> deposit_skill') {
    router.resolve_action('skillset_deposit') == 'deposit_skill'
  }
  assert('extension: skillset_browse -> browse') {
    router.resolve_action('skillset_browse') == 'browse'
  }

  # Built-in takes precedence (deposit is both built-in and could be extension)
  assert('built-in takes precedence over extension') {
    router.resolve_action('deposit') == 'deposit_skill'
  }
end

# ============================================================================
# Section 4: Skillset#place_extensions Reads Metadata
# ============================================================================
section('4. Skillset#place_extensions Metadata') do
  Dir.mktmpdir('kairos_test_pe') do |tmpdir|
    # SkillSet without place_extensions
    plain_dir = create_knowledge_skillset(tmpdir, name: 'plain_skill')
    plain = KairosMcp::Skillset.new(plain_dir)
    assert('no place_extensions returns empty array') { plain.place_extensions == [] }

    # SkillSet with place_extensions
    ext_defs = [
      {
        'class' => 'SkillsetExchange::PlaceExtension',
        'require' => 'lib/skillset_exchange/place_extension.rb',
        'route_actions' => {
          'skillset_deposit' => 'deposit_skill',
          'skillset_browse' => 'browse'
        }
      }
    ]
    ext_dir = create_knowledge_skillset(tmpdir, name: 'ext_skill', place_extensions: ext_defs)
    ext_ss = KairosMcp::Skillset.new(ext_dir)

    assert('place_extensions returns declared extensions') { ext_ss.place_extensions.size == 1 }
    assert('extension class matches') {
      ext_ss.place_extensions.first['class'] == 'SkillsetExchange::PlaceExtension'
    }
    assert('route_actions included') {
      ext_ss.place_extensions.first['route_actions']['skillset_deposit'] == 'deposit_skill'
    }
  end
end

# ============================================================================
# Section 5: install_from_archive with force: true
# ============================================================================
section('5. install_from_archive force reinstall') do
  Dir.mktmpdir('kairos_test_force') do |tmpdir|
    ss_dir_base = File.join(tmpdir, 'source')
    FileUtils.mkdir_p(ss_dir_base)
    skillsets_dir = File.join(tmpdir, 'skillsets')
    FileUtils.mkdir_p(skillsets_dir)

    # Create v1.0.0
    ss_v1 = create_knowledge_skillset(ss_dir_base, name: 'test_pkg', version: '1.0.0')
    pkg_v1 = package_skillset(ss_v1, 'test_pkg')

    KairosMcp.data_dir = tmpdir
    manager = KairosMcp::SkillSetManager.new(skillsets_dir: skillsets_dir)

    # First install
    result1 = manager.install_from_archive(pkg_v1)
    assert('first install succeeds') { result1[:success] == true }
    assert('first install version is 1.0.0') { result1[:version] == '1.0.0' }

    # Add user config to installed SkillSet
    config_dir = File.join(skillsets_dir, 'test_pkg', 'config')
    FileUtils.mkdir_p(config_dir)
    File.write(File.join(config_dir, 'user_settings.yml'), "custom: true\n")

    # Attempt install without force -> should raise
    raised = false
    begin
      manager.install_from_archive(pkg_v1)
    rescue ArgumentError => e
      raised = e.message.include?('already installed')
    end
    assert('install without force raises for existing') { raised }

    # Create v2.0.0
    ss_dir_v2 = File.join(tmpdir, 'source_v2')
    FileUtils.mkdir_p(ss_dir_v2)
    ss_v2 = create_knowledge_skillset(ss_dir_v2, name: 'test_pkg', version: '2.0.0')
    # Add different knowledge content
    File.write(
      File.join(ss_v2, 'knowledge', 'test_pkg_topic', 'test_pkg_topic.md'),
      "# test_pkg v2\n\nUpdated content.\n"
    )
    pkg_v2 = package_skillset(ss_v2, 'test_pkg')

    # Force reinstall with v2
    result2 = manager.install_from_archive(pkg_v2, force: true)
    assert('force reinstall succeeds') { result2[:success] == true }
    assert('force reinstall version is 2.0.0') { result2[:version] == '2.0.0' }

    # Verify user config preserved
    user_config = File.join(skillsets_dir, 'test_pkg', 'config', 'user_settings.yml')
    assert('user config preserved after force reinstall') { File.exist?(user_config) }
    assert('user config content preserved') { File.read(user_config).include?('custom: true') }

    # Verify content updated
    content_file = File.join(skillsets_dir, 'test_pkg', 'knowledge', 'test_pkg_topic', 'test_pkg_topic.md')
    assert('content updated after force reinstall') { File.read(content_file).include?('v2') }
  end
end

# ============================================================================
# Section 6: install_from_archive with force: false (reject existing)
# ============================================================================
section('6. install_from_archive force: false rejects existing') do
  Dir.mktmpdir('kairos_test_no_force') do |tmpdir|
    ss_dir_base = File.join(tmpdir, 'source')
    FileUtils.mkdir_p(ss_dir_base)
    skillsets_dir = File.join(tmpdir, 'skillsets')
    FileUtils.mkdir_p(skillsets_dir)

    ss_dir = create_knowledge_skillset(ss_dir_base, name: 'reject_test', version: '1.0.0')
    pkg = package_skillset(ss_dir, 'reject_test')

    KairosMcp.data_dir = tmpdir
    manager = KairosMcp::SkillSetManager.new(skillsets_dir: skillsets_dir)

    # First install succeeds
    result = manager.install_from_archive(pkg)
    assert('initial install succeeds') { result[:success] == true }

    # Second install without force raises
    raised_msg = nil
    begin
      manager.install_from_archive(pkg, force: false)
    rescue ArgumentError => e
      raised_msg = e.message
    end
    assert('force: false raises ArgumentError') { !raised_msg.nil? }
    assert('error message mentions already installed') { raised_msg&.include?('already installed') }
    assert('error message mentions force: true') { raised_msg&.include?('force: true') }
  end
end

# ============================================================================
# Section 7: check_installable_dependencies
# ============================================================================
section('7. check_installable_dependencies') do
  Dir.mktmpdir('kairos_test_deps') do |tmpdir|
    skillsets_dir = File.join(tmpdir, 'skillsets')
    FileUtils.mkdir_p(skillsets_dir)

    # Install base dependencies
    create_knowledge_skillset(skillsets_dir, name: 'base_a', version: '1.0.0')
    create_knowledge_skillset(skillsets_dir, name: 'base_b', version: '2.0.0')
    create_knowledge_skillset(skillsets_dir, name: 'base_disabled', version: '1.0.0')

    KairosMcp.data_dir = tmpdir
    manager = KairosMcp::SkillSetManager.new(skillsets_dir: skillsets_dir)

    # Disable base_disabled
    # Write config to disable it
    config_path = File.join(skillsets_dir, 'config.yml')
    config = { 'skillsets' => { 'base_disabled' => { 'enabled' => false } } }
    File.write(config_path, config.to_yaml)
    manager = KairosMcp::SkillSetManager.new(skillsets_dir: skillsets_dir)

    # --- Test 1: All dependencies satisfied ---
    ss_ok_dir = File.join(tmpdir, 'source_ok')
    FileUtils.mkdir_p(ss_ok_dir)
    create_knowledge_skillset(ss_ok_dir, name: 'needs_a',
      depends_on: [{ 'name' => 'base_a', 'version' => '>= 1.0.0' }])
    ss_ok = KairosMcp::Skillset.new(File.join(ss_ok_dir, 'needs_a'))

    result_ok = manager.check_installable_dependencies(ss_ok)
    assert('all satisfied: satisfiable is true') { result_ok[:satisfiable] == true }
    assert('all satisfied: no missing') { result_ok[:missing].empty? }
    assert('all satisfied: no version_mismatch') { result_ok[:version_mismatch].empty? }
    assert('all satisfied: no disabled') { result_ok[:disabled].empty? }

    # --- Test 2: Missing dependency ---
    ss_missing_dir = File.join(tmpdir, 'source_missing')
    FileUtils.mkdir_p(ss_missing_dir)
    create_knowledge_skillset(ss_missing_dir, name: 'needs_missing',
      depends_on: [{ 'name' => 'nonexistent', 'version' => '>= 1.0.0' }])
    ss_missing = KairosMcp::Skillset.new(File.join(ss_missing_dir, 'needs_missing'))

    result_missing = manager.check_installable_dependencies(ss_missing)
    assert('missing: satisfiable is false') { result_missing[:satisfiable] == false }
    assert('missing: includes nonexistent') { result_missing[:missing].include?('nonexistent') }

    # --- Test 3: Version mismatch ---
    ss_ver_dir = File.join(tmpdir, 'source_ver')
    FileUtils.mkdir_p(ss_ver_dir)
    create_knowledge_skillset(ss_ver_dir, name: 'needs_newer',
      depends_on: [{ 'name' => 'base_a', 'version' => '>= 5.0.0' }])
    ss_ver = KairosMcp::Skillset.new(File.join(ss_ver_dir, 'needs_newer'))

    result_ver = manager.check_installable_dependencies(ss_ver)
    assert('version mismatch: satisfiable is false') { result_ver[:satisfiable] == false }
    assert('version mismatch: includes base_a') {
      result_ver[:version_mismatch].any? { |m| m[:name] == 'base_a' }
    }
    assert('version mismatch: reports required version') {
      result_ver[:version_mismatch].first[:required] == '>= 5.0.0'
    }
    assert('version mismatch: reports installed version') {
      result_ver[:version_mismatch].first[:installed] == '1.0.0'
    }

    # --- Test 4: Disabled dependency ---
    ss_dis_dir = File.join(tmpdir, 'source_dis')
    FileUtils.mkdir_p(ss_dis_dir)
    create_knowledge_skillset(ss_dis_dir, name: 'needs_disabled',
      depends_on: [{ 'name' => 'base_disabled' }])
    ss_dis = KairosMcp::Skillset.new(File.join(ss_dis_dir, 'needs_disabled'))

    result_dis = manager.check_installable_dependencies(ss_dis)
    assert('disabled dep: satisfiable is true (disabled does not block)') { result_dis[:satisfiable] == true }
    assert('disabled dep: disabled list includes base_disabled') {
      result_dis[:disabled].include?('base_disabled')
    }
  end
end

# ============================================================================
# Summary
# ============================================================================
puts ''
puts '=' * 60
puts "TOTAL: #{$pass_count} passed, #{$fail_count} failed"
puts '=' * 60

exit($fail_count > 0 ? 1 : 0)
