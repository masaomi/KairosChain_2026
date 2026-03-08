# frozen_string_literal: true

require_relative 'skillset_creator/scaffold_generator'
require_relative 'skillset_creator/review_templates'

module SkillsetCreator
  SKILLSET_ROOT = File.expand_path('..', __dir__)
  KNOWLEDGE_DIR = File.join(SKILLSET_ROOT, 'knowledge')
  VERSION = '1.0.0'

  class << self
    def load!(config: {})
      @config = config
      @loaded = true
    end

    def loaded?
      @loaded == true
    end

    def unload!
      @config = nil
      @loaded = false
    end

    def provider(user_context: nil)
      provider = KairosMcp::KnowledgeProvider.new(nil, user_context: user_context)
      provider.add_external_dir(
        KNOWLEDGE_DIR,
        source: 'skillset:skillset_creator',
        layer: :L1,
        index: true
      )
      provider
    end

    def skillset_config
      @skillset_config ||= begin
        config_path = File.join(SKILLSET_ROOT, 'config', 'skillset_creator.yml')
        if File.exist?(config_path)
          YAML.safe_load(File.read(config_path, encoding: 'UTF-8'))&.dig('skillset_creator') || {}
        else
          {}
        end
      end
    end

    # Runtime detection of Knowledge Creator integration (v2.1 fix)
    def knowledge_creator_available?
      defined?(::KnowledgeCreator) && ::KnowledgeCreator.loaded?
    rescue StandardError
      false
    end
  end

  load! unless loaded?
end
