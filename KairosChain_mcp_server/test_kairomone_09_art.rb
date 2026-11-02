# frozen_string_literal: true

# Kairomone 0.9, drawings every ten levels and their history (design
# log/kairomone_0_9_screens_and_generated_growth_design_v0.2_20261102.md,
# Inv 6, N5): a drawing is due at every multiple of ten the drawing shown does
# not answer; skipped milestones are not backfilled; a proposal holds its form,
# level and milestone and its acceptance record carries stage, level, milestone
# and form_sha256; a drawing accepted before 0.9 is shown by its stage, never
# an invented level; the history is every accepted drawing in order, absent or
# failing ones shown as missing; the terminal restore shows every form. All
# data is synthetic and confined to temporary hosts.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'minitest/autorun'
require_relative 'templates/skillsets/kairomone/test/support_09'

class Kairomone09ArtTest < Minitest::Test
  include Kairomone09Support

  def drawing(n) = Kairomone::Art::EGG.sub('Kairomone egg', "Drawing #{n}")

  def draw(store, n, form: "Form #{n}") = store.accept_art(proposal: store.propose_art(svg: drawing(n), form: form)[:proposal])[:sha256]

  # A drawing record as 0.8 wrote it: a stage, nothing else.
  def accept_as_08(store, n, stage)
    text = drawing(n)
    sha = Digest::SHA256.hexdigest(text)
    store.send(:with_lock) do
      Kairomone::Paths.write(store.root, "art/#{sha}.svg", text)
      Kairomone::Records.append!(store.chain, [{ 'type' => 'kairomone_art', 'sha256' => sha, 'origin' => 'proposal', 'stage' => stage }], -> { store.chain })
    end
    sha
  end

  def test_a_drawing_is_due_at_every_milestone_the_shown_one_does_not_answer
    store = create
    grow_exactly(store, 9)
    refute store.art_get[:due], 'below level 10 nothing is due'
    grow_exactly(store, 10)
    assert_equal [10, true], store.art_get.values_at(:milestone, :due)
    proposed = store.propose_art(svg: drawing(1), form: 'A fox kit with a notebook')
    assert_equal [10, 10, 'hatchling', 'A fox kit with a notebook'], proposed.values_at(:level, :milestone, :stage, :form)
    doc = JSON.parse(File.read(File.join(store.root, "proposals/#{proposed[:proposal]}.json")))
    assert_equal [10, 10, 'A fox kit with a notebook'], doc.values_at('level', 'milestone', 'form'), 'the proposal holds them'
    store.accept_art(proposal: proposed[:proposal])
    record = records(store, 'kairomone_art').last
    assert_equal({ 'stage' => 'hatchling', 'level' => 10, 'milestone' => 10, 'form_sha256' => Digest::SHA256.hexdigest('A fox kit with a notebook') },
                 record.slice('stage', 'level', 'milestone', 'form_sha256'))
    grow_exactly(store, 19)
    refute store.art_get[:due]
    grow_exactly(store, 20)
    assert store.art_get[:due]
    assert_equal 'A fox kit with a notebook', store.art_get[:form], 'the shown drawing names its form'
  end

  def test_skipped_milestones_are_not_backfilled
    store = create
    grow_exactly(store, 10)
    draw(store, 1)
    grow_exactly(store, 35) # 20 and 30 passed without a drawing
    assert_equal [30, true], store.art_get.values_at(:milestone, :due)
    draw(store, 2)
    refute store.art_get[:due], 'one drawing answers the milestone of the level it was drawn at'
    assert_equal [[10, 10], [35, 30]], store.art_history.map { |d| d.values_at('level', 'milestone') }
  end

  def test_a_drawing_from_before_09_is_shown_by_its_stage_and_answers_its_stages_milestone_inside
    store = create
    grow_exactly(store, 25)
    sha = accept_as_08(store, 1, 'young') # young begins at 20
    refute store.art_get[:due], 'a young drawing answers milestone 20 internally'
    grow_exactly(store, 30)
    assert store.art_get[:due]
    item = store.art_history.find { |d| d['sha256'] == sha }
    assert_equal 'young', item['stage']
    refute item.key?('level'), 'never an invented level'
    refute item.key?('milestone'), 'the derived milestone stays inside'
    assert_nil item['form']
    unknown = accept_as_08(store, 2, 'mystery')
    assert_equal unknown, store.art_get[:sha256]
    assert store.art_get[:due], 'an unknown stage answers milestone 0'
  end

  def test_a_drawing_accepted_by_08_reads_by_its_stage
    with_08(@host, <<~RUBY)
      profile = { 'name' => 'Momo', 'kind' => 'animal' }
      Kairomone::Host.new.create(listing_id: 'old', profile: profile, profession: { 'template' => 'researcher' }, material_kind: 'free_text')
      s = Kairomone::Instance.new(host_root: host, kairomone: 'old')
      n = 0
      n += 1 while s.progression_status[:level] < 5 && s.create_knowledge(id: "f\#{n}", title: "F\#{n}", content: "Fact \#{n}")
      p = s.propose_art(svg: Kairomone::Art::EGG.sub('Kairomone egg', 'Hatchling drawing'))
      puts JSON.generate(s.accept_art(proposal: p[:proposal]))
    RUBY
    store = Kairomone::Instance.new(host_root: @host, kairomone: 'old')
    assert_equal [{ 'stage' => 'hatchling', 'present' => true, 'valid' => true, 'missing' => false, 'form' => nil }],
                 store.art_history.map { |d| d.slice('stage', 'present', 'valid', 'missing', 'form') }
    refute store.art_get[:due]
    grow_to(store, 10, prefix: 'more')
    assert store.art_get[:due], 'a hatchling drawing does not answer milestone 10'
    assert_equal 'Researcher', store.profession_status[:name], 'its 0.8 profession stays in force'
  end

  def test_the_history_keeps_every_drawing_in_order_and_shows_the_missing_as_missing
    store = create
    shas = (1..3).map { |n| draw(store, n) }
    File.delete(File.join(store.root, "art/#{shas[0]}.svg"))
    File.write(File.join(store.root, "art/#{shas[1]}.svg"), drawing(2).sub('<title>', '<image href="x"/><title>'))
    history = store.art_history
    assert_equal shas, history.map { |d| d['sha256'] }
    assert_equal [[false, false, true], [false, false, true], [true, true, false]], history.map { |d| d.values_at('present', 'valid', 'missing') }
    assert_equal ['Form 1', 'Form 2', 'Form 3'], history.map { |d| d['form'] }
    assert_equal shas[2], store.art_get[:sha256], 'the shown drawing is the newest that passes'
    tool_history = tool(:Art, 'command' => 'history')
    assert_equal shas, tool_history['drawings'].map { |d| d['sha256'] }
    refute(tool_history['drawings'].any? { |d| d.key?('data_uri') }, 'the tool lists drawings by reference')
    images = store.art_history(images: true)
    assert_equal [nil, nil, Kairomone::Art.data_uri(drawing(3))], images.map { |d| d['data_uri'] }, 'a missing drawing is never shown as another'
  end

  def test_the_form_is_display_text_guarded_like_every_composed_text
    store = create
    assert_raises(Kairomone::Error) { store.propose_art(svg: drawing(1)) }
    ['', 'f' * 81, "A fox‮", "A fox\nwith a hat", 'A fox with password: hunter22'].each do |form|
      assert_raises(Kairomone::Error, form.inspect) { store.propose_art(svg: drawing(1), form: form) }
    end
    assert store.propose_art(svg: drawing(1), form: 'あ' * 26)[:proposal], 'eighty bytes of form fit'
  end

  def test_a_received_drawing_keeps_only_its_stage
    a = create('alpha')
    draw(a, 1, form: 'The exporter\'s own words')
    out = a.exchange_export(file_sha256: a.exchange_preview(include: [])[:file_sha256])
    refute_includes File.read(out[:path]), 'The exporter\'s own words', 'exchange carries one drawing per stage, not its form'
    FileUtils.mkdir_p(File.join(@host, 'kairomone-inbox'))
    FileUtils.cp(out[:path], File.join(@host, 'kairomone-inbox', out[:file]))
    Kairomone::Host.new.import_exchange(file: out[:file], listing_id: 'copy')
    copy = Kairomone::Instance.new(host_root: @host, kairomone: 'copy')
    waiting = copy.proposals[:proposals].find { |p| p['kind'] == 'art' && p['state'] == 'waiting' }
    copy.accept_art(proposal: waiting['proposal'])
    record = records(copy, 'kairomone_art').last
    assert_equal ['egg', nil, nil], record.values_at('stage', 'level', 'form_sha256')
  end

  def test_the_terminal_restore_shows_every_form
    store = create
    draw(store, 1, form: 'A sleepy pebble')
    accept_as_08(store, 2, 'egg')
    archive = archive_of(store.create_backup[:path])
    archive.delete('signature')
    shown = nil
    Kairomone::Host.new.restore(JSON.generate(archive), trust: ->(lines) { shown = lines; false }, listing_id: 'copy') rescue nil
    assert_includes shown, 'Drawings: 2'
    assert(shown.any? { |l| l.include?('A sleepy pebble (level 1)') }, shown.inspect)
    assert(shown.any? { |l| l.include?('(no form recorded) (stage egg)') }, shown.inspect)
  end

  def test_the_material_continues_from_the_previous_drawing
    store = create
    one_cycle(store, 'moss', subjects: %w[botany])
    draw(store, 1, form: 'A mossy pebble')
    material = tool(:Art, 'command' => 'material')
    assert material['success'], material.inspect
    assert_equal ['A mossy pebble', drawing(1)], material['previous'].values_at('form', 'svg')
    assert_equal ['Momo', 0, 'egg'], [material.dig('profile', 'name'), material['milestone'], material.dig('stage', 'id')]
    assert_equal ['botany'], material['learned_subjects'].map { |l| l['id'] }
    assert_nil material['profession']
    assert_match(/any living, imagined or inanimate thing/, material['note'])
  end
end
