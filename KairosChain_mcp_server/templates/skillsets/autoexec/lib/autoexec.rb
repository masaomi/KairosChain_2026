# frozen_string_literal: true

require 'yaml'
require 'json'
require 'digest'
require 'fileutils'
require 'time'

require_relative 'autoexec/task_dsl'
require_relative 'autoexec/risk_classifier'
require_relative 'autoexec/plan_store'

module Autoexec
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

    def storage_path(subdir)
      base = if defined?(KairosMcp) && KairosMcp.respond_to?(:kairos_dir)
               File.join(KairosMcp.kairos_dir, 'autoexec', subdir)
             else
               File.join(Dir.pwd, '.kairos', 'autoexec', subdir)
             end
      FileUtils.mkdir_p(base) unless Dir.exist?(base)
      base
    end

    private

    def default_config_path
      candidates = [
        File.join(Dir.pwd, '.kairos', 'skillsets', 'autoexec', 'config', 'autoexec.yml'),
        File.expand_path('../../../config/autoexec.yml', __FILE__)
      ]
      candidates.find { |p| File.exist?(p) }
    end
  end

  load! unless loaded?
end
