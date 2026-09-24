# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'open3'

# The projected command itself (plugin/hooks.json), run under sh the way the
# harness runs it, before the script is reached.
class TestHookCommand < Minitest::Test
  CMD = JSON.parse(File.read(File.expand_path('../plugin/hooks.json', __dir__)))
            .dig('hooks', 'Stop', 0, 'hooks', 0, 'command')

  def run_cmd(env)
    Open3.capture3({ 'PATH' => ENV['PATH'] }.merge(env), 'sh', '-c', CMD, stdin_data: '{}',
                   unsetenv_others: true)
  end

  def test_every_event_uses_the_same_guarded_command
    hooks = JSON.parse(File.read(File.expand_path('../plugin/hooks.json', __dir__)))['hooks']
    assert_equal %w[PostModelSwitch Stop SubagentStop], hooks.keys.sort
    assert(hooks.values.all? { |h| h.dig(0, 'hooks', 0, 'command') == CMD })
  end

  def test_a_codex_named_variable_with_no_dirs_is_a_silent_no_op
    out, err, st = run_cmd('CODEX_HOME' => '/tmp')
    assert_equal [0, '', ''], [st.exitstatus, out, err]
  end

  def test_no_dirs_and_no_codex_name_is_a_visible_failure
    out, err, st = run_cmd({})
    assert_equal [1, ''], [st.exitstatus, out]
    assert_match(/neither KAIROS_DATA_DIR nor CLAUDE_PROJECT_DIR/, err)
  end

  # Round 2 (K11): a CODEX line inside another variable's value is not a name.
  def test_a_codex_line_inside_a_value_does_not_pass_for_a_name
    _out, err, st = run_cmd('FOO' => "bar\nCODEX_fake=1")
    assert_equal 1, st.exitstatus
    assert_match(/neither KAIROS_DATA_DIR/, err)
  end
end
