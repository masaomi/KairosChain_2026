# frozen_string_literal: true
#
# One-off operator deposit of the constitutive-note v1.8 anchor.
# Sibling of anchor_inaugural_constitutive_note_v17.rb, updated for the S1-S3
# anchor migration: the anchor store now lives in Synoptis::Anchoring (append-line
# hash-chained log), NOT Hestia::Anchoring (the v17 script's namespace). The
# DepositBoard API (deposit_by_reference + attest) is unchanged by the migration,
# so this is a namespace swap + fresh frozen facts.
#
# Runs INSIDE a container that has the kairos-data volume mounted at /app/.kairos
# (same libs + storage the running Meeting Place uses), e.g.:
#
#   docker run --rm -i --volumes-from kairos-meeting-place \
#     -e KAIROS_DATA_DIR=/app/.kairos -e MODE=inspect \
#     docker-meeting-place:latest ruby - < this_script.rb
#
# MODE=inspect : print the resolved operator/self id (two independent sources) and
#                whether the source_id is already anchored. Writes NOTHING.
# MODE=deposit : append the anchor entry + a correspondence attestation, then print
#                the resolved public record. Idempotent (skips if already present).
#
# The anchor log is append-only: get the operator id right in `inspect` BEFORE
# depositing, so the entry is same-party ("public reference point"), not foreign.
# v1.7 sits at chain position #0; this appends v1.8 at #1 on the SAME chain.

require 'json'

MODE   = ENV.fetch('MODE', 'inspect')
DATADIR = ENV.fetch('KAIROS_DATA_DIR', '/app/.kairos')
%w[mmp synoptis].each { |ss| $LOAD_PATH.unshift File.join(DATADIR, 'skillsets', ss, 'lib') }

require 'kairos_mcp'
require 'mmp'
require 'synoptis'

# --- Frozen facts from the v1.8 deposit. Do not edit. -------------------------
DIGEST = '2ae235cf07e63de7243d44720db0a23d49f5fa3d2771e86d199a7f613bd62224'
SOURCE = 'place://meeting.genomicschain.io/anchor/constitutive-note-v1.8'
DOI    = 'doi:10.5281/zenodo.21459275'
NOTE   = 'SHA-256 of constitutive-note v1.8 matches the Zenodo deposit ' \
         '(DOI 10.5281/zenodo.21459275); constitutively recorded on MasaChain ' \
         'block 296; e2e re-hash from public Zenodo verified 2026-07-20.'
# ------------------------------------------------------------------------------

storage = KairosMcp.storage_dir
log_path = File.join(storage, 'hestia_anchor_log.json')          # filename unchanged by S1-S3
att_path = File.join(storage, 'hestia_anchor_attestations.json') # correspondence store, unchanged

# (1) self id as the SERVER computes it (auto_start_meeting_place).
mmp_config = MMP.load_config
identity_self_id = MMP::Identity.new(config: mmp_config).introduce.dig(:identity, :instance_id)

# (2) self id as the SERVER actually registered it (agent_registry is_self).
registry_self_id = begin
  reg_path = File.join(storage, 'agent_registry.json')
  raw = JSON.parse(File.read(reg_path))
  agents = raw.is_a?(Hash) ? (raw['agents'] || raw.values.find { |v| v.is_a?(Array) } || raw) : raw
  list = agents.is_a?(Hash) ? agents.values : Array(agents)
  self_entry = list.find { |a| a.is_a?(Hash) && (a['is_self'] || a[:is_self]) }
  self_entry && (self_entry['id'] || self_entry[:id])
rescue StandardError => e
  warn "[warn] could not read registry self id: #{e.class}: #{e.message}"
  nil
end

warn "storage         = #{storage}"
warn "log_path        = #{log_path}"
warn "identity self_id= #{identity_self_id.inspect}"
warn "registry self_id= #{registry_self_id.inspect}"

# Prefer the registry id (what the server actually uses); fall back to computed.
operator_id = registry_self_id || identity_self_id
if registry_self_id && identity_self_id && registry_self_id != identity_self_id
  warn "[warn] self id mismatch (registry vs computed). Using registry id: #{operator_id}"
end
abort '[fatal] could not resolve operator/self id' if operator_id.to_s.strip.empty?

log = Synoptis::Anchoring::Log.new(storage_path: log_path, operator_id: operator_id)
already = log.find_by_source_id(SOURCE).select(&:anchor?)
warn "already anchored at source_id? #{already.size} entr#{already.size == 1 ? 'y' : 'ies'}"
warn "current chain length = #{log.length} (v1.7 = #0; this deposits at ##{log.length})"

if MODE == 'inspect'
  warn "MODE=inspect — no write performed. Re-run with MODE=deposit to append."
  exit 0
end

budget = Synoptis::Anchoring::WriteBudget.new(operator_id: operator_id)
board  = Synoptis::Anchoring::DepositBoard.new(
  log: log, attestation_store_path: att_path, budget: budget
)
principal = Synoptis::Anchoring::WritePath::Principal.new(peer_id: operator_id, verified: true)

if already.any?
  warn "deposit already present (#{already.first.entry_hash}); skipping deposit_by_reference."
  deposit_id = already.first.entry_hash
else
  dep = board.deposit_by_reference(
    principal: principal, digest: DIGEST, source_id: SOURCE,
    anchor_type: 'custom.constitutive_note', retrieval_pointer: DOI
  )
  deposit_id = dep.deposit_id
  warn "deposited: entry_hash=#{deposit_id}"
end

# Attest correspondence unless an identical claim already exists (idempotent).
existing_att = board.attestations_for(deposit_id).reject { |a| a['withdrawn'] }
                    .any? { |a| a['claim_type'] == 'correspondence' && a['attester'] == operator_id }
if existing_att
  warn 'correspondence attestation already present; skipping attest.'
else
  board.attest(deposit_id: deposit_id, principal: principal,
               claim_type: 'correspondence', note: NOTE)
  warn 'attested: correspondence'
end

# Verify via the SAME PublicVerifier the ANC-7 view uses.
rec = Synoptis::Anchoring::PublicVerifier.new(log: log, board: board).by_source_id(SOURCE).first
abort '[fatal] post-deposit record not resolvable by source_id' unless rec
warn "relation = #{rec[:relation]} (expect same_party)"
puts JSON.pretty_generate(rec)
