# frozen_string_literal: true

require_relative 'knowledge_creator/assembly_templates'

module KnowledgeCreator
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

    # Build a KnowledgeProvider that includes bundled knowledge.
    # Each tool calls this to access SkillSet-local knowledge.
    def provider(user_context: nil)
      provider = KairosMcp::KnowledgeProvider.new(nil, user_context: user_context)
      provider.add_external_dir(
        KNOWLEDGE_DIR,
        source: 'skillset:knowledge_creator',
        layer: :L1,
        index: true
      )
      provider
    end

    def skillset_config
      @skillset_config ||= begin
        config_path = File.join(SKILLSET_ROOT, 'config', 'knowledge_creator.yml')
        if File.exist?(config_path)
          YAML.safe_load(File.read(config_path, encoding: 'UTF-8'))&.dig('knowledge_creator') || {}
        else
          {}
        end
      end
    end
  end

  load! unless loaded?
end
