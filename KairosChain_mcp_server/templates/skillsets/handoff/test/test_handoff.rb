# frozen_string_literal: true

# Drives the real session-end hook and the real record script with fixture
# transcripts and hook JSON on stdin, against a temporary data directory:
#   ruby <this file>
require 'minitest/autorun'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'securerandom'
require 'date'

class TestHandoff < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  HOOK = File.join(ROOT, 'hooks', 'session_end.rb')
  RECORD = File.join(ROOT, 'scripts', 'record.rb')
  L2_SESSION = 'session_20261126_152911_686c8ed3'

  def setup
    @tmp = Dir.mktmpdir('handoff')
    @data = File.join(@tmp, 'project', '.kairos')
    FileUtils.mkdir_p(File.join(@data, 'context'))
    @claude = File.join(@tmp, 'claude')
    @sid = SecureRandom.uuid
    @transcript = File.join(@claude, 'projects', '-tmp-project', "#{@sid}.jsonl")
    FileUtils.mkdir_p(File.dirname(@transcript))
    File.write(@transcript, '')
    @config = File.join(@tmp, 'handoff.yml')
    @log = File.join(@tmp, 'project', 'command.log')
    write_config('log_file' => 'command.log')
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  # --- helpers ---------------------------------------------------------------

  def write_config(values)
    File.write(@config, YAML.dump('handoff' => values))
  end

  def env(extra = {})
    { 'KAIROS_DATA_DIR' => @data, 'HANDOFF_CONFIG' => @config, 'CLAUDE_CONFIG_DIR' => @claude,
      'CLAUDE_PROJECT_DIR' => File.join(@tmp, 'project'), 'CLAUDE_CODE_SESSION_ID' => @sid }.merge(extra)
  end

  def row(hash)
    File.write(@transcript, "#{JSON.generate(hash)}\n", mode: 'a')
  end

  def prompt(text)
    row('type' => 'user', 'uuid' => SecureRandom.uuid, 'message' => { 'role' => 'user', 'content' => text })
  end

  def reply(text, uuid: SecureRandom.uuid)
    row('type' => 'assistant', 'uuid' => uuid,
        'message' => { 'role' => 'assistant', 'content' => [{ 'type' => 'thinking', 'thinking' => 'hidden-thought' },
                                                            { 'type' => 'text', 'text' => text }] })
  end

  def tool_round
    row('type' => 'assistant', 'uuid' => SecureRandom.uuid,
        'message' => { 'content' => [{ 'type' => 'tool_use', 'name' => 'Bash', 'input' => {} }] })
    row('type' => 'user', 'uuid' => SecureRandom.uuid,
        'message' => { 'content' => [{ 'type' => 'tool_result', 'content' => 'tool-output-sentinel' }] })
  end

  def exit_rows
    row('type' => 'user', 'isMeta' => true, 'uuid' => SecureRandom.uuid,
        'message' => { 'content' => '<local-command-caveat>caveat</local-command-caveat>' })
    row('type' => 'user', 'uuid' => SecureRandom.uuid,
        'message' => { 'content' => "<command-name>/exit</command-name>\n<command-message>exit</command-message>\n<command-args></command-args>" })
    row('type' => 'user', 'uuid' => SecureRandom.uuid,
        'message' => { 'content' => '<local-command-stdout>See ya!</local-command-stdout>' })
  end

  def name_session(title)
    row('type' => 'custom-title', 'customTitle' => title)
  end

  def end_session(reason: 'prompt_input_exit', transcript: @transcript, sid: @sid, extra_env: {})
    input = { 'session_id' => sid, 'transcript_path' => transcript, 'cwd' => @tmp,
              'hook_event_name' => 'SessionEnd', 'reason' => reason }
    Open3.capture3(env(extra_env), 'ruby', HOOK, stdin_data: JSON.generate(input))
  end

  def save_l2(name, frontmatter = {}, session: L2_SESSION)
    dir = File.join(@data, 'context', session, name)
    FileUtils.mkdir_p(dir)
    fm = { 'name' => name, 'type' => 'handoff', 'status' => 'pending' }.merge(frontmatter)
    File.write(File.join(dir, "#{name}.md"), "#{YAML.dump(fm)}---\n\n# body\n")
  end

  def record(*args, extra_env: {})
    Open3.capture3(env(extra_env), 'ruby', RECORD, *args)
  end

  def log
    File.exist?(@log) ? File.read(@log) : nil
  end

  def conversation
    prompt('first question')
    reply('first answer')
    prompt("please hand off\nsecond line")
    tool_round
    reply("L2 に保存しました。\n\n次は設計文書を読みます。")
  end

  # --- session end -------------------------------------------------------------

  def test_session_end_writes_last_turn_and_named_resume_command
    conversation
    name_session('other_than_mcp_20261126')
    exit_rows
    _, err, status = end_session
    assert status.success?, err
    text = log
    assert_match(/^# \[session end\] \d{4}-\d\d-\d\d \d\d:\d\d \(prompt_input_exit\)$/, text)
    assert_includes text, "# ❯ please hand off\n#   second line\n"
    assert_includes text, "# ⏺ L2 に保存しました。\n#\n#   次は設計文書を読みます。\n"
    assert_includes text, "# L2 handoff: none saved in this session\n"
    assert text.end_with?("# Resume this session with:\n# claude --resume #{@sid}\nclaude --resume \"other_than_mcp_20261126\"\n")
    refute_includes text, 'first answer'
    refute_includes text, 'hidden-thought'
    refute_includes text, 'tool-output-sentinel'
    refute_includes text, 'See ya!'
  end

  def test_unnamed_session_resumes_by_id_as_the_only_live_line
    conversation
    end_session
    live = log.lines.reject { |l| l.start_with?('#') || l.strip.empty? }
    assert_equal ["claude --resume #{@sid}\n"], live
  end

  def test_slash_command_prompt_is_shown_by_its_name
    prompt('earlier')
    reply('earlier answer')
    row('type' => 'user', 'uuid' => SecureRandom.uuid,
        'message' => { 'content' => "<command-message>handoff</command-message>\n<command-name>/handoff</command-name>\n<command-args>mmp topic</command-args>" })
    row('type' => 'user', 'isMeta' => true, 'uuid' => SecureRandom.uuid,
        'message' => { 'content' => [{ 'type' => 'text', 'text' => 'skill-body-sentinel' }] })
    reply('saved')
    exit_rows
    end_session
    assert_includes log, "# ❯ /handoff mmp topic\n#\n# ⏺ saved\n"
    refute_includes log, 'skill-body-sentinel'
  end

  def test_recap_is_copied_when_present
    conversation
    row('type' => 'system', 'subtype' => 'away_summary', 'uuid' => SecureRandom.uuid, 'content' => "recap line\nmore")
    end_session
    assert_includes log, "# ※ recap: recap line more\n"
  end

  def test_long_last_turn_keeps_its_end
    write_config('log_file' => 'command.log', 'last_turn_max_lines' => 3)
    prompt('q')
    reply((1..10).map { |i| "line #{i}" }.join("\n"))
    end_session
    assert_includes log, "# (the first 9 lines of the last turn are left out)\n#   line 8\n#   line 9\n#   line 10\n"
    refute_includes log, 'line 7'
  end

  def test_last_turn_off_writes_no_conversation_text
    write_config('log_file' => 'command.log', 'last_turn' => false)
    conversation
    end_session
    refute_includes log, '保存'
    assert_includes log, "claude --resume #{@sid}\n"
  end

  def test_no_log_file_configured_writes_nothing
    write_config('log_file' => nil)
    conversation
    _, err, status = end_session
    assert status.success?, err
    assert_nil log
    refute File.exist?(File.join(@data, 'storage'))
  end

  def test_reason_other_writes_nothing
    conversation
    _, _, status = end_session(reason: 'other')
    assert status.success?
    assert_nil log
  end

  def test_each_default_reason_writes
    %w[prompt_input_exit clear resume logout].each do |reason|
      FileUtils.rm_f(@log)
      FileUtils.rm_rf(File.join(@data, 'storage'))
      File.write(@transcript, '')
      conversation
      end_session(reason: reason)
      assert_includes log.to_s, "(#{reason})", reason
    end
  end

  def test_subagent_transcript_writes_nothing
    sub = File.join(File.dirname(@transcript), @sid, 'subagents', 'agent-1.jsonl')
    FileUtils.mkdir_p(File.dirname(sub))
    FileUtils.cp(@transcript, sub)
    conversation
    FileUtils.cp(@transcript, sub)
    end_session(transcript: sub)
    assert_nil log
  end

  def test_session_with_no_reply_writes_nothing
    prompt('hello')
    exit_rows
    end_session
    assert_nil log
  end

  def test_hook_running_twice_for_one_end_writes_one_block
    conversation
    exit_rows
    2.times { end_session }
    assert_equal 1, log.scan('[session end]').size
  end

  def test_resumed_and_left_without_a_new_turn_writes_no_second_block
    conversation
    exit_rows
    end_session
    exit_rows
    end_session
    assert_equal 1, log.scan('[session end]').size
  end

  def test_resumed_session_with_a_new_turn_writes_again
    conversation
    end_session
    prompt('one more')
    reply('done more')
    end_session
    assert_equal 2, log.scan('[session end]').size
    assert_includes log, '# ⏺ done more'
  end

  def test_existing_log_content_is_kept
    File.write(@log, "# 20261126 masa\nls -l\n")
    conversation
    end_session
    assert log.start_with?("# 20261126 masa\nls -l\n\n# [session end]")
  end

  def test_input_this_hook_cannot_read_ends_quietly_without_writing
    conversation
    ['not json', '[1, 2]', '{"hook_event_name":"SessionEnd"}', ''].each do |stdin|
      out, err, status = Open3.capture3(env, 'ruby', HOOK, stdin_data: stdin)
      assert_equal 0, status.exitstatus, stdin
      assert_empty err, stdin
      assert_empty out, stdin
    end
    out, err, status = end_session(sid: 'not-a-uuid')
    assert_equal 0, status.exitstatus
    assert_empty err + out
    assert_nil log
    refute File.exist?(File.join(@data, 'storage'))
  end

  def test_unreadable_config_still_fails_loudly
    conversation
    File.write(@config, "handoff: [not, a, mapping]\n")
    _, err, status = end_session
    assert_equal 1, status.exitstatus
    assert_includes err, 'handoff:'
    assert_nil log
  end

  def test_missing_log_directory_fails_and_leaves_the_end_unlogged
    write_config('log_file' => 'nowhere/command.log')
    conversation
    _, err, status = end_session
    assert_equal 1, status.exitstatus
    assert_includes err, 'does not exist'
    write_config('log_file' => 'command.log')
    end_session
    assert_equal 1, log.scan('[session end]').size
  end

  # --- record ------------------------------------------------------------------

  def test_record_fails_for_a_handoff_that_is_not_in_l2
    out, err, status = record('--name', 'handoff_missing_20261126', '--session', L2_SESSION)
    assert_equal 1, status.exitstatus
    assert_includes err, 'no such handoff in L2'
    assert_empty out
    assert_nil log
    refute File.exist?(File.join(@data, 'storage', 'handoff', "#{@sid}.json"))
  end

  def test_record_rejects_names_that_leave_the_context_directory
    save_l2('handoff_x_20261126')
    { '../handoff_x_20261126' => 'not an L2 name', 'a/b' => 'not an L2 name', '' => '--name is required' }.each do |bad, why|
      _, err, status = record('--name', bad)
      assert_equal 1, status.exitstatus, bad
      assert_includes err, why, bad
    end
    _, err, status = record('--name', 'handoff_x_20261126', '--session', '../context')
    assert_equal 1, status.exitstatus
    assert_includes err, 'not an L2 session id'
    assert_nil log
  end

  def test_record_appends_block_with_priority_and_commented_resume
    conversation
    name_session('mmp_20261126')
    save_l2('handoff_x_20261126', { 'importance' => 4, 'urgency' => 2, 'date' => Date.new(2026, 11, 26) })
    out, err, status = record('--name', 'handoff_x_20261126', '--session', L2_SESSION)
    assert status.success?, err
    assert_includes out, "handoff recorded: handoff_x_20261126 (L2 session #{L2_SESSION})"
    assert_includes out, "priority: importance 4/5, urgency 2/5 (the session's estimate)"
    assert_includes out, "block appended to #{@log}"
    assert_match(/\A\n# \[handoff\] \d{4}-\d\d-\d\d \d\d:\d\d\n# L2 handoff: handoff_x_20261126 \(#{L2_SESSION}\)\n# priority: importance 4\/5, urgency 2\/5 \(the session's estimate\)\n# claude --resume #{@sid}\n# claude --resume "mmp_20261126"\n\z/, log)
  end

  def test_record_finds_the_l2_session_when_not_given
    save_l2('handoff_x_20261126')
    out, _, status = record('--name', 'handoff_x_20261126')
    assert status.success?
    assert_includes out, "(L2 session #{L2_SESSION})"
  end

  def test_priority_out_of_range_or_not_an_integer_is_left_out
    save_l2('handoff_x_20261126', { 'importance' => 6, 'urgency' => 'high' })
    out, = record('--name', 'handoff_x_20261126')
    assert_includes out, 'priority: none read'
    refute_includes log, 'priority:'
    save_l2('handoff_y_20261126', { 'importance' => 0, 'urgency' => 5 })
    record('--name', 'handoff_y_20261126')
    assert_includes log, "# priority: urgency 5/5 (the session's estimate)\n"
  end

  def test_record_with_no_log_file_keeps_state_only
    write_config('log_file' => '')
    save_l2('handoff_x_20261126')
    out, _, status = record('--name', 'handoff_x_20261126')
    assert status.success?
    assert_includes out, 'log file: off'
    assert_nil log
    state = JSON.parse(File.read(File.join(@data, 'storage', 'handoff', "#{@sid}.json")))
    assert_equal ['handoff_x_20261126'], state['handoffs'].map { |h| h['name'] }
  end

  def test_record_without_claude_session_still_logs_the_l2_name
    save_l2('handoff_x_20261126')
    out, _, status = record('--name', 'handoff_x_20261126', extra_env: { 'CLAUDE_CODE_SESSION_ID' => '' })
    assert status.success?
    assert_includes out, 'Claude Code session: unknown'
    assert_includes log, '# L2 handoff: handoff_x_20261126'
    assert_includes log, 'no resume command'
    refute_includes log, 'claude --resume'
  end

  def test_recording_the_same_handoff_twice_lists_it_once_with_the_new_priority
    conversation
    save_l2('handoff_x_20261126', { 'importance' => 2, 'urgency' => 2 })
    record('--name', 'handoff_x_20261126')
    save_l2('handoff_x_20261126', { 'importance' => 5, 'urgency' => 1 })
    record('--name', 'handoff_x_20261126')
    FileUtils.rm_f(@log)
    end_session
    assert_equal 1, log.scan('# L2 handoff: handoff_x_20261126').size
    assert_includes log, "# priority: importance 5/5, urgency 1/5 (the session's estimate)\n"
  end

  # --- both --------------------------------------------------------------------

  def test_session_end_lists_the_handoffs_this_session_recorded_and_not_another_sessions
    conversation
    save_l2('handoff_a_20261126', { 'importance' => 3, 'urgency' => 4 })
    save_l2('handoff_b_20261126')
    save_l2('handoff_other_20261126')
    record('--name', 'handoff_a_20261126')
    record('--name', 'handoff_b_20261126')
    record('--name', 'handoff_other_20261126', extra_env: { 'CLAUDE_CODE_SESSION_ID' => SecureRandom.uuid })
    FileUtils.rm_f(@log)
    end_session
    text = log
    assert_match(/^# L2 handoff: handoff_a_20261126 \(#{L2_SESSION}\), saved \d{4}-\d\d-\d\d \d\d:\d\d\n# priority: importance 3\/5, urgency 4\/5/, text)
    assert_match(/^# L2 handoff: handoff_b_20261126 \(#{L2_SESSION}\), saved /, text)
    refute_includes text, 'handoff_other'
    refute_includes text, 'none saved'
  end

  # --- found by the pre-flight falsifier (2026-11-27) ----------------------------

  def test_hook_input_with_a_transcript_path_that_is_not_a_string_ends_quietly
    [123, { 'a' => 1 }, [1], "a\u0000b"].each do |path|
      input = { 'session_id' => @sid, 'transcript_path' => path, 'reason' => 'prompt_input_exit' }
      out, err, status = Open3.capture3(env, 'ruby', HOOK, stdin_data: JSON.generate(input))
      assert_equal 0, status.exitstatus, path.inspect
      assert_empty err + out, path.inspect
    end
    assert_nil log
  end

  def test_transcript_rows_in_an_unknown_shape_are_skipped
    prompt('real question')
    row('type' => 'user', 'uuid' => SecureRandom.uuid, 'message' => 'hi')
    row('type' => 'user', 'uuid' => SecureRandom.uuid, 'message' => { 'content' => [1, 'x', nil] })
    row('type' => 'user', 'uuid' => SecureRandom.uuid, 'message' => { 'content' => [{ 'type' => 'text', 'text' => 9 }] })
    reply('real answer')
    row('type' => 'assistant', 'uuid' => SecureRandom.uuid, 'message' => [1, 2])
    row('type' => 'assistant', 'uuid' => SecureRandom.uuid, 'message' => { 'content' => [3, { 'type' => 'text', 'text' => 7 }] })
    row('type' => 'assistant', 'uuid' => SecureRandom.uuid, 'message' => { 'content' => 'a string' })
    row('type' => 'custom-title', 'customTitle' => { 'x' => 1 })
    row('type' => 'system', 'subtype' => 'away_summary', 'content' => ['list'])
    _, err, status = end_session
    assert status.success?, err
    assert_includes log, "# ❯ real question\n#\n# ⏺ real answer\n"
  end

  def test_api_error_rows_are_not_answers
    prompt('hello')
    row('type' => 'assistant', 'uuid' => SecureRandom.uuid, 'isApiErrorMessage' => true,
        'message' => { 'content' => [{ 'type' => 'text', 'text' => 'API Error: 401 authentication_error' }] })
    end_session
    assert_nil log
    reply('a real answer')
    end_session
    prompt('again')
    row('type' => 'assistant', 'uuid' => SecureRandom.uuid, 'isApiErrorMessage' => true,
        'message' => { 'content' => [{ 'type' => 'text', 'text' => 'API Error: 500' }] })
    end_session
    assert_equal 1, log.scan('[session end]').size
    refute_includes log, 'API Error'
  end

  def test_control_characters_and_other_line_breaks_never_start_a_line_without_the_comment_mark
    prompt("ask\rtouch PWNED1")
    reply("done.\rtouch PWNED2\u2028touch PWNED3\u0085touch PWNED4\u2029touch PWNED5\e[2Jtouch\u0000x\vy\fz")
    row('type' => 'system', 'subtype' => 'away_summary', 'uuid' => SecureRandom.uuid, 'content' => "recap\rtouch PWNED6")
    end_session
    bytes = File.binread(@log).force_encoding('UTF-8')
    lines = bytes.split(/\r\n?|\n|\u2028|\u2029|\u0085|\v|\f/)
    live = lines.reject { |l| l.start_with?('#') || l.empty? }
    assert_equal ["claude --resume #{@sid}"], live
    refute_match(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f\u2028\u2029]/, bytes)
    (1..6).each { |i| assert_includes bytes, "PWNED#{i}" }
    # Each kind of line break starts a new note line, as a newline does.
    assert_includes bytes, "# ❯ ask\n#   touch PWNED1\n"
    assert_includes bytes, "# ⏺ done.\n#   touch PWNED2\n#   touch PWNED3\n#   touch PWNED4\n#   touch PWNED5 [2Jtouch x\n#   y\n#   z\n"
  end

  def test_title_that_is_not_plain_text_is_never_written_as_a_command
    ['--version', '-n', "x\u0015touch PWNED #", %q(it's $HOME "x"!), 'a;b', '$(id)', '`id`', "two\nlines",
     'a"b', 'a" --version "b', 'a!b', 'a\\b', 'a&b', 'a|b', 'a>b', 'a<b', 'a*b', 'a~b', 'a#b', "a'b", 'a=b', 'a?b',
     'a[b', 'a{b', 'a%b', 'a^b', 'a:b', 'a,b', 'a@b', 'a$b', 'a$HOME', '$HOME', 'a`b', 'a`id`b', 'a(b', 'a)b', 'a+b',
     '`id`x', '(a', '+a'].each do |title|
      FileUtils.rm_f(@log)
      FileUtils.rm_rf(File.join(@data, 'storage'))
      File.write(@transcript, '')
      conversation
      name_session(title)
      end_session
      live = File.binread(@log).force_encoding('UTF-8').split(/[\r\n]/).reject { |l| l.start_with?('#') || l.empty? }
      assert_equal ["claude --resume #{@sid}"], live, title.inspect
    end
  end

  def test_plain_title_in_another_script_is_written_as_a_quoted_command
    conversation
    name_session('引き継ぎ 2026-11-27')
    end_session
    assert log.end_with?("# claude --resume #{@sid}\nclaude --resume \"引き継ぎ 2026-11-27\"\n")
  end

  def test_record_refuses_a_handoff_path_that_is_not_a_regular_file
    FileUtils.mkdir_p(File.join(@data, 'context', L2_SESSION, 'handoff_d_20261126', 'handoff_d_20261126.md'))
    out, err, status = record('--name', 'handoff_d_20261126')
    assert_equal 1, status.exitstatus
    assert_includes err, 'no such handoff in L2'
    assert_empty out
    assert_nil log
  end

  def test_record_refuses_a_handoff_reached_through_a_link_that_leaves_the_context_directory
    outside = File.join(@tmp, 'outside')
    FileUtils.mkdir_p(File.join(outside, 'handoff_o_20261126'))
    File.write(File.join(outside, 'handoff_o_20261126', 'handoff_o_20261126.md'), "---\nimportance: 5\n---\n")
    File.symlink(outside, File.join(@data, 'context', 'linked_session'))
    [['--name', 'handoff_o_20261126'], ['--name', 'handoff_o_20261126', '--session', 'linked_session']].each do |args|
      out, _, status = record(*args)
      assert_equal 1, status.exitstatus, args.inspect
      assert_empty out
    end
    assert_nil log
  end

  def test_record_skips_an_l2_session_directory_whose_name_is_not_a_name
    dir = File.join(@data, 'context', "s1)\ntouch PWNED\n#", 'handoff_x_20261126')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'handoff_x_20261126.md'), "---\nimportance: 1\n---\n")
    out, _, status = record('--name', 'handoff_x_20261126')
    assert_equal 1, status.exitstatus
    assert_empty out
    assert_nil log
  end

  # The handoff exists where the unchecked value would point, so only the check refuses it.
  def test_record_refuses_session_and_name_values_that_would_reach_an_existing_file
    FileUtils.mkdir_p(File.join(@data, 'outside', 'handoff_x_20261126'))
    File.write(File.join(@data, 'outside', 'handoff_x_20261126', 'handoff_x_20261126.md'), "---\n---\n")
    _, err, status = record('--name', 'handoff_x_20261126', '--session', '../outside')
    assert_equal 1, status.exitstatus
    assert_includes err, 'not an L2 session id'

    FileUtils.mkdir_p(File.join(@data, 'context', 's2', 'x'))
    FileUtils.mkdir_p(File.join(@data, 'context', 's2', 's2'))
    File.write(File.join(@data, 'context', 's2', 's2', 'x.md'), "---\n---\n")
    FileUtils.mkdir_p(File.join(@data, 'context', 's1'))
    _, err, status = record('--name', '../s2/x', '--session', 's1')
    assert_equal 1, status.exitstatus
    assert_includes err, 'not an L2 name'
    assert_nil log
    refute File.exist?(File.join(@data, 'storage'))
  end

  def test_priority_that_is_not_a_whole_number_is_left_out
    save_l2('handoff_x_20261126', { 'importance' => 2.5, 'urgency' => '3' })
    out, = record('--name', 'handoff_x_20261126')
    assert_includes out, 'priority: none read'
    refute_includes log, 'priority:'
    state = JSON.parse(File.read(File.join(@data, 'storage', 'handoff', "#{@sid}.json")))
    assert_equal %w[at l2_session name], state['handoffs'].first.keys.sort
  end

  def test_log_file_that_is_not_text_is_a_config_fault_and_writes_nothing
    File.write(@config, "handoff:\n  log_file: off\n")
    conversation
    _, err, status = end_session
    assert_equal 1, status.exitstatus
    assert_includes err, 'log_file'
    assert_empty Dir.children(File.join(@tmp, 'project')) - ['.kairos']
  end

  # --- found in round 1 of the review (2026-11-27) -------------------------------

  def raw_row(line)
    File.binwrite(@transcript, line, mode: 'ab')
  end

  def run_hook(stdin, extra_env = {})
    Open3.capture3(env(extra_env), 'ruby', HOOK, stdin_data: stdin)
  end

  def hook_input(overrides = {})
    JSON.generate({ 'session_id' => @sid, 'transcript_path' => @transcript, 'cwd' => @tmp,
                    'hook_event_name' => 'SessionEnd', 'reason' => 'prompt_input_exit' }.merge(overrides))
  end

  def test_transcript_lines_that_are_not_rows_are_skipped
    conversation
    raw_row("[1,2]\n\"a string\"\n7\nnull\n\xFF\xFE not json\n")
    raw_row(%({"type":"assistant","uuid":"u-last","message":{"content":[{"type":"text","text":"ok \xFF end"}]}}\n))
    raw_row(%({"type":"assistant","uuid":"u-cut","message":{"content":[{"type":"text","te))
    out, err, status = end_session
    assert_equal 0, status.exitstatus, err
    assert_empty err + out
    assert_match(/^# ⏺ ok .? ?end$/, log)
  end

  def test_an_escaped_lone_surrogate_in_a_row_does_not_stop_the_hook
    raw_row(%({"type":"user","uuid":"u1","message":{"content":"q \\udc00 x"}}\n))
    raw_row(%({"type":"assistant","uuid":"u2","message":{"content":[{"type":"text","text":"a \\udc00 b"}]}}\n))
    raw_row(%({"type":"custom-title","customTitle":"t\\udc00"}\n))
    raw_row(%({"type":"system","subtype":"away_summary","uuid":"u3","content":"r \\udc00"}\n))
    out, err, status = end_session
    assert_equal 0, status.exitstatus, err
    assert_empty err + out
    assert_includes log, '# ❯ q '
    assert_includes log, '# ⏺ a '
    assert log.end_with?("claude --resume #{@sid}\n")
    assert log.valid_encoding?
  end

  def test_hook_input_with_bytes_that_are_not_text_ends_quietly
    conversation
    ["{\"session_id\":\"\xFF\"}", "{\"session_id\":\"#{@sid}\\ntouch PWNED\"}", "{\"session_id\":\"#{@sid} \"}",
     "{\"session_id\":[\"#{@sid}\"]}", "kein JSON: Gr\xC3\xBC\xC3\x9Fe", "\xFF\xFE",
     '{"session_id":"\udc00"}', '{"session_id":"a\udc00b","transcript_path":"\udc00","reason":"\udc00"}'].each do |stdin|
      out, err, status = run_hook(stdin)
      assert_equal 0, status.exitstatus, stdin.inspect
      assert_empty err + out, stdin.inspect
    end
    assert_nil log
    refute File.exist?(File.join(@data, 'storage'))
  end

  def test_a_locale_that_is_not_utf8_changes_nothing
    File.write(@config, "# 設定 — handoff\nhandoff:\n  log_file: 記録.log\n")
    @log = File.join(@tmp, 'project', '記録.log')
    prompt('日本語の問い')
    reply('日本語の答え')
    name_session('引き継ぎ')
    save_l2('handoff_x_20261126', { 'importance' => 4 })
    c_locale = { 'LC_ALL' => 'C', 'LANG' => 'C' }
    out, err, status = record('--name', 'handoff_x_20261126', extra_env: c_locale)
    assert_equal 0, status.exitstatus, err
    assert_includes out.dup.force_encoding('UTF-8'), '(引き継ぎ)'
    out, err, status = run_hook(hook_input('cwd' => '/Users/x/文書'), c_locale)
    assert_equal 0, status.exitstatus, err
    assert_empty err + out
    text = log
    assert_includes text, "# ❯ 日本語の問い\n#\n# ⏺ 日本語の答え\n"
    assert_includes text, "# L2 handoff: handoff_x_20261126"
    assert text.end_with?("claude --resume \"引き継ぎ\"\n")
  end

  def test_a_row_claude_code_wrote_in_the_models_place_is_not_an_answer
    synthetic = { 'type' => 'assistant', 'message' => { 'model' => '<synthetic>',
                                                       'content' => [{ 'type' => 'text', 'text' => 'No response requested.' }] } }
    prompt('hello')
    row(synthetic.merge('uuid' => SecureRandom.uuid))
    end_session
    assert_nil log
    reply('a real answer')
    end_session
    prompt('again')
    row(synthetic.merge('uuid' => SecureRandom.uuid))
    exit_rows
    end_session
    assert_equal 1, log.scan('[session end]').size
    assert_includes log, '# ⏺ a real answer'
    refute_includes log, 'No response requested.'
  end

  def test_rows_claude_code_wrote_as_the_user_are_not_the_operators_prompt
    prompt('typed question')
    row('type' => 'user', 'uuid' => SecureRandom.uuid,
        'message' => { 'content' => [{ 'type' => 'tool_result', 'content' => 'out' },
                                     { 'type' => 'text', 'text' => 'text the host put beside a tool result' }] })
    ['<task-notification><task-id>t1</task-id></task-notification>', '<bash-input>ls</bash-input>',
     '<bash-stdout>file</bash-stdout>', "  <local-command-stdout>out</local-command-stdout>",
     '<local-command-caveat>note</local-command-caveat>', '<system-reminder>r</system-reminder>'].each do |text|
      row('type' => 'user', 'uuid' => SecureRandom.uuid, 'message' => { 'content' => text })
    end
    reply('the answer')
    end_session
    assert_includes log, "# ❯ typed question\n#\n# ⏺ the answer\n"
    %w[task-notification bash-input bash-stdout local-command system-reminder beside].each { |tag| refute_includes log, tag }
  end

  def test_a_typed_prompt_that_mentions_command_markup_is_kept_as_typed
    prompt('What does <command-name>/help</command-name> mean?')
    reply('It is markup.')
    end_session
    assert_includes log, "# ❯ What does <command-name>/help</command-name> mean?\n"
  end

  def test_record_refuses_a_claude_session_value_that_is_not_an_id
    write_config('log_file' => '')
    save_l2('handoff_x_20261126')
    good = SecureRandom.uuid
    ["#{good}\ntouch PWNED", '../../escaped', 'x', "#{good} ", good.upcase].each do |bad|
      out, err, status = record('--name', 'handoff_x_20261126', '--claude-session', bad)
      assert_equal 1, status.exitstatus, bad.inspect
      assert_includes err, 'not a Claude Code session id', bad.inspect
      assert_equal 1, err.lines.size, bad.inspect
      assert_empty out
    end
    assert_empty Dir.glob(File.join(@data, '**', '*.json'))
    refute File.exist?(File.join(@data, 'storage'))
    write_config('log_file' => 'command.log')
    _, _, status = record('--name', 'handoff_x_20261126', '--claude-session', "#{good}\ntouch PWNED")
    assert_equal 1, status.exitstatus
    assert_nil log
  end

  def test_record_takes_the_session_named_on_the_command_line
    other = SecureRandom.uuid
    save_l2('handoff_x_20261126')
    out, err, status = record('--name', 'handoff_x_20261126', '--claude-session', other)
    assert_equal 0, status.exitstatus, err
    assert_includes out, "Claude Code session: #{other}"
    assert File.file?(File.join(@data, 'storage', 'handoff', "#{other}.json"))
    refute File.exist?(File.join(@data, 'storage', 'handoff', "#{@sid}.json"))
    assert_includes log, "# claude --resume #{other}\n"
  end

  def test_record_refuses_a_link_to_a_sibling_whose_name_starts_like_the_context_directory
    sibling = File.join(@data, 'context_old')
    FileUtils.mkdir_p(File.join(sibling, 'handoff_s_20261126'))
    File.write(File.join(sibling, 'handoff_s_20261126', 'handoff_s_20261126.md'), "---\n---\n")
    File.symlink(sibling, File.join(@data, 'context', 'linked'))
    out, _, status = record('--name', 'handoff_s_20261126', '--session', 'linked')
    assert_equal 1, status.exitstatus
    assert_empty out
    assert_nil log
  end

  def test_hooks_started_together_for_one_end_write_one_block
    conversation
    exit_rows
    results = Array.new(12) { Thread.new { end_session } }.map(&:value)
    results.each { |_, err, status| assert_equal 0, status.exitstatus, err }
    assert_equal 1, log.scan('[session end]').size
    state = JSON.parse(File.read(File.join(@data, 'storage', 'handoff', "#{@sid}.json")))
    assert_equal 1, state['ends'].size
  end

  def test_records_started_together_all_reach_the_state_and_the_log
    names = (1..12).map { |i| format('handoff_n%02d_20261126', i) }
    names.each { |n| save_l2(n) }
    results = names.map { |n| Thread.new { record('--name', n) } }.map(&:value)
    results.each { |_, err, status| assert_equal 0, status.exitstatus, err }
    state = JSON.parse(File.read(File.join(@data, 'storage', 'handoff', "#{@sid}.json")))
    assert_equal names, state['handoffs'].map { |h| h['name'] }.sort
    names.each { |n| assert_equal 1, log.scan("# L2 handoff: #{n} ").size, n }
    assert_empty Dir.glob(File.join(@data, 'storage', 'handoff', '*.tmp'))
  end

  def test_state_entries_in_an_unknown_shape_are_dropped
    conversation
    dir = File.join(@data, 'storage', 'handoff')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{@sid}.json"),
               JSON.generate('handoffs' => [1, nil, 'x', { 'name' => 'handoff_k_20261126', 'l2_session' => 's', 'at' => 't', 'importance' => 'high' }],
                             'ends' => [1, nil, 'x']))
    out, err, status = end_session
    assert_equal 0, status.exitstatus, err
    assert_empty err + out
    assert_includes log, "# L2 handoff: handoff_k_20261126 (s), saved t\n"
    refute_includes log, 'priority:'
    File.write(File.join(dir, "#{@sid}.json"), '{"handoffs": "nope", "ends": {"a": 1}}')
    reply('next')
    _, err, status = end_session
    assert_equal 0, status.exitstatus, err
    assert_equal 2, log.scan('[session end]').size
  end

  def test_replies_without_a_row_id_are_told_apart_by_their_text
    prompt('one')
    row('type' => 'assistant', 'message' => { 'content' => [{ 'type' => 'text', 'text' => 'first' }] })
    2.times { end_session }
    assert_equal 1, log.scan('[session end]').size
    prompt('two')
    row('type' => 'assistant', 'uuid' => '', 'message' => { 'content' => [{ 'type' => 'text', 'text' => 'second' }] })
    2.times { end_session }
    assert_equal 2, log.scan('[session end]').size
    assert_includes log, '# ⏺ second'
  end

  def test_only_the_configured_reasons_write_and_only_as_spelled
    write_config('log_file' => 'command.log', 'end_reasons' => ['logout'])
    conversation
    %w[clear prompt_input_exit resume other].each { |reason| end_session(reason: reason) }
    assert_nil log
    end_session(reason: 'logout')
    assert_equal 1, log.scan('(logout)').size

    write_config('log_file' => 'command.log')
    FileUtils.rm_f(@log)
    FileUtils.rm_rf(File.join(@data, 'storage'))
    ['Clear', 'cle', 'clear ', ' clear', 'clearx', ''].each { |reason| end_session(reason: reason) }
    run_hook(JSON.generate('session_id' => @sid, 'transcript_path' => @transcript))
    run_hook(hook_input('reason' => 123))
    run_hook(hook_input('reason' => ['clear']))
    run_hook(hook_input('reason' => nil))
    assert_nil log
  end

  def test_a_transcript_anywhere_under_a_subagents_directory_writes_nothing
    conversation
    sub = File.join(File.dirname(@transcript), @sid, 'subagents', 'workflows', 'wf_1', 'agent-1.jsonl')
    FileUtils.mkdir_p(File.dirname(sub))
    FileUtils.cp(@transcript, sub)
    end_session(transcript: sub)
    assert_nil log
  end

  def test_a_transcript_that_is_not_there_writes_nothing_and_says_nothing
    out, err, status = end_session(transcript: File.join(@tmp, 'gone.jsonl'))
    assert_equal 0, status.exitstatus
    assert_empty err + out
    out, err, status = run_hook(JSON.generate('session_id' => @sid, 'reason' => 'prompt_input_exit'))
    assert_equal 0, status.exitstatus
    assert_empty err + out
    assert_nil log
  end

  def test_config_values_of_the_wrong_type_are_faults_in_one_line
    conversation
    { "last_turn: 'false'" => 'last_turn', 'last_turn: 0' => 'last_turn', 'last_turn: no thanks' => 'last_turn',
      'end_reasons: [~]' => 'end_reasons', "end_reasons: ['']" => 'end_reasons', 'end_reasons: clear' => 'end_reasons',
      'end_reasons: [1]' => 'end_reasons', 'last_turn_max_lines: 0' => 'last_turn_max_lines',
      "log_file: '~no_such_user_zz/x'" => 'log_file' }.each do |line, word|
      File.write(@config, "handoff:\n  log_file: command.log\n  #{line}\n".sub(/log_file: command.log\n(?=  log_file)/, ''))
      out, err, status = end_session
      assert_equal 1, status.exitstatus, line
      assert_includes err, word, line
      assert_equal 1, err.lines.size, line
      assert_empty out
    end
    assert_nil log
    write_config('log_file' => 'command.log', 'last_turn' => false, 'end_reasons' => ['clear'])
    end_session(reason: 'clear')
    assert_equal 1, log.scan('[session end]').size
  end

  def test_record_that_cannot_write_the_log_records_nothing
    write_config('log_file' => 'nowhere/command.log')
    save_l2('handoff_x_20261126')
    out, err, status = record('--name', 'handoff_x_20261126')
    assert_equal 1, status.exitstatus
    assert_includes err, 'does not exist'
    assert_empty out
    refute File.exist?(File.join(@data, 'storage', 'handoff', "#{@sid}.json"))
  end

  def test_record_with_an_unknown_option_fails_in_one_line
    out, err, status = record('--nope')
    assert_equal 1, status.exitstatus
    assert_equal 1, err.lines.size
    assert err.start_with?('handoff: ')
    assert_empty out
    _, err, status = record('--name')
    assert_equal 1, status.exitstatus
    assert_equal 1, err.lines.size
  end

  def test_paths_with_pattern_characters_are_read_as_paths
    odd = File.join(@tmp, 'p[1] {a,b} *?')
    data = File.join(odd, '.kairos')
    claude = File.join(@tmp, 'c[2]')
    dir = File.join(data, 'context', L2_SESSION, 'handoff_x_20261126')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'handoff_x_20261126.md'), "---\nurgency: 2\n---\n")
    transcript = File.join(claude, 'projects', '-p', "#{@sid}.jsonl")
    FileUtils.mkdir_p(File.dirname(transcript))
    File.write(transcript, "#{JSON.generate('type' => 'custom-title', 'customTitle' => 'odd_paths')}\n")
    odd_env = { 'KAIROS_DATA_DIR' => data, 'CLAUDE_CONFIG_DIR' => claude }
    out, err, status = record('--name', 'handoff_x_20261126', extra_env: odd_env)
    assert_equal 0, status.exitstatus, err
    assert_includes out, '(odd_paths)'
    assert_includes File.read(File.join(odd, 'command.log')), "# claude --resume \"odd_paths\"\n"
  end

  # The record script runs in the Bash tool, which has no CLAUDE_PROJECT_DIR; the
  # hook has it. Both must write the same file all the same.
  def test_a_relative_log_file_is_one_file_for_both_writers_when_the_data_directory_is_elsewhere
    data = File.join(@tmp, 'elsewhere', 'data')
    dir = File.join(data, 'context', L2_SESSION, 'handoff_x_20261126')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'handoff_x_20261126.md'), "---\n---\n")
    conversation
    _, err, status = record('--name', 'handoff_x_20261126', extra_env: { 'KAIROS_DATA_DIR' => data, 'CLAUDE_PROJECT_DIR' => nil })
    assert_equal 0, status.exitstatus, err
    _, err, status = end_session(extra_env: { 'KAIROS_DATA_DIR' => data })
    assert_equal 0, status.exitstatus, err
    shared = File.read(File.join(@tmp, 'elsewhere', 'command.log'))
    assert_equal 1, shared.scan('[handoff]').size
    assert_equal 1, shared.scan('[session end]').size
    assert_includes shared, "# L2 handoff: handoff_x_20261126 (#{L2_SESSION}), saved "
    assert_nil log
  end

  # An installed copy, run the way the host runs it: no variable of ours set.
  def test_an_installed_copy_finds_its_own_places_without_our_variables
    project = File.join(@tmp, 'inst', 'my project')
    installed = File.join(project, '.kairos', 'skillsets', 'handoff')
    FileUtils.mkdir_p(File.dirname(installed))
    FileUtils.cp_r(ROOT, installed)
    File.write(File.join(installed, 'config', 'handoff.yml'), "handoff:\n  log_file: command.log\n")
    dir = File.join(project, '.kairos', 'context', L2_SESSION, 'handoff_x_20261126')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'handoff_x_20261126.md'), "---\nimportance: 3\n---\n")
    home = File.join(@tmp, 'home')
    transcript = File.join(home, '.claude', 'projects', '-my-project', "#{@sid}.jsonl")
    FileUtils.mkdir_p(File.dirname(transcript))
    FileUtils.rm_f(@transcript)
    @transcript = transcript
    conversation
    name_session('installed_copy')
    bare = { 'KAIROS_DATA_DIR' => nil, 'HANDOFF_CONFIG' => nil, 'CLAUDE_CONFIG_DIR' => nil, 'CLAUDE_PROJECT_DIR' => nil,
             'HOME' => home, 'CLAUDE_CODE_SESSION_ID' => @sid }
    out, err, status = Open3.capture3(bare, 'ruby', File.join(installed, 'scripts', 'record.rb'),
                                      '--name', 'handoff_x_20261126', chdir: @tmp)
    assert_equal 0, status.exitstatus, err
    assert_includes out, '(installed_copy)'
    assert_includes out, "block appended to #{File.join(File.realpath(project), 'command.log')}"

    command = JSON.parse(File.read(File.join(ROOT, 'plugin', 'hooks.json'))).dig('hooks', 'SessionEnd', 0, 'hooks', 0, 'command')
    out, err, status = Open3.capture3(bare.merge('CLAUDE_PROJECT_DIR' => project), 'sh', '-c', command,
                                      stdin_data: hook_input, chdir: @tmp)
    assert_equal 0, status.exitstatus, err
    assert_empty err + out
    text = File.read(File.join(project, 'command.log'))
    assert_equal 1, text.scan('[handoff]').size
    assert_equal 1, text.scan('[session end]').size
    assert_includes text, "# L2 handoff: handoff_x_20261126 (#{L2_SESSION}), saved "
    assert text.end_with?("claude --resume \"installed_copy\"\n")
    assert File.file?(File.join(project, '.kairos', 'storage', 'handoff', "#{@sid}.json"))

    # Where no copy is installed, the same command does nothing and says nothing.
    out, err, status = Open3.capture3(bare.merge('CLAUDE_PROJECT_DIR' => File.join(@tmp, 'no such project')), 'sh', '-c',
                                      command, stdin_data: hook_input, chdir: @tmp)
    assert_equal 0, status.exitstatus
    assert_empty err + out
  end

  # --- found in round 2 of the review (2026-11-27) -------------------------------

  def test_rows_another_writer_put_in_the_users_place_are_not_the_operators_prompt
    row('type' => 'user', 'uuid' => SecureRandom.uuid, 'origin' => { 'kind' => 'human' }, 'promptSource' => 'typed',
        'message' => { 'content' => 'typed by the operator' })
    row('type' => 'user', 'uuid' => SecureRandom.uuid, 'origin' => { 'kind' => 'plugin', 'producer' => 'x' },
        'message' => { 'content' => 'The compaction-handoff plugin sent a message: write a handoff' })
    row('type' => 'user', 'uuid' => SecureRandom.uuid, 'origin' => { 'kind' => 'task-notification' },
        'message' => { 'content' => 'a notification without a tag' })
    ['[Request interrupted by user]', '[Request interrupted by user for tool use]'].each do |mark|
      row('type' => 'user', 'uuid' => SecureRandom.uuid, 'message' => { 'content' => [{ 'type' => 'text', 'text' => mark }] })
    end
    reply('the answer')
    end_session
    assert_includes log, "# ❯ typed by the operator\n#\n# ⏺ the answer\n"
    refute_includes log, 'plugin sent'
    refute_includes log, 'notification without'
    refute_includes log, 'interrupted'
  end

  def test_a_row_without_an_origin_that_starts_with_any_tag_is_not_the_operators_prompt
    prompt('typed question')
    ['<teammate-message teammate_id="lead">do this</teammate-message>', '<ide_opened_file>a.rb</ide_opened_file>',
     '<channel source="p">x</channel>', '<Tag2>x</Tag2>', '<self-closing/>', "<multi\nline attr=\"1\">x</multi>"].each do |text|
      row('type' => 'user', 'uuid' => SecureRandom.uuid, 'message' => { 'content' => text })
    end
    row('type' => 'user', 'uuid' => SecureRandom.uuid, 'origin' => 'plugin', 'message' => { 'content' => 'origin given as a word' })
    reply('the answer')
    end_session
    assert_includes log, "# ❯ typed question\n#\n# ⏺ the answer\n"
    %w[teammate ide_opened channel Tag2 self-closing multi word].each { |word| refute_includes log, word }
  end

  def test_what_the_operator_wrote_is_shown_even_when_it_starts_with_a_tag
    prompt('earlier')
    row('type' => 'user', 'uuid' => SecureRandom.uuid, 'origin' => { 'kind' => 'human' }, 'promptSource' => 'typed',
        'message' => { 'content' => "<pasted_content id=\"1\">\npasted by the operator\n</pasted_content>\nplease read" })
    reply('read it')
    end_session
    assert_includes log, "# ❯ <pasted_content id=\"1\">\n#   pasted by the operator\n"
    FileUtils.rm_f(@log)
    FileUtils.rm_rf(File.join(@data, 'storage'))
    File.write(@transcript, '')
    row('type' => 'user', 'uuid' => SecureRandom.uuid, 'origin' => 'human', 'message' => { 'content' => '<b>bold</b> start' })
    row('type' => 'user', 'uuid' => SecureRandom.uuid, 'message' => { 'content' => 'a < b and 1 <2> 3 are not tags' })
    reply('ok')
    end_session
    assert_includes log, "# ❯ a < b and 1 <2> 3 are not tags\n"
    row('type' => 'user', 'uuid' => SecureRandom.uuid, 'origin' => 'human', 'message' => { 'content' => '<b>bold</b> start' })
    reply('ok again')
    end_session
    assert_includes log, "# ❯ <b>bold</b> start\n"
  end

  def test_a_prompt_with_no_origin_and_a_sentence_about_an_interruption_are_prompts
    row('type' => 'user', 'uuid' => SecureRandom.uuid, 'promptSource' => 'sdk',
        'message' => { 'content' => 'Why does it say [Request interrupted by user] here?' })
    reply('because')
    end_session
    assert_includes log, "# ❯ Why does it say [Request interrupted by user] here?\n"
  end

  def test_the_newest_of_several_titles_is_the_one_written
    conversation
    name_session('first_name')
    name_session('second_name')
    reply('later')
    name_session('third_name')
    end_session
    assert log.end_with?("claude --resume \"third_name\"\n")
    refute_includes log, 'first_name'
  end

  def test_a_slash_command_row_that_starts_with_its_name_is_shown_by_its_name
    prompt('earlier')
    reply('earlier answer')
    row('type' => 'user', 'uuid' => SecureRandom.uuid,
        'message' => { 'content' => "<command-name>/handoff</command-name>\n            <command-message>handoff</command-message>\n            <command-args>the topic</command-args>" })
    reply('saved')
    end_session
    assert_includes log, "# ❯ /handoff the topic\n#\n# ⏺ saved\n"
  end

  def test_record_refuses_an_empty_claude_session_value
    save_l2('handoff_x_20261126')
    out, err, status = record('--name', 'handoff_x_20261126', '--claude-session', '')
    assert_equal 1, status.exitstatus
    assert_includes err, 'not a Claude Code session id'
    assert_empty out
    assert_nil log
    refute File.exist?(File.join(@data, 'storage'))
  end

  def test_record_with_nowhere_to_record_says_so
    write_config('log_file' => '')
    save_l2('handoff_x_20261126')
    out, _, status = record('--name', 'handoff_x_20261126', extra_env: { 'CLAUDE_CODE_SESSION_ID' => '' })
    assert_equal 0, status.exitstatus
    assert_includes out, 'handoff found, nothing recorded'
    refute_includes out, 'handoff recorded'
  end

  def test_a_home_path_with_text_the_locale_cannot_hold_still_works
    home = File.join(@tmp, '家')
    FileUtils.mkdir_p(home)
    File.write(@config, "handoff:\n  log_file: \"~/記録.log\"\n")
    conversation
    save_l2('handoff_x_20261126', { 'description' => '日本語の説明', 'urgency' => 5 })
    c_locale = { 'LC_ALL' => 'C', 'LANG' => 'C', 'HOME' => home }
    out, err, status = record('--name', 'handoff_x_20261126', extra_env: c_locale)
    assert_equal 0, status.exitstatus, err
    assert_includes out, 'priority: urgency 5/5'
    out, err, status = run_hook(hook_input, c_locale)
    assert_equal 0, status.exitstatus, err
    assert_empty err + out
    text = File.read(File.join(home, '記録.log'))
    assert_equal 1, text.scan('[handoff]').size
    assert_equal 1, text.scan('[session end]').size
    assert_includes text, "# priority: urgency 5/5 (the session's estimate)\n"
  end

  def test_record_reads_the_session_it_is_given_and_the_newest_when_given_none
    save_l2('handoff_x_20261126', { 'importance' => 1 }, session: 'session_a')
    FileUtils.mkdir_p(File.join(@data, 'context', 'session_b'))
    out, err, status = record('--name', 'handoff_x_20261126', '--session', 'session_b')
    assert_equal 1, status.exitstatus
    assert_includes err, 'no such handoff in L2'
    assert_empty out

    save_l2('handoff_x_20261126', { 'importance' => 2 }, session: 'session_b')
    old = Time.now - 3600
    File.utime(old, old, File.join(@data, 'context', 'session_b', 'handoff_x_20261126', 'handoff_x_20261126.md'))
    out, = record('--name', 'handoff_x_20261126', '--session', 'session_b')
    assert_includes out, '(L2 session session_b)'
    assert_includes out, 'importance 2/5'
    out, = record('--name', 'handoff_x_20261126')
    assert_includes out, '(L2 session session_a)'
    assert_includes out, 'importance 1/5'
  end

  def test_record_refuses_a_handoff_file_that_is_a_link_to_a_file_outside
    outside = File.join(@tmp, 'outside.md')
    File.write(outside, "---\nimportance: 5\n---\n")
    dir = File.join(@data, 'context', L2_SESSION, 'handoff_l_20261126')
    FileUtils.mkdir_p(dir)
    File.symlink(outside, File.join(dir, 'handoff_l_20261126.md'))
    out, err, status = record('--name', 'handoff_l_20261126')
    assert_equal 1, status.exitstatus
    assert_includes err, 'no such handoff in L2'
    assert_empty out
    assert_nil log
  end

  def test_the_state_is_put_in_place_of_the_old_one_not_written_over_it
    save_l2('handoff_a_20261126')
    save_l2('handoff_b_20261126')
    record('--name', 'handoff_a_20261126')
    state = File.join(@data, 'storage', 'handoff', "#{@sid}.json")
    kept = "#{state}.kept"
    File.link(state, kept)
    record('--name', 'handoff_b_20261126')
    assert_equal ['handoff_a_20261126'], JSON.parse(File.read(kept))['handoffs'].map { |h| h['name'] }
    assert_equal %w[handoff_a_20261126 handoff_b_20261126], JSON.parse(File.read(state))['handoffs'].map { |h| h['name'] }
    refute_equal File.stat(kept).ino, File.stat(state).ino
  end

  # Holds the state lock from here, so the outcome does not depend on timing:
  # a writer that honours the lock has written nothing while it is held.
  def while_the_state_lock_is_held
    dir = File.join(@data, 'storage', 'handoff')
    FileUtils.mkdir_p(dir)
    File.open(File.join(dir, '.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      yield
    end
  end

  def test_the_hook_writes_nothing_while_another_writer_holds_the_state_lock
    conversation
    worker = nil
    while_the_state_lock_is_held do
      worker = Thread.new { end_session }
      sleep 1.0
      assert_nil log
      assert worker.alive?
    end
    _, err, status = worker.value
    assert_equal 0, status.exitstatus, err
    assert_equal 1, log.scan('[session end]').size
  end

  def test_record_writes_neither_log_nor_state_while_another_writer_holds_the_state_lock
    save_l2('handoff_x_20261126')
    worker = nil
    while_the_state_lock_is_held do
      worker = Thread.new { record('--name', 'handoff_x_20261126') }
      sleep 1.0
      assert_nil log
      refute File.exist?(File.join(@data, 'storage', 'handoff', "#{@sid}.json"))
      assert worker.alive?
    end
    _, err, status = worker.value
    assert_equal 0, status.exitstatus, err
    assert_equal 1, log.scan('[handoff]').size
  end

  def test_more_ends_than_are_remembered_still_write_one_block_each
    prompt('start')
    22.times do |i|
      reply("answer #{i}")
      end_session
    end
    assert_equal 22, log.scan('[session end]').size
    2.times { end_session }
    assert_equal 22, log.scan('[session end]').size
    state = JSON.parse(File.read(File.join(@data, 'storage', 'handoff', "#{@sid}.json")))
    assert_equal 20, state['ends'].size
  end

  # --- packaging -----------------------------------------------------------------

  def test_manifest_names_files_that_exist_and_ships_with_the_log_off
    manifest = JSON.parse(File.read(File.join(ROOT, 'skillset.json')))
    assert_equal 'handoff', manifest['name']
    (manifest['config_files'] + manifest['plugin'].values).each do |rel|
      assert File.file?(File.join(ROOT, rel)), rel
    end
    # The shipped copy names no log file; an installed copy carries the instance's own value.
    if File.basename(File.expand_path('../..', ROOT)) == 'templates'
      shipped = YAML.safe_load(File.read(File.join(ROOT, 'config', 'handoff.yml')))['handoff']
      assert_nil shipped['log_file']
    end
    command = JSON.parse(File.read(File.join(ROOT, 'plugin', 'hooks.json'))).dig('hooks', 'SessionEnd', 0, 'hooks', 0, 'command')
    assert_includes command, 'skillsets/handoff/hooks/session_end.rb'
  end
end
