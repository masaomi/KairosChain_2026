# frozen_string_literal: true

module Kairomone
  # Portable, single-owner settings and canonical chat summaries. No model,
  # scheduler, transport credentials, raw conversation log or L0 writes.
  class Instance
    COMPANION_PATH = 'companion/state.json'
    MEMORY_GATE_PATH = 'companion/memory-gate.json'
    CHAT_SESSION = 'kairomone_chat'
    DIRECTION_PRESETS = %w[balanced profession research building creativity evidence practical reflective custom].freeze

    def companion_status
      ensure_initialized!
      state = companion_state
      { success: true, companion: companion_public(state) }
    end

    def configure_companion(request_id:, expected_revision:, display_name: nil, memory_enabled: nil, direction: nil, personality: nil)
      Paths.id!(request_id)
      with_lock do
        ensure_writable!('L2')
        state = companion_state
        changes = {}
        changes['display_name'] = companion_text!(display_name, 'display_name', 256) unless display_name.nil?
        unless memory_enabled.nil?
          raise Error, 'memory_enabled must be boolean' unless [true, false].include?(memory_enabled)
          changes['memory_enabled'] = memory_enabled
        end
        changes['direction'] = validate_direction!(direction) unless direction.nil?
        changes['personality'] = companion_text!(personality, 'personality', 2000, empty: true) unless personality.nil?
        raise Error, 'No companion settings supplied' if changes.empty?
        request_hash = Digest::SHA256.hexdigest(JSON.generate([expected_revision, changes.sort.to_h]))
        prior = state['history'].find { |v| v['request_id'] == request_id }
        if prior
          raise Error, 'Request ID already used with different settings' unless prior['request_hash'] == request_hash
          next { success: true, preserved: true, applied_revision: prior['revision'], companion: companion_public(state) }
        end
        raise Error, 'Stale companion revision' unless expected_revision.is_a?(Integer) && expected_revision == state['revision']
        raise Error, 'Companion settings history is full' if state['history'].length >= 200
        state['revision'] += 1
        state['settings'] = state['settings'].merge(changes)
        state['history'] << { 'revision' => state['revision'], 'request_id' => request_id, 'request_hash' => request_hash,
                              'at' => Time.now.utc.iso8601, 'settings' => state['settings'].dup }
        save_companion(state)
        save_memory_gate(false) if memory_enabled == true
        { success: true, preserved: false, applied_revision: state['revision'], companion: companion_public(state) }
      end
    end

    # Capacity-independent fail-closed OFF switch. Does not erase saved memory.
    def revoke_companion_memory
      with_lock do
        ensure_initialized!
        raise Error, 'Restored targets are read-only' if @restored
        save_memory_gate(true)
        { success: true, revoked: true, companion: companion_public(companion_state) }
      end
    end

    # Summary only; explicit current global AND per-conversation consent. The
    # adapter verifies message ownership and that this summary actually derives
    # from those messages. IDs/hashes are provenance, not factual verification.
    def remember_companion(request_id:, conversation_id:, message_ids:, consent_revision:, summary:, memory_enabled: false)
      Paths.id!(request_id); Paths.id!(conversation_id)
      raise Error, 'message_ids must contain 1–40 distinct IDs' unless message_ids.is_a?(Array) && message_ids.length.between?(1, 40) && message_ids.uniq == message_ids
      message_ids.each { |id| Paths.id!(id) }
      content = companion_text!(summary, 'summary', 8192).gsub("\r\n", "\n")
      with_lock do
        ensure_writable!('L2')
        state = companion_state
        raise Error, 'Memory consent is off or stale' unless memory_enabled == true && state['settings']['memory_enabled'] && !memory_revoked? && consent_revision.is_a?(Integer) && consent_revision == state['revision']
        hash = Digest::SHA256.hexdigest(content)
        digest = Digest::SHA256.hexdigest(JSON.generate([conversation_id, message_ids, consent_revision, hash]))
        id = 'chat_' + Digest::SHA256.hexdigest(request_id)[0, 40]
        prior = state['memories'][request_id]
        raise Error, 'Request ID already used with different summary' if prior && prior['request_hash'] != digest
        raise Error, 'Cancelled summary requires a new request and current consent' if prior && prior['state'] == 'cancelled'
        unless prior
          raise Error, 'Chat memory limit reached' if state['memories'].length >= 200
          prior = { 'id' => id, 'request_hash' => digest, 'sha256' => hash, 'conversation_id' => conversation_id,
                    'message_ids' => message_ids, 'consent_revision' => consent_revision, 'at' => Time.now.utc.iso8601,
                    'state' => 'reserved', 'preexisting_content' => companion_legacy_content?(hash) }
          state['memories'][request_id] = prior
          # Reserve before canonical write. Crash recovery cannot turn a chat
          # summary into an ordinary XP-bearing observation.
          save_companion(state)
        end
        relative = "context/#{CHAT_SESSION}/#{id}/#{id}.md"
        preserved = File.exist?(Paths.checked(root, relative))
        if preserved
          entry = context_manager.get_context(CHAT_SESSION, id)
          raise Error, 'Existing chat summary does not match its receipt' unless entry && entry.content == content
        else
          raise Error, 'Completed chat summary is missing; recovery required' if prior['state'] == 'completed'
          raw = document(id, 'Conversation summary', content, 'L2', prior['at'])
          result = context_manager.save_context(CHAT_SESSION, id, raw)
          raise Error, 'Canonical chat summary write failed' unless result[:success]
        end
        entry = context_manager.get_context(CHAT_SESSION, id)
        raise Error, 'Chat summary readback mismatch' unless entry && Digest::SHA256.hexdigest(entry.content) == hash
        prior['state'] = 'completed'
        save_companion(state)
        { success: true, preserved: preserved, id: id, layer: 'L2', session: CHAT_SESSION, xp_eligible: false, sha256: hash, receipt: companion_receipt(request_id, prior) }
      end
    end

    # Reconcile a lost write acknowledgement without repeating the write or
    # requiring old consent to be re-enabled. Existing exact bytes are recorded;
    # an unwritten reservation is cancelled. No canonical data is deleted.
    def recover_companion_memory(request_id:)
      Paths.id!(request_id)
      with_lock do
        ensure_initialized!
        raise Error, 'Restored targets are read-only' if @restored
        state = companion_state
        receipt = state['memories'][request_id]
        raise Error, 'Unknown memory request' unless receipt
        if receipt['state'] != 'reserved'
          next { success: true, preserved: true, state: receipt['state'], id: receipt['id'], receipt: companion_receipt(request_id, receipt) }
        end
        path = Paths.checked(root, "context/#{CHAT_SESSION}/#{receipt['id']}/#{receipt['id']}.md")
        if File.exist?(path)
          entry = context_manager.get_context(CHAT_SESSION, receipt['id'])
          raise Error, 'Reserved memory bytes do not match; manual recovery required' unless entry && entry.name == receipt['id'] && entry.layer == 'L2' && Digest::SHA256.hexdigest(entry.content) == receipt['sha256']
          receipt['state'] = 'completed'
        else
          directory = Paths.checked(root, "context/#{CHAT_SESSION}/#{receipt['id']}")
          if File.exist?(directory)
            raise Error, 'Unexpected partial memory directory; manual recovery required' unless File.directory?(directory) && Dir.empty?(directory)
            Dir.rmdir(directory) # Only a verified empty, owned directory; never recursive.
          end
          receipt['state'] = 'cancelled'
        end
        save_companion(state)
        { success: true, preserved: false, state: receipt['state'], id: receipt['id'], canonical_write_performed: false, receipt: companion_receipt(request_id, receipt) }
      end
    end

    def companion_context(query:, limit: 8)
      query = companion_text!(query, 'query', 2000)
      raise Error, 'limit must be 1–12' unless limit.is_a?(Integer) && limit.between?(1, 12)
      with_lock do
        ensure_initialized!
        state = companion_state
        terms = query.downcase.scan(/[[:alnum:]]+/).uniq.first(30)
        refs = knowledge_entries.select { |e| e['recorded'] }.map do |e|
          entry = knowledge_provider.get(e['id'])
          companion_reference(entry, 'knowledge')
        end
        refs += observation_entries.map { |e| companion_reference(context_manager.get_context(L2_SESSION, e['id']), 'observation') }
        chat_entries = verified_chat_entries(state)
        refs += chat_entries.map { |e| companion_reference(e, 'chat_summary') }
        refs = refs.sort_by { |r| [-terms.count { |term| (r[:title] + ' ' + r[:content]).downcase.include?(term) }, r[:id]] }.first(limit)
        remaining = 24_000
        refs = refs.filter_map do |r|
          next if remaining <= 0
          text = r[:content].each_char.take(remaining).join
          # Bound UTF-8 bytes without splitting codepoints. Hash always refers
          # to full source; truncated=true explicitly identifies an excerpt.
          text = text.each_char.take(6000).join
          text = text[0...-1] while text.bytesize > [remaining, 6000].min
          remaining -= text.bytesize
          r.merge(content: text, truncated: text != r[:content])
        end
        { success: true, companion: companion_public(state), profession: profession_status, references: refs }
      end
    end

    private

    def companion_receipt(request_id, value)
      value.slice('conversation_id', 'message_ids', 'consent_revision', 'request_hash', 'sha256', 'id', 'state').merge('request_id' => request_id)
    end

    def memory_revoked?
      return false unless File.exist?(Paths.checked(root, MEMORY_GATE_PATH))
      value = JSON.parse(Paths.read(root, MEMORY_GATE_PATH, limit: 4096))
      raise Error, 'Invalid memory gate' unless value.is_a?(Hash) && value.keys.sort == %w[disabled schema_version] && value['schema_version'] == 1 && [true, false].include?(value['disabled'])
      value['disabled']
    rescue JSON::ParserError
      raise Error, 'Invalid memory gate JSON'
    end

    def save_memory_gate(disabled)
      Paths.write(root, MEMORY_GATE_PATH, JSON.generate('schema_version' => 1, 'disabled' => disabled) + "\n", replace: true)
    end

    def companion_legacy_content?(hash)
      knowledge_entries.any? { |e| e['recorded'] && Progression.fingerprint(knowledge_provider.get(e['id']).content) == hash } ||
        observation_entries.any? { |e| Progression.fingerprint(context_manager.get_context(L2_SESSION, e['id']).content) == hash }
    end

    def chat_xp_excluded_fingerprints
      state = companion_state
      verified_chat_entries(state)
      state['memories'].values.reject { |m| m['preexisting_content'] }.map { |m| m['sha256'] }.uniq
    end

    def companion_reference(entry, source)
      { id: entry.name, layer: entry.layer, version: entry.frontmatter['version'] || '1.0.0',
        sha256: Digest::SHA256.hexdigest(entry.content), title: entry.description.to_s,
        content: entry.content, source: source }
    end

    def companion_public(state)
      state['settings'].merge('memory_enabled' => state['settings']['memory_enabled'] && !memory_revoked?, 'memory_revoked' => memory_revoked?, 'dot_id' => profile['dot_id'], 'revision' => state['revision'],
        'history' => state['history'], 'memory_count' => state['memories'].count { |_k, v| v['state'] == 'completed' },
        'direction_applies' => 'next newly prepared cycle; existing claims keep their captured context')
    end

    def companion_text!(value, field, max, empty: false)
      return '' if empty && value == ''
      text = text!(value, field, max).strip
      # Conservative guard, not a promise of complete secret detection.
      raise Error, 'Potential credential detected; remove it before saving' if text.match?(/(?:\b(?:sk|ghp|github_pat)-?[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|\bBearer\s+\S{12,}|\b(?:password|api[_ -]?key|access[_ -]?token)\s*[:=]\s*\S+)/i)
      text
    end

    def validate_direction!(value)
      raise Error, 'direction must contain preset and text only' unless value.is_a?(Hash) && value.keys.sort == %w[preset text]
      raise Error, 'Unknown direction preset' unless DIRECTION_PRESETS.include?(value['preset'])
      { 'preset' => value['preset'], 'text' => companion_text!(value['text'], 'direction text', 1000, empty: true) }
    end

    def companion_state
      path = Paths.checked(root, COMPANION_PATH)
      return { 'schema_version' => 1, 'revision' => 0,
               'settings' => { 'display_name' => profile['display_name'], 'memory_enabled' => false,
                               'direction' => { 'preset' => 'balanced', 'text' => '' }, 'personality' => '' },
               'history' => [], 'memories' => {} } unless File.exist?(path)
      value = JSON.parse(Paths.read(root, COMPANION_PATH))
      validate_companion_state!(value)
      value
    rescue JSON::ParserError
      raise Error, 'Invalid companion state JSON'
    end

    def validate_companion_state!(value)
      raise Error, 'Invalid companion state' unless value.is_a?(Hash) && value.keys.sort == %w[history memories revision schema_version settings] && value['schema_version'] == 1 && value['revision'].is_a?(Integer) && value['revision'].between?(0, 200)
      settings = value['settings']
      raise Error, 'Invalid companion settings' unless settings.is_a?(Hash) && settings.keys.sort == %w[direction display_name memory_enabled personality] && [true, false].include?(settings['memory_enabled'])
      companion_text!(settings['display_name'], 'display_name', 256)
      companion_text!(settings['personality'], 'personality', 2000, empty: true)
      validate_direction!(settings['direction'])
      history = value['history']
      raise Error, 'Invalid companion history' unless history.is_a?(Array) && history.length == value['revision'] && history.map { |h| h['revision'] } == (1..value['revision']).to_a
      history.each do |h|
        raise Error, 'Invalid settings receipt' unless h.is_a?(Hash) && h.keys.sort == %w[at request_hash request_id revision settings] && h['request_hash'].to_s.match?(/\A[0-9a-f]{64}\z/)
        Paths.id!(h['request_id']); Time.iso8601(h['at'])
      end
      raise Error, 'Duplicate settings request' unless history.map { |h| h['request_id'] }.uniq.length == history.length
      raise Error, 'Settings history mismatch' unless history.empty? || history.last['settings'] == settings
      memories = value['memories']
      raise Error, 'Invalid memory receipts' unless memories.is_a?(Hash) && memories.length <= 200
      memories.each do |request_id, m|
        Paths.id!(request_id)
        raise Error, 'Invalid memory receipt' unless m.is_a?(Hash) && m.keys.sort == %w[at consent_revision conversation_id id message_ids preexisting_content request_hash sha256 state] && %w[reserved completed cancelled].include?(m['state']) && [true, false].include?(m['preexisting_content']) && m['id'] == 'chat_' + Digest::SHA256.hexdigest(request_id)[0, 40]
        %w[sha256 request_hash].each { |k| raise Error, 'Invalid memory digest' unless m[k].to_s.match?(/\A[0-9a-f]{64}\z/) }
        Paths.id!(m['conversation_id']); Time.iso8601(m['at'])
        raise Error, 'Invalid memory consent' unless m['consent_revision'].is_a?(Integer) && m['consent_revision'].between?(1, value['revision']) && history[m['consent_revision'] - 1]['settings']['memory_enabled'] == true
        raise Error, 'Invalid message references' unless m['message_ids'].is_a?(Array) && m['message_ids'].length.between?(1, 40) && m['message_ids'].uniq == m['message_ids']
        m['message_ids'].each { |id| Paths.id!(id) }
        expected = Digest::SHA256.hexdigest(JSON.generate([m['conversation_id'], m['message_ids'], m['consent_revision'], m['sha256']]))
        raise Error, 'Memory receipt digest mismatch' unless m['request_hash'] == expected
      end
      true
    rescue ArgumentError, TypeError, NoMethodError
      raise Error, 'Malformed companion state'
    end

    def verified_chat_entries(state = companion_state)
      ids = entry_ids("context/#{CHAT_SESSION}", optional: true)
      receipts = state['memories'].values.to_h { |m| [m['id'], m] }
      raise Error, 'Chat summary has no provenance receipt' unless (ids - receipts.keys).empty?
      raise Error, 'Completed chat summary is missing' unless (receipts.values.select { |m| m['state'] == 'completed' }.map { |m| m['id'] } - ids).empty?
      ids.filter_map do |id|
        entry = context_manager.get_context(CHAT_SESSION, id)
        m = receipts.fetch(id)
        raise Error, 'Cancelled summary unexpectedly exists' if m['state'] == 'cancelled'
        raise Error, 'Chat summary provenance mismatch' unless entry && entry.name == id && entry.layer == 'L2' && Digest::SHA256.hexdigest(entry.content) == m['sha256']
        entry if m['state'] == 'completed'
      end
    end

    def save_companion(value)
      validate_companion_state!(value)
      bytes = JSON.pretty_generate(value) + "\n"
      raise Error, 'Companion state exceeds 1 MiB; no changes saved' if bytes.bytesize > 1_048_576
      Paths.write(root, COMPANION_PATH, bytes, replace: true)
    end
  end
end
