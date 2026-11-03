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
  # of the 0.6 growth state whose entries are present (the identification
  # restore_summary made in 0.8). 0.6 put no per-cycle L1 hash and no L2 hash
  # on the ledger, so its entries are its own only while that cycle's
  # provenance is established: the L2 still holds the evidence whose hash the
  # 0.6 state recorded, the L1 still rebuilds from it — body and title (the
  # 0.6 progression_content rule) — and the L1 is what the ledger last
  # recorded. A later knowledge record alone establishes nothing: a replaced
  # L1 recorded again is not the cycle's. A 0.6 cycle whose entries are
  # present but whose provenance is not established is not own growth, and
  # the count of cycles is then unknown. Received, inherited and owner-written
  # entries never are: an import or a fusion records identities, never a
  # cycle, and an ID alone proves nothing. A cycle counts only while its L1 is
  # an own growth entry: an intent whose entries never landed, a 0.6 claim
  # that failed or expired, and the 0.6 claim counter count nothing. What
  # cannot be read or established is reported as unknown.
  class Instance
    LEARNED_TOP = 12

    # => { cycles: [{ 'generation' => '0.6' | '0.8', 'request_id', 'l1_id',
    #                 'l2_id', 'l1_sha256', 'l2_sha256', 'l2_own', 'subjects',
    #                 'methods_applied' }] (in the order they were learned),
    #      unknown: nil or why some cycles could not be established }
    def own_growth(ledger = chain)
      ensure_initialized!
      shared = @own_growth_shared
      key = shared && [ledger.load_state, ledger.latest_block&.hash]
      return shared[key] if key && shared.key?(key)

      growth = read_own_growth(ledger)
      shared[key] = growth if key
      growth
    end

    # One reading of own growth for the length of the block: a status or a
    # console payload asks for it in several places, and each reading opens
    # every L1 and L2 entry. Within the block a reading is kept per ledger
    # head; nothing is kept once the block ends, so the next call reads
    # afresh.
    def sharing_own_growth
      return yield if @own_growth_shared

      @own_growth_shared = {}
      begin
        yield
      ensure
        @own_growth_shared = nil
      end
    end

    def sharing_own_growth? = !@own_growth_shared.nil?

    # What own_growth returns, read now.
    def read_own_growth(ledger)
      unless %i[readable absent].include?(ledger.load_state)
        return { cycles: [], unknown: "the ledger is #{ledger.load_state}, so no cycle can be established" }
      end

      l1 = knowledge_entries(ledger).to_h { |e| [e['id'], e] }
      l2 = observation_entries.to_h { |e| [e['id'], e] }
      legacy, legacy_fault = autonomy.legacy_growth_state
      cycles, malformed, unestablished = legacy ? legacy_own_cycles(legacy, l1, l2) : [[], 0, 0]
      legacy_fault ||= "#{malformed} completed request(s) without a readable result" if malformed.positive?
      seen = Set.new(cycles.map { |c| c['l1_id'] })
      Records.of_type(ledger, 'kairomone_growth_completed').each do |record|
        next unless record['request_id'].is_a?(String) && growth_intent?(record) && !seen.include?(record['l1_id'])

        entry = l1[record['l1_id']]
        next unless entry && entry['recorded'] && entry['hash'] == record['l1_sha256']

        seen << record['l1_id']
        cycles << { 'generation' => '0.8', 'request_id' => record['request_id'], 'l1_id' => record['l1_id'], 'l2_id' => record['l2_id'],
                    'l1_sha256' => record['l1_sha256'], 'l2_sha256' => record['l2_sha256'],
                    'l2_own' => l2.dig(record['l2_id'], 'hash') == record['l2_sha256'],
                    'subjects' => string_list(record['subjects']), 'methods_applied' => string_list(record['methods_applied']) }
      end
      unknown = [legacy_fault && "the 0.6 growth state cannot be read (#{legacy_fault}), so its cycles are not established",
                 unestablished.positive? && "#{unestablished} completed 0.6 cycle(s) whose entries are present no longer rebuild from the " \
                                            'evidence that cycle recorded, so they are not established as its own'].select { |r| r }
      { cycles: cycles, unknown: unknown.empty? ? nil : unknown.join('; ') }
    end
    private :read_own_growth

    # [[layer, id]] of every own growth entry.
    def own_growth_entries(growth = own_growth)
      Set.new(growth[:cycles].flat_map { |c| [['L1', c['l1_id']]] + (c['l2_own'] ? [['L2', c['l2_id']]] : []) })
    end

    # The cycle whose own growth entry a source {entry_id, layer, sha256}
    # names, holding that hash now — its L1, or its L2 while that is its own
    # — or nil. A source without a layer (as 0.9 first wrote skills) names an L1.
    def own_growth_source(source, growth = own_growth)
      return nil unless source.is_a?(Hash)

      id, sha = source.values_at('entry_id', 'sha256')
      case source.fetch('layer', 'L1')
      when 'L1' then growth[:cycles].find { |c| c['l1_id'] == id && c['l1_sha256'] == sha }
      when 'L2' then growth[:cycles].find { |c| c['l2_own'] && c['l2_id'] == id && c['l2_sha256'] == sha }
      end
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

    # [the 0.6 growth state's completed requests whose entries are this
    # individual's own, oldest first; how many completed ones cannot be read;
    # how many have both entries present but no established provenance].
    def legacy_own_cycles(state, l1, l2)
      completed = state['requests'].select { |_id, r| r.is_a?(Hash) && r['state'] == 'completed' }
      requests = completed.select { |_id, r| r['result'].is_a?(Hash) }
      unestablished = 0
      cycles = requests.sort_by { |id, r| [r['result']['completed_at'].to_s, id.to_s] }.filter_map do |request_id, r|
        id = r['result']['l1_id']
        next unless id.is_a?(String) && id == "growth_#{request_id}" && r['result']['l2_id'] == id

        entry = l1[id]
        next unless entry && l2[id] # its knowledge is gone: nothing of it is here to count

        unless legacy_cycle_established?(id, entry)
          unestablished += 1
          next
        end

        { 'generation' => '0.6', 'request_id' => request_id, 'l1_id' => id, 'l2_id' => id, 'l1_sha256' => entry['hash'],
          'l2_sha256' => l2[id]['hash'], 'l2_own' => true, 'subjects' => [], 'methods_applied' => [] }
      end
      [cycles, completed.length - requests.length, unestablished]
    end

    # The 0.6 cycle's provenance: its L1 is what the ledger last recorded, and
    # both entries rebuild from the evidence whose hash the 0.6 state holds —
    # the L1's body by the 0.6 renderer and its title as the cycle wrote it.
    def legacy_cycle_established?(id, entry)
      return false unless entry['recorded']

      body1 = knowledge_provider.get(id)&.content
      body2 = context_manager.get_context(L2_SESSION, id)&.content
      return false unless body1 && body2 && autonomy.legacy_progression_content(id: id, l1_body: body1, l2_body: body2)

      title = JSON.parse(body2).dig('evidence', 'knowledge', 'title')
      title.is_a?(String) && entry['title'].to_s.strip == title.strip
    rescue JSON::ParserError, TypeError
      false
    end
  end
end
