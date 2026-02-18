# frozen_string_literal: true

# MMP - Model Meeting Protocol
# Standalone SkillSet for P2P agent communication
module MMP
  SKILLSET_ROOT = File.expand_path('..', __dir__)
  VERSION = '1.0.0'

  autoload :ChainAdapter, File.join(__dir__, 'mmp/chain_adapter')
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

  def self.config_path
    File.join(SKILLSET_ROOT, 'config', 'meeting.yml')
  end

  def self.load_config
    return default_config unless File.exist?(config_path)
    require 'yaml'
    YAML.load_file(config_path) || default_config
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
