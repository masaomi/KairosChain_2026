#!/usr/bin/env ruby
# frozen_string_literal: true

# Secure MMP v1 (design log/secure_mmp_v1_design_v0.4_20261025.md, §7).
#
# Offline, against a temporary data dir. Each section names the invariant it
# checks. Usage: ruby -I lib test_secure_mmp.rb

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'
require 'stringio'
require 'openssl'
require 'digest'
require 'base64'

$pass = 0
$fail = 0

def assert(msg)
  ok = yield
  puts "  #{ok ? 'PASS' : 'FAIL'}: #{msg}"
  ok ? $pass += 1 : $fail += 1
rescue StandardError => e
  puts "  FAIL: #{msg} (#{e.class}: #{e.message})"
  puts e.backtrace.first(3).map { |l| "      #{l}" }.join("\n")
  $fail += 1
end

def section(title)
  puts ''
  puts "== #{title}"
  yield
rescue StandardError => e
  puts "  SECTION ERROR: #{e.class}: #{e.message}"
  puts e.backtrace.first(5).join("\n")
  $fail += 1
end

TEMPLATES = File.expand_path('templates/skillsets', __dir__)
DATA = Dir.mktmpdir('kairos_secure_mmp')
at_exit { FileUtils.rm_rf(DATA) }

# --- setup: a receiver instance with mmp and secure_mmp installed ---------
%w[skills knowledge context storage config skillsets].each { |d| FileUtils.mkdir_p(File.join(DATA, d)) }
File.write(File.join(DATA, 'skills', 'config.yml'), { 'skill_tools_enabled' => false }.to_yaml)
File.write(File.join(DATA, 'skills', 'kairos.rb'), "# test\n")
%w[mmp secure_mmp].each { |n| FileUtils.cp_r(File.join(TEMPLATES, n), File.join(DATA, 'skillsets', n)) }
meeting_yml = File.join(DATA, 'skillsets', 'mmp', 'config', 'meeting.yml')
cfg = YAML.load_file(meeting_yml)
cfg['enabled'] = true
cfg['identity']['name'] = 'Receiver'
File.write(meeting_yml, cfg.to_yaml)

def write_l1(name, frontmatter, body)
  dir = File.join(DATA, 'knowledge', name)
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "#{name}.md"), "#{frontmatter.to_yaml}---\n\n#{body}\n")
end
write_l1('open_note', { 'name' => 'open_note', 'description' => 'public entry', 'public' => true }, 'Public body.')
write_l1('private_note', { 'name' => 'private_note', 'description' => 'private entry', 'public' => false },
         '非公開の本文。SECRET-MARKER-42')

KairosMcp.data_dir = DATA
$LOAD_PATH.unshift File.join(DATA, 'skillsets', 'mmp', 'lib')
$LOAD_PATH.unshift File.join(DATA, 'skillsets', 'secure_mmp', 'lib')
require 'mmp'
require 'mmp/meeting_session_store'
require 'kairos_mcp/meeting_router'
require 'kairos_mcp/admission_records'
require 'kairos_mcp/admission_commands'
require 'secure_mmp'

# The receiver's own keypair (Identity creates it on first use).
receiver_identity = MMP::Identity.new(workspace_root: DATA, config: MMP.load_config)
receiver_identity.introduce
RECEIVER_KEY = KairosMcp::AdmissionRecords.load_private_key(DATA)

ORIGIN = 'http://127.0.0.1:8080'

def mock_env(method, path, body: nil, raw: nil, token: nil, addr: '100.64.0.9')
  data = raw || (body ? JSON.generate(body) : '')
  env = { 'REQUEST_METHOD' => method, 'PATH_INFO' => path, 'QUERY_STRING' => '',
          'CONTENT_TYPE' => 'application/json', 'REMOTE_ADDR' => addr,
          'CONTENT_LENGTH' => data.bytesize.to_s, 'rack.input' => StringIO.new(data) }
  env['HTTP_AUTHORIZATION'] = "Bearer #{token}" if token
  env
end

def call(router, env)
  status, _h, body = router.call(env)
  [status, (JSON.parse(body.first) rescue body.first)]
end

def key_sha(key) = Digest::SHA256.hexdigest(key.public_key.public_to_der)

# A peer that signs its own introduce and direct proof.
def peer_intro(key, name:, instance_id:, audience: ORIGIN, issued_at: Time.now.utc,
               protocol: MMP::RegistrationProof::DIRECT_PROTOCOL, nonce: SecureRandom.hex(16))
  identity = { 'name' => name, 'description' => 'peer', 'scope' => 'general', 'version' => '1.3.0',
               'instance_id' => instance_id }
  sig = Base64.strict_encode64(key.sign(OpenSSL::Digest.new('SHA256'), JSON.generate(identity, sort_keys: true)))
  proof = MMP::RegistrationProof.build(audience: audience, agent_id: instance_id, issued_at: issued_at, nonce: nonce)
  {
    'identity' => identity, 'identity_signature' => sig, 'public_key' => key.public_key.to_pem,
    'direct_proof' => proof,
    'direct_proof_signature' => MMP::RegistrationProof.sign(key, proof, protocol: protocol)
  }
end

PEER = OpenSSL::PKey::RSA.new(2048)
PEER2 = OpenSSL::PKey::RSA.new(2048)
STRANGER = OpenSSL::PKey::RSA.new(2048)

# Records handlers receive, to check what the router hands them.
$seen = []
MMP::Protocol.register_handler('ext:test:echo') { |msg, _p| $seen << msg; { status: 'ok' } }

def pinned_router(started_at: Time.now.utc - 120)
  KairosMcp::MeetingRouter.new(admission: { policy: 'pinned', origins: [ORIGIN], started_at: started_at })
end

def reset_records!
  KairosMcp::AdmissionRecords.reset_instances!
end

# ==========================================================================
section('I1 — disclosure') do
  router = KairosMcp::MeetingRouter.new
  status, card = call(router, mock_env('GET', '/meeting/v1/introduce'))
  raw = JSON.generate(card)
  assert('card answers 200') { status == 200 }
  assert('card lists the public entry') { card['skills'].any? { |s| s['name'] == 'open_note' } }
  assert('card omits the private entry') { card['skills'].none? { |s| s['name'] == 'private_note' } }
  assert('no skill carries a path') { card['skills'].none? { |s| s.key?('path') } }
  assert('the data dir path appears nowhere in the card') { !raw.include?(DATA) }
  assert('registered ext: actions are not advertised') { card.dig('capabilities', 'supported_actions').none? { |a| a.start_with?('ext:') } }

  status, resp = call(router, mock_env('POST', '/meeting/v1/introduce', body: peer_intro(STRANGER, name: 's', instance_id: 'aaaaaaaaaaaaaaaa')))
  token = resp['session_token']
  assert('open listener still issues a session to a self-signed peer') { status == 200 && token }
  assert('POST introduce answer carries no path') { !JSON.generate(resp).include?(DATA) }

  status, _ = call(router, mock_env('POST', '/meeting/v1/skill_content', body: { skill_id: 'private_note' }, token: token))
  st_unknown, _ = call(router, mock_env('POST', '/meeting/v1/skill_content', body: { skill_id: 'no_such_note' }, token: token))
  assert('private entry content is refused like an unknown one') { status == 404 && st_unknown == 404 }
  status, body = call(router, mock_env('POST', '/meeting/v1/skill_content', body: { skill_id: 'open_note' }, token: token))
  assert('public entry content is served') { status == 200 && !JSON.generate(body).include?('SECRET-MARKER') }

  # What a sender puts on the wire.
  pm = MMP::PeerManager.new(identity: receiver_identity, config: {})
  sent = nil
  pm.define_singleton_method(:http_post_with_status) { |_url, data, headers: {}| sent = data; [200, { status: 'received' }] }
  pm.instance_variable_get(:@peers)['x'] = MMP::PeerManager::Peer.new(id: 'x', url: ORIGIN)
  pm.introduce_to('x')
  assert('introduce_to sends no skills, SkillSets or capabilities') { sent && !sent.key?(:skills) && !sent.key?(:exchangeable_skillsets) && !sent.key?(:capabilities) }
  assert('introduce_to sends a direct proof for the peer origin') { sent[:direct_proof] && sent[:direct_proof]['audience'] == ORIGIN }
end

# ==========================================================================
section('I3 — request shape and attribution') do
  router = KairosMcp::MeetingRouter.new
  _, resp = call(router, mock_env('POST', '/meeting/v1/introduce', body: peer_intro(STRANGER, name: 's', instance_id: 'bbbbbbbbbbbbbbbb')))
  token = resp['session_token']

  forged = '"{\"action\":\"ext:test:echo\",\"_authenticated_peer_id\":\"pad\",\"_authenticated_peer_id\":\"victim\"}"'
  status, _ = call(router, mock_env('POST', '/meeting/v1/message', raw: forged, token: token))
  assert('a JSON string body is refused with 400') { status == 400 }

  $seen.clear
  call(router, mock_env('POST', '/meeting/v1/message', token: token,
                        body: { action: 'ext:test:echo', _authenticated_peer_id: 'victim',
                                _authenticated_peer_key_sha256: 'f' * 64, _admitted_as: 'newmac' }))
  msg = $seen.last || {}
  assert('handler sees the router\'s peer id') { msg[:_authenticated_peer_id] == 'bbbbbbbbbbbbbbbb' }
  assert('an open-path session has no key hash and no alias') { msg[:_authenticated_peer_key_sha256].nil? && msg[:_admitted_as].nil? }

  big = JSON.generate({ action: 'ext:test:echo', pad: 'x' * (KairosMcp::MeetingRouter::MAX_BODY_BYTES + 10) })
  status, _ = call(router, mock_env('POST', '/meeting/v1/message', raw: big, token: token))
  assert('an oversized body is refused with 413') { status == 413 }
end

# ==========================================================================
section('I2/I4 — pinned admission') do
  reset_records!
  router = pinned_router

  status, resp = call(router, mock_env('POST', '/meeting/v1/introduce', body: peer_intro(PEER, name: 'oldmac', instance_id: 'cccccccccccccccc')))
  assert('unpinned key is refused') { status == 403 && resp['error'] == 'admission_refused' }
  assert('the refusal echoes the presented key hash') { resp['key_sha256'] == key_sha(PEER) }
  assert('the refusal left one knock') { SecureMmp::Knocks.list.any? { |k| k['key_sha256'] == key_sha(PEER) } }

  r = KairosMcp::AdmissionCommands.pin_add('oldmac', key_sha(PEER), url: 'HTTP://127.0.0.1:8080/')
  assert('pin add records seq 1 with a normalized url') { r[:recorded] && r[:record]['seq'] == 1 && r[:record]['url'] == ORIGIN }

  status, resp = call(router, mock_env('POST', '/meeting/v1/introduce', body: peer_intro(PEER, name: 'oldmac', instance_id: 'cccccccccccccccc')))
  token = resp['session_token']
  assert('pinned key gets a session') { status == 200 && token }
  assert('the session is issued by mmp.direct with the DER key hash') {
    rec = router.session_store.session_record(token)
    rec[:issuer] == 'mmp.direct' && rec[:key_sha256] == key_sha(PEER)
  }

  $seen.clear
  call(router, mock_env('POST', '/meeting/v1/message', token: token, body: { action: 'ext:test:echo', _admitted_as: 'forged' }))
  msg = $seen.last || {}
  assert('handler sees the alias and key hash from the router') { msg[:_admitted_as] == 'oldmac' && msg[:_authenticated_peer_key_sha256] == key_sha(PEER) }

  proof_body = peer_intro(PEER, name: 'oldmac', instance_id: 'cccccccccccccccc')
  call(router, mock_env('POST', '/meeting/v1/introduce', body: proof_body))
  status, resp = call(router, mock_env('POST', '/meeting/v1/introduce', body: proof_body))
  assert('a replayed proof is refused') { status == 403 && resp['error'] == 'proof_invalid' }

  status, resp = call(router, mock_env('POST', '/meeting/v1/introduce',
                                       body: peer_intro(PEER, name: 'oldmac', instance_id: 'cccccccccccccccc', issued_at: Time.now.utc + 31)))
  assert('a proof dated 31 s ahead is stale') { status == 403 && resp['error'] == 'proof_stale' && resp['earliest_acceptable_at'] }

  status, resp = call(router, mock_env('POST', '/meeting/v1/introduce',
                                       body: peer_intro(PEER, name: 'oldmac', instance_id: 'cccccccccccccccc', audience: 'http://127.0.0.1:9999')))
  assert('a proof for another origin is refused') { status == 403 && resp['error'] == 'proof_wrong_audience' && resp['expected_audience'] == ORIGIN }

  status, resp = call(router, mock_env('POST', '/meeting/v1/introduce',
                                       body: peer_intro(PEER, name: 'oldmac', instance_id: 'cccccccccccccccc', protocol: MMP::RegistrationProof::PROTOCOL)))
  assert('a Place registration proof does not pass as a direct proof') { status == 403 && resp['error'] == 'proof_invalid' }

  body = peer_intro(PEER, name: 'oldmac', instance_id: 'cccccccccccccccc')
  body['identity']['instance_id'] = 'dddddddddddddddd'
  status, _ = call(router, mock_env('POST', '/meeting/v1/introduce', body: body))
  assert('a proof for another instance id is refused') { status == 403 }

  fresh = pinned_router(started_at: Time.now.utc)
  status, resp = call(fresh, mock_env('POST', '/meeting/v1/introduce', body: peer_intro(PEER, name: 'oldmac', instance_id: 'cccccccccccccccc')))
  assert('a proof issued within 30 s of listener start is stale (restart rule)') { status == 403 && resp['error'] == 'proof_stale' }

  place_token = router.session_store.create_session('placeagent', PEER.public_key.to_pem, issuer: 'hestia.place')
  status, _ = call(router, mock_env('POST', '/meeting/v1/message', token: place_token, body: { action: 'ext:test:echo' }))
  assert('a Place-issued token is refused with 401') { status == 401 }
  assert('… and not revoked') { router.session_store.validate(place_token) == 'placeagent' }

  # Revocation applies to the live session.
  KairosMcp::AdmissionCommands.pin_revoke('oldmac')
  status, resp = call(router, mock_env('POST', '/meeting/v1/message', token: token, body: { action: 'ext:test:echo' }))
  assert('after revoke the live session is refused') { status == 403 && resp['error'] == 'admission_revoked' }
  status, _ = call(router, mock_env('POST', '/meeting/v1/message', token: token, body: { action: 'ext:test:echo' }))
  assert('… and the token is dead') { status == 401 }

  # Replaying the signed add record through an unauthenticated append.
  records = KairosMcp::AdmissionRecords.for_data_dir
  chain = KairosMcp::KairosChain::Chain.new
  add_entry = chain.chain.flat_map(&:data).find { |e| e.include?('"action":"add"') && e.include?(key_sha(PEER)) }
  chain.add_block([add_entry])
  assert('a re-appended copy of the signed add admits nothing') { records.admitted_alias(key_sha(PEER)).nil? }
  forged = { 'type' => KairosMcp::AdmissionRecords::PIN, 'seq' => records.state.heads[KairosMcp::AdmissionRecords::PIN][:seq] + 1,
             'prev' => records.state.heads[KairosMcp::AdmissionRecords::PIN][:prev], 'signed_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
             'action' => 'add', 'alias' => 'evil', 'key_sha256' => key_sha(STRANGER), 'url' => ORIGIN, 'replaces' => nil }
  forged['signature'] = KairosMcp::AdmissionRecords.sign(STRANGER, KairosMcp::AdmissionRecords::PIN, forged)
  KairosMcp::KairosChain::Chain.new.add_block([JSON.generate(forged)])
  assert('a pin record signed by another key admits nothing') { records.admitted_alias(key_sha(STRANGER)).nil? }
  assert('… and is listed as ignored') { records.state.ignored.any? { |i| i['reason'] == 'signature' } }

  # Re-pinning an alias displaces the old key.
  KairosMcp::AdmissionCommands.pin_add('oldmac', key_sha(PEER), url: ORIGIN)
  r = KairosMcp::AdmissionCommands.pin_add('oldmac', key_sha(PEER2), url: ORIGIN)
  assert('re-pinning names the replaced key') { r[:replaces] == key_sha(PEER) }
  assert('the old key is no longer admitted') { records.admitted_alias(key_sha(PEER)).nil? }
  assert('the new key is admitted') { records.admitted_alias(key_sha(PEER2)) == 'oldmac' }

  # An MCP caller cannot widen.
  require 'kairos_mcp/tools/base_tool'
  require File.join(DATA, 'skillsets', 'secure_mmp', 'tools', 'peer_pin.rb')
  tool = KairosMcp::SkillSets::SecureMmp::Tools::PeerPin.new
  assert('peer_pin offers no add command') { !tool.input_schema.dig(:properties, :command, :enum).include?('add') }
  out = JSON.parse(tool.call({ 'command' => 'add', 'target' => key_sha(STRANGER) }).first[:text])
  assert('peer_pin add is an unknown command') { out['status'] == 'error' }
end

# ==========================================================================
section('I2 — fail closed') do
  reset_records!
  router = pinned_router
  _, resp = call(router, mock_env('POST', '/meeting/v1/introduce', body: peer_intro(PEER2, name: 'oldmac', instance_id: 'eeeeeeeeeeeeeeee')))
  token = resp['session_token']
  assert('setup: pinned PEER2 has a session') { token }

  ledger = KairosMcp.blockchain_path
  saved = File.binread(ledger)
  File.binwrite(ledger, '{ not json')
  reset_records!
  status, resp = call(router, mock_env('POST', '/meeting/v1/message', token: token, body: { action: 'ext:test:echo' }))
  assert('an unreadable ledger refuses the request') { status == 403 && resp['error'] == 'admission_refused' }
  File.binwrite(ledger, saved)
  reset_records!
  status, _ = call(router, mock_env('POST', '/meeting/v1/message', token: token, body: { action: 'ext:test:echo' }))
  assert('… without revoking the live session') { status == 200 }

  MMP::Admission.unregister('pinned')
  status, resp = call(router, mock_env('POST', '/meeting/v1/introduce', body: peer_intro(PEER2, name: 'oldmac', instance_id: 'eeeeeeeeeeeeeeee')))
  assert('no registered decider admits nothing') { status == 403 && resp['error'] == 'admission_refused' }
  SecureMmp.register!

  # Rollback while the process runs.
  records = KairosMcp::AdmissionRecords.for_data_dir
  records.state
  blocks = JSON.parse(File.read(ledger))
  KairosMcp::AdmissionCommands.pin_revoke('oldmac')
  File.write(ledger, JSON.pretty_generate(blocks))
  assert('a ledger rolled back past a folded record resolves closed') { records.state.status == :rolled_back }
  assert('… and admits nothing') { records.admitted_alias(key_sha(PEER2)).nil? }
  reset_records!
end

# ==========================================================================
section('I4 — knocks are bounded') do
  FileUtils.rm_f(SecureMmp::Knocks.path)
  21.times do |i|
    SecureMmp::Knocks.record({ key_sha256: format('%064x', i + 1), remote_addr: "100.64.1.#{i}",
                               instance_id: 'ffffffffffffffff', claimed_name: 'x' })
  end
  assert('21 knocks keep the newest 20') { SecureMmp::Knocks.list.size == 20 }
  SecureMmp::Knocks.record({ key_sha256: 'a' * 64, remote_addr: '100.64.2.1', instance_id: "bad\nid",
                             claimed_name: "#{"‮" * 3}#{'n' * 10_000}" })
  k = SecureMmp::Knocks.list.first
  assert('claimed_name is cut to 64 printable ASCII characters') { k['claimed_name'].size == 64 && k['claimed_name'].match?(/\A[ -~]*\z/) }
  assert('an instance id of the wrong shape is dropped') { k['instance_id'].nil? }
  assert('a second knock from the same address within a minute is not written') {
    !SecureMmp::Knocks.record({ key_sha256: 'b' * 64, remote_addr: '100.64.2.1' })
  }
end

# ==========================================================================
section('I1/I4 — publication') do
  reset_records!
  pack = File.join(DATA, 'skillsets', 'notes_pack')
  FileUtils.mkdir_p(File.join(pack, 'knowledge', 'n'))
  File.write(File.join(pack, 'skillset.json'), JSON.generate({ name: 'notes_pack', version: '1.0.0', layer: 'L2',
                                                                 description: 'k', knowledge_dirs: ['knowledge/n'] }))
  File.write(File.join(pack, 'knowledge', 'n', 'n.md'), "---\nname: n\n---\nbody\n")
  records = KairosMcp::AdmissionRecords.for_data_dir
  require 'kairos_mcp/skillset_manager'
  ss = KairosMcp::SkillSetManager.new.find_skillset('notes_pack')
  assert('an exchangeable SkillSet is unpublished by default') { !records.published?('notes_pack', ss.content_hash) }
  KairosMcp::AdmissionCommands.publish('notes_pack')
  assert('publish makes it served at this content') { records.published?('notes_pack', ss.content_hash) }
  File.write(File.join(pack, 'knowledge', 'n', 'n.md'), "---\nname: n\n---\nchanged\n")
  ss2 = KairosMcp::SkillSetManager.new.find_skillset('notes_pack')
  assert('changing its content unpublishes it') { !records.published?('notes_pack', ss2.content_hash) }
  assert('the card does not list it after the change') {
    MMP::Identity.new(workspace_root: DATA, config: MMP.load_config).introduce[:exchangeable_skillsets].none? { |s| s[:name] == 'notes_pack' }
  }
end

# ==========================================================================
section('I5 — meeting-only listener') do
  require 'kairos_mcp/http_server'
  server = KairosMcp::HttpServer.new(host: '127.0.0.1', port: 8080, meeting_only: true, admission: 'pinned')
  app = server.build_rack_app
  get = ->(path, method = 'GET') { app.call(mock_env(method, path)).first }
  assert('/mcp is not served') { get.call('/mcp', 'POST') == 404 }
  assert('/admin is not served') { get.call('/admin') == 404 }
  assert('/place/v1/info is not served') { get.call('/place/v1/info') == 404 }
  assert('/health is served') { get.call('/health') == 200 }
  assert('/meeting/v1/introduce is served') { get.call('/meeting/v1/introduce') == 200 }
  assert('own origin is derived from the bind') { server.admission_config[:origins] == [ORIGIN] }

  exits = lambda do |**kw|
    s = KairosMcp::HttpServer.new(**kw)
    begin
      s.send(:check_meeting_only!)
      s.send(:check_admission!)
      false
    rescue SystemExit
      true
    end
  end
  assert('non-loopback meeting-only without --admission refuses to start') { exits.call(host: '100.64.0.1', meeting_only: true) }
  assert('… with --admission open it starts') { !exits.call(host: '100.64.0.1', meeting_only: true, admission: 'open') }
  assert('pinned on a wildcard bind without --origin refuses to start') { exits.call(host: '0.0.0.0', meeting_only: true, admission: 'pinned') }
  assert('… with --origin it starts') { !exits.call(host: '0.0.0.0', meeting_only: true, admission: 'pinned', origins: [ORIGIN]) }
end

# ==========================================================================
section('impl R1 fixes') do
  reset_records!
  router = KairosMcp::MeetingRouter.new

  # mmp older than 1.3.0 under this core: 503, never the old card.
  saved_version = MMP::VERSION
  MMP.send(:remove_const, :VERSION)
  MMP.const_set(:VERSION, '1.2.0')
  status, body = call(router, mock_env('GET', '/meeting/v1/introduce'))
  MMP.send(:remove_const, :VERSION)
  MMP.const_set(:VERSION, saved_version)
  assert('an mmp older than 1.3.0 answers 503 mmp_upgrade_required') { status == 503 && body['error'] == 'mmp_upgrade_required' }

  # Publicity is per entry: sub-documents inherit the main file's decision.
  cfg2 = YAML.load_file(meeting_yml)
  cfg2['skill_exchange']['public_by_default'] = true
  File.write(meeting_yml, cfg2.to_yaml)
  FileUtils.mkdir_p(File.join(DATA, 'knowledge', 'private_note', 'references'))
  File.write(File.join(DATA, 'knowledge', 'private_note', 'references', 'detail.md'), "# detail\nSUB-SECRET-77\n")
  FileUtils.mkdir_p(File.join(DATA, 'knowledge', 'open_note', 'references'))
  File.write(File.join(DATA, 'knowledge', 'open_note', 'references', 'extra.md'), "# extra\nfine\n")
  r2 = KairosMcp::MeetingRouter.new
  _, card = call(r2, mock_env('GET', '/meeting/v1/introduce'))
  names = card['skills'].map { |x| x['name'] }
  assert('a sub-document of a private entry stays private under public_by_default') { !names.include?('detail') }
  assert('a sub-document of a public entry is public') { names.include?('extra') }
  # A sub-document's own public: false narrows its public entry.
  File.write(File.join(DATA, 'knowledge', 'open_note', 'references', 'draft.md'), "---\npublic: false\n---\nDRAFT-MARKER\n")
  # A main file whose front matter does not parse makes its entry private.
  FileUtils.mkdir_p(File.join(DATA, 'knowledge', 'broken_note'))
  File.write(File.join(DATA, 'knowledge', 'broken_note', 'broken_note.md'), "---\npublic: false\nbad: : :\n---\nBROKEN\n")
  _, card3 = call(KairosMcp::MeetingRouter.new, mock_env('GET', '/meeting/v1/introduce'))
  names3 = card3['skills'].map { |x| x['name'] }
  assert('a sub-document marked public: false stays private inside a public entry') { !names3.include?('draft') }
  assert('an entry whose main front matter does not parse is private under public_by_default') { !names3.include?('broken_note') }

  # Front matter that is opened but cannot be read makes the file private, as
  # sub-document or main file; a public: that is not true narrows.
  refs = File.join(DATA, 'knowledge', 'open_note', 'references')
  {
    'sub_date' => "---\npublic: false\nupdated: 2026-10-25\n---\nSUB-DATE\n",
    'sub_yaml' => "---\npublic: false\nbad: : :\n---\nSUB-YAML\n",
    'sub_unclosed' => "---\npublic: false\nSUB-UNCLOSED\n",
    'sub_bom' => "\uFEFF---\npublic: false\n---\nSUB-BOM\n",
    'sub_blank' => "\n---\npublic: false\n---\nSUB-BLANK\n",
    'sub_str' => "---\npublic: \"false\"\n---\nSUB-STR\n",
    'sub_empty' => "---\npublic:\n---\nSUB-EMPTY\n",
    'sub_list' => "---\n- a\n---\nSUB-LIST\n",
    'sub_nl_bom' => "\n\uFEFF---\npublic: false\n---\nSUB-NL-BOM\n",
    'sub_two_boms' => "\uFEFF\uFEFF---\npublic: false\n---\nSUB-TWO-BOMS\n",
    'sub_nbsp' => "\u00A0---\npublic: false\n---\nSUB-NBSP\n",
    'sub_zwsp' => "\u200B---\npublic: false\n---\nSUB-ZWSP\n",
    'sub_nul' => "\u0000---\npublic: false\n---\nSUB-NUL\n",
    'sub_hangul_filler' => "\u3164---\npublic: false\n---\nSUB-HF\n",
    'sub_braille_blank' => "\u2800---\npublic: false\n---\nSUB-BB\n",
    'sub_cgj' => "\u034F---\npublic: false\n---\nSUB-CGJ\n",
    'sub_vs16' => "\uFE0F---\npublic: false\n---\nSUB-VS16\n"
  }.each { |n, text| File.write(File.join(refs, "#{n}.md"), text) }
  File.write(File.join(refs, 'sub_true.md'), "---\npublic: true\n---\nSUB-TRUE\n")
  File.write(File.join(refs, 'sub_japanese.md'), "日本語の本文\nfine\n")
  FileUtils.mkdir_p(File.join(DATA, 'knowledge', 'bom_private'))
  File.write(File.join(DATA, 'knowledge', 'bom_private', 'bom_private.md'), "\uFEFF\uFEFF---\npublic: false\n---\nBOM-PRIV\n")
  FileUtils.mkdir_p(File.join(DATA, 'knowledge', 'bom_public'))
  File.write(File.join(DATA, 'knowledge', 'bom_public', 'bom_public.md'), "\uFEFF---\npublic: true\n---\nBOM-PUB\n")
  _, card4 = call(KairosMcp::MeetingRouter.new, mock_env('GET', '/meeting/v1/introduce'))
  names4 = card4['skills'].map { |x| x['name'] }
  %w[sub_date sub_yaml sub_unclosed sub_bom sub_blank sub_str sub_empty sub_list
     sub_nl_bom sub_two_boms sub_nbsp sub_zwsp sub_nul sub_hangul_filler sub_braille_blank sub_cgj sub_vs16].each do |n|
    assert("a sub-document #{n} of a public entry is private") { !names4.include?(n) }
  end
  assert('a sub-document with public: true in a public entry stays public') { names4.include?('sub_true') }
  assert('a sub-document that starts with Japanese text and has no front matter stays public') { names4.include?('sub_japanese') }
  assert('a BOM-led main file with public: false is private under public_by_default') { !names4.include?('bom_private') }
  assert('a BOM-led main file with public: true is read as public') { names4.include?('bom_public') }
  cfg2['skill_exchange']['public_by_default'] = false
  File.write(meeting_yml, cfg2.to_yaml)

  # The unhandled-action reply lists only advertised actions.
  _, resp = call(router, mock_env('POST', '/meeting/v1/introduce', body: peer_intro(STRANGER, name: 's', instance_id: '1111111111111111')))
  tok = resp['session_token']
  _, reply = call(router, mock_env('POST', '/meeting/v1/message', token: tok, body: { action: 'list_skillsets' }))
  assert('an unhandled action does not list registered ext: actions') {
    reply['status'] == 'action_not_supported' && Array(reply['available_actions']).none? { |a| a.start_with?('ext:') }
  }

  # goodbye under a policy ends only sessions this router issued.
  pr = pinned_router
  place_token = pr.session_store.create_session('placeagent', PEER.public_key.to_pem, issuer: 'hestia.place')
  env = mock_env('POST', '/meeting/v1/goodbye')
  env['HTTP_AUTHORIZATION'] = "Bearer #{place_token}"
  status, _ = call(pr, env)
  assert('goodbye with a Place token is refused under a policy') { status == 401 }
  assert('… and the Place session survives') { pr.session_store.validate(place_token) == 'placeagent' }

  # A pinned listener never mints a key for this instance.
  key_path = File.join(DATA, 'keys', 'mmp_keypair.pem')
  File.rename(key_path, "#{key_path}.aside")
  begin
    call(pinned_router, mock_env('GET', '/meeting/v1/introduce'))
    assert('GET introduce on a pinned listener creates no key') { !File.exist?(key_path) }
  ensure
    FileUtils.rm_f(key_path)
    File.rename("#{key_path}.aside", key_path)
  end

  # A missing key is not latched: once it appears, the pinned listener's card carries it.
  File.rename(key_path, "#{key_path}.aside2")
  pr_latch = pinned_router
  _, card_nokey = call(pr_latch, mock_env('GET', '/meeting/v1/introduce'))
  File.rename("#{key_path}.aside2", key_path)
  _, card_key = call(pr_latch, mock_env('GET', '/meeting/v1/introduce'))
  assert('without a key the card has no public key') { card_nokey['public_key'].nil? }
  assert('… and once the key exists the same listener presents it') { card_key['public_key'].to_s.include?('BEGIN PUBLIC KEY') }

  # A key file that vanishes between the check and the load is not replaced
  # by an identity that may not create keys, and the Place id is kept.
  place_id_path = File.join(DATA, 'keys', MMP::Identity::PLACE_ID_FILE)
  place_id_before = File.exist?(place_id_path) ? File.read(place_id_path) : nil
  orig_new = MMP::Crypto.method(:new)
  MMP::Crypto.define_singleton_method(:new) do |**kw|
    File.rename(key_path, "#{key_path}.aside3") if File.exist?(key_path)
    orig_new.call(**kw)
  end
  begin
    no_mint = MMP::Identity.new(workspace_root: DATA, config: MMP.load_config, auto_generate_key: false)
    no_mint.send(:crypto_available?)
    assert('a key that vanishes mid-load is not minted when the identity may not create keys') { !File.exist?(key_path) }
    assert('… and the Place id is left as it was') { (File.exist?(place_id_path) ? File.read(place_id_path) : nil) == place_id_before }
  ensure
    MMP::Crypto.singleton_class.send(:remove_method, :new)
    FileUtils.rm_f(key_path)
    File.rename("#{key_path}.aside3", key_path) if File.exist?("#{key_path}.aside3")
  end

  # One DirectSession per router, even when first reached from two threads.
  pr2 = pinned_router
  sessions = 2.times.map { Thread.new { pr2.send(:direct_session) } }.map(&:value)
  assert('concurrent first use builds one DirectSession') { sessions.uniq.size == 1 }

  # Concurrent writers: success is reported exactly for records that count.
  reset_records!
  keys = 4.times.map { OpenSSL::PKey::RSA.new(2048) }
  results = keys.each_with_index.map do |k, i|
    Thread.new do
      KairosMcp::AdmissionCommands.pin_add("peer#{i}", key_sha(k), url: ORIGIN)
      :ok
    rescue KairosMcp::AdmissionRecords::Error
      :rerun
    end
  end.map(&:value)
  recs = KairosMcp::AdmissionRecords.for_data_dir
  recs.refresh!
  consistent = keys.each_with_index.all? do |k, i|
    admitted = !recs.admitted_alias(key_sha(k)).nil?
    results[i] == :ok ? admitted : !admitted
  end
  assert("concurrent pin_add reports success exactly for admitted keys (#{results.inspect})") { consistent }

  # A writer whose record lost the race is told so, deterministically.
  writer = KairosMcp::AdmissionRecords.new(data_dir: DATA)
  stale = writer.refresh!
  KairosMcp::AdmissionRecords.new(data_dir: DATA).append(
    KairosMcp::AdmissionRecords::PIN,
    { 'action' => 'add', 'alias' => 'racer1', 'key_sha256' => key_sha(OpenSSL::PKey::RSA.new(2048)), 'url' => ORIGIN, 'replaces' => nil },
    private_key: RECEIVER_KEY
  )
  calls = 0
  writer.define_singleton_method(:refresh!) do
    calls += 1
    calls == 1 ? stale : super()
  end
  lost = begin
    writer.append(KairosMcp::AdmissionRecords::PIN,
                  { 'action' => 'add', 'alias' => 'racer2', 'key_sha256' => key_sha(OpenSSL::PKey::RSA.new(2048)), 'url' => ORIGIN, 'replaces' => nil },
                  private_key: RECEIVER_KEY)
    :ok
  rescue KairosMcp::AdmissionRecords::Error
    :rerun
  end
  assert('a record appended on a stale head is reported as not recorded') { lost == :rerun }
  assert('… and indeed does not count') { KairosMcp::AdmissionRecords.new(data_dir: DATA).pin_for_alias('racer2').nil? }

  # The stale retry still happens right after a restart.
  pm = MMP::PeerManager.new(identity: receiver_identity, config: {})
  now = Time.now.utc
  wait = pm.send(:stale_wait_seconds, { server_time: now.iso8601, earliest_acceptable_at: (now + 30).iso8601 })
  assert('a stale answer 30 s before acceptance still yields one retry') { wait && wait <= 32 }

  # The listener's own origin is normalized like the origin senders dial.
  srv = KairosMcp::HttpServer.new(host: 'MyMac.Example', port: 8080, meeting_only: true, admission: 'pinned')
  assert('own origin is lowercased and normalized') { srv.admission_config[:origins] == ['http://mymac.example:8080'] }
  srv80 = KairosMcp::HttpServer.new(host: '127.0.0.1', port: 80, meeting_only: true, admission: 'pinned')
  assert('the default port is dropped from the origin') { srv80.admission_config[:origins] == ['http://127.0.0.1'] }

  # Publication is re-checked against what was packaged.
  reset_records!
  KairosMcp::AdmissionCommands.publish('notes_pack') rescue nil
  _, resp = call(router, mock_env('POST', '/meeting/v1/introduce', body: peer_intro(STRANGER, name: 's', instance_id: '2222222222222222')))
  tok = resp['session_token']
  status, _ = call(router, mock_env('POST', '/meeting/v1/skillset_content', token: tok, body: { name: 'notes_pack' }))
  assert('setup: the published pack is served') { status == 200 }
  KairosMcp::SkillSetManager.prepend(Module.new do
    def package(name)
      super.merge(content_hash: 'f' * 64)
    end
  end)
  status, _ = call(router, mock_env('POST', '/meeting/v1/skillset_content', token: tok, body: { name: 'notes_pack' }))
  assert('content that changed by packaging time is not served') { status == 404 }
end

# ==========================================================================
section('impl R1 fixes — separate processes') do
  lib = File.expand_path('lib', __dir__)
  bin = File.expand_path('bin/kairos-chain', __dir__)
  out = `ruby -I #{lib} #{bin} --meeting-only --data-dir #{DATA} 2>&1 < /dev/null`
  assert('listener flags without --http are refused') { $?.exitstatus == 1 && out.include?('apply only with --http') }

  # The card lists a published SkillSet even when nothing else loaded the record reader first.
  script = <<~RUBY
    require 'kairos_mcp'; require 'yaml'; KairosMcp.data_dir = ARGV[0]
    $LOAD_PATH.unshift File.join(ARGV[0], 'skillsets', 'mmp', 'lib'); require 'mmp'
    intro = MMP::Identity.new(workspace_root: ARGV[0], config: MMP.load_config).introduce
    puts intro[:exchangeable_skillsets].map { |s| s[:name] }.inspect
  RUBY
  File.write(File.join(DATA, 'card_probe.rb'), script)
  shown = `ruby -I #{lib} #{File.join(DATA, 'card_probe.rb')} #{DATA} 2>/dev/null`
  assert("a fresh process's card lists the published pack (#{shown.strip})") { shown.include?('notes_pack') }
end

puts ''
puts '=' * 60
puts "RESULT: #{$pass} passed, #{$fail} failed"
puts '=' * 60
exit($fail.zero? ? 0 : 1)
