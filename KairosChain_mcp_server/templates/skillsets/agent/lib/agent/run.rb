# frozen_string_literal: true

require 'json'
require 'set'
require 'digest'
require 'securerandom'
require 'fileutils'
require_relative 'journal'
require_relative 'dsl'
require_relative 'transcript'
require_relative 'precedents'

module KairosMcp
  module SkillSets
    module Agent
      # Where the agent keeps its state under a data directory. Hook processes
      # build this from KAIROS_DATA_DIR / CLAUDE_PROJECT_DIR; the MCP server
      # from KairosMcp.data_dir. Every path here governs runs (INV-2).
      class Paths
        attr_reader :data_dir

        def initialize(data_dir)
          @data_dir = File.expand_path(data_dir)
        end

        def root
          File.join(@data_dir, 'storage', 'agent')
        end

        # The agent's storage holds the operator's words and journals; a data
        # directory kept in git must not carry them to a remote.
        def ensure_ignored
          FileUtils.mkdir_p(root)
          f = File.join(root, '.gitignore')
          File.write(f, "*\n") unless File.exist?(f)
        rescue SystemCallError
          nil
        end

        def runs_dir
          File.join(root, 'runs')
        end

        def run_dir(run_id)
          File.join(runs_dir, run_id)
        end

        def bindings_dir
          File.join(root, 'bindings')
        end

        def guard_seen_dir
          File.join(root, 'guard_seen')
        end

        def operator_words_path
          File.join(root, 'operator_words.jsonl')
        end

        def precedents_dir
          File.join(root, 'precedents')
        end

        def adoptions_path
          File.join(root, 'policy_adoptions.jsonl')
        end

        # Sessions ever bound to a run, in every instance on this machine, so
        # harvest anywhere can tell stand-in answers from the operator's.
        def self.global_bound_sessions_path
          File.expand_path(ENV['KAIROS_AGENT_GLOBAL'] || '~/.kairos_agent/bound_sessions.txt')
        end

        def policies_dir
          File.join(@data_dir, 'skillsets', 'agent', 'config', 'policies')
        end

        # Paths no run may write, whatever their reversibility (INV-2): the
        # data directory (L0, L1, L2 store, chain, storage, installed
        # SkillSets, instruction mode), the host's settings, hooks, skills
        # and agents, instruction files, and the user-level host config.
        # .claude/worktrees is not governing: run worktrees live there.
        def governing_roots(project_root = File.dirname(@data_dir))
          [@data_dir, File.join(project_root, '.claude'),
           File.join(project_root, '.mcp.json'), File.join(project_root, '.codex'), File.join(project_root, '.git'),
           File.expand_path('~/.claude'), File.expand_path('~/.codex'), File.expand_path('~/.claude.json')]
        end


        # Instruction files the host loads from any directory.
        INSTRUCTION_FILES = %w[CLAUDE.md CLAUDE.local.md AGENTS.md GEMINI.md].freeze
      end

      # A run, reconstructed by replaying its journal (INV-6). Mutations are
      # journal appends; the object is a read model.
      class Run
        ACTIVE = %w[running interrupted].freeze
        # A session whose run another session took over keeps a marker, so
        # its guard refuses instead of falling silent mid-turn.
        TAKEN_OVER = 'taken_over:'

        def self.taken_over?(paths, session_id)
          f = File.join(paths.bindings_dir, safe(session_id))
          File.exist?(f) && File.read(f).start_with?(TAKEN_OVER)
        rescue SystemCallError
          false
        end

        def self.clear_taken_over(paths, session_id)
          f = File.join(paths.bindings_dir, safe(session_id))
          File.delete(f) if taken_over?(paths, session_id)
        rescue SystemCallError
          nil
        end

        attr_reader :id, :journal, :state

        def self.create(paths, goal:, target_repo:, worktree:, branch:, plan:, policy:)
          id = "run_#{Time.now.utc.strftime('%Y%m%d_%H%M%S')}_#{SecureRandom.hex(3)}"
          paths.ensure_ignored
          dir = paths.run_dir(id)
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, 'plan.rb'), plan.source)
          # The policy as adopted, so what the stand-in read stays readable if
          # the file is later edited.
          File.write(File.join(dir, 'policy.rb'), policy.source)
          run = new(paths, id)
          run.journal.append(:run_started,
                             run_id: id, goal: goal, target_repo: target_repo, worktree: worktree,
                             branch: branch, plan_digest: plan.digest, plan_name: plan.name,
                             phases: plan.phase_names.map(&:to_s), policy_name: policy.name,
                             policy_digest: policy.digest,
                             spend: plan.spend.empty? ? policy.spend : policy.spend.merge(plan.spend))
          run.reload
        end

        def self.load(paths, run_id)
          return nil unless File.exist?(File.join(paths.run_dir(run_id), 'journal.jsonl'))

          new(paths, run_id).reload
        end

        def self.all(paths)
          Dir.glob(File.join(paths.runs_dir, '*', 'journal.jsonl')).sort.map do |f|
            new(paths, File.basename(File.dirname(f))).reload
          end
        end

        # The run bound to a session, if the binding is live.
        def self.bound_to(paths, session_id)
          return nil if session_id.to_s.empty?

          f = File.join(paths.bindings_dir, safe(session_id))
          return nil unless File.exist?(f)

          id = File.read(f).strip
          return nil if id.start_with?(TAKEN_OVER)

          run = load(paths, id)
          # After any ending (stop, hazard, waiting, finish) the guard and
          # journal stay until the operator's next typed words (design §8),
          # which unbind; so does SessionEnd.
          run && run.bound_session == session_id && (ACTIVE + %w[ended finished]).include?(run.status) ? run : nil
        end

        # Resumable: anything not finished. A resume in another session takes
        # the binding over; the old session's binding file then no longer
        # matches and its hooks fall inert for this run.
        def resumable?
          %w[running interrupted ended].include?(status)
        end

        def self.safe(name)
          name.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
        end

        # Git's own blob id of a file's bytes, so a pinned test compares with
        # the base commit's tree without one git call per file.
        def self.blob_id(content, algo = 'sha1')
          data = String.new("blob #{content.to_s.bytesize}\0", encoding: Encoding::BINARY) << content.to_s.b
          algo == 'sha256' ? Digest::SHA256.hexdigest(data) : Digest::SHA1.hexdigest(data)
        end

        def self.file_blob_id(path, algo = 'sha1')
          File.file?(path) ? blob_id(File.binread(path), algo) : 'removed'
        end

        def initialize(paths, id)
          @paths = paths
          @id = id
          @journal = Journal.new(File.join(paths.run_dir(id), 'journal.jsonl'))
        end

        def dir
          @paths.run_dir(@id)
        end

        # The plan as pinned: plan.rb lives in the data directory (governing),
        # and its bytes must still match the digest the journal names.
        # An amended plan is kept under plans/<digest>.rb before the journal
        # names it, so no crash leaves the journal naming a missing plan.
        def plan
          amended = plan_digest && File.join(dir, 'plans', "#{plan_digest}.rb")
          path = amended && File.exist?(amended) ? amended : File.join(dir, 'plan.rb')
          plan = DSL.parse_plan(File.read(path))
          raise "plan of #{@id} does not match its pinned digest" if plan_digest && plan.digest != plan_digest

          plan
        end

        def reload
          @state = replay(@journal.entries)
          self
        end

        def append(kind, data = nil, id_prefix: nil, **fields)
          e = @journal.append(kind, (data || {}).merge(fields), id_prefix: id_prefix)
          reload
          e
        end

        # A stand-in decision, with its id allocated by the journal.
        # The stand-in's full evidence and instruction-mode text go to files
        # named by their digest; the journal keeps the digests (INV-3: what
        # the judgment read is recoverable).
        def record_decision(point, question, answer, extra = {})
          h = answer.to_h
          inputs = h['inputs'].is_a?(Hash) ? h['inputs'].dup : nil
          if inputs
            { 'evidence_json' => 'evidence', 'mode_text' => 'mode' }.each do |key, name|
              text = inputs.delete(key)
              next if text.nil?

              sha = Digest::SHA256.hexdigest(text.to_s)
              inputs["#{name}_file"] = keep_input(name, sha, text.to_s)
              inputs["#{name}_sha256"] = sha
            end
            h = h.merge('inputs' => inputs)
          end
          append(:decision, { 'point' => point, 'question' => question.to_s[0, 2000] }.merge(extra).merge(h),
                 id_prefix: 'D')
        end

        def keep_input(name, sha, text)
          d = File.join(dir, 'inputs')
          FileUtils.mkdir_p(d)
          f = File.join(d, "#{name}_#{sha[0, 16]}.txt")
          File.write(f, text) unless File.exist?(f)
          f
        end

        %w[status goal target_repo worktree branch bound_session items decisions phases
           current_phase created_paths pinned spend counters hazard last_progress_seq
           policy_digest plan_digest report last_block_seq operator_words end_reason transcript_path
           bound_history in_flight_review base_commit round_extensions].each do |k|
          define_method(k) { @state[k] }
        end

        def open_items
          items.values.select { |i| i['state'] == 'open' }
        end

        def provisional_closures
          phases.values.select { |p| p['provisional'] }.map { |p| p['name'] }
        end

        # Binding: only after the guard has been seen in that session (INV-6).
        # A binding in another session is taken over: that session's binding
        # file is removed, so its hooks fall inert for this run.
        def bind(session_id, transcript_path: nil, prestart_words: [], kind: :bound)
          raise ArgumentError, 'guard not seen in this session' unless guard_seen?(session_id)

          previous = bound_session
          if previous && previous != session_id
            f = File.join(@paths.bindings_dir, Run.safe(previous))
            File.write(f, "#{TAKEN_OVER}#{@id}:#{session_id}") if File.exist?(f) && File.read(f).strip == @id
          end
          append(kind, session_id: session_id, transcript_path: transcript_path, taken_over_from: previous)
          attach(session_id, transcript_path: transcript_path, prestart_words: prestart_words) if transcript_path
          FileUtils.mkdir_p(@paths.bindings_dir)
          File.write(File.join(@paths.bindings_dir, Run.safe(session_id)), @id)
          register_globally(session_id)
          self
        end

        # The host's transcript and the operator's words typed before the
        # binding, attached once the host reports them (PostToolUse).
        def attach(session_id, transcript_path:, prestart_words: [])
          words = prestart_words.map { |w| Precedents.strip_pasted(w) }.reject(&:empty?)
          append(:transcript_attached, session_id: session_id, transcript_path: transcript_path)
          append(:prestart_words, session_id: session_id, words: words) unless words.empty?
          self
        end

        def unbind(reason, session_id = bound_session)
          append(:unbound, session_id: session_id, reason: reason)
          remove_binding_file(session_id)
          self
        end

        def remove_binding_file(session_id)
          return unless session_id

          f = File.join(@paths.bindings_dir, Run.safe(session_id.to_s))
          File.delete(f) if File.exist?(f) && File.read(f).strip == @id
        end

        # Once every phase has ended (or the run ended early), the run branch
        # waits for the operator's merge; the item exists before the report
        # material is read, so the report names it.
        def ensure_merge_item
          return nil unless branch
          return nil if items.values.any? { |i| i['item_kind'] == 'merge' }
          return nil unless current_phase.nil? || status == 'ended'

          open_item('merge', "merge #{branch} into its base (or delete it); this settles the merge and confirms " \
                             'only the closures the operator names', command: "git merge #{branch}")
        end

        # The operator's words in this run, freshest first: pre-binding words
        # (taken from typed transcript entries at binding) and words during the
        # run that the transcript confirms the operator typed.
        def verified_operator_words(limit: 20)
          pre = @journal.entries.select { |e| e['kind'] == 'prestart_words' }.flat_map { |e| Array(e['words']) }
          (pre + words_during).reject(&:empty?).last(limit).reverse
        end

        # Only words typed while the run was bound, freshest first.
        def typed_words_during(limit: 200)
          words_during.last(limit).reverse
        end

        def words_during
          typed = Hash.new do |h, path|
            h[path] = Transcript.typed_entries(path).map { |e| [e['prompt_id'], e['text'].strip] }
          end
          @journal.entries.select { |e| e['kind'] == 'operator_words' }
                  .select do |e|
                    text = e['text'].to_s.strip
                    typed[e['transcript_path'] || transcript_path].any? do |pid, t|
                      t == text && (e['prompt_id'].nil? || pid == e['prompt_id'])
                    end
                  end
                  .map { |e| Precedents.strip_pasted(e['text']) }.reject(&:empty?)
        end

        def register_globally(session_id)
          path = Paths.global_bound_sessions_path
          FileUtils.mkdir_p(File.dirname(path))
          return if File.exist?(path) && File.foreach(path, encoding: 'UTF-8').any? { |l| l.strip == session_id.to_s }

          File.open(path, 'a') { |f| f.puts(session_id) }
        rescue SystemCallError
          nil
        end

        def guard_seen?(session_id, within: 600)
          f = File.join(@paths.guard_seen_dir, Run.safe(session_id))
          File.exist?(f) && (Time.now - File.mtime(f)) <= within
        end

        def open_item(kind, text, command: nil, ref: nil, detail: nil)
          data = { item_kind: kind, text: text, command: command,
                   state_ref: { 'worktree' => worktree, 'branch' => branch, 'ref' => ref } }
          data[:detail] = detail if detail
          e = append(:item_opened, data, id_prefix: 'I')
          items[e['id']]
        end

        # Items of one kind still open for a phase.
        def open_items_for(phase, kinds)
          open_items.select { |i| kinds.include?(i['item_kind']) && i.dig('state_ref', 'ref') == phase.to_s }
        end

        def within_spend?(counter)
          limit = spend[counter.to_s]
          limit.nil? || counters[counter.to_s].to_i < limit
        end

        def started_at
          @journal.entries.first&.dig('at')
        end

        private

        def replay(entries)
          s = { 'status' => 'new', 'items' => {}, 'decisions' => [], 'phases' => {},
                'created_paths' => [], 'pinned' => {}, 'counters' => Hash.new(0), 'spend' => {},
                'hazard' => nil, 'last_progress_seq' => 0, 'report' => nil, 'round_extensions' => Hash.new(0) }
          entries.each { |e| apply(s, e) }
          s['current_phase'] = s['phase_order'].to_a.find { |n| s['phases'][n]['status'] != 'ended' }
          s
        end

        # Work that moved the run. A refusal, a queued question, or a decision
        # passed to the operator is not progress: a turn made only of those
        # rests instead of being pushed on.
        PROGRESS = %w[item_resolved created pinned check review_dispatched review_round review_labelled phase_ended
                      report_built plan_ratified seat_launched seat_settled].freeze

        FILE_TOOLS = %w[Edit Write MultiEdit NotebookEdit].freeze

        # An outcome follows an effect; a shell call is progress only when it
        # changes the workspace, which the Stop hook sees for itself; a file
        # tool's allowed write is progress. A check is progress when it passes
        # or tests a new commit.
        def progress?(e, s = nil)
          return false if e['kind'] == 'effect_outcome'
          return e['verdict'] != 'refused' && FILE_TOOLS.include?(e['tool']) if e['kind'] == 'effect'
          if e['kind'] == 'check' && s
            return e['ok'] || e['commit'].nil? || e['commit'] != s['last_check_commit']
          end
          return e['class'] != 'operator_item' && !%w[review_labels data_check].include?(e['point']) if e['kind'] == 'decision'

          PROGRESS.include?(e['kind'])
        end

        def apply(s, e)
          s['last_progress_seq'] = e['seq'] if progress?(e, s)
          s['last_check_commit'] = e['commit'] if e['kind'] == 'check' && e['commit']
          case e['kind']
          when 'run_started'
            %w[goal target_repo worktree branch policy_digest plan_digest spend].each { |k| s[k] = e[k] }
            s['status'] = 'running'
            s['phase_order'] = e['phases']
            e['phases'].each { |n| s['phases'][n] = { 'name' => n, 'status' => 'pending', 'rounds' => 0 } }
          when 'bound', 'resumed'
            s['bound_session'] = e['session_id']
            s['transcript_path'] = e['transcript_path'] if e['transcript_path']
            (s['bound_history'] ||= []) << e['session_id']
            s['status'] = 'running' if s['status'] == 'interrupted'
          when 'transcript_attached'
            s['transcript_path'] = e['transcript_path'] if e['transcript_path']
          when 'unbound'
            s['bound_session'] = nil if s['bound_session'] == e['session_id'] || e['session_id'].nil?
          when 'worktree_base'
            s['base_commit'] = e['commit']
          when 'plan_amended'
            s['plan_digest'] = e['digest']
          when 'rounds_extended'
            s['round_extensions'][e['phase']] += e['by'].to_i
          when 'run_reopened'
            s['status'] = 'running'
            s['end_reason'] = nil
            s['report'] = nil
          when 'spend_extended'
            if s['spend'].key?(e['counter'])
              s['spend'] = s['spend'].merge(e['counter'] => s['spend'][e['counter']].to_i + e['by'].to_i)
            end
          when 'decision'
            s['decisions'] << e
            s['counters']['stand_in_calls'] += e['calls'].to_i
          when 'item_opened'
            s['items'][e['id']] = e.merge('state' => 'open')
          when 'item_resolved'
            s['items'][e['id']]&.merge!('state' => 'resolved', 'resolution' => e['resolution'])
          when 'created'
            s['created_paths'] |= [e['path']]
          when 'pinned'
            s['pinned'][e['phase']] = { 'command' => e['command'], 'tests' => e['tests'], 'algo' => e['algo'],
                                        'base' => e['base'] }
          when 'review_dispatched'
            s['counters']['review_rounds'] += 1
            s['in_flight_review'] = e
          when 'review_round', 'review_dispatch_failed'
            s['phases'][e['phase']]['rounds'] = e['round'] if e['kind'] == 'review_round'
            s['in_flight_review'] = nil
          when 'phase_ended'
            s['phases'][e['phase']].merge!('status' => 'ended', 'by' => e['by'],
                                           'provisional' => e['provisional'] ? true : false)
          when 'phase_reopened'
            s['phases'][e['phase']]&.merge!('status' => 'pending', 'by' => nil, 'provisional' => false)
          when 'phase_confirmed'
            s['phases'][e['phase']]&.merge!('provisional' => false, 'confirmed' => true)
          when 'hazard'
            s['hazard'] = e
          when 'interrupted'
            s['status'] = 'interrupted'
            s['bound_session'] = nil
          when 'stop_blocked'
            s['last_block_seq'] = e['seq']
          when 'operator_words', 'prestart_words'
            (s['operator_words'] ||= []).concat(Array(e['words'] || e['text']))
          when 'report_built'
            s['report'] = e
            s['status'] = 'finished'
          when 'item_detail'
            s['items'][e['id']]&.merge!('change_file' => e['change_file'])
          when 'run_ended'
            s['status'] = 'ended' unless s['status'] == 'finished'
            s['end_reason'] = e['reason']
          end
        end
      end
    end
  end
end
