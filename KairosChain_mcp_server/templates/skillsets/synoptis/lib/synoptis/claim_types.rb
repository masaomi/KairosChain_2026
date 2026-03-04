# frozen_string_literal: true

module Synoptis
  module ClaimTypes
    # Standard claim types with scoring weights
    # Higher weight = stronger attestation value
    CLAIM_TYPES = {
      'PIPELINE_EXECUTION' => { weight: 1.0, description: 'Skill/pipeline re-execution for reproducibility verification' },
      'DATA_INTEGRITY'     => { weight: 0.7, description: 'Chain-wide integrity verification' },
      'SKILL_QUALITY'      => { weight: 0.6, description: 'Skill quality and behavior confirmation' },
      'L0_COMPLIANCE'      => { weight: 0.5, description: 'L0 (framework) compliance verification' },
      'L1_GOVERNANCE'      => { weight: 0.4, description: 'L1 (governance/knowledge) correctness verification' },
      'GENOMICS_QC'        => { weight: 0.8, description: 'Genomics data quality control (GenomicsChain integration)' },
      'OBSERVATION_CONFIRM' => { weight: 0.2, description: 'Observation record confirmation only' }
    }.freeze

    # Disclosure levels for selective proof exposure
    DISCLOSURE_LEVELS = {
      'existence_only' => { description: 'Prove existence only (content not disclosed)', merkle: 'root + proof path only' },
      'full'           => { description: 'Full evidence disclosure', merkle: 'complete evidence + merkle tree' }
    }.freeze

    def self.valid_claim_type?(type)
      CLAIM_TYPES.key?(type.to_s)
    end

    def self.weight_for(type)
      CLAIM_TYPES.dig(type.to_s, :weight) || 0.0
    end

    def self.valid_disclosure_level?(level)
      DISCLOSURE_LEVELS.key?(level.to_s)
    end

    def self.all_types
      CLAIM_TYPES.keys
    end
  end
end
