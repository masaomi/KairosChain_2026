# frozen_string_literal: true

require 'yaml'
require 'digest'
require_relative '../version'

module KairosMcp
  module Meeting
    # Identity provides self-description capabilities for a KairosChain instance.
    # This allows agents to introduce themselves to other agents.
    class Identity
      CONFIG_PATH = File.expand_path('../../../config/meeting.yml', __dir__)
      
      attr_reader :config

      def initialize(workspace_root: nil)
        @workspace_root = workspace_root
        @config = load_config
      end

      # Returns the full self-introduction for this KairosChain instance
      def introduce
        {
          identity: identity_info,
          capabilities: capabilities_info,
          skills: available_skills,
          constraints: constraints_info,
          exchange_policy: exchange_policy,
          timestamp: Time.now.utc.iso8601
        }
      end

      # Returns just the capabilities
      def capabilities
        capabilities_info
      end

      # Returns public skills available for exchange
      def public_skills
        available_skills.select { |s| s[:public] }
      end

      private

      def load_config
        if File.exist?(CONFIG_PATH)
          YAML.load_file(CONFIG_PATH) || default_config
        else
          default_config
        end
      rescue StandardError => e
        $stderr.puts "[WARN] Failed to load meeting config: #{e.message}"
        default_config
      end

      def default_config
        {
          'identity' => {
            'name' => 'KairosChain Instance',
            'description' => 'A memory-capable, evolvable agent framework',
            'scope' => 'general'
          },
          'capabilities' => {
            'meeting_protocol_version' => '1.0.0',
            'supported_actions' => %w[introduce offer_skill request_skill accept decline reflect]
          },
          'skill_exchange' => {
            'allowed_formats' => %w[markdown yaml_frontmatter],
            'allow_executable' => false,
            'public_by_default' => false
          },
          'constraints' => {
            'max_skill_size_bytes' => 100_000,
            'rate_limit_per_minute' => 10
          }
        }
      end

      def identity_info
        id_config = @config['identity'] || {}
        {
          name: id_config['name'] || 'KairosChain Instance',
          description: id_config['description'] || 'A memory-capable, evolvable agent framework',
          scope: id_config['scope'] || 'general',
          version: KairosMcp::VERSION,
          instance_id: generate_instance_id
        }
      end

      def capabilities_info
        cap_config = @config['capabilities'] || {}
        {
          meeting_protocol_version: cap_config['meeting_protocol_version'] || '1.0.0',
          supported_actions: cap_config['supported_actions'] || %w[introduce offer_skill request_skill],
          skill_formats: allowed_formats
        }
      end

      def constraints_info
        const_config = @config['constraints'] || {}
        {
          max_skill_size_bytes: const_config['max_skill_size_bytes'] || 100_000,
          rate_limit_per_minute: const_config['rate_limit_per_minute'] || 10,
          allowed_formats: allowed_formats,
          executable_allowed: executable_allowed?
        }
      end

      def exchange_policy
        {
          allowed_formats: allowed_formats,
          allow_executable: executable_allowed?,
          public_by_default: public_by_default?
        }
      end

      def allowed_formats
        exchange_config = @config['skill_exchange'] || {}
        exchange_config['allowed_formats'] || %w[markdown yaml_frontmatter]
      end

      def executable_allowed?
        exchange_config = @config['skill_exchange'] || {}
        exchange_config['allow_executable'] == true
      end

      def public_by_default?
        exchange_config = @config['skill_exchange'] || {}
        exchange_config['public_by_default'] == true
      end

      # Scans available skills and returns those marked as public
      def available_skills
        skills = []
        
        # Scan L1 knowledge directory for markdown skills
        knowledge_dir = knowledge_path
        if knowledge_dir && File.directory?(knowledge_dir)
          Dir.glob(File.join(knowledge_dir, '**', '*.md')).each do |file|
            skill = parse_skill_file(file, 'L1')
            skills << skill if skill
          end
        end

        # Optionally scan L2 context directory
        context_dir = context_path
        if context_dir && File.directory?(context_dir)
          Dir.glob(File.join(context_dir, '**', '*.md')).each do |file|
            skill = parse_skill_file(file, 'L2')
            skills << skill if skill && skill[:public]
          end
        end

        skills
      end

      def parse_skill_file(file_path, layer)
        content = File.read(file_path)
        frontmatter = extract_frontmatter(content)
        
        # Determine if skill is public based on frontmatter or default
        is_public = if frontmatter && frontmatter.key?('public')
                      frontmatter['public'] == true
                    else
                      public_by_default?
                    end

        {
          id: generate_skill_id(file_path),
          name: File.basename(file_path, '.md'),
          layer: layer,
          format: 'markdown',
          public: is_public,
          summary: extract_summary(content, frontmatter),
          content_hash: Digest::SHA256.hexdigest(content),
          path: file_path
        }
      rescue StandardError => e
        $stderr.puts "[WARN] Failed to parse skill file #{file_path}: #{e.message}"
        nil
      end

      def extract_frontmatter(content)
        return nil unless content.start_with?('---')
        
        parts = content.split(/^---\s*$/, 3)
        return nil if parts.length < 3
        
        YAML.safe_load(parts[1])
      rescue StandardError
        nil
      end

      def extract_summary(content, frontmatter)
        # Use frontmatter description if available
        return frontmatter['description'] if frontmatter && frontmatter['description']
        
        # Otherwise, extract first non-empty line after frontmatter
        lines = content.lines.map(&:strip).reject(&:empty?)
        
        # Skip frontmatter
        if content.start_with?('---')
          in_frontmatter = true
          lines = lines.drop_while do |line|
            if line == '---'
              if in_frontmatter
                in_frontmatter = false
                true
              else
                false
              end
            else
              in_frontmatter
            end
          end
        end

        # Get first content line, skip headers
        summary_line = lines.find { |l| !l.start_with?('#') && !l.empty? }
        summary_line&.slice(0, 200) || 'No description available'
      end

      def generate_skill_id(file_path)
        relative_path = if @workspace_root
                          file_path.sub(@workspace_root, '').sub(%r{^/}, '')
                        else
                          File.basename(file_path)
                        end
        Digest::SHA256.hexdigest(relative_path)[0, 16]
      end

      def generate_instance_id
        # Generate a stable instance ID based on workspace path and config
        seed = [@workspace_root, @config.to_s].join(':')
        Digest::SHA256.hexdigest(seed)[0, 16]
      end

      def knowledge_path
        return nil unless @workspace_root
        path = File.join(@workspace_root, 'knowledge')
        File.directory?(path) ? path : nil
      end

      def context_path
        return nil unless @workspace_root
        path = File.join(@workspace_root, 'context')
        File.directory?(path) ? path : nil
      end
    end
  end
end
