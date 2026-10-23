# frozen_string_literal: true

module Kairomone
  # No mutable XP counter: progress is derived from current canonical content.
  # IDs, titles, timestamps and retries cannot manufacture additional XP.
  module Progression
    LEVEL_CAP = 999
    XP_PER_LEVEL = 20
    L1_XP = 50
    L2_XP = 10
    PROFESSIONS = [
      { id: 'generalist', name: 'Generalist', unlock_level: 1, topics: [] },
      { id: 'researcher', name: 'Researcher', unlock_level: 5, topics: %w[research evidence verification] },
      { id: 'builder', name: 'Builder', unlock_level: 10, topics: %w[software design testing] },
      { id: 'strategist', name: 'Strategist', unlock_level: 20, topics: %w[planning decisions tradeoffs] },
      { id: 'guardian', name: 'Guardian', unlock_level: 30, topics: %w[safety reliability privacy] },
      { id: 'creator', name: 'Creator', unlock_level: 40, topics: %w[writing storytelling creativity] }
    ].map { |item| item[:topics].freeze; item.freeze }.freeze
    SHA = /\A[0-9a-f]{64}\z/

    def self.fingerprint(content)
      Digest::SHA256.hexdigest(content.to_s.gsub("\r\n", "\n").strip)
    end

    def self.calculate(l1_fingerprints:, l2_fingerprints:)
      l1 = l1_fingerprints.uniq
      l2 = l2_fingerprints.uniq - l1
      xp = l1.length * L1_XP + l2.length * L2_XP
      level = [1 + xp / XP_PER_LEVEL, LEVEL_CAP].min
      capped = level == LEVEL_CAP
      { level: level, level_cap: LEVEL_CAP, total_xp: xp,
        xp_into_level: capped ? 0 : xp % XP_PER_LEVEL,
        xp_for_next_level: capped ? nil : XP_PER_LEVEL,
        xp_to_next_level: capped ? 0 : XP_PER_LEVEL - xp % XP_PER_LEVEL,
        unique_l1: l1.length, unique_l2: l2.length,
        rules: { l1_xp: L1_XP, l2_xp: L2_XP, xp_per_level: XP_PER_LEVEL,
                 basis: 'Unique XP identities of present content; verified L1 supersedes identical L2. Inherited or received not-counted entries and new chat-summary content count nowhere. No rewards for retries, titles, IDs or timestamps.' } }
    end

    # One entry of a kairomone_xp record (design v0.6 M5).
    def self.valid_xp_entry?(entry)
      entry.is_a?(Hash) && %w[L1 L2].include?(entry['layer']) && Paths::ID.match?(entry['id'].to_s) &&
        SHA.match?(entry['identity'].to_s) && SHA.match?(entry['content_sha256'].to_s) &&
        [true, false].include?(entry['counted']) && entry['holds'].is_a?(Array) && entry['holds'].all? { |h| SHA.match?(h.to_s) }
    end
  end

  # XP identity (design v0.6 Inv 3, M5). Each entry has one XP identity, fixed
  # when it is first written and recorded on the ledger with the entry's
  # content hash; a record counts only while the present entry matches that
  # hash, and the latest matching record is the one in force. An entry with no
  # matching record takes its identity by the 0.6 rule, and the next write
  # records the result. XP is computed from sets, not from history.
  class Instance
    def progression_status(ledger = nil)
      ensure_initialized!
      ledger ||= chain
      basis = xp_basis(ledger)
      l1 = basis.select { |b| b['layer'] == 'L1' && b['recorded'] && b['counted'] }.map { |b| b['identity'] }
      l2 = basis.select { |b| b['layer'] == 'L2' && b['counted'] }.map { |b| b['identity'] }
      # An identity an inherited or received not-counted entry holds — its own
      # and those of the sources it keeps excluded — counts nowhere, for as
      # long as that entry is present; so does a chat summary's new content.
      excluded = basis.reject { |b| b['counted'] }.flat_map { |b| [b['identity'], *b['holds']] } | chat_xp_excluded_fingerprints
      Progression.calculate(l1_fingerprints: l1 - excluded, l2_fingerprints: l2 - excluded)
    end

    # Every present L1 and L2 entry with the identity in force for it:
    # [{ 'id', 'layer', 'identity', 'content_sha256', 'counted', 'holds',
    #    'recorded' (L1), 'source' => 'record' | '0.6 rule' }].
    def xp_basis(ledger = chain)
      records = identity_records(ledger)
      l1 = knowledge_entries(ledger)
      l2 = observation_entries
      legacy = nil
      rule06 = -> { legacy ||= legacy_identities(l1, l2) }
      out = l1.map { |e| basis_entry('L1', e['id'], e['hash'], records, rule06).merge('recorded' => e['recorded']) }
      out + l2.map { |e| basis_entry('L2', e['id'], e['hash'], records, rule06) }
    end

    private

    # Identity records by entry, in ledger order: kairomone_xp entries and the
    # two entries each kairomone_growth_completed intent names.
    def identity_records(ledger)
      out = Hash.new { |h, k| h[k] = [] }
      Records.each(ledger) do |record, _index|
        case record['type']
        when 'kairomone_xp'
          Array(record['entries']).each do |entry|
            out[[entry['layer'], entry['id']]] << entry if Progression.valid_xp_entry?(entry)
          end
        when 'kairomone_growth_completed'
          next unless growth_intent?(record)

          out[['L1', record['l1_id']]] << { 'identity' => record['l1_identity'], 'content_sha256' => record['l1_sha256'], 'counted' => true, 'holds' => [] }
          out[['L2', record['l2_id']]] << { 'identity' => record['l2_identity'], 'content_sha256' => record['l2_sha256'], 'counted' => true, 'holds' => [] }
        end
      end
      out
    end

    def growth_intent?(record)
      %w[l1_id l2_id].all? { |k| Paths::ID.match?(record[k].to_s) } &&
        %w[l1_identity l2_identity l1_sha256 l2_sha256 evidence_sha256].all? { |k| Progression::SHA.match?(record[k].to_s) }
    end

    def basis_entry(layer, id, hash, records, rule06)
      found = records[[layer, id]].reverse.find { |r| r['content_sha256'] == hash }
      if found
        { 'id' => id, 'layer' => layer, 'identity' => found['identity'], 'content_sha256' => hash,
          'counted' => found['counted'], 'holds' => found['holds'], 'source' => 'record' }
      else
        { 'id' => id, 'layer' => layer, 'identity' => rule06.call.fetch([layer, id]), 'content_sha256' => hash,
          'counted' => true, 'holds' => [], 'source' => '0.6 rule' }
      end
    end

    # The 0.6 rule: the fingerprint of the entry's content, except that a
    # growth pair the 0.6 growth state lists as completed takes its
    # normalised content (0.6 progression_content), as 0.6 counted it.
    def legacy_identities(l1, l2)
      l1_content = l1.to_h { |e| [e['id'], knowledge_provider.get(e['id']).content] }
      l2_content = l2.to_h { |e| [e['id'], context_manager.get_context(L2_SESSION, e['id']).content] }
      out = {}
      l1_content.each { |id, body| out[['L1', id]] = Progression.fingerprint(body) }
      l2_content.each { |id, body| out[['L2', id]] = Progression.fingerprint(body) }
      recorded = l1.select { |e| e['recorded'] }.map { |e| e['id'] }
      (recorded & l2_content.keys).each do |id|
        normalized = autonomy.legacy_progression_content(id: id, l1_body: l1_content[id], l2_body: l2_content[id])
        next unless normalized

        out[['L1', id]] = Progression.fingerprint(normalized[:l1])
        out[['L2', id]] = Progression.fingerprint(normalized[:l2])
      end
      out
    end

    def xp_entry(layer, id, identity, raw, counted: true, holds: [])
      { 'id' => id, 'layer' => layer, 'identity' => identity, 'content_sha256' => Digest::SHA256.hexdigest(raw),
        'counted' => counted, 'holds' => holds }
    end

    # Appends one kairomone_xp record: the entries about to be written, after
    # the present entries that have no matching record yet (their 0.6-rule
    # identities, so the migration happens at the next write). Called with the
    # instance lock held, once the write's own checks have passed and
    # immediately before the write. `also` names entries written under another
    # identity record in the same block (a growth intent), which are not
    # backfilled.
    def record_identities!(entries, ledger = chain, also: [], with: [])
      writing = (entries.map { |e| [e['layer'], e['id']] } + also)
      backfill = xp_basis(ledger).select { |b| b['source'] == '0.6 rule' && !writing.include?([b['layer'], b['id']]) }
                                 .map { |b| b.slice('id', 'layer', 'identity', 'content_sha256', 'counted', 'holds') }
      all = backfill + entries
      raise Error, 'Invalid XP identity record' unless all.all? { |e| Progression.valid_xp_entry?(e) }

      records = all.empty? ? [] : [{ 'type' => 'kairomone_xp', 'entries' => all }]
      Records.append!(ledger, records + with, -> { chain })
    end
  end

  class Instance
    def profession_status(progression: nil)
      ensure_initialized!
      selection = profession_selection
      level = (progression || progression_status)[:level]
      catalog = Progression::PROFESSIONS.map { |item| item.merge(unlocked: level >= item[:unlock_level]) }
      selected = catalog.find { |item| item[:id] == selection['selected_id'] }
      active = selected && selected[:unlocked] ? selected : catalog.first
      { selected_id: selection['selected_id'], effective_id: active[:id], name: active[:name],
        selection_required: selection['selected_id'].nil?, selected_unlocked: !!(selected && selected[:unlocked]),
        catalog: catalog, learning_bias: { topics: active[:topics], max_topic_fraction: 0.5 },
        note: 'A profession biases bounded learning topics only; it never changes permissions, limits or L0.' }
    end

    def select_profession(id:)
      raise Error, 'Unknown profession ID' unless Progression::PROFESSIONS.any? { |item| item[:id] == id }
      with_lock do
        ensure_initialized!
        raise Error, 'Restored targets are read-only' if @restored
        status = profession_status
        choice = status[:catalog].find { |item| item[:id] == id }
        raise Error, "Profession unlocks at level #{choice[:unlock_level]}" unless choice[:unlocked]
        previous = profession_selection
        preserved = previous['selected_id'] == id
        unless preserved
          value = { 'schema_version' => 1, 'selected_id' => id, 'selected_at' => Time.now.utc.iso8601 }
          Paths.write(root, 'profession.json', JSON.pretty_generate(value) + "\n", replace: true)
        end
        { success: true, preserved: preserved, profession: profession_status, kairomone: address }
      end
    end

    def validate_profession!(value)
      valid = value.is_a?(Hash) && value.keys.sort == %w[schema_version selected_at selected_id] &&
        value['schema_version'] == 1 && Progression::PROFESSIONS.any? { |item| item[:id] == value['selected_id'] }
      raise Error, 'Invalid profession selection' unless valid
      Time.iso8601(value.fetch('selected_at'))
      true
    rescue ArgumentError, TypeError
      raise Error, 'Invalid profession selection timestamp'
    end

    private

    def profession_selection
      path = Paths.checked(root, 'profession.json')
      return { 'selected_id' => nil } unless File.exist?(path)
      value = JSON.parse(Paths.read(root, 'profession.json', limit: 4096))
      validate_profession!(value)
      value
    rescue JSON::ParserError => e
      raise Error, "Invalid profession selection: #{e.message}"
    end
  end
end
