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
                 basis: 'Unique current content; verified L1 supersedes identical L2. No rewards for retries, titles, IDs or timestamps.' } }
    end
  end

  class Instance
    def progression_status
      ensure_initialized!
      l1_content = knowledge_entries.select { |entry| entry['recorded'] }.to_h do |entry|
        [entry['id'], knowledge_provider.get(entry['id']).content]
      end
      l2_content = observation_entries.to_h do |entry|
        [entry['id'], context_manager.get_context(L2_SESSION, entry['id']).content]
      end
      # Only a completed, locally validated growth record may remove protocol
      # metadata from its XP identity. Arbitrary JSON/frontmatter gets no bypass.
      (l1_content.keys & l2_content.keys).each do |id|
        normalized = autonomy.progression_content(id: id, l1_body: l1_content[id], l2_body: l2_content[id])
        next unless normalized
        l1_content[id] = normalized[:l1]
        l2_content[id] = normalized[:l2]
      end
      l1 = l1_content.values.map { |body| Progression.fingerprint(body) }
      l2 = l2_content.values.map { |body| Progression.fingerprint(body) }
      excluded = chat_xp_excluded_fingerprints
      Progression.calculate(l1_fingerprints: l1 - excluded, l2_fingerprints: l2 - excluded)
    end

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
        note: 'A profession biases bounded learning topics only; it never changes permissions, budgets or L0.' }
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
        { success: true, preserved: preserved, profession: profession_status }
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
