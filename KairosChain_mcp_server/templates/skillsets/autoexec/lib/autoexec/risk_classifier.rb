# frozen_string_literal: true

module Autoexec
  # Risk classification for task steps.
  # L0 deny-list is read from L0 governance (not hardcoded in L1).
  # Protected files force :high risk for any write operation.
  class RiskClassifier
    class DeniedOperationError < SecurityError; end

    # Read L0 deny-list from L0 governance skill (self-referential design).
    # Falls back to a safe default when L0 is not available (e.g., testing).
    def self.l0_deny_list
      if defined?(Kairos) && Kairos.respond_to?(:skill)
        gov = begin
          Kairos.skill(:l0_governance)&.behavior&.call
        rescue StandardError
          nil
        end
        if gov.is_a?(Hash)
          immutable = Array(gov[:immutable_skills])
          base = %i[l0_evolution chain_modification skill_deletion]
          return (base + immutable.map { |s| :"#{s}_modification" }).uniq
        end
      end
      # Fallback for standalone testing
      %i[l0_evolution chain_modification skill_deletion]
    end

    # Protected files: any write to these forces :high risk + human approval
    PROTECTED_FILE_PATTERNS = [
      /autoexec\.yml$/,
      /config\.yml$/,
      /skillset\.json$/,
      /kairos\.rb$/,
      /\.env$/,
      /credentials/i,
      /id_rsa/,
      /\.pem$/,
    ].freeze

    RULES = [
      { pattern: /\b(read|search|analyze|list|grep|glob|inspect|check|view)\b/i, risk: :low },
      { pattern: /\b(edit|create|write|test|build|generate|scaffold)\b/i,        risk: :medium },
      { pattern: /\b(delete|remove|push|deploy|rm|drop|force|destroy)\b/i,       risk: :high },
    ].freeze

    def self.classify(action:, target: nil)
      action_str = action.to_s

      # 1. Check L0 deny-list — raise if matched
      if denied?(action_str)
        raise DeniedOperationError, "Operation '#{action_str}' is on the L0 deny-list and cannot be executed by autoexec"
      end

      # 2. Check if action mentions L0 / core_safety / kairos.rb -> force :high
      if action_str.match?(/\b(l0|core_safety|kairos\.rb|skills\/kairos)\b/i)
        return :high
      end

      # 3. Check protected file patterns -> force :high
      if target
        target_str = target.to_s
        if PROTECTED_FILE_PATTERNS.any? { |pat| target_str.match?(pat) }
          return :high
        end
      end

      # 4. Match against static rules
      RULES.each do |rule|
        return rule[:risk] if action_str.match?(rule[:pattern])
      end

      # 5. Default to :medium (fail-safe)
      :medium
    end

    def self.denied?(action)
      action_str = action.to_s.downcase
      l0_deny_list.any? { |d| action_str.include?(d.to_s.gsub('_', ' ')) || action_str.include?(d.to_s) }
    end

    def self.classify_step(step)
      classify(action: step.action, target: nil)
    end

    def self.risk_summary(steps)
      counts = { low: 0, medium: 0, high: 0 }
      steps.each do |step|
        risk = step.risk || classify_step(step)
        counts[risk] = (counts[risk] || 0) + 1
      end
      counts
    end
  end
end
