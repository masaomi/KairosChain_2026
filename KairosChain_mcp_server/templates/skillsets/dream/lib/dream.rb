# frozen_string_literal: true

require 'yaml'
require 'json'
require 'fileutils'
require 'time'

require_relative 'dream/scanner'
require_relative 'dream/proposer'
require_relative 'dream/archiver'

module Dream
  SKILLSET_ROOT = File.expand_path('..', __dir__)
  KNOWLEDGE_DIR = File.join(SKILLSET_ROOT, 'knowledge')

  class << self
    def load!(config_path = nil)
      return if loaded?

      path = config_path || default_config_path
      @config = if path && File.exist?(path)
                  YAML.safe_load(File.read(path), permitted_classes: [Symbol]) || {}
                else
                  {}
                end
      @loaded = true
    end

    def loaded?
      @loaded == true
    end

    def unload!
      @config = nil
      @loaded = false
    end

    def config
      load! unless loaded?
      @config
    end

    def provider(user_context: nil)
      return nil unless defined?(KairosMcp::KnowledgeProvider)

      provider = KairosMcp::KnowledgeProvider.new(nil, user_context: user_context)
      provider.add_external_dir(
        KNOWLEDGE_DIR,
        source: 'skillset:dream',
        layer: :L1,
        index: true
      )
      provider
    end

    def storage_path(subdir)
      base = if defined?(KairosMcp) && KairosMcp.respond_to?(:kairos_dir)
               File.join(KairosMcp.kairos_dir, 'dream', subdir)
             else
               File.join(Dir.pwd, '.kairos', 'dream', subdir)
             end
      FileUtils.mkdir_p(base) unless Dir.exist?(base)
      base
    end

    private

    def default_config_path
      candidates = [
        File.join(Dir.pwd, '.kairos', 'skillsets', 'dream', 'config', 'dream.yml'),
        File.expand_path('../../../config/dream.yml', __FILE__)
      ]
      candidates.find { |p| File.exist?(p) }
    end
  end

  load! unless loaded?
end
