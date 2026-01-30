# frozen_string_literal: true

require 'digest'
require 'yaml'
require 'fileutils'
require_relative '../kairos_chain/chain'

module KairosMcp
  module Meeting
    # SkillExchange handles the packaging, validation, and storage of exchanged skills.
    # It enforces safety policies to prevent execution of untrusted code.
    # 
    # Provenance Tracking:
    # - Each received skill is recorded in the local KairosChain with origin information
    # - Provenance chain tracks the full path a skill has traveled between agents
    # - This enables tracing issues back to their source
    class SkillExchange
      # Safe formats that can be exchanged by default
      SAFE_FORMATS = %w[markdown yaml_frontmatter].freeze
      
      # Dangerous formats that require explicit opt-in
      DANGEROUS_FORMATS = %w[ruby ruby_dsl ast executable].freeze

      # Maximum skill size in bytes (default 100KB)
      DEFAULT_MAX_SIZE = 100_000

      attr_reader :chain

      def initialize(config:, workspace_root: nil, chain: nil)
        @config = config
        @workspace_root = workspace_root
        @exchange_config = config['skill_exchange'] || {}
        @chain = chain || KairosChain::Chain.new
      end

      # Package a skill for sending to another agent
      # @param skill_path [String] Path to the skill file
      # @return [Hash] Packaged skill with metadata
      def package_skill(skill_path)
        raise ArgumentError, "File not found: #{skill_path}" unless File.exist?(skill_path)
        
        content = File.read(skill_path)
        format = detect_format(skill_path, content)
        
        # Verify we're allowed to send this format
        unless can_send_format?(format)
          raise SecurityError, "Cannot send format '#{format}'. Only safe formats allowed: #{allowed_formats.join(', ')}"
        end

        # Check size limit
        max_size = @exchange_config['max_skill_size_bytes'] || DEFAULT_MAX_SIZE
        if content.bytesize > max_size
          raise ArgumentError, "Skill exceeds maximum size (#{content.bytesize} > #{max_size} bytes)"
        end

        {
          name: File.basename(skill_path, '.*'),
          format: format,
          content: content,
          content_hash: Digest::SHA256.hexdigest(content),
          size_bytes: content.bytesize,
          frontmatter: extract_frontmatter(content),
          packaged_at: Time.now.utc.iso8601
        }
      end

      # Validate a received skill before accepting it
      # @param skill_data [Hash] Skill data from skill_content message
      # @return [Hash] Validation result
      def validate_received_skill(skill_data)
        errors = []
        warnings = []

        content = skill_data[:content] || skill_data['content']
        format = skill_data[:format] || skill_data['format']
        content_hash = skill_data[:content_hash] || skill_data['content_hash']

        # 1. Check format is allowed
        unless can_receive_format?(format)
          errors << "Format '#{format}' is not allowed. Allowed: #{allowed_formats.join(', ')}"
        end

        # 2. Verify content hash
        if content && content_hash
          calculated = Digest::SHA256.hexdigest(content)
          if calculated != content_hash
            errors << "Content hash mismatch: expected #{content_hash}, got #{calculated}"
          end
        end

        # 3. Check size limit
        max_size = @exchange_config['max_skill_size_bytes'] || DEFAULT_MAX_SIZE
        if content && content.bytesize > max_size
          errors << "Skill exceeds maximum size (#{content.bytesize} > #{max_size} bytes)"
        end

        # 4. Scan for dangerous patterns (even in markdown)
        if content
          dangerous = scan_for_dangerous_content(content, format)
          warnings.concat(dangerous[:warnings]) if dangerous[:warnings].any?
          errors.concat(dangerous[:errors]) if dangerous[:errors].any?
        end

        {
          valid: errors.empty?,
          errors: errors,
          warnings: warnings,
          format: format,
          size_bytes: content&.bytesize,
          content_hash: content_hash
        }
      end

      # Store a received skill in the appropriate location
      # @param skill_data [Hash] Validated skill data
      # @param target_layer [String] Layer to store in ('L1' or 'L2')
      # @return [Hash] Storage result with provenance information
      def store_received_skill(skill_data, target_layer: 'L2')
        validation = validate_received_skill(skill_data)
        raise SecurityError, "Skill validation failed: #{validation[:errors].join(', ')}" unless validation[:valid]

        skill_name = skill_data[:skill_name] || skill_data['skill_name'] || 'received_skill'
        content = skill_data[:content] || skill_data['content']
        format = skill_data[:format] || skill_data['format']

        # Build provenance chain (tracks where this skill came from)
        provenance = build_provenance(skill_data)

        # Determine storage path based on layer
        base_dir = case target_layer.upcase
                   when 'L1'
                     File.join(@workspace_root, 'knowledge', 'received')
                   when 'L2'
                     File.join(@workspace_root, 'context', 'received_skills')
                   else
                     raise ArgumentError, "Invalid target layer: #{target_layer}"
                   end

        FileUtils.mkdir_p(base_dir)

        # Generate safe filename
        safe_name = skill_name.gsub(/[^a-zA-Z0-9_-]/, '_')
        timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
        filename = "#{safe_name}_#{timestamp}.md"
        filepath = File.join(base_dir, filename)

        # Add received metadata and provenance to frontmatter
        enriched_content = add_received_metadata(content, skill_data, provenance)

        File.write(filepath, enriched_content)

        final_hash = Digest::SHA256.hexdigest(enriched_content)

        # Record provenance to blockchain for immutable audit trail
        record_provenance_to_chain(skill_data, provenance, filepath, final_hash)

        {
          stored: true,
          path: filepath,
          layer: target_layer,
          skill_name: skill_name,
          content_hash: final_hash,
          provenance: provenance
        }
      end

      # Get provenance history for a skill by its content hash
      # @param content_hash [String] The skill's content hash
      # @return [Array<Hash>] Provenance records from the chain
      def get_provenance_history(content_hash)
        records = []
        @chain.chain.each do |block|
          block.data.each do |data_item|
            next unless data_item.is_a?(String)
            
            parsed = JSON.parse(data_item, symbolize_names: true)
            if parsed[:_type] == 'skill_provenance' && 
               (parsed[:content_hash] == content_hash || parsed[:original_hash] == content_hash)
              records << parsed
            end
          rescue JSON::ParserError
            next
          end
        end
        records
      end

      # Trace the origin of a skill through its provenance chain
      # @param content_hash [String] The skill's content hash
      # @return [Hash] Origin information
      def trace_skill_origin(content_hash)
        records = get_provenance_history(content_hash)
        return nil if records.empty?

        # Find the oldest record (closest to origin)
        oldest = records.min_by { |r| r[:received_at] }
        
        {
          original_sender: oldest[:provenance_chain]&.first || oldest[:received_from],
          full_chain: oldest[:provenance_chain] || [oldest[:received_from]],
          first_received_at: oldest[:received_at],
          total_hops: (oldest[:provenance_chain]&.length || 1) - 1,
          content_hash: content_hash
        }
      end

      # Check if we can send a given format
      def can_send_format?(format)
        return false if DANGEROUS_FORMATS.include?(format) && !executable_allowed?
        allowed_formats.include?(format)
      end

      # Check if we can receive a given format
      def can_receive_format?(format)
        return false if DANGEROUS_FORMATS.include?(format) && !executable_allowed?
        allowed_formats.include?(format)
      end

      # Get list of allowed formats
      def allowed_formats
        @exchange_config['allowed_formats'] || SAFE_FORMATS
      end

      # Check if executable code exchange is allowed
      def executable_allowed?
        @exchange_config['allow_executable'] == true
      end

      private

      def detect_format(path, content)
        ext = File.extname(path).downcase

        case ext
        when '.md', '.markdown'
          content.start_with?('---') ? 'yaml_frontmatter' : 'markdown'
        when '.rb'
          'ruby'
        when '.yml', '.yaml'
          'yaml'
        else
          'markdown'
        end
      end

      def extract_frontmatter(content)
        return nil unless content.start_with?('---')
        
        parts = content.split(/^---\s*$/, 3)
        return nil if parts.length < 3
        
        YAML.safe_load(parts[1])
      rescue StandardError
        nil
      end

      def scan_for_dangerous_content(content, format)
        warnings = []
        errors = []

        # Check for potential prompt injection patterns
        prompt_injection_patterns = [
          /ignore\s+(previous|all|above)\s+instructions?/i,
          /disregard\s+(previous|all|above)/i,
          /you\s+are\s+now\s+a/i,
          /pretend\s+you\s+are/i,
          /act\s+as\s+if/i,
          /system\s*:\s*/i
        ]

        prompt_injection_patterns.each do |pattern|
          if content.match?(pattern)
            warnings << "Potential prompt injection pattern detected: #{pattern.source}"
          end
        end

        # Check for executable code in markdown (should be documentation only)
        if %w[markdown yaml_frontmatter].include?(format)
          # Ruby code blocks that look like they're meant to be executed
          if content.match?(/```ruby\s*\n.*\b(system|exec|eval|`|%x)\b/m)
            warnings << "Markdown contains Ruby code with system execution patterns"
          end

          # Shell command blocks
          if content.match?(/```(?:bash|sh|shell)\s*\n.*\b(rm\s+-rf|sudo|curl.*\|\s*sh)/m)
            warnings << "Markdown contains potentially dangerous shell commands"
          end
        end

        # If format claims to be safe but contains code indicators
        if SAFE_FORMATS.include?(format) && content.match?(/^#!/)
          warnings << "File starts with shebang - may be executable despite format"
        end

        { warnings: warnings, errors: errors }
      end

      # Build provenance information for a received skill
      # @param skill_data [Hash] The skill data with optional existing provenance
      # @return [Hash] Provenance information
      def build_provenance(skill_data)
        sender = skill_data[:from] || skill_data['from']
        original_hash = skill_data[:content_hash] || skill_data['content_hash']
        
        # Check if the skill already has provenance chain (was forwarded)
        existing_provenance = skill_data[:provenance] || skill_data['provenance'] || {}
        existing_chain = existing_provenance[:chain] || existing_provenance['chain'] || []
        
        # Build the provenance chain
        provenance_chain = if existing_chain.empty?
                             [sender]  # This is the first hop
                           else
                             existing_chain + [sender]  # Add this sender to the chain
                           end

        {
          received_from: sender,
          received_at: Time.now.utc.iso8601,
          original_hash: original_hash,
          provenance_chain: provenance_chain,
          origin: provenance_chain.first,  # Original source
          hop_count: provenance_chain.length - 1,  # Number of intermediaries
          protocol_version: '1.0.0'
        }
      end

      # Record provenance to the blockchain for immutable audit trail
      # @param skill_data [Hash] Original skill data
      # @param provenance [Hash] Computed provenance
      # @param stored_path [String] Where the skill was stored
      # @param final_hash [String] Hash of the stored content
      def record_provenance_to_chain(skill_data, provenance, stored_path, final_hash)
        record = {
          _type: 'skill_provenance',
          skill_name: skill_data[:skill_name] || skill_data['skill_name'],
          original_hash: provenance[:original_hash],
          content_hash: final_hash,
          received_from: provenance[:received_from],
          received_at: provenance[:received_at],
          provenance_chain: provenance[:provenance_chain],
          origin: provenance[:origin],
          hop_count: provenance[:hop_count],
          stored_path: stored_path,
          recorded_at: Time.now.utc.iso8601
        }

        @chain.add_block([record.to_json])
      end

      def add_received_metadata(content, skill_data, provenance = nil)
        provenance ||= build_provenance(skill_data)
        
        metadata = {
          'received_from' => provenance[:received_from],
          'received_at' => provenance[:received_at],
          'original_hash' => provenance[:original_hash],
          'exchange_protocol_version' => provenance[:protocol_version]
        }

        # Add provenance tracking information
        provenance_data = {
          'origin' => provenance[:origin],
          'chain' => provenance[:provenance_chain],
          'hop_count' => provenance[:hop_count]
        }

        if content.start_with?('---')
          # Merge with existing frontmatter
          parts = content.split(/^---\s*$/, 3)
          if parts.length >= 3
            existing = YAML.safe_load(parts[1]) || {}
            merged = existing.merge(
              '_received' => metadata,
              '_provenance' => provenance_data
            )
            return "---\n#{merged.to_yaml}---\n#{parts[2]}"
          end
        end

        # Add new frontmatter
        frontmatter = {
          '_received' => metadata,
          '_provenance' => provenance_data
        }
        "---\n#{frontmatter.to_yaml}---\n\n#{content}"
      end
    end
  end
end
