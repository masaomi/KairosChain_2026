require 'yaml'
require 'fileutils'

module KairosMcp
  class SkillsConfig
    CONFIG_PATH = File.expand_path('../../skills/config.yml', __dir__)
    
    DEFAULTS = {
      'enabled' => true,
      'evolution_enabled' => false,
      'max_evolutions_per_session' => 3,
      'require_human_approval' => true,
      'immutable_skills' => ['core_safety'],
      'layers' => {
        'L0_constitution' => { 'enabled' => true, 'mutable' => false },
        'L0_law' => { 'enabled' => true, 'mutable' => true, 'require_blockchain' => 'full' },
        'L1' => { 'enabled' => true, 'mutable' => true, 'require_blockchain' => 'hash_only' },
        'L2' => { 'enabled' => true, 'mutable' => true, 'require_blockchain' => 'none' }
      },
      'kairos_meta_skills' => %w[core_safety evolution_rules self_inspection chain_awareness]
    }.freeze
    
    def self.load
      return DEFAULTS.dup unless File.exist?(CONFIG_PATH)
      loaded = YAML.safe_load(File.read(CONFIG_PATH)) || {}
      DEFAULTS.merge(loaded)
    rescue StandardError
      DEFAULTS.dup
    end
    
    def self.save(config)
      FileUtils.mkdir_p(File.dirname(CONFIG_PATH))
      File.write(CONFIG_PATH, config.to_yaml)
    end
    
    def self.enabled?
      load['enabled']
    end
    
    def self.evolution_enabled?
      load['evolution_enabled'] && enabled?
    end
    
    def self.disable!
      config = load
      config['enabled'] = false
      save(config)
    end

    # Layer-specific configuration methods

    def self.layer_config(layer)
      layers = load['layers'] || {}
      layers[layer.to_s] || {}
    end

    def self.layer_enabled?(layer)
      config = layer_config(layer)
      config['enabled'] != false
    end

    def self.layer_mutable?(layer)
      config = layer_config(layer)
      config['mutable'] == true
    end

    def self.layer_blockchain_mode(layer)
      config = layer_config(layer)
      (config['require_blockchain'] || 'none').to_sym
    end

    def self.layer_requires_approval?(layer)
      config = layer_config(layer)
      config['require_human_approval'] == true
    end

    def self.kairos_meta_skills
      load['kairos_meta_skills'] || DEFAULTS['kairos_meta_skills']
    end

    def self.kairos_meta_skill?(skill_id)
      kairos_meta_skills.include?(skill_id.to_s)
    end
  end
end
