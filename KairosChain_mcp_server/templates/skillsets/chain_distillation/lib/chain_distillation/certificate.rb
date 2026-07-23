# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'canon'
require_relative 'recorder'

module KairosMcp
  module SkillSets
    module ChainDistillation
      # Certificate shape and verification (design v0.5 §4, CD-2/CD-3/CD-6).
      #
      # The certificate's vocabulary is exhausted by three claim families —
      # identity, derivation, recording — plus the checkability-status
      # table and the designation-overlap predecessor citations. It is
      # origin-only: there is no field a quality claim could occupy, and
      # verification rejects any claim-core key outside the pinned
      # vocabulary (CD-3's "incapable of expressing quality" made
      # mechanical).
      #
      # Grounding is fixed at issuance (CD-6): the authoritative
      # distillation record is the one whose claim-core commitment the
      # certificate's claim core matches and which its finalized form
      # cites — a positive check, never by exhaustion. Identity uniqueness,
      # designation-overlap citation observance, the drawn-from link, and
      # revocation status are trusted claims; mislabeling any status in
      # either direction fails verification as a whole (CD-2).
      module Certificate
        module_function

        CONVENTION = 'cd-1'

        # Pinned claim-core vocabulary (CD-3): verification fails on any
        # key outside this set, so the claim language cannot be extended
        # into quality territory by an issuer.
        CLAIM_CORE_KEYS = %w[
          convention
          certificate_identity
          identity
          derivation
          recording
          predecessors
          statuses
        ].freeze

        # Pinned per-claim-family checkability-status table (design v0.5
        # §6 slice 1; CD-2). The certificate must carry exactly this
        # table — labeling a checkable claim as trusted is the same defect
        # as the converse, and either fails verification as a whole.
        STATUS_TABLE = {
          'identity.binding'               => 'checkable',
          'identity.continuity'            => 'trusted',
          'identity.uniqueness'            => 'trusted',
          'derivation'                     => 'anchor-pending',
          'recording'                      => 'anchor-pending',
          'reissuance_citation_observance' => 'trusted',
          'drawn_from'                     => 'trusted',
          'revocation_status'              => 'trusted'
        }.freeze

        # Claim core: the certificate's claim content EXCLUDING its
        # citation of the CD-6 record, carrier lifecycle metadata, and
        # commitment openings (all outside the core, CD-6) — which is what
        # breaks the self-citation fixed point.
        def build_claim_core(certificate_identity:, chain_identity:, head_index:, head_hash:,
                             designation:, guard_policy_sha256:, distillate_commitment:,
                             verdict_block_indices:, predecessors:)
          {
            'convention'           => CONVENTION,
            'certificate_identity' => certificate_identity,
            'identity' => {
              'chain_identity'   => chain_identity,
              'chain_head_index' => head_index,
              'chain_head_hash'  => head_hash
            },
            'derivation' => {
              'designation'           => designation.sort,
              'designation_digest'    => Recorder.designation_digest(designation),
              'span'                  => { 'first_index' => designation.min, 'last_index' => designation.max },
              'guard_policy_sha256'   => guard_policy_sha256,
              'distillate_commitment' => distillate_commitment,
              'verdict_block_indices' => verdict_block_indices
            },
            'recording' => {
              'revocation_channel' => 'source-chain:cd_revocation'
            },
            'predecessors' => predecessors,
            'statuses'     => STATUS_TABLE.dup
          }
        end

        # Finalization adds only what sits outside the claim core: the
        # CD-6 record citation and the commitment openings for the
        # released artifacts the holder possesses (CD-2). Later cites
        # earlier; nothing here feeds back into the committed core.
        def finalize(claim_core:, record_citation:, openings:)
          {
            'claim_core'      => claim_core,
            'record_citation' => record_citation,
            'openings'        => openings
          }
        end

        # Verification (CD-2/CD-6): positive checks only. `chain_entries`
        # is the parsed record list of the source chain (index => entry),
        # available to an in-instance or chain-access verifier; claims
        # whose witness is the private chain alone are trusted-status and
        # verified here only when chain access is provided.
        # Returns { valid:, errors:, revoked: }.
        # Pinned nested vocabulary per claim family (CD-3): nested extras
        # and nested missing fields are both defects, so no quality-shaped
        # content can hide one level down.
        NESTED_KEYS = {
          'identity'   => %w[chain_identity chain_head_index chain_head_hash],
          'derivation' => %w[designation designation_digest span guard_policy_sha256
                             distillate_commitment verdict_block_indices],
          'recording'  => %w[revocation_channel]
        }.freeze

        # The span sub-mapping's closed vocabulary (CD-3 at every depth).
        SPAN_KEYS = %w[first_index last_index].freeze

        def verify(certificate, chain_entries: nil, distillate_json: nil, chain_hashes: nil)
          unless certificate.is_a?(Hash)
            return { valid: false, errors: ['certificate/not-a-mapping'], revoked: nil }
          end
          errors = []
          cert = Canon.stringify(certificate)
          core = cert['claim_core']
          return { valid: false, errors: ['certificate/missing-claim-core'], revoked: nil } unless core.is_a?(Hash)

          # CD-3 vocabulary bound: no key outside the pinned set, at the
          # top level and inside each claim family.
          extra = core.keys - CLAIM_CORE_KEYS
          errors << "vocabulary/unknown-keys:#{extra.join(',')}" unless extra.empty?
          missing = CLAIM_CORE_KEYS - core.keys
          errors << "vocabulary/missing-keys:#{missing.join(',')}" unless missing.empty?
          NESTED_KEYS.each do |family, keys|
            fam = core[family]
            unless fam.is_a?(Hash)
              errors << "vocabulary/#{family}-not-a-mapping"
              next
            end
            nested_extra = fam.keys - keys
            errors << "vocabulary/#{family}-unknown-keys:#{nested_extra.join(',')}" unless nested_extra.empty?
            nested_missing = keys - fam.keys
            errors << "vocabulary/#{family}-missing-keys:#{nested_missing.join(',')}" unless nested_missing.empty?
          end
          # The span sub-mapping is likewise closed (CD-3 holds at every
          # depth of the claim core — impl review R3).
          span = core.is_a?(Hash) ? core.dig('derivation', 'span') : nil
          if span.is_a?(Hash) && span.keys.sort != SPAN_KEYS
            errors << "vocabulary/span-keys:#{(span.keys - SPAN_KEYS).join(',')}"
          elsif !span.is_a?(Hash) && core['derivation'].is_a?(Hash)
            errors << 'vocabulary/span-not-a-mapping'
          end

          # CD-2 mislabeling defect, both directions: statuses must equal
          # the pinned table exactly.
          errors << 'statuses/mislabeled' unless core['statuses'] == STATUS_TABLE

          # Openings only over released artifacts (claim core + distillate).
          openings = cert['openings'].is_a?(Hash) ? cert['openings'] : {}
          errors << 'openings/extra' unless (openings.keys - %w[claim_core_salt distillate_salt]).empty?

          revoked = nil
          if chain_entries
            revoked, chain_errors = verify_against_chain(cert, core, openings, chain_entries,
                                                         chain_hashes: chain_hashes)
            errors.concat(chain_errors)
            # A revoked certificate does not verify (CD-6: revocation is
            # the authoritative channel); callers checking only `valid`
            # must not accept a chain-revoked certificate.
            errors << 'revocation/revoked' if revoked
          end

          if distillate_json
            if openings['distillate_salt']
              digest = core.dig('derivation', 'distillate_commitment')
              unless Recorder.commitment_valid?(Recorder::ARTIFACT_DOMAIN, digest.to_s,
                                                openings['distillate_salt'], distillate_json)
                errors << 'distillate/commitment-mismatch'
              end
            else
              # A supplied distillate that cannot be checked is a defect,
              # not a silent pass (impl review R1).
              errors << 'distillate/no-opening'
            end
          end

          { valid: errors.empty?, errors: errors, revoked: revoked }
        end

        # Grounding and chain-witnessed checks (positive, never by
        # exhaustion): locate the cited record, match commitments and
        # identity, check revocation and the designation-overlap
        # predecessor-citation obligation.
        def verify_against_chain(cert, core, openings, chain_entries, chain_hashes: nil)
          errors = []
          citation = cert['record_citation'].is_a?(Hash) ? cert['record_citation'] : {}
          record_index = normalize_index(citation['block_index'])
          record = record_index ? chain_entries[record_index] : nil
          unless record.is_a?(Hash) && record['type'] == 'cd_distillation'
            return [nil, ['grounding/cited-record-absent']]
          end

          # Positive grounding: claim core matches the cited record's
          # claim-core commitment (via the disclosed opening), and every
          # field the record and the core both carry must agree — identity,
          # designation digest, guard policy version, distillate
          # commitment, predecessors (impl review R1: grounding must bind
          # the whole citation, not the index alone).
          if openings['claim_core_salt']
            unless Recorder.commitment_valid?(Recorder::CLAIM_CORE_DOMAIN,
                                              record['claim_core_commitment'].to_s,
                                              openings['claim_core_salt'], Canon.canonical(core))
              errors << 'grounding/claim-core-commitment-mismatch'
            end
          else
            errors << 'grounding/no-claim-core-opening'
          end
          errors << 'grounding/identity-mismatch' unless record['certificate_identity'] == core['certificate_identity']
          errors << 'grounding/designation-mismatch' unless record['designation_digest'] == core.dig('derivation', 'designation_digest')
          errors << 'grounding/policy-mismatch' unless record['guard_policy_sha256'] == core.dig('derivation', 'guard_policy_sha256')
          errors << 'grounding/distillate-commitment-mismatch' unless record['distillate_commitment'] == core.dig('derivation', 'distillate_commitment')
          errors << 'grounding/predecessors-mismatch' unless Array(record['predecessors']).sort == Array(core['predecessors']).sort

          # With block hashes available, bind the citation to the block
          # itself and check the identity family (identity.binding is a
          # CHECKABLE claim and must actually be checked — impl review R1).
          if chain_hashes.is_a?(Hash) && !chain_hashes.empty?
            # Full-citation grounding (CD-2): the block hash is part of the
            # citation, not an optional extra — a certificate stripped of
            # it must not verify (impl review R3).
            cited_hash = citation['block_hash']
            if cited_hash.nil? || cited_hash.to_s.empty?
              errors << 'grounding/no-block-hash'
            elsif chain_hashes[record_index] != cited_hash
              errors << 'grounding/block-hash-mismatch'
            end
            genesis_hash = chain_hashes[chain_hashes.keys.min]
            claimed_identity = core.dig('identity', 'chain_identity')
            if genesis_hash && claimed_identity != "block1-sha256:#{genesis_hash}"
              errors << 'identity/chain-identity-mismatch'
            end
            head_index = normalize_index(core.dig('identity', 'chain_head_index'))
            head_hash = core.dig('identity', 'chain_head_hash')
            if head_index && head_hash && chain_hashes[head_index] != head_hash
              errors << 'identity/head-binding-mismatch'
            end
          end

          # Revocation: keyed to the certificate identity, chain
          # authoritative (trusted-status for outside verifiers; checked
          # here because chain access was provided).
          revoked = chain_entries.values.any? do |e|
            e.is_a?(Hash) && e['type'] == 'cd_revocation' &&
              e['certificate_identity'] == core['certificate_identity']
          end

          # Designation-overlap predecessor-citation obligation (CD-6,
          # evaluated at issuance): every certificate identity that was
          # revoked before this record and whose distillation record's
          # designation shares records with this designation must appear
          # in predecessors.
          required = revoked_overlapping_identities(chain_entries, core.dig('derivation', 'designation'), record_index)
          cited = Array(core['predecessors'])
          missing = required - cited
          errors << "reissuance/uncited-revoked-predecessors:#{missing.join(',')}" unless missing.empty?

          [revoked, errors]
        end

        # Identities of certificates revoked before `before_index` whose
        # distillation designation overlaps `designation`. Both the
        # revocation AND its grounding distillation record must precede
        # `before_index` (impl review R1: records written after the
        # evaluated record cannot ground an obligation on it).
        def revoked_overlapping_identities(chain_entries, designation, before_index)
          designated = Array(designation)
          distillations = {}
          revoked_before = []
          chain_entries.each do |index, entry|
            next unless entry.is_a?(Hash)
            next if index.to_i >= before_index
            case entry['type']
            when 'cd_distillation'
              distillations[entry['certificate_identity']] = Array(entry['designation'])
            when 'cd_revocation'
              revoked_before << entry['certificate_identity']
            end
          end
          revoked_before.uniq.select do |identity|
            overlap = distillations[identity]
            overlap && !(overlap & designated).empty?
          end
        end

        # Integer indices only; a JSON round-trip may deliver strings.
        def normalize_index(value)
          return value if value.is_a?(Integer)
          return value.to_i if value.is_a?(String) && value.match?(/\A\d+\z/)
          nil
        end
      end
    end
  end
end
