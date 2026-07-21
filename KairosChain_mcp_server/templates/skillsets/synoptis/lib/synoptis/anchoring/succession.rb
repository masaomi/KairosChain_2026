# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'entry'
require_relative 'chain_credential'

module Synoptis
  module Anchoring
    # Succession governance (aud_l2_mutual_anchoring_design v0.5 §3c, MAP-2)
    # under the map-1 convention §4: designation and retraction records on the
    # OLD chain, evaluated by a single scan in committed order. Pure functions
    # of the record sequence — no state, no clock, no network.
    #
    # Diagnostic posture (the HeadBinding.coherence pattern): asked for a
    # governance VERDICT over possibly hostile records, this module never
    # raises — unverifiable records are ignored as noise, and the verdict says
    # what the records show, never intent (key compromise is indistinguishable
    # from the issuer, MAP-2 disclosed limit).
    module Succession
      DESIGNATION_FORMAT = 'map-1/succession-designation'
      RETRACTION_FORMAT = 'map-1/succession-retraction'
      HEX_DIGEST = /\A[a-f0-9]{64}\z/
      HEX_SIG = /\A[a-f0-9]{128}\z/
      CHAIN_IDENTITY = /\Ablock1-sha256:[a-f0-9]{64}\z/

      class SuccessionError < StandardError; end

      module_function

      # Build a designation record string (map-1 §4) for the OLD chain, signed
      # under its credential +key+.
      def designation_record(old_credential, key, successor_identity, successor_credential_digest)
        si = successor_identity.to_s
        sd = successor_credential_digest.to_s
        raise SuccessionError, "successor_identity must be block1-sha256:<64-hex>, got #{si.inspect}" unless si.match?(CHAIN_IDENTITY)
        raise SuccessionError, 'successor_credential_digest must be 64-char lowercase hex' unless sd.match?(HEX_DIGEST)

        old_digest = ChainCredential.credential_digest(old_credential)
        unless ChainCredential.public_key_hex(key) == old_credential.transform_keys(&:to_s)['public_key']
          raise SuccessionError, 'signing key does not match old credential.public_key (issuer-only, MAP-2)'
        end

        message = "#{DESIGNATION_FORMAT}|#{old_digest}|#{si}|#{sd}"
        Entry.canonical_json(
          'designation_sig' => key.sign(nil, message).unpack1('H*'),
          'format' => DESIGNATION_FORMAT,
          'successor_credential_digest' => sd,
          'successor_identity' => si
        )
      end

      # Build a retraction record string (map-1 §4) targeting a designation
      # record string, signed under the SAME old-chain credential.
      def retraction_record(old_credential, key, designation_record_string)
        old_digest = ChainCredential.credential_digest(old_credential)
        unless ChainCredential.public_key_hex(key) == old_credential.transform_keys(&:to_s)['public_key']
          raise SuccessionError, 'signing key does not match old credential.public_key (issuer-only, MAP-2)'
        end

        target = Digest::SHA256.hexdigest(designation_record_string.to_s)
        message = "#{RETRACTION_FORMAT}|#{old_digest}|#{target}"
        Entry.canonical_json(
          'format' => RETRACTION_FORMAT,
          'retraction_sig' => key.sign(nil, message).unpack1('H*'),
          'target_record_sha256' => target
        )
      end

      # Governance verdict (map-1 §4.1) over the old chain's ordered +records+
      # (array of record strings in committed order) under +old_credential+.
      # +changeover_position+ is the optional committed position (index into
      # +records+) at or after which old-credential acts no longer alter
      # governance — the caller derives it from the successor chain's first
      # extension act committing the governing designation (map-1 §4.1 step 4).
      #
      # Returns:
      #   { status: 'governed'|'orphan',
      #     governing: {successor_identity:, successor_credential_digest:,
      #                 position:} | nil,
      #     contested: [ {position:, reason:} ... ],
      #     designations: <count of valid designations seen> }
      def governance(old_credential, records, changeover_position: nil)
        # Caller parameters (unlike hostile records) are refused, not coerced:
        # a mistyped changeover would silently shift the boundary.
        unless changeover_position.nil? || (changeover_position.is_a?(Integer) && changeover_position >= 0)
          raise SuccessionError, "changeover_position must be nil or a non-negative Integer, got #{changeover_position.inspect}"
        end
        raise SuccessionError, "records must be an Array, got #{records.class}" unless records.is_a?(Array)

        old_digest = ChainCredential.credential_digest(old_credential)
        pub = old_credential.transform_keys(&:to_s)['public_key']

        designations = [] # {position:, record_sha256:, successor_identity:, successor_credential_digest:, retracted:}
        contested = []

        records.each_with_index do |raw, position|
          parsed = parse_record(raw)
          next if parsed.nil?

          # map-1 §4.1 step 2: acts count "at or before the changeover
          # position", so only positions strictly AFTER it are post-changeover.
          post = !changeover_position.nil? && position > changeover_position
          case parsed['format']
          when DESIGNATION_FORMAT
            next unless designation_valid?(parsed, old_digest, pub)

            if post
              contested << { position: position, reason: 'designation after changeover (never alters governance)' }
              next
            end
            designations << {
              position: position,
              record_sha256: Digest::SHA256.hexdigest(raw.to_s),
              successor_identity: parsed['successor_identity'],
              successor_credential_digest: parsed['successor_credential_digest'],
              retracted: false
            }
          when RETRACTION_FORMAT
            next unless retraction_valid?(parsed, old_digest, pub)

            if post
              contested << { position: position, reason: 'retraction after changeover (never alters governance)' }
              next
            end
            # Mark EVERY designation carrying the targeted record digest at or
            # before this retraction (map-1 §4.1 step 2: a retraction applies
            # to earlier copies; a byte-identical designation re-appended LATER
            # is a fresh act and governs). Retracted stays retracted; a
            # retraction with no visible target is ignored as noise.
            designations.each do |d|
              # The position predicate is redundant with scan order (only
              # already-scanned designations are in the list) but stated
              # explicitly so at-or-before never depends on iteration detail.
              next unless d[:record_sha256] == parsed['target_record_sha256'] &&
                          !d[:retracted] && d[:position] <= position

              d[:retracted] = true
              d[:retracted_at] = position
            end
          end
        end

        governing = designations.find { |d| !d[:retracted] }
        later = governing.nil? ? [] : designations.select { |d| !d[:retracted] && d[:position] > governing[:position] }
        later.each do |d|
          contested << { position: d[:position], reason: 'later non-retracted designation (does not override, MAP-2)' }
        end
        # MAP-2: every retract-and-redesignate trail is surfaced in one and
        # the same contested register as post-changeover acts and trail-less
        # competitors — no path to a governing successor is silent.
        designations.select { |d| d[:retracted] }.each do |d|
          contested << { position: d[:position],
                         reason: "designation retracted at position #{d[:retracted_at]} (retract-and-redesignate trail)" }
        end
        # Deterministic order even if two reasons ever share a position.
        contested.sort_by! { |c| [c[:position], c[:reason]] }

        if governing.nil?
          { status: 'orphan', governing: nil, contested: contested, designations: designations.size }
        else
          {
            status: 'governed',
            governing: governing.slice(:position, :successor_identity, :successor_credential_digest),
            contested: contested,
            designations: designations.size
          }
        end
      end

      # -- internal helpers --

      DESIGNATION_FIELDS = %w[designation_sig format successor_credential_digest successor_identity].freeze
      RETRACTION_FIELDS = %w[format retraction_sig target_record_sha256].freeze

      # A succession artifact is valid only in its canonical serialization
      # with exactly the specified fields (map-1 §4): a non-canonical or
      # extra-field record is not the artifact and is ignored as noise —
      # otherwise one logical designation could carry several record digests,
      # splitting retraction targeting.
      def parse_record(raw)
        return nil unless raw.is_a?(String)

        parsed = JSON.parse(raw)
        return nil unless parsed.is_a?(Hash)

        p = parsed.transform_keys(&:to_s)
        return nil unless Entry.canonical_json(p) == raw

        p
      rescue JSON::ParserError
        nil
      end

      def designation_valid?(parsed, old_digest, public_key_hex)
        return false unless parsed.keys.sort == DESIGNATION_FIELDS

        si = parsed['successor_identity']
        sd = parsed['successor_credential_digest']
        sig = parsed['designation_sig']
        return false unless si.is_a?(String) && si.match?(CHAIN_IDENTITY)
        return false unless sd.is_a?(String) && sd.match?(HEX_DIGEST)
        return false unless sig.is_a?(String) && sig.match?(HEX_SIG)

        message = "#{DESIGNATION_FORMAT}|#{old_digest}|#{si}|#{sd}"
        ChainCredential.verify_raw(public_key_hex, sig, message)
      end

      def retraction_valid?(parsed, old_digest, public_key_hex)
        return false unless parsed.keys.sort == RETRACTION_FIELDS

        target = parsed['target_record_sha256']
        sig = parsed['retraction_sig']
        return false unless target.is_a?(String) && target.match?(HEX_DIGEST)
        return false unless sig.is_a?(String) && sig.match?(HEX_SIG)

        message = "#{RETRACTION_FORMAT}|#{old_digest}|#{target}"
        ChainCredential.verify_raw(public_key_hex, sig, message)
      end
    end
  end
end
