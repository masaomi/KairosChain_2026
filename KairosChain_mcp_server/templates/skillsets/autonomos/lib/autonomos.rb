# frozen_string_literal: true

require 'yaml'
require 'json'
require 'digest'
require 'fileutils'
require 'time'
require 'open3'

require_relative 'autonomos/cycle_store'
require_relative 'autonomos/mandate'
require_relative 'autonomos/ooda'
require_relative 'autonomos/reflector'

module Autonomos
  SKILLSET_ROOT = File.expand_path('..', __dir__)
  KNOWLEDGE_DIR = File.join(SKILLSET_ROOT, 'knowledge')
  VERSION = '0.1.0'

  class DependencyError < StandardError; end

  class << self
    def load!(config_path = nil)
      return if loaded?

      # Hard dependency: autoexec must be available
      unless defined?(::Autoexec)
        raise DependencyError,
              'Autonomos requires the autoexec SkillSet. Install it first: kairos-chain skillset install autoexec'
      end

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
        source: 'skillset:autonomos',
        layer: :L1,
        index: true
      )
      provider
    end

    def storage_path(subdir)
      base = if defined?(KairosMcp) && KairosMcp.respond_to?(:data_dir)
               File.join(KairosMcp.data_dir, 'autonomos', subdir)
             else
               File.join(Dir.pwd, '.kairos', 'autonomos', subdir)
             end
      FileUtils.mkdir_p(base) unless Dir.exist?(base)
      base
    end

    # Read git state safely using Open3 (no shell interpolation)
    def git_observation
      return { git_available: false, reason: 'disabled' } unless config.fetch('git_observation', true)

      # Check if git is available and we're in a repo
      out, status = Open3.capture2('git', 'rev-parse', '--is-inside-work-tree')
      unless status.success?
        return { git_available: false, reason: 'not a git repository' }
      end

      result = { git_available: true }

      # Branch
      branch, _ = Open3.capture2('git', 'rev-parse', '--abbrev-ref', 'HEAD')
      result[:branch] = branch.strip

      # Status (short)
      status_out, _ = Open3.capture2('git', 'status', '--short')
      result[:status] = status_out.strip.split("\n").first(20)

      # Recent commits
      log_out, _ = Open3.capture2('git', 'log', '--oneline', '-10')
      result[:recent_commits] = log_out.strip.split("\n")

      result
    rescue Errno::ENOENT
      { git_available: false, reason: 'git not installed' }
    end

    private

    def default_config_path
      candidates = [
        File.join(Dir.pwd, '.kairos', 'skillsets', 'autonomos', 'config', 'autonomos.yml'),
        File.expand_path('../../../config/autonomos.yml', __FILE__)
      ]
      candidates.find { |p| File.exist?(p) }
    end
  end

  # Defer load! — will be called on first tool use to allow autoexec to load first
end
