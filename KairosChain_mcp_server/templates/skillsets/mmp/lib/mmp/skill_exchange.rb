# frozen_string_literal: true

require 'digest'
require 'yaml'
require 'fileutils'

module MMP
  class SkillExchange
    SAFE_FORMATS = %w[markdown yaml_frontmatter].freeze
    DANGEROUS_FORMATS = %w[ruby ruby_dsl ast executable].freeze
    DEFAULT_MAX_SIZE = 100_000
    MAX_HOP_COUNT = 3

    attr_reader :chain_adapter

    def initialize(config:, workspace_root: nil, chain_adapter: nil)
      @config = config
      @workspace_root = workspace_root
      @exchange_config = config['skill_exchange'] || {}
      @chain_adapter = chain_adapter || default_chain_adapter
    end

    def package_skill(skill_path)
      raise ArgumentError, "File not found: #{skill_path}" unless File.exist?(skill_path)
      content = File.read(skill_path)
      format = detect_format(skill_path, content)
      raise SecurityError, "Cannot send format '#{format}'" unless can_send_format?(format)
      max_size = @exchange_config['max_skill_size_bytes'] || DEFAULT_MAX_SIZE
      raise ArgumentError, "Skill exceeds maximum size" if content.bytesize > max_size
      { name: File.basename(skill_path, '.*'), format: format, content: content, content_hash: Digest::SHA256.hexdigest(content), size_bytes: content.bytesize, frontmatter: extract_frontmatter(content), packaged_at: Time.now.utc.iso8601 }
    end

    def validate_received_skill(skill_data)
      errors = []; warnings = []
      content = skill_data[:content] || skill_data['content']
      format = skill_data[:format] || skill_data['format']
      content_hash = skill_data[:content_hash] || skill_data['content_hash']
      # hop_count enforcement
      hop_count = skill_data.dig(:provenance, :hop_count) || skill_data.dig('provenance', 'hop_count') || 0
      errors << "hop_count limit exceeded (#{hop_count} >= #{MAX_HOP_COUNT})" if hop_count.to_i >= MAX_HOP_COUNT
      errors << "Format '#{format}' is not allowed" unless can_receive_format?(format)
      if content && content_hash
        calculated = Digest::SHA256.hexdigest(content)
        errors << "Content hash mismatch" if calculated != content_hash
      end
      max_size = @exchange_config['max_skill_size_bytes'] || DEFAULT_MAX_SIZE
      errors << "Skill exceeds maximum size" if content && content.bytesize > max_size
      if content
        dangerous = scan_for_dangerous_content(content, format)
        warnings.concat(dangerous[:warnings])
        errors.concat(dangerous[:errors])
      end
      { valid: errors.empty?, errors: errors, warnings: warnings, format: format, size_bytes: content&.bytesize, content_hash: content_hash }
    end

    def store_received_skill(skill_data, target_layer: 'L2')
      validation = validate_received_skill(skill_data)
      raise SecurityError, "Validation failed: #{validation[:errors].join(', ')}" unless validation[:valid]
      skill_name = skill_data[:skill_name] || skill_data['skill_name'] || 'received_skill'
      content = skill_data[:content] || skill_data['content']
      provenance = build_provenance(skill_data)
      base_dir = case target_layer.upcase
                 when 'L1' then File.join(@workspace_root, 'knowledge', 'received')
                 when 'L2' then File.join(@workspace_root, 'context', 'received_skills')
                 else raise ArgumentError, "Invalid target layer: #{target_layer}"
                 end
      FileUtils.mkdir_p(base_dir)
      safe_name = skill_name.gsub(/[^a-zA-Z0-9_-]/, '_')
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      filepath = File.join(base_dir, "#{safe_name}_#{timestamp}.md")
      enriched_content = add_received_metadata(content, skill_data, provenance)
      File.write(filepath, enriched_content)
      final_hash = Digest::SHA256.hexdigest(enriched_content)
      record_provenance(skill_data, provenance, filepath, final_hash)
      { stored: true, path: filepath, layer: target_layer, skill_name: skill_name, content_hash: final_hash, provenance: provenance }
    end

    def get_provenance_history(content_hash)
      records = []
      @chain_adapter.chain_data.each do |block|
        block_data = block.respond_to?(:data) ? block.data : (block.is_a?(Hash) ? block[:data] : [])
        Array(block_data).each do |item|
          next unless item.is_a?(String)
          parsed = JSON.parse(item, symbolize_names: true) rescue next
          records << parsed if parsed[:_type] == 'skill_provenance' && (parsed[:content_hash] == content_hash || parsed[:original_hash] == content_hash)
        end
      end
      records
    end

    def can_send_format?(format) = !(DANGEROUS_FORMATS.include?(format) && !executable_allowed?) && allowed_formats.include?(format)
    def can_receive_format?(format) = can_send_format?(format)
    def allowed_formats = @exchange_config['allowed_formats'] || SAFE_FORMATS
    def executable_allowed? = @exchange_config['allow_executable'] == true

    private

    def default_chain_adapter
      MMP::KairosChainAdapter.new
    rescue StandardError
      MMP::NullChainAdapter.new
    end

    def detect_format(path, content)
      case File.extname(path).downcase
      when '.md', '.markdown' then content.start_with?('---') ? 'yaml_frontmatter' : 'markdown'
      when '.rb' then 'ruby'
      when '.yml', '.yaml' then 'yaml'
      else 'markdown'
      end
    end

    def extract_frontmatter(content)
      return nil unless content.start_with?('---')
      parts = content.split(/^---\s*$/, 3)
      return nil if parts.length < 3
      YAML.safe_load(parts[1]) rescue nil
    end

    def scan_for_dangerous_content(content, format)
      warnings = []; errors = []
      [/ignore\s+(previous|all|above)\s+instructions?/i, /disregard\s+(previous|all|above)/i, /you\s+are\s+now\s+a/i].each do |pattern|
        warnings << "Potential prompt injection: #{pattern.source}" if content.match?(pattern)
      end
      if %w[markdown yaml_frontmatter].include?(format)
        warnings << "Ruby code with system execution patterns" if content.match?(/```ruby\s*\n.*\b(system|exec|eval|`|%x)\b/m)
        warnings << "Dangerous shell commands" if content.match?(/```(?:bash|sh|shell)\s*\n.*\b(rm\s+-rf|sudo|curl.*\|\s*sh)/m)
      end
      { warnings: warnings, errors: errors }
    end

    def build_provenance(skill_data)
      sender = skill_data[:from] || skill_data['from']
      original_hash = skill_data[:content_hash] || skill_data['content_hash']
      existing_chain = skill_data.dig(:provenance, :chain) || skill_data.dig('provenance', 'chain') || []
      provenance_chain = existing_chain.empty? ? [sender] : existing_chain + [sender]
      { received_from: sender, received_at: Time.now.utc.iso8601, original_hash: original_hash, provenance_chain: provenance_chain, origin: provenance_chain.first, hop_count: provenance_chain.length - 1, protocol_version: '1.0.0' }
    end

    def record_provenance(skill_data, provenance, stored_path, final_hash)
      record = { _type: 'skill_provenance', skill_name: skill_data[:skill_name] || skill_data['skill_name'], original_hash: provenance[:original_hash], content_hash: final_hash, received_from: provenance[:received_from], received_at: provenance[:received_at], provenance_chain: provenance[:provenance_chain], origin: provenance[:origin], hop_count: provenance[:hop_count], stored_path: stored_path, recorded_at: Time.now.utc.iso8601 }
      @chain_adapter.record([record.to_json])
    end

    def add_received_metadata(content, skill_data, provenance)
      metadata = { 'received_from' => provenance[:received_from], 'received_at' => provenance[:received_at], 'original_hash' => provenance[:original_hash] }
      provenance_data = { 'origin' => provenance[:origin], 'chain' => provenance[:provenance_chain], 'hop_count' => provenance[:hop_count] }
      if content.start_with?('---')
        parts = content.split(/^---\s*$/, 3)
        if parts.length >= 3
          existing = YAML.safe_load(parts[1]) || {}
          merged = existing.merge('_received' => metadata, '_provenance' => provenance_data)
          return "---\n#{merged.to_yaml}---\n#{parts[2]}"
        end
      end
      frontmatter = { '_received' => metadata, '_provenance' => provenance_data }
      "---\n#{frontmatter.to_yaml}---\n\n#{content}"
    end
  end
end
