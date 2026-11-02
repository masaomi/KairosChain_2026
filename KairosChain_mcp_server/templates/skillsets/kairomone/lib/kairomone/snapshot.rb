# frozen_string_literal: true

module Kairomone
  # What the snapshot page carries (design 0.9 Inv 10, N6): what the
  # individual publicly is — name, accepted drawings, level, stage, profession
  # name and lineage names, counts — and, for each own growth entry
  # (Instance#own_growth), what that cycle learned: its L1 title, the
  # evidence's knowledge.content (not the rendered L1 body, which carries
  # retrieval references), its finding, the subjects its ledger record names
  # and its sources' URLs. Nothing else: never a cycle's request (its topic
  # included), any other entry, chat, the direction, the lean, skills, a
  # waiting proposal, a local path or anything secret. Every text is checked
  # as the page is assembled; one that fails is left out and counted in
  # withheld.
  module Snapshot
    SCHEMA = 'kairomone-snapshot-1'
    DRAWINGS_MAX = 30
    CYCLES_MAX = 100
    # The local-path markers the check refuses (file: in any case).
    LOCAL_PATHS = %w[/Users/ /home/ ~/].freeze

    module_function

    # A text the snapshot may carry: not a credential by the guard, and
    # naming no local path.
    def public_text?(value)
      value.is_a?(String) && value.valid_encoding? && !value.match?(ComposedText::CREDENTIAL) && !local_path?(value)
    end

    def local_path?(value) = LOCAL_PATHS.any? { |marker| value.include?(marker) } || value.match?(/file:/i)
  end

  class Instance
    # The snapshot's data, assembled now (nothing written).
    def status_public
      ensure_initialized!
      ledger = chain
      withheld = 0
      check = lambda do |text|
        next nil if text.nil?
        next text if Snapshot.public_text?(text)

        withheld += 1
        nil
      end

      level = progression_status(ledger)[:level]
      view, text, = art_shown(ledger, level)
      drawings = art_history(ledger, images: true, last: Snapshot::DRAWINGS_MAX).map do |d|
        { 'data_uri' => d['data_uri'], 'missing' => d['missing'], 'form' => check.call(d['form']), 'stage' => d['stage'],
          'level' => d['level'], 'milestone' => d['milestone'] }.compact
      end
      status = profession_status
      growth = own_growth(ledger)
      entries = knowledge_entries(ledger).to_h { |e| [e['id'], e] }
      sources = Set.new
      cycles = growth[:cycles].map do |c|
        evidence = own_growth_evidence(c)
        urls = Array(evidence && evidence['sources']).filter_map { |s| s['url'] if s.is_a?(Hash) && s['url'].is_a?(String) }
        { cycle: c, evidence: evidence, urls: urls }
      end
      # Every own cycle's public sources count, also those beyond the newest
      # shown here; each URL is checked once.
      checked_urls = {}
      public_url = lambda do |url|
        checked_urls[url] = Snapshot.public_text?(url) unless checked_urls.key?(url)
        checked_urls[url]
      end
      cycles.each { |c| c[:urls].each { |u| sources << u if public_url.call(u) } }
      shown = cycles.last(Snapshot::CYCLES_MAX).reverse.map do |c|
        evidence = c[:evidence] || {}
        knowledge = evidence['knowledge'].is_a?(Hash) ? evidence['knowledge'] : {}
        dropped = c[:urls].reject { |u| public_url.call(u) }.length
        withheld += dropped
        { 'subjects' => Vocabulary.subject_names(c[:cycle]['subjects']),
          'title' => check.call(entries.dig(c[:cycle]['l1_id'], 'title')),
          'synthesis' => check.call(knowledge['content'].is_a?(String) ? knowledge['content'] : nil),
          'finding' => check.call(evidence['finding'].is_a?(String) ? evidence['finding'] : nil),
          'sources' => c[:urls].select { |u| public_url.call(u) } }
      end
      name = check.call(self.name)
      { 'schema' => Snapshot::SCHEMA, 'product' => 'Kairomone', 'version' => VERSION, 'generated_at' => Time.now.utc.iso8601,
        'name' => name, 'level' => level, 'stage' => Vocabulary.stage(level).slice('id', 'en', 'ja'),
        'drawing' => { 'shown' => view[:shown], 'data_uri' => Art.data_uri(text), 'form' => check.call(view[:form]) }.compact,
        'drawings' => drawings,
        'profession' => { 'name' => check.call(status[:name]), 'lineage' => status[:lineage].filter_map { |l| check.call(l[:name]) } },
        'counts' => { 'lifetime_cycles' => growth[:unknown] ? nil : growth[:cycles].length, 'learned_sources' => sources.length,
                      'own_growth_l1' => growth[:cycles].length, 'own_growth_l2' => growth[:cycles].count { |c| c['l2_own'] } },
        'cycles' => shown, 'withheld' => withheld }
    end
  end
end
