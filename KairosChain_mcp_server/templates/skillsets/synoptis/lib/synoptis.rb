# frozen_string_literal: true

# Synoptis - Mutual Attestation Protocol
# Enables inter-agent trust building through cryptographic attestation proofs
module Synoptis
  SKILLSET_ROOT = File.expand_path('..', __dir__)
  VERSION = '0.1.0'

  autoload :ClaimTypes, File.join(__dir__, 'synoptis/claim_types')
  autoload :ProofEnvelope, File.join(__dir__, 'synoptis/proof_envelope')
  autoload :MerkleTree, File.join(__dir__, 'synoptis/merkle')
  autoload :Verifier, File.join(__dir__, 'synoptis/verifier')
  autoload :RevocationManager, File.join(__dir__, 'synoptis/revocation_manager')
  autoload :AttestationEngine, File.join(__dir__, 'synoptis/attestation_engine')
  autoload :TrustScorer, File.join(__dir__, 'synoptis/trust_scorer')
  autoload :GraphAnalyzer, File.join(__dir__, 'synoptis/graph_analyzer')
  autoload :ChallengeManager, File.join(__dir__, 'synoptis/challenge_manager')

  # Registry backends
  module Registry
    autoload :Base, File.join(__dir__, 'synoptis/registry/base')
    autoload :FileRegistry, File.join(__dir__, 'synoptis/registry/file_registry')
  end

  # Transport backends
  module Transport
    autoload :Base, File.join(__dir__, 'synoptis/transport/base')
    autoload :Router, File.join(__dir__, 'synoptis/transport/router')
    autoload :MMPTransport, File.join(__dir__, 'synoptis/transport/mmp_transport')
    autoload :HestiaTransport, File.join(__dir__, 'synoptis/transport/hestia_transport')
    autoload :LocalTransport, File.join(__dir__, 'synoptis/transport/local_transport')
  end

  # Resolve config path dynamically
  def self.config_path
    if defined?(KairosMcp)
      installed = File.join(KairosMcp.skillsets_dir, 'synoptis', 'config', 'synoptis.yml')
      return installed if File.exist?(installed)
    end
    File.join(SKILLSET_ROOT, 'config', 'synoptis.yml')
  end

  def self.load_config
    path = config_path
    return default_config unless File.exist?(path)
    require 'yaml'
    YAML.safe_load_file(path, permitted_classes: []) || default_config
  rescue StandardError => e
    $stderr.puts "[Synoptis] WARNING: Failed to load config from #{path}: #{e.class}: #{e.message}"
    default_config
  end

  def self.default_config
    {
      'enabled' => false,
      'attestation' => {
        'default_expiry_days' => 180,
        'min_evidence_fields' => 2,
        'allow_self_attestation' => false,
        'auto_reciprocate' => false
      },
      'trust' => {
        'score_half_life_days' => 90,
        'cluster_threshold' => 0.8,
        'velocity_threshold_24h' => 10,
        'min_diversity' => 0.3
      },
      'challenge' => {
        'response_window_hours' => 72,
        'max_active_challenges' => 5
      },
      'storage' => {
        'backend' => 'file',
        'file_path' => 'storage/synoptis'
      },
      'transport' => {
        'priority' => %w[mmp hestia local]
      },
      'revocation' => {
        'allow_third_party' => false,
        'check_re_issuance' => true
      }
    }
  end

  # Load Synoptis SkillSet: register hooks and log startup
  def self.load!
    return if @loaded

    config = load_config
    unless config['enabled']
      $stderr.puts "[Synoptis] disabled by config (enabled: false)"
      return
    end
    require_relative 'synoptis/hooks/mmp_hooks'
    Hooks.register_mmp_actions!

    store = config.dig('storage', 'backend') || 'file'
    transport = (config.dig('transport', 'priority') || ['mmp']).first
    $stderr.puts "[Synoptis] v#{VERSION} loaded (transport: #{transport}, store: #{store})"
    @loaded = true
  end

  # Storage path resolution
  def self.storage_path(config = nil)
    config ||= load_config
    base = config.dig('storage', 'file_path') || 'storage/synoptis'

    if defined?(KairosMcp)
      File.join(KairosMcp.storage_dir, 'synoptis')
    else
      File.join(SKILLSET_ROOT, base)
    end
  end

  # Create a configured AttestationEngine
  def self.engine(config: nil)
    config ||= load_config
    registry = Registry::FileRegistry.new(storage_path: storage_path(config))
    engine = AttestationEngine.new(config: config, registry: registry)
    engine.transport_router = Transport::Router.new(config: config)
    engine
  end
end

# Auto-initialize when running inside KairosMcp
Synoptis.load! if defined?(KairosMcp)
