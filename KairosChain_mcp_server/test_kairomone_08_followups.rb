# frozen_string_literal: true

# Kairomone 0.8, the findings run B's second implementation review left open
# (design log/kairomone_core_0_8_design_v0.6_FROZEN_20261023.md, Inv 4, Inv 5,
# M3, M4, M5, M7, M9): the companion audit keyed on request, field and hash;
# retries answered before the name rule; the run stepped before the request
# reads the profession; proposal states and bounds; the host's own profile
# material; one name limit; joiners allowed; fewer credential false
# positives; retired subject IDs followed; retry result shapes.
# All data is synthetic and confined to temporary hosts.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'minitest/autorun'
require_relative 'templates/skillsets/kairomone/test/support_08'

class Kairomone08FollowupsTest < Minitest::Test
  include Kairomone08Support

  PROFILE = { 'name' => 'Momo', 'kind' => 'animal', 'kind_label' => 'Fox', 'appearance' => 'A small round fox with a notebook',
              'personality' => %w[curious gentle], 'voice' => 'Soft', 'interests' => %w[stories] }.freeze
  CRAFT = { 'name' => 'Field naturalist', 'description' => 'Learns from the living world',
            'focus' => %w[ecology botany entomology], 'habits' => { 'sources' => 'primary', 'depth' => 'deep', 'reflection' => 'narrative', 'stance' => 'practical' } }.freeze

  def setup = fresh_host
  def teardown = FileUtils.remove_entry_secure(@host)

  def create(id = 'momo', profile: PROFILE)
    Kairomone::Host.new.create(listing_id: id, profile: profile, profession: { 'template' => 'researcher' }, material_kind: 'free_text')
    Kairomone::Instance.new(host_root: @host, kairomone: id)
  end

  def grow_to(store, level)
    n = 0
    n += 1 while store.progression_status[:level] < level && store.create_knowledge(id: "fact_#{n}", title: "Fact #{n}", content: "Distinct fact #{n}")
  end

  def candidates(prefix) = 3.times.map { |i| CRAFT.merge('name' => "#{prefix} #{i}") }

  def test_an_audit_record_that_landed_does_not_hide_the_one_that_did_not
    store = create
    direction = { 'preset' => 'evidence', 'text' => '' }
    # The direction record of request 'set' landed before a crash; its
    # personality record and the state did not.
    store.send(:with_lock) do
      Kairomone::Records.append!(store.chain, [{ 'type' => 'kairomone_companion', 'field' => 'direction', 'revision' => 1, 'request_id' => 'set',
                                                 'sha256' => Digest::SHA256.hexdigest(JSON.generate(direction)) }], -> { store.chain })
    end
    store.configure_companion(request_id: 'set', expected_revision: 0, personality: 'Curious', direction: direction)
    audit = Kairomone::Records.of_type(store.chain, 'kairomone_companion')
    assert_equal %w[direction personality], audit.map { |r| r['field'] }
    assert_equal Digest::SHA256.hexdigest(JSON.generate('Curious')), audit.last['sha256']
  end

  def test_a_name_request_applied_before_a_profile_was_accepted_is_answered_on_retry
    legacy = KairomoneLegacyFixture.slot!(@host, dot_id: 'old_one', display_name: 'Old one')
    first = legacy.configure_companion(request_id: 'rename', expected_revision: 0, display_name: 'New one')
    assert_equal 'New one', first[:companion]['display_name']
    proposal = legacy.propose_profile(fields: PROFILE.merge('name' => 'Kuro'), material_kind: 'legacy')[:proposal]
    legacy.accept_profile(proposal: proposal)
    retried = legacy.configure_companion(request_id: 'rename', expected_revision: 0, display_name: 'New one')
    assert retried[:preserved]
    assert_equal 'Kuro', retried[:companion]['display_name']
    error = assert_raises(Kairomone::Error) { legacy.configure_companion(request_id: 'again', expected_revision: 1, display_name: 'Other') }
    assert_match(/lives in the profile/, error.message)
  end

  def test_a_request_with_a_wrong_token_is_refused_for_the_token_first
    store = create
    run = store.autonomy.run_start(owner_words: 'One', cycles: 1)
    error = assert_raises(Kairomone::Error) do
      store.autonomy.request(run_id: run[:run_id], token: 'x' * 43, request_id: 'one', topic: 'Topic', profession_id: 'template:creator')
    end
    assert_match(/driver token/, error.message)
  end

  def test_offers_the_owner_can_no_longer_choose_are_marked_superseded
    store = create
    grow_to(store, 10)
    old = store.offer_professions(candidates: candidates('Old'))[:offer]
    fresh = store.offer_professions(candidates: candidates('New'))[:offer]
    states = store.proposals[:proposals].to_h { |p| [p['proposal'], p['state']] }
    assert_equal({ old => 'superseded', fresh => 'waiting' }, states)
    store.choose_profession(offer: fresh, index: 1)
    states = store.proposals[:proposals].to_h { |p| [p['proposal'], p['state']] }
    assert_equal({ old => 'superseded', fresh => 'chosen' }, states)
    assert_equal 0, store.proposals[:waiting_total]
  end

  def test_the_proposal_list_is_bounded_and_counts_what_it_leaves_out
    store = create
    12.times { |i| store.propose_profile(fields: PROFILE.merge('name' => "Draft #{i}")) }
    listed = store.proposals
    assert_equal 10, listed[:proposals].length
    assert_equal 12, listed[:waiting_total]
    assert(listed[:proposals].all? { |p| p['state'] == 'waiting' })
  end

  def test_the_host_material_drafts_a_first_kairomone_from_the_instruction_mode
    File.write(File.join(@host, 'skills/config.yml'), "instructions_mode: developer\n")
    empty = tool('Profile', { 'command' => 'material' })
    assert empty['success'], empty['error']
    assert_equal 'developer', empty.dig('instruction_mode', 'name')
    assert_equal '# synthetic philosophy', empty.dig('instruction_mode', 'text')
    assert_equal [], empty['kairomones']
    refute empty.key?('seeds')
    create('one')
    single = tool('Profile', { 'command' => 'material' })
    refute single.key?('seeds'), 'unnamed is always the material for a new one'
    assert_equal %w[one], single['kairomones'].map { |k| k['listing_id'] }
    assert_equal 'Momo', tool('Profile', { 'command' => 'material', 'kairomone' => 'one' }).dig('seeds', 'name')
    create('two')
    several = tool('Profile', { 'command' => 'material' })
    assert_equal %w[one two], several['kairomones'].map { |k| k['listing_id'] }
    refute several.key?('seeds')
    assert_equal 'developer', several.dig('instruction_mode', 'name')
  end

  def test_one_name_limit_holds_for_creation_proposals_and_init
    assert create('long', profile: PROFILE.merge('name' => 'n' * 256))
    assert_raises(Kairomone::Error) { create('longer', profile: PROFILE.merge('name' => 'n' * 257)) }
    store = Kairomone::Instance.new(host_root: @host, kairomone: 'long')
    assert store.propose_profile(fields: PROFILE.merge('name' => 'm' * 256))[:proposal]
    assert_raises(Kairomone::Error) { store.propose_profile(fields: PROFILE.merge('name' => 'm' * 257)) }
  end

  def test_init_applies_the_composed_text_rules_only_to_a_new_kairomone
    error = assert_raises(Kairomone::Error) { Kairomone::Instance.new(bind: false).init(dot_id: 'firsty', display_name: "Bad\u202Ename") }
    assert_match(/control characters/, error.message)
    assert_equal [], listing
    Kairomone::Instance.new(bind: false).init(dot_id: 'firsty', display_name: 'Firsty')
    again = Kairomone::Instance.new(bind: false).init(dot_id: 'firsty', display_name: 'Firsty')
    assert again[:preserved]
  end

  def test_emoji_joiners_are_text_but_other_format_characters_are_not
    scientist = "\u{1F469}\u200D\u{1F52C} Momo"
    assert_equal scientist, create('emoji', profile: PROFILE.merge('name' => scientist)).name
    ["Mo\u200Bmo", "Mo\u202Emo", "Mo\u0007mo"].each do |name|
      assert_raises(Kairomone::Error, name.inspect) { create('bad', profile: PROFILE.merge('name' => name)) }
    end
  end

  def test_hyphenated_words_are_not_taken_for_keys
    store = create('fur', profile: PROFILE.merge('appearance' => 'sky-blue-and-silver-fur-with-stripes, a ghp-shaped-hat-with-feathers'))
    assert_match(/sky-blue/, store.profile['appearance'])
    store.configure_companion(request_id: 'p', expected_revision: 0, personality: 'sky-blue-and-silver-fur-with-stripes')
    # Key-shaped samples are assembled here so no file carries one whole.
    [%w[sk ant api03 abcdefghijklmnop1234].join('-'), ['ghp', 'abcdefghijklmnopqrstuvwxyzABCDEF'].join('_'),
     ['github', 'pat', '11ABCDEFG0123456789abcdef'].join('_')].each do |key|
      assert_raises(Kairomone::Error, key) { store.propose_profile(fields: PROFILE.merge('voice' => "Soft #{key}")) }
      assert_raises(Kairomone::Error, key) { store.configure_companion(request_id: 'k', expected_revision: 1, personality: key) }
    end
  end

  def test_a_retired_subject_id_is_followed_to_its_current_successor
    Kairomone::Vocabulary.subjects # loads the vocabulary whichever test runs first
    cache = Kairomone::Vocabulary.instance_variable_get(:@cache)
    original = cache['subjects.json']
    cache['subjects.json'] = original.merge('aliases' => { 'old_ecology' => 'older_ecology', 'older_ecology' => 'ecology' })
    assert_equal 'ecology', Kairomone::Vocabulary.subject_id('old_ecology')
    assert_nil Kairomone::Vocabulary.subject_id('never_a_subject')
  ensure
    cache['subjects.json'] = original if cache
  end

  def test_retries_answer_in_the_shape_of_the_first_answer
    store = create
    proposal = store.propose_profile(fields: PROFILE.merge('name' => 'Kuro'))[:proposal]
    first = store.accept_profile(proposal: proposal)
    again = store.accept_profile(proposal: proposal)
    assert_equal first.keys.sort, (again.keys - [:preserved]).sort
    assert_equal 'Kuro', again[:profile]['name']
    grow_to(store, 10)
    offer = store.offer_professions(candidates: candidates('Branch'))[:offer]
    chosen = store.choose_profession(offer: offer, index: 2)
    retried = store.choose_profession(offer: offer, index: 2)
    assert_equal chosen.keys.sort, (retried.keys - [:preserved]).sort
    assert_equal 'Branch 2', retried[:profession][:current][:name]
  end

  def test_a_proposal_is_read_only_by_its_own_hash
    store = create
    assert_nil store.send(:read_proposal, '../profile')
    sha = store.propose_profile(fields: PROFILE)[:proposal]
    path = File.join(store.root, "proposals/#{sha}.json")
    File.write(path, File.read(path).sub('Momo', 'Mimi'))
    assert_nil store.send(:read_proposal, sha)
  end
end
