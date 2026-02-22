# frozen_string_literal: true

# MMP - Model Meeting Protocol
# Standalone SkillSet for P2P agent communication
module MMP
  SKILLSET_ROOT = File.expand_path('..', __dir__)
  VERSION = '1.0.0'

  # ChainAdapter and its implementations must be eagerly loaded
  # since NullChainAdapter/KairosChainAdapter are referenced as MMP::*
  require_relative 'mmp/chain_adapter'

  autoload :Protocol, File.join(__dir__, 'mmp/protocol')
  autoload :Identity, File.join(__dir__, 'mmp/identity')
  autoload :PeerManager, File.join(__dir__, 'mmp/peer_manager')
  autoload :Crypto, File.join(__dir__, 'mmp/crypto')
  autoload :SkillExchange, File.join(__dir__, 'mmp/skill_exchange')
  autoload :InteractionLog, File.join(__dir__, 'mmp/interaction_log')
  autoload :ProtocolLoader, File.join(__dir__, 'mmp/protocol_loader')
  autoload :ProtocolEvolution, File.join(__dir__, 'mmp/protocol_evolution')
  autoload :Compatibility, File.join(__dir__, 'mmp/compatibility')
  autoload :PlaceClient, File.join(__dir__, 'mmp/place_client')

  # Resolve config path dynamically: prefer the installed SkillSet config
  # in the current data directory, fall back to the bundled template config.
  def self.config_path
    if defined?(KairosMcp)
      installed = File.join(KairosMcp.skillsets_dir, 'mmp', 'config', 'meeting.yml')
      return installed if File.exist?(installed)
    end
    File.join(SKILLSET_ROOT, 'config', 'meeting.yml')
  end

  def self.load_config
    path = config_path
    return default_config unless File.exist?(path)
    require 'yaml'
    YAML.load_file(path) || default_config
  rescue StandardError
    default_config
  end

  def self.default_config
    {
      'enabled' => false,
      'identity' => { 'name' => 'KairosChain Instance', 'scope' => 'general' },
      'capabilities' => { 'meeting_protocol_version' => '1.0.0' },
      'skill_exchange' => { 'allowed_formats' => %w[markdown yaml_frontmatter] },
      'constraints' => { 'max_skill_size_bytes' => 100_000 }
    }
  end
end
