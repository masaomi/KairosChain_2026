# frozen_string_literal: true

module Kairomone
  # The canonical provider performs creation and hash recording. Its optional
  # state-commit hook uses global host paths even with an injected backend;
  # suppress that hook for this explicitly isolated instance. No core patches,
  # host path resolver changes, or global configuration changes are made.
  class OwnedKnowledgeProvider < KairosMcp::KnowledgeProvider
    private

    def track_pending_change(**_args); end

    # A Kairomone keeps no core 3.94+ L1 body history (hosted-dot design K4):
    # its bodies would sit in files the backup does not carry, and this
    # create-only store would gain nothing from them. One an earlier Kairomone
    # let core activate is closed by Instance#create_knowledge on every core.
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

  # One individual: its own L1, L2, ledger and state under one directory. The
  # directory is the legacy slot (<data_dir>/kairomone, made before 0.8) or a
  # listing under <data_dir>/kairomones/. Which one an Instance serves is fixed
  # when it is built (Host#root_for); an Instance never reaches another
  # individual's files.
  class Instance
    MAX_CONTENT = 16_384
    MAX_ENTRIES = 1_000
    L2_SESSION = 'kairomone'
    L0_FILES = %w[skills/kairos.rb skills/kairos.md].freeze
    BACKUP_SCOPE = ['The Kairomone\'s profile versions, professions, drawings, proposals and host L0 baseline records', 'All owned canonical L1 knowledge and L2 observations, chat summaries and companion settings', 'Complete dedicated Kairomone ledger; locally verified on restore', 'Growth run history; live runs end on restore'].freeze
    BACKUP_EXCLUDED = ['Host KC knowledge, context, ledger and L0 file contents', 'External account/token stores, environment variables and unrelated host files (private user-authored L1/L2 text is included)', 'Installed SkillSet code, HTML exports, prior backups, lock and temporary files, the host archive key'].freeze
    STORE_DIRS = %w[knowledge context storage backups exports].freeze

    attr_reader :host_root

    # A legacy slot's identity is its schema-1 profile's dot_id.
    def self.legacy_identity(root)
      value = JSON.parse(Paths.read(root, 'profile.json', limit: 65_536))
      value.is_a?(Hash) && value['schema_version'] == 1 && Paths::ID.match?(value['dot_id'].to_s) ? value['dot_id'] : nil
    rescue StandardError
      nil
    end

    # kairomone: the listing ID to serve; without one, the host's only
    # individual (none yet: unbound until init). root: a directory under the
    # host (staging); restored_id: a 0.6 read-only recovery copy; bind: false
    # serves no individual yet (init and restore bind it).
    def initialize(host_root: KairosMcp.data_dir, kairomone: nil, restored_id: nil, backend: nil, root: nil, bind: true)
      expanded = File.expand_path(host_root)
      @host_root = File.exist?(expanded) ? File.realpath(expanded) : expanded
      package_path = File.expand_path('../..', __dir__)
      package = File.exist?(package_path) ? File.realpath(package_path) : package_path
      raise Error, 'Runtime data must be outside the installed SkillSet package' if @host_root == package || @host_root.start_with?(package + '/')

      @host = Host.new(host_root: @host_root)
      @root = if root
                raise Error, 'An individual lives under its host' unless root.start_with?(@host_root + '/')

                root
              elsif restored_id
                Paths.checked(@host_root, "kairomone-restored/#{Paths.id!(restored_id)}")
              elsif bind
                @host.root_for(kairomone)
              end
      @restored = !!restored_id
      @backend_override = backend
    end

    def host = @host

    def root
      @root or raise Error, 'Run kairomone_init first'
    end

    def bound? = !@root.nil?

    def legacy_slot? = bound? && @root == Paths.checked(host_root, Host::LEGACY)

    # The name the host lists this individual under (its directory name; the
    # identity for the legacy slot).
    def listing_id
      legacy_slot? ? identity : File.basename(root)
    end

    # kairomone_init through the registry (Host#init). The Instance serves the
    # individual init made or preserved.
    def init(dot_id:, display_name:)
      Paths.id!(dot_id)
      title = text!(display_name, 'display_name', 256)
      raise Error, 'Restored targets are read-only; activation is a separate operator decision' if @restored

      result = @host.init(dot_id: dot_id, display_name: title)
      @root = result.delete(:root)
      result.merge(kairomone: address)
    end

    # Fills a staged directory: the store's directories, the first profile
    # version, and the ledger records that open every 0.8 individual (Inv 1,
    # M5) — identity, baseline at entry, and the profile acceptance.
    def open_new!(identity:, origin:, listing_id:, name:, baseline: l0_fingerprints)
      Paths.id!(identity)
      Paths.id!(listing_id)
      STORE_DIRS.each { |dir| Paths.mkdir(root, dir) }
      with_lock { nil } # the instance lock file exists from birth, as 0.6 left it
      sha = write_piece('profile', Profile.initial(name: name, origin: origin))
      Records.append!(chain, [{ 'type' => 'kairomone_identity', 'identity' => identity, 'origin' => origin, 'listing_id' => listing_id },
                              { 'type' => 'kairomone_baseline', 'files' => baseline },
                              { 'type' => 'kairomone_profile', 'sha256' => sha, 'origin' => origin }], -> { chain })
    end

    # The individual's identity: its kairomone_identity record, or the
    # schema-1 profile's dot_id for an individual made before 0.8. Never changes.
    def identity(ledger = nil)
      legacy = legacy_profile
      return legacy['dot_id'] if legacy

      ledger ||= chain
      raise Error, "Identity unavailable: the ledger is #{ledger.load_state}" unless ledger.load_state == :readable

      record = Records.of_type(ledger, 'kairomone_identity').first
      raise Error, 'Not a Kairomone: no identity on its ledger' unless record && Paths::ID.match?(record['identity'].to_s)

      record['identity']
    end

    # The host L0 fingerprints recorded when the individual entered a host.
    def initial_baseline(ledger = nil)
      legacy = legacy_profile
      return legacy['host_l0_baseline'] if legacy

      ledger ||= chain
      record = Records.of_type(ledger, 'kairomone_baseline').first
      raise Error, 'L0 baseline unavailable: no baseline on the ledger' unless record && baseline_map?(record['files'], allow_empty: true)

      record['files']
    end

    def initialized?
      return false unless @root && File.directory?(@root)
      return true if File.exist?(Paths.checked(root, 'profile.json'))

      File.exist?(Paths.checked(root, 'storage/blockchain.json'))
    end

    # Who a write changed, stated in every write result (Inv 1, M2).
    def address
      { listing_id: listing_id, identity: identity }
    end

    # The schema-1 profile of an individual made before 0.8 (read only), or
    # the current 0.8 profile as a view. Without a current profile (its pieces
    # lost or not yet accepted) the individual is an egg under its listing ID.
    def profile
      legacy = legacy_profile
      current = current_profile_piece
      return legacy if legacy && current.nil?
      raise Error, 'Run kairomone_init first' unless initialized?

      piece = current ? current[:piece] : {}
      name = piece['name'] || legacy&.fetch('display_name') || listing_id
      { 'schema_version' => 2, 'identity' => identity, 'listing_id' => listing_id, 'name' => name,
        'dot_id' => identity, 'display_name' => name, 'sha256' => current&.fetch(:sha256), 'profile_present' => !current.nil? }
        .merge(piece.slice(*Profile::FIELDS - %w[name]))
    end

    def name
      profile['schema_version'] == 1 ? profile['display_name'] : profile['name']
    end

    def legacy_profile
      return nil unless @root && File.exist?(Paths.checked(root, 'profile.json'))

      value = JSON.parse(Paths.read(root, 'profile.json', limit: 65_536))
      validate_profile!(value)
      value
    rescue JSON::ParserError => e
      raise Error, "Invalid profile: #{e.message}"
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
          next { success: true, id: id, layer: 'L2', canonical: true, recorded_on_chain: false, preserved: true, created_at: entry.frontmatter['created_at'], kairomone: address }
        end
        raise Error, 'Observation limit reached; v0 does not delete existing observations' if observation_entries.length >= MAX_ENTRIES
        id ||= "obs_#{Time.now.utc.strftime('%Y%m%d_%H%M%S')}_#{SecureRandom.hex(5)}"
        now = Time.now.utc.iso8601
        raw = document(id, title, content, 'L2', now)
        record_identities!([xp_entry('L2', id, Progression.fingerprint(content), raw)])
        write_l2_raw!(id, raw)
        { success: true, id: id, layer: 'L2', canonical: true, recorded_on_chain: false, created_at: now, kairomone: address }
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
                 pending: !item[:recorded], error: (item[:recorded] ? nil : 'Existing content has no matching verified ledger record'),
                 kairomone: address }.compact
        end
        raise Error, 'Knowledge limit reached; use a separate explicit archival workflow' if knowledge_entries.length >= MAX_ENTRIES
        before = chain
        raise Error, "Cannot write knowledge: dedicated ledger is #{before.load_state}" unless %i[absent readable].include?(before.load_state)
        BodyHistory.close!(before, -> { chain })
        raw = document(id, title, content, 'L1', Time.now.utc.iso8601)
        record_identities!([xp_entry('L1', id, Progression.fingerprint(content), raw)])
        write_l1_raw(id, raw, 'Explicit Kairomone basic knowledge creation').merge(kairomone: address)
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
      { success: true, items: knowledge_entries, scope: 'dedicated Kairomone canonical L1 store', kairomone: address }
    end

    def autonomy
      Autonomy.new(instance: self)
    end

    def status(render_html: false)
      result = { schema_version: 1, product: 'Kairomone', version: VERSION,
                 generated_at: Time.now.utc.iso8601, initialized: false, profile: nil, kairomone: nil,
                 storage: { scope: 'dedicated owned canonical KairosChain instance', data_root: @root, restored_read_only: @restored },
                 knowledge: { count: 0, items: [], available: false },
                 observations: { count: 0, recent: [], available: false },
                 integrity: { state: 'absent', valid: false, block_count: 0, latest_hash: nil, pending_count: 0, details: [] },
                 backup: { scope: BACKUP_SCOPE, excluded: BACKUP_EXCLUDED },
                 instructions: { refresh: 'kairomone_status(render_html: true)', cli: 'ruby <installed-skillset>/scripts/kairomone.rb status --html' } }
      return result unless initialized?
      result[:initialized] = true
      ensure_store_dirs!
      ledger = chain
      result[:profile] = profile
      result[:kairomone] = { listing_id: listing_id, identity: identity(ledger), legacy_slot: legacy_slot? }
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
        # 'unchanged' is exactly what growth accepts (same files, same
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
                   "ruby .kairos/skillsets/kairomone/scripts/kairomone.rb l0 rebaseline#{legacy_slot? ? '' : " --kairomone #{listing_id}"} --reason \"WHY\". An assistant never runs it."
      end
      result[:integrity] = { state: ledger.load_state.to_s, valid: ledger.valid? && pending.zero?,
                             block_count: ledger.chain.length, latest_hash: ledger.latest_block&.hash,
                             pending_count: pending, details: details,
                             host_l0: { state: l0_state, scope: L0_FILES, baseline: expected, current: l0, baseline_source: baseline_source } }
      result[:growth] = autonomy.status
      result[:autonomy] = result[:growth]
      result[:progression] = progression_status(ledger)
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
        raw = Paths.read(root, "context/#{L2_SESSION}/#{id}/#{id}.md")
        entry = context_manager.get_context(L2_SESSION, id)
        raise Error, "Malformed L2 entry: #{id}" unless entry && entry.name == id && entry.layer == 'L2'
        { 'id' => id, 'title' => entry.description, 'created_at' => entry.frontmatter['created_at'], 'hash' => Digest::SHA256.hexdigest(raw) }
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
        AtomicLedgerBackend.new(storage_dir: File.join(root, 'storage'),
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

    # Room for one more L1 and one more L2 entry (a growth cycle writes both).
    def room_for_cycle?
      entry_ids('knowledge').length < MAX_ENTRIES && entry_ids("context/#{L2_SESSION}", optional: true).length < MAX_ENTRIES
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

    # Writes an L2 entry with these exact bytes and reads them back. The
    # caller holds the instance lock and has recorded the entry's identity.
    def write_l2_raw!(id, raw)
      result = context_manager.save_context(L2_SESSION, id, raw)
      raise Error, result[:error] unless result[:success]
      persisted = Paths.read(root, "context/#{L2_SESSION}/#{id}/#{id}.md")
      raise Error, 'Observation write could not be verified' unless persisted == raw.b
    end

    # Writes an L1 entry with these exact bytes through the canonical
    # provider. KnowledgeProvider deliberately rescues recording errors, so
    # success is read from the disk and the ledger again, never from its flag.
    def write_l1_raw(id, raw, reason)
      result = knowledge_provider.create(id, raw, reason: reason)
      written = File.exist?(Paths.checked(root, "knowledge/#{id}/#{id}.md"))
      persisted = written && Paths.read(root, "knowledge/#{id}/#{id}.md") == raw.b
      verified = persisted && recorded?(id, Digest::SHA256.hexdigest(raw), chain)
      { success: !!verified, id: id, layer: 'L1', canonical: !!persisted,
        data_written: !!persisted, recorded_on_chain: !!verified, pending: persisted && !verified,
        error: (verified ? nil : result[:error] || 'Content may be present, but its canonical ledger record could not be verified; inspect status before retrying') }.compact
    end

    # A content-addressed piece (profile version, profession, drawing): the
    # file is named by the sha256 of its bytes and never rewritten.
    def write_piece(kind, value)
      bytes = JSON.pretty_generate(value) + "\n"
      sha = Digest::SHA256.hexdigest(bytes)
      relative = "#{kind}/#{sha}.json"
      if File.exist?(Paths.checked(root, relative))
        raise Error, "#{relative} holds other bytes" unless Paths.read(root, relative) == bytes.b
      else
        Paths.write(root, relative, bytes)
      end
      sha
    end

    def ensure_initialized!
      raise Error, 'Run kairomone_init first' unless initialized?
      identity
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

    def with_lock
      raise Error, 'Run kairomone_init first' unless @root && File.directory?(@root)
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
