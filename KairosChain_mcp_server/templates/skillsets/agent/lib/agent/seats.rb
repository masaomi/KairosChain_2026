# frozen_string_literal: true

require 'json'
require 'time'
require 'digest'
require 'fileutils'

module KairosMcp
  module SkillSets
    module Agent
      # Persona seats of a review round (log/agent_persona_seats_design_v0.3_20261022.md).
      #
      # A seat is a host subagent the actor launches with a one-line marker.
      # The PreToolUse hook replaces the marker with a short prompt naming the
      # seat's stored prompt file and journals the launch; from then on the
      # subagent is a seat for its whole life, recognised by the host's meta
      # file naming that launch (toolUseId). A seat reads only its prompt, and
      # its reply reaches the journal only from hook inputs, never through the
      # actor (INV-2, INV-3).
      #
      # Everything here is read from the journal, run storage and the host's
      # own files, so the MCP server and the hook processes agree without
      # sharing memory.
      module Seats
        # Three personas per review type, from L1 multi_llm_review_workflow
        # § Orchestrator Delegation Protocol. Constants of the SkillSet: how
        # the work is judged is set neither by the actor nor at run time.
        PERSONAS = {
          'design' => [
            ['architect', 'whether the structure holds what the artifact claims, end to end, and fits what already exists'],
            ['security', 'whether anyone can author, alter, bypass or forge what the artifact protects, and what a mistake exposes'],
            ['operability', 'what happens in real use: failures, interruptions, deadlines, cost, migration and how a reader finds out']
          ],
          'implementation' => [
            ['correctness', 'whether the code does what its design and tests claim, including edge cases, error paths and concurrency'],
            ['performance', 'cost in time, memory, I/O and external calls, and what grows with input or with use'],
            ['api-design', 'interfaces, names, contracts and compatibility with the code and records that already exist']
          ],
          'document' => [
            ['ontologist', 'whether the concepts are defined once and used consistently, and whether claims follow from them'],
            ['skeptic', 'claims without evidence, numbers without denominators, and what a hostile reader would refute'],
            ['integration', 'whether the document agrees with the code, the other documents and the decisions it relies on']
          ]
        }.freeze
        MARKER_PREFIX = 'agent-run review seat'
        # The token's life when seats are convened, and how long before its
        # end a round is collected whatever the seats do.
        DEADLINE_SECONDS = 3600
        CUTOFF_SECONDS = 600
        # One agent_advance call waits at most this long in total.
        WAIT_SECONDS = 540
        POLL_SECONDS = 5
        # A launch with no host meta file this long after it never started.
        START_GRACE_SECONDS = 120
        # A seat may be launched again once after a launch that ended unanswered.
        MAX_LAUNCHES = 2
        # Stop-hook blocks a held round gets with no agent_advance between them.
        HOLD_BLOCKS = 3
        HANDBACK = 'SubagentHandback'
        LAUNCH_TOOLS = %w[Agent Task].freeze
        TARGET_TOOLS = %w[SendMessage TaskStop].freeze
        TARGET_KEYS = %w[to task_id shell_id agent_id id].freeze
        EFFORTS = %w[low medium high xhigh max].freeze
        SAFE_ID = /\A[A-Za-z0-9_.\-]{1,128}\z/
        VERDICTS = %w[APPROVE REVISE REJECT].freeze
        MLR_LIB = File.expand_path('../../../multi_llm_review/lib/multi_llm_review', __dir__)
        MLR_CONFIG = File.expand_path('../../../multi_llm_review/config/multi_llm_review.yml', __dir__)
        HANDBACK_CLAUSE = <<~TEXT.strip
          ## Your hand-back

          You are one persona seat of a review. Answer from this prompt alone: every file you need is inlined above,
          and your tools are refused except reading this prompt and the hand-back. Your final report — the hand-back,
          or your final message where there is no hand-back tool — is your review, and it must begin with the
          `**Overall Verdict**:` line, with nothing before it. Then list each finding on its own line as the output
          contract above says, and classify each as (a), (b) or (c) where the review frame asks for it.
        TEXT

        module_function

        def personas(type)
          PERSONAS.fetch(type.to_s, PERSONAS['design'])
        end

        def marker(run_id, token, persona)
          "#{MARKER_PREFIX} #{run_id} #{token.to_s[0, 8]} #{persona}"
        end

        def now
          Time.now
        end

        # --- composition (MCP server) -------------------------------------------

        def mlr
          unless defined?(KairosMcp::SkillSets::MultiLlmReview::BuildReviewBundle) &&
                 defined?(KairosMcp::SkillSets::MultiLlmReview::Consensus)
            require File.join(MLR_LIB, 'build_review_bundle')
            require File.join(MLR_LIB, 'consensus')
          end
          require File.join(MLR_LIB, 'persona_assembly') unless defined?(KairosMcp::SkillSets::MultiLlmReview::PersonaAssembly)
          KairosMcp::SkillSets::MultiLlmReview
        end

        def review_context
          require 'yaml'
          ctx = (YAML.safe_load(File.read(MLR_CONFIG)) || {})['default_review_context'] if File.file?(MLR_CONFIG)
          %w[independent project_aware].include?(ctx) ? ctx : 'independent'
        rescue StandardError
          'independent'
        end

        # One full prompt per persona: its header, MLR's canonical prompt for
        # the same bundle (what the subprocess seats read, under the same
        # output contract), and the hand-back clause.
        def compose(review_type:, artifact_name:, bundle:, round:, prior: nil, worktree: nil, branch: nil)
          canon = mlr::BuildReviewBundle.build_canonical_prompts(
            artifact_content: bundle, artifact_name: artifact_name, review_type: review_type.to_s,
            review_context: review_context, review_round: round, prior_findings: prior
          )
          personas(review_type).map do |name, focus|
            header = "# Persona seat: #{name}\n\nYou are the #{name} persona of a review team. Your focus: #{focus}. " \
                     'Review the whole artifact; weigh your focus first.'
            if worktree && review_type.to_s == 'implementation'
              header += "\n\nContext only: the work lives on branch #{branch} in #{worktree}. You cannot open it; the " \
                        'diff and the files below are what you review.'
            end
            text = [header, canon[:system_prompt], canon[:user_message], HANDBACK_CLAUSE].join("\n\n---\n\n")
            { 'persona' => name, 'prompt' => text, 'sha256' => Digest::SHA256.hexdigest(text) }
          end
        end

        def seats_dir(run)
          File.join(run.dir, 'reviews', 'seats')
        end

        def prompt_path(run, sha)
          File.join(seats_dir(run), "#{sha}.md")
        end

        # Stores each full prompt under its digest; returns the seats without
        # their text.
        def store_prompts(run, seats)
          FileUtils.mkdir_p(seats_dir(run))
          seats.map do |s|
            path = prompt_path(run, s['sha256'])
            File.write(path, s['prompt']) unless File.file?(path) && Digest::SHA256.file(path).hexdigest == s['sha256']
            s.reject { |k, _| k == 'prompt' }
          end
        end

        # What the seat's launch carries in place of the marker: the stored
        # prompt's place and digest, which the seat reads itself.
        READ_CHUNK_LINES = 400

        def short_prompt(run, seat, dispatch)
          path = prompt_path(run, seat['sha256'])
          lines = File.file?(path) ? File.foreach(path).count : 0
          "# Persona seat: #{seat['persona']} (agent run #{run.id}, review #{dispatch['phase']} round #{dispatch['round']})\n\n" \
            "Your full review prompt is the file below (#{lines} lines). Read it whole with the Read tool, " \
            "#{READ_CHUNK_LINES} lines at a time (offset and limit), and follow it. It is the only file you may read; " \
            "every other tool is refused to you except the hand-back.\n\nFile: #{path}\nSHA-256: #{seat['sha256']}\n"
        end

        # --- reading the journal -------------------------------------------------

        def dispatches_with_seats(entries)
          entries.select { |e| e['kind'] == 'review_dispatched' && e['seats'].is_a?(Array) && !e['seats'].empty? }
        end

        def collected?(entries, token)
          entries.any? { |e| %w[review_round review_dispatch_failed].include?(e['kind']) && e['token'] == token }
        end

        # The dispatch's seats were closed: by its collect, which goes on to
        # submit them, or by a run that stopped before it collected.
        def closed?(entries, token)
          entries.any? { |e| e['kind'] == 'seats_closed' && e['token'] == token }
        end

        # Dispatches whose seats can still be launched or settled.
        def live_dispatches(entries)
          dispatches_with_seats(entries).reject { |d| collected?(entries, d['token']) || closed?(entries, d['token']) }
        end

        # Live dispatches still before their cutoff: the only ones a seat may
        # be launched for, since from the cutoff on the round collects
        # whatever the seats do.
        def launchable_dispatches(entries, at = now)
          live_dispatches(entries).select { |d| at < cutoff_of(d) }
        end

        def dispatch_for(entries, token)
          dispatches_with_seats(entries).reverse.find { |d| d['token'] == token }
        end

        def launches(entries)
          entries.select { |e| e['kind'] == 'seat_launched' }
        end

        def any_launch?(entries)
          entries.any? { |e| e['kind'] == 'seat_launched' }
        end

        def settlements(entries)
          entries.select { |e| e['kind'] == 'seat_settled' }
        end

        def launch_for(entries, tool_use_id)
          return nil if tool_use_id.to_s.empty?

          launches(entries).find { |l| l['tool_use_id'] == tool_use_id }
        end

        def settlement_for(entries, launch)
          settlements(entries).find { |s| s['tool_use_id'] == launch['tool_use_id'] }
        end

        def unsettled_launches(entries)
          settled = settlements(entries).map { |s| s['tool_use_id'] }.to_h { |id| [id, true] }
          launches(entries).reject { |l| settled[l['tool_use_id']] }
        end

        # Each declared seat of a dispatch with where it stands: answered,
        # running, ended (every launch ended unanswered), or not_launched.
        def seat_states(entries, dispatch)
          by_launch = settlements(entries).to_h { |s| [s['tool_use_id'], s] }
          first_answer = by_launch.values.select { |s| s['token'] == dispatch['token'] && s['answered'] }.map { |s| s['seq'] }.min
          mine = launches(entries).select { |l| l['token'] == dispatch['token'] }
          Array(dispatch['seats']).map do |seat|
            own = mine.select { |l| l['persona'] == seat['persona'] }
            settled = own.filter_map { |l| by_launch[l['tool_use_id']] }
            answered = settled.find { |s| s['answered'] }
            running = own.reject { |l| by_launch[l['tool_use_id']] }
            state = if answered then 'answered'
                    elsif running.any? then 'running'
                    elsif own.any? then 'ended'
                    else 'not_launched'
                    end
            late = !own.empty? && first_answer && own.first['seq'] > first_answer
            seat.merge('state' => state, 'launches' => own.size, 'answer' => answered, 'late' => late ? true : false,
                       'last_cause' => settled.reject { |s| s['answered'] }.last&.dig('cause'))
          end
        end

        # Seats the actor should launch now: never launched, or ended
        # unanswered with a launch left.
        def to_launch(states)
          states.select { |s| s['state'] == 'not_launched' || (s['state'] == 'ended' && s['launches'] < MAX_LAUNCHES) }
        end

        def live_markers(run_id, entries, at = now)
          launchable_dispatches(entries, at).flat_map do |d|
            Array(d['seats']).map do |s|
              [marker(run_id, d['token'], s['persona']),
               s.merge('token' => d['token'], 'phase' => d['phase'], 'round' => d['round'])]
            end
          end.to_h
        end

        # Why a marker of one of the run's dispatches can no longer launch,
        # or nil when the text is no marker of the run.
        def spent_reason(run_id, entries, text)
          d = dispatches_with_seats(entries).reverse.find do |x|
            Array(x['seats']).any? { |s| marker(run_id, x['token'], s['persona']) == text }
          end
          return nil unless d

          token = d['token']
          advance = "agent_advance(run_id: '#{run_id}')"
          if entries.any? { |e| e['kind'] == 'review_dispatch_failed' && e['token'] == token }
            return "its round's dispatch failed; #{advance} dispatches the round anew, with new markers"
          end
          return 'its round has already collected' if collected?(entries, token)
          return 'its round has closed its seats (the round is collecting, or the run stopped)' if closed?(entries, token)

          "its round is past its cutoff; #{advance} collects it without further seats"
        end

        # Why a seat may not be launched now, or nil.
        def launch_refusal(entries, seat)
          d = dispatch_for(entries, seat['token'])
          st = d && seat_states(entries, d).find { |s| s['persona'] == seat['persona'] }
          return 'its round has no such seat' unless st
          return "seat #{seat['persona']} has a launch still running" if st['state'] == 'running'
          return "seat #{seat['persona']} has already answered" if st['state'] == 'answered'
          return "seat #{seat['persona']} has had its #{MAX_LAUNCHES} launches" if st['launches'] >= MAX_LAUNCHES

          nil
        end

        # The next step for a review phase whose dispatch has seats, or nil.
        def instruction(run, phase, at = now)
          entries = run.journal.entries
          d = launchable_dispatches(entries, at).reverse.find { |x| x['phase'] == phase }
          return nil unless d

          states = seat_states(entries, d)
          launch = to_launch(states)
          running = states.select { |s| s['state'] == 'running' }
          advance = "agent_advance(run_id: '#{run.id}', phase: '#{phase}')"
          unless launch.empty?
            return "Phase #{phase}: review round #{d['round']} is out to the external seats. Launch its persona " \
                   "seats now — in ONE message, one Agent call per line below, subagent_type general-purpose, the " \
                   'prompt exactly the line and nothing else (the hook replaces it with the seat\'s prompt):' + "\n" +
                   launch.map { |s| marker(run.id, d['token'], s['persona']) }.join("\n") +
                   "\nThen call #{advance}; it waits for the seats. Do not message or stop the seats, and do not " \
                   'relay their replies: the hooks record them.'
          end
          return nil if running.empty?

          "Phase #{phase}: #{running.size} persona seat(s) of review round #{d['round']} are reviewing. Call " \
            "#{advance}; it waits for them (up to 9 minutes per call) and collects the round."
        end

        # A dispatch with seats that has not collected and whose token has not
        # expired: the Stop hook keeps the actor calling agent_advance, which
        # waits for the seats and, from the cutoff on, collects.
        def holding_dispatch(entries, at = now)
          live_dispatches(entries).find { |d| at < expiry_of(d) }
        end

        # The token's end: must_collect_by, or the dispatch time plus the
        # deadline the dispatch asked for when the review tool gave none.
        def expiry_of(dispatch)
          by = dispatch['must_collect_by']
          return Time.parse(by.to_s) if by

          Time.parse(dispatch['at'].to_s) + DEADLINE_SECONDS
        rescue ArgumentError, TypeError
          Time.at(0)
        end

        def cutoff_of(dispatch)
          expiry_of(dispatch) - CUTOFF_SECONDS
        end

        # --- the host's files --------------------------------------------------

        # The meta and transcript files of a subagent: next to
        # agent_transcript_path at SubagentStop, else under the session's
        # transcript directory.
        def host_files(input, agent_id = input['agent_id'])
          return nil unless SAFE_ID.match?(agent_id.to_s)

          own = input['agent_transcript_path'].to_s
          base = if !own.empty? && agent_id == input['agent_id']
                   own.sub(/\.jsonl\z/, '')
                 else
                   dir = subagents_dir(input)
                   return nil unless dir

                   direct = File.join(dir, "agent-#{agent_id}")
                   if File.file?("#{direct}.meta.json")
                     direct
                   else
                     Dir.glob(File.join(dir, '**', "agent-#{agent_id}.meta.json")).first&.delete_suffix('.meta.json') || direct
                   end
                 end
          { 'meta' => "#{base}.meta.json", 'transcript' => "#{base}.jsonl" }
        end

        def subagents_dir(input)
          tp = input['transcript_path'].to_s
          sid = input['session_id'].to_s
          return nil if tp.empty? || !SAFE_ID.match?(sid)

          File.join(File.dirname(tp), sid, 'subagents')
        end

        def read_meta(path)
          return nil unless path && File.file?(path)

          m = JSON.parse(File.read(path))
          m.is_a?(Hash) ? m : nil
        rescue JSON::ParserError, SystemCallError
          nil
        end

        # The launch (tool_use id) the host recorded for a subagent; nil when
        # the meta file cannot be read or names no launch.
        def launch_id(files)
          id = read_meta(files && files['meta'])&.dig('toolUseId')
          id.is_a?(String) && !id.empty? ? id : nil
        end

        # SHA-256 of the first user record of a subagent's transcript: the
        # prompt it was given.
        def first_prompt_sha256(files)
          return nil unless files && File.file?(files['transcript'])

          File.foreach(files['transcript'], encoding: 'UTF-8') do |line|
            d = JSON.parse(line) rescue next
            next unless d['type'] == 'user'

            c = d.dig('message', 'content')
            text = c.is_a?(Array) ? c.select { |b| b.is_a?(Hash) && b['type'] == 'text' }.map { |b| b['text'] }.join : c
            return text.is_a?(String) ? Digest::SHA256.hexdigest(text) : nil
          end
          nil
        rescue SystemCallError
          nil
        end

        # What a subagent is to the run: [:seat, launch], [:other, nil], or
        # [:unknown, nil] when its launch cannot be read.
        def identify(entries, input, agent_id = input['agent_id'])
          id = launch_id(host_files(input, agent_id))
          return [:unknown, nil] unless id

          launch = launch_for(entries, id)
          launch ? [:seat, launch] : [:other, nil]
        end

        # The meta file a launch produced, found by its toolUseId.
        def meta_of_launch(launch)
          dir = launch['subagents_dir'].to_s
          return nil if dir.empty? || !File.directory?(dir)

          Dir.glob(File.join(dir, 'agent-*.meta.json')).each do |f|
            m = read_meta(f)
            return [f, m] if m && m['toolUseId'] == launch['tool_use_id']
          end
          nil
        end

        # --- replies and settlement ------------------------------------------------

        def handback_path(run, agent_id)
          File.join(seats_dir(run), "handback_#{agent_id}.txt")
        end

        def keep_handback(run, agent_id, message)
          return unless SAFE_ID.match?(agent_id.to_s) && message.is_a?(String) && !message.strip.empty?

          path = handback_path(run, agent_id)
          FileUtils.mkdir_p(File.dirname(path))
          tmp = "#{path}.#{Process.pid}.tmp"
          File.write(tmp, message)
          File.rename(tmp, path)
        end

        def kept_handback(run, agent_id)
          return nil unless SAFE_ID.match?(agent_id.to_s)

          path = handback_path(run, agent_id)
          File.file?(path) ? File.read(path) : nil
        end

        # Freezes a reply: written once and whole (a crash leaves no partial
        # file under the name), named by the launch, digest journaled.
        def freeze_reply(run, launch, text)
          path = File.join(seats_dir(run), "reply_#{launch['tool_use_id'].to_s.gsub(/[^A-Za-z0-9_\-]/, '_')}.txt")
          FileUtils.mkdir_p(File.dirname(path))
          unless File.file?(path)
            tmp = "#{path}.#{Process.pid}.tmp"
            File.write(tmp, text)
            File.rename(tmp, path)
          end
          path
        end

        # Settles a launch once, under the run's seat lock.
        def settle(run, launch, agent_id:, reply:, cause: nil)
          locked(run) { settle_held(run, launch, agent_id: agent_id, reply: reply, cause: cause) }
        end

        # settle, for a caller already holding the seat lock (flock is per
        # open file, so taking it again in the same process would wait on
        # itself).
        def settle_held(run, launch, agent_id:, reply:, cause: nil)
          entries = run.journal.entries
          return nil if settlement_for(entries, launch)

          text = reply.to_s
          answered = cause.nil? && !text.strip.empty?
          cause ||= 'no_reply' unless answered
          data = { token: launch['token'], persona: launch['persona'], phase: launch['phase'], round: launch['round'],
                   tool_use_id: launch['tool_use_id'], agent_id: agent_id, answered: answered }
          if answered
            file = freeze_reply(run, launch, text)
            data.merge!(reply_file: file, reply_sha256: Digest::SHA256.file(file).hexdigest)
          else
            data[:cause] = cause
          end
          run.append(:seat_settled, data)
        end

        # The settled reply, only while its file still holds the settled bytes.
        def settled_reply(settlement)
          f = settlement['reply_file'].to_s
          return nil unless File.file?(f)

          text = File.read(f)
          Digest::SHA256.hexdigest(text) == settlement['reply_sha256'] ? text : nil
        end

        # A finished meta file is left to the seat's own SubagentStop (which
        # sees last_assistant_message) for this long.
        STOP_GRACE_SECONDS = 60

        # Launches the host never stopped, settled from what the host's files
        # show: no meta file after the grace (not_started), a finished meta
        # with no stop seen, or a session no longer bound to the run.
        def settle_orphans(run, at = now)
          entries = run.journal.entries
          unsettled_launches(entries).each do |l|
            launched_at = Time.parse(l['at'].to_s) rescue at
            if l['session_id'] && run.bound_session && l['session_id'] != run.bound_session
              settle(run, l, agent_id: nil, reply: nil, cause: 'session_ended')
              next
            end
            found = meta_of_launch(l)
            if found.nil?
              settle(run, l, agent_id: nil, reply: nil, cause: 'not_started') if at - launched_at >= START_GRACE_SECONDS
              next
            end
            next unless found[1]['finished'] == true
            next if at - (File.mtime(found[0]) rescue at) < STOP_GRACE_SECONDS

            agent = File.basename(found[0], '.meta.json').delete_prefix('agent-')
            kept = kept_handback(run, agent)
            files = { 'meta' => found[0], 'transcript' => found[0].delete_suffix('.meta.json') + '.jsonl' }
            cause = if first_prompt_sha256(files) != l['prompt_sha256'] then 'prompt_mismatch'
                    elsif kept.nil? then 'no_reply'
                    end
            settle(run, l, agent_id: agent, reply: kept, cause: cause)
          end
        end

        # At collect, or when the run stops first: closes the dispatch's seats
        # and settles not_settled the launches still unsettled, in one hold of
        # the lock that admits launches. No launch is admitted after the
        # close, so none outlives the round, and nothing keeps the run's seat
        # refusals on after it.
        def settle_remaining(run, token)
          locked(run) do
            entries = run.journal.entries
            unsettled_launches(entries).select { |l| l['token'] == token }.each do |l|
              settle_held(run, l, agent_id: nil, reply: nil, cause: 'not_settled')
            end
            unless closed?(entries, token)
              d = dispatch_for(entries, token)
              run.append(:seats_closed, token: token, phase: d&.dig('phase'), round: d&.dig('round'))
            end
          end
        end

        def locked(run)
          FileUtils.mkdir_p(seats_dir(run))
          File.open(File.join(seats_dir(run), 'seats.lock'), File::RDWR | File::CREAT, 0o600) do |f|
            f.flock(File::LOCK_EX)
            yield
          end
        end

        # The verdict MLR reads from a reply: start-anchored, never inferred.
        def verdict(text)
          v = mlr::Consensus.extract_verdict({ status: :success, raw_text: text.to_s.sub(/\A\s+/, '') })[:verdict]
          VERDICTS.include?(v) ? v : nil
        end

        # The finding lines of a reply, as the review tool's own extraction
        # reads them (the scan in Consensus.aggregate_findings; a test checks
        # the two stay the same).
        FINDING_LINE = /\*{0,2}(P[0-3])\*{0,2}[-\s]*\d*[.:]\s*(.+?)(?=\n\s*\n|\n\s*\*{0,2}P[0-3]|\z)/mi

        # One finding per line the seat wrote, each built by the review tool's
        # own rule, so a finding's severity and consequence come from the same
        # line. (Its merged rows can take them from different lines, which
        # once let a P0 without a consequence borrow another finding's.) The
        # review tool merges the submitted findings itself when it reads them.
        def findings(text, _verdict = nil)
          limit = mlr::PersonaAssembly::MAX_ISSUE_LENGTH
          found = text.to_s.scan(FINDING_LINE).map do |sev, issue|
            f = mlr::Consensus.build_finding(sev, issue, 'seat')
            { 'severity' => f[:severity_stated] || f[:severity],
              'issue' => keep_consequence(f[:issue].to_s, f[:consequence], limit) }
          end
          # Most severe first, in the seat's order within a severity: the
          # review tool reads only a persona's first findings
          # (PersonaAssembly::MAX_FINDINGS_PER_PERSONA).
          found.each_with_index.sort_by { |f, i| [f['severity'], i] }.map(&:first)
        end

        # The review tool cuts a persona finding at `limit` characters before
        # it reads the finding again, and a consequence clause cut away reads
        # as none stated, which records a P0 as P2. An issue whose cut keeps
        # its stated clause and every stated location clause is kept as
        # written. Any other issue with a consequence is rebuilt: a body
        # shortened to fit (the shortening marked only where it cut), then the
        # clause, then the first stated location the body would lose. A
        # location the kept front still holds stays where it is, so the front
        # the review tool groups findings by does not move.
        def keep_consequence(issue, consequence, limit)
          return issue if consequence.nil?

          head = issue.each_char.first(limit).join
          lost = locations(issue).any? { |m| m.end(0) > head.length }
          return issue if states_consequence?(head) && !lost

          clause = "[consequence: #{bounded(consequence, limit / 2)}]"
          body = issue.gsub(mlr::Consensus::CONSEQUENCE_RE, ' ').gsub(/\s+/, ' ').strip
          carried = locations(body).find { |m| m.end(0) > limit - clause.length - 5 }
          tail = clause
          if carried
            tail = "#{clause} [location: #{bounded(carried[1], limit / 8)}]"
            body = "#{body[0...carried.begin(0)]} #{body[carried.end(0)..]}".gsub(/\s+/, ' ').strip
          end
          room = [limit - tail.length - 5, 0].max
          kept = body[0, room].rstrip
          kept = "#{kept} ...".lstrip if body.length > room
          kept.empty? ? tail : "#{kept} #{tail}"
        end

        LOCATION_RE = /\[\s*location:\s*([^\]]*)\]/i

        # The stated (non-empty) location clauses of a text, as match data.
        def locations(text)
          text.enum_for(:scan, LOCATION_RE).map { Regexp.last_match }.reject { |m| m[1].strip.empty? }
        end

        def states_consequence?(text)
          text.scan(mlr::Consensus::CONSEQUENCE_RE).any? { |c| !c[0].strip.empty? }
        end

        # Whitespace folded and cut to `max` characters, the cut marked.
        def bounded(text, max)
          t = text.to_s.gsub(/\s+/, ' ').strip
          t.length > max ? "#{t[0, max - 3]}..." : t
        end
      end
    end
  end
end
