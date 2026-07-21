# frozen_string_literal: true
#
# Stage A of the inaugural head-binding anchor (khab-1): build the head binding
# from the LOCAL internal chain (MasaChain). Run at the project root on the
# operator workstation — the internal chain lives here, not on the Meeting
# Place server:
#
#   ruby docker/scripts/khab_build_binding.rb            # print binding JSON
#   ruby docker/scripts/khab_build_binding.rb --coherence # + self-check + summary
#
# The printed compact JSON is the value to pass as KHAB_BINDING_JSON to
# anchor_inaugural_head_binding_khab1.rb (Stage B, runs in the server
# container). Nothing here writes anywhere.

require 'json'

root = File.expand_path('../..', __dir__)
$LOAD_PATH.unshift File.join(root, '.kairos', 'skillsets', 'synoptis', 'lib')
require 'synoptis/anchoring/head_binding'

HB = Synoptis::Anchoring::HeadBinding

chain_path = File.join(root, '.kairos', 'storage', 'blockchain.json')
blocks = HB.load_blocks(chain_path)
binding = HB.build(blocks)

if ARGV.include?('--coherence')
  coh = HB.coherence(binding, blocks)
  warn "chain            = #{chain_path}"
  warn "blocks           = #{blocks.size} (head index #{binding['chain_head_index']})"
  warn "records          = #{binding['tree_size']}"
  warn "chain_identity   = #{binding['chain_identity']}"
  warn "cumulative_root  = #{binding['cumulative_root']}"
  warn "convention       = #{binding['convention']} (sha256 #{binding['convention_sha256'][0, 12]}…)"
  warn "coherence        = #{coh[:coherent] ? 'OK' : "MISMATCH #{coh[:mismatches]}"}"
  abort '[fatal] coherence self-check failed' unless coh[:coherent]
end

puts JSON.generate(binding)
