# frozen_string_literal: true

# model_provenance hook entry point (design v0.3). One script, three events:
#
#   PostModelSwitch  record the switch; on an automatic one, tell the model (INV-5)
#   SubagentStop     observe the subagent's latest run and record it (INV-7's source)
#   Stop             read every finished response not yet reported, in the main
#                    transcript and every subagent transcript, and tell the
#                    operator what has not been shown before (INV-6)
#
# It never blocks, halts, prolongs or alters a turn (INV-4): it prints nothing,
# a plain-text context line (PostModelSwitch only), or a `systemMessage`. On any
# failure it prints nothing to stdout, writes the cause to stderr and exits 1,
# which Claude Code shows as a non-blocking hook error.
#
# Stop commits nothing until the whole report is composed, and commits it in
# one step: every transcript's cursor, the shown causes and the session's
# "announced" flag live in one state file replaced by a single rename, so a
# failure at any point leaves either all of it or none of it (INV-4, "no
# partial success"). A failure confined to one transcript becomes that
# transcript's "not observed" line instead.

require 'json'
require 'fileutils'
require 'timeout'
require_relative 'transcript_reader'
require_relative '../lib/model_provenance/observation_store'

module ModelProvenanceHook
  class Unplaceable < StandardError; end

  class Observer
    Store = KairosMcp::SkillSets::ModelProvenance::ObservationStore
    Reader = TranscriptReader
    PREFIX = '[model_provenance]'
    # Well inside the hook timeout declared in plugin/hooks.json (20 s). The
    # budget is checked between transcripts; HARD_LIMIT interrupts a single
    # read that stalls, so the hook fails visibly before Claude Code kills it.
    BUDGET_SECONDS = 8.0
    HARD_LIMIT_SECONDS = 15
    POLL_ATTEMPTS = 15
    POLL_DELAY = 0.1

    def initialize(input, env: ENV, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @input = input
      @env = env
      @clock = clock
      @started = clock.call
      @state = nil
      @state_note = nil
    end

    # Returns [stdout_text_or_nil, exit_status].
    def run
      project_dir = @env['CLAUDE_PROJECT_DIR'].to_s
      if project_dir.empty?
        # INV-2: silence only for input positively identified as another host's.
        return [nil, 0] if @env.keys.any? { |k| k.start_with?('CODEX') }

        raise Unplaceable, 'CLAUDE_PROJECT_DIR is not set, so this is not recognisably a Claude Code hook call'
      end
      @data_dir = @env['KAIROS_DATA_DIR'].to_s.empty? ? File.join(project_dir, '.kairos') : @env['KAIROS_DATA_DIR']
      @session_id = @input['session_id'].to_s
      raise Unplaceable, 'hook input has no session_id' if @session_id.empty?

      case @input['hook_event_name']
      when 'PostModelSwitch' then post_model_switch
      when 'SubagentStop' then subagent_stop
      when 'Stop' then stop
      else raise Unplaceable, "unexpected hook_event_name #{@input['hook_event_name'].inspect}"
      end
    end

    private

    def elapsed
      @clock.call - @started
    end

    def now_iso
      Time.now.utc.iso8601(3)
    end

    # --- PostModelSwitch ------------------------------------------------------

    def post_model_switch
      from = @input['from_model'].to_s
      to = @input['to_model'].to_s
      source = @input['source'].to_s
      auto = source == 'auto'
      Store.append(@data_dir, @session_id, 'switch', 'session',
                   'at' => now_iso, 'source' => source, 'from_model' => from, 'to_model' => to,
                   'told_model' => auto, 'host' => 'claude_code', 'layer' => 'claude_code_hook')
      return [nil, 0] unless auto

      # INV-5. `source: "auto"` covers a fallback or another change Claude Code
      # made on its own (U8), so the statement says what changed, not why.
      [
        "#{PREFIX} Claude Code changed this session's model automatically, from #{from} to #{to}. " \
        "You are now #{to}. When you say which model you are, say #{to}.",
        0
      ]
    end

    # --- SubagentStop ---------------------------------------------------------

    def subagent_stop
      agent_id = @input['agent_id'].to_s
      path = @input['agent_transcript_path'].to_s
      raise Unplaceable, 'SubagentStop input has no agent_id or agent_transcript_path' if agent_id.empty? || path.empty?
      # Claude Code's own internal agents (prompt suggestions, /btw) stop with
      # an empty agent_type and keep no transcript: nothing to observe.
      return [nil, 0] if @input['agent_type'].to_s.empty?
      raise Unplaceable, "agent_id #{agent_id.inspect} is not a safe identifier" unless Store::SAFE.match?(agent_id)

      unless File.file?(path)
        Store.append(@data_dir, @session_id, 'observation', "agent_#{agent_id}",
                     base_record(agent_id).merge('state' => 'unobserved',
                                                 'cause' => 'subagent transcript absent at SubagentStop',
                                                 'detected_by' => 'claude_code:subagent_stop'))
        return [nil, 0]
      end

      read, complete = read_until_final(path, :subagent, @input['last_assistant_message'])
      Store.append(@data_dir, @session_id, 'observation', "agent_#{agent_id}",
                   run_observation(agent_id, read, complete, 'claude_code:subagent_stop'))
      [nil, 0]
    end

    # --- Stop -----------------------------------------------------------------

    def stop
      path = @input['transcript_path'].to_s
      raise Unplaceable, 'Stop input has no transcript_path' if path.empty?

      lines = []
      load_state
      lines << @state_note if @state_note
      first = !@state['announced']
      if first
        lines << "#{PREFIX} active: from here on, a line appears only when a response in this " \
                 'session was answered by a model other than expected, or could not be checked.'
      end

      # PostModelSwitch reports the main session's model changes only, so they
      # explain changes in the main transcript and nowhere else.
      switches = Store.records(@data_dir, @session_id, 'switch', 'session')
                      .reject { |r| r['_unreadable'] }
                      .map { |r| { 'at' => r['at'], 'source' => r['source'], 'to' => r['to_model'] } }
      lines.concat(observe('main', path, :main, 'main session',
                           final_text: @input['last_assistant_message'], switches: switches))

      tasks = Array(@input['background_tasks']).select { |t| t.is_a?(Hash) }
      running = tasks.map { |t| t['id'].to_s }
      sub_root = File.join(File.dirname(path), File.basename(path, '.jsonl'), 'subagents')
      seen = []
      skipped = 0
      backstops = []
      # Recursive: workflow agents keep their transcripts under subagents/workflows/.
      Dir.glob(File.join(sub_root, '**', 'agent-*.jsonl')).sort.each do |sub_path|
        agent_id = File.basename(sub_path, '.jsonl').delete_prefix('agent-')
        seen << agent_id
        label = agent_label(File.dirname(sub_path), agent_id)
        unless Store::SAFE.match?(agent_id)
          lines.concat(cause_line('main', label, "unsafe_agent_id:#{File.basename(sub_path).scrub('?')}",
                                  'agent id is not a safe identifier'))
          next
        end
        if elapsed > BUDGET_SECONDS
          skipped += 1
          next
        end
        key = "agent_#{agent_id}"
        if running.include?(agent_id)
          lines.concat(pending(key, label))
        else
          grew = File.size?(sub_path).to_i != load_cursor(key)['offset']
          lines.concat(observe(key, sub_path, :subagent, label))
          # A full read only when something is new or no complete record exists.
          complete = Store.records(@data_dir, @session_id, 'observation', key)
                          .any? { |r| Store.current?(r) && r['complete'] == true }
          backstops << [agent_id, sub_path] if grew || !complete
        end
      end
      # A subagent the harness reports as running may not have written its
      # transcript yet; it is still pending, and says so.
      tasks.each do |t|
        id = t['id'].to_s
        next unless t['type'] == 'subagent' || t.key?('agent_type')
        next if seen.include?(id) || !Store::SAFE.match?(id)

        lines.concat(pending("agent_#{id}", "subagent \"#{t['description'].to_s[0, 60]}\""))
      end
      if skipped.positive?
        lines << "#{PREFIX} #{skipped} subagent transcript(s) not read this turn (time budget); " \
                 'they will be read at the next turn.'
      end

      # Everything decided. Compose the output first (it can fail on odd text),
      # then add the backstop records (append-only; a repeat is harmless), then
      # commit all state in one rename. Only after that is the output returned.
      output = lines.empty? ? nil : JSON.generate('systemMessage' => lines.map { |l| l.to_s.scrub('?') }.join("\n"))
      backstops.each { |agent_id, sub_path| backstop_record(agent_id, sub_path) }
      @state['announced'] = true
      commit_state
      if first
        begin
          Store.append(@data_dir, @session_id, 'live', 'session',
                       'at' => now_iso, 'host' => 'claude_code', 'layer' => 'claude_code_hook')
        rescue StandardError
          nil # an audit trace only; the announced flag above is what gates the line
        end
      end
      [output, 0]
    end

    # Read what is new in one transcript and return the operator lines owed.
    # The cursor update is staged, not written (see #commit_state).
    def observe(key, path, scope, label, final_text: nil, switches: [])
      cursor = load_cursor(key)
      size = File.size(path)
      return [] if size == cursor['offset'] && cursor['pending_shown'].nil?

      after = !cursor.dig('state', 'last_model').nil?
      read, complete = if scope == :main
                         read_until_final(path, scope, final_text, from: cursor['offset'], after_response: after)
                       else
                         [Reader.read(path, from: cursor['offset'], scope: scope, after_response: after), true]
                       end
      events = read[:events]
      new_offset = read[:end_offset]
      if !complete && read[:tail_offset]
        # The final response is not in the file yet (flush lag): leave it, and
        # everything after where it began, for the next turn to read.
        events = events.select { |_k, _p, off| off < read[:tail_offset] }
        new_offset = read[:tail_offset]
      end
      result = Reader.classify(events, state: cursor['state'] || {}, switches: switches)
      out = result[:anomalies].map { |a| anomaly_line(label, a, result[:responses]) }
      stage_cursor(key, 'offset' => new_offset, 'state' => result[:state], 'pending_shown' => nil)
      if read[:unparsable].positive?
        out.concat(cause_line(key, label, 'unparsable_lines',
                              "#{read[:unparsable]} unreadable transcript line(s) skipped"))
      end
      out
    rescue StandardError => e
      # One transcript's failure is that transcript's non-observation. Its
      # cursor is not moved, so nothing in it is marked read.
      @state['cursors'][key] = cursor if cursor
      cause_line(key, label, "read_failed_#{e.class}", "transcript could not be read (#{e.class})")
    end

    def anomaly_line(label, anomaly, responses)
      why = case anomaly[:kind]
            when 'fallback' then "automatic fallback from #{anomaly[:from]}"
            when 'automatic' then "changed automatically by Claude Code from #{anomaly[:from]}"
            else "changed from #{anomaly[:from]} with no recorded cause"
            end
      "#{PREFIX} #{label}: #{anomaly[:responses]}/#{responses} new response(s) answered by " \
        "#{anomaly[:to]} (#{why})."
    end

    # Shown once per kind of cause per transcript; the text may carry a count,
    # the key does not.
    def cause_line(key, label, kind, text)
      cursor = load_cursor(key)
      shown = Array(cursor['shown_causes'])
      return [] if shown.include?(kind)

      stage_cursor(key, 'shown_causes' => shown + [kind])
      ["#{PREFIX} #{label}: not observed — #{text}."]
    end

    def pending(key, label)
      return [] if load_cursor(key)['pending_shown']

      stage_cursor(key, 'pending_shown' => now_iso)
      ["#{PREFIX} #{label}: still running, not yet observed."]
    end

    # INV-6: every subagent transcript is observed after it stops, whether or
    # not its own stop hook produced a record. When no complete record covers
    # its latest run, the Stop hook writes one, so a binding can still resolve.
    def backstop_record(agent_id, path)
      read = Reader.read(path, scope: :subagent)
      run = latest_run(read[:events])[:run]
      existing = Store.records(@data_dir, @session_id, 'observation', "agent_#{agent_id}")
                      .select { |r| Store.current?(r) }
      return if existing.any? { |r| r['run'].to_i == run && r['complete'] == true }

      Store.append(@data_dir, @session_id, 'observation', "agent_#{agent_id}",
                   run_observation(agent_id, read, true, 'claude_code:stop_backstop'))
    rescue StandardError => e
      warn("model_provenance: backstop record for #{agent_id} failed: #{e.class}")
    end

    # --- shared ---------------------------------------------------------------

    # Read a transcript; when the hook input names the final text, wait
    # (bounded) for it to be written, and say whether it was.
    def read_until_final(path, scope, final_text, from: 0, after_response: false)
      want = normalize(final_text)
      read = nil
      POLL_ATTEMPTS.times do |i|
        read = Reader.read(path, from: from, scope: scope, after_response: after_response)
        return [read, true] if want.empty?

        last = read[:events].reverse.find { |k, _p, _o| k == :response }
        return [read, true] if last && final_matches?(normalize(last[1].text), want)
        break if i == POLL_ATTEMPTS - 1 || elapsed > BUDGET_SECONDS

        sleep(POLL_DELAY)
      end
      [read, false]
    end

    def normalize(text)
      text.to_s.gsub(/\s+/, ' ').strip
    end

    # The whole response's text must end with the final text the hook was
    # given. A prefix written so far does not: accepting one would let the
    # rest of the same response be read later as a second response.
    def final_matches?(have, want)
      !have.empty? && have.end_with?(want)
    end

    def latest_run(events)
      index = events.rindex { |k, _p, _o| k == :run_start }
      run = 1 + events.count { |k, _p, _o| k == :run_start }
      { run: run, events: index ? events[(index + 1)..] : events }
    end

    def run_observation(agent_id, read, complete, detected_by)
      latest = latest_run(read[:events])
      result = Reader.classify(latest[:events])
      base_record(agent_id).merge(
        'state' => 'observed', 'run' => latest[:run], 'models' => result[:models],
        'responses' => result[:responses],
        'anomalies' => result[:anomalies].map { |a| a.transform_keys(&:to_s) },
        'complete' => complete, 'unreadable_lines' => read[:unparsable],
        'extent' => { 'end_offset' => read[:end_offset],
                      'last_request_id' => result[:last_response]&.request_id },
        'detected_by' => detected_by
      )
    end

    def base_record(agent_id)
      { 'schema' => Store::SCHEMA, 'at' => now_iso, 'scope' => 'subagent', 'agent_id' => agent_id,
        'agent_type' => @input['agent_type'], 'session_id' => @session_id,
        'host' => 'claude_code', 'layer' => 'claude_code_hook' }
    end

    def agent_label(dir, agent_id)
      meta = JSON.parse(File.read(File.join(dir, "agent-#{agent_id}.meta.json")))
      desc = meta['description'].to_s.scrub('?')[0, 60]
      desc.empty? ? "subagent #{agent_id}" : "subagent \"#{desc}\""
    rescue StandardError
      "subagent #{agent_id}"
    end

    # The observer's working state, not a record: every transcript's cursor and
    # the announced flag in one file, replaced whole by a single rename. Stop
    # runs for one session one at a time, so there is no concurrent writer.
    def state_path
      File.join(Store.session_dir(@data_dir, @session_id), 'observer_state.json')
    end

    # An unreadable state file is not a reason to stop observing forever: the
    # observer starts again from the beginning and says once that earlier
    # lines may be shown again.
    def load_state
      @state = JSON.parse(File.read(state_path))
      raise JSON::ParserError, 'not an object' unless @state.is_a?(Hash) && @state['cursors'].is_a?(Hash)
    rescue Errno::ENOENT
      @state = { 'cursors' => {} }
    rescue JSON::ParserError, EncodingError, SystemCallError => e
      @state = { 'cursors' => {}, 'announced' => true }
      @state_note = "#{PREFIX} observer state was unreadable (#{e.class}); every transcript is read " \
                    'again from the start, so earlier lines may repeat.'
    end

    def load_cursor(key)
      @state['cursors'][key] || { 'offset' => 0, 'state' => {} }
    end

    def stage_cursor(key, changes)
      @state['cursors'][key] = load_cursor(key).merge(changes)
    end

    def commit_state
      path = state_path
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.generate(@state))
      File.rename(tmp, path)
    end
  end

  def self.main(stdin = $stdin, stdout = $stdout, stderr = $stderr, env: ENV)
    input = JSON.parse(stdin.read)
    raise Unplaceable, 'hook input is not a JSON object' unless input.is_a?(Hash)

    out, status = Timeout.timeout(Observer::HARD_LIMIT_SECONDS) { Observer.new(input, env: env).run }
    stdout.print(out) if out
    status
  rescue StandardError => e
    stderr.puts("model_provenance: #{e.class}: #{e.message}"[0, 500])
    1
  end
end

exit(ModelProvenanceHook.main) if $PROGRAM_NAME == __FILE__
