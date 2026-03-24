# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'time'
require 'yaml'

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

    MAX_SUMMARY_BYTES = 500
    MAX_INPUT_OUTPUT_BYTES = 1000
    MAX_PREVIEW_LINES = 100
    DEFAULT_DEPOSIT_RATE_LIMIT = 10  # per hour
    MAX_DESCRIPTION_BYTES = 500

    def initialize(registry:, config: {}, storage_path: nil, self_place_id: nil,
                   federation_config: {}, trust_scorer: nil)
      @registry = registry
      @posted_needs = []
      @deposited_skills = []
      @deposit_config = config
      @federation_config = federation_config
      @trust_scorer = trust_scorer  # Optional Synoptis::TrustScorer (DI)
      @exchange_counts = {}  # internal_key => count
      @total_exchange_count = 0
      @deposit_timestamps = {}  # agent_id => [Time] for rate limiting
      @attestations = []  # attestation deposits on skills
      @self_place_id = self_place_id
      @storage_path = storage_path || 'storage/skill_board_state.json'
      @content_dir = File.join(File.dirname(@storage_path), 'deposits')
      @state_dirty = false
      @mutex = Mutex.new
      load_state
    end

    # Deposit a skill to the Place. Validates format, size, hash, and signature.
    # Internal key is "agent_id/skill_id" to prevent cross-agent collisions.
    #
    # @param agent_id [String] Depositor's agent ID (from session token)
    # @param skill [Hash] Skill data with :skill_id, :name, :content, etc.
    # @param public_key [String, nil] Depositor's public key for signature verification
    # @return [Hash] { valid: true/false, ... }
    def deposit_skill(agent_id:, skill:, public_key: nil)
      internal_key = "#{agent_id}/#{skill[:skill_id]}"

      @mutex.synchronize do
        # Deposit rate limit (per agent, per hour) — gates attempts, not just successes
        unless check_deposit_rate(agent_id)
          return { valid: false, errors: ["Deposit rate limit exceeded (max #{deposit_rate_limit}/hour)"] }
        end
        record_deposit_timestamp(agent_id)

        # Exclude existing deposit of same key from quota checks (allows updates at quota limit)
        is_replacement = @deposited_skills.any? { |d| d[:internal_key] == internal_key }
        validation = validate_deposit(skill, agent_id: agent_id, public_key: public_key,
                                      replacing_key: is_replacement ? internal_key : nil)
        return validation unless validation[:valid]

        # Replace existing deposit of same skill from same agent
        @deposited_skills.reject! { |d| d[:internal_key] == internal_key }

        now = Time.now.utc.iso8601
        provenance = build_provenance(skill[:provenance], agent_id, now)

        # Truncate metadata to prevent abuse
        summary = skill[:summary]
        summary = summary[0, MAX_SUMMARY_BYTES] if summary && summary.bytesize > MAX_SUMMARY_BYTES
        input_output = skill[:input_output]
        if input_output
          io_json = JSON.generate(input_output) rescue '{}'
          input_output = nil if io_json.bytesize > MAX_INPUT_OUTPUT_BYTES
        end

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
          deposited_at: now,
          provenance: provenance,
          summary: summary,
          input_output: input_output
        }

        save_content(internal_key, skill[:content])
        save_state
      end

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
      removed = @deposited_skills.select { |d| d[:agent_id] == agent_id }
      @deposited_skills.reject! { |d| d[:agent_id] == agent_id }
      removed.each { |d| delete_content(d[:internal_key]) }
      save_state if removed.any?
    end

    # Record an acquire event for a deposited skill.
    # Uses internal_key (agent_id/skill_id) to avoid cross-agent count collisions.
    #
    # @param internal_key [String] The internal key of the acquired skill
    # @param acquirer_id [String] The acquiring agent's ID
    def record_acquire(internal_key, acquirer_id)
      @exchange_counts[internal_key] = (@exchange_counts[internal_key] || 0) + 1
      @total_exchange_count += 1
      @state_dirty = true
    end

    # Withdraw a deposited skill. Only the depositor can withdraw their own skill.
    #
    # @param agent_id [String] Requesting agent's ID (must match depositor)
    # @param skill_id [String] The skill ID to withdraw
    # @return [Hash] { valid: true/false, ... }
    def withdraw_skill(agent_id:, skill_id:)
      internal_key = "#{agent_id}/#{skill_id}"

      @mutex.synchronize do
        deposit = @deposited_skills.find { |d| d[:internal_key] == internal_key }
        unless deposit
          return { valid: false, error: 'not_found', message: "No deposit found: #{skill_id} (owner: #{agent_id})" }
        end

        content_hash = deposit[:content_hash]
        @deposited_skills.reject! { |d| d[:internal_key] == internal_key }
        @exchange_counts.delete(internal_key)
        delete_content(internal_key)
        save_state

        { valid: true, status: 'withdrawn', skill_id: skill_id, content_hash: content_hash }
      end
    end

    # Preview a deposited skill without full content download.
    # Returns structured overview: summary, sections, first N lines, trust metadata.
    #
    # @param skill_id [String] The skill ID
    # @param owner_agent_id [String, nil] Owner's agent ID for exact match
    # @param first_lines [Integer] Number of content lines to include (default: 30)
    # @return [Hash, nil] Preview data or nil
    def preview_skill(skill_id, owner_agent_id: nil, first_lines: 30)
      dep = get_deposited_skill(skill_id, owner_agent_id: owner_agent_id)
      return nil unless dep

      first_lines = [[first_lines.to_i, 1].max, MAX_PREVIEW_LINES].min
      content = dep[:content] || ''
      fm_fields = extract_frontmatter_fields(content)
      result = {
        skill_id: dep[:skill_id],
        name: dep[:name],
        description: dep[:description],
        tags: dep[:tags],
        format: dep[:format],
        size_bytes: dep[:size_bytes],
        content_size_lines: content.lines.size,
        deposited_at: dep[:deposited_at],
        depositor_id: dep[:agent_id],
        content_hash: dep[:content_hash],
        summary: dep[:summary] || extract_content_summary(content),
        sections: extract_sections(content),
        input_output: dep[:input_output],
        first_lines: content.lines.first(first_lines).join,
        trust_metadata: build_trust_metadata(dep)
      }
      result[:version] = fm_fields[:version] if fm_fields[:version]
      result[:license] = fm_fields[:license] if fm_fields[:license]
      skill_attestations = get_attestations(dep[:skill_id], owner_agent_id: dep[:agent_id])
      unless skill_attestations.empty?
        result[:attestations] = skill_attestations.map do |a|
          { attester_id: a[:attester_id], attester_name: a[:attester_name],
            claim: a[:claim], evidence_hash: a[:evidence_hash], deposited_at: a[:deposited_at],
            has_signature: !!a[:signature], signed_payload: a[:signed_payload], signature: a[:signature] }
        end
      end
      result
    end

    # Flush dirty state to disk. Called from HeartbeatManager or status checks.
    def flush_if_dirty
      return unless @state_dirty
      save_state
      @state_dirty = false
    end

    # Total exchange count across all skills
    def total_exchanges
      @total_exchange_count
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
      entries = entries.select { |e| e[:type] == type } if type
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

    # Clean up expired federated deposits (hop_count > 0 only).
    # Local deposits never expire — depositor is responsible.
    # Called from HeartbeatManager check cycle.
    def cleanup_expired_deposits
      max_age = @federation_config['max_deposit_age_hours'] || 168
      cutoff = Time.now.utc - (max_age * 3600)

      expired = @deposited_skills.select do |dep|
        prov = dep[:provenance]
        next false unless prov && prov[:hop_count].to_i > 0
        origin_time = Time.parse(prov[:deposited_at_origin]) rescue nil
        origin_time && origin_time < cutoff
      end

      expired.each { |d| delete_content(d[:internal_key]) }
      @deposited_skills -= expired
      save_state if expired.any?
      { removed: expired.size, remaining: @deposited_skills.size }
    end

    # Deposit an attestation on a skill. Attester must be authenticated.
    # Stores a copy of the attestation metadata + signature on the Place.
    # The original proof stays with the attester.
    #
    # @param attester_id [String] Agent ID of the attester
    # @param attester_name [String] Display name of the attester
    # @param skill_id [String] ID of the attested skill
    # @param owner_agent_id [String] Owner of the attested skill
    # @param claim [String] Attestation claim (e.g., "reviewed", "used_in_production")
    # @param evidence_hash [String, nil] SHA256 hash of evidence (full evidence stays with attester)
    # @param signature [String, nil] RSA signature of the signed_payload
    # @param signed_payload [String, nil] Canonical payload that was signed
    # @return [Hash] Result
    def deposit_attestation(attester_id:, attester_name: nil, skill_id:, owner_agent_id:,
                            claim:, evidence_hash: nil, signature: nil, signed_payload: nil)
      # Verify the skill exists
      internal_key = "#{owner_agent_id}/#{skill_id}"
      deposit = @deposited_skills.find { |d| d[:internal_key] == internal_key }
      unless deposit
        return { valid: false, error: 'skill_not_found', message: "No deposit found: #{skill_id} (owner: #{owner_agent_id})" }
      end

      # Prevent duplicate attestation (same attester + same claim on same skill)
      existing = @attestations.find do |a|
        a[:attester_id] == attester_id && a[:skill_id] == skill_id &&
          a[:owner_agent_id] == owner_agent_id && a[:claim] == claim
      end
      if existing
        return { valid: false, error: 'duplicate', message: "Attestation already exists: #{claim} by #{attester_id}" }
      end

      now = Time.now.utc.iso8601
      attestation = {
        attester_id: attester_id,
        attester_name: attester_name,
        skill_id: skill_id,
        owner_agent_id: owner_agent_id,
        internal_key: internal_key,
        claim: claim,
        evidence_hash: evidence_hash,
        signature: signature,
        signed_payload: signed_payload,
        deposited_at: now
      }

      @attestations << attestation
      save_state

      { valid: true, status: 'attestation_deposited', claim: claim, skill_id: skill_id, deposited_at: now }
    end

    # Get attestations for a deposited skill.
    def get_attestations(skill_id, owner_agent_id: nil)
      if owner_agent_id
        internal_key = "#{owner_agent_id}/#{skill_id}"
        @attestations.select { |a| a[:internal_key] == internal_key }
      else
        @attestations.select { |a| a[:skill_id] == skill_id }
      end
    end

    # Deposit limits for publishing in /place/v1/info.
    # Note: deposit_rate_limit is process-scoped (resets on server restart).
    def deposit_limits
      {
        max_skills_per_agent: max_skills_per_agent,
        max_total_deposits: max_total_deposits,
        max_skill_size_bytes: @deposit_config['max_skill_size_bytes'] || DEFAULT_MAX_SKILL_SIZE,
        deposit_rate_limit_per_hour: deposit_rate_limit,
        deposit_rate_limit_scope: 'process',
        max_summary_bytes: MAX_SUMMARY_BYTES,
        max_description_bytes: MAX_DESCRIPTION_BYTES,
        max_preview_lines: MAX_PREVIEW_LINES
      }
    end

    # Compile a public profile bundle for an agent (for /place/v1/agent_profile/:id).
    # Returns aggregated public data: identity, deposited skills metadata, needs.
    def compile_agent_profile(agent_id)
      agent_full = @registry.get(agent_id)
      return nil unless agent_full

      # Whitelist public-safe fields only (exclude visited_places, last_heartbeat, is_self, url)
      agent = {
        id: agent_full[:id],
        name: agent_full[:name],
        description: agent_full[:description],
        scope: agent_full[:scope],
        capabilities: agent_full[:capabilities],
        registered_at: agent_full[:registered_at]
      }.compact

      skills = @deposited_skills.select { |d| d[:agent_id] == agent_id }.map do |dep|
        content = dep[:content] || ''
        fm_fields = extract_frontmatter_fields(content)
        skill_entry = {
          skill_id: dep[:skill_id],
          name: dep[:name],
          description: dep[:description],
          tags: dep[:tags],
          summary: dep[:summary] || extract_content_summary(content),
          sections: extract_sections(content),
          content_hash: dep[:content_hash],
          deposited_at: dep[:deposited_at],
          size_bytes: dep[:size_bytes],
          content_size_lines: content.lines.size,
          exchange_count: @exchange_counts[dep[:internal_key]] || 0
        }
        skill_entry[:version] = fm_fields[:version] if fm_fields[:version]
        skill_entry[:license] = fm_fields[:license] if fm_fields[:license]
        skill_entry
      end

      needs = @posted_needs.select { |n| n[:agent_id] == agent_id }

      {
        agent: agent,
        deposited_skills: skills,
        deposit_count: skills.size,
        posted_needs: needs,
        profile_generated_at: Time.now.utc.iso8601,
        note: 'Public profile bundle. Interpret through your own cognitive lens.'
      }
    end

    # Deposit statistics for status reporting
    def deposit_stats
      federated = @deposited_skills.count { |d| d.dig(:provenance, :hop_count).to_i > 0 }
      {
        total_deposits: @deposited_skills.size,
        local_deposits: @deposited_skills.size - federated,
        federated_deposits: federated,
        agents_with_deposits: @deposited_skills.map { |d| d[:agent_id] }.uniq.size,
        max_per_agent: max_skills_per_agent,
        max_total: max_total_deposits
      }
    end

    private

    def agent_deposit_count(agent_id)
      @deposited_skills.count { |d| d[:agent_id] == agent_id }
    end

    def validate_deposit(skill, agent_id: nil, public_key: nil, replacing_key: nil)
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

      # Per-agent quota (exclude the deposit being replaced)
      if agent_id
        agent_count = @deposited_skills.count { |d| d[:agent_id] == agent_id && d[:internal_key] != replacing_key }
        if agent_count >= max_skills_per_agent
          errors << "Per-agent quota exceeded (max #{max_skills_per_agent})"
        end
      end

      # Total quota (exclude the deposit being replaced)
      effective_total = replacing_key ? @deposited_skills.size - 1 : @deposited_skills.size
      if effective_total >= max_total_deposits
        errors << "Total deposit quota exceeded (max #{max_total_deposits})"
      end

      # Skill ID required
      errors << 'skill_id is required' unless skill[:skill_id] && !skill[:skill_id].empty?

      # Format Gate: structural validation for yaml_frontmatter deposits
      if format == 'yaml_frontmatter' && content && !content.empty?
        unless content.start_with?('---')
          errors << 'yaml_frontmatter format requires YAML frontmatter delimiters (---)'
        else
          parts = content.split(/^---\s*$/, 3)
          if parts.length < 3
            errors << 'yaml_frontmatter format requires valid frontmatter (---...---)'
          else
            begin
              fm = YAML.safe_load(parts[1])
              errors << 'Frontmatter must be a valid YAML hash' unless fm.is_a?(Hash)
            rescue StandardError => e
              errors << "Invalid YAML frontmatter: #{e.message}"
            end
          end
        end
      end

      # Description size limit
      if skill[:description] && skill[:description].bytesize > MAX_DESCRIPTION_BYTES
        errors << "Description exceeds size limit (#{MAX_DESCRIPTION_BYTES} bytes)"
      end

      # Federation validation (for deposits with provenance from other Places)
      if skill[:provenance] && skill[:provenance][:hop_count].to_i > 0
        # Check if federation is accepted
        unless federation_accept?
          errors << 'This Place does not accept federated deposits'
        end

        # Hop count limit
        max_hops = @federation_config['max_hop_count'] || 3
        if skill[:provenance][:hop_count].to_i >= max_hops
          errors << "Hop count exceeds limit (max #{max_hops})"
        end

        # Loop detection: reject if this Place is already in the via list
        if skill[:provenance][:via].is_a?(Array) && @self_place_id
          if skill[:provenance][:via].include?(@self_place_id)
            errors << 'Loop detected: this Place is already in the provenance chain'
          end
        end

        # Age limit for federated deposits
        if skill[:provenance][:deposited_at_origin]
          max_age = @federation_config['max_deposit_age_hours'] || 168
          begin
            origin_time = Time.parse(skill[:provenance][:deposited_at_origin])
            now = Time.now.utc
            if origin_time > now
              errors << 'Federated deposit has future timestamp'
            elsif (now - origin_time) > max_age * 3600
              errors << "Federated deposit too old (max #{max_age} hours)"
            end
          rescue ArgumentError
            errors << 'Invalid deposited_at_origin timestamp'
          end
        end
      end

      { valid: errors.empty?, errors: errors }
    end

    def max_skills_per_agent
      @deposit_config['max_skills_per_agent'] || DEFAULT_MAX_SKILLS_PER_AGENT
    end

    def max_total_deposits
      @deposit_config['max_total_deposits'] || DEFAULT_MAX_TOTAL_DEPOSITS
    end

    def deposit_rate_limit
      [(@deposit_config['deposit_rate_limit'] || DEFAULT_DEPOSIT_RATE_LIMIT).to_i, 1].max
    end

    def check_deposit_rate(agent_id)
      now = Time.now.utc
      cutoff = now - 3600
      @deposit_timestamps[agent_id] = (@deposit_timestamps[agent_id] || []).select { |t| t > cutoff }
      @deposit_timestamps[agent_id].size < deposit_rate_limit
    end

    def record_deposit_timestamp(agent_id)
      @deposit_timestamps[agent_id] ||= []
      @deposit_timestamps[agent_id] << Time.now.utc
    end

    # Build trust_metadata for a deposited skill.
    # Includes Synoptis trust score when trust_scorer is available (DI).
    # DEE compliant: factual metadata only, no ranking or recommendation.
    def build_trust_metadata(dep)
      metadata = {
        exchange_count: @exchange_counts[dep[:internal_key]] || 0,
        depositor_deposit_count: agent_deposit_count(dep[:agent_id]),
        first_deposited: dep[:deposited_at],
        provenance: {
          is_local: dep.dig(:provenance, :hop_count).to_i == 0,
          hop_count: dep.dig(:provenance, :hop_count) || 0,
          origin_place_id: dep.dig(:provenance, :origin_place_id),
          origin_agent_id: dep.dig(:provenance, :origin_agent_id),
          via: dep.dig(:provenance, :via) || [],
          deposited_at_origin: dep.dig(:provenance, :deposited_at_origin)
        }
      }

      # Enrich with Synoptis trust score if available (graceful degradation)
      if @trust_scorer
        subject_ref = "skill://#{dep[:skill_id]}"
        begin
          score_result = @trust_scorer.calculate(subject_ref)
          metadata[:synoptis] = {
            trust_score: score_result[:score],
            attestation_count: score_result[:attestation_count],
            active_count: score_result[:active_count],
            details: score_result[:details]
          }
        rescue StandardError => e
          $stderr.puts "[SkillBoard] Synoptis scoring failed (non-fatal): #{e.message}"
        end
      end

      metadata
    end

    def federation_accept?
      # Both federation.enabled and federation.accept_federated must be true
      @federation_config.fetch('enabled', false) &&
        @federation_config.fetch('accept_federated', true)
    end

    # --- Persistence ---

    def save_state
      FileUtils.mkdir_p(File.dirname(@storage_path))
      data = {
        deposited_skills: @deposited_skills.map { |d| d.except(:content) },
        exchange_counts: @exchange_counts,
        total_exchange_count: @total_exchange_count,
        attestations: @attestations,
        updated_at: Time.now.utc.iso8601
      }
      temp = "#{@storage_path}.tmp"
      File.write(temp, JSON.pretty_generate(data))
      File.rename(temp, @storage_path)
      @state_dirty = false
    rescue StandardError => e
      $stderr.puts "[SkillBoard] Failed to save state: #{e.message}"
    end

    def load_state
      return unless File.exist?(@storage_path)
      data = JSON.parse(File.read(@storage_path), symbolize_names: true)
      @exchange_counts = (data[:exchange_counts] || {}).transform_keys(&:to_s)
      @total_exchange_count = data[:total_exchange_count] || 0
      @attestations = data[:attestations] || []
      (data[:deposited_skills] || []).each do |dep|
        ik = dep[:internal_key]&.to_s
        next unless ik
        content = load_content(ik)
        next unless content
        @deposited_skills << dep.merge(internal_key: ik, content: content)
      end
    rescue StandardError => e
      $stderr.puts "[SkillBoard] Failed to load state: #{e.message}"
    end

    def save_content(internal_key, content)
      return unless content
      FileUtils.mkdir_p(@content_dir)
      path = content_path(internal_key)
      File.write(path, content)
    rescue StandardError => e
      $stderr.puts "[SkillBoard] Failed to save content for #{internal_key}: #{e.message}"
    end

    def load_content(internal_key)
      path = content_path(internal_key)
      File.exist?(path) ? File.read(path) : nil
    rescue StandardError
      nil
    end

    def delete_content(internal_key)
      path = content_path(internal_key)
      File.delete(path) if File.exist?(path)
    rescue StandardError
      nil
    end

    def content_path(internal_key)
      sanitized = internal_key.gsub('/', '__').gsub('..', '_').gsub(/[^a-zA-Z0-9_\-]/, '_')
      File.join(@content_dir, "#{sanitized}.md")
    end

    # Extract ## headings from Markdown content.
    def extract_sections(content)
      content.lines.select { |l| l.match?(/^##\s/) }.map { |l| l.sub(/^##\s+/, '').strip }
    end

    # Extract frontmatter fields (version, license) from YAML frontmatter.
    def extract_frontmatter_fields(content)
      return {} unless content&.start_with?('---')
      parts = content.split(/^---\s*$/, 3)
      return {} if parts.length < 3
      fm = YAML.safe_load(parts[1])
      return {} unless fm.is_a?(Hash)
      fields = {}
      fields[:version] = fm['version'].to_s if fm['version']
      fields[:license] = fm['license'].to_s if fm['license']
      fields
    rescue StandardError
      {}
    end

    # Extract a summary from Markdown content (first paragraph after frontmatter/headings).
    def extract_content_summary(content)
      text = content
      if content.start_with?('---')
        parts = content.split(/^---\s*$/, 3)
        text = parts[2] || ''
      end
      lines = text.lines.map(&:strip)
      paragraph = lines.reject { |l| l.empty? || l.start_with?('#') }.first
      paragraph&.slice(0, 300) || ''
    end

    # --- Provenance ---

    def build_provenance(incoming_provenance, agent_id, timestamp)
      if incoming_provenance && incoming_provenance[:hop_count].to_i > 0
        # Federated deposit: preserve origin and hop_count as received
        # (client increments hop_count before POST), append self to via
        {
          origin_place_id: incoming_provenance[:origin_place_id],
          origin_agent_id: incoming_provenance[:origin_agent_id],
          via: (incoming_provenance[:via] || []) + [@self_place_id].compact,
          hop_count: incoming_provenance[:hop_count].to_i,
          deposited_at_origin: incoming_provenance[:deposited_at_origin]
        }
      else
        # Local deposit: this Place is the origin
        {
          origin_place_id: nil,
          origin_agent_id: agent_id,
          via: [],
          hop_count: 0,
          deposited_at_origin: timestamp
        }
      end
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
        entry = {
          agent_id: agent[:id],
          agent_name: agent[:name],
          name: agent[:name],
          format: 'agent',
          type: 'agent',
          capabilities: supported,
          skill_formats: skill_formats,
          is_self: agent[:is_self],
          tags: [],
          registered_at: agent[:registered_at],
          deposit_count: agent_deposit_count(agent[:id])
        }
        entry[:description] = agent[:description] if agent[:description]
        entry[:scope] = agent[:scope] if agent[:scope]
        entries << entry
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

      # Add deposited skills with trust_metadata, summary, and sections
      @deposited_skills.each do |dep|
        content = dep[:content] || ''
        fm_fields = extract_frontmatter_fields(content)
        entry = {
          agent_id: dep[:agent_id],
          name: dep[:name],
          skill_id: dep[:skill_id],
          description: dep[:description],
          format: dep[:format],
          type: 'deposited_skill',
          tags: dep[:tags],
          size_bytes: dep[:size_bytes],
          content_size_lines: content.lines.size,
          deposited_at: dep[:deposited_at],
          content_hash: dep[:content_hash],
          summary: dep[:summary] || extract_content_summary(content),
          sections: extract_sections(content),
          trust_notice: {
            verified_by_place: false,
            depositor_signed: !!dep[:depositor_signature],
            depositor_id: dep[:agent_id],
            disclaimer: 'Place verified format safety and depositor identity only.'
          },
          trust_metadata: build_trust_metadata(dep)
        }
        entry[:input_output] = dep[:input_output] if dep[:input_output]
        entry[:version] = fm_fields[:version] if fm_fields[:version]
        entry[:license] = fm_fields[:license] if fm_fields[:license]
        skill_attestations = get_attestations(dep[:skill_id], owner_agent_id: dep[:agent_id])
        unless skill_attestations.empty?
          entry[:attestations] = skill_attestations.map do |a|
            { attester_id: a[:attester_id], attester_name: a[:attester_name],
              claim: a[:claim], evidence_hash: a[:evidence_hash], deposited_at: a[:deposited_at],
              has_signature: !!a[:signature] }
          end
        end
        entries << entry
      end

      entries
    end
  end
end
