# frozen_string_literal: true

require 'yaml'
require 'fileutils'

module Synoptis
  module ToolHelpers
    def synoptis_data_dir
      dir = File.join(KairosMcp.data_dir, 'synoptis_data')
      FileUtils.mkdir_p(dir)
      dir
    end

    def registry
      @_registry ||= Registry::FileRegistry.new(data_dir: synoptis_data_dir)
    end

    def attestation_engine
      @_engine ||= AttestationEngine.new(registry: registry, config: synoptis_config)
    end

    def revocation_manager
      @_revocation ||= RevocationManager.new(registry: registry, config: synoptis_config)
    end

    def challenge_manager
      @_challenge ||= ChallengeManager.new(registry: registry, config: synoptis_config)
    end

    def trust_scorer
      @_scorer ||= TrustScorer.new(registry: registry, config: synoptis_config)
    end

    # --- Constitutive L2 attestation (Slice 1) ---

    def context_root
      KairosMcp.context_dir
    end

    def constitutive_chain
      @_constitutive_chain ||= Constitutive::AttestationChain.new(registry: registry)
    end

    def proposal_criterion
      @_proposal_criterion ||= Constitutive::ProposalCriterion.new(
        context_dir: context_root,
        judgment_types: constitutive_config['judgment_types'] ||
          Constitutive::ProposalCriterion::DEFAULT_JUDGMENT_TYPES
      )
    end

    def constitutive_config
      synoptis_config['constitutive'] || synoptis_config[:constitutive] || {}
    end

    # Best-effort "current session": the most recently modified session dir under
    # the L2 context root. Used when a scan is invoked without an explicit session_id.
    def latest_session_id
      root = context_root
      return nil unless Dir.exist?(root)

      Dir.children(root)
         .select { |c| File.directory?(File.join(root, c)) }
         .max_by { |c| File.mtime(File.join(root, c)) }
    end

    def resolve_agent_id
      mmp_identity.introduce.dig(:identity, :instance_id)
    rescue StandardError
      'unknown'
    end

    def resolve_actor_user_id
      @safety&.current_user&.dig(:user)
    end

    def resolve_actor_role
      @safety&.current_user&.dig(:role) || 'owner'
    end

    def resolve_crypto
      id = mmp_identity
      id.send(:crypto) if id.send(:crypto_available?)
    rescue StandardError
      nil
    end

    def mmp_identity
      @_mmp_identity ||= MMP::Identity.new(
        workspace_root: KairosMcp.data_dir,
        config: mmp_config
      )
    end

    def synoptis_config
      @_synoptis_config ||= load_synoptis_config
    end

    def mmp_config
      ::MMP.load_config
    rescue StandardError
      {}
    end

    private

    def load_synoptis_config
      config_path = File.join(KairosMcp.skillsets_dir, 'synoptis', 'config', 'synoptis.yml')
      if File.exist?(config_path)
        YAML.safe_load(File.read(config_path)) || {}
      else
        {}
      end
    rescue StandardError
      {}
    end
  end
end
