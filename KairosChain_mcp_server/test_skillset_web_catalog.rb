#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================================
# SkillSet Web Catalog Test (design: skillset_web_catalog v0.3.1 FROZEN)
# ============================================================================
# Covers, at unit level:
#   - PlaceRouter public-route mechanism (WC-1/WC-2): declaration as recorded
#     act, namespace validation, method restriction, rate limiting,
#     capability-severed dispatch via #public_call
#   - PlaceExtension anonymous catalog (WC-3/WC-4/WC-5): deposit-time
#     certificate summary extraction, three-state provenance field,
#     depositor-text register separation, search exclusion of
#     certificate-derived fields, escaping, withdrawal/redeposit address
#     severance, disclosure bound, launch backfill
#
# Scenario D (deployed composition) is a deploy-time check, not covered here.
#
# Usage:
#   cd /path/to/KairosChain_2026 && ruby -I KairosChain_mcp_server/lib \
#     KairosChain_mcp_server/test_skillset_web_catalog.rb
# ============================================================================

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/hestia/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/skillset_exchange/lib', __dir__)

require 'kairos_mcp'
require 'kairos_mcp/skillset'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'base64'
require 'zlib'
require 'rubygems/package'
require 'stringio'

require 'hestia/place_router'
require 'skillset_exchange/place_extension'

$pass_count = 0
$fail_count = 0

def assert(msg)
  result = yield
  if result
    puts "  PASS: #{msg}"
    $pass_count += 1
  else
    puts "  FAIL: #{msg}"
    $fail_count += 1
  end
rescue StandardError => e
  puts "  FAIL: #{msg} (#{e.class}: #{e.message})"
  $fail_count += 1
end

def section(title)
  puts ''
  puts '=' * 60
  puts "SECTION: #{title}"
  puts '=' * 60
  yield
rescue StandardError => e
  puts "  SECTION ERROR: #{e.class}: #{e.message}"
  puts e.backtrace.first(3).join("\n")
  $fail_count += 1
end

# --- Helpers ---------------------------------------------------------------

def create_skillset_dir(parent_dir, name:, description: 'Test SkillSet', certificate: nil)
  ss_dir = File.join(parent_dir, name)
  FileUtils.mkdir_p(File.join(ss_dir, 'knowledge'))
  metadata = {
    'name' => name, 'version' => '1.0.0', 'description' => description,
    'author' => 'Test', 'layer' => 'L1', 'provides' => [name],
    'tool_classes' => [], 'knowledge_files' => ["knowledge/#{name}.json"]
  }
  File.write(File.join(ss_dir, 'skillset.json'), JSON.pretty_generate(metadata))
  File.write(File.join(ss_dir, 'knowledge', "#{name}.json"), JSON.generate({ 'body' => "content of #{name}" }))
  if certificate
    content = certificate == :corrupt ? '{ not json' : JSON.pretty_generate(certificate)
    File.write(File.join(ss_dir, 'certificate.json'), content)
  end
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

SAMPLE_CERT = {
  'claim_core' => {
    'convention' => 'cd-1',
    'certificate_identity' => 'cert-1234-abcd',
    'recording' => { 'revocation_channel' => 'source-chain:cd_revocation' },
    'statuses' => {
      'identity.binding' => 'checkable',
      'derivation' => 'anchor-pending',
      'revocation_status' => 'trusted'
    }
  },
  'openings' => { 'claim_core_salt' => 'SECRET_SALT_MUST_NOT_LEAK' }
}.freeze

class StubRegistry
  def public_key_for(_id) = nil
end

class StubRouter
  attr_reader :skill_board, :session_store, :registry

  def initialize
    @skill_board = nil
    @session_store = nil
    @registry = StubRegistry.new
  end
end

def deposit_env(body_hash)
  body = JSON.generate(body_hash)
  {
    'REQUEST_METHOD' => 'POST', 'PATH_INFO' => '/place/v1/skillset_deposit',
    'CONTENT_LENGTH' => body.bytesize.to_s, 'rack.input' => StringIO.new(body)
  }
end

def get_env(path, query = '')
  { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => path, 'QUERY_STRING' => query, 'REMOTE_ADDR' => '127.0.0.1' }
end

def do_deposit(ext, ss_dir, name, peer: 'agent-001')
  tar = create_tar_gz(ss_dir, name)
  ss = KairosMcp::Skillset.new(ss_dir)
  env = deposit_env(
    'name' => name, 'version' => ss.version, 'description' => ss.description,
    'content_hash' => ss.content_hash,
    'archive_base64' => Base64.strict_encode64(tar),
    'file_list' => ss.file_list, 'tags' => [], 'provides' => ss.provides
  )
  ext.call(env, peer_id: peer)
end

def body_of(response)
  response[2].join
end

# A public-route extension double for router-mechanism tests.
class CatalogStubExtension
  def initialize(_router = nil); end
  def call(_env, peer_id:) = nil

  def public_call(env)
    return [200, { 'Content-Type' => 'text/html' }, ['<html>stub-catalog</html>']] if env['PATH_INFO'] == '/place/web/stub'

    nil
  end
end

# Declares its public routes via #public_route_prefixes (capability travels
# with the extension). Registration paths need not pass public_routes.
class SelfDeclaringExtension
  def self.public_route_prefixes = ['/place/web/selfdecl']
  def initialize(_router = nil); end
  def public_route_prefixes = self.class.public_route_prefixes
  def call(_env, peer_id:) = nil

  def public_call(env)
    return [200, { 'Content-Type' => 'text/html' }, ['self-declared']] if env['PATH_INFO'] == '/place/web/selfdecl'

    nil
  end
end

class NoPublicCallExtension
  def initialize(_router = nil); end
  def call(_env, peer_id:) = nil
end

# ============================================================================
section('1. PlaceRouter public-route mechanism (WC-1/WC-2)') do
  router = Hestia::PlaceRouter.new(config: {})
  router.instance_variable_set(:@started, true)

  # Declaration validation: namespace + public_call capability
  bad_ns = begin
    router.register_extension(CatalogStubExtension.new, public_routes: ['/place/v1/evil'])
    false
  rescue ArgumentError
    true
  end
  assert('public route outside /place/web/ namespace is rejected') { bad_ns }

  no_call = begin
    router.register_extension(NoPublicCallExtension.new, public_routes: ['/place/web/x'])
    false
  rescue ArgumentError
    true
  end
  assert('extension without #public_call cannot declare public routes') { no_call }

  # Valid registration is a recorded act
  router.register_extension(CatalogStubExtension.new, public_routes: ['/place/web/stub'])
  decls = router.public_route_declarations
  assert('declaration recorded with extension class') { decls.size == 1 && decls.first[:extension_class] == 'CatalogStubExtension' }
  assert('declaration records prefixes') { decls.first[:prefixes] == ['/place/web/stub'] }
  assert('declaration records timestamp') { !decls.first[:declared_at].to_s.empty? }

  # Anonymous GET dispatch (no auth, no peer identity)
  res = router.call(get_env('/place/web/stub'))
  assert('anonymous GET on declared route served') { res[0] == 200 && body_of(res).include?('stub-catalog') }

  # Method restriction (window discipline)
  post_res = router.call({ 'REQUEST_METHOD' => 'POST', 'PATH_INFO' => '/place/web/stub', 'REMOTE_ADDR' => '127.0.0.1' })
  assert('POST on public route rejected 405') { post_res[0] == 405 }

  # Unmatched path under prefix → 404 (extension returned nil)
  res_404 = router.call(get_env('/place/web/stub/nothing'))
  assert('unhandled path under declared prefix returns 404') { res_404[0] == 404 }

  # Rate limiting participation
  limited = false
  40.times do
    r = router.call(get_env('/place/web/stub'))
    limited = true if r[0] == 429
  end
  assert('public route participates in rate limiting (429 after burst)') { limited }

  # Security headers contributed by the window (WC-1)
  hdr_res = router.call(get_env('/place/web/stub'))
  # (may be 429 after the burst above; use a fresh router)
  r2 = Hestia::PlaceRouter.new(config: {})
  r2.instance_variable_set(:@started, true)
  r2.register_extension(CatalogStubExtension.new, public_routes: ['/place/web/stub'])
  sec = r2.call(get_env('/place/web/stub'))
  assert('window adds X-Frame-Options: DENY') { sec[1]['X-Frame-Options'] == 'DENY' }
  assert('window adds Content-Security-Policy') { sec[1]['Content-Security-Policy'].to_s.include?("default-src 'none'") }
  assert('window adds X-Content-Type-Options: nosniff') { sec[1]['X-Content-Type-Options'] == 'nosniff' }

  # HEAD returns empty body
  head = r2.call({ 'REQUEST_METHOD' => 'HEAD', 'PATH_INFO' => '/place/web/stub', 'REMOTE_ADDR' => '10.0.0.5' })
  assert('HEAD returns 200 with empty body') { head[0] == 200 && head[2] == [] }
end

# ============================================================================
section('1b. Auto-sourced + idempotent-upgrade public routes (wiring hardening)') do
  # Self-declaring extension: registration WITHOUT explicit public_routes still
  # wires the route (capability travels with the extension). This closes the
  # lazy/STDIO dead-in-prod gap.
  r = Hestia::PlaceRouter.new(config: {})
  r.instance_variable_set(:@started, true)
  r.register_extension(SelfDeclaringExtension.new)  # no public_routes: kwarg
  assert('self-declared route auto-wired without explicit kwarg') {
    r.public_route_declarations.any? { |d| d[:prefixes].include?('/place/web/selfdecl') }
  }
  res = r.call(get_env('/place/web/selfdecl'))
  assert('self-declared route resolves anonymously') { res[0] == 200 && body_of(res).include?('self-declared') }

  # Idempotent-upgrade: an extension first registered WITHOUT routes (older
  # lazy path simulated by a plain call) gets routes attached on a later call.
  r2 = Hestia::PlaceRouter.new(config: {})
  r2.instance_variable_set(:@started, true)
  first = CatalogStubExtension.new
  r2.register_extension(first)  # CatalogStubExtension has no public_route_prefixes → no routes
  assert('no routes after route-less registration') { r2.public_route_declarations.empty? }
  r2.register_extension(CatalogStubExtension.new, public_routes: ['/place/web/stub'])
  assert('idempotent-upgrade attaches routes to already-registered class') {
    r2.public_route_declarations.any? { |d| d[:prefixes].include?('/place/web/stub') }
  }
  assert('upgraded route dispatches to the original instance') {
    r2.call(get_env('/place/web/stub'))[0] == 200
  }

  # Declaration introspection is a deep copy (cannot mutate the registry)
  decls = r2.public_route_declarations
  decls.first[:prefixes] << '/place/web/injected'
  assert('declaration introspection is deep-copied') {
    r2.public_route_declarations.none? { |d| d[:prefixes].include?('/place/web/injected') }
  }

  # Window security headers win over extension-supplied headers (WC-1)
  r_sec = Hestia::PlaceRouter.new(config: {})
  r_sec.instance_variable_set(:@started, true)
  weak = Class.new do
    def call(_e, peer_id:) = nil
    def public_call(_e)
      [200, { 'Content-Type' => 'text/html', 'X-Frame-Options' => 'SAMEORIGIN',
              'Content-Security-Policy' => "default-src *" }, ['weak']]
    end
  end.new
  r_sec.register_extension(weak, public_routes: ['/place/web/weak'])
  wres = r_sec.call(get_env('/place/web/weak'))
  assert('extension cannot weaken X-Frame-Options') { wres[1]['X-Frame-Options'] == 'DENY' }
  assert('extension cannot weaken CSP') { wres[1]['Content-Security-Policy'].include?("default-src 'none'") }
  assert('extension keeps its own Content-Type') { wres[1]['Content-Type'] == 'text/html' }

  # Bare namespace prefix is rejected (would shadow the WebRouter)
  bare_rejected = begin
    r_sec.register_extension(CatalogStubExtension.new, public_routes: ['/place/web/'])
    false
  rescue ArgumentError
    true
  end
  assert('bare /place/web/ namespace prefix rejected') { bare_rejected }

  # Upgrade path still enforces #public_call
  r_up = Hestia::PlaceRouter.new(config: {})
  r_up.instance_variable_set(:@started, true)
  r_up.register_extension(NoPublicCallExtension.new)  # no routes, no public_call
  upgrade_rejected = begin
    r_up.register_extension(NoPublicCallExtension.new, public_routes: ['/place/web/np'])
    false
  rescue ArgumentError
    true
  end
  assert('upgrade path rejects routes for extension without #public_call') { upgrade_rejected }

  # Longest-prefix wins regardless of order
  r3 = Hestia::PlaceRouter.new(config: {})
  r3.instance_variable_set(:@started, true)
  broad = Class.new do
    def call(_e, peer_id:) = nil
    def public_call(_e) = [200, { 'Content-Type' => 'text/plain' }, ['broad']]
  end.new
  narrow = Class.new do
    def call(_e, peer_id:) = nil
    def public_call(_e) = [200, { 'Content-Type' => 'text/plain' }, ['narrow']]
  end.new
  r3.register_extension(broad, public_routes: ['/place/web/a'])
  r3.register_extension(narrow, public_routes: ['/place/web/a/b'])
  assert('longest-prefix wins: /a/b/x → narrow, not broad') {
    body_of(r3.call(get_env('/place/web/a/b/x'))).include?('narrow')
  }
end

# ============================================================================
Dir.mktmpdir('kairos_wc_test') do |tmpdir|
  KairosMcp.data_dir = tmpdir
  src = File.join(tmpdir, 'src')
  FileUtils.mkdir_p(src)

  ext = SkillsetExchange::PlaceExtension.new(StubRouter.new)

  certified_dir = create_skillset_dir(src, name: 'certified_pkg',
    description: 'A certified distillate package', certificate: SAMPLE_CERT)
  plain_dir = create_skillset_dir(src, name: 'plain_pkg',
    description: 'CERTIFIED! provenance verified checkable — trust me')
  corrupt_dir = create_skillset_dir(src, name: 'corrupt_cert_pkg',
    description: 'Certificate present but unreadable', certificate: :corrupt)

  section('2. Deposit-time certificate extraction (BL-WC-5, WC-3)') do
    r1 = do_deposit(ext, certified_dir, 'certified_pkg')
    assert('certified deposit accepted') { r1[0] == 200 }
    r2 = do_deposit(ext, plain_dir, 'plain_pkg')
    assert('plain deposit accepted') { r2[0] == 200 }
    r3 = do_deposit(ext, corrupt_dir, 'corrupt_cert_pkg')
    assert('corrupt-certificate deposit accepted') { r3[0] == 200 }

    metas = ext.instance_variable_get(:@deposited_skillsets)
    cert_meta = metas['certified_pkg:agent-001']
    assert('certified: summary extracted at deposit time') {
      cert_meta[:certificate][:present] == true &&
        cert_meta[:certificate][:summary][:certificate_identity] == 'cert-1234-abcd'
    }
    assert('certified: statuses carried in CD-2 vocabulary') {
      cert_meta[:certificate][:summary][:statuses].values.include?('anchor-pending')
    }
    assert('plain: no provenance claim recorded') {
      metas['plain_pkg:agent-001'][:certificate][:present] == false
    }
    assert('corrupt: claim present, summary unavailable') {
      c = metas['corrupt_cert_pkg:agent-001'][:certificate]
      c[:present] == true && c[:summary].nil?
    }
    assert('listing addresses assigned (16 hex)') {
      metas.values.all? { |m| m[:listing_address] =~ /\A[a-f0-9]{16}\z/ }
    }
  end

  section('3. Scenario A — co-equal rendering, register separation, search exclusion (WC-4)') do
    res = ext.public_call(get_env('/place/web/skillsets'))
    html = body_of(res)
    assert('catalog renders 200 HTML') { res[0] == 200 && res[1]['Content-Type'].include?('text/html') }
    assert('cache discipline: no-store') { res[1]['Cache-Control'] == 'no-store' }
    assert('every listing carries the provenance register') { html.scan('class="provenance"').size == 3 }
    assert('uncertified renders "No provenance claim"') { html.include?('No provenance claim.') }
    assert('corrupt renders unavailability marker, not a negative claim') {
      html.include?('Provenance claim present — summary unavailable.')
    }
    assert('no certification badge/filter/sort controls exist') {
      !html.match?(/badge|sort=|filter=certified/i)
    }
    assert('depositor forgery text stays in depositor register') {
      # plain_pkg's description asserts certification, but its provenance
      # register still says "No provenance claim".
      html.include?('CERTIFIED! provenance verified checkable')
    }

    # Search over CD-2 vocabulary must not select certificate-derived fields:
    # only plain_pkg (whose depositor text contains "checkable") may match.
    res_s = ext.public_call(get_env('/place/web/skillsets', 'search=checkable'))
    html_s = body_of(res_s)
    assert('search "checkable" does not select the certified listing') {
      html_s.include?('plain_pkg') && !html_s.include?('certified_pkg')
    }
    res_s2 = ext.public_call(get_env('/place/web/skillsets', 'search=cert-1234'))
    assert('search on certificate identity matches nothing certificate-derived') {
      !body_of(res_s2).include?('certified_pkg')
    }
  end

  section('4. Scenario A/B — detail view, disclosure bound (WC-3, WC-5)') do
    metas = ext.instance_variable_get(:@deposited_skillsets)
    addr = metas['certified_pkg:agent-001'][:listing_address]
    res = ext.public_call(get_env("/place/web/skillsets/#{addr}"))
    html = body_of(res)
    assert('detail view resolves by address') { res[0] == 200 && html.include?('certified_pkg') }
    assert('detail shows checkability statuses table') {
      html.include?('anchor-pending') && html.include?('identity.binding')
    }
    assert('detail shows revocation channel') { html.include?('source-chain:cd_revocation') }
    assert('disclosed limitation: deposit-judgment staleness + carrier-side revocation') {
      html.include?('reflects deposit-judgment') && html.include?('carrier-side')
    }
    assert('provenance-not-quality stated') { html.include?('origin, not quality') }
    assert('acquisition described, not performed (agent path)') {
      html.include?('skillset_acquire') && !html.include?('archive_base64')
    }
    assert('disclosure bound: no package content, no salts') {
      !html.include?('content of certified_pkg') && !html.include?('SECRET_SALT_MUST_NOT_LEAK')
    }
    assert('no anonymous route serves archive content') {
      ext.public_call(get_env('/place/web/skillsets/content')).nil?
    }
  end

  section('5. Scenario C — withdrawal and redeposit severance (WC-5)') do
    metas = ext.instance_variable_get(:@deposited_skillsets)
    old_addr = metas['certified_pkg:agent-001'][:listing_address]

    wbody = JSON.generate('name' => 'certified_pkg', 'reason' => 'test withdrawal')
    wenv = { 'REQUEST_METHOD' => 'POST', 'PATH_INFO' => '/place/v1/skillset_withdraw',
             'rack.input' => StringIO.new(wbody) }
    wres = ext.call(wenv, peer_id: 'agent-001')
    assert('withdrawal succeeds') { wres[0] == 200 }

    gone = ext.public_call(get_env("/place/web/skillsets/#{old_addr}"))
    assert('withdrawn address ceases to resolve (404, absence only)') {
      gone[0] == 404 && !body_of(gone).include?('cert-1234-abcd')
    }
    cat = body_of(ext.public_call(get_env('/place/web/skillsets')))
    assert('withdrawn listing absent from catalog') { !cat.include?('certified_pkg') }

    # Redeposit without certificate: new identity in every register
    recert_dir = create_skillset_dir(File.join(tmpdir, 'src2'), name: 'certified_pkg',
      description: 'Redeposited without certificate')
    rres = do_deposit(ext, recert_dir, 'certified_pkg')
    assert('redeposit accepted') { rres[0] == 200 }
    new_meta = ext.instance_variable_get(:@deposited_skillsets)['certified_pkg:agent-001']
    assert('redeposit gets a new address (severance)') {
      new_meta[:listing_address] != old_addr
    }
    assert('redeposit inherits no certificate state') { new_meta[:certificate][:present] == false }
    old_after = ext.public_call(get_env("/place/web/skillsets/#{old_addr}"))
    assert('predecessor address still does not resolve after redeposit') { old_after[0] == 404 }
  end

  section('5b. CD-2 status projection — malformed certificate cannot forge the register (WC-3/WC-4)') do
    # A certificate whose statuses contain a quality-shaped claim, a nested
    # value hiding a salt, and a non-vocabulary value.
    forged = {
      'claim_core' => {
        'certificate_identity' => 'forged-cert-9',
        'recording' => { 'revocation_channel' => 'source-chain:cd_revocation' },
        'statuses' => {
          'quality' => 'excellent',                                   # non-CD-2 key
          'identity.binding' => { 'opening' => 'SECRET_SALT' },       # nested → dropped
          'derivation' => 'anchor-pending',                           # valid → kept
          'revocation_status' => 'definitely-fine'                    # non-vocabulary value → dropped
        }
      }
    }
    forged_dir = create_skillset_dir(File.join(tmpdir, 'src_forged'), name: 'forged_pkg',
      description: 'forged certificate', certificate: forged)
    do_deposit(ext, forged_dir, 'forged_pkg')
    meta = ext.instance_variable_get(:@deposited_skillsets)['forged_pkg:agent-001']
    st = meta[:certificate][:summary][:statuses]
    assert('quality-shaped key dropped from projected statuses') { !st.key?('quality') }
    assert('nested/salt-bearing status value dropped') { !st.key?('identity.binding') }
    assert('non-vocabulary status value dropped') { !st.key?('revocation_status') }
    assert('valid CD-2 status survives projection') { st['derivation'] == 'anchor-pending' }

    addr = meta[:listing_address]
    html = body_of(ext.public_call(get_env("/place/web/skillsets/#{addr}")))
    assert('forged quality claim never rendered in provenance register') { !html.include?('excellent') }
    assert('hidden salt never rendered') { !html.include?('SECRET_SALT') }

    # Oversized identity → unavailable summary, never a partial render
    big = { 'claim_core' => { 'certificate_identity' => 'x' * 500, 'statuses' => {} } }
    big_dir = create_skillset_dir(File.join(tmpdir, 'src_big'), name: 'big_pkg',
      description: 'oversized identity', certificate: big)
    do_deposit(ext, big_dir, 'big_pkg')
    big_meta = ext.instance_variable_get(:@deposited_skillsets)['big_pkg:agent-001']
    assert('oversized certificate identity → summary unavailable (present, no summary)') {
      big_meta[:certificate][:present] == true && big_meta[:certificate][:summary].nil?
    }
  end

  section('6. Escaping (WC-1: extension owns rendering escape)') do
    xss_dir = create_skillset_dir(File.join(tmpdir, 'src3'), name: 'xss_pkg',
      description: '<script>alert(1)</script>')
    do_deposit(ext, xss_dir, 'xss_pkg')
    html = body_of(ext.public_call(get_env('/place/web/skillsets')))
    assert('depositor markup rendered inert') {
      !html.include?('<script>alert(1)</script>') && html.include?('&lt;script&gt;')
    }
  end

  section('7. Launch backfill (BL-WC-5)') do
    # Simulate a legacy state: strip certificate + address, then rebuild ext.
    state_path = File.join(KairosMcp.storage_dir, 'skillset_deposits', 'exchange_state.json')
    state = JSON.parse(File.read(state_path))
    state['deposited_skillsets'].each_value do |m|
      m.delete('certificate')
      m.delete('listing_address')
    end
    File.write(state_path, JSON.pretty_generate(state))

    ext2 = SkillsetExchange::PlaceExtension.new(StubRouter.new)
    metas2 = ext2.instance_variable_get(:@deposited_skillsets)
    assert('backfill restores listing addresses') {
      metas2.values.all? { |m| m[:listing_address].to_s.length == 16 }
    }
    assert('backfill re-derives certificate state from stored archives') {
      metas2['xss_pkg:agent-001'][:certificate][:present] == false
    }
    assert('backfill persists (state file updated)') {
      persisted = JSON.parse(File.read(state_path))
      persisted['deposited_skillsets'].values.all? { |m| m['listing_address'] }
    }
  end
end

# ============================================================================
puts ''
puts '=' * 60
puts "TOTAL: #{$pass_count} passed, #{$fail_count} failed"
puts '=' * 60
exit($fail_count > 0 ? 1 : 0)
