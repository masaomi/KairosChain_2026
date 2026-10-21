# frozen_string_literal: true

# Host hook entry for the agent SkillSet (design v0.5.1 §4). One script for
# every event; the event name comes from the hook input. In a session that is
# not bound to a run it only marks the guard as seen (PreToolUse,
# SessionStart), tells KairosChain's own agent tools which session calls them,
# and keeps the operator's words that may later adopt, confirm or correct
# something; otherwise it returns without output, so ordinary sessions pay one
# Ruby start and a file stat.

require 'json'
require 'fileutils'

# The host may start hooks without a UTF-8 locale; journals and transcripts
# hold the operator's words in UTF-8.
Encoding.default_external = Encoding::UTF_8

input = begin
  JSON.parse($stdin.read)
rescue JSON::ParserError => e
  # Unreadable input cannot be attributed to a session; on a failing exit
  # the plugin's PreToolUse command line blocks the call only if the session
  # id it finds in the input is bound here.
  warn "agent hook: unreadable hook input (#{e.message[0, 100]})"
  exit 1
end

event = input['hook_event_name'].to_s
sid = input['session_id'].to_s
data_dir = ENV['KAIROS_DATA_DIR'] || File.join(ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd, '.kairos')
root = File.join(data_dir, 'storage', 'agent')
safe = sid.gsub(/[^A-Za-z0-9_.-]/, '_')

bound = !sid.empty? && File.exist?(File.join(root, 'bindings', safe))
begin
  if %w[PreToolUse SessionStart].include?(event) && !sid.empty?
    FileUtils.mkdir_p(File.join(root, 'guard_seen'))
    FileUtils.touch(File.join(root, 'guard_seen', safe))
  end
rescue SystemCallError
  # The prelude never blocks an ordinary session; a bound one fails closed below.
  exit 0 unless bound
end

# KairosChain's own agent tools (a server whose name says kairos, never
# another server's agent_*) learn the calling session and its project in
# every session (INV-6), without loading the library (Hooks.agent_tool?).
AGENT_TOOL = /\Amcp__(.+)__agent_(start|status|advance|items|finish|stop)\z/
agent_tool = (m = AGENT_TOOL.match(input['tool_name'].to_s)) && m[1].match?(/kairos/i) ? m[2] : nil
# A bound session goes through the library, which also releases an ended
# run's guard once the operator has spoken.
if event == 'PreToolUse' && agent_tool && !bound
  extra = { '_session_id' => sid, '_project_dir' => ENV['CLAUDE_PROJECT_DIR'] || input['cwd'] }.compact
  puts JSON.generate('hookSpecificOutput' => { 'hookEventName' => 'PreToolUse', 'permissionDecision' => 'allow',
                                               'updatedInput' => (input['tool_input'] || {}).merge(extra) })
  exit 0
end

# Words that may adopt a policy, or name a decision or item to confirm,
# correct or resolve (Hooks::REFERENCE).
REFERENCE = /(?<![A-Za-z0-9])[DI]\d+(?![0-9A-Za-z])|(?i:adopt\s+policy)|採用|訂正|承認|確定(?!申告)|差し戻/
needs_full = bound ||
             (event == 'PostToolUse' && agent_tool == 'start') ||
             (event == 'SessionStart' && Dir.exist?(File.join(root, 'runs'))) ||
             (event == 'UserPromptSubmit' && input['prompt'].to_s.match?(REFERENCE))
exit 0 unless needs_full

begin
  $LOAD_PATH.unshift(ENV['KAIROS_MCP_LIB']) if ENV['KAIROS_MCP_LIB']
  require_relative '../lib/agent/hooks'

  project_root = ENV['CLAUDE_PROJECT_DIR'] || File.dirname(data_dir)
  paths = KairosMcp::SkillSets::Agent::Paths.new(data_dir)

  # The operator's own deny and ask rules (user and project). A guard allow
  # does not suppress the host's prompt for an ask rule, and a run's operator
  # is not answering, so both are refused and queued (design §8). Bash rules
  # are matched against every command the original line runs, before it is
  # wrapped for confinement.
  deny = []
  rules = []
  [File.expand_path('~/.claude/settings.json'),
   File.join(project_root, '.claude', 'settings.json'),
   File.join(project_root, '.claude', 'settings.local.json')].each do |path|
    next unless File.exist?(path)

    perms = JSON.parse(File.read(path))['permissions'] || {}
    %w[deny ask].each do |kind|
      Array(perms[kind]).each do |rule|
        rule = rule.to_s.strip
        if (m = rule.match(/\ABash\((.+)\)\z/))
          pat = m[1]
          prefix = pat.end_with?(':*')
          # The host's wildcard form: * spans any text, a multi-line command's
          # newlines too, and a final ' *' also takes the bare command
          # (Bash(git commit *) names `git commit`).
          body = Regexp.escape(prefix ? pat[0..-3] : pat).gsub('\\*', '.*').sub(/\\ \.\*\z/) { '(?:\s.*)?' }
          # A prefix ends at a word: Bash(mv:*) names mv, not mvn.
          deny << if !prefix then /\A\s*#{body}\s*\z/m
                  elsif pat[0..-3].match?(/\w\z/) then /\A\s*#{body}(?=\s|\z)/m
                  else /\A\s*#{body}/m
                  end
        elsif rule == 'Bash'
          deny << /./
        elsif (m = rule.match(/\A([A-Za-z0-9_*-]+)(?:\((.*)\))?\z/))
          rules << { 'kind' => kind, 'tool' => m[1], 'spec' => m[2] }
        end
      end
    end
  rescue JSON::ParserError
    next
  end

  stand_in_factory = lambda do |_run, policy|
    llm_call = File.join(data_dir, 'skillsets', 'llm_client', 'tools', 'llm_call.rb')
    require 'kairos_mcp/tools/base_tool'
    require llm_call
    KairosMcp::SkillSets::Agent::StandIn.new(
      policy: policy,
      instruction_mode: KairosMcp::SkillSets::Agent::InstructionMode.load(data_dir),
      llm: KairosMcp::SkillSets::Agent::StandIn.default_llm(KairosMcp::SkillSets::LlmClient::Tools::LlmCall)
    )
  end

  hooks = KairosMcp::SkillSets::Agent::Hooks.new(paths: paths, project_root: project_root,
                                                 stand_in_factory: stand_in_factory, settings_deny: deny,
                                                 settings_rules: rules)
  out = hooks.handle(event, input)
  puts JSON.generate(out) if out
  exit 0
rescue StandardError, ScriptError => e
  warn "agent hook (#{event}): #{e.class}: #{e.message[0, 300]}"
  if event == 'PreToolUse' && bound
    puts JSON.generate('hookSpecificOutput' => { 'hookEventName' => 'PreToolUse', 'permissionDecision' => 'deny',
                                                 'permissionDecisionReason' => "agent guard failed: #{e.class}" })
    exit 0
  end
  exit 1
end
