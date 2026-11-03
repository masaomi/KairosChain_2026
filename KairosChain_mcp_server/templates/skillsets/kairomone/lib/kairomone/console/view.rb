# frozen_string_literal: true

module Kairomone
  module Console
    # What the page shows (design 0.8 v0.6 Inv 10, M2, M12; 0.9 Inv 10, N5,
    # N7): the individuals the host lists and, for the one the page asks for,
    # its status, its drawing and what waits for the owner — drawings,
    # received or drafted profiles, professions and skills, and the open
    # branch offer — each with the IDs and hashes the page puts into the text
    # it places; its lean, its skills in force, its own growth entries (what
    # a skill can be drafted from), its lifetime cycles and learned subjects,
    # and a digest of its drawing history. The history itself, with its
    # images, is a separate read the page makes when the digest it holds
    # differs, so it travels once per load and when it changes, not with
    # every status. No branch level and no fixed profession list is ever
    # part of it. Reading only: the console still writes nothing (Inv 10).
    module View
      # The newest own growth entries the skills panel names.
      OWN_GROWTH_SHOWN = 50

      module_function

      # kairomone: the listing ID the page shows; nil, or one the host no
      # longer lists, shows the first listed. The listing comes back whatever
      # fails for the one shown, so the page can always switch away from it.
      def payload(data_dir, kairomone = nil)
        host = Host.new(host_root: data_dir)
        listed = host.summaries.map { |s| s.transform_keys(&:to_s) }
        ids = listed.map { |l| l['listing_id'] }
        shown = ids.include?(kairomone) ? kairomone : ids.first
        base = { 'data_dir' => data_dir, 'kairomones' => listed, 'shown' => shown, 'kinds' => kinds }
        base['notice'] = "#{kairomone} is not listed on this host; showing #{shown || 'none'}" if kairomone && kairomone != shown
        return base.merge('status' => Instance.new(host_root: data_dir, bind: false).status) if shown.nil?

        store = Instance.new(host_root: data_dir, kairomone: shown)
        # The status and the individual's panels read own growth from one
        # reading per payload (the page polls /status).
        store.sharing_own_growth do
          status = store.status
          out = base.merge('status' => status).merge(growth_counts(status))
          errors = []
          begin
            out['waiting'] = waiting(store, status)
          rescue StandardError => e
            out['waiting'] = nil
            errors << "What waits for the owner could not be read: #{e.message}"
          end
          begin
            out.merge!(individual(store))
          rescue StandardError => e
            out.merge!('lean' => nil, 'skills' => nil, 'own_growth' => nil, 'own_growth_total' => nil, 'art_history' => nil)
            errors << "The lean, skills and drawing history could not be read: #{e.message}"
          end
          out['error'] = errors.join(' ') unless errors.empty?
          out
        end
      end

      # The drawing history of one listed individual, with each drawing that
      # passes the art check now as a data: image (Inv 6), and the digest the
      # status payload names for it. A drawing absent or failing the check is
      # in the list as missing, never as another.
      def art_history(data_dir, kairomone)
        host = Host.new(host_root: data_dir)
        listed = host.summaries.map { |s| s[:listing_id] || s['listing_id'] }
        unless listed.include?(kairomone)
          return { 'shown' => nil, 'digest' => nil, 'drawings' => nil, 'error' => "#{kairomone} is not listed on this host" }
        end

        store = Instance.new(host_root: data_dir, kairomone: kairomone)
        drawings = history_items(store, store.chain, images: true)
        { 'shown' => kairomone, 'digest' => history_digest(drawings), 'drawings' => drawings }
      end

      def waiting(store, status)
        level = status.dig(:progression, :level) or return nil

        art = store.send(:art_page, store.chain, level)
        pieces = store.proposals[:proposals].select { |p| p['state'] == 'waiting' && %w[profile profession skill].include?(p['kind']) }.map do |p|
          piece = p['piece'].is_a?(Hash) ? p['piece'] : {}
          { 'proposal' => p['proposal'], 'kind' => p['kind'], 'name' => piece['name'].to_s,
            'sha256' => Digest::SHA256.hexdigest(JSON.pretty_generate(piece) + "\n"), 'received' => !p['received_sha256'].nil? }
        end
        offer = status.dig(:profession, :branch, :offer)
        { 'art' => { 'shown' => art[:shown], 'sha256' => art[:sha256], 'stage' => art[:stage], 'due' => art[:due], 'data_uri' => art[:data_uri],
                     'form' => art[:form], 'waiting' => art[:waiting].map { |w| w.transform_keys(&:to_s) } },
          'proposals' => pieces,
          'offer' => offer && { 'offer' => offer[:offer], 'candidates' => offer[:candidates].map { |c| c.slice('name', 'description') } } }
      end

      # Lifetime cycles and learned subjects as the status reports them
      # (0.9 N3); unknown stays unknown (nil), never zero.
      def growth_counts(status)
        growth = status[:growth]
        return { 'lifetime_cycles' => nil, 'lifetime_unknown' => nil, 'learned_subjects' => nil } unless growth.is_a?(Hash)

        { 'lifetime_cycles' => growth['lifetime_cycles'], 'lifetime_unknown' => growth['lifetime_unknown'],
          'learned_subjects' => growth['learned_subjects'] }
      end

      # The lean in force with the owner's quoted words, the skills in force
      # by name, method and subject names, the newest own growth entries, and
      # the drawing history's digest and count.
      def individual(store)
        ledger = store.chain
        growth = store.own_growth(ledger)
        titles = store.knowledge_entries(ledger).to_h { |e| [e['id'], e['title']] }
        skills = store.skills_in_force(ledger, growth).map do |s|
          piece = s[:piece]
          { 'sha256' => s[:sha256], 'name' => piece['name'], 'description' => piece['description'],
            'methods' => Vocabulary.learning_method_names(piece['methods']), 'focus' => Vocabulary.subject_names(piece['focus']) }
        end
        own = growth[:cycles].reverse.first(OWN_GROWTH_SHOWN).map do |c|
          { 'entry_id' => c['l1_id'], 'sha256' => c['l1_sha256'], 'title' => titles[c['l1_id']] }
        end
        history = history_items(store, ledger, images: false)
        { 'lean' => store.lean_view(ledger), 'skills' => skills, 'own_growth' => own, 'own_growth_total' => growth[:cycles].length,
          'art_history' => { 'digest' => history_digest(history), 'count' => history.length } }
      end

      # Every accepted drawing in the order it was accepted, with its stage's
      # names for display (a drawing accepted before 0.9 is shown by stage).
      def history_items(store, ledger, images:)
        store.art_history(ledger, images: images).map do |item|
          named = item['stage'] && Vocabulary.stage_named(item['stage'])
          item.merge('stage_name' => named && named.slice('en', 'ja'))
        end
      end

      # Over the history without its images: the images are a function of
      # the files their sha256 names, whose presence and validity it holds.
      def history_digest(items) = Digest::SHA256.hexdigest(JSON.generate(items.map { |i| i.except('data_uri') }))

      # The starters the creation panel offers: kinds, and the traits their
      # starters name.
      def kinds
        Vocabulary.characters.map do |k|
          { 'kind' => k['kind'], 'label' => k.dig('kind_label', 'ja') || k['kind'],
            'traits' => Array(k.dig('starter', 'personality')) + Array(k.dig('starter', 'interests')) }
        end
      end
    end
  end
end
