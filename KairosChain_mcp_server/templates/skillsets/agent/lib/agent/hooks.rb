# frozen_string_literal: true

require 'json'
require 'digest'
require 'open3'
require 'fileutils'
require_relative 'run'
require_relative 'guard'
require_relative 'stand_in'
require_relative 'precedents'
require_relative 'policies'
require_relative 'transcript'

module KairosMcp
  module SkillSets
    module Agent
      # What the run asks of the host next, in words the host acts on.
      module Guidance
        KIT_DIR = File.expand_path('../../report_kit', __dir__)

        module_function

        def next_step(run)
          return report_step(run) if run.current_phase.nil? || %w[ended finished].include?(run.status)

          plan = run.plan
          phase = plan.phase(run.current_phase)
          id = run.id
          case phase.kind
          when :produce
            "Phase #{phase.name}: write the document matching #{phase.args[:glob]} in the main checkout " \
              "(#{run.target_repo}) as a new file — each version is a new file. Then call " \
              "agent_advance(run_id: '#{id}', phase: '#{phase.name}')."
          when :review
            answer = plan.phase(phase.args[:of])&.kind == :produce ? 'writing the next version as a new file' : 'new commits on the run branch'
            "Phase #{phase.name}: call agent_advance(run_id: '#{id}', phase: '#{phase.name}'). It dispatches the next " \
              "review round of the latest #{phase.args[:of]} artifact and, on the next call, returns the seats' findings " \
              "as labelled by the stand-in. Answer open (a)/(b) P0s by #{answer} — by deletion, correction or naming, " \
              'not by adding mechanism — then call agent_advance again. The review closes when no P0 is open.'
          when :check
            checked = if phase.args[:tests]
                        "The test set under #{phase.args[:tests]} is pinned from the base commit; changing a pinned test " \
                          'goes to the stand-in. The SkillSet re-runs the tests on the committed state.'
                      elsif phase.args[:command]
                        "The SkillSet runs `#{phase.args[:command]}` on the committed state from the worktree root."
                      else
                        'The SkillSet checks that the work is committed.'
                      end
            "Phase #{phase.name}: work in the worktree #{run.worktree} (branch #{run.branch}) and commit there. " \
              'Each Bash call runs confined and starts afresh: use absolute paths, or cd within the same call. ' \
              "#{checked} When your commits are ready, call agent_advance(run_id: '#{id}', phase: '#{phase.name}')."
          end
        end

        def report_step(run)
          return 'The run has ended; its report is built.' if run.report

          dir = File.join(run.target_repo.to_s, 'log', 'agent_runs', run.id)
          "#{run.status == 'ended' ? "The run has ended (#{run.end_reason})." : 'All phases ended.'} Build the report " \
            'with a subagent (Agent tool, not a fork). The subagent: (1) calls ' \
            "agent_status(run_id: '#{run.id}', report_material: true), which writes #{dir}/material.json; " \
            "(2) runs `python3 #{KIT_DIR}/make_report_deck.py #{dir}/material.json #{dir}/deck.html`; (3) may " \
            "rewrite the main slides' wording in Japanese, keeping every id; (4) runs `python3 #{KIT_DIR}/check.py " \
            "#{dir}/deck.html` until issues=0. Then call agent_finish(run_id: '#{run.id}'); it checks the deck again " \
            'itself.'
        end

        def summary(run)
          items = run.open_items.map { |i| "#{i['id']}: #{i['text']}" }
          lines = ["Agent run #{run.id} (#{run.status}) — goal: #{run.goal}",
                   (run.worktree ? "Worktree: #{run.worktree} (branch #{run.branch}). " : '') + "Main checkout: #{run.target_repo}.",
                   'The line: inside = files this run created, its worktree and branch. Outside (refused, queued for the ' \
                   'operator) = governing material (L0/L1, instruction mode, policy, precedent store, journal, hook settings, ' \
                   'installed SkillSet code), shared files, and anything that discloses, publishes, sends or commits the operator.',
                   "Next: #{next_step(run)}"]
          lines << "Open operator items: #{items.join('; ')}" unless items.empty?
          lines.join("\n")
        end
      end

      # The host hook dispatcher (design v0.5.1 §4). Inert unless the session
      # is bound to a run, except for the guard-seen marker, the binding on
      # agent_start, and capture of the operator's adopting words.
      class Hooks
        QUESTION_END = /(\?|\uFF1F|ますか。?|でしょうか。?|しますか。?|ですか。?|どちらにしますか.?)\s*\z/
        HAZARD_WORDS = Regexp.union(
          /api[_\s]?key|secret|credential|private\s+key|password|秘密鍵|鍵(が|を)(漏|流出|公開)|漏洩|\bleak/i,
          /chain\s+(is\s+)?corrupt|チェーン.{0,8}(破損|壊)/i,
          /data\s+loss|データ.{0,6}(消失|失われ)/i,
          /wrong\s+output\s+(was\s+)?published|誤った.{0,10}公開/i
        )

        AGENT_TOOL = /\Amcp__(.+)__agent_(start|status|advance|items|finish|stop)\z/

        # Only KairosChain's own agent tools (a server whose name says
        # kairos), never another server's agent_*.
        def self.agent_tool?(tool, name = nil)
          m = AGENT_TOOL.match(tool.to_s)
          m && m[1].match?(/kairos/i) && (name.nil? || m[2] == name) ? true : false
        end

        # The SkillSet's own tools learn which session calls them (INV-6: only
        # the bound session advances, finishes or stops a run) and which
        # project the session works in.
        def self.with_session(input)
          extra = { '_session_id' => input['session_id'], '_project_dir' => ENV['CLAUDE_PROJECT_DIR'] || input['cwd'] }.compact
          { 'hookSpecificOutput' => { 'hookEventName' => 'PreToolUse', 'permissionDecision' => 'allow',
                                      'updatedInput' => (input['tool_input'] || {}).merge(extra) } }
        end

        # settings_deny: the operator's Bash deny and ask rules as regexps;
        # settings_rules: their other deny and ask rules (see Guard).
        def initialize(paths:, project_root:, stand_in_factory:, settings_deny: [], settings_rules: [])
          @paths = paths
          @project_root = project_root
          @stand_in_factory = stand_in_factory
          @settings_deny = settings_deny
          @settings_rules = settings_rules
        end

        def handle(event, input)
          case event
          when 'PreToolUse' then pre_tool_use(input)
          when 'PostToolUse' then post_tool_use(input)
          when 'UserPromptSubmit' then user_prompt_submit(input)
          when 'Stop' then stop(input, subagent: false)
          when 'SubagentStop' then stop(input, subagent: true)
          when 'SessionStart' then session_start(input)
          when 'SessionEnd' then session_end(input)
          end
        end

        # --- PreToolUse -------------------------------------------------------

        def pre_tool_use(input)
          sid = input['session_id']
          touch_guard_seen(sid)
          tool = input['tool_name'].to_s
          if Hooks.agent_tool?(tool)
            # The operator's words after an ending release the guard before the
            # agent tool runs (agent_start right after them is not refused).
            held = Run.bound_to(@paths, sid)
            release_if_typed(held, sid) if held
            clear_taken_over_if_typed(sid) if Run.taken_over?(@paths, sid)
            return Hooks.with_session(input)
          end
          return taken_over(tool) if Run.taken_over?(@paths, sid) && !clear_taken_over_if_typed(sid)

          run = Run.bound_to(@paths, sid)
          return nil unless run
          return nil if release_if_typed(run, sid)

          policy = policy_for(run)
          unless policy
            return deny("the policy pinned by run #{run.id} changed or is missing; the guard cannot decide. " \
                        "Restore it, or call agent_stop(run_id: '#{run.id}').")
          end

          guard = Guard.new(run: run, paths: @paths, policy: policy, project_root: run.target_repo || @project_root,
                            deny_patterns: @settings_deny, settings_rules: @settings_rules)

          v = guard.decide(tool, input['tool_input'], cwd: input['cwd'] || @project_root)
          ti = input['tool_input'] || {}
          meta = { 'tool' => tool, 'tool_use_id' => input['tool_use_id'], 'agent_id' => input['agent_id'],
                   'path' => ti['file_path'] || ti['notebook_path'] }.compact
          case v.kind
          when :allow
            run.append(:effect, meta.merge('verdict' => 'allowed', 'reason' => v.reason)) unless %w[read-only session-local].include?(v.reason)
            run.append(:created, path: v.created) if v.created
            allow
          when :rewrite
            run.append(:effect, meta.merge('verdict' => 'confined', 'command' => input.dig('tool_input', 'command')))
            allow(updated_input: v.updated_input)
          when :refuse
            # The same refusal again is the same item, not a new one.
            item = run.open_items.find do |i|
              i['item_kind'] == 'refused_effect' && i['text'] == v.reason && i['command'] == v.item&.dig('command')
            end
            item ||= run.open_item('refused_effect', v.reason, command: v.item&.dig('command'))
            keep_change(run, item, v.item&.dig('change'))
            run.append(:effect, meta.merge('verdict' => 'refused', 'reason' => v.reason, 'item' => item['id']))
            deny("Refused by agent run #{run.id}: #{v.reason}. Queued as operator item #{item['id']}. " \
                 'Continue with work that does not depend on it.')
          when :decision_point
            decision_point(run, policy, v, input)
          end
        rescue StandardError, ScriptError => e
          # Fail closed inside a bound session (INV-2): a guard that cannot decide refuses.
          deny("agent guard error (#{e.class}): #{e.message[0, 200]}")
        end

        # --- PostToolUse ------------------------------------------------------

        def post_tool_use(input)
          sid = input['session_id']
          tool = input['tool_name'].to_s
          return bind_from_start(input) if Hooks.agent_tool?(tool, 'start')
          # The SkillSet's own tools journal what they do themselves.
          return nil if Hooks.agent_tool?(tool)

          run = Run.bound_to(@paths, sid)
          return nil unless run
          return nil if Guard::READ_ONLY_TOOLS.include?(tool)

          resp = input['tool_response']
          failed = resp.is_a?(Hash) && (resp['is_error'] || resp['error'])
          # The report's bytes as they stand after each effect: whoever changed
          # them last is known however the change was made (a redirect after
          # cd, a copy, the kit's generator).
          deck = File.join(run.target_repo.to_s, 'log', 'agent_runs', run.id, 'deck.html')
          run.append(:effect_outcome, { 'tool' => tool, 'tool_use_id' => input['tool_use_id'],
                                        'agent_id' => input['agent_id'], 'ok' => !failed,
                                        'path' => input.dig('tool_input', 'file_path'),
                                        'deck_sha256' => File.file?(deck) ? Digest::SHA256.file(deck).hexdigest : nil }.compact)
          nil
        end

        def bind_from_start(input)
          payload = parse_tool_response(input['tool_response'])
          run_id = payload && payload['run_id']
          return nil unless run_id && payload['bind']

          run = Run.load(@paths, run_id)
          return nil unless run

          sid = input['session_id']
          # The service bound the session; this attaches the transcript and the
          # words typed before. It never takes a run over.
          return nil unless run.bound_session == sid

          words = Transcript.typed_entries(input['transcript_path']).last(20).map { |e| e['text'] }
          run.attach(sid, transcript_path: input['transcript_path'], prestart_words: words)
          context('PostToolUse', "Run #{run.id} is bound to this session.\n#{Guidance.summary(run.reload)}")
        rescue ArgumentError => e
          context('PostToolUse', "Run #{run_id} could not bind: #{e.message}. The run does not advance until a " \
                                 'session whose guard is live binds it (agent_start with resume).')
        end

        # --- UserPromptSubmit ---------------------------------------------------

        def user_prompt_submit(input)
          sid = input['session_id']
          prompt = input['prompt'].to_s
          # Hand-backs, notifications, peer messages and slash commands arrive
          # as prompts too; none is the operator's typing (INV-5). What is
          # kept here is still verified against the transcript before use.
          # A slash command's arguments are the operator's words ("/agent 設計から
          #収束まで"); a bare command, a hand-back or a notification is not.
          text = Transcript.operator_text(prompt)
          return nil unless text

          # A run another session took over no longer holds this session once
          # the operator speaks here; like a release, that waits for the
          # transcript to show the prompt as typed.
          note_taken_over_words(sid, input) if Run.taken_over?(@paths, sid)
          record_operator_reference(input, text)
          run = Run.bound_to(@paths, sid)
          return nil unless run

          run.append(:operator_words, text: text, prompt_id: input['prompt_id'], session_id: sid,
                                      transcript_path: input['transcript_path'])
          # After any ending the guard and journal stay until the operator's
          # next typed words (design §8). A scheduled or host prompt is not
          # those words, so the release waits until the transcript shows this
          # prompt as typed (checked at the next hook event). Words that name
          # this run's own items or decisions continue the run's business (a
          # decision, a correction) and do not release it.
          if %w[ended finished].include?(run.status) && !names_run_ref?(run, text)
            run.append(:release_pending, prompt_id: input['prompt_id'], text: text, transcript_path: input['transcript_path'])
          end
          nil
        end

        # The operator's own words (pasted output set aside) naming this run's
        # items or decisions; the merge item is the operator's own act outside
        # the run, so naming it releases like any other words.
        def names_run_ref?(run, text)
          own = Precedents.strip_pasted(text)
          ids = run.items.values.reject { |i| i['item_kind'] == 'merge' }.map { |i| i['id'] } + run.decisions.map { |d| d['id'] }
          ids.any? { |id| own.match?(/(?<![A-Za-z0-9])#{Regexp.escape(id)}(?![0-9])/) }
        end

        def taken_over_pending_path(sid)
          File.join(@paths.bindings_dir, "#{Run.safe(sid)}.pending")
        end

        def note_taken_over_words(sid, input)
          File.write(taken_over_pending_path(sid),
                     JSON.generate('prompt_id' => input['prompt_id'], 'text' => Transcript.operator_text(input['prompt'].to_s),
                                   'transcript_path' => input['transcript_path']))
        rescue SystemCallError
          nil
        end

        # The taken-over marker clears once the transcript shows the operator
        # typed in this session; a scheduled prompt leaves it. True if cleared.
        def clear_taken_over_if_typed(sid)
          f = taken_over_pending_path(sid)
          return false unless File.exist?(f)

          pend = JSON.parse(File.read(f))
          case typed_in_transcript(pend)
          when true
            File.delete(f)
            Run.clear_taken_over(@paths, sid)
            true
          when false
            File.delete(f)
            false
          else
            false
          end
        rescue JSON::ParserError, SystemCallError
          false
        end

        # Releases an ended run's guard once the pending prompt shows in the
        # transcript as the operator's typing; cancels the release if it shows
        # as anything else. True when released.
        def release_if_typed(run, sid)
          return false unless %w[ended finished].include?(run.status)

          # Only words typed after the latest ending release it; a pending
          # release left before a reopen does not carry to the next ending.
          entries = run.journal.entries
          ended_at = entries.reverse.find { |e| e['kind'] == 'run_ended' }&.dig('seq').to_i
          pend = entries.reverse.find { |e| %w[release_pending release_cancelled unbound run_reopened].include?(e['kind']) }
          return false unless pend && pend['kind'] == 'release_pending' && pend['seq'] > ended_at

          case typed_in_transcript(pend)
          when true
            run.unbind('the operator spoke after the ending', sid)
            true
          when false
            run.append(:release_cancelled, prompt_id: pend['prompt_id'], reason: 'the prompt was not typed by the operator')
            false
          else
            false
          end
        end

        # true / false once the prompt is in the transcript; nil before.
        def typed_in_transcript(pend)
          path = pend['transcript_path']
          return nil unless path && File.exist?(path)

          want = pend['text'].to_s.strip
          matches = File.foreach(path, encoding: 'UTF-8').filter_map do |line|
            d = JSON.parse(line) rescue next
            next unless d['type'] == 'user'
            next unless pend['prompt_id'] ? d['promptId'] == pend['prompt_id'] : Transcript.text_of(d).to_s.strip == want

            d
          end
          return nil if matches.empty?

          matches.any? { |d| Transcript.typed?(d) }
        end

        # A reference like D4 or I3 may be followed directly by Japanese text
        # ("D4は違う"), so no word boundary is required after the number.
        REFERENCE = /(?<![A-Za-z0-9])[DI]\d+(?![0-9A-Za-z])|(?i:adopt\s+policy)|採用|訂正|承認|確定(?!申告)|差し戻/

        # Words that may later confirm, correct, resolve or adopt something,
        # from any session: kept with their transcript so they can be verified.
        def record_operator_reference(input, prompt)
          return unless REFERENCE.match?(prompt)

          @paths.ensure_ignored
          FileUtils.mkdir_p(File.dirname(@paths.operator_words_path))
          File.open(@paths.operator_words_path, 'a') do |f|
            f.puts(JSON.generate('session_id' => input['session_id'], 'transcript_path' => input['transcript_path'],
                                 'prompt_id' => input['prompt_id'], 'text' => prompt, 'at' => Time.now.utc.iso8601(3)))
          end
        end

        # --- Stop / SubagentStop -----------------------------------------------

        def stop(input, subagent:)
          run = Run.bound_to(@paths, input['session_id'])
          return nil unless run
          return nil if release_if_typed(run, input['session_id'])
          return nil if run.status == 'finished'

          policy = policy_for(run)
          return nil unless policy

          msg = input['last_assistant_message'].to_s
          tail = msg[-2000..] || msg
          # While phases remain, a turn's last words are read for hazards and
          # questions. Once every phase has ended (the report is being built),
          # or after an ending, they are not decision points of the run.
          live = run.status == 'running' && run.current_phase
          if live && HAZARD_WORDS.match?(tail)
            out = begin
              hazard(run, policy, tail)
            rescue StandardError, ScriptError => e
              # A ruling that cannot be made ends the run (INV-4), also when
              # making it raised.
              end_on_unruled_hazard(run, tail, e)
            end
            return out if out
          end
          return nil if !subagent && Array(input['background_tasks']).any?
          if live && QUESTION_END.match?(tail.strip)
            answer = prose_question(run, policy, tail)
            return block("Stand-in answer (provisional, journaled): #{answer}. Continue the run.") if answer
          end
          return nil if subagent

          continue_or_rest(run)
        end

        def continue_or_rest(run)
          remaining = run.current_phase || !run.report
          return nil unless remaining

          if run.status == 'ended'
            return nil if run.last_block_seq && run.last_progress_seq.to_i <= run.last_block_seq.to_i

            run.append(:stop_blocked)
            return block("Run #{run.id} has ended (#{run.end_reason}). #{Guidance.report_step(run)}")
          end

          # Before the first block, starting is the progress. After it, the
          # journal's progress or a change in the workspace (commits, edited
          # files, a new design file) is; a read-only shell call is not.
          fingerprint = workspace_fingerprint(run)
          last_block = run.journal.entries.reverse.find { |e| e['kind'] == 'stop_blocked' }
          progressed = run.last_block_seq.nil? || run.last_progress_seq.to_i > run.last_block_seq.to_i ||
                       (last_block && last_block['fingerprint'] && last_block['fingerprint'] != fingerprint)
          if run.in_flight_review
            # Once per progress: a round that never comes back rests the run.
            last = run.journal.entries.reverse.find { |e| e['kind'] == 'stop_blocked' }
            unless last && last['for'] == 'review_in_flight' && !progressed
              run.append(:stop_blocked, for: 'review_in_flight', fingerprint: fingerprint)
              return block("Run #{run.id}: a review round is running. Call agent_advance(run_id: '#{run.id}') to collect it.")
            end
          end
          if progressed
            run.append(:stop_blocked, fingerprint: fingerprint)
            return block("Run #{run.id} continues. #{Guidance.next_step(run)}")
          end
          # Only what blocks the current phase can make the run wait; a
          # refused effect elsewhere leaves other work to do.
          if run.current_phase && run.open_items_for(run.current_phase, %w[review_open blocking]).any?
            run.append(:run_ended, reason: 'waiting on operator items')
            run.ensure_merge_item
            run.append(:stop_blocked)
            return block("Run #{run.id} can only wait on operator items and has ended. #{Guidance.report_step(run.reload)}")
          end
          # The session is alive and stays bound (the guard keeps working); the
          # run rests until the next turn. Interruption is a session ending.
          run.append(:idle, reason: 'the turn ended without progress while work remained')
          nil
        end

        # --- SessionStart / SessionEnd -------------------------------------------

        def session_start(input)
          sid = input['session_id']
          touch_guard_seen(sid)
          run = Run.bound_to(@paths, sid)
          return context('SessionStart', Guidance.summary(run)) if run

          recent = Time.now - (7 * 86_400)
          here = Confinement.real(File.expand_path(@project_root.to_s))
          # Offered here: runs of this project without a report whose own
          # session is not live (a live one is continued there, not taken).
          active = Run.all(@paths).select do |r|
            r.resumable? && File.mtime(r.journal.path) > recent && Confinement.real(r.target_repo.to_s) == here &&
              !session_live?(r.bound_session)
          end
          return nil if active.empty?

          lines = active.map do |r|
            "Agent run #{r.id} (#{r.status}, goal: #{r.goal}) has no report yet. If the operator wants it continued " \
              "here, call agent_start(resume: '#{r.id}'); its state: agent_status(run_id: '#{r.id}')."
          end
          context('SessionStart', lines.join("\n"))
        end

        def session_end(input)
          sid = input['session_id']
          Run.clear_taken_over(@paths, sid)
          FileUtils.rm_f(taken_over_pending_path(sid))
          run = Run.bound_to(@paths, sid)
          return nil unless run

          run.append(:interrupted, reason: "session ended (#{input['reason']})") if run.status == 'running'
          run.unbind('session ended', sid)
          nil
        end

        private

        SAFE_GIT = ['-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', '--no-pager', '--no-optional-locks'].freeze

        # What the run's work stands at: the run branch's HEAD, the worktree's
        # changes (and when the changed files were last written), and the
        # files the run created.
        def workspace_fingerprint(run)
          parts = []
          if run.worktree && File.directory?(run.worktree)
            head, = Open3.capture2('git', *SAFE_GIT, '-C', run.worktree, 'rev-parse', 'HEAD', err: File::NULL)
            st, = Open3.capture2('git', *SAFE_GIT, '-C', run.worktree, 'status', '--porcelain', '--untracked-files=normal',
                                 err: File::NULL)
            changed = st.lines.map { |l| File.join(run.worktree, l[3..].to_s.strip.split(' -> ').last.to_s) }
            parts << head.strip << st << changed.map { |f| File.mtime(f).to_f rescue 0 }.max.to_s
          end
          created = run.created_paths.reject { |p| p.start_with?('l2:') } +
                    Dir.glob(File.join(run.target_repo.to_s, 'log', 'agent_runs', run.id, '*'))
          parts << created.size.to_s << created.map { |f| File.mtime(f).to_f rescue 0 }.max.to_s
          Digest::SHA256.hexdigest(parts.join("\0"))
        rescue SystemCallError
          nil
        end

        def session_live?(sid, within: 600)
          return false if sid.to_s.empty?

          f = File.join(@paths.guard_seen_dir, Run.safe(sid))
          File.exist?(f) && (Time.now - File.mtime(f)) <= within
        end

        # A session whose run another session took over: its guard refuses
        # what would act, until the operator speaks here again or the session
        # ends, so its turn does not continue unguarded.
        def taken_over(tool)
          return nil if Guard::READ_ONLY_TOOLS.include?(tool) || Guard::SESSION_LOCAL_TOOLS.include?(tool)

          deny('The agent run of this session was taken over by another session. Stop here: nothing more is done ' \
               "in this session for that run. (Refused: #{tool}.)")
        end

        def decision_point(run, policy, v, input)
          # After an ending the operator is back: the host asks them.
          return nil if %w[AskUserQuestion ExitPlanMode].include?(v.decision) && run.status != 'running'

          stand_in = stand_in_for(run, policy)
          case v.decision
          when 'AskUserQuestion' then ask_user_question(run, stand_in, input)
          when 'ExitPlanMode' then exit_plan_mode(run, stand_in, input)
          when 'pinned_test_change' then pinned_test_change(run, stand_in, input, v.reason)
          else deny("unknown decision point #{v.decision}")
          end
        end

        def ask_user_question(run, stand_in, input)
          questions = Array(input.dig('tool_input', 'questions'))
          answers = {}
          queued = []
          questions.each do |q|
            labels = Array(q['options']).map { |o| o['label'] }
            a = stand_in.ask(point: 'question', question: q['question'], options: labels,
                             evidence: { 'header' => q['header'], 'multiSelect' => q['multiSelect'],
                                         'options' => q['options'] },
                             precedents: precedents(run, q['question']), operator_words: words(run))
            record_decision(run, 'question', q['question'], a, input)
            if a.operator_item?
              queued << q['question']
              run.open_item('question', q['question'], detail: { 'header' => q['header'], 'options' => labels })
            else
              answers[q['question']] = Array(a.answer).join(', ')
            end
          end
          if queued.empty?
            allow(updated_input: input['tool_input'].merge('answers' => answers))
          else
            told = answers.map { |k, val| "\"#{k}\" → #{val}" }.join('; ')
            deny("The operator is not answering during this run. Stand-in answers: #{told.empty? ? 'none' : told}. " \
                 "Queued for the operator: #{queued.join(' | ')}. Continue with work that does not depend on them.")
          end
        end

        def exit_plan_mode(run, stand_in, input)
          plan = input.dig('tool_input', 'plan').to_s
          a = stand_in.ask(point: 'plan_approval', question: 'Approve this plan for the run?',
                           options: %w[approve revise], evidence: { 'plan' => plan[0, 12_000], 'goal' => run.goal },
                           precedents: precedents(run, plan[0, 2000]), operator_words: words(run))
          record_decision(run, 'plan_approval', 'plan', a, input)
          return allow if a.answer.to_s == 'approve' && !a.operator_item?

          if a.operator_item?
            run.open_item('plan_approval', 'plan approval needs the operator')
            return deny('Plan approval is queued for the operator; continue with independent work.')
          end
          deny("Stand-in asks for a revision: #{a.reason}")
        end

        def pinned_test_change(run, stand_in, input, path)
          # The ruling compares with the pinned base, not with whatever an
          # earlier unruled change left in the file.
          old = base_text(run, path) || (File.exist?(path) ? File.read(path) : '')
          ti = input['tool_input'] || {}
          new_text = expected_content(path, ti) || ti['content'] ||
                     [ti['old_string'], ti['new_string']].compact.join("\n--- becomes ---\n")
          a = stand_in.ask(point: 'pinned_test_change',
                           question: "May the pinned test #{path} change? Approve only if the design calls for it.",
                           options: %w[approve refuse],
                           evidence: { 'path' => path, 'old' => old[0, 6000], 'new' => new_text.to_s[0, 6000],
                                       'goal' => run.goal },
                           precedents: precedents(run, "test #{File.basename(path)} #{run.goal}"),
                           operator_words: words(run))
          d = record_decision(run, 'pinned_test_change', path, a, input)
          if a.answer.to_s == 'approve' && !a.operator_item?
            run.append(:pinned_change, path: path, decision: d['id'], by: 'stand-in', digest: expected_digest(run, path, ti))
            return allow
          end
          if a.operator_item?
            run.open_item('pinned_test_change', "change to pinned test #{path}", ref: run.current_phase,
                                                                              detail: { 'paths' => [path],
                                                                                        'digests' => { path => expected_digest(run, path, ti) } })
          end
          deny("The stand-in did not approve changing pinned test #{path}: #{a.reason}")
        end

        def prose_question(run, policy, tail)
          stand_in = stand_in_for(run, policy)
          a = stand_in.ask(point: 'prose_question', question: tail[-1200..] || tail,
                           precedents: precedents(run, tail), operator_words: words(run))
          record_decision(run, 'prose_question', tail[-1200..] || tail, a, {})
          if a.operator_item?
            run.open_item('question', tail[-300..] || tail)
            return nil
          end
          Array(a.answer).join(', ')
        end

        def hazard(run, policy, tail)
          stand_in = stand_in_for(run, policy)
          ruling, a = stand_in.rule_hazard(tail[-1500..] || tail, precedents: precedents(run, tail), operator_words: words(run))
          record_decision(run, 'hazard', tail[-1500..] || tail, a, {})
          case ruling
          when 'in_world', 'uncertain', 'not_ruled'
            # INV-4: present in the world, or the stand-in cannot rule.
            run.append(:hazard, ruling: ruling, text: tail[-1500..] || tail)
            run.append(:run_ended, reason: "hazard (#{ruling})")
            run.ensure_merge_item
            run.append(:stop_blocked)
            block("A fatal hazard was ruled #{ruling}; run #{run.id} has ended. Do not continue the task. " \
                  "#{Guidance.report_step(run)} Put the hazard first.")
          when 'in_draft'
            run.open_item('finding', "fatal-kind defect in the work under review: #{(tail[-300..] || tail)}")
            nil
          end
        end

        def base_text(run, path)
          return nil unless run.worktree && run.base_commit

          rel = Confinement.real(path).delete_prefix("#{Confinement.real(run.worktree)}/")
          out, st = Open3.capture2('git', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', '--no-pager',
                                   '-C', run.worktree, 'cat-file', 'blob', "#{run.base_commit}:#{rel}", err: File::NULL)
          st.success? ? out : nil
        rescue SystemCallError
          nil
        end

        # The stand-in, or one that answers every point as failed when it
        # cannot even be built (e.g. the project's ruby cannot load the
        # KairosChain gem): a failure is an operator item, and a hazard it
        # cannot rule ends the run (INV-4).
        def stand_in_for(run, policy)
          StandIn.guard(run, @stand_in_factory.call(run, policy))
        rescue StandardError, ScriptError => e
          StandIn.guard(run, UnavailableStandIn.new(e))
        end

        def end_on_unruled_hazard(run, tail, error)
          run.append(:hazard, ruling: 'not_ruled', text: tail[-1500..] || tail, error: "#{error.class}: #{error.message[0, 200]}")
          run.append(:run_ended, reason: 'hazard (not_ruled)')
          run.ensure_merge_item
          run.append(:stop_blocked)
          block("A possible fatal hazard could not be ruled (#{error.class}); run #{run.id} has ended. Do not continue the " \
                "task. #{Guidance.report_step(run.reload)} Put the hazard first.")
        end

        def record_decision(run, point, question, a, input)
          run.record_decision(point, question, a, 'tool_use_id' => input['tool_use_id'])
        end

        def precedents(run, text)
          Precedents.new(@paths.precedents_dir).retrieve(text, project: File.basename(run.target_repo.to_s))
        end

        def words(run)
          run.verified_operator_words
        end

        # The pinned test's text once the edit lands (Write, Edit, MultiEdit).
        def expected_content(path, ti)
          return ti['content'] if ti['content']

          edits = ti['edits'] || (ti['old_string'] ? [ti] : nil)
          return nil unless edits && File.exist?(path)

          edits.reduce(File.read(path)) do |cur, e|
            old = e['old_string'].to_s
            new = e['new_string'].to_s
            e['replace_all'] ? cur.gsub(old) { new } : cur.sub(old) { new }
          end
        end

        # Its blob id in the pin's own scheme, so the check does not rule on
        # an approved change a second time.
        def expected_digest(run, path, ti)
          content = expected_content(path, ti)
          content ? Run.blob_id(content, run.pinned.values.first&.dig('algo') || 'sha1') : nil
        end

        # A refused file change is kept whole, so the operator can judge and
        # apply it from the item (INV-2: the exact command and its state).
        def keep_change(run, item, change)
          return unless change.is_a?(Hash) && !change.empty?

          dir = File.join(run.dir, 'items')
          FileUtils.mkdir_p(dir)
          path = change['file_path'] || change['path']
          File.write(File.join(dir, "#{item['id']}.json"),
                     JSON.pretty_generate(change.merge('target_sha256' => (File.file?(path.to_s) ? Digest::SHA256.file(path).hexdigest : nil))))
          run.append(:item_detail, id: item['id'], change_file: File.join(dir, "#{item['id']}.json"))
        end

        def policy_for(run)
          Policies.new(@paths).all.find { |p| p.digest == run.policy_digest }
        end

        def touch_guard_seen(sid)
          return if sid.to_s.empty?

          FileUtils.mkdir_p(@paths.guard_seen_dir)
          FileUtils.touch(File.join(@paths.guard_seen_dir, Run.safe(sid)))
        end

        def parse_tool_response(resp)
          text = case resp
                 when String then resp
                 when Array then resp.map { |c| c.is_a?(Hash) ? c['text'] : c.to_s }.join
                 when Hash then resp['text'] || (resp['content'] && parse_tool_response(resp['content']).to_json) || resp.to_json
                 end
          parsed = JSON.parse(text.to_s)
          parsed.is_a?(Array) ? parse_tool_response(parsed) : parsed
        rescue JSON::ParserError
          nil
        end

        def allow(updated_input: nil)
          out = { 'hookEventName' => 'PreToolUse', 'permissionDecision' => 'allow' }
          out['updatedInput'] = updated_input if updated_input
          { 'hookSpecificOutput' => out }
        end

        def deny(reason)
          { 'hookSpecificOutput' => { 'hookEventName' => 'PreToolUse', 'permissionDecision' => 'deny',
                                      'permissionDecisionReason' => reason } }
        end

        def block(reason)
          { 'decision' => 'block', 'reason' => reason }
        end

        def context(event, text)
          { 'hookSpecificOutput' => { 'hookEventName' => event, 'additionalContext' => text } }
        end
      end

      # A stand-in that could not be built: every point fails, with the cause.
      class UnavailableStandIn
        def initialize(error)
          @reason = "#{StandIn::FAILED}: stand-in unavailable: #{error.class}: #{error.message.to_s[0, 160]}"
        end

        def ask(**)
          StandIn::Answer.new(answer: nil, klass: 'operator_item', confidence: 0.0, basis: [], reason: @reason,
                              calls: 0, inputs_digest: '')
        end

        def rule_hazard(_text, **kw)
          ['not_ruled', ask(**kw)]
        end
      end
    end
  end
end
