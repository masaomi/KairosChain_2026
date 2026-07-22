# frozen_string_literal: true

require 'digest'
require 'json'
require 'securerandom'
require_relative 'entry'
require_relative 'chain_credential'
require_relative 'reproduction'

module Synoptis
  module Anchoring
    # Selective disclosure artifacts (aud_l4_selective_disclosure_design v0.3,
    # SDP-1..5) under the sdp-1 convention: field commitments (the checkably
    # bound auxiliary, SDP-2), disclosure profile, presentation, and the
    # currency scan. sdp-1 blinds field VALUES of committed canonical-JSON
    # records; it never blinds which record (disclosed narrowness, sdp-1 §0)
    # and modifies nothing in khab-1/map-1/rpr-1. Refuse-not-coerce for
    # authored artifacts; verification reports rather than repairs.
    module SelectiveDisclosure
      CONVENTION_ID = 'sdp-1'
      CONVENTION_PATH = File.expand_path('conventions/sdp-1.md', __dir__)
      AUX_FORMAT = 'sdp-1/field-commitments'
      PROFILE_FORMAT = 'sdp-1/profile'
      PRESENTATION_FORMAT = 'sdp-1/presentation'
      FIELD_DOMAIN = 'sdp-1/field'
      PREDICATES = %w[typed-existence claimed-verdict conforming-verdict].freeze
      VERDICT_PREDICATES = %w[claimed-verdict conforming-verdict].freeze
      CURRENCIES = %w[scan-checkable unestablished].freeze
      HEX_DIGEST = /\A[a-f0-9]{64}\z/
      HEX_SALT = /\A[a-f0-9]{32}\z/
      HEX_SIG = /\A[a-f0-9]{128}\z/
      FIELD_NAME = /\A[a-z0-9_]+\z/
      SALT_BYTES = 16

      AUX_FIELDS = %w[fields format record_sha256].freeze
      PROFILE_FIELDS = %w[currency format opened predicate].freeze
      PRESENTATION_BASE_FIELDS = %w[aux_record format opened profile].freeze
      # conforming-verdict opened set beyond claimed-verdict's, per mode
      # (sdp-1 §4; procedure_sha256 exists exactly when the mode is procedure).
      CONFORMING_OPENED = %w[adjudication_mode target_sha256 tolerance_sha256].freeze

      class DisclosureError < StandardError; end

      module_function

      # SHA-256 of the shipped sdp-1 convention definition's raw bytes.
      def convention_sha256
        @convention_sha256 ||= begin
          Digest::SHA256.hexdigest(File.binread(CONVENTION_PATH))
        rescue SystemCallError => e
          raise DisclosureError, "sdp-1 convention definition unreadable at #{CONVENTION_PATH}: #{e.message}"
        end
      end

      # -- field digest (sdp-1 §1) --

      def field_digest(salt_hex, name, value)
        raise DisclosureError, 'salt must be 32-char lowercase hex (16 bytes)' unless salt_hex.is_a?(String) && salt_hex.match?(HEX_SALT)
        raise DisclosureError, "field name #{name.inspect} outside sdp-1 grammar ([a-z0-9_]+)" unless name.is_a?(String) && name.match?(FIELD_NAME)

        Digest::SHA256.hexdigest("#{FIELD_DOMAIN}|#{salt_hex}|#{name}|#{Entry.canonical_json(value)}")
      end

      # -- field commitments (sdp-1 §1, SDP-2) --

      # Build the auxiliary for +record_string+. Coverage is total: one salt
      # and one digest per top-level field. Returns {'record' => aux record
      # string, 'salts' => {name => salt_hex}}; fresh random salts unless
      # +salts+ supplies them (which a test may, a producer should not reuse).
      def build_field_commitments(record_string, salts: nil)
        record = canonical_object!(record_string, 'record')
        names = record.keys.sort
        names.each do |n|
          raise DisclosureError, "record field #{n.inspect} outside sdp-1 grammar ([a-z0-9_]+)" unless n.match?(FIELD_NAME)
        end
        chosen = {}
        names.each do |n|
          s = salts&.key?(n) ? salts[n] : SecureRandom.hex(SALT_BYTES)
          raise DisclosureError, "supplied salt for #{n} must be 32-char lowercase hex" unless s.is_a?(String) && s.match?(HEX_SALT)

          chosen[n] = s
        end
        if salts && salts.keys.sort != names
          raise DisclosureError, "supplied salts must cover exactly the record fields (#{names.join(', ')})"
        end

        fields = names.each_with_object({}) { |n, acc| acc[n] = field_digest(chosen[n], n, record[n]) }
        aux = Entry.canonical_json(
          'fields' => fields,
          'format' => AUX_FORMAT,
          'record_sha256' => Digest::SHA256.hexdigest(record_string.to_s)
        )
        { 'record' => aux, 'salts' => chosen }
      end

      def parse_field_commitments!(aux_string)
        parsed = json_object!(aux_string, 'field-commitments')
        a = parsed.transform_keys(&:to_s)
        keys = a.keys.sort
        raise DisclosureError, "field-commitments fields must be exactly #{AUX_FIELDS.join(', ')}, got #{keys.join(', ')}" unless keys == AUX_FIELDS
        raise DisclosureError, "unknown format #{a['format'].inspect} (#{AUX_FORMAT} only)" unless a['format'] == AUX_FORMAT
        unless a['record_sha256'].is_a?(String) && a['record_sha256'].match?(HEX_DIGEST)
          raise DisclosureError, 'field-commitments.record_sha256 must be 64-char lowercase hex'
        end
        raise DisclosureError, 'field-commitments.fields must be a non-empty object' unless a['fields'].is_a?(Hash) && !a['fields'].empty?

        a['fields'].each do |n, d|
          raise DisclosureError, "field name #{n.inspect} outside sdp-1 grammar" unless n.is_a?(String) && n.match?(FIELD_NAME)
          raise DisclosureError, "field digest for #{n} must be 64-char lowercase hex" unless d.is_a?(String) && d.match?(HEX_DIGEST)
        end
        unless Entry.canonical_json(a) == aux_string.to_s
          raise DisclosureError, 'field-commitments record is not in canonical serialization (one record, one digest)'
        end

        a
      end

      # Checkable binding (SDP-2): with the record and the salts in hand,
      # every digest recomputes or the auxiliary is not bound. Malformed
      # artifacts raise; a well-formed non-matching pair returns false.
      def verify_field_commitments(aux_string, record_string, salts)
        aux = parse_field_commitments!(aux_string)
        record = canonical_object!(record_string, 'record')
        raise DisclosureError, 'salts must be a Hash of field name => 32-hex salt' unless salts.is_a?(Hash)

        s = salts.transform_keys(&:to_s)
        return false unless aux['record_sha256'] == Digest::SHA256.hexdigest(record_string.to_s)
        return false unless aux['fields'].keys.sort == record.keys.sort # total coverage
        return false unless s.keys.sort == record.keys.sort

        aux['fields'].all? do |n, d|
          s[n].is_a?(String) && s[n].match?(HEX_SALT) && field_digest(s[n], n, record[n]) == d
        end
      end

      # -- disclosure profile (sdp-1 §2, SDP-4) --

      def build_profile(predicate:, opened:, currency: 'unestablished')
        raise DisclosureError, "predicate must be one of #{PREDICATES.join(', ')}, got #{predicate.inspect}" unless PREDICATES.include?(predicate.to_s)
        raise DisclosureError, "currency must be one of #{CURRENCIES.join(', ')}, got #{currency.inspect}" unless CURRENCIES.include?(currency.to_s)

        names = Array(opened).map(&:to_s)
        raise DisclosureError, 'opened must be a non-empty list of field names' if names.empty?
        raise DisclosureError, 'opened must not contain duplicates' unless names.uniq.size == names.size
        names.each do |n|
          raise DisclosureError, "opened name #{n.inspect} outside sdp-1 grammar" unless n.match?(FIELD_NAME)
        end
        raise DisclosureError, 'opened must include format (sdp-1 §2: the record kind is always readable)' unless names.include?('format')

        {
          'currency' => currency.to_s,
          'format' => PROFILE_FORMAT,
          'opened' => names.sort,
          'predicate' => predicate.to_s
        }
      end

      def validate_profile!(profile)
        raise DisclosureError, "profile must be a Hash, got #{profile.class}" unless profile.is_a?(Hash)

        pr = profile.transform_keys(&:to_s)
        keys = pr.keys.sort
        raise DisclosureError, "profile fields must be exactly #{PROFILE_FIELDS.join(', ')}, got #{keys.join(', ')}" unless keys == PROFILE_FIELDS
        raise DisclosureError, "unknown profile format #{pr['format'].inspect} (#{PROFILE_FORMAT} only)" unless pr['format'] == PROFILE_FORMAT
        raise DisclosureError, "profile.predicate must be one of #{PREDICATES.join(', ')}" unless PREDICATES.include?(pr['predicate'])
        raise DisclosureError, "profile.currency must be one of #{CURRENCIES.join(', ')}" unless CURRENCIES.include?(pr['currency'])
        opened = pr['opened']
        raise DisclosureError, 'profile.opened must be a non-empty array' unless opened.is_a?(Array) && !opened.empty?
        raise DisclosureError, 'profile.opened must be sorted and duplicate-free (canonical)' unless opened == opened.map(&:to_s).uniq.sort
        raise DisclosureError, 'profile.opened must include format' unless opened.include?('format')

        pr
      end

      # -- presentation (sdp-1 §3) --

      # Producer-side build. Verifies the binding first (a presentation over
      # an unbound auxiliary would be a claim about nothing) and enforces the
      # predicate's opened-set requirements against the actual record.
      def build_presentation(record_string:, aux_string:, salts:, opened:, predicate:,
                             currency: 'unestablished', credential: nil, signature: nil,
                             carrier_entry_hash: nil)
        unless verify_field_commitments(aux_string, record_string, salts)
          raise DisclosureError, 'auxiliary is not checkably bound to the record (SDP-2); refusing to present'
        end

        record = canonical_object!(record_string, 'record')
        profile = build_profile(predicate: predicate, opened: opened, currency: currency)
        profile['opened'].each do |n|
          raise DisclosureError, "opened field #{n} not present in the record" unless record.key?(n)
        end
        require_predicate_opened!(profile, record)

        s = salts.transform_keys(&:to_s)
        opened_map = profile['opened'].each_with_object({}) do |n, acc|
          acc[n] = { 'salt' => s[n], 'value' => record[n] }
        end
        presentation = {
          'aux_record' => aux_string.to_s,
          'format' => PRESENTATION_FORMAT,
          'opened' => opened_map,
          'profile' => profile
        }
        if VERDICT_PREDICATES.include?(profile['predicate'])
          raise DisclosureError, "#{profile['predicate']} requires credential and signature (sdp-1 §3)" if credential.nil? || signature.nil?

          ChainCredential.validate!(credential)
          raise DisclosureError, 'signature must be 128-char lowercase hex' unless signature.is_a?(String) && signature.match?(HEX_SIG)

          presentation['credential'] = credential.transform_keys(&:to_s)
          presentation['signature'] = signature
        elsif credential || signature
          raise DisclosureError, 'typed-existence carries no credential or signature (closed schema per shape)'
        end
        if profile['currency'] == 'scan-checkable'
          unless carrier_entry_hash.is_a?(String) && carrier_entry_hash.match?(HEX_DIGEST)
            raise DisclosureError, 'scan-checkable currency requires carrier_entry_hash as 64-char lowercase hex (sdp-1 §3)'
          end

          presentation['carrier_entry_hash'] = carrier_entry_hash
        elsif carrier_entry_hash
          raise DisclosureError, 'carrier_entry_hash exists exactly when currency is scan-checkable (closed schema per shape)'
        end
        Entry.canonical_json(presentation)
      end

      def parse_presentation!(presentation_string)
        parsed = json_object!(presentation_string, 'presentation')
        p = parsed.transform_keys(&:to_s)
        raise DisclosureError, "unknown format #{p['format'].inspect} (#{PRESENTATION_FORMAT} only)" unless p['format'] == PRESENTATION_FORMAT

        profile = validate_profile!(p['profile'] || {})
        expected = PRESENTATION_BASE_FIELDS.dup
        expected += %w[credential signature] if VERDICT_PREDICATES.include?(profile['predicate'])
        expected << 'carrier_entry_hash' if profile['currency'] == 'scan-checkable'
        keys = p.keys.sort
        raise DisclosureError, "presentation fields must be exactly #{expected.sort.join(', ')}, got #{keys.join(', ')}" unless keys == expected.sort

        opened = p['opened']
        raise DisclosureError, 'presentation.opened must be an object' unless opened.is_a?(Hash)
        raise DisclosureError, 'opened keys must equal profile.opened exactly (statement-determining, SDP-4)' unless opened.keys.sort == profile['opened']

        opened.each do |n, e|
          entry = e.is_a?(Hash) ? e.transform_keys(&:to_s) : {}
          unless entry.keys.sort == %w[salt value] && entry['salt'].is_a?(String) && entry['salt'].match?(HEX_SALT)
            raise DisclosureError, "opened.#{n} must be {salt: 32-hex, value: ...}"
          end
        end
        if VERDICT_PREDICATES.include?(profile['predicate'])
          raise DisclosureError, 'presentation.credential must be a JSON object (map-1 credential)' unless p['credential'].is_a?(Hash)
          unless p['signature'].is_a?(String) && p['signature'].match?(HEX_SIG)
            raise DisclosureError, 'presentation.signature must be 128-char lowercase hex'
          end
        end
        if profile['currency'] == 'scan-checkable' &&
           !(p['carrier_entry_hash'].is_a?(String) && p['carrier_entry_hash'].match?(HEX_DIGEST))
          raise DisclosureError, 'presentation.carrier_entry_hash must be 64-char lowercase hex'
        end
        parse_field_commitments!(p['aux_record'].to_s)
        unless Entry.canonical_json(p) == presentation_string.to_s
          raise DisclosureError, 'presentation is not in canonical serialization (one artifact, one digest)'
        end

        p
      end

      # Verifier-side check (sdp-1 §4). Structural malformation raises;
      # check failures are reported. For conforming-verdict the operator
      # credential and the rpr-1 §2.1 assessment material are REQUIRED
      # (refuse, not degrade — SDP-1 upward bound):
      #   assessment: {targets:, declarations:, endorsement_position:}
      def verify_presentation(presentation_string, operator_credential: nil, assessment: nil)
        p = parse_presentation!(presentation_string)
        aux = parse_field_commitments!(p['aux_record'])
        profile = validate_profile!(p['profile'])
        failures = []
        notes = []

        opened_values = {}
        p['opened'].each do |n, e|
          entry = e.transform_keys(&:to_s)
          committed = aux['fields'][n]
          if committed.nil?
            failures << "opened field #{n} has no committed digest in the auxiliary"
            next
          end
          if field_digest(entry['salt'], n, entry['value']) == committed
            opened_values[n] = entry['value']
          else
            failures << "opened field #{n} does not recompute against its committed digest"
          end
        end

        case profile['predicate']
        when 'claimed-verdict', 'conforming-verdict'
          failures.concat(verify_verdict_claims(p, profile, aux, opened_values,
                                                operator_credential: operator_credential,
                                                assessment: assessment, notes: notes))
        end

        notes << if profile['currency'] == 'scan-checkable'
                   "currency is scan-checkable: run the sdp-1 §5 scan against carrier entry #{p['carrier_entry_hash'][0, 12]}… and a named extent"
                 else
                   'currency unestablished (SDP-3): this presentation does not support a retraction scan'
                 end
        notes << 'selection is invisible by construction (SDP-3): this shows one committed record, nothing about siblings or contrary verdicts'
        notes << 'opened values bind to the committed auxiliary; the auxiliary\'s fidelity to the record is the sdp-1 §1 disclosed residue, checkable by holders of record + salts (MPR-4 asymmetry)'

        {
          valid: failures.empty?,
          predicate: profile['predicate'],
          record_sha256: aux['record_sha256'],
          opened: opened_values,
          failures: failures,
          notes: notes
        }
      end

      # -- currency scan (sdp-1 §5, SDP-3) --

      # +entries+: array of anchor-log entry views, each a Hash with
      # entry_hash, attestation_type, depositor, position (Integer), and for
      # retractions metadata: {'target_entry_hash' => ...}. The scan is a
      # function of the supplied view; it reports, the reader prices.
      def scan_currency(entries:, carrier_entry_hash:, extent:)
        raise DisclosureError, 'extent must be an Integer committed position' unless extent.is_a?(Integer)
        unless carrier_entry_hash.is_a?(String) && carrier_entry_hash.match?(HEX_DIGEST)
          raise DisclosureError, 'carrier_entry_hash must be 64-char lowercase hex'
        end

        views = Array(entries).map { |e| e.is_a?(Hash) ? e.transform_keys(&:to_s) : {} }
        carrier = views.find { |e| e['entry_hash'] == carrier_entry_hash }
        if carrier.nil?
          return { status: 'unestablished', hits: [], scanned_extent: extent,
                   note: 'carrier entry not in supplied view; currency undecidable there (SDP-3 residue disclosed)' }
        end
        unless carrier['depositor'].is_a?(String) && !carrier['depositor'].empty?
          return { status: 'unestablished', hits: [], scanned_extent: extent,
                   note: 'carrier depositor missing in supplied view; the map-1 §3 issuer rule is undecidable (refuse, not degrade)' }
        end

        # A retraction view whose metadata is not an object is noise, never a
        # crash (assess_declarations residue precedent; probed R1 finding).
        # Duplicate views of one committed entry are one entry. The map-1 §3
        # issuer rule filters everywhere (a foreign "retraction" retracts
        # nothing, inside or outside the extent) — but non-issuer targeting
        # entries are disclosed as a residue line, never silently dropped.
        aimed = views.select do |e|
          e['attestation_type'] == 'retraction' &&
            e['metadata'].is_a?(Hash) &&
            e['metadata']['target_entry_hash'] == carrier_entry_hash
        end.uniq { |e| [e['entry_hash'], e['position']] }
        targeting, foreign = aimed.partition { |e| e['depositor'] == carrier['depositor'] }
        hits = targeting.select { |e| e['position'].is_a?(Integer) && e['position'] <= extent }
        beyond = targeting.count { |e| e['position'].is_a?(Integer) && e['position'] > extent }
        undecidable = targeting.count { |e| !e['position'].is_a?(Integer) }
        note = if hits.any?
                 'a retraction from the carrier depositor targets this entry at or before the extent; the claim was taken back (RPR-5/MAP-4 discipline, never unsaid by deletion)'
               else
                 "unretracted up to extent #{extent} in the supplied view; absence beyond it proves nothing (MPR-9)"
               end
        # Residue lines are appended unconditionally (§5: never silently
        # dropped) — a hit does not exempt the beyond-extent disclosure.
        note += "; #{beyond} same-issuer retraction(s) fall outside the extent (disclosed, not dropped)" if beyond.positive?
        note += "; #{undecidable} same-issuer retraction(s) carry no decidable position (disclosed)" if undecidable.positive?
        note += "; #{foreign.size} non-issuer entr#{foreign.size == 1 ? 'y' : 'ies'} target the carrier and retract nothing (map-1 §3)" if foreign.any?
        {
          status: hits.empty? ? 'unretracted' : 'retracted',
          hits: hits.map { |e| e['position'] }.uniq.sort,
          scanned_extent: extent,
          note: note
        }
      end

      # -- internal helpers --

      # Producer-side enforcement of sdp-1 §4 opened-set requirements against
      # the actual record (a presentation that could not verify is refused at
      # build, not shipped).
      def require_predicate_opened!(profile, record)
        return unless VERDICT_PREDICATES.include?(profile['predicate'])

        unless record['format'] == Reproduction::ENDORSEMENT_FORMAT
          raise DisclosureError, "#{profile['predicate']} presents an #{Reproduction::ENDORSEMENT_FORMAT} record, got #{record['format'].inspect}"
        end
        raise DisclosureError, "#{profile['predicate']} requires verdict opened" unless profile['opened'].include?('verdict')
        return unless profile['predicate'] == 'conforming-verdict'

        missing = CONFORMING_OPENED.reject { |n| profile['opened'].include?(n) }
        raise DisclosureError, "conforming-verdict requires opened #{missing.join(', ')}" unless missing.empty?
        if record['adjudication_mode'] == 'procedure' && !profile['opened'].include?('procedure_sha256')
          raise DisclosureError, 'procedure mode requires procedure_sha256 opened (RPR-4: the adopted procedure is named)'
        end
      end

      def verify_verdict_claims(p, profile, aux, opened_values, operator_credential:, assessment:, notes:)
        failures = []
        if opened_values['format'] != Reproduction::ENDORSEMENT_FORMAT
          failures << "verdict predicates require an #{Reproduction::ENDORSEMENT_FORMAT} record, opened format is #{opened_values['format'].inspect}"
        end
        failures << 'verdict predicates require the verdict field opened' unless profile['opened'].include?('verdict')
        # The referenced record must WEAR the rpr-1 endorsement shape publicly:
        # the auxiliary's field-name set (public by construction) must equal one
        # of the closed rpr-1 §3 schemas. A crafted record carrying the
        # endorsement format label with a different field set is not an
        # endorsement and must not verify under a verdict predicate (SDP-1
        # face/substance; probed R1 finding).
        shape = aux['fields'].keys.sort
        unless [Reproduction::ENDORSEMENT_FIELDS_HAND, Reproduction::ENDORSEMENT_FIELDS_PROCEDURE].include?(shape)
          failures << "referenced record's field set is not an rpr-1 endorsement shape (got #{shape.join(', ')})"
        end
        if opened_values.key?('verdict') && !Reproduction::VERDICTS.include?(opened_values['verdict'])
          failures << "opened verdict must be one of #{Reproduction::VERDICTS.join(', ')}, got #{opened_values['verdict'].inspect} (rpr-1 closed vocabulary)"
        end
        if opened_values.key?('adjudication_mode')
          mode_shape = opened_values['adjudication_mode'] == 'procedure' ? Reproduction::ENDORSEMENT_FIELDS_PROCEDURE : Reproduction::ENDORSEMENT_FIELDS_HAND
          if Reproduction::MODES.include?(opened_values['adjudication_mode'])
            failures << 'opened adjudication_mode does not match the record shape (closed schema per mode)' unless shape == mode_shape
          else
            failures << "opened adjudication_mode must be one of #{Reproduction::MODES.join(', ')}, got #{opened_values['adjudication_mode'].inspect}"
          end
        end

        cred = p['credential']
        begin
          cred_digest = ChainCredential.credential_digest(cred)
          signing = "map-1/attestation|#{cred_digest}|#{aux['record_sha256']}"
          unless ChainCredential.verify_raw(cred.transform_keys(&:to_s)['public_key'], p['signature'], signing)
            failures << 'signature does not verify under the presented credential over the committed record digest (map-1 §1.1)'
          end
        rescue ChainCredential::CredentialError => e
          failures << "credential unresolvable: #{e.message}"
          cred_digest = nil
        end

        if profile['predicate'] == 'conforming-verdict'
          missing = CONFORMING_OPENED.reject { |n| profile['opened'].include?(n) }
          failures << "conforming-verdict requires opened #{missing.join(', ')}" unless missing.empty?
          if opened_values['adjudication_mode'] == 'procedure' && !profile['opened'].include?('procedure_sha256')
            failures << 'procedure mode requires procedure_sha256 opened (the adopted procedure is named, RPR-4)'
          end
          # The opened conformance digests must be digests: a non-hex value in
          # a crafted record must FAIL, never slip past the assessment gate
          # (refuse-not-degrade; probed R1 finding).
          bad_hex = (CONFORMING_OPENED + (profile['opened'].include?('procedure_sha256') ? ['procedure_sha256'] : []) - ['adjudication_mode'])
                    .select { |n| opened_values.key?(n) && !(opened_values[n].is_a?(String) && opened_values[n].match?(HEX_DIGEST)) }
          bad_hex.each { |n| failures << "opened #{n} must be a 64-hex digest, got #{opened_values[n].inspect} (refuse, not degrade)" }
          if operator_credential.nil?
            failures << 'conforming-verdict requires the operator credential for the foreignness check (refuse, not degrade)'
          elsif cred_digest
            begin
              unless Reproduction.foreign?(p['credential'], operator_credential)
                failures << 'endorser credential equals operator credential: not foreign, not a conforming endorsement (RPR-4)'
              end
            rescue ChainCredential::CredentialError => e
              failures << "operator credential unresolvable: #{e.message}"
            end
          end
          a = assessment.is_a?(Hash) ? assessment.transform_keys(&:to_s) : nil
          if a.nil? || !a.key?('targets') || !a.key?('declarations') || !a.key?('endorsement_position')
            failures << 'conforming-verdict requires the rpr-1 §2.1 assessment material (targets, declarations, endorsement_position); refuse, not degrade'
          elsif bad_hex.empty? && opened_values['tolerance_sha256'].is_a?(String)
            begin
              report = Reproduction.assess_declarations(
                targets: a['targets'], declarations: a['declarations'],
                invoked_tolerance_sha256: opened_values['tolerance_sha256'],
                endorsement_position: a['endorsement_position']
              )
              if report[:invoked_conforming]
                notes << "tolerance anteriority assessed conforming (multiplicity #{report[:multiplicity]}, rpr-1 §2.1: the menu is visible)"
              else
                failures << "invoked tolerance does not assess as conforming: #{report[:note]}"
              end
              # Tolerance-target coherence (probed R1/R2 findings): the invoked
              # tolerance must be bound to the endorsement's opened target OR to
              # a sibling target sharing its committed computation
              # identification — the rpr-1 §2.1 pooling rule, not exact-digest
              # equality (a sibling menu is one menu). A tolerance bound to an
              # UNRELATED computation is some other computation's tolerance
              # wearing this endorsement's face and fails.
              invoked_decl = Array(a['declarations']).map { |d| d.is_a?(Hash) ? d.transform_keys(&:to_s) : {} }
                                                     .find { |d| Digest::SHA256.hexdigest(d['tolerance'].to_s) == opened_values['tolerance_sha256'] }
              if invoked_decl
                begin
                  tol = Reproduction.parse_tolerance!(invoked_decl['tolerance'].to_s)
                  unless tol['target_sha256'] == opened_values['target_sha256']
                    comp = {}
                    Array(a['targets']).each do |t|
                      comp[Digest::SHA256.hexdigest(t.to_s)] = Reproduction.computation_id(t)
                    rescue Reproduction::ReproductionError
                      next
                    end
                    tol_comp = comp[tol['target_sha256']]
                    end_comp = comp[opened_values['target_sha256']]
                    if end_comp.nil?
                      failures << "endorsement's opened target unresolvable in supplied view (coherence undecidable; refuse, not degrade)"
                    elsif tol_comp.nil?
                      failures << "invoked tolerance's target unresolvable in supplied view (coherence undecidable; refuse, not degrade) (RPR-3 target binding)"
                    elsif tol_comp != end_comp
                      failures << "invoked tolerance binds target #{tol['target_sha256'][0, 12]}…, which shares no committed computation identification with the endorsement's opened target (RPR-3 target binding, rpr-1 §2.1 sibling rule)"
                    end
                  end
                rescue Reproduction::ReproductionError => e
                  failures << "invoked tolerance record unresolvable: #{e.message}"
                end
              end
            rescue Reproduction::ReproductionError => e
              failures << "assessment material unresolvable: #{e.message}"
            end
          end
          notes << 'foreignness is distinctness, not independence: a colluding pair fabricates freely (RPR-4 disclosed limit)'
        else
          notes << 'claimed-verdict asserts the claim, not conformance: no foreignness or anteriority is checked (SDP-1 face/substance rule)'
        end
        failures
      end

      def canonical_object!(string, label)
        parsed = json_object!(string, label)
        r = parsed.transform_keys(&:to_s)
        unless Entry.canonical_json(r) == string.to_s
          raise DisclosureError, "#{label} is not in canonical serialization (one record, one digest)"
        end

        r
      end

      def json_object!(string, label)
        parsed = begin
          JSON.parse(string.to_s)
        rescue JSON::ParserError => e
          raise DisclosureError, "#{label} is not valid JSON: #{e.message}"
        end
        raise DisclosureError, "#{label} must be a JSON object, got #{parsed.class}" unless parsed.is_a?(Hash)

        parsed
      end
    end
  end
end
