# frozen_string_literal: true

require 'yaml'
require 'digest'
require 'fileutils'

module KairosMcp
  module Meeting
    # ProtocolEvolution manages the co-evolution of MMP protocol extensions.
    # It enables agents to:
    # - Propose new protocol extensions
    # - Evaluate received extensions for safety
    # - Adopt extensions (store in L2)
    # - Promote extensions (L2 -> L1, requires human approval)
    # - Share extensions with other agents
    class ProtocolEvolution
      # Default configuration
      DEFAULT_CONFIG = {
        auto_evaluate: true,
        evaluation_period_days: 7,
        auto_promote: false,
        blocked_actions: %w[execute_code system_command file_write shell_exec eval],
        max_actions_per_extension: 20,
        require_human_approval_for_l1: true
      }.freeze

      # Extension states
      STATE_PENDING = 'pending'       # Received but not evaluated
      STATE_EVALUATING = 'evaluating' # Under evaluation in L2
      STATE_ADOPTED = 'adopted'       # Adopted in L2
      STATE_PROMOTED = 'promoted'     # Promoted to L1
      STATE_REJECTED = 'rejected'     # Rejected (safety or policy)
      STATE_DISABLED = 'disabled'     # Temporarily disabled

      attr_reader :config, :extensions_registry

      def initialize(knowledge_root:, config: {})
        @knowledge_root = knowledge_root
        @config = DEFAULT_CONFIG.merge(config)
        @extensions_registry = {}  # name => extension metadata
        @evaluation_log = []
        
        # Ensure L2 directory exists
        @l2_dir = File.join(@knowledge_root, 'L2_experimental')
        FileUtils.mkdir_p(@l2_dir) unless File.exist?(@l2_dir)
        
        # Load existing extensions
        load_existing_extensions
      end

      # Propose a new extension (create message payload)
      # @param extension_content [String] Markdown content of the extension
      # @return [Hash] Proposal payload for MMP message
      def create_proposal(extension_content:)
        metadata = parse_extension_metadata(extension_content)
        return { error: 'Invalid extension format' } unless metadata

        content_hash = "sha256:#{Digest::SHA256.hexdigest(extension_content)}"

        {
          extension_name: metadata['name'],
          extension_version: metadata['version'] || '1.0.0',
          extension_type: metadata['type'] || 'protocol_extension',
          actions: metadata['actions'] || [],
          requires: metadata['requires'] || [],
          description: metadata['description'],
          content_hash: content_hash,
          layer: 'L2'  # Always propose as L2 (experimental)
        }
      end

      # Evaluate a received extension for safety and compatibility
      # @param extension_content [String] Markdown content
      # @param from_agent [String] Agent ID that sent this
      # @return [Hash] Evaluation result
      def evaluate_extension(extension_content:, from_agent:)
        metadata = parse_extension_metadata(extension_content)
        
        unless metadata
          return {
            status: 'rejected',
            reason: 'invalid_format',
            message: 'Could not parse extension metadata'
          }
        end

        # Safety checks
        safety_result = check_safety(metadata)
        unless safety_result[:safe]
          log_evaluation(metadata['name'], 'rejected', safety_result[:reason], from_agent)
          return {
            status: 'rejected',
            reason: safety_result[:reason],
            message: safety_result[:message],
            blocked_actions: safety_result[:blocked_actions]
          }
        end

        # Compatibility checks
        compat_result = check_compatibility(metadata)
        unless compat_result[:compatible]
          log_evaluation(metadata['name'], 'rejected', 'incompatible', from_agent)
          return {
            status: 'rejected',
            reason: 'incompatible',
            message: compat_result[:message],
            missing_dependencies: compat_result[:missing]
          }
        end

        # All checks passed
        log_evaluation(metadata['name'], 'passed', nil, from_agent)
        
        {
          status: 'passed',
          extension_name: metadata['name'],
          actions: metadata['actions'],
          can_adopt: @config[:auto_evaluate],
          message: 'Extension passed safety and compatibility checks'
        }
      end

      # Adopt an extension (store in L2)
      # @param extension_content [String] Markdown content
      # @param from_agent [String] Agent that provided this
      # @return [Hash] Adoption result
      def adopt_extension(extension_content:, from_agent:)
        # First evaluate
        eval_result = evaluate_extension(extension_content: extension_content, from_agent: from_agent)
        
        unless eval_result[:status] == 'passed'
          return eval_result.merge(adopted: false)
        end

        metadata = parse_extension_metadata(extension_content)
        name = metadata['name']

        # Check if already exists
        if @extensions_registry[name]
          existing = @extensions_registry[name]
          if existing[:state] == STATE_PROMOTED
            return {
              status: 'exists',
              adopted: false,
              message: "Extension '#{name}' already exists in L1",
              current_version: existing[:version]
            }
          end
        end

        # Store in L2
        ext_dir = File.join(@l2_dir, name)
        FileUtils.mkdir_p(ext_dir)
        
        file_path = File.join(ext_dir, "#{name}.md")
        File.write(file_path, extension_content)

        # Update registry
        @extensions_registry[name] = {
          name: name,
          version: metadata['version'] || '1.0.0',
          state: STATE_ADOPTED,
          layer: 'L2',
          actions: metadata['actions'] || [],
          from_agent: from_agent,
          adopted_at: Time.now.utc.iso8601,
          file_path: file_path,
          content_hash: "sha256:#{Digest::SHA256.hexdigest(extension_content)}",
          evaluation_expires_at: (Time.now + (@config[:evaluation_period_days] * 24 * 60 * 60)).utc.iso8601
        }

        save_registry

        {
          status: 'adopted',
          adopted: true,
          extension_name: name,
          layer: 'L2',
          message: "Extension '#{name}' adopted in L2 for evaluation",
          evaluation_period_days: @config[:evaluation_period_days]
        }
      end

      # Request promotion of an extension (L2 -> L1)
      # @param extension_name [String] Name of extension to promote
      # @return [Hash] Promotion request result
      def request_promotion(extension_name:)
        ext = @extensions_registry[extension_name]
        
        unless ext
          return {
            status: 'not_found',
            promoted: false,
            message: "Extension '#{extension_name}' not found"
          }
        end

        unless ext[:state] == STATE_ADOPTED
          return {
            status: 'invalid_state',
            promoted: false,
            message: "Extension is in state '#{ext[:state]}', must be '#{STATE_ADOPTED}' to promote"
          }
        end

        if @config[:require_human_approval_for_l1] && !@config[:auto_promote]
          # Create promotion request (requires human approval)
          ext[:promotion_requested_at] = Time.now.utc.iso8601
          ext[:state] = 'pending_promotion'
          save_registry

          return {
            status: 'pending_approval',
            promoted: false,
            message: "Promotion of '#{extension_name}' requires human approval",
            approval_instructions: "Run: kairos_meeting_place admin promote #{extension_name}"
          }
        end

        # Auto-promote (if configured)
        promote_extension(extension_name: extension_name, approved_by: 'auto')
      end

      # Actually promote an extension (called after human approval)
      # @param extension_name [String] Name of extension
      # @param approved_by [String] Who approved (user ID or 'auto')
      # @return [Hash] Promotion result
      def promote_extension(extension_name:, approved_by:)
        ext = @extensions_registry[extension_name]
        
        unless ext
          return { status: 'not_found', promoted: false }
        end

        # Move file from L2 to L1
        l1_dir = File.join(@knowledge_root, extension_name)
        FileUtils.mkdir_p(l1_dir)
        
        # Read current content and update layer
        content = File.read(ext[:file_path])
        content = update_layer_in_content(content, 'L1')
        
        new_path = File.join(l1_dir, "#{extension_name}.md")
        File.write(new_path, content)

        # Remove from L2
        FileUtils.rm_rf(File.dirname(ext[:file_path]))

        # Update registry
        ext[:state] = STATE_PROMOTED
        ext[:layer] = 'L1'
        ext[:file_path] = new_path
        ext[:promoted_at] = Time.now.utc.iso8601
        ext[:approved_by] = approved_by
        
        save_registry

        {
          status: 'promoted',
          promoted: true,
          extension_name: extension_name,
          layer: 'L1',
          approved_by: approved_by,
          message: "Extension '#{extension_name}' promoted to L1"
        }
      end

      # Disable an extension (rollback)
      # @param extension_name [String] Name of extension
      # @param reason [String] Reason for disabling
      # @return [Hash] Result
      def disable_extension(extension_name:, reason:)
        ext = @extensions_registry[extension_name]
        
        unless ext
          return { status: 'not_found', disabled: false }
        end

        ext[:previous_state] = ext[:state]
        ext[:state] = STATE_DISABLED
        ext[:disabled_at] = Time.now.utc.iso8601
        ext[:disabled_reason] = reason
        
        save_registry

        {
          status: 'disabled',
          disabled: true,
          extension_name: extension_name,
          previous_state: ext[:previous_state],
          message: "Extension '#{extension_name}' disabled: #{reason}"
        }
      end

      # Re-enable a disabled extension
      # @param extension_name [String] Name of extension
      # @return [Hash] Result
      def enable_extension(extension_name:)
        ext = @extensions_registry[extension_name]
        
        unless ext
          return { status: 'not_found', enabled: false }
        end

        unless ext[:state] == STATE_DISABLED
          return { status: 'not_disabled', enabled: false }
        end

        ext[:state] = ext[:previous_state] || STATE_ADOPTED
        ext[:enabled_at] = Time.now.utc.iso8601
        ext.delete(:disabled_reason)
        
        save_registry

        {
          status: 'enabled',
          enabled: true,
          extension_name: extension_name,
          state: ext[:state]
        }
      end

      # Get list of shareable extensions (that can be offered to other agents)
      # @return [Array<Hash>] List of shareable extensions
      def shareable_extensions
        @extensions_registry.values.select do |ext|
          ext[:state] == STATE_PROMOTED && ext[:layer] == 'L1'
        end.map do |ext|
          {
            name: ext[:name],
            version: ext[:version],
            actions: ext[:actions],
            content_hash: ext[:content_hash]
          }
        end
      end

      # Get extension content for sharing
      # @param extension_name [String]
      # @return [String, nil] Content or nil
      def get_extension_content(extension_name)
        ext = @extensions_registry[extension_name]
        return nil unless ext && File.exist?(ext[:file_path])
        
        File.read(ext[:file_path])
      end

      # Get extension status
      # @param extension_name [String]
      # @return [Hash, nil]
      def extension_status(extension_name)
        @extensions_registry[extension_name]
      end

      # List all extensions with their states
      # @return [Hash] Extensions grouped by state
      def list_extensions
        grouped = @extensions_registry.values.group_by { |e| e[:state] }
        
        {
          adopted: grouped[STATE_ADOPTED] || [],
          promoted: grouped[STATE_PROMOTED] || [],
          pending_promotion: grouped['pending_promotion'] || [],
          disabled: grouped[STATE_DISABLED] || [],
          rejected: grouped[STATE_REJECTED] || []
        }
      end

      private

      def parse_extension_metadata(content)
        return nil unless content.start_with?('---')
        
        parts = content.split('---', 3)
        return nil if parts.size < 3
        
        YAML.safe_load(parts[1], permitted_classes: [Symbol])
      rescue StandardError
        nil
      end

      def check_safety(metadata)
        actions = metadata['actions'] || []
        blocked = actions & @config[:blocked_actions]
        
        if blocked.any?
          return {
            safe: false,
            reason: 'blocked_actions',
            message: "Extension contains blocked actions: #{blocked.join(', ')}",
            blocked_actions: blocked
          }
        end

        if actions.size > @config[:max_actions_per_extension]
          return {
            safe: false,
            reason: 'too_many_actions',
            message: "Extension has #{actions.size} actions, max is #{@config[:max_actions_per_extension]}"
          }
        end

        # Check for suspicious patterns in action names
        suspicious = actions.select { |a| a.match?(/exec|eval|system|shell|command/i) }
        if suspicious.any?
          return {
            safe: false,
            reason: 'suspicious_actions',
            message: "Extension contains suspicious action names: #{suspicious.join(', ')}",
            blocked_actions: suspicious
          }
        end

        { safe: true }
      end

      def check_compatibility(metadata)
        requires = metadata['requires'] || []
        
        # For now, we only require meeting_protocol_core
        # In Phase 7+, we could check against actually loaded protocols
        missing = requires.reject do |req|
          req == 'meeting_protocol_core' || @extensions_registry[req]
        end

        if missing.any?
          return {
            compatible: false,
            message: "Missing required extensions: #{missing.join(', ')}",
            missing: missing
          }
        end

        { compatible: true }
      end

      def log_evaluation(name, result, reason, from_agent)
        @evaluation_log << {
          timestamp: Time.now.utc.iso8601,
          extension_name: name,
          result: result,
          reason: reason,
          from_agent: from_agent
        }
      end

      def load_existing_extensions
        registry_file = File.join(@knowledge_root, '.extensions_registry.yml')
        if File.exist?(registry_file)
          data = YAML.safe_load(File.read(registry_file), permitted_classes: [Symbol])
          @extensions_registry = data.transform_keys(&:to_s) if data
        end
      rescue StandardError => e
        warn "[ProtocolEvolution] Error loading registry: #{e.message}"
      end

      def save_registry
        registry_file = File.join(@knowledge_root, '.extensions_registry.yml')
        File.write(registry_file, YAML.dump(@extensions_registry))
      end

      def update_layer_in_content(content, new_layer)
        content.sub(/^layer:\s*L\d/m, "layer: #{new_layer}")
      end
    end
  end
end
