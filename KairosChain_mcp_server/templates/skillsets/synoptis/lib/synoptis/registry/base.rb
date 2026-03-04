# frozen_string_literal: true

module Synoptis
  module Registry
    class Base
      def save_proof(_proof_hash)
        raise NotImplementedError
      end

      def find_proof(_proof_id)
        raise NotImplementedError
      end

      def list_proofs(_filters = {})
        raise NotImplementedError
      end

      def update_proof_status(_proof_id, _status, _revoke_ref = nil)
        raise NotImplementedError
      end

      def save_revocation(_revocation_hash)
        raise NotImplementedError
      end

      def find_revocation(_proof_id)
        raise NotImplementedError
      end

      def save_challenge(_challenge_hash)
        raise NotImplementedError
      end

      def find_challenge(_challenge_id)
        raise NotImplementedError
      end

      def list_challenges(**_filters)
        raise NotImplementedError
      end

      def update_challenge(_challenge_id, _updated_hash)
        raise NotImplementedError
      end
    end
  end
end
