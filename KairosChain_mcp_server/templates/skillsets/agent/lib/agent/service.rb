# frozen_string_literal: true

require 'json'
require 'open3'
require 'digest'
require 'shellwords'
require 'pathname'
require 'time'
require_relative 'run'
require_relative 'dsl'
require_relative 'templates'
require_relative 'policies'
require_relative 'precedents'
require_relative 'review'
require_relative 'confinement'
require_relative 'transcript'
require_relative 'hooks'

module KairosMcp
  module SkillSets
    module Agent
      # The six tools' behaviour (design v0.5.1 §4), with its outside world
      # injected: stand_in_factory(run, policy), invoke(tool, args) for other
      # MCP tools, chain(logs) for the chain record, and run_cmd(argv, chdir,
      # timeout) for git and the confined checks.
      class Service
        KIT_DIR = File.expand_path('../../report_kit', __dir__)
        HARVEST = File.expand_path('../../bin/agent_harvest.rb', __dir__)
        DIFF_LIMIT = 200_000
        GUARD_SEEN_WITHIN = 600

        # The SkillSet's own git reads run in an actor-writable worktree: no
        # hooks, no fsmonitor, no pager, no external diff or text conversion.
        SAFE_GIT = ['-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', '-c', 'core.pager=cat',
                    '-c', 'protocol.allow=never', '-c', 'core.quotePath=false', '--no-pager', '--no-optional-locks'].freeze

        # Test files the check runs, and the runner used when the plan names none.
        TEST_PATTERNS = %w[test_*.rb *_test.rb *_spec.rb test_*.py *_test.py *.test.js *.test.ts *.test.mjs
                           *.spec.js *.spec.ts *_test.go].freeze
        # A test command names a known test runner, or a script the operator's
        # repository already tracks (bin/test); anything else could pass
        # without running a test.
        RUNNERS = %w[ruby bundle rake rails rspec python python3 pytest py.test tox nox node npm npx yarn pnpm jest
                     vitest mocha go cargo make deno bun perl prove php phpunit mvn gradle gradlew dotnet swift julia
                     Rscript R elixir mix ctest playwright ava tap tsx c8 nyc latexmk pandoc typst quarto].freeze
        RUNNERS_MORE = %w[uv poetry conda pipenv hatch pdm rye].freeze
        WRAPPERS = %w[nice time command caffeinate stdbuf ionice chrt taskset nohup timeout env].freeze
        # How each interpreter's options read: letters that run inline code,
        # letters that take a value (attached or the next word), and a letter
        # that hands the rest to a module (python -m pytest …).
        INTERPRETER_FLAGS = {
          'ruby' => { inline: %w[e], value: %w[I r E C x K T W F i], module: [], long_inline: [] },
          'python' => { inline: %w[c], value: %w[W X Q], module: %w[m], long_inline: [] },
          'python3' => { inline: %w[c], value: %w[W X Q], module: %w[m], long_inline: [] },
          'node' => { inline: %w[e p], value: %w[r], module: [], long_inline: %w[--eval --print] },
          'perl' => { inline: %w[e E], value: %w[I M m x C], module: [], long_inline: [] },
          'php' => { inline: %w[r], value: %w[d c z], module: [], long_inline: [] },
          'bun' => { inline: %w[e p], value: [], module: [], long_inline: %w[--eval --print] },
          'deno' => { inline: [], value: [], module: [], long_inline: %w[eval] },
          # rake's words are tasks, not a script; -e/-E/-p/-P run code.
          'rake' => { inline: %w[e E p P], value: %w[f I r R C T D N j], module: [], tasks: true,
                      long_inline: %w[--execute --execute-print --execute-continue] },
          'Rscript' => { inline: %w[e], value: [], module: [], long_inline: [] },
          'julia' => { inline: %w[e E], value: [], module: [], long_inline: %w[--eval --print] },
          'elixir' => { inline: %w[e], value: %w[r], module: [], long_inline: %w[--eval] }
        }.freeze

        # home: the operator's home, for the check of 0.x files outside the
        # instance (nil: not checked).
        def initialize(paths:, project_root:, stand_in_factory:, invoke:, chain:, run_cmd: nil, home: nil)
          @home = home
          @paths = paths
          @project_root = File.expand_path(project_root)
          @stand_in_factory = stand_in_factory
          @invoke = invoke
          @chain = chain
          @run_cmd = run_cmd || method(:default_run_cmd)
        end

        # --- agent_start -------------------------------------------------------

        def start(args)
          sid = args['_session_id']
          return no_hooks_refusal unless hooks_live?(sid)

          if Run.taken_over?(@paths, sid)
            return { 'status' => 'refused',
                     'reason' => 'the run of this session was taken over by another session; nothing more starts here until ' \
                                 'the operator speaks in this session' }
          end
          bound = Run.bound_to(@paths, sid)
          # A finished run's guard waits only for the operator's next words; a
          # new start (which follows them) releases it.
          if bound&.status == 'finished'
            bound.unbind('a new run starts in this session', sid)
            bound = nil
          end
          if bound && bound.id != args['resume']
            how = if bound.status == 'running'
                    'stop it (agent_stop), have its report built and finish it (agent_finish)'
                  else
                    'have its report built and finish it (agent_finish); the operator\'s next words also release it'
                  end
            return { 'status' => 'refused',
                     'reason' => "this session is bound to run #{bound.id} (#{bound.status}); #{how} before starting another" }
          end
          return resume(args['resume'], sid) if args['resume']

          policy = Policies.new(@paths).adopted
          return refusal_without_policy unless policy

          # The repository is the session's project (the hooks name it), not the
          # data directory's parent: several projects may share one data dir.
          begin
            target = Confinement.real(File.expand_path(args['target_repo'] || args['_project_dir'] || @project_root))
          rescue Confinement::Error => e
            return { 'status' => 'refused', 'reason' => "the repository path does not resolve: #{e.message}" }
          end
          template = (args['template'] || 'dev_cycle').to_s
          params = { 'name' => (args['name'] || args['goal'].to_s[0, 40]).to_s.gsub(/[^A-Za-z0-9_]+/, '_').downcase,
                     'goal' => args['goal'], 'design_glob' => args['design_glob'], 'tests' => args['tests'],
                     'output_glob' => args['output_glob'], 'review_as' => args['review_as'],
                     'test_command' => args['test_command'] }.compact
          if (why = test_command_problem(params['test_command'],
                                         Confinement.real(File.expand_path(args['target_repo'] || args['_project_dir'] || @project_root)),
                                         File.dirname(test_root(params['tests'].to_s))))
            return { 'status' => 'refused', 'reason' => why }
          end
          return { 'status' => 'refused', 'reason' => "unknown template #{template} (#{Templates::NAMES.join(', ')})" } unless Templates::NAMES.include?(template)

          begin
            source = Templates.build(template, **params.transform_keys(&:to_sym))
            plan = DSL.parse_plan(source).check_against(policy)
          rescue DSL::Error, ArgumentError => e
            return { 'status' => 'refused', 'reason' => e.message }
          end

          id_hint = Time.now.utc.strftime('%Y%m%d_%H%M%S')
          branch = worktree = base = nil
          if plan.phases.any? { |p| p.kind == :check }
            return { 'status' => 'refused', 'reason' => 'confinement (sandbox-exec) is unavailable on this host' } unless Confinement.available?

            branch = "agent-run/#{id_hint}"
            worktree = File.join(target, '.claude', 'worktrees', "agent-run-#{id_hint}")
            out, ok = @run_cmd.call(['git', *SAFE_GIT, '-C', target, 'worktree', 'add', '-b', branch, worktree, 'HEAD'], target, 120)
            return { 'status' => 'error', 'reason' => "git worktree add failed: #{out.to_s[0, 300]}" } unless ok

            out, ok = @run_cmd.call(['git', *SAFE_GIT, '-C', worktree, 'rev-parse', 'HEAD'], worktree, 30)
            return { 'status' => 'error', 'reason' => "git rev-parse failed: #{out.to_s[0, 300]}" } unless ok

            base = out.to_s.strip
          end
          run = Run.create(@paths, goal: args['goal'], target_repo: target, worktree: worktree, branch: branch,
                                   plan: plan, policy: policy)
          run.bind(sid)
          run.append(:worktree_base, commit: base) if base
          run.append(:plan_parameters, template: template, args: params, source: 'agent_start arguments',
                                       note: 'ruled by the stand-in against the operator\'s words at the first advance')
          FileUtils.mkdir_p(report_dir(run))
          begin
            plan.phases.select { |p| p.kind == :check }.each { |p| pin_tests(run, p) }
          rescue StandardError => e
            run.append(:run_ended, reason: "the test set could not be pinned: #{e.message[0, 200]}")
            return { 'status' => 'error', 'reason' => "the test set could not be pinned: #{e.message[0, 200]}",
                     'run_id' => run.id, 'next' => Guidance.report_step(run.reload) }
          end
          note_empty_precedents(run)
          note_legacy_files(run)
          record_chain('agent_run_start', run)
          run.reload
          out = { 'status' => 'started', 'run_id' => run.id, 'bind' => true, 'worktree' => worktree, 'branch' => branch,
                  'policy' => "#{policy.name} #{policy.digest[0, 12]}", 'open_items' => run.open_items,
                  'next' => Guidance.next_step(run) }
          if worktree
            dirty, = run_process(['git', *SAFE_GIT, '-C', target, 'status', '--porcelain', '--untracked-files=no'], target, 60,
                                 merge: false)
            n = dirty.to_s.lines.size
            if n.positive?
              out['note'] = "the worktree starts from HEAD of #{target}; #{n} uncommitted change(s) in the main checkout " \
                            'are not in it (commit them there first if the run needs them)'
            end
          end
          out
        end

        # Any run without a report can be taken up again, in this session: a
        # running run whose session died, an interrupted one, or an ended one
        # whose report is still to be built.
        def resume(run_id, sid)
          run = Run.load(@paths, run_id.to_s)
          return { 'status' => 'error', 'reason' => "no run #{run_id}" } unless run
          return { 'status' => 'refused', 'reason' => "run #{run_id} is #{run.status}; its report is built" } unless run.resumable?

          from = run.bound_session
          # INV-6: a run whose session is alive is not taken from it.
          if from && from != sid && hooks_live?(from) && Run.bound_to(@paths, from)&.id == run.id
            return { 'status' => 'refused',
                     'reason' => "run #{run.id} is live in another session (its guard was seen in the last " \
                                 "#{GUARD_SEEN_WITHIN / 60} minutes); continue it there, or end that session first" }
          end
          run.bind(sid, kind: :resumed)
          { 'status' => 'resumed', 'run_id' => run.id, 'bind' => true, 'run_status' => run.status,
            'taken_over_from' => (from == sid ? nil : from), 'next' => Guidance.next_step(run.reload) }
        end

        def refusal_without_policy
          ps = Policies.new(@paths).all
          { 'status' => 'refused',
            'reason' => 'No adopted policy. A run needs the operator\'s mandate: the operator adopts a policy by typing ' \
                        '"adopt policy <name> <first 8 hex digits of its digest>", then agent_items(action: "adopt_policy", policy: <name>).',
            'policies' => ps.map { |p| { 'name' => p.name, 'digest' => p.digest, 'type_to_adopt' => "adopt policy #{p.name} #{p.digest[0, 8]}" } } }
        end

        def no_hooks_refusal
          { 'status' => 'refused',
            'reason' => 'the agent hooks are not active in this session, so no guard would watch the run. If the SkillSet ' \
                        'was just installed or upgraded, restart Claude Code so its hooks load. Otherwise start Claude Code ' \
                        'in a project whose .claude carries the agent hooks; a project whose KairosChain data directory is ' \
                        'elsewhere needs KAIROS_DATA_DIR set for the hooks to that directory.' }
        end

        # --- agent_status ------------------------------------------------------

        def status(args)
          return overview unless args['run_id']

          run = Run.load(@paths, args['run_id']) or return { 'status' => 'error', 'reason' => 'no such run' }
          out = { 'status' => run.status, 'summary' => Guidance.summary(run), 'next' => Guidance.next_step(run),
                  'bound_session' => run.bound_session, 'worktree' => run.worktree, 'branch' => run.branch,
                  'open_items' => run.open_items, 'phases' => run.phases.values, 'journal_intact' => run.journal.intact? }
          out['report_material'] = report_material_reply(run) if args['report_material']
          out
        end

        def overview
          pol = Policies.new(@paths)
          { 'adopted_policy' => pol.adopted&.then { |p| "#{p.name} #{p.digest[0, 12]}" },
            'policies' => pol.all.map { |p| { 'name' => p.name, 'digest' => p.digest } },
            'precedent_records' => Precedents.new(@paths.precedents_dir).all.size,
            'runs' => Run.all(@paths).map { |r| { 'run_id' => r.id, 'status' => r.status, 'goal' => r.goal, 'phase' => r.current_phase } } }
        end

        # --- agent_advance -----------------------------------------------------

        def advance(args)
          run = Run.load(@paths, args['run_id'].to_s) or return { 'status' => 'error', 'reason' => 'no such run' }
          if (r = session_refusal(run, args))
            return r
          end
          unless run.status == 'running'
            return { 'status' => 'refused', 'reason' => "run is #{run.status}", 'next' => Guidance.next_step(run) }
          end

          with_advance_lock(run) do
            unless run.current_phase
              run.ensure_merge_item
              return { 'status' => 'all_phases_ended', 'next' => Guidance.report_step(run.reload) }
            end

            policy = policy_for(run)
            stand_in = stand_in_for(run, policy)
            ratify_plan(run, stand_in, policy) unless run.journal.entries.any? { |e| e['kind'] == 'plan_ratified' }
            run.reload
            phase_name = (args['phase'] || run.current_phase).to_s
            if phase_name != run.current_phase.to_s
              return { 'status' => 'error', 'reason' => "phase #{phase_name} is not the current phase #{run.current_phase}" }
            end

            phase = run.plan.phase(phase_name)
            out = case phase.kind
                  when :produce then produce_check(run, phase)
                  when :check then test_check(run, phase, stand_in)
                  when :review then review_step(run, policy, stand_in, phase)
                  end
            run.reload
            run.ensure_merge_item if run.current_phase.nil?
            # A labelled round with open P0s says how to revise; the phase's
            # standing guidance follows it.
            guidance = Guidance.next_step(run.reload)
            out.merge('next' => out['open_p0'] && out['next'] ? "#{out['next']} #{guidance}" : guidance)
          end
        end

        # The actor chose the plan's parameters; the stand-in rules on them
        # against the operator's words and precedent, and its ruling is
        # applied. If it cannot rule, the thorough bounds apply (never lower
        # than the actor's); a test command that passed the runner check stays
        # and is named on an item. A ruling that cannot be applied is recorded
        # as such, so the ratification is not asked again.
        def ratify_plan(run, stand_in, policy)
          ratify_plan!(run, stand_in, policy)
        rescue StandardError => e
          run.open_item('plan_parameters', "the plan ratification failed (#{e.class}: #{e.message[0, 160]}); the plan stands as started")
          run.append(:plan_ratified, answer: nil, error: e.message[0, 300], applied: {})
        end

        # The parameters in force: the actor's start arguments with every
        # amendment since applied in order.
        def effective_params(run)
          pe = run.journal.entries.find { |e| e['kind'] == 'plan_parameters' } || {}
          run.journal.entries.select { |e| e['kind'] == 'plan_amended' }
             .reduce((pe['args'] || {}).dup) { |acc, e| acc.merge(e['changes'] || {}) }
        end

        def ratify_plan!(run, stand_in, policy)
          pe = run.journal.entries.find { |e| e['kind'] == 'plan_parameters' } || {}
          params = effective_params(run)
          # Nothing left to rule on: no test set and no command.
          if params['tests'].to_s.empty? && params['test_command'].nil?
            run.append(:plan_ratified, answer: nil, applied: {}, skipped: 'no test set or command to rule on')
            return
          end
          template = (pe['template'] || run.plan.template).to_s
          a = stand_in.ask(
            point: 'plan_parameters',
            question: "The actor started this run with the plan below (template #{template}). Rule on its parameters " \
                      "against the operator's words and precedent. Answer with a list of any of: \"approve\"; " \
                      '"tests:<directory>" when the tests the run is judged by should be another directory of the ' \
                      'repository (see the candidates); "reject_test_command" when the test command would not run the ' \
                      'tests it is given.',
            options: ['approve', 'tests:<directory>', 'reject_test_command'],
            evidence: { 'plan' => run.plan.source, 'parameters' => params,
                        'test_directory_candidates' => test_dir_candidates(run), 'policy_spend' => policy.spend },
            precedents: precedents(run, "#{run.goal} test command"),
            operator_words: run.verified_operator_words
          )
          d = run.record_decision('plan_parameters', 'plan parameters', a)
          changes = {}
          # Only a plan whose check has a test set may have it moved.
          impl = !params['tests'].to_s.empty?
          unless a.operator_item?
            Array(a.answer).flat_map { |x| x.to_s.split(/[\s,]+/) }.each do |tok|
              if (m = tok.match(/\Atests:(.+)\z/)) && impl && m[1] != params['tests']
                changes['tests'] = m[1]
              elsif tok == 'reject_test_command' && params['test_command']
                changes['test_command'] = nil
              end
            end
          end
          applied = changes.empty? ? {} : amend_plan(run, template, params, changes, policy, d['id'])
          if applied.key?('tests')
            run.plan.phases.select { |p| p.kind == :check }.each { |p| pin_tests(run.reload, p) }
          end
          if a.operator_item?
            run.open_item('plan_parameters', 'the stand-in could not rule on the plan parameters; the plan stands as started' +
                                             (params['test_command'] ? " and the actor's test command `#{params['test_command']}` stays" : ''))
          end
          if applied.key?('test_command')
            run.open_item('plan_parameters', "the stand-in rejected the test command `#{params['test_command']}`; the default " \
                                             'runner applies where there is one. The operator restores it by resolving this item ' \
                                             'with decision restore_test_command.',
                          detail: { 'test_command' => params['test_command'] })
          end
          run.append(:plan_ratified, answer: a.answer, decision: d['id'], applied: applied)
        end

        # Directories of the base tree that hold tests, for the stand-in.
        def test_dir_candidates(run)
          return [] unless run.worktree && run.base_commit

          out, ok = git(run, ['ls-tree', '-r', '-d', '--name-only', run.base_commit])
          return [] unless ok

          out.to_s.lines.map(&:strip).select { |d| File.basename(d) =~ /\A(test|tests|spec|specs|__tests__)\z/ }.first(30)
        rescue StandardError
          []
        end

        # The new plan is written under plans/<digest>.rb before the journal
        # names it (Run#plan reads that file), so a crash between the two
        # leaves the old plan in force, never a missing one.
        def amend_plan(run, template, params, changes, policy, decision_id)
          merged = params.merge(changes).compact
          source = Templates.build(template, **merged.transform_keys(&:to_sym))
          plan = DSL.parse_plan(source).check_against(policy)
          return {} if plan.digest == run.plan_digest

          dir = File.join(run.dir, 'plans')
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, "#{plan.digest}.rb"), source)
          run.append(:plan_amended, digest: plan.digest, from: run.plan_digest, decision: decision_id, changes: changes)
          changes
        rescue DSL::Error, ArgumentError => e
          run.open_item('plan_parameters', "the stand-in's plan change could not be applied: #{e.message}")
          {}
        end

        def produce_check(run, phase)
          mine = created_matching(run, phase.args[:glob])
          unless mine
            return { 'status' => 'not_yet', 'reason' => "no file matching #{phase.args[:glob]} created by this run" }
          end

          run.append(:check, phase: phase.name.to_s, ok: true, artifact: mine, sha256: Digest::SHA256.file(mine).hexdigest)
          run.append(:phase_ended, phase: phase.name.to_s, by: 'check')
          { 'status' => 'phase_ended', 'artifact' => mine }
        end

        # The test set is pinned when the run starts, from the base commit:
        # every file under the tests' directory as the operator's branch had
        # it, by git blob id. Edits made before any advance are still changes.
        # (A glob with no directory before it pins only the files it matches,
        # never the whole repository.)
        def pin_tests(run, phase)
          spec = phase.args[:tests].to_s
          root = test_root(spec)
          out, ok = spec.empty? ? ['', true] : git(run, ['ls-tree', '-r', '-z', '--full-tree', run.base_commit, '--', root])
          raise "git ls-tree failed: #{out.to_s[0, 200]}" unless ok

          # A directory is a test directory: all of it is pinned (helpers and
          # fixtures too). A glob pins only the files it matches, never the
          # source beside them.
          only_glob = spec =~ /[*?\[{]/
          flags = File::FNM_PATHNAME | File::FNM_EXTGLOB
          algo = 'sha1'
          blobs = out.to_s.split("\0").filter_map do |line|
            m = line.match(/\A\d+ blob ([0-9a-f]{40,64})\t(.+)\z/m) or next
            algo = 'sha256' if m[1].length == 64
            [m[2], m[1]]
          end
          matches = lambda do |rel|
            File.fnmatch(spec, rel, flags) || File.fnmatch(spec.sub(%r{\A\*\*/}, ''), rel, flags) ||
              File.fnmatch(spec.sub(%r{/\*\*/}, '/'), rel, flags)
          end
          # With a glob, the helpers beside the matched tests are pinned too
          # (spec_helper, conftest, fixtures, support files).
          # Only in the matched tests' own directories: the conventional helper
          # names, and fixtures/support/factories directories below them.
          # The matched tests' directories and their ancestors up to the glob's
          # own root (spec/models → spec): conventional helper files there,
          # and fixtures/support/factories directories below them.
          top = root == '.' ? [] : root.split('/')
          dirs = blobs.select { |rel, _| matches.call(rel) }.flat_map do |rel, _|
            parts = File.dirname(rel) == '.' ? [] : File.dirname(rel).split('/')
            (top.size..parts.size).map { |n| n.zero? ? '.' : parts.first(n).join('/') }
          end.uniq
          helper = lambda do |rel|
            dir = File.dirname(rel)
            base = File.basename(rel)
            (dirs.include?(dir) && base.match?(/\A((test|spec|rails)_helper\.rb|conftest\.py)\z/)) ||
              dirs.any? { |d| rel.match?(%r{\A#{d == '.' ? '' : "#{Regexp.escape(d)}/"}(fixtures|support|factories)/}) }
          end
          tests = blobs.each_with_object({}) do |(rel, id), h|
            next if only_glob && !(matches.call(rel) || helper.call(rel))

            h[File.join(run.worktree, rel)] = id
          end
          cwd_rel = File.dirname(root)
          (test_command_scripts(phase.args[:command]) + runner_files(phase.args[:command])).uniq.each do |script|
            rel = Pathname.new(File.join(cwd_rel, script.delete_prefix('./'))).cleanpath.to_s
            sout, sok = git(run, ['ls-tree', '-z', '--full-tree', run.base_commit, '--', rel])
            m = sok && sout.to_s.split("\0").first.to_s.match(/\A\d+ blob ([0-9a-f]{40,64})\t/)
            tests[File.join(run.worktree, rel)] = m[1] if m
          end
          run.append(:pinned, phase: phase.name.to_s, command: phase.args[:command], tests: tests, algo: algo,
                              base: run.base_commit, root: root)
        end

        # The check runs the committed state of the run branch, confined. A
        # pinned test changed by any route goes to the stand-in first.
        # item_phase: where items it opens belong (the review phase when the
        # implementation review re-runs the check, so they block that phase).
        def test_check(run, phase, stand_in, recheck: false, item_phase: phase)
          dirty, ok = git(run, ['status', '--porcelain', '--untracked-files=normal'])
          return { 'status' => 'error', 'reason' => "git status failed: #{dirty.to_s[0, 300]}" } unless ok
          unless dirty.to_s.strip.empty?
            return { 'status' => 'refused',
                     'reason' => 'the worktree has uncommitted changes; commit them on the run branch first (the check ' \
                                 'and the review read the committed state); build or test output belongs in a .gitignore ' \
                                 'committed on the run branch, and a tracked file the build rewrote is reverted',
                     'uncommitted' => dirty.to_s.lines.first(20).map(&:rstrip) }
          end
          head = git_head(run)
          pin_tests(run, phase) unless run.pinned[phase.name.to_s]
          return work_check(run, phase, stand_in, head, recheck, item_phase) if phase.args[:tests].to_s.empty?

          pin = run.reload.pinned[phase.name.to_s]
          algo = pin['algo'] || 'sha1'
          ruled = run.journal.entries.select { |e| e['kind'] == 'pinned_change' }
                     .to_h { |e| [Confinement.real(e['path'].to_s), e['digest']] }
          changed = pin['tests'].keys.select do |f|
            now = Run.file_blob_id(f, algo)
            now != pin['tests'][f] && ruled[Confinement.real(f)] != now
          end
          changed.each do |f|
            ruling = rule_pinned_change(run, stand_in, f, algo)
            next if ruling == :approved

            if ruling == :operator
              item = blocking_item(run, item_phase, "a change to pinned test #{f.delete_prefix("#{run.worktree}/")} needs the " \
                                               'operator (decision accept_test_change, or revert it)', detail: { 'paths' => [f] })
              return { 'status' => 'check_refused', 'reason' => "the change to pinned test #{f} is the operator's to rule",
                       'changed' => [f], 'item' => item['id'] }
            end
            return { 'status' => 'check_refused', 'reason' => "the stand-in did not approve the change to pinned test #{f}; " \
                                                              'revert it (git checkout <base> -- <path>) and commit',
                     'changed' => [f] }
          end

          files = test_files(run, phase)
          if files.empty?
            item = blocking_item(run, item_phase, "no test files under #{phase.args[:tests]}: the plan's tests must be corrected by the operator")
            return { 'status' => 'refused', 'item' => item['id'],
                     'reason' => "no test files under #{phase.args[:tests]}: a check that runs nothing proves nothing" }
          end
          plans = files.map { |f| [f, test_argv(phase, f)] }
          if (none = plans.find { |_, argv| argv.nil? })
            item = blocking_item(run, item_phase, "no runner for #{File.basename(none.first)}: the plan needs a test_command")
            return { 'status' => 'refused', 'item' => item['id'],
                     'reason' => "no runner for #{File.basename(none.first)}; the plan needs a test_command" }
          end

          removed = pin['tests'].keys.reject { |f| File.exist?(f) }
          cwd = File.join(run.worktree, File.dirname(test_root(phase.args[:tests])))
          results = plans.map { |f, argv| [f, run_confined(run, argv, cwd)] }
          # A test that already failed on the base commit does not block the
          # run; it is reported as failing before the run.
          preexisting = baseline_failures(run, phase, results.reject { |_, r| r[:ok] }, item_phase)
          failed = results.reject { |f, r| r[:ok] || preexisting.include?(f) }
          run.append(:check, phase: phase.name.to_s, ok: failed.empty?, ran: files.size, failed: failed.map(&:first),
                             failing_before_the_run: preexisting, removed_tests: removed, commit: head, recheck: recheck,
                             tail: tail(failed.first&.last&.dig(:out)))
          unless failed.empty?
            waiting = run.reload.open_items_for(item_phase.name, %w[blocking]).select { |i| i['text'].include?('fails on the base commit') }
            return { 'status' => 'tests_failed', 'commit' => head,
                     'failed' => failed.map { |f, r| { 'file' => f, 'out' => tail(r[:out]) } },
                     'failing_on_the_base_too' => waiting.map { |i| { 'item' => i['id'], 'file' => i.dig('detail', 'file') } } }
          end

          run.append(:phase_ended, phase: phase.name.to_s, by: 'check') unless recheck
          { 'status' => recheck ? 'rechecked' : 'phase_ended', 'ran' => files.size, 'commit' => head, 'removed_tests' => removed,
            'failing_before_the_run' => preexisting }
        end

        # A check with no test set (design v0.6): the work is committed on the
        # run branch, and its command — a build such as latexmk, when the plan
        # names one — succeeds on the committed state, run confined from the
        # worktree root. The command's own scripts are pinned like tests.
        def work_check(run, phase, stand_in, head, recheck, item_phase)
          return { 'status' => 'refused', 'reason' => 'the run branch has no commits yet; commit the work first' } if head == run.base_commit

          pin = run.reload.pinned[phase.name.to_s] || { 'tests' => {} }
          changed = pin['tests'].keys.select { |f| Run.file_blob_id(f, pin['algo'] || 'sha1') != pin['tests'][f] }
          ruled = run.journal.entries.select { |e| e['kind'] == 'pinned_change' }.to_h { |e| [Confinement.real(e['path'].to_s), e['digest']] }
          changed.reject! { |f| ruled[Confinement.real(f)] == Run.file_blob_id(f, pin['algo'] || 'sha1') }
          changed.each do |f|
            ruling = rule_pinned_change(run, stand_in, f, pin['algo'] || 'sha1')
            next if ruling == :approved

            item = blocking_item(run, item_phase, "a change to pinned test (build file) #{f.delete_prefix("#{run.worktree}/")} " \
                                                  'needs the operator (decision accept_test_change, or revert it)', detail: { 'paths' => [f] })
            return { 'status' => 'check_refused', 'reason' => "the change to #{f} is not approved", 'changed' => [f], 'item' => item['id'] }
          end
          result = phase.args[:command] ? run_confined(run, Shellwords.split(phase.args[:command]), run.worktree) : { ok: true, out: '' }
          run.append(:check, phase: phase.name.to_s, ok: result[:ok], ran: phase.args[:command] ? 1 : 0, failed: [],
                             commit: head, recheck: recheck, tail: tail(result[:out]))
          return { 'status' => 'build_failed', 'commit' => head, 'out' => tail(result[:out]) } unless result[:ok]

          run.append(:phase_ended, phase: phase.name.to_s, by: 'check') unless recheck
          { 'status' => recheck ? 'rechecked' : 'phase_ended', 'ran' => phase.args[:command] ? 1 : 0, 'commit' => head }
        end

        # Of the failing test files, those whose failures were already there
        # on the base commit. The whole base tree is extracted to scratch once
        # and each failing file run there, confined. A file is excused only
        # when the failing tests it names now (minitest or pytest names) were
        # all failing on the base too, or when the operator accepted it;
        # otherwise a file that also fails on the base opens an item.
        def baseline_failures(run, phase, failing, item_phase = phase)
          return [] if failing.empty?

          entries = run.journal.entries
          known = entries.select { |e| e['kind'] == 'baseline' }.to_h { |e| [e['file'], e] }
          accepted = entries.select { |e| e['kind'] == 'baseline_accepted' }.map { |e| e['file'] }
          cwd_rel = File.dirname(test_root(phase.args[:tests]))
          base_dir = File.join('/tmp', 'kairos_agent_runs', run.id, 'base')
          tree = File.join(base_dir, 'tree')
          unless File.directory?(tree)
            FileUtils.mkdir_p(tree)
            tar = File.join(base_dir, 'base.tar')
            _, ok = git(run, ['archive', '--format=tar', '-o', tar, run.base_commit], writable: [base_dir], timeout: 600)
            _, ok = run_process(['tar', '-xf', tar, '-C', tree], base_dir, 600, merge: true) if ok
            return [] unless ok
          end
          failing.filter_map do |f, result|
            rel = f.delete_prefix("#{run.worktree}/")
            base = known[rel] || begin
              base_file = File.join(tree, rel)
              r = if File.file?(base_file)
                    argv = test_argv(phase, base_file)
                    argv ? run_confined_in(run, argv, File.join(tree, cwd_rel), [base_dir]) : { ok: true, out: '' }
                  else
                    { ok: true, out: '' } # a test the run added has no baseline
                  end
              run.append(:baseline, file: rel, ok: r[:ok] ? true : false, failing_tests: failing_tests(r[:out]),
                                    commit: run.base_commit)
            end
            next if base['ok']
            next f if accepted.include?(rel)

            now = failing_tests(result[:out])
            before = base['failing_tests']
            next f if now && before && !now.empty? && (now - before).empty?

            blocking_item(run, item_phase, "#{rel} fails on the base commit too, and its failures now cannot be shown to be " \
                                      'only those; the operator decides (decision accept_failing, or freeze)',
                          detail: { 'file' => rel })
            nil
          end
        end

        # Names of failing tests in minitest or pytest output; nil when the
        # output names none.
        def failing_tests(out)
          text = out.to_s
          ids = text.scan(/^\s*\d+\) (?:Failure|Error):\s*\n\s*([A-Za-z_][\w:]*#\S+?)(?=\s|\[|:?$)/).flatten +
                text.scan(/^(?:FAILED|ERROR) (\S+::\S+)/).flatten
          # Only named tests (minitest, pytest) can show that the same tests
          # failed before the run; output without names leaves it to the
          # operator (accept_failing).
          ids.empty? ? nil : ids.uniq
        end

        def blocking_item(run, phase, text, detail: nil)
          run.open_items_for(phase.name, %w[blocking]).find { |i| i['text'] == text } ||
            run.open_item('blocking', text, ref: phase.name.to_s, detail: detail)
        end

        # A pinned test changed by any route (an edit the guard saw, or a shell
        # command it could not read) is ruled on here, against the base.
        def rule_pinned_change(run, stand_in, path, algo)
          rel = path.sub("#{File.expand_path(run.worktree)}/", '')
          old, = git(run, ['cat-file', 'blob', "#{run.base_commit}:#{rel}"])
          now = File.file?(path) ? File.read(path) : '(removed)'
          a = stand_in.ask(point: 'pinned_test_change', options: %w[approve refuse],
                           question: "May the pinned test #{rel} change as shown? Approve only if the design or the " \
                                     "operator's words call for it; weakening a test to pass is refused.",
                           evidence: { 'path' => rel, 'old' => old.to_s[0, 8000], 'new' => now[0, 8000], 'goal' => run.goal },
                           precedents: precedents(run, "test #{File.basename(path)} #{run.goal}"),
                           operator_words: run.verified_operator_words)
          d = run.record_decision('pinned_test_change', rel, a)
          return :operator if a.operator_item?
          return :refused unless a.answer.to_s == 'approve'

          run.append(:pinned_change, path: path, digest: Run.file_blob_id(path, algo), decision: d['id'], by: 'stand-in')
          :approved
        end

        def test_root(tests)
          segs = tests.to_s.split('/').take_while { |s| s !~ /[*?\[{]/ }
          segs.empty? ? '.' : segs.join('/')
        end

        def test_files(run, phase)
          t = phase.args[:tests].to_s
          found = if t =~ /[*?\[{]/
                    Dir.glob(File.join(run.worktree, t)).select do |f|
                      # Without a test command, a glob runs the files that look
                      # like tests (a helper it also matches is not a test).
                      phase.args[:command] || TEST_PATTERNS.any? { |pat| File.fnmatch(pat, File.basename(f)) }
                    end
                  else
                    TEST_PATTERNS.flat_map { |pat| Dir.glob(File.join(run.worktree, t, '**', pat)) }
                  end
          found.select { |f| File.file?(f) }.map { |f| File.expand_path(f) }.uniq.sort
        end

        def test_argv(phase, file)
          return Shellwords.split(phase.args[:command]) + [file] if phase.args[:command]

          case File.basename(file)
          when /\Atest_.*\.rb\z/, /_test\.rb\z/ then ['ruby', '-Ilib', '-Itest', file]
          when /\Atest_.*\.py\z/, /_test\.py\z/ then ['python3', '-m', 'pytest', '-q', file]
          end
        end

        # A test command runs without a shell, one test file appended; it must
        # name a test runner.
        def test_command_problem(cmd, repo = nil, cwd_rel = '.')
          return nil if cmd.nil?

          words = Shellwords.split(cmd.to_s)
          return 'test_command is empty' if words.empty?
          return 'test_command runs without a shell; shell operators do not apply' if words.any? { |w| w =~ /[;&|`<>]|\$\(/ }

          rest = unwrap(words)
          rest = unwrap_runner(rest)
          path = rest.first.to_s
          prog = File.basename(path)
          return 'test_command names no program' if prog.empty?
          if %w[python python3].include?(prog) && (i = rest.index('-m')) && !TEST_MODULES.include?(rest[i + 1])
            return "test_command runs python module #{rest[i + 1]}, not a test runner (#{TEST_MODULES.join(', ')})"
          end
          script_alias = SCRIPT_RUNNERS.include?(File.basename(words.find { |w| RUN_WRAPPERS.key?(File.basename(w)) }.to_s)) &&
                         !path.include?('/') && !INTERPRETER_FLAGS.key?(prog)
          unless RUNNERS.include?(prog) || RUNNERS_MORE.include?(prog) || script_alias ||
                 (path.include?('/') && tracked_script?(repo, path, cwd_rel))
            return "test_command must name a test runner (#{RUNNERS.first(12).join(', ')}, …) or a script the " \
                   "repository tracks, not #{path}"
          end
          flags = INTERPRETER_FLAGS[prog]
          return nil unless flags

          kind, arg = read_interpreter_args(rest.drop(1), flags)
          return "test_command must run the test files, not inline code (#{rest.first(3).join(' ')})" if kind == :inline
          if kind == :script && !tracked_script?(repo, arg, cwd_rel)
            return "test_command runs #{arg}, which the repository does not track; its script would judge the run"
          end

          nil
        rescue ArgumentError => e
          "test_command does not parse: #{e.message}"
        end

        # Runners that run another program: `bundle exec X`, `uv run X` …
        # (the number of words before the program they run).
        RUN_WRAPPERS = { 'bundle' => 1, 'uv' => 1, 'poetry' => 1, 'pipenv' => 1, 'pdm' => 1, 'hatch' => 1, 'rye' => 1,
                         'npx' => 0, 'conda' => 1 }.freeze
        TEST_MODULES = %w[pytest unittest nose2 doctest].freeze

        WRAPPER_VALUE_OPTS = %w[-n --name -p --prefix --with --python --env -e --package].freeze
        # Wrappers whose `run <name>` names a script the project defines.
        SCRIPT_RUNNERS = %w[hatch pdm].freeze

        # The program a runner wrapper runs, with the wrapper, its subcommand
        # and its own options taken off (`uv run --frozen pytest` → pytest).
        def unwrap_runner(rest)
          return rest unless run_wrapper?(rest)

          r = rest.drop(RUN_WRAPPERS[File.basename(rest.first.to_s)].to_i + 1)
          while r.first.to_s.start_with?('-')
            o = r.shift
            r.shift if WRAPPER_VALUE_OPTS.include?(o)
          end
          r
        end

        def run_wrapper?(rest)
          n = RUN_WRAPPERS[File.basename(rest.first.to_s)]
          return false unless n

          n.zero? || %w[exec run].include?(rest[1])
        end

        def unwrap(words)
          rest = words.dup
          rest.shift while rest.first && (WRAPPERS.include?(File.basename(rest.first)) || rest.first.start_with?('-') ||
                                          rest.first =~ /\A\d+[smhd]?\z/ || rest.first =~ /\A[A-Za-z_]\w*=/)
          rest
        end

        # [:inline | :module | :script | :none, script path]
        def read_interpreter_args(args, flags)
          i = 0
          while i < args.size
            w = args[i]
            if w == '--'
              return args[i + 1] ? [:script, args[i + 1]] : [:none, nil]
            elsif w.start_with?('--')
              return [:inline, nil] if flags[:long_inline].include?(w.split('=').first)
            elsif w.start_with?('-') && w.size > 1
              chars = w[1..].chars
              chars.each_with_index do |c, j|
                return [:inline, nil] if flags[:inline].include?(c)
                return [:module, nil] if flags[:module].include?(c)
                next unless flags[:value].include?(c)

                i += 1 if j == chars.size - 1
                break
              end
            else
              return [:none, nil] if flags[:tasks]

              return flags[:long_inline].include?(w) ? [:inline, nil] : [:script, w]
            end
            i += 1
          end
          [:none, nil]
        end

        # Scripts the test command runs (a tracked runner script, or the script
        # an interpreter is given): they judge the run, so they are pinned.
        # Files the runner itself reads to decide what to run.
        # (package.json is not pinned: dependency edits would all become test
        # changes; the test script it defines is a stated residual.)
        RUNNER_FILES = { 'make' => %w[Makefile GNUmakefile], 'rake' => %w[Rakefile],
                         'pytest' => %w[pytest.ini conftest.py], 'tox' => %w[tox.ini],
                         'latexmk' => %w[latexmkrc .latexmkrc], 'quarto' => %w[_quarto.yml] }.freeze
        # Options that point a runner at another configuration file.
        RUNNER_CONFIG_OPTS = { 'make' => %w[-f --file --makefile], 'rake' => %w[-f --rakefile], 'pytest' => %w[-c],
                               'tox' => %w[-c], 'latexmk' => %w[-r] }.freeze

        def runner_files(cmd)
          return [] if cmd.nil?

          words = unwrap_runner(unwrap(Shellwords.split(cmd.to_s)))
          prog = File.basename(words.first.to_s)
          prog = 'pytest' if %w[python python3].include?(prog) && words.each_cons(2).any? { |a, b| a == '-m' && b == 'pytest' }
          named = words.drop(1).each_with_index.filter_map do |w, i|
            opt = RUNNER_CONFIG_OPTS.fetch(prog, []).find { |o| w == o || w.start_with?("#{o}=") || (o.length == 2 && w.start_with?(o) && w.length > 2) }
            next unless opt

            w == opt ? words[i + 2] : w.delete_prefix(opt).delete_prefix('=')
          end
          (named.compact + RUNNER_FILES.fetch(prog, [])).uniq
        rescue ArgumentError
          []
        end

        def test_command_scripts(cmd)
          return [] if cmd.nil?

          rest = unwrap(Shellwords.split(cmd.to_s))
          rest = unwrap_runner(rest)
          out = []
          out << rest.first if rest.first.to_s.include?('/')
          flags = INTERPRETER_FLAGS[File.basename(rest.first.to_s)]
          if flags
            kind, arg = read_interpreter_args(rest.drop(1), flags)
            out << arg if kind == :script
          end
          out
        rescue ArgumentError
          []
        end

        def tracked_script?(repo, path, cwd_rel = '.')
          return false unless repo && path

          [File.join(cwd_rel, path), path].map { |p| Pathname.new(p.delete_prefix('./')).cleanpath.to_s }.uniq.any? do |rel|
            _, ok = run_process(['git', *SAFE_GIT, '-C', repo, 'ls-files', '--error-unmatch', '--', rel], repo, 30, merge: true)
            ok
          end
        end

        def run_confined(run, argv, cwd)
          run_confined_in(run, argv, cwd, [run.worktree])
        end

        def run_confined_in(run, argv, cwd, writable)
          scratch = File.join('/tmp', 'kairos_agent_runs', run.id, 'check')
          full = Confinement.argv(argv, writable: writable, scratch: scratch, worktree: run.worktree,
                                        deny_read: storage_paths, deny_write: git_admin_files(run))
          out, ok = @run_cmd.call(full, cwd, 900)
          { ok: ok, out: out.to_s }
        end

        def review_step(run, policy, stand_in, phase)
          # What is reviewed follows the reviewed phase's kind, not its name:
          # the newest file of a produce phase, or the run branch of a check
          # phase. What a round must have seen to close is that file's digest,
          # or the branch's HEAD.
          target = run.plan.phase(phase.args[:of])
          return { 'status' => 'error', 'reason' => "the plan names no phase #{phase.args[:of]} to review" } unless target

          produce = target.kind == :produce
          type = (phase.args[:as] || (produce ? :design : :implementation)).to_s
          current = if produce
                      -> { (a = latest_artifact(run, target.name.to_s)) && Digest::SHA256.file(a).hexdigest }
                    else
                      -> { git_head(run) }
                    end
          rv = Review.new(run: run, policy: policy, stand_in: stand_in, invoke: @invoke, project_root: run.target_repo,
                          words: -> { run.verified_operator_words }, precedents: ->(t) { precedents(run, t) }, head: current,
                          type: type, revision_diff: ->(before, now) { revision_diff(run, before, now) })
          pending = rv.pending_round(phase.name.to_s)
          return rv.collect(phase, pending) if pending

          unlabelled = rv.unlabelled_round(phase.name.to_s)
          return rv.label_round(phase, unlabelled) if unlabelled

          if produce
            a = latest_artifact(run, target.name.to_s)
            return { 'status' => 'error', 'reason' => "no #{target.name} artifact to review" } unless a

            sha = Digest::SHA256.file(a).hexdigest
            return rv.dispatch(phase, File.basename(a), File.read(a), type,
                               extra: { 'artifact' => a, 'artifact_sha256' => sha, 'commit' => sha })
          end

          # The reviewed code is the tested code: a clean worktree and a passing
          # check on HEAD — unless the operator ended the check phase themselves
          # (a freeze), whose decision the review does not undo. Items the
          # re-run opens belong to this review phase.
          head = git_head(run)
          check_phase = target
          frozen_by_operator = check_phase && (run.phases.dig(check_phase.name.to_s, 'by') == 'operator' ||
                                               run.journal.entries.any? { |e| e['kind'] == 'check_waived' && e['phase'] == phase.name.to_s })
          last_ok = run.journal.entries.reverse.find { |e| e['kind'] == 'check' && e['ok'] && e['commit'] }
          # What a round reviews is the committed state, so nothing may be left
          # uncommitted beside it, whichever way the check stands.
          if !frozen_by_operator && !(last_ok && last_ok['commit'] == head) && check_phase
            r = test_check(run, check_phase, stand_in, recheck: true, item_phase: phase)
            return r unless r['status'] == 'rechecked'
          end
          dirty, ok = git(run, ['status', '--porcelain', '--untracked-files=normal'])
          return { 'status' => 'error', 'reason' => "git status failed: #{dirty.to_s[0, 300]}" } unless ok
          unless dirty.to_s.strip.empty?
            return { 'status' => 'refused', 'reason' => 'the worktree has uncommitted changes; commit them first (build or ' \
                                                        'test output belongs in a .gitignore committed on the run branch, and a tracked file the build rewrote is reverted)',
                     'uncommitted' => dirty.to_s.lines.first(20).map(&:rstrip) }
          end
          diff, ok = git(run, ['diff', '--no-ext-diff', '--no-textconv', run.base_commit, 'HEAD'])
          return { 'status' => 'error', 'reason' => "git diff failed: #{diff.to_s[0, 300]}" } unless ok
          return { 'status' => 'refused', 'reason' => 'the run branch has no commits to review' } if diff.to_s.strip.empty?
          lifted = run.journal.entries.any? { |e| e['kind'] == 'diff_limit_lifted' && e['phase'] == phase.name.to_s }
          if diff.length > DIFF_LIMIT && !lifted
            if run.open_items_for(phase.name, %w[blocking]).none? { |i| i['text'].include?('diff exceeds') }
              run.open_item('blocking', "#{phase.name}: the implementation diff exceeds #{DIFF_LIMIT} characters " \
                                        "(#{diff.length}); how to split the review is the operator's decision", ref: phase.name.to_s)
            end
            return { 'status' => 'refused', 'reason' => "the diff is #{diff.length} characters; above #{DIFF_LIMIT} it is not reviewed in one round" }
          end
          stat, = git(run, ['diff', '--no-ext-diff', '--stat', run.base_commit, 'HEAD'])
          artifact = "## #{type == 'implementation' ? 'Implementation' : 'Work'} under review\n\nBranch #{run.branch}, #{run.base_commit[0, 12]}..#{head[0, 12]}\n\n" \
                     "### Files\n\n```\n#{stat}```\n\n### Diff\n\n```diff\n#{diff}\n```\n" + review_context(run, head)
          rv.dispatch(phase, "#{run.branch} #{run.base_commit[0, 8]}..#{head[0, 8]}", artifact, type,
                      extra: { 'commit' => head })
        end

        # What the actor changed between two rounds: the two versions of a
        # produced file, or the commits between the two reviewed HEADs.
        def revision_diff(run, before, now)
          if before['artifact'] && now['artifact']
            return '' unless File.file?(before['artifact'].to_s) && File.file?(now['artifact'].to_s)

            out, = run_process(['/usr/bin/diff', '-u', before['artifact'], now['artifact']], run.target_repo, 60, merge: true)
            out.to_s
          elsif before['commit'] && now['commit'] && before['commit'] != now['commit']
            out, ok = git(run, ['diff', '--no-ext-diff', '--no-textconv', before['commit'], now['commit']])
            ok ? out.to_s : ''
          else
            ''
          end
        rescue StandardError
          ''
        end

        FULL_FILES_LIMIT = 150_000

        # What implementation seats also read (L1 multi_llm_review_workflow:
        # implementation seats see the source): the design the run's own review
        # closed, and the full text of the changed files, within a bound; files
        # left out are named.
        def review_context(run, head)
          parts = []
          run.plan.phases.select { |p| p.kind == :produce }.each do |p|
            next unless (d = latest_artifact(run, p.name.to_s))

            parts << "## The #{p.name} this work follows (#{File.basename(d)})\n\n#{File.read(d)[0, 60_000]}"
          end
          names, = git(run, ['diff', '--no-ext-diff', '--name-only', '--diff-filter=AM', '-z', run.base_commit, head])
          budget = FULL_FILES_LIMIT
          left = []
          files = names.to_s.split("\0").reject(&:empty?).filter_map do |rel|
            body, ok = git(run, ['cat-file', 'blob', "#{head}:#{rel}"])
            next left << rel unless ok && body.valid_encoding? && !body.include?("\0") && body.length <= budget

            budget -= body.length
            "### #{rel}\n\n```\n#{body}\n```"
          end
          parts << "## Changed files in full\n\n#{files.join("\n\n")}" unless files.empty?
          parts << "Not included (size or binary): #{left.join(', ')}" unless left.empty?
          parts.empty? ? '' : "\n---\n\n#{parts.join("\n\n---\n\n")}\n"
        end

        def latest_artifact(run, phase_name)
          e = run.journal.entries.reverse.find { |x| x['kind'] == 'check' && x['phase'] == phase_name && x['artifact'] }
          created_matching(run, run.plan.phase(phase_name).args[:glob].to_s) || e&.dig('artifact')
        end

        # The newest file matching the glob that this run created; paths are
        # compared resolved, as the guard records them.
        def created_matching(run, glob)
          created = run.created_paths.reject { |p| p.start_with?('l2:') }.map { |p| Confinement.real(p) }
          Dir.glob(File.join(run.target_repo, glob)).select { |f| created.include?(Confinement.real(f)) }
             .max_by { |f| File.mtime(f) }
        end

        # --- agent_items -------------------------------------------------------

        def items(args)
          case args['action']
          when 'list', nil then list_items(args)
          when 'adopt_policy' then adopt_policy(args)
          when 'alert' then alert(args)
          when 'confirm', 'correct', 'resolve' then operator_act(args)
          else { 'status' => 'error', 'reason' => "unknown action #{args['action']}" }
          end
        end

        def list_items(args)
          run = Run.load(@paths, args['run_id'].to_s) or return { 'status' => 'error', 'reason' => 'no such run' }
          { 'open_items' => run.open_items,
            'decisions' => run.decisions.map { |d| d.slice('id', 'point', 'question', 'answer', 'class', 'confidence', 'reason') } }
        end

        def adopt_policy(args)
          pol = Policies.new(@paths)
          name = args['policy'].to_s
          policy = pol.find(name) or return { 'status' => 'error', 'reason' => "no policy #{name}" }
          cand = recent_operator_words.reverse.find { |w| w['text'].include?(name) && w['text'].include?(policy.digest[0, 8]) }
          return { 'status' => 'refused', 'reason' => "no typed sentence naming #{name} and #{policy.digest[0, 8]} found" } unless cand

          pol.adopt(name, words: cand['text'], transcript_path: cand['transcript_path'], prompt_id: cand['prompt_id'],
                          record: ->(entry) { @chain.call([JSON.generate('type' => 'agent_policy_adoption', 'entry' => entry)]) })
          { 'status' => 'adopted', 'policy' => name, 'digest' => policy.digest }
        rescue ArgumentError => e
          { 'status' => 'refused', 'reason' => e.message }
        end

        def alert(args)
          run = Run.load(@paths, args['run_id'].to_s) or return { 'status' => 'error', 'reason' => 'no such run' }
          if (r = session_refusal(run, args))
            return r
          end
          return { 'status' => 'refused', 'reason' => "run is #{run.status}; tell the operator directly" } unless run.status == 'running'

          policy = policy_for(run)
          text = args['text'].to_s
          ruling, a = stand_in_for(run, policy)
                      .rule_hazard(text, evidence: { 'alert' => text }, precedents: precedents(run, text),
                                         operator_words: run.verified_operator_words)
          run.record_decision('hazard', text[0, 1000], a)
          case ruling
          when 'in_world', 'uncertain', 'not_ruled'
            # INV-4: present in the world, or the stand-in cannot rule.
            run.append(:hazard, ruling: ruling, text: text)
            run.append(:run_ended, reason: "hazard (#{ruling})")
            run.ensure_merge_item
            { 'status' => 'run_ended', 'ruling' => ruling, 'next' => Guidance.report_step(run.reload) }
          else
            item = run.open_item('finding', "raised hazard ruled #{ruling}: #{text[0, 300]}")
            { 'status' => 'continue', 'ruling' => ruling, 'item' => item['id'] }
          end
        end

        # A confirmation, correction or resolution is the operator's only when
        # the operator's own typed words name the item or decision (INV-5). The
        # kind is the actor's reading of those words; the words are kept whole.
        def operator_act(args)
          run = Run.load(@paths, args['run_id'].to_s) or return { 'status' => 'error', 'reason' => 'no such run' }
          ref = args['ref'].to_s
          words = typed_words_naming(run, ref)
          return { 'status' => 'refused', 'reason' => "no typed operator words naming #{ref} for run #{run.id}" } unless words

          kind = { 'confirm' => 'confirmation', 'correct' => 'correction', 'resolve' => 'ruling' }[args['action']]
          target = run.decisions.find { |d| d['id'] == ref } || run.items[ref]
          Precedents.new(@paths.precedents_dir).add([{ 'source' => "run #{run.id} #{ref}", 'project' => File.basename(run.target_repo.to_s),
                                                       'at' => Time.now.utc.iso8601, 'kind' => kind, 'kind_by' => 'actor reading',
                                                       'question' => (target && (target['question'] || target['text'])).to_s,
                                                       'words' => words, 'ref' => ref }], file: 'operator_acts.jsonl')
          out = { 'status' => 'recorded', 'ref' => ref, 'kind' => kind }
          item = run.items[ref]
          return out unless item && item['state'] == 'open'

          decision = args['decision'].to_s
          allowed = decisions_for(item)
          # What a phase waits on changes only by an explicit decision the
          # actor read in the operator's words, and the words must say it;
          # anything else is recorded and leaves the item open.
          if allowed
            # A plain resolve or confirm settles an item; a correction of a
            # closure needs its decision (send_back).
            plain = allowed.include?('') && %w[resolve confirm].include?(args['action']) && decision.empty?
            unless plain || (!decision.empty? && allowed.include?(decision))
              return out.merge('item_open' => true, 'reason' => "#{ref} stays open: resolving it needs a decision " \
                                                                "(#{(allowed - ['']).join(' | ')}) from the operator's words")
            end
            if !decision.empty? && !says?(words, ref, decision)
              return out.merge('item_open' => true, 'reason' => "the operator's words naming #{ref} do not say #{decision}")
            end
          end

          phase = item.dig('state_ref', 'ref')
          restore_test_command(run, item) if decision == 'restore_test_command' && item.dig('detail', 'test_command')
          run.append(:item_resolved, id: ref, resolution: args['action'], words_sha256: Digest::SHA256.hexdigest(words),
                                     decision: decision.empty? ? nil : decision)
          # The count the operator's words give (one when they give none); the
          # actor's argument cannot raise it.
          n = [[args['rounds'].to_i, 1].max, words_count(words, ref)].min
          if item['item_kind'] == 'closure' && decision.empty? && phase
            run.append(:phase_confirmed, phase: phase, item: ref)
          end
          case decision
          when 'more_rounds'
            run.append(:rounds_extended, phase: phase, by: n, item: ref)
          when 'accept_failing'
            run.append(:baseline_accepted, file: item.dig('detail', 'file'), item: ref)
          when 'review_whole'
            run.append(:diff_limit_lifted, phase: phase, item: ref)
          when 'accept_test_change'
            algo = run.pinned.values.first&.dig('algo') || 'sha1'
            Array(item.dig('detail', 'paths')).each do |f|
              digest = item.dig('detail', 'digests', f) || Run.file_blob_id(f, algo)
              run.append(:pinned_change, path: f, digest: digest, by: 'operator', item: ref)
            end
          when 'freeze'
            if check_item_on_review?(run, item)
              # The operator accepts the check as it stands; the review goes on.
              run.append(:check_waived, phase: phase, item: ref, commit: (git_head(run) rescue nil))
            elsif phase && run.phases.dig(phase, 'status') != 'ended'
              freeze_by_operator(run.reload, phase, ref)
            end
          when 'more_calls'
            if run.spend.key?('stand_in_calls')
              run.append(:spend_extended, counter: 'stand_in_calls', by: 50 * n, item: ref)
            end
          when 'send_back'
            # The phase sent back and every phase after it are worked again;
            # each reopened review gets the rounds, and its closure item is
            # superseded.
            order = run.plan.phase_names.map(&:to_s)
            order.drop(order.index(phase) || order.size).each do |ph|
              next unless run.reload.phases.dig(ph, 'status') == 'ended'

              run.append(:phase_reopened, phase: ph, item: ref)
              next unless run.plan.phase(ph).kind == :review

              run.append(:rounds_extended, phase: ph, by: n, item: ref)
              run.open_items_for(ph, %w[closure]).each do |c|
                run.append(:item_resolved, id: c['id'], resolution: "superseded: #{phase} was sent back (#{ref})")
              end
            end
          end
          reopen_if_unblocked(run.reload, ref, args['_session_id'], sent_back: decision == 'send_back')
          out.merge('run_status' => run.reload.status, 'next' => Guidance.next_step(run))
        end

        # Words that must appear in the operator's own words, in the sentence
        # that names the item, for the decision the actor read in them. The
        # decision's own name counts. A sentence that negates is refused.
        A = '(?<![A-Za-z])'
        Z = '(?![A-Za-z])'
        DECISION_WORDS = {
          'freeze' => /凍結|#{A}freeze#{Z}|確定|閉じ|止め|打ち切|終わり|これで(いい|良い|OK)|進め|先へ|続行/i,
          'more_rounds' => /周|#{A}rounds?#{Z}|もう(一|1|１|\d|[二三四五])|あと(一|1|１|\d|[二三四五])|続け|回し|まわし|追加/i,
          'more_calls' => /#{A}calls?#{Z}|呼び|回数|増や|追加/i,
          'review_whole' => /全部|全体|丸ごと|まとめて|#{A}whole#{Z}|そのまま/i,
          'restore_test_command' => /戻|#{A}restore#{Z}|元に/i,
          'accept_test_change' => /認め|承認|#{A}accept#{Z}|許可|#{A}OK#{Z}|いい|良い/i,
          'accept_failing' => /認め|承認|#{A}accept#{Z}|許可|#{A}OK#{Z}|いい|良い|そのまま/i,
          'send_back' => /差し戻|やり直|send.?back|戻し|もう(一|1|１)/i
        }.freeze
        # A decision word negated where it stands: "凍結しないで", "差し戻さないで",
        # "承認しません", "don't freeze". ("問題ないので確定" still says 確定.)
        NEGATED_AFTER = /\A\p{Hiragana}{0,2}?(ない|ません|ないで|ず|ずに|なくて)|\A.{0,4}(やめ|不要|だめ|ダメ)/
        NEGATED_BEFORE = /(don'?t|do not|not|never|no)\s*\z|(やめ|不要)\s*\z/i

        REF_PATTERN = /(?<![A-Za-z0-9])[DI]\d+(?![0-9A-Za-z])/

        # The words about one item: from the sentence that names it, the part
        # from that name up to the next item's name ("I5 は凍結しないで、I6 は
        # 凍結" gives I6 only "I6 は凍結").
        def clause_naming(own, ref)
          mine = /(?<![A-Za-z0-9])#{Regexp.escape(ref)}(?![0-9])/
          sentence = own.split(/[。．.!?！？\n]/).find { |c| c.match?(mine) } || own
          start = sentence.index(mine) || 0
          rest = sentence[start..]
          after = rest.sub(mine, '')
          nxt = after.index(REF_PATTERN)
          head = sentence[0...start].split(/[、，,]/, -1).last.to_s
          head = '' if head.match?(REF_PATTERN)
          head + (nxt ? rest[0, rest.length - after.length + nxt].sub(/[、，,]\s*\z/, '') : rest)
        end

        def says?(words, ref, decision)
          own = Precedents.strip_pasted(words)
          clause = clause_naming(own, ref)
          pattern = Regexp.union(/#{Regexp.escape(decision)}/i, DECISION_WORDS.fetch(decision, /(?!)/))
          matches = clause.to_enum(:scan, pattern).map { Regexp.last_match }
          matches.any? do |m|
            after = clause[m.end(0), 8].to_s
            before = clause[[m.begin(0) - 8, 0].max...m.begin(0)].to_s
            !(after.match?(NEGATED_AFTER) || before.match?(NEGATED_BEFORE) || (m[0] == 'いい' && after.start_with?('え')))
          end
        end

        KANJI_DIGITS = { '一' => 1, '二' => 2, '三' => 3, '四' => 4, '五' => 5 }.freeze

        # The count the clause naming the item gives ("あと 2 周", "もう二回"), or 1.
        def words_count(words, ref)
          own = Precedents.strip_pasted(words)
          clause = clause_naming(own, ref)
          clause = clause.gsub(/(?<![A-Za-z0-9])#{Regexp.escape(ref)}(?![0-9])/, '')
          m = clause.match(/(\d+)\s*(周|回|rounds?|calls?)/i) || clause.match(/([一二三四五])\s*(周|回)/)
          return 1 unless m

          [KANJI_DIGITS[m[1]] || m[1].to_i, 1].max
        end

        CHECK_ITEM = /fails on the base commit|pinned test|no test files|no runner/

        def check_item_on_review?(run, item)
          ph = item.dig('state_ref', 'ref')
          ph && run.plan.phase(ph)&.kind == :review && item['text'].to_s.match?(CHECK_ITEM)
        end

        # The decisions an item accepts ('' = a plain resolve), or nil when a
        # resolution changes nothing the run waits on.
        def decisions_for(item)
          text = item['text'].to_s
          case item['item_kind']
          when 'review_open' then %w[freeze more_rounds]
          when 'closure' then ['', 'send_back']
          when 'pinned_test_change' then ['', 'accept_test_change']
          when 'plan_parameters' then ['', 'restore_test_command']
          when 'blocking'
            if text.include?('diff exceeds') then %w[review_whole freeze]
            elsif text.include?('stand-in call') then %w[more_calls freeze]
            elsif text.include?('pinned test') then %w[accept_test_change freeze]
            elsif text.include?('fails on the base commit') then %w[accept_failing freeze]
            else ['', 'freeze']
            end
          end
        end

        # The operator ends a review or check phase: its open P0s — those of
        # the last labelled round and those a later, unlabelled round's
        # review tool extracted — are carried like a freeze's, and the ending
        # is the operator's, not provisional.
        def freeze_by_operator(run, phase, ref)
          entries = run.journal.entries
          last = entries.reverse.find { |e| e['kind'] == 'review_labelled' && e['phase'] == phase }
          carried = Array(last && last['labels']).select { |l| l['open'] }
                                                 .map { |o| { 'finding' => o['id'], 'seat' => o['seat'], 'text' => o['text'] } }
          latest = entries.reverse.find { |e| e['kind'] == 'review_round' && e['phase'] == phase }
          if latest && (last.nil? || latest['round'] > last['round'])
            p0_lines = (JSON.parse(File.read(latest['replies_file'].to_s))['p0_lines'] rescue [])
            Array(p0_lines).each_with_index do |t, i|
              carried << { 'finding' => "#{phase} round #{latest['round']} P0 #{i + 1}", 'seat' => '(unlabelled round)', 'text' => t }
            end
          end
          carried.each do |c|
            run.open_item('carried_p0', "#{phase}: #{c['seat']}: #{c['text'].to_s[0, 300]}", ref: phase, detail: c)
          end
          run.append(:phase_ended, phase: phase, by: 'operator', provisional: false, item: ref)
        end

        # The rejected command comes back into the parameters in force (the
        # ratified rounds and tests stay).
        def restore_test_command(run, item)
          pe = run.journal.entries.find { |e| e['kind'] == 'plan_parameters' } || {}
          params = effective_params(run)
          changed = amend_plan(run, (pe['template'] || run.plan.template).to_s, params,
                               { 'test_command' => item.dig('detail', 'test_command') }, policy_for(run), item['id'])
          # The restored command's own scripts and files are pinned again.
          run.reload.plan.phases.select { |ph| ph.kind == :check }.each { |ph| pin_tests(run, ph) } unless changed.empty?
        end

        # A run that ended only because it waited on the operator — even one
        # whose report is built — continues once the operator's words clear
        # what it waited on; a closure sent back reopens it too. Its earlier
        # report is kept beside the new one. It continues in the session whose
        # words reopened it, if that session's guard is live and the session
        # holds no other run.
        def reopen_if_unblocked(run, ref, sid = nil, sent_back: false)
          return unless %w[ended finished].include?(run.status) && run.current_phase
          return if run.hazard
          return unless sent_back || run.end_reason == 'waiting on operator items'
          return if run.open_items_for(run.current_phase, %w[blocking review_open]).any?

          deck = File.join(report_dir(run), 'deck.html')
          if run.report && File.exist?(deck)
            n = Dir.glob(File.join(report_dir(run), 'deck_*.html')).size + 1
            File.rename(deck, File.join(report_dir(run), "deck_#{n}.html"))
          end
          run.append(:run_reopened, by: ref)
          run.reload
          old = run.bound_session
          held = hooks_live?(sid) ? Run.bound_to(@paths, sid) : :not_live
          free = held.nil? || (held.is_a?(Run) && held.id == run.id)
          # The run had ended, so its old session is not working it: the
          # resolving session takes it (the old one keeps a taken-over marker).
          if free
            run.bind(sid, kind: :resumed)
          elsif old && old != sid
            # Neither session can take it now: the old one keeps a marker that
            # refuses acting, and the run waits for agent_start(resume:).
            run.unbind('reopened from another session', old)
            f = File.join(@paths.bindings_dir, Run.safe(old))
            File.write(f, "#{Run::TAKEN_OVER}#{run.id}:reopened")
          end
        rescue ArgumentError
          nil
        end

        # Words naming the ref: typed during the run (the transcript confirms
        # them), or typed after the run started in a session that was bound to
        # it, or in any session if they also name the run. Pasted host output
        # is set aside before the ref is looked for.
        def typed_words_naming(run, ref)
          return nil if ref.empty?

          pattern = /(?<![A-Za-z0-9])#{Regexp.escape(ref)}(?![0-9])/
          during = run.typed_words_during.find { |t| t =~ pattern }
          return during if during

          sessions = Array(run.bound_history)
          started = run.started_at
          recent_operator_words.reverse_each do |x|
            # (Times may be kept to the second: a second's allowance.)
            next if started && (Time.parse(x['at'].to_s) rescue Time.at(0)) < (Time.parse(started) rescue Time.at(0)) - 1

            own = Precedents.strip_pasted(x['text'].to_s)
            next unless own =~ pattern
            next unless sessions.include?(x['session_id']) || own.include?(run.id) || own.include?(run.id[-6..])

            return own if Transcript.typed_prompt?(x['transcript_path'], prompt_id: x['prompt_id'], text: x['text'].to_s)
          end
          nil
        end

        def recent_operator_words
          return [] unless File.exist?(@paths.operator_words_path)

          File.readlines(@paths.operator_words_path, chomp: true, encoding: 'UTF-8').last(500).filter_map { |l| JSON.parse(l) rescue nil }
        end

        # --- agent_finish / agent_stop -------------------------------------------

        def finish(args)
          run = Run.load(@paths, args['run_id'].to_s) or return { 'status' => 'error', 'reason' => 'no such run' }
          if run.report
            return { 'status' => 'finished', 'already' => true, 'report' => run.report['path'], 'open_items' => run.open_items }
          end
          if (r = session_refusal(run, args))
            return r
          end
          if run.status == 'running' && run.current_phase
            return { 'status' => 'refused', 'reason' => "phase #{run.current_phase} has not ended by its check or closure" }
          end
          run.ensure_merge_item

          deck = File.join(report_dir(run), 'deck.html')
          return { 'status' => 'refused', 'reason' => "no report at #{deck}", 'next' => Guidance.report_step(run) } unless File.exist?(deck)

          missing = completeness(run.reload, File.read(deck))
          return { 'status' => 'refused', 'reason' => 'the report omits journal entries', 'missing' => missing } unless missing.empty?

          unless built_by_subagent?(run, deck)
            return { 'status' => 'refused',
                     'reason' => 'the report must be built by a subagent (Agent tool, not a fork), not by the acting context' }
          end
          issues = kit_check(deck)
          if (n = issues[/issues=(\d+)/, 1]) && n.to_i.positive?
            return { 'status' => 'refused', 'reason' => "the kit's check found #{n} issues; fix them and check again", 'checker' => issues }
          end

          run.append(:run_ended, reason: 'finished') unless run.status == 'ended'
          run.append(:report_built, path: deck, checker: issues, built_by_subagent: true,
                                    checker_unavailable: issues.start_with?('unchecked'))
          # The guard and journal stay until the operator's next typed words
          # (design §8); UserPromptSubmit unbinds then.
          record_chain('agent_run_end', run)
          { 'status' => 'finished', 'report' => deck, 'checker' => issues, 'open_items' => run.reload.open_items }
        end

        def stop(args)
          run = Run.load(@paths, args['run_id'].to_s) or return { 'status' => 'error', 'reason' => 'no such run' }
          return { 'status' => 'refused', 'reason' => 'the run is finished' } if run.report
          if (r = session_refusal(run, args))
            return r
          end
          run.append(:run_ended, reason: "stopped: #{args['reason']}") unless run.status == 'ended'
          run.ensure_merge_item
          # A round that will never collect closes its persona seats now, so
          # its launches do not keep the seat refusals on after the run. A
          # close that fails is journaled; the stop stands.
          Seats.live_dispatches(run.journal.entries).each do |d|
            Seats.settle_remaining(run, d['token'])
          rescue StandardError => e
            run.append(:seats_close_failed, phase: d['phase'], round: d['round'], token: d['token'],
                                            reason: "#{e.class}: #{e.message[0, 300]}")
          end
          { 'status' => 'stopped', 'next' => Guidance.report_step(run.reload) }
        end

        def completeness(run, html)
          ids = run.decisions.map { |d| d['id'] } + run.items.keys + run.phases.keys
          ids.compact.reject { |id| html.match?(/(?<![A-Za-z0-9_])#{Regexp.escape(id)}(?![A-Za-z0-9_])/) }
        end

        # The report's bytes were last changed by a subagent. The hooks record
        # the deck's digest after every effect; the last change must carry an
        # agent id and the deck must still be what that effect left. Without
        # such records, the last write effect into the report directory counts.
        def built_by_subagent?(run, deck)
          seen = run.journal.entries.select { |e| e['kind'] == 'effect_outcome' && e.key?('deck_sha256') }
          unless seen.empty?
            prev = nil
            changed_by = nil
            seen.each do |o|
              changed_by = o if o['deck_sha256'] != prev
              prev = o['deck_sha256']
            end
            current = File.file?(deck) ? Digest::SHA256.file(deck).hexdigest : nil
            return prev == current && changed_by['agent_id'].to_s != ''
          end
          built_by_subagent_effects?(run, deck)
        end

        def built_by_subagent_effects?(run, deck)
          dir = Confinement.real(File.dirname(deck))
          writes = run.journal.entries.select do |e|
            e['kind'] == 'effect' && e['verdict'] != 'refused' &&
              ((e['path'] && Confinement.real(File.expand_path(e['path'].to_s)).start_with?("#{dir}/")) ||
               writes_report?(e['command'].to_s, run))
          end
          !writes.empty? && writes.last['agent_id'].to_s != ''
        end

        # A shell command that writes into the report directory (the kit's
        # generator, a redirect, a copy); reading it (ls, cat, check.py) does not.
        def writes_report?(command, run)
          return false unless command.include?(File.join('agent_runs', run.id))

          command.include?('make_report_deck.py') ||
            command.match?(/>\s*\S*agent_runs|\b(cp|mv|tee|rsync|install)\b|\bsed\s+-i/)
        end

        def kit_check(deck)
          checker = File.join(KIT_DIR, 'check.py')
          return 'unchecked: kit missing' unless File.exist?(checker)

          # The deck is the actor's side's HTML: the checker's browser opens it
          # confined, writing only the report directory and scratch.
          argv = ['python3', checker, deck]
          if Confinement.available?
            argv = Confinement.argv(argv, writable: [File.dirname(deck)],
                                          scratch: File.join('/tmp', 'kairos_agent_report_check', File.basename(File.dirname(deck))),
                                          deny_read: storage_paths)
          end
          out, ok = @run_cmd.call(argv, File.dirname(deck), 300)
          return "unchecked: #{tail(out, 200)}" unless ok

          out.to_s[/issues=\d+/] || 'unchecked: no issues line'
        end

        # --- report material -----------------------------------------------------

        # The material is written to <report dir>/material.json by the
        # SkillSet (a real run's material exceeds what one tool reply carries);
        # the reply names the file and counts what it holds.
        def report_material_reply(run)
          m = report_material(run)
          path = File.join(report_dir(run), 'material.json')
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, JSON.pretty_generate(m))
          { 'material_path' => path, 'decisions' => m['decisions'].size, 'items' => m['items'].size,
            'phases' => m['phases'].size, 'effects' => m['effects'].size, 'review_rounds' => m['review_rounds'].size,
            'next' => Guidance.report_step(run) }
        end

        def report_material(run)
          run.ensure_merge_item if run.current_phase.nil? || run.status == 'ended'
          run.reload
          e = run.journal.entries
          design = e.reverse.find { |x| %w[review_dispatched check].include?(x['kind']) && x['artifact'] }
          { 'run_id' => run.id, 'goal' => run.goal, 'status' => run.status, 'end_reason' => run.end_reason,
            'policy_digest' => run.policy_digest, 'plan' => run.plan.source,
            'design_latest' => design && { 'path' => design['artifact'], 'sha256' => design['artifact_sha256'] || design['sha256'] },
            'plan_parameters' => e.find { |x| x['kind'] == 'plan_parameters' }&.slice('template', 'args'),
            'plan_ratified' => e.find { |x| x['kind'] == 'plan_ratified' }&.slice('answer', 'decision', 'applied'),
            'phases' => run.phases.values, 'provisional_closures' => run.provisional_closures,
            'decisions' => run.decisions.map { |d| d.slice('id', 'point', 'question', 'answer', 'class', 'confidence', 'basis', 'reason') },
            'novel_or_low_confidence' => run.decisions.select { |d| d['class'] == 'decided_novel' || d['confidence'].to_f < 0.6 }.map { |d| d['id'] },
            'items' => run.items.values, 'hazard' => run.hazard,
            'effects' => e.select { |x| x['kind'] == 'effect' }.map { |x| x.slice('seq', 'tool', 'verdict', 'reason', 'command', 'path', 'item', 'agent_id') },
            'review_rounds' => e.select { |x| x['kind'] == 'review_round' }.map do |x|
              labelled = e.reverse.find { |l| l['kind'] == 'review_labelled' && l['phase'] == x['phase'] && l['round'] == x['round'] }
              x.slice('phase', 'round', 'counted', 'quorum', 'commit', 'artifact', 'persona_count_declared')
               .merge('labels' => labelled&.dig('labels'), 'tally' => labelled&.dig('tally'),
                      'seats' => Array(x['seats']).map { |s| s.slice('seat', 'verdict') },
                      'personas' => x['personas'] && Array(x['personas']).map { |o| o.slice('persona', 'submitted', 'verdict', 'cause', 'late') })
            end,
            'checks' => e.select { |x| x['kind'] == 'check' },
            'pinned_changes' => e.select { |x| x['kind'] == 'pinned_change' },
            'code' => code_summary(run),
            'precedent_records' => Precedents.new(@paths.precedents_dir).all.size,
            'journal_digest' => run.journal.digest,
            'kit' => KIT_DIR, 'report_dir' => report_dir(run),
            'not_checked' => check_waiver_notes(run) + persona_seat_notes(run) +
                             ['choices the actor made without stopping are listed only where found',
                              'the kind of a confirmation or correction is the actor\'s reading of the operator\'s words'] }
        end

        # A round that judged with fewer persona seats than it declared, or
        # with none (a dispatch made without seats), says so with each cause.
        def persona_seat_notes(run)
          e = run.journal.entries
          notes = e.select { |x| x['kind'] == 'review_round' }.filter_map do |x|
            label = "#{x['phase']} round #{x['round']}"
            unless x['personas']
              why = e.reverse.find { |c| c['kind'] == 'seats_not_composed' && c['phase'] == x['phase'] && c['round'] == x['round'] }
              next "#{label}: no persona seats were convened (#{why ? "their prompts could not be composed: #{why['reason']}" : 'dispatched without seats'})"
            end

            missed = Array(x['personas']).reject { |o| o['submitted'] }
            next if missed.empty?

            "#{label}: #{x['personas'].size - missed.size} of #{x['persona_count_declared'] || x['personas'].size} persona " \
              "seats submitted; #{missed.map { |o| "#{o['persona']} #{o['cause']}#{o['late'] ? ' (launched after another seat answered)' : ''}" }.join(', ')}"
          end
          lost = e.select { |x| x['kind'] == 'seat_settled' && x['answered'] }
                  .reject { |s| e.any? { |x| x['kind'] == 'review_round' && x['token'] == s['token'] } }
          notes << "persona replies of rounds that never collected: #{lost.map { |s| "#{s['phase']} round #{s['round']} #{s['persona']}" }.join(', ')}" unless lost.empty?
          notes
        end

        def check_waiver_notes(run)
          notes = run.journal.entries.select { |x| x['kind'] == 'check_waived' }.map do |x|
            "the operator accepted the check as it stood at #{x['commit'].to_s[0, 12]}; later commits were not tested"
          end
          ph = run.plan.phases.find { |p| p.kind == :check }
          notes << 'the operator ended the check phase; commits after that were not tested' if ph && run.phases.dig(ph.name.to_s, 'by') == 'operator'
          notes
        end

        def code_summary(run)
          return nil unless run.worktree && run.base_commit && File.directory?(run.worktree)

          head = git_head(run)
          log, = git(run, ['log', '--oneline', '--no-decorate', "#{run.base_commit}..HEAD"])
          stat, = git(run, ['diff', '--no-ext-diff', '--stat', run.base_commit, 'HEAD'])
          { 'branch' => run.branch, 'worktree' => run.worktree, 'base' => run.base_commit, 'head' => head,
            'commits' => log.to_s.lines.map(&:strip).first(100), 'diffstat' => tail(stat, 4000) }
        rescue StandardError => e
          { 'error' => e.message[0, 200] }
        end

        private

        # INV-6: only the bound session advances, finishes or stops a run. The
        # session id reaches the tools through the agent hooks.
        def session_refusal(run, args)
          sid = args['_session_id']
          return nil if sid && sid == run.bound_session

          { 'status' => 'refused',
            'reason' => if sid
                          "run #{run.id} is not bound to this session; take it over here with agent_start(resume: '#{run.id}')"
                        else
                          no_hooks_refusal['reason']
                        end }
        end

        # The agent's own storage and the snapshot of the operator's answers:
        # nothing the run executes reads them.
        def storage_paths
          [@paths.root, File.join(@paths.data_dir, 'storage', 'agent_precedent_snapshots')]
        end

        def stand_in_for(run, policy)
          StandIn.guard(run, @stand_in_factory.call(run, policy))
        rescue StandardError, ScriptError => e
          StandIn.guard(run, UnavailableStandIn.new(e))
        end

        def hooks_live?(sid)
          return false if sid.to_s.empty?

          f = File.join(@paths.guard_seen_dir, Run.safe(sid))
          File.exist?(f) && (Time.now - File.mtime(f)) <= GUARD_SEEN_WITHIN
        end

        def with_advance_lock(run)
          File.open(File.join(run.dir, 'advance.lock'), File::RDWR | File::CREAT, 0o600) do |f|
            unless f.flock(File::LOCK_EX | File::LOCK_NB)
              return { 'status' => 'busy', 'reason' => 'another agent_advance of this run is in progress' }
            end

            yield
          end
        end

        def note_empty_precedents(run)
          return unless Precedents.new(@paths.precedents_dir).all.empty?

          run.open_item('setup', 'the precedent store is empty, so the stand-in decides from the instruction mode alone. ' \
                                 'The operator fills it with the harvest (it writes a governing store).',
                        command: "ruby #{HARVEST} --data-dir #{@paths.data_dir} --import-snapshot " \
                                 "#{File.join(@paths.data_dir, 'storage', 'agent_precedent_snapshots')}")
        end

        LEGACY_USER_FILES = ['.claude/skills/agent/SKILL.md', '.claude/agents/agent-monitor.md'].freeze

        # 0.x files outside the instance that an upgrade does not remove; a
        # personal skill named agent can shadow the project's 1.0 SKILL.md.
        def note_legacy_files(run)
          return unless @home

          found = LEGACY_USER_FILES.map { |f| File.join(@home, f) }.select do |f|
            File.exist?(f) && File.read(f, encoding: 'UTF-8').match?(/OODA|agent_cycle|cognitive_loop|agent-monitor|agent_execute/)
          end
          return if found.empty?

          backup = File.join(@home, '.claude', 'agent_0x_backup')
          run.open_item('setup', "agent 0.x files remain outside the instance (#{found.join(', ')}); a personal skill named " \
                                 'agent may load instead of 1.0. The operator moves them aside.',
                        command: "mkdir -p #{backup} && #{found.map { |f| "mv #{f} #{backup}/" }.join(' && ')}")
        rescue SystemCallError
          nil
        end

        def report_dir(run)
          File.join(run.target_repo.to_s, 'log', 'agent_runs', run.id)
        end

        def precedents(run, text)
          Precedents.new(@paths.precedents_dir).retrieve(text, project: File.basename(run.target_repo.to_s))
        end

        def git(run, args, timeout: 60, writable: [])
          argv = ['git', *SAFE_GIT, '-C', run.worktree, *args]
          if Confinement.available?
            argv = Confinement.argv(argv, writable: writable, scratch: File.join('/tmp', 'kairos_agent_runs', run.id, 'git'),
                                          worktree: run.worktree, deny_read: storage_paths)
          end
          spawn_split(argv, run.worktree, timeout)
        end

        def git_head(run)
          out, ok = git(run, ['rev-parse', 'HEAD'])
          raise "git rev-parse failed: #{out.to_s[0, 200]}" unless ok

          out.to_s.strip
        end

        # The worktree's own git admin files that name where its repository is.
        def git_admin_files(run)
          link = File.join(run.worktree, '.git')
          admin = File.file?(link) ? File.read(link)[/gitdir:\s*(.+)/, 1]&.strip : nil
          admin ? %w[commondir gitdir config.worktree].map { |f| File.join(admin, f) } : []
        rescue SystemCallError
          []
        end

        def tail(text, n = 1500)
          t = text.to_s
          t.length > n ? t[-n..] : t
        end

        def policy_for(run)
          Policies.new(@paths).all.find { |p| p.digest == run.policy_digest } or raise 'pinned policy missing'
        end

        def record_chain(type, run)
          @chain.call([JSON.generate('type' => type, 'run_id' => run.id, 'journal_digest' => run.journal.digest,
                                     'policy_digest' => run.policy_digest, 'plan_digest' => run.plan_digest)])
        rescue StandardError => e
          run.append(:chain_record_failed, error: e.message[0, 200])
        end

        def default_run_cmd(argv, chdir, timeout)
          run_process(argv, chdir, timeout, merge: true)
        end

        # stdout only (stderr discarded), for output the SkillSet parses.
        def spawn_split(argv, chdir, timeout)
          run_process(argv, chdir, timeout, merge: false)
        end

        def run_process(argv, chdir, timeout, merge:)
          out = +''
          ok = false
          opener = merge ? Open3.method(:popen2e) : Open3.method(:popen3)
          opener.call(*argv, chdir: chdir, pgroup: true) do |stdin, io, *rest|
            th = rest.last
            stdin.close
            err_reader = merge ? nil : Thread.new { rest.first.read }
            reader = Thread.new { out << io.read.to_s }
            unless th.join(timeout)
              begin
                Process.kill('-TERM', th.pid)
                sleep 1
                Process.kill('-KILL', th.pid)
              rescue Errno::ESRCH
                nil
              end
              out << "\n[timed out after #{timeout}s]"
            end
            reader.join(5)
            err_reader&.join(5)
            ok = th.value.success?
          end
          [out, ok]
        rescue SystemCallError => e
          [e.message, false]
        end
      end
    end
  end
end
