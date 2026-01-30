# frozen_string_literal: true

require 'yaml'
require 'digest'

module KairosMcp
  module Meeting
    # ProtocolLoader loads MMP protocol definitions from skill files.
    # It handles the bootstrap problem by loading core protocols first,
    # then dynamically loading extensions.
    #
    # Protocol definitions are stored in knowledge/ as Markdown files
    # with YAML frontmatter containing action definitions.
    class ProtocolLoader
      PROTOCOL_TYPE = 'protocol_definition'
      EXTENSION_TYPE = 'protocol_extension'

      attr_reader :loaded_protocols, :available_actions, :extensions

      def initialize(knowledge_root:)
        @knowledge_root = knowledge_root
        @loaded_protocols = {}
        @available_actions = []
        @extensions = []
        @action_handlers = {}
      end

      # Load all protocol definitions
      # @return [Hash] Summary of loaded protocols
      def load_all
        # Step 1: Load bootstrap protocols (core)
        bootstrap_protocols = load_bootstrap_protocols
        
        # Step 2: Load extension protocols
        extension_protocols = load_extension_protocols
        
        # Step 3: Build action registry
        build_action_registry
        
        {
          bootstrap_count: bootstrap_protocols.size,
          extension_count: extension_protocols.size,
          total_actions: @available_actions.size,
          actions: @available_actions,
          extensions: @extensions,
          protocols: @loaded_protocols.keys
        }
      end

      # Load only bootstrap (core) protocols
      # @return [Array<Hash>] Loaded bootstrap protocols
      def load_bootstrap_protocols
        protocols = find_protocol_files.select do |file|
          metadata = parse_frontmatter(file)
          metadata && metadata['bootstrap'] == true
        end

        protocols.map do |file|
          load_protocol_file(file)
        end.compact
      end

      # Load extension protocols (non-bootstrap)
      # @return [Array<Hash>] Loaded extension protocols
      def load_extension_protocols
        protocols = find_protocol_files.reject do |file|
          metadata = parse_frontmatter(file)
          metadata && metadata['bootstrap'] == true
        end

        protocols.map do |file|
          load_protocol_file(file)
        end.compact
      end

      # Load a specific extension by name
      # @param extension_name [String] Name of the extension to load
      # @return [Hash, nil] Loaded extension or nil
      def load_extension(extension_name)
        file = find_protocol_files.find do |f|
          metadata = parse_frontmatter(f)
          metadata && metadata['name'] == extension_name
        end

        return nil unless file

        load_protocol_file(file)
      end

      # Check if an action is supported
      # @param action [String] Action name
      # @return [Boolean]
      def action_supported?(action)
        @available_actions.include?(action)
      end

      # Get action definition
      # @param action [String] Action name
      # @return [Hash, nil] Action definition or nil
      def action_definition(action)
        @action_handlers[action]
      end

      # Get all core (immutable) actions
      # @return [Array<String>]
      def core_actions
        core_protocol = @loaded_protocols.values.find { |p| p[:bootstrap] }
        return [] unless core_protocol

        core_protocol[:actions] || []
      end

      # Get extension actions (non-core)
      # @return [Array<String>]
      def extension_actions
        @available_actions - core_actions
      end

      # Check if an extension is loaded
      # @param extension_name [String]
      # @return [Boolean]
      def extension_loaded?(extension_name)
        @extensions.include?(extension_name)
      end

      # Get protocol definition by name
      # @param name [String] Protocol name
      # @return [Hash, nil]
      def get_protocol(name)
        @loaded_protocols[name]
      end

      # Reload all protocols (useful after receiving new extensions)
      def reload!
        @loaded_protocols = {}
        @available_actions = []
        @extensions = []
        @action_handlers = {}
        load_all
      end

      private

      # Find all protocol definition files in knowledge/
      # @return [Array<String>] File paths
      def find_protocol_files
        pattern = File.join(@knowledge_root, '*', '*.md')
        Dir.glob(pattern).select do |file|
          metadata = parse_frontmatter(file)
          metadata && [PROTOCOL_TYPE, EXTENSION_TYPE].include?(metadata['type'])
        end
      end

      # Parse YAML frontmatter from a Markdown file
      # @param file_path [String]
      # @return [Hash, nil]
      def parse_frontmatter(file_path)
        content = File.read(file_path)
        return nil unless content.start_with?('---')

        # Extract frontmatter
        parts = content.split('---', 3)
        return nil if parts.size < 3

        YAML.safe_load(parts[1], permitted_classes: [Symbol])
      rescue StandardError => e
        warn "[ProtocolLoader] Error parsing #{file_path}: #{e.message}"
        nil
      end

      # Load a single protocol file
      # @param file_path [String]
      # @return [Hash, nil]
      def load_protocol_file(file_path)
        content = File.read(file_path)
        metadata = parse_frontmatter(file_path)
        return nil unless metadata

        name = metadata['name']
        return nil unless name

        # Check dependencies
        requires = metadata['requires'] || []
        requires.each do |req|
          unless @loaded_protocols.key?(req)
            warn "[ProtocolLoader] #{name} requires #{req} which is not loaded"
            # Try to load the dependency first
            dep_loaded = load_extension(req)
            unless dep_loaded
              warn "[ProtocolLoader] Could not load dependency #{req} for #{name}"
              return nil
            end
          end
        end

        protocol = {
          name: name,
          file_path: file_path,
          layer: metadata['layer'] || 'L2',
          type: metadata['type'],
          version: metadata['version'] || '1.0.0',
          bootstrap: metadata['bootstrap'] == true,
          immutable: metadata['immutable'] == true,
          actions: metadata['actions'] || [],
          extends: metadata['extends'],
          requires: requires,
          description: metadata['description'],
          content_hash: Digest::SHA256.hexdigest(content),
          loaded_at: Time.now.utc.iso8601
        }

        @loaded_protocols[name] = protocol

        # Register actions
        protocol[:actions].each do |action|
          unless @available_actions.include?(action)
            @available_actions << action
            @action_handlers[action] = {
              protocol: name,
              layer: protocol[:layer],
              immutable: protocol[:immutable]
            }
          end
        end

        # Track extensions
        if protocol[:type] == EXTENSION_TYPE && !@extensions.include?(name)
          @extensions << name
        end

        protocol
      end

      # Build the complete action registry
      def build_action_registry
        # Sort actions: core first, then by layer
        @available_actions.sort_by! do |action|
          handler = @action_handlers[action]
          layer_order = { 'L0' => 0, 'L1' => 1, 'L2' => 2 }
          [
            handler[:immutable] ? 0 : 1,
            layer_order[handler[:layer]] || 3
          ]
        end
      end
    end
  end
end
