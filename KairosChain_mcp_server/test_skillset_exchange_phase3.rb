#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================================
# SkillSet Exchange Phase 3 Test
# ============================================================================
# Tests PlaceExtension content + withdraw handlers, and MCP acquire/withdraw
# tool implementations.
#
# Usage:
#   RBENV_VERSION=3.3.7 ruby -I KairosChain_mcp_server/lib \
#     KairosChain_mcp_server/test_skillset_exchange_phase3.rb
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
# Helpers
# ============================================================================
def create_knowledge_skillset(parent_dir, name:, version: '1.0.0', tags: nil, provides: nil, depends_on: nil)
  ss_dir = File.join(parent_dir, name)
  FileUtils.mkdir_p(File.join(ss_dir, 'knowledge', "#{name}_topic"))

  metadata = {
    'name' => name,
    'version' => version,
    'description' => "Test knowledge SkillSet: #{name}",
    'author' => 'Test',
    'layer' => 'L2',
    'depends_on' => depends_on || [],
    'provides' => provides || [name],
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
class StubRegistryP3
  attr_accessor :keys

  def initialize
    @keys = {}
  end

  def public_key_for(id)
    @keys[id]
  end
end

class StubSessionStoreP3
  def validate(token)
    token
  end
end

class StubSkillBoardP3; end

class StubRouterP3
  attr_reader :skill_board, :session_store, :registry, :extensions

  def initialize(registry: nil)
    @skill_board = StubSkillBoardP3.new
    @session_store = StubSessionStoreP3.new
    @registry = registry || StubRegistryP3.new
    @extensions = []
  end
end

# Helper: deposit a SkillSet to the extension and return the result
def deposit_to_ext(ext, pkg, name:, peer_id:, tags: [], provides: [])
  deposit_body = {
    'name' => name,
    'version' => '1.0.0',
    'description' => "Test SkillSet: #{name}",
    'content_hash' => pkg[:content_hash],
    'archive_base64' => pkg[:archive_base64],
    'file_list' => pkg[:file_list],
    'tags' => tags,
    'provides' => provides
  }
  env = mock_env('POST', '/place/v1/skillset_deposit', body: deposit_body)
  status, _headers, body = ext.call(env, peer_id: peer_id)
  result = JSON.parse(body.first, symbolize_names: true)
  [status, result]
end

# ============================================================================
# Setup
# ============================================================================
puts ''
puts '=' * 60
puts 'SETUP: Creating Phase 3 test environment'
puts '=' * 60

test_dir = Dir.mktmpdir('kairos_se_phase3')
skillsets_dir = File.join(test_dir, 'skillsets')
FileUtils.mkdir_p(skillsets_dir)
FileUtils.mkdir_p(File.join(test_dir, 'storage'))
FileUtils.mkdir_p(File.join(test_dir, 'knowledge'))
FileUtils.mkdir_p(File.join(test_dir, 'config'))
FileUtils.mkdir_p(File.join(test_dir, 'skills'))
File.write(File.join(test_dir, 'skills', 'config.yml'), { 'skill_tools_enabled' => false }.to_yaml)

KairosMcp.data_dir = test_dir

# Create knowledge-only SkillSets for testing
create_knowledge_skillset(skillsets_dir, name: 'test_knowledge', version: '1.0.0', tags: ['test', 'knowledge'], provides: ['test_knowledge'])

puts "  Test dir: #{test_dir}"

# Load PlaceExtension
require_relative 'templates/skillsets/skillset_exchange/lib/skillset_exchange/place_extension'

# ============================================================================
# Section 1: PlaceExtension — handle_skillset_content
# ============================================================================
section('1. PlaceExtension — skillset_content') do
  storage_dir = Dir.mktmpdir('content_test')
  registry = StubRegistryP3.new
  registry.keys['agent-alpha'] = 'PEM_KEY_ALPHA_FAKE'
  stub_router = StubRouterP3.new(registry: registry)
  ext = SkillsetExchange::PlaceExtension.new(stub_router)
  ext.instance_variable_set(:@storage_dir, storage_dir)
  ext.instance_variable_set(:@config, {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 10 },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })

  manager = KairosMcp::SkillSetManager.new(skillsets_dir: skillsets_dir)
  pkg = manager.package('test_knowledge')

  # Deposit first
  dep_status, dep_result = deposit_to_ext(ext, pkg, name: 'test_knowledge', peer_id: 'agent-alpha', provides: ['test_knowledge'])
  assert('setup: deposit succeeds') { dep_status == 200 }

  # --- C1: Missing name parameter ---
  env = mock_env('GET', '/place/v1/skillset_content')
  status, _h, body = ext.call(env, peer_id: 'agent-beta')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('C1: missing name returns 400') { status == 400 }
  assert('C1: error is missing_name') { result[:error] == 'missing_name' }

  # --- C2: Non-existent name ---
  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=nonexistent')
  status, _h, body = ext.call(env, peer_id: 'agent-beta')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('C2: not found returns 404') { status == 404 }
  assert('C2: error is not_found') { result[:error] == 'not_found' }

  # --- C3: Successful content retrieval (single depositor) ---
  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=test_knowledge')
  status, _h, body = ext.call(env, peer_id: 'agent-beta')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('C3: content returns 200') { status == 200 }
  assert('C3: has name') { result[:name] == 'test_knowledge' }
  assert('C3: has version') { result[:version] == '1.0.0' }
  assert('C3: has archive_base64') { result[:archive_base64].is_a?(String) && !result[:archive_base64].empty? }
  assert('C3: has content_hash') { result[:content_hash] == pkg[:content_hash] }
  assert('C3: has depositor_id') { result[:depositor_id] == 'agent-alpha' }
  assert('C3: has file_list') { result[:file_list].is_a?(Array) }
  assert('C3: has provides') { result[:provides].is_a?(Array) }

  # --- C7: Verify archive_base64 decodes to valid tar.gz ---
  decoded = Base64.strict_decode64(result[:archive_base64])
  assert('C7: decoded archive is valid gzip') {
    begin
      io = StringIO.new(decoded)
      gz = Zlib::GzipReader.new(io)
      gz.close
      true
    rescue StandardError
      false
    end
  }

  # --- C8: Verify depositor_public_key is included ---
  assert('C8: depositor_public_key present') { result[:depositor_public_key] == 'PEM_KEY_ALPHA_FAKE' }

  # --- C11: Verify trust_notice fields ---
  tn = result[:trust_notice]
  assert('C11: trust_notice is hash') { tn.is_a?(Hash) }
  assert('C11: verified_by_place is false') { tn[:verified_by_place] == false }
  assert('C11: tar_header_scanned is true') { tn[:tar_header_scanned] == true }
  assert('C11: has disclaimer') { tn[:disclaimer].is_a?(String) && !tn[:disclaimer].empty? }
  assert('C11: has depositor_signed') { tn.key?(:depositor_signed) }

  # --- C4: Ambiguity (multiple depositors, no depositor param) ---
  # Deposit same name from different agent
  dep_status2, _ = deposit_to_ext(ext, pkg, name: 'test_knowledge', peer_id: 'agent-gamma')
  assert('setup: second deposit succeeds') { dep_status2 == 200 }

  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=test_knowledge')
  status, _h, body = ext.call(env, peer_id: 'agent-beta')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('C4: ambiguous returns 409') { status == 409 }
  assert('C4: error is ambiguous') { result[:error] == 'ambiguous' }
  assert('C4: depositors list present') { result[:depositors].is_a?(Array) && result[:depositors].size == 2 }

  # --- C5: Disambiguated by depositor param ---
  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=test_knowledge&depositor=agent-alpha')
  status, _h, body = ext.call(env, peer_id: 'agent-beta')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('C5: disambiguated returns 200') { status == 200 }
  assert('C5: correct depositor') { result[:depositor_id] == 'agent-alpha' }

  # --- C6: Wrong depositor_id ---
  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=test_knowledge&depositor=agent-nonexistent')
  status, _h, body = ext.call(env, peer_id: 'agent-beta')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('C6: wrong depositor returns 404') { status == 404 }

  # --- C9: depositor_public_key is nil when no key ---
  registry_nokey = StubRegistryP3.new
  router_nokey = StubRouterP3.new(registry: registry_nokey)
  ext_nokey = SkillsetExchange::PlaceExtension.new(router_nokey)
  ext_nokey.instance_variable_set(:@storage_dir, Dir.mktmpdir('nokey_test'))
  ext_nokey.instance_variable_set(:@config, {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 10 },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })
  deposit_to_ext(ext_nokey, pkg, name: 'test_knowledge', peer_id: 'agent-nokey')

  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=test_knowledge')
  status, _h, body = ext_nokey.call(env, peer_id: 'agent-reader')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('C9: depositor_public_key is nil when no key') { result[:depositor_public_key].nil? }

  # --- C12: Archive file missing on disk (storage inconsistency) ---
  ext_broken = SkillsetExchange::PlaceExtension.new(StubRouterP3.new)
  broken_storage = Dir.mktmpdir('broken_test')
  ext_broken.instance_variable_set(:@storage_dir, broken_storage)
  ext_broken.instance_variable_set(:@config, {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 10 },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })
  deposit_to_ext(ext_broken, pkg, name: 'test_knowledge', peer_id: 'agent-alpha')
  # Delete the archive file to simulate inconsistency
  archive_dir = File.join(broken_storage, 'test_knowledge_agent-alpha')
  File.delete(File.join(archive_dir, 'archive.tar.gz'))

  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=test_knowledge')
  status, _h, body = ext_broken.call(env, peer_id: 'agent-reader')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('C12: archive missing returns 500') { status == 500 }
  assert('C12: error is archive_missing') { result[:error] == 'archive_missing' }

  # --- C13: Content after state reload ---
  persist_storage = Dir.mktmpdir('persist_content_test')
  ext_persist = SkillsetExchange::PlaceExtension.new(StubRouterP3.new)
  ext_persist.instance_variable_set(:@storage_dir, persist_storage)
  ext_persist.instance_variable_set(:@config, {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 10 },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })
  deposit_to_ext(ext_persist, pkg, name: 'test_knowledge', peer_id: 'agent-persist')

  # Create new instance, reload state
  ext_reloaded = SkillsetExchange::PlaceExtension.new(StubRouterP3.new)
  ext_reloaded.instance_variable_set(:@storage_dir, persist_storage)
  ext_reloaded.instance_variable_set(:@config, {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 10 },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })
  ext_reloaded.send(:load_state)

  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=test_knowledge')
  status, _h, body = ext_reloaded.call(env, peer_id: 'agent-reader')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('C13: content after reload returns 200') { status == 200 }
  assert('C13: reloaded content_hash matches') { result[:content_hash] == pkg[:content_hash] }
end

# ============================================================================
# Section 2: PlaceExtension — handle_skillset_withdraw
# ============================================================================
section('2. PlaceExtension — skillset_withdraw') do
  storage_dir = Dir.mktmpdir('withdraw_test')
  stub_router = StubRouterP3.new
  ext = SkillsetExchange::PlaceExtension.new(stub_router)
  ext.instance_variable_set(:@storage_dir, storage_dir)
  ext.instance_variable_set(:@config, {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 10 },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })

  manager = KairosMcp::SkillSetManager.new(skillsets_dir: skillsets_dir)
  pkg = manager.package('test_knowledge')

  # Deposit for withdrawal tests
  deposit_to_ext(ext, pkg, name: 'test_knowledge', peer_id: 'agent-alpha')

  # --- W1: Missing name ---
  env = mock_env('POST', '/place/v1/skillset_withdraw', body: {})
  status, _h, body = ext.call(env, peer_id: 'agent-alpha')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('W1: missing name returns 400') { status == 400 }
  assert('W1: error is missing_name') { result[:error] == 'missing_name' }

  # --- W2: Non-existent deposit ---
  env = mock_env('POST', '/place/v1/skillset_withdraw', body: { 'name' => 'nonexistent' })
  status, _h, body = ext.call(env, peer_id: 'agent-alpha')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('W2: not found returns 404') { status == 404 }
  assert('W2: error is not_found') { result[:error] == 'not_found' }

  # --- W3: Not the depositor ---
  env = mock_env('POST', '/place/v1/skillset_withdraw', body: { 'name' => 'test_knowledge' })
  status, _h, body = ext.call(env, peer_id: 'agent-other')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('W3: not depositor returns 404') { status == 404 }
  assert('W3: error is not_found') { result[:error] == 'not_found' }

  # --- W8/W9: Withdrawal with reason and without ---
  # First, deposit two SkillSets for these tests
  create_knowledge_skillset(skillsets_dir, name: 'withdraw_reason_test', version: '1.0.0')
  pkg_reason = manager.package('withdraw_reason_test')
  deposit_to_ext(ext, pkg_reason, name: 'withdraw_reason_test', peer_id: 'agent-alpha')

  create_knowledge_skillset(skillsets_dir, name: 'withdraw_noreason_test', version: '1.0.0')
  pkg_noreason = manager.package('withdraw_noreason_test')
  deposit_to_ext(ext, pkg_noreason, name: 'withdraw_noreason_test', peer_id: 'agent-alpha')

  # --- W4: Successful withdrawal ---
  deposit_dir = File.join(storage_dir, 'test_knowledge_agent-alpha')
  assert('W4 setup: deposit dir exists before withdrawal') { File.directory?(deposit_dir) }

  env = mock_env('POST', '/place/v1/skillset_withdraw', body: { 'name' => 'test_knowledge', 'reason' => 'upgrading' })
  status, _h, body = ext.call(env, peer_id: 'agent-alpha')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('W4: withdrawal returns 200') { status == 200 }
  assert('W4: status is withdrawn') { result[:status] == 'withdrawn' }
  assert('W4: name correct') { result[:name] == 'test_knowledge' }
  assert('W4: depositor_id present') { result[:depositor_id] == 'agent-alpha' }
  assert('W4: chain_recorded true') { result[:chain_recorded] == true }
  assert('W4: has note') { result[:note].is_a?(String) }

  # --- W5: After withdrawal, browse returns 0 for this SkillSet ---
  env = mock_env('GET', '/place/v1/skillset_browse', query: 'search=test_knowledge')
  _, _h, body = ext.call(env, peer_id: 'agent-beta')
  browse_result = JSON.parse(body.first, symbolize_names: true)
  test_knowledge_entries = browse_result[:entries].select { |e| e[:name] == 'test_knowledge' }
  assert('W5: withdrawn SkillSet not in browse') { test_knowledge_entries.empty? }

  # --- W6: After withdrawal, content returns 404 ---
  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=test_knowledge')
  status, _h, body = ext.call(env, peer_id: 'agent-beta')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('W6: content after withdrawal returns 404') { status == 404 }

  # --- W7: Disk files deleted ---
  assert('W7: deposit dir deleted after withdrawal') { !File.directory?(deposit_dir) }

  # --- W10: State persistence after withdrawal ---
  ext_reloaded = SkillsetExchange::PlaceExtension.new(StubRouterP3.new)
  ext_reloaded.instance_variable_set(:@storage_dir, storage_dir)
  ext_reloaded.instance_variable_set(:@config, {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 10 },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })
  ext_reloaded.send(:load_state)

  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=test_knowledge')
  status, _h, _body = ext_reloaded.call(env, peer_id: 'agent-reader')
  assert('W10: after reload, withdrawn SkillSet still gone (404)') { status == 404 }
end

# ============================================================================
# Section 3: MCP Tool Loading — acquire and withdraw
# ============================================================================
section('3. MCP Tool Loading — acquire and withdraw') do
  require_relative 'templates/skillsets/skillset_exchange/tools/skillset_acquire'
  require_relative 'templates/skillsets/skillset_exchange/tools/skillset_withdraw'

  safety = KairosMcp::Safety.new

  # --- Acquire tool ---
  acquire_tool = KairosMcp::SkillSets::SkillsetExchange::Tools::SkillsetAcquire.new(safety)
  assert('acquire tool instantiates') { !acquire_tool.nil? }
  assert('acquire tool name correct') { acquire_tool.name == 'skillset_acquire' }
  assert('acquire tool has input_schema') { acquire_tool.input_schema[:type] == 'object' }
  assert('acquire tool schema has name property') { acquire_tool.input_schema[:properties].key?(:name) }
  assert('acquire tool schema has depositor_id property') { acquire_tool.input_schema[:properties].key?(:depositor_id) }
  assert('acquire tool schema has force property') { acquire_tool.input_schema[:properties].key?(:force) }
  assert('acquire tool description is not stub') {
    !acquire_tool.description.include?('not yet implemented') &&
    !acquire_tool.description.include?('Not yet implemented')
  }

  # --- Withdraw tool ---
  withdraw_tool = KairosMcp::SkillSets::SkillsetExchange::Tools::SkillsetWithdraw.new(safety)
  assert('withdraw tool instantiates') { !withdraw_tool.nil? }
  assert('withdraw tool name correct') { withdraw_tool.name == 'skillset_withdraw' }
  assert('withdraw tool has input_schema') { withdraw_tool.input_schema[:type] == 'object' }
  assert('withdraw tool schema has name property') { withdraw_tool.input_schema[:properties].key?(:name) }
  assert('withdraw tool schema has reason property') { withdraw_tool.input_schema[:properties].key?(:reason) }
  assert('withdraw tool description is not stub') {
    !withdraw_tool.description.include?('not yet implemented') &&
    !withdraw_tool.description.include?('Not yet implemented')
  }

  # --- Both tools return error without connection (not stub text) ---
  acquire_result = acquire_tool.call({ 'name' => 'anything' })
  acquire_text = acquire_result.first[:text]
  acquire_parsed = JSON.parse(acquire_text)
  assert('acquire tool without connection returns structured error') { acquire_parsed['error'] == 'Not connected' }
  assert('acquire tool without connection has hint') { acquire_parsed['hint'].include?('meeting_connect') }

  withdraw_result = withdraw_tool.call({ 'name' => 'anything' })
  withdraw_text = withdraw_result.first[:text]
  withdraw_parsed = JSON.parse(withdraw_text)
  assert('withdraw tool without connection returns structured error') { withdraw_parsed['error'] == 'Not connected' }
end

# ============================================================================
# Section 4: Integration — deposit -> content -> verify round-trip
# ============================================================================
section('4. Integration — deposit -> content -> verify') do
  int_storage = Dir.mktmpdir('integration_test')
  stub_router = StubRouterP3.new
  ext = SkillsetExchange::PlaceExtension.new(stub_router)
  ext.instance_variable_set(:@storage_dir, int_storage)
  ext.instance_variable_set(:@config, {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 10 },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })

  manager = KairosMcp::SkillSetManager.new(skillsets_dir: skillsets_dir)

  # --- I1: Deposit -> content -> verify archive hash ---
  pkg = manager.package('test_knowledge')
  deposit_to_ext(ext, pkg, name: 'test_knowledge', peer_id: 'agent-alice')

  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=test_knowledge')
  status, _h, body = ext.call(env, peer_id: 'agent-bob')
  content = JSON.parse(body.first, symbolize_names: true)
  assert('I1: content retrieval succeeds') { status == 200 }

  # Verify that decoding archive and computing content_hash matches
  archive_data = Base64.strict_decode64(content[:archive_base64])
  Dir.mktmpdir('verify_hash') do |tmpdir|
    # Extract tar.gz
    io = StringIO.new(archive_data)
    Zlib::GzipReader.wrap(io) do |gz|
      Gem::Package::TarReader.new(gz) do |tar|
        tar.each do |entry|
          next if entry.header.typeflag == '2'
          next if entry.header.typeflag == '1'
          dest = File.join(tmpdir, entry.full_name)
          if entry.directory?
            FileUtils.mkdir_p(dest)
          elsif entry.file?
            FileUtils.mkdir_p(File.dirname(dest))
            File.binwrite(dest, entry.read)
          end
        end
      end
    end
    extracted = File.join(tmpdir, 'test_knowledge')
    temp_ss = KairosMcp::Skillset.new(extracted)
    actual_hash = temp_ss.content_hash
    assert('I1: content_hash round-trip matches') { actual_hash == content[:content_hash] }
    assert('I1: content_hash matches original package') { actual_hash == pkg[:content_hash] }
  end

  # --- I2: Deposit -> withdraw -> content returns 404 ---
  create_knowledge_skillset(skillsets_dir, name: 'lifecycle_test', version: '1.0.0')
  pkg_lc = manager.package('lifecycle_test')
  deposit_to_ext(ext, pkg_lc, name: 'lifecycle_test', peer_id: 'agent-alice')

  env = mock_env('POST', '/place/v1/skillset_withdraw', body: { 'name' => 'lifecycle_test' })
  status, _h, _body = ext.call(env, peer_id: 'agent-alice')
  assert('I2: withdrawal succeeds') { status == 200 }

  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=lifecycle_test')
  status, _h, _body = ext.call(env, peer_id: 'agent-bob')
  assert('I2: content after withdraw returns 404') { status == 404 }

  # --- I3: Deposit by A -> content by B -> depositor_id is A ---
  create_knowledge_skillset(skillsets_dir, name: 'cross_agent_test', version: '1.0.0')
  pkg_ca = manager.package('cross_agent_test')
  deposit_to_ext(ext, pkg_ca, name: 'cross_agent_test', peer_id: 'agent-alice')

  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=cross_agent_test')
  status, _h, body = ext.call(env, peer_id: 'agent-bob')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('I3: content by B returns 200') { status == 200 }
  assert('I3: depositor_id is A') { result[:depositor_id] == 'agent-alice' }

  # --- I4: Multiple deposits same name -> disambiguate -> get specific ---
  create_knowledge_skillset(skillsets_dir, name: 'multi_dep_test', version: '1.0.0')
  pkg_md = manager.package('multi_dep_test')
  deposit_to_ext(ext, pkg_md, name: 'multi_dep_test', peer_id: 'agent-alice')
  deposit_to_ext(ext, pkg_md, name: 'multi_dep_test', peer_id: 'agent-charlie')

  # Without disambiguation -> 409
  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=multi_dep_test')
  status, _h, body = ext.call(env, peer_id: 'agent-bob')
  assert('I4: ambiguous returns 409') { status == 409 }

  # With disambiguation -> specific depositor
  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=multi_dep_test&depositor=agent-charlie')
  status, _h, body = ext.call(env, peer_id: 'agent-bob')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('I4: disambiguated returns 200') { status == 200 }
  assert('I4: correct depositor returned') { result[:depositor_id] == 'agent-charlie' }

  # --- I5: Deposit -> withdraw -> re-acquire fails (content gone) ---
  create_knowledge_skillset(skillsets_dir, name: 'reacquire_test', version: '1.0.0')
  pkg_ra = manager.package('reacquire_test')
  deposit_to_ext(ext, pkg_ra, name: 'reacquire_test', peer_id: 'agent-alice')

  # Verify content available
  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=reacquire_test')
  status, _h, _body = ext.call(env, peer_id: 'agent-bob')
  assert('I5: content available before withdrawal') { status == 200 }

  # Withdraw
  env = mock_env('POST', '/place/v1/skillset_withdraw', body: { 'name' => 'reacquire_test' })
  ext.call(env, peer_id: 'agent-alice')

  # Try to get content again
  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=reacquire_test')
  status, _h, _body = ext.call(env, peer_id: 'agent-bob')
  assert('I5: content gone after withdrawal (404)') { status == 404 }
end

# ============================================================================
# Section 5: Content hash integrity — archive matches declared hash
# ============================================================================
section('5. Content hash integrity') do
  storage_dir = Dir.mktmpdir('hash_test')
  stub_router = StubRouterP3.new
  ext = SkillsetExchange::PlaceExtension.new(stub_router)
  ext.instance_variable_set(:@storage_dir, storage_dir)
  ext.instance_variable_set(:@config, {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 10 },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })

  manager = KairosMcp::SkillSetManager.new(skillsets_dir: skillsets_dir)
  pkg = manager.package('test_knowledge')
  deposit_to_ext(ext, pkg, name: 'test_knowledge', peer_id: 'agent-alice')

  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=test_knowledge')
  _, _h, body = ext.call(env, peer_id: 'agent-bob')
  content = JSON.parse(body.first, symbolize_names: true)

  # The content_hash in the response should match what was deposited
  assert('content_hash from content matches deposited hash') {
    content[:content_hash] == pkg[:content_hash]
  }

  # The archive_base64 should be identical to what was deposited
  assert('archive_base64 from content matches deposited archive') {
    content[:archive_base64] == pkg[:archive_base64]
  }

  # Signature and depositor_id are preserved
  assert('depositor_id preserved') { content[:depositor_id] == 'agent-alice' }
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
