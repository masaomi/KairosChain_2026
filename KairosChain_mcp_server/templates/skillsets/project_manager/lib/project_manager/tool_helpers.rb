# frozen_string_literal: true

require 'yaml'

module ProjectManager
  module ToolHelpers
    def pm_store
      @_pm_store ||= Store.new
    end

    def pm_config
      @_pm_config ||= begin
        path = File.expand_path('../../config/pm.yml', __dir__)
        File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
      end
    end

    def pm_digest
      Digest.new(pm_store, pm_config['digest'])
    end
  end
end
