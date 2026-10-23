# frozen_string_literal: true

module Kairomone
  # Art is inert (design v0.6 Inv 6, M8): a drawing is static vector markup
  # that runs, reacts and refers to nothing outside itself. The check below is
  # an allowlist, run when a drawing is proposed, when it is accepted and each
  # time it leaves (a page, kairomone_art get); a drawing
  # that fails it then is not given out and the built-in egg is shown. Pages
  # show art only as an image (a data: URI), never as markup.
  module Art
    SVG_NS = 'http://www.w3.org/2000/svg'
    MAX_BYTES = 64 * 1024
    MAX_DEPTH = 32
    MAX_ELEMENTS = 4_000
    ELEMENTS = %w[svg g path circle ellipse rect line polyline polygon defs linearGradient radialGradient stop clipPath title desc].freeze
    TEXT_ELEMENTS = %w[title desc].freeze
    # Geometric and presentation attributes, the id that url(#…) names, and
    # the version. No style, href, event handler or class.
    ATTRIBUTES = %w[
      id version viewBox preserveAspectRatio width height x y x1 y1 x2 y2 cx cy r rx ry fx fy fr d points pathLength
      transform offset gradientUnits gradientTransform spreadMethod clipPathUnits
      fill fill-opacity fill-rule stroke stroke-width stroke-opacity stroke-linecap stroke-linejoin stroke-miterlimit
      stroke-dasharray stroke-dashoffset opacity clip-path clip-rule stop-color stop-opacity color display visibility
      paint-order vector-effect shape-rendering
    ].freeze
    # Functions an attribute value may call: colours, transforms and url(#id).
    FUNCTIONS = %w[url rgb rgba hsl hsla matrix translate scale rotate skewx skewy].freeze
    ID = /\A[A-Za-z_][A-Za-z0-9_.-]{0,63}\z/
    DECLARATION = /\A<\?xml\s+version\s*=\s*["']1\.[0-9]["'](?:\s+encoding\s*=\s*["']utf-8["'])?(?:\s+standalone\s*=\s*["'](?:yes|no)["'])?\s*\?>/i

    # The built-in egg: shown until a drawing is accepted, and in place of one
    # that fails the check. It passes the check itself.
    EGG = <<~SVG.strip.freeze
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 140"><title>Kairomone egg</title><ellipse cx="60" cy="130" rx="34" ry="6" fill="#d9d3c3"/><path d="M60 8C32 8 16 52 16 82c0 27 19 44 44 44s44-17 44-44C104 52 88 8 60 8Z" fill="#f6f0df" stroke="#8a7f68" stroke-width="3"/><path d="M28 66l10-8 11 8 11-8 11 8 11-8 10 8" fill="none" stroke="#9cad7e" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><ellipse cx="46" cy="88" rx="3.5" ry="4.5" fill="#3d3a33"/><ellipse cx="74" cy="88" rx="3.5" ry="4.5" fill="#3d3a33"/><path d="M54 98q6 5 12 0" fill="none" stroke="#3d3a33" stroke-width="2.5" stroke-linecap="round"/><ellipse cx="38" cy="98" rx="6" ry="3" fill="#f0b9a8"/><ellipse cx="82" cy="98" rx="6" ry="3" fill="#f0b9a8"/></svg>
    SVG

    module_function

    # The drawing's UTF-8 text, or an Error naming the first rule it breaks.
    def check!(value)
      raise Error, 'A drawing is SVG text' unless value.is_a?(String)

      bytes = value.b
      raise Error, "A drawing is at most #{MAX_BYTES} bytes" if bytes.bytesize > MAX_BYTES
      raise Error, 'A drawing is UTF-8 without a byte order mark' if bytes.start_with?("\xEF\xBB\xBF".b, "\xFE\xFF".b, "\xFF\xFE".b) || bytes.include?("\x00".b)

      text = bytes.dup.force_encoding(Encoding::UTF_8)
      raise Error, 'A drawing is UTF-8 without a byte order mark' unless text.valid_encoding?

      body = text.sub(DECLARATION, '')
      raise Error, 'A drawing has no processing instructions' if body.include?('<?')
      raise Error, 'A drawing has no document type or declarations' if body.match?(/<!(?!--|\[CDATA\[)/)

      # Loaded here, so a Ruby without the rexml gem loses only drawings.
      begin
        require 'rexml/document'
      rescue LoadError
        raise Error, 'Drawings need the rexml gem, which this Ruby does not provide; art is unavailable on this host'
      end
      document = begin
        REXML::Document.new(text)
      rescue StandardError => e
        raise Error, "A drawing must parse as XML (#{e.message.lines.first.to_s.strip})"
      end
      root = document.root or raise Error, 'A drawing has an svg root element'
      raise Error, 'A drawing has an svg root element' unless root.name == 'svg'
      # REXML refuses anything beside the root but the declaration, comments
      # and white space; the walk below starts at the root.

      viewbox = root.attributes['viewBox'].to_s.strip.split(/[\s,]+/)
      unless viewbox.length == 4 && viewbox.all? { |n| n.match?(/\A-?(?:\d+\.?\d*|\.\d+)\z/) } && viewbox[2].to_f.positive? && viewbox[3].to_f.positive?
        raise Error, 'A drawing needs a viewBox of four numbers with a positive width and height'
      end

      ids = []
      references = []
      count = 0
      walk = lambda do |element, depth|
        raise Error, "A drawing nests at most #{MAX_DEPTH} deep" if depth > MAX_DEPTH

        count += 1
        raise Error, "A drawing has at most #{MAX_ELEMENTS} elements" if count > MAX_ELEMENTS
        unless element.prefix.to_s.empty? && element.namespace == SVG_NS && ELEMENTS.include?(element.name)
          raise Error, "A drawing has no #{element.expanded_name} element"
        end

        element.attributes.each_attribute do |attribute|
          name = attribute.expanded_name
          next if name == 'xmlns' # any other default namespace fails the element check
          raise Error, "A drawing has no #{name} attribute" unless attribute.prefix.to_s.empty? && ATTRIBUTES.include?(name)

          value = attribute.value
          raise Error, "The #{name} attribute holds no escapes" if value.include?('\\')
          value.scan(/([A-Za-z_-]+)\s*\(/) do |(function)|
            raise Error, "The #{name} attribute calls no #{function}()" unless FUNCTIONS.include?(function.downcase)
          end
          if value.match?(/url\s*\(/i)
            targets = value.scan(/url\s*\(\s*#([^)\s]*)\s*\)/i).flatten
            raise Error, "The #{name} attribute refers only to ids inside the drawing" unless targets.length == value.scan(/url\s*\(/i).length
            references.concat(targets)
          end
          if name == 'id'
            raise Error, 'An id is a short name' unless ID.match?(value)
            ids << value
          end
        end

        element.children.each do |child|
          case child
          when REXML::Element then walk.call(child, depth + 1)
          when REXML::Text
            next if child.value.strip.empty? || TEXT_ELEMENTS.include?(element.name)

            raise Error, 'A drawing holds text only in title and desc'
          when REXML::Comment then next
          else raise Error, "A drawing has no #{child.class.name.split('::').last.downcase} node"
          end
        end
      end
      walk.call(root, 1)
      raise Error, 'An id is used once' unless ids.uniq.length == ids.length
      missing = references.uniq - ids
      raise Error, "url(##{missing.first}) names no id inside the drawing" unless missing.empty?

      text
    end

    def valid?(value)
      check!(value)
      true
    rescue Error
      false
    end

    def data_uri(text) = "data:image/svg+xml;base64,#{Base64.strict_encode64(text.b)}"
  end

  class Instance
    # The composer draws; the drawing waits as a proposal until the owner
    # accepts it (Inv 4). It is checked before it is stored.
    def propose_art(svg:)
      text = Art.check!(svg)
      with_lock do
        ensure_writable!('L2')
        stage = Vocabulary.stage(progression_status[:level])['id']
        proposal = write_piece('proposals', { 'kind' => 'art', 'svg' => text, 'sha256' => Digest::SHA256.hexdigest(text.b),
                                              'stage' => stage, 'proposed_at' => Time.now.utc.iso8601 })
        { success: true, proposal: proposal, sha256: Digest::SHA256.hexdigest(text.b), stage: stage, kairomone: address,
          note: 'The owner sees a waiting drawing as an image on the status page (kairomone_status render_html). ' \
                'It takes effect only when they accept it (kairomone_art accept).' }
      end
    end

    # The owner accepts a proposed drawing: checked again by the rules current
    # now, written as art/<sha256>.svg, then its acceptance record appended
    # with the stage it is accepted at, the stage it answers (M7). Accepting
    # the same proposal again changes nothing.
    def accept_art(proposal:)
      raise Error, 'proposal must be a proposal sha256' unless Progression::SHA.match?(proposal.to_s)

      with_lock do
        ensure_writable!('L2')
        ledger = chain
        if (prior = Records.of_type(ledger, 'kairomone_art').find { |r| r['proposal_sha256'] == proposal })
          next { success: true, accepted: true, preserved: true, sha256: prior['sha256'], art: art_view(ledger), kairomone: address }
        end
        doc = read_proposal(proposal) or raise Error, 'No such proposal'
        raise Error, 'This proposal is not a drawing' unless doc['kind'] == 'art'

        text = Art.check!(doc['svg'])
        sha = Digest::SHA256.hexdigest(text.b)
        raise Error, 'The proposed drawing does not match its hash' unless sha == doc['sha256']

        relative = "art/#{sha}.svg"
        if File.exist?(Paths.checked(root, relative))
          raise Error, "#{relative} holds other bytes" unless Paths.read(root, relative, limit: Art::MAX_BYTES) == text.b
        else
          Paths.write(root, relative, text)
        end
        level = progression_status(ledger)[:level]
        Records.append!(ledger, [{ 'type' => 'kairomone_art', 'sha256' => sha, 'origin' => 'proposal', 'proposal_sha256' => proposal,
                                   'stage' => Vocabulary.stage(level)['id'] }], -> { chain })
        { success: true, accepted: true, sha256: sha, art: art_view(chain, level: level), kairomone: address }
      end
    end

    # A drawing as it leaves: the one named (it must be accepted and pass the
    # check now), or the one shown, which is the egg in place of one that
    # fails. The markup comes last; pages build their image from it.
    def art_get(sha256: nil)
      ensure_initialized!
      ledger = chain
      if sha256
        raise Error, 'sha256 must be a drawing sha256' unless Progression::SHA.match?(sha256.to_s)
        raise Error, 'No accepted drawing has this sha256' unless Records.of_type(ledger, 'kairomone_art').any? { |r| r['sha256'] == sha256 }

        text = art_text(sha256) or raise Error, 'This drawing is not present'
        begin
          Art.check!(text)
        rescue Error => e
          raise Error, "This drawing does not pass the art check now and is not given out (#{e.message})"
        end
        return { success: true, kairomone: address, shown: 'drawing', sha256: sha256, svg: text }
      end
      view, text = art_shown(ledger)
      { success: true, kairomone: address }.merge(view).merge(svg: text)
    end

    # What is shown: the latest accepted drawing that is present and passes
    # the check now, else the egg; and whether a drawing is due (at hatch and
    # at each later stage, M7).
    def art_view(ledger = chain, level: nil) = art_shown(ledger, level).first

    private

    # [view, the text shown]: the text is the one that passed the check. A
    # drawing is due unless the one shown was accepted at the current stage;
    # an accepted drawing that is absent or fails the check answers nothing.
    def art_shown(ledger, level = nil)
      stage = Vocabulary.stage(level || progression_status(ledger)[:level])['id']
      view = { shown: 'egg', sha256: nil, stage: stage, due: stage != 'egg' }
      Records.of_type(ledger, 'kairomone_art').reverse_each do |record|
        text = art_text(record['sha256']) or next
        begin
          Art.check!(text)
        rescue Error => e
          view[:refused] ||= { sha256: record['sha256'], reason: e.message }
          next
        end
        return [view.merge(shown: 'drawing', sha256: record['sha256'], due: stage != 'egg' && record['stage'] != stage), text]
      end
      [view, Art::EGG]
    end

    # A drawing stops waiting once a drawing is accepted for its stage or a
    # later one; it can still be accepted by name.
    def art_superseded?(doc, ledger)
      rank = Vocabulary.stage_rank(doc['stage'])
      Records.of_type(ledger, 'kairomone_art').any? { |r| Vocabulary.stage_rank(r['stage']) >= rank }
    end

    # What a page shows: the drawing as a data: image, and the newest
    # drawings waiting for the owner that pass the check now.
    def art_page(ledger, level, limit: 3)
      view, text = art_shown(ledger, level)
      answered = Records.of_type(ledger, 'kairomone_art').filter_map { |r| r['proposal_sha256'] }
      waiting = piece_files('proposals').filter_map do |sha|
        next if answered.include?(sha)

        doc = read_proposal(sha)
        [sha, doc] if doc && doc['kind'] == 'art' && !art_superseded?(doc, ledger)
      end
      shown = waiting.sort_by { |sha, doc| [doc['proposed_at'].to_s, sha] }.reverse.lazy
                     .select { |_sha, doc| Art.valid?(doc['svg']) }.first(limit)
                     .map { |sha, doc| { proposal: sha, stage: doc['stage'], data_uri: Art.data_uri(doc['svg']) } }
      view.merge(data_uri: Art.data_uri(text), waiting: shown)
    end

    def art_text(sha)
      return nil unless Progression::SHA.match?(sha.to_s)

      relative = "art/#{sha}.svg"
      return nil unless File.file?(Paths.checked(root, relative))

      bytes = Paths.read(root, relative)
      return nil unless Digest::SHA256.hexdigest(bytes) == sha

      bytes.force_encoding(Encoding::UTF_8)
    rescue Error
      nil # unreadable as a regular file of bounded size: not present
    end
  end
end
