# frozen_string_literal: true

require 'json'
require 'yaml'
require 'time'
require 'fileutils'

# Shared parts of the three hooks (design log/compaction_handoff_design_v0.3.md).
# Claude Code layer: this file knows the hook input; it lives in hooks/, outside
# lib/, so nothing on the KairosChain side reaches it by name (INV-9).
module CompactionHandoffHook
  SESSION_ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  CONFIG_FILE = File.expand_path('../config/compaction_handoff.yml', __dir__)
  TAG_FORMAT = /\A[a-z][a-z0-9_]{0,40}\z/
  # A usage figure below this share of the previous one is taken as a
  # compaction that actually happened (INV-7). Only real context sizes count
  # (UsageReader drops zero and synthetic records), so an API error is not one.
  DROP_RATIO = 0.5
  FRONTMATTER_KEY = 'compaction_handoff_session'

  class Unreadable < StandardError; end

  module_function

  def read_input(io = $stdin)
    JSON.parse(io.read.to_s)
  rescue JSON::ParserError
    raise Unreadable, 'hook input is not JSON'
  end

  def session_id(input)
    sid = input.is_a?(Hash) ? input['session_id'].to_s : ''
    raise Unreadable, 'hook input carries no well-formed session id' unless SESSION_ID.match?(sid)

    sid
  end

  # A subagent's transcript lives under <session>/subagents/; its compaction
  # neither spends nor ends the main thread's cycle.
  def subagent?(input)
    input['transcript_path'].to_s.include?('/subagents/')
  end

  def data_dir
    dir = ENV['KAIROS_DATA_DIR'].to_s
    dir = File.join(ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd, '.kairos') if dir.empty?
    raise Unreadable, 'no KairosChain data directory' unless File.directory?(File.join(dir, 'context'))

    dir
  end

  def config(path = ENV['COMPACTION_HANDOFF_CONFIG'] || CONFIG_FILE)
    raw = YAML.safe_load(File.read(path))
    c = raw.is_a?(Hash) ? raw['compaction_handoff'] : nil
    raise Unreadable, 'config has no compaction_handoff section' unless c.is_a?(Hash)

    at = c['compact_at_tokens']
    ratio = c['request_ratio']
    tag = c['l2_tag'].to_s
    raise Unreadable, 'compact_at_tokens must be an integer of at least 10000' unless at.is_a?(Integer) && at >= 10_000
    raise Unreadable, 'request_ratio must be above 0 and below 1' unless ratio.is_a?(Numeric) && ratio.positive? && ratio < 1
    raise Unreadable, 'l2_tag must be lower-case letters, digits and underscores' unless TAG_FORMAT.match?(tag)

    { compact_at_tokens: at, request_ratio: ratio.to_f, tag: tag,
      request_point: (at * ratio.to_f).floor }
  rescue SystemCallError, Psych::Exception => e
    raise Unreadable, "config unreadable (#{e.class})"
  end

  # --- state (per session, the hooks' own; not data to commit) --------------

  def state_path(dir, sid)
    File.join(dir, 'storage', 'compaction_handoff', 'sessions', "#{sid}.json")
  end

  def fresh_state
    { 'cycle' => 1, 'cycle_started_at' => now, 'cycle_offset' => 0, 'first_request_at' => nil,
      'blocked' => false, 'urgent' => false, 'last_usage' => nil, 'saved_at' => nil }
  end

  def load_state(dir, sid)
    path = state_path(dir, sid)
    return fresh_state unless File.exist?(path)

    s = JSON.parse(File.read(path))
    raise Unreadable, 'state is not an object' unless s.is_a?(Hash) && s['cycle'].is_a?(Integer)

    fresh_state.merge(s)
  rescue JSON::ParserError, SystemCallError => e
    raise Unreadable, "state unreadable (#{e.class})"
  end

  # Written by rename, so a reader never sees half a file. Returns true only
  # once the state is on disk (INV-2 blocks only after that).
  def save_state(dir, sid, state)
    path = state_path(dir, sid)
    FileUtils.mkdir_p(File.dirname(path))
    tmp = "#{path}.#{Process.pid}.tmp"
    File.open(tmp, 'w') do |f|
      f.write(JSON.generate(state))
      f.flush
      f.fsync
    end
    File.rename(tmp, path)
    true
  rescue SystemCallError, IOError
    false
  end

  # Ends the cycle: nothing it accumulated counts in the next (INV-7).
  def new_cycle!(state, offset:, reason:)
    state['cycle'] += 1
    state['cycle_started_at'] = now
    state['cycle_offset'] = offset.to_i
    state['first_request_at'] = nil
    state['blocked'] = false
    state['urgent'] = false
    state['last_usage'] = nil
    state['saved_at'] = nil
    state['cycle_reason'] = reason
    state
  end

  # Records the usage figure; a sharp fall ends the cycle at that response.
  def observe_usage!(state, usage)
    return state unless usage

    prev = state['last_usage']
    if prev.is_a?(Integer) && usage[:tokens] < prev * DROP_RATIO
      new_cycle!(state, offset: usage[:offset], reason: 'usage_fell')
    end
    state['last_usage'] = usage[:tokens]
    state
  end

  def now
    Time.now.utc.iso8601
  end

  # --- L2, through KairosChain's own interface (INV-9) ----------------------

  def l2(dir)
    require 'kairos_mcp'
    KairosMcp.data_dir = dir
    require 'kairos_mcp/context_manager'
    KairosMcp::ContextManager.new
  end

  def handoff_prefix(tag, sid)
    "#{tag}_#{sid[0, 8]}_"
  end

  def fallback_prefix(tag, sid)
    "#{tag}_fallback_#{sid[0, 8]}_"
  end

  # [session_dir_name, name, written_at] of entries whose name starts with
  # `prefix`, newest first. Names are found by listing; content is read only
  # through the interface.
  def entries(dir, prefix)
    Dir.glob(File.join(dir, 'context', '*', "#{prefix}*")).filter_map do |path|
      next unless File.directory?(path)

      # The entry's own file is rewritten on every save; the directory is not.
      md = File.join(path, "#{File.basename(path)}.md")
      [File.basename(File.dirname(path)), File.basename(path), File.mtime(File.exist?(md) ? md : path).utc]
    end.sort_by { |e| e[2] }.reverse
  end

  # This session's handoffs: name prefix plus the full id in the frontmatter.
  # Entries with the prefix but not the id are returned as near misses, so the
  # request can say why a save was not counted.
  def handoffs(manager, dir, tag, sid)
    found = []
    near = []
    entries(dir, handoff_prefix(tag, sid)).each do |session, name, at|
      next if name.start_with?(fallback_prefix(tag, sid))

      skill = manager.get_context(session, name)
      fm = skill&.frontmatter || {}
      if fm[FRONTMATTER_KEY].to_s == sid
        found << { session: session, name: name, written_at: at }
      else
        near << { session: session, name: name, written_at: at }
      end
    end
    [found, near]
  end

  def fallbacks(manager, dir, tag, sid)
    entries(dir, fallback_prefix(tag, sid)).map do |session, name, at|
      { session: session, name: name, written_at: at }
    end
  end

  # A handoff written in this cycle at or after its first request (§3).
  def fresh?(handoff, state)
    return false unless handoff && state['first_request_at']

    handoff[:written_at] >= Time.iso8601(state['first_request_at'])
  end

  def emit(event, text)
    $stdout.write(JSON.generate({ hookSpecificOutput: { hookEventName: event, additionalContext: text } }) + "\n")
    $stdout.flush
  end

  def guide_name
    'compaction_handoff_guide'
  end
end
