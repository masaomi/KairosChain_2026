# frozen_string_literal: true

require 'digest'

module Hestia
  # SkillBoard aggregates skills from registered agents and deposited skills.
  #
  # DEE design principles:
  # - Returns raw catalog — NO compatibility judgments
  # - Random sample (max N), NOT sorted by any metric (D3)
  # - NO ranking, scoring, or "recommended agents" (D5)
  # - Each agent decides compatibility locally
  #
  # Deposit model:
  # - Agents deposit skills (metadata + content) to the Place
  # - Place validates format safety, size, hash, signature (deposit gate)
  # - Place does NOT verify content quality — only depositor identity
  # - Trust notice attached to all responses
  class SkillBoard
    DEFAULT_MAX_RESULTS = 50
    SAFE_FORMATS = %w[markdown yaml_frontmatter].freeze
    DEFAULT_MAX_SKILL_SIZE = 100_000
    DEFAULT_MAX_SKILLS_PER_AGENT = 20
    DEFAULT_MAX_TOTAL_DEPOSITS = 500

    def initialize(registry:, config: {})
      @registry = registry
      @posted_needs = []
      @deposited_skills = []
      @deposit_config = config
    end

    # Deposit a skill to the Place. Validates format, size, hash, and signature.
    # Internal key is "agent_id/skill_id" to prevent cross-agent collisions.
    #
    # @param agent_id [String] Depositor's agent ID (from session token)
    # @param skill [Hash] Skill data with :skill_id, :name, :content, etc.
    # @param public_key [String, nil] Depositor's public key for signature verification
    # @return [Hash] { valid: true/false, ... }
    def deposit_skill(agent_id:, skill:, public_key: nil)
      validation = validate_deposit(skill, agent_id: agent_id, public_key: public_key)
      return validation unless validation[:valid]

      internal_key = "#{agent_id}/#{skill[:skill_id]}"

      # Replace existing deposit of same skill from same agent
      @deposited_skills.reject! { |d| d[:internal_key] == internal_key }

      @deposited_skills << {
        internal_key: internal_key,
        agent_id: agent_id,
        skill_id: skill[:skill_id],
        name: skill[:name],
        description: skill[:description],
        tags: skill[:tags] || [],
        format: skill[:format] || 'markdown',
        content: skill[:content],
        content_hash: skill[:content_hash],
        size_bytes: skill[:content]&.bytesize || 0,
        depositor_signature: skill[:signature],
        deposited_at: Time.now.utc.iso8601
      }

      { valid: true, status: 'deposited', skill_id: skill[:skill_id], internal_key: internal_key }
    end

    # Retrieve a deposited skill by skill_id. If owner_agent_id is provided,
    # uses the exact internal key. Otherwise, returns the first match.
    #
    # @param skill_id [String] The skill ID
    # @param owner_agent_id [String, nil] Owner's agent ID for exact match
    # @return [Hash, nil] The deposited skill or nil
    def get_deposited_skill(skill_id, owner_agent_id: nil)
      if owner_agent_id
        internal_key = "#{owner_agent_id}/#{skill_id}"
        @deposited_skills.find { |d| d[:internal_key] == internal_key }
      else
        @deposited_skills.find { |d| d[:skill_id] == skill_id }
      end
    end

    # Remove all deposits by an agent (called on unregister cleanup).
    def remove_deposits(agent_id)
      @deposited_skills.reject! { |d| d[:agent_id] == agent_id }
    end

    # Post knowledge needs for an agent (session-only, no persistence — DEE compliant).
    # Overwrites existing needs for the same agent_id.
    def post_need(agent_id:, agent_name:, agent_mode:, needs:)
      @posted_needs.reject! { |n| n[:agent_id] == agent_id }
      @posted_needs << {
        agent_id: agent_id,
        agent_name: agent_name,
        agent_mode: agent_mode,
        needs: needs,
        published_at: Time.now.utc.iso8601
      }
    end

    # Remove all needs posted by an agent (called on unregister cleanup).
    def remove_needs(agent_id)
      @posted_needs.reject! { |n| n[:agent_id] == agent_id }
    end

    # Browse available skills across all registered agents and deposited skills.
    #
    # Returns a random sample — never sorted by popularity, recency, or any metric.
    def browse(type: nil, search: nil, tags: nil, limit: DEFAULT_MAX_RESULTS)
      all_entries = collect_all_entries

      # Apply filters
      entries = all_entries
      entries = entries.select { |e| e[:format] == type } if type
      entries = entries.select { |e| e[:name]&.downcase&.include?(search.downcase) } if search
      if tags && !tags.empty?
        entries = entries.select do |e|
          entry_tags = e[:tags] || []
          tags.any? { |t| entry_tags.include?(t) }
        end
      end

      # Random sample — DEE principle: no ordering bias
      sampled = entries.size > limit ? entries.sample(limit) : entries.shuffle

      {
        entries: sampled,
        total_available: entries.size,
        returned: sampled.size,
        sampling: entries.size > limit ? 'random_sample' : 'all_shuffled',
        agents_contributing: sampled.map { |e| e[:agent_id] }.uniq.size
      }
    end

    # Deposit statistics for status reporting
    def deposit_stats
      {
        total_deposits: @deposited_skills.size,
        agents_with_deposits: @deposited_skills.map { |d| d[:agent_id] }.uniq.size,
        max_per_agent: max_skills_per_agent,
        max_total: max_total_deposits
      }
    end

    private

    def validate_deposit(skill, agent_id: nil, public_key: nil)
      errors = []
      content = skill[:content]
      format = skill[:format]

      # Format safety
      errors << "Unsafe format: #{format}" unless SAFE_FORMATS.include?(format)

      # Content required
      errors << 'Content is required' if content.nil? || content.empty?

      # Size limit
      max_size = @deposit_config['max_skill_size_bytes'] || DEFAULT_MAX_SKILL_SIZE
      errors << "Exceeds size limit (#{max_size} bytes)" if content && content.bytesize > max_size

      # Content hash verification
      if content && skill[:content_hash]
        calculated = Digest::SHA256.hexdigest(content)
        errors << 'Content hash mismatch' if calculated != skill[:content_hash]
      else
        errors << 'Content hash is required' unless skill[:content_hash]
      end

      # Signature required
      unless skill[:signature]
        errors << 'Deposit signature is required'
      end

      # Signature verification (if public_key available)
      if skill[:signature] && public_key
        begin
          crypto = ::MMP::Crypto.new(auto_generate: false)
          unless crypto.verify_signature(content, skill[:signature], public_key)
            errors << 'Signature verification failed'
          end
        rescue StandardError => e
          errors << "Signature verification error: #{e.message}"
        end
      end

      # Per-agent quota
      if agent_id
        agent_count = @deposited_skills.count { |d| d[:agent_id] == agent_id }
        if agent_count >= max_skills_per_agent
          errors << "Per-agent quota exceeded (max #{max_skills_per_agent})"
        end
      end

      # Total quota
      if @deposited_skills.size >= max_total_deposits
        errors << "Total deposit quota exceeded (max #{max_total_deposits})"
      end

      # Skill ID required
      errors << 'skill_id is required' unless skill[:skill_id] && !skill[:skill_id].empty?

      { valid: errors.empty?, errors: errors }
    end

    def max_skills_per_agent
      @deposit_config['max_skills_per_agent'] || DEFAULT_MAX_SKILLS_PER_AGENT
    end

    def max_total_deposits
      @deposit_config['max_total_deposits'] || DEFAULT_MAX_TOTAL_DEPOSITS
    end

    def collect_all_entries
      agents = @registry.list(include_self: true)
      entries = []

      agents.each do |agent|
        skills = agent[:capabilities]
        next unless skills.is_a?(Hash)

        skill_formats = skills[:skill_formats] || skills['skill_formats'] || []
        supported = skills[:supported_actions] || skills['supported_actions'] || []

        # Each agent contributes their capability info as board entries
        entries << {
          agent_id: agent[:id],
          agent_name: agent[:name],
          name: agent[:name],
          format: 'agent',
          type: 'agent',
          capabilities: supported,
          skill_formats: skill_formats,
          is_self: agent[:is_self],
          tags: [],
          registered_at: agent[:registered_at]
        }
      end

      # Add need entries from posted needs (session-only, in-memory)
      @posted_needs.each do |posted|
        posted[:needs].each do |need|
          entries << {
            agent_id: posted[:agent_id],
            agent_name: posted[:agent_name],
            name: need[:name],
            format: 'need',
            type: 'need',
            description: need[:description],
            agent_mode: posted[:agent_mode],
            tags: ['knowledge_need'],
            published_at: posted[:published_at]
          }
        end
      end

      # Add deposited skills
      @deposited_skills.each do |dep|
        entries << {
          agent_id: dep[:agent_id],
          name: dep[:name],
          skill_id: dep[:skill_id],
          description: dep[:description],
          format: dep[:format],
          type: 'deposited_skill',
          tags: dep[:tags],
          size_bytes: dep[:size_bytes],
          deposited_at: dep[:deposited_at],
          trust_notice: {
            verified_by_place: false,
            depositor_signed: !!dep[:depositor_signature],
            depositor_id: dep[:agent_id],
            disclaimer: 'Place verified format safety and depositor identity only.'
          }
        }
      end

      entries
    end
  end
end
