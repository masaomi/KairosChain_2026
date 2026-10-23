# frozen_string_literal: true

module Hestia
  # Single-use registration nonces for one Place process.
  #
  # A nonce is recorded only after its proof's signature has verified, so
  # unauthenticated requests cannot fill the store, and is kept until its
  # proof can no longer be fresh. Proofs from before this process started are
  # refused by the freshness rule, so the store need not survive a restart.
  class RegistrationNonceStore
    def initialize
      @seen = {}
      @mutex = Mutex.new
      @pruned_at = Time.at(0)
    end

    # @return [Boolean] true when the nonce was unseen (and is now recorded)
    def accept(nonce, expires_at:)
      @mutex.synchronize do
        now = Time.now
        if now - @pruned_at >= 1
          @seen.delete_if { |_n, exp| exp < now }
          @pruned_at = now
        end
        return false if @seen.key?(nonce)

        @seen[nonce] = expires_at
        true
      end
    end

    def size
      @mutex.synchronize { @seen.size }
    end
  end
end
