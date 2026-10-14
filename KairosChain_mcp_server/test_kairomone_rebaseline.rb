#!/usr/bin/env ruby
# frozen_string_literal: true
# L0 re-baseline ruling. All data is synthetic and confined to temporary roots;
# the "upgrades" below rewrite only the temporary host's skills/ files.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'kairomone'
require 'tmpdir'
require 'stringio'
require 'open3'
require 'minitest/autorun'

class KairomoneRebaselineTest < Minitest::Test
  SCRIPT = File.expand_path('templates/skillsets/kairomone/scripts/kairomone.rb', __dir__)

  # A tty_in whose answer is computed when the prompt is read.
  class Answer
    def initialize(&block) = @block = block
    def gets = @block.call
  end

  class NeverRead
    def gets = raise('the nonce prompt must not be shown')
  end

  def setup
    @host = Dir.mktmpdir('kairomone-rebaseline-')
    KairosMcp.data_dir = @host
    write_l0('kairos.rb' => '# synthetic L0 rules v1', 'kairos.md' => '# synthetic philosophy v1')
    @store = Kairomone::Instance.new(host_root: @host)
    @store.init(dot_id: 'rebase_dot', display_name: 'Rebaseline fixture')
  end

  def teardown
    FileUtils.remove_entry_secure(@host) if File.directory?(@host)
  end

  def write_l0(files)
    FileUtils.mkdir_p(File.join(@host, 'skills'))
    files.each { |name, body| File.write(File.join(@host, 'skills', name), body) }
  end

  def blocks(store = @store) = store.chain.chain.length
  def host_l0(store = @store) = store.status[:integrity][:host_l0]

  def rule(store: @store, nonce: 'k7m3xp', typed: nonce, reason: 'synthetic upgrade', tty_in: nil)
    out = StringIO.new
    result = store.rebaseline_l0_interactive(tty_in: tty_in || StringIO.new("#{typed}\n"), tty_out: out, reason: reason, nonce: nonce)
    [result, out.string]
  end

  def evidence
    excerpt = 'Synthetic fixture excerpt, not actual research.'
    { 'knowledge' => { 'title' => 'Fixture synthesis', 'content' => 'Synthetic content for a re-baseline test.' },
      'finding' => 'Fixture finding.', 'uncertainty' => 'Fixture uncertainty.', 'counterexample' => 'Fixture counterexample.',
      'sources' => [{ 'url' => 'https://example.com/fixture', 'title' => 'Test fixture, not actual research',
                      'retrieved_at' => Time.now.utc.iso8601, 'excerpt' => excerpt,
                      'excerpt_sha256' => Digest::SHA256.hexdigest(excerpt), 'retrieval_reference' => 'fixture-only-source' }] }
  end

  def claim_one(id)
    growth = @store.autonomy
    growth.configure(max_cycles: 10, already_used: 0)
    growth.request(request_id: id, topic: "Topic #{id}", resume: true)
    growth.claim(worker_id: 'test_worker', lease_seconds: 60)['claim_token']
  end

  def test_fresh_instance_reads_the_init_baseline
    l0 = host_l0
    assert_equal 'unchanged', l0[:state]
    assert_equal({ 'kind' => 'init' }, l0[:baseline_source])
    assert_equal @store.profile['host_l0_baseline'], l0[:baseline]
    result, out = rule(tty_in: NeverRead.new)
    assert_equal false, result[:recorded]
    assert_equal 'unchanged', result[:reason]
    assert_includes out, 'Nothing to re-baseline'
    assert_equal 0, blocks
  end

  def test_changed_l0_blocks_growth_and_names_the_terminal_command
    profile_bytes = File.binread(File.join(@store.root, 'profile.json'))
    write_l0('kairos.md' => '# synthetic philosophy v2')
    l0 = host_l0
    assert_equal 'changed', l0[:state]
    assert(@store.status[:integrity][:details].any? { |d| d.include?('l0 rebaseline') && d.include?('An assistant never runs it') })
    token = claim_one('blocked')
    error = assert_raises(Kairomone::Error) { @store.autonomy.commit(claim_token: token, evidence: evidence) }
    assert_match(/L0 baseline unavailable or changed/, error.message)
    assert_equal profile_bytes, File.binread(File.join(@store.root, 'profile.json'))
  end

  def test_wrong_nonce_records_nothing
    write_l0('kairos.md' => '# synthetic philosophy v2')
    result, out = rule(typed: 'nope00')
    assert_equal false, result[:success]
    assert_equal 'nonce_mismatch', result[:reason]
    assert_includes out, 'Cancelled. Nothing was recorded.'
    assert_equal 0, blocks
    assert_equal 'changed', host_l0[:state]
  end

  def test_ruling_records_one_block_and_growth_resumes
    profile_bytes = File.binread(File.join(@store.root, 'profile.json'))
    before = @store.profile['host_l0_baseline']
    write_l0('kairos.md' => '# synthetic philosophy v2')
    @store.autonomy.configure(max_cycles: 10, already_used: 0)
    state_bytes = File.binread(File.join(@store.root, 'growth/state.json'))
    result, out = rule
    assert result[:success] && result[:recorded]
    assert_includes out, 'changed'
    assert_includes out, 'Recorded as block #1'
    assert_equal profile_bytes, File.binread(File.join(@store.root, 'profile.json')), 'profile.json stays create-only'
    assert_equal state_bytes, File.binread(File.join(@store.root, 'growth/state.json')), 'budget and stop state are untouched'
    event = JSON.parse(@store.chain.chain.last.data.first)
    assert_equal Kairomone::Instance::REBASELINE_KEYS.sort, event.keys.sort
    assert_equal before, event['previous']
    assert_equal @store.send(:l0_fingerprints), event['next']
    assert_equal 'terminal_nonce', event['attestation']
    assert_equal 'synthetic upgrade', event['reason']
    l0 = host_l0
    assert_equal 'unchanged', l0[:state]
    assert_equal 'ruling', l0[:baseline_source]['kind']
    assert_equal 1, l0[:baseline_source]['block']
    token = claim_one('after_ruling')
    assert_equal 'completed', @store.autonomy.commit(claim_token: token, evidence: evidence)['state']
    assert_equal 'unchanged', host_l0[:state], 'a later knowledge_update block does not disturb the fold'
  end

  def test_two_rulings_fold_in_order
    write_l0('kairos.md' => '# synthetic philosophy v2')
    assert rule[0][:recorded]
    write_l0('kairos.rb' => '# synthetic L0 rules v2')
    result, = rule(reason: 'second upgrade')
    assert result[:recorded]
    l0 = host_l0
    assert_equal 'unchanged', l0[:state]
    assert_equal 2, l0[:baseline_source]['block']
  end

  def test_l0_changing_after_display_records_nothing
    write_l0('kairos.md' => '# synthetic philosophy v2')
    answer = Answer.new do
      write_l0('kairos.md' => '# synthetic philosophy v3 slipped in')
      "k7m3xp\n"
    end
    error = assert_raises(Kairomone::Error) { rule(tty_in: answer) }
    assert_match(/changed after it was shown/, error.message)
    assert_equal 0, blocks
  end

  def test_live_claim_refuses_and_a_finished_claim_allows
    token = claim_one('in_flight')
    write_l0('kairos.md' => '# synthetic philosophy v2')
    error = assert_raises(Kairomone::Error) { rule }
    assert_match(/claim is active/, error.message)
    assert_equal 0, blocks
    @store.autonomy.fail(claim_token: token, reason: 'Fixture failure')
    assert rule[0][:recorded]
  end

  def test_expired_claim_does_not_block
    growth = @store.autonomy
    growth.configure(max_cycles: 10, already_used: 0)
    growth.request(request_id: 'expiring', topic: 'Expiry', resume: true)
    growth.claim(worker_id: 'test_worker', lease_seconds: 1)
    sleep 1.2
    write_l0('kairos.md' => '# synthetic philosophy v2')
    assert rule[0][:recorded]
    assert_equal 'expired', @store.autonomy.status['last_result']['state']
  end

  def test_restored_target_refuses
    backup = @store.create_backup
    @store.restore_backup(file: backup[:file], target_id: 'copy_one')
    restored = Kairomone::Instance.new(host_root: @host, restored_id: 'copy_one')
    write_l0('kairos.md' => '# synthetic philosophy v2')
    assert_raises(Kairomone::Error) { rule(store: restored) }
  end

  def test_file_absent_at_init_that_appears_reports_changed
    FileUtils.rm_f(File.join(@host, 'skills/kairos.rb'))
    FileUtils.rm_rf(@store.root)
    @store.init(dot_id: 'rebase_dot', display_name: 'One-file baseline')
    assert_equal ['skills/kairos.md'], @store.profile['host_l0_baseline'].keys
    write_l0('kairos.rb' => '# synthetic L0 rules appeared')
    assert_equal 'changed', host_l0[:state], 'v0.4.0 reported unchanged here while commit refused'
  end

  def test_masai_shape_one_file_baseline_to_two
    FileUtils.rm_f(File.join(@host, 'skills/kairos.rb'))
    FileUtils.rm_rf(@store.root)
    @store.init(dot_id: 'rebase_dot', display_name: 'Dots-era shape')
    write_l0('kairos.md' => '# new host philosophy', 'kairos.rb' => '# new host rules')
    result, out = rule(reason: 'migration from Dots')
    assert result[:recorded]
    assert_includes out, 'appeared'
    assert_equal ['skills/kairos.md'], result[:previous].keys
    assert_equal %w[skills/kairos.md skills/kairos.rb], result[:next].keys.sort
    assert_equal 'unchanged', host_l0[:state]
  end

  def test_empty_init_baseline_is_changed_once_l0_appears_and_a_ruling_fixes_it
    FileUtils.rm_rf(File.join(@host, 'skills'))
    FileUtils.rm_rf(@store.root)
    @store.init(dot_id: 'rebase_dot', display_name: 'Born without L0')
    assert_equal({}, @store.profile['host_l0_baseline'])
    assert_equal 'unavailable', host_l0[:state]
    assert_raises(Kairomone::Error) { rule(tty_in: NeverRead.new) }
    write_l0('kairos.md' => '# synthetic philosophy arrives')
    assert_equal 'changed', host_l0[:state]
    assert(@store.status[:integrity][:details].any? { |d| d.include?('l0 rebaseline') })
    result, = rule
    assert result[:recorded]
    assert_equal({}, result[:previous])
    assert_equal 'unchanged', host_l0[:state]
  end

  def test_ledger_timestamps_cannot_carry_control_characters_to_the_terminal
    write_l0('kairos.md' => '# synthetic philosophy v2')
    forged = { 'type' => 'kairomone_l0_rebaseline', 'schema_version' => 1, 'dot_id' => 'rebase_dot',
               'previous' => @store.profile['host_l0_baseline'], 'next' => @store.send(:l0_fingerprints),
               'reason' => 'crafted', 'host_kairos_chain_version' => '0.0.0', 'attested' => true,
               'attestation' => 'terminal_nonce', 'ruled_at' => "2026-10-14T00:00:00Z\r" }
    @store.chain.add_block([JSON.generate(forged)])
    assert_equal 'unchanged', host_l0[:state], 'Time.iso8601 accepts the trailing carriage return'
    write_l0('kairos.md' => '# synthetic philosophy v3')
    _, out = rule(typed: 'cancel')
    refute_includes out, "\r"
    assert_includes out, '\\u000d'
  end

  def test_out_of_order_or_malformed_ruling_makes_the_baseline_unavailable
    write_l0('kairos.md' => '# synthetic philosophy v2')
    current = @store.send(:l0_fingerprints)
    forged = { 'type' => 'kairomone_l0_rebaseline', 'schema_version' => 1, 'dot_id' => 'rebase_dot',
               'previous' => { 'skills/kairos.md' => 'a' * 64 }, 'next' => current, 'reason' => 'forged',
               'host_kairos_chain_version' => '0.0.0', 'attested' => true, 'attestation' => 'terminal_nonce',
               'ruled_at' => Time.now.utc.iso8601 }
    @store.chain.add_block([JSON.generate(forged)])
    l0 = host_l0
    assert_equal 'unavailable', l0[:state]
    assert_nil l0[:baseline]
    assert(@store.status[:integrity][:details].any? { |d| d.include?('does not follow') })
    token = claim_one('forged')
    assert_raises(Kairomone::Error) { @store.autonomy.commit(claim_token: token, evidence: evidence) }
    @store.autonomy.fail(claim_token: token, reason: 'Fixture')
    assert_raises(Kairomone::Error) { rule }
  end

  def test_malformed_ruling_makes_the_baseline_unavailable
    @store.chain.add_block([JSON.generate('type' => 'kairomone_l0_rebaseline', 'next' => {})])
    assert_equal 'unavailable', host_l0[:state]
    assert(@store.status[:integrity][:details].any? { |d| d.include?('malformed re-baseline ruling') })
  end

  def test_unreadable_ruling_bytes_make_the_baseline_unavailable
    @store.chain.add_block(['{"type":"kairomone_l0_rebaseline","previous":'])
    assert_equal 'unavailable', host_l0[:state]
    assert(@store.status[:integrity][:details].any? { |d| d.include?('unreadable re-baseline ruling') })
    token = claim_one('unreadable')
    assert_raises(Kairomone::Error) { @store.autonomy.commit(claim_token: token, evidence: evidence) }
  end

  def test_knowledge_named_like_the_ruling_type_does_not_disturb_the_fold
    assert @store.create_knowledge(id: 'kairomone_l0_rebaseline', title: 'Named like a ruling', content: 'Ordinary knowledge.')[:success]
    assert_equal 'unchanged', host_l0[:state]
  end

  def test_unreadable_ledger_makes_the_baseline_unavailable_and_refuses_commit
    token = claim_one('corrupt_ledger')
    File.write(File.join(@store.root, 'storage/blockchain.json'), '{broken')
    l0 = host_l0
    assert_equal 'unavailable', l0[:state]
    assert_nil l0[:baseline]
    assert_raises(Kairomone::Error) { @store.autonomy.commit(claim_token: token, evidence: evidence) }
  end

  def test_ruling_for_another_dot_makes_the_baseline_unavailable
    write_l0('kairos.md' => '# synthetic philosophy v2')
    forged = { 'type' => 'kairomone_l0_rebaseline', 'schema_version' => 1, 'dot_id' => 'other_dot',
               'previous' => @store.profile['host_l0_baseline'], 'next' => @store.send(:l0_fingerprints),
               'reason' => 'another dot', 'host_kairos_chain_version' => '0.0.0', 'attested' => true,
               'attestation' => 'terminal_nonce', 'ruled_at' => Time.now.utc.iso8601 }
    @store.chain.add_block([JSON.generate(forged)])
    assert_equal 'unavailable', host_l0[:state]
  end

  def test_baseline_ruled_elsewhere_between_display_and_code_records_nothing
    write_l0('kairos.md' => '# synthetic philosophy v2')
    answer = Answer.new do
      write_l0('kairos.md' => '# synthetic philosophy v3')
      other_terminal = Kairomone::Instance.new(host_root: @host)
      assert other_terminal.rebaseline_l0_interactive(tty_in: StringIO.new("zz\n"), tty_out: StringIO.new, reason: 'other terminal', nonce: 'zz')[:recorded]
      write_l0('kairos.md' => '# synthetic philosophy v2')
      "k7m3xp\n"
    end
    error = assert_raises(Kairomone::Error) { rule(tty_in: answer) }
    assert_match(/baseline in force changed/, error.message)
    assert_equal 1, @store.chain.chain.last.index, "only the other terminal's ruling is on the ledger"
  end

  def test_ruling_waits_for_the_growth_lock
    write_l0('kairos.md' => '# synthetic philosophy v2')
    held = Queue.new
    holder = Thread.new { @store.autonomy.synchronize { held << true; sleep 0.8 } }
    held.pop
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert rule[0][:recorded]
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.6
    holder.join
  end

  def test_default_reason_does_not_speak_for_the_owner
    write_l0('kairos.md' => '# synthetic philosophy v2')
    out = StringIO.new
    assert @store.rebaseline_l0_interactive(tty_in: StringIO.new("k7m3xp\n"), tty_out: out, nonce: 'k7m3xp')[:recorded]
    event = JSON.parse(@store.chain.chain.last.data.first)
    assert_equal 'No reason given at the terminal', event['reason']
  end

  def test_backup_and_restore_new_carry_the_ruling
    write_l0('kairos.md' => '# synthetic philosophy v2')
    assert rule[0][:recorded]
    backup = @store.create_backup
    Dir.mktmpdir('kairomone-rebaseline-new-') do |other|
      FileUtils.cp_r(File.join(@host, 'skills'), other)
      FileUtils.mkdir_p(File.join(other, 'kairomone-inbox'))
      FileUtils.cp(backup[:path], File.join(other, 'kairomone-inbox', backup[:file]))
      fresh = Kairomone::Instance.new(host_root: other)
      outcome = fresh.restore_new(file: backup[:file], dot_id: 'rebase_dot')
      assert outcome[:success]
      assert_nil outcome[:l0_warning]
      l0 = fresh.status[:integrity][:host_l0]
      assert_equal 'unchanged', l0[:state]
      assert_equal 'ruling', l0[:baseline_source]['kind']
    end
  end

  def test_terminal_text_cannot_carry_control_sequences
    FileUtils.rm_rf(@store.root)
    @store.init(dot_id: 'rebase_dot', display_name: "Name\e[2J\e[HNothing to re-baseline\u202E")
    write_l0('kairos.md' => '# synthetic philosophy v2')
    _, out = rule(typed: 'cancel', reason: "why\e[1A")
    refute_includes out, "\e"
    refute_includes out, "\u202E"
    assert_includes out, '\\u001b'
  end

  def test_overlong_reason_refused_before_the_prompt
    write_l0('kairos.md' => '# synthetic philosophy v2')
    assert_raises(Kairomone::Error) { rule(reason: 'x' * 513, tty_in: NeverRead.new) }
    assert_equal 0, blocks
  end

  def test_cli_without_a_terminal_refuses
    write_l0('kairos.md' => '# synthetic philosophy v2')
    lib = File.expand_path('lib', __dir__)
    out_r, out_w = IO.pipe
    pid = fork do
      Process.setsid # no controlling terminal, as for an assistant's shell tool
      out_r.close
      $stdout.reopen(out_w)
      $stdin.reopen(File::NULL)
      exec({ 'KAIROS_DATA_DIR' => @host }, RbConfig.ruby, '-I', lib, SCRIPT, 'l0', 'rebaseline', '--reason', 'cli')
    end
    out_w.close
    output = out_r.read
    _, status = Process.wait2(pid)
    refute status.success?
    assert_match(/needs a terminal/, JSON.parse(output)['error'])
    assert_equal 0, blocks
  end
end
