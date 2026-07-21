# frozen_string_literal: true
#
# Stage B of the inaugural head-binding anchor (khab-1, MPR-1..9): one-off
# operator deposit of the FIRST head-binding anchor for the production
# MasaChain, on the same anchor chain that holds the constitutive-note
# document anchors (#0 v1.7, #1 v1.8). Sibling of
# anchor_inaugural_constitutive_note_v18.rb; same container invocation:
#
#   BINDING=$(ruby docker/scripts/khab_build_binding.rb --coherence)   # Stage A, local
#   docker run --rm -i --volumes-from kairos-meeting-place \
#     -e KAIROS_DATA_DIR=/app/.kairos -e MODE=inspect \
#     -e KHAB_BINDING_JSON="$BINDING" \
#     docker-meeting-place:latest ruby - < docker/scripts/anchor_inaugural_head_binding_khab1.rb
#
# MODE=inspect : resolve operator id, validate the binding, report whether a
#                chain_head anchor for this chain identity already exists.
#                Writes NOTHING.
# MODE=deposit : append the head-binding anchor entry. Idempotent (skips when
#                an anchor with the same cumulative_root is already present).
#
# PRECONDITION: the server's synoptis lib must already include the head-anchor
# slice (cumulative_commitment/head_binding + extended containment); deploy the
# updated skillset to the kairos-data volume BEFORE running MODE=deposit.
#
# Design notes (frozen v0.3):
#   - The entry digest IS the binding's cumulative_root (khab-1 §6), and the
#     binding travels INSIDE the committed body (MPR-1).
#   - This inaugural anchor gives every existing MasaChain record its first
#     temporal bound ("no later than this anchor"); the pre-anchor backdating
#     window stays honestly unbounded (MPR-7).
#   - Cadence/automation of subsequent head anchors is L2 and deliberately NOT
#     set up here (MPR-5).

require 'json'

MODE    = ENV.fetch('MODE', 'inspect')
abort "[fatal] MODE must be 'inspect' or 'deposit', got #{MODE.inspect}" unless %w[inspect deposit].include?(MODE)
DATADIR = ENV.fetch('KAIROS_DATA_DIR', '/app/.kairos')
%w[mmp synoptis].each { |ss| $LOAD_PATH.unshift File.join(DATADIR, 'skillsets', ss, 'lib') }

require 'kairos_mcp'
require 'mmp'
require 'synoptis'
require 'synoptis/anchoring/head_binding'

SOURCE = 'place://meeting.genomicschain.io/anchor/masachain-head'

raw = ENV['KHAB_BINDING_JSON'].to_s
abort '[fatal] KHAB_BINDING_JSON not set (run Stage A: khab_build_binding.rb)' if raw.strip.empty?
binding = begin
  JSON.parse(raw)
rescue JSON::ParserError => e
  abort "[fatal] KHAB_BINDING_JSON is not valid JSON: #{e.message}"
end
abort "[fatal] KHAB_BINDING_JSON must be a JSON object, got #{binding.class}" unless binding.is_a?(Hash)

# The container must hold the SAME convention definition the binding commits;
# otherwise the deposit would commit an unresolvable convention (MPR-3).
# Checked BEFORE validate! (which also enforces it) so a stale container gets
# this actionable message instead of a raw BindingError backtrace.
local_conv = Synoptis::Anchoring::HeadBinding.convention_sha256
if binding['convention_sha256'] != local_conv
  abort "[fatal] convention_sha256 mismatch: binding #{binding['convention_sha256']} vs " \
        "container definition #{local_conv} — deploy matching synoptis lib first"
end
Synoptis::Anchoring::HeadBinding.validate!(binding)

storage = KairosMcp.storage_dir
log_path = File.join(storage, 'hestia_anchor_log.json')

mmp_config = MMP.load_config
identity_self_id = MMP::Identity.new(config: mmp_config).introduce.dig(:identity, :instance_id)
registry_self_id = begin
  reg_path = File.join(storage, 'agent_registry.json')
  raw_reg = JSON.parse(File.read(reg_path))
  agents = raw_reg.is_a?(Hash) ? (raw_reg['agents'] || raw_reg.values.find { |v| v.is_a?(Array) } || raw_reg) : raw_reg
  list = agents.is_a?(Hash) ? agents.values : Array(agents)
  self_entry = list.find { |a| a.is_a?(Hash) && (a['is_self'] || a[:is_self]) }
  self_entry && (self_entry['id'] || self_entry[:id])
rescue StandardError => e
  warn "[warn] could not read registry self id: #{e.class}: #{e.message}"
  nil
end

operator_id = registry_self_id || identity_self_id
if registry_self_id && identity_self_id && registry_self_id != identity_self_id
  warn "[warn] self id mismatch (registry vs computed). Using registry id: #{operator_id}"
end
abort '[fatal] could not resolve operator/self id' if operator_id.to_s.strip.empty?

log = Synoptis::Anchoring::Log.new(storage_path: log_path, operator_id: operator_id)
# Idempotency is scoped to head anchors carrying EXACTLY this binding: an
# unrelated document anchor with a coinciding digest must not suppress the
# deposit, and a chain_head anchor with the same root but a DIFFERENT binding
# is an integrity anomaly that must stop the run, not be silently skipped.
head_anchors = log.find_by_digest(binding['cumulative_root']).select do |e|
  e.anchor? && e.body['anchor_type'] == 'chain_head' && e.head_binding
end
existing = head_anchors.select { |e| e.head_binding == binding }
divergent = head_anchors - existing
unless divergent.empty?
  abort "[fatal] existing chain_head anchor(s) #{divergent.map(&:entry_hash).join(', ')} commit the " \
        'same cumulative_root with a DIFFERENT head_binding — investigate before depositing'
end

warn "storage          = #{storage}"
warn "operator_id      = #{operator_id}"
warn "chain length     = #{log.length} (this deposits at ##{log.length})"
warn "chain_identity   = #{binding['chain_identity']}"
warn "cumulative_root  = #{binding['cumulative_root']}"
warn "tree_size        = #{binding['tree_size']} (head block ##{binding['chain_head_index']})"
warn "already anchored?  #{existing.size} entr#{existing.size == 1 ? 'y' : 'ies'} with this root"

if MODE == 'inspect'
  warn 'MODE=inspect — no write performed. Re-run with MODE=deposit to append.'
  exit 0
end

if existing.any?
  warn "head binding already anchored (#{existing.first.entry_hash}); nothing to do."
  entry_hash = existing.first.entry_hash
else
  budget = Synoptis::Anchoring::WriteBudget.new(operator_id: operator_id)
  board  = Synoptis::Anchoring::DepositBoard.new(
    log: log,
    attestation_store_path: File.join(storage, 'hestia_anchor_attestations.json'),
    budget: budget
  )
  principal = Synoptis::Anchoring::WritePath::Principal.new(peer_id: operator_id, verified: true)
  dep = board.deposit_by_reference(
    principal: principal,
    digest: binding['cumulative_root'],
    source_id: SOURCE,
    anchor_type: 'chain_head',
    head_binding: binding
  )
  entry_hash = dep.deposit_id
  warn "deposited: entry_hash=#{entry_hash}"
end

rec = Synoptis::Anchoring::PublicVerifier.new(log: log).get(entry_hash)
abort '[fatal] post-deposit record not resolvable' unless rec
warn "relation = #{rec[:relation]} (expect same_party)"
puts JSON.pretty_generate(rec)
