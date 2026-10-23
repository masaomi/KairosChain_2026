# frozen_string_literal: true

# Kairomone 0.8, fusion (design log/kairomone_core_0_8_design_v0.6_FROZEN_20261023.md,
# Inv 1, Inv 3, Inv 9, M14): the child starts at level 1 as an egg with no
# L2 and acceptance records for its profile and profession; its inherited
# knowledge is held and never counted; the summary counts match the plan; a
# moved parent head refuses accept; self-fusion is refused; the parents are
# unchanged. All data is synthetic and confined to temporary hosts.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'minitest/autorun'
require_relative 'templates/skillsets/kairomone/test/support_08'

class Kairomone08FusionTest < Minitest::Test
  include Kairomone08Support

  PROFILE = { 'name' => 'Momo', 'kind' => 'animal', 'kind_label' => 'Fox', 'appearance' => 'A small round fox',
              'personality' => %w[curious], 'voice' => 'Soft', 'interests' => %w[stories] }.freeze
  CHILD = { 'name' => 'Pip', 'kind' => 'imaginary', 'kind_label' => 'Mossling', 'appearance' => 'A tiny moss sprite',
            'personality' => %w[gentle], 'voice' => 'Bright', 'interests' => %w[gardens] }.freeze
  CRAFT = { 'description' => 'Learns from the living world', 'focus' => %w[ecology botany],
            'habits' => { 'sources' => 'primary', 'depth' => 'deep', 'reflection' => 'narrative', 'stance' => 'practical' } }.freeze

  def setup = fresh_host
  def teardown = FileUtils.remove_entry_secure(@host)

  def create(id, profile = PROFILE)
    Kairomone::Host.new.create(listing_id: id, profile: profile.merge('name' => id.capitalize), profession: { 'template' => 'researcher' }, material_kind: 'free_text')
    Kairomone::Instance.new(host_root: @host, kairomone: id)
  end

  def parents
    a = create('alpha')
    a.create_knowledge(id: 'tea', title: 'Tea notes', content: 'Green tea is steamed.')
    a.create_knowledge(id: 'moss', title: 'Moss', content: 'Moss holds water.')
    b = create('beta')
    b.create_knowledge(id: 'tea', title: 'Tea brewing', content: 'Brew green tea at 70 degrees.')
    b.create_knowledge(id: 'fern', title: 'Ferns', content: 'Ferns spread by spores.')
    [a, b]
  end

  def material(host = Kairomone::Host.new)
    first = host.fusion_material(parents: %w[alpha beta])
    items = first[:items] + (2..first[:pages]).flat_map { |n| host.fusion_material(parents: %w[alpha beta], page: n)[:items] }
    [first[:heads], items.select { |i| i['item'] == 'entry' }.to_h { |i| [[i['parent'], i['id']], i] }]
  end

  def plan_entries(entries)
    [{ 'id' => 'tea', 'title' => 'Tea', 'content' => 'Green tea is steamed and brewed at 70 degrees.', 'mode' => 'merge',
       'sources' => [entries[%w[alpha tea]], entries[%w[beta tea]]].map { |e| { 'parent' => e['parent'], 'entry_id' => e['id'], 'sha256' => e['sha256'] } } },
     { 'id' => 'fern', 'title' => 'Ferns', 'content' => 'Ferns spread by spores.', 'mode' => 'keep',
       'sources' => [{ 'parent' => 'beta', 'entry_id' => 'fern', 'sha256' => entries[%w[beta fern]]['sha256'] }] }]
  end

  def propose(heads, entries, child: 'pip')
    Kairomone::Host.new.fusion_propose(parents: %w[alpha beta], child: child, profile: CHILD,
                                       candidates: %w[Gardener Herbalist Forager].map { |n| CRAFT.merge('name' => n) },
                                       entries: plan_entries(entries), heads: heads)
  end

  def snapshot(store) = [store.chain.latest_block.hash, Dir.glob(File.join(store.root, '**', '*')).sort.map { |f| [f, File.file?(f) ? Digest::SHA256.file(f).hexdigest : nil] }]

  def test_the_child_starts_as_an_egg_holding_what_it_inherits
    a, b = parents
    before = [snapshot(a), snapshot(b)]
    heads, entries = material
    summary = propose(heads, entries)
    assert_equal [1, 1, 1], summary.values_at(:kept, :merged, :dropped), 'summary counts match the plan'
    assert_equal [%w[alpha moss]], summary[:items].select { |i| i['item'] == 'dropped' }.map { |d| [d['parent'], d['id']] }
    child_items = summary[:items].select { |i| i['item'] == 'child_entry' }
    assert_equal %w[Tea Ferns], child_items.map { |i| i['title'] }
    assert_equal 'Green tea is steamed and brewed at 70 degrees.', child_items.first['content'], 'the owner sees each merged text'
    assert_equal [%w[alpha tea], %w[beta tea]], child_items.first['sources'].map { |s| [s['parent'], s['entry_id']] }
    done = Kairomone::Host.new.fusion_accept(plan: summary[:plan], candidate: 1)
    assert done[:fused], done.inspect
    refute File.exist?(File.join(@host, 'kairomone-fusion', "#{summary[:plan]}.json")), 'an accepted plan is removed'
    child = Kairomone::Instance.new(host_root: @host, kairomone: 'pip')
    assert_equal 1, child.progression_status[:level]
    assert_equal 0, child.progression_status[:total_xp]
    assert_equal 'egg', child.art_get[:shown]
    assert_equal 0, child.status[:observations][:count], 'no L2'
    assert_equal 'Pip', child.name
    assert_equal 'Herbalist', child.profession_status[:current][:name]
    assert_equal [a.profession_status[:current][:id], b.profession_status[:current][:id]], child.profession_status[:current][:parents]
    types = types(child)
    assert_equal %w[kairomone_identity kairomone_baseline kairomone_lineage kairomone_profile kairomone_profession kairomone_xp], types.first(6)
    assert_equal %w[fusion fusion], [Kairomone::Records.of_type(child.chain, 'kairomone_profile').first['origin'],
                                     Kairomone::Records.of_type(child.chain, 'kairomone_profession').first['origin']]
    lineage = Kairomone::Records.of_type(child.chain, 'kairomone_lineage').first
    assert_equal ['fusion', %w[alpha beta], summary[:plan]], [lineage['kind'], lineage['sources'].map { |s| s['identity'] }, lineage['plan_sha256']]
    xp = Kairomone::Records.of_type(child.chain, 'kairomone_xp').first['entries']
    assert(xp.all? { |e| e['counted'] == false })
    tea = xp.find { |e| e['id'] == 'tea' }
    assert_equal [entries[%w[alpha tea]]['identity'], entries[%w[beta tea]]['identity']].sort, tea['holds'].sort
    assert_equal before, [snapshot(a), snapshot(b)], 'the parents are unchanged'
  end

  def test_relearning_an_inherited_source_adds_no_xp
    _a, _b = parents
    heads, entries = material
    Kairomone::Host.new.fusion_accept(plan: propose(heads, entries)[:plan], candidate: 0)
    child = Kairomone::Instance.new(host_root: @host, kairomone: 'pip')
    child.create_knowledge(id: 'again', title: 'Tea again', content: 'Brew green tea at 70 degrees.')
    child.create_knowledge(id: 'kept_again', title: 'Ferns again', content: 'Ferns spread by spores.')
    assert_equal 0, child.progression_status[:unique_l1], 'a held identity counts nowhere'
    child.create_knowledge(id: 'new', title: 'New', content: 'Something the parents never knew.')
    assert_equal 1, child.progression_status[:unique_l1]
  end

  def test_a_moved_parent_head_or_a_changed_source_refuses_accept
    a, _b = parents
    heads, entries = material
    plan = propose(heads, entries)[:plan]
    a.create_knowledge(id: 'later', title: 'Later', content: 'Written after the plan')
    error = assert_raises(Kairomone::Error) { Kairomone::Host.new.fusion_accept(plan: plan, candidate: 0) }
    assert_match(/alpha changed since the plan/, error.message)
    refute_includes listing, 'pip', 'nothing listed and no ID used'
    heads, entries = material
    stale = plan_entries(entries)
    stale[1]['sources'][0]['sha256'] = '0' * 64
    error = assert_raises(Kairomone::Error) do
      Kairomone::Host.new.fusion_propose(parents: %w[alpha beta], child: 'pip', profile: CHILD,
                                         candidates: %w[Gardener Herbalist Forager].map { |n| CRAFT.merge('name' => n) }, entries: stale, heads: heads)
    end
    assert_match(/no longer holds the cited content/, error.message)
    kept = plan_entries(entries)
    kept[1]['content'] = 'Ferns are rewritten here.'
    assert_raises(Kairomone::Error) do
      Kairomone::Host.new.fusion_propose(parents: %w[alpha beta], child: 'pip', profile: CHILD,
                                         candidates: %w[Gardener Herbalist Forager].map { |n| CRAFT.merge('name' => n) }, entries: kept, heads: heads)
    end
  end

  def test_a_plan_from_stale_material_is_refused
    a, = parents
    heads, entries = material
    a.create_knowledge(id: 'later', title: 'Later', content: 'Written after the material was read')
    error = assert_raises(Kairomone::Error) { propose(heads, entries) }
    assert_match(/heads/, error.message)
  end

  def test_accept_judges_the_pieces_by_the_rules_current_then
    parents
    heads, entries = material
    plan = propose(heads, entries)[:plan]
    real = Kairomone::Vocabulary.method(:subject_id)
    Kairomone::Vocabulary.define_singleton_method(:subject_id) { |id| id == 'botany' ? nil : real.call(id) }
    error = assert_raises(Kairomone::Error) { Kairomone::Host.new.fusion_accept(plan: plan, candidate: 0) }
    assert_match(/botany/, error.message)
    refute_includes listing, 'pip'
  ensure
    Kairomone::Vocabulary.define_singleton_method(:subject_id, real) if real
  end

  def test_accept_judges_the_profile_by_the_rules_current_then
    parents
    heads, entries = material
    plan = propose(heads, entries)[:plan]
    real = Kairomone::Vocabulary.method(:kinds)
    Kairomone::Vocabulary.define_singleton_method(:kinds) { real.call - ['imaginary'] }
    assert_raises(Kairomone::Error) { Kairomone::Host.new.fusion_accept(plan: plan, candidate: 0) }
    refute_includes listing, 'pip'
  ensure
    Kairomone::Vocabulary.define_singleton_method(:kinds, real) if real
  end

  def test_the_child_is_a_new_identity_and_host_governance_applies
    parents
    heads, entries = material
    error = assert_raises(Kairomone::Error) { propose(heads, entries, child: 'alpha') }
    assert_match(/already listed/, error.message)
    plan = propose(heads, entries)[:plan]
    File.write(File.join(@host, 'skills/config.yml'), { 'layers' => { 'L1' => { 'enabled' => false } } }.to_yaml)
    error = assert_raises(Kairomone::Error) { Kairomone::Host.new.fusion_accept(plan: plan, candidate: 0) }
    assert_match(/governance/, error.message)
    refute_includes listing, 'pip'
  end

  def test_a_copy_of_a_fused_child_still_holds_its_parents_content
    parents
    heads, entries = material
    Kairomone::Host.new.fusion_accept(plan: propose(heads, entries)[:plan], candidate: 0)
    child = Kairomone::Instance.new(host_root: @host, kairomone: 'pip')
    out = child.exchange_export(file_sha256: child.exchange_preview(include: %w[inherited])[:file_sha256])
    FileUtils.mkdir_p(File.join(@host, 'kairomone-inbox'))
    FileUtils.cp(out[:path], File.join(@host, 'kairomone-inbox', out[:file]))
    Kairomone::Host.new.import_exchange(file: out[:file], listing_id: 'pip_copy')
    copy = Kairomone::Instance.new(host_root: @host, kairomone: 'pip_copy')
    copy.create_knowledge(id: 'again', title: 'Tea again', content: 'Brew green tea at 70 degrees.')
    assert_equal 0, copy.progression_status[:unique_l1], 'the parents\' source is held in the copy too'
  end

  def test_a_grandchild_holds_what_its_parents_held
    parents
    heads, entries = material
    Kairomone::Host.new.fusion_accept(plan: propose(heads, entries)[:plan], candidate: 0)
    create('delta').create_knowledge(id: 'sky', title: 'Sky', content: 'The sky is wide.')
    host = Kairomone::Host.new
    first = host.fusion_material(parents: %w[pip delta])
    items = first[:items] + (2..first[:pages]).flat_map { |n| host.fusion_material(parents: %w[pip delta], page: n)[:items] }
    tea = items.find { |i| i['item'] == 'entry' && i['parent'] == 'pip' && i['id'] == 'tea' }
    plan = host.fusion_propose(parents: %w[pip delta], child: 'kit', profile: CHILD, heads: first[:heads],
                               candidates: %w[Gardener Herbalist Forager].map { |n| CRAFT.merge('name' => n) },
                               entries: [{ 'id' => 'tea', 'title' => 'Tea', 'content' => tea['body'], 'mode' => 'keep',
                                           'sources' => [{ 'parent' => 'pip', 'entry_id' => 'tea', 'sha256' => tea['sha256'] }] }])[:plan]
    host.fusion_accept(plan: plan, candidate: 0)
    kit = Kairomone::Instance.new(host_root: @host, kairomone: 'kit')
    kit.create_knowledge(id: 'again', title: 'Tea again', content: 'Brew green tea at 70 degrees.')
    assert_equal 0, kit.progression_status[:unique_l1], 'a grandparent\'s source stays held'
  end

  def test_a_copy_of_a_fused_child_names_its_parents
    parents
    heads, entries = material
    Kairomone::Host.new.fusion_accept(plan: propose(heads, entries)[:plan], candidate: 0)
    child = Kairomone::Instance.new(host_root: @host, kairomone: 'pip')
    out = child.exchange_export(file_sha256: child.exchange_preview(include: %w[inherited])[:file_sha256])
    FileUtils.mkdir_p(File.join(@host, 'kairomone-inbox'))
    FileUtils.cp(out[:path], File.join(@host, 'kairomone-inbox', out[:file]))
    Kairomone::Host.new.import_exchange(file: out[:file], listing_id: 'pip_copy')
    copy = Kairomone::Instance.new(host_root: @host, kairomone: 'pip_copy')
    lineage = Kairomone::Records.of_type(copy.chain, 'kairomone_lineage').last
    assert_equal ['pip'], lineage['sources'].map { |s| s['identity'] }
    assert_equal [%w[alpha beta]], lineage['ancestry'].select { |a| a['kind'] == 'fusion' }.map { |a| a['sources'].map { |s| s['identity'] } }
  end

  def test_an_old_plan_is_removed_when_another_is_proposed
    parents
    heads, entries = material
    old = propose(heads, entries)[:plan]
    path = File.join(@host, 'kairomone-fusion', "#{old}.json")
    File.utime(Time.now - 8 * 24 * 3600, Time.now - 8 * 24 * 3600, path)
    propose(heads, entries, child: 'pip_two')
    refute File.exist?(path)
  end

  def test_self_fusion_is_refused
    parents
    error = assert_raises(Kairomone::Error) { Kairomone::Host.new.fusion_material(parents: %w[alpha alpha]) }
    assert_match(/itself/, error.message)
  end

  def test_an_interrupted_fusion_leaves_nothing_listed
    parents
    heads, entries = material
    plan = propose(heads, entries)[:plan]
    Kairomone::Instance.class_eval do
      alias_method :__write_l1_raw, :write_l1_raw
      define_method(:write_l1_raw) { |*| raise Kairomone::Error, 'interrupted' }
    end
    assert_raises(Kairomone::Error) { Kairomone::Host.new.fusion_accept(plan: plan, candidate: 0) }
    refute_includes listing, 'pip'
    assert_equal [], Dir.children(File.join(@host, 'kairomones/.staging'))
  ensure
    Kairomone::Instance.class_eval do
      alias_method :write_l1_raw, :__write_l1_raw
      remove_method :__write_l1_raw
    end
  end

  def test_an_inherited_learned_entry_stays_outside_content
    a, = parents
    growth = a.autonomy
    run = growth.run_start(owner_words: 'One', cycles: 1)
    growth.request(run_id: run[:run_id], token: run[:token], request_id: 'moss', topic: 'Moss')
    claim = growth.claim(run_id: run[:run_id], token: run[:token], worker_id: 'w')
    excerpt = 'Synthetic excerpt.'
    growth.commit(run_id: run[:run_id], token: run[:token], claim_token: claim['claim_token'],
                  evidence: { 'knowledge' => { 'title' => 'Moss study', 'content' => 'Moss study content' }, 'finding' => 'f', 'uncertainty' => 'u', 'counterexample' => 'c',
                              'sources' => [{ 'url' => 'https://example.com/a', 'title' => 'Fixture', 'retrieved_at' => Time.now.utc.iso8601, 'excerpt' => excerpt,
                                              'retrieval_reference' => 'fixture', 'excerpt_sha256' => Digest::SHA256.hexdigest(excerpt) }] })
    heads, entries = material
    learned = entries[%w[alpha growth_moss]]
    assert learned['outside']
    refute entries[%w[alpha tea]]['outside']
    plan = Kairomone::Host.new.fusion_propose(
      parents: %w[alpha beta], child: 'pip', profile: CHILD, candidates: %w[Gardener Herbalist Forager].map { |n| CRAFT.merge('name' => n) }, heads: heads,
      entries: [{ 'id' => 'moss', 'title' => 'Moss', 'content' => 'A merged moss note.', 'mode' => 'merge',
                  'sources' => [{ 'parent' => 'alpha', 'entry_id' => 'growth_moss', 'sha256' => learned['sha256'] }] }]
    )[:plan]
    Kairomone::Host.new.fusion_accept(plan: plan, candidate: 0)
    child = Kairomone::Instance.new(host_root: @host, kairomone: 'pip')
    body = KairosMcp::KnowledgeProvider.new(nil).get(child.transplant_knowledge(id: 'moss')[:host_name]).content
    assert body.start_with?("> #{Kairomone::Instance::TRANSPLANT_NOTICE}"), body
    assert_includes body, 'Origin: inherited by fusion from Kairomone alpha + beta'
  end

  def test_an_exported_child_imports_at_level_1
    parents
    heads, entries = material
    Kairomone::Host.new.fusion_accept(plan: propose(heads, entries)[:plan], candidate: 0)
    child = Kairomone::Instance.new(host_root: @host, kairomone: 'pip')
    out = child.exchange_export(file_sha256: child.exchange_preview(include: %w[inherited])[:file_sha256])
    FileUtils.mkdir_p(File.join(@host, 'kairomone-inbox'))
    FileUtils.cp(out[:path], File.join(@host, 'kairomone-inbox', out[:file]))
    Kairomone::Host.new.import_exchange(file: out[:file], listing_id: 'pip_copy')
    copy = Kairomone::Instance.new(host_root: @host, kairomone: 'pip_copy')
    assert_equal 2, copy.list_knowledge[:items].length
    assert_equal 1, copy.progression_status[:level]
  end

  def test_the_tool_runs_material_propose_summary_and_accept
    parents
    first = tool('Fusion', { 'command' => 'material', 'parents' => %w[alpha beta] })
    assert first['success'], first['error']
    _heads, entries = material
    proposed = tool('Fusion', { 'command' => 'propose', 'parents' => %w[alpha beta], 'kairomone' => 'pip', 'profile' => CHILD,
                                'candidates' => %w[Gardener Herbalist Forager].map { |n| CRAFT.merge('name' => n) },
                                'entries' => plan_entries(entries), 'heads' => first['heads'] })
    assert proposed['success'], proposed['error']
    assert_equal proposed['kept'], tool('Fusion', { 'command' => 'summary', 'plan' => proposed['plan'] })['kept']
    assert tool('Fusion', { 'command' => 'accept', 'plan' => proposed['plan'], 'candidate' => 2 })['fused']
  end
end
