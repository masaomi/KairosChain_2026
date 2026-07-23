# frozen_string_literal: true

require 'json'
require_relative 'distiller'

module KairosMcp
  module SkillSets
    module ChainDistillation
      # Slice-2 carrier wiring: the slice-1 carrier seam becomes live
      # here — design v0.4 §1 names the attestation carrier as the
      # presence-visibility channel this slice adds under CD-8.
      #
      # The carrier is the shipped synoptis attestation structure consumed
      # as-is: a ProofEnvelope with the INJECTED, content-independent
      # proof_id = certificate_identity (CD-6), stored through the shipped
      # registry. No behavioral change to the carrier is authored here —
      # the parent design's depends_on re-open condition is not triggered.
      # The envelope is written at issuance and is source-local; outward
      # reachability is a separate property that begins at deposit
      # approval (CD-8, exposure marker in the Depositor; the remote query
      # surface itself is BL-S2-7).
      module CarrierWiring
        module_function

        # Injectable registry seam (design-constraint tests). Production
        # resolves the shipped synoptis file registry under the data dir.
        @registry = nil

        class << self
          attr_writer :registry
        end

        # Explicitly setting the seam to false simulates "no carrier
        # reachable" in tests; nil falls through to the shipped default.
        def registry
          return nil if @registry == false
          @registry || default_registry
        end

        # Wire Distiller.@carrier to the synoptis registry. Idempotent;
        # returns false (leaving the seam untouched) when synoptis is not
        # installed — DISTILLATION then proceeds carrier-less exactly as
        # in slice 1 (in-instance certification is not degraded), but
        # DEPOSIT under slice 2 requires the carrier and declines without
        # it (CD-8: neither form is optional — enforced at the deposit
        # admission, see Depositor).
        def wire!(registry: nil)
          # Availability is checked WITHOUT construction; the registry
          # itself (whose construction may create its data directory) is
          # resolved lazily INSIDE the lambda — i.e. at issuance step 8,
          # after every verdict — so wiring at tool load causes no
          # persistent effect before judgment (impl review R6 (b)).
          return false unless registry || carrier_available?
          injected = registry
          Distiller.carrier = lambda do |proof_id:, attester_id:, subject_ref:, claim:|
            reg = injected || self.registry
            unless defined?(Synoptis::ProofEnvelope)
              require_relative '../../../synoptis/lib/synoptis/proof_envelope'
            end
            envelope = Synoptis::ProofEnvelope.new(
              proof_id: proof_id,
              attester_id: attester_id.to_s,
              subject_ref: subject_ref.to_s,
              claim: JSON.generate(claim),
              ttl: nil,
              timestamp: Time.now.utc.iso8601
            )
            reg.store_proof(envelope)
          end
          true
        end

        # CD-8 at the deposit boundary, ADMISSION half: the mirror form
        # must be reachable for a certificate to distribute. STRICTLY
        # read-only — admission writes nothing and creates nothing
        # (verdict precedes every effect, CD-9; impl review R4: even the
        # default registry's directory creation must not happen before
        # the verdict, so availability is checked WITHOUT instantiation).
        def require_carrier!
          return true if carrier_available?
          raise Distiller::Declined, JSON.generate(
            distiller: 'chain_distillation', verdict: 'decline',
            rule: 'cd-8/carrier-unavailable',
            remedy: 'the attestation carrier is required for distribution; install/enable synoptis before depositing'
          )
        end

        # Availability without side effects: an injected seam answers
        # directly; the default answers iff the synoptis code loads —
        # no registry object (and no data directory) is created here.
        def carrier_available?
          return false if @registry == false
          return true if @registry
          require_relative '../../../synoptis/lib/synoptis/proof_envelope'
          require_relative '../../../synoptis/lib/synoptis/registry/file_registry'
          true
        rescue LoadError
          false
        end

        # CD-8 at the deposit boundary, POST-VERDICT half: runs only after
        # the certificate verified and the crossing was approved. Backfills
        # the envelope for certificates issued before the wiring was live;
        # an existing envelope whose carried claim is not THIS certificate
        # declines loudly rather than silently shadowing it (a planted
        # pre-seeded proof must not become the exposed carrier answer).
        def ensure_envelope!(certificate, identity, attester_id: 'chain_distillation')
          require_carrier!
          # Post-verdict: instantiating the default registry (which may
          # create its data directory) is an approved effect here.
          reg = registry
          claim_json = JSON.generate(certificate)
          existing = reg.find_proof(identity)
          if existing
            # Semantic comparison in canonical form: byte order of JSON
            # keys must not fabricate a mismatch (impl review R3 — a
            # foreign serializer reordering keys would otherwise decline
            # a legitimate certificate forever). Canonical form is
            # injective on content, so a false MATCH stays impossible.
            same = begin
              Canon.canonical(JSON.parse(existing.claim)) == Canon.canonical(certificate)
            rescue StandardError
              false
            end
            return true if same
            raise Distiller::Declined, JSON.generate(
              distiller: 'chain_distillation', verdict: 'decline',
              rule: 'cd-8/carrier-envelope-mismatch',
              remedy: 'a carrier envelope exists for this identity but does not carry this certificate; inspect the carrier before depositing'
            )
          end
          unless defined?(Synoptis::ProofEnvelope)
            require_relative '../../../synoptis/lib/synoptis/proof_envelope'
          end
          digest = certificate.dig('claim_core', 'derivation', 'distillate_commitment')
          envelope = Synoptis::ProofEnvelope.new(
            proof_id: identity,
            attester_id: attester_id,
            subject_ref: "distillate:#{digest}",
            claim: claim_json,
            ttl: nil,
            timestamp: Time.now.utc.iso8601
          )
          reg.store_proof(envelope)
          true
        end

        # CD-6/CD-11: the chain is the authoritative revocation channel;
        # the carrier MIRRORS it, never the reverse. Mirroring is
        # fail-visible best-effort — a failed mirror is disclosed lag
        # (BL-S2-2/3), never a rollback of the chain record.
        def mirror_revocation(identity, reason)
          reg = registry
          return { 'status' => 'unavailable', 'note' => 'carrier registry not reachable; mirror pending' } unless reg
          begin
            require_relative '../../../synoptis/lib/synoptis/revocation_manager'
            envelope = reg.find_proof(identity)
            return { 'status' => 'no_envelope', 'note' => 'no carrier envelope for this identity' } unless envelope
            manager = Synoptis::RevocationManager.new(registry: reg)
            result = manager.revoke(proof_id: identity, reason: reason,
                                    revoker_id: envelope.attester_id)
            JSON.parse(JSON.generate(result))
          rescue StandardError => e
            { 'status' => 'mirror_error', 'error' => e.class.name, 'message' => e.message }
          end
        end

        def default_registry
          require_relative '../../../synoptis/lib/synoptis/proof_envelope'
          require_relative '../../../synoptis/lib/synoptis/registry/file_registry'
          dir = File.join(data_root, 'synoptis_data')
          Synoptis::Registry::FileRegistry.new(data_dir: dir)
        rescue LoadError
          nil
        end

        def data_root
          if defined?(KairosMcp) && KairosMcp.respond_to?(:data_dir)
            KairosMcp.data_dir
          else
            ENV['KAIROS_DATA_DIR'] || File.join(Dir.pwd, '.kairos')
          end
        end
      end
    end
  end
end
