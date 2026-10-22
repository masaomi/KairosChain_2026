# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require_relative 'seats'

module KairosMcp
  module SkillSets
    module Agent
      # Review phases (design v0.5.1 INV-2, INV-3). The SkillSet composes and
      # dispatches each round itself — the actor never calls the review tool
      # in a bound session — from the artifact, the findings still open and
      # the plan; no line is written by the stand-in's judgment of the work,
      # so no precedent reaches a seat. The stand-in checks the bundle before
      # dispatch and labels each seat's reply as produced. A label it cannot
      # justify stays open: closure needs quorum and every P0 fixed or
      # refuted with grounds (design v0.6.6: at the policy's rounds for each
      # review, or a cap the plan names, it waits for the operator). Each
      # round also says which new P0s land in the actor's last revision, so
      # the next step asks for a subtractive revision (L1
      # multi_llm_review_workflow § Revision Discipline).
      class Review
        CREDENTIAL = [
          /AKIA[0-9A-Z]{16}/, /\bsk-(ant-|proj-)?[A-Za-z0-9_-]{20,}/, /\bghp_[A-Za-z0-9]{30,}/, /\bxox[baprs]-[A-Za-z0-9-]{10,}/,
          /-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----/, /\bAIza[0-9A-Za-z_-]{30,}/
        ].freeze
        FRAME_HEADING = '## Review philosophy frame (this project)'
        CHUNK = 60_000
        LABELS = %w[new carried_over fixed refuted deferred].freeze
        LEVEL_FRAME = '## Review level (fixed by the SkillSet)' + "\n\n" \
                      'Review this artifact at its own level. A finding about how to implement it is not a P0 of this ' \
                      'review; name it as P1 (implementation). Do not propose code.'
        REVISION_DIFF_MAX = 40_000
        MIN_GROUNDS = 40
        REPLY_BUDGET = 150_000
        WAITING = %w[still_pending pending running].freeze

        # invoke: callable(tool_name, args) -> parsed JSON Hash (the tool's payload)
        # words: callable -> the operator's verified words, freshest first
        # precedents: callable(text) -> retrieved precedent records
        # head: callable -> the run branch's HEAD (implementation reviews), so
        # a closure is never given to commits the round did not see.
        # revision_diff: callable(previous review_round entry, this one) -> the
        # actor's change between the two rounds' artifacts, as text.
        def initialize(run:, policy:, stand_in:, invoke:, project_root:, words: -> { [] }, precedents: ->(_t) { [] },
                       head: nil, type: nil, revision_diff: ->(_a, _b) { '' }, clock: -> { Time.now },
                       sleep: ->(s) { Kernel.sleep(s) })
          @run = run
          @policy = policy
          @stand_in = stand_in
          @invoke = invoke
          @project_root = project_root
          @words = words
          @precedents = precedents
          @head = head
          @type = type&.to_s
          @revision_diff = revision_diff
          @clock = clock
          @sleep = sleep
        end

        def credentials?(text)
          CREDENTIAL.any? { |re| re.match?(text) }
        end

        # One step of the phase: collect a pending round, label a collected
        # one, or dispatch the next.
        def step(phase, artifact_name:, artifact:, review_type:)
          pending = pending_round(phase.name.to_s)
          return collect(phase, pending) if pending

          unlabelled = unlabelled_round(phase.name.to_s)
          return label_round(phase, unlabelled) if unlabelled

          dispatch(phase, artifact_name, artifact, review_type)
        end

        def dispatch(phase, artifact_name, artifact, review_type, extra: {})
          name = phase.name.to_s
          unlabelled = unlabelled_round(name)
          return label_round(phase, unlabelled) if unlabelled

          unless @policy.consents?(:review)
            return refuse_with_item(name, 'blocking', "#{name}: the adopted policy gives no consent to send artifacts to review seats",
                                    'the policy gives no review consent')
          end
          round = rounds_done(name) + 1
          bound = round_bound_of(phase)
          if bound && round > bound
            return refuse_with_item(name, 'review_open', "#{name} is not closed and has had its #{bound} rounds; it waits for " \
                                                         'the operator (decision more_rounds, or freeze)',
                                    "#{name} is at its round cap; it waits for the operator", status: 'waiting',
                                                                                              any_of_kind: true)
          end

          carry = open_findings(name)
          bundle = compose(artifact, carry, %w[design document].include?((@type || review_type).to_s))
          # The artifact itself, not the bundle (whose carried lines change
          # from round to round), says whether anything changed.
          artifact_digest = Digest::SHA256.hexdigest(artifact.to_s)
          entries = @run.journal.entries
          last = entries.reverse.find { |e| e['kind'] == 'review_round' && e['phase'] == name }
          sent_back = last && entries.any? { |e| e['kind'] == 'phase_reopened' && e['phase'] == name && e['seq'] > last['seq'] }
          if last && !sent_back && last['counted'].to_i >= last['quorum'].to_i && last['artifact_digest'] == artifact_digest
            return { 'status' => 'refused',
                     'reason' => "nothing changed since round #{last['round']}: answer its open P0s in a new version " \
                                 '(a new design file, or new commits) before the next round' }
          end
          if credentials?(bundle)
            return refuse_with_item(name, 'blocking', "#{name}: the bundle carries a credential; review not dispatched",
                                    'credential in bundle')
          end
          # The whole bundle is checked, in chunks; the project exemption covers
          # the artifact only, so a bundle with carried-over lines is checked.
          unless @policy.free_of_personal_data?(File.basename(@project_root.to_s)) && carry.empty?
            pieces = (0...bundle.length).step(CHUNK).map { |i| bundle[i, CHUNK] }
            pieces.each_with_index do |piece, i|
              a = @stand_in.ask(point: 'data_check', options: %w[clean carries_personal_or_third_party_data],
                                question: "Does this part (#{i + 1}/#{pieces.size}) of a review bundle carry personal or third-party data, or credentials?",
                                evidence: { 'bundle_part' => piece })
              @run.record_decision('data_check', "bundle for #{name} round #{round}, part #{i + 1}/#{pieces.size}", a)
              next if a.answer.to_s == 'clean' && !a.operator_item?

              return refuse_with_item(name, 'blocking', "#{name}: bundle part #{i + 1} may carry personal or third-party data",
                                      'data check did not pass')
            end
          end
          clear_blocking(name)

          prior = carry.map { |f| { 'id' => f['id'], 'severity' => 'P0', 'issue' => f['text'][0, 400] } }
          seats = compose_seats(name, round, review_type, artifact_name, bundle, prior)
          request = {
            'artifact_name' => artifact_name, 'review_type' => review_type,
            'artifact_content' => bundle, 'review_round' => round,
            'orchestrator_strategy' => 'delegate', 'orchestrator_model' => 'claude-opus-5-5',
            'persona_count_declared' => seats.size, 'escalate' => true, 'complexity' => 'high',
            'prior_findings' => prior
          }
          request['collect_deadline_seconds_override'] = Seats::DEADLINE_SECONDS unless seats.empty?
          payload = @invoke.call('multi_llm_review', request)
          token = payload['collect_token']
          return { 'status' => 'error', 'reason' => payload['error'] || 'no collect token' } unless token

          entry = { phase: name, round: round, token: token,
                    bundle_sha256: Digest::SHA256.hexdigest(bundle), artifact_digest: artifact_digest,
                    bundle_file: store_bundle(name, round, bundle) }.merge(extra)
          # Persona seats exist in the delegated protocol only; the seats, the
          # token and its deadline are journaled in the one dispatch entry.
          if !seats.empty? && payload['status'] == 'delegation_pending'
            entry[:seats] = seats
            entry[:must_collect_by] = payload['must_collect_by']
          end
          @run.append(:review_dispatched, entry)
          { 'status' => 'dispatched', 'round' => round,
            'next' => "Round #{round} is running (about 5-10 minutes). Call agent_advance again to collect it." }
        end

        # The persona seats' full prompts, stored under their digests; none
        # (the round runs as 1.0.1 did) when they cannot be composed.
        def compose_seats(phase, round, review_type, artifact_name, bundle, prior)
          composed = Seats.compose(review_type: review_type, artifact_name: artifact_name, bundle: bundle, round: round,
                                   prior: prior, worktree: @run.worktree, branch: @run.branch)
          Seats.store_prompts(@run, composed)
        rescue StandardError, ScriptError => e
          @run.append(:seats_not_composed, phase: phase, round: round, reason: "#{e.class}: #{e.message[0, 300]}")
          []
        end

        # Collects whatever the round produced, also after a worker crash: a
        # round with quorum is a round.
        def collect(phase, pending)
          name = phase.name.to_s
          budget_end = @clock.call + Seats::WAIT_SECONDS
          with_seats = pending['seats'].is_a?(Array) && !pending['seats'].empty?
          if with_seats
            held = seat_gate(pending, budget_end)
            return held if held
          end
          left = (budget_end - @clock.call).to_i.clamp(30, Seats::WAIT_SECONDS)
          wait = @invoke.call('multi_llm_review_wait', { 'collect_token' => pending['token'], 'max_wait_seconds' => left })
          st = wait['status'].to_s
          if WAITING.include?(st)
            # Each call that waited earns the Stop hook's next block (§3.7).
            @run.append(:seats_waited, phase: name, round: pending['round'], token: pending['token'], running: 0) if with_seats
            return { 'status' => 'pending', 'detail' => st, 'next' => 'The round is still running. Call agent_advance again.' }
          end

          reviews, persona_rows, outcomes = with_seats ? seat_submission(pending) : [[], [], nil]
          result = collect_call(pending['token'], reviews)
          if result['status'] == 'error' && !reviews.empty? && result['error'].to_s.start_with?('invalid orchestrator_reviews')
            # MLR's refusal of a persona submission leaves the token
            # collectable: the external seats' replies are kept.
            @run.append(:seat_submission_refused, phase: name, round: pending['round'], token: pending['token'],
                                                  detail: result['error'].to_s[0, 600])
            outcomes.each { |o| o.merge!('submitted' => false, 'cause' => 'refused_by_review_tool') if o['submitted'] }
            result = collect_call(pending['token'], [])
          end
          if result['status'] != 'ok'
            detail = "#{st}: #{result['error'] || result['status']}"
            @run.append(:review_dispatch_failed, phase: name, round: pending['round'], token: pending['token'], detail: detail)
            return { 'status' => 'dispatch_failed', 'detail' => detail, 'next' => 'Call agent_advance again to dispatch the round anew.' }
          end
          seats = Array(result['reviews']).map do |r|
            { 'seat' => r['role_label'].to_s, 'verdict' => r['verdict'].to_s, 'reply' => (r['raw_text'] || r['raw_text_excerpt']).to_s }
          end
          # What the stand-in reads: each persona's own reply in place of the
          # review tool's assembled persona row (INV-3).
          team = Array(result['reviews']).find { |r| r['synthetic'] || r.key?('persona_rows') }
          team_label = team ? team['role_label'].to_s : 'claude_team'
          read = if with_seats
                   seats.reject { |s| s['seat'] == team_label } +
                     persona_rows.map { |r| { 'seat' => "#{team_label}/#{r['persona']}", 'verdict' => r['verdict'], 'reply' => r['reply'] } }
                 else
                   seats
                 end
          p0_lines = Array(result['aggregated_findings']).select { |f| f.is_a?(Hash) && f['severity'].to_s.upcase == 'P0' }
                                                         .map { |f| (f['issue'] || f['text']).to_s[0, 600] }
          counted = result.dig('vote_tally', 'successful_count').to_i
          quorum = result.dig('vote_tally', 'min_quorum').to_i.nonzero? || 2
          file = store_replies(name, pending['round'], read, p0_lines)
          @run.append(:review_round, { phase: name, round: pending['round'], token: pending['token'], counted: counted,
                                       quorum: quorum, wait_status: st, commit: pending['commit'], replies_file: file,
                                       bundle_sha256: pending['bundle_sha256'], artifact: pending['artifact'],
                                       bundle_file: pending['bundle_file'], artifact_digest: pending['artifact_digest'],
                                       seats: seats.map { |s| { 'seat' => s['seat'], 'verdict' => s['verdict'],
                                                                'reply_sha256' => Digest::SHA256.hexdigest(s['reply']),
                                                                'reply' => s['reply'][0, 4000] } } }
                                     .merge(with_seats ? { personas: outcomes, persona_count_declared: pending['seats'].size } : {}))
          label_round(phase, @run.journal.entries.reverse.find { |e| e['kind'] == 'review_round' && e['phase'] == name })
        end

        def collect_call(token, reviews)
          @invoke.call('multi_llm_review_collect', { 'collect_token' => token, 'orchestrator_reviews' => reviews,
                                                     'include_raw_text' => true })
        end

        # Holds the round while persona seats are reviewing, within this
        # call's budget and never past the cutoff. Seats never launched get
        # the launch instruction once; after that, and at the cutoff, what is
        # missing becomes a shortfall. Returns a reply, or nil to collect.
        def seat_gate(pending, budget_end)
          token = pending['token']
          loop do
            at = @clock.call
            Seats.settle_orphans(@run, at)
            entries = @run.journal.entries
            return nil if Seats.closed?(entries, token)

            d = Seats.dispatch_for(entries, token) || pending
            cutoff = Seats.cutoff_of(d)
            return nil if cutoff && at >= cutoff

            states = Seats.seat_states(entries, d)
            launch = Seats.to_launch(states)
            running = states.select { |s| s['state'] == 'running' }
            prompted = entries.any? { |e| e['kind'] == 'seats_prompted' && e['token'] == token }
            if !launch.empty? && !prompted
              @run.append(:seats_prompted, phase: d['phase'], round: d['round'], token: token,
                                           personas: launch.map { |s| s['persona'] })
              return { 'status' => 'pending', 'detail' => 'persona seats to launch',
                       'markers' => launch.map { |s| Seats.marker(@run.id, token, s['persona']) } }
            end
            return nil if running.empty?

            if at >= budget_end
              @run.append(:seats_waited, phase: d['phase'], round: d['round'], token: token, running: running.size)
              return { 'status' => 'pending', 'detail' => 'persona seats reviewing', 'running' => running.map { |s| s['persona'] } }
            end
            @sleep.call([Seats::POLL_SECONDS, budget_end - at, cutoff ? cutoff - at : Seats::POLL_SECONDS].min.clamp(0.05, Seats::POLL_SECONDS))
          end
        end

        # The seats' replies as settled: submitted to the review tool when a
        # verdict reads from them, given to the stand-in either way, never
        # inferred or transcribed.
        def seat_submission(pending)
          close_seats(pending)
          entries = @run.journal.entries
          d = Seats.dispatch_for(entries, pending['token']) || pending
          reviews = []
          rows = []
          outcomes = Seats.seat_states(entries, d).map do |s|
            o = { 'persona' => s['persona'], 'launches' => s['launches'], 'late' => s['late'] }
            a = s['answer']
            unless a
              cause = case s['state']
                      when 'not_launched' then 'not_launched'
                      when 'running' then 'not_settled'
                      else s['last_cause'] || 'no_reply'
                      end
              next o.merge('submitted' => false, 'cause' => cause)
            end
            text = Seats.settled_reply(a)
            next o.merge('submitted' => false, 'cause' => 'reply_changed') unless text

            v = Seats.verdict(text)
            rows << { 'persona' => s['persona'], 'verdict' => v.to_s, 'reply' => text }
            next o.merge('submitted' => false, 'cause' => 'no_verdict', 'agent_id' => a['agent_id']) unless v

            reviews << { 'persona' => s['persona'], 'verdict' => v, 'findings' => Seats.findings(text, v),
                         'reasoning' => text, 'agent_id' => a['agent_id'] }.compact
            o.merge('submitted' => true, 'verdict' => v, 'agent_id' => a['agent_id'])
          end
          [reviews, rows, outcomes]
        rescue StandardError, ScriptError => e
          # The review tool's parsers are its internals: if they cannot be
          # used, the round is collected without personas, and says why.
          @run.append(:seat_submission_failed, phase: pending['phase'], round: pending['round'], token: pending['token'],
                                               reason: "#{e.class}: #{e.message[0, 300]}")
          [[], [], Array(pending['seats']).map { |x| { 'persona' => x['persona'], 'submitted' => false, 'cause' => 'parse_failed' } }]
        end

        # Closes the round's seats. A close that fails (the seat lock cannot be
        # taken) is journaled as itself and the replies already settled are
        # still submitted; launches left unsettled count as not_settled. A
        # journal that cannot be written fails the round whatever this does.
        def close_seats(pending)
          Seats.settle_remaining(@run, pending['token'])
        rescue StandardError => e
          @run.append(:seats_close_failed, phase: pending['phase'], round: pending['round'], token: pending['token'],
                                           reason: "#{e.class}: #{e.message[0, 300]}")
        end

        # Labels a collected round. A failed labelling keeps the round: the
        # next advance labels it again without paying for another dispatch.
        def label_round(phase, entry)
          name = phase.name.to_s
          round = entry['round']
          seats, p0_lines = load_replies(entry)
          prior = open_findings(name)
          bundle = (File.read(entry['bundle_file'].to_s) rescue '')
          before = @run.journal.entries.reverse.find { |e| e['kind'] == 'review_round' && e['phase'] == name && e['round'].to_i < round.to_i }
          revision = before ? @revision_diff.call(before, entry).to_s[0, REVISION_DIFF_MAX] : ''
          labels = label(phase, round, seats, prior, p0_lines, bundle, revision)
          if labels.nil?
            if @run.decisions.last&.dig('reason') == StandIn::SPENT
              return refuse_with_item(name, 'blocking', "#{name} round #{round}: the policy's stand-in call bound is reached; " \
                                                        'the seats\' findings cannot be labelled (decision more_calls)',
                                      'stand-in call bound reached', status: 'labelling_failed')
            end
            return refuse_with_item(name, 'blocking', "#{name} round #{round}: the stand-in could not label the seats' findings",
                                    'labelling failed', status: 'labelling_failed',
                                                        next_step: 'Call agent_advance again to label the round again.')
          end

          # The review tool extracted P0 lines, yet the labelling listed
          # nothing at all: that is an incomplete labelling, not a closure.
          listed = labels.reject { |l| l['label_given'].to_s.start_with?('(') }
          # Every extracted P0 line is answered: by the lines each label says
          # it covers, or — when the labelling gives no coverage at all — by
          # at least as many labels as lines.
          given = listed.any? { |l| !Array(l['covers']).empty? }
          covered = listed.flat_map { |l| Array(l['covers']) }.map(&:to_i)
          incomplete = given ? (0...p0_lines.size).any? { |i| !covered.include?(i) } : listed.size < p0_lines.size
          if !p0_lines.empty? && (listed.empty? || incomplete)
            return refuse_with_item(name, 'blocking', "#{name} round #{round}: the labelling did not answer every P0 line the review tool extracted",
                                    'labelling incomplete', status: 'labelling_failed',
                                                            next_step: 'Call agent_advance again to label the round again.')
          end

          open = labels.select { |l| l['open'] }
          tally = tally_of(labels)
          @run.append(:review_labelled, phase: name, round: round, labels: labels, open: open.size, tally: tally)
          defer(name, labels)
          quorate = entry['counted'].to_i >= entry['quorum'].to_i
          settle_carried(name, round, labels) if quorate
          clear_blocking(name)
          bound = round_bound_of(phase)
          moved = @head && entry['commit'] && @head.call != entry['commit']
          if quorate && open.empty? && moved
            # A round that saw no P0 but not the latest commits: one more round
            # sees them, within the cap (at the cap the operator grants it).
            at_cap = bound && round >= bound
            return { 'status' => 'open', 'round' => round, 'labels' => labels,
                     'next' => 'The work changed after this round was dispatched (new commits or a new version); ' +
                               (at_cap ? "this review has had its #{bound} rounds, so a round that sees it waits for the operator's more_rounds." :
                                         'call agent_advance for a round that sees it.') }
          end
          if quorate && open.empty?
            @run.append(:phase_ended, phase: name, by: 'closure', provisional: true, round: round)
            item = @run.open_item('closure', "#{name} closed provisionally at round #{round}; the operator confirms it, or sends " \
                                             "it back (decision send_back)#{seats_note(entry)}", ref: name)
            return { 'status' => 'closed_provisionally', 'round' => round, 'labels' => labels, 'item' => item['id'] }
          end
          if quorate && bound && round >= bound
            return refuse_with_item(name, 'review_open', "#{name} is open (#{open.size} P0) and has had its #{bound} rounds; it " \
                                                         "waits for the operator (decision more_rounds, or freeze)#{seats_note(entry)}",
                                    "#{name} is at its round cap; it waits for the operator", status: 'waiting',
                                                                                              extra: { 'labels' => labels },
                                                                                              any_of_kind: true)
          end

          { 'status' => quorate ? 'open' : 'no_quorum', 'round' => round, 'open_p0' => open, 'tally' => tally,
            'next' => quorate ? revise_step(name, labels) : 'Too few seats answered; call agent_advance again for the next round.' }
        end

        # The next step after a round with open P0s (L1 multi_llm_review_workflow
        # § Revision Discipline): new P0s drawn by the last revision are
        # answered by undoing it, and a count that has not fallen for two
        # rounds calls for another approach. The run does not stop for either.
        def revise_step(phase, labels)
          steps = []
          drawn = labels.select { |l| l['label'] == 'new' && l['from_revision'] }
          unless drawn.empty?
            steps << "#{drawn.size} new P0 (#{drawn.map { |l| l['id'] }.join(', ')}) were drawn by what you added since the " \
                     'previous round: undo that addition, and answer the finding it was meant to answer by deletion, ' \
                     'correction or naming instead.'
          end
          counts = @run.journal.entries.select { |e| e['kind'] == 'review_labelled' && e['phase'] == phase }.map { |e| e['open'].to_i }
          if counts.size >= 3 && counts[-1] >= counts[-2] && counts[-2] >= counts[-3]
            steps << "The open P0 count has not fallen for two rounds (#{counts.last(3).join(' → ')}): change approach — " \
                     'prove or refute each open P0 by a test or a reproduction, undo additions, or split the artifact.'
          end
          steps << 'Answer each open P0 in the next version of the artifact (a new file, or new commits) by deletion, ' \
                   'correction or naming; a new mechanism a finding seems to need is a question to ask before writing it. ' \
                   'Then call agent_advance again.'
          steps.join(' ')
        end

        # Persona seats the round went without because of how they were
        # launched — never, or only after another seat had answered — named
        # where the operator rules on the round (design v0.3 §3.8).
        def seats_note(entry)
          missed = Array(entry['personas']).select { |o| o['cause'] == 'not_launched' || o['late'] }
          return '' if missed.empty?

          '. Persona seats launched late or never in this round: ' +
            missed.map do |o|
              how = o['cause'] == 'not_launched' ? 'never launched' : 'first launched after another seat had answered'
              "#{o['persona']} (#{how}#{o['submitted'] ? ', then submitted' : (o['cause'] == 'not_launched' ? '' : ", then #{o['cause']}")})"
            end.join(', ')
        end

        def tally_of(labels)
          n = ->(label, rev = nil) { labels.count { |l| l['label'] == label && (rev.nil? || (l['from_revision'] == true) == rev) } }
          { 'carried_open' => n.call('carried_over'), 'fixed' => n.call('fixed'), 'refuted' => n.call('refuted'),
            'deferred' => n.call('deferred'), 'new_from_revision' => n.call('new', true), 'new_elsewhere' => n.call('new', false) }
        end

        # A deferred design finding is carried, as an item, into the run's
        # later reviews (open_findings), or stays an operator item where no
        # later review comes.
        def defer(phase, labels)
          labels.select { |l| l['label'] == 'deferred' }.each do |l|
            key = [l['seat'].to_s, l['text'].to_s[0, 120]]
            next if @run.open_items.any? { |i| i['item_kind'] == 'carried_p0' && [i.dig('detail', 'seat').to_s, i.dig('detail', 'text').to_s[0, 120]] == key }

            @run.open_item('carried_p0', "#{phase}: deferred to the implementation: #{l['seat']}: #{l['text'][0, 300]}", ref: phase,
                                         detail: { 'finding' => l['id'], 'seat' => l['seat'], 'text' => l['text'], 'deferred' => true,
                                                   'grounds' => l['grounds'] })
          end
        end

        def pending_round(phase)
          entries = @run.journal.entries
          last = entries.select { |e| e['kind'] == 'review_dispatched' && e['phase'] == phase }.last
          return nil unless last

          done = entries.any? do |e|
            %w[review_round review_dispatch_failed].include?(e['kind']) && e['phase'] == phase && e['round'] == last['round'] &&
              e['seq'] > last['seq']
          end
          done ? nil : last
        end

        def unlabelled_round(phase)
          entries = @run.journal.entries
          last = entries.select { |e| e['kind'] == 'review_round' && e['phase'] == phase }.last
          return nil unless last
          return nil if entries.any? { |e| e['kind'] == 'review_labelled' && e['phase'] == phase && e['round'] == last['round'] }

          last
        end

        private

        LABEL_QUESTION = 'List every (a) or (b) P0 the seats raised in their replies, and rule on every earlier open P0 ' \
                         'listed in the evidence. "text" quotes the seat\'s own words for the finding, never the ' \
                         'operator\'s (the text is carried to the seats). Label each: "new" (raised this round), "carried_over" (an earlier P0 ' \
                         'still raised or not answered), "fixed" (an earlier P0 the artifact now answers and no seat ' \
                         'raises), "refuted" (wrong, with grounds that cite the artifact as sent). A "new" P0 that an addition ' \
                         'in the revision diff (what the actor changed since the previous round) drew has "from_revision": true. ' \
                         'Earlier P0s carry their id ' \
                         'as "earlier_id". Each label lists in "covers" the indices (from 0) of the extracted P0 lines ' \
                         'it answers; every extracted line must be covered by some label. Return the list as the answer: ' \
                         '[{"seat":..,"text":..,"label":..,"earlier_id":..,"grounds":..,"covers":[..],"from_revision":..}].'
        DEFER_QUESTION = ' This is a design review: a P0 that, with grounds, concerns only how to implement the design ' \
                         '(not what it requires) is labelled "deferred"; it goes to the implementation review.'

        # The labeller reads what the seats read (the bundle, so a "refuted"
        # or "fixed" can be checked against the artifact) and their replies,
        # within one budget shared across the seats.
        def label(phase, round, seats, prior, p0_lines, bundle = '', revision = '')
          per_seat = seats.empty? ? 0 : REPLY_BUDGET / seats.size
          a = @stand_in.ask(
            point: 'review_labels', question: LABEL_QUESTION + (@type == 'design' ? DEFER_QUESTION : ''),
            evidence: { 'phase' => phase.name.to_s, 'revision_diff' => revision.to_s,
                        'earlier_open_p0' => prior.map { |p| { 'id' => p['id'], 'seat' => p['seat'], 'text' => p['text'].to_s[0, 600] } },
                        'p0_lines_the_review_tool_extracted' => p0_lines.each_with_index.map { |t, i| { 'index' => i, 'text' => t } },
                        'artifact_as_sent' => bundle.to_s[0, 60_000],
                        'seat_replies' => seats.map { |s| { 'seat' => s['seat'], 'verdict' => s['verdict'], 'reply' => s['reply'][0, per_seat] } } },
            operator_words: @words.call
          )
          @run.record_decision('review_labels', "labels for #{phase.name} round #{round}", a)
          # A failed or malformed labelling never closes a review.
          return nil if a.operator_item? || !a.answer.is_a?(Array)

          normalize(a.answer, prior, seats, round, phase.name)
        end

        # Any label outside the five, a "fixed" with no earlier P0, or a
        # "refuted" without grounds stays open; an earlier P0 the labelling
        # did not address is carried over; a seat that rejects with no P0
        # listed is an open finding of its own.
        def normalize(raw, prior, seats, round, phase = 'review')
          abbr = phase.to_s.split('_').map { |w| w[0].to_s.upcase }.join
          prior_ids = prior.map { |p| p['id'].to_s }
          seen = []
          out = raw.each_with_index.map do |l, i|
            l = {} unless l.is_a?(Hash)
            given = l['label'].to_s
            norm = given.downcase.strip.gsub(/[\s-]+/, '_')
            norm = 'carried_over' if %w[carried carriedover open still_open].include?(norm)
            earlier = prior_ids.include?(l['earlier_id'].to_s) ? l['earlier_id'].to_s : nil
            seen << earlier if earlier
            grounds = l['grounds'].to_s.strip
            label = LABELS.include?(norm) ? norm : 'new'
            label = 'new' if label == 'fixed' && earlier.nil?
            label = 'new' if %w[refuted deferred].include?(label) && grounds.length < MIN_GROUNDS
            label = 'new' if label == 'deferred' && @type != 'design'
            label = 'carried_over' if label == 'new' && earlier
            { 'id' => earlier || "#{abbr}#{round}.F#{i + 1}", 'seat' => l['seat'].to_s, 'text' => l['text'].to_s,
              'label' => label, 'label_given' => given, 'grounds' => grounds, 'earlier_id' => earlier,
              'covers' => Array(l['covers']).map(&:to_i), 'open' => %w[new carried_over].include?(label),
              'from_revision' => label == 'new' && l['from_revision'] == true }
          end
          prior.reject { |p| seen.include?(p['id'].to_s) }.each do |p|
            out << { 'id' => p['id'].to_s, 'seat' => p['seat'].to_s, 'text' => p['text'].to_s, 'label' => 'carried_over',
                     'label_given' => '(not addressed by the labelling)', 'grounds' => '', 'earlier_id' => p['id'].to_s,
                     'open' => true }
          end
          seats.each do |s|
            next unless s['verdict'].upcase == 'REJECT'
            next if out.any? { |l| same_seat?(l['seat'], s['seat']) }

            out << { 'id' => "#{abbr}#{round}.#{s['seat']}", 'seat' => s['seat'], 'text' => "#{s['seat']} rejected with no P0 listed",
                     'label' => 'new', 'label_given' => '(seat verdict REJECT)', 'grounds' => '', 'earlier_id' => nil, 'open' => true }
          end
          out
        end

        # Seats compare by their whole label (case and punctuation aside); an
        # abbreviated name answers no seat's REJECT.
        def same_seat?(a, b)
          x = a.to_s.downcase.gsub(/[^a-z0-9]/, '')
          y = b.to_s.downcase.gsub(/[^a-z0-9]/, '')
          !x.empty? && x == y
        end

        # A P0 frozen open at an earlier review and labelled fixed or refuted
        # here is settled (provisionally, as the closure is): its item closes,
        # so it is not sent to the seats again.
        def settle_carried(phase, round, labels)
          labels.each do |l|
            next if l['open'] || l['earlier_id'].nil? || l['label'] == 'deferred'

            item = @run.items[l['earlier_id']] ||
                   @run.open_items.find { |i| i['item_kind'] == 'carried_p0' && i.dig('detail', 'finding') == l['earlier_id'] }
            next unless item && item['item_kind'] == 'carried_p0' && item['state'] == 'open'

            @run.append(:item_resolved, id: item['id'],
                                        resolution: "labelled #{l['label']} in #{phase} round #{round} (provisional)")
          end
        end

        # Rounds a review may take: the policy's review_rounds, counted for
        # each review apart (design v0.6.6), or a cap the plan names, plus
        # the rounds the operator granted this review.
        def round_bound_of(phase)
          cap = [phase.args[:max_rounds], @run.spend['review_rounds']].compact.map(&:to_i).min
          return nil unless cap

          cap + @run.round_extensions[phase.name.to_s].to_i
        end

        # Opens an item once per phase and text, and answers the actor.
        def refuse_with_item(phase, kind, text, reason, status: 'refused', next_step: nil, extra: {}, any_of_kind: false)
          item = @run.open_items_for(phase, [kind]).find { |i| any_of_kind || i['text'] == text } ||
                 @run.open_item(kind, text, ref: phase)
          out = { 'status' => status, 'reason' => reason, 'item' => item['id'] }.merge(extra)
          out['next'] = next_step if next_step
          out
        end

        # A blocking item whose cause has cleared (the next dispatch passed its
        # checks, or the round was labelled) is resolved.
        def clear_blocking(phase)
          @run.open_items_for(phase, %w[blocking]).each do |i|
            @run.append(:item_resolved, id: i['id'], resolution: 'cleared: the step it blocked has passed')
          end
        end

        def store_bundle(phase, round, bundle)
          dir = File.join(@run.dir, 'reviews')
          FileUtils.mkdir_p(dir)
          path = File.join(dir, "#{phase}_r#{round}_bundle.md")
          File.write(path, bundle)
          path
        end

        def store_replies(phase, round, seats, p0_lines)
          dir = File.join(@run.dir, 'reviews')
          FileUtils.mkdir_p(dir)
          path = File.join(dir, "#{phase}_r#{round}.json")
          File.write(path, JSON.generate('seats' => seats, 'p0_lines' => p0_lines))
          path
        end

        def load_replies(entry)
          data = JSON.parse(File.read(entry['replies_file'].to_s))
          [data['seats'], Array(data['p0_lines'])]
        rescue Errno::ENOENT, JSON::ParserError, TypeError
          [Array(entry['seats']).map { |s| s.merge('reply' => s['reply'].to_s) }, []]
        end

        def compose(artifact, carry, level = false)
          parts = []
          frame = project_frame
          parts << frame if frame
          parts << LEVEL_FRAME if level
          unless carry.empty?
            parts << "## Findings still open from earlier rounds or reviews (as labelled from the seats' replies)\n" +
                     carry.map { |f| "- [#{f['id']}] [#{f['seat']}] #{f['text']}" }.join("\n")
          end
          parts << artifact
          parts.join("\n\n---\n\n")
        end

        def project_frame
          path = File.join(@project_root.to_s, 'CLAUDE.md')
          return nil unless File.exist?(path)

          text = File.read(path)
          i = text.index('```', text.index(FRAME_HEADING) || return)
          j = i && text.index('```', i + 3)
          i && j ? text[(i + 3)...j].sub(/\A\w*\n/, '') : nil
        end

        def rounds_done(phase)
          @run.journal.entries.count { |e| e['kind'] == 'review_round' && e['phase'] == phase }
        end

        # Open P0s: this phase's latest labels, plus those an earlier design
        # review deferred to the implementation (design v0.6.4: P0s frozen
        # open stay on the cover as operator items and are not carried).
        def open_findings(phase)
          last = @run.journal.entries.reverse.find { |e| e['kind'] == 'review_labelled' && e['phase'] == phase }
          own = last ? Array(last['labels']).select { |l| l['open'] } : []
          carried = @run.open_items.select { |i| i['item_kind'] == 'carried_p0' && i.dig('detail', 'deferred') && i.dig('state_ref', 'ref') != phase }
                        .map { |i| { 'id' => i['id'], 'seat' => i.dig('detail', 'seat').to_s, 'text' => i.dig('detail', 'text').to_s } }
          carried.reject { |c| own.any? { |o| o['id'] == c['id'] } } + own
        end
      end
    end
  end
end
