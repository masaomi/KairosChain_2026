# frozen_string_literal: true

require 'json'
require 'digest'
require 'securerandom'
require 'time'

module Synoptis
  class ProofEnvelope
    PROOF_VERSION = '1.0.0'

    # 1.1.0 adds one identity field to the canonical form: submitter_pubkey, the
    # party that handed over the content, as distinct from attester_id, which
    # names the anchor that recorded it. The version selects the canonical field
    # set, so an envelope signed under 1.0.0 keeps verifying against the same
    # bytes it was signed over — adding fields unconditionally would have
    # invalidated every existing signature.
    #
    # It deliberately does NOT carry attester_pubkey. An earlier revision put the
    # signing key in the canonical form so a reader could verify from the record
    # alone; the version field is itself a field of the record, so a forger could
    # write version 1.1.0, name any attester, sign with their own key, record that
    # key alongside, and obtain valid: true from a key-less verification. Ruling of
    # 2026-08-02 (option A2): the key is never taken from the record. Verification
    # needs a key supplied by the caller, which is where authenticity has to come
    # from anyway — binding a key to a named attester requires a trusted key list
    # this layer does not have.
    PROOF_VERSION_WITH_IDENTITY = '1.1.0'
    VERSIONS_CARRYING_IDENTITY = [PROOF_VERSION_WITH_IDENTITY].freeze

    attr_reader :proof_id, :version, :attester_id, :subject_ref, :claim,
                :evidence, :merkle_root, :signature, :timestamp, :ttl,
                :actor_user_id, :actor_role, :metadata, :submitter_pubkey

    def initialize(attrs = {})
      attrs = attrs.transform_keys(&:to_sym) if attrs.is_a?(Hash)
      @proof_id = attrs[:proof_id] || SecureRandom.uuid
      @submitter_pubkey = attrs[:submitter_pubkey]
      @version = attrs[:version] || (@submitter_pubkey ? PROOF_VERSION_WITH_IDENTITY : PROOF_VERSION)
      @attester_id = attrs[:attester_id]
      @subject_ref = attrs[:subject_ref]
      @claim = attrs[:claim]
      @evidence = attrs[:evidence]
      @merkle_root = attrs[:merkle_root]
      @signature = attrs[:signature]
      @timestamp = attrs[:timestamp] || Time.now.utc.iso8601
      @ttl = attrs[:ttl]
      @actor_user_id = attrs[:actor_user_id]
      @actor_role = attrs[:actor_role]
      @metadata = attrs[:metadata] || {}
    end

    def to_h
      {
        proof_id: @proof_id,
        version: @version,
        attester_id: @attester_id,
        subject_ref: @subject_ref,
        claim: @claim,
        evidence: @evidence,
        merkle_root: @merkle_root,
        signature: @signature,
        timestamp: @timestamp,
        ttl: @ttl,
        actor_user_id: @actor_user_id,
        actor_role: @actor_role,
        metadata: @metadata,
        submitter_pubkey: @submitter_pubkey
      }
    end

    # S-C1 fix: Retain nil values as JSON null for canonical form.
    # .compact is intentionally NOT used here — canonical form must be
    # deterministic regardless of which fields are populated.
    #
    # Design decision: actor_user_id, actor_role, and metadata are
    # intentionally EXCLUDED from canonical_json (and thus from signature).
    # actor_role is a trust hint used by TrustScorer to weight quality,
    # not a cryptographic claim. The evidence field (which IS signed)
    # carries the verifiable substance (DOI, hash, etc.).
    def canonical_json
      canonical = {
        proof_id: @proof_id,
        version: @version,
        attester_id: @attester_id,
        subject_ref: @subject_ref,
        claim: @claim,
        evidence: @evidence,
        merkle_root: @merkle_root,
        timestamp: @timestamp,
        ttl: @ttl
      }
      canonical[:submitter_pubkey] = @submitter_pubkey if carries_identity_fields?
      JSON.generate(canonical, sort_keys: true)
    end

    # The field set is chosen by the envelope's own version, not by whether the
    # values happen to be populated, so the canonical form stays deterministic
    # within a version — the property the exclusion note above protects.
    def carries_identity_fields?
      VERSIONS_CARRYING_IDENTITY.include?(@version)
    end

    # An identity field present at a version whose canonical form does not carry
    # it is a value sitting outside the signature — displayed as if it were part
    # of the record while nothing binds it to the signed bytes.
    #
    # Deserialisation must not raise on it, because from_h is the read path and
    # a stored or third-party record of this shape would otherwise take down
    # every unfiltered listing and escape the caller's error taxonomy. The
    # Verifier reports it instead, so the record comes back invalid.
    def identity_outside_signature?
      return false if carries_identity_fields?

      !@submitter_pubkey.nil?
    end

    def content_hash
      Digest::SHA256.hexdigest(canonical_json)
    end

    def expired?
      return false unless @ttl
      issued_at = Time.parse(@timestamp)
      Time.now.utc > issued_at + @ttl
    rescue ArgumentError
      false
    end

    # Accepts an MMP::Crypto instance (which holds the private key internally).
    #
    # Signing does not record the signing key. A key recorded by the signer is a
    # self-report: it tells a reader which key to check against only if the reader
    # already trusts whoever wrote the record, which is the thing being checked.
    # The verifying key travels out of band (see PROOF_VERSION_WITH_IDENTITY).
    def sign!(crypto)
      return unless crypto

      @signature = crypto.sign(canonical_json)
    end

    def self.from_h(hash)
      hash = hash.transform_keys(&:to_sym) if hash.is_a?(Hash)
      new(hash)
    end
  end
end
