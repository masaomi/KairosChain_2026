# frozen_string_literal: true

require 'yaml'
require 'digest'
require 'fileutils'

module MMP
  class ProtocolEvolution
    DEFAULT_CONFIG = { auto_evaluate: true, evaluation_period_days: 7, auto_promote: false, blocked_actions: %w[execute_code system_command file_write shell_exec eval], max_actions_per_extension: 20, require_human_approval_for_l1: true }.freeze

    attr_reader :config, :extensions_registry

    def initialize(knowledge_root:, config: {})
      @knowledge_root = knowledge_root
      @config = DEFAULT_CONFIG.merge(config)
      @extensions_registry = {}
      @l2_dir = File.join(@knowledge_root, 'L2_experimental')
      FileUtils.mkdir_p(@l2_dir) unless File.exist?(@l2_dir)
      load_existing_extensions
    end

    def create_proposal(extension_content:)
      metadata = parse_extension_metadata(extension_content)
      return { error: 'Invalid extension format' } unless metadata
      { extension_name: metadata['name'], extension_version: metadata['version'] || '1.0.0', actions: metadata['actions'] || [], requires: metadata['requires'] || [], description: metadata['description'], content_hash: "sha256:#{Digest::SHA256.hexdigest(extension_content)}", layer: 'L2' }
    end

    def evaluate_extension(extension_content:, from_agent:)
      metadata = parse_extension_metadata(extension_content)
      return { status: 'rejected', reason: 'invalid_format' } unless metadata
      safety = check_safety(metadata)
      return { status: 'rejected', reason: safety[:reason], blocked_actions: safety[:blocked_actions] } unless safety[:safe]
      compat = check_compatibility(metadata)
      return { status: 'rejected', reason: 'incompatible', missing: compat[:missing] } unless compat[:compatible]
      { status: 'passed', extension_name: metadata['name'], actions: metadata['actions'], can_adopt: @config[:auto_evaluate] }
    end

    def adopt_extension(extension_content:, from_agent:)
      eval_result = evaluate_extension(extension_content: extension_content, from_agent: from_agent)
      return eval_result.merge(adopted: false) unless eval_result[:status] == 'passed'
      metadata = parse_extension_metadata(extension_content)
      name = metadata['name']
      ext_dir = File.join(@l2_dir, name); FileUtils.mkdir_p(ext_dir)
      file_path = File.join(ext_dir, "#{name}.md"); File.write(file_path, extension_content)
      @extensions_registry[name] = { name: name, version: metadata['version'] || '1.0.0', state: 'adopted', layer: 'L2', actions: metadata['actions'] || [], from_agent: from_agent, adopted_at: Time.now.utc.iso8601, file_path: file_path, content_hash: "sha256:#{Digest::SHA256.hexdigest(extension_content)}" }
      save_registry
      { status: 'adopted', adopted: true, extension_name: name, layer: 'L2' }
    end

    def get_extension_content(extension_name)
      ext = @extensions_registry[extension_name]
      return nil unless ext && File.exist?(ext[:file_path])
      File.read(ext[:file_path])
    end

    def extension_status(extension_name) = @extensions_registry[extension_name]

    def list_extensions
      grouped = @extensions_registry.values.group_by { |e| e[:state] }
      { adopted: grouped['adopted'] || [], promoted: grouped['promoted'] || [], disabled: grouped['disabled'] || [] }
    end

    private

    def parse_extension_metadata(content)
      return nil unless content&.start_with?('---')
      parts = content.split('---', 3)
      return nil if parts.size < 3
      YAML.safe_load(parts[1], permitted_classes: [Symbol])
    rescue StandardError
      nil
    end

    def check_safety(metadata)
      actions = metadata['actions'] || []
      blocked = actions & @config[:blocked_actions]
      return { safe: false, reason: 'blocked_actions', blocked_actions: blocked } if blocked.any?
      return { safe: false, reason: 'too_many_actions' } if actions.size > @config[:max_actions_per_extension]
      suspicious = actions.select { |a| a.match?(/exec|eval|system|shell|command/i) }
      return { safe: false, reason: 'suspicious_actions', blocked_actions: suspicious } if suspicious.any?
      { safe: true }
    end

    def check_compatibility(metadata)
      missing = (metadata['requires'] || []).reject { |r| r == 'meeting_protocol_core' || @extensions_registry[r] }
      missing.any? ? { compatible: false, missing: missing } : { compatible: true }
    end

    def load_existing_extensions
      registry_file = File.join(@knowledge_root, '.extensions_registry.yml')
      return unless File.exist?(registry_file)
      data = YAML.safe_load(File.read(registry_file), permitted_classes: [Symbol])
      @extensions_registry = data.transform_keys(&:to_s) if data
    rescue StandardError; end

    def save_registry
      File.write(File.join(@knowledge_root, '.extensions_registry.yml'), YAML.dump(@extensions_registry))
    end
  end
end
