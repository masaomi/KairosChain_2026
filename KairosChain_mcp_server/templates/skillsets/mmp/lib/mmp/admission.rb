# frozen_string_literal: true

module MMP
  # Registry of direct-mode admission deciders (secure MMP v1).
  #
  # The policy is chosen when the listener starts (`--admission <name>`); a
  # SkillSet registers the decider for that name. A decider receives a
  # candidate Hash and answers { admit: true|false, as: <name or nil> }.
  # A decider that is missing or raises admits nothing.
  #
  # Candidate keys: :phase (:introduce or :request), :key_sha256,
  # :public_key_pem, :instance_id, :claimed_name, :remote_addr.
  module Admission
    OPEN = 'open'
    NAME_PATTERN = /\A[a-z][a-z0-9_-]{0,31}\z/

    @deciders = {}
    @mutex = Mutex.new

    class << self
      def register(name, &block)
        name = name.to_s
        raise ArgumentError, "invalid policy name #{name.inspect}" unless NAME_PATTERN.match?(name) && name != OPEN
        raise ArgumentError, 'a decider block is required' unless block

        @mutex.synchronize { @deciders[name] = block }
      end

      def unregister(name)
        @mutex.synchronize { @deciders.delete(name.to_s) }
      end

      def registered?(name)
        @mutex.synchronize { @deciders.key?(name.to_s) }
      end

      def registered_names
        @mutex.synchronize { @deciders.keys.sort }
      end

      # @return [Hash] { admit:, as:, unavailable:, reason: }
      def decide(name, candidate)
        decider = @mutex.synchronize { @deciders[name.to_s] }
        return { admit: false, as: nil, unavailable: true, reason: 'policy_unavailable' } unless decider

        result = decider.call(candidate)
        return { admit: false, as: nil, unavailable: true, reason: 'policy_error' } unless result.is_a?(Hash)

        {
          admit: result[:admit] == true,
          as: result[:admit] == true ? result[:as] : nil,
          unavailable: result[:unavailable] == true,
          reason: result[:reason]
        }
      rescue StandardError, ScriptError => e
        warn "[MMP::Admission] decider '#{name}' failed: #{e.class}: #{e.message}"
        { admit: false, as: nil, unavailable: true, reason: 'policy_error' }
      end

      def clear!
        @mutex.synchronize { @deciders = {} }
      end
    end
  end
end
