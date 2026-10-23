#!/usr/bin/env ruby
# frozen_string_literal: true

# Meeting Place registration takeover fix (design v0.4,
# log/meeting_place_registration_takeover_fix_design_v0.4_20261023.md).
#
# Drives the real PlaceRouter, AgentRegistry, SkillBoard, SkillSet exchange
# extension, MMP::Identity and MMP::PlaceClient. Numbered sections follow §6
# of the design. Run from KairosChain_mcp_server/:
#   ruby -I templates/skillsets/synoptis/lib test_meeting_place_key_binding.rb

require 'tmpdir'
DATA_DIR = Dir.mktmpdir('kairos_keybind')
ENV['KAIROS_DATA_DIR'] = DATA_DIR

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/mmp/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/hestia/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/synoptis/lib', __dir__)

require 'kairos_mcp'
KairosMcp.data_dir = DATA_DIR
require 'mmp'
require 'mmp/meeting_session_store'
require 'hestia'
require 'json'
require 'stringio'
require 'openssl'
require 'digest'
require 'fileutils'

$pass = 0
$fail = 0

def assert(msg)
  if yield
    puts "  PASS: #{msg}"
    $pass += 1
  else
    puts "  FAIL: #{msg}"
    $fail += 1
  end
rescue StandardError => e
  puts "  FAIL: #{msg} (#{e.class}: #{e.message})"
  $fail += 1
end

def section(name)
  puts "\n--- #{name} ---"
  yield
rescue StandardError => e
  puts "  SECTION ERROR: #{e.class}: #{e.message}"
  puts e.backtrace.first(4).join("\n")
  $fail += 1
end

def rack_env(method, path, body: nil, bearer_token: nil, query: nil)
  env = {
    'REQUEST_METHOD' => method, 'PATH_INFO' => path, 'QUERY_STRING' => query || '',
    'HTTP_AUTHORIZATION' => bearer_token ? "Bearer #{bearer_token}" : nil
  }
  env['rack.input'] = StringIO.new(body ? JSON.generate(body) : '')
  env
end

def call_json(router, method, path, body: nil, token: nil, query: nil)
  status, _h, resp = router.call(rack_env(method, path, body: body, bearer_token: token, query: query))
  [status, (JSON.parse(resp.first, symbolize_names: true) rescue {})]
end

KEYS = Hash.new { |h, k| h[k] = OpenSSL::PKey::RSA.new(2048) }
def pem(name) = KEYS[name].public_key.to_pem

# Build a Place in its own directory. place_host nil → loopback audiences.
def new_place(dir, place_host: nil, extra: {}, age: true, identity_root: nil)
  mp = {
    'name' => 'KeyBind Place', 'max_agents' => 50, 'session_timeout' => 3600,
    'registry_path' => File.join(dir, 'agents.json'),
    'bindings_path' => File.join(dir, 'bindings.json'),
    'deposit_storage_path' => File.join(dir, 'board.json')
  }
  mp['web_ui'] = { 'enabled' => false, 'place_host' => place_host } if place_host
  mp['web_ui'] ||= { 'enabled' => false }
  config = { 'meeting_place' => mp.merge(extra) }
  router = Hestia::PlaceRouter.new(config: config)
  identity = MMP::Identity.new(workspace_root: identity_root || File.join(dir, 'place_ws'),
                               config: { 'identity' => { 'name' => 'Place' } })
  store = MMP::MeetingSessionStore.new
  router.start(identity: identity, session_store: store)
  # A just-started Place refuses proofs issued in its first 30 s; move the
  # start time back rather than sleeping.
  router.instance_variable_set(:@started_at, Time.now.utc - 120) if age
  [router, store, identity]
end

def proof(id:, key:, audience: 'http://localhost', issued_at: Time.now.utc, nonce: SecureRandom.hex(16), sign: :pss)
  fields = MMP::RegistrationProof.build(audience: audience, agent_id: id, issued_at: issued_at, nonce: nonce)
  sig = if sign == :pss
          MMP::RegistrationProof.sign(KEYS[key], fields)
        else
          Base64.strict_encode64(KEYS[key].sign(OpenSSL::Digest.new('SHA256'), MMP::RegistrationProof.message(fields)))
        end
  [fields, sig]
end

def register(router, id:, key: id, name: id, audience: 'http://localhost', fields: nil, sig: nil,
             public_key: :auto, extra: {})
  fields, sig = proof(id: id, key: key, audience: audience) unless fields
  body = { 'id' => id, 'name' => name, 'registration' => fields, 'registration_signature' => sig }
  body['public_key'] = public_key == :auto ? pem(key) : public_key if public_key
  call_json(router, 'POST', '/place/v1/register', body: body.merge(extra))
end

def deposit_signed(router, owner_id:, key:, skill_id:)
  content = "# #{skill_id}\nbody of #{skill_id}\n"
  skill = { skill_id: skill_id, name: skill_id, content: content, format: 'markdown',
            content_hash: Digest::SHA256.hexdigest(content),
            signature: Base64.strict_encode64(KEYS[key].sign(OpenSSL::Digest.new('SHA256'), content)) }
  router.skill_board.deposit_skill(agent_id: owner_id, skill: skill, public_key: pem(key))
end

puts '=' * 64
puts 'Meeting Place key binding (registration takeover fix)'
puts '=' * 64

section('1. Known id + attacker key → 409, binding and profile unchanged') do
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    s1, r1 = register(router, id: 'victim', name: 'Victim')
    assert('victim registers (200, token)') { s1 == 200 && r1[:session_token] }
    s2, r2 = register(router, id: 'victim', key: 'attacker', name: 'Attacker')
    assert('attacker key on victim id → 409 key_mismatch') { s2 == 409 && r2[:error] == 'key_mismatch' }
    assert('no token issued to attacker') { r2[:session_token].nil? }
    assert('binding unchanged') { router.registry.bound_key('victim') == pem('victim') }
    assert('profile unchanged') { router.registry.get('victim')[:name] == 'Victim' }
    s3, r3 = register(router, id: 'victim', key: 'attacker', name: 'Attacker', public_key: nil)
    assert('attacker without public_key → signature fails against binding') { s3 == 401 && r3[:error] == 'registration_proof_invalid' }
  end
end

section('2. Unsigned or legacy-only registration → 401, nothing written') do
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    before = router.registry.count
    s1, r1 = call_json(router, 'POST', '/place/v1/register', body: { 'id' => 'plain', 'name' => 'Plain' })
    assert('unsigned → 401 registration_proof_required') { s1 == 401 && r1[:error] == 'registration_proof_required' }
    identity = { 'name' => 'Legacy', 'instance_id' => 'legacy01' }
    legacy_sig = Base64.strict_encode64(KEYS['legacy'].sign(OpenSSL::Digest.new('SHA256'), JSON.generate(identity)))
    s2, = call_json(router, 'POST', '/place/v1/register',
                    body: { 'id' => 'legacy01', 'public_key' => pem('legacy'), 'identity' => identity,
                            'identity_signature' => legacy_sig })
    assert('legacy static signature only → 401') { s2 == 401 }
    assert('nothing registered') { router.registry.count == before && router.registry.get('plain').nil? }
    assert('nothing bound') { router.registry.bound_key('legacy01').nil? }
  end
end

section('3. Replays, audience, freshness') do
  Dir.mktmpdir do |dir|
    router, = new_place(dir, place_host: 'meeting.example')
    fields, sig = proof(id: 'agent3', key: 'agent3', audience: 'https://meeting.example')
    s1, = register(router, id: 'agent3', fields: fields, sig: sig)
    assert('fresh proof for the configured origin → 200') { s1 == 200 }
    s2, r2 = register(router, id: 'agent3', fields: fields, sig: sig)
    assert('same proof again → 401 replayed') { s2 == 401 && r2[:error] == 'registration_proof_replayed' }
    f3, g3 = proof(id: 'agent3', key: 'agent3', audience: 'https://other.example')
    s3, r3 = register(router, id: 'agent3', fields: f3, sig: g3)
    assert('proof for another origin → 401 wrong_audience') { s3 == 401 && r3[:error] == 'registration_proof_wrong_audience' }
    f4, g4 = proof(id: 'agent3', key: 'agent3', audience: 'http://meeting.example')
    s4, = register(router, id: 'agent3', fields: f4, sig: g4)
    assert('cleartext http audience for the configured host → 401') { s4 == 401 }
    f5, g5 = proof(id: 'agent3', key: 'agent3', audience: 'https://meeting.example', issued_at: Time.now.utc - 400)
    s5, r5 = register(router, id: 'agent3', fields: f5, sig: g5)
    assert('proof older than 300 s → 401 stale') { s5 == 401 && r5[:error] == 'registration_proof_stale' }
    f6, g6 = proof(id: 'agent3', key: 'agent3', audience: 'https://meeting.example', issued_at: Time.now.utc + 120)
    s6, = register(router, id: 'agent3', fields: f6, sig: g6)
    assert('proof issued too far in the future → 401') { s6 == 401 }
    floc, gloc = proof(id: 'agent3', key: 'agent3', audience: 'http://localhost')
    sloc, = register(router, id: 'agent3', fields: floc, sig: gloc)
    assert('loopback audience refused when place_host is set') { sloc == 401 }
  end
  Dir.mktmpdir do |dir|
    router, = new_place(dir, age: false)
    router.instance_variable_set(:@started_at, Time.now.utc - 5)
    s, r = register(router, id: 'early')
    assert('proof issued before started_at + 30 s → 401 stale with earliest time') do
      s == 401 && r[:error] == 'registration_proof_stale' && r[:earliest_acceptable_at]
    end
  end
end

section('4. Sessions not issued by this Place are refused at /place/*') do
  Dir.mktmpdir do |dir|
    router, store, = new_place(dir)
    register(router, id: 'victim4')
    core_token = store.create_session('victim4', pem('attacker4')) # core introduce: no pubkey_hash
    s1, = call_json(router, 'GET', '/place/v1/agents', token: core_token)
    assert('core-issued session (no pubkey_hash) → 401') { s1 == 401 }
    forged = store.create_session('victim4', pem('attacker4'), pubkey_hash: Digest::SHA256.hexdigest(pem('attacker4')))
    s2, = call_json(router, 'GET', '/place/v1/agents', token: forged)
    assert('session hashed from another key → 401') { s2 == 401 }
    s3, = call_json(router, 'POST', '/place/v1/unregister', body: {}, token: core_token)
    assert('core-issued session cannot unregister the victim') { s3 == 401 && router.registry.registered?('victim4') }
    _, ok = register(router, id: 'victim4')
    s4, = call_json(router, 'GET', '/place/v1/agents', token: ok[:session_token])
    assert('Place-issued session → 200') { s4 == 200 }
  end
end

section('5. Unregister and fade-out keep the binding') do
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    _, r = register(router, id: 'leaver')
    call_json(router, 'POST', '/place/v1/unregister', body: {}, token: r[:session_token])
    assert('unregistered') { !router.registry.registered?('leaver') }
    s1, = register(router, id: 'leaver', key: 'attacker5')
    assert('after unregister, another key → 409') { s1 == 409 }
    register(router, id: 'idler')
    router.registry.agents['idler'].last_heartbeat = (Time.now.utc - 7200).iso8601
    router.instance_variable_get(:@heartbeat_manager).check_all
    assert('idler faded out of the registry') { !router.registry.registered?('idler') }
    s2, = register(router, id: 'idler', key: 'attacker5')
    assert('after fade-out, another key → 409') { s2 == 409 }
    s3, = register(router, id: 'idler')
    assert('owner re-registers after fade-out → 200') { s3 == 200 }
  end
end

section('6. Claiming an unbound id that holds items') do
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    # Pre-deploy state: items held under ids that have no binding.
    deposit_signed(router, owner_id: 'orphan', key: 'orphan', skill_id: 'skill-a')
    assert('orphan holds a deposit and is unbound') { router.registry.bound_key('orphan').nil? }
    s1, r1 = register(router, id: 'orphan', key: 'attacker6')
    assert('attacker claim of deposit holder → 409 id_claim_unproven') { s1 == 409 && r1[:error] == 'id_claim_unproven' }
    s2, = register(router, id: 'orphan')
    assert('the depositing key claims it → 200 and bound') { s2 == 200 && router.registry.bound_key('orphan') == pem('orphan') }

    deposit_signed(router, owner_id: 'owner6', key: 'owner6', skill_id: 'skill-b')
    payload = ['attester6', 'reviewed', 'skill-b', 'owner6', router.skill_board.get_deposited_skill('skill-b', owner_agent_id: 'owner6')[:content_hash]].join('|')
    att_sig = Base64.strict_encode64(KEYS['attester6'].sign(OpenSSL::Digest.new('SHA256'), payload))
    router.skill_board.deposit_attestation(attester_id: 'attester6', skill_id: 'skill-b', owner_agent_id: 'owner6',
                                           claim: 'reviewed', signature: att_sig, signed_payload: payload,
                                           public_key: pem('attester6'))
    s3, = register(router, id: 'attester6', key: 'attacker6')
    assert('attacker claim of an attester → 409') { s3 == 409 }
    s4, = register(router, id: 'attester6')
    assert('the attesting key claims it → 200') { s4 == 200 }

    require 'kairos_mcp/skillset_manager' rescue nil
    require File.expand_path('templates/skillsets/skillset_exchange/lib/skillset_exchange/place_extension', __dir__)
    ext = SkillsetExchange::PlaceExtension.new(router)
    content_hash = "sha256:#{'a' * 64}"
    ext.instance_variable_get(:@deposited_skillsets)['ss1:ssowner'] = {
      name: 'ss1', depositor_id: 'ssowner', content_hash: content_hash,
      signature: Base64.strict_encode64(KEYS['ssowner'].sign(OpenSSL::Digest.new('SHA256'), content_hash))
    }
    router.register_extension(ext)
    s5, = register(router, id: 'ssowner', key: 'attacker6')
    assert('attacker claim of a SkillSet depositor → 409') { s5 == 409 }
    s6, = register(router, id: 'ssowner')
    assert('the SkillSet signing key claims it → 200') { s6 == 200 }

    hookless = Class.new { def call(_env, peer_id:) = nil }.new
    refused = begin
      router.register_extension(hookless)
      false
    rescue ArgumentError
      true
    end
    assert('register_extension refuses an extension without holdings_evidence') { refused }
    s7, = register(router, id: 'newcomer6')
    assert('newcomers still register') { s7 == 200 }
  end
end

section('7. Binding rate bound') do
  Dir.mktmpdir do |dir|
    router, = new_place(dir, extra: { 'binding_rate_per_hour' => 3 })
    statuses = %w[r1 r2 r3].map { |id| register(router, id: id).first }
    assert('first 3 new ids → 200') { statuses.all?(200) }
    s, r = register(router, id: 'r4')
    assert('4th new id within the hour → 503 binding_rate_exceeded') { s == 503 && r[:error] == 'binding_rate_exceeded' && r[:retry_after].to_i.positive? }
    assert('refused id is not bound') { router.registry.bound_key('r4').nil? }
    s2, = register(router, id: 'r1')
    assert('known id still registers') { s2 == 200 }
  end
end

section('8. Same id + same key re-registers; profile updates') do
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    register(router, id: 'same', name: 'Before')
    s, r = register(router, id: 'same', name: 'After')
    assert('re-register → 200 with token') { s == 200 && r[:session_token] }
    assert('profile update applies') { router.registry.get('same')[:name] == 'After' }
  end
end

section('9. Writes act on the session id') do
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    register(router, id: 'victim9')
    deposit_signed(router, owner_id: 'victim9', key: 'victim9', skill_id: 'v9-skill')
    _, ra = register(router, id: 'attacker9')
    token = ra[:session_token]
    s1, = call_json(router, 'POST', '/place/v1/unregister', body: { 'agent_id' => 'victim9' }, token: token)
    assert('unregister naming another id → 403') { s1 == 403 }
    assert('victim still registered, deposit kept') do
      router.registry.registered?('victim9') && router.skill_board.get_deposited_skill('v9-skill', owner_agent_id: 'victim9')
    end
    s2, = call_json(router, 'POST', '/place/v1/board/needs', body: { 'agent_id' => 'victim9', 'needs' => [] }, token: token)
    s3, = call_json(router, 'DELETE', '/place/v1/board/needs', body: { 'agent_id' => 'victim9' }, token: token)
    assert('needs post/delete naming another id → 403') { s2 == 403 && s3 == 403 }
    s4, r4 = call_json(router, 'POST', '/place/v1/board/needs',
                       body: { 'needs' => [{ 'name' => 'n', 'description' => 'd' }] }, token: token)
    assert('needs without agent_id act on the session id') { s4 == 200 && r4[:agent_id] == 'attacker9' }
    hash = router.skill_board.get_deposited_skill('v9-skill', owner_agent_id: 'victim9')[:content_hash]
    payload = ['victim9', 'reviewed', 'v9-skill', 'victim9', hash].join('|')
    s5, r5 = call_json(router, 'POST', '/place/v1/board/attest', token: token,
                       body: { 'skill_id' => 'v9-skill', 'owner_agent_id' => 'victim9', 'claim' => 'reviewed',
                               'signed_payload' => payload,
                               'signature' => Base64.strict_encode64(KEYS['attacker9'].sign(OpenSSL::Digest.new('SHA256'), payload)) })
    assert('attest payload naming another attester → 403') { s5 == 403 && r5[:error] == 'attester_id_mismatch' }
  end
end

section('10. Bindings file') do
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    _, r = register(router, id: 'hb10')
    path = File.join(dir, 'bindings.json')
    mtime = File.mtime(path)
    sleep 1.1
    call_json(router, 'GET', '/place/v1/agents', token: r[:session_token])
    router.registry.heartbeat('hb10')
    assert('heartbeats and requests do not rewrite the bindings file') { File.mtime(path) == mtime }
  end

  start_error = lambda do |dir, extra = {}|
    new_place(dir, extra: extra)
    nil
  rescue Hestia::AgentRegistry::BindingStoreError => e
    e.message
  end

  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'bindings.json'), '{ not json')
    assert('unparsable bindings file → Place refuses to start') { start_error.call(dir) }
  end
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'bindings.json'), JSON.generate('someone' => { 'public_key' => 'garbage' }))
    assert('bindings file holding a bad key → refuses to start') { start_error.call(dir) }
  end
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'bindings.json'), '{}')
    File.chmod(0o000, File.join(dir, 'bindings.json'))
    msg = start_error.call(dir)
    File.chmod(0o600, File.join(dir, 'bindings.json'))
    assert('unreadable bindings file → refuses to start') { msg || Process.uid.zero? }
  end
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'board.json'), JSON.generate('deposited_skills' => []))
    assert('missing bindings file with board state present → refuses to start') { start_error.call(dir)&.include?('missing') }
  end
  Dir.mktmpdir do |dir|
    assert('missing bindings file with no other state → starts') { start_error.call(dir).nil? }
    assert('Place binds itself at first start') { File.exist?(File.join(dir, 'bindings.json')) }
  end
  Dir.mktmpdir do |dir|
    config = { 'meeting_place' => { 'registry_path' => File.join(dir, 'agents.json'),
                                    'deposit_storage_path' => File.join(dir, 'board.json'),
                                    'bindings_path' => 'rel/bindings.json', 'web_ui' => { 'enabled' => false } } }
    router = Hestia::PlaceRouter.new(config: config)
    router.start(identity: MMP::Identity.new(workspace_root: File.join(dir, 'ws'), config: {}),
                 session_store: MMP::MeetingSessionStore.new)
    assert('relative bindings_path resolves under storage_dir') do
      File.exist?(File.join(KairosMcp.storage_dir, 'rel', 'bindings.json'))
    end
  end
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    File.chmod(0o500, dir)
    s, r = begin
      register(router, id: 'wfail')
    ensure
      File.chmod(0o700, dir)
    end
    assert('failed binding write → 500, no session') { Process.uid.zero? || (s == 500 && r[:session_token].nil? && !router.registry.registered?('wfail')) }
  end
  Dir.mktmpdir do |dir|
    messy = pem('hand').gsub("\n", "\r\n") + "\n\n"
    File.write(File.join(dir, 'bindings.json'), JSON.generate('hand10' => { 'public_key' => messy }))
    router, store, = new_place(dir)
    _, r = register(router, id: 'hand10', key: 'hand')
    assert('hand-written PEM with stray whitespace → same pubkey_hash as the client export') do
      store.pubkey_hash_for_token(r[:session_token]) == Digest::SHA256.hexdigest(KEYS['hand'].public_key.to_pem)
    end
  end
  Dir.mktmpdir do |dir|
    # A registry file from before this version: entries carry no keys.
    File.write(File.join(dir, 'agents.json'),
               JSON.generate('agents' => [{ 'id' => 'oldagent', 'name' => 'Old', 'is_self' => false }]))
    File.write(File.join(dir, 'bindings.json'), '{}')
    router, = new_place(dir)
    assert('registry entries without a binding are not loaded') { !router.registry.registered?('oldagent') }
  end
  Dir.mktmpdir do |dir|
    identity = MMP::Identity.new(workspace_root: File.join(dir, 'place_ws'), config: { 'identity' => { 'name' => 'Place' } })
    self_id = identity.instance_id
    File.write(File.join(dir, 'bindings.json'), JSON.generate(self_id => { 'public_key' => pem('other') }))
    assert("Place's own id bound to another key → refuses to start") { start_error.call(dir) }
  end
end

section('11. Identity: Place-facing id file') do
  Dir.mktmpdir do |root|
    fresh = MMP::Identity.new(workspace_root: File.join(root, 'fresh'), config: { 'identity' => { 'name' => 'X' } })
    id = fresh.place_agent_id
    legacy = Digest::SHA256.hexdigest(":#{fresh.config}")[0, 16]
    assert('keypair created now → random 16-hex id, not the legacy id') { id.match?(/\A[0-9a-f]{16}\z/) && id != legacy }
    assert('id file written beside the keypair') { File.read(File.join(root, 'fresh', 'keys', 'mmp_place_id')).strip == id }
    assert('instance_id unchanged by the id file') { fresh.instance_id == Digest::SHA256.hexdigest("#{File.join(root, 'fresh')}:#{fresh.config}")[0, 16] }

    old_root = File.join(root, 'old')
    FileUtils.mkdir_p(File.join(old_root, 'keys'))
    MMP::Crypto.new(auto_generate: true).save_keypair(File.join(old_root, 'keys', 'mmp_keypair.pem'))
    old = MMP::Identity.new(workspace_root: old_root, config: { 'identity' => { 'name' => 'Old' } })
    old_legacy = Digest::SHA256.hexdigest(":#{old.config}")[0, 16]
    assert('pre-existing keypair without id file → legacy id written once') do
      old.place_agent_id == old_legacy && File.read(File.join(old_root, 'keys', 'mmp_place_id')).strip == old_legacy
    end
    stock = MMP::Identity.new(workspace_root: old_root, config: YAML.load_file(File.expand_path('templates/skillsets/mmp/config/meeting.yml', __dir__)))
    if RUBY_VERSION >= '3.4' # Hash#to_s changed format in Ruby 3.4; the production fact is for 3.4
      assert('legacy derivation matches the id meeting_connect presented (stock config → 95752c5e115561dc)') do
        Digest::SHA256.hexdigest(":#{stock.config}")[0, 16] == '95752c5e115561dc'
      end
    end
    replaced = old.fresh_place_agent_id!
    assert('fresh_place_agent_id! replaces the file') { replaced != old_legacy && old.place_agent_id == replaced }
  end
end

section('12. PlaceClient#register end to end') do
  Dir.mktmpdir do |dir|
    router, = new_place(dir, place_host: 'meeting.example')
    client_identity = MMP::Identity.new(workspace_root: File.join(dir, 'client_ws'), config: { 'identity' => { 'name' => 'Client' } })
    seen = []
    wire = lambda do |client|
      client.define_singleton_method(:get_unauthenticated) do |path, _params = {}|
        _s, body = call_json(router, 'GET', path)
        body
      end
      client.define_singleton_method(:post) do |path, body|
        seen << JSON.parse(JSON.generate(body))
        _s, resp = call_json(router, 'POST', path, body: JSON.parse(JSON.generate(body)))
        resp
      end
    end
    client = MMP::PlaceClient.new(place_url: 'https://Meeting.Example:443', identity: client_identity, crypto: client_identity.crypto)
    wire.call(client)
    result = client.connect
    assert('client registers through the router and gets a token') { result[:session_token] && client.agent_id == client_identity.place_agent_id }
    assert('https://host:443 and https://host match') { seen.last['registration']['audience'] == 'https://meeting.example' }
    assert('a Place advertising registration_proof receives no legacy signature') do
      !seen.last.key?('identity_signature') && !seen.last.key?('identity')
    end

    plain = MMP::PlaceClient.new(place_url: 'http://meeting.example', identity: client_identity, crypto: client_identity.crypto)
    wire.call(plain)
    count = seen.size
    r = plain.register
    assert('client refuses to send a proof over cleartext http') { r[:error] == 'insecure_transport' && seen.size == count }
  end
  Dir.mktmpdir do |dir|
    router, = new_place(dir, age: false)
    router.instance_variable_set(:@started_at, Time.now.utc - 25)
    client_identity = MMP::Identity.new(workspace_root: File.join(dir, 'client_ws'), config: { 'identity' => { 'name' => 'Client' } })
    client = MMP::PlaceClient.new(place_url: 'http://localhost:8080', identity: client_identity, crypto: client_identity.crypto)
    client.define_singleton_method(:get_unauthenticated) { |path, _p = {}| call_json(router, 'GET', path)[1] }
    client.define_singleton_method(:post) { |path, body| call_json(router, 'POST', path, body: JSON.parse(JSON.generate(body)))[1] }
    t0 = Time.now
    r = client.register
    assert('right after a restart the client waits for the earliest time and succeeds') { r[:session_token] && (Time.now - t0) >= 4 }
  end
end

section('13. Signature scheme and key rules') do
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    fields, sig = proof(id: 'pk13', key: 'pk13', sign: :pkcs1)
    s1, = register(router, id: 'pk13', fields: fields, sig: sig)
    assert('PKCS#1 v1.5 signature over a well-formed message → 401') { s1 == 401 }
    weak_e = OpenSSL::PKey::RSA.new(2048, 3)
    KEYS['e3'] = weak_e
    s2, r2 = register(router, id: 'e3agent', key: 'e3')
    assert('exponent 3 key → 400 unacceptable_key') { s2 == 400 && r2[:error] == 'unacceptable_key' }
    KEYS['small'] = OpenSSL::PKey::RSA.new(1024)
    s3, = register(router, id: 'smallagent', key: 'small')
    assert('1024-bit key → 400') { s3 == 400 }
    assert('origin normalization') do
      MMP::RegistrationProof.normalize_origin('HTTPS://Meeting.Example:443/x') == 'https://meeting.example' &&
        MMP::RegistrationProof.normalize_origin('http://h:8080') == 'http://h:8080' &&
        MMP::RegistrationProof.origin_for_host('meeting.example:8443') == 'https://meeting.example:8443'
    end
  end
end

section('14. Proof field types, boundaries, nonces') do
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    router.instance_variable_set(:@started_at, Time.now.utc - 3600) # old proofs must not hit the start-time rule
    digits = '1' * 32
    fields, sig = proof(id: 'num14', key: 'num14', nonce: digits)
    s1, = register(router, id: 'num14', fields: fields, sig: sig)
    replay = fields.merge('nonce' => digits.to_i)
    s2, r2 = register(router, id: 'num14', fields: replay, sig: sig)
    assert('nonce sent as a JSON number → 401 (no second session from one proof)') { s1 == 200 && s2 == 401 && r2[:session_token].nil? }

    KEYS['old14']
    f3, g3 = proof(id: 'old14', key: 'old14', issued_at: Time.now.utc - 290)
    s3, = register(router, id: 'old14', fields: f3, sig: g3)
    sleep 1.1 # let the nonce store prune once: the nonce must outlive the proof, not just the call
    s4, r4 = register(router, id: 'old14', fields: f3, sig: g3)
    assert('a 290 s old proof is accepted once, then refused as replayed') { s3 == 200 && s4 == 401 && r4[:error] == 'registration_proof_replayed' }

    %w[b14a b14b b14c b14d].each { |k| KEYS[k] } # generate keys before taking timestamps
    f5, g5 = proof(id: 'b14a', key: 'b14a', issued_at: Time.now.utc - 298)
    f6, g6 = proof(id: 'b14b', key: 'b14b', issued_at: Time.now.utc - 302)
    f7, g7 = proof(id: 'b14c', key: 'b14c', issued_at: Time.now.utc + 29)
    f8, g8 = proof(id: 'b14d', key: 'b14d', issued_at: Time.now.utc + 32)
    assert('298 s old → accepted; 302 s old → refused') do
      register(router, id: 'b14a', fields: f5, sig: g5).first == 200 && register(router, id: 'b14b', fields: f6, sig: g6).first == 401
    end
    assert('29 s ahead → accepted; 32 s ahead → refused') do
      register(router, id: 'b14c', fields: f7, sig: g7).first == 200 && register(router, id: 'b14d', fields: f8, sig: g8).first == 401
    end

    nonces = router.instance_variable_get(:@registration_nonces)
    before = nonces.size
    f9, = proof(id: 'bad14', key: 'bad14')
    bad_sig = proof(id: 'bad14', key: 'other14')[1]
    register(router, id: 'bad14', fields: f9, sig: bad_sig)
    assert('a proof with a bad signature records no nonce') { nonces.size == before }

    f10, g10 = proof(id: 'mismatch14', key: 'mismatch14')
    s10, = register(router, id: 'someone_else14', key: 'mismatch14', fields: f10, sig: g10)
    assert('proof agent_id differing from the body id → 401') { s10 == 401 }
  end
end

section('15. Audience rules, holdings edge cases, durability, races') do
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    f1, g1 = proof(id: 'aud15', key: 'aud15', audience: 'https://other.example')
    s1, = register(router, id: 'aud15', fields: f1, sig: g1)
    assert('place_host unset: a non-loopback audience → 401') { s1 == 401 }
  end
  Dir.mktmpdir do |dir|
    router, = new_place(dir, place_host: 'meeting.example')
    f2, g2 = proof(id: 'port15', key: 'port15', audience: 'https://meeting.example:8443')
    s2, = register(router, id: 'port15', fields: f2, sig: g2)
    assert('audience with another port → 401') { s2 == 401 }
  end
  Dir.mktmpdir do |dir|
    assert('place_host set but unparseable → refuses to start') do
      begin
        new_place(dir, place_host: 'bad host name')
        false
      rescue Hestia::AgentRegistry::BindingStoreError
        true
      end
    end
  end
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'agents.json'), JSON.generate('agents' => []))
    assert('missing bindings file with a registry file present → refuses to start') do
      begin
        new_place(dir)
        false
      rescue Hestia::AgentRegistry::BindingStoreError
        true
      end
    end
  end
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    deposit_signed(router, owner_id: 'mixed15', key: 'owner15', skill_id: 'm1')
    deposit_signed(router, owner_id: 'mixed15', key: 'planter15', skill_id: 'm2')
    s1, = register(router, id: 'mixed15', key: 'planter15')
    s2, = register(router, id: 'mixed15', key: 'owner15')
    assert('id holding items from two keys: neither key can claim it (409, 409)') { s1 == 409 && s2 == 409 }

    require File.expand_path('templates/skillsets/skillset_exchange/lib/skillset_exchange/place_extension', __dir__)
    ext = router.extensions.find { |e| e.is_a?(SkillsetExchange::PlaceExtension) } || SkillsetExchange::PlaceExtension.new(router)
    ext.instance_variable_get(:@deposited_skillsets)['ss15:unsigned15'] = { name: 'ss15', depositor_id: 'unsigned15',
                                                                             content_hash: "sha256:#{'b' * 64}", signature: nil }
    router.register_extension(ext)
    s3, = register(router, id: 'unsigned15')
    assert('id holding an unsigned item cannot be claimed (409)') { s3 == 409 }
  end
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    File.chmod(0o500, dir)
    begin
      register(router, id: 'durable15')
    ensure
      File.chmod(0o700, dir)
    end
    assert('after a failed binding write nothing is bound') { Process.uid.zero? || router.registry.bound_key('durable15').nil? }
  end
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    KEYS['raceA']; KEYS['raceB']
    results = %w[raceA raceB].map { |k| Thread.new { register(router, id: 'race15', key: k).first } }.map(&:value)
    assert('two first claims racing: exactly one 200, the other 409') { results.sort == [200, 409] }
  end
  Dir.mktmpdir do |dir|
    router, store, = new_place(dir)
    messy = pem('crlf15').gsub("\n", "\r\n")
    _, r = register(router, id: 'crlf15', public_key: messy)
    assert('client PEM with CRLF → session pubkey_hash of the canonical PEM') do
      store.pubkey_hash_for_token(r[:session_token]) == Digest::SHA256.hexdigest(pem('crlf15'))
    end
  end
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    _, r = register(router, id: 'fade15')
    router.registry.agents['fade15'].last_heartbeat = (Time.now.utc - 7200).iso8601
    router.instance_variable_get(:@heartbeat_manager).check_all
    content = "# x\nfaded body\n"
    forged = { skill_id: 'f15', name: 'f15', content: content, format: 'markdown',
               content_hash: Digest::SHA256.hexdigest(content),
               signature: Base64.strict_encode64(KEYS['intruder15'].sign(OpenSSL::Digest.new('SHA256'), content)) }
    s, body = call_json(router, 'POST', '/place/v1/deposit', body: forged, token: r[:session_token])
    assert('after fade-out, deposits still verify against the binding (bad signature refused)') { s != 200 || body[:valid] == false }
  end
end

section('16. Declared place extensions must be mounted before new ids are claimed') do
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    register(router, id: 'known16')
    router.declared_extension_classes_source = -> { ['SkillsetExchange::PlaceExtension'] }
    require File.expand_path('templates/skillsets/skillset_exchange/lib/skillset_exchange/place_extension', __dir__)
    s1, r1 = register(router, id: 'new16')
    assert('declared extension not mounted → new id refused (409, names the extension)') do
      s1 == 409 && r1[:message].include?('SkillsetExchange::PlaceExtension')
    end
    s2, = register(router, id: 'known16')
    assert('an already bound id still registers') { s2 == 200 }
    router.register_extension(SkillsetExchange::PlaceExtension.new(router))
    s3, = register(router, id: 'new16')
    assert('once mounted, the new id registers') { s3 == 200 }
  end
end

section('17. Tools: meeting_connect and meeting_attest_skill') do
  require 'kairos_mcp/tools/base_tool'
  require File.expand_path('templates/skillsets/mmp/tools/meeting_connect', __dir__)
  require File.expand_path('templates/skillsets/mmp/tools/meeting_attest_skill', __dir__)
  Dir.mktmpdir do |dir|
    router, = new_place(dir, place_host: 'meeting.example')
    $tool_router = router
    wiring = Module.new do
      def get_unauthenticated(path, _params = {}) = call_json($tool_router, 'GET', path)[1]
      def post(path, body)
        raise EOFError, 'connection dropped' if $wiring_raise

        call_json($tool_router, 'POST', path, body: JSON.parse(JSON.generate(body)), token: @bearer_token)[1]
      end
      def get(path, params = {}, timeout: nil)
        call_json($tool_router, 'GET', path, token: @bearer_token, query: URI.encode_www_form(params))[1]
      end
    end
    MMP::PlaceClient.prepend(wiring)
    tool_config = { 'enabled' => true, 'identity' => { 'name' => 'ToolClient' } }
    MMP.define_singleton_method(:load_config) { tool_config }
    connect = KairosMcp::SkillSets::MMP::Tools::MeetingConnect.new
    connect.define_singleton_method(:http_get) { |_u| { 'name' => 'KeyBind Place' } }
    connect.define_singleton_method(:http_post) { |_u, _b| nil }

    first = JSON.parse(connect.call('url' => 'https://meeting.example').first[:text])
    first_id = first['self_agent_id']
    assert('meeting_connect registers and saves the connection') do
      first['status'] == 'connected' && first['session_token'] && File.exist?(File.join(KairosMcp.storage_dir, 'meeting_connection.json'))
    end

    fresh = JSON.parse(connect.call('url' => 'https://meeting.example', 'fresh_id' => true).first[:text])
    assert('fresh_id success: new id, previous id and note reported') do
      fresh['status'] == 'connected' && fresh['self_agent_id'] != first_id && fresh['previous_agent_id'] == first_id && fresh['fresh_id_note']
    end

    saved_before = File.read(File.join(KairosMcp.storage_dir, 'meeting_connection.json'))
    id_before = MMP::Identity.new(config: tool_config).place_agent_id
    router.instance_variable_set(:@started_at, Time.now.utc + 3600) # every proof now looks early, beyond the client's wait bound
    refused = JSON.parse(connect.call('url' => 'https://meeting.example', 'fresh_id' => true).first[:text])
    router.instance_variable_set(:@started_at, Time.now.utc - 120)
    assert('a refused connect is reported as refused and not saved') do
      refused['status'] == 'refused' && File.read(File.join(KairosMcp.storage_dir, 'meeting_connection.json')) == saved_before
    end
    assert('a fresh id that did not register is rolled back') { MMP::Identity.new(config: tool_config).place_agent_id == id_before }

    id_before_raise = MMP::Identity.new(config: tool_config).place_agent_id
    $wiring_raise = true
    connect.call('url' => 'https://meeting.example', 'fresh_id' => true)
    $wiring_raise = false
    assert('a fresh id is rolled back when connecting raises') { MMP::Identity.new(config: tool_config).place_agent_id == id_before_raise }

    deposit_signed(router, owner_id: 'owner17', key: 'owner17', skill_id: 's17')
    attest = KairosMcp::SkillSets::MMP::Tools::MeetingAttestSkill.new
    out = JSON.parse(attest.call('skill_id' => 's17', 'owner_agent_id' => 'owner17', 'claim' => 'reviewed').first[:text])
    stored = router.skill_board.instance_variable_get(:@attestations).last
    assert('meeting_attest_skill signs as the connection id and the Place accepts it') do
      out['status'] == 'attestation_deposited' && stored[:signed_payload].split('|').first == fresh['self_agent_id']
    end
  end
end

section('18. Client fallback to an older Place; id format at binding') do
  Dir.mktmpdir do |dir|
    client_identity = MMP::Identity.new(workspace_root: File.join(dir, 'client_ws'), config: { 'identity' => { 'name' => 'Client' } })
    client = MMP::PlaceClient.new(place_url: 'https://old.example', identity: client_identity, crypto: client_identity.crypto)
    sent = []
    client.define_singleton_method(:get_unauthenticated) { |_path, _p = {}| { name: 'Old Place', version: '0.2.0' } }
    client.define_singleton_method(:post) { |path, body| sent << [path, body]; { status: 'registered' } }
    client.register
    assert('a Place without registration_proof gets the legacy identity signature, no proof') do
      body = sent.last[1]
      body[:identity_signature] && body[:registration].nil?
    end
  end
  registry = Hestia::AgentRegistry.new(registry_path: File.join(Dir.mktmpdir, 'agents.json'))
  r = registry.register(id: 'bad id!', name: 'x', public_key: pem('badid18'))
  assert('binding an id outside the id format is refused') { r[:status] == 'invalid_id' && registry.bound_key('bad id!').nil? }
end

section('19. Storage names cannot collide across depositors') do
  require 'kairos_mcp/skillset_manager'
  require 'zlib'
  require 'rubygems/package'
  require File.expand_path('templates/skillsets/skillset_exchange/lib/skillset_exchange/place_extension', __dir__)
  Dir.mktmpdir do |dir|
    ss_root = File.join(dir, 'skillsets')
    %w[genomicschain_tier1 genomicschain].each do |name|
      ss = File.join(ss_root, name)
      FileUtils.mkdir_p(File.join(ss, 'knowledge', "#{name}_topic"))
      File.write(File.join(ss, 'skillset.json'), JSON.pretty_generate(
        'name' => name, 'version' => '1.0.0', 'description' => name, 'author' => 'T', 'layer' => 'L2',
        'depends_on' => [], 'provides' => [name], 'tool_classes' => [], 'knowledge_dirs' => ["knowledge/#{name}_topic"]))
      File.write(File.join(ss, 'knowledge', "#{name}_topic", "#{name}_topic.md"), "---\nname: #{name}_topic\n---\n\n# #{name}\n")
    end
    manager = KairosMcp::SkillSetManager.new(skillsets_dir: ss_root)
    router, = new_place(dir)
    ext = SkillsetExchange::PlaceExtension.new(router)
    router.register_extension(ext)
    deposit = lambda do |name, peer, key|
      pkg = manager.package(name)
      body = { 'name' => name, 'version' => '1.0.0', 'description' => name, 'content_hash' => pkg[:content_hash],
               'archive_base64' => pkg[:archive_base64], 'file_list' => pkg[:file_list],
               'signature' => Base64.strict_encode64(KEYS[key].sign(OpenSSL::Digest.new('SHA256'), pkg[:content_hash])) }
      status, _h, resp = ext.call(rack_env('POST', '/place/v1/skillset_deposit', body: body), peer_id: peer)
      [status, JSON.parse(resp.first, symbolize_names: true), pkg]
    end
    s1, _r1, victim_pkg = deposit.call('genomicschain_tier1', '95752c5e115561dc', 'victim19')
    assert('victim deposits genomicschain_tier1') { s1 == 200 }
    s2, r2, = deposit.call('genomicschain', 'tier1_95752c5e115561dc', 'attacker19')
    assert('a deposit whose directory another depositor holds → 409 storage_conflict') { s2 == 409 && r2[:error] == 'storage_conflict' }
    archive = File.join(ext.instance_variable_get(:@storage_dir), 'genomicschain_tier1_95752c5e115561dc', 'archive.tar.gz')
    assert("the victim's archive is untouched") { File.binread(archive) == Base64.strict_decode64(victim_pkg[:archive_base64]) }

    s3, = register(router, id: '95752c5e115561dc', key: 'attacker19')
    s4, = register(router, id: '95752c5e115561dc', key: 'victim19')
    assert('a real SkillSet deposit (signed as the deposit tool signs) proves its owner: attacker 409, owner 200') { s3 == 409 && s4 == 200 }

    deposit_signed(router, owner_id: 'x19', key: 'x19', skill_id: 'y__z')
    clash = deposit_signed(router, owner_id: 'x19__y', key: 'x19b', skill_id: 'z') # x19/y__z and x19__y/z share one file name
    assert('a board deposit whose content file another deposit holds is refused') { clash[:valid] == false }
  end
end

section('20. Round-2 fixes') do
  require 'kairos_mcp/skillset_manager'
  require File.expand_path('templates/skillsets/skillset_exchange/lib/skillset_exchange/place_extension', __dir__)

  # Restart round trip: a binding made by registration survives a new process.
  Dir.mktmpdir do |dir|
    router, = new_place(dir, identity_root: File.join(dir, 'ws'))
    register(router, id: 'persist20')
    router2, = new_place(dir, identity_root: File.join(dir, 'ws'))
    assert('after a restart, another key → 409; the owner → 200') do
      register(router2, id: 'persist20', key: 'attacker20').first == 409 && register(router2, id: 'persist20').first == 200
    end
  end

  # The Place's own id: foreign items under it block self-binding.
  Dir.mktmpdir do |dir|
    router, = new_place(dir, identity_root: File.join(dir, 'ws'))
    self_id = router.instance_variable_get(:@self_id)
    deposit_signed(router, owner_id: self_id, key: 'squatter20', skill_id: 'planted')
    File.write(File.join(dir, 'bindings.json'), '{}')
    refused = begin
      new_place(dir, identity_root: File.join(dir, 'ws'))
      false
    rescue Hestia::AgentRegistry::BindingStoreError
      true
    end
    assert("Place's own unbound id holding items another key signed → refuses to start") { refused }
  end

  # Sessions with the right hash but not issued by this Place.
  Dir.mktmpdir do |dir|
    router, store, = new_place(dir)
    register(router, id: 'victim20')
    forged = store.create_session('victim20', pem('victim20'), pubkey_hash: Digest::SHA256.hexdigest(pem('victim20')))
    s, = call_json(router, 'GET', '/place/v1/agents', token: forged)
    assert("a session carrying the binding's hash but not issued by this Place → 401") { s == 401 }

    register(router, id: 'odd20') # bound first: the fall-through would otherwise find a binding and issue a session
    router.registry.define_singleton_method(:register) { |**_k| { status: 'something_new', agent_id: 'odd20' } }
    s2, r2 = register(router, id: 'odd20')
    assert('an unknown registry status fails closed (500, no session)') { s2 == 500 && r2[:session_token].nil? }
  end

  Dir.mktmpdir do |dir|
    refused = begin
      new_place(dir, place_host: 'https://meeting.example')
      false
    rescue Hestia::AgentRegistry::BindingStoreError
      true
    end
    assert('place_host written as a URL → refuses to start') { refused }
  end

  # Case-insensitive storage names, reservations, withdraw safety, own replacement.
  Dir.mktmpdir do |dir|
    ss_root = File.join(dir, 'skillsets')
    %w[genomicschain_tier1].each do |name|
      ss = File.join(ss_root, name)
      FileUtils.mkdir_p(File.join(ss, 'knowledge', "#{name}_topic"))
      File.write(File.join(ss, 'skillset.json'), JSON.pretty_generate(
        'name' => name, 'version' => '1.0.0', 'description' => name, 'author' => 'T', 'layer' => 'L2',
        'depends_on' => [], 'provides' => [name], 'tool_classes' => [], 'knowledge_dirs' => ["knowledge/#{name}_topic"]))
      File.write(File.join(ss, 'knowledge', "#{name}_topic", "#{name}_topic.md"), "---\nname: #{name}_topic\n---\n\n# #{name}\n")
    end
    manager = KairosMcp::SkillSetManager.new(skillsets_dir: ss_root)
    router, = new_place(dir)
    ext = SkillsetExchange::PlaceExtension.new(router)
    router.register_extension(ext)
    deposit = lambda do |peer|
      pkg = manager.package('genomicschain_tier1')
      body = { 'name' => 'genomicschain_tier1', 'version' => '1.0.0', 'description' => 'x', 'content_hash' => pkg[:content_hash],
               'archive_base64' => pkg[:archive_base64], 'file_list' => pkg[:file_list], 'signature' => nil }
      status, _h, resp = ext.call(rack_env('POST', '/place/v1/skillset_deposit', body: body), peer_id: peer)
      [status, (JSON.parse(resp.first, symbolize_names: true) rescue {})]
    end
    assert('victim deposits') { deposit.call('95752c5e115561dc').first == 200 }
    assert('the same name under the id in upper case → 409 storage_conflict') { deposit.call('95752C5E115561DC').first == 409 }

    ext.send(:claim_deposit_dir, 'genomicschain_tier1_inflight20', 'genomicschain_tier1:other')
    assert('a directory reserved by a deposit in progress refuses a colliding deposit') { deposit.call('inflight20').first == 409 }
    ext.send(:release_deposit_dir, 'genomicschain_tier1_inflight20', 'genomicschain_tier1:other')

    storage = ext.instance_variable_get(:@storage_dir)
    File.chmod(0o500, storage)
    failed = begin
      deposit.call('failer20').first
    rescue StandardError
      :raised
    ensure
      File.chmod(0o700, storage)
    end
    reserved = ext.instance_variable_get(:@dirs_in_flight)
    assert('a deposit that fails to write releases its reservation') do
      Process.uid.zero? || (failed != 200 && !reserved.key?('genomicschain_tier1_failer20'))
    end

    # Pre-existing collision: two deposits share one directory; withdrawing one keeps the files.
    shared_meta = ext.instance_variable_get(:@deposited_skillsets)['genomicschain_tier1:95752c5e115561dc']
    ext.instance_variable_get(:@deposited_skillsets)['genomicschain_tier1:95752C5E115561DC'] =
      shared_meta.merge(depositor_id: '95752C5E115561DC')
    st, = ext.call(rack_env('POST', '/place/v1/skillset_withdraw', body: { 'name' => 'genomicschain_tier1' }), peer_id: '95752C5E115561DC')
    assert('withdrawing one of two deposits sharing a directory keeps the other deposit\'s files') do
      st == 200 && File.exist?(File.join(storage, 'genomicschain_tier1_95752c5e115561dc', 'archive.tar.gz'))
    end

    deposit_signed(router, owner_id: 'owner20', key: 'owner20', skill_id: 'notes20')
    again = deposit_signed(router, owner_id: 'owner20', key: 'owner20', skill_id: 'notes20')
    assert('an owner can replace its own board deposit') { again[:valid] == true }
    upper = deposit_signed(router, owner_id: 'OWNER20', key: 'other20', skill_id: 'notes20')
    assert('a board deposit whose content file differs only in case is refused') { upper[:valid] == false }
  end

  # The production path of the declared-extension check (no injection).
  installed = File.join(KairosMcp.skillsets_dir, 'skillset_exchange')
  begin
    FileUtils.mkdir_p(KairosMcp.skillsets_dir)
    FileUtils.cp_r(File.expand_path('templates/skillsets/skillset_exchange', __dir__), installed)
    Dir.mktmpdir do |dir|
      router, = new_place(dir)
      s1, r1 = register(router, id: 'prodpath20')
      status = router.status
      assert('installed, enabled skillset_exchange not mounted → new id refused, status lists it') do
        s1 == 409 && r1[:message].include?('SkillsetExchange::PlaceExtension') &&
          status[:unmounted_extensions] == ['SkillsetExchange::PlaceExtension']
      end
      router.register_extension(SkillsetExchange::PlaceExtension.new(router))
      assert('after mounting, the new id registers') { register(router, id: 'prodpath20').first == 200 }
    end
  ensure
    FileUtils.rm_rf(installed)
  end
end

section('21. Round-3 fixes') do
  require 'kairos_mcp/skillset_manager'
  require File.expand_path('templates/skillsets/skillset_exchange/lib/skillset_exchange/place_extension', __dir__)

  # A second start in the same process (new router, same session store) keeps live sessions.
  Dir.mktmpdir do |dir|
    store = MMP::MeetingSessionStore.new
    mk = lambda do
      config = { 'meeting_place' => { 'registry_path' => File.join(dir, 'agents.json'), 'bindings_path' => File.join(dir, 'bindings.json'),
                                      'deposit_storage_path' => File.join(dir, 'board.json'), 'web_ui' => { 'enabled' => false } } }
      r = Hestia::PlaceRouter.new(config: config)
      r.start(identity: MMP::Identity.new(workspace_root: File.join(dir, 'ws'), config: {}), session_store: store)
      r.instance_variable_set(:@started_at, Time.now.utc - 120)
      r
    end
    first = mk.call
    _, r = register(first, id: 'live21')
    second = mk.call
    s, = call_json(second, 'GET', '/place/v1/agents', token: r[:session_token])
    assert('a session issued before a second meeting_place_start still works') { s == 200 }
  end

  # Unreadable SkillSet list fails closed for new ids.
  Dir.mktmpdir do |dir|
    router, = new_place(dir)
    original = KairosMcp::SkillSetManager.method(:new)
    KairosMcp::SkillSetManager.define_singleton_method(:new) { |*_a, **_k| raise IOError, 'skillsets unreadable' }
    begin
      s, = register(router, id: 'unreadable21')
    ensure
      KairosMcp::SkillSetManager.define_singleton_method(:new, original)
    end
    assert('when the declared-extension list cannot be read, new ids are refused') { s == 409 }
  end

  # meeting_place_status shows the running Place, including unmounted extensions.
  Dir.mktmpdir do |dir|
    require 'kairos_mcp/tools/base_tool'
    require File.expand_path('templates/skillsets/hestia/tools/meeting_place_status', __dir__)
    router, = new_place(dir)
    router.declared_extension_classes_source = -> { ['Some::Extension'] }
    previous = KairosMcp.http_server
    KairosMcp.http_server = Struct.new(:place_router).new(router)
    begin
      out = JSON.parse(KairosMcp::SkillSets::Hestia::Tools::MeetingPlaceStatus.new.call({}).first[:text])
    ensure
      KairosMcp.http_server = previous
    end
    assert('meeting_place_status reports unmounted extensions of the running Place') do
      out.dig('running', 'unmounted_extensions') == ['Some::Extension']
    end
  end

  # Withdraw keeps its directory reserved while deleting; no same-key race.
  Dir.mktmpdir do |dir|
    ss_root = File.join(dir, 'skillsets')
    ss = File.join(ss_root, 'genomicschain_tier1')
    FileUtils.mkdir_p(File.join(ss, 'knowledge', 'genomicschain_tier1_topic'))
    File.write(File.join(ss, 'skillset.json'), JSON.pretty_generate(
      'name' => 'genomicschain_tier1', 'version' => '1.0.0', 'description' => 'x', 'author' => 'T', 'layer' => 'L2',
      'depends_on' => [], 'provides' => ['genomicschain_tier1'], 'tool_classes' => [], 'knowledge_dirs' => ['knowledge/genomicschain_tier1_topic']))
    File.write(File.join(ss, 'knowledge', 'genomicschain_tier1_topic', 'genomicschain_tier1_topic.md'), "---\nname: t\n---\n\n# t\n")
    manager = KairosMcp::SkillSetManager.new(skillsets_dir: ss_root)
    router, = new_place(dir)
    ext = SkillsetExchange::PlaceExtension.new(router)
    router.register_extension(ext)
    pkg = manager.package('genomicschain_tier1')
    body = { 'name' => 'genomicschain_tier1', 'version' => '1.0.0', 'description' => 'x', 'content_hash' => pkg[:content_hash],
             'archive_base64' => pkg[:archive_base64], 'file_list' => pkg[:file_list], 'signature' => nil }
    deposit = ->(peer) { ext.call(rack_env('POST', '/place/v1/skillset_deposit', body: body), peer_id: peer).first }
    withdraw = lambda do |peer|
      status, _h, resp = ext.call(rack_env('POST', '/place/v1/skillset_withdraw', body: { 'name' => 'genomicschain_tier1' }), peer_id: peer)
      [status, (JSON.parse(resp.first, symbolize_names: true) rescue {})]
    end
    deposit.call('owner21')

    during = nil
    fu = FileUtils.singleton_class
    fu.alias_method(:__orig_rm_rf21, :rm_rf)
    fu.define_method(:rm_rf) do |*args, **kw|
      during ||= deposit.call('OWNER21') # collides case-insensitively with owner21's directory
      __orig_rm_rf21(*args, **kw)
    end
    begin
      withdraw.call('owner21')
    ensure
      fu.alias_method(:rm_rf, :__orig_rm_rf21)
      fu.remove_method(:__orig_rm_rf21)
    end
    assert('a colliding deposit arriving while withdraw deletes the directory is refused') { during == 409 }
    assert('and nothing of it was stored') { ext.instance_variable_get(:@deposited_skillsets).keys.none? { |k| k.end_with?(':OWNER21') } }

    deposit.call('owner21')
    ext.send(:claim_deposit_dir, 'genomicschain_tier1_owner21', 'genomicschain_tier1:owner21')
    st, rr = withdraw.call('owner21')
    ext.send(:release_deposit_dir, 'genomicschain_tier1_owner21', 'genomicschain_tier1:owner21')
    assert('withdraw while a deposit to the same storage is in progress → 409, deposit kept') do
      st == 409 && rr[:error] == 'deposit_in_progress' && ext.instance_variable_get(:@deposited_skillsets).key?('genomicschain_tier1:owner21')
    end
  end
end

puts "\n#{'=' * 64}"
puts "RESULT: #{$pass} passed, #{$fail} failed"
puts '=' * 64
FileUtils.rm_rf(DATA_DIR)
exit($fail.zero? ? 0 : 1)
