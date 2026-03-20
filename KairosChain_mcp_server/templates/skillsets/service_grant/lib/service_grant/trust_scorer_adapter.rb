# frozen_string_literal: true

module ServiceGrant
  # Adapter bridging Synoptis::TrustScorer to AccessChecker's expected interface.
  #
  # AccessChecker expects: @trust_scorer.call(pubkey_hash) → Float (0.0–1.0)
  # Synoptis provides:     TrustScorer#calculate(subject_ref) → Hash { score: Float, ... }
  #
  # This adapter handles:
  # - API translation (Hash → Float)
  # - TTL-based in-memory cache (adapter-owned, not DB)
  # - Graceful degradation if Synoptis is unavailable
  class TrustScorerAdapter
    DEFAULT_CACHE_TTL = 300  # seconds

    def initialize(scorer:, cache_ttl: DEFAULT_CACHE_TTL)
      @scorer = scorer
      @cache = {}
      @cache_ttl = cache_ttl
      @mutex = Mutex.new
    end

    # AccessChecker calls this: @trust_scorer.call(pubkey_hash)
    # Returns the trust-relevant score (quality + bridge dimensions only).
    # Non-trust dimensions (freshness, diversity, velocity) are excluded because
    # a self-only agent with zero external attestation can still score high
    # on those dimensions, bypassing trust_requirements thresholds.
    #
    # @param pubkey_hash [String] Agent identity
    # @return [Float] Trust-relevant score (0.0–1.0)
    def call(pubkey_hash)
      cached = get_cached(pubkey_hash)
      return cached if cached

      result = @scorer.calculate(pubkey_hash)
      details = result[:details] || {}
      # Use only trust-relevant dimensions: quality (attester-weighted) + bridge
      trust_score = ((details[:quality] || 0.0) + (details[:bridge] || 0.0)).clamp(0.0, 1.0)
      set_cached(pubkey_hash, trust_score)
      trust_score
    rescue StandardError => e
      warn "[ServiceGrant] TrustScorer unavailable: #{e.message}"
      0.0  # fail-closed: unknown trust = zero trust
    end

    # Invalidate cache for a specific pubkey_hash (called on attestation events)
    def invalidate(pubkey_hash)
      @mutex.synchronize { @cache.delete(pubkey_hash) }
    end

    # Clear entire cache (called on bulk operations)
    def clear_cache!
      @mutex.synchronize { @cache.clear }
    end

    private

    def get_cached(key)
      @mutex.synchronize do
        entry = @cache[key]
        return nil unless entry
        return nil if Time.now - entry[:at] > @cache_ttl
        entry[:score]
      end
    end

    def set_cached(key, score)
      @mutex.synchronize do
        @cache[key] = { score: score, at: Time.now }
        # Evict oldest entries if cache grows beyond reasonable size
        if @cache.size > 10_000
          oldest_key = @cache.min_by { |_, v| v[:at] }.first
          @cache.delete(oldest_key)
        end
      end
    end
  end
end
