# frozen_string_literal: true

require 'securerandom'
require 'time'
require 'digest'

module KairosMcp
  module MeetingPlace
    # SkillStore manages skills published by agents to the Meeting Place.
    # This enables the "relay mode" where agents don't need HTTP servers -
    # they publish their skills to the Meeting Place, and other agents
    # can discover and acquire skills directly from the Meeting Place.
    #
    # Workflow:
    # 1. Agent connects and publishes their skills (metadata + content)
    # 2. Other agents browse available skills
    # 3. When acquiring, the Meeting Place provides the content directly
    class SkillStore
      DEFAULT_TTL_HOURS = 24
      DEFAULT_MAX_SKILL_SIZE = 1_048_576  # 1 MB

      Skill = Struct.new(
        :id, :agent_id, :name, :description, :layer, :format, :tags,
        :version, :content, :content_hash, :size_bytes, :metadata,
        :published_at, :expires_at, :download_count,
        keyword_init: true
      )

      def initialize(ttl_hours: DEFAULT_TTL_HOURS, max_skill_size: DEFAULT_MAX_SKILL_SIZE)
        @skills = {}  # skill_id => Skill
        @agent_skills = {}  # agent_id => [skill_ids]
        @ttl_hours = ttl_hours
        @max_skill_size = max_skill_size
        @mutex = Mutex.new
      end

      # Publish a skill to the store
      def publish(agent_id:, skill_data:)
        validate_skill!(skill_data)
        
        @mutex.synchronize do
          skill_id = skill_data[:id] || skill_data['id'] || generate_skill_id
          now = Time.now.utc
          
          content = skill_data[:content] || skill_data['content']
          content_hash = "sha256:#{Digest::SHA256.hexdigest(content)}"
          
          skill = Skill.new(
            id: skill_id,
            agent_id: agent_id,
            name: skill_data[:name] || skill_data['name'] || skill_id,
            description: skill_data[:description] || skill_data['description'] || '',
            layer: skill_data[:layer] || skill_data['layer'] || 'L1',
            format: skill_data[:format] || skill_data['format'] || 'markdown',
            tags: skill_data[:tags] || skill_data['tags'] || [],
            version: skill_data[:version] || skill_data['version'] || '1.0.0',
            content: content,
            content_hash: content_hash,
            size_bytes: content.bytesize,
            metadata: skill_data[:metadata] || skill_data['metadata'] || {},
            published_at: now,
            expires_at: now + (@ttl_hours * 3600),
            download_count: 0
          )
          
          @skills[skill_id] = skill
          @agent_skills[agent_id] ||= []
          @agent_skills[agent_id] << skill_id unless @agent_skills[agent_id].include?(skill_id)
          
          {
            skill_id: skill_id,
            content_hash: content_hash,
            published_at: skill.published_at.iso8601,
            expires_at: skill.expires_at.iso8601,
            status: 'published'
          }
        end
      end

      # Unpublish a skill
      def unpublish(skill_id, agent_id: nil)
        @mutex.synchronize do
          skill = @skills[skill_id]
          return { error: 'Skill not found' } unless skill
          
          # Only owner can unpublish
          if agent_id && skill.agent_id != agent_id
            return { error: 'Not authorized to unpublish this skill' }
          end
          
          @skills.delete(skill_id)
          @agent_skills[skill.agent_id]&.delete(skill_id)
          
          { skill_id: skill_id, status: 'unpublished' }
        end
      end

      # Get skill metadata (without content)
      def get_metadata(skill_id)
        cleanup_expired
        
        @mutex.synchronize do
          skill = @skills[skill_id]
          return nil unless skill
          
          skill_to_metadata(skill)
        end
      end

      # Get skill content (full)
      def get_content(skill_id)
        cleanup_expired
        
        @mutex.synchronize do
          skill = @skills[skill_id]
          return nil unless skill
          
          # Increment download count
          skill.download_count += 1
          
          {
            skill_id: skill.id,
            agent_id: skill.agent_id,
            name: skill.name,
            format: skill.format,
            content: skill.content,
            content_hash: skill.content_hash,
            size_bytes: skill.size_bytes,
            provenance: {
              origin: skill.agent_id,
              published_at: skill.published_at.iso8601,
              hop_count: 1
            }
          }
        end
      end

      # Get preview of skill content
      def get_preview(skill_id, lines: 10)
        cleanup_expired
        
        @mutex.synchronize do
          skill = @skills[skill_id]
          return nil unless skill
          
          content_lines = skill.content.lines
          preview_lines = content_lines.first(lines)
          
          {
            skill_id: skill.id,
            preview: preview_lines.join,
            preview_lines: preview_lines.size,
            total_lines: content_lines.size,
            truncated: content_lines.size > lines,
            content_hash: skill.content_hash
          }
        end
      end

      # List all skills from an agent
      def list_by_agent(agent_id)
        cleanup_expired
        
        @mutex.synchronize do
          skill_ids = @agent_skills[agent_id] || []
          skill_ids.map { |id| skill_to_metadata(@skills[id]) }.compact
        end
      end

      # Browse all skills with optional filters
      def browse(filters: {})
        cleanup_expired
        
        @mutex.synchronize do
          result = @skills.values
          
          # Filter by agent
          if filters[:agent_id]
            result = result.select { |s| s.agent_id == filters[:agent_id] }
          end
          
          # Filter by tags
          if filters[:tags] && !filters[:tags].empty?
            result = result.select do |s|
              (s.tags & filters[:tags]).any?
            end
          end
          
          # Filter by format
          if filters[:format]
            result = result.select { |s| s.format == filters[:format] }
          end
          
          # Filter by search term
          if filters[:search]
            search_term = filters[:search].downcase
            result = result.select do |s|
              s.name.downcase.include?(search_term) ||
                s.description.downcase.include?(search_term)
            end
          end
          
          # Limit results
          if filters[:limit]
            result = result.first(filters[:limit].to_i)
          end
          
          result.map { |s| skill_to_metadata(s) }
        end
      end

      # Statistics
      def stats
        cleanup_expired
        
        @mutex.synchronize do
          {
            total_skills: @skills.size,
            total_agents: @agent_skills.keys.size,
            total_size_bytes: @skills.values.sum(&:size_bytes),
            total_downloads: @skills.values.sum(&:download_count),
            by_format: @skills.values.group_by(&:format).transform_values(&:count)
          }
        end
      end

      private

      def generate_skill_id
        "skill_#{SecureRandom.hex(8)}"
      end

      def validate_skill!(skill_data)
        content = skill_data[:content] || skill_data['content']
        
        raise ArgumentError, 'content is required' unless content
        
        if content.bytesize > @max_skill_size
          raise ArgumentError, "Skill content exceeds maximum size (#{@max_skill_size} bytes)"
        end
      end

      def cleanup_expired
        now = Time.now.utc
        
        @mutex.synchronize do
          @skills.delete_if do |skill_id, skill|
            expired = skill.expires_at < now
            if expired
              @agent_skills[skill.agent_id]&.delete(skill_id)
            end
            expired
          end
          
          # Clean up empty agent entries
          @agent_skills.delete_if { |_, skills| skills.empty? }
        end
      end

      def skill_to_metadata(skill)
        return nil unless skill
        
        {
          id: skill.id,
          agent_id: skill.agent_id,
          name: skill.name,
          description: skill.description,
          layer: skill.layer,
          format: skill.format,
          tags: skill.tags,
          version: skill.version,
          content_hash: skill.content_hash,
          size_bytes: skill.size_bytes,
          published_at: skill.published_at.iso8601,
          expires_at: skill.expires_at.iso8601,
          download_count: skill.download_count
        }
      end
    end
  end
end
