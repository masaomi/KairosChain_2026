#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================================
# Slice 2 / S2.3: ANC-7 public verification view (WebRouter) — local prototype
# ============================================================================
# The public unauthenticated verification view over anchor entries. Loads the
# .kairos runtime copy of hestia (which carries the full web/ view tree).
#
# Usage:  ruby test_hestia_anchor_web.rb
# ============================================================================

ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.join(ROOT, '.kairos/skillsets/mmp/lib')
$LOAD_PATH.unshift File.join(ROOT, '.kairos/skillsets/hestia/lib')

# Minimal Rack::Utils.parse_query shim so the WebRouter can be exercised without
# bundler (the production server has the real rack gem). Only parse_query is used.
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
            acc[CGI.unescape(k)] = CGI.unescape(v.to_s)
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
require 'hestia'
require 'hestia/public_rate_limiter'
require 'hestia/public_presenter'
require 'hestia/import_command_generator'
require 'hestia/web_router'
require 'tmpdir'
require 'fileutils'
require 'digest'

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

def get(router, path, query = '')
  env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => path, 'QUERY_STRING' => query,
          'REMOTE_ADDR' => '127.0.0.1' }
  status, _headers, body = router.call(env)
  [status, Array(body).join]
end

Dir.mktmpdir do |dir|
  HOST = 'meeting.genomicschain.io'
  log = Hestia::Anchoring::Log.new(storage_path: File.join(dir, 'log.json'),
                                   operator_id: "operator:#{HOST}")
  board = Hestia::Anchoring::DepositBoard.new(log: log,
                                              attestation_store_path: File.join(dir, 'att.json'))
  op = Hestia::Anchoring::WritePath::Principal.new(peer_id: "operator:#{HOST}", verified: true)

  digest = Digest::SHA256.hexdigest('the paper bytes')
  dep = board.deposit_by_reference(
    principal: op, digest: digest,
    source_id: "place://#{HOST}/anchor/constitutive-note-v1_7",
    anchor_type: 'custom.constitutive_note',
    retrieval_pointer: 'https://doi.org/10.5281/zenodo.100'
  )
  board.attest(deposit_id: dep.deposit_id, principal: op, claim_type: 'correspondence',
               note: 'digest matches the Zenodo file')

  router = Hestia::WebRouter.new(
    skill_board: nil, agent_registry: nil,
    config: { 'name' => 'GenomicsChain Meeting Place', 'place_host' => HOST },
    anchor_log: log, anchor_board: board
  )

  puts "\n[1] /place/web/anchor/<entry_hash> renders the verification view"
  st, html = get(router, "/place/web/anchor/#{dep.deposit_id}")
  assert('200 OK') { st == 200 }
  assert('shows the digest') { html.include?(digest) }
  assert('shows chain position #0') { html.include?('#0') }
  assert('shows depositor') { html.include?("operator:#{HOST}") }
  assert('shows same-party public reference point') { html.include?('Public reference point') }
  assert('shows algorithm') { html.include?('sha256') }
  assert('renders the DOI as a link') { html.include?('href="https://doi.org/10.5281/zenodo.100"') }
  assert('shows the correspondence attestation') { html.include?('correspondence') }
  assert('states the honest proof scope') { html.include?('does NOT prove') }
  assert('states the ANC-8 relation disclosure') { html.include?('identity issuance') }

  puts "\n[2] /place/web/anchor/<slug> resolves the content-independent address"
  st2, html2 = get(router, '/place/web/anchor/constitutive-note-v1_7')
  assert('slug resolves via source_id (200)') { st2 == 200 }
  assert('slug view shows the same digest') { html2.include?(digest) }

  puts "\n[3] /place/web/verify?digest=<hex>"
  st3, html3 = get(router, '/place/web/verify', "digest=#{digest}")
  assert('verify 200') { st3 == 200 }
  assert('verify lists the record') { html3.include?('match this digest') }
  assert('verify links to the anchor detail') { html3.include?("/place/web/anchor/#{dep.deposit_id}") }

  st3b, html3b = get(router, '/place/web/verify', "digest=#{'0' * 64}")
  assert('unknown digest -> no anchor recorded') { html3b.include?('No anchor recorded') }

  st3c, html3c = get(router, '/place/web/verify')
  assert('empty verify shows the form') { st3c == 200 && html3c.include?('<form') }
  assert('verify page discloses the write budget / Sybil limit (ANC-9)') do
    html3.include?('Sybil') && html3.include?('identity issuance')
  end

  puts "\n[4] Not-found & disabled behavior"
  st4, = get(router, '/place/web/anchor/deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef')
  assert('unknown 64-hex anchor -> 404') { st4 == 404 }
  st4b, = get(router, '/place/web/anchor/no-such-slug')
  assert('unknown slug -> 404') { st4b == 404 }
  no_anchor_router = Hestia::WebRouter.new(skill_board: nil, agent_registry: nil, config: {})
  st4c, = get(no_anchor_router, "/place/web/anchor/#{dep.deposit_id}")
  assert('anchor route 404s when capability not wired') { st4c == 404 }

  puts "\n[5] XSS containment: surfaced fields are HTML-escaped"
  evil = Hestia::Anchoring::WritePath::Principal.new(peer_id: 'peer<script>alert(1)</script>', verified: true)
  edep = board.deposit_by_reference(principal: evil, digest: Digest::SHA256.hexdigest('evil'),
                                    source_id: "place://#{HOST}/anchor/evil",
                                    retrieval_pointer: 'https://x.example/"><b>x</b>')
  _, ehtml = get(router, "/place/web/anchor/#{edep.deposit_id}")
  assert('depositor script tag is escaped') { ehtml.include?('&lt;script&gt;') && !ehtml.include?('<script>alert(1)') }
  assert('pointer double-quote is escaped in href') { !ehtml.include?('href="https://x.example/"><b>') }

  puts "\n[6] Withdrawn entry: digest readable, pointer suppressed"
  log.append_withdrawal(target: dep.deposit_id, withdrawer: "operator:#{HOST}")
  _, whtml = get(router, "/place/web/anchor/#{dep.deposit_id}")
  assert('withdrawn notice shown') { whtml.include?('withdrawn') || whtml.include?('Withdrawn') }
  assert('withdrawn view keeps digest') { whtml.include?(digest) }
  assert('withdrawn view suppresses DOI link') { !whtml.include?('href="https://doi.org/10.5281/zenodo.100"') }
end

puts "\n" + ('=' * 60)
puts "RESULT: #{$pass} passed, #{$fail} failed"
puts('=' * 60)
exit($fail.zero? ? 0 : 1)
