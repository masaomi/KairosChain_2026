# frozen_string_literal: true

module Kairomone
  # What an individual learned itself (design 0.9 "own growth entry", Inv 5,
  # Inv 10, N2, N3, N4, N6). This is the one definition; skills, lifetime
  # cycles, learned subjects, composition material and the snapshot all read
  # it from here:
  #
  #   an own growth entry is an L1 or L2 entry this individual's own cycle
  #   committed, whose present content matches the hash that cycle recorded
  #   on this individual's ledger.
  #
  # A cycle of 0.8 or later is its kairomone_growth_completed record, which
  # names both entries and their hashes. A cycle of 0.6 is a completed request
  # of the 0.6 growth state (the identification restore_summary made in 0.8);
  # its entries are its own while its L1 matches the knowledge record its
  # write left on the ledger and both entries still rebuild from the evidence
  # hash the 0.6 state recorded (the 0.6 progression_content rule). Received,
  # inherited and owner-written entries never are: an import or a fusion
  # records identities, never a cycle, and an ID alone proves nothing. A cycle
  # counts only while its L1 is an own growth entry: an intent whose entries
  # never landed, a 0.6 claim that failed or expired, and the 0.6 claim
  # counter count nothing. What cannot be read is reported as unknown.
  class Instance
    LEARNED_TOP = 12

    # => { cycles: [{ 'generation' => '0.6' | '0.8', 'request_id', 'l1_id',
    #                 'l2_id', 'l1_sha256', 'l2_own', 'subjects',
    #                 'methods_applied' }] (in the order they were learned),
    #      unknown: nil or why some cycles could not be established }
    def own_growth(ledger = chain)
      ensure_initialized!
      unless %i[readable absent].include?(ledger.load_state)
        return { cycles: [], unknown: "the ledger is #{ledger.load_state}, so no cycle can be established" }
      end

      l1 = knowledge_entries(ledger).to_h { |e| [e['id'], e] }
      l2 = observation_entries.to_h { |e| [e['id'], e] }
      legacy, legacy_fault = autonomy.legacy_growth_state
      cycles = legacy ? legacy_own_cycles(legacy, l1, l2) : []
      seen = Set.new(cycles.map { |c| c['l1_id'] })
      Records.of_type(ledger, 'kairomone_growth_completed').each do |record|
        next unless record['request_id'].is_a?(String) && growth_intent?(record) && !seen.include?(record['l1_id'])

        entry = l1[record['l1_id']]
        next unless entry && entry['recorded'] && entry['hash'] == record['l1_sha256']

        seen << record['l1_id']
        cycles << { 'generation' => '0.8', 'request_id' => record['request_id'], 'l1_id' => record['l1_id'], 'l2_id' => record['l2_id'],
                    'l1_sha256' => record['l1_sha256'], 'l2_own' => l2.dig(record['l2_id'], 'hash') == record['l2_sha256'],
                    'subjects' => string_list(record['subjects']), 'methods_applied' => string_list(record['methods_applied']) }
      end
      unknown = legacy_fault && "the 0.6 growth state cannot be read (#{legacy_fault}), so its cycles are not established"
      { cycles: cycles, unknown: unknown }
    end

    # [[layer, id]] of every own growth entry.
    def own_growth_entries(growth = own_growth)
      Set.new(growth[:cycles].flat_map { |c| [['L1', c['l1_id']]] + (c['l2_own'] ? [['L2', c['l2_id']]] : []) })
    end

    # The cycle whose own L1 entry this is, with this content hash, or nil.
    def own_growth_cycle(entry_id, sha256, growth = own_growth)
      growth[:cycles].find { |c| c['l1_id'] == entry_id && c['l1_sha256'] == sha256 }
    end

    # The number of completed cycles by the one test above, or nil with the
    # reason when it cannot be established.
    def lifetime_cycles(growth = own_growth)
      { 'lifetime_cycles' => growth[:unknown] ? nil : growth[:cycles].length,
        'lifetime_unknown' => growth[:unknown] && { 'reason' => growth[:unknown], 'at_least' => growth[:cycles].length } }
    end

    # The subjects completed cycles declared, counted over own growth entries:
    # the top LEARNED_TOP the vocabulary holds now, each with its count.
    def learned_subjects(growth = own_growth)
      counts = Hash.new(0)
      growth[:cycles].each { |c| c['subjects'].filter_map { |id| Vocabulary.subject_id(id) }.uniq.each { |id| counts[id] += 1 } }
      counts.sort_by { |id, n| [-n, id] }.first(LEARNED_TOP).map { |id, n| Vocabulary.subject_name(id).merge('count' => n) }
    end

    # The evidence a cycle's own L2 entry holds (never its request), or nil.
    def own_growth_evidence(cycle)
      return nil unless cycle['l2_own']

      entry = context_manager.get_context(L2_SESSION, cycle['l2_id']) or return nil
      envelope = JSON.parse(entry.content)
      evidence = envelope.is_a?(Hash) ? envelope['evidence'] : nil
      evidence.is_a?(Hash) ? evidence : nil
    rescue JSON::ParserError
      nil
    end

    private

    def string_list(value) = value.is_a?(Array) ? value.select { |v| v.is_a?(String) } : []

    # The 0.6 growth state's completed requests whose entries are this
    # individual's own, oldest first.
    def legacy_own_cycles(state, l1, l2)
      requests = state['requests'].select { |_id, r| r.is_a?(Hash) && r['state'] == 'completed' }
      requests.sort_by { |id, r| [r.dig('result', 'completed_at').to_s, id.to_s] }.filter_map do |request_id, r|
        id = r.dig('result', 'l1_id')
        next unless id.is_a?(String) && id == "growth_#{request_id}" && r.dig('result', 'l2_id') == id

        entry = l1[id]
        next unless entry && entry['recorded'] && l2[id]

        body1 = knowledge_provider.get(id)&.content
        body2 = context_manager.get_context(L2_SESSION, id)&.content
        next unless body1 && body2 && autonomy.legacy_progression_content(id: id, l1_body: body1, l2_body: body2)

        { 'generation' => '0.6', 'request_id' => request_id, 'l1_id' => id, 'l2_id' => id, 'l1_sha256' => entry['hash'],
          'l2_own' => true, 'subjects' => [], 'methods_applied' => [] }
      end
    end
  end
end
