# frozen_string_literal: true

# Kairomone 0.8, the console (design log/kairomone_core_0_8_design_v0.6_FROZEN_20261023.md,
# Inv 10, M2, M3, M12): the console still writes nothing; it lists the
# individuals and, for the one the page asks for, shows its status, its
# drawing as an image and what waits for the owner, with the IDs and hashes
# the page places; the page's placed text names the individual and carries
# no acceptance or consent; the page names every tool M3 lists. Runs without
# loopback servers or processes. All data is synthetic and confined to
# temporary hosts.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'minitest/autorun'
require_relative 'templates/skillsets/kairomone/test/support_08'
require 'kairomone/console'

class Kairomone08ConsoleTest < Minitest::Test
  include Kairomone08Support

  PAGE = File.expand_path('templates/skillsets/kairomone/assets/console.html', __dir__)
  PROFILE = { 'name' => 'Momo', 'kind' => 'animal', 'kind_label' => 'Fox', 'appearance' => 'A small round fox',
              'personality' => %w[curious], 'voice' => 'Soft', 'interests' => %w[stories] }.freeze
  ACCEPTANCE = /受け入れ|受入|承認|承諾|同意|許可|了承|決定|選ぶ|選び|選択|にします|accept|approv|consent|agree|confirm|choose|choice|allow/i

  Res = Struct.new(:status, :body, :keep_alive) do
    def []=(_name, _value); end
  end
  Req = Struct.new(:query)

  def setup = fresh_host
  def teardown = FileUtils.remove_entry_secure(@host)

  def create(id, name = id.capitalize)
    Kairomone::Host.new.create(listing_id: id, profile: PROFILE.merge('name' => name), profession: { 'template' => 'researcher' }, material_kind: 'free_text')
    Kairomone::Instance.new(host_root: @host, kairomone: id)
  end

  def view(kairomone = nil) = JSON.parse(JSON.generate(Kairomone::Console::View.payload(@host, kairomone)))

  def script = File.read(PAGE)[%r{<script>(.*)</script>}m, 1]

  # The PLACE table of the page: key => template.
  def place_table
    body = script[/var PLACE = \{(.*?)\n  \};/m, 1] or flunk 'the page has no PLACE table'
    body.scan(/^\s+(\w+): '([^']*)'/).to_h
  end

  def test_the_page_lists_every_individual_and_shows_the_one_it_asks_for
    create('momo')
    create('pip', 'Pip')
    first = view
    assert_equal %w[momo pip], first['kairomones'].map { |k| k['listing_id'] }
    assert_equal 'momo', first['shown'], 'without a choice the page shows the first listed'
    assert_equal 'momo', first.dig('status', 'kairomone', 'listing_id')
    other = view('pip')
    assert_equal ['pip', 'Pip'], [other['shown'], other.dig('status', 'profile', 'display_name')]
    gone = view('nobody')
    assert_equal ['momo', 'nobody is not listed on this host; showing momo'], gone.values_at('shown', 'notice'), 'an ID no longer listed falls back'
    assert_equal 'momo', view('../momo')['shown']
  end

  def test_a_failure_for_the_one_shown_still_lists_every_individual
    create('momo')
    create('pip', 'Pip')
    original = Kairomone::Console::View.method(:waiting)
    Kairomone::Console::View.define_singleton_method(:waiting) { |*| raise Kairomone::Error, 'a damaged proposal' }
    payload = view('pip')
    assert_equal [%w[momo pip], 'pip', nil], [payload['kairomones'].map { |k| k['listing_id'] }, payload['shown'], payload['waiting']]
    assert_match(/a damaged proposal/, payload['error'])
    assert_equal 'Pip', payload.dig('status', 'profile', 'display_name'), 'its status still comes'
  ensure
    Kairomone::Console::View.define_singleton_method(:waiting, original) if original
  end

  def test_the_page_logic_on_a_stand_in_dom
    out, status = Open3.capture2e('node', File.expand_path('templates/skillsets/kairomone/assets/test_console_logic.mjs', __dir__))
    assert status.success?, out
    assert_equal 5, out.scan(/^PASS: /).length, out
  rescue Errno::ENOENT
    skip 'node is not available here'
  end

  def test_a_host_without_individuals_shows_none
    payload = view
    assert_equal [[], nil, false], [payload['kairomones'], payload['shown'], payload.dig('status', 'initialized')]
    refute payload.key?('waiting')
    assert payload['kinds'].any? && payload['templates'].any?, 'the creation panel still has its starters'
  end

  def test_the_drawing_and_what_waits_come_with_their_ids_and_hashes
    store = create('momo')
    waiting_art = store.propose_art(svg: Kairomone::Art::EGG.sub('rx="34"', 'rx="30"'))
    drafted = store.propose_profile(fields: PROFILE.merge('name' => 'Momo II'))
    w = view('momo')['waiting']
    assert_match(%r{\Adata:image/svg\+xml;base64,}, w.dig('art', 'data_uri'))
    drawing = w.dig('art', 'waiting').first
    assert_equal [waiting_art[:proposal], waiting_art[:sha256]], drawing.values_at('proposal', 'sha256')
    profile = w['proposals'].find { |p| p['kind'] == 'profile' }
    assert_equal drafted[:proposal], profile['proposal']
    doc = JSON.parse(File.read(File.join(store.root, 'proposals', "#{drafted[:proposal]}.json")))
    assert_equal Digest::SHA256.hexdigest(JSON.pretty_generate(doc['piece']) + "\n"), profile['sha256'], 'the hash the accepted piece will have'
    assert_nil w['offer']
  end

  def test_an_open_branch_offer_comes_with_its_id_and_candidates
    store = create('momo')
    4.times { |i| store.create_knowledge(id: "n#{i}", title: "N#{i}", content: "Note #{i}") }
    craft = { 'description' => 'Learns', 'focus' => %w[ecology], 'habits' => { 'sources' => 'primary', 'depth' => 'deep', 'reflection' => 'narrative', 'stance' => 'practical' } }
    offer = store.offer_professions(candidates: %w[Gardener Herbalist Forager].map { |n| craft.merge('name' => n) })
    w = view('momo')['waiting']
    assert_equal [offer[:offer], %w[Gardener Herbalist Forager]], [w.dig('offer', 'offer'), w.dig('offer', 'candidates').map { |c| c['name'] }]
  end

  def test_reading_the_view_writes_nothing
    store = create('momo')
    store.propose_art(svg: Kairomone::Art::EGG)
    before = Dir.glob(File.join(@host, '**', '*'), File::FNM_DOTMATCH).reject { |f| File.basename(f).end_with?('.lock') }.sort
                .map { |f| [f, File.file?(f) ? Digest::SHA256.file(f).hexdigest : nil] }
    view('momo')
    view
    after = Dir.glob(File.join(@host, '**', '*'), File::FNM_DOTMATCH).reject { |f| File.basename(f).end_with?('.lock') }.sort
               .map { |f| [f, File.file?(f) ? Digest::SHA256.file(f).hexdigest : nil] }
    assert_equal before, after
  end

  def test_the_status_route_passes_the_shown_individual_and_refuses_another_shape
    seen = []
    server = Kairomone::Console::Server.allocate
    server.instance_variable_set(:@status_reader, ->(kairomone = nil) { seen << kairomone; { 'ok' => true } })
    res = server.send(:status, Req.new({ 'kairomone' => 'pip' }), Res.new)
    assert_equal [200, ['pip']], [res.status, seen]
    server.send(:status, Req.new({}), Res.new)
    assert_equal ['pip', nil], seen
    assert_raises(Kairomone::Console::Server::BadRequest) { server.send(:status, Req.new({ 'kairomone' => '../pip' }), Res.new) }
    legacy = Kairomone::Console::Server.allocate
    legacy.instance_variable_set(:@status_reader, -> { { 'ok' => true } })
    assert_equal 200, legacy.send(:status, Req.new({ 'kairomone' => 'pip' }), Res.new).status, 'a reader without an argument still serves'
  end

  def test_placed_text_names_the_individual_and_never_accepts
    table = place_table
    assert_equal %w[status recent learn backup proposal drawing offer create exportPreview].sort, table.keys.sort
    table.each do |key, template|
      refute_match ACCEPTANCE, template, "#{key}: #{template}"
      assert_includes template, '{who}', key unless key == 'create'
    end
    %w[proposal drawing].each { |key| assert(%w[{proposal} {hash}].all? { |k| table[key].include?(k) }, key) }
    assert_includes table['offer'], '{offer}'
    # The words filled in come from fixed tables with the same rule.
    words = script[/var KIND_WORDS = \{(.*?)\};/m, 1] + script[/var PIECE_WORDS = \{(.*?)\};/m, 1]
    refute_match ACCEPTANCE, words
  end

  def test_the_tools_take_what_the_page_offers
    exchange = Kairomone08Support::TOOLS::Exchange.new(nil).input_schema
    assert_equal Kairomone::Exchange::KINDS, exchange.dig(:properties, :include, :items, :enum)
    assert_includes Kairomone::Exchange::KINDS, 'received'
    fusion = Kairomone08Support::TOOLS::Fusion.new(nil).input_schema
    assert_equal 'boolean', fusion.dig(:properties, :bodies, :type)
    create('alpha').create_knowledge(id: 'tea', title: 'Tea', content: 'Green tea is steamed.')
    create('beta')
    light = tool('Fusion', { 'command' => 'material', 'parents' => %w[alpha beta], 'bodies' => false })
    entries = light['items'].select { |i| i['item'] == 'entry' }
    assert_equal [[false, true]], entries.map { |e| [e.key?('body'), e['bytes'].positive?] }, 'the tool passes bodies: false through'
  end

  def test_the_page_names_every_tool_and_no_dot
    names = Kairomone08Support::TOOLS.constants.map { |c| Kairomone08Support::TOOLS.const_get(c) }
                                     .select { |k| k.is_a?(Class) && k < KairosMcp::Tools::BaseTool && k.method_defined?(:name) && k.instance_method(:name).owner == k }
                                     .map { |k| k.new(nil).name }.sort
    assert_equal 14, names.length, names.inspect
    labels = script[/var TOOL_LABELS = \{(.*?)\n  \};/m, 1].scan(/(kairomone_\w+):/).flatten.sort
    assert_equal names, labels
    refute_match(/\bdots?\b/i, File.read(PAGE).gsub(/data:[^'"]*/, ''), 'the page says Kairomone, not dot')
  end

  def test_the_page_shows_drawings_only_as_checked_data_images
    page = File.read(PAGE)
    assert_equal 1, page.scan(/<img\b/).length, 'one image element in the markup: the drawing shown'
    assert_match(%r{var DATA_SVG = /\^data:image\\/svg\\\+xml;base64,}, script)
    assert_equal 2, script.scan(/\.src = /).length
    assert_equal 2, script.scan(/DATA_SVG\.test\(/).length, 'every image source is tested first'
    refute_match(/innerHTML|outerHTML|insertAdjacentHTML|document\.write/, script)
  end
end
