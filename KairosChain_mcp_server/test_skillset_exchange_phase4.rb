#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================================
# SkillSet Exchange Phase 4 Test — Integration & Edge Cases
# ============================================================================
# Comprehensive integration tests covering:
#   4-1: End-to-end (Agent A deposits, Agent B browses/acquires/installs)
#   4-2: Security (executable rejection, tampered archive, path traversal, signatures)
#   4-3: DEE compliance (random order, no ranking)
#   4-4: Edge cases (disambiguation, quotas, re-deposit, force, withdraw)
#   4-5: MCP tool behavior against local PlaceExtension
#
# Usage:
#   RBENV_VERSION=3.3.7 ruby -I KairosChain_mcp_server/lib \
#     KairosChain_mcp_server/test_skillset_exchange_phase4.rb
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
require 'openssl'

# Load MMP::Crypto directly (needed for signature tests)
require_relative 'templates/skillsets/mmp/lib/mmp/crypto'

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
def create_knowledge_skillset(parent_dir, name:, version: '1.0.0', tags: nil, provides: nil, depends_on: nil, content: nil)
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
    content || "---\nname: #{name}_topic\ndescription: Test topic\nversion: #{version}\n---\n\n# #{name}\n\nTest content for #{name}.\n"
  )
  ss_dir
end

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
# Stub components
# ============================================================================
class StubRegistryP4
  attr_accessor :keys

  def initialize
    @keys = {}
  end

  def public_key_for(id)
    @keys[id]
  end
end

class StubSessionStoreP4
  def validate(token)
    token
  end
end

class StubSkillBoardP4; end

class StubRouterP4
  attr_reader :skill_board, :session_store, :registry, :extensions

  def initialize(registry: nil)
    @skill_board = StubSkillBoardP4.new
    @session_store = StubSessionStoreP4.new
    @registry = registry || StubRegistryP4.new
    @extensions = []
  end
end

# Helper: deposit a SkillSet to the extension and return [status, result]
def deposit_to_ext(ext, pkg, name:, peer_id:, tags: [], provides: [], signature: nil)
  deposit_body = {
    'name' => name,
    'version' => pkg[:version] || '1.0.0',
    'description' => "Test SkillSet: #{name}",
    'content_hash' => pkg[:content_hash],
    'archive_base64' => pkg[:archive_base64],
    'file_list' => pkg[:file_list],
    'tags' => tags,
    'provides' => provides,
    'signature' => signature
  }
  env = mock_env('POST', '/place/v1/skillset_deposit', body: deposit_body)
  status, _headers, body = ext.call(env, peer_id: peer_id)
  result = JSON.parse(body.first, symbolize_names: true)
  [status, result]
end

# Helper: create a fresh PlaceExtension with custom config
def create_extension(registry: nil, config: nil, storage_dir: nil)
  stub_router = StubRouterP4.new(registry: registry)
  ext = SkillsetExchange::PlaceExtension.new(stub_router)
  sd = storage_dir || Dir.mktmpdir('phase4_ext')
  ext.instance_variable_set(:@storage_dir, sd)
  ext.instance_variable_set(:@config, config || {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 10 },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })
  [ext, sd]
end

# Helper: simulate what MCP acquire tool does (GET content + verify + install)
def simulate_acquire(ext, name:, peer_id:, depositor_id: nil, manager:, force: false, verify_signature_config: true)
  # 1. GET /place/v1/skillset_content
  query = "name=#{name}"
  query += "&depositor=#{depositor_id}" if depositor_id
  env = mock_env('GET', '/place/v1/skillset_content', query: query)
  status, _headers, body = ext.call(env, peer_id: peer_id)
  content = JSON.parse(body.first, symbolize_names: true)

  return { success: false, http_status: status, error: content } unless status == 200

  # 2. Decode and verify content hash
  archive_data = Base64.strict_decode64(content[:archive_base64])
  confirmed_name = content[:name] || name

  hash_verified = false
  Dir.mktmpdir('phase4_acquire') do |tmpdir|
    # Extract
    target_dir = File.expand_path(tmpdir)
    io = StringIO.new(archive_data)
    Zlib::GzipReader.wrap(io) do |gz|
      Gem::Package::TarReader.new(gz) do |tar|
        tar.each do |entry|
          next if entry.header.typeflag == '2'
          next if entry.header.typeflag == '1'
          dest = File.expand_path(File.join(target_dir, entry.full_name))
          unless dest.start_with?(target_dir + '/') || dest == target_dir
            return { success: false, error: 'path_traversal' }
          end
          if entry.directory?
            FileUtils.mkdir_p(dest)
          elsif entry.file?
            FileUtils.mkdir_p(File.dirname(dest))
            File.binwrite(dest, entry.read)
          end
        end
      end
    end

    extracted_dir = File.join(tmpdir, confirmed_name)
    return { success: false, error: 'invalid_archive_structure' } unless File.directory?(extracted_dir)

    temp_ss = ::KairosMcp::Skillset.new(extracted_dir)
    actual_hash = temp_ss.content_hash
    if actual_hash != content[:content_hash]
      return { success: false, error: 'content_hash_mismatch', expected: content[:content_hash], actual: actual_hash }
    end
    hash_verified = true
  end

  # 3. Signature verification (simplified)
  sig_verified = false
  if verify_signature_config
    sig = content[:signature]
    pubkey = content[:depositor_public_key]
    if sig && pubkey
      begin
        crypto = ::MMP::Crypto.new(auto_generate: false)
        sig_verified = crypto.verify_signature(content[:content_hash], sig, pubkey)
        return { success: false, error: 'signature_failed' } unless sig_verified
      rescue StandardError => e
        return { success: false, error: "signature_error: #{e.message}" }
      end
    end
  end

  # 4. Install
  archive_payload = {
    name: confirmed_name,
    archive_base64: content[:archive_base64],
    content_hash: content[:content_hash]
  }

  begin
    install_result = manager.install_from_archive(archive_payload, force: force)
  rescue ArgumentError => e
    return { success: false, error: e.message }
  rescue SecurityError => e
    return { success: false, error: "security: #{e.message}" }
  end

  {
    success: true,
    name: confirmed_name,
    version: content[:version],
    content_hash: content[:content_hash],
    signature_verified: sig_verified,
    content_hash_verified: hash_verified,
    installed_path: install_result[:path]
  }
end

# ============================================================================
# Setup
# ============================================================================
puts ''
puts '=' * 60
puts 'SETUP: Creating Phase 4 test environment'
puts '=' * 60

# Agent A environment
dir_a = Dir.mktmpdir('kairos_p4_agent_a')
ss_dir_a = File.join(dir_a, 'skillsets')
FileUtils.mkdir_p(ss_dir_a)
FileUtils.mkdir_p(File.join(dir_a, 'storage'))
FileUtils.mkdir_p(File.join(dir_a, 'knowledge'))
FileUtils.mkdir_p(File.join(dir_a, 'config'))
FileUtils.mkdir_p(File.join(dir_a, 'skills'))
File.write(File.join(dir_a, 'skills', 'config.yml'), { 'skill_tools_enabled' => false }.to_yaml)

# Agent B environment
dir_b = Dir.mktmpdir('kairos_p4_agent_b')
ss_dir_b = File.join(dir_b, 'skillsets')
FileUtils.mkdir_p(ss_dir_b)
FileUtils.mkdir_p(File.join(dir_b, 'storage'))
FileUtils.mkdir_p(File.join(dir_b, 'knowledge'))
FileUtils.mkdir_p(File.join(dir_b, 'config'))
FileUtils.mkdir_p(File.join(dir_b, 'skills'))
File.write(File.join(dir_b, 'skills', 'config.yml'), { 'skill_tools_enabled' => false }.to_yaml)

# Load PlaceExtension
require_relative 'templates/skillsets/skillset_exchange/lib/skillset_exchange/place_extension'

puts "  Agent A dir: #{dir_a}"
puts "  Agent B dir: #{dir_b}"

# ============================================================================
# Section 1 (4-1): End-to-End — Agent A deposits, Agent B browses and acquires
# ============================================================================
section('4-1. End-to-End: deposit -> browse -> acquire -> verify') do
  KairosMcp.data_dir = dir_a

  # Agent A creates a knowledge-only SkillSet
  knowledge_content = <<~MD
    ---
    name: genomics_guide_topic
    description: Genomics analysis guide
    version: 1.0.0
    tags:
      - genomics
      - guide
    ---

    # Genomics Analysis Guide

    ## RNA-Seq Pipeline
    1. Quality control with FastQC
    2. Alignment with STAR
    3. Quantification with featureCounts
  MD
  create_knowledge_skillset(ss_dir_a, name: 'genomics_guide', version: '1.0.0',
    tags: ['genomics', 'guide'], provides: ['genomics_guide'], content: knowledge_content)

  manager_a = KairosMcp::SkillSetManager.new(skillsets_dir: ss_dir_a)
  pkg_a = manager_a.package('genomics_guide')

  # Create PlaceExtension (shared meeting place)
  ext, _storage = create_extension

  # Agent A deposits
  dep_status, dep_result = deposit_to_ext(ext, pkg_a, name: 'genomics_guide', peer_id: 'agent-a',
    tags: ['genomics', 'guide'], provides: ['genomics_guide'])
  assert('E2E: Agent A deposit succeeds') { dep_status == 200 }
  assert('E2E: deposit status is deposited') { dep_result[:status] == 'deposited' }

  # Agent B browses
  env = mock_env('GET', '/place/v1/skillset_browse', query: 'search=genomics')
  status, _h, body = ext.call(env, peer_id: 'agent-b')
  browse_result = JSON.parse(body.first, symbolize_names: true)
  assert('E2E: browse returns 200') { status == 200 }
  assert('E2E: browse finds genomics_guide') {
    browse_result[:entries].any? { |e| e[:name] == 'genomics_guide' }
  }

  # Agent B acquires (via simulate_acquire)
  KairosMcp.data_dir = dir_b
  manager_b = KairosMcp::SkillSetManager.new(skillsets_dir: ss_dir_b)

  acquire_result = simulate_acquire(ext, name: 'genomics_guide', peer_id: 'agent-b',
    manager: manager_b, verify_signature_config: false)

  assert('E2E: acquire succeeds') { acquire_result[:success] == true }
  assert('E2E: content_hash verified') { acquire_result[:content_hash_verified] == true }
  assert('E2E: installed version correct') { acquire_result[:version] == '1.0.0' }

  # Verify installed SkillSet is valid
  installed_ss = manager_b.find_skillset('genomics_guide')
  assert('E2E: installed SkillSet found') { !installed_ss.nil? }
  assert('E2E: installed SkillSet is valid') { installed_ss.valid? }
  assert('E2E: installed SkillSet is knowledge_only') { installed_ss.knowledge_only? }
  assert('E2E: installed version matches') { installed_ss.version == '1.0.0' }

  # Verify knowledge content matches original
  original_path = File.join(ss_dir_a, 'genomics_guide', 'knowledge', 'genomics_guide_topic', 'genomics_guide_topic.md')
  installed_path = File.join(installed_ss.path, 'knowledge', 'genomics_guide_topic', 'genomics_guide_topic.md')
  assert('E2E: knowledge content matches') { File.read(original_path) == File.read(installed_path) }

  # Verify content_hash matches
  assert('E2E: content_hash matches original') { installed_ss.content_hash == pkg_a[:content_hash] }
end

# ============================================================================
# Section 2 (4-2): Security Tests
# ============================================================================
section('4-2. Security: executable rejection, tampered archive, signatures') do
  KairosMcp.data_dir = dir_a

  # --- S1: Executable SkillSet deposit refused by ExchangeValidator (client-side) ---
  require_relative 'templates/skillsets/skillset_exchange/lib/skillset_exchange/exchange_validator'
  create_executable_skillset(ss_dir_a, name: 'evil_executable')

  manager_a = KairosMcp::SkillSetManager.new(skillsets_dir: ss_dir_a)
  validator = SkillsetExchange::ExchangeValidator.new(config: {})
  result = validator.validate_for_deposit('evil_executable', manager: manager_a)
  assert('S1: executable rejected by client ExchangeValidator') { result[:valid] == false }

  # --- S2: Executable archive refused by PlaceExtension tar header scan ---
  exec_dir = File.join(ss_dir_a, 'evil_executable')
  exec_tar = create_tar_gz(exec_dir, 'evil_executable')
  ext_sec, _storage = create_extension

  exec_body = {
    'name' => 'evil_executable',
    'version' => '1.0.0',
    'description' => 'Evil',
    'content_hash' => 'fake',
    'archive_base64' => Base64.strict_encode64(exec_tar),
    'file_list' => [],
    'tags' => []
  }
  env = mock_env('POST', '/place/v1/skillset_deposit', body: exec_body)
  status, _h, body = ext_sec.call(env, peer_id: 'agent-evil')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('S2: server rejects executable archive') { status == 422 }
  assert('S2: error is executable_content') { result[:error] == 'executable_content' }

  # --- S3: Tampered archive (content hash mismatch) ---
  create_knowledge_skillset(ss_dir_a, name: 'tampered_test', version: '1.0.0')
  pkg_tamper = manager_a.package('tampered_test')

  tampered_body = {
    'name' => 'tampered_test',
    'version' => '1.0.0',
    'description' => 'Tampered',
    'content_hash' => 'sha256:0000000000000000000000000000000000000000000000000000000000000000',
    'archive_base64' => pkg_tamper[:archive_base64],
    'file_list' => pkg_tamper[:file_list],
    'tags' => []
  }
  env = mock_env('POST', '/place/v1/skillset_deposit', body: tampered_body)
  status, _h, body = ext_sec.call(env, peer_id: 'agent-evil')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('S3: tampered archive rejected by Place') { status == 422 }
  assert('S3: error is content_hash_mismatch') { result[:error] == 'content_hash_mismatch' }

  # --- S4: Path traversal in tar entries ---
  # SecurityError from extract_tar_gz may not be caught by rescue StandardError
  # (SecurityError < Exception in Ruby 3.x), so we test that the error is raised.
  malicious_tar_gz = StringIO.new
  Zlib::GzipWriter.wrap(malicious_tar_gz) do |gz|
    Gem::Package::TarWriter.new(gz) do |tar|
      tar.add_file_simple('../../etc/passwd', 0o644, 4) { |tio| tio.write('evil') }
    end
  end
  traversal_body = {
    'name' => 'traversal_test',
    'version' => '1.0.0',
    'description' => 'Traversal',
    'content_hash' => 'fake',
    'archive_base64' => Base64.strict_encode64(malicious_tar_gz.string),
    'file_list' => [],
    'tags' => []
  }
  env = mock_env('POST', '/place/v1/skillset_deposit', body: traversal_body)
  begin
    status, _h, body = ext_sec.call(env, peer_id: 'agent-evil')
    result = JSON.parse(body.first, symbolize_names: true)
    # If the error is caught, we expect a 422
    assert('S4: path traversal tar rejected (structured)') { status == 422 }
  rescue SecurityError => e
    # SecurityError may propagate uncaught (Ruby 3.x: SecurityError < Exception)
    assert('S4: path traversal detected via SecurityError') { e.message.include?('Path traversal') }
  end

  # --- S5-S10: Signature verification modes ---
  # Generate a keypair for signing tests
  crypto = ::MMP::Crypto.new(auto_generate: true)
  pubkey_pem = crypto.export_public_key

  create_knowledge_skillset(ss_dir_a, name: 'sig_test', version: '1.0.0')
  pkg_sig = manager_a.package('sig_test')

  # Sign the content hash
  valid_sig = crypto.sign(pkg_sig[:content_hash])

  # S5: Valid signature passes (require_signature: true)
  registry_sig = StubRegistryP4.new
  registry_sig.keys['agent-signer'] = pubkey_pem
  ext_sig, _storage = create_extension(
    registry: registry_sig,
    config: {
      'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 10, 'require_signature' => true },
      'place' => { 'max_total_archive_bytes' => 100_000_000 }
    }
  )
  dep_status, dep_result = deposit_to_ext(ext_sig, pkg_sig, name: 'sig_test',
    peer_id: 'agent-signer', signature: valid_sig)
  assert('S5: valid signature deposit succeeds') { dep_status == 200 }
  assert('S5: depositor_signed is true') { dep_result.dig(:trust_notice, :depositor_signed) == true }

  # S6: Invalid signature fails when require_signature: true
  # Create separate SkillSets for each test so archive name matches deposit name
  create_knowledge_skillset(ss_dir_a, name: 'sig_bad', version: '1.0.0') unless File.directory?(File.join(ss_dir_a, 'sig_bad'))
  pkg_sig_bad = manager_a.package('sig_bad')
  invalid_sig = Base64.strict_encode64('invalid_signature_data')
  dep_status_bad, dep_result_bad = deposit_to_ext(ext_sig, pkg_sig_bad, name: 'sig_bad',
    peer_id: 'agent-signer', signature: invalid_sig)
  assert('S6: invalid signature rejected') { dep_status_bad == 422 }
  assert('S6: error is signature_invalid') { dep_result_bad[:error] == 'signature_invalid' }

  # S7: Missing signature when require_signature: true
  create_knowledge_skillset(ss_dir_a, name: 'sig_nosig', version: '1.0.0') unless File.directory?(File.join(ss_dir_a, 'sig_nosig'))
  pkg_sig_nosig = manager_a.package('sig_nosig')
  dep_status_nosig, dep_result_nosig = deposit_to_ext(ext_sig, pkg_sig_nosig, name: 'sig_nosig',
    peer_id: 'agent-signer')
  assert('S7: missing sig rejected when require_signature') { dep_status_nosig == 422 }
  assert('S7: error is signature_required') { dep_result_nosig[:error] == 'signature_required' }

  # S8: No public key in registry when require_signature: true
  create_knowledge_skillset(ss_dir_a, name: 'sig_nokey', version: '1.0.0') unless File.directory?(File.join(ss_dir_a, 'sig_nokey'))
  pkg_sig_nokey = manager_a.package('sig_nokey')
  valid_sig_nokey = crypto.sign(pkg_sig_nokey[:content_hash])
  dep_status_nokey, dep_result_nokey = deposit_to_ext(ext_sig, pkg_sig_nokey, name: 'sig_nokey',
    peer_id: 'agent-unknown', signature: valid_sig_nokey)
  assert('S8: no public key rejected when require_signature') { dep_status_nokey == 422 }
  assert('S8: error is public_key_unavailable') { dep_result_nokey[:error] == 'public_key_unavailable' }

  # S9: Signature present but require_signature: false (passes even with invalid sig)
  ext_nosigcheck, _ = create_extension(
    registry: registry_sig,
    config: {
      'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 10, 'require_signature' => false },
      'place' => { 'max_total_archive_bytes' => 100_000_000 }
    }
  )
  dep_status_opt, _ = deposit_to_ext(ext_nosigcheck, pkg_sig, name: 'sig_test',
    peer_id: 'agent-signer', signature: invalid_sig)
  assert('S9: invalid sig allowed when require_signature=false') { dep_status_opt == 200 }

  # S10: Acquire-side signature verification (valid sig passes on content retrieval)
  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=sig_test')
  status, _h, body = ext_sig.call(env, peer_id: 'agent-acquirer')
  content = JSON.parse(body.first, symbolize_names: true)
  assert('S10: content includes depositor_public_key') { content[:depositor_public_key] == pubkey_pem }
  assert('S10: content includes signature') { content[:signature] == valid_sig }

  # Verify the signature client-side (as acquire tool would)
  verify_crypto = ::MMP::Crypto.new(auto_generate: false)
  verified = verify_crypto.verify_signature(content[:content_hash], content[:signature], content[:depositor_public_key])
  assert('S10: client-side signature verification passes') { verified == true }
end

# ============================================================================
# Section 3 (4-3): DEE Compliance
# ============================================================================
section('4-3. DEE Compliance: random order, no ranking') do
  ext_dee, _storage = create_extension

  KairosMcp.data_dir = dir_a
  manager_a = KairosMcp::SkillSetManager.new(skillsets_dir: ss_dir_a)

  # Deposit 5 SkillSets
  5.times do |i|
    ss_name = "dee_test_#{i}"
    create_knowledge_skillset(ss_dir_a, name: ss_name, version: '1.0.0') unless File.directory?(File.join(ss_dir_a, ss_name))
    pkg = manager_a.package(ss_name)
    deposit_to_ext(ext_dee, pkg, name: ss_name, peer_id: "agent-#{i}")
  end

  # Browse multiple times and collect orderings
  orderings = Set.new
  20.times do
    env = mock_env('GET', '/place/v1/skillset_browse')
    _, _h, body = ext_dee.call(env, peer_id: 'agent-observer')
    result = JSON.parse(body.first, symbolize_names: true)
    names = result[:entries].map { |e| e[:name] }
    orderings.add(names.join(','))
  end

  assert('DEE: browse returns varying order over 20 calls') { orderings.size > 1 }

  # Verify no popularity/ranking fields in browse response
  env = mock_env('GET', '/place/v1/skillset_browse')
  _, _h, body = ext_dee.call(env, peer_id: 'agent-observer')
  result = JSON.parse(body.first, symbolize_names: true)
  entry = result[:entries].first
  assert('DEE: no popularity field in entry') { !entry.key?(:popularity) && !entry.key?(:downloads) }
  assert('DEE: no ranking field in entry') { !entry.key?(:rank) && !entry.key?(:score) }
  assert('DEE: sampling field present') { result[:sampling].is_a?(String) }
end

# ============================================================================
# Section 4 (4-4): Edge Cases
# ============================================================================
section('4-4. Edge Cases: disambiguation, quotas, re-deposit, force, withdraw') do
  KairosMcp.data_dir = dir_a
  manager_a = KairosMcp::SkillSetManager.new(skillsets_dir: ss_dir_a)

  # --- E1-E3: Multiple depositors, same name -> disambiguation ---
  ext_edge, _storage = create_extension

  create_knowledge_skillset(ss_dir_a, name: 'shared_skill', version: '1.0.0') unless File.directory?(File.join(ss_dir_a, 'shared_skill'))
  pkg_shared = manager_a.package('shared_skill')

  # Two agents deposit the same name
  deposit_to_ext(ext_edge, pkg_shared, name: 'shared_skill', peer_id: 'agent-x')
  deposit_to_ext(ext_edge, pkg_shared, name: 'shared_skill', peer_id: 'agent-y')

  # Browse shows both
  env = mock_env('GET', '/place/v1/skillset_browse', query: 'search=shared_skill')
  _, _h, body = ext_edge.call(env, peer_id: 'agent-z')
  browse = JSON.parse(body.first, symbolize_names: true)
  shared_entries = browse[:entries].select { |e| e[:name] == 'shared_skill' }
  assert('E1: browse shows both depositors') { shared_entries.size == 2 }
  depositors = shared_entries.map { |e| e[:depositor_id] }.sort
  assert('E1: both depositor IDs present') { depositors == ['agent-x', 'agent-y'] }

  # Content without depositor -> 409 ambiguous
  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=shared_skill')
  status, _h, body = ext_edge.call(env, peer_id: 'agent-z')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('E2: ambiguous returns 409') { status == 409 }
  assert('E2: error is ambiguous') { result[:error] == 'ambiguous' }
  assert('E2: depositors list included') { result[:depositors].is_a?(Array) && result[:depositors].size == 2 }

  # Content with depositor -> success
  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=shared_skill&depositor=agent-x')
  status, _h, body = ext_edge.call(env, peer_id: 'agent-z')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('E3: disambiguated content returns 200') { status == 200 }
  assert('E3: correct depositor returned') { result[:depositor_id] == 'agent-x' }

  # --- E4: Per-agent quota exceeded -> 422 ---
  ext_quota, _storage = create_extension(config: {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 1 },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })

  # First deposit uses shared_skill (name matches archive)
  deposit_to_ext(ext_quota, pkg_shared, name: 'shared_skill', peer_id: 'agent-limited')

  # Second deposit by same agent should fail (quota = 1)
  create_knowledge_skillset(ss_dir_a, name: 'quota_exceed', version: '1.0.0') unless File.directory?(File.join(ss_dir_a, 'quota_exceed'))
  pkg_q2 = manager_a.package('quota_exceed')
  status_q, result_q = deposit_to_ext(ext_quota, pkg_q2, name: 'quota_exceed', peer_id: 'agent-limited')
  assert('E4: per-agent quota exceeded returns 422') { status_q == 422 }
  assert('E4: error is quota_exceeded') { result_q[:error] == 'quota_exceeded' }

  # --- E5: Total archive quota exceeded -> 422 ---
  ext_total_quota, _ = create_extension(config: {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 100 },
    'place' => { 'max_total_archive_bytes' => 1 }  # 1 byte = always exceeded after first
  })
  # First deposit succeeds (total starts at 0, this archive is smaller than max_archive but quota is 1 byte)
  # Note: total quota is checked AFTER per-agent quota. The first deposit has 0 existing bytes,
  # so 0 + archive_size > 1 will actually FAIL for even the first deposit if archive > 1 byte.
  # Use a larger total quota that allows exactly one deposit.
  ext_total_quota2, _ = create_extension(config: {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 100 },
    'place' => { 'max_total_archive_bytes' => 100_000 }  # ~100KB allows one small deposit
  })
  s1, _ = deposit_to_ext(ext_total_quota2, pkg_shared, name: 'shared_skill', peer_id: 'agent-a1')
  assert('E5: first deposit under total quota succeeds') { s1 == 200 }

  # Create a large-ish SkillSet to exceed remaining quota
  create_knowledge_skillset(ss_dir_a, name: 'total_q_exceed', version: '1.0.0') unless File.directory?(File.join(ss_dir_a, 'total_q_exceed'))
  pkg_tq = manager_a.package('total_q_exceed')

  # Now set total to very small (after first deposit stored, new instance starts fresh but we reuse ext)
  # Actually, deposit already consumed space. Try depositing enough to exceed.
  # Better approach: set total_quota to size of first archive (so second will exceed)
  first_archive_size = Base64.strict_decode64(pkg_shared[:archive_base64]).bytesize
  ext_total_small, _ = create_extension(config: {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 100 },
    'place' => { 'max_total_archive_bytes' => first_archive_size + 1 }
  })
  deposit_to_ext(ext_total_small, pkg_shared, name: 'shared_skill', peer_id: 'agent-a1')
  s2, r2 = deposit_to_ext(ext_total_small, pkg_tq, name: 'total_q_exceed', peer_id: 'agent-a2')
  assert('E5: second deposit over total quota fails 422') { s2 == 422 }
  assert('E5: error is total_quota_exceeded') { r2[:error] == 'total_quota_exceeded' }

  # --- E6: Re-deposit (same agent, same name) -> replaces previous ---
  ext_redeposit, _ = create_extension

  create_knowledge_skillset(ss_dir_a, name: 'redeposit_test', version: '1.0.0',
    content: "---\nname: redeposit_test_topic\nversion: 1.0.0\n---\n# V1 content\n") unless File.directory?(File.join(ss_dir_a, 'redeposit_test'))
  pkg_v1 = manager_a.package('redeposit_test')

  deposit_to_ext(ext_redeposit, pkg_v1, name: 'redeposit_test', peer_id: 'agent-a')

  # Modify content and re-deposit
  FileUtils.rm_rf(File.join(ss_dir_a, 'redeposit_test'))
  create_knowledge_skillset(ss_dir_a, name: 'redeposit_test', version: '2.0.0',
    content: "---\nname: redeposit_test_topic\nversion: 2.0.0\n---\n# V2 content updated\n")
  pkg_v2 = manager_a.package('redeposit_test')

  status_rd, _ = deposit_to_ext(ext_redeposit, pkg_v2, name: 'redeposit_test', peer_id: 'agent-a')
  assert('E6: re-deposit succeeds') { status_rd == 200 }

  # Browse should show only 1 entry for this name from agent-a
  env = mock_env('GET', '/place/v1/skillset_browse', query: 'search=redeposit')
  _, _h, body = ext_redeposit.call(env, peer_id: 'agent-b')
  browse_rd = JSON.parse(body.first, symbolize_names: true)
  rd_entries = browse_rd[:entries].select { |e| e[:name] == 'redeposit_test' }
  assert('E6: only 1 entry after re-deposit') { rd_entries.size == 1 }

  # --- E7: Already installed SkillSet -> acquire fails -> force: true succeeds ---
  KairosMcp.data_dir = dir_b
  manager_b = KairosMcp::SkillSetManager.new(skillsets_dir: ss_dir_b)

  # First install (genomics_guide was installed in Section 1)
  # Try to acquire again without force
  ext_force, _ = create_extension
  create_knowledge_skillset(ss_dir_a, name: 'force_test', version: '1.0.0') unless File.directory?(File.join(ss_dir_a, 'force_test'))
  KairosMcp.data_dir = dir_a
  manager_a2 = KairosMcp::SkillSetManager.new(skillsets_dir: ss_dir_a)
  pkg_force = manager_a2.package('force_test')
  deposit_to_ext(ext_force, pkg_force, name: 'force_test', peer_id: 'agent-a')

  # First install by Agent B
  KairosMcp.data_dir = dir_b
  result_first = simulate_acquire(ext_force, name: 'force_test', peer_id: 'agent-b',
    manager: manager_b, verify_signature_config: false)
  assert('E7: first install succeeds') { result_first[:success] == true }

  # Second install without force -> fails
  result_dup = simulate_acquire(ext_force, name: 'force_test', peer_id: 'agent-b',
    manager: manager_b, verify_signature_config: false, force: false)
  assert('E7: duplicate install without force fails') { result_dup[:success] == false }
  assert('E7: error mentions already installed') { result_dup[:error].include?('already installed') }

  # Third install with force -> succeeds
  result_force = simulate_acquire(ext_force, name: 'force_test', peer_id: 'agent-b',
    manager: manager_b, verify_signature_config: false, force: true)
  assert('E7: force reinstall succeeds') { result_force[:success] == true }

  # --- E8-E10: Withdraw by depositor, non-depositor, non-existent ---
  ext_wd, wd_storage = create_extension
  KairosMcp.data_dir = dir_a
  create_knowledge_skillset(ss_dir_a, name: 'wd_test', version: '1.0.0') unless File.directory?(File.join(ss_dir_a, 'wd_test'))
  pkg_wd = manager_a2.package('wd_test')
  deposit_to_ext(ext_wd, pkg_wd, name: 'wd_test', peer_id: 'agent-depositor')

  # E8: Withdraw by depositor -> success
  deposit_dir = File.join(wd_storage, 'wd_test_agent-depositor')
  assert('E8 setup: deposit dir exists') { File.directory?(deposit_dir) }

  env = mock_env('POST', '/place/v1/skillset_withdraw', body: { 'name' => 'wd_test' })
  status, _h, body = ext_wd.call(env, peer_id: 'agent-depositor')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('E8: withdraw by depositor returns 200') { status == 200 }
  assert('E8: status is withdrawn') { result[:status] == 'withdrawn' }
  assert('E8: disk cleaned up') { !File.directory?(deposit_dir) }

  # E9: Withdraw by non-depositor -> 404
  deposit_to_ext(ext_wd, pkg_wd, name: 'wd_test2', peer_id: 'agent-depositor')
  env = mock_env('POST', '/place/v1/skillset_withdraw', body: { 'name' => 'wd_test2' })
  status, _h, body = ext_wd.call(env, peer_id: 'agent-other')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('E9: withdraw by non-depositor returns 404') { status == 404 }
  assert('E9: error is not_found') { result[:error] == 'not_found' }

  # E10: Withdraw non-existent -> 404
  env = mock_env('POST', '/place/v1/skillset_withdraw', body: { 'name' => 'doesnt_exist' })
  status, _h, body = ext_wd.call(env, peer_id: 'agent-anyone')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('E10: withdraw non-existent returns 404') { status == 404 }
  assert('E10: error is not_found') { result[:error] == 'not_found' }

  # --- E11: Content for non-existent -> 404 ---
  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=doesnt_exist')
  status, _h, body = ext_wd.call(env, peer_id: 'agent-anyone')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('E11: content for non-existent returns 404') { status == 404 }
  assert('E11: error is not_found') { result[:error] == 'not_found' }

  # --- E12-E14: Empty/malformed requests ---
  # Empty name on deposit
  env = mock_env('POST', '/place/v1/skillset_deposit', body: { 'name' => '' })
  status, _h, body = ext_wd.call(env, peer_id: 'agent-anyone')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('E12: empty name deposit returns 400') { status == 400 }
  assert('E12: error is invalid_name') { result[:error] == 'invalid_name' }

  # Empty body on withdraw
  env = mock_env('POST', '/place/v1/skillset_withdraw', body: {})
  status, _h, body = ext_wd.call(env, peer_id: 'agent-anyone')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('E13: empty body withdraw returns 400') { status == 400 }
  assert('E13: error is missing_name') { result[:error] == 'missing_name' }

  # Malformed JSON body
  env = mock_env('POST', '/place/v1/skillset_deposit', body: 'not json at all')
  status, _h, body = ext_wd.call(env, peer_id: 'agent-anyone')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('E14: malformed JSON returns 400') { status == 400 }
end

# ============================================================================
# Section 5 (4-5): MCP Tool Behavior Tests against local PlaceExtension
# ============================================================================
section('4-5. MCP Tool Behavior: full protocol flow via PlaceExtension') do
  KairosMcp.data_dir = dir_a
  manager_a = KairosMcp::SkillSetManager.new(skillsets_dir: ss_dir_a)

  # --- Setup: shared PlaceExtension with registry ---
  crypto_a = ::MMP::Crypto.new(auto_generate: true)
  pubkey_a = crypto_a.export_public_key
  registry = StubRegistryP4.new
  registry.keys['agent-a'] = pubkey_a

  ext_mcp, _storage = create_extension(registry: registry, config: {
    'deposit' => { 'max_archive_size_bytes' => 5_242_880, 'max_per_agent' => 10, 'require_signature' => false },
    'place' => { 'max_total_archive_bytes' => 100_000_000 }
  })

  # Agent A deposits with valid signature
  create_knowledge_skillset(ss_dir_a, name: 'mcp_flow_test', version: '1.0.0') unless File.directory?(File.join(ss_dir_a, 'mcp_flow_test'))
  pkg_mcp = manager_a.package('mcp_flow_test')
  valid_sig = crypto_a.sign(pkg_mcp[:content_hash])
  deposit_to_ext(ext_mcp, pkg_mcp, name: 'mcp_flow_test', peer_id: 'agent-a', signature: valid_sig)

  # --- M1: Browse -> find deposit ---
  env = mock_env('GET', '/place/v1/skillset_browse')
  status, _h, body = ext_mcp.call(env, peer_id: 'agent-b')
  browse = JSON.parse(body.first, symbolize_names: true)
  assert('M1: browse returns entry') { browse[:entries].any? { |e| e[:name] == 'mcp_flow_test' } }

  # --- M2: Content retrieval ---
  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=mcp_flow_test')
  status, _h, body = ext_mcp.call(env, peer_id: 'agent-b')
  content = JSON.parse(body.first, symbolize_names: true)
  assert('M2: content returns 200') { status == 200 }
  assert('M2: archive_base64 present') { !content[:archive_base64].nil? }
  assert('M2: content_hash matches') { content[:content_hash] == pkg_mcp[:content_hash] }
  assert('M2: depositor_public_key present') { content[:depositor_public_key] == pubkey_a }
  assert('M2: signature present') { content[:signature] == valid_sig }
  assert('M2: trust_notice present') { content[:trust_notice].is_a?(Hash) }

  # --- M3: Client-side content hash verification ---
  archive_data = Base64.strict_decode64(content[:archive_base64])
  Dir.mktmpdir('mcp_hash_verify') do |tmpdir|
    io = StringIO.new(archive_data)
    Zlib::GzipReader.wrap(io) do |gz|
      Gem::Package::TarReader.new(gz) do |tar|
        tar.each do |entry|
          next if entry.header.typeflag == '2' || entry.header.typeflag == '1'
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

    temp_ss = ::KairosMcp::Skillset.new(File.join(tmpdir, 'mcp_flow_test'))
    assert('M3: extracted content_hash matches declared') { temp_ss.content_hash == content[:content_hash] }
  end

  # --- M4: Client-side signature verification ---
  verify_crypto = ::MMP::Crypto.new(auto_generate: false)
  sig_valid = verify_crypto.verify_signature(content[:content_hash], content[:signature], content[:depositor_public_key])
  assert('M4: client-side signature verification passes') { sig_valid == true }

  # --- M5: Client-side signature fails on tampered content_hash ---
  assert('M5: tampered hash fails signature check') {
    !verify_crypto.verify_signature('tampered_hash', content[:signature], content[:depositor_public_key])
  }

  # --- M6: Full acquire flow (deposit -> content -> verify -> install) ---
  KairosMcp.data_dir = dir_b
  # Clean up any previous install
  prev_install = File.join(ss_dir_b, 'mcp_flow_test')
  FileUtils.rm_rf(prev_install) if File.directory?(prev_install)
  manager_b = KairosMcp::SkillSetManager.new(skillsets_dir: ss_dir_b)

  acq = simulate_acquire(ext_mcp, name: 'mcp_flow_test', peer_id: 'agent-b',
    manager: manager_b, verify_signature_config: true)
  assert('M6: full acquire with sig verification succeeds') { acq[:success] == true }
  assert('M6: signature_verified is true') { acq[:signature_verified] == true }
  assert('M6: content_hash_verified is true') { acq[:content_hash_verified] == true }

  # --- M7: Verify installed content matches ---
  installed = manager_b.find_skillset('mcp_flow_test')
  assert('M7: installed SkillSet found') { !installed.nil? }
  assert('M7: installed SkillSet is valid') { installed.valid? }
  assert('M7: installed content_hash matches') { installed.content_hash == pkg_mcp[:content_hash] }

  # --- M8: Withdraw flow ---
  env = mock_env('POST', '/place/v1/skillset_withdraw', body: { 'name' => 'mcp_flow_test', 'reason' => 'test complete' })
  status, _h, body = ext_mcp.call(env, peer_id: 'agent-a')
  result = JSON.parse(body.first, symbolize_names: true)
  assert('M8: withdraw returns 200') { status == 200 }
  assert('M8: status is withdrawn') { result[:status] == 'withdrawn' }
  assert('M8: depositor_id correct') { result[:depositor_id] == 'agent-a' }
  assert('M8: chain_recorded is true') { result[:chain_recorded] == true }

  # --- M9: Content after withdraw -> 404 ---
  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=mcp_flow_test')
  status, _h, body = ext_mcp.call(env, peer_id: 'agent-b')
  assert('M9: content after withdraw returns 404') { status == 404 }

  # --- M10: Browse after withdraw -> empty ---
  env = mock_env('GET', '/place/v1/skillset_browse', query: 'search=mcp_flow_test')
  _, _h, body = ext_mcp.call(env, peer_id: 'agent-b')
  browse_after = JSON.parse(body.first, symbolize_names: true)
  assert('M10: browse after withdraw returns 0 entries') {
    browse_after[:entries].none? { |e| e[:name] == 'mcp_flow_test' }
  }
end

# ============================================================================
# Section 6: State Persistence across Extension Instances
# ============================================================================
section('4-6. State persistence and late extension registration') do
  KairosMcp.data_dir = dir_a
  manager_a = KairosMcp::SkillSetManager.new(skillsets_dir: ss_dir_a)

  persist_storage = Dir.mktmpdir('persist_p4')
  ext1, _ = create_extension(storage_dir: persist_storage)

  create_knowledge_skillset(ss_dir_a, name: 'persist_test', version: '1.0.0') unless File.directory?(File.join(ss_dir_a, 'persist_test'))
  pkg_persist = manager_a.package('persist_test')
  deposit_to_ext(ext1, pkg_persist, name: 'persist_test', peer_id: 'agent-a')

  # Verify state file exists
  state_file = File.join(persist_storage, 'exchange_state.json')
  assert('P1: state file created after deposit') { File.exist?(state_file) }

  # Create new extension instance, reload state
  ext2, _ = create_extension(storage_dir: persist_storage)
  ext2.send(:load_state)

  # Browse should show the deposit
  env = mock_env('GET', '/place/v1/skillset_browse')
  status, _h, body = ext2.call(env, peer_id: 'agent-b')
  browse = JSON.parse(body.first, symbolize_names: true)
  assert('P2: persisted deposit visible after reload') {
    browse[:entries].any? { |e| e[:name] == 'persist_test' }
  }

  # Content should work
  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=persist_test')
  status, _h, body = ext2.call(env, peer_id: 'agent-b')
  assert('P3: content available after reload') { status == 200 }

  # Withdraw, reload, verify gone
  env = mock_env('POST', '/place/v1/skillset_withdraw', body: { 'name' => 'persist_test' })
  ext2.call(env, peer_id: 'agent-a')

  ext3, _ = create_extension(storage_dir: persist_storage)
  ext3.send(:load_state)

  env = mock_env('GET', '/place/v1/skillset_content', query: 'name=persist_test')
  status, _h, _body = ext3.call(env, peer_id: 'agent-b')
  assert('P4: withdrawn SkillSet still gone after reload') { status == 404 }

  FileUtils.rm_rf(persist_storage)
end

# ============================================================================
# Cleanup
# ============================================================================
FileUtils.rm_rf(dir_a)
FileUtils.rm_rf(dir_b)

# ============================================================================
# Summary
# ============================================================================
puts ''
puts '=' * 60
puts "FINAL RESULTS: #{$pass_count} passed, #{$fail_count} failed"
puts '=' * 60
puts ''

exit($fail_count > 0 ? 1 : 0)
