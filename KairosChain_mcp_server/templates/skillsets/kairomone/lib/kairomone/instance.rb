# frozen_string_literal: true

module Kairomone
  # The canonical provider performs creation and hash recording. Its optional
  # state-commit hook uses global host paths even with an injected backend;
  # suppress that hook for this explicitly isolated instance. No core patches,
  # host path resolver changes, or global configuration changes are made.
  class OwnedKnowledgeProvider < KairosMcp::KnowledgeProvider
    private

    def track_pending_change(**_args); end

    # The dot keeps no core 3.94+ L1 body history (hosted-dot design K4): its
    # bodies would sit in files the backup does not carry, and this create-only
    # store would gain nothing from them. A dot an earlier Kairomone let core
    # activate is closed by Instance#create_knowledge, which runs on every core.
    def keep_bodies!(*_bodies)
      nil
    end
  end

  # Kairomone before 0.6.1 let core 3.94+ activate L1 body history on the dot,
  # and such a dot's ledger still says so, also after a backup restore and on a
  # core that never asks the provider about history. Before the write it
  # guards, the switch-off is recorded on that ledger, in core's record shape,
  # so after every Kairomone L1 write the ledger states the regime in force. Only
  # the ledger is read: <dot>/l1_history/state.json may still say active and is
  # left as it is, and bodies already under l1_history/ stay there.
  module BodyHistory
    SWITCH_OFF_REASON = "Kairomone keeps no L1 body history; bodies stay in the dot's knowledge files"

    module_function

    # Read as core's history reads it: the last activation record wins.
    def declared_active?(ledger)
      declared = false
      ledger.chain.each do |block|
        Array(block.data).each do |raw|
          record = JSON.parse(raw) rescue nil
          next unless record.is_a?(Hash) && record['type'] == 'l1_history_activation'

          flag = record.key?('active') ? record['active'] : record['enabled']
          declared = [true, 'true'].include?(flag)
        end
      end
      declared
    end

    # ledger: a Chain whose load_state the caller has checked under the dot's
    # lock. Raises Error unless the switch-off is confirmed on the ledger, so
    # the guarded write does not happen.
    def close!(ledger, reread)
      return unless declared_active?(ledger)

      ledger.add_block([{ type: 'l1_history_activation', layer: 'L1', active: false,
                          timestamp: Time.now.utc.iso8601, reason: SWITCH_OFF_REASON }.to_json])
    rescue KairosMcp::Storage::Error => e
      # Unknown whether the append landed: decide on what the ledger now says.
      # A ledger that cannot be re-read confirms nothing.
      confirmed = begin
        after = reread.call
        after.load_state == :readable && !declared_active?(after)
      rescue StandardError
        false
      end
      return if confirmed

      raise Error, "The end of L1 body history may or may not be on the dot ledger; nothing else was written: #{e.message}"
    rescue StandardError => e
      raise Error, "Could not record the end of L1 body history on the dot ledger; nothing was written: #{e.message}"
    end
  end

  class Instance
    MAX_CONTENT = 16_384
    MAX_ENTRIES = 1_000
    L2_SESSION = 'kairomone'
    L0_FILES = %w[skills/kairos.rb skills/kairos.md].freeze
    BACKUP_SCOPE = ['Kairomone profile, explicit profession selection and host L0 baseline hashes', 'All owned canonical L1 knowledge and L2 observations', 'Complete dedicated Kairomone ledger; locally verified on restore', 'Bounded growth budget and history; restored workers and queued requests are stopped'].freeze
    BACKUP_EXCLUDED = ['Host KC knowledge, context, ledger and L0 file contents', 'External account/token stores, environment variables and unrelated host files (private user-authored L1/L2 text is included)', 'Installed SkillSet code, HTML exports, prior backups and lock files'].freeze

    attr_reader :root, :host_root

    def initialize(host_root: KairosMcp.data_dir, restored_id: nil, backend: nil)
      expanded = File.expand_path(host_root)
      @host_root = File.exist?(expanded) ? File.realpath(expanded) : expanded
      package_path = File.expand_path('../..', __dir__)
      package = File.exist?(package_path) ? File.realpath(package_path) : package_path
      raise Error, 'Runtime data must be outside the installed SkillSet package' if @host_root == package || @host_root.start_with?(package + '/')
      @root = if restored_id
                Paths.checked(@host_root, "kairomone-restored/#{Paths.id!(restored_id)}")
              else
                Paths.checked(@host_root, 'kairomone')
              end
      @restored = !!restored_id
      @backend_override = backend
    end

    def init(dot_id:, display_name:)
      Paths.id!(dot_id)
      title = text!(display_name, 'display_name', 256)
      raise Error, 'Restored targets are read-only; activation is a separate operator decision' if @restored
      with_lock(create: true) do
        if File.exist?(Paths.checked(root, 'profile.json'))
          existing = profile
          raise Error, 'This instance is already bound to a different dot_id' unless existing['dot_id'] == dot_id
          next { success: true, initialized: false, preserved: true, profile: existing }
        end
        unknown = Dir.children(root) - ['.lock']
        raise Error, 'Refusing to initialize a nonempty, unrecognized instance directory' unless unknown.empty?
        %w[knowledge context storage backups exports].each { |dir| Paths.mkdir(root, dir) }
        value = { 'schema_version' => 1, 'dot_id' => dot_id, 'display_name' => title,
                  'supply_profile' => 'basic', 'created_at' => Time.now.utc.iso8601,
                  'host_l0_baseline' => l0_fingerprints }
        Paths.write(root, 'profile.json', JSON.pretty_generate(value) + "\n")
        { success: true, initialized: true, preserved: false, profile: value }
      end
    end

    def profile
      value = JSON.parse(Paths.read(root, 'profile.json', limit: 65_536))
      validate_profile!(value)
      value
    end

    def validate_profile!(value)
      raise Error, 'Unsupported or invalid Kairomone profile' unless value.is_a?(Hash) && value['schema_version'] == 1 && value['supply_profile'] == 'basic'
      raise Error, 'Unexpected profile fields' unless value.keys.sort == %w[created_at display_name dot_id host_l0_baseline schema_version supply_profile]
      Paths.id!(value['dot_id'])
      text!(value['display_name'], 'display_name', 256)
      Time.iso8601(value.fetch('created_at'))
      baseline = value['host_l0_baseline']
      raise Error, 'Invalid L0 hash baseline' unless baseline.is_a?(Hash) && (baseline.keys - L0_FILES).empty? && baseline.values.all? { |v| v.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(v) }
      true
    rescue KeyError, ArgumentError => e
      raise Error, "Invalid profile: #{e.message}"
    end

    def observe(title:, content:, id: nil)
      title = text!(title, 'title', 512)
      content = text!(content, 'content', MAX_CONTENT)
      Paths.id!(id) if id
      with_lock do
        ensure_writable!('L2')
        if id && observation_entries.any? { |entry| entry['id'] == id }
          entry = context_manager.get_context(L2_SESSION, id)
          raise Error, 'Observation ID already exists with different content; use a new ID' unless entry.description == title && entry.content == content.strip
          next { success: true, id: id, layer: 'L2', canonical: true, recorded_on_chain: false, preserved: true, created_at: entry.frontmatter['created_at'] }
        end
        raise Error, 'Observation limit reached; v0 does not delete existing observations' if observation_entries.length >= MAX_ENTRIES
        id ||= "obs_#{Time.now.utc.strftime('%Y%m%d_%H%M%S')}_#{SecureRandom.hex(5)}"
        now = Time.now.utc.iso8601
        raw = document(id, title, content, 'L2', now)
        result = context_manager.save_context(L2_SESSION, id, raw)
        raise Error, result[:error] unless result[:success]
        persisted = Paths.read(root, "context/#{L2_SESSION}/#{id}/#{id}.md")
        raise Error, 'Observation write could not be verified' unless persisted == raw.b
        { success: true, id: id, layer: 'L2', canonical: true, recorded_on_chain: false, created_at: now }
      end
    end

    # Create-only. Existing knowledge is never overwritten, even with a reused
    # ID. An identical retry is checked against disk AND the canonical ledger.
    def create_knowledge(id:, title:, content:)
      Paths.id!(id)
      title = text!(title, 'title', 512)
      content = text!(content, 'content', MAX_CONTENT)
      with_lock do
        ensure_writable!('L1')
        existing = knowledge_entries.find { |entry| entry['id'] == id }
        if existing
          item = read_knowledge(id: id)
          raise Error, 'Knowledge ID already exists with different content; use a new ID' unless item[:title] == title && item[:content] == content.strip
          next { success: item[:recorded], id: id, layer: 'L1', canonical: true,
                 data_written: true, recorded_on_chain: item[:recorded], preserved: true,
                 pending: !item[:recorded], error: (item[:recorded] ? nil : 'Existing content has no matching verified ledger record') }.compact
        end
        raise Error, 'Knowledge limit reached; use a separate explicit archival workflow' if knowledge_entries.length >= MAX_ENTRIES
        before = chain
        raise Error, "Cannot write knowledge: dedicated ledger is #{before.load_state}" unless %i[absent readable].include?(before.load_state)
        BodyHistory.close!(before, -> { chain })
        raw = document(id, title, content, 'L1', Time.now.utc.iso8601)
        result = knowledge_provider.create(id, raw, reason: 'Explicit Kairomone basic knowledge creation')
        # KnowledgeProvider deliberately rescues recording errors. Never infer
        # ledger success from its success flag: read the disk and chain again.
        written = File.exist?(Paths.checked(root, "knowledge/#{id}/#{id}.md"))
        persisted = written && Paths.read(root, "knowledge/#{id}/#{id}.md") == raw.b
        verified = persisted && recorded?(id, Digest::SHA256.hexdigest(raw), chain)
        { success: !!verified, id: id, layer: 'L1', canonical: !!persisted,
          data_written: !!persisted, recorded_on_chain: !!verified, pending: persisted && !verified,
          error: (verified ? nil : result[:error] || 'Content may be present, but its canonical ledger record could not be verified; inspect status before retrying') }.compact
      end
    end

    def read_knowledge(id:)
      Paths.id!(id)
      ensure_initialized!
      path = "knowledge/#{id}/#{id}.md"
      raw = Paths.read(root, path)
      entry = knowledge_provider.get(id)
      raise Error, 'Knowledge could not be parsed' unless entry && entry.name == id && entry.layer == 'L1'
      hash = Digest::SHA256.hexdigest(raw)
      { success: true, id: id, title: entry.description, content: entry.content, layer: 'L1',
        canonical: true, hash: hash, recorded: recorded?(id, hash, chain) }
    end

    def list_knowledge
      ensure_initialized!
      { success: true, items: knowledge_entries, scope: 'dedicated Kairomone canonical L1 store' }
    end

    def autonomy
      Autonomy.new(instance: self)
    end

    def status(render_html: false)
      result = { schema_version: 1, product: 'Kairomone', version: VERSION,
                 generated_at: Time.now.utc.iso8601, initialized: false, profile: nil,
                 storage: { scope: 'dedicated owned canonical KairosChain instance', data_root: root, restored_read_only: @restored },
                 knowledge: { count: 0, items: [], available: false },
                 observations: { count: 0, recent: [], available: false },
                 integrity: { state: 'absent', valid: false, block_count: 0, latest_hash: nil, pending_count: 0, details: [] },
                 backup: { scope: BACKUP_SCOPE, excluded: BACKUP_EXCLUDED },
                 instructions: { refresh: 'kairomone_status(render_html: true)', cli: 'ruby <installed-skillset>/scripts/kairomone.rb status --html' } }
      return result unless File.exist?(Paths.checked(root, 'profile.json'))
      result[:profile] = profile
      result[:initialized] = true
      ensure_store_dirs!
      ledger = chain
      knowledge = knowledge_entries(ledger)
      observations = observation_entries
      missing_ids = ledger_knowledge_ids(ledger) - knowledge.map { |entry| entry['id'] }
      pending = knowledge.count { |entry| !entry['recorded'] } + missing_ids.length
      result[:knowledge] = { count: knowledge.length, items: knowledge, available: true }
      result[:observations] = { count: observations.length, recent: observations.last(10).reverse, available: true }
      details = ['L1 and L2 are read through dedicated canonical providers. Host knowledge_get does not search this instance.',
                 'The chain check is local consistency, not independent authenticity. L2 observations are not chain-recorded.']
      details << 'L1/ledger correspondence is incomplete: content is missing or has no matching current canonical ledger hash.' if pending.positive?
      l0 = l0_fingerprints
      begin
        effective = effective_l0_baseline(ledger)
        expected, baseline_source = effective[:baseline], effective[:source]
        # 'unchanged' is exactly what growth commit accepts (same files, same
        # hashes); 'changed' is what an owner ruling can fix; 'unavailable' is
        # what it cannot (no host L0 present, or no derivable baseline).
        l0_state = l0.empty? ? 'unavailable' : (l0 == expected ? 'unchanged' : 'changed')
      rescue Error => e
        expected, baseline_source, l0_state = nil, nil, 'unavailable'
        details << e.message
      end
      details << "Host L0 fingerprint comparison: #{l0_state}. Scope: skills/kairos.rb and skills/kairos.md only; no L0 contents are copied or modified."
      if l0_state == 'changed'
        details << 'Growth is refused until the owner accepts the current host L0 in their own terminal, in the project folder: ' \
                   'ruby .kairos/skillsets/kairomone/scripts/kairomone.rb l0 rebaseline --reason "WHY". An assistant never runs it.'
      end
      result[:integrity] = { state: ledger.load_state.to_s, valid: ledger.valid? && pending.zero?,
                             block_count: ledger.chain.length, latest_hash: ledger.latest_block&.hash,
                             pending_count: pending, details: details,
                             host_l0: { state: l0_state, scope: L0_FILES, baseline: expected, current: l0, baseline_source: baseline_source } }
      result[:autonomy] = autonomy.status
      result[:progression] = progression_status
      result[:profession] = profession_status(progression: result[:progression])
      result[:companion] = companion_status[:companion]
      result[:chat_memory] = { count: verified_chat_entries.length, pending_count: companion_state['memories'].values.count { |m| m['state'] == 'reserved' }, xp_eligible: false }
      result[:html_path] = render_status(result) if render_html
      result
    rescue StandardError => e
      raise unless defined?(result) && result
      result[:integrity] = { state: 'unreadable', valid: false, block_count: 0, latest_hash: nil,
                             pending_count: 0, details: ["Status could not be fully verified: #{e.message}"] }
      result[:error] = e.message
      result
    end

    def knowledge_entries(ledger = chain)
      entries = entry_ids('knowledge')
      entries.map do |id|
        raw = Paths.read(root, "knowledge/#{id}/#{id}.md")
        entry = knowledge_provider.get(id)
        raise Error, "Malformed L1 entry: #{id}" unless entry && entry.name == id && entry.layer == 'L1'
        hash = Digest::SHA256.hexdigest(raw)
        { 'id' => id, 'title' => entry.description, 'hash' => hash, 'recorded' => recorded?(id, hash, ledger) }
      end
    end

    def observation_entries
      entries = entry_ids("context/#{L2_SESSION}", optional: true)
      entries.map do |id|
        Paths.read(root, "context/#{L2_SESSION}/#{id}/#{id}.md")
        entry = context_manager.get_context(L2_SESSION, id)
        raise Error, "Malformed L2 entry: #{id}" unless entry && entry.name == id && entry.layer == 'L2'
        { 'id' => id, 'title' => entry.description, 'created_at' => entry.frontmatter['created_at'] }
      end
    end

    def chain
      KairosMcp::KairosChain::Chain.new(storage_backend: backend)
    end

    def backend
      @backend_override || begin
        ensure_store_dirs!
        %w[storage/blockchain.json storage/blockchain.json.lock storage/action_log.jsonl].each do |relative|
          Paths.regular_file!(Paths.checked(root, relative), optional: true, limit: 16 * 1024 * 1024)
        end
        KairosMcp::Storage::FileBackend.new(storage_dir: File.join(root, 'storage'),
          blockchain_file: File.join(root, 'storage/blockchain.json'), action_log_file: File.join(root, 'storage/action_log.jsonl'))
      end
    end

    def knowledge_provider
      ensure_store_dirs!
      OwnedKnowledgeProvider.new(File.join(root, 'knowledge'), vector_search_enabled: false,
        include_skillset_knowledge: false, storage_backend: backend)
    end

    def context_manager
      ensure_store_dirs!
      KairosMcp::ContextManager.new(File.join(root, 'context'))
    end

    private

    def text!(value, field, max)
      raise Error, "#{field} must be nonempty valid UTF-8 text (at most #{max} bytes)" unless value.is_a?(String) && value.encoding != Encoding::ASCII_8BIT && value.valid_encoding? && value.bytesize <= max && !value.strip.empty? && value.encode('UTF-8').valid_encoding?
      value.encode('UTF-8')
    rescue EncodingError
      raise Error, "#{field} must be valid UTF-8"
    end

    def document(id, title, content, layer, now)
      KairosMcp::AnthropicSkillParser.generate_content({ 'name' => id, 'description' => title,
        'version' => '1.0.0', 'layer' => layer, 'tags' => ['kairomone', 'basic'], 'created_at' => now }, content)
    end

    def ensure_initialized!
      profile
      ensure_store_dirs!
    end

    def ensure_writable!(layer)
      ensure_initialized!
      raise Error, 'Restored targets are read-only; activation is a separate operator decision' if @restored
      raise Error, "Host governance disables or locks #{layer}" unless KairosMcp::SkillsConfig.layer_enabled?(layer) && KairosMcp::SkillsConfig.layer_mutable?(layer)
    end

    def ensure_store_dirs!
      %w[knowledge context storage].each do |relative|
        path = Paths.checked(root, relative)
        raise Error, "Missing canonical directory: #{relative}" unless File.directory?(path)
      end
    end

    def entry_ids(relative, optional: false)
      path = Paths.checked(root, relative)
      return [] if optional && !File.exist?(path)
      ids = Dir.children(path).sort
      raise Error, 'Entry count exceeds basic limit' if ids.length > MAX_ENTRIES
      ids.each do |id|
        Paths.id!(id)
        dir = Paths.checked(root, "#{relative}/#{id}")
        raise Error, "Unexpected entry shape: #{id}" unless File.directory?(dir) && Dir.children(dir) == ["#{id}.md"]
      end
      ids
    end

    def ledger_knowledge_ids(ledger)
      return [] unless ledger.valid?
      ledger.chain.flat_map(&:data).filter_map do |data|
        event = JSON.parse(data) if data.is_a?(String)
        event['knowledge_id'] if event.is_a?(Hash) && event['type'] == 'knowledge_update' && event['layer'] == 'L1'
      rescue JSON::ParserError
        nil
      end.uniq
    end

    def recorded?(id, hash, ledger)
      return false unless ledger.valid?
      events = ledger.chain.flat_map(&:data).filter_map do |data|
        JSON.parse(data) if data.is_a?(String)
      rescue JSON::ParserError
        nil
      end
      latest = events.reverse.find { |event| event.is_a?(Hash) && event['type'] == 'knowledge_update' && event['layer'] == 'L1' && event['knowledge_id'] == id }
      latest && latest['next_hash'] == hash ? true : false
    end

    def with_lock(create: false)
      unless File.directory?(root)
        raise Error, 'Run kairomone_init first' unless create
        FileUtils.mkdir_p(root, mode: 0o700)
      end
      lock = Paths.checked(root, '.lock')
      Paths.regular_file!(lock, optional: true, limit: 1_048_576)
      File.open(lock, File::RDWR | File::CREAT, 0o600) do |io|
        io.flock(File::LOCK_EX)
        yield
      end
    end

    def l0_fingerprints
      L0_FILES.each_with_object({}) do |relative, hashes|
        path = Paths.checked(host_root, relative)
        hashes[relative] = Digest::SHA256.hexdigest(Paths.read(host_root, relative, limit: 4_194_304)) if File.file?(path)
      end
    end

    def render_status(snapshot)
      raise Error, 'Restored targets are read-only; inspect JSON status instead' if @restored
      template = File.read(File.join(PACKAGE_ROOT, 'assets/status.html'), encoding: 'UTF-8')
      token = '__KAIROMONE_STATUS_JSON__'
      raise Error, 'Status template must contain exactly one JSON token' unless template.scan(token).length == 1
      json = JSON.generate(snapshot).gsub(/[<>&\u2028\u2029]/) { |char| format('\\u%04x', char.ord) }
      with_lock { Paths.write(root, 'exports/status.html', template.sub(token) { json }, replace: true) }
    end
  end
end
