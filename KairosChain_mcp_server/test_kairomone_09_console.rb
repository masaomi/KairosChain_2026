# frozen_string_literal: true

# Kairomone 0.9, the console page and what it reads (design
# log/kairomone_0_9_screens_and_generated_growth_design_v0.2_20261102.md,
# Inv 10, N5, N7): the payload adds the lean, the skills in force, the own
# growth entries a skill can be drafted from, lifetime cycles, learned
# subjects and a digest of the drawing history, and drops the profession
# templates; the history with its images is a separate read the page makes
# when the digest changes; nothing the console reads names a branch level;
# the console still writes nothing; every placed text names the individual
# shown and carries no acceptance, choice or consent wording and no branch
# level; every message the page sends begins with the line naming the
# listing ID shown. Runs without loopback servers or processes; the page's
# behaviour itself is driven in assets/test_console_logic.mjs. All data is
# synthetic and confined to temporary hosts.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'minitest/autorun'
require_relative 'templates/skillsets/kairomone/test/support_09'
require 'kairomone/console'

# Counts the readings of own growth (every L1 and L2 entry opened) while a
# test asks; otherwise it only passes through.
module Kairomone09OwnGrowthReads
  private

  def read_own_growth(*)
    Thread.current[:kairomone_own_growth_reads] += 1 if Thread.current[:kairomone_own_growth_reads]
    super
  end
end
Kairomone::Instance.prepend(Kairomone09OwnGrowthReads)

class Kairomone09ConsoleTest < Minitest::Test
  include Kairomone09Support

  PAGE = File.expand_path('templates/skillsets/kairomone/assets/console.html', __dir__)
  ACCEPTANCE = /受け入れ|受入|承認|承諾|同意|許可|了承|決定|決め|選ぶ|選び|選ん|選択|にします|それで|お願いします|accept|approv|consent|agree|confirm|choose|choice|chose|allow|pick/i
  # A level a branch opens at, as a number standing alone, or words for one.
  BRANCH_LEVEL = /(?<![\d{])(?:#{Kairomone::Vocabulary::BRANCH_LEVELS.join('|')})(?![\d}])|レベル|分岐|\blevel\b|\blv\b/i

  Res = Struct.new(:status, :body, :keep_alive) do
    def []=(_name, _value); end
  end
  Req = Struct.new(:query)

  def view(kairomone = nil) = JSON.parse(JSON.generate(Kairomone::Console::View.payload(@host, kairomone)))
  def history(kairomone) = JSON.parse(JSON.generate(Kairomone::Console::View.art_history(@host, kairomone)))
  def script = File.read(PAGE)[%r{<script>(.*)</script>}m, 1]

  def place_table
    body = script[/var PLACE = \{(.*?)\n  \};/m, 1] or flunk 'the page has no PLACE table'
    body.scan(/^\s+(\w+): '([^']*)'/).to_h
  end

  def own_source(store, id)
    store.skill_material[:own_growth_entries].find { |e| e['entry_id'] == "growth_#{id}" }.slice('entry_id', 'sha256')
  end

  def skill(source, name) = { 'name' => name, 'description' => "#{name}, carefully", 'methods' => %w[quantify], 'focus' => %w[botany], 'source' => source }

  def snapshot_files
    Dir.glob(File.join(@host, '**', '*'), File::FNM_DOTMATCH).reject { |f| File.basename(f).end_with?('.lock') }.sort
       .map { |f| [f, File.file?(f) ? Digest::SHA256.file(f).hexdigest : nil] }
  end

  def test_the_payload_carries_lean_skills_own_growth_lifetime_and_learned_subjects
    store = create
    one_cycle(store, 'moss', subjects: %w[botany])
    one_cycle(store, 'rock', subjects: %w[geology botany])
    store.create_knowledge(id: 'tea', title: 'Tea', content: 'Owner-written tea notes')
    store.accept_skill(proposal: store.propose_skill(skill: skill(own_source(store, 'moss'), 'Count the moss'))[:proposal])
    waiting = store.propose_skill(skill: skill(own_source(store, 'rock'), 'Read the strata'))
    lean(store, 'lean_1', 'もっと苔のことを知ってほしい', %w[botany])
    payload = view('momo')
    assert_equal({ 'subjects' => [{ 'id' => 'botany', 'en' => 'Botany', 'ja' => '植物学' }], 'owner_words' => 'もっと苔のことを知ってほしい',
                   'request_id' => 'lean_1' }, payload['lean'])
    assert_equal ['Count the moss'], payload['skills'].map { |s| s['name'] }
    assert_equal [%w[quantify], %w[botany]], [payload['skills'][0]['methods'].map { |m| m['id'] }, payload['skills'][0]['focus'].map { |f| f['id'] }]
    refute payload['skills'][0].key?('source'), 'the page is not handed the skill\'s source'
    assert_equal %w[growth_rock growth_moss], payload['own_growth'].map { |e| e['entry_id'] }, 'own growth entries, newest first; owner-written ones are not'
    assert_equal [2, own_source(store, 'rock')['sha256']], [payload['own_growth_total'], payload['own_growth'][0]['sha256']]
    assert_equal [2, nil], payload.values_at('lifetime_cycles', 'lifetime_unknown')
    assert_equal [%w[botany 2], %w[geology 1]], payload['learned_subjects'].map { |s| [s['id'], s['count'].to_s] }
    skill_wait = payload.dig('waiting', 'proposals').find { |p| p['kind'] == 'skill' }
    assert_equal [waiting[:proposal], 'Read the strata'], skill_wait.values_at('proposal', 'name'), 'a skill proposal waits like any other'
    doc = JSON.parse(File.read(File.join(store.root, 'proposals', "#{waiting[:proposal]}.json")))
    assert_equal Digest::SHA256.hexdigest(JSON.pretty_generate(doc['piece']) + "\n"), skill_wait['sha256'], 'the hash the accepted skill will have'
    assert_nil payload.dig('status', 'profession', 'current'), 'no profession yet; the page says so'
    refute payload.key?('templates'), 'no fixed profession list'
  end

  def test_a_lean_or_history_that_cannot_be_read_is_unknown_and_the_listing_still_comes
    create
    create('pip', profile: PROFILE.merge('name' => 'Pip'))
    original = Kairomone::Console::View.method(:individual)
    Kairomone::Console::View.define_singleton_method(:individual) { |*| raise Kairomone::Error, 'a damaged ledger' }
    payload = view('pip')
    assert_equal [%w[momo pip], 'pip'], [payload['kairomones'].map { |k| k['listing_id'] }, payload['shown']]
    assert_equal [nil, nil, nil, nil], payload.values_at('lean', 'skills', 'own_growth', 'art_history'), 'unknown, never empty'
    assert_match(/a damaged ledger/, payload['error'])
    refute_nil payload['waiting'], 'what waits is still read'
  ensure
    Kairomone::Console::View.define_singleton_method(:individual, original) if original
  end

  def test_the_history_travels_by_its_digest_and_a_missing_drawing_is_missing
    store = create
    empty = view('momo')['art_history']
    assert_equal 0, empty['count']
    assert_equal({ 'shown' => 'momo', 'digest' => empty['digest'], 'drawings' => [] }, history('momo'))
    drawn = Kairomone::Art::EGG.sub('rx="34"', 'rx="30"')
    store.accept_art(proposal: store.propose_art(svg: drawn, form: 'A round seed')[:proposal])
    first = view('momo')['art_history']
    refute_equal empty['digest'], first['digest'], 'an accepted drawing changes the digest'
    assert_equal first, view('momo')['art_history'], 'reading again changes nothing: the page does not fetch again'
    full = history('momo')
    assert_equal first['digest'], full['digest'], 'the history read names the digest the status names'
    item = full['drawings'].first
    assert_equal ['A round seed', 1, false, Kairomone::Art.data_uri(drawn)], item.values_at('form', 'level', 'missing', 'data_uri')
    assert_equal({ 'en' => 'Egg', 'ja' => '卵' }, item['stage_name'])
    File.delete(File.join(store.root, "art/#{item['sha256']}.svg"))
    gone = view('momo')['art_history']
    refute_equal first['digest'], gone['digest'], 'a drawing gone missing changes the digest'
    missing = history('momo')['drawings'].first
    assert_equal [true, false, nil], missing.values_at('missing', 'present', 'data_uri'), 'missing, never shown as another'
    assert_equal({ 'shown' => nil, 'digest' => nil, 'drawings' => nil, 'error' => 'nobody is not listed on this host' }, history('nobody'))
  end

  def test_nothing_the_console_reads_names_a_branch_level
    store = create
    grow_to(store, 10)
    store.offer_professions(candidates: candidates('Moss'))
    payload = view('momo')
    branch = payload.dig('status', 'profession', 'branch')
    assert_equal %w[due offer], branch.keys.sort
    assert_equal [%w[description name]] * 3, payload.dig('waiting', 'offer', 'candidates').map { |c| c.keys.sort }, 'a candidate by its name and description only'
    text = JSON.generate(payload)
    %w[next_level branch_level opens_at catalog selected_unlocked selection_required templates].each do |key|
      refute_includes text, "\"#{key}\"", key
    end
    refute_match(/next_level|branch_level|BRANCH_LEVELS|\.branch\b/, script, 'the page reads no branch level, nor anything of the branch but the offer the view hands it')
  end

  def test_reading_the_view_and_the_history_writes_nothing
    store = create
    one_cycle(store, 'moss')
    store.accept_art(proposal: store.propose_art(svg: Kairomone::Art::EGG, form: 'An egg')[:proposal])
    before = snapshot_files
    view('momo')
    history('momo')
    view
    assert_equal before, snapshot_files
  end

  def test_the_history_route_needs_a_listing_id_and_a_reader
    seen = []
    server = Kairomone::Console::Server.allocate
    server.instance_variable_set(:@art_reader, ->(kairomone) { seen << kairomone; { 'shown' => kairomone } })
    res = server.send(:art_history, Req.new({ 'kairomone' => 'pip' }), Res.new)
    assert_equal [200, ['pip']], [res.status, seen]
    [{}, { 'kairomone' => '../pip' }, { 'kairomone' => '' }].each do |query|
      assert_raises(Kairomone::Console::Server::BadRequest, query.inspect) { server.send(:art_history, Req.new(query), Res.new) }
    end
    bare = Kairomone::Console::Server.allocate
    bare.instance_variable_set(:@art_reader, nil)
    assert_equal 404, bare.send(:art_history, Req.new({ 'kairomone' => 'pip' }), Res.new).status
    assert_equal 'GET', Kairomone::Console::Server::ROUTES['/art-history']
  end

  def test_no_placed_text_carries_acceptance_choice_consent_or_a_branch_level
    table = place_table
    table.each do |key, template|
      refute_match ACCEPTANCE, template, "#{key}: #{template}"
      refute_match BRANCH_LEVEL, template, "#{key}: #{template}"
      assert_includes template, '{who}', key unless key == 'create'
    end
    assert_equal '{who}、{n}回学習して', table['learnRun'], 'N7: 「〈N〉回学習して」 for the individual shown'
    assert_equal '{who}の学習を止めて', table['learnStop']
    assert_equal '{who}の傾きを消して', table['leanClear'], 'N1: 「傾きを消して」'
    assert(%w[{title} {entry} {hash}].all? { |k| table['skillDraft'].include?(k) }, 'a skill is asked for from a named own growth entry and its hash')
    words = %w[KIND_WORDS PIECE_WORDS WINDOW_WORDS].map { |name| script[/var #{name} = \{(.*?)\};/m, 1] or flunk name }.join
    refute_match ACCEPTANCE, words
    labels = File.read(PAGE).scan(/<button\b[^>]*>([^<]*)<\/button>/).flatten
    %w[学習を始める 学習を止める].each { |label| assert_includes labels, label }
  end

  def test_every_sent_message_starts_with_the_listing_id_line
    code = script
    assert_equal 1, code.scan(%r{'/message'}).length, 'one place sends a message'
    sender = code[/function send\(\) \{(.*?)\n  \}/m, 1] or flunk 'no send function'
    assert_match(/var message = idLine\(\) \+ '\\n' \+ value;/, sender)
    assert_match(/api\('POST', '\/message', \{ text: message \}\)/, sender)
    assert_match(/bytes\(message\) > MAX_TEXT_BYTES/, sender, 'the limit counts the line too')
    line = code[/function idLine\(\) \{(.*?)\}/m, 1]
    assert_includes line, "'[Kairomone: ' + (state.shown && ID.test(state.shown) ? state.shown : NONE_SHOWN) + ']'"
    assert_includes code, "var NONE_SHOWN = '(none shown)';"
    refute_match Kairomone::Paths::ID, '(none shown)', 'the none-shown word can be no listing ID'
  end

  def test_the_page_keeps_its_contract_and_lays_out_three_columns
    html = File.read(PAGE)
    assert_equal [1, 1], [html.scan(/<script\b/).length, html.scan(/<style\b/).length]
    markup = html.sub(%r{<script>.*</script>}m, '').sub(%r{<style>.*</style>}m, '')
    refute_match(/\sstyle\s*=|\son[a-z]+\s*=/i, markup, 'no style attribute or inline handler')
    refute_match(%r{\b(?:src|href)\s*=\s*["']?(?:https?:)?//}i, markup, 'no external resource')
    refute_match(/innerHTML|outerHTML|insertAdjacentHTML|document\.write|localStorage|document\.cookie/, script)
    %w[sessionStorage history.replaceState X-Kairomone-Session X-Kairomone-Bootstrap textContent].each { |word| assert_includes script, word }
    left = markup[%r{<aside class="left".*?</aside>}m] or flunk 'no left column'
    side = markup[%r{<aside class="side".*?</aside>}m] or flunk 'no right column'
    %w[art st-name st-stage st-level st-profession lean-subjects lean-words lean-clear skill-list].each { |id| assert_includes left, "id=\"#{id}\"", id }
    %w[learn-cycles learn-start learn-stop st-used st-max st-lifetime st-policy history-list wait-list skill-source skill-place export-place tool-list]
      .each { |id| assert_includes side, "id=\"#{id}\"", id }
    assert_includes markup[%r{<section class="convo".*?</section>\s*<aside}m], 'id="log"'
    assert_includes script, "'まだ職業はない'"
    refute_includes html, 'create-template', 'no profession template to pick'
  end

  def own_growth_reads
    Thread.current[:kairomone_own_growth_reads] = 0
    yield
    Thread.current[:kairomone_own_growth_reads]
  ensure
    Thread.current[:kairomone_own_growth_reads] = nil
  end

  # The page polls /status; one payload, and one status, read own growth
  # once, however many parts ask for it. Nothing is kept between calls.
  def test_one_payload_and_one_status_read_own_growth_once
    store = create
    one_cycle(store, 'moss')
    source = store.skill_material[:own_growth_entries].first.slice('entry_id', 'sha256')
    store.accept_skill(proposal: store.propose_skill(skill: { 'name' => 'S', 'description' => 'D', 'methods' => %w[quantify], 'focus' => [],
                                                              'source' => source })[:proposal])
    assert_equal 1, own_growth_reads { view('momo') }, 'one console payload'
    assert_equal 1, own_growth_reads { store.status }, 'one status'
    assert_equal 1, own_growth_reads { store.status(render_html: true) }, 'one status with its snapshot'
    assert_equal 2, own_growth_reads { 2.times { store.status } }, 'nothing is kept between calls'
    before = view('momo')
    path = File.join(store.root, 'knowledge/growth_moss/growth_moss.md')
    File.write(path, File.read(path).sub('Learned in moss', 'Edited'))
    after = view('momo')
    shown = ->(payload) { [payload['own_growth_total'], payload['lifetime_cycles'], payload['skills'].length] }
    assert_equal [[1, 1, 1], [0, 0, 0]], [shown.call(before), shown.call(after)], 'a change shows in the next payload'
  end
end
