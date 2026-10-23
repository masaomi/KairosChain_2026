# frozen_string_literal: true

require 'set'

module Kairomone
  # Exchange (design v0.6 Inv 8, M11): a labelled copy of what the owner chose.
  # The preview fixes the inputs and shows every piece the file will carry;
  # export rebuilds the file from the same inputs and writes it only when its
  # sha256 is the one previewed. Chat memories, growth state, backups, the
  # ledger, the owner's direction and personality, composition material and
  # host references never go in. The exporter's content, ledger and state do
  # not change. Import makes a new individual from a file (Inv 1): received
  # knowledge is outside content and keeps the XP basis it carried (Inv 3);
  # received pieces wait as proposals (Inv 4).
  module Exchange
    FORMAT = 'kairomone-exchange'
    VERSION = 1
    NAME = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,150}\.kairomone-exchange\.json\z/
    OUTBOX = 'kairomone-outbox'
    PREVIEWS = 'kairomone-previews' # host-private: never inside the hand-off folder
    INBOX = 'kairomone-inbox'
    # learned: written by a cycle or carried with its evidence; inherited:
    # held and never counted; received: counted content that came from
    # outside (an import); owner_written: the rest (Inv 8).
    KINDS = %w[learned owner_written inherited received].freeze
    PAGE_BYTES = 24 * 1024
    PREVIEW_TTL = 24 * 3600
    FILE_LIMIT = 32 * 1024 * 1024
    PROFILE_FIELDS = %w[name kind kind_label appearance personality voice interests].freeze
    PROFESSION_FIELDS = %w[name description focus habits tier parents origin].freeze
    PIECES_MAX = 64
    TOP = %w[format version renderer source includes pieces entries xp_basis lineage manifest_sha256].freeze
    PREVIEW_FILE = /\A[0-9a-f]{64}(?:\.p\d{1,6})?\.(?:json|file)\z/

    module_function

    def manifest(doc) = Digest::SHA256.hexdigest(JSON.generate(doc.reject { |k, _| k == 'manifest_sha256' }))
    def bytes(doc) = JSON.pretty_generate(doc) + "\n"

    # Integrity and shape only: the manifest, the fixed set of keys, sizes.
    # What the pieces and entries say is judged when they are stored.
    def load(bytes)
      doc = JSON.parse(bytes)
      raise Error, 'Not a Kairomone exchange file' unless doc.is_a?(Hash) && doc['format'] == FORMAT && doc['version'] == VERSION
      raise Error, 'Unexpected exchange file fields' unless doc.keys.sort == TOP.sort
      raise Error, 'Exchange file manifest mismatch' unless manifest(doc) == doc['manifest_sha256']

      source = doc['source']
      short = ->(v, max) { v.is_a?(String) && v.bytesize <= max }
      raise Error, 'Invalid exchange renderer' unless short.call(doc['renderer'], 64)
      unless source.is_a?(Hash) && source.keys.sort == %w[exported_at identity ledger_head name] && Paths::ID.match?(source['identity'].to_s) &&
             short.call(source['name'], 256) && short.call(source['exported_at'], 64) && (source['ledger_head'].nil? || short.call(source['ledger_head'], 128))
        raise Error, 'Invalid exchange source'
      end
      entries = doc['entries']
      raise Error, 'Invalid exchange entries' unless entries.is_a?(Array) && entries.length <= Instance::MAX_ENTRIES
      entries.each do |e|
        ok = e.is_a?(Hash) && (e.keys - ['evidence']).sort == %w[content id kind title] && Paths::ID.match?(e['id'].to_s) &&
             KINDS.include?(e['kind']) && e['title'].is_a?(String) && !e['title'].strip.empty? && e['title'].bytesize <= 512 &&
             e['content'].is_a?(String) && !e['content'].strip.empty? && e['content'].bytesize <= Instance::MAX_CONTENT
        raise Error, 'Invalid exchange entry' unless ok
      end
      raise Error, 'Duplicate exchange entry IDs' unless entries.map { |e| e['id'] }.uniq.length == entries.length
      basis = doc['xp_basis']
      basis_ok = basis.is_a?(Array) && basis.all? do |b|
        b.is_a?(Hash) && b.keys.sort == %w[counted holds id identity layer] && %w[L1 L2].include?(b['layer']) &&
          Progression::SHA.match?(b['identity'].to_s) && [true, false].include?(b['counted']) &&
          b['holds'].is_a?(Array) && b['holds'].length <= 256 && b['holds'].all? { |h| Progression::SHA.match?(h.to_s) }
      end
      raise Error, 'Invalid exchange XP basis' unless basis_ok

      pieces = doc['pieces']
      raise Error, 'Invalid exchange pieces' unless pieces.is_a?(Hash) && pieces.keys.sort == %w[art professions profile]
      raise Error, "An exchange file carries at most #{PIECES_MAX} professions and #{PIECES_MAX} drawings" unless
        [pieces['professions'], pieces['art']].all? { |list| list.is_a?(Array) && list.length <= PIECES_MAX }
      lineage_ok = doc['lineage'].is_a?(Array) && doc['lineage'].length <= PIECES_MAX && doc['lineage'].all? do |l|
        l.is_a?(Hash) && l.keys.sort == %w[kind sources] && short.call(l['kind'], 32) && l['sources'].is_a?(Array) && l['sources'].length <= 8 &&
          l['sources'].all? { |s| s.is_a?(Hash) && s.keys.sort == %w[identity name] && Paths::ID.match?(s['identity'].to_s) && short.call(s['name'], 256) }
      end
      raise Error, 'Invalid exchange lineage' unless lineage_ok
      doc
    rescue JSON::ParserError => e
      raise Error, "Invalid exchange file: #{e.message}"
    end
  end

  class Instance
    # Shows, in full and paged under one file sha256, every piece the file
    # will carry and what is left out. A new preview (no file_sha256) fixes
    # the inputs and keeps them, with the file they build, outside the
    # individual; its later pages are read from that file by its sha256.
    def exchange_preview(include: nil, entry_ids: nil, page: 1, file_sha256: nil)
      raise Error, 'page is a positive integer' unless page.is_a?(Integer) && page.positive?
      return exchange_preview_page(file_sha256, page) if file_sha256

      raise Error, 'Pages after the first name the preview by its file_sha256' unless page == 1
      includes = Exchange::KINDS.to_h { |k| [k, Array(include).include?(k)] }
      raise Error, "include names one or more of #{Exchange::KINDS.join(', ')}" unless Array(include).all? { |k| Exchange::KINDS.include?(k) }
      ids = entry_ids.nil? ? nil : Array(entry_ids).map { |id| Paths.id!(id) }

      autonomy.synchronize do
        with_lock do
          ensure_initialized!
          ledger = chain
          inputs = { 'listing_id' => listing_id, 'includes' => includes, 'entry_ids' => ids, 'exported_at' => Time.now.utc.iso8601,
                     'ledger_head' => ledger.latest_block&.hash }
          doc, left_out = exchange_document(inputs, ledger)
          bytes = Exchange.bytes(doc)
          raise Error, "This file would be #{bytes.bytesize} bytes, over the #{Exchange::FILE_LIMIT} an import reads; include less" if bytes.bytesize > Exchange::FILE_LIMIT

          # The importer's integrity and shape checks, run on the bytes the
          # export would write: no file is offered that an import refuses.
          begin
            Exchange.load(bytes)
          rescue Error => e
            raise Error, "An import would refuse this file (#{e.message}); include less"
          end
          sha = Digest::SHA256.hexdigest(bytes)
          pages = exchange_pages(doc, left_out['entries']).map { |items| JSON.generate(items) }
          @host.send(:prune_exchange_previews!)
          Paths.mkdir(host_root, Exchange::PREVIEWS)
          pages.each_with_index { |page, i| Paths.write(host_root, "#{Exchange::PREVIEWS}/#{sha}.p#{i + 1}.json", page, replace: true) }
          Paths.write(host_root, "#{Exchange::PREVIEWS}/#{sha}.file", bytes, replace: true)
          Paths.write(host_root, "#{Exchange::PREVIEWS}/#{sha}.json",
                      JSON.generate(inputs.merge('left_out' => left_out, 'bytes' => bytes.bytesize, 'pages' => pages.map { |p| Digest::SHA256.hexdigest(p) })),
                      replace: true)
          exchange_preview_page(sha, 1)
        end
      end
    end

    # Writes the previewed file to kairomone-outbox/ when the same inputs
    # rebuild it byte for byte.
    def exchange_export(file_sha256:)
      raise Error, 'file_sha256 must be a sha256 hex digest' unless Progression::SHA.match?(file_sha256.to_s)

      autonomy.synchronize do
        with_lock do
          ensure_initialized!
          relative = "#{Exchange::PREVIEWS}/#{file_sha256}.json"
          raise Error, 'No such preview (it expired or was used); preview again' unless File.file?(Paths.checked(host_root, relative))
          raise Error, 'This preview expired; preview again' if File.mtime(Paths.checked(host_root, relative)) < Time.now - Exchange::PREVIEW_TTL

          inputs = JSON.parse(Paths.read(host_root, relative, limit: 4 * 1_048_576))
          raise Error, 'This preview is of another Kairomone' unless inputs['listing_id'] == listing_id

          ledger = chain
          unless inputs['ledger_head'] == ledger.latest_block&.hash
            raise Error, 'This Kairomone changed since the preview (a live run, a write); stop the run or preview again'
          end
          doc, = exchange_document(inputs, ledger)
          bytes = Exchange.bytes(doc)
          raise Error, 'The file no longer rebuilds as previewed; preview again' unless Digest::SHA256.hexdigest(bytes) == file_sha256

          Paths.mkdir(host_root, Exchange::OUTBOX)
          name = "#{listing_id}-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}.kairomone-exchange.json"
          path = Paths.write(host_root, "#{Exchange::OUTBOX}/#{name}", bytes)
          used = [relative, relative.sub(/\.json\z/, '.file')] + Array(inputs['pages']).each_index.map { |i| "#{Exchange::PREVIEWS}/#{file_sha256}.p#{i + 1}.json" }
          used.each { |r| File.delete(Paths.checked(host_root, r)) if File.file?(Paths.checked(host_root, r)) }
          @host.send(:prune_exchange_previews!)
          { success: true, exported: true, kairomone: address, file: name, path: path, file_sha256: file_sha256,
            manifest_sha256: doc['manifest_sha256'], entries: doc['entries'].length,
            note: 'The file is unencrypted. This Kairomone did not change.' }
        end
      end
    end

    # Stores a parsed exchange file into this staged individual (Host#import_exchange).
    def import_exchange_into!(doc, listing:, keep_pieces: true)
      now = Time.now.utc.iso8601
      entries = doc['entries']
      basis = doc['xp_basis'].to_h { |b| [[b['layer'], b['id']], b] }
      if entries.any? { |e| e['evidence'] } && doc['renderer'] != Autonomy::KNOWLEDGE_RENDERER
        raise Error, "This file's learned entries were rendered by #{doc['renderer']}; this Kairomone renders #{Autonomy::KNOWLEDGE_RENDERER}; refused"
      end
      writes = []
      # One identity rule, whatever kind the file names: an entry whose
      # evidence travels is checked against the evidence; any other entry's
      # identity is the fingerprint of its content (Inv 3).
      entries.each do |entry|
        l1 = basis[['L1', entry['id']]] or raise Error, "The file carries no XP basis for #{entry['id']}"
        raise Error, "#{entry['id']} is inherited, and inherited knowledge never counts; refused" if entry['kind'] == 'inherited' && l1['counted']

        evidence = entry['evidence']
        if evidence
          l2 = basis[['L2', entry['id']]] or raise Error, "The file carries no XP basis for the evidence of #{entry['id']}"
          envelope = received_evidence!(entry, evidence, l1, l2)
          writes << ['L2', entry['id'], document(entry['id'], "Growth evidence: #{entry['title']}", JSON.pretty_generate(envelope), 'L2', now), l2]
        elsif l1['identity'] != Progression.fingerprint(entry['content'])
          raise Error, "The XP identity of #{entry['id']} does not match its content; refused"
        end
        writes << ['L1', entry['id'], document(entry['id'], entry['title'], entry['content'], 'L1', now), l1]
      end
      raise Error, "An individual holds at most #{MAX_ENTRIES} L1 entries" if entries.length > MAX_ENTRIES

      open_new!(identity: listing, origin: 'import', listing_id: listing, with_profile: false)
      ledger = chain
      record_identities!(writes.map { |layer, id, raw, b| xp_entry(layer, id, b['identity'], raw, counted: b['counted'], holds: b['holds']).merge('outside' => true) }, ledger)
      writes.each { |layer, id, raw, _| write_l2_raw!(id, raw) if layer == 'L2' }
      write_l1_all!(writes.select { |layer, *| layer == 'L1' }.map { |_, id, raw, _| [id, raw] }, 'Kairomone exchange import')
      received, skipped = if keep_pieces
                            received_pieces!(doc['pieces'], now)
                          else
                            [[], [{ 'kind' => 'pieces', 'reason' => 'Host governance locks L2, where proposals wait; no received piece was kept' }]]
                          end
      Records.append!(chain, [{ 'type' => 'kairomone_received', 'manifest_sha256' => doc['manifest_sha256'], 'pieces' => received,
                                'entries' => entries.map { |e| e['id'] } },
                              { 'type' => 'kairomone_lineage', 'kind' => 'exchange',
                                'sources' => [doc['source'].slice('identity', 'name', 'ledger_head')], 'manifest_sha256' => doc['manifest_sha256'],
                                'ancestry' => doc['lineage'] }],
                      -> { chain })
      { received: received, skipped: skipped, entries: entries.length }
    end

    private

    # The file for these inputs and this ledger: [document, what is left out].
    def exchange_document(inputs, ledger)
      basis = xp_basis(ledger)
      excluded = Set.new(basis.reject { |b| b['counted'] }.flat_map { |b| [b['identity'], *b['holds']] } | chat_xp_excluded_fingerprints)
      effective = ->(b) { b['counted'] && !excluded.include?(b['identity']) }
      growth = growth_entry_ids(ledger)
      l2_basis = basis.select { |b| b['layer'] == 'L2' }.to_h { |b| [b['id'], b] }
      provider = knowledge_provider
      records = identity_records(ledger)
      # The kind follows where an entry came from: learned when a cycle wrote
      # it or it came with its evidence, otherwise inherited when it does not
      # count, otherwise received when it came from outside, otherwise
      # owner-written. Whether it counts is its own field.
      eligible = basis.select { |b| b['layer'] == 'L1' && b['recorded'] }.sort_by { |b| b['id'] }.map do |b|
        evidence = carried_evidence(b['id'])
        outside = records[['L1', b['id']]].reverse.find { |r| r['content_sha256'] == b['content_sha256'] }&.dig('outside') == true
        kind = if growth.include?(b['id']) || evidence then 'learned'
               elsif !b['counted'] then 'inherited'
               elsif outside then 'received'
               else 'owner_written'
               end
        [b, kind, evidence && l2_basis[b['id']] ? evidence : nil]
      end
      # An entry goes in only when an importer can check its identity, by
      # the import rule and the importer's own check: a learned one by its
      # evidence, any other by its content. One that cannot be checked is
      # left out with the reason.
      unchecked = lambda do |b, kind, evidence|
        if kind == 'learned'
          next 'its evidence is absent, so an importer could not check it' unless evidence

          fault = autonomy.travelling_evidence_fault(id: b['id'], content: provider.get(b['id']).content, envelope: evidence,
                                                     l1_identity: b['identity'], l2_identity: l2_basis[b['id']]['identity'])
          fault && "#{fault}, so an importer could not check it"
        elsif b['identity'] != Progression.fingerprint(provider.get(b['id']).content)
          'its XP identity is not its content\'s, so an importer could not check it'
        end
      end
      wanted = eligible.select { |b, kind, _| inputs['includes'][kind] && (inputs['entry_ids'].nil? || inputs['entry_ids'].include?(b['id'])) }
      reasons = wanted.to_h { |b, kind, evidence| [b['id'], unchecked.call(b, kind, evidence)] }
      chosen = wanted.reject { |b, _| reasons[b['id']] }
      unknown = Array(inputs['entry_ids']) - wanted.map { |b, _| b['id'] }
      raise Error, "Not exportable under the chosen kinds: #{unknown.join(', ')}" unless unknown.empty?

      basis_item = ->(b) { { 'id' => b['id'], 'layer' => b['layer'], 'identity' => b['identity'], 'counted' => effective.call(b), 'holds' => b['holds'] } }
      entries = []
      xp = []
      chosen.each do |b, kind, evidence|
        item = provider.get(b['id'])
        entry = { 'id' => b['id'], 'title' => item.description.to_s, 'content' => item.content.to_s, 'kind' => kind }
        xp << basis_item.call(b)
        if kind == 'learned'
          entry['evidence'] = evidence
          xp << basis_item.call(l2_basis[b['id']])
        end
        entries << entry
      end
      doc = { 'format' => Exchange::FORMAT, 'version' => Exchange::VERSION, 'renderer' => Autonomy::KNOWLEDGE_RENDERER,
              'source' => { 'identity' => identity(ledger), 'name' => name, 'ledger_head' => inputs['ledger_head'], 'exported_at' => inputs['exported_at'] },
              'includes' => inputs['includes'], 'pieces' => exchange_pieces(ledger), 'entries' => entries, 'xp_basis' => xp,
              'lineage' => exchange_lineage(ledger) }
      doc['manifest_sha256'] = Exchange.manifest(doc)
      taken = Set.new(chosen.map { |b, _| b['id'] })
      left = eligible.reject { |b, _| taken.include?(b['id']) }.map do |b, kind, _|
        { 'id' => b['id'], 'kind' => kind, 'title' => provider.get(b['id']).description.to_s }.merge(reasons[b['id']] ? { 'reason' => reasons[b['id']] } : {})
      end
      left_out = { 'entries' => left, 'observations' => observation_entries.length - entries.count { |e| e['evidence'] },
                   'chat_memories' => verified_chat_entries.length,
                   'never' => 'Chat memories, growth state, backups, the ledger, the companion\'s direction and personality settings, ' \
                              'composition material and host references never go in.' }
      [doc, left_out]
    end

    # This individual's lineage and the ancestry it received, nearest first.
    def exchange_lineage(ledger)
      Records.of_type(ledger, 'kairomone_lineage').reverse.flat_map do |r|
        [{ 'kind' => r['kind'].to_s, 'sources' => Array(r['sources']).map { |s| s.slice('identity', 'name') } }] + Array(r['ancestry'])
      end.first(Exchange::PIECES_MAX)
    end

    # The current profile's fields, the accepted professions with every
    # ancestor present (so the lineage reads the same where they arrive), and
    # the accepted drawings that pass the art check now, each with the stage
    # it answers. Material hashes stay. More than an import reads is not cut
    # here: the preview refuses it (Exchange.load).
    def exchange_pieces(ledger)
      current = current_profile_piece(ledger)
      profile = if current then current[:piece].slice(*Exchange::PROFILE_FIELDS)
                elsif (legacy = legacy_profile) then { 'name' => legacy['display_name'], 'kind' => 'unknown' }
                end
      accepted = Records.of_type(ledger, 'kairomone_profession').map { |r| r['sha256'] }.uniq
      professions = profession_ancestry(accepted, limit: Exchange::PIECES_MAX + 1).map do |sha, piece|
        { 'sha256' => sha }.merge(piece.slice(*Exchange::PROFESSION_FIELDS))
      end
      stages = Records.of_type(ledger, 'kairomone_art').to_h { |r| [r['sha256'], r['stage']] }
      art = stages.filter_map do |sha, stage|
        text = art_text(sha)
        text && Art.valid?(text) ? { 'sha256' => sha, 'svg' => text, 'stage' => stage.to_s } : nil
      end
      { 'profile' => profile, 'professions' => professions, 'art' => art }
    end

    # A growth entry's evidence without its request (no topic, no direction).
    def carried_evidence(id)
      entry = context_manager.get_context(L2_SESSION, id) or return nil
      envelope = JSON.parse(entry.content)
      return nil unless envelope.is_a?(Hash) && %w[untrusted_research_evidence].include?(envelope['kind']) && envelope['l1_id'] == id

      envelope.slice('kind', 'evidence', 'evidence_sha256', 'l1_id')
    rescue JSON::ParserError
      nil
    end

    def growth_entry_ids(ledger)
      ids = Records.of_type(ledger, 'kairomone_growth_completed').map { |r| r['l1_id'] }
      legacy = autonomy.send(:legacy_state)
      ids += legacy['requests'].values.select { |r| r['state'] == 'completed' }.map { |r| r.dig('result', 'l1_id') } if legacy
      ids.compact
    end

    # One page of a preview, read from the page the preview wrote for it.
    def exchange_preview_page(sha, page)
      raise Error, 'file_sha256 must be a sha256 hex digest' unless Progression::SHA.match?(sha.to_s)

      relative = "#{Exchange::PREVIEWS}/#{sha}"
      raise Error, 'No such preview (it expired or was used); preview again' unless File.file?(Paths.checked(host_root, "#{relative}.json"))
      raise Error, 'This preview expired; preview again' if File.mtime(Paths.checked(host_root, "#{relative}.json")) < Time.now - Exchange::PREVIEW_TTL

      inputs = JSON.parse(Paths.read(host_root, "#{relative}.json", limit: 4 * 1_048_576))
      raise Error, 'This preview is of another Kairomone' unless inputs['listing_id'] == listing_id

      pages = Array(inputs['pages'])
      raise Error, "page runs from 1 to #{pages.length}" if page > pages.length

      text = Paths.read(host_root, "#{relative}.p#{page}.json", limit: Exchange::FILE_LIMIT)
      raise Error, 'This preview page does not match its sha256; preview again' unless Digest::SHA256.hexdigest(text) == pages[page - 1]

      left_out = inputs['left_out']
      { success: true, kairomone: address, file_sha256: sha, bytes: inputs['bytes'], page: page, pages: pages.length, items: JSON.parse(text),
        left_out: left_out.reject { |k, _| k == 'entries' }.merge('entries' => left_out['entries'].length),
        note: 'Show the owner every page in full (later pages: preview with this file_sha256 and page). The file is written only by ' \
              'export with this file_sha256, and only while nothing on this Kairomone has changed since; the preview expires after 24 hours.' }
    end

    def exchange_pages(doc, left_out = [])
      items = [{ 'item' => 'source' }.merge(doc['source']), { 'item' => 'includes' }.merge(doc['includes'])]
      items << { 'item' => 'profile', 'fields' => doc['pieces']['profile'] } if doc['pieces']['profile']
      items += doc['pieces']['professions'].map { |p| { 'item' => 'profession' }.merge(p) }
      items += doc['pieces']['art'].map { |a| { 'item' => 'drawing' }.merge(a) }
      doc['entries'].each do |e|
        items << { 'item' => 'entry' }.merge(e.reject { |k, _| k == 'evidence' })
        items << { 'item' => 'evidence', 'id' => e['id'] }.merge(e['evidence']) if e['evidence']
      end
      items += doc['lineage'].map { |l| { 'item' => 'lineage' }.merge(l) }
      items += left_out.map { |e| { 'item' => 'left_out' }.merge(e) }
      pages = [[]]
      size = 0
      items.each do |item|
        bytes = JSON.generate(item).bytesize
        if size + bytes > Exchange::PAGE_BYTES && !pages.last.empty?
          pages << []
          size = 0
        end
        pages.last << item
        size += bytes
      end
      pages
    end

    # A received growth entry passes the same check the exporter ran.
    def received_evidence!(entry, evidence, l1, l2)
      fault = autonomy.travelling_evidence_fault(id: entry['id'], content: entry['content'], envelope: evidence,
                                                 l1_identity: l1['identity'], l2_identity: l2['identity'])
      raise Error, "#{entry['id']}: #{fault}; refused" if fault

      evidence
    end

    # Received pieces wait as proposals; one that does not read as a piece
    # by the current rules is skipped and reported.
    def received_pieces!(pieces, now)
      received = []
      skipped = []
      if (fields = pieces['profile'])
        begin
          piece = Profile.build(fields.is_a?(Hash) ? fields.slice(*Exchange::PROFILE_FIELDS) : {}, origin: 'import')
          ComposedText.guard!(Profile.texts(piece))
          sha = write_piece('proposals', { 'kind' => 'profile', 'piece' => piece, 'material_kind' => 'none', 'proposed_at' => now })
          received << { 'kind' => 'profile', 'proposal' => sha }
        rescue Error => e
          skipped << { 'kind' => 'profile', 'reason' => e.message }
        end
      end
      Array(pieces['professions']).each do |p|
        begin
          raise Error, 'not a profession' unless p.is_a?(Hash)

          # Rebuilt by the rules current now and kept only when the bytes are
          # the ones sent, so the sha256 its descendants name still finds it.
          piece = Profession.build(p.slice('name', 'description', 'focus', 'habits'), parents: p['parents'], tier: p['tier'], origin: p['origin'].to_s)
          raise Error, 'it does not match the sha256 it was sent with' unless Digest::SHA256.hexdigest(JSON.pretty_generate(piece) + "\n") == p['sha256']

          ComposedText.guard!(Profession.texts(piece))
          write_piece('professions', piece) # present for lineage; in force only by an acceptance record (Inv 4)
          sha = write_piece('proposals', { 'kind' => 'profession', 'piece' => piece, 'received_sha256' => p['sha256'], 'proposed_at' => now })
          received << { 'kind' => 'profession', 'proposal' => sha }
        rescue Error => e
          skipped << { 'kind' => 'profession', 'reason' => e.message }
        end
      end
      Array(pieces['art']).each do |a|
        begin
          text = Art.check!(a.is_a?(Hash) ? a['svg'] : nil)
          # Each drawing waits for the stage it answered where it was drawn.
          stage = Vocabulary.stage_rank(a['stage']).negative? ? 'egg' : a['stage']
          sha = write_piece('proposals', { 'kind' => 'art', 'svg' => text, 'sha256' => Digest::SHA256.hexdigest(text.b), 'stage' => stage, 'proposed_at' => now })
          received << { 'kind' => 'art', 'proposal' => sha }
        rescue Error => e
          skipped << { 'kind' => 'art', 'reason' => e.message }
        end
      end
      [received, skipped]
    end
  end

  class Host
    # Imports an exchange file the owner placed in kairomone-inbox/ as a new
    # individual listed under listing_id, which is also its new identity.
    def import_exchange(file:, listing_id:)
      raise Error, 'The exchange file is a basename ending in .kairomone-exchange.json' unless file.is_a?(String) && Exchange::NAME.match?(file)

      Paths.id!(listing_id)
      governed!('L1')
      doc = Exchange.load(Paths.read(host_root, "#{Exchange::INBOX}/#{file}", limit: Exchange::FILE_LIMIT))
      governed!('L2') if doc['entries'].any? { |e| e['evidence'] }
      raise Error, "An import is a new Kairomone: name it other than its source #{listing_id}" if doc['source']['identity'] == listing_id
      # Received pieces wait as proposals, which are L2 writes here (as every
      # proposal is); under a locked L2 the knowledge still comes in, the
      # pieces do not, and the result says so.
      keep_pieces = KairosMcp::SkillsConfig.layer_enabled?('L2') && KairosMcp::SkillsConfig.layer_mutable?('L2')
      with_registry_lock do
        outcome = nil
        path = assemble(listing_id) do |staged|
          outcome = staged.import_exchange_into!(doc, listing: listing_id, keep_pieces: keep_pieces)
          listing_id
        end
        made = Instance.new(host_root: host_root, root: path)
        { success: true, imported: true, kairomone: made.address, source: doc['source'].slice('identity', 'name'),
          entries: outcome[:entries], received: outcome[:received], skipped: outcome[:skipped],
          level: made.progression_status[:level],
          note: 'Received knowledge is outside content. The received profile, professions and drawings wait as proposals for the owner.' }
      end
    end

    private

    # Host governance applies to every new L1 and L2 write, as it does to
    # each individual's own writes.
    def governed!(*layers)
      layers.each do |layer|
        unless KairosMcp::SkillsConfig.layer_enabled?(layer) && KairosMcp::SkillsConfig.layer_mutable?(layer)
          raise Error, "Host governance disables or locks #{layer}"
        end
      end
    end

    def prune_exchange_previews!
      dir = Paths.checked(host_root, Exchange::PREVIEWS)
      return unless File.directory?(dir) && !File.symlink?(dir)

      Dir.children(dir).each do |name|
        path = File.join(dir, name)
        File.delete(path) if name.match?(Exchange::PREVIEW_FILE) && File.file?(path) && File.mtime(path) < Time.now - Exchange::PREVIEW_TTL
      rescue Errno::ENOENT
        next # pruned by a concurrent preview
      end
    end
  end
end
