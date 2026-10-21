# frozen_string_literal: true

# Regression tests for the implementation review round R3, guard group:
# lib/agent/guard.rb and hooks/agent_hook.rb. The listener rule both ways,
# the false refusals (rsync, curl reads, git checkout <ref> <path>, heredoc
# delimiters with -), the operator's Bash rules inside case, eval and
# find -exec, reads of the agent's own storage, and the hook script's
# wildcard rules and reference words. Confined reads run under real
# sandbox-exec; the hook script runs as a subprocess with HOME,
# KAIROS_DATA_DIR and CLAUDE_PROJECT_DIR in the tmpdir.
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require 'fileutils'
require 'securerandom'
require_relative '../lib/agent/service'
require_relative 'test_agent1_r1_hookscript'

# The harness is reused for a bound session; its own tests run in their own file.
Minitest::Runnable.runnables.delete(KairosMcp::SkillSets::Agent::TestAgent1R1Hookscript)

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R3Guard < Minitest::Test
        FakeRun = Struct.new(:id, :worktree, :target_repo, :branch, :created_paths, :pinned, keyword_init: true)
        LISTENS = 'a server listening on every network interface'

        def setup
          @root = File.realpath(Dir.mktmpdir('r3g'))
          ENV['KAIROS_AGENT_GLOBAL'] = File.join(@root, 'global_bound_sessions.txt')
          @data = File.join(@root, '.kairos')
          @paths = Paths.new(@data)
          FileUtils.mkdir_p(@paths.policies_dir)
          FileUtils.mkdir_p(File.join(@data, 'knowledge', 'k1'))
          File.write(File.join(@data, 'knowledge', 'k1', 'k1.md'), "knowledge\n")
          @run_id = "run_r3g_#{SecureRandom.hex(4)}"
          @wt = File.join(@root, '.claude', 'worktrees', "agent-run-#{@run_id}")
          FileUtils.mkdir_p(File.join(@wt, 'lib'))
          File.write(File.join(@wt, 'lib', 'a.rb'), "a = 1\n")
          @run = FakeRun.new(id: @run_id, worktree: @wt, target_repo: @root, branch: "agent-run/#{@run_id}",
                             created_paths: [], pinned: {})
          @guard = guard
        end

        def teardown
          FileUtils.rm_rf(@root)
          FileUtils.rm_rf(File.join('/tmp', 'kairos_agent_runs', @run_id))
        end

        def guard(**kw)
          Guard.new(run: @run, paths: @paths, policy: policy, project_root: @root, **kw)
        end

        def policy
          DSL.parse_policy("policy \"p\" do\n  stand_in may: [:precedent]\n  spend default: { stand_in_calls: 5 }\nend\n")
        end

        def bash(cmd, g = @guard, cwd: @wt)
          g.decide('Bash', { 'command' => cmd }, cwd: cwd)
        end

        def assert_refused(cmd, g = @guard, cwd: @wt)
          v = bash(cmd, g, cwd: cwd)
          assert v.refuse?, "#{cmd.inspect} should be refused, got #{v.kind}: #{v.reason}"
          v
        end

        # Allowed by the guard: confined where confinement exists, refused
        # only for its absence otherwise.
        def assert_inside(cmd, g = @guard, cwd: @wt)
          v = bash(cmd, g, cwd: cwd)
          if Confinement.available?
            assert v.rewrite?, "#{cmd.inspect} should run confined, got #{v.kind}: #{v.reason}"
          else
            assert_equal 'confinement unavailable on this host', v.reason, cmd
          end
        end

        # The operator's Bash rules as the hook script compiles a prefix rule.
        def denying(*prefixes)
          guard(deny_patterns: prefixes.map { |p| /\A\s*#{Regexp.escape(p)}(?=\s|\z)/m })
        end

        # --- the listener rule: what is text stays allowed -----------------------

        def test_an_address_in_text_is_not_a_listener
          ["cat > .env.example <<'EOF'\nHOST=0.0.0.0\nPORT=3000\nEOF",
           "cat > .env.example <<EOF\nHOST=0.0.0.0\nEOF",
           'git commit -m "dev: HOST=0.0.0.0 lets the phone reach the server"',
           "git commit -F - <<'EOF'\nfix: run with HOST=0.0.0.0 npm run dev\nEOF",
           "sed -i '' 's/HOST=127.0.0.1/HOST=0.0.0.0/' .env.example",
           "echo 'HOST=0.0.0.0 npm start' >> notes.md",
           'printf "%s\n" "BIND_ADDR=0.0.0.0"',
           'grep -rn "http.server" lib', "rg 'http.server' docs", 'grep -rn http.server .',
           'grep -H 0.0.0.0 config/puma.rb', 'grep -b 0.0.0.0 log/x.log', 'rg -e --host -e 0.0.0.0 config',
           'curl -s http://0.0.0.0:3000/health', 'grep -rn -- "--host 0.0.0.0" docs',
           "python3 -c 'import http.server'", 'python3 -m pytest -k http.server'].each { |c| assert_inside(c) }
        end

        def test_an_address_variable_set_for_a_command_is_a_listener
          ['HOST=0.0.0.0 npm run dev', 'HOST="0.0.0.0" PORT=3000 node server.js', 'env HOST=0.0.0.0 npm start',
           'BIND_ADDR=0.0.0.0:8080 ./bin/serve', 'export HOST=0.0.0.0; npm run dev', 'HOSTNAME=:: node .next/standalone/server.js',
           "sh -c 'HOST=0.0.0.0 npm start'", "cd web && HOST='[::]' yarn dev"].each do |c|
            assert_includes assert_refused(c).reason, LISTENS, c
          end
          ['HOST=127.0.0.1 npm run dev', 'HOST=localhost npm start', 'GHOST_MODE=1 npm test',
           'PORT=3000 npm start'].each { |c| assert_inside(c) }
        end

        def test_http_server_counts_only_as_python_dash_m_http_server
          ['python3 -m http.server', 'python -m http.server 8000', 'python3.12 -m http.server --directory site',
           'uv run python -m http.server -b 0.0.0.0', 'python3 -mhttp.server', 'python3 -m http.server --bind ::'].each do |c|
            assert_includes assert_refused(c).reason, LISTENS, c
          end
          ['python3 -m http.server --bind 127.0.0.1', 'python3 -m http.server -b localhost 8000',
           'python3 -m http.server --bind=::1'].each { |c| assert_inside(c) }
        end

        # --- the listener rule: what listens is refused ---------------------------

        def test_other_bind_flags_and_bare_host_are_listeners
          ['ruby -run -e httpd -- --bind-address=0.0.0.0 .', 'ruby -run -e httpd . --bind-address 0.0.0.0',
           'ruby -run -e httpd . -p 8000',
           'jupyter lab --ip=0.0.0.0', 'jupyter notebook --ip 0.0.0.0', "jupyter lab --ip='*'",
           'next dev --hostname 0.0.0.0', 'npx next dev --hostname=0.0.0.0', 'npx next dev -H 0.0.0.0',
           'php -S 0.0.0.0:8000', 'php -S 0.0.0.0:8000 -t public', 'php8.3 -S [::]:8000',
           'npx vite --host', 'vite --host --port 5173', 'npm run dev -- --host', 'pnpm astro dev --host',
           'flask run -h 0.0.0.0', 'bin/rails s -b 0.0.0.0', 'uvicorn app:app --host 0.0.0.0',
           'hugo server --bind=0.0.0.0', 'go run . -addr 0.0.0.0:8080'].each do |c|
            assert_includes assert_refused(c).reason, LISTENS, c
          end
          ['ruby -run -e httpd . --bind-address=127.0.0.1', 'jupyter lab --ip=127.0.0.1', 'next dev --hostname localhost',
           'npx next dev -H 127.0.0.1', 'php -S localhost:8000', 'php -S 127.0.0.1:8000', 'npx vite --host 127.0.0.1',
           'vite --host=localhost --port 5173', 'npx vite', 'flask run -h 127.0.0.1', 'bin/rails s',
           'ls -H 0.0.0.0', 'sort -h data.txt'].each { |c| assert_inside(c) }
        end

        # --- false refusals ----------------------------------------------------

        def test_rsync_is_a_local_copy_unless_it_names_another_host
          ['rsync -a --delete build/ dist/', 'rsync -av ./a/ ./b/', 'rsync -a --exclude "*.o" src/ /tmp/x/',
           'rsync -a --chown www:www build/ dist/', 'rsync -a --chown=www:www build/ dist/'].each { |c| assert_inside(c) }
          ['rsync -a build/ host:dist/', 'rsync -a user@host:/srv/x ./x', 'rsync -a ./x host::module/x',
           'rsync rsync://mirror.example.org/pub/x ./x', 'rsync -e ssh -a ./x deploy@10.0.0.5:/srv/',
           'rsync --daemon --port 8873'].each { |c| assert_refused(c) }
        end

        def test_curl_reads_by_any_spelling_of_get_head_or_options
          ['curl -X GET http://localhost:3000/x', 'curl -XGET http://localhost:3000/x', 'curl -X head localhost:3000',
           'curl --request OPTIONS http://localhost:3000/', 'curl --request=GET http://localhost:3000/',
           'curl -I http://localhost:3000/', 'curl --request-target "*" -X OPTIONS http://localhost:3000/',
           'wget -T 10 http://localhost:3000/x', 'wget -d http://localhost:3000/x',
           'wget --method=GET http://localhost:3000/x'].each { |c| assert_inside(c) }
          ['curl -X POST http://localhost:3000/x', 'curl -XPUT http://localhost:3000/x', 'curl --request=DELETE x',
           'curl -X PATCH x', 'curl -X', 'curl -d a=1 http://localhost/x', 'curl -d@body.json http://localhost/x',
           'curl --data-binary @f x', 'curl -F f=@a x', 'curl -T a.txt x', 'curl --upload-file a.txt x',
           "curl --json '{}' x", 'curl -X GET -d a=1 x', 'wget --method=PUT x', 'wget --method DELETE x',
           'wget --post-data a=1 x', 'wget --body-file f x'].each do |c|
            assert_includes assert_refused(c).reason, 'an upload or a write request', c
          end
        end

        def test_git_checkout_of_a_ref_and_paths_restores_files
          ['git checkout HEAD lib/a.rb', 'git checkout HEAD lib/deleted.rb', 'git checkout HEAD~2 lib/a.rb lib/gone.rb',
           'git checkout main lib', 'git checkout --ours HEAD lib/a.rb'].each { |c| assert_inside(c) }
          assert_nil Guard.crossing(%w[git checkout HEAD lib/x.rb]), 'a ref and a path need no cwd'
          # A ref alone leaves the branch; so does a ref that creates or tracks one.
          ['git checkout main', 'git checkout HEAD~1', 'git checkout -t origin/feature', 'git checkout --track origin/f',
           'git checkout -b x main', 'git switch main lib', 'git checkout - lib/a.rb'].each { |c| assert_refused(c) }
          # The first word is a path, so every word is one (R2): main is none.
          assert_refused('git checkout lib/a.rb main')
        end

        def test_a_heredoc_delimiter_may_carry_a_dash
          ["git commit -F - <<'END-MSG'\nfix: push back later\n\ngit push is the operator's\nEND-MSG",
           "git commit -F - <<END-MSG\nfix: no push here\nEND-MSG",
           "cat > notes.md <<-\"END.TXT\"\n\tgit push origin main\n\tEND.TXT"].each { |c| assert_inside(c) }
          assert_equal ["git commit -F - <<'END-MSG'", 'ls'], Guard.segments("git commit -F - <<'END-MSG'\ngit push\nEND-MSG\nls")
          # The line after the body is read again; a body fed to a shell runs.
          assert_refused("cat > x.md <<'END-MSG'\ntext\nEND-MSG\ngit push origin main")
          assert_refused("cat <<'END-MSG' | sh\ngit push\nEND-MSG")
          assert_refused("bash <<END-MSG\ngh pr create\nEND-MSG")
        end

        # --- the operator's Bash rules: case, eval, find -exec ---------------------

        def test_a_bash_rule_sees_the_command_after_a_case_pattern
          g = denying('rm')
          ['case "$1" in start) rm -rf x;; esac',
           "case \"$1\" in\n  start) echo ok;;\n  stop) rm -rf x;;\nesac",
           "case $x in\n  a|b) rm -rf x ;;\nesac", "case $x in\n  (clean) rm -rf build;;\nesac",
           "case $x in *) rm -f y;; esac"].each do |c|
            assert_includes assert_refused(c, g).reason, 'permission rules', c
          end
          ["case $x in a) echo rm;; esac", "case $x in\n  start) make;;\nesac"].each { |c| assert_inside(c, g) }
          # A subshell's closing word is no pattern: the command in it is still read.
          ['(cd lib && make) > log', '(cd lib; make) 2>&1', '(make) >> log', '(cd lib && make)'].each do |c|
            assert_refused(c, denying('make'))
          end
          assert_includes assert_refused("case $1 in\n  ship) git push origin main;;\nesac").reason, 'git push'
        end

        def test_a_bash_rule_sees_evals_arguments_as_a_command
          g = denying('rm')
          ['eval rm -rf x', 'eval "rm -rf x"', "eval 'cd /tmp && rm -rf x'", 'true && eval rm x', 'eval eval rm x'].each do |c|
            assert_includes assert_refused(c, g).reason, 'permission rules', c
          end
          assert_inside('eval "echo rm"', g)
          assert_includes assert_refused('eval "git push origin main"').reason, 'git push'
        end

        def test_a_bash_rule_sees_the_command_after_find_exec
          g = denying('rm')
          ['find . -exec rm -rf {} +', "find . -name '*.o' -execdir rm {} \\;", "find . -type f -ok rm {} ';'",
           'find build -okdir rm -f {} +', "find . -exec sh -c 'rm -rf \"$1\"' _ {} \\;"].each do |c|
            assert_includes assert_refused(c, g).reason, 'permission rules', c
          end
          ["find . -name '*.rb' -exec grep -l rm {} +", 'find . -name rm', "find . -exec wc -l {} \\; -print"].each do |c|
            assert_inside(c, g)
          end
          assert_includes assert_refused('find . -maxdepth 0 -exec git push origin main \;').reason, 'git push'
        end

        # --- the agent's own storage is not read in a run ----------------------------

        def storage_files
          words = @paths.operator_words_path
          journal = File.join(@paths.run_dir(@run_id), 'journal.jsonl')
          precedent = File.join(@paths.precedents_dir, 'raw', 'harvest.jsonl')
          snapshot = File.join(@data, 'storage', 'agent_precedent_snapshots', 'answers.jsonl')
          [words, journal, precedent, snapshot].each do |f|
            FileUtils.mkdir_p(File.dirname(f))
            File.write(f, "{\"text\":\"the operator's words\"}\n")
          end
          [words, journal, precedent, snapshot]
        end

        def read(tool, input, cwd: @wt)
          @guard.decide(tool, input, cwd: cwd)
        end

        def test_read_grep_and_glob_of_the_agents_storage_are_refused
          words, journal, precedent, snapshot = storage_files
          [words, journal, precedent, snapshot].each do |f|
            v = read('Read', { 'file_path' => f })
            assert v.refuse?, "Read #{f}"
            assert_includes v.reason, "the agent's own storage"
            assert_equal "Read #{File.realpath(f)}", v.item['command']
          end
          relative = words.delete_prefix("#{@root}/")
          assert read('Read', { 'file_path' => relative }, cwd: @root).refuse?, 'a path relative to the cwd'
          assert read('NotebookRead', { 'notebook_path' => journal }).refuse?
          assert read('Grep', { 'pattern' => 'words', 'path' => @paths.root }).refuse?
          assert read('Grep', { 'pattern' => 'x', 'path' => @paths.precedents_dir, 'output_mode' => 'content' }).refuse?
          assert read('Grep', { 'pattern' => 'x', 'path' => @data }).refuse?, 'a search from the data dir passes through it'
          assert read('Grep', { 'pattern' => 'x', 'path' => File.join(@data, 'storage') }).refuse?
          assert read('Grep', { 'pattern' => 'x', 'glob' => '.kairos/storage/agent/**/*.jsonl' }, cwd: @root).refuse?
          assert read('Glob', { 'pattern' => '**/*.jsonl', 'path' => @paths.root }).refuse?
          assert read('Glob', { 'pattern' => '.kairos/storage/agent/runs/*/journal.jsonl' }, cwd: @root).refuse?
          assert read('Glob', { 'pattern' => "#{@paths.root}/*.jsonl" }).refuse?, 'an absolute pattern'
          assert read('Glob', { 'pattern' => '*', 'path' => File.dirname(snapshot) }).refuse?
          assert read('LS', { 'path' => @paths.runs_dir }).refuse?
        end

        def test_a_link_into_the_storage_is_placed_where_it_leads
          words, = storage_files
          link = File.join(@wt, 'lib', 'words.jsonl')
          File.symlink(words, link)
          assert read('Read', { 'file_path' => link }).refuse?
          File.symlink(@paths.root, File.join(@wt, 'store'))
          assert read('Grep', { 'pattern' => 'x', 'path' => File.join(@wt, 'store') }).refuse?
        end

        def test_reading_other_places_stays_allowed
          storage_files
          [['Read', { 'file_path' => File.join(@wt, 'lib', 'a.rb') }], ['Read', { 'file_path' => '/etc/hosts' }],
           ['Read', { 'file_path' => File.join(@data, 'knowledge', 'k1', 'k1.md') }],
           ['Grep', { 'pattern' => 'x' }], ['Grep', { 'pattern' => 'x', 'path' => @root }],
           ['Grep', { 'pattern' => 'x', 'path' => @root, 'glob' => '**/*.rb' }],
           ['Grep', { 'pattern' => 'x', 'path' => File.join(@data, 'knowledge') }],
           ['Glob', { 'pattern' => '**/*.rb', 'path' => @root }], ['Glob', { 'pattern' => '**/*.jsonl' }],
           ['Glob', { 'pattern' => 'knowledge/**/*.md', 'path' => @data }],
           ['Glob', { 'pattern' => '.kairos/knowledge/*/*.md' }], ['LS', { 'path' => @data }],
           ['Read', { 'file_path' => File.join(@data, 'storage', 'agentx', 'f') }]].each do |tool, input|
            v = read(tool, input, cwd: @root)
            assert v.allow?, "#{tool} #{input.inspect}: #{v.reason}"
          end
        end

        def test_a_confined_command_cannot_read_the_agents_storage_either
          skip 'sandbox-exec unavailable' unless Confinement.available?
          words, journal, precedent, snapshot = storage_files
          [words, journal, precedent, snapshot].each do |f|
            v = bash("cat #{f}")
            assert v.rewrite?, v.reason
            out, err, st = Open3.capture3({ 'HOME' => File.join(@root, 'home') }, '/bin/bash', '-c', v.updated_input['command'])
            refute st.success?, "#{f} was read inside confinement: #{out}"
            assert_match(/not permitted/i, err)
          end
          v = bash("cat #{File.join(@wt, 'lib', 'a.rb')} #{File.join(@data, 'knowledge', 'k1', 'k1.md')}")
          out, err, st = Open3.capture3({ 'HOME' => File.join(@root, 'home') }, '/bin/bash', '-c', v.updated_input['command'])
          assert st.success?, "control: other files stay readable: #{err}"
          assert_equal "a = 1\nknowledge\n", out
        end

        # --- the hook script ------------------------------------------------------

        def with_hook_harness
          t = TestAgent1R1Hookscript.new('x')
          t.setup
          yield t
        ensure
          t&.teardown
        end

        def test_a_wildcard_bash_rule_matches_a_multi_line_command
          with_hook_harness do |t|
            t.bound_run
            home = t.instance_variable_get(:@home)
            t.write_settings(File.join(home, '.claude', 'settings.json'), ['Bash(git commit *)', 'Bash(npm * --force)'])
            decide = lambda do |cmd|
              out, err, code = t.pre('s1', 'Bash', 'command' => cmd)
              assert_equal 0, code, err
              t.decision_of(out)['permissionDecision']
            end
            ["git commit -m \"fix: x\n\nbody line\"", "git commit -F - <<'EOF'\nfix: x\n\nbody\nEOF",
             "git commit -m \"$(cat <<'EOF'\nfix: x\n\nCo-Authored-By: a\nEOF\n)\"", 'git commit', 'git commit -m x',
             "npm config set note \"a\nb\" --force"].each do |cmd|
              assert_equal 'deny', decide.call(cmd), cmd
            end
            if Confinement.available?
              ['git commit-tree HEAD^{tree} -m x', 'git log -1', "echo 'git commit -m x'\nls",
               'npm install --force-color'].each { |cmd| assert_equal 'allow', decide.call(cmd), cmd }
            end
          end
        end

        def test_a_reference_is_not_followed_by_a_letter_or_digit
          with_hook_harness do |t|
            prompt = { 'hook_event_name' => 'UserPromptSubmit', 'session_id' => 'u1', 'prompt_id' => 'p1' }
            ['fix the I2C bus', 'the D3js chart', 'I2S audio', 'D4x', 'I12b'].each do |words|
              refute t.loads_library?(prompt.merge('prompt' => words)), words
            end
            ['I2 は凍結', 'D4は違う', 'D12.', 'resolve I7, then D3', '(I2)', 'I2と D3'].each do |words|
              assert t.loads_library?(prompt.merge('prompt' => words)), words
            end
          end
        end
      end
    end
  end
end
