# frozen_string_literal: true

require 'json'
require 'digest'
require 'securerandom'
require_relative 'canon'

module KairosMcp
  module SkillSets
    module ChainDistillation
      # Constitutive distillation records (design v0.5 CD-6).
      #
      # The CD-6 record is written on the source chain BEFORE the outputs
      # are released: it carries the designated selection, the guard policy
      # version in force, salted commitments binding the distillate and the
      # certificate's claim core, and the pre-assigned certificate
      # identity. Records carry identifiers, versions, and commitments —
      # never content. Revocation is a recorded act on the same chain,
      # keyed to the certificate identity (effective across the entire
      # source chain regardless of which record a copy cites).
      #
      # Commitment construction follows the sdp-1 salted pattern
      # (domain-tagged SHA-256 over salt + canonical content, 16-byte hex
      # salt). Unlike the guard's decision commitments, the salts here are
      # DISCLOSED in the certificate as openings — but only over the
      # released artifacts themselves, which the certificate holder
      # already possesses (CD-2's openings clause).
      module Recorder
        module_function

        SALT_BYTES = 16 # 16 random bytes, hex-encoded (32 hex chars)
        ARTIFACT_DOMAIN   = 'cd-1/artifact'
        CLAIM_CORE_DOMAIN = 'cd-1/claim-core'
        DESIGNATION_DOMAIN = 'cd-1/designation'

        # Injectable chain factory so design-constraint tests can redirect
        # records away from the live chain store (same seam as the guard).
        @chain_factory = nil

        def chain_factory=(callable)
          @chain_factory = callable
        end

        def chain
          if @chain_factory
            @chain_factory.call
          else
            unless defined?(KairosMcp::KairosChain::Chain)
              # Template layout: lib/chain_distillation -> skillset root ->
              # skillsets -> templates -> server root (5 ups).
              require_relative '../../../../../lib/kairos_mcp/kairos_chain/chain'
            end
            # Fresh instance per call, matching the guard's Recorder: the
            # real Chain persists by rewriting the whole store from the
            # instance's in-memory view, so a memoized instance held across
            # another writer's append would clobber that writer's block on
            # its next save (impl review R3 P0 — the guard's distillate
            # verdict record was silently destroyed by the distiller's
            # stale instance). Reload-per-call keeps every writer's view
            # current; the remaining write-write race is the accepted
            # single-writer residual.
            KairosMcp::KairosChain::Chain.new
          end
        end

        def commitment(domain, content_json)
          salt = SecureRandom.hex(SALT_BYTES)
          { salt: salt, digest: digest(domain, salt, content_json) }
        end

        def digest(domain, salt, content_json)
          Digest::SHA256.hexdigest("#{domain}|#{salt}|#{content_json}")
        end

        def commitment_valid?(domain, digest_hex, salt, content_json)
          digest(domain, salt, content_json) == digest_hex
        end

        # Unsalted designation digest: the designation is a list of record
        # identifiers (not content), and the digest must be recomputable by
        # any chain-access verifier without an opening.
        def designation_digest(indices)
          Digest::SHA256.hexdigest("#{DESIGNATION_DOMAIN}|#{Canon.canonical(indices.sort)}")
        end

        # CD-6 record. Written before release; the claim-core commitment
        # covers the certificate's claim content excluding its citation of
        # this record, carrier lifecycle metadata, and commitment openings.
        def record_distillation(designation:, guard_policy_sha256:, distillate_commitment:,
                                claim_core_commitment:, certificate_identity:, predecessors:)
          entry = {
            'type'                  => 'cd_distillation',
            'designation'           => designation.sort,
            'designation_digest'    => designation_digest(designation),
            'guard_policy_sha256'   => guard_policy_sha256,
            'distillate_commitment' => distillate_commitment,
            'claim_core_commitment' => claim_core_commitment,
            'certificate_identity'  => certificate_identity,
            'predecessors'          => predecessors
          }
          block = append(entry)
          { entry: entry, block_index: block_index(block), block_hash: block_hash(block) }
        end

        # Closed revocation-reason vocabulary (CD-5 discipline: chain
        # entries carry identifiers, never operator-authored content — a
        # free-text reason would be a content channel onto the chain).
        REVOCATION_REASONS = %w[superseded defective withdrawn other].freeze

        # Revocation keyed to the certificate identity (CD-6): the chain
        # record is the authoritative revocation channel; a carrier mirror,
        # where wired, follows it and never the reverse.
        def record_revocation(certificate_identity:, reason:)
          reason_id = reason.to_s
          unless REVOCATION_REASONS.include?(reason_id)
            raise ArgumentError, "reason must be one of: #{REVOCATION_REASONS.join(', ')}"
          end
          entry = {
            'type'                 => 'cd_revocation',
            'certificate_identity' => certificate_identity,
            'reason'               => reason_id
          }
          block = append(entry)
          { entry: entry, block_index: block_index(block) }
        end

        def append(entry)
          chain.add_block([JSON.generate(entry)])
        end

        def block_index(block)
          block.respond_to?(:index) ? block.index : block['index']
        end

        # Only a String is a block hash (Object#hash is an Integer and
        # must never be recorded as one — impl review R1).
        def block_hash(block)
          h = block.is_a?(Hash) ? block['hash'] : block.hash
          h.is_a?(String) ? h : nil
        end
      end
    end
  end
end
