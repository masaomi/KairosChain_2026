# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'canon'
require_relative 'recorder'
require_relative 'certificate'

module KairosMcp
  module SkillSets
    module ChainDistillation
      # The distillation pipeline (design v0.5 CD-1..CD-6, slice 1).
      #
      # Ordering (CD-1/CD-6, later-cites-earlier, verdict-precedes-effect):
      #   1. active guard regime required — decline, never degrade (CD-1)
      #   2. designation validated against the source chain (closed-world)
      #   3. certificate identity pre-assigned, content-independent (CD-6)
      #   4. distillate crossing judged by the guard (verdict precedes the
      #      release effect; denial aborts with the guard's non-leaking
      #      report and nothing is recorded or released)
      #   5. CD-6 record written (commitments over distillate + claim core
      #      excluding the record citation; identity; predecessors)
      #   6. certificate finalized (cites the record + openings)
      #   7. certificate crossing judged by the guard (separate crossing,
      #      after the distillate's — CD-1 order)
      #   8. release (outputs returned / written; carrier envelope stored
      #      where a carrier is wired)
      #
      # Record-precedes-release is distiller-internal discipline; its
      # violation yields no certificate rather than a false one (CD-6
      # residual, stated in the design).
      module Distiller
        module_function

        class Declined < StandardError; end

        DISTILLATE_CROSSING  = 'cd_release_distillate'
        CERTIFICATE_CROSSING = 'cd_release_certificate'

        # Injectable seams (design-constraint tests): the gate registry,
        # the guard regime module, and the attestation carrier writer.
        @registry_class = nil
        @guard_regime = nil
        @carrier = nil

        class << self
          attr_writer :registry_class, :guard_regime, :carrier
        end

        def registry_class
          return @registry_class if @registry_class
          unless defined?(KairosMcp::ToolRegistry)
            # Template layout: 5 ups to the server root (impl review R1).
            require_relative '../../../../../lib/kairos_mcp/tool_registry'
          end
          KairosMcp::ToolRegistry
        end

        def guard_regime
          return @guard_regime if @guard_regime
          unless defined?(KairosMcp::SkillSets::ConfidentialityGuard::Regime)
            begin
              require_relative '../../../confidentiality_guard/lib/confidentiality_guard/regime'
            rescue LoadError
              return nil
            end
          end
          KairosMcp::SkillSets::ConfidentialityGuard::Regime
        end

        def carrier
          @carrier
        end

        # distill(designation:, distillate:, safety:) => {
        #   certificate:, record_block_index:, distillate_json: }
        # Raises Declined (CD-1, non-leaking) or the guard's
        # GateDeniedError (crossing denied; report is the guard's own).
        def distill(designation:, distillate:, safety: nil, attester_id: nil)
          regime = guard_regime
          # CD-1: certified distillation only under an active regime.
          # Declining names no content — only the fact and the remedy.
          unless regime && regime.active? && regime.policy
            raise Declined, JSON.generate(
              distiller: 'chain_distillation', verdict: 'decline',
              rule: 'cd-1/guard-regime-inactive',
              remedy: 'activate the confidentiality guard regime before distilling'
            )
          end
          policy_sha = regime.policy.sha256

          indices = validate_designation(designation)
          # The crossing presents the distillate ITSELF (stringified), not
          # a pre-serialized JSON string wrapped in another field: the
          # guard canonicalizes the presented arguments exactly once, so
          # detection patterns match the single-encoded form and the
          # commitment binds the very string the guard judged (impl
          # review R3 P1 — double encoding escaped inner quotes and
          # defeated content-class detection for structured distillates).
          presented = Canon.stringify(distillate)
          presented = { 'content' => presented } unless presented.is_a?(Hash)
          distillate_json = Canon.canonical(presented)
          certificate_identity = SecureRandom.uuid

          # Predecessor obligation (CD-6, evaluated at issuance): revoked
          # certificates with overlapping designation must be cited.
          # 4. Distillate crossing — verdict precedes the release effect.
          # The gate contract is deny-by-raise (ToolRegistry::GateDeniedError
          # aborts before any effect); a registry whose gates reported
          # denial by return value would violate the CG-2 contract this
          # code inherits, so no return value is consulted here.
          height_before = chain_height
          registry_class.run_gates(DISTILLATE_CROSSING, presented, safety)
          verdict_indices = ((height_before + 1)..chain_height).to_a

          # Predecessor obligation (CD-6, evaluated at issuance): computed
          # from the chain as it stands immediately before the CD-6 record
          # is written, so the verifier's strictly-before-the-record window
          # sees the same revocation set (impl review R1).
          entries = chain_entries
          predecessors = Certificate.revoked_overlapping_identities(
            entries, indices, chain_height + 1
          )

          distillate_commitment = Recorder.commitment(Recorder::ARTIFACT_DOMAIN, distillate_json)

          claim_core = Certificate.build_claim_core(
            certificate_identity: certificate_identity,
            chain_identity: chain_identity,
            head_index: head_block_index,
            head_hash: head_block_hash,
            designation: indices,
            guard_policy_sha256: policy_sha,
            distillate_commitment: distillate_commitment[:digest],
            verdict_block_indices: verdict_indices,
            predecessors: predecessors
          )
          claim_core_commitment = Recorder.commitment(Recorder::CLAIM_CORE_DOMAIN, Canon.canonical(claim_core))

          # 5. CD-6 record — before release, after the distillate verdict.
          record = Recorder.record_distillation(
            designation: indices,
            guard_policy_sha256: policy_sha,
            distillate_commitment: distillate_commitment[:digest],
            claim_core_commitment: claim_core_commitment[:digest],
            certificate_identity: certificate_identity,
            predecessors: predecessors
          )

          # 6. Finalize — cites only what precedes it (CD-6).
          certificate = Certificate.finalize(
            claim_core: claim_core,
            record_citation: { 'block_index' => record[:block_index], 'block_hash' => record[:block_hash] },
            openings: {
              'claim_core_salt' => claim_core_commitment[:salt],
              'distillate_salt' => distillate_commitment[:salt]
            }
          )

          # 7. Certificate crossing — separate, after the distillate
          # (CD-1). The certificate identity rides the call as an explicit
          # identifier so the guard's verdict record cites it (CD-1: "its
          # verdict record cites the certificate's identity").
          # The certificate crosses in the same single-encoded register:
          # its stringified form IS the presented arguments, plus the
          # identity identifier the guard's verdict record cites.
          registry_class.run_gates(
            CERTIFICATE_CROSSING,
            Canon.stringify(certificate).merge('certificate_identity' => certificate_identity),
            safety
          )

          # 8. Release: carrier envelope where wired (proof_id = the
          # pre-assigned identity — carrier identity is content-independent
          # and injectable), then return the artifacts.
          store_on_carrier(certificate, certificate_identity, distillate_commitment[:digest], attester_id)

          {
            certificate: certificate,
            record_block_index: record[:block_index],
            distillate_json: distillate_json
          }
        end

        # Closed-world designation: a non-empty list of existing source
        # chain record indices. Decline-not-coerce (impl review R1): only
        # Integer instances are admitted — "1.9" or "0x2" must decline,
        # never truncate or parse to a neighbouring index. Index 0 (the
        # genesis block, which carries no record entry) is not designable.
        def validate_designation(designation)
          indices = Array(designation)
          if indices.empty? || indices.any? { |v| !v.is_a?(Integer) }
            raise Declined, JSON.generate(
              distiller: 'chain_distillation', verdict: 'decline',
              rule: 'cd-6/designation-invalid',
              remedy: 'designation must be a non-empty list of integer record indices'
            )
          end
          height = chain_height
          missing = indices.reject { |i| i >= 1 && i <= height }
          unless missing.empty?
            raise Declined, JSON.generate(
              distiller: 'chain_distillation', verdict: 'decline',
              rule: 'cd-6/designation-absent-records',
              remedy: "designated records not on the source chain: #{missing.join(',')}"
            )
          end
          indices.uniq
        end

        # --- source-chain access helpers -------------------------------

        def chain
          Recorder.chain
        end

        # The real KairosChain::Chain exposes its block list as `#chain`
        # (attr_reader :chain); test fakes may expose `#blocks`. Reading
        # `#chain` FIRST pins the production contract (impl review R1 P0:
        # a respond_to?(:blocks)-only read silently saw an empty chain in
        # production and made every distillation decline).
        def blocks
          c = chain
          if c.respond_to?(:chain) && c.chain.is_a?(Array)
            c.chain
          elsif c.respond_to?(:blocks)
            Array(c.blocks)
          else
            []
          end
        end

        def chain_height
          b = blocks
          b.empty? ? -1 : block_index(b.last)
        end

        def head_block_index
          chain_height
        end

        def head_block_hash
          b = blocks
          b.empty? ? nil : block_hash(b.last)
        end

        # khab-1-shaped chain identity: the genesis block's hash under the
        # standard prefix (full HeadBinding integration is carrier wiring,
        # §8 backlog; the identity claim form is stable).
        def chain_identity
          b = blocks
          return nil if b.empty?
          "block1-sha256:#{block_hash(b.first)}"
        end

        # Parsed record entries by block index (first data item per block,
        # matching the Recorder's one-entry-per-block append convention).
        def chain_entries
          entries = {}
          blocks.each do |blk|
            data = blk.respond_to?(:data) ? blk.data : blk['data']
            first = Array(data).first
            next unless first.is_a?(String)
            begin
              entries[block_index(blk)] = JSON.parse(first)
            rescue JSON::ParserError
              next
            end
          end
          entries
        end

        def block_index(blk)
          blk.respond_to?(:index) ? blk.index : blk['index']
        end

        # Only a String is a block hash; Ruby's Object#hash (an Integer)
        # must never leak into an identity claim (impl review R1).
        def block_hash(blk)
          h = blk.is_a?(Hash) ? blk['hash'] : blk.hash
          h.is_a?(String) ? h : nil
        end

        # Block-hash map by index, for grounding and identity-binding
        # checks (cd_verify): index => hash string.
        def chain_block_hashes
          blocks.each_with_object({}) do |blk, acc|
            h = block_hash(blk)
            acc[block_index(blk)] = h if h
          end
        end

        def store_on_carrier(certificate, certificate_identity, distillate_digest, attester_id)
          return unless @carrier
          @carrier.call(
            proof_id: certificate_identity,
            attester_id: attester_id || 'chain_distillation',
            subject_ref: "distillate:#{distillate_digest}",
            claim: certificate
          )
        end
      end
    end
  end
end
