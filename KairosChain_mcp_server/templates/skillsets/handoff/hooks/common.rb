# frozen_string_literal: true

require 'json'
require 'yaml'
require 'time'
require 'date'
require 'digest'
require 'fileutils'

# Shared parts of the session-end hook and the record script.
# Claude Code layer: this file knows the hook input and the transcript rows.
# It lives in hooks/, outside lib/, so nothing on the KairosChain side reaches
# it by name. The transcript format is internal to Claude Code and changes
# between versions; every reader here returns nil when a row is not in the
# shape it knows, and the callers write their block without that part.
#
# Text: everything read here (stdin, files, environment) is taken as UTF-8
# whatever the locale says, and made valid before anything looks at it.
module HandoffHook
  SESSION_ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  L2_NAME = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,200}\z/
  DEFAULT_END_REASONS = %w[prompt_input_exit clear resume logout].freeze
  # A title written as a command: letters and digits of any script, then also
  # _ . - / and space. Nothing a shell reads, and no leading dash, which
  # `claude --resume` would take as an option.
  PLAIN_TITLE = %r{\A[\p{L}\p{N}_][\p{L}\p{N}_.\-/ ]*\z}
  # Whatever a reader of the log file may take as the end of a line.
  LINE_BREAK = /\r\n?|[\n\v\f\u0085\u2028\u2029]/
  CONTROL = /[\p{Cc}\p{Cf}\u2028\u2029]/
  # Who wrote a user row. Its `origin` says so when it has one: `human` is the
  # operator (also when the text starts with a tag, as a paste does), anything
  # else is another writer (a plugin, a task notification). A row without an
  # `origin` is the operator's unless it is the mark Claude Code leaves for an
  # interrupted turn or starts with a tag, with or without attributes (the
  # output of a local command, a shell line run with `!`); a slash command
  # starts with a tag too and is kept, by its name.
  HUMAN = 'human'
  INTERRUPTED = /\A\[Request interrupted by user[^\]\n]*\]\z/
  HOST_TAG = %r{\A\s*<([A-Za-z][A-Za-z0-9_-]*)(?=[\s/>])}
  COMMAND_TAGS = %w[command-name command-message].freeze
  COMMAND_NAME = %r{<command-name>([^<]+)</command-name>}
  COMMAND_ARGS = %r{<command-args>(.*?)</command-args>}m
  SYNTHETIC_MODEL = '<synthetic>'
  KEPT_ENDS = 20
  PRIORITY_KEYS = %w[importance urgency].freeze
  PRIORITY_RANGE = (1..5).freeze

  class Unreadable < StandardError; end

  Config = Struct.new(:log_file, :last_turn, :last_turn_max_lines, :end_reasons, keyword_init: true)

  module_function

  # --- text -----------------------------------------------------------------

  def utf8(value)
    value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
  end

  # A parsed JSON value with every string made valid (an escaped lone surrogate
  # parses to a string that is not).
  def clean(value)
    case value
    when String then value.scrub
    when Array then value.map { |v| clean(v) }
    when Hash then value.to_h { |k, v| [clean(k), clean(v)] }
    else value
    end
  end

  # --- inputs ---------------------------------------------------------------

  def read_input(io = $stdin)
    input = clean(JSON.parse(utf8(io.binmode.read)))
    raise Unreadable, 'hook input is not a JSON object' unless input.is_a?(Hash)

    path = input['transcript_path']
    raise Unreadable, 'hook input carries a transcript path that is not a path' unless path.nil? || (path.is_a?(String) && !path.include?("\0"))

    input
  rescue JSON::ParserError
    raise Unreadable, 'hook input is not JSON'
  end

  def session_id(input)
    sid = input['session_id']
    raise Unreadable, 'hook input carries no well-formed session id' unless sid.is_a?(String) && SESSION_ID.match?(sid)

    sid
  end

  def subagent?(input)
    input['transcript_path'].to_s.include?('/subagents/')
  end

  def config_file
    named = utf8(ENV['HANDOFF_CONFIG'])
    named.empty? ? File.join(skillset_dir, 'config', 'handoff.yml') : named
  end

  def config(path = config_file)
    raw = YAML.safe_load(File.read(path, encoding: 'UTF-8').scrub)
    c = raw.is_a?(Hash) ? raw['handoff'] : nil
    raise Unreadable, "#{path} has no handoff section" unless c.is_a?(Hash)

    max = c.fetch('last_turn_max_lines', 200)
    raise Unreadable, 'last_turn_max_lines must be an integer of at least 1' unless max.is_a?(Integer) && max >= 1

    reasons = c.fetch('end_reasons', DEFAULT_END_REASONS)
    unless reasons.is_a?(Array) && reasons.all? { |r| r.is_a?(String) && !r.empty? }
      raise Unreadable, 'end_reasons must be a list of names'
    end

    log_file = c['log_file']
    raise Unreadable, 'log_file must be a path in quotes or empty' unless log_file.nil? || log_file.is_a?(String)

    last_turn = c.fetch('last_turn', true)
    raise Unreadable, 'last_turn must be true or false' unless [true, false].include?(last_turn)

    Config.new(log_file: log_file.to_s.strip, last_turn: last_turn, last_turn_max_lines: max, end_reasons: reasons)
  rescue Errno::ENOENT
    raise Unreadable, "no config at #{path}"
  rescue Psych::Exception => e
    raise Unreadable, "config is not readable YAML: #{e.message}"
  end

  def skillset_dir
    utf8(File.expand_path('..', __dir__))
  end

  # The data directory this copy of the SkillSet is installed in, unless the
  # caller names another one.
  def data_dir
    named = utf8(ENV['KAIROS_DATA_DIR'])
    named.empty? ? File.expand_path('../..', skillset_dir) : named
  end

  # nil when the instance has named no log file. A relative path is read from
  # the directory that holds the data directory, for the hook and the record
  # script alike: it is the one place both can find without the host's help.
  def log_path(cfg)
    return nil if cfg.log_file.empty?

    # The home directory comes from the environment in the locale's encoding;
    # it is put in as UTF-8 here so that the rest of the path can be any text.
    named = cfg.log_file.sub(%r{\A~(?=/|\z)}) { utf8(Dir.home) }
    File.expand_path(named, File.dirname(File.expand_path(data_dir)))
  rescue ArgumentError, EncodingError => e
    raise Unreadable, "log_file is not a usable path: #{e.message}"
  end

  # --- state: which handoffs a Claude Code session saved, which ends were logged

  def state_dir
    File.join(data_dir, 'storage', 'handoff')
  end

  def state_path(sid)
    raise Unreadable, 'not a session id' unless SESSION_ID.match?(sid.to_s)

    File.join(state_dir, "#{sid}.json")
  end

  # Reads the session's state, yields it, and puts the new state in place of
  # the old in one step (a file under another name, then a rename), all under
  # one lock for the directory. An interrupted run leaves the old state whole,
  # and so does a block that raises. Both writers append to the log inside
  # this block, so neither sees the other between its log line and its state.
  def with_state(sid)
    path = state_path(sid)
    FileUtils.mkdir_p(state_dir)
    File.open(File.join(state_dir, '.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      state = parse_state(File.file?(path) ? File.read(path, encoding: 'UTF-8') : '')
      result = yield state
      temp = "#{path}.#{Process.pid}.tmp"
      File.write(temp, JSON.pretty_generate(state), perm: 0o600)
      File.rename(temp, path)
      result
    end
  end

  def parse_state(raw)
    state = clean(JSON.parse(utf8(raw)))
    state = {} unless state.is_a?(Hash)
    %w[handoffs ends].each { |key| state[key] = Array(state[key]).grep(Hash) }
    state
  rescue JSON::ParserError
    { 'handoffs' => [], 'ends' => [] }
  end

  # --- the saved handoff ----------------------------------------------------

  def frontmatter(file)
    text = File.read(file, encoding: 'UTF-8').scrub
    return {} unless text.start_with?('---')

    block = text.split(/^---\s*$/, 3)[1]
    data = YAML.safe_load(block.to_s, permitted_classes: [Date, Time])
    data.is_a?(Hash) ? data : {}
  rescue Psych::Exception, SystemCallError
    {}
  end

  # The session's own estimate, read from the handoff it saved: importance and
  # urgency, each 1 (low) to 5 (high). A value that is absent or out of range
  # is left out, not replaced by a middle one.
  def priority(file)
    fm = frontmatter(file)
    PRIORITY_KEYS.each_with_object({}) { |key, out| out[key] = fm[key] if rating?(fm[key]) }
  end

  def rating?(value)
    value.is_a?(Integer) && PRIORITY_RANGE.cover?(value)
  end

  def priority_text(entry)
    parts = PRIORITY_KEYS.filter_map { |k| "#{k} #{entry[k]}/5" if rating?(entry[k]) }
    parts.empty? ? nil : "#{parts.join(', ')} (the session's estimate)"
  end

  # --- transcript -----------------------------------------------------------

  def find_transcript(sid)
    root = utf8(ENV['CLAUDE_CONFIG_DIR'])
    root = File.join(utf8(Dir.home), '.claude') if root.empty?
    projects = File.join(root, 'projects')
    found = Dir.glob(File.join('*', "#{sid}.jsonl"), base: projects).map { |rel| File.join(projects, rel) }
    found.select { |p| File.file?(p) }.max_by { |p| File.mtime(p) }
  end

  def read_rows(path)
    return [] if path.to_s.empty? || !File.file?(path)

    File.foreach(path, encoding: 'UTF-8').filter_map do |line|
      row = JSON.parse(line)
      clean(row) if row.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end
  end

  # The newest name of the session (--name and /rename both write such a row).
  def title(rows)
    row = rows.reverse_each.find { |r| r['type'] == 'custom-title' && r['customTitle'].is_a?(String) && !r['customTitle'].strip.empty? }
    row && row['customTitle'].strip
  end

  def message(row)
    row['message'].is_a?(Hash) ? row['message'] : {}
  end

  def text_blocks(content)
    content.filter_map { |b| b['text'] if b.is_a?(Hash) && b['type'] == 'text' && b['text'].is_a?(String) }.join("\n")
  end

  # What the operator typed, or nil when the row is not a prompt.
  def prompt_text(row)
    return nil unless row['type'] == 'user' && !row['isMeta'] && !row['isCompactSummary']

    writer = row['origin'].is_a?(Hash) ? row['origin']['kind'] : row['origin']
    return nil unless writer.nil? || writer == HUMAN

    content = message(row)['content']
    text = case content
           when String then content
           when Array
             return nil if content.any? { |b| b.is_a?(Hash) && b['type'] == 'tool_result' }

             text_blocks(content)
           end
    return nil if text.to_s.strip.empty? || INTERRUPTED.match?(text.strip)

    tag = text[HOST_TAG, 1]
    return text.strip if writer == HUMAN || !tag
    return nil unless COMMAND_TAGS.include?(tag) && (name = text[COMMAND_NAME, 1])

    [name.strip, text[COMMAND_ARGS, 1].to_s.strip].reject(&:empty?).join(' ')
  end

  # An answer of the model. A row Claude Code wrote in the model's place (an
  # API error, the placeholder for a turn that asked for no answer) is not one.
  def reply_text(row)
    return nil unless row['type'] == 'assistant' && !row['isApiErrorMessage']
    return nil if message(row)['model'] == SYNTHETIC_MODEL

    content = message(row)['content']
    return nil unless content.is_a?(Array)

    text = text_blocks(content).strip
    text.empty? ? nil : text
  end

  # The last prompt that was answered, the final reply to it, and the mark that
  # tells one session end from the next: the id of the row the reply sits in,
  # or, for a row without one, a digest of the reply.
  def last_turn(rows)
    main = rows.reject { |r| r['isSidechain'] }
    reply_at = main.rindex { |r| reply_text(r) }
    return { prompt: nil, reply: nil, recap: nil, mark: nil } unless reply_at

    reply = reply_text(main[reply_at])
    uuid = main[reply_at]['uuid']
    prompt_at = main[0...reply_at].rindex { |r| prompt_text(r) }
    recap = main[reply_at..].reverse_each.find do |r|
      r['type'] == 'system' && r['subtype'] == 'away_summary' && r['content'].is_a?(String)
    end
    { prompt: prompt_at && prompt_text(main[prompt_at]), reply: reply, recap: recap && recap['content'].strip,
      mark: uuid.is_a?(String) && !uuid.empty? ? uuid : "sha256:#{Digest::SHA256.hexdigest(reply)}" }
  end

  # --- blocks ---------------------------------------------------------------

  # The only way text reaches the log file as notes: every line gets the comment
  # mark, and no character is left in it that a reader could take as a line end
  # or act on (CONTROL covers every character LINE_BREAK names).
  def comment(lines)
    lines.map do |l|
      l = utf8(l).gsub(CONTROL, ' ').rstrip
      l.empty? ? '#' : "# #{l}"
    end
  end

  def led(mark, text)
    lines = text.to_s.split(LINE_BREAK, -1)
    lines.each_with_index.map { |l, i| i.zero? ? "#{mark} #{l}" : (l.strip.empty? ? '' : "  #{l}") }
  end

  def last_turn_lines(turn, max)
    lines = []
    lines.concat(led('❯', turn[:prompt])).push('') if turn[:prompt]
    lines.concat(led('⏺', turn[:reply]))
    lines.push('', "※ recap: #{turn[:recap].split(LINE_BREAK).map(&:strip).join(' ')}") unless turn[:recap].to_s.empty?
    return lines if lines.size <= max

    ["(the first #{lines.size - max} lines of the last turn are left out)"] + lines.last(max)
  end

  # live: the last line is a command, not a comment. A command line has one of
  # two shapes only: the session id, or a plain title in double quotes. A title
  # that is not plain is not written at all; the id resumes the same session.
  def resume_lines(sid, title, live:)
    raise Unreadable, 'not a session id' unless SESSION_ID.match?(sid.to_s)

    lead = live ? '' : '# '
    return ["#{lead}claude --resume #{sid}"] unless title.is_a?(String) && PLAIN_TITLE.match?(title)

    ["# claude --resume #{sid}", %(#{lead}claude --resume "#{title}")]
  end

  def handoff_line(entry)
    [["L2 handoff: #{entry['name']} (#{entry['l2_session']})", "saved #{entry['at']}"].join(', '),
     priority_line(entry)].compact
  end

  def priority_line(entry)
    text = priority_text(entry)
    text && "priority: #{text}"
  end

  def handoff_block(entry, sid, title, now: Time.now)
    lines = ["[handoff] #{stamp(now)}", "L2 handoff: #{entry['name']} (#{entry['l2_session']})",
             priority_line(entry)].compact
    resume = sid ? resume_lines(sid, title, live: false) : ['# (Claude Code session id unknown: no resume command)']
    comment(lines) + resume
  end

  def session_end_block(sid:, title:, reason:, turn:, handoffs:, cfg:, now: Time.now)
    head = ["[session end] #{stamp(now)} (#{reason})"]
    body = cfg.last_turn ? last_turn_lines(turn, cfg.last_turn_max_lines) + [''] : []
    saved = handoffs.empty? ? ['L2 handoff: none saved in this session'] : handoffs.flat_map { |h| handoff_line(h) }
    comment(head + body + saved + ['Resume this session with:']) + resume_lines(sid, title, live: true)
  end

  def stamp(time)
    time.strftime('%Y-%m-%d %H:%M')
  end

  # One empty line, then the block. The empty line is the only line this
  # SkillSet writes that neither starts with the comment mark nor is a resume
  # command.
  def append(path, lines)
    raise Unreadable, "the log file's directory does not exist: #{File.dirname(path)}" unless File.directory?(File.dirname(path))

    File.open(path, 'a:UTF-8') do |f|
      f.flock(File::LOCK_EX)
      f.write("\n#{lines.join("\n")}\n")
    end
  end
end
