# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'
require 'fileutils'
require_relative 'run'
require_relative 'policies'
require_relative 'stand_in'

module KairosMcp
  module SkillSets
    module Agent
      # The policy report (design v0.7.2 INV-8): for each rule of the adopted
      # policy, what the runs the instance's chain records as ended hold
      # against that rule — counts with their denominators and the operator's
      # words of each act — and what those counts cannot show. It moves no
      # rule and binds nothing. The operator runs it outside runs; it reads
      # the data directory, calls no model, evaluates no file from a run
      # directory, and writes one file under storage/agent/policy_reports
      # (and storage/agent/.gitignore when absent).
      class PolicyReport
        # Decision points the policy's stand-in classes govern; the reading
        # points (StandIn::READING_POINTS) are counted apart.
        GOVERNED_POINTS = %w[question prose_question plan_approval plan_parameters pinned_test_change].freeze
        DERIVED_CLASSES = %w[precedent instruction_mode novel_reversible operator_item].freeze
        # The SkillSet's own unit for a more_calls grant (Service#operator_act).
        CALLS_PER_COUNT = 50
        ACT_SOURCE = /\Arun (\S+) ([DI]\d+)\z/
        DATA_ITEM = 'may carry personal or third-party data'
        NO_CONSENT = 'gives no consent to send artifacts'
        CAVEAT = 'What these counts cannot show: every act is recorded on the actor\'s reading of the operator\'s ' \
                 'words, in both directions. An act the actor never recorded, or recorded under another kind, is ' \
                 'missing here; words a keyword check misread (for example a refusal read as a grant) are counted here.'
        CAP_SIGNAL = 'Frequent cap hits are a signal to revisit how reviews converge.'
        # What Paths#ensure_ignored writes. The report is written only beside a
        # regular file (not a link, which git does not read) holding exactly
        # these bytes; anything else is refused rather than read as git would
        # read it. This is the bound of the protection: it does not ask git, and
        # it is the same protection the journals and the operator's words in
        # storage/agent already have.
        IGNORE_ALL = "*\n"

        Material = Struct.new(:id, :dir, :entries, :lines_total, :lines_counted, :chained, :start,
                              :pinned_policy, keyword_init: true) do
          def project
            File.basename(start['target_repo'].to_s)
          end

          def decisions
            entries.select { |e| e['kind'] == 'decision' }
          end

          def of_kind(kind)
            entries.select { |e| e['kind'] == kind }
          end
        end

        def initialize(paths, now: Time.now)
          @paths = paths
          @now = now.utc
        end

        # The default file backend's ledger under the data directory.
        def chain_path
          File.join(@paths.data_dir, 'storage', 'blockchain.json')
        end

        def reports_dir
          File.join(@paths.root, 'policy_reports')
        end

        # Writes the report as a new file (never over an existing one) and
        # returns its path. storage/agent is git-ignored before anything is
        # written there.
        def write
          raise ArgumentError, "no data directory at #{@paths.data_dir}" unless File.directory?(@paths.data_dir)

          text = markdown
          @paths.ensure_ignored
          ignore = File.join(@paths.root, '.gitignore')
          unless !File.symlink?(ignore) && File.file?(ignore) && File.read(ignore) == IGNORE_ALL
            raise IOError, "#{ignore} is not a regular file holding exactly the line '*'; the report quotes " \
                           "the operator's words, so none is written"
          end

          FileUtils.mkdir_p(reports_dir)
          stamp = @now.strftime('%Y%m%d-%H%M%S')
          n = 1
          begin
            path = File.join(reports_dir, n == 1 ? "#{stamp}.md" : "#{stamp}-#{n}.md")
            File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(text) }
          rescue Errno::EEXIST
            n += 1
            retry
          end
          path
        end

        def markdown
          @policies = Policies.new(@paths)
          @all_policies = nil
          @adopted = @policies.adopted
          @acts = operator_acts
          chain = read_chain
          runs, no_end, mismatch, journals = gather(chain)
          out = ['# Agent policy report', '', "Generated: #{@now.iso8601} (UTC). Data directory: #{@paths.data_dir}", '']
          out << 'This report reads the data directory above and describes it. It moves no rule and binds nothing. ' \
                 'Outside runs the chain is unsigned and journals can be written by any session, so what follows is ' \
                 "material for the operator's reading, not proof; the chain's block hashes are not verified here " \
                 '(chain_verify does that). L2 contexts and the answers harvested from transcripts are not read.'
          out << ''
          base_section(out)
          runs_section(out, chain, runs, no_end, mismatch, journals)
          if runs.empty?
            out << '## No material yet' << ''
            out << "There is no material yet: #{count(journals.size, 'journal')} found under " \
                   "#{@paths.runs_dir}, 0 runs counted."
            out << ''
          else
            stand_in_section(out, runs)
            review_rounds_section(out, runs)
            stand_in_calls_section(out, runs)
            other_spend_section(out)
            personal_data_section(out, runs)
            consent_section(out, runs)
          end
          closing_section(out)
          out.join("\n") + "\n"
        end

        private

        # --- reading ------------------------------------------------------------

        # The chain's agent_run_end records: { state:, ends: { run_id => [digests] }, records:, error: }.
        def read_chain
          return { state: :absent, ends: {}, records: 0 } unless File.exist?(chain_path)

          blocks = JSON.parse(File.read(chain_path, encoding: 'UTF-8'))
          raise TypeError, "not a JSON array (#{blocks.class})" unless blocks.is_a?(Array)

          ends = Hash.new { |h, k| h[k] = [] }
          records = 0
          blocks.each do |b|
            next unless b.is_a?(Hash)

            Array(b['data']).each do |d|
              rec = d.is_a?(String) ? (JSON.parse(d) rescue nil) : d
              next unless rec.is_a?(Hash) && rec['type'] == 'agent_run_end'

              records += 1
              ends[rec['run_id'].to_s] << rec['journal_digest'].to_s
            end
          end
          { state: :readable, ends: ends, records: records }
        rescue JSON::ParserError, TypeError, SystemCallError, IOError => e
          { state: :unreadable, ends: {}, records: 0, error: "#{e.class}: #{e.message.to_s[0, 200]}" }
        end

        # A journal counts up to its last line whose SHA-256 a chain end record
        # for its run names; lines after it are not counted.
        def gather(chain)
          journals = Dir.glob(File.join(@paths.runs_dir, '*', 'journal.jsonl')).sort
          runs = []
          no_end = []
          mismatch = []
          journals.each do |f|
            id = File.basename(File.dirname(f))
            recorded = chain[:ends].fetch(id, [])
            if recorded.empty?
              no_end << id
              next
            end
            lines = Journal.new(f).lines
            last = lines.rindex { |l| recorded.include?(Digest::SHA256.hexdigest(l)) }
            if last.nil?
              mismatch << id
              next
            end
            runs << material(id, File.dirname(f), lines, last)
          end
          [runs, no_end, mismatch, journals]
        end

        def material(id, dir, lines, last)
          counted = lines[0..last]
          entries = counted.filter_map do |l|
            h = JSON.parse(l)
            h if h.is_a?(Hash)
          rescue JSON::ParserError
            nil
          end
          start = entries.find { |e| e['kind'] == 'run_started' } || {}
          Material.new(id: id, dir: dir, entries: entries, lines_total: lines.size, lines_counted: counted.size,
                       chained: chained?(counted), start: start,
                       pinned_policy: pinned_policy(start['policy_digest']))
        end

        def chained?(lines)
          prev = Journal::GENESIS
          lines.each do |l|
            return false unless (JSON.parse(l)['prev'] rescue nil) == prev

            prev = Digest::SHA256.hexdigest(l)
          end
          true
        end

        # The policy the run pinned, found by its digest among the policies in
        # place (as Service#policy_for finds it). The run directory's own copy
        # is never evaluated: a file there is not code this report runs.
        def pinned_policy(digest)
          (@all_policies ||= @policies.all).find { |p| p.digest == digest }
        end

        def operator_acts
          path = File.join(@paths.precedents_dir, 'raw', 'operator_acts.jsonl')
          return [] unless File.exist?(path)

          File.readlines(path, chomp: true, encoding: 'UTF-8').filter_map do |l|
            h = JSON.parse(l)
            h if h.is_a?(Hash) && h['source'].to_s.match?(ACT_SOURCE)
          rescue JSON::ParserError
            nil
          end.sort_by { |a| [a['at'].to_s, a['id'].to_s] }
        end

        def acts_naming(run_id, ref)
          @acts.select { |a| a['source'] == "run #{run_id} #{ref}" }
        end

        # The act whose words resolved an item (the resolution keeps their
        # digest); every act naming the item when none matches.
        def resolving_acts(run, item_id)
          res = run.entries.reverse.find { |e| e['kind'] == 'item_resolved' && e['id'] == item_id }
          naming = acts_naming(run.id, item_id)
          sha = res && res['words_sha256']
          matched = naming.select { |a| Digest::SHA256.hexdigest(a['words'].to_s) == sha }
          [res, matched.empty? ? naming : matched, !matched.empty?]
        end

        # --- deriving -------------------------------------------------------------

        # The class the stand-in's answer stood on, as StandIn#decision_class
        # derived it under the run's pinned policy. A recorded "decided" already
        # stood on an allowed basis; only one citing both a precedent and the
        # instruction mode depends on the policy, and without the pinned policy
        # in place it is not classed.
        def derived_class(decision, policy)
          allows = ->(c) { policy.nil? || policy.allows?(c) }
          case decision['class']
          when 'decided_novel' then 'novel_reversible'
          when 'decided'
            basis = Array(decision['basis']).map(&:to_s)
            given = Array(decision.dig('inputs', 'precedent_ids')).map(&:to_s)
            cites = (basis & given).any?
            if policy.nil? && cites && basis.include?('instruction_mode') then 'unclassified'
            elsif allows.call(:precedent) && cites then 'precedent'
            elsif allows.call(:instruction_mode) && basis.include?('instruction_mode') then 'instruction_mode'
            else 'unclassified'
            end
          else 'operator_item'
          end
        end

        def no_answer_kind(decision)
          return nil unless decision['answer'].nil?
          return 'bound' if decision['reason'] == StandIn::SPENT
          return 'failed' if decision['reason'].to_s.start_with?(StandIn::FAILED)

          nil
        end

        # --- rendering ------------------------------------------------------------

        def of(k, n)
          "#{k} of #{n}"
        end

        def count(n, word)
          "#{n} #{word}#{n == 1 ? '' : 's'}"
        end

        def short(text, n = 160)
          t = text.to_s.gsub(/\s+/, ' ').strip
          t.length > n ? "#{t[0, n]}…" : t
        end

        def quote(words, indent = '  ')
          lines = words.to_s.strip.lines.map(&:chomp)
          lines = [''] if lines.empty?
          lines.map { |l| l.empty? ? "#{indent}>" : "#{indent}> #{l}" }
        end

        def adopted_line(text)
          @adopted ? text : 'No adopted policy: nothing to compare against; the runs are reported below.'
        end

        def base_section(out)
          out << '## Base: the adopted policy' << ''
          latest = @policies.adoptions.last
          if @adopted
            file = adopted_file
            out << "Adopted: `#{@adopted.name}`, digest #{@adopted.digest[0, 12]}, adopted at #{latest['at']}" \
                   "#{file ? "; file #{file}" : ''}."
            out << ''
            out << "- stand_in may: #{@adopted.stand_in_classes.map(&:inspect).join(', ').then { |s| s.empty? ? '(none)' : s }}"
            out << "- consent: #{consents_text(@adopted)}"
            out << "- free_of_personal_data projects: #{@adopted.free_of_personal_data.empty? ? '(none)' : @adopted.free_of_personal_data.join(', ')}"
            out << "- spend: #{@adopted.spend.map { |k, v| "#{k} #{v}" }.join(', ')}"
          elsif latest
            out << "No policy is adopted: the latest adoption names `#{latest['name']}` with digest " \
                   "#{latest['digest'].to_s[0, 12]}, and no policy file under #{@paths.policies_dir} has those bytes now."
          else
            out << "No policy is adopted: #{@paths.adoptions_path} holds no adoption. The runs are reported below " \
                   'without a rule to compare against.'
          end
          out << ''
        end

        def adopted_file
          @policies.files.find { |f| DSL.digest(File.read(f)) == @adopted.digest }
        rescue SystemCallError
          nil
        end

        def consents_text(policy)
          return '(none: a review is refused without it)' if policy.consents.empty?

          policy.consents.map { |c| "#{c[:kind]} #{c[:value].inspect}#{c[:of] ? " of #{c[:of].inspect}" : ''}" }.join('; ')
        end

        def runs_section(out, chain, runs, no_end, mismatch, journals)
          out << '## Runs' << ''
          case chain[:state]
          when :absent
            out << "No chain file at #{chain_path}: no run can be counted. (This reads the file backend's ledger only.)"
          when :unreadable
            out << "The chain file #{chain_path} could not be read (#{chain[:error]}): no run can be counted."
          else
            out << "Chain: #{chain_path} holds #{count(chain[:records], 'agent_run_end record')} " \
                   "for #{count(chain[:ends].size, 'run id')}."
          end
          out << ''
          out << "Journals found under #{@paths.runs_dir}: #{journals.size}. Counted: #{of(runs.size, journals.size)} " \
                 '(a run counts when the chain holds an agent_run_end record whose journal digest is the SHA-256 of ' \
                 'a line of its journal; the journal counts up to the last such line).'
          out << ''
          unless runs.empty?
            out << '| run | pinned policy | lines counted | lines chain to their predecessor | note |'
            out << '|---|---|---|---|---|'
            runs.each do |r|
              notes = []
              notes << 'pinned to a policy other than the adopted one' if other_policy?(r)
              notes << 'pinned policy not in place; an answer citing both a precedent and the mode is unclassified' if r.pinned_policy.nil?
              note = notes.join('; ')
              out << "| #{r.id} | #{r.start['policy_name']} #{r.start['policy_digest'].to_s[0, 12]} | " \
                     "#{of(r.lines_counted, r.lines_total)} | #{r.chained ? 'yes' : 'no'} | #{note} |"
            end
            out << ''
            other = runs.count { |r| other_policy?(r) }
            if other.positive?
              out << "Counts below cover every counted run; #{of(other, runs.size)} ran under a policy other than " \
                     'the adopted one.'
              out << ''
            end
          end
          out << "Journals with no chain end record (#{of(no_end.size, journals.size)}): #{list(no_end)}"
          out << "Journals whose recorded digest matches no line (#{of(mismatch.size, journals.size)}): #{list(mismatch)}"
          here = journals.map { |f| File.basename(File.dirname(f)) }
          orphan = chain[:ends].keys.sort - here
          out << "Chain end records for runs with no journal here: #{orphan.size}#{orphan.empty? ? '' : " (#{orphan.join(', ')})"}"
          out << ''
        end

        def other_policy?(run)
          !@adopted.nil? && run.start['policy_digest'] != @adopted.digest
        end

        def list(ids)
          ids.empty? ? 'none' : ids.join(', ')
        end

        def stand_in_section(out, runs)
          out << '## Rule: stand_in may' << ''
          out << adopted_line("Adopted: may #{@adopted&.stand_in_classes.inspect}.")
          out << ''
          governed = []
          reading = Hash.new(0)
          other = Hash.new(0)
          runs.each do |r|
            r.decisions.each do |d|
              point = d['point'].to_s
              if GOVERNED_POINTS.include?(point)
                governed << [r, d, derived_class(d, r.pinned_policy)]
              elsif StandIn::READING_POINTS.include?(point)
                reading[point] += 1
              else
                other[point] += 1
              end
            end
          end
          n = governed.size
          out << "Decision points the policy governs (#{GOVERNED_POINTS.join(', ')}): #{n} in #{runs.size} counted " \
                 "run#{runs.size == 1 ? '' : 's'}."
          out << ''
          out << '| derived class | decisions | the adopted policy |'
          out << '|---|---|---|'
          counts = governed.map(&:last).tally
          (DERIVED_CLASSES + (counts.key?('unclassified') ? ['unclassified'] : [])).each do |c|
            allowed = if c == 'operator_item' then "the operator's"
                      elsif c == 'unclassified' || @adopted.nil? then '—'
                      else @adopted.allows?(c) ? 'allows' : 'does not allow'
                      end
            out << "| #{c} | #{of(counts.fetch(c, 0), n)} | #{allowed} |"
          end
          out << ''
          items = governed.select { |_, _, c| c == 'operator_item' }
          bound = items.count { |_, d, _| no_answer_kind(d) == 'bound' }
          failed = items.count { |_, d, _| no_answer_kind(d) == 'failed' }
          out << "Of the #{items.size} operator_item: #{bound} had no answer because the stand-in call bound was " \
                 "reached, #{failed} because the stand-in's call failed."
          by_point = GOVERNED_POINTS.map { |p| "#{p} #{of(governed.count { |_, d, _| d['point'] == p }, n)}" }
          out << "By point: #{by_point.join(', ')}."
          reading_n = reading.values.sum + other.values.sum
          out << "Not counted here (the stand-in reads material at these points; the policy's classes do not apply): " \
                 "#{StandIn::READING_POINTS.map { |p| "#{p} #{reading[p]}" }.join(', ')}" \
                 "#{other.empty? ? '' : "; other points: #{other.sort.map { |p, k| "#{p} #{k}" }.join(', ')}"} — " \
                 "#{of(reading_n, reading_n + n)} decisions in counted runs."
          out << 'How a class is derived: an answer of class "decided" that cites a precedent it was given is ' \
                 'precedent, one that cites the instruction mode is instruction_mode (in that order, as far as the ' \
                 "run's pinned policy allows each); \"decided_novel\" is novel_reversible; everything else is operator_item."
          out << ''
          acts = governed.flat_map do |r, d, c|
            acts_naming(r.id, d['id']).map { |a| [r, d, c, a] }
          end
          corrections = acts.select { |*, a| a['kind'] == 'correction' }
          corrected = corrections.map { |r, d, *| [r.id, d['id']] }.uniq.size
          out << "Corrections: #{of(corrected, n)} decisions corrected, in #{corrections.size} recorded " \
                 "act#{corrections.size == 1 ? '' : 's'} of kind correction (precedents/raw/operator_acts.jsonl)."
          render_acts(out, corrections)
          others = acts.reject { |*, a| a['kind'] == 'correction' }
          kinds = others.map { |*, a| a['kind'].to_s }.tally
          out << "Other acts naming these decisions: #{kinds.empty? ? 'none' : kinds.sort.map { |k, v| "#{k} #{v}" }.join(', ')}."
          render_acts(out, others)
          out << '' << CAVEAT << ''
        end

        def render_acts(out, acts)
          acts.each do |r, d, c, a|
            out << "- #{r.id} #{d['id']} (#{d['point']}, #{c}; question: \"#{short(d['question'])}\"), " \
                   "#{a['kind']} recorded #{a['at']}:"
            out.concat(quote(a['words']))
          end
        end

        def review_phases(run)
          kinds = %w[review_dispatched review_round review_labelled rounds_extended]
          names = run.entries.select { |e| kinds.include?(e['kind']) }.map { |e| e['phase'].to_s }
          names += run.of_kind('item_opened').select { |e| e['item_kind'] == 'review_open' }.map { |e| e.dig('state_ref', 'ref').to_s }
          order = Array(run.start['phases'])
          names.uniq.reject(&:empty?).sort_by { |p| [order.index(p) || order.size, p] }
        end

        ENDED_BY = { 'closure' => 'closure', 'operator' => 'the operator (freeze)' }.freeze

        # How the review stood at the counted end of its run.
        def ended_by(run, phase)
          state = nil
          run.entries.each do |e|
            next unless e['phase'] == phase

            case e['kind']
            when 'phase_ended'
              state = ENDED_BY.fetch(e['by'].to_s, e['by'].to_s)
              state += ' (provisional)' if e['provisional']
            when 'phase_reopened' then state = nil
            when 'phase_confirmed' then state = 'closure (confirmed)' if state&.start_with?('closure')
            end
          end
          state || 'not ended'
        end

        def review_rounds_section(out, runs)
          out << '## Rule: spend review_rounds' << ''
          out << adopted_line("Adopted: #{@adopted&.spend&.dig(:review_rounds) || '(not set)'} rounds for each review, counted apart.")
          out << ''
          out << "Caps shown are the run's review_rounds plus the rounds granted; a lower cap a plan set for one " \
                 'review is not read (this report evaluates no file from a run directory).'
          out << ''
          rows = runs.flat_map { |r| review_phases(r).map { |ph| [r, ph] } }
          total = rows.size
          rounds = rows.sum { |r, ph| r.of_kind('review_round').count { |e| e['phase'] == ph } }
          out << "Reviews in counted runs: #{total}. Rounds collected: #{rounds} over #{count(total, 'review')}."
          out << ''
          grants = []
          hit_reviews = 0
          hits_all = 0
          frozen = 0
          unless rows.empty?
            out << '| run · review | rounds of cap | cap hits | ended by |'
            out << '|---|---|---|---|'
            rows.each do |r, ph|
              done = r.of_kind('review_round').count { |e| e['phase'] == ph }
              ext = r.of_kind('rounds_extended').select { |e| e['phase'] == ph }
              granted = ext.sum { |e| e['by'].to_i }
              base = r.start.dig('spend', 'review_rounds')&.to_i
              cap = if base then "#{of(done, base + granted)} (#{base}#{granted.positive? ? " + #{granted} granted" : ''})"
                    else "#{done} (no cap)"
                    end
              hits = r.of_kind('item_opened').count { |e| e['item_kind'] == 'review_open' && e.dig('state_ref', 'ref') == ph }
              hit_reviews += 1 if hits.positive?
              hits_all += hits
              frozen += 1 if r.of_kind('phase_ended').any? { |e| e['phase'] == ph && e['by'] == 'operator' }
              out << "| #{r.id} · #{ph} | #{cap} | #{hits} | #{ended_by(r, ph)} |"
              ext.each { |e| grants << [r, ph, e] }
            end
            out << ''
          end
          out << "Reviews that reached their cap: #{of(hit_reviews, total)} (cap hits in all: #{hits_all})."
          out << "Rounds granted (rounds_extended): #{count(grants.size, 'grant')}, " \
                 "#{count(grants.sum { |*, e| e['by'].to_i }, 'round')}, answering #{count(hits_all, 'cap hit')} " \
                 'and any send-backs.'
          grants.each do |r, ph, e|
            render_grant(out, "#{r.id} #{ph}: +#{count(e['by'].to_i, 'round')}", r, e['item'])
          end
          waived = runs.sum { |r| r.of_kind('check_waived').size }
          out << "Frozen by the operator: #{of(frozen, total)} reviews. Checks waived on a review: #{waived}."
          runs.each do |r|
            r.of_kind('phase_ended').select { |e| e['by'] == 'operator' && e['item'] }.each do |e|
              render_grant(out, "#{r.id} #{e['phase']}: frozen", r, e['item'])
            end
            r.of_kind('check_waived').select { |e| e['item'] }.each do |e|
              render_grant(out, "#{r.id} #{e['phase']}: check waived", r, e['item'])
            end
          end
          out << '' << CAP_SIGNAL << '' << CAVEAT << ''
        end

        def stand_in_calls_section(out, runs)
          out << '## Rule: spend stand_in_calls' << ''
          out << adopted_line("Adopted: #{@adopted&.spend&.dig(:stand_in_calls) || '(not set)'} stand-in calls in a run.")
          out << ''
          out << "Unit: each grant is #{CALLS_PER_COUNT} calls per count the actor read from the operator's words " \
                 "(a grant of n counts adds #{CALLS_PER_COUNT} × n calls); the operator's words name a count, not calls."
          out << ''
          out << '| run | calls spent of cap | bound reached |'
          out << '|---|---|---|'
          grants = []
          reached = 0
          runs.each do |r|
            spent = r.decisions.sum { |d| d['calls'].to_i }
            start = r.start.dig('spend', 'stand_in_calls')
            ext = start ? r.of_kind('spend_extended').select { |e| e['counter'] == 'stand_in_calls' } : []
            granted = ext.sum { |e| e['by'].to_i }
            hit = r.decisions.any? { |d| d['reason'] == StandIn::SPENT } || (start && spent >= start.to_i + granted)
            reached += 1 if hit
            cap = start ? "#{of(spent, start.to_i + granted)} (#{start} at start#{granted.positive? ? " + #{granted} granted" : ''})" : "#{spent} (no cap)"
            out << "| #{r.id} | #{cap} | #{hit ? 'yes' : 'no'} |"
            ext.each { |e| grants << [r, e] }
          end
          out << ''
          out << "Runs that reached the bound: #{of(reached, runs.size)}."
          out << "Grants (spend_extended): #{grants.size}, #{grants.sum { |_, e| e['by'].to_i }} calls in all."
          grants.each do |r, e|
            n = e['by'].to_i / CALLS_PER_COUNT
            render_grant(out, "#{r.id}: +#{e['by'].to_i} calls (#{count(n, 'count')} × #{CALLS_PER_COUNT})",
                         r, e['item'])
          end
          out << '' << CAVEAT << ''
        end

        # One act on an item (a grant, a freeze, a waiver), the decision its
        # item was resolved with, and the words of the act that resolved it.
        def render_grant(out, head, run, item)
          res, acts, matched = resolving_acts(run, item)
          tail = if acts.empty? then '; no recorded act names it'
                 elsif matched then ", the resolving act's words:"
                 else ", acts naming it (none matches the resolution's words digest):"
                 end
          out << "- #{head}, decision #{res&.dig('decision') || '(no resolution recorded)'} on #{item}#{tail}"
          acts.each { |a| out.concat(quote(a['words'])) }
        end

        def other_spend_section(out)
          extra = (@adopted&.spend || {}).keys - %i[review_rounds stand_in_calls]
          return if extra.empty?

          out << '## Rule: spend (other keys)' << ''
          out << "#{extra.map { |k| "#{k} #{@adopted.spend[k]}" }.join(', ')}: the SkillSet keeps no counter for " \
                 "#{extra.size == 1 ? 'this key' : 'these keys'} in a run; there is nothing to count."
          out << ''
        end

        def personal_data_section(out, runs)
          out << '## Rule: free_of_personal_data' << ''
          out << adopted_line("Adopted: projects exempt from the data check: #{@adopted&.free_of_personal_data&.then { |l| l.empty? ? '(none)' : l.join(', ') }}.")
          out << ''
          by_project = runs.group_by(&:project)
          out << '| project | exempt | data checks clean | blocking data items |'
          out << '|---|---|---|---|'
          not_clean = 0
          carried = 0
          by_project.keys.sort.each do |project|
            checks = by_project[project].flat_map { |r| r.decisions.select { |d| d['point'] == 'data_check' } }
            # Review#dispatch passes a part only on "clean" from an answer
            # that is not an operator item.
            clean = checks.count { |d| d['answer'].to_s == 'clean' && d['class'] != 'operator_item' }
            not_clean += checks.size - clean
            carried += checks.count { |d| !d['answer'].nil? && d['answer'].to_s != 'clean' && d['class'] != 'operator_item' }
            items = by_project[project].sum do |r|
              r.of_kind('item_opened').count { |e| e['item_kind'] == 'blocking' && e['text'].to_s.include?(DATA_ITEM) }
            end
            exempt = @adopted.nil? ? '—' : (@adopted.free_of_personal_data?(project) ? 'yes' : 'no')
            out << "| #{project} | #{exempt} | #{of(clean, checks.size)} | #{items} |"
          end
          out << ''
          out << "Of the #{count(not_clean, 'data check')} not clean: #{carried} answered that the part carries personal or " \
                 "third-party data, #{not_clean - carried} had no answer or went to the operator."
          out << '' << CAVEAT << ''
        end

        def consent_section(out, runs)
          out << '## Rule: consent review' << ''
          out << adopted_line(@adopted && "Adopted: #{consents_text(@adopted)}.")
          out << ''
          rounds = runs.flat_map { |r| r.of_kind('review_round').map { |e| [r, e] } }
          failed = runs.sum { |r| r.of_kind('review_dispatch_failed').size }
          refused = runs.sum do |r|
            r.of_kind('item_opened').count { |e| e['item_kind'] == 'blocking' && e['text'].to_s.include?(NO_CONSENT) }
          end
          dispatched = runs.sum { |r| r.of_kind('review_dispatched').size }
          out << "Rounds collected: #{of(rounds.size, dispatched)} dispatched, in #{runs.size} counted run" \
                 "#{runs.size == 1 ? '' : 's'}; dispatches that failed: #{failed}; dispatches refused for want of " \
                 "consent: #{refused}."
          out << ''
          rounds.each do |r, e|
            seats = Array(e['seats'])
            named = seats.map { |s| "#{s['seat']} (#{s['verdict']})" }
            out << "- #{r.id} · #{e['phase']} round #{e['round']}: counted #{of(e['counted'].to_i, seats.size)} seats " \
                   "with a reply, quorum #{e['quorum']}: #{named.empty? ? 'none' : named.join(', ')}"
          end
          out << '' unless rounds.empty?
          out << CAVEAT << ''
        end

        def closing_section(out)
          file = @adopted && adopted_file
          out << '## How a policy changes' << ''
          out << "1. Copy the adopted file#{file ? " (#{file})" : ''} under a new file name in #{@paths.policies_dir}, " \
                 'and change the name in its `policy "…"` line to a new name. Of two policies under one name only ' \
                 'the first file by name that parses is ever found: the other can never be adopted, and a refused ' \
                 "adoption names the found file's digest."
          out << '2. Edit the rules in the copy.'
          out << '3. The operator types `adopt policy <name> <first 8 hex digits of the new file\'s SHA-256>` in a ' \
                 'prompt (`shasum -a 256 <file>` shows the digest), and agent_items is called with action adopt_policy.'
          out << ''
          out << "A change a model drafts from this report carries the actor's readings into the mandate. This report " \
                 'never changes a policy.'
        end
      end
    end
  end
end
