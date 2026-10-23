# frozen_string_literal: true

# Kairomone 0.8, art (design log/kairomone_core_0_8_design_v0.6_FROZEN_20261023.md,
# Inv 4, Inv 6, M7, M8): a drawing waits as a proposal until the owner accepts
# it; the allowlist admits only static vector drawing and runs again whenever
# a drawing leaves; a drawing that fails it then is shown as the egg; pages
# show art only as an image. All data is synthetic and confined to temporary
# hosts.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'minitest/autorun'
require_relative 'templates/skillsets/kairomone/test/support_08'

class Kairomone08ArtTest < Minitest::Test
  include Kairomone08Support

  PROFILE = { 'name' => 'Momo', 'kind' => 'animal', 'kind_label' => 'Fox', 'appearance' => 'A small round fox with a notebook',
              'personality' => %w[curious gentle], 'voice' => 'Soft', 'interests' => %w[stories] }.freeze
  NS = 'xmlns="http://www.w3.org/2000/svg"'
  FOX = <<~SVG
    <?xml version="1.0" encoding="UTF-8"?>
    <svg #{NS} viewBox="0 0 200 200" width="200" height="200">
      <title>Momo the fox, marker-momo-drawing</title>
      <desc>A small round fox with a notebook &amp; a smile</desc>
      <defs>
        <radialGradient id="fur" cx="0.5" cy="0.4" r="0.6"><stop offset="0" stop-color="#f7b267"/><stop offset="1" stop-color="rgb(230, 120, 60)"/></radialGradient>
        <clipPath id="face"><circle cx="100" cy="110" r="60"/></clipPath>
      </defs>
      <!-- body -->
      <g transform="translate(0 4) rotate(-3 100 100)" clip-path="url(#face)">
        <ellipse cx="100" cy="110" rx="70" ry="60" fill="url(#fur)" stroke="#5a3a22" stroke-width="3"/>
        <polygon points="50,60 70,20 85,62" fill="#e07a3f"/><polyline points="1,2 3,4" fill="none" stroke="#000"/>
        <rect x="80" y="140" width="40" height="30" rx="4" fill="#fff8e7"/><line x1="85" y1="150" x2="115" y2="150" stroke="#9cad7e"/>
        <path d="M90 120q10 8 20 0" fill="none" stroke="#3d3a33" stroke-linecap="round"/>
      </g>
    </svg>
  SVG

  def setup = fresh_host
  def teardown = FileUtils.remove_entry_secure(@host)

  def create(id = 'momo')
    Kairomone::Host.new.create(listing_id: id, profile: PROFILE, profession: { 'template' => 'researcher' }, material_kind: 'free_text')
    Kairomone::Instance.new(host_root: @host, kairomone: id)
  end

  def grow_to(store, level)
    n = 0
    n += 1 while store.progression_status[:level] < level && store.create_knowledge(id: "fact_#{n}", title: "Fact #{n}", content: "Distinct fact #{n}")
  end

  def svg(inner, attributes: '') = %(<svg #{NS} viewBox="0 0 10 10"#{attributes}>#{inner}</svg>)

  def refused?(text)
    Kairomone::Art.check!(text)
    false
  rescue Kairomone::Error
    true
  end

  def test_the_egg_and_a_typical_drawing_pass
    assert Kairomone::Art.valid?(Kairomone::Art::EGG)
    assert Kairomone::Art.valid?(FOX)
    # The bounds are inclusive: 32 levels with the root, 4,000 elements, 64 KiB.
    assert Kairomone::Art.valid?(svg((1..31).reduce('') { |inner, _| "<g>#{inner}</g>" }))
    assert Kairomone::Art.valid?(svg('<g/>' * 3_999))
    filler = svg('<desc></desc>')
    assert Kairomone::Art.valid?(svg("<desc>#{'a' * (65_536 - filler.bytesize)}</desc>"))
  end

  def test_each_forbidden_construct_is_refused
    nested = (1..33).reduce('<rect width="1" height="1"/>') { |inner, _| "<g>#{inner}</g>" }
    crowded = '<g/>' * 4_000 # with the root, one element too many, in 16 KB
    forbidden = {
      'UTF-16 with a byte order mark' => "\xFF\xFE".b + svg('').encode('UTF-16LE').b,
      'UTF-16 without one' => svg('').encode('UTF-16BE').b,
      'a UTF-8 byte order mark' => "\xEF\xBB\xBF" + svg(''),
      'a document type' => "<!DOCTYPE svg>#{svg('')}",
      'an entity declaration' => %(<!DOCTYPE svg [<!ENTITY a "b">]>#{svg('<title>&a;</title>')}),
      'a stylesheet instruction' => %(<?xml-stylesheet href="https://example.com/a.css"?>#{svg('')}),
      'a foreign namespace' => svg('<x:a xmlns:x="urn:x"/>'),
      'a declared second namespace' => svg('', attributes: ' xmlns:xlink="http://www.w3.org/1999/xlink"'),
      'an unprefixed foreign element' => %(<svg #{NS} viewBox="0 0 10 10"><a xmlns="http://www.w3.org/1999/xhtml"/></svg>),
      'href' => svg('<path d="M0 0" href="https://example.com"/>'),
      'xlink:href' => svg('<path d="M0 0" xlink:href="#a"/>', attributes: ' xmlns:xlink="http://www.w3.org/1999/xlink"'),
      'a style element' => svg('<style>path{fill:red}</style>'),
      'a style attribute' => svg('<path d="M0 0" style="fill:red"/>'),
      'an event handler' => svg('', attributes: ' onload="alert(1)"'),
      'a script' => svg('<script>alert(1)</script>'),
      'an image' => svg('<image width="1" height="1"/>'),
      'foreignObject' => svg('<foreignObject/>'),
      'text' => svg('<text>hello</text>'),
      'loose text' => svg('<g>hello</g>'),
      'an outside url' => svg('<path d="M0 0" fill="url(https://example.com/a.svg#x)"/>'),
      'a url to a missing id' => svg('<path d="M0 0" fill="url(#missing)"/>'),
      'a url hidden in a character reference' => svg('<path d="M0 0" fill="&#117;rl(https://example.com/a)"/>'),
      'a CSS escape' => svg('<path d="M0 0" fill="\\75 rl(https://example.com/a)"/>'),
      'any CSS escape, values being read as written' => svg('<path d="M0 0" fill="re\\64"/>'),
      'an allowed name in another namespace' => svg('<g xmlns="urn:x"/>'),
      'an unknown function' => svg('<path d="M0 0" fill="image(https://example.com/a)"/>'),
      'excess depth' => svg(nested),
      'too many elements' => svg(crowded),
      'too many bytes' => svg("<desc>#{'a' * 65_536}</desc>"),
      'no viewBox' => %(<svg #{NS}/>),
      'no namespace' => '<svg viewBox="0 0 10 10"/>',
      'a zero-sized viewBox' => %(<svg #{NS} viewBox="0 0 0 10"/>),
      'another root' => %(<g #{NS}/>),
      'text beside the root' => "#{svg('')}trailing",
      'a reused id' => svg('<g id="a"/><g id="a"/>'),
      'not XML' => '<svg'
    }
    forbidden.each { |what, text| assert refused?(text), "#{what} must be refused" }
  end

  def test_a_proposal_changes_nothing_until_the_owner_accepts_it
    store = create
    proposed = store.propose_art(svg: FOX)
    assert_equal 'egg', store.art_get[:shown]
    assert_equal [], Kairomone::Records.of_type(store.chain, 'kairomone_art')
    accepted = store.accept_art(proposal: proposed[:proposal])
    assert_equal proposed[:sha256], accepted[:sha256]
    shown = store.art_get
    assert_equal ['drawing', proposed[:sha256], FOX], shown.values_at(:shown, :sha256, :svg)
    refute shown.key?(:data_uri), 'the drawing leaves once, as markup'
    assert_equal :svg, shown.keys.last, 'the markup comes after what describes it'
    record = Kairomone::Records.of_type(store.chain, 'kairomone_art').last
    assert_equal({ 'sha256' => proposed[:sha256], 'origin' => 'proposal', 'stage' => 'egg' }, record.slice('sha256', 'origin', 'stage'))
    again = store.accept_art(proposal: proposed[:proposal])
    assert again[:preserved]
    assert_equal 1, Kairomone::Records.of_type(store.chain, 'kairomone_art').length
    assert_raises(Kairomone::Error) { store.propose_art(svg: svg('<script/>')) }
  end

  def test_a_drawing_that_fails_the_check_now_is_shown_as_the_egg_and_not_given_out
    store = create
    good = store.accept_art(proposal: store.propose_art(svg: FOX)[:proposal])[:sha256]
    crafted = svg('<path d="M0 0"/><script>alert(1)</script>')
    sha = Digest::SHA256.hexdigest(crafted)
    store.send(:with_lock) do
      Kairomone::Paths.write(store.root, "art/#{sha}.svg", crafted)
      Kairomone::Records.append!(store.chain, [{ 'type' => 'kairomone_art', 'sha256' => sha, 'origin' => 'import', 'stage' => 'egg' }], -> { store.chain })
    end
    shown = store.art_get
    assert_equal ['drawing', good], shown.values_at(:shown, :sha256), 'the latest drawing that passes is shown'
    assert_equal sha, shown.dig(:refused, :sha256)
    error = assert_raises(Kairomone::Error) { store.art_get(sha256: sha) }
    assert_match(/not given out/, error.message)
    File.write(File.join(store.root, "art/#{good}.svg"), File.read(File.join(store.root, "art/#{good}.svg")).sub('<title>', '<image href="x"/><title>'))
    assert_equal 'egg', store.art_get[:shown], 'a drawing whose bytes changed is not present'
    html = File.read(store.status(render_html: true)[:html_path])
    refute_includes html, Base64.strict_encode64(crafted)
    assert_includes html, Base64.strict_encode64(Kairomone::Art::EGG)
  end

  def test_drawings_are_listed_by_reference_and_one_that_fails_is_not_accepted
    store = create
    good = store.propose_art(svg: FOX)[:proposal]
    bad = svg('<script/>')
    store.send(:with_lock) do
      store.send(:write_piece, 'proposals', { 'kind' => 'art', 'svg' => bad, 'sha256' => Digest::SHA256.hexdigest(bad), 'stage' => 'egg', 'proposed_at' => Time.now.utc.iso8601 })
    end
    listed = store.proposals[:proposals].select { |p| p['kind'] == 'art' }
    assert_equal 2, listed.length
    listed.each { |p| refute p.key?('svg'), 'no markup in the list' }
    assert_equal FOX.bytesize, listed.find { |p| p['proposal'] == good }['bytes']
    refused = listed.find { |p| p['proposal'] != good }['proposal']
    assert_raises(Kairomone::Error) { store.accept_art(proposal: refused) }
    html = File.read(store.status(render_html: true)[:html_path])
    payload = JSON.parse(html[%r{<script id="kairomone-status" type="application/json">(.*?)</script>}m, 1])
    assert_equal [good], payload.dig('art', 'waiting').map { |w| w['proposal'] }, 'only a drawing that passes reaches the page'
  end

  def test_a_drawing_waiting_behind_many_profile_drafts_still_reaches_the_page
    store = create
    # Proposed before the twelve drafts that follow it.
    drawing = store.send(:with_lock) do
      store.send(:write_piece, 'proposals', { 'kind' => 'art', 'svg' => FOX, 'sha256' => Digest::SHA256.hexdigest(FOX), 'stage' => 'egg',
                                              'proposed_at' => '2026-01-01T00:00:00Z' })
    end
    12.times { |i| store.propose_profile(fields: PROFILE.merge('name' => "Draft #{i}")) }
    listed = store.proposals
    assert_equal 13, listed[:waiting_total]
    refute_includes listed[:proposals].map { |p| p['proposal'] }, drawing, 'the list shows the ten newest of thirteen'
    html = File.read(store.status(render_html: true)[:html_path])
    payload = JSON.parse(html[%r{<script id="kairomone-status" type="application/json">(.*?)</script>}m, 1])
    assert_equal [drawing], payload.dig('art', 'waiting').map { |w| w['proposal'] }
  end

  def test_a_drawing_at_the_size_bound_goes_through_every_path
    store = create
    big = svg("<desc>#{'a' * (65_536 - svg('<desc></desc>').bytesize)}</desc>")
    assert_equal 65_536, big.bytesize
    sha = store.accept_art(proposal: store.propose_art(svg: big)[:proposal])[:sha256]
    named = store.art_get(sha256: sha)
    assert_equal big, named[:svg]
    refute named.key?(:data_uri), 'the drawing leaves once, as markup'
    assert_equal ['drawing', sha], store.art_get.values_at(:shown, :sha256)
    html = File.read(store.status(render_html: true)[:html_path])
    assert_includes html, Base64.strict_encode64(big)
  end

  def test_art_is_due_at_hatch_and_at_each_later_stage
    store = create
    refute store.art_get[:due], 'an egg needs no drawing'
    grow_to(store, 5)
    view = store.art_get
    assert_equal ['hatchling', true], view.values_at(:stage, :due)
    early = store.propose_art(svg: FOX)[:proposal]
    store.accept_art(proposal: store.propose_art(svg: Kairomone::Art::EGG)[:proposal])
    refute store.art_get[:due]
    assert_equal 'hatchling', Kairomone::Records.of_type(store.chain, 'kairomone_art').last['stage']
    grow_to(store, 20)
    assert store.art_get[:due], 'young needs its own drawing'
    # A drawing proposed at hatch and accepted now answers the stage it is
    # accepted at.
    store.accept_art(proposal: early)
    assert_equal 'young', Kairomone::Records.of_type(store.chain, 'kairomone_art').last['stage']
    refute store.art_get[:due]
  end

  def test_the_page_shows_art_only_as_an_image
    store = create
    store.accept_art(proposal: store.propose_art(svg: FOX)[:proposal])
    waiting = store.propose_art(svg: Kairomone::Art::EGG.sub('Kairomone egg', 'Second drawing'))[:proposal]
    status = store.status
    assert_equal 'drawing', status[:art][:shown]
    refute status[:art].key?(:data_uri), 'the JSON status carries no image'
    rendered = store.status(render_html: true)
    assert_equal %i[shown sha256 stage due], rendered[:art].keys, 'the page has the images; the result names them'
    html = File.read(rendered[:html_path])
    assert_includes html, "img-src data:;"
    payload = JSON.parse(html[%r{<script id="kairomone-status" type="application/json">(.*?)</script>}m, 1])
    assert_equal "data:image/svg+xml;base64,#{Base64.strict_encode64(FOX)}", payload.dig('art', 'data_uri')
    assert_equal [waiting], payload.dig('art', 'waiting').map { |w| w['proposal'] }
    refute_includes html, 'marker-momo-drawing', 'no drawing markup on the page'
    refute_match(/<img[^>]*\bsrc=/, html.gsub(%r{<script\b.*?</script>}m, ''), 'the template sets no image source itself')
  end

  def test_a_drawing_travels_in_a_backup
    store = create
    sha = store.accept_art(proposal: store.propose_art(svg: FOX)[:proposal])[:sha256]
    store.restore_backup(file: store.create_backup[:file], target_id: 'twin')
    twin = Kairomone::Instance.new(host_root: @host, kairomone: 'twin')
    assert_equal ['drawing', sha], twin.art_get.values_at(:shown, :sha256)
  end

  def test_the_tool_proposes_accepts_and_gets
    create
    proposed = tool('Art', { 'command' => 'propose', 'svg' => FOX })
    assert proposed['success'], proposed['error']
    assert tool('Art', { 'command' => 'accept', 'proposal' => proposed['proposal'] })['accepted']
    got = tool('Art', { 'command' => 'get' })
    assert_equal ['drawing', FOX], got.values_at('shown', 'svg')
    refused = tool('Art', { 'command' => 'propose', 'svg' => svg('<script/>') })
    refute refused['success']
  end
end
