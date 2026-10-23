# frozen_string_literal: true

module Kairomone
  module Console
    # What the page shows (design v0.6 Inv 10, M2, M12): the individuals the
    # host lists and, for the one the page asks for, its status, its drawing
    # and what waits for the owner — drawings, received or drafted profiles
    # and professions, and the open branch offer — each with the IDs and
    # hashes the page puts into the text it places. Reading only: the
    # console still writes nothing (Inv 10).
    module View
      module_function

      # kairomone: the listing ID the page shows; nil shows the first listed.
      def payload(data_dir, kairomone = nil)
        host = Host.new(host_root: data_dir)
        listed = host.summaries.map { |s| s.transform_keys(&:to_s) }
        shown = kairomone || listed.first&.fetch('listing_id')
        base = { 'data_dir' => data_dir, 'kairomones' => listed, 'shown' => shown, 'kinds' => kinds, 'templates' => templates }
        return base.merge('status' => Instance.new(host_root: data_dir, bind: false).status) if shown.nil?

        store = Instance.new(host_root: data_dir, kairomone: shown) # refuses an ID the host does not list
        status = store.status
        base.merge('status' => status, 'waiting' => waiting(store, status))
      end

      def waiting(store, status)
        level = status.dig(:progression, :level) or return nil

        art = store.send(:art_page, store.chain, level)
        pieces = store.proposals[:proposals].select { |p| p['state'] == 'waiting' && %w[profile profession].include?(p['kind']) }.map do |p|
          piece = p['piece'].is_a?(Hash) ? p['piece'] : {}
          { 'proposal' => p['proposal'], 'kind' => p['kind'], 'name' => piece['name'].to_s,
            'sha256' => Digest::SHA256.hexdigest(JSON.pretty_generate(piece) + "\n"), 'received' => !p['received_sha256'].nil? }
        end
        offer = status.dig(:profession, :branch, :offer)
        { 'art' => { 'shown' => art[:shown], 'sha256' => art[:sha256], 'stage' => art[:stage], 'due' => art[:due], 'data_uri' => art[:data_uri],
                     'waiting' => art[:waiting].map { |w| w.transform_keys(&:to_s) } },
          'proposals' => pieces,
          'offer' => offer && { 'offer' => offer[:offer], 'candidates' => offer[:candidates].map { |c| c.slice('name', 'description') } } }
      end

      # The starters the creation panel offers: kinds, and the traits their
      # starters name.
      def kinds
        Vocabulary.characters.map do |k|
          { 'kind' => k['kind'], 'label' => k.dig('kind_label', 'ja') || k['kind'],
            'traits' => Array(k.dig('starter', 'personality')) + Array(k.dig('starter', 'interests')) }
        end
      end

      def templates = Vocabulary.templates.map { |t| { 'id' => t['id'], 'name' => t['name'] } }
    end
  end
end
