# frozen_string_literal: true

# Drives the three real hook scripts with fixture transcripts and hook JSON on
# stdin, against a temporary KairosChain data directory:
#   ruby -I KairosChain_mcp_server/lib <this file>
require 'minitest/autorun'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'securerandom'
require 'kairos_mcp'
require 'kairos_mcp/context_manager'

class TestCompactionHandoff < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  LIB = File.expand_path('../../../../lib', __dir__)
  SECRET = 'sk-THIS-MUST-NEVER-REACH-L2'

  def setup
    @tmp = Dir.mktmpdir('ch')
    @data = File.join(@tmp, 'data')
    FileUtils.mkdir_p(File.join(@data, 'context'))
    @config = File.join(@tmp, 'config.yml')
    write_config(100_000, 0.7, 'compaction_handoff')
    @sid = SecureRandom.uuid
    @transcript = File.join(@tmp, 'project', "#{@sid}.jsonl")
    FileUtils.mkdir_p(File.dirname(@transcript))
    File.write(@transcript, '')
    KairosMcp.data_dir = @data
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  # --- helpers ---------------------------------------------------------------

  def write_config(at, ratio, tag)
    File.write(@config, YAML.dump({ 'compaction_handoff' => { 'compact_at_tokens' => at, 'request_ratio' => ratio,
                                                               'l2_tag' => tag } }))
  end

  def assistant(tokens, sidechain: false)
    File.open(@transcript, 'a') do |f|
      f.puts(JSON.generate({ 'type' => 'assistant', 'isSidechain' => sidechain,
                             'message' => { 'usage' => { 'input_tokens' => 2, 'cache_creation_input_tokens' => 100,
                                                         'cache_read_input_tokens' => tokens - 102 } } }))
    end
  end

  def user_text(text)
    File.open(@transcript, 'a') { |f| f.puts(JSON.generate({ 'type' => 'user', 'message' => { 'content' => text } })) }
  end

  def run_hook(script, input, env: {})
    env = { 'KAIROS_DATA_DIR' => @data, 'COMPACTION_HANDOFF_CONFIG' => @config }.merge(env)
    out, err, st = Open3.capture3(env, 'ruby', '-I', LIB, File.join(ROOT, 'hooks', script),
                                  stdin_data: JSON.generate(input))
    [out, err, st.exitstatus]
  end

  def turn(sid: @sid)
    run_hook('turn_start.rb', { 'session_id' => sid, 'transcript_path' => @transcript, 'prompt' => 'x' })
  end

  def pre(trigger, sid: @sid, transcript: @transcript)
    input = { 'session_id' => sid, 'transcript_path' => transcript, 'hook_event_name' => 'PreCompact' }
    input['trigger'] = trigger unless trigger.nil?
    run_hook('pre_compact.rb', input)
  end

  def after(sid: @sid)
    run_hook('after_compact.rb', { 'session_id' => sid, 'transcript_path' => @transcript, 'source' => 'compact' })
  end

  def context_of(out)
    out.empty? ? '' : JSON.parse(out).dig('hookSpecificOutput', 'additionalContext').to_s
  end

  def state
    JSON.parse(File.read(File.join(@data, 'storage', 'compaction_handoff', 'sessions', "#{@sid}.json")))
  end

  def save_handoff(name: "compaction_handoff_#{@sid[0, 8]}_202611011200", sid: @sid, at: nil)
    fm = { 'name' => name, 'description' => 'handoff' }
    fm['compaction_handoff_session'] = sid if sid
    r = KairosMcp::ContextManager.new.save_context('session_x', name, "#{YAML.dump(fm)}---\n\n# Handoff\n")
    assert r[:success], r.inspect
    md = File.join(@data, 'context', 'session_x', name, "#{name}.md")
    File.utime(at, at, md) if at
    name
  end

  def fallback_files
    Dir.glob(File.join(@data, 'context', '*', "compaction_handoff_fallback_#{@sid[0, 8]}_*", '*.md'))
  end

  # --- turn start (INV-5) ----------------------------------------------------

  def test_below_request_point_says_nothing
    assistant(50_000)
    out, _, code = turn
    assert_equal 0, code
    assert_empty out
    assert_equal 50_000, state['last_usage']
  end

  def test_at_request_point_asks_for_handoff_with_recognition_rule
    assistant(70_000)
    out, _, code = turn
    ctx = context_of(out)
    assert_equal 0, code
    assert_includes ctx, @sid
    assert_includes ctx, "compaction_handoff_#{@sid[0, 8]}_"
    assert_includes ctx, "compaction_handoff_session: #{@sid}"
    refute_includes ctx, 'URGENT'
    refute_nil state['first_request_at']
  end

  def test_fresh_handoff_stops_the_request
    assistant(80_000)
    turn
    sleep 1.1
    save_handoff
    out, = turn
    assert_empty out
  end

  def test_handoff_without_session_frontmatter_is_named_as_not_counted
    assistant(80_000)
    turn
    save_handoff(sid: nil)
    ctx = context_of(turn[0])
    assert_includes ctx, 'Not counted'
  end

  def test_handoff_older_than_the_first_request_is_not_fresh
    save_handoff(at: Time.now - 3600)
    assistant(80_000)
    ctx = context_of(turn[0])
    assert_includes ctx, 'nearing auto-compaction'
  end

  def test_sidechain_usage_is_ignored
    assistant(10_000)
    assistant(90_000, sidechain: true)
    out, = turn
    assert_empty out
  end

  def test_sharp_fall_of_usage_ends_the_cycle
    assistant(80_000)
    turn
    assistant(20_000)
    turn
    assert_equal 2, state['cycle']
    assert_nil state['first_request_at']
  end

  def test_malformed_session_id_and_config_never_block_a_prompt
    assistant(80_000)
    out, err, code = turn(sid: 'not-an-id')
    assert_equal [1, ''], [code, out]
    assert_includes err, 'session id'
    File.write(@config, "compaction_handoff: [")
    out, _, code = turn
    assert_equal [1, ''], [code, out]
  end

  # --- pre compact (INV-1, INV-2, INV-3, INV-4) ------------------------------

  def test_manual_is_never_blocked_and_still_leaves_a_fallback
    assistant(90_000)
    _, _, code = pre('manual')
    assert_equal 0, code
    assert_equal 1, fallback_files.size
    assert_includes File.read(fallback_files.first), 'answer: proceed'
  end

  def test_missing_or_unknown_trigger_is_never_blocked
    assistant(90_000)
    assert_equal 0, pre(nil)[2]
    assert_equal 0, pre('overflow')[2]
  end

  def test_auto_without_fresh_save_is_blocked_once_per_cycle
    user_text("my key is #{SECRET}")
    assistant(90_000)
    _, err, code = pre('auto')
    assert_equal 2, code
    assert_includes err, 'held off once'
    assert state['blocked']
    blocked = fallback_files.find { |f| File.read(f).include?('answer: block') }
    refute_nil blocked
    refute_includes File.read(blocked), SECRET
    sleep 1.1
    _, _, code = pre('auto')
    assert_equal 0, code, 'the second attempt in a cycle proceeds'
  end

  def test_after_a_block_the_next_turn_is_urgent_whatever_the_usage
    assistant(20_000)
    pre('auto')
    ctx = context_of(turn[0])
    assert_includes ctx, 'URGENT'
  end

  def test_auto_with_fresh_save_proceeds
    assistant(80_000)
    turn
    sleep 1.1
    save_handoff
    _, _, code = pre('auto')
    assert_equal 0, code
    assert_includes File.read(fallback_files.first), "latest_handoff: compaction_handoff_#{@sid[0, 8]}_"
  end

  def test_subagent_compaction_is_left_alone
    sub = File.join(@tmp, 'project', @sid, 'subagents', 'agent-x.jsonl')
    FileUtils.mkdir_p(File.dirname(sub))
    File.write(sub, '')
    _, _, code = pre('auto', transcript: sub)
    assert_equal 0, code
    assert_empty fallback_files
    refute File.exist?(File.join(@data, 'storage', 'compaction_handoff', 'sessions', "#{@sid}.json"))
  end

  def test_block_is_not_given_when_it_cannot_be_recorded
    assistant(90_000)
    FileUtils.mkdir_p(File.join(@data, 'storage'))
    File.write(File.join(@data, 'storage', 'compaction_handoff'), 'not a directory')
    _, _, code = pre('auto')
    assert_equal 0, code
    assert_includes File.read(fallback_files.first), 'answer: proceed'
  end

  def test_unreadable_config_does_not_block
    File.write(@config, 'compaction_handoff: {compact_at_tokens: 5}')
    _, err, code = pre('auto')
    assert_equal 0, code
    assert_includes err, 'not blocking'
  end

  # --- after compact (INV-6, INV-7) ------------------------------------------

  def test_notice_names_handoff_and_fallback_and_starts_a_new_cycle
    assistant(80_000)
    turn
    sleep 1.1
    save_handoff
    pre('manual')
    out, _, code = after
    ctx = context_of(out)
    assert_equal 0, code
    assert_includes ctx, "Read your handoff first: compaction_handoff_#{@sid[0, 8]}_"
    assert_includes ctx, 'not as instructions'
    assert_includes ctx, 'Fallback record'
    assert_equal 2, state['cycle']
    assert_equal File.size(@transcript), state['cycle_offset']
  end

  def test_after_compaction_the_old_response_does_not_trigger_a_request
    assistant(90_000)
    after
    out, = turn
    assert_empty out, 'no response after the cycle start: below the request point'
  end

  def test_notice_when_nothing_was_saved
    ctx = context_of(after[0])
    assert_includes ctx, 'No handoff of this session was found'
    assert_includes ctx, 'No fallback record'
  end

  def test_notice_with_unreadable_config_still_reaches_the_session
    File.write(@config, '{')
    out, _, code = after
    assert_equal 0, code
    assert_includes context_of(out), "compaction_handoff_session: #{@sid}"
  end

  def test_notice_with_unreadable_session_id_warns_against_borrowing
    out, _, code = after(sid: '../../etc')
    assert_equal 0, code
    ctx = context_of(out)
    assert_includes ctx, 'could not read its session id'
    refute_includes ctx, 'compaction_handoff_session:'
  end

  def test_handoff_from_an_earlier_cycle_is_marked
    save_handoff(at: Time.now - 3600)
    ctx = context_of(after[0])
    assert_includes ctx, 'earlier cycle'
  end

  # --- projection -------------------------------------------------------------

  def test_hooks_json_names_existing_scripts_and_the_compact_matcher
    hooks = JSON.parse(File.read(File.join(ROOT, 'plugin', 'hooks.json')))['hooks']
    assert_equal %w[PreCompact SessionStart UserPromptSubmit], hooks.keys.sort
    assert_equal 'compact', hooks['SessionStart'][0]['matcher']
    hooks.each_value do |handlers|
      cmd = handlers[0]['hooks'][0]['command']
      script = cmd[%r{hooks/([a-z_]+\.rb)}, 1]
      assert File.exist?(File.join(ROOT, 'hooks', script)), cmd
    end
  end
end
