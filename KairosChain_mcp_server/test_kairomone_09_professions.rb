# frozen_string_literal: true

# Kairomone 0.9, professions without a fixed list (design
# log/kairomone_0_9_screens_and_generated_growth_design_v0.2_20261102.md,
# Inv 5, Inv 10, N4): a new Kairomone has no profession and no template
# becomes its parent; branch levels are internal — status shows whether a
# branch is due, never the level it opens at; offers come one at a time for as
# long as the level is at or past the next branch level; a 0.6 selection still
# reads as its template; templates and select are refused and kairomone_create
# takes no profession; profession material draws L1 only from own growth
# entries. All data is synthetic and confined to temporary hosts.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'minitest/autorun'
require_relative 'templates/skillsets/kairomone/test/support_09'

class Kairomone09ProfessionsTest < Minitest::Test
  include Kairomone09Support

  def test_a_new_kairomone_has_no_profession
    store = create
    status = store.profession_status
    assert_equal [nil, nil, nil, [], 0], status.values_at(:current, :name, :effective_id, :lineage, :tier)
    %i[catalog selected_unlocked selection_required].each { |key| refute status.key?(key), key }
    assert_equal({ due: false, offer: nil }, status[:branch])
    assert_match(/no profession yet/, status[:note])
    growth = store.autonomy
    run = growth.run_start(owner_words: 'One', cycles: 1)
    context = growth.request(run_id: run[:run_id], token: run[:token], request_id: 'one', topic: 'T', subjects: %w[geology])['queue']['context']
    assert_equal({ 'focus' => [], 'habits' => { 'sources' => 'mixed', 'depth' => 'survey', 'reflection' => 'concise', 'stance' => 'practical' } },
                 context['profession'], 'no profession: no focus and the default habits')
    assert_nil growth.status.dig('queue', 'profession_id')
  end

  def test_the_first_offer_has_no_parents_and_status_never_names_a_branch_level
    store = create
    error = assert_raises(Kairomone::Error) { store.offer_professions(candidates: candidates('Early')) }
    assert_equal 'No branch is open for this profession', error.message
    grow_to(store, 10)
    status = store.profession_status
    assert status[:branch][:due]
    refute_match(/\b(10|30|100|300|600)\b/, JSON.generate(status.reject { |k, _| k == :note }), 'no branch level in what status surfaces')
    offer = store.offer_professions(candidates: candidates('First'))
    assert(offer[:candidates].all? { |c| c['parents'] == [] && c['tier'] == 1 }, 'no template becomes a parent')
    assert_nil records(store, 'kairomone_offer').last['from']
    chosen = store.choose_profession(offer: offer[:offer], index: 1)
    current = chosen[:profession][:current]
    assert_equal ['First 1', [], 1], current.values_at(:name, :parents, :tier)
    assert_equal [], chosen[:profession][:lineage]
    assert_equal 1, chosen[:profession][:tier]
  end

  def test_offers_come_one_after_another_while_the_level_is_past_the_next_branch
    store = create
    grow_to(store, 31)
    assert_equal 31, store.progression_status[:level]
    first = store.offer_professions(candidates: candidates('One'))
    refute store.profession_status[:branch][:due], 'an open offer waits'
    store.choose_profession(offer: first[:offer], index: 0)
    assert store.profession_status[:branch][:due], 'the next branch is due at once'
    second = store.offer_professions(candidates: candidates('Two'))
    assert(second[:candidates].all? { |c| c['parents'] == [records(store, 'kairomone_profession').last['sha256']] })
    store.choose_profession(offer: second[:offer], index: 2)
    status = store.profession_status
    assert_equal [2, false], [status[:tier], status[:branch][:due]], 'two branches taken; the third is not reached'
    assert_equal %w[One\ 0], status[:lineage].map { |l| l[:name] }
    assert_equal 'No branch is open for this profession', assert_raises(Kairomone::Error) { store.offer_professions(candidates: candidates('Three')) }.message
  end

  def test_a_06_selection_reads_as_its_template_until_its_next_branch
    legacy = KairomoneLegacyFixture.slot!(@host, dot_id: 'old_one', display_name: 'Old one')
    select_06(legacy, 'researcher')
    grow_to(legacy, 10)
    status = legacy.profession_status
    assert_equal ['template:researcher', 'researcher', 'Researcher', 0], [status.dig(:current, :id), status[:effective_id], status[:name], status[:tier]]
    offer = legacy.offer_professions(candidates: candidates('Heir'))
    assert(offer[:candidates].all? { |c| c['parents'] == ['template:researcher'] }, 'a template stays readable as a lineage parent')
    legacy.choose_profession(offer: offer[:offer], index: 0)
    assert_equal [{ id: 'template:researcher', name: 'Researcher' }], legacy.profession_status[:lineage]
    assert_equal 'researcher', legacy.profession_status[:selected_id], 'the 0.6 file is read, never rewritten'
  end

  def test_no_fixed_list_is_offered_anywhere
    store = create
    %w[templates select].each do |command|
      result = tool(:Profession, 'command' => command, 'id' => 'researcher')
      refute result['success']
      assert_match(/no fixed list/, result['error'])
    end
    assert_raises(Kairomone::Error) { store.select_profession(id: 'researcher') }
    refute File.exist?(File.join(store.root, 'profession.json'))
    refused = tool(:Create, 'kairomone' => 'other', 'profile' => PROFILE, 'profession' => { 'template' => 'creator' })
    assert_match(/takes no \{template:\}/, refused['error'])
    assert File.file?(File.join(Kairomone::PACKAGE_ROOT, 'templates/professions.json')), 'the templates still ship, for 0.6 selections and lineage'
  end

  def test_no_tool_description_names_a_branch_level_or_hatching
    texts = TOOLS.constants.map { |c| TOOLS.const_get(c) }.select { |k| k.is_a?(Class) && k.instance_methods(false).include?(:description) }
                 .map { |k| k.new(nil) }.flat_map { |t| [t.description, JSON.generate(t.input_schema)] }
    texts.each do |text|
      refute_match(/\b(?:30|100|300|600)\b|levels? 10\b|hatch/i, text, text[0, 120])
    end
    profession = TOOLS::Profession.new(nil).description
    assert_match(/Never tell the owner when a branch comes/, profession)
    assert_match(/every tenth level/, TOOLS::Art.new(nil).description)
  end

  def test_profession_material_draws_l1_only_from_own_growth_entries
    File.write(File.join(@host, 'skills/config.yml'), "instructions_mode: masa\n")
    File.write(File.join(@host, 'skills/masa.md'), "# Masa mode\nProcess over outcome.\n")
    sha = Digest::SHA256.hexdigest("# Masa mode\nProcess over outcome.\n")
    Kairomone::Host.new.create(listing_id: 'momo', profile: PROFILE, material_kind: 'instruction_mode', material_sha256: sha)
    store = Kairomone::Instance.new(host_root: @host, kairomone: 'momo')
    one_cycle(store, 'moss', subjects: %w[botany], title: 'Moss holds water')
    store.create_knowledge(id: 'diary', title: 'A private owner note', content: 'Owner-written')
    material = store.profession_material
    assert_equal ['instruction_mode', sha], material[:material].values_at(:kind, :sha256)
    assert_includes material[:material][:text], 'Process over outcome'
    assert_equal ['Moss holds water'], material[:own_growth_titles]
    refute_includes JSON.generate(material), 'A private owner note', 'owner-written titles are not material for a shown piece'
    assert_equal ['botany'], material[:learned_subjects].map { |l| l['id'] }
    assert_equal 'Momo', material[:profile]['name']
    File.write(File.join(@host, 'skills/masa.md'), "# Masa mode\nChanged since.\n")
    changed = store.profession_material[:material]
    assert_nil changed[:text]
    assert_match(/no longer available/, changed[:note])
    tool_material = tool(:Profession, 'command' => 'material')
    assert tool_material['success'], tool_material.inspect
  end

  def test_fusion_of_two_without_a_profession_gives_a_child_whose_profession_has_no_parents
    a = create('alpha')
    b = create('beta')
    a.create_knowledge(id: 'tea', title: 'Tea', content: 'Green tea is steamed.')
    b.create_knowledge(id: 'fern', title: 'Ferns', content: 'Ferns spread by spores.')
    host = Kairomone::Host.new
    first = host.fusion_material(parents: %w[alpha beta])
    assert(first[:items].select { |i| i['item'] == 'parent' }.all? { |p| p['profession'].nil? })
    entries = first[:items].select { |i| i['item'] == 'entry' }
    plan = host.fusion_propose(parents: %w[alpha beta], child: 'pip', profile: PROFILE.merge('name' => 'Pip'), candidates: candidates('Child'),
                               entries: entries.map { |e| { 'id' => e['id'], 'mode' => 'keep', 'sources' => [{ 'parent' => e['parent'], 'entry_id' => e['id'], 'sha256' => e['sha256'] }] } },
                               heads: first[:heads])
    made = host.fusion_accept(plan: plan[:plan], candidate: 1)
    assert made[:fused]
    child = Kairomone::Instance.new(host_root: @host, kairomone: 'pip')
    assert_equal ['Child 1', []], child.profession_status[:current].values_at(:name, :parents)
    again = host.fusion_accept(plan: plan[:plan], candidate: 1)
    assert again[:preserved]
  end

  def test_a_received_profession_still_waits_and_is_accepted
    a = create_08('alpha', profile: PROFILE, template: 'creator')
    a.create_knowledge(id: 'tea', title: 'Tea', content: 'Green tea is steamed.')
    out = a.exchange_export(file_sha256: a.exchange_preview(include: %w[owner_written])[:file_sha256])
    FileUtils.mkdir_p(File.join(@host, 'kairomone-inbox'))
    FileUtils.cp(out[:path], File.join(@host, 'kairomone-inbox', out[:file]))
    Kairomone::Host.new.import_exchange(file: out[:file], listing_id: 'copy')
    copy = Kairomone::Instance.new(host_root: @host, kairomone: 'copy')
    assert_nil copy.profession_status[:current], 'nothing is in force before the owner accepts'
    waiting = copy.proposals[:proposals].find { |p| p['kind'] == 'profession' && p['state'] == 'waiting' }
    copy.accept_profession(proposal: waiting['proposal'])
    assert_equal 'Creator', copy.profession_status[:name]
  end
end
