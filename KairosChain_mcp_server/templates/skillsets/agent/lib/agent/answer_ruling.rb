# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'

module KairosMcp
  module SkillSets
    module Agent
      # Every answer at an approval point is a ruling on the chain
      # (design v0.3, INV-D4 / INV-D8).
      #
      # Two record kinds:
      #
      #   agent_answer              one per committed advance, written by the
      #                             driver when the advance commits. It is the
      #                             ruling: it exists only for a decision that
      #                             was carried out, and a replayed retry never
      #                             writes a second one (it never commits).
      #   agent_answer_attestation  the operator's answer typed at the terminal
      #                             (bin/agent_rule.rb answer), bound to the
      #                             anchor it was given at. While it is the
      #                             latest one at that anchor, an MCP answer
      #                             there proceeds only if it is the same
      #                             answer; a stop always proceeds (operator
      #                             ruling 2026-10-07: stopping is never
      #                             refused) and is recorded as overriding it.
      #
      # Texts (revise feedback, rationale) stay off the chain in the session
      # directory; records carry their sha256.
      #
      # Attestation boundary (INV-D8): 'terminal_nonce' records the path the
      # answer came by. Any party that can write the chain could write a block
      # of the same shape; the constrained party in phase 1 is the agent.
      module AnswerRuling
        KIND = 'agent_answer'
        ATTESTATION_KIND = 'agent_answer_attestation'
        TEXTS_FILE = 'answer_texts.jsonl'

        # Why a session is waiting. Written with the state change that stops it
        # (Session#update_state / #stop_at); a stop without one reads as
        # 'unspecified'. cycle_checkpoint is the scheduled end-of-cycle stop
        # (Gate 8 in autonomous mode, the end of an act with nothing left over
        # in manual mode) and nothing else.
        STOP_KINDS = %w[
          session_started cycle_observed plan_proposed cycle_checkpoint cycle_skipped adjudicated
          awaiting_operator guard_halt human_cognition_halt act_failed phase_error
          risk_exceeded goal_drift timeout llm_budget_exceeded l0_escalation
          review_rejected review_max_retries terminated
        ].freeze

        # States at which the persisted plan is the subject of the answer.
        PLAN_STATES = %w[proposed checkpoint paused_risk].freeze

        class << self
          # Test seam: a callable returning [records, error]. nil in production.
          attr_accessor :records_source
        end

        module_function

        def sha256(text)
          text.nil? || text.to_s.empty? ? nil : Digest::SHA256.hexdigest(text.to_s)
        end

        def plan_sha256(decision)
          task = decision.is_a?(Hash) ? decision['task_json'] : nil
          task.nil? ? nil : Digest::SHA256.hexdigest(JSON.generate(task))
        end

        # Answer records in chain order, each with the index of its block.
        def records_from_blocks(blocks)
          Array(blocks).flat_map do |block|
            data = block.respond_to?(:data) ? block.data : (block['data'] || block[:data])
            index = block.respond_to?(:index) ? block.index : (block['index'] || block[:index])
            Array(data).filter_map do |entry|
              rec = entry.is_a?(String) ? (JSON.parse(entry) rescue nil) : entry
              next unless rec.is_a?(Hash) && [KIND, ATTESTATION_KIND].include?(rec['kind'])

              rec.merge('block' => index)
            end
          end
        end

        # [records, nil], or [[], reason] when the chain cannot be read. The
        # ledger is rewritten in place on every append, so a read that races a
        # writer can see a torn file (measured in review, about 1 in 10,000
        # reads under load); a read is retried before it is believed.
        READ_ATTEMPTS = 3

        def chain_records
          return AnswerRuling.records_source.call if AnswerRuling.records_source

          require 'kairos_mcp/kairos_chain/chain'
          reason = nil
          READ_ATTEMPTS.times do |i|
            sleep(0.05 * i) if i.positive?
            begin
              chain = ::KairosMcp::KairosChain::Chain.new
              state = chain.load_state
              return [records_from_blocks(chain.chain), nil] if %i[readable absent].include?(state)

              reason = "chain #{state}"
            rescue StandardError => e
              reason = "chain unreadable: #{e.class}: #{e.message[0, 120]}"
            end
          end
          [[], reason]
        rescue StandardError, ScriptError => e
          [[], "chain unreadable: #{e.class}: #{e.message[0, 120]}"]
        end

        # An earlier ruling at the same anchor of the same session: only a
        # crash between the chain write and the gate commit leaves one. The
        # later ruling names it, so a count takes one ruling per anchor.
        def prior_ruling_at(records, session_id, anchor)
          Array(records).select do |r|
            r['kind'] == KIND && r['session_id'] == session_id && r['anchor'] == anchor
          end.last
        end

        # The operator's latest attested answer at this anchor, or nil.
        def attestation_at(records, session_id, anchor)
          Array(records).select do |r|
            r['kind'] == ATTESTATION_KIND && r['attested'] == true &&
              r['session_id'] == session_id && r['anchor'] == anchor
          end.last
        end

        # Whether an answer arriving through MCP may proceed where the operator
        # answered at the terminal. Returns { 'ok' => true, 'feedback',
        # 'attestation' | 'overrode' } or { 'ok' => false, 'reason',
        # 'attestation' }. A revise without feedback takes the text typed at the
        # terminal, if its sha256 is the one the attestation names.
        # check_plan: false for a call that targets an anchor the session has
        # already left; such a call can only replay, and the plan has moved on.
        def reconcile(attestation, action:, resolution: nil, feedback: nil, plan_sha256: nil, texts: nil,
                      check_plan: true)
          return { 'ok' => true, 'feedback' => feedback } unless attestation

          if action == 'stop'
            key = attestation['decision'] == 'stop' ? 'attestation' : 'overrode'
            return { 'ok' => true, 'feedback' => feedback, key => attestation }
          end
          refuse = ->(why) { { 'ok' => false, 'reason' => why, 'attestation' => attestation } }
          unless attestation['decision'] == action
            return refuse.call("the operator answered #{attestation['decision']} at the terminal")
          end
          if action == 'adjudicate' && attestation['resolution'] != resolution
            return refuse.call("the operator adjudicated #{attestation['resolution']} at the terminal")
          end
          if check_plan && attestation['plan_sha256'] && attestation['plan_sha256'] != plan_sha256
            return refuse.call('the plan is not the one the operator answered at the terminal')
          end
          if action == 'revise'
            want = attestation['feedback_sha256']
            if feedback.to_s.empty?
              text = Array(texts&.call).reverse.map { |t| t['feedback'] }.find { |f| want && sha256(f) == want }
              return refuse.call('the feedback typed at the terminal is not available; send it with the answer') unless text

              feedback = text
            elsif sha256(feedback) != want
              return refuse.call('the feedback differs from the one typed at the terminal')
            end
          end
          { 'ok' => true, 'feedback' => feedback, 'attestation' => attestation }
        end

        # The ruling for a committed advance. point: { 'state', 'cycle', 'stop',
        # and when a plan is the subject 'plan_sha256', 'signals', 'set_aside' }.
        def ruling(session_id:, mandate_id:, anchor:, point:, action:, action_key:, tables:,
                   answer: {}, feedback: nil, rationale: nil)
          att = answer['attestation']
          rec = {
            'kind' => KIND, 'session_id' => session_id, 'mandate_id' => mandate_id,
            'anchor' => anchor, 'state' => point['state'], 'cycle' => point['cycle'],
            'stop' => point['stop'], 'decision' => action, 'decision_key' => action_key,
            'approver' => att ? 'operator' : 'caller',
            'attestation' => att ? 'terminal_nonce' : 'caller_unattested',
            'tables' => tables, 'answered_at' => Time.now.utc.iso8601
          }
          rec['attestation_block'] = att['block'] if att
          rec['overrode_attestation_block'] = answer['overrode']['block'] if answer['overrode']
          rec['attestation_check'] = answer['read_error'][0, 160] if answer['read_error']
          rec['supersedes_block'] = answer['prior_ruling_block'] if answer['prior_ruling_block']
          %w[plan_sha256 signals set_aside].each { |k| rec[k] = point[k] if point.key?(k) }
          rec['feedback_sha256'] = sha256(feedback) if action == 'revise'
          # An attested ruling carries the operator's reason, typed at the
          # terminal; a caller's text is not attributed to the operator.
          reason = att ? att['rationale_sha256'] : sha256(rationale)
          rec['rationale_sha256'] = reason if reason
          rec
        end

        # Appends a record through the tool's chain_record. Never raises: a
        # human answer is never blocked by a recording failure (INV-D4).
        def record(tool, rec)
          out = tool.invoke_tool('chain_record', { 'logs' => [JSON.generate(rec)] })
          text = Array(out).map { |b| b[:text] || b['text'] }.compact.join
          m = text.match(/Block #(\d+) recorded successfully\./)
          return { 'recorded' => true, 'block' => m[1].to_i, 'attestation' => rec['attestation'] } if m

          { 'recorded' => false, 'error' => "chain_record replied: #{text[0, 160]}",
            'note' => 'the answer proceeded; this point does not count as evidence for delegation' }
        rescue StandardError, ScriptError => e
          { 'recorded' => false, 'error' => "#{e.class}: #{e.message[0, 160]}",
            'note' => 'the answer proceeded; this point does not count as evidence for delegation' }
        end

        def save_texts(session_dir, anchor:, source:, feedback: nil, rationale: nil)
          return if feedback.to_s.empty? && rationale.to_s.empty?

          entry = { 'anchor' => anchor, 'source' => source, 'at' => Time.now.utc.iso8601 }
          entry['feedback'] = feedback unless feedback.to_s.empty?
          entry['rationale'] = rationale unless rationale.to_s.empty?
          File.open(File.join(session_dir, TEXTS_FILE), 'a') { |f| f.puts(JSON.generate(entry)) }
        end

        def texts_at(session_dir, anchor, source: 'terminal')
          path = File.join(session_dir, TEXTS_FILE)
          return [] unless File.exist?(path)

          File.foreach(path).filter_map do |line|
            e = JSON.parse(line) rescue nil
            e if e.is_a?(Hash) && e['anchor'] == anchor && e['source'] == source
          end
        end

        # Agent-authored text as it may reach the operator's terminal: control
        # and format characters (escape sequences, carriage returns, newlines,
        # bidirectional overrides) are shown as escapes, so the text cannot
        # move the cursor, erase lines, or reorder what the operator reads.
        #
        # Invalid bytes are replaced, so no string the agent writes can make
        # the display raise. max caps text the answer does not bind (goal,
        # stop detail); the plan is shown whole.
        def printable(text, max = nil)
          s = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub('?')
          s = s.gsub(/[[:cntrl:]\p{Cf}\p{Zl}\p{Zp}]|[\p{Zs}&&[^ ]]/) { |c| format('\\u{%x}', c.ord) }
          max && s.length > max ? "#{s[0, max]}…" : s
        end

        def json_text(value)
          JSON.generate(value)
        rescue StandardError
          value.inspect
        end

        # Argument names that say where a step acts; shown first.
        LOCATION_NAME = /path|file|dir|root|source|destination|target|url|name/i

        # The plan exactly as the attested hash covers it: every step with
        # every argument, location arguments first, nothing cut; any other
        # field of the task; and the file that holds it. The agent wrote all
        # of it, so all of it is escaped, and the summary is marked as the
        # plan's own claim rather than something the driver observed.
        def show_plan(tty_out, decision, state, plan_sha, decision_path)
          lines = []
          out = Object.new
          out.define_singleton_method(:puts) { |line = ''| lines << line.to_s }
          plan_lines(out, decision, state, plan_sha, decision_path)
          lines.each { |l| tty_out.puts l }
          show_locations(tty_out, decision['task_json'], lines, decision_path)
        end

        # Where the plan acts, repeated last, next to the prompt. The agent
        # wrote the plan above and controls its length and order, so it can
        # push any line of it out of sight; this block is short by
        # construction, so what the answer most depends on stays in view.
        def show_locations(tty_out, task, lines, decision_path)
          steps = task['steps'].is_a?(Array) ? task['steps'] : []
          tty_out.puts
          tty_out.puts "Where this plan acts (#{steps.size} step(s); each step's tool and location arguments):"
          steps.each_with_index do |st, i|
            unless st.is_a?(Hash)
              tty_out.puts "  step #{i + 1}: (not a step; read the file)"
              next
            end
            args = st['tool_arguments'].is_a?(Hash) ? st['tool_arguments'] : {}
            locs = args.select { |k, _| k.to_s.match?(LOCATION_NAME) }
            where = if locs.empty?
                      '(no location argument)'
                    else
                      locs.map { |k, v| "#{printable(k, 30)}=#{visible(json_text(v))}" }.join(' ')
                    end
            tty_out.puts "  step #{i + 1}: #{printable(st['tool_name'], 40)} #{where}"
          end
          tty_out.puts "The plan above took #{lines.size} lines (#{lines.sum(&:length)} characters). If it scrolled " \
                       "away, read it whole in #{File.expand_path(decision_path)}"
        end

        # A location value made legible: runs of spaces shown as a count, a
        # long value cut with a marker that says so.
        def visible(text, max = 120)
          s = printable(text).gsub(/ {2,}/) { |m| "[#{m.size} spaces]" }
          s.length > max ? "#{s[0, max]} (cut; read the file)" : s
        end

        def plan_lines(tty_out, decision, state, plan_sha, decision_path)
          heading = { 'proposed' => 'Plan proposed (this answer decides whether it runs):',
                      'paused_risk' => 'Plan stopped at the risk gate (this answer decides whether it runs):',
                      'checkpoint' => 'Plan that has already run this cycle (approve starts the next cycle):' }
          tty_out.puts heading[state] || 'Plan:'
          tty_out.puts "  summary, as the plan states it: #{printable(decision['summary'])}"
          task = decision['task_json']
          steps = task['steps']
          if steps.is_a?(Array)
            steps.each_with_index do |st, i|
              unless st.is_a?(Hash)
                tty_out.puts "  step #{i + 1}: #{printable(json_text(st))}"
                next
              end
              tty_out.puts "  step #{i + 1}: id #{printable(st['step_id'])}, tool #{printable(st['tool_name'])}"
              args = st['tool_arguments']
              if args.is_a?(Hash)
                args.keys.sort_by { |k| k.to_s.match?(LOCATION_NAME) ? 0 : 1 }.each do |k|
                  tty_out.puts "      #{printable(k)}: #{printable(json_text(args[k]))}"
                end
              elsif !args.nil?
                tty_out.puts "      arguments: #{printable(json_text(args))}"
              end
              extra = st.reject { |k, _| %w[step_id tool_name tool_arguments].include?(k) }
              tty_out.puts "      other fields: #{printable(json_text(extra))}" unless extra.empty?
            end
          else
            tty_out.puts "  steps: #{printable(json_text(steps))}"
          end
          rest = task.reject { |k, _| k == 'steps' }
          tty_out.puts "  other plan fields: #{printable(json_text(rest))}" unless rest.empty?
          tty_out.puts "  The whole plan is in #{File.expand_path(decision_path)}"
          tty_out.puts "  sha256 #{plan_sha}"
        end

        # The answers the terminal offers at a state.
        def answers_for(effective_state, intent)
          return [] if effective_state == 'terminated'
          return %w[adjudicate stop] if intent

          case effective_state
          when 'proposed' then %w[approve revise skip stop]
          when 'paused_risk', 'paused_error' then %w[approve skip stop]
          else %w[approve stop]
          end
        end

        # ---- the terminal answer (INV-D8) ----

        # Shows the stop on tty_out, reads the answer, an optional reason and
        # the nonce on tty_in, and records the attestation only when the nonce
        # matches and the session is still at the anchor shown. reload: a
        # callable returning the session as persisted now. Returns
        # { 'recorded' => bool, ... }.
        def interactive_answer(session:, gate:, tty_in:, tty_out:, reload:, chain: nil,
                               nonce_value: ActClassification.nonce)
          anchor = gate.current_anchor(session)
          state = gate.effective_state(session)
          intent = gate.unresolved_intent
          offered = answers_for(state, intent)
          if offered.empty?
            tty_out.puts "Session #{session.session_id} is #{session.state}; there is nothing to answer."
            return { 'recorded' => false, 'reason' => 'nothing_to_answer' }
          end

          decision = session.load_decision
          plan_sha = PLAN_STATES.include?(state) ? plan_sha256(decision) : nil
          stop = session.stop || {}
          tty_out.puts "Session: #{printable(session.session_id)} (#{session.autonomous? ? 'autonomous' : 'manual'})"
          tty_out.puts "Goal:    #{printable(session.goal_name)}"
          tty_out.puts "Stopped: #{printable(session.state)}, cycle #{session.cycle_number}, " \
                       "because #{printable(session.stop_kind)}"
          tty_out.puts "         #{printable(stop['detail'], 300)}" if stop['detail']
          tty_out.puts "Anchor:  #{anchor}"
          if intent
            tty_out.puts 'An act started and its outcome was never recorded. Answer adjudicate (reattempt or already_done) or stop.'
          end
          show_plan(tty_out, decision, state, plan_sha, session.send(:decision_path)) if plan_sha
          tty_out.puts
          tty_out.print "Your answer (#{offered.join(' / ')}): "
          tty_out.flush
          action = tty_in.gets.to_s.strip.downcase
          unless offered.include?(action)
            tty_out.puts 'Not one of the answers offered. Nothing was recorded.'
            return { 'recorded' => false, 'reason' => 'not_offered' }
          end

          resolution = nil
          feedback = nil
          if action == 'adjudicate'
            tty_out.print 'Resolution (reattempt / already_done): '
            tty_out.flush
            resolution = tty_in.gets.to_s.strip
            unless %w[reattempt already_done].include?(resolution)
              tty_out.puts 'Not a resolution. Nothing was recorded.'
              return { 'recorded' => false, 'reason' => 'not_offered' }
            end
          elsif action == 'revise'
            tty_out.print 'Feedback for the revision (one line): '
            tty_out.flush
            feedback = tty_in.gets.to_s.strip
            if feedback.empty?
              tty_out.puts 'A revision needs feedback. Nothing was recorded.'
              return { 'recorded' => false, 'reason' => 'empty_feedback' }
            end
          end
          tty_out.print 'Reason (optional, one line, kept off the chain): '
          tty_out.flush
          rationale = tty_in.gets.to_s.strip

          tty_out.print "Type #{nonce_value} to record this answer (anything else cancels): "
          tty_out.flush
          unless tty_in.gets.to_s.strip == nonce_value
            tty_out.puts 'Cancelled. Nothing was recorded.'
            return { 'recorded' => false, 'reason' => 'nonce_mismatch' }
          end

          record = {
            'kind' => ATTESTATION_KIND, 'session_id' => session.session_id, 'anchor' => anchor,
            'state' => session.state, 'stop' => session.stop_kind, 'decision' => action,
            'attested' => true, 'attestation' => 'terminal_nonce', 'ruled_at' => Time.now.utc.iso8601
          }
          record['resolution'] = resolution if resolution
          record['plan_sha256'] = plan_sha if plan_sha
          record['feedback_sha256'] = sha256(feedback) if feedback
          record['rationale_sha256'] = sha256(rationale) if sha256(rationale)

          # Recorded under the advance lock, and only if no advance moved the
          # session while the operator was typing.
          result = gate.with_lock do
            now = reload.call
            if now.nil? || gate.current_anchor(now) != anchor
              next { 'recorded' => false, 'reason' => 'moved_on',
                     'detail' => "the session moved to #{now ? gate.current_anchor(now) : 'nowhere'}" }
            end
            # What was shown must still be what is answered: an act can open
            # its intent, or a plan be rewritten, without the anchor moving.
            now_state = gate.effective_state(now)
            unless answers_for(now_state, gate.unresolved_intent).include?(action)
              next { 'recorded' => false, 'reason' => 'moved_on',
                     'detail' => "#{action} is no longer an answer this session can take" }
            end
            if (PLAN_STATES.include?(now_state) ? plan_sha256(now.load_decision) : nil) != plan_sha
              next { 'recorded' => false, 'reason' => 'moved_on', 'detail' => 'the plan changed after it was shown' }
            end

            record['state'] = now.state
            record['stop'] = now.stop_kind
            save_texts(session.guard_dir, anchor: anchor, source: 'terminal', feedback: feedback, rationale: rationale)
            chain ||= begin
              require 'kairos_mcp/kairos_chain/chain'
              ::KairosMcp::KairosChain::Chain.new
            end
            begin
              block = chain.add_block([JSON.generate(record)])
            rescue StandardError => e
              next { 'recorded' => false, 'reason' => 'chain_refused', 'detail' => "#{e.class}: #{e.message[0, 160]}" }
            end
            { 'recorded' => true, 'block_index' => block.index, 'record' => record }
          end

          if result['status'] == 'busy'
            tty_out.puts 'An advance is in flight on this session. Nothing was recorded; try again when it settles.'
            return { 'recorded' => false, 'reason' => 'busy' }
          end
          unless result['recorded']
            if result['reason'] == 'chain_refused'
              tty_out.puts "The chain did not take the answer (#{result['detail']}). Nothing was recorded."
            else
              tty_out.puts "The session moved on while you were answering (#{result['detail']}). Nothing was recorded."
            end
            return result
          end

          tty_out.puts "Recorded as block ##{result['block_index']}."
          tty_out.puts "Now send #{action}#{resolution ? " (#{resolution})" : ''} at this anchor (agent_step). " \
                       'A different answer here is refused; a stop always goes through.'
          result
        end
      end
    end
  end
end
