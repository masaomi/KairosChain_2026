#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================================
# SkillSet Exchange Phase 2 Test
# ============================================================================
# Tests ExchangeValidator, PlaceExtension (deposit + browse), and MCP tools.
#
# Usage:
#   RBENV_VERSION=3.3.7 ruby -I KairosChain_mcp_server/lib \
#     KairosChain_mcp_server/test_skillset_exchange_phase2.rb
# ============================================================================

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/skillset'
require 'kairos_mcp/skillset_manager'
require 'kairos_mcp/tools/base_tool'
require 'kairos_mcp/safety'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'
require 'base64'
require 'zlib'
require 'rubygems/package'
require 'stringio'
require 'digest'

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
  puts e.backtrace.first(5).join("\n")
  $fail_count += 1
end

# ============================================================================
# Helper: create a knowledge-only SkillSet
# ============================================================================
def create_knowledge_skillset(parent_dir, name:, version: '1.0.0', tags: nil)
  ss_dir = File.join(parent_dir, name)
  FileUtils.mkdir_p(File.join(ss_dir, 'knowledge', "#{name}_topic"))

  metadata = {
    'name' => name,
    'version' => version,
    'description' => "Test knowledge SkillSet: #{name}",
    'author' => 'Test',
    'layer' => 'L2',
    'depends_on' => [],
    'provides' => [name],
    'tool_classes' => [],
    'knowledge_dirs' => ["knowledge/#{name}_topic"]
  }
  metadata['tags'] = tags if tags

  File.write(File.join(ss_dir, 'skillset.json'), JSON.pretty_generate(metadata))
  File.write(
    File.join(ss_dir, 'knowledge', "#{name}_topic", "#{name}_topic.md"),
    "---\nname: #{name}_topic\ndescription: Test topic\nversion: 1.0.0\n---\n\n# #{name}\n\nTest content.\n"
  )
  ss_dir
end

# Helper: create an executable SkillSet (tools/ with .rb)
def create_executable_skillset(parent_dir, name:)
  ss_dir = File.join(parent_dir, name)
  FileUtils.mkdir_p(File.join(ss_dir, 'tools'))

  File.write(File.join(ss_dir, 'skillset.json'), JSON.generate({
    'name' => name,
    'version' => '1.0.0',
    'description' => "Executable SkillSet: #{name}",
    'layer' => 'L1',
    'tool_classes' => ['FakeTool']
  }))
  File.write(File.join(ss_dir, 'tools', 'fake_tool.rb'), 'class FakeTool; end')
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

# Helper: create a mock Rack env
def mock_env(method, path, body: nil, query: nil, bearer_token: nil)
  env = {
    'REQUEST_METHOD' => method,
    'PATH_INFO' => path,
    'QUERY_STRING' => query || '',
    'CONTENT_TYPE' => 'application/json'
  }
  env['HTTP_AUTHORIZATION'] = "Bearer #{bearer_token}" if bearer_token
  if body
    env['rack.input'] = StringIO.new(body.is_a?(String) ? body : JSON.generate(body))
  else
    env['rack.input'] = StringIO.new('')
  end
  env
end

# ============================================================================
# Stub router for PlaceExtension tests
# ============================================================================
class StubRegistry
  def public_key_for(_id)
    nil
  end
end

class StubSessionStore
  def validate(token)
    token
  end
end

class StubSkillBoard; end

class StubRouter
  attr_reader :skill_board, :session_store, :registry, :extensions

  def initialize
    @skill_board = StubSkillBoard.new
    @session_store = StubSessionStore.new
    @registry = StubRegistry.new
    @extensions = []
  end
end

# ============================================================================
# Setup
# ============================================================================
puts ''
puts '=' * 60
puts 'SETUP: Creating test environment'
puts '=' * 60

test_dir = Dir.mktmpdir('kairos_se_phase2')
skillsets_dir = File.join(test_dir, 'skillsets')
FileUtils.mkdir_p(skillsets_dir)
FileUtils.mkdir_p(File.join(test_dir, 'storage'))
FileUtils.mkdir_p(File.join(test_dir, 'knowledge'))
FileUtils.mkdir_p(File.join(test_dir, 'config'))
FileUtils.mkdir_p(File.join(test_dir, 'skills'))
File.write(File.join(test_dir, 'skills', 'config.yml'), { 'skill_tools_enabled' => false }.to_yaml)

KairosMcp.data_dir = test_dir

# Create a knowledge-only SkillSet for testing
create_knowledge_skillset(skillsets_dir, name: 'test_knowledge', version: '1.0.0', tags: ['test', 'knowledge'])

# Create an executable SkillSet for negative testing
create_executable_skillset(skillsets_dir, name: 'test_executable')

puts "  Test dir: #{test_dir}"

# ============================================================================
# Section 1: ExchangeValidator
# ============================================================================
section('1. ExchangeValidator') do
  require_relative 'templates/skillsets/skillset_exchange/lib/skillset_exchange/exchange_validator'

  manager = KairosMcp::SkillSetManager.new(skillsets_dir: skillsets_dir)
  validator = SkillsetExchange::ExchangeValidator.new(config: {})

  # Valid knowledge-only SkillSet passes
  result = validator.validate_for_deposit('test_knowledge', manager: manager)
  assert('knowledge-only SkillSet passes validation') { result[:valid] == true }
  assert('knowledge-only: no errors') { result[:errors].empty? }

  # Executable SkillSet fails
  result = validator.validate_for_deposit('test_executable', manager: manager)
  assert('executable SkillSet fails validation') { result[:valid] == false }
  assert('executable: error mentions executable') {
    result[:errors].any? { |e| e.include?('executable') || e.include?('exchangeable') }
  }

  # Non-existent SkillSet fails
  result = validator.validate_for_deposit('nonexistent', manager: manager)
  assert('non-existent SkillSet fails') { result[:valid] == false }
  assert('non-existent: error mentions not found') {
    result[:errors].any? { |e| e.include?('not found') }
  }

  # Invalid name fails
  result = validator.validate_for_deposit('../../evil', manager: manager)
  assert('invalid name fails') { result[:valid] == false }
  assert('invalid name: error mentions name') {
    result[:errors].any? { |e| e.include?('Invalid') || e.include?('name') }
  }

  # Size limit check
  small_validator = SkillsetExchange::ExchangeValidator.new(
    config: { 'deposit' => { 'max_archive_size_bytes' => 1 } }
  )
  result = small_validator.validate_for_deposit('test_knowledge', manager: manager)
  assert('oversized SkillSet fails') { result[:valid] == false }
  assert('oversized: error mentions large') {
    result[:errors].any? { |e| e.include?('large') || e.include?('too large') }
  }
end

# ============================================================================
# Section 2: PlaceExtension — Deposit
# ============================================================================
section('2. PlaceExtension — Deposit') do
  require_relative 'templates/skillsets/skillset_exchange/lib/skillset_exchange/place_extension'

  storage_dir = File.join(test_dir, 'storage', 'skillset_deposits_test')
  FileUtils.mkdir_p(storage_dir)

  # Create extension with custom config (small quotas for testing)
  stub_router = StubRouter.new
  ext = SkillsetExchange::PlaceExtension.new(stub_router)

  # Override storage dir for testing
  ext.instance_variable_set(:@storage_dir, storage_dir)
  ext.instance_variable_set(:@config, {
    'deposit' => {
      'max_archive_size_bytes' => 5_242_880,
      'max_per_agent' => 3
    },
    'place' => {
      'max_total_archive_bytes' => 10_000_000,
      'storage_dir' => 'skillset_deposits_test'
    }
  })

  # Package the test_knowledge SkillSet
  manager = KairosMcp::SkillSetManager.new(skillsets_dir: skillsets_dir)
  pkg = manager.package('test_knowledge')

  # --- 2.1 Successful deposit ---
  deposit_body = {
    'name' => 'test_knowledge',
    'version' => '1.0.0',
    'description' => 'Test knowledge SkillSet',
    'content_hash' => pkg[:content_hash],
    'archive_base64' => pkg[:archive_base64],
    'signature' => nil,
    'file_list' => pkg[:file_list],
    'tags' => ['test', 'knowledge']
  }

  env = mock_env('POST', '/place/v1/skillset_deposit', body: deposit_body)
  status, _headers, body = ext.call(env, peer_id: 'agent-alpha')
  result = JSON.parse(body.first, symbolize_names: true)

  assert('deposit returns 200') { status == 200 }
  assert('deposit status is deposited') { result[:status] == 'deposited' }
  assert('deposit returns name') { result[:name] == 'test_knowledge' }
  assert('deposit returns content_hash') { result[:content_hash] == pkg[:content_hash] }
  assert('deposit returns trust_notice') { result[:trust_notice].is_a?(Hash) }
  assert('trust_notice has tar_header_scanned') { result[:trust_notice][:tar_header_scanned] == true }
  assert('trust_notice has content_hash_verified') { result[:trust_notice][:content_hash_verified] == true }

  # Verify on-disk storage
  deposit_dir = File.join(storage_dir, 'test_knowledge_agent-alpha')
  assert('archive.tar.gz stored on disk') { File.exist?(File.join(deposit_dir, 'archive.tar.gz')) }
  assert('metadata.json stored on disk') { File.exist?(File.join(deposit_dir, 'metadata.json')) }

  # --- 2.2 Executable archive rejection (tar header scan) ---
  exec_ss_dir = File.join(skillsets_dir, 'test_executable')
  exec_tar_gz = create_tar_gz(exec_ss_dir, 'test_executable')
  exec_archive_base64 = Base64.strict_encode64(exec_tar_gz)

  exec_body = {
    'name' => 'test_executable',
    'version' => '1.0.0',
    'description' => 'Executable SkillSet',
    'content_hash' => 'fake_hash',
    'archive_base64' => exec_archive_base64,
    'file_list' => [],
    'tags' => []
  }

  env = mock_env('POST', '/place/v1/skillset_deposit', body: exec_body)
  status, _headers, body = ext.call(env, peer_id: 'agent-evil')
  result = JSON.parse(body.first, symbolize_names: true)

  assert('executable deposit returns 422') { status == 422 }
  assert('executable deposit error is executable_content') { result[:error] == 'executable_content' }

  # --- 2.3 Name sanitization ---
  bad_name_body = deposit_body.merge('name' => '../../evil')
  env = mock_env('POST', '/place/v1/skillset_deposit', body: bad_name_body)
  status, _headers, body = ext.call(env, peer_id: 'agent-alpha')
  result = JSON.parse(body.first, symbolize_names: true)

  assert('invalid name returns 400') { status == 400 }
  assert('invalid name error is invalid_name') { result[:error] == 'invalid_name' }

  # --- 2.4 Archive size limit ---
  tiny_ext = SkillsetExchange::PlaceExtension.new(stub_router)
  tiny_ext.instance_variable_set(:@storage_dir, Dir.mktmpdir('tiny_storage'))
  tiny_ext.instance_variable_set(:@config, {
    'deposit' => { 'max_archive_size_bytes' => 10, 'max_per_agent' => 10 },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })

  env = mock_env('POST', '/place/v1/skillset_deposit', body: deposit_body)
  status, _headers, body = tiny_ext.call(env, peer_id: 'agent-alpha')
  result = JSON.parse(body.first, symbolize_names: true)

  assert('oversized archive returns 422') { status == 422 }
  assert('oversized archive error is archive_too_large') { result[:error] == 'archive_too_large' }

  # --- 2.5 Per-agent quota enforcement ---
  quota_ext = SkillsetExchange::PlaceExtension.new(stub_router)
  quota_storage = Dir.mktmpdir('quota_storage')
  quota_ext.instance_variable_set(:@storage_dir, quota_storage)
  quota_ext.instance_variable_set(:@config, {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 1 },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })

  # First deposit: should succeed
  env = mock_env('POST', '/place/v1/skillset_deposit', body: deposit_body)
  status1, _, _ = quota_ext.call(env, peer_id: 'agent-quota')
  assert('first deposit under quota succeeds') { status1 == 200 }

  # Second deposit with different name: should fail (quota = 1)
  second_ss = create_knowledge_skillset(skillsets_dir, name: 'test_knowledge2', version: '1.0.0')
  pkg2 = manager.package('test_knowledge2')
  second_body = deposit_body.merge(
    'name' => 'test_knowledge2',
    'content_hash' => pkg2[:content_hash],
    'archive_base64' => pkg2[:archive_base64],
    'file_list' => pkg2[:file_list]
  )
  env = mock_env('POST', '/place/v1/skillset_deposit', body: second_body)
  status2, _, body2 = quota_ext.call(env, peer_id: 'agent-quota')
  result2 = JSON.parse(body2.first, symbolize_names: true)

  assert('second deposit over quota returns 422') { status2 == 422 }
  assert('quota error is quota_exceeded') { result2[:error] == 'quota_exceeded' }

  # --- 2.6 Content hash mismatch ---
  wrong_hash_body = deposit_body.merge('content_hash' => 'wrong_hash_value')
  env = mock_env('POST', '/place/v1/skillset_deposit', body: wrong_hash_body)
  status, _headers, body = ext.call(env, peer_id: 'agent-mismatch')
  result = JSON.parse(body.first, symbolize_names: true)

  assert('wrong content_hash returns 422') { status == 422 }
  assert('wrong hash error is content_hash_mismatch') { result[:error] == 'content_hash_mismatch' }

  # --- 2.7 Invalid Base64 ---
  invalid_b64_body = deposit_body.merge('archive_base64' => '!!!not-base64!!!')
  env = mock_env('POST', '/place/v1/skillset_deposit', body: invalid_b64_body)
  status, _headers, body = ext.call(env, peer_id: 'agent-bad64')
  result = JSON.parse(body.first, symbolize_names: true)

  assert('invalid base64 returns 400') { status == 400 }
  assert('invalid base64 error') { result[:error] == 'invalid_base64' }

  # --- 2.8 Missing archive ---
  no_archive_body = deposit_body.merge('archive_base64' => nil)
  env = mock_env('POST', '/place/v1/skillset_deposit', body: no_archive_body)
  status, _headers, body = ext.call(env, peer_id: 'agent-noarchive')
  result = JSON.parse(body.first, symbolize_names: true)

  assert('missing archive returns 400') { status == 400 }
  assert('missing archive error') { result[:error] == 'missing_archive' }
end

# ============================================================================
# Section 3: PlaceExtension — Browse
# ============================================================================
section('3. PlaceExtension — Browse') do
  storage_dir = File.join(test_dir, 'storage', 'skillset_deposits_browse')
  FileUtils.mkdir_p(storage_dir)

  stub_router = StubRouter.new
  ext = SkillsetExchange::PlaceExtension.new(stub_router)
  ext.instance_variable_set(:@storage_dir, storage_dir)
  ext.instance_variable_set(:@deposited_skillsets, {})
  ext.instance_variable_set(:@config, {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 10 },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })

  manager = KairosMcp::SkillSetManager.new(skillsets_dir: skillsets_dir)
  pkg = manager.package('test_knowledge')

  # Deposit a SkillSet first
  deposit_body = {
    'name' => 'test_knowledge',
    'version' => '1.0.0',
    'description' => 'A test knowledge SkillSet for exchange',
    'content_hash' => pkg[:content_hash],
    'archive_base64' => pkg[:archive_base64],
    'file_list' => pkg[:file_list],
    'tags' => ['test', 'knowledge']
  }
  env = mock_env('POST', '/place/v1/skillset_deposit', body: deposit_body)
  ext.call(env, peer_id: 'agent-alpha')

  # --- 3.1 Browse returns deposited SkillSet ---
  env = mock_env('GET', '/place/v1/skillset_browse')
  status, _headers, body = ext.call(env, peer_id: 'agent-beta')
  result = JSON.parse(body.first, symbolize_names: true)

  assert('browse returns 200') { status == 200 }
  assert('browse has entries') { result[:entries].is_a?(Array) && result[:entries].size > 0 }
  assert('browse total_available >= 1') { result[:total_available] >= 1 }
  assert('browse has sampling field') { result[:sampling].is_a?(String) }

  entry = result[:entries].first
  assert('entry has name') { entry[:name] == 'test_knowledge' }
  assert('entry has version') { entry[:version] == '1.0.0' }
  assert('entry has description') { !entry[:description].nil? }
  assert('entry has content_hash') { entry[:content_hash] == pkg[:content_hash] }
  assert('entry has depositor_id') { entry[:depositor_id] == 'agent-alpha' }
  assert('entry has tags') { entry[:tags].include?('test') }

  # --- 3.2 Search filter works ---
  env = mock_env('GET', '/place/v1/skillset_browse', query: 'search=knowledge')
  status, _headers, body = ext.call(env, peer_id: 'agent-beta')
  result = JSON.parse(body.first, symbolize_names: true)

  assert('search filter returns results') { result[:entries].size > 0 }

  env = mock_env('GET', '/place/v1/skillset_browse', query: 'search=zzz_nonexistent_zzz')
  status, _headers, body = ext.call(env, peer_id: 'agent-beta')
  result = JSON.parse(body.first, symbolize_names: true)

  assert('search for non-matching returns empty') { result[:entries].empty? }
  assert('search non-matching total is 0') { result[:total_available] == 0 }

  # --- 3.3 Random order (DEE compliance) ---
  # Deposit multiple SkillSets to test randomness
  3.times do |i|
    ss_name = "browse_test_#{i}"
    create_knowledge_skillset(skillsets_dir, name: ss_name, version: '1.0.0')
    pkg_i = manager.package(ss_name)
    body_i = {
      'name' => ss_name,
      'version' => '1.0.0',
      'description' => "Browse test #{i}",
      'content_hash' => pkg_i[:content_hash],
      'archive_base64' => pkg_i[:archive_base64],
      'file_list' => pkg_i[:file_list],
      'tags' => ['browse_test']
    }
    env = mock_env('POST', '/place/v1/skillset_deposit', body: body_i)
    ext.call(env, peer_id: "agent-#{i}")
  end

  # Call browse multiple times, collect orderings
  orderings = Set.new
  10.times do
    env = mock_env('GET', '/place/v1/skillset_browse')
    _, _, body = ext.call(env, peer_id: 'agent-beta')
    result = JSON.parse(body.first, symbolize_names: true)
    names = result[:entries].map { |e| e[:name] }
    orderings.add(names.join(','))
  end

  assert('multiple browse calls produce varying order (DEE random)') { orderings.size > 1 }
end

# ============================================================================
# Section 4: MCP Tool Stubs Loadable
# ============================================================================
section('4. MCP Tool Stubs Loadable') do
  # Load the tool files
  require_relative 'templates/skillsets/skillset_exchange/tools/skillset_deposit'
  require_relative 'templates/skillsets/skillset_exchange/tools/skillset_browse'
  require_relative 'templates/skillsets/skillset_exchange/tools/skillset_acquire'
  require_relative 'templates/skillsets/skillset_exchange/tools/skillset_withdraw'

  safety = KairosMcp::Safety.new

  # Verify all 4 tool classes can be instantiated
  deposit_tool = KairosMcp::SkillSets::SkillsetExchange::Tools::SkillsetDeposit.new(safety)
  assert('SkillsetDeposit instantiates') { !deposit_tool.nil? }
  assert('SkillsetDeposit name correct') { deposit_tool.name == 'skillset_deposit' }
  assert('SkillsetDeposit has input_schema') { deposit_tool.input_schema[:type] == 'object' }
  assert('SkillsetDeposit has category') { deposit_tool.category == :meeting }

  browse_tool = KairosMcp::SkillSets::SkillsetExchange::Tools::SkillsetBrowse.new(safety)
  assert('SkillsetBrowse instantiates') { !browse_tool.nil? }
  assert('SkillsetBrowse name correct') { browse_tool.name == 'skillset_browse' }
  assert('SkillsetBrowse has input_schema') { browse_tool.input_schema[:type] == 'object' }

  acquire_tool = KairosMcp::SkillSets::SkillsetExchange::Tools::SkillsetAcquire.new(safety)
  assert('SkillsetAcquire instantiates') { !acquire_tool.nil? }
  assert('SkillsetAcquire name correct') { acquire_tool.name == 'skillset_acquire' }
  assert('SkillsetAcquire returns stub message') {
    result = acquire_tool.call({})
    result.first[:text].include?('not yet implemented') || result.first[:text].include?('Not yet implemented')
  }

  withdraw_tool = KairosMcp::SkillSets::SkillsetExchange::Tools::SkillsetWithdraw.new(safety)
  assert('SkillsetWithdraw instantiates') { !withdraw_tool.nil? }
  assert('SkillsetWithdraw name correct') { withdraw_tool.name == 'skillset_withdraw' }
  assert('SkillsetWithdraw returns stub message') {
    result = withdraw_tool.call({})
    result.first[:text].include?('not yet implemented') || result.first[:text].include?('Not yet implemented')
  }
end

# ============================================================================
# Section 5: PlaceExtension — Tar Header Scan Edge Cases
# ============================================================================
section('5. Tar Header Scan Edge Cases') do
  stub_router = StubRouter.new
  ext = SkillsetExchange::PlaceExtension.new(stub_router)

  # 5.1 Archive with .py file in tools/
  Dir.mktmpdir('tar_scan_test') do |tmpdir|
    ss_dir = File.join(tmpdir, 'py_ss')
    FileUtils.mkdir_p(File.join(ss_dir, 'tools'))
    File.write(File.join(ss_dir, 'skillset.json'), '{}')
    File.write(File.join(ss_dir, 'tools', 'script.py'), 'print("hello")')
    tar_data = create_tar_gz(ss_dir, 'py_ss')

    result = ext.send(:tar_header_scan, tar_data)
    assert('.py in tools/ detected by tar scan') { !result.nil? }
    assert('.py filename in result') { result.include?('.py') }
  end

  # 5.2 Archive with shebang in lib/
  Dir.mktmpdir('tar_scan_test') do |tmpdir|
    ss_dir = File.join(tmpdir, 'shebang_ss')
    FileUtils.mkdir_p(File.join(ss_dir, 'lib'))
    File.write(File.join(ss_dir, 'skillset.json'), '{}')
    File.write(File.join(ss_dir, 'lib', 'runner'), "#!/usr/bin/env python3\nprint('hi')")
    tar_data = create_tar_gz(ss_dir, 'shebang_ss')

    result = ext.send(:tar_header_scan, tar_data)
    assert('shebang in lib/ detected by tar scan') { !result.nil? }
  end

  # 5.3 Clean knowledge archive passes
  Dir.mktmpdir('tar_scan_test') do |tmpdir|
    ss_dir = File.join(tmpdir, 'clean_ss')
    FileUtils.mkdir_p(File.join(ss_dir, 'knowledge'))
    File.write(File.join(ss_dir, 'skillset.json'), '{}')
    File.write(File.join(ss_dir, 'knowledge', 'guide.md'), '# Guide')
    File.write(File.join(ss_dir, 'config.yml'), 'key: value')
    tar_data = create_tar_gz(ss_dir, 'clean_ss')

    result = ext.send(:tar_header_scan, tar_data)
    assert('clean knowledge archive passes tar scan') { result.nil? }
  end

  # 5.4 Archive with .lua extension
  Dir.mktmpdir('tar_scan_test') do |tmpdir|
    ss_dir = File.join(tmpdir, 'lua_ss')
    FileUtils.mkdir_p(File.join(ss_dir, 'tools'))
    File.write(File.join(ss_dir, 'skillset.json'), '{}')
    File.write(File.join(ss_dir, 'tools', 'init.lua'), 'print("hello")')
    tar_data = create_tar_gz(ss_dir, 'lua_ss')

    result = ext.send(:tar_header_scan, tar_data)
    assert('.lua extension detected by tar scan') { !result.nil? }
  end
end

# ============================================================================
# Section 6: PlaceExtension — State Persistence
# ============================================================================
section('6. PlaceExtension — State Persistence') do
  persist_storage = Dir.mktmpdir('persist_test')

  stub_router = StubRouter.new
  ext1 = SkillsetExchange::PlaceExtension.new(stub_router)
  ext1.instance_variable_set(:@storage_dir, persist_storage)
  ext1.instance_variable_set(:@config, {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 10 },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })

  manager = KairosMcp::SkillSetManager.new(skillsets_dir: skillsets_dir)
  pkg = manager.package('test_knowledge')

  deposit_body = {
    'name' => 'test_knowledge',
    'version' => '1.0.0',
    'description' => 'Persistence test',
    'content_hash' => pkg[:content_hash],
    'archive_base64' => pkg[:archive_base64],
    'file_list' => pkg[:file_list],
    'tags' => ['persist']
  }

  env = mock_env('POST', '/place/v1/skillset_deposit', body: deposit_body)
  ext1.call(env, peer_id: 'agent-persist')

  # Verify state file exists
  state_file = File.join(persist_storage, 'exchange_state.json')
  assert('state file created after deposit') { File.exist?(state_file) }

  # Create new extension instance — should load persisted state
  ext2 = SkillsetExchange::PlaceExtension.new(stub_router)
  ext2.instance_variable_set(:@storage_dir, persist_storage)
  ext2.instance_variable_set(:@config, {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 10 },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })
  # Reload state
  ext2.send(:load_state)

  env = mock_env('GET', '/place/v1/skillset_browse')
  status, _headers, body = ext2.call(env, peer_id: 'agent-reader')
  result = JSON.parse(body.first, symbolize_names: true)

  assert('persisted state restored in new instance') { result[:entries].size > 0 }
  assert('persisted entry has correct name') {
    result[:entries].any? { |e| e[:name] == 'test_knowledge' }
  }

  FileUtils.rm_rf(persist_storage)
end

# ============================================================================
# Section 7: SkillSet Directory Structure
# ============================================================================
section('7. SkillSet Directory Structure') do
  template_dir = File.join(File.expand_path('templates', __dir__), 'skillsets', 'skillset_exchange')

  assert('skillset.json exists') { File.exist?(File.join(template_dir, 'skillset.json')) }
  assert('config/skillset_exchange.yml exists') { File.exist?(File.join(template_dir, 'config', 'skillset_exchange.yml')) }
  assert('tools/skillset_deposit.rb exists') { File.exist?(File.join(template_dir, 'tools', 'skillset_deposit.rb')) }
  assert('tools/skillset_browse.rb exists') { File.exist?(File.join(template_dir, 'tools', 'skillset_browse.rb')) }
  assert('tools/skillset_acquire.rb exists') { File.exist?(File.join(template_dir, 'tools', 'skillset_acquire.rb')) }
  assert('tools/skillset_withdraw.rb exists') { File.exist?(File.join(template_dir, 'tools', 'skillset_withdraw.rb')) }
  assert('lib/skillset_exchange/place_extension.rb exists') {
    File.exist?(File.join(template_dir, 'lib', 'skillset_exchange', 'place_extension.rb'))
  }
  assert('lib/skillset_exchange/exchange_validator.rb exists') {
    File.exist?(File.join(template_dir, 'lib', 'skillset_exchange', 'exchange_validator.rb'))
  }
  assert('knowledge guide exists') {
    File.exist?(File.join(template_dir, 'knowledge', 'skillset_exchange_guide', 'skillset_exchange_guide.md'))
  }

  # Verify skillset.json is parseable and correct
  metadata = JSON.parse(File.read(File.join(template_dir, 'skillset.json')))
  assert('skillset.json name is skillset_exchange') { metadata['name'] == 'skillset_exchange' }
  assert('skillset.json has 4 tool_classes') { metadata['tool_classes'].size == 4 }
  assert('skillset.json has place_extensions') { metadata['place_extensions'].is_a?(Array) && metadata['place_extensions'].size == 1 }
  assert('skillset.json depends_on mmp and hestia') {
    deps = metadata['depends_on'].map { |d| d['name'] }
    deps.include?('mmp') && deps.include?('hestia')
  }

  # Verify as valid Skillset
  ss = KairosMcp::Skillset.new(template_dir)
  assert('skillset_exchange is valid Skillset') { ss.valid? }
  assert('skillset_exchange layer is L1') { ss.layer == :L1 }
  assert('skillset_exchange has place_extensions') { ss.place_extensions.size == 1 }
end

# ============================================================================
# Cleanup
# ============================================================================
FileUtils.rm_rf(test_dir)

# ============================================================================
# Summary
# ============================================================================
puts ''
puts '=' * 60
puts "FINAL RESULTS: #{$pass_count} passed, #{$fail_count} failed"
puts '=' * 60
puts ''

exit($fail_count > 0 ? 1 : 0)
