# frozen_string_literal: true

module SkillsetExchange
  # Single gatekeeper for SkillSet deposit eligibility.
  #
  # Validates that a SkillSet is safe to deposit:
  # - Name matches safe pattern
  # - SkillSet exists and is exchangeable (knowledge_only? + valid?)
  # - Estimated archive size within limit
  class ExchangeValidator
    SAFE_NAME_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/

    def initialize(config: {})
      @max_archive_size = config.dig('deposit', 'max_archive_size_bytes') || 5_242_880
    end

    # Validate a SkillSet for deposit eligibility.
    #
    # @param name [String] SkillSet name
    # @param manager [KairosMcp::SkillSetManager, nil] Manager instance (auto-created if nil)
    # @return [Hash] { valid: Boolean, errors: Array<String> }
    def validate_for_deposit(name, manager: nil)
      manager ||= ::KairosMcp::SkillSetManager.new
      errors = []

      # Name validation
      errors << "Invalid SkillSet name" unless SAFE_NAME_PATTERN.match?(name.to_s)

      ss = manager.find_skillset(name)
      errors << "SkillSet '#{name}' not found" unless ss

      if ss
        errors << "Not exchangeable: contains executable code" unless ss.exchangeable?

        # Estimate archive size from file sizes (avoid packaging just to check)
        estimated_size = estimate_archive_size(ss)
        if estimated_size > @max_archive_size
          errors << "Estimated archive too large (#{estimated_size} > #{@max_archive_size})"
        end
      end

      { valid: errors.empty?, errors: errors }
    end

    private

    # Estimate archive size from the sum of file sizes in the SkillSet.
    # Tar overhead is ~512 bytes per entry; gzip typically compresses text well,
    # so raw file size is a reasonable upper bound.
    def estimate_archive_size(skillset)
      Dir[File.join(skillset.path, '**', '*')]
        .select { |f| File.file?(f) }
        .sum { |f| File.size(f) }
    rescue StandardError
      Float::INFINITY  # fail-closed: unable to estimate size
    end
  end
end
