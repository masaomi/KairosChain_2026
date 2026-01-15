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
      'immutable_skills' => ['core_safety']
    }.freeze
    
    def self.load
      return DEFAULTS.dup unless File.exist?(CONFIG_PATH)
      YAML.safe_load(File.read(CONFIG_PATH)) || DEFAULTS.dup
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
  end
end
