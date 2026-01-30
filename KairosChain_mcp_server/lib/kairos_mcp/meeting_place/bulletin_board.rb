# frozen_string_literal: true

require 'securerandom'
require 'time'

module KairosMcp
  module MeetingPlace
    # BulletinBoard manages postings in the Meeting Place.
    # Agents can post skill offers/requests and browse what others have posted.
    class BulletinBoard
      DEFAULT_TTL_HOURS = 24
      MAX_POSTINGS_PER_AGENT = 10

      Posting = Struct.new(
        :id, :agent_id, :agent_name, :type, :skill_name, :skill_summary,
        :skill_format, :tags, :created_at, :expires_at, :metadata,
        keyword_init: true
      )

      VALID_TYPES = %w[offer_skill request_skill announcement].freeze

      def initialize(default_ttl_hours: DEFAULT_TTL_HOURS)
        @postings = {}
        @default_ttl_hours = default_ttl_hours
        @mutex = Mutex.new
      end

      # Create a new posting
      def post(posting_data)
        @mutex.synchronize do
          agent_id = posting_data[:agent_id] || posting_data['agent_id']
          return { error: 'agent_id is required' } unless agent_id

          type = posting_data[:type] || posting_data['type']
          return { error: "Invalid type. Must be one of: #{VALID_TYPES.join(', ')}" } unless VALID_TYPES.include?(type)

          # Check posting limit per agent
          agent_postings = @postings.values.count { |p| p.agent_id == agent_id }
          if agent_postings >= MAX_POSTINGS_PER_AGENT
            return { error: "Maximum postings reached (#{MAX_POSTINGS_PER_AGENT}). Remove old postings first." }
          end

          now = Time.now.utc
          ttl_hours = posting_data[:ttl_hours] || posting_data['ttl_hours'] || @default_ttl_hours

          posting = Posting.new(
            id: generate_posting_id,
            agent_id: agent_id,
            agent_name: posting_data[:agent_name] || posting_data['agent_name'] || 'Unknown',
            type: type,
            skill_name: posting_data[:skill_name] || posting_data['skill_name'],
            skill_summary: posting_data[:skill_summary] || posting_data['skill_summary'] || '',
            skill_format: posting_data[:skill_format] || posting_data['skill_format'] || 'markdown',
            tags: posting_data[:tags] || posting_data['tags'] || [],
            created_at: now,
            expires_at: now + (ttl_hours * 3600),
            metadata: posting_data[:metadata] || posting_data['metadata'] || {}
          )

          @postings[posting.id] = posting

          {
            posting_id: posting.id,
            status: 'posted',
            expires_at: posting.expires_at.iso8601
          }
        end
      end

      # Remove a posting
      def remove(posting_id, agent_id: nil)
        @mutex.synchronize do
          posting = @postings[posting_id]
          return { error: 'Posting not found' } unless posting

          # Verify ownership if agent_id provided
          if agent_id && posting.agent_id != agent_id
            return { error: 'Not authorized to remove this posting' }
          end

          @postings.delete(posting_id)
          { posting_id: posting_id, status: 'removed' }
        end
      end

      # Get a specific posting
      def get(posting_id)
        @mutex.synchronize do
          posting = @postings[posting_id]
          return nil unless posting && !expired?(posting)

          posting_to_hash(posting)
        end
      end

      # Browse postings with filters
      def browse(filters: {})
        @mutex.synchronize do
          cleanup_expired

          result = @postings.values

          # Filter by type
          if filters[:type]
            result = result.select { |p| p.type == filters[:type] }
          end

          # Filter by agent
          if filters[:agent_id]
            result = result.select { |p| p.agent_id == filters[:agent_id] }
          end

          # Filter by skill format
          if filters[:skill_format]
            result = result.select { |p| p.skill_format == filters[:skill_format] }
          end

          # Filter by tags (any match)
          if filters[:tags] && !filters[:tags].empty?
            filter_tags = Array(filters[:tags])
            result = result.select { |p| (p.tags & filter_tags).any? }
          end

          # Search in skill_name and skill_summary
          if filters[:search]
            search_term = filters[:search].downcase
            result = result.select do |p|
              (p.skill_name&.downcase&.include?(search_term)) ||
                (p.skill_summary&.downcase&.include?(search_term))
            end
          end

          # Sort by created_at (newest first)
          result = result.sort_by { |p| -p.created_at.to_i }

          # Limit results
          limit = filters[:limit] || 50
          result = result.first(limit)

          result.map { |p| posting_to_hash(p) }
        end
      end

      # Get postings count
      def count(type: nil)
        @mutex.synchronize do
          cleanup_expired

          if type
            @postings.values.count { |p| p.type == type }
          else
            @postings.size
          end
        end
      end

      # Get statistics
      def stats
        @mutex.synchronize do
          cleanup_expired

          by_type = @postings.values.group_by(&:type).transform_values(&:count)
          by_format = @postings.values.group_by(&:skill_format).transform_values(&:count)
          
          all_tags = @postings.values.flat_map(&:tags)
          popular_tags = all_tags.tally.sort_by { |_tag, count| -count }.first(10).to_h

          {
            total_postings: @postings.size,
            by_type: by_type,
            by_format: by_format,
            popular_tags: popular_tags,
            unique_agents: @postings.values.map(&:agent_id).uniq.count
          }
        end
      end

      # Get postings for a specific agent
      def agent_postings(agent_id)
        @mutex.synchronize do
          cleanup_expired

          @postings.values
                   .select { |p| p.agent_id == agent_id }
                   .sort_by { |p| -p.created_at.to_i }
                   .map { |p| posting_to_hash(p) }
        end
      end

      private

      def generate_posting_id
        "post_#{SecureRandom.hex(8)}"
      end

      def expired?(posting)
        Time.now.utc > posting.expires_at
      end

      def cleanup_expired
        @postings.delete_if { |_id, posting| expired?(posting) }
      end

      def posting_to_hash(posting)
        {
          id: posting.id,
          agent_id: posting.agent_id,
          agent_name: posting.agent_name,
          type: posting.type,
          skill_name: posting.skill_name,
          skill_summary: posting.skill_summary,
          skill_format: posting.skill_format,
          tags: posting.tags,
          created_at: posting.created_at.iso8601,
          expires_at: posting.expires_at.iso8601,
          metadata: posting.metadata
        }
      end
    end
  end
end
