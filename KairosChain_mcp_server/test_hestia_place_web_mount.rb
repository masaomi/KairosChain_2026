#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================================
# Part C: PlaceRouter mounts the public WebRouter + anchor store (Option B)
# ============================================================================
# Verifies the SkillSet-owned mount: PlaceRouter#call delegates /place/web/*
# and /place/api/v1/* to a WebRouter it constructs in #start, WITHOUT any core
# HTTP-server change. This closes the "WebRouter is not mounted in any release"
# gap. The key handoff assertion is that the public surface returns 200/404,
# not 401 (it is no longer behind the authenticated PlaceRouter flow).
#
# Usage:  ruby test_hestia_place_web_mount.rb
# ============================================================================

ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.join(ROOT, '.kairos/skillsets/mmp/lib')
$LOAD_PATH.unshift File.join(ROOT, '.kairos/skillsets/hestia/lib')

# Minimal Rack::Utils.parse_query shim so the WebRouter runs without bundler
# (the production server has the real rack gem). Only parse_query is used.
require 'tmpdir'
require 'fileutils'
unless begin; require 'rack/utils'; rescue LoadError; false; end
  shim_dir = Dir.mktmpdir('rack_shim')
  FileUtils.mkdir_p(File.join(shim_dir, 'rack'))
  File.write(File.join(shim_dir, 'rack', 'utils.rb'), <<~RUBY)
    require 'cgi'
    module Rack
      module Utils
        module_function
        def parse_query(qs, delim = '&')
          (qs || '').split(delim).each_with_object({}) do |pair, acc|
            k, v = pair.split('=', 2)
            next if k.nil? || k.empty?
            acc[CGI.unescape(k)] = CGI.unescape(v || '')
          end
        end
      end
    end
  RUBY
  $LOAD_PATH.unshift(shim_dir)
  require 'rack/utils'
end

require 'kairos_mcp'
require 'mmp'
require 'mmp/meeting_session_store'
require 'hestia'
require 'json'
require 'digest'
require 'stringio'

$pass = 0
$fail = 0
def assert(msg)
  ok = yield
  puts(ok ? "  PASS: #{msg}" : "  FAIL: #{msg}")
  ok ? $pass += 1 : $fail += 1
rescue StandardError => e
  puts "  FAIL: #{msg} (#{e.class}: #{e.message})"
  $fail += 1
end

def section(title)
  puts "\n#{title}"
  yield
end

def mock_identity(instance_id: 'place-self-001')
  MMP::Identity.new(config: {
    'enabled' => true,
    'identity' => { 'name' => 'WebMountPlace', 'instance_id' => instance_id },
    'capabilities' => { 'supported_actions' => %w[meeting_protocol skill_exchange] }
  })
end

def env(method, path, query: '')
  { 'REQUEST_METHOD' => method, 'PATH_INFO' => path, 'QUERY_STRING' => query,
    'REMOTE_ADDR' => '127.0.0.1', 'rack.input' => StringIO.new('') }
end

def get(router, path, query = '')
  status, _headers, body = router.call(env('GET', path, query: query))
  [status, Array(body).join]
end

HOST = 'meeting.test'

# Build a started PlaceRouter with the given meeting_place overrides.
def start_router(dir, overrides)
  base = {
    'name' => 'Web Mount Place',
    'registry_path' => File.join(dir, 'agents.json'),
    'deposit_storage_path' => File.join(dir, 'skill_board.json')
  }
  config = { 'meeting_place' => base.merge(overrides) }
  router = Hestia::PlaceRouter.new(config: config)
  router.start(identity: mock_identity, session_store: MMP::MeetingSessionStore.new)
  router
end

puts '=' * 64
puts 'Part C: PlaceRouter public web + anchor mount (Option B)'
puts '=' * 64

# --------------------------------------------------------------------------
section('[A] web_ui + anchoring enabled → public surface served (200/404, not 401)') do
  Dir.mktmpdir do |dir|
    router = start_router(dir,
      'web_ui' => { 'enabled' => true, 'place_host' => HOST },
      'anchoring' => {
        'enabled' => true,
        'log_path' => File.join(dir, 'anchor_log.json'),
        'attestation_store_path' => File.join(dir, 'anchor_att.json')
      })

    assert('web_router constructed') { !router.web_router.nil? }
    assert('anchor_log exposed') { !router.anchor_log.nil? }
    assert('anchor_board exposed') { !router.anchor_board.nil? }
    # The place self id (ANC-5/8 control boundary) is the generated instance id
    # (a 16-hex digest), not the config literal.
    assert('operator_id is the place self id (16-hex boundary)') do
      router.anchor_log.operator_id.to_s.match?(/\A[a-f0-9]{16}\z/)
    end

    st, html = get(router, '/place/web/')
    assert('GET /place/web/ → 200 (catalog served, was 401)') { st == 200 }

    st, _ = get(router, '/place/web/about')
    assert('GET /place/web/about → 200') { st == 200 }

    st, json = get(router, '/place/api/v1/catalog')
    assert('GET /place/api/v1/catalog → 200') { st == 200 }
    assert('catalog is JSON') { JSON.parse(json).key?('entries') }

    st, html = get(router, '/place/web/verify')
    assert('GET /place/web/verify (empty) → 200') { st == 200 }
    assert('verify shows Sybil disclosure') { html.include?('Full Sybil resistance') }

    # Deposit an anchor as the operator (same-party / budget-exempt).
    op = Hestia::Anchoring::WritePath::Principal.new(peer_id: router.anchor_log.operator_id, verified: true)
    digest = Digest::SHA256.hexdigest('the constitutive note bytes v1.7')
    slug = 'constitutive-note-v1_7'
    dep = router.anchor_board.deposit_by_reference(
      principal: op, digest: digest,
      source_id: "place://#{HOST}/anchor/#{slug}",
      anchor_type: 'custom.constitutive_note',
      retrieval_pointer: 'doi:10.5281/zenodo.123456'
    )
    router.anchor_board.attest(deposit_id: dep.deposit_id, principal: op,
                               claim_type: 'correspondence', note: 'digest matches Zenodo file')

    st, html = get(router, '/place/web/verify', "digest=#{digest}")
    assert('verify?digest=<hex> → 200 lists the record') { st == 200 && html.include?(digest) }

    st, html = get(router, "/place/web/anchor/#{slug}")
    assert('GET /place/web/anchor/<slug> → 200 (stable citable view)') { st == 200 }
    assert('anchor view shows the digest') { html.include?(digest) }
    assert('anchor view links the DOI') { html.include?('doi.org/10.5281/zenodo.123456') }

    st, _ = get(router, "/place/web/anchor/#{dep.deposit_id}")
    assert('GET /place/web/anchor/<entry_hash> → 200') { st == 200 }

    st, _ = get(router, '/place/web/anchor/no-such-reference')
    assert('GET /place/web/anchor/<unknown> → 404 (NOT 401)') { st == 404 }
  end
end

# --------------------------------------------------------------------------
section('[B] auth flow intact: web delegation does not swallow authenticated routes') do
  Dir.mktmpdir do |dir|
    router = start_router(dir, 'web_ui' => { 'enabled' => true, 'place_host' => HOST })

    st, _ = get(router, '/place/v1/info')
    assert('GET /place/v1/info still 200 (unauth endpoint)') { st == 200 }

    st, _ = get(router, '/place/v1/agents')
    assert('GET /place/v1/agents without token still 401') { st == 401 }

    # A POST to the web prefix is delegated to WebRouter (GET-only → 405),
    # NOT passed to the authenticated flow.
    status, _h, _b = router.call(env('POST', '/place/web/'))
    assert('POST /place/web/ → 405 (WebRouter GET-only, not auth 401)') { status == 405 }
  end
end

# --------------------------------------------------------------------------
section('[C] anchoring disabled → catalog served, anchor routes 404') do
  Dir.mktmpdir do |dir|
    router = start_router(dir,
      'web_ui' => { 'enabled' => true, 'place_host' => HOST },
      'anchoring' => { 'enabled' => false })

    assert('anchor_log nil when anchoring disabled') { router.anchor_log.nil? }
    assert('anchor_board nil when anchoring disabled') { router.anchor_board.nil? }

    st, _ = get(router, '/place/web/')
    assert('catalog still 200') { st == 200 }

    st, _ = get(router, '/place/web/verify')
    assert('GET /place/web/verify → 404 (capability not present)') { st == 404 }
  end
end

# --------------------------------------------------------------------------
section('[D] web_ui disabled → public surface not mounted (falls through to auth)') do
  Dir.mktmpdir do |dir|
    router = start_router(dir, 'web_ui' => { 'enabled' => false })

    assert('web_router nil when web_ui disabled') { router.web_router.nil? }

    st, _ = get(router, '/place/web/')
    assert('GET /place/web/ → 401 (no web router, hits auth flow)') { st == 401 }
  end
end

puts "\n#{'=' * 64}"
puts "RESULT: #{$pass} passed, #{$fail} failed"
puts '=' * 64
exit($fail.zero? ? 0 : 1)
