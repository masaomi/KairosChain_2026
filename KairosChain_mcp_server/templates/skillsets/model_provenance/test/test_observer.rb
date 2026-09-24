# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'json'
require 'fileutils'
require 'rbconfig'
require_relative 'fixture_builder'

# Drives the real hook script as Claude Code would: JSON on stdin, environment
# variables, stdout/stderr/exit status observed from outside.
class TestObserver < Minitest::Test
  SCRIPT = File.expand_path('../hooks/observer.rb', __dir__)
  O55 = 'claude-opus-5-5'
  O5 = 'claude-opus-5'

  def setup
    @root = Dir.mktmpdir
    @project = File.join(@root, 'project')
    @data = File.join(@root, 'data')
    @projects = File.join(@root, 'projects')
    FileUtils.mkdir_p([@project, @data, @projects])
    @sid = 'sess-0001'
    @main = File.join(@projects, "#{@sid}.jsonl")
    @subdir = File.join(@projects, @sid, 'subagents')
    FileUtils.mkdir_p(@subdir)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def env(extra = {})
    { 'CLAUDE_PROJECT_DIR' => @project, 'KAIROS_DATA_DIR' => @data }.merge(extra)
  end

  def hook(input, env_vars = env)
    out, err, status = Open3.capture3(env_vars, RbConfig.ruby, SCRIPT, stdin_data: JSON.generate(input),
                                                                      unsetenv_others: false)
    [out, err, status.exitstatus]
  end

  def stop(extra = {})
    hook({ 'hook_event_name' => 'Stop', 'session_id' => @sid, 'transcript_path' => @main,
           'last_assistant_message' => '', 'background_tasks' => [] }.merge(extra))
  end

  def notice(out)
    out.empty? ? nil : JSON.parse(out)['systemMessage']
  end

  def subagent(id, fixture)
    fixture.write(File.join(@subdir, "agent-#{id}.jsonl"))
  end

  def test_first_stop_announces_the_observer_once_and_a_clean_session_then_says_nothing
    TranscriptFixture.new.user('hi').response(O55, 'r1', text: 'done').write(@main)
    out, err, code = stop
    assert_equal 0, code, err
    assert_match(/active/, notice(out))
    out, _err, code = stop
    assert_equal 0, code
    assert_equal '', out, 'a clean session after the first turn prints nothing'
  end

  def test_a_subagent_fallback_is_reported_once
    TranscriptFixture.new.user('hi').response(O55, 'r1').write(@main)
    subagent('aaa111', TranscriptFixture.new.user('task').response(O55, 's1')
                                        .marker(O55, O5, 'sm').response(O5, 's2').response(O5, 's3'))
    out, = stop
    assert_match(%r{2/3 new response\(s\) answered by claude-opus-5 \(automatic fallback from claude-opus-5-5\)},
                 notice(out))
    out, = stop
    assert_equal '', out, 'the same responses are not reported twice'
  end

  def test_a_running_subagent_is_named_as_pending_and_observed_after_it_stops
    TranscriptFixture.new.user('hi').response(O55, 'r1').write(@main)
    stop # consume the one-time announcement
    sub = TranscriptFixture.new.user('task').response(O55, 's1').marker(O55, O5, 'sm').response(O5, 's2')
    subagent('bbb222', sub)
    running = [{ 'id' => 'bbb222', 'type' => 'subagent', 'status' => 'running' }]
    out, = stop('background_tasks' => running)
    assert_match(/still running, not yet observed/, notice(out))
    out, = stop('background_tasks' => running)
    assert_equal '', out, 'pending is shown once per run'
    out, = stop
    assert_match(/answered by claude-opus-5/, notice(out))
  end

  def test_the_stop_backstop_writes_a_record_a_binding_can_resolve
    TranscriptFixture.new.user('hi').response(O55, 'r1').write(@main)
    subagent('ccc333', TranscriptFixture.new.user('task').response(O5, 's1'))
    stop
    recs = Dir.glob(File.join(@data, 'model_provenance', @sid, 'observation-agent_ccc333-*.json'))
    assert_equal 1, recs.size
    rec = JSON.parse(File.read(recs.first))
    assert_equal({ O5 => 1 }, rec['models'])
    assert_equal 'claude_code:stop_backstop', rec['detected_by']
  end

  def test_subagent_stop_records_the_latest_run_only
    path = subagent('ddd444', TranscriptFixture.new.user('task').response(O55, 's1').marker(O55, O5, 'sm')
                                       .response(O5, 's2')
                                       .resume('The coordinator sent a message while you were working')
                                       .response(O55, 's3', text: 'second run done'))
    out, err, code = hook('hook_event_name' => 'SubagentStop', 'session_id' => @sid, 'agent_id' => 'ddd444',
                          'agent_type' => 'general-purpose', 'agent_transcript_path' => path,
                          'last_assistant_message' => 'second run done')
    assert_equal 0, code, err
    assert_equal '', out, 'SubagentStop never prints (its display location is undocumented)'
    rec = JSON.parse(File.read(Dir.glob(File.join(@data, 'model_provenance', @sid, 'observation-agent_ddd444-*.json')).first))
    assert_equal 2, rec['run']
    assert_equal({ O55 => 1 }, rec['models'])
    assert_equal true, rec['complete']
  end

  def test_subagent_stop_marks_a_missing_final_response_incomplete
    path = subagent('eee555', TranscriptFixture.new.user('task').response(O55, 's1', text: 'earlier'))
    hook('hook_event_name' => 'SubagentStop', 'session_id' => @sid, 'agent_id' => 'eee555',
         'agent_type' => 'general-purpose',
         'agent_transcript_path' => path, 'last_assistant_message' => 'final words not yet flushed')
    rec = JSON.parse(File.read(Dir.glob(File.join(@data, 'model_provenance', @sid, 'observation-agent_eee555-*.json')).first))
    assert_equal false, rec['complete']
  end

  # The flush race that matters: the final response is half written at Stop
  # (its first record is in the file, its text record is not). Counting it
  # then and again when the rest arrives would count one response twice.
  def test_a_half_written_final_response_is_deferred_and_counted_once
    TranscriptFixture.new.user('hi').response(O55, 'r1').marker(O55, O5, 'rm').response(O5, 'r2').write(@main)
    stop # announcement, and r2
    half = TranscriptFixture.new.user('next')
                            .assistant(O5, 'r3', [{ 'type' => 'thinking', 'thinking' => '' }])
    File.write(@main, File.read(@main) + half.to_s)
    out, = stop('last_assistant_message' => 'final')
    first = notice(out).to_s
    rest = TranscriptFixture.new.assistant(O5, 'r3', [{ 'type' => 'text', 'text' => 'final' }])
    File.write(@main, File.read(@main) + rest.to_s)
    out, = stop('last_assistant_message' => 'final')
    second = notice(out).to_s
    counted = [first, second].join("\n").scan(%r{(\d+)/\d+ new response}).flatten.map(&:to_i).sum
    assert_equal 1, counted, "r3 must be counted exactly once (got: #{first.inspect} / #{second.inspect})"
  end

  # C10: a written prefix of the final text is not the final text.
  def test_a_prefix_of_the_final_text_does_not_count_as_complete
    TranscriptFixture.new.user('hi').response(O55, 'r1').marker(O55, O5, 'rm').response(O5, 'r2').write(@main)
    stop
    File.write(@main, File.read(@main) + TranscriptFixture.new.user('next')
                                                         .assistant(O5, 'r3', [{ 'type' => 'text', 'text' => 'Hello' }]).to_s)
    out, = stop('last_assistant_message' => 'Hello world')
    first = notice(out).to_s
    File.write(@main, File.read(@main) + TranscriptFixture.new.assistant(O5, 'r3', [{ 'type' => 'text', 'text' => 'world' }]).to_s)
    out, = stop('last_assistant_message' => 'Hello world')
    counted = [first, notice(out).to_s].join("\n").scan(%r{(\d+)/\d+ new response}).flatten.map(&:to_i).sum
    assert_equal 1, counted
  end

  # C9/C12: a failure in one transcript neither loses the others' lines nor
  # swallows the one-time announcement.
  def test_one_unreadable_transcript_does_not_lose_other_lines_or_the_announcement
    TranscriptFixture.new.user('hi').response(O55, 'r1').marker(O55, O5, 'rm').response(O5, 'r2').write(@main)
    bad = subagent('fff666', TranscriptFixture.new.user('t').response(O55, 's1'))
    File.chmod(0o000, bad)
    begin
      out, err, code = stop
      assert_equal 0, code, err
      msg = notice(out)
      assert_match(/active/, msg)
      assert_match(%r{main session: 1/2 new response}, msg)
      assert_match(/not observed — transcript could not be read/, msg)
    ensure
      File.chmod(0o644, bad)
    end
    out, = stop
    refute_match(/main session/, notice(out).to_s, 'the main lines were committed once, not lost or repeated')
  end

  # A whole Stop that fails (here: the store cannot be written) commits
  # nothing, so the next successful Stop still makes the announcement and
  # still reports the responses the failed one had read.
  def test_a_failed_first_stop_commits_nothing
    TranscriptFixture.new.user('hi').response(O55, 'r1').marker(O55, O5, 'rm').response(O5, 'r2').write(@main)
    store = File.join(@data, 'model_provenance')
    FileUtils.mkdir_p(store)
    File.chmod(0o500, store)
    begin
      out, _err, code = stop
      assert_equal [1, ''], [code, out]
    ensure
      File.chmod(0o755, store)
    end
    out, = stop
    msg = notice(out).to_s
    assert_match(/active/, msg)
    assert_match(%r{main session: 1/2 new response}, msg)
  end

  # C13: once per kind of cause, whatever the count.
  def test_unparsable_lines_are_reported_once_per_transcript
    File.write(@main, TranscriptFixture.new.user('hi').response(O55, 'r1').to_s + "{broken\n")
    out, = stop
    assert_match(/unreadable transcript line/, notice(out))
    File.write(@main, File.read(@main) + "{broken\n{broken\n")
    out, = stop
    refute_match(/unreadable transcript line/, notice(out).to_s)
  end

  # C9: workflow agents keep their transcripts one level deeper.
  def test_workflow_agent_transcripts_are_observed
    TranscriptFixture.new.user('hi').response(O55, 'r1').write(@main)
    dir = File.join(@subdir, 'workflows', 'wf_1')
    FileUtils.mkdir_p(dir)
    TranscriptFixture.new.user('t').response(O55, 's1').marker(O55, O5, 'sm').response(O5, 's2')
                     .write(File.join(dir, 'agent-ggg777.jsonl'))
    out, = stop
    assert_match(/answered by claude-opus-5/, notice(out))
  end

  # C11: a running subagent that has not written its transcript yet.
  def test_a_running_subagent_without_a_transcript_is_pending
    TranscriptFixture.new.user('hi').response(O55, 'r1').write(@main)
    stop
    out, = stop('background_tasks' => [{ 'id' => 'hhh888', 'type' => 'subagent', 'status' => 'running',
                                        'description' => 'persona x', 'agent_type' => 'general-purpose' }])
    assert_match(/persona x.*still running/, notice(out))
  end

  def test_internal_agents_leave_no_record
    hook('hook_event_name' => 'SubagentStop', 'session_id' => @sid, 'agent_id' => 'iii999', 'agent_type' => '',
         'agent_transcript_path' => File.join(@subdir, 'agent-iii999.jsonl'))
    assert_empty Dir.glob(File.join(@data, 'model_provenance', @sid, 'observation-*'))
  end

  # A SubagentStop record left incomplete is superseded by the Stop backstop.
  def test_an_incomplete_subagent_record_is_superseded_after_the_agent_stops
    path = subagent('jjj000', TranscriptFixture.new.user('t').response(O55, 's1', text: 'done'))
    hook('hook_event_name' => 'SubagentStop', 'session_id' => @sid, 'agent_id' => 'jjj000',
         'agent_type' => 'general-purpose', 'agent_transcript_path' => path,
         'last_assistant_message' => 'not written yet')
    TranscriptFixture.new.user('hi').response(O55, 'r1').write(@main)
    stop
    recs = Dir.glob(File.join(@data, 'model_provenance', @sid, 'observation-agent_jjj000-*.json')).sort
                 .map { |f| JSON.parse(File.read(f)) }
    assert_equal [false, true], recs.map { |r| r['complete'] }
  end

  # Round 2 (K7): a corrupt state file is not a permanent failure.
  def test_an_unreadable_state_file_restarts_observation_with_a_note
    TranscriptFixture.new.user('hi').response(O55, 'r1').marker(O55, O5, 'rm').response(O5, 'r2').write(@main)
    stop
    File.write(File.join(@data, 'model_provenance', @sid, 'observer_state.json'), '')
    out, err, code = stop
    assert_equal 0, code, err
    msg = notice(out)
    assert_match(/observer state was unreadable/, msg)
    assert_match(%r{main session: 1/2 new response}, msg, 're-read from the start')
    out, = stop
    assert_equal '', out, 'the rebuilt state is committed'
  end

  # Round 2 (K7): text that cannot be encoded does not fail the Stop.
  def test_invalid_bytes_in_a_subagent_description_do_not_fail_the_stop
    TranscriptFixture.new.user('hi').response(O55, 'r1').write(@main)
    subagent('mmm111', TranscriptFixture.new.user('t').response(O55, 's1').marker(O55, O5, 'sm').response(O5, 's2'))
    File.binwrite(File.join(@subdir, 'agent-mmm111.meta.json'), "{\"description\":\"bad \xFF byte\"}")
    out, err, code = stop
    assert_equal 0, code, err
    assert_match(/answered by claude-opus-5/, notice(out))
  end

  # Round 2 (K9): an incomplete record is superseded even when the transcript
  # has not grown since the last Stop read it.
  def test_an_incomplete_record_is_superseded_without_growth
    path = subagent('nnn222', TranscriptFixture.new.user('t').response(O55, 's1', text: 'done'))
    TranscriptFixture.new.user('hi').response(O55, 'r1').write(@main)
    stop # reads the subagent (cursor at its end) and writes a complete backstop record
    hook('hook_event_name' => 'SubagentStop', 'session_id' => @sid, 'agent_id' => 'nnn222',
         'agent_type' => 'general-purpose', 'agent_transcript_path' => path,
         'last_assistant_message' => 'not written yet')
    stop
    $LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
    require 'model_provenance'
    got = KairosMcp::SkillSets::ModelProvenance::ObservationStore.resolve_binding(@data, 'nnn222')
    assert_equal true, got['complete']
  end

  # Round 2 (K9, the state F2 exists for): only an incomplete record exists
  # and the cursor already sits at the end of the transcript (an earlier
  # backstop was lost). The next Stop still writes a complete one.
  def test_an_incomplete_only_record_with_the_cursor_at_the_end_gets_a_backstop
    path = subagent('ooo333', TranscriptFixture.new.user('t').response(O55, 's1', text: 'done'))
    TranscriptFixture.new.user('hi').response(O55, 'r1').write(@main)
    hook('hook_event_name' => 'SubagentStop', 'session_id' => @sid, 'agent_id' => 'ooo333',
         'agent_type' => 'general-purpose', 'agent_transcript_path' => path,
         'last_assistant_message' => 'not written yet')
    state = { 'announced' => true,
              'cursors' => { 'agent_ooo333' => { 'offset' => File.size(path), 'state' => { 'last_model' => O55 } } } }
    File.write(File.join(@data, 'model_provenance', @sid, 'observer_state.json'), JSON.generate(state))
    stop
    recs = Dir.glob(File.join(@data, 'model_provenance', @sid, 'observation-agent_ooo333-*.json')).sort
                 .map { |f| JSON.parse(File.read(f)) }
    assert_equal [false, true], recs.map { |r| r['complete'] }
  end

  # Round 2 (K8): the unsafe-id line is keyed by name, not position.
  def test_an_unsafe_id_line_is_not_repeated_when_another_transcript_sorts_before_it
    TranscriptFixture.new.user('hi').response(O55, 'r1').write(@main)
    stop
    TranscriptFixture.new.user('t').response(O55, 's1').write(File.join(@subdir, 'agent-b c.jsonl'))
    out, = stop
    assert_match(/not a safe identifier/, notice(out))
    TranscriptFixture.new.user('t').response(O55, 's1').write(File.join(@subdir, 'agent-a1.jsonl'))
    out, = stop
    refute_match(/not a safe identifier/, notice(out).to_s)
  end

  def test_post_model_switch_auto_tells_the_model_and_records_it
    out, err, code = hook('hook_event_name' => 'PostModelSwitch', 'session_id' => @sid,
                          'from_model' => O55, 'to_model' => O5, 'source' => 'auto')
    assert_equal 0, code, err
    assert_match(/You are now claude-opus-5/, out)
    rec = JSON.parse(File.read(Dir.glob(File.join(@data, 'model_provenance', @sid, 'switch-session-*.json')).first))
    assert_equal true, rec['told_model']
    out, = hook('hook_event_name' => 'PostModelSwitch', 'session_id' => @sid,
                'from_model' => O5, 'to_model' => O55, 'source' => 'command')
    assert_equal '', out, 'a requested switch needs no statement'
  end

  def test_unreadable_main_transcript_is_a_cause_line_not_silence
    File.write(@main, TranscriptFixture.new.user('hi').response(O55, 'r1').to_s + "{broken\n")
    out, = stop
    assert_match(/not observed — 1 unreadable transcript line/, notice(out))
  end

  def test_another_hosts_input_is_a_silent_no_op
    out, err, code = hook({ 'hook_event_name' => 'Stop', 'session_id' => @sid },
                          { 'CLAUDE_PROJECT_DIR' => nil, 'KAIROS_DATA_DIR' => @data, 'CODEX_HOME' => '/tmp' })
    assert_equal [0, '', ''], [code, out, err]
  end

  def test_unplaceable_input_is_a_visible_non_blocking_failure_with_nothing_on_stdout
    out, err, code = hook({ 'hook_event_name' => 'Stop', 'session_id' => @sid },
                          { 'CLAUDE_PROJECT_DIR' => nil, 'KAIROS_DATA_DIR' => @data })
    assert_equal 1, code
    assert_equal '', out
    assert_match(/model_provenance: .*CLAUDE_PROJECT_DIR/, err)

    out, err, code = hook({ 'hook_event_name' => 'Stop' })
    assert_equal [1, ''], [code, out]
    assert_match(/session_id/, err)

    out, _err, status = Open3.capture3(env, RbConfig.ruby, SCRIPT, stdin_data: 'not json')
    assert_equal [1, ''], [status.exitstatus, out]
  end

  def test_the_script_never_exits_two_or_emits_blocking_fields
    TranscriptFixture.new.user('hi').response(O55, 'r1').response(O5, 'r2').write(@main)
    out, _err, code = stop
    refute_equal 2, code
    parsed = JSON.parse(out)
    assert_equal ['systemMessage'], parsed.keys
  end
end
