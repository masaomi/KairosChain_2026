# frozen_string_literal: true

require 'yaml'
require 'digest'
require 'json'
require 'fileutils'
require 'securerandom'

module MMP
  class Identity
    PLACE_ID_FILE = 'mmp_place_id'
    PLACE_ID_PATTERN = /\A[0-9a-f]{16}\z/

    attr_reader :config

    # @param auto_generate_key [Boolean] create keys/mmp_keypair.pem when it is
    #   missing. A listener under an admission policy passes false, so a probe
    #   can never mint a new identity for this instance (secure MMP v1).
    def initialize(workspace_root: nil, config: nil, auto_generate_key: true)
      @workspace_root = workspace_root
      @config = config || MMP.load_config
      @crypto = nil
      @auto_generate_key = auto_generate_key
    end

    def introduce
      intro_data = {
        identity: identity_info,
        capabilities: capabilities_info,
        skills: public_skill_entries,
        exchangeable_skillsets: exchangeable_skillset_info,
        constraints: constraints_info,
        exchange_policy: exchange_policy,
        timestamp: Time.now.utc.iso8601
      }

      # Signed introduce (H2 fix: attach public key and identity signature)
      if crypto_available?
        intro_data[:public_key] = crypto.export_public_key
        intro_data[:key_fingerprint] = crypto.key_fingerprint
        # Sign canonical identity_info so receiver can verify
        canonical = JSON.generate(intro_data[:identity], sort_keys: true)
        intro_data[:identity_signature] = crypto.sign(canonical)
      end

      intro_data
    end

    def capabilities
      capabilities_info
    end

    def capabilities_info(extensions: nil)
      cap_config = @config['capabilities'] || {}
      info = {
        meeting_protocol_version: cap_config['meeting_protocol_version'] || '1.0.0',
        supported_actions: cap_config['supported_actions'] || %w[introduce offer_skill request_skill],
        skill_formats: allowed_formats
      }
      info[:extensions] = extensions if extensions && !extensions.empty?
      info
    end

    # The one public L1 set (I1). Entries keep :path for reading content
    # in-process; nothing built from this for the wire may carry it.
    def public_skills
      available_skills.select { |s| s[:public] }
    end

    # Public L1 entries as they go on the wire: no filesystem path.
    def public_skill_entries
      public_skills.map { |s| s.reject { |k, _| k == :path } }
    end

    # The smallest introduce a direct-mode peer needs: who we are, our key and
    # the signature over our identity. Nothing about skills or SkillSets.
    def minimal_introduce
      intro = { identity: identity_info, timestamp: Time.now.utc.iso8601 }
      if crypto_available?
        intro[:public_key] = crypto.export_public_key
        intro[:key_fingerprint] = crypto.key_fingerprint
        intro[:identity_signature] = crypto.sign(JSON.generate(intro[:identity], sort_keys: true))
      end
      intro
    end

    def instance_id
      @instance_id ||= generate_instance_id
    end

    # The id this install presents to Meeting Places, kept in keys/mmp_place_id
    # beside the MMP keypair. A keypair created by this version is created
    # together with a fresh random id; an install whose keypair predates the file
    # gets the id it has always presented written once and keeps it. instance_id
    # (P2P, Synoptis, a Place's own self-registration) is not affected.
    def place_agent_id
      crypto_available? # a keypair created here comes with a random id file
      existing = read_place_id
      return existing if existing

      write_place_id(legacy_place_agent_id, overwrite: false)
      read_place_id || legacy_place_agent_id
    end

    # Replace the Place-facing id with a fresh random one (meeting_connect fresh_id).
    # Items held under the old id at any Place stay with the old id.
    def fresh_place_agent_id!
      crypto_available?
      write_place_id(SecureRandom.hex(8), overwrite: true)
      read_place_id
    end

    # Put back a Place-facing id (meeting_connect restores the previous id
    # when registering under a fresh one fails).
    def restore_place_agent_id!(value)
      raise ArgumentError, 'Place id must be 16 lowercase hex characters' unless PLACE_ID_PATTERN.match?(value.to_s)

      write_place_id(value, overwrite: true)
      read_place_id
    end

    # Public accessor for the Identity's crypto instance.
    # Ensures the same keypair is used for signing and verification.
    def crypto
      crypto_available?
      @crypto
    end

    private

    def identity_info
      id_config = @config['identity'] || {}
      {
        name: id_config['name'] || 'KairosChain Instance',
        description: id_config['description'] || 'A memory-capable, evolvable agent framework',
        scope: id_config['scope'] || 'general',
        version: MMP::VERSION,
        instance_id: generate_instance_id
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
      { allowed_formats: allowed_formats, allow_executable: executable_allowed?, public_by_default: public_by_default? }
    end

    def allowed_formats
      (@config.dig('skill_exchange', 'allowed_formats') || %w[markdown yaml_frontmatter])
    end

    def executable_allowed?
      @config.dig('skill_exchange', 'allow_executable') == true
    end

    def public_by_default?
      @config.dig('skill_exchange', 'public_by_default') == true
    end

    def available_skills
      skills = []
      knowledge_dir = knowledge_path
      if knowledge_dir && File.directory?(knowledge_dir)
        entry_public = {}
        Dir.glob(File.join(knowledge_dir, '**', '*.md')).each do |file|
          skill = parse_skill_file(file, 'L1', entry_public: entry_public, knowledge_dir: knowledge_dir)
          skills << skill if skill
        end
      end
      skills
    end

    # Publicity belongs to an L1 entry, decided by its main file
    # (knowledge/<entry>/<entry>.md): its own `public:` key, else
    # public_by_default. Other files under the entry inherit that decision
    # and can only narrow it (a `public:` that is not true), never widen it.
    # Any file that opens front matter it cannot read is private, as main
    # file or sub-document.
    def entry_public?(file_path, knowledge_dir, cache)
      relative = file_path.sub(%r{\A#{Regexp.escape(knowledge_dir)}/}, '')
      entry = relative.split('/').first
      return false if entry.nil? || entry == File.basename(file_path) # a loose file outside any entry

      cache.fetch(entry) do
        main = File.join(knowledge_dir, entry, "#{entry}.md")
        cache[entry] = File.file?(main) && own_publicity(frontmatter_of(File.read(main)))
      end
    end

    # Whether a file is public by its own front matter alone.
    def own_publicity(fm)
      case fm
      when :none then public_by_default?
      when Hash then fm.key?('public') ? fm['public'] == true : public_by_default?
      else false
      end
    end

    # A file's front matter: a Hash, :none when it has none, or :unreadable
    # when it opens one that does not read as a Hash — a YAML error, a Date
    # value, no closing ---. Whatever precedes the first visible ASCII
    # character (BOMs, NUL, whitespace, any invisible or non-ASCII run) is
    # skipped before looking for ---: what counts is the shape, not a list
    # of characters to strip.
    def frontmatter_of(content)
      text = content.sub(/\A[^\x21-\x7E]+/, '')
      return :none unless text.start_with?('---')

      fm = extract_frontmatter(text)
      fm.is_a?(Hash) ? fm : :unreadable
    end

    def parse_skill_file(file_path, layer, entry_public: {}, knowledge_dir: nil)
      content = File.read(file_path)
      fm = frontmatter_of(content)
      frontmatter = fm.is_a?(Hash) ? fm : nil
      is_public = if knowledge_dir
                    entry_public?(file_path, knowledge_dir, entry_public) &&
                      fm != :unreadable && !(frontmatter&.key?('public') && frontmatter['public'] != true)
                  else
                    own_publicity(fm)
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
    rescue StandardError
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
      return frontmatter['description'] if frontmatter&.dig('description')
      lines = content.lines.map(&:strip).reject(&:empty?)
      if content.start_with?('---')
        in_fm = true
        lines = lines.drop_while { |l| (in_fm = false if l == '---' && !in_fm) || (l == '---' ? (in_fm = false; true) : in_fm) }
      end
      lines.find { |l| !l.start_with?('#') && !l.empty? }&.slice(0, 200) || 'No description available'
    end

    def generate_skill_id(file_path)
      relative = @workspace_root ? file_path.sub(@workspace_root, '').sub(%r{^/}, '') : File.basename(file_path)
      Digest::SHA256.hexdigest(relative)[0, 16]
    end

    def generate_instance_id
      seed = [@workspace_root, @config.to_s].join(':')
      Digest::SHA256.hexdigest(seed)[0, 16]
    end

    def exchangeable_skillset_info
      return [] unless defined?(KairosMcp)

      require 'kairos_mcp/skillset_manager'
      begin
        require 'kairos_mcp/admission_records'
      rescue LoadError
        return []
      end

      manager = KairosMcp::SkillSetManager.new
      records = KairosMcp::AdmissionRecords.for_data_dir
      manager.all_skillsets.select { |ss| ss.exchangeable? && records.published?(ss.name, ss.content_hash) }.map do |ss|
        { name: ss.name, version: ss.version, layer: ss.layer.to_s,
          description: ss.description, content_hash: ss.content_hash }
      end
    rescue StandardError
      []
    end

    def knowledge_path
      return nil unless @workspace_root
      path = File.join(@workspace_root, 'knowledge')
      File.directory?(path) ? path : nil
    end

    # Crypto key management for identity signing (H2 fix)
    def crypto_available?
      # A missing key is not latched when this identity may not create one:
      # once the key file appears (created by another process) it is used.
      return !@crypto.nil? if @crypto_checked && (@crypto || @auto_generate_key)

      @crypto_checked = true
      keypair_path = File.join(keypair_dir, 'mmp_keypair.pem')
      return false unless @auto_generate_key || File.exist?(keypair_path)

      @crypto = begin
        c = MMP::Crypto.new(keypair_path: keypair_path, auto_generate: @auto_generate_key)
        unless File.exist?(keypair_path)
          # The file vanished after the check: an identity that may not
          # create keys mints none.
          raise 'keypair file disappeared while loading' unless @auto_generate_key

          FileUtils.mkdir_p(keypair_dir)
          # The Place-facing id is born with the key, and written first so a
          # crash between the two writes never leaves a key without its id.
          write_place_id(SecureRandom.hex(8), overwrite: true)
          c.save_keypair(keypair_path)
        end
        c
      rescue StandardError => e
        $stderr.puts "[Identity] Crypto initialization failed: #{e.message}"
        nil
      end
      !@crypto.nil?
    end

    def keypair_dir
      base_dir = @workspace_root || (defined?(KairosMcp) && KairosMcp.respond_to?(:data_dir) ? KairosMcp.data_dir : '.')
      File.join(base_dir, 'keys')
    end

    def place_id_path
      File.join(keypair_dir, PLACE_ID_FILE)
    end

    # The id meeting_connect has always presented: derived from config contents
    # only, regardless of workspace root.
    def legacy_place_agent_id
      Digest::SHA256.hexdigest(":#{@config}")[0, 16]
    end

    # @return [String, nil] the stored id; raises if the file holds anything else,
    #   so a damaged file is noticed rather than silently replaced.
    def read_place_id
      path = place_id_path
      return nil unless File.exist?(path)

      value = File.read(path).strip
      raise "Invalid Place id file #{path}: expected 16 lowercase hex characters" unless PLACE_ID_PATTERN.match?(value)

      value
    end

    # Atomic write. overwrite: false never replaces an existing file (a
    # concurrent writer that got there first wins).
    def write_place_id(value, overwrite:)
      path = place_id_path
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
      File.write(tmp, value)
      if overwrite
        File.rename(tmp, path)
      else
        begin
          File.link(tmp, path)
        rescue Errno::EEXIST
          nil
        rescue NotImplementedError, Errno::EPERM, Errno::EOPNOTSUPP
          # No hard links on this filesystem: fall back to a rename, which can
          # only race with another first writer of the same install.
          File.rename(tmp, path) unless File.exist?(path)
        end
      end
    ensure
      File.unlink(tmp) if tmp && File.exist?(tmp)
    end

  end
end
