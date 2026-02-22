# frozen_string_literal: true

require 'yaml'
require 'json'

module Hestia
  SKILLSET_ROOT = File.expand_path('..', __dir__)
  VERSION = '0.1.0'

  # Eagerly load chain components (needed by adapter and tools)
  require_relative 'hestia/chain/core/anchor'
  require_relative 'hestia/chain/core/config'
  require_relative 'hestia/chain/core/batch_processor'
  require_relative 'hestia/chain/core/client'
  require_relative 'hestia/chain/backend/base'
  require_relative 'hestia/chain/backend/in_memory'
  require_relative 'hestia/chain/protocol'
  require_relative 'hestia/chain/integrations/base'
  require_relative 'hestia/chain/integrations/meeting_protocol'

  # SkillSet-specific modules
  require_relative 'hestia/hestia_chain_adapter'
  require_relative 'hestia/chain_migrator'

  # Config resolution (supports both installed & template locations)
  def self.config_path
    if defined?(KairosMcp)
      installed = File.join(KairosMcp.skillsets_dir, 'hestia', 'config', 'hestia.yml')
      return installed if File.exist?(installed)
    end
    File.join(SKILLSET_ROOT, 'config', 'hestia.yml')
  end

  def self.load_config
    path = config_path
    return default_config unless File.exist?(path)
    YAML.load_file(path) || default_config
  rescue StandardError
    default_config
  end

  def self.default_config
    {
      'enabled' => false,
      'meeting_place' => {
        'enabled' => false,
        'name' => 'KairosChain Meeting Place',
        'max_agents' => 100,
        'session_timeout' => 3600
      },
      'chain' => {
        'backend' => 'in_memory',
        'enabled' => true
      },
      'trust_anchor' => {
        'record_exchanges' => true,
        'record_registrations' => true
      }
    }
  end

  # Create a configured HestiaChain client
  def self.chain_client(config: nil)
    chain_config = config || load_config.dig('chain') || {}
    Chain::Core::Client.new(config: chain_config)
  end

  # Create a configured HestiaChainAdapter (MMP::ChainAdapter)
  def self.chain_adapter(config: nil)
    chain_config = config || Chain::Core::Config.new(load_config.dig('chain') || {})
    HestiaChainAdapter.new(config: chain_config)
  end
end
