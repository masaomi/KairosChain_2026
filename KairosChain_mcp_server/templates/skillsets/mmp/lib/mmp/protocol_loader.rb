# frozen_string_literal: true

require 'yaml'
require 'digest'
require 'set'
require 'time'

module MMP
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

    def load_all
      bootstrap_protocols = load_bootstrap_protocols
      extension_protocols = load_extension_protocols
      build_action_registry
      { bootstrap_count: bootstrap_protocols.size, extension_count: extension_protocols.size, total_actions: @available_actions.size, actions: @available_actions, extensions: @extensions, protocols: @loaded_protocols.keys }
    end

    def load_bootstrap_protocols
      find_protocol_files.select { |f| (m = parse_frontmatter(f)) && m['bootstrap'] == true }.filter_map { |f| load_protocol_file(f) }
    end

    def load_extension_protocols
      files = find_protocol_files.reject { |f| (m = parse_frontmatter(f)) && m['bootstrap'] == true }
      sort_by_dependencies(files).filter_map { |f| load_protocol_file(f) }
    end

    def sort_by_dependencies(files)
      name_to_file = {}; file_to_metadata = {}
      files.each { |f| m = parse_frontmatter(f); next unless m&.dig('name'); name_to_file[m['name']] = f; file_to_metadata[f] = m }
      sorted = []; visited = Set.new; temp = Set.new
      visit = lambda do |file|
        return if visited.include?(file) || temp.include?(file)
        temp.add(file); m = file_to_metadata[file]
        (m&.dig('requires') || []).each { |r| next if @loaded_protocols.key?(r); visit.call(name_to_file[r]) if name_to_file[r] }
        temp.delete(file); visited.add(file); sorted << file
      end
      files.each { |f| visit.call(f) }; sorted
    end

    def action_supported?(action) = @available_actions.include?(action)
    def action_definition(action) = @action_handlers[action]
    def core_actions
      core = @loaded_protocols.values.find { |p| p[:bootstrap] }
      core ? (core[:actions] || []) : []
    end
    def extension_actions = @available_actions - core_actions
    def extension_loaded?(name) = @extensions.include?(name)
    def get_protocol(name) = @loaded_protocols[name]
    def reload!
      @loaded_protocols = {}; @available_actions = []; @extensions = []; @action_handlers = {}; load_all
    end

    private

    def find_protocol_files
      Dir.glob(File.join(@knowledge_root, '*', '*.md')).select { |f| m = parse_frontmatter(f); m && [PROTOCOL_TYPE, EXTENSION_TYPE].include?(m['type']) }
    end

    def parse_frontmatter(file_path)
      content = File.read(file_path)
      return nil unless content.start_with?('---')
      parts = content.split('---', 3)
      return nil if parts.size < 3
      YAML.safe_load(parts[1], permitted_classes: [Symbol])
    rescue StandardError
      nil
    end

    def load_protocol_file(file_path)
      content = File.read(file_path); metadata = parse_frontmatter(file_path); return nil unless metadata
      name = metadata['name']; return nil unless name
      protocol = { name: name, file_path: file_path, layer: metadata['layer'] || 'L2', type: metadata['type'], version: metadata['version'] || '1.0.0', bootstrap: metadata['bootstrap'] == true, immutable: metadata['immutable'] == true, actions: metadata['actions'] || [], extends: metadata['extends'], requires: metadata['requires'] || [], description: metadata['description'], content_hash: Digest::SHA256.hexdigest(content), loaded_at: Time.now.utc.iso8601 }
      @loaded_protocols[name] = protocol
      protocol[:actions].each { |a| unless @available_actions.include?(a); @available_actions << a; @action_handlers[a] = { protocol: name, layer: protocol[:layer], immutable: protocol[:immutable] }; end }
      @extensions << name if protocol[:type] == EXTENSION_TYPE && !@extensions.include?(name)
      protocol
    end

    def build_action_registry
      layer_order = { 'L0' => 0, 'L1' => 1, 'L2' => 2 }
      @available_actions.sort_by! { |a| h = @action_handlers[a]; [h[:immutable] ? 0 : 1, layer_order[h[:layer]] || 3] }
    end
  end
end
