# frozen_string_literal: true

module Kairomone
  # Fusion (design v0.6 Inv 9, M14): a new individual from two, changing
  # neither. The composer reads both parents' L1 (material), proposes a plan
  # (the child's listing ID, a draft profile, three profession candidates and
  # the child's entries, each kept from or merged out of cited parent
  # entries), and the owner accepts it from its summary. The child starts at
  # level 1 as an egg with no L2; everything it inherits is held and never
  # counted (Inv 3), and what came from outside stays marked so.
  module Fusion
    PLANS = 'kairomone-fusion'
    PAGE_BYTES = 24 * 1024
    MODES = %w[keep merge].freeze
    PLAN_TTL = 7 * 24 * 3600
  end

  class Host
    # Both parents' L1 for the composer: id, title, body, sha256, recorded
    # identity and outside flag, paged; with each parent's ledger head.
    def fusion_material(parents:, page: 1)
      a, b = fusion_parents(parents)
      raise Error, 'page is a positive integer' unless page.is_a?(Integer) && page.positive?

      items = []
      heads = {}
      [a, b].each do |parent|
        ledger = parent.chain
        heads[parent.listing_id] = ledger.latest_block&.hash
        items << { 'item' => 'parent', 'listing_id' => parent.listing_id, 'identity' => parent.identity(ledger), 'name' => parent.name,
                   'profession' => parent.profession_status[:current].slice(:id, :name, :focus, :habits) }
        items += parent.send(:fusion_entries, ledger).map { |e| { 'item' => 'entry', 'parent' => parent.listing_id }.merge(e) }
      end
      pages = fusion_pages(items)
      raise Error, "page runs from 1 to #{pages.length}" if page > pages.length

      { success: true, parents: [a.listing_id, b.listing_id], heads: heads, page: page, pages: pages.length, items: pages[page - 1],
        note: 'Propose the child from this material: a draft profile, three profession candidates and its entries, each kept from ' \
              'one parent entry or merged from several, citing them by parent, entry_id and sha256.' }
    end

    # Stores the composer's plan; nothing takes effect until the owner
    # accepts it from its summary.
    def fusion_propose(parents:, child:, profile:, candidates:, entries:, heads:)
      a, b = fusion_parents(parents)
      Paths.id!(child)
      raise Error, "#{child} is already listed on this host; choose another listing ID" if listed?(child)

      current = { a.listing_id => a.chain.latest_block&.hash, b.listing_id => b.chain.latest_block&.hash }
      raise Error, 'heads must give both parents\' ledger heads as the material showed them' unless heads.is_a?(Hash) && heads.transform_keys(&:to_s) == current

      piece = Profile.build(profile, origin: 'fusion')
      ComposedText.guard!(Profile.texts(piece))
      parent_professions = [a, b].map { |p| p.profession_status[:current][:id] }
      raise Error, 'Offer exactly three profession candidates' unless candidates.is_a?(Array) && candidates.length == 3

      pieces = candidates.map { |c| Profession.build(c, parents: parent_professions, tier: 0, origin: 'fusion') }
      ComposedText.guard!(pieces.flat_map { |p| Profession.texts(p) })
      raise Error, 'The three professions need three different names' unless pieces.map { |p| p['name'] }.uniq.length == 3

      sources_of = { a.listing_id => a, b.listing_id => b }.to_h { |id, parent| [id, parent.send(:fusion_entries).to_h { |e| [e['id'], e] }] }
      planned = fusion_plan_entries!(entries, sources_of)
      plan = { 'kind' => 'fusion_plan', 'parents' => [a.listing_id, b.listing_id], 'heads' => current, 'child' => child, 'profile' => piece,
               'candidates' => pieces, 'entries' => planned, 'proposed_at' => Time.now.utc.iso8601 }
      bytes = JSON.pretty_generate(plan) + "\n"
      sha = Digest::SHA256.hexdigest(bytes)
      prune_fusion_plans!
      Paths.mkdir(host_root, Fusion::PLANS)
      relative = "#{Fusion::PLANS}/#{sha}.json"
      Paths.write(host_root, relative, bytes) unless File.exist?(Paths.checked(host_root, relative))
      fusion_summary(plan: sha).merge(note: 'Show the owner every page of this summary (summary with the plan and page). The child is made ' \
                                              'only when they accept the plan with one candidate.')
    end

    # What the owner accepts a plan from: the counts of what is kept, merged
    # and dropped, the draft profile and the three candidates on every page;
    # paged, each child entry in full with the parent entries it came from,
    # and each parent entry dropped.
    def fusion_summary(plan:, page: 1)
      raise Error, 'page is a positive integer' unless page.is_a?(Integer) && page.positive?

      doc = fusion_plan(plan)
      cited = Set.new(doc['entries'].flat_map { |e| e['sources'].map { |s| [s['parent'], s['entry_id']] } })
      dropped = doc['parents'].flat_map do |id|
        Instance.new(host_root: host_root, kairomone: id).send(:fusion_entries).reject { |e| cited.include?([id, e['id']]) }
                .map { |e| { 'item' => 'dropped', 'parent' => id, 'id' => e['id'], 'title' => e['title'] } }
      end
      items = doc['entries'].map { |e| { 'item' => 'child_entry' }.merge(e) } + dropped
      pages = fusion_pages(items)
      raise Error, "page runs from 1 to #{pages.length}" if page > pages.length

      { success: true, plan: plan, parents: doc['parents'], child: doc['child'],
        kept: doc['entries'].count { |e| e['mode'] == 'keep' }, merged: doc['entries'].count { |e| e['mode'] == 'merge' }, dropped: dropped.length,
        profile: doc['profile'], candidates: doc['candidates'].map { |c| c.slice('name', 'description', 'focus', 'habits') },
        page: page, pages: pages.length, items: pages[page - 1] }
    end

    # Makes the child when the owner accepts the plan with one candidate.
    def fusion_accept(plan:, candidate:)
      raise Error, 'candidate is 0, 1 or 2' unless [0, 1, 2].include?(candidate)

      governed!('L1')
      with_registry_lock do
        doc = fusion_plan(plan)
        a, b = fusion_parents(doc['parents'])
        # The pieces are judged by the rules current now, as every accept is.
        piece = Profile.build(doc['profile'].is_a?(Hash) ? doc['profile'].slice(*Exchange::PROFILE_FIELDS) : {}, origin: 'fusion')
        ComposedText.guard!(Profile.texts(piece))
        chosen = doc['candidates'][candidate]
        profession = Profession.build(chosen.is_a?(Hash) ? chosen.slice('name', 'description', 'focus', 'habits') : {},
                                      parents: [a, b].map { |p| p.profession_status[:current][:id] }, tier: 0, origin: 'fusion')
        ComposedText.guard!(Profession.texts(profession))
        first, second = [a, b].sort_by(&:listing_id)
        first.send(:with_lock) do
          second.send(:with_lock) do
            [a, b].each do |parent|
              raise Error, "#{parent.listing_id} changed since the plan was made; propose again" unless parent.chain.latest_block&.hash == doc['heads'][parent.listing_id]
            end
            sources_of = { a.listing_id => a, b.listing_id => b }.to_h { |id, parent| [id, parent.send(:fusion_entries).to_h { |e| [e['id'], e] }] }
            fusion_plan_entries!(doc['entries'], sources_of)
            path = assemble(doc['child']) do |staged|
              staged.fuse_into!(doc.merge('profile' => piece), plan, profession, [a, b], sources_of)
              doc['child']
            end
            relative = "#{Fusion::PLANS}/#{plan}.json"
            File.delete(Paths.checked(host_root, relative)) if File.file?(Paths.checked(host_root, relative))
            child = Instance.new(host_root: host_root, root: path)
            { success: true, fused: true, kairomone: child.address, parents: doc['parents'], level: child.progression_status[:level],
              entries: doc['entries'].length, note: 'Both parents are unchanged. The child is an egg; its drawing is due at hatch.' }
          end
        end
      end
    end

    private

    # Plans not accepted within a week are removed.
    def prune_fusion_plans!
      dir = Paths.checked(host_root, Fusion::PLANS)
      return unless File.directory?(dir) && !File.symlink?(dir)

      Dir.children(dir).each do |name|
        path = File.join(dir, name)
        File.delete(path) if name.match?(/\A[0-9a-f]{64}\.json\z/) && File.file?(path) && File.mtime(path) < Time.now - Fusion::PLAN_TTL
      rescue Errno::ENOENT
        next
      end
    end

    def fusion_pages(items)
      pages = [[]]
      size = 0
      items.each do |item|
        bytes = JSON.generate(item).bytesize
        if size + bytes > Fusion::PAGE_BYTES && !pages.last.empty?
          pages << []
          size = 0
        end
        pages.last << item
        size += bytes
      end
      pages
    end

    def fusion_parents(parents)
      ids = Array(parents)
      raise Error, 'Name exactly two parents' unless ids.length == 2

      ids.each { |id| Paths.id!(id) }
      raise Error, 'A Kairomone cannot fuse with itself' if ids.uniq.length == 1

      ids.map do |id|
        raise Error, "No Kairomone is listed as #{id} on this host" unless listed?(id)

        Instance.new(host_root: host_root, kairomone: id)
      end
    end

    def fusion_plan(sha)
      raise Error, 'plan must be a plan sha256' unless Progression::SHA.match?(sha.to_s)

      relative = "#{Fusion::PLANS}/#{sha}.json"
      raise Error, 'No such fusion plan' unless File.file?(Paths.checked(host_root, relative))

      bytes = Paths.read(host_root, relative, limit: 64 * 1024 * 1024)
      raise Error, 'The fusion plan does not match its hash' unless Digest::SHA256.hexdigest(bytes) == sha

      doc = JSON.parse(bytes)
      raise Error, 'Not a fusion plan' unless doc.is_a?(Hash) && doc['kind'] == 'fusion_plan'

      doc
    end

    # The child's entries, each citing parent entries by the hash they hold
    # now; a kept entry is its source's body.
    def fusion_plan_entries!(entries, sources_of)
      raise Error, 'entries is a list' unless entries.is_a?(Array)
      raise Error, "A Kairomone holds at most #{Instance::MAX_ENTRIES} L1 entries" if entries.length > Instance::MAX_ENTRIES

      planned = entries.map do |e|
        e = e.transform_keys(&:to_s) if e.is_a?(Hash)
        raise Error, 'Each entry is {id, title, content, mode, sources}' unless e.is_a?(Hash) && e.keys.sort == %w[content id mode sources title]

        Paths.id!(e['id'])
        raise Error, "Entry #{e['id']}: mode is keep or merge" unless Fusion::MODES.include?(e['mode'])
        raise Error, "Entry #{e['id']}: title is text of at most 512 bytes" unless e['title'].is_a?(String) && !e['title'].strip.empty? && e['title'].bytesize <= 512
        raise Error, "Entry #{e['id']}: content is text of at most #{Instance::MAX_CONTENT} bytes" unless e['content'].is_a?(String) && !e['content'].strip.empty? && e['content'].bytesize <= Instance::MAX_CONTENT

        sources = Array(e['sources']).map { |s| s.is_a?(Hash) ? s.transform_keys(&:to_s) : {} }
        raise Error, "Entry #{e['id']}: cite at least one source" if sources.empty?
        raise Error, "Entry #{e['id']}: a kept entry has one source" if e['mode'] == 'keep' && sources.length != 1

        sources.each do |s|
          held = sources_of.dig(s['parent'], s['entry_id'])
          raise Error, "Entry #{e['id']}: #{s['parent']}/#{s['entry_id']} is not a parent entry" unless held
          raise Error, "Entry #{e['id']}: #{s['parent']}/#{s['entry_id']} no longer holds the cited content" unless held['sha256'] == s['sha256']
        end
        if e['mode'] == 'keep' && sources_of.dig(sources[0]['parent'], sources[0]['entry_id'], 'body').to_s.strip != e['content'].strip
          raise Error, "Entry #{e['id']}: a kept entry differs from its source"
        end
        { 'id' => e['id'], 'title' => e['title'], 'content' => e['content'], 'mode' => e['mode'],
          'sources' => sources.map { |s| s.slice('parent', 'entry_id', 'sha256') } }
      end
      raise Error, 'Entry IDs repeat' unless planned.map { |e| e['id'] }.uniq.length == planned.length

      planned
    end
  end

  class Instance
    # Assembles the fused child in this staged individual.
    def fuse_into!(plan, plan_sha, profession, parents, sources_of)
      child = plan['child']
      now = Time.now.utc.iso8601
      lineage = { 'type' => 'kairomone_lineage', 'kind' => 'fusion', 'plan_sha256' => plan_sha,
                  'sources' => parents.map { |p| { 'identity' => p.identity, 'listing_id' => p.listing_id, 'name' => p.name, 'ledger_head' => plan['heads'][p.listing_id] } } }
      open_new!(identity: child, origin: 'fusion', listing_id: child, profile_piece: plan['profile'], profession_piece: profession, lineage: lineage)
      ledger = chain
      writes = plan['entries'].map do |e|
        raw = document(e['id'], e['title'], e['content'], 'L1', now)
        cited = e['sources'].map { |s| sources_of.dig(s['parent'], s['entry_id']) }
        # A child holds each cited entry's identity and what that entry holds.
        entry = xp_entry('L1', e['id'], Progression.fingerprint(e['content']), raw, counted: false,
                         holds: cited.flat_map { |c| [c['identity'], *c['holds']] }.uniq.first(256))
        [e['id'], raw, entry.merge('outside' => cited.any? { |c| c['outside'] })]
      end
      record_identities!(writes.map { |_, _, entry| entry }, ledger)
      writes.each do |id, raw, _|
        written = write_l1_raw(id, raw, 'Kairomone fusion: inherited entry')
        raise Error, "Inherited entry #{id} could not be recorded" unless written[:success]
      end
    end

    private

    # This individual's recorded L1 as fusion material: id, title, body,
    # sha256 of the file, the identity in force and whether it is outside
    # content (learned, received, or marked so).
    def fusion_entries(ledger = chain)
      growth = growth_entry_ids(ledger)
      records = identity_records(ledger)
      xp_basis(ledger).select { |b| b['layer'] == 'L1' && b['recorded'] }.sort_by { |b| b['id'] }.map do |b|
        item = knowledge_provider.get(b['id'])
        record = records[['L1', b['id']]].reverse.find { |r| r['content_sha256'] == b['content_sha256'] }
        { 'id' => b['id'], 'title' => item.description.to_s, 'body' => item.content.to_s, 'sha256' => b['content_sha256'],
          'identity' => b['identity'], 'holds' => b['holds'], 'outside' => growth.include?(b['id']) || record&.dig('outside') == true }
      end
    end
  end
end
