# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative 'fixture_builder'
require_relative '../hooks/transcript_reader'

class TestTranscriptReader < Minitest::Test
  R = ModelProvenanceHook::TranscriptReader
  O55 = 'claude-opus-5-5'
  O5 = 'claude-opus-5'

  def classify(fixture, scope: :subagent, switches: [])
    Dir.mktmpdir do |dir|
      path = fixture.write(File.join(dir, 't.jsonl'))
      read = R.read(path, scope: scope)
      [read, R.classify(read[:events], switches: switches)]
    end
  end

  # First observed shape: the marker shares its requestId with the flagged
  # request, whose first record was written by the original model.
  def test_marker_inside_the_flagged_request_counts_that_request_as_fallback
    f = TranscriptFixture.new.user('go')
                         .response(O55, 'r1').response(O55, 'r2')
                         .assistant(O55, 'r3', [{ 'type' => 'thinking', 'thinking' => '' }])
                         .marker(O55, O5, 'r3')
                         .assistant(O5, 'r3', [{ 'type' => 'text', 'text' => 'x' }])
                         .response(O5, 'r4')
    _read, c = classify(f)
    assert_equal 4, c[:responses]
    assert_equal({ O55 => 2, O5 => 2 }, c[:models])
    assert_equal [{ kind: 'fallback', from: O55, to: O5, responses: 2 }], c[:anomalies]
  end

  # Second observed shape: the marker has its own requestId and is not itself
  # a response.
  def test_marker_with_its_own_request_closes_the_response_before_it
    f = TranscriptFixture.new.user('go').response(O55, 'r1').response(O55, 'r2')
                         .marker(O55, O5, 'rm').response(O5, 'r3').response(O5, 'r4')
    _read, c = classify(f)
    assert_equal 4, c[:responses], 'the marker record is not a response'
    assert_equal [{ kind: 'fallback', from: O55, to: O5, responses: 2 }], c[:anomalies]
  end

  # A resumed run starts on the declared model again: a change of recognised
  # origin, not an anomaly, and a later marker is a new fallback.
  def test_resumed_run_returns_to_declared_model_without_anomaly
    f = TranscriptFixture.new.user('go').response(O55, 'r1').marker(O55, O5, 'rm')
                         .response(O5, 'r2').tool_result
                         .resume('The coordinator sent a message while you were working')
                         .response(O55, 'r3').marker(O55, O5, 'rm2').response(O5, 'r4')
    _read, c = classify(f)
    assert_equal 2, c[:state]['run']
    assert_equal [{ kind: 'fallback', from: O55, to: O5, responses: 2 }], c[:anomalies]
  end

  # Implementation review R1 (C9/C15/C21): a Skill body is written as a user
  # record; it is not a resume and must not end the fallback stretch.
  def test_a_harness_companion_record_is_not_a_resume
    f = TranscriptFixture.new.user('go').response(O55, 'r1').marker(O55, O5, 'rm').response(O5, 'r2')
                         .companion.response(O5, 'r3').response(O5, 'r4')
    _read, c = classify(f)
    assert_nil c[:state]['run']
    assert_equal [{ kind: 'fallback', from: O55, to: O5, responses: 3 }], c[:anomalies]
  end

  def test_the_agents_own_task_notification_is_not_a_resume_and_fallback_continues
    f = TranscriptFixture.new.user('go').response(O55, 'r1').marker(O55, O5, 'rm').response(O5, 'r2')
                         .task_notification.response(O5, 'r3')
    _read, c = classify(f)
    assert_nil c[:state]['run']
    assert_equal 2, c[:anomalies].first[:responses]
  end

  # A resume that leaves the agent on the fallback model is still fallback.
  def test_a_resume_on_the_fallback_model_keeps_counting_fallback
    f = TranscriptFixture.new.user('go').response(O55, 'r1').marker(O55, O5, 'rm').response(O5, 'r2')
                         .resume('more please').response(O5, 'r3')
    _read, c = classify(f)
    assert_equal 2, c[:state]['run']
    assert_equal 2, c[:anomalies].first[:responses]
  end

  # A quoted /model tag in a subagent or in ordinary text is not a model change.
  def test_a_quoted_model_tag_is_not_a_switch
    f = TranscriptFixture.new.user('go').response(O55, 'r1').marker(O55, O5, 'rm').response(O5, 'r2')
                         .resume('please explain <command-name>/model</command-name>').response(O55, 'r3')
    read, _c = classify(f)
    assert(read[:events].none? { |k, _p, _o| k == :user_switch })
    main = TranscriptFixture.new.user('go').response(O55, 'r1').marker(O55, O5, 'rm').response(O5, 'r2')
                            .user('what does <command-name>/model</command-name> do?').response(O5, 'r3')
    _read, c = classify(main, scope: :main)
    assert_equal 2, c[:anomalies].first[:responses]
  end

  # C15: a resume that is the first new record after the cursor.
  def test_a_resume_at_the_start_of_a_later_read_is_recognised
    Dir.mktmpdir do |dir|
      path = TranscriptFixture.new.user('go').response(O55, 'r1').marker(O55, O5, 'rm').response(O5, 'r2')
                              .write(File.join(dir, 't.jsonl'))
      first = R.read(path, scope: :subagent)
      c1 = R.classify(first[:events])
      File.write(path, File.read(path) + TranscriptFixture.new.resume('again').response(O55, 'r3').to_s)
      second = R.read(path, from: first[:end_offset], scope: :subagent, after_response: true)
      c2 = R.classify(second[:events], state: c1[:state])
      assert_empty c2[:anomalies], 'returning to the declared model at a resume is a recognised change'
    end
  end

  def test_a_local_model_command_counts_only_in_the_main_transcript
    f = TranscriptFixture.new.user('go').response(O55, 'r1').model_command('Opus 5').response(O5, 'r2')
    _read, c = classify(f, scope: :subagent)
    assert_equal 'unexplained', c[:anomalies].first[:kind]
  end

  def test_system_reminders_and_tool_results_do_not_start_a_run
    f = TranscriptFixture.new.user('go').response(O55, 'r1').tool_result
                         .user('<system-reminder>budget</system-reminder>').response(O55, 'r2')
    _read, c = classify(f)
    assert_nil c[:state]['run']
  end

  def test_a_model_command_is_a_change_of_recognised_origin
    f = TranscriptFixture.new.user('go').response(O55, 'r1').model_command('Opus 5').response(O5, 'r2')
    _read, c = classify(f, scope: :main)
    assert_empty c[:anomalies]
  end

  def test_a_change_with_no_recorded_cause_is_reported_as_unexplained
    f = TranscriptFixture.new.user('go').response(O55, 'r1').response(O5, 'r2').response(O5, 'r3')
    _read, c = classify(f, scope: :main)
    assert_equal [{ kind: 'unexplained', from: O55, to: O5, responses: 2 }], c[:anomalies]
  end

  def test_a_hook_reported_automatic_switch_names_its_origin
    f = TranscriptFixture.new.user('go').response(O55, 'r1').response(O5, 'r2')
    _read, c = classify(f, scope: :main,
                           switches: [{ 'at' => '2026-09-24T08:00:03.500Z', 'source' => 'auto', 'to' => O5 }])
    assert_equal 'automatic', c[:anomalies].first[:kind]
    _read, c = classify(f, scope: :main,
                           switches: [{ 'at' => '2026-09-24T08:00:03.500Z', 'source' => 'command', 'to' => O5 }])
    assert_empty c[:anomalies]
  end

  def test_synthetic_records_are_not_responses_even_with_a_request_id
    f = TranscriptFixture.new.user('go').response(O55, 'r1').synthetic('rx').synthetic.response(O55, 'r2')
    _read, c = classify(f)
    assert_equal 2, c[:responses]
    assert_empty c[:anomalies]
  end

  def test_a_line_still_being_written_is_not_consumed
    Dir.mktmpdir do |dir|
      path = File.join(dir, 't.jsonl')
      body = TranscriptFixture.new.user('go').response(O55, 'r1').to_s
      File.write(path, body + '{"type":"assistant","requestId":"r2"')
      read = R.read(path)
      assert read[:torn_tail]
      assert_equal body.bytesize, read[:end_offset]
    end
  end

  def test_unparsable_lines_are_counted_not_skipped_silently
    f = TranscriptFixture.new.user('go').raw('{not json').response(O55, 'r1')
    read, _c = classify(f)
    assert_equal 1, read[:unparsable]
  end

  def test_reading_from_an_offset_continues_the_anomaly_through_state
    f = TranscriptFixture.new.user('go').response(O55, 'r1').marker(O55, O5, 'rm').response(O5, 'r2')
    Dir.mktmpdir do |dir|
      path = f.write(File.join(dir, 't.jsonl'))
      first = R.read(path, scope: :subagent)
      c1 = R.classify(first[:events])
      File.write(path, File.read(path) + TranscriptFixture.new.response(O5, 'r3').to_s)
      second = R.read(path, from: first[:end_offset], scope: :subagent)
      c2 = R.classify(second[:events], state: c1[:state])
      assert_equal [{ kind: 'fallback', from: O55, to: O5, responses: 1 }], c2[:anomalies]
    end
  end

  # The two real transcripts the design cites, when present on this machine.
  def test_real_first_fallback_transcript_when_available
    path = File.expand_path('~/.claude/projects/-Users-masa-forback-github-KairosChain-2026/' \
                            '0e7f7c4f-66bb-4a2d-98ef-362fae2c3941/subagents/agent-aa4454f492d12dc54.jsonl')
    skip 'real transcript not present' unless File.file?(path)

    c = R.classify(R.read(path, scope: :subagent)[:events])
    assert_equal 62, c[:responses]
    assert_equal [{ kind: 'fallback', from: O55, to: O5, responses: 56 }], c[:anomalies]
  end
end
