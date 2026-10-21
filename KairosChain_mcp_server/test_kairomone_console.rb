#!/usr/bin/env ruby
# frozen_string_literal: true
# Kairomone console units, written from design v0.3 and implementation plan
# v0.2 (log/kairomone_console_design_v0.3_20261021.md,
# log/kairomone_console_impl_plan_v0.2_20261021.md) without reading the
# implementation. All data is synthetic and confined to temporary roots; child
# stdout lines follow the shapes retained in log/kairomone_console_probes_20261021/.
# No `claude` is run, and the only sockets are on 127.0.0.1.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'kairomone'
require_relative 'templates/skillsets/kairomone/lib/kairomone/console'
require 'kairos_mcp/skillset_manager'
require 'tmpdir'
require 'open3'
require 'net/http'
require 'shellwords'
require 'minitest/autorun'

# Child stdout lines, after the retained probe logs (file names in comments).
module ConsoleLines
  SESSION_ID = '6d0f58d6-4b24-46ac-a462-4e71b852e9cb'
  module_function

  def uuid = SecureRandom.uuid

  # system/init is a per-turn report and comes before the replay (m8, m9).
  def init(mode)
    { 'type' => 'system', 'subtype' => 'init', 'cwd' => '/private/tmp/kmc/work', 'session_id' => SESSION_ID,
      'tools' => %w[Bash Glob Grep Read ToolSearch mcp__kairos-chain__kairomone_status],
      'mcp_servers' => [{ 'name' => 'kairos-chain', 'status' => 'connected', 'source' => 'dynamic' }],
      'model' => 'claude-haiku-5-5', 'permissionMode' => mode, 'slash_commands' => [], 'apiKeySource' => 'none',
      'claude_code_version' => '2.1.303', 'output_style' => 'default', 'uuid' => uuid }
  end

  def status(mode)
    { 'type' => 'system', 'subtype' => 'status', 'status' => nil, 'permissionMode' => mode, 'uuid' => uuid,
      'session_id' => SESSION_ID }
  end

  def echo(request_id, word)
    { 'type' => 'control_response',
      'response' => { 'subtype' => 'success', 'request_id' => request_id, 'response' => { 'mode' => word } } }
  end

  def replay(message)
    { 'type' => 'user', 'message' => message, 'session_id' => SESSION_ID, 'parent_tool_use_id' => nil,
      'uuid' => uuid, 'timestamp' => '2026-10-21T17:49:02.403Z', 'isReplay' => true }
  end

  def assistant(blocks)
    { 'type' => 'assistant',
      'message' => { 'model' => 'claude-haiku-5-5', 'id' => "msg_#{uuid.delete('-')}", 'type' => 'message',
                     'role' => 'assistant', 'content' => blocks, 'stop_reason' => nil },
      'parent_tool_use_id' => nil, 'session_id' => SESSION_ID, 'uuid' => uuid }
  end

  def text(value) = assistant([{ 'type' => 'text', 'text' => value }])

  def tool_use(id, name, input)
    assistant([{ 'type' => 'tool_use', 'id' => id, 'name' => name, 'input' => input, 'caller' => { 'type' => 'direct' } }])
  end

  # A Bash request carries a top-level description (m11); an MCP request names its server (s1).
  def can_use_tool(request_id, tool_use_id, name, input, display_name: name, description: nil)
    request = { 'subtype' => 'can_use_tool', 'tool_name' => name, 'display_name' => display_name, 'input' => input,
                'permission_suggestions' => [], 'tool_use_id' => tool_use_id }
    if name.start_with?('mcp__')
      request['mcp_server'] = { 'name' => 'kairos-chain', 'source' => 'dynamic' }
      request['server_policy_ask_only'] = true
    end
    if description
      request['description'] = description
      request['decision_reason'] = 'This command requires approval'
      request['decision_reason_type'] = 'other'
    end
    { 'type' => 'control_request', 'request_id' => request_id, 'request' => request }
  end

  # The CLI writes the host's own answer back on stdout (m8 line 24).
  def answer_echo(request_id, body)
    { 'type' => 'control_response', 'response' => { 'subtype' => 'success', 'request_id' => request_id, 'response' => body } }
  end

  def tool_result(tool_use_id, content, decision:, source:, is_error: nil)
    block = { 'tool_use_id' => tool_use_id, 'type' => 'tool_result', 'content' => content }
    block['is_error'] = is_error unless is_error.nil?
    meta = { 'id' => tool_use_id, 'permission_decision' => { 'decision' => decision, 'source' => source } }
    meta['non_execution_kind'] = 'permission-rule' if decision == 'reject'
    { 'type' => 'user', 'message' => { 'role' => 'user', 'content' => [block] }, 'parent_tool_use_id' => nil,
      'session_id' => SESSION_ID, 'uuid' => uuid, 'timestamp' => '2026-10-21T16:52:06.722Z',
      'tool_use_result' => 'fixture', 'tool_result_meta' => [meta] }
  end

  def result(subtype: 'success', is_error: false)
    { 'type' => 'result', 'subtype' => subtype, 'is_error' => is_error, 'duration_ms' => 1615, 'num_turns' => 1,
      'result' => 'ok', 'session_id' => SESSION_ID, 'permission_denials' => [], 'terminal_reason' => 'completed',
      'uuid' => uuid }
  end

  # A turn sent from another of the owner's sessions (m6 line 11).
  def foreign(body)
    text = "Another Claude session sent a message:\n<cross-session-message from=\"uds:/tmp/cc-socks/22271.sock\" " \
           "from-name=\"kairomone_peer_fixture\" from-mode=\"prompting\">\n#{body}\n</cross-session-message>"
    { 'type' => 'user', 'message' => { 'role' => 'user', 'content' => text }, 'session_id' => SESSION_ID,
      'parent_tool_use_id' => nil, 'uuid' => uuid, 'timestamp' => '2026-10-21T17:15:58.041Z',
      'isReplay' => true, 'isSynthetic' => true,
      'origin' => { 'kind' => 'peer', 'from' => 'uds:/tmp/cc-socks/22271.sock', 'verifiedPeerPid' => 22_271,
                    'msg_id' => uuid, 'name' => 'kairomone_peer_fixture', 'hopChain' => ['dc8c399a23fa58e8be7c727c'],
                    'fromMode' => 'prompting', 'body' => body } }
  end

  # Lines seen in the probes that are neither turns nor answers.
  def noise
    [{ 'type' => 'rate_limit_event', 'rate_limit_info' => { 'status' => 'allowed', 'rateLimitType' => 'five_hour' },
       'uuid' => uuid, 'session_id' => SESSION_ID },
     { 'type' => 'system', 'subtype' => 'thinking_tokens', 'estimated_tokens' => 50, 'estimated_tokens_delta' => 50,
       'session_id' => SESSION_ID, 'uuid' => uuid },
     { 'type' => 'system', 'subtype' => 'session_title_changed', 'title' => 'fixture', 'uuid' => uuid,
       'session_id' => SESSION_ID },
     { 'type' => 'command_lifecycle', 'command_uuid' => uuid, 'state' => 'started', 'uuid' => uuid,
       'session_id' => SESSION_ID },
     { 'type' => 'system', 'subtype' => 'hook_started', 'hook_id' => uuid, 'hook_name' => 'SessionStart:startup',
       'hook_event' => 'SessionStart', 'uuid' => uuid, 'session_id' => SESSION_ID },
     assistant([{ 'type' => 'thinking', 'thinking' => '', 'signature' => 'CAQS1gUK' }])]
  end
end

module ConsoleTestSupport
  HEX64 = /\A[0-9a-f]{64}\z/

  def plain(value) = JSON.parse(JSON.generate(value))

  def feed(line)
    @session.handle_line("#{line.is_a?(String) ? line : JSON.generate(line)}\n")
  end

  def events = plain(@session.events_after(0))
  def events_of(kind) = events.select { |e| e['kind'] == kind }
  def last_event(kind) = events_of(kind).last

  def mode_requests
    @writes.select { |w| w['type'] == 'control_request' && w.dig('request', 'subtype') == 'set_permission_mode' }
  end

  def interrupts
    @writes.select { |w| w['type'] == 'control_request' && w.dig('request', 'subtype') == 'interrupt' }
  end

  def answers = @writes.select { |w| w['type'] == 'control_response' && w.dig('response', 'subtype') == 'success' }
  def answers_for(id) = answers.select { |w| w.dig('response', 'request_id') == id }
  def user_messages = @writes.select { |w| w['type'] == 'user' }

  def text_of(content)
    return content if content.is_a?(String)

    Array(content).select { |b| b.is_a?(Hash) && b['type'] == 'text' }.map { |b| b['text'] }.join
  end
end

class KairomoneConsoleSessionTest < Minitest::Test
  include ConsoleTestSupport
  L = ConsoleLines
  KC = Kairomone::Console

  def build(cap: 64 * 1024 * 1024)
    @writes = []
    @logs = []
    @now = Time.utc(2031, 2, 3, 4, 5, 6)
    @session = KC::Session.new(writer: ->(hash) { @writes << plain(hash) }, clock: -> { @now },
                               memory_cap_bytes: cap, log: ->(hash) { @logs << plain(hash) })
  end

  # Started and confirmed in the asking mode, as after the measured handshake (m9).
  def confirm!(cap: 64 * 1024 * 1024)
    build(cap: cap)
    @session.start!
    feed(L.echo(mode_requests.first.fetch('request_id'), 'default'))
    assert @session.accepting?, 'accepting after the asking echo'
  end

  # An owner turn as the CLI reports it: system/init, then the replay.
  def owner_turn(text, mode: 'default')
    assert_equal :accepted, @session.send_message(text)
    message = user_messages.last.fetch('message')
    feed(L.init(mode))
    feed(L.replay(message))
    message
  end

  def at_from_clock?(value)
    return (value.to_f - @now.to_f).abs < 2 || (value.to_f / 1000 - @now.to_f).abs < 2 if value.is_a?(Numeric)

    value.to_s.include?(@now.strftime('%Y-%m-%d'))
  end

  def test_mode_request_is_written_first_and_only_its_asking_echo_opens_the_box
    build
    @session.start!
    first = @writes.first
    assert_equal 'control_request', first['type']
    assert_equal({ 'subtype' => 'set_permission_mode', 'mode' => 'manual' }, first['request'])
    assert_match(/\Akm-mode-/, first['request_id'])
    started = events.first
    assert_equal ['child_started', false], started.values_at('kind', 'resumed')
    refute @session.accepting?
    assert_equal 'mode_unconfirmed', @session.accept_reason
    assert_equal [:refused, 'mode_unconfirmed'], @session.send_message('hello')
    feed(L.status('default'))
    feed(L.echo('pre1', 'default'))
    refute @session.accepting?, 'only the echo of the console own mode request opens the box'
    assert_empty user_messages, 'no message is written before the asking echo'
    feed(L.echo(first['request_id'], 'default'))
    assert @session.accepting?
    assert @session.asking?
    assert_equal 'default', @session.mode_word
    assert_equal({ 'word' => 'default', 'asking' => true, 'source' => 'echo' },
                 last_event('mode').slice('word', 'asking', 'source'))
    assert_equal true, last_event('accepting')['value']
    assert_equal :accepted, @session.send_message('hello')
    assert_equal 'hello', text_of(user_messages.last.dig('message', 'content'))
    assert_equal 'user', user_messages.last.dig('message', 'role')
  end

  def test_a_non_asking_echo_is_shown_as_not_asking_and_keeps_the_box_closed
    %w[auto manual acceptEdits plan bypassPermissions dontAsk].each do |word|
      build
      @session.start!
      feed(L.echo(mode_requests.first['request_id'], word))
      assert_equal [word, false], last_event('mode').values_at('word', 'asking'), word
      assert_equal word, @session.mode_word
      refute @session.asking?, word
      refute @session.accepting?, word
      assert_equal [:refused, 'mode_unconfirmed'], @session.send_message('hello'), word
    end
  end

  def test_resume_names_the_session_and_repeats_the_handshake
    build
    @session.start!(resumed: true, session_id: 'resume-session-7f3a')
    assert_equal ['child_started', true, 'resume-session-7f3a'], events.first.values_at('kind', 'resumed', 'session_id')
    assert_equal({ 'subtype' => 'set_permission_mode', 'mode' => 'manual' }, @writes.first['request'])
    refute @session.accepting?
    feed(L.echo(mode_requests.first['request_id'], 'default'))
    assert @session.accepting?
    assert_includes JSON.generate(@logs), 'resume-session-7f3a', 'the console log records the resume with its session id'
  end

  def test_switching_to_auto_and_back_waits_for_the_echo_and_the_status
    confirm!
    assert_equal :sent, @session.request_mode('auto')
    to_auto = mode_requests.last
    assert_equal 'auto', to_auto.dig('request', 'mode')
    assert_match(/\Akm-mode-/, to_auto['request_id'])
    refute_equal mode_requests.first['request_id'], to_auto['request_id']
    feed(L.echo(to_auto['request_id'], 'auto'))
    feed(L.status('auto'))
    assert_equal 'auto', @session.mode_word
    refute @session.asking?
    assert_equal false, last_event('mode')['asking']
    owner_turn('in auto', mode: 'auto')
    assert_empty events_of('mode_mismatch'), 'a turn reporting the confirmed auto is no mismatch'
    feed(L.result)
    assert_equal :sent, @session.request_mode('ask')
    back = mode_requests.last
    assert_equal 'manual', back.dig('request', 'mode')
    assert_equal [:refused, 'mode_unconfirmed'], @session.send_message('too early')
    feed(L.echo(back['request_id'], 'default'))
    assert_equal [:refused, 'mode_unconfirmed'], @session.send_message('still early'),
                 'switching back from auto also awaits system/status'
    feed(L.status('default'))
    assert @session.asking?
    assert @session.accepting?
    assert_equal :accepted, @session.send_message('asking again')
  end

  def test_request_mode_sends_only_auto_or_manual
    confirm!
    count = @writes.length
    %w[bypassPermissions acceptEdits plan dontAsk].each do |word|
      assert_equal :refused, Array(@session.request_mode(word)).first, word
    end
    assert_equal count, @writes.length
  end

  def test_a_turn_init_reporting_another_mode_is_a_mismatch_and_interrupts
    confirm!
    assert_equal :accepted, @session.send_message('first')
    feed(L.init('auto'))
    mismatch = last_event('mode_mismatch')
    refute_nil mismatch
    assert_equal({ 'expected' => 'default', 'reported' => 'auto' }, mismatch.slice('expected', 'reported'))
    refute_empty interrupts
    assert_equal 'auto', @session.mode_word, 'the page shows the latest word the CLI reported'
    refute @session.asking?
  end

  def test_a_turn_init_matching_the_confirmed_mode_changes_nothing
    confirm!
    owner_turn('first')
    assert_empty events_of('mode_mismatch')
    assert_empty interrupts
    assert_empty events_of('foreign_turn')
  end

  def test_the_replay_of_a_page_message_is_consumed_and_a_second_copy_is_foreign
    confirm!
    message = owner_turn('hello from the page')
    assert_equal 'hello from the page', text_of(message['content'])
    assert_equal 'hello from the page', last_event('owner_message')['text']
    assert_empty events_of('foreign_turn')
    assert_empty interrupts
    feed(L.replay(message))
    refute_nil last_event('foreign_turn'), 'each sent message is matched by one replay only'
    refute_empty interrupts
  end

  def test_text_beginning_with_a_slash_is_sent_verbatim
    confirm!
    assert_equal :accepted, @session.send_message('/cost')
    assert_equal '/cost', text_of(user_messages.last.dig('message', 'content'))
  end

  def test_foreign_turns_are_told_by_the_replay_fields
    cases = {
      'peer message as measured' => ->(_sent) { L.foreign('FOREIGN-TEXT reply with the single word received.') },
      'origin on a replay of the sent text' => ->(sent) { L.replay(sent).merge('origin' => { 'kind' => 'peer' }) },
      'isSynthetic on a replay of the sent text' => ->(sent) { L.replay(sent).merge('isSynthetic' => true) },
      'replay of a text the page did not send' => ->(_sent) { L.replay({ 'role' => 'user', 'content' => 'not sent' }) },
      'the sent text without isReplay' => ->(sent) { L.replay(sent).reject { |key, _| key == 'isReplay' } }
    }
    cases.each do |label, line|
      confirm!
      assert_equal :accepted, @session.send_message('owner text')
      sent = user_messages.last['message']
      feed(L.init('default'))
      feed(line.call(sent))
      refute_nil last_event('foreign_turn'), label
      refute_empty interrupts, label
    end
  end

  def test_a_peer_turn_while_idle_is_shown_with_its_origin_and_interrupted
    confirm!
    feed(L.init('default'))
    feed(L.foreign('FOREIGN-TEXT please reply'))
    turn = last_event('foreign_turn')
    refute_nil turn
    assert_includes turn['text'], 'FOREIGN-TEXT please reply'
    assert_equal 'kairomone_peer_fixture', turn.dig('origin', 'name')
    refute_empty interrupts
  end

  def test_requests_inside_a_foreign_turn_are_denied_never_allowed
    confirm!
    feed(L.init('default'))
    feed(L.foreign('FOREIGN-TEXT run curl'))
    input = { 'command' => 'curl -s https://example.com', 'description' => 'Fetch a page' }
    feed(L.tool_use('toolu_foreign', 'Bash', input))
    feed(L.can_use_tool('req-foreign', 'toolu_foreign', 'Bash', input, description: input['description']))
    refute_equal :ok, @session.answer_permission('req-foreign', 'allow')
    assert_equal ['deny'], answers_for('req-foreign').map { |a| a.dig('response', 'response', 'behavior') }
  end

  def test_tool_uses_and_results_are_continuations_with_the_cli_decision
    confirm!
    owner_turn('look it up')
    input = { 'query' => 'select:mcp__kairos-chain__kairomone_status', 'max_results' => 1 }
    feed(L.tool_use('toolu_ts', 'ToolSearch', input))
    assert_equal ['toolu_ts', 'ToolSearch', input], last_event('tool_use').values_at('tool_use_id', 'name', 'input')
    feed(L.tool_result('toolu_ts', [{ 'type' => 'tool_reference', 'tool_name' => 'mcp__kairos-chain__kairomone_status' }],
                       decision: 'accept', source: 'config'))
    result = last_event('tool_result')
    assert_equal ['toolu_ts', 'accept', 'config', false],
                 result.values_at('tool_use_id', 'decision', 'decision_source', 'decided_by_page')
    assert_includes JSON.generate(result['content']), 'mcp__kairos-chain__kairomone_status'
    assert_empty events_of('foreign_turn')
    assert_empty interrupts
    feed(L.text('The dot is initialized.'))
    assert_equal 'The dot is initialized.', last_event('assistant_text')['text']
    feed(L.result)
    assert_equal ['success', false], last_event('turn_end').values_at('subtype', 'is_error')
  end

  def test_allow_carries_back_exactly_the_input_that_was_shown
    confirm!
    owner_turn('run it')
    input = { 'command' => 'ps -o pid,pgid,ppid,command -p $$,$PPID', 'description' => 'Show PID, PGID, PPID',
              'nested' => { 'list' => [1, 'two', nil, { 'k' => '日本語 <b>&amp;</b>' }] } }
    feed(L.tool_use('toolu_1', 'Bash', input))
    feed(L.can_use_tool('req-1', 'toolu_1', 'Bash', input, description: 'Show PID, PGID, PPID'))
    assert_equal ['req-1'], @session.pending_ids
    shown = last_event('permission_request')
    assert_equal({ 'request_id' => 'req-1', 'tool_use_id' => 'toolu_1', 'tool_name' => 'Bash', 'display_name' => 'Bash',
                   'description' => 'Show PID, PGID, PPID', 'input' => input },
                 shown.slice('request_id', 'tool_use_id', 'tool_name', 'display_name', 'description', 'input'))
    assert_equal :ok, @session.answer_permission('req-1', 'allow')
    assert_equal({ 'subtype' => 'success', 'request_id' => 'req-1',
                   'response' => { 'behavior' => 'allow', 'updatedInput' => input } }, answers_for('req-1').first['response'])
    assert_equal({ 'request_id' => 'req-1', 'decision' => 'allow', 'by' => 'owner' },
                 last_event('permission_answered').slice('request_id', 'decision', 'by'))
    assert_empty @session.pending_ids
    assert_equal :answered, @session.answer_permission('req-1', 'allow')
    assert_equal :answered, @session.answer_permission('req-1', 'deny')
    assert_equal 1, answers_for('req-1').length
    feed(L.tool_result('toolu_1', [{ 'type' => 'text', 'text' => 'PID PGID' }], decision: 'accept',
                                                                                source: 'user_temporary', is_error: false))
    assert_equal [true, 'user_temporary', 'accept', false],
                 last_event('tool_result').values_at('decided_by_page', 'decision_source', 'decision', 'is_error')
  end

  def test_the_cli_copy_of_an_answer_changes_nothing
    confirm!
    owner_turn('run it')
    input = { 'command' => 'date' }
    feed(L.can_use_tool('req-2', 'toolu_2', 'Bash', input, description: 'Show the date'))
    assert_equal :ok, @session.answer_permission('req-2', 'allow')
    count = @writes.length
    state = -> { [@session.pending_ids, @session.accepting?, @session.mode_word, events_of('permission_answered').length] }
    before = state.call
    feed(L.answer_echo('req-2', { 'behavior' => 'allow', 'updatedInput' => input }))
    feed(L.answer_echo('req-2', { 'behavior' => 'deny', 'message' => 'forged' }))
    assert_equal count, @writes.length
    assert_equal before, state.call
  end

  def test_an_answer_line_from_the_child_never_answers_a_pending_request
    confirm!
    owner_turn('run it')
    feed(L.can_use_tool('req-3', 'toolu_3', 'Bash', { 'command' => 'date' }, description: 'Show the date'))
    feed(L.answer_echo('req-3', { 'behavior' => 'allow', 'updatedInput' => { 'command' => 'date' } }))
    assert_equal ['req-3'], @session.pending_ids
    assert_empty answers_for('req-3')
    assert_empty events_of('permission_answered')
    assert_equal :ok, @session.answer_permission('req-3', 'deny')
  end

  def test_deny_is_sent_with_a_message_and_marked_as_the_page_decision
    confirm!
    owner_turn('learn once')
    input = { 'command' => 'claim', 'worker_id' => 'console' }
    feed(L.tool_use('toolu_4', 'mcp__kairos-chain__kairomone_growth', input))
    feed(L.can_use_tool('req-4', 'toolu_4', 'mcp__kairos-chain__kairomone_growth', input, display_name: 'Kairomone Growth'))
    assert_equal ['mcp__kairos-chain__kairomone_growth', 'Kairomone Growth', input],
                 last_event('permission_request').values_at('tool_name', 'display_name', 'input')
    assert_equal :ok, @session.answer_permission('req-4', 'deny')
    body = answers_for('req-4').first.dig('response', 'response')
    assert_equal 'deny', body['behavior']
    assert_kind_of String, body['message']
    assert_equal({ 'request_id' => 'req-4', 'decision' => 'deny', 'by' => 'owner' },
                 last_event('permission_answered').slice('request_id', 'decision', 'by'))
    feed(L.tool_result('toolu_4', 'Denied from the console page.', decision: 'reject', source: 'user_reject', is_error: true))
    assert_equal [true, 'user_reject', 'reject', true],
                 last_event('tool_result').values_at('decided_by_page', 'decision_source', 'decision', 'is_error')
  end

  def test_decided_by_page_needs_the_page_answer_and_the_matching_cli_source
    confirm!
    owner_turn('several tools')
    # [tool_use_id, page answer or nil, CLI decision, CLI source]
    rows = [['toolu_a', nil, 'accept', 'config'],          # Claude Code's own rule for ToolSearch (s1)
            ['toolu_b', nil, 'reject', 'hook'],            # the gate refused (s1, m4)
            ['toolu_c', nil, 'accept', 'user_temporary'],  # names the owner, but nothing was asked
            ['toolu_d', 'allow', 'reject', 'user_reject'], # rejected although the page allowed
            ['toolu_e', 'deny', 'accept', 'user_temporary']] # accepted although the page denied
    rows.each_with_index do |(id, page, decision, source), i|
      if page
        feed(L.can_use_tool("req-r#{i}", id, 'Bash', { 'command' => "echo #{i}" }, description: 'Echo'))
        assert_equal :ok, @session.answer_permission("req-r#{i}", page)
      end
      feed(L.tool_result(id, "result #{i}", decision: decision, source: source))
      result = events_of('tool_result').find { |e| e['tool_use_id'] == id }
      refute_nil result, id
      assert_equal [false, source, decision], result.values_at('decided_by_page', 'decision_source', 'decision'), id
    end
  end

  def test_an_unknown_request_id_is_not_found_and_writes_nothing
    confirm!
    count = @writes.length
    assert_equal :not_found, @session.answer_permission('no-such-request', 'allow')
    assert_equal count, @writes.length
  end

  def test_a_decision_other_than_allow_or_deny_allows_nothing
    confirm!
    owner_turn('run it')
    feed(L.can_use_tool('req-5', 'toolu_5', 'Bash', { 'command' => 'date' }, description: 'Show the date'))
    %w[maybe yes accept].each do |word|
      refute_equal :ok, @session.answer_permission('req-5', word), word
    rescue Kairomone::Error, ArgumentError
      nil
    end
    assert_empty answers_for('req-5')
    assert_equal ['req-5'], @session.pending_ids
  end

  def test_an_unanswered_request_stays_pending_however_long_it_waits
    confirm!
    owner_turn('run it')
    feed(L.can_use_tool('req-6', 'toolu_6', 'Bash', { 'command' => 'date' }, description: 'Show the date'))
    @now += 3 * 86_400
    L.noise.each { |line| feed(line) }
    assert_equal ['req-6'], @session.pending_ids
    assert_empty answers, 'nothing is allowed or denied by timeout'
  end

  def test_control_requests_other_than_can_use_tool_are_answered_with_an_error
    confirm!
    %w[hook_callback mcp_message elicitation set_permission_mode interrupt initialize future_subtype_2031].each_with_index do |subtype, i|
      feed({ 'type' => 'control_request', 'request_id' => "cli-#{i}",
             'request' => { 'subtype' => subtype, 'tool_name' => 'Bash', 'input' => {}, 'mode' => 'auto' } })
      assert_equal({ 'type' => 'control_response',
                     'response' => { 'subtype' => 'error', 'request_id' => "cli-#{i}", 'error' => 'not supported' } },
                   @writes.last, subtype)
    end
    feed({ 'type' => 'control_request', 'request_id' => 'cli-bare' })
    assert_equal %w[error cli-bare], @writes.last['response'].values_at('subtype', 'request_id')
    assert_empty @session.pending_ids
    assert_empty events_of('permission_request')
    assert_equal 'default', @session.mode_word, 'a mode request from the child changes nothing'
    refute_includes JSON.generate(@writes), '"allow"'
  end

  def test_stop_denies_every_pending_request_interrupts_and_refuses
    confirm!
    owner_turn('two tools')
    feed(L.can_use_tool('req-a', 'toolu_a', 'Bash', { 'command' => 'date' }, description: 'Show the date'))
    feed(L.can_use_tool('req-b', 'toolu_b', 'mcp__kairos-chain__kairomone_status', {}, display_name: 'Kairomone Status'))
    assert_equal %w[req-a req-b], @session.pending_ids.sort
    @session.stop!(by: :page)
    assert_empty @session.pending_ids
    assert_equal [%w[req-a deny], %w[req-b deny]],
                 answers.map { |a| [a.dig('response', 'request_id'), a.dig('response', 'response', 'behavior')] }.sort
    assert_equal %w[console_stop console_stop], events_of('permission_answered').map { |e| e['by'] }
    refute_empty interrupts
    refute @session.accepting?
    assert_equal 'stopped', @session.accept_reason
    assert_equal [:refused, 'stopped'], @session.send_message('after stop')
    assert_equal :answered, @session.answer_permission('req-a', 'allow')
    assert_empty(answers.select { |a| a.dig('response', 'response', 'behavior') == 'allow' })
  end

  def test_past_the_memory_cap_messages_are_refused_the_turn_interrupted_and_events_kept
    confirm!(cap: 4096)
    owner_turn('fill the memory')
    big = 'x' * 6000
    feed(L.text(big))
    refute_empty interrupts, 'the turn in flight is interrupted'
    refute_nil last_event('notice'), 'the page is told'
    feed(L.text('LATE-ARRIVAL'))
    feed(L.result)
    texts = events_of('assistant_text').map { |e| e['text'] }
    assert_includes texts, big
    assert_includes texts, 'LATE-ARRIVAL', 'events past the cap are still recorded'
    assert_equal 1, events.first['seq'], 'nothing is dropped from the start'
    assert_equal [:refused, 'memory_cap'], @session.send_message('one more')
  end

  def test_messages_must_be_non_empty_at_most_32_kib_and_one_turn_at_a_time
    confirm!
    assert_equal [:refused, 'empty'], @session.send_message('')
    assert_equal [:refused, 'too_long'], @session.send_message('a' * 32_769)
    assert_equal [:refused, 'too_long'], @session.send_message('あ' * 10_923), '32 KiB is counted in bytes'
    assert_empty user_messages
    assert_equal :accepted, @session.send_message('a' * 32_768)
    assert_equal [:refused, 'turn_in_progress'], @session.send_message('second')
    feed(L.init('default'))
    feed(L.replay(user_messages.last['message']))
    feed(L.result)
    assert_equal :accepted, @session.send_message('after the turn')
  end

  def test_interrupt_is_a_control_request_and_its_success_changes_nothing
    confirm!
    @session.interrupt!
    request = interrupts.last
    refute_nil request
    assert_equal({ 'subtype' => 'interrupt' }, request['request'])
    assert_kind_of String, request['request_id']
    feed({ 'type' => 'control_response', 'response' => { 'subtype' => 'success', 'request_id' => request['request_id'] } })
    assert @session.accepting?
    assert_equal 'default', @session.mode_word
  end

  def test_other_stream_lines_seen_in_the_probes_change_nothing
    confirm!
    count = @writes.length
    L.noise.each { |line| feed(line) }
    assert_equal count, @writes.length
    assert_empty events_of('foreign_turn')
    assert @session.accepting?
  end

  def test_child_exit_is_an_event_and_closes_the_box
    confirm!
    _pid, status = Process.wait2(Process.spawn(RbConfig.ruby, '-e', 'exit 3'))
    @session.child_exited(status)
    refute_nil last_event('child_exited')
    refute @session.accepting?
    assert_equal :refused, Array(@session.send_message('anyone there?')).first
  end

  def test_events_are_numbered_from_one_and_replay_from_any_point
    confirm!
    owner_turn('hello')
    feed(L.text('hi'))
    feed(L.result)
    all = events
    seqs = all.map { |e| e['seq'] }
    assert_equal (1..all.length).to_a, seqs
    assert_equal seqs.last, @session.last_seq
    all.each do |event|
      refute_nil event['kind']
      assert at_from_clock?(event['at']), "#{event['kind']} at #{event['at'].inspect} comes from the injected clock"
    end
    assert_equal all.drop(2), plain(@session.events_after(2))
    assert_equal [], plain(@session.events_after(@session.last_seq))
    assert_equal all, events, 'reading does not consume'
  end

  def test_log_lines_hold_no_tool_input_and_no_message_text
    confirm!
    owner_turn('OWNER-TEXT-MARKER-71')
    feed(L.text('ASSISTANT-TEXT-MARKER-72'))
    input = { 'command' => 'echo TOOL-INPUT-MARKER-73', 'description' => 'DESCRIPTION-MARKER-74' }
    feed(L.tool_use('toolu_log', 'Bash', input))
    feed(L.can_use_tool('req-log', 'toolu_log', 'Bash', input, description: input['description']))
    assert_equal :ok, @session.answer_permission('req-log', 'allow')
    feed(L.answer_echo('req-log', { 'behavior' => 'allow', 'updatedInput' => input }))
    feed(L.tool_result('toolu_log', [{ 'type' => 'text', 'text' => 'TOOL-RESULT-MARKER-75' }], decision: 'accept',
                                                                                                 source: 'user_temporary'))
    feed(L.result)
    feed(L.init('default'))
    feed(L.foreign('FOREIGN-TEXT-MARKER-76'))
    refute_empty @logs
    log = JSON.generate(@logs)
    %w[OWNER-TEXT-MARKER-71 ASSISTANT-TEXT-MARKER-72 TOOL-INPUT-MARKER-73 DESCRIPTION-MARKER-74
       TOOL-RESULT-MARKER-75 FOREIGN-TEXT-MARKER-76].each { |marker| refute_includes log, marker }
    assert_includes log, 'req-log', 'each permission answer is logged by its request'
    assert_includes log, 'user_temporary', 'with the decision the CLI stated'
  end
end

class KairomoneConsoleSecretTest < Minitest::Test
  include ConsoleTestSupport
  KC = Kairomone::Console

  def setup
    @now = Time.utc(2031, 2, 3, 4, 5, 6)
    @secret = KC::Secret.new(clock: -> { @now })
  end

  def test_values_are_256_bit_hex_and_never_repeat
    values = Array.new(20) { @secret.issue_bootstrap }
    assert(values.all? { |v| HEX64.match?(v) })
    assert_equal values.uniq, values
    session = @secret.exchange(values.last)
    assert_match HEX64, session
    refute_includes values, session
  end

  def test_the_bootstrap_is_spent_on_first_use
    bootstrap = @secret.issue_bootstrap
    session = @secret.exchange(bootstrap)
    refute_nil session
    assert_nil @secret.exchange(bootstrap)
    assert @secret.valid_session?(session)
  end

  def test_a_wrong_or_missing_bootstrap_is_refused_and_spends_nothing
    bootstrap = @secret.issue_bootstrap
    [nil, '', '0' * 64, bootstrap.upcase, bootstrap[0, 63], "#{bootstrap}0", " #{bootstrap}"].each do |value|
      next if value == bootstrap

      assert_nil @secret.exchange(value), value.inspect
    end
    refute_nil @secret.exchange(bootstrap), 'failed guesses do not spend the printed bootstrap'
  end

  def test_the_bootstrap_expires_with_the_injected_clock
    bootstrap = @secret.issue_bootstrap
    @now += 601
    assert_nil @secret.exchange(bootstrap)
    fresh = @secret.issue_bootstrap
    @now += 599
    refute_nil @secret.exchange(fresh)
  end

  def test_the_bootstrap_lifetime_is_configurable
    secret = KC::Secret.new(clock: -> { @now }, bootstrap_ttl: 5)
    expired = secret.issue_bootstrap
    @now += 6
    assert_nil secret.exchange(expired)
    live = secret.issue_bootstrap
    @now += 4
    refute_nil secret.exchange(live)
  end

  def test_a_reissue_revokes_the_previous_session
    first = @secret.exchange(@secret.issue_bootstrap)
    assert @secret.valid_session?(first)
    bootstrap = @secret.issue_bootstrap
    refute @secret.valid_session?(first)
    second = @secret.exchange(bootstrap)
    assert @secret.valid_session?(second)
    refute @secret.valid_session?(first)
  end

  def test_only_the_current_session_is_valid
    refute @secret.valid_session?(nil)
    refute @secret.valid_session?('')
    bootstrap = @secret.issue_bootstrap
    refute @secret.valid_session?(bootstrap), 'a bootstrap is not a session'
    session = @secret.exchange(bootstrap)
    refute @secret.valid_session?(bootstrap)
    [session.upcase, session[0, 63], "#{session}0", " #{session}", session.reverse].each do |value|
      next if value == session

      refute @secret.valid_session?(value), value
    end
    assert @secret.valid_session?(session.dup)
  end
end

class KairomoneConsoleGateTest < Minitest::Test
  KC = Kairomone::Console
  SERVER = 'kairos-chain'
  SILENT = [['Bash', { 'command' => 'date', 'description' => 'Show the date' }],
            ['Bash', { 'command' => 'curl -s https://example.com', 'run_in_background' => false }],
            ['Read', { 'file_path' => '/private/tmp/kmc/work/a.txt' }],
            ['Grep', { 'pattern' => 'kairomone' }],
            ['Glob', { 'pattern' => '**/*.md' }],
            ['ToolSearch', { 'query' => 'select:mcp__kairos-chain__kairomone_status', 'max_results' => 1 }],
            *%w[status init observe knowledge profession growth companion].map { |t| ["mcp__#{SERVER}__kairomone_#{t}", {}] },
            ["mcp__#{SERVER}__kairomone_backup", { 'command' => 'create' }],
            ["mcp__#{SERVER}__kairomone_backup", { 'command' => 'verify', 'file' => 'a.kairomone.json' }]].freeze
  REFUSED = [*%w[Write Edit NotebookEdit Task Agent SendMessage ListAgents WebFetch WebSearch CronCreate ScheduleWakeup
                 RemoteTrigger Workflow AskUserQuestion ExitPlanMode Skill].map { |t| [t, {}] },
             # names a later CLI might add, and near misses of the five
             *%w[BashOutput KillShell Bash2 bash read Monitor2031].map { |t| [t, {}] },
             ["mcp__#{SERVER}__chain_status", {}], ["mcp__#{SERVER}__knowledge_update", {}],
             ["mcp__#{SERVER}__safe_file_write", {}], ['mcp__other__kairomone_status', {}],
             ["mcp__#{SERVER}-evil__kairomone_status", {}], ["mcp__#{SERVER}__kairomone", {}],
             ['Bash', { 'command' => 'sleep 600', 'run_in_background' => true }],
             ["mcp__#{SERVER}__kairomone_backup", { 'command' => 'restore', 'file' => 'a.kairomone.json', 'target_id' => 'copy' }],
             ["mcp__#{SERVER}__kairomone_backup", { 'command' => 'restore_new', 'file' => 'a.kairomone.json', 'dot_id' => 'dot' }]].freeze

  # PreToolUse stdin as Claude Code sends it.
  def hook(tool_name, tool_input = {})
    { 'session_id' => '839eae4f-aed9-4919-8f78-8564db3fb676', 'transcript_path' => '/private/tmp/kmc/transcript.jsonl',
      'cwd' => '/private/tmp/kmc/work', 'permission_mode' => 'default', 'hook_event_name' => 'PreToolUse',
      'tool_name' => tool_name, 'tool_input' => tool_input, 'tool_use_id' => 'toolu_01TLzDjBNz1GNFCdTbuvmurc' }
  end

  def run_program(program, stdin, env: {})
    Open3.capture3(env, RbConfig.ruby, '-e', program, stdin_data: stdin)
  end

  def test_builtins_are_the_five_measured_tools
    assert_equal %w[Bash Read Grep Glob ToolSearch], KC::Gate::BUILTINS
    assert_predicate KC::Gate::BUILTINS, :frozen?
  end

  def test_decide_is_silent_only_for_the_named_tools
    SILENT.each { |name, input| assert_nil KC::Gate.decide(hook(name, input), server: SERVER), "#{name} #{input}" }
    REFUSED.each do |name, input|
      reason = KC::Gate.decide(hook(name, input), server: SERVER)
      assert_kind_of String, reason, "#{name} #{input}"
      refute_empty reason.strip, name
    end
  end

  def test_decide_refuses_background_bash_for_any_truthy_value
    [true, 'true', 1].each do |value|
      assert_kind_of String, KC::Gate.decide(hook('Bash', { 'command' => 'sleep 9', 'run_in_background' => value }), server: SERVER), value.inspect
    end
    [false, nil].each do |value|
      assert_nil KC::Gate.decide(hook('Bash', { 'command' => 'sleep 9', 'run_in_background' => value }), server: SERVER), value.inspect
    end
  end

  def test_decide_refuses_input_without_a_tool_name
    assert_kind_of String, KC::Gate.decide({}, server: SERVER)
    assert_kind_of String, KC::Gate.decide(hook(nil), server: SERVER)
  end

  def test_the_program_stays_silent_or_refuses_and_never_prints_a_decision
    program = KC::Gate.program(server: SERVER)
    refute_includes program, 'permissionDecision'
    refute_includes program, 'hookSpecificOutput'
    refute_includes program, Kairomone::PACKAGE_ROOT, 'the gate reads no file the child could edit'
    SILENT.each do |name, input|
      out, err, status = run_program(program, JSON.generate(hook(name, input)))
      assert_equal 0, status.exitstatus, "#{name} #{input}: #{err}"
      assert_equal '', out, "#{name}: silent means no output"
    end
    REFUSED.each do |name, input|
      out, err, status = run_program(program, JSON.generate(hook(name, input)))
      assert_equal 2, status.exitstatus, "#{name} #{input}"
      assert_equal '', out, "#{name}: a refusal prints no decision"
      refute_empty err.strip, "#{name}: the reason goes to stderr"
    end
  end

  def test_the_program_refuses_malformed_stdin
    program = KC::Gate.program(server: SERVER)
    ['', 'not json', '[]', '"Bash"', 'null', '{"tool_input":{}}', '{"tool_name":null}', '{"tool_name":42}',
     '{"tool_name":["Bash"]}', '{"tool_name":"Bash"'].each do |stdin|
      out, _err, status = run_program(program, stdin)
      assert_equal 2, status.exitstatus, stdin
      assert_equal '', out, stdin
    end
    # Shapes Claude Code never sends: either answer is allowed, a crash (exit 1 lets the tool run) is not.
    ['{"tool_name":"Bash","tool_input":[1]}', '{"tool_name":"Bash","tool_input":"x"}',
     %({"tool_name":"mcp__#{SERVER}__kairomone_backup","tool_input":["restore"]})].each do |stdin|
      out, _err, status = run_program(program, stdin)
      assert_includes [0, 2], status.exitstatus, stdin
      assert_equal '', out, stdin
    end
  end

  def test_the_hook_command_runs_the_same_program_through_a_shell
    command = KC::Gate.hook_command(server: SERVER)
    words = Shellwords.split(command)
    assert_equal RbConfig.ruby, words.first
    index = words.index('-e')
    refute_nil index
    assert_equal KC::Gate.program(server: SERVER), words[index + 1]
    assert_equal '/opt/my ruby/bin/ruby', Shellwords.split(KC::Gate.hook_command(server: SERVER, ruby: '/opt/my ruby/bin/ruby')).first
    [['Read', { 'file_path' => '/private/tmp/kmc/a' }, 0], ["mcp__#{SERVER}__kairomone_status", {}, 0],
     ['Write', { 'file_path' => '/private/tmp/kmc/a', 'content' => 'x' }, 2],
     ['Bash', { 'command' => 'sleep 9', 'run_in_background' => true }, 2]].each do |name, input, code|
      out, _err, status = Open3.capture3('/bin/sh', '-c', command, stdin_data: JSON.generate(hook(name, input)))
      assert_equal code, status.exitstatus, name
      assert_equal '', out, name
    end
  end

  def test_the_program_treats_the_server_name_as_data
    Dir.mktmpdir('kairomone-console-gate-') do |tmp|
      marker = File.join(tmp, 'injected')
      weird = %(kc'"\#{File.write(ENV.fetch('KMC_MARKER'), 1)}\\)
      begin
        program = KC::Gate.program(server: weird)
      rescue Kairomone::Error, ArgumentError
        next # refusing such a name outright is also safe
      end
      env = { 'KMC_MARKER' => marker }
      own = hook("mcp__#{weird}__kairomone_status")
      _out, _err, own_status = run_program(program, JSON.generate(own), env: env)
      _out, _err, other_status = run_program(program, JSON.generate(hook("mcp__#{SERVER}__kairomone_status")), env: env)
      refute File.exist?(marker), 'no part of the server name runs as code'
      assert_equal KC::Gate.decide(own, server: weird).nil? ? 0 : 2, own_status.exitstatus, 'the program applies the decide rule'
      assert_equal 2, other_status.exitstatus, 'another server name is refused'
    end
  end

  def test_flag_settings_carry_the_restrictive_rules_and_the_gate_only
    rules = { 'deny' => ['Bash(rm:*)', 'Read(./secrets/**)'], 'ask' => ['Bash(git push:*)'] }
    settings = KC::Gate.flag_settings(server: SERVER, rules: rules)
    assert_equal %w[autoMemoryEnabled crossSessionInbound hooks permissions], settings.keys.sort
    assert_equal 'refuse', settings['crossSessionInbound']
    assert_equal false, settings['autoMemoryEnabled']
    assert_equal rules, settings['permissions']
    assert_equal({ 'PreToolUse' => [{ 'matcher' => '.*', 'hooks' => [{ 'type' => 'command',
                                                                         'command' => KC::Gate.hook_command(server: SERVER) }] }] },
                 settings['hooks'])
    assert_equal settings, JSON.parse(JSON.generate(settings)), 'plain JSON data'
  end

  def test_flag_settings_never_carry_an_allow_rule
    settings = KC::Gate.flag_settings(server: SERVER, rules: { 'deny' => ['Bash(rm:*)'], 'ask' => [], 'allow' => ['Write'] })
    refute settings['permissions'].key?('allow')
    assert_equal ['Bash(rm:*)'], settings['permissions']['deny']
  rescue Kairomone::Error, ArgumentError, KeyError
    nil # refusing rules that grant is also safe
  end
end

class KairomoneConsoleChildArgvTest < Minitest::Test
  KC = Kairomone::Console

  def setup
    @tmp = File.realpath(Dir.mktmpdir('kairomone-console-argv-'))
    @project_dir = File.join(@tmp, 'project')
    @data = File.join(@project_dir, '.kairos')
    @home = File.join(@tmp, 'home')
    [@data, @home].each { |dir| FileUtils.mkdir_p(dir) }
    File.write(File.join(@project_dir, '.mcp.json'),
               JSON.generate('mcpServers' => { 'kairos-chain' => { 'command' => 'kairos-chain', 'args' => ['--data-dir', @data] } }))
    @project = KC::Project.load(@project_dir, env: {}, home: @home)
    @settings = KC::Gate.flag_settings(server: 'kairos-chain', rules: { 'deny' => ['Bash(rm:*)'], 'ask' => [] })
  end

  def teardown
    FileUtils.remove_entry_secure(@tmp) if File.directory?(@tmp)
  end

  def value(argv, flag)
    index = argv.index(flag)
    index && argv[index + 1]
  end

  def test_argv_names_every_required_flag_once_and_nothing_else
    argv = KC::Child.argv(project: @project, flag_settings: @settings, claude: '/opt/fake/claude')
    assert_equal '/opt/fake/claude', argv.first
    bare = %w[-p --verbose --replay-user-messages --disable-slash-commands --strict-mcp-config]
    values = { '--input-format' => 'stream-json', '--output-format' => 'stream-json', '--permission-prompts' => 'host',
               '--permission-prompt-tool' => 'stdio', '--permission-mode' => 'manual', '--setting-sources' => '',
               '--mcp-config' => File.join(@project_dir, '.mcp.json'), '--append-system-prompt-file' => @project.skill_md_path }
    flags = argv.drop(1).select { |a| a.start_with?('-') }
    assert_equal (bare + values.keys + %w[--tools --settings]).sort, flags.sort, 'each flag once, no other flag'
    assert_equal 1 + bare.length + 2 * (values.length + 2), argv.length, 'no other argument'
    values.each { |flag, expected| assert_equal expected, value(argv, flag), flag }
    assert_equal KC::Gate::BUILTINS.sort, value(argv, '--tools').split(',').sort
    assert_equal @settings, JSON.parse(value(argv, '--settings'))
    assert_equal File.join(@project.package_root, 'plugin', 'SKILL.md'), value(argv, '--append-system-prompt-file')
  end

  def test_resume_adds_the_session_id_and_claude_is_the_default
    argv = KC::Child.argv(project: @project, flag_settings: @settings, resume: 'resume-session-7f3a')
    assert_equal 'claude', argv.first
    assert_equal 'resume-session-7f3a', value(argv, '--resume')
    assert_equal 1, argv.count('--resume')
  end

  def test_argv_carries_no_secret
    secret = KC::Secret.new
    bootstrap = secret.issue_bootstrap
    session = secret.exchange(bootstrap)
    settings = KC::Gate.flag_settings(server: @project.server_name, rules: @project.restrictive_rules)
    joined = KC::Child.argv(project: @project, flag_settings: settings, resume: 'resume-session-7f3a').join("\0")
    refute_includes joined, bootstrap
    refute_includes joined, session
  end
end

class KairomoneConsoleProjectTest < Minitest::Test
  KC = Kairomone::Console
  CORE_LIB = File.expand_path('lib', __dir__)
  PACKAGE = File.expand_path('templates/skillsets/kairomone', __dir__)
  # Loads the console from an installed copy, so that Kairomone::PACKAGE_ROOT
  # (the Project's package_root) is that copy, then runs the start check.
  START_CHECK = <<~'RUBY'
    core, package, project_dir, home = ARGV
    $LOAD_PATH.unshift(core)
    $LOAD_PATH.unshift(File.join(package, 'lib'))
    require 'json'
    require 'kairomone'
    require File.join(package, 'lib', 'kairomone', 'console')
    project = Kairomone::Console::Project.load(project_dir, env: {}, home: home)
    begin
      puts JSON.generate('result' => project.start_check!, 'package_root' => project.package_root)
    rescue Kairomone::Console::Refusal => e
      puts JSON.generate('refusal' => e.message, 'package_root' => project.package_root)
    end
  RUBY

  def setup
    @tmp = File.realpath(Dir.mktmpdir('kairomone-console-project-'))
    @project = File.join(@tmp, 'project')
    @data = File.join(@tmp, 'data') # deliberately not <project>/.kairos
    @home = File.join(@tmp, 'home')
    [@project, @data, @home].each { |dir| FileUtils.mkdir_p(dir) }
  end

  def teardown
    KairosMcp.reset_data_dir!
    FileUtils.remove_entry_secure(@tmp) if File.directory?(@tmp)
  end

  def server(data_dir = @data, env: nil)
    { 'command' => 'kairos-chain', 'args' => ['--data-dir', data_dir] }.merge(env ? { 'env' => env } : {})
  end

  def mcp(content)
    File.write(File.join(@project, '.mcp.json'), content.is_a?(String) ? content : JSON.generate(content))
  end

  def valid_mcp! = mcp('mcpServers' => { 'kairos-chain' => server })
  def load_project(env: {}) = KC::Project.load(@project, env: env, home: @home)

  def settings_file(path, value)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, value.is_a?(String) ? value : JSON.generate(value))
  end

  def settings_paths
    [File.join(@home, '.claude', 'settings.json'), File.join(@project, '.claude', 'settings.json'),
     File.join(@project, '.claude', 'settings.local.json')]
  end

  # The core's own install path, recording to the chain of the given data dir.
  def install(data, source = PACKAGE, force: false)
    KairosMcp.data_dir = data
    KairosMcp::SkillSetManager.new(skillsets_dir: File.join(data, 'skillsets')).install(source, force: force)
  ensure
    KairosMcp.reset_data_dir!
  end

  def installed = File.join(@data, 'skillsets', 'kairomone')

  def start_check
    out, err, status = Open3.capture3({ 'KAIROS_DATA_DIR' => nil }, RbConfig.ruby, '-e', START_CHECK, CORE_LIB, installed,
                                      @project, @home, chdir: @tmp)
    assert status.success?, err
    result = JSON.parse(out.lines.last)
    assert_equal File.realpath(installed), File.realpath(result['package_root']), 'the Project points at the installed copy'
    result
  end

  # Each child exits with exit! so that no at_exit hook of this test runs there.
  def fork_child
    fork do
      begin
        yield
      rescue Exception # rubocop:disable Lint/RescueException
        exit!(4)
      end
      exit!(0)
    end
  end

  def lock_taken_in_child?
    pid = fork_child do
      KC::Project.load(@project, env: {}, home: @home).lock!
    rescue KC::Refusal
      exit!(3)
    end
    _, status = Process.wait2(pid)
    refute_equal 4, status.exitstatus, 'unexpected error in the child'
    status.exitstatus.zero?
  end

  def test_refusal_is_a_kairomone_error
    assert_operator KC::Refusal, :<, Kairomone::Error
  end

  def test_load_names_the_single_server_and_derives_every_path
    valid_mcp!
    project = load_project
    assert_equal @project, project.dir
    assert_equal 'kairos-chain', project.server_name
    assert_equal @data, project.data_dir
    assert_equal File.realpath(Kairomone::PACKAGE_ROOT), File.realpath(project.package_root)
    assert_equal File.join(project.package_root, 'plugin', 'SKILL.md'), project.skill_md_path
    assert_equal File.join(@data, 'run'), project.run_dir
    assert_equal File.join(@data, 'run', 'kairomone_console.log'), project.log_path
  end

  def test_load_refuses_every_mcp_json_shape_it_cannot_trust
    file = File.join(@tmp, 'a_file')
    File.write(file, 'x')
    shapes = {
      'no .mcp.json' => nil,
      'not JSON' => '{"mcpServers": ',
      'top level is a list' => '[]',
      'no mcpServers' => { 'servers' => { 'kairos-chain' => server } },
      'mcpServers is a list' => { 'mcpServers' => [server] },
      'no server' => { 'mcpServers' => {} },
      'two servers' => { 'mcpServers' => { 'kairos-chain' => server, 'other' => server } },
      'server is not an object' => { 'mcpServers' => { 'kairos-chain' => "kairos-chain --data-dir #{@data}" } },
      'no args' => { 'mcpServers' => { 'kairos-chain' => { 'command' => 'kairos-chain' } } },
      'args not a list' => { 'mcpServers' => { 'kairos-chain' => { 'command' => 'kairos-chain', 'args' => "--data-dir #{@data}" } } },
      'no --data-dir' => { 'mcpServers' => { 'kairos-chain' => { 'command' => 'kairos-chain', 'args' => ['--stdio'] } } },
      '--data-dir without a value' => { 'mcpServers' => { 'kairos-chain' => { 'command' => 'kairos-chain', 'args' => ['--data-dir'] } } },
      'relative data dir' => { 'mcpServers' => { 'kairos-chain' => server('data') } },
      'missing data dir' => { 'mcpServers' => { 'kairos-chain' => server(File.join(@tmp, 'absent')) } },
      'data dir is a file' => { 'mcpServers' => { 'kairos-chain' => server(file) } },
      'server env names KAIROS_DATA_DIR' => { 'mcpServers' => { 'kairos-chain' => server(env: { 'KAIROS_DATA_DIR' => @data }) } }
    }
    shapes.each do |label, content|
      FileUtils.rm_f(File.join(@project, '.mcp.json'))
      mcp(content) unless content.nil?
      error = assert_raises(KC::Refusal, label) { load_project }
      refute_empty error.message.strip, label
      refute_includes error.message.strip, "\n", "#{label}: a refusal is one human line"
    end
  end

  def test_load_refuses_a_kairos_data_dir_naming_another_directory
    valid_mcp!
    other = File.join(@tmp, 'other')
    FileUtils.mkdir_p(other)
    assert_raises(KC::Refusal) { load_project(env: { 'KAIROS_DATA_DIR' => other }) }
    assert_equal @data, load_project(env: { 'KAIROS_DATA_DIR' => @data }).data_dir
    assert_equal @data, load_project(env: { 'KAIROS_DATA_DIR' => "#{@data}/" }).data_dir, 'compared after File.expand_path'
    mcp('mcpServers' => { 'kairos-chain' => server(env: { 'RUBYOPT' => '-W0' }) })
    assert_equal 'kairos-chain', load_project.server_name, 'other server env entries are fine'
  end

  def test_restrictive_rules_are_the_ordered_union_and_never_carry_allow
    valid_mcp!
    home, project, local = settings_paths
    settings_file(home, 'permissions' => { 'allow' => ['Write', 'Bash(curl:*)'], 'deny' => ['Bash(rm:*)', 'Read(~/.ssh/**)'],
                                           'ask' => ['Bash(git push:*)'], 'defaultMode' => 'acceptEdits' },
                        'hooks' => { 'PreToolUse' => [{ 'matcher' => '.*', 'hooks' => [{ 'type' => 'command', 'command' => 'true' }] }] })
    settings_file(project, 'permissions' => { 'deny' => ['Read(~/.ssh/**)', 'Bash(sudo:*)'], 'allow' => ['mcp__kairos-chain__kairomone_backup'] })
    settings_file(local, 'permissions' => { 'ask' => ['mcp__kairos-chain__kairomone_growth', 'Bash(git push:*)'],
                                            'deny' => ['Bash(rm:*)', 'WebFetch'], 'allow' => ['Edit'] })
    assert_equal({ 'deny' => ['Bash(rm:*)', 'Read(~/.ssh/**)', 'Bash(sudo:*)', 'WebFetch'],
                   'ask' => ['Bash(git push:*)', 'mcp__kairos-chain__kairomone_growth'] }, load_project.restrictive_rules)
  end

  def test_restrictive_rules_skip_missing_files
    valid_mcp!
    assert_equal({ 'deny' => [], 'ask' => [] }, load_project.restrictive_rules)
    settings_file(settings_paths.last, 'permissions' => { 'ask' => ['Bash(git push:*)'] })
    assert_equal({ 'deny' => [], 'ask' => ['Bash(git push:*)'] }, load_project.restrictive_rules)
  end

  def test_an_unparseable_settings_file_stops_the_start
    valid_mcp!
    settings_paths.each do |broken|
      settings_paths.each { |path| FileUtils.rm_f(path) }
      settings_file(broken, '{"permissions": {"deny": [')
      assert_raises(KC::Refusal, broken) { load_project.restrictive_rules }
    end
  end

  def test_the_lock_is_exclusive_across_processes_and_released
    valid_mcp!
    project = load_project
    lock = project.lock!
    assert_equal 0o700, File.stat(project.run_dir).mode & 0o777
    refute lock_taken_in_child?, 'a second console on the same folder is refused while the lock is held'
    lock.release
    assert lock_taken_in_child?, 'a released lock can be taken again'
  end

  def test_a_lock_left_by_a_killed_console_does_not_block
    valid_mcp!
    reader, writer = IO.pipe
    pid = fork_child do
      reader.close
      KC::Project.load(@project, env: {}, home: @home).lock!
      writer.write('locked')
      writer.close
      sleep
    end
    writer.close
    assert_equal 'locked', reader.read(6)
    Process.kill('KILL', pid)
    Process.wait(pid)
    load_project.lock!.release
  ensure
    reader&.close
  end

  def test_start_check_passes_for_the_recorded_install
    install(@data)
    valid_mcp!
    assert_equal true, start_check['result']
  end

  def test_start_check_refuses_an_install_edited_after_recording_and_names_the_reinstall
    install(@data)
    valid_mcp!
    File.open(File.join(installed, 'plugin', 'SKILL.md'), 'a') { |f| f.puts('<!-- edited after install -->') }
    result = start_check
    refute_nil result['refusal']
    assert_match(/kairos-chain skillset\b.*\binstall\b/, result['refusal'], 'names the core reinstall command')
  end

  def test_start_check_refuses_without_an_install_event_for_kairomone
    FileUtils.mkdir_p(File.join(@data, 'skillsets'))
    FileUtils.cp_r(PACKAGE, installed)
    valid_mcp!
    refute_nil start_check['refusal'], 'no chain at all'
    other = File.join(@tmp, 'other_ss')
    FileUtils.mkdir_p(other)
    File.write(File.join(other, 'skillset.json'), JSON.generate('name' => 'other_ss', 'version' => '1.0.0', 'layer' => 'L1'))
    install(@data, other)
    events = JSON.parse(File.read(File.join(@data, 'storage', 'blockchain.json'))).flat_map { |b| b['data'] }
    assert(events.any? { |d| d.include?('"skillset_name":"other_ss"') }, 'fixture: another SkillSet event is on the chain')
    refute_nil start_check['refusal'], 'an event for another SkillSet does not count'
  end

  def test_start_check_follows_the_latest_kairomone_event
    install(@data)
    valid_mcp!
    variant = File.join(@tmp, 'variant')
    FileUtils.cp_r(PACKAGE, variant)
    File.open(File.join(variant, 'plugin', 'SKILL.md'), 'a') { |f| f.puts('<!-- reinstalled variant -->') }
    install(@data, variant, force: true)
    assert_equal true, start_check['result'], 'the reinstall recorded the edited content'
    File.binwrite(File.join(installed, 'plugin', 'SKILL.md'), File.binread(File.join(PACKAGE, 'plugin', 'SKILL.md')))
    refute_nil start_check['refusal'], 'an earlier event matching the files does not count'
  end
end

class KairomoneConsoleServerTest < Minitest::Test
  include ConsoleTestSupport
  L = ConsoleLines
  KC = Kairomone::Console
  STYLE = "\n  main { font-family: sans-serif; }\n"
  SCRIPT = "\n  document.documentElement.dataset.fixture = 'console';\n"
  PAGE = "<!doctype html>\n<html lang=\"ja\"><head><meta charset=\"utf-8\"><title>fixture</title><style>#{STYLE}</style></head>\n" \
         "<body><main>fixture page</main><script>#{SCRIPT}</script></body></html>\n"

  def setup
    @tmp = File.realpath(Dir.mktmpdir('kairomone-console-server-'))
    page = File.join(@tmp, 'console.html')
    File.write(page, PAGE)
    @now = Time.utc(2031, 2, 3, 4, 5, 6)
    @writes = []
    @session = KC::Session.new(writer: ->(hash) { @writes << plain(hash) }, clock: -> { @now })
    @session.start!
    @secret = KC::Secret.new(clock: -> { @now })
    @status = { 'data_dir' => '/fixture/.kairos', 'status' => { 'initialized' => true, 'profile' => { 'dot_id' => 'fixture_dot' } } }
    @server = KC::Server.new(session: @session, secret: @secret, status_reader: -> { @status }, page_path: page, port: 0)
    @server.start
    @port = @server.port
    @origin = "http://127.0.0.1:#{@port}"
    @bootstrap = @secret.issue_bootstrap
  end

  def teardown
    @server&.shutdown
    FileUtils.remove_entry_secure(@tmp) if File.directory?(@tmp)
  end

  def digest(text) = Base64.strict_encode64(Digest::SHA256.digest(text))

  def expected_csp
    { 'default-src' => "'none'", 'script-src' => "'sha256-#{digest(SCRIPT)}'", 'style-src' => "'sha256-#{digest(STYLE)}'",
      'connect-src' => "'self'", 'img-src' => "'self' data:", 'frame-ancestors' => "'none'", 'base-uri' => "'none'",
      'form-action' => "'none'" }
  end

  def directives(header)
    header.to_s.split(';').map(&:strip).reject(&:empty?).to_h do |directive|
      name, *values = directive.split(/\s+/)
      [name, values.join(' ')]
    end
  end

  def assert_contract_headers(res)
    assert_nil res['Set-Cookie'], 'no cookie is ever set'
    assert_empty res.to_hash.keys.grep(/\Aaccess-control-/), 'no CORS headers'
    assert_equal expected_csp, directives(res['Content-Security-Policy'])
    assert_equal 'DENY', res['X-Frame-Options']
    assert_equal 'no-referrer', res['Referrer-Policy']
    assert_includes res['Cache-Control'].to_s.split(',').map(&:strip), 'no-store'
    assert_equal 'nosniff', res['X-Content-Type-Options']
  end

  def request(method, path, session: nil, origin: (method == :post ? :page : nil), host: nil, headers: {}, body: nil,
              read_timeout: 10, check: true)
    req = { get: Net::HTTP::Get, post: Net::HTTP::Post, options: Net::HTTP::Options }.fetch(method).new(path)
    req['Host'] = host if host
    req['Origin'] = origin == :page ? @origin : origin if origin
    req['X-Kairomone-Session'] = session if session
    headers.each { |name, value| req[name] = value }
    if method == :post
      req.body = body.is_a?(String) ? body : JSON.generate(body || {})
      req['Content-Type'] = 'application/json'
    end
    res = Net::HTTP.start('127.0.0.1', @port, open_timeout: 5, read_timeout: read_timeout) { |http| http.request(req) }
    assert_contract_headers(res) if check
    res
  end

  def exchange(bootstrap = @bootstrap, **options)
    request(:post, '/session', headers: { 'X-Kairomone-Bootstrap' => bootstrap }, **options)
  end

  def session!(bootstrap = @bootstrap)
    res = exchange(bootstrap)
    assert_equal '200', res.code
    value = JSON.parse(res.body)['session']
    assert_match HEX64, value
    value
  end

  def confirm_mode! = feed(L.echo(mode_requests.first['request_id'], 'default'))

  def test_the_page_is_served_with_the_contract_headers_and_hash_pinned_csp
    res = request(:get, '/')
    assert_equal '200', res.code
    assert_match(%r{\Atext/html}, res['Content-Type'])
    assert_match(/utf-8/i, res['Content-Type'])
    assert_includes res.body, SCRIPT
    assert_equal "http://127.0.0.1:#{@port}", @server.origin
  end

  def test_every_request_needs_the_exact_host
    hosts = ["localhost:#{@port}", '127.0.0.1', "127.0.0.1:#{@port + 1}", "127.0.0.1:#{@port}0", "evil.example:#{@port}",
             "[::1]:#{@port}"]
    hosts.each { |host| assert_equal '403', request(:get, '/', host: host).code, host }
    assert_equal '403', exchange(host: "localhost:#{@port}").code
    session = session!
    assert_equal '403', request(:get, '/events?after=0', session: session, host: "localhost:#{@port}").code
    assert_equal '403', request(:post, '/message', session: session, host: "evil.example:#{@port}", body: { 'text' => 'x' }).code
  end

  def test_every_post_needs_the_exact_origin_and_a_refused_post_changes_nothing
    bad = [nil, 'null', "http://localhost:#{@port}", "http://127.0.0.1:#{@port + 1}", "https://127.0.0.1:#{@port}",
           "http://127.0.0.1:#{@port}0", 'http://127.0.0.1', "http://127.0.0.1:#{@port}.evil.example"]
    bad.each { |origin| assert_equal '403', exchange(origin: origin).code, origin.inspect }
    session = session!
    confirm_mode!
    bad.each do |origin|
      assert_equal '403', request(:post, '/message', session: session, origin: origin, body: { 'text' => 'hello' }).code, origin.inspect
    end
    assert_empty user_messages
  end

  def test_the_bootstrap_is_exchanged_once_for_a_session
    assert_equal '403', request(:post, '/session').code, 'missing bootstrap'
    assert_equal '403', exchange('0' * 64).code
    session = session!
    assert_equal '403', exchange.code, 'spent'
    assert_equal '403', exchange(session).code, 'a session is not a bootstrap'
    assert_equal '200', request(:get, '/events?after=0', session: session).code
  end

  def test_an_expired_bootstrap_is_refused
    @now += 601
    assert_equal '403', exchange.code
  end

  def test_the_session_header_is_required_everywhere_but_the_page_and_the_exchange
    session = session!
    routes = [[:get, '/events?after=0'], [:get, '/status'], [:post, '/message'], [:post, '/permission/req-x'],
              [:post, '/mode'], [:post, '/interrupt']]
    routes.each do |method, path|
      [nil, '', @bootstrap, '0' * 64, session.upcase].each do |value|
        next if value == session

        assert_equal '403', request(method, path, session: value, body: {}).code, "#{method} #{path} #{value.inspect}"
      end
    end
    assert_equal 1, @writes.length, 'only the start mode request was written'
  end

  def test_a_reissued_bootstrap_revokes_the_session
    first = session!
    fresh = @secret.issue_bootstrap
    assert_equal '403', request(:get, '/events?after=0', session: first).code
    second = session!(fresh)
    assert_equal '200', request(:get, '/events?after=0', session: second).code
  end

  def test_events_replay_from_zero_and_a_long_poll_wakes_on_a_new_event
    session = session!
    body = JSON.parse(request(:get, '/events?after=0', session: session).body)
    assert_equal plain(@session.events_after(0)), body['events']
    assert_equal @session.last_seq, body['last']
    last = body['last']
    waiter = Thread.new { request(:get, "/events?after=#{last}", session: session, read_timeout: 30) }
    sleep 0.3
    confirm_mode!
    res = waiter.join(5)&.value
    refute_nil res, 'the long poll returns once a new event exists'
    fresh = JSON.parse(res.body)['events']
    refute_empty fresh
    assert(fresh.all? { |e| e['seq'] > last })
    assert(fresh.any? { |e| e['kind'] == 'mode' })
  ensure
    waiter&.kill
  end

  def test_message_route_answers
    session = session!
    res = request(:post, '/message', session: session, body: { 'text' => 'hello' })
    assert_equal ['409', { 'error' => 'not_accepting', 'reason' => 'mode_unconfirmed' }], [res.code, JSON.parse(res.body)]
    confirm_mode!
    res = request(:post, '/message', session: session, body: { 'text' => '' })
    assert_equal ['409', 'empty'], [res.code, JSON.parse(res.body)['reason']]
    over = JSON.generate('text' => 'a' * 65_526)
    at_limit = JSON.generate('text' => 'a' * 65_525)
    assert_equal [65_537, 65_536], [over.bytesize, at_limit.bytesize]
    assert_equal '413', request(:post, '/message', session: session, body: over).code
    res = request(:post, '/message', session: session, body: at_limit)
    assert_equal ['409', 'too_long'], [res.code, JSON.parse(res.body)['reason']], 'a 64 KiB body is read; its text is too long'
    res = request(:post, '/message', session: session, body: { 'text' => 'hello' })
    assert_equal ['202', { 'accepted' => true }], [res.code, JSON.parse(res.body)]
    assert_equal ['hello'], user_messages.map { |m| text_of(m.dig('message', 'content')) }
    res = request(:post, '/message', session: session, body: { 'text' => 'again' })
    assert_equal ['409', 'turn_in_progress'], [res.code, JSON.parse(res.body)['reason']]
  end

  def test_permission_route_answers_once_with_the_shown_input
    session = session!
    confirm_mode!
    assert_equal '202', request(:post, '/message', session: session, body: { 'text' => 'run it' }).code
    feed(L.init('default'))
    feed(L.replay(user_messages.last['message']))
    input = { 'command' => 'echo shown', 'description' => 'Print' }
    feed(L.tool_use('toolu_h1', 'Bash', input))
    feed(L.can_use_tool('req-http-1', 'toolu_h1', 'Bash', input, description: 'Print'))
    assert_equal ['req-http-1'], @session.pending_ids
    assert_equal '404', request(:post, '/permission/req-unknown', session: session, body: { 'decision' => 'allow' }).code
    res = request(:post, '/permission/req-http-1', session: session,
                                                   body: { 'decision' => 'allow', 'updatedInput' => { 'command' => 'echo replaced' } })
    unless res.code == '200'
      assert_empty answers_for('req-http-1'), 'a refused answer writes nothing'
      res = request(:post, '/permission/req-http-1', session: session, body: { 'decision' => 'allow' })
    end
    assert_equal '200', res.code
    assert_equal [input], answers_for('req-http-1').map { |a| a.dig('response', 'response', 'updatedInput') },
                 'the page cannot edit the input it allows'
    assert_equal '409', request(:post, '/permission/req-http-1', session: session, body: { 'decision' => 'deny' }).code
    feed(L.tool_use('toolu_h2', 'Bash', input))
    feed(L.can_use_tool('req-http-2', 'toolu_h2', 'Bash', input, description: 'Print'))
    assert_equal '200', request(:post, '/permission/req-http-2', session: session, body: { 'decision' => 'deny' }).code
    assert_equal ['deny'], answers_for('req-http-2').map { |a| a.dig('response', 'response', 'behavior') }
  end

  def test_mode_interrupt_and_status_routes
    session = session!
    confirm_mode!
    assert_equal '202', request(:post, '/mode', session: session, body: { 'mode' => 'auto' }).code
    assert_equal 'auto', mode_requests.last.dig('request', 'mode')
    count = @writes.length
    assert_equal '409', request(:post, '/mode', session: session, body: { 'mode' => 'bypassPermissions' }).code
    assert_equal count, @writes.length
    assert_equal '202', request(:post, '/interrupt', session: session, body: {}).code
    refute_empty interrupts
    res = request(:get, '/status', session: session)
    assert_equal ['200', @status], [res.code, JSON.parse(res.body)]
  end

  def test_unknown_route_and_a_cors_preflight
    session = session!
    assert_equal '404', request(:get, '/nope', session: session).code
    res = request(:options, '/message', origin: 'http://evil.example', check: false,
                                        headers: { 'Access-Control-Request-Method' => 'POST',
                                                   'Access-Control-Request-Headers' => 'x-kairomone-session' })
    assert_empty res.to_hash.keys.grep(/\Aaccess-control-/), 'a preflight gets no CORS grant'
  end
end
