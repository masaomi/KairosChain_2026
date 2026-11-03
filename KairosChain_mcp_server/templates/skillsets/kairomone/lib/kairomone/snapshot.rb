# frozen_string_literal: true

module Kairomone
  # What the snapshot page carries (design 0.9 Inv 10, N6): what the
  # individual publicly is — name, accepted drawings, level, stage, profession
  # name and lineage names, counts — and, for each own growth entry
  # (Instance#own_growth), what that cycle learned: its L1 title, the
  # evidence's knowledge.content (not the rendered L1 body, which carries
  # retrieval references), its finding, the subjects its ledger record names
  # and its sources' addresses — scheme, host and path, never a query or a
  # fragment, which can carry the words a search was made of or a token.
  # Nothing else: never a cycle's request (its topic
  # included), any other entry, chat, the direction, the lean, skills, a
  # waiting proposal, a local path or anything secret. Every text is checked
  # as the page is assembled — a drawing's markup too, since its title and
  # desc are text whoever holds the file can read — by the credential guard,
  # for secrets URLs commonly carry, and for a local path (the markers below
  # and this host's own directory); one that fails is left out and counted in
  # withheld. A source address is checked whole before it is shortened.
  # Instance#render_status writes only this.
  module Snapshot
    SCHEMA = 'kairomone-snapshot-1'
    DRAWINGS_MAX = 30
    CYCLES_MAX = 100
    # The local-path markers the check refuses (file: in any case, as a word
    # of its own: "Dockerfile:" and "profile:" are not paths).
    LOCAL_PATHS = %w[/Users/ /home/ ~/].freeze
    FILE_SCHEME = /(?<![A-Za-z0-9])file:/i
    # Secrets a URL or a pasted token commonly carries, beyond the credential
    # guard: signed-URL parameters, token-named parameters with a value, and
    # well-known token prefixes. Conservative, not complete.
    URL_SECRETS = [
      /\bX-(?:Amz|Goog)-(?:Signature|Credential|Security-Token)\b/i,
      /(?<![A-Za-z0-9])[\w.-]*(?:token|signature|secret|passw(?:or)?d|api[_-]?key|apikey|credential|sig|auth)=[^\s&#]+/i,
      /\bxox[abposr]-[A-Za-z0-9-]{10,}/,
      /\bgh[opsu]_[A-Za-z0-9]{20,}/,
      /\bAKIA[0-9A-Z]{16}\b/,
      /\bAIza[0-9A-Za-z_-]{35}/,
      /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/
    ].freeze
    DATA_URI = 'data:image/svg+xml;base64,'

    module_function

    # A text the snapshot may carry: not a credential by the guard, and
    # naming no local path — neither a marker above nor one of roots.
    def public_text?(value, roots = [])
      value.is_a?(String) && value.valid_encoding? && !value.match?(ComposedText::CREDENTIAL) &&
        URL_SECRETS.none? { |pattern| value.match?(pattern) } && !local_path?(value, roots)
    end

    def local_path?(value, roots = [])
      LOCAL_PATHS.any? { |marker| value.include?(marker) } || value.match?(FILE_SCHEME) || roots.any? { |r| value.include?(r) }
    end

    # How a source address is shown: scheme, host (and a port other than the
    # scheme's own) and path — no user, query or fragment — once the whole
    # address passes the check; nil for one that fails or is no web address.
    def public_url(value, roots = [])
      return nil unless public_text?(value, roots)

      uri = URI.parse(value)
      return nil unless uri.is_a?(URI::HTTP) && uri.host.is_a?(String) && !uri.host.empty?

      port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ''
      shown = "#{uri.scheme.downcase}://#{uri.host}#{port}#{uri.path}"
      public_text?(shown, roots) ? shown : nil
    rescue URI::Error
      nil
    end

    # This host's own directory, which holds every individual's files, where
    # the markers above miss it (macOS temporary and external volumes, a
    # server's data directory), with its /private-less form on macOS. A
    # one-segment root such as /data is left to the markers, since as text it
    # would also match the path of a public address.
    def local_roots(host_root)
      return [] unless host_root.is_a?(String) && host_root.split('/').count { |s| !s.empty? } >= 2

      [host_root, (host_root.delete_prefix('/private') if host_root.start_with?('/private/'))].compact
    end

    # The markup an Art.data_uri image holds.
    def svg_of(uri) = Base64.strict_decode64(uri.delete_prefix(DATA_URI)).force_encoding(Encoding::UTF_8)

    # A stage the vocabulary holds, as { id, en, ja }; anything else is nil.
    def stage_names(id) = Vocabulary.stage_named(id)&.slice('id', 'en', 'ja')
  end

  class Instance
    # The snapshot's data, assembled now (nothing written).
    def status_public
      ensure_initialized!
      ledger = chain
      withheld = 0
      roots = Snapshot.local_roots(host_root)
      check = lambda do |text|
        next nil if text.nil?
        next text if Snapshot.public_text?(text, roots)

        withheld += 1
        nil
      end
      # A drawing is checked once, by its markup and its form, wherever it is
      # shown (the hero and the history may show the same one; the same bytes
      # accepted again under another form are another drawing here).
      drawings_seen = {}
      drawing = lambda do |sha, svg, form|
        drawings_seen[[sha, form]] ||= begin
          uri = if svg.nil? then nil
                elsif Snapshot.public_text?(svg, roots) then Art.data_uri(svg)
                else
                  withheld += 1
                  nil
                end
          [uri, check.call(form)]
        end
      end

      level = progression_status(ledger)[:level]
      view, text, = art_shown(ledger, level)
      drawings = art_history(ledger, images: true, last: Snapshot::DRAWINGS_MAX).map do |d|
        uri, form = drawing.call(d['sha256'], d['data_uri'] && Snapshot.svg_of(d['data_uri']), d['form'])
        { 'data_uri' => uri, 'missing' => uri.nil?, 'form' => form, 'stage' => Snapshot.stage_names(d['stage']),
          'level' => d['level'], 'milestone' => d['milestone'] }.compact
      end
      shown_uri, shown_form = view[:shown] == 'drawing' ? drawing.call(view[:sha256], text, view[:form]) : [Art.data_uri(text), nil]
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
      # shown here, as they are shown; each URL is checked once.
      checked_urls = {}
      public_url = lambda do |url|
        checked_urls[url] = Snapshot.public_url(url, roots) unless checked_urls.key?(url)
        checked_urls[url]
      end
      cycles.each { |c| c[:urls].each { |u| (address = public_url.call(u)) && sources << address } }
      shown = cycles.last(Snapshot::CYCLES_MAX).reverse.map do |c|
        evidence = c[:evidence] || {}
        knowledge = evidence['knowledge'].is_a?(Hash) ? evidence['knowledge'] : {}
        dropped = c[:urls].count { |u| public_url.call(u).nil? }
        withheld += dropped
        { 'subjects' => Vocabulary.subject_names(c[:cycle]['subjects']),
          'title' => check.call(entries.dig(c[:cycle]['l1_id'], 'title')),
          'synthesis' => check.call(knowledge['content'].is_a?(String) ? knowledge['content'] : nil),
          'finding' => check.call(evidence['finding'].is_a?(String) ? evidence['finding'] : nil),
          'sources' => c[:urls].filter_map { |u| public_url.call(u) }.uniq }
      end
      name = check.call(self.name)
      # chosen tells "no profession yet" from a profession whose name was
      # left out.
      { 'schema' => Snapshot::SCHEMA, 'product' => 'Kairomone', 'version' => VERSION, 'generated_at' => Time.now.utc.iso8601,
        'name' => name, 'level' => level, 'stage' => Vocabulary.stage(level).slice('id', 'en', 'ja'),
        'drawing' => { 'shown' => view[:shown], 'data_uri' => shown_uri, 'form' => shown_form }.compact,
        'drawings' => drawings,
        'profession' => { 'chosen' => !status[:current].nil?, 'name' => check.call(status[:name]),
                          'lineage' => status[:lineage].filter_map { |l| check.call(l[:name]) } },
        'counts' => { 'lifetime_cycles' => growth[:unknown] ? nil : growth[:cycles].length, 'learned_sources' => sources.length,
                      'own_growth_l1' => growth[:cycles].length, 'own_growth_l2' => growth[:cycles].count { |c| c['l2_own'] } },
        'cycles' => shown, 'withheld' => withheld }
    end
  end
end
