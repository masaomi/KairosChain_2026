# frozen_string_literal: true

# Verification of the R3 fixes, group "guardwords": the guard's and the
# words' R3 work driven through the real hook script and the service, in
# the host's order (PreToolUse → the tool → PostToolUse, Stop at a turn's
# end). Every hook event runs hooks/agent_hook.rb as a subprocess with the
# hook input on stdin and HOME, KAIROS_DATA_DIR, CLAUDE_PROJECT_DIR and
# KAIROS_AGENT_GLOBAL in the tmpdir; a Bash call the hook allows runs as the
# host runs it, with the command the hook returned (sandbox-exec for real).
# Real git. The stand-in's llm is a stub llm_client tool in the tmp data
# dir, loaded by the hook script's own factory; no claude -p is run.
# The triggers are the R3 findings'.
require 'rbconfig'
require 'socket'
require_relative 'test_agent1_r1_check'

# The harness's own tests run in their own file.
Minitest::Runnable.runnables.delete(KairosMcp::SkillSets::Agent::TestAgent1R1Check)

module KairosMcp
  module SkillSets
    module Agent
      class TestAgent1R3VGuardwords < TestAgent1R1Check
        TestAgent1R1Check.public_instance_methods(false).grep(/\Atest_/).each { |m| undef_method m }

        SID = 's1'
        SKILLSET = File.expand_path('..', __dir__)
        HOOK_SCRIPT = File.join(SKILLSET, 'hooks', 'agent_hook.rb')
        HARVEST_BIN = File.join(SKILLSET, 'bin', 'agent_harvest.rb')
        LISTENS = 'a server listening on every network interface'
        STORAGE = "the agent's own storage"
        GOAL = 'S1まで実装を続けて下さい。'
        HOST_ENV = %w[HOME CLAUDE_PROJECT_DIR KAIROS_DATA_DIR].freeze
        AGENT_METHODS = { 'agent_start' => :start, 'agent_status' => :status, 'agent_advance' => :advance,
                          'agent_items' => :items, 'agent_finish' => :finish, 'agent_stop' => :stop }.freeze

        # A connect from inside confinement: prints CONNECTED or the error class.
        CONNECT_PROBE = <<~RUBY
          require 'socket'
          begin
            s = Socket.tcp(ARGV[0], Integer(ARGV[1]), connect_timeout: 3)
            puts 'CONNECTED'
            s.close
          rescue SystemCallError, SocketError => e
            puts e.class.name
          end
        RUBY
        UDP_PROBE = <<~RUBY
          require 'socket'
          begin
            UDPSocket.new.send('x', 0, ARGV[0], Integer(ARGV[1]))
            puts 'SENT'
          rescue SystemCallError, SocketError => e
            puts e.class.name
          end
        RUBY

        # The host-side library the hook script's stand-in factory requires,
        # and llm_client's tool in the data dir: a stub that answers, or
        # fails (odd calls return an error payload, even calls raise).
        BASE_TOOL_STUB = <<~RUBY
          module KairosMcp
            module Tools
              class BaseTool
                def initialize(*); end
              end
            end
          end
        RUBY
        LLM_CALL_STUB = <<~'RUBY'
          require 'json'
          module KairosMcp
            module SkillSets
              module LlmClient
                module Tools
                  class LlmCall < KairosMcp::Tools::BaseTool
                    def input_schema
                      { properties: { isolated: { type: 'boolean' } } }
                    end

                    def call(args)
                      counter = ENV.fetch('R3VG_LLM_COUNTER')
                      n = (File.exist?(counter) ? File.read(counter).to_i : 0) + 1
                      File.write(counter, n.to_s)
                      File.open(ENV.fetch('R3VG_LLM_LOG'), 'a') do |f|
                        f.puts(JSON.generate('n' => n, 'user' => args.dig('messages', 0, 'content'), 'isolated' => args['isolated']))
                      end
                      if ENV['R3VG_LLM_MODE'] == 'fail'
                        raise IOError, "claude -p exited 1: Credit balance is too low (call #{n})" if n.even?

                        return [{ text: JSON.generate('status' => 'error', 'error' => { 'message' => "overloaded (call #{n})" }) }]
                      end
                      reply = { 'answer' => ENV.fetch('R3VG_LLM_ANSWER', '3000'), 'class' => 'decided', 'confidence' => 0.9,
                                'basis' => ['instruction_mode'], 'reason' => 'stub' }
                      [{ text: JSON.generate('status' => 'ok', 'provider' => 'claude_code',
                                             'isolation' => { 'safe_mode' => true, 'tools' => '', 'cwd' => '/tmp/kairos_sandbox' },
                                             'response' => { 'content' => JSON.generate(reply), 'model_observed' => 'claude-opus-5-5' }) }]
                    end
                  end
                end
              end
            end
          end
        RUBY

        def setup
          super
          @saved_host_env = HOST_ENV.to_h { |k| [k, ENV.fetch(k, nil)] }
          @home = File.join(@tmp, 'home')
          FileUtils.mkdir_p(@home)
          ENV['HOME'] = @home
          ENV['CLAUDE_PROJECT_DIR'] = @root
          ENV['KAIROS_DATA_DIR'] = @paths.data_dir
          # The operator's git identity, as the host's shell has it.
          File.write(ENV.fetch('GIT_CONFIG_GLOBAL'), "[user]\n\temail = op@example.org\n\tname = Operator\n")
          @tu = 0
          @mcp_lib = nil
          @llm_env = {}
          @probe_dir = File.join(@tmp, 'probe')
          FileUtils.mkdir_p(@probe_dir)
        end

        def teardown
          super
        ensure
          @saved_host_env&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
        end

        # --- the host ---------------------------------------------------------------

        def hook_env(extra = {})
          { 'HOME' => @home, 'KAIROS_DATA_DIR' => @paths.data_dir, 'CLAUDE_PROJECT_DIR' => @root,
            'KAIROS_AGENT_GLOBAL' => ENV.fetch('KAIROS_AGENT_GLOBAL'), 'KAIROS_MCP_LIB' => @mcp_lib }.merge(@llm_env).merge(extra)
        end

        # One hook event through hooks/agent_hook.rb, as the host runs it.
        def event(name, input)
          out, err, st = Open3.capture3(hook_env, RbConfig.ruby, HOOK_SCRIPT,
                                        stdin_data: JSON.generate(input.merge('hook_event_name' => name)), chdir: @root)
          assert_equal 0, st.exitstatus, "#{name} hook failed: #{err}"
          out.strip.empty? ? nil : JSON.parse(out)
        end

        def pre_tool(tool, input, cwd: @root, agent_id: nil)
          @last_tu = "toolu_r3vg_#{@tu += 1}"
          ev = { 'session_id' => SID, 'transcript_path' => @transcript, 'cwd' => cwd, 'tool_name' => tool,
                 'tool_input' => input, 'tool_use_id' => @last_tu }
          ev['agent_id'] = agent_id if agent_id
          event('PreToolUse', ev)
        end

        def post_tool(tool, input, response, cwd: @root)
          event('PostToolUse', 'session_id' => SID, 'transcript_path' => @transcript, 'cwd' => cwd, 'tool_name' => tool,
                               'tool_input' => input, 'tool_response' => response, 'tool_use_id' => @last_tu)
        end

        def stop!(msg)
          event('Stop', 'session_id' => SID, 'transcript_path' => @transcript, 'cwd' => @root,
                        'last_assistant_message' => msg, 'stop_hook_active' => false)
        end

        # An agent tool: PreToolUse names the session, the service runs with
        # the input the hook returned, PostToolUse sees the reply.
        def host_tool(tool, args)
          name = "mcp__kairos-chain__#{tool}"
          pre = pre_tool(name, args)
          input = pre&.dig('hookSpecificOutput', 'updatedInput')
          refute_nil input, "PreToolUse gives #{tool} its session: #{pre.inspect}"
          assert_equal SID, input['_session_id']
          out = service.public_send(AGENT_METHODS.fetch(tool), input)
          post_tool(name, input, [{ 'type' => 'text', 'text' => JSON.generate(out) }])
          out
        end

        # A Bash call: PreToolUse; if allowed, the host runs the command the
        # hook returned, in the session's cwd, then PostToolUse.
        def bash!(cmd, cwd: @wt, execute: true)
          input = { 'command' => cmd, 'description' => 'r3v guardwords' }
          v = pre_tool('Bash', input, cwd: cwd)&.dig('hookSpecificOutput')
          res = { decision: v&.dig('permissionDecision'), reason: v&.dig('permissionDecisionReason').to_s,
                  ran: false, confined: false }
          return res unless v && v['permissionDecision'] == 'allow'

          ran = v['updatedInput'] || input
          res[:confined] = ran['command'].include?(Confinement::SANDBOX_EXEC)
          return res unless execute

          out, err, st = Open3.capture3({ 'HOME' => @home }, '/bin/bash', '-c', ran['command'], chdir: cwd)
          post_tool('Bash', ran, { 'stdout' => out, 'stderr' => err, 'interrupted' => false, 'isImage' => false }, cwd: cwd)
          res.merge(ran: true, out: out, err: err, ok: st.success?)
        end

        def tool_decision(tool, input, cwd: @root)
          v = pre_tool(tool, input, cwd: cwd)&.dig('hookSpecificOutput')
          [v&.dig('permissionDecision'), v&.dig('permissionDecisionReason').to_s]
        end

        def transcript_entry(entry)
          File.open(@transcript, 'a') { |f| f.puts(JSON.generate(entry)) }
        end

        def typed_entry(text, prompt_id)
          { 'type' => 'user', 'promptId' => prompt_id, 'origin' => { 'kind' => 'human' }, 'promptSource' => 'typed',
            'message' => { 'role' => 'user', 'content' => text } }
        end

        # A built-in command as the host records it: name first, no origin,
        # no prompt source.
        def builtin_entry(name, args, prompt_id)
          { 'type' => 'user', 'promptId' => prompt_id,
            'message' => { 'role' => 'user',
                           'content' => "<command-name>/#{name}</command-name>\n            <command-message>#{name}" \
                                        "</command-message>\n            <command-args>#{args}</command-args>" } }
        end

        # The operator types: the transcript records it, UserPromptSubmit fires.
        def operator_types(text, prompt_id, entry: typed_entry(text, prompt_id))
          transcript_entry(entry)
          event('UserPromptSubmit', 'session_id' => SID, 'prompt' => text, 'prompt_id' => prompt_id,
                                    'transcript_path' => @transcript, 'cwd' => @root)
        end

        def hex
          @policy.digest[0, 8]
        end

        def adopt_by_words!
          operator_types("adopt policy p1 #{hex} でお願いします", 'p-adopt')
          out = host_tool('agent_items', 'action' => 'adopt_policy', 'policy' => 'p1')
          assert_equal 'adopted', out['status'], out.inspect
        end

        def impl_run!(files = {})
          repo!({ 'lib/x.rb' => "X_VALUE = 1\n", 'test/test_x.rb' => "exit 0\n" }.merge(files))
          adopt_by_words! unless Policies.new(@paths).adopted
          out = host_tool('agent_start', 'goal' => 'make x work', 'template' => 'impl_cycle', 'tests' => 'test')
          assert_equal 'started', out['status'], out.inspect
          run = Run.load(@paths, out['run_id'])
          assert_equal SID, run.bound_session
          assert_equal @transcript, run.transcript_path, 'PostToolUse of agent_start attached the transcript'
          @wt = run.worktree
          run
        end

        def refused_items(run)
          run.reload.open_items.select { |i| i['item_kind'] == 'refused_effect' }
        end

        def install_llm_stub!(mode)
          lib = File.join(@tmp, 'mcp_lib')
          FileUtils.mkdir_p(File.join(lib, 'kairos_mcp', 'tools'))
          File.write(File.join(lib, 'kairos_mcp', 'tools', 'base_tool.rb'), BASE_TOOL_STUB)
          @mcp_lib = lib
          dir = File.join(@paths.data_dir, 'skillsets', 'llm_client', 'tools')
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, 'llm_call.rb'), LLM_CALL_STUB) if mode
          @llm_log = File.join(@tmp, 'llm_calls.jsonl')
          @llm_env = { 'R3VG_LLM_MODE' => mode.to_s, 'R3VG_LLM_LOG' => @llm_log,
                       'R3VG_LLM_COUNTER' => File.join(@tmp, 'llm_counter') }
        end

        def llm_calls
          File.exist?(@llm_log) ? File.readlines(@llm_log).map { |l| JSON.parse(l) } : []
        end

        def ask_question!
          pre_tool('AskUserQuestion', { 'questions' => [{ 'question' => 'Which port should the dev server use?',
                                                          'header' => 'port', 'multiSelect' => false,
                                                          'options' => [{ 'label' => '3000', 'description' => 'default' },
                                                                        { 'label' => '8080', 'description' => 'alt' }] }] })
        end

        # --- 1. confinement reaches this host only -----------------------------------

        def probe(name, src)
          path = File.join(@probe_dir, name)
          File.write(path, src)
          path
        end

        # A LAN host that is not this one: the default gateway, else an
        # address of a private range no interface here holds.
        def other_lan_host
          @other_lan_host ||= find_other_lan_host
        end

        def find_other_lan_host
          own = Socket.ip_address_list.select(&:ipv4?).map(&:ip_address)
          out, = Open3.capture2('/sbin/route', '-n', 'get', 'default', err: File::NULL)
          gw = out[/gateway:\s*(\d+\.\d+\.\d+\.\d+)/, 1]
          gw && !own.include?(gw) && gw.match?(/\A(10|192\.168|172\.(1[6-9]|2\d|3[01]))\./) ? gw : '10.254.254.1'
        end

        # R3 guard_adversary P0: with `local ip "localhost:*"` TCP to
        # 1.1.1.1:443 and to a LAN host on :80 connected, and UDP sendto went
        # out. A loopback connect may be refused about once in a hundred
        # (stated residual), so it is tried up to three times.
        def test_a_confined_connect_reaches_loopback_and_no_external_or_lan_host
          run = impl_run!
          connect = probe('connect.rb', CONNECT_PROBE)
          udp = probe('udp.rb', UDP_PROBE)
          server = TCPServer.new('127.0.0.1', 0)
          port = server.addr[1]
          acceptor = Thread.new do
            loop { server.accept.close }
          rescue IOError, SystemCallError
            nil
          end
          ruby = RbConfig.ruby

          [['1.1.1.1', 443], ['1.1.1.1', 80], [other_lan_host, 80], [other_lan_host, 443]].each do |host, p|
            r = bash!("#{ruby} #{connect} #{host} #{p}")
            assert_equal 'allow', r[:decision], r[:reason]
            assert r[:confined], 'the host runs the command the hook rewrote'
            assert_equal 'Errno::EPERM', r[:out].to_s.strip, "TCP to #{host}:#{p} from inside confinement (#{r[:err]})"
          end
          r = bash!("#{ruby} #{udp} 1.1.1.1 53")
          assert_equal 'Errno::EPERM', r[:out].to_s.strip, 'UDP sendto an external host'
          r = bash!("#{ruby} #{udp} #{other_lan_host} 53")
          assert_equal 'Errno::EPERM', r[:out].to_s.strip, 'UDP sendto a LAN host'

          loopback = []
          3.times do
            loopback << bash!("#{ruby} #{connect} 127.0.0.1 #{port}")[:out].to_s.strip
            break if loopback.last == 'CONNECTED'
          end
          assert_equal 'CONNECTED', loopback.last, "loopback stays reachable (tries: #{loopback.inspect})"
          sent = 3.times.lazy.map { bash!("#{ruby} #{udp} 127.0.0.1 #{port}")[:out].to_s.strip }.find { |x| x == 'SENT' }
          assert_equal 'SENT', sent, 'loopback UDP stays reachable (three tries: the ~1/100 loopback refusal is a stated residual)'

          assert(run.reload.journal.entries.any? { |e| e['kind'] == 'effect' && e['verdict'] == 'confined' })
          assert_empty refused_items(run), 'nothing here is refused by the guard; confinement does the refusing'
          stop!('Probed the network from the worktree.')
        ensure
          server&.close
          acceptor&.join(1)
        end

        # --- 2. the listener rule ----------------------------------------------------

        # R3 guard_adversary P1 (two lines): the rule refused text (heredoc
        # bodies, commit messages, sed of .env.example, grep http.server) and
        # missed explicit binds by other flags.
        def test_the_listener_rule_refuses_listeners_and_lets_text_through
          run = impl_run!('.env.example' => "HOST=127.0.0.1\nPORT=3000\n",
                          'lib/server.rb' => "# serve the docs with python3 -m http.server\n")
          listeners = ['ruby -run -e httpd -- --bind-address=0.0.0.0', 'php -S 0.0.0.0:8000', 'jupyter lab --ip=0.0.0.0',
                       'npx vite --host', 'HOST=0.0.0.0 npm run dev']
          listeners.each do |cmd|
            r = bash!(cmd)
            assert_equal 'deny', r[:decision], "#{cmd}: #{r.inspect}"
            assert_includes r[:reason], LISTENS, cmd
            refute r[:ran]
          end
          queued = refused_items(run)
          assert_equal listeners.sort, queued.map { |i| i['command'] }.sort, 'each listener is queued with its command'
          assert(queued.all? { |i| i['text'].include?(LISTENS) })

          head = git_out(@wt, 'rev-parse', 'HEAD')
          g = bash!('grep -rn http.server lib/')
          assert_equal 'allow', g[:decision], g[:reason]
          assert g[:confined]
          assert g[:ok], g[:err]
          assert_match(%r{\Alib/+server\.rb:1:.*http\.server}, g[:out])

          s = bash!("sed -i '' 's/HOST=127.0.0.1/HOST=0.0.0.0/' .env.example")
          assert_equal 'allow', s[:decision], s[:reason]
          assert s[:ok], s[:err]
          assert_equal "HOST=0.0.0.0\nPORT=3000\n", File.read(File.join(@wt, '.env.example'))

          c = bash!("git add .env.example && git commit -q -F - <<'EOF'\ndev: HOST=0.0.0.0 lets the phone reach the dev server\n\n" \
                    "Start it with HOST=0.0.0.0 npm run dev; python3 -m http.server is not used.\nEOF")
          assert_equal 'allow', c[:decision], c[:reason]
          assert c[:confined]
          assert c[:ok], "the commit runs confined: #{c[:err]}"
          refute_equal head, git_out(@wt, 'rev-parse', 'HEAD')
          assert_equal git_out(@wt, 'rev-parse', 'HEAD'), git_out(@root, 'rev-parse', run.branch), 'on the run branch'
          assert_includes git_out(@wt, 'log', '-1', '--format=%B'), 'Start it with HOST=0.0.0.0 npm run dev'

          h = bash!('python3 -m http.server -b 127.0.0.1', execute: false)
          assert_equal 'allow', h[:decision], h[:reason]
          assert h[:confined]

          assert_equal listeners.size, refused_items(run).size, 'the text commands queued nothing'
          assert_equal 'block', stop!('Committed the .env.example change on the run branch.')&.dig('decision')
        end

        # --- 3. the operator's ask rule ----------------------------------------------

        # R3 guard_adversary P1: Bash(git commit *) missed multi-line commands
        # (`.` did not match a newline). The heredoc forms are how commits
        # with a body are typed, Claude Code's own form among them.
        def test_an_ask_rule_for_git_commit_refuses_the_multi_line_heredoc_commit
          settings = File.join(@home, '.claude', 'settings.json')
          FileUtils.mkdir_p(File.dirname(settings))
          File.write(settings, JSON.generate('permissions' => { 'ask' => ['Bash(git commit *)'] }))
          run = impl_run!
          edit = { 'file_path' => File.join(@wt, 'lib', 'x.rb'), 'content' => "X_VALUE = 2\n" }
          assert_equal 'allow', pre_tool('Write', edit)&.dig('hookSpecificOutput', 'permissionDecision')
          File.write(edit['file_path'], edit['content'])
          post_tool('Write', edit, { 'type' => 'update', 'filePath' => edit['file_path'] })
          head = git_out(@wt, 'rev-parse', 'HEAD')
          assert bash!('git add lib/x.rb')[:ok], 'staging is not a commit'

          forms = ["git commit -F - <<'EOF'\nfeat: x is 2\n\nThe body explains why.\nEOF",
                   "git commit -m \"$(cat <<'EOF'\nfeat: x is 2\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nEOF\n)\"",
                   "cd #{@wt} && git commit -q -F - <<'END-MSG'\nfeat: x is 2\n\nbody\nEND-MSG",
                   "git commit -m \"feat: x is 2\n\nsecond paragraph\""]
          forms.each do |cmd|
            r = bash!(cmd)
            assert_equal 'deny', r[:decision], "#{cmd.inspect}: #{r.inspect}"
            assert_includes r[:reason], "the operator's own permission rules", cmd
            refute r[:ran]
          end
          assert_equal head, git_out(@wt, 'rev-parse', 'HEAD'), 'nothing was committed'
          assert_equal forms.sort, refused_items(run).map { |i| i['command'] }.sort, 'each is queued for the operator'

          ['git status --short', 'git log -1 --format=%s', 'git diff --cached --stat'].each do |cmd|
            r = bash!(cmd)
            assert_equal 'allow', r[:decision], "#{cmd}: #{r[:reason]}"
            assert r[:ok], "#{cmd}: #{r[:err]}"
          end
          stop!('The commit waits for the operator.')
        end

        # --- 4. the agent's own storage ----------------------------------------------

        # R3 precedent/instructions P1: Read, Grep and Glob were allowed
        # unconditionally, so the actor could read precedents/raw/*.jsonl.
        def test_read_grep_and_glob_of_the_agents_storage_are_refused_in_a_bound_session
          run = impl_run!
          words = @paths.operator_words_path
          journal = File.join(@paths.run_dir(run.id), 'journal.jsonl')
          precedent = Dir.glob(File.join(@paths.precedents_dir, 'raw', '*.jsonl')).first
          [words, journal, precedent].each { |f| assert f && File.exist?(f), "the storage holds #{f.inspect}" }

          reads = [['Read', { 'file_path' => words }], ['Read', { 'file_path' => journal }],
                   ['Read', { 'file_path' => precedent }],
                   ['Read', { 'file_path' => '.kairos/storage/agent/operator_words.jsonl' }],
                   ['Grep', { 'pattern' => 'adopt', 'path' => @paths.root, 'output_mode' => 'content' }],
                   ['Grep', { 'pattern' => 'adopt', 'path' => @paths.data_dir }],
                   ['Grep', { 'pattern' => 'adopt', 'glob' => '.kairos/storage/agent/**/*.jsonl' }],
                   ['Glob', { 'pattern' => '**/*.jsonl', 'path' => @paths.root }],
                   ['Glob', { 'pattern' => '.kairos/storage/agent/precedents/raw/*.jsonl' }],
                   ['Glob', { 'pattern' => "#{@paths.precedents_dir}/**/*" }]]
          reads.each do |tool, input|
            decision, reason = tool_decision(tool, input)
            assert_equal 'deny', decision, "#{tool} #{input.inspect}: #{reason}"
            assert_includes reason, STORAGE, "#{tool} #{input.inspect}"
          end
          queued = refused_items(run)
          assert(queued.all? { |i| i['text'].include?(STORAGE) })
          assert_operator queued.size, :>=, 3

          [['Read', { 'file_path' => File.join(@wt, 'lib', 'x.rb') }], ['Grep', { 'pattern' => 'X_VALUE', 'path' => @wt }],
           ['Glob', { 'pattern' => '**/*.rb', 'path' => @wt }], ['Grep', { 'pattern' => 'X_VALUE' }],
           ['Read', { 'file_path' => File.join(@paths.policies_dir, 'p1.rb') }]].each do |tool, input|
            decision, reason = tool_decision(tool, input)
            assert_equal 'allow', decision, "#{tool} #{input.inspect}: #{reason}"
          end

          r = bash!("cat #{words}")
          assert r[:confined], r[:reason]
          refute r[:ok], "the operator's words were read inside confinement: #{r[:out]}"
          assert_match(/not permitted/i, r[:err])
          stop!('Looked at the worktree.')
        end

        # --- 5. adoption read by sentence --------------------------------------------

        # R3 instructions P1 / precedent_auditor P1: "で。以後は質問しないで進めて"
        # was refused; "って何ですか？" adopted.
        def test_an_adopting_sentence_adopts_and_a_question_about_it_does_not
          repo!('lib/x.rb' => "X_VALUE = 1\n", 'test/test_x.rb' => "exit 0\n")
          question = "adopt policy p1 #{hex} って何ですか？"
          operator_types(question, 'p-what')
          kept = File.readlines(@paths.operator_words_path).map { |l| JSON.parse(l)['text'] }
          assert_includes kept, question, 'the hook script keeps words that may adopt'
          out = host_tool('agent_items', 'action' => 'adopt_policy', 'policy' => 'p1')
          assert_equal 'refused', out['status'], out.inspect
          assert_match(/ask about the adoption/, out['reason'])
          assert_nil Policies.new(@paths).adopted
          assert_empty Policies.new(@paths).adoptions
          start = host_tool('agent_start', 'goal' => 'make x work', 'template' => 'impl_cycle', 'tests' => 'test')
          assert_equal 'refused', start['status'], 'no mandate, no run'
          assert_includes start['reason'], 'No adopted policy'

          operator_types("adopt policy p1 #{hex} で。以後は質問しないで進めて", 'p-adopt')
          out = host_tool('agent_items', 'action' => 'adopt_policy', 'policy' => 'p1')
          assert_equal 'adopted', out['status'], out.inspect
          assert_equal 'p1', Policies.new(@paths).adopted&.name
          start = host_tool('agent_start', 'goal' => 'make x work', 'template' => 'impl_cycle', 'tests' => 'test')
          assert_equal 'started', start['status'], start.inspect

          # The question typed again afterwards does not undo it or adopt again.
          operator_types(question, 'p-what2')
          out = host_tool('agent_items', 'action' => 'adopt_policy', 'policy' => 'p1')
          assert_equal 'refused', out['status']
          assert_equal 1, Policies.new(@paths).adoptions.size
          assert_equal 'p1', Policies.new(@paths).adopted&.name
        end

        # --- 6. a built-in command's arguments --------------------------------------

        # R3 precedent_auditor P1: `/goal S1まで実装を続けて下さい。` is recorded
        # with no origin and was lost from the operator's words.
        def test_a_goal_commands_arguments_are_the_operators_words_in_a_bound_run
          install_llm_stub!(:answer)
          before = 'まず設計 v0.5.1 を読んでから実装して下さい。'
          transcript_entry(builtin_entry('goal', before, 'p-goal0'))
          run = impl_run!
          assert_includes run.reload.verified_operator_words, before, 'a /goal typed before the start is a pre-start word'

          operator_types("/goal #{GOAL}", 'p-goal1', entry: builtin_entry('goal', GOAL, 'p-goal1'))
          # Neither a scheduled prompt nor a bare command is the operator's.
          transcript_entry(builtin_entry('loop', '継続して下さい。', 'p-loop').merge('isMeta' => true, 'promptSource' => 'system'))
          event('UserPromptSubmit', 'session_id' => SID, 'prompt' => '/loop 継続して下さい。', 'prompt_id' => 'p-loop',
                                    'transcript_path' => @transcript, 'cwd' => @root)
          operator_types('/compact', 'p-compact', entry: builtin_entry('compact', '', 'p-compact'))

          words = run.reload.verified_operator_words
          assert_equal GOAL, words.first, "the freshest verified word: #{words.inspect}"
          assert_includes words, before
          refute_includes words, '継続して下さい。'
          assert(run.journal.entries.any? { |e| e['kind'] == 'operator_words' && e['text'] == GOAL && e['prompt_id'] == 'p-goal1' })

          # The stand-in reads them: a question goes to it with the words.
          v = ask_question!
          assert_equal 'allow', v&.dig('hookSpecificOutput', 'permissionDecision'), v.inspect
          assert_equal({ 'Which port should the dev server use?' => '3000' }, v.dig('hookSpecificOutput', 'updatedInput', 'answers'))
          user = llm_calls.last['user']
          assert_includes user, "The operator's words in this session (freshest first):\n- #{GOAL}"
          assert_includes user, "- #{before}"
          refute_includes user, '継続して下さい。'
          d = run.reload.decisions.last
          assert_equal 'question', d['point']
          assert_includes d.dig('inputs', 'operator_words_sha256'), Digest::SHA256.hexdigest(GOAL)[0, 16]
        end

        # --- 7. harvest after a snapshot import --------------------------------------

        def ask_pair(q, opts)
          { 'question' => q, 'header' => 'h', 'multiSelect' => false, 'options' => opts.map { |o| { 'label' => o, 'description' => '' } } }
        end

        # One live transcript in HOME/.claude/projects and the snapshot the
        # operator took of it (answers the snapshot format quotes the way
        # the host's tool result does).
        def harvest_fixture
          proj = '-Users-operator-projects-x'
          dir = File.join(@home, '.claude', 'projects', proj)
          FileUtils.mkdir_p(dir)
          file = File.join(dir, 'sx.jsonl')
          q1 = '古い苗をどうしますか。'
          q2 = 'Planting §6 の配置表を、16株に合わせてどう書き直しますか。'
          a1 = '植えないが、記録としては残す'
          a2 = '8株（B. 東側の畝のみ）に絞る（推奨）'
          input = { 'questions' => [ask_pair(q1, %w[植える 植えない]), ask_pair(q2, ['8株', '16株'])] }
          long = "#{'畝と鉢で 3 品種がこう育ちます。' * 120}\n\n植え替えをどちらにしますか？"
          prose = '鉢に替えましょう。植え替えは週末になってから。'
          lines = [
            { 'type' => 'assistant', 'sessionId' => 'sx', 'timestamp' => '2026-09-21T10:00:00.000Z',
              'message' => { 'content' => [{ 'type' => 'tool_use', 'id' => 'tu1', 'name' => 'AskUserQuestion', 'input' => input }] } },
            { 'type' => 'user', 'sessionId' => 'sx', 'timestamp' => '2026-09-21T10:01:00.000Z',
              'toolUseResult' => { 'questions' => input['questions'], 'answers' => { q1 => a1, q2 => a2 } },
              'message' => { 'content' => [{ 'type' => 'tool_result', 'tool_use_id' => 'tu1', 'content' => 'answered' }] } },
            { 'type' => 'assistant', 'sessionId' => 'sx', 'timestamp' => '2026-09-21T14:30:32.504Z',
              'message' => { 'content' => [{ 'type' => 'text', 'text' => long }] } },
            typed_entry(prose, 'pp1').merge('sessionId' => 'sx', 'timestamp' => '2026-09-21T14:38:26.634Z')
          ]
          File.write(file, lines.map { |l| JSON.generate(l) }.join("\n") + "\n")
          snap = File.join(@tmp, 'snap')
          FileUtils.mkdir_p(snap)
          result = "Your questions have been answered: \"#{q1}\"=\"#{a1}\", \"#{q2}\"=\"#{a2}\" selected preview:\n" \
                   "| Bed | 500g |\n| BED_E_2 | 42.50 % |. You can now continue with the user's answers in mind."
          File.write(File.join(snap, 'askuserquestion_pairs_20261020.json'),
                     JSON.generate([{ 'proj' => proj, 'ts' => '2026-09-21T10:00:00.000Z', 'input' => input, 'result' => result,
                                      'tur' => { 'questions' => input['questions'] } }]))
          File.write(File.join(snap, 'prose_question_answers_20261020_operator_only.json'),
                     JSON.generate([{ 'source' => "/Users/operator/.claude/projects/#{proj}/sx.jsonl", 'project' => proj,
                                      'asked_at' => '2026-09-21T14:30:32.504Z', 'answered_at' => '2026-09-21T14:38:26.634Z',
                                      'question_tail' => long[-1500..], 'answer' => prose }]))
          [snap, [a1, a2, prose]]
        end

        def harvest!(data, *args)
          out, err, st = Open3.capture3({ 'HOME' => @home, 'KAIROS_AGENT_GLOBAL' => ENV.fetch('KAIROS_AGENT_GLOBAL'),
                                          'KAIROS_DATA_DIR' => nil, 'CLAUDE_PROJECT_DIR' => nil },
                                        RbConfig.ruby, HARVEST_BIN, '--data-dir', data, *args, chdir: @tmp)
          assert st.success?, "harvest failed: #{err}"
          out
        end

        # R3 precedent_auditor P2: snapshot import then harvest stored the
        # same answers twice (another source and time, so another id).
        def test_snapshot_import_then_harvest_stores_each_answer_once
          snap, answers = harvest_fixture
          data = File.join(@tmp, 'data_h')
          out = harvest!(data, '--import-snapshot', snap)
          assert_includes out, 'imported 3 snapshot records'
          assert_includes out, 'harvested 0 new records from transcripts', 'the live transcript holds the same answers'
          assert_includes harvest!(data), 'harvested 0 new records from transcripts'
          store = Precedents.new(Paths.new(data).precedents_dir).all
          assert_equal answers.sort, store.map { |r| r['words'] }.sort, 'each answer once'
          assert(store.all? { |r| r['source'].start_with?('snapshot:', '/Users/operator/') }, 'the snapshot records are the ones kept')

          # The other order stores each once too.
          other = File.join(@tmp, 'data_h2')
          assert_includes harvest!(other), 'harvested 3 new records from transcripts'
          assert_includes harvest!(other, '--import-snapshot', snap, '--no-transcripts'), 'imported 0 snapshot records'
          assert_equal answers.sort, Precedents.new(Paths.new(other).precedents_dir).all.map { |r| r['words'] }.sort
          refute Dir.exist?(File.join(@tmp, 'home', '.kairos_agent')), 'the global list stays in the tmpdir'
        end

        # --- 8. a stand-in failure keeps its cause ------------------------------------

        # R3 precedent_auditor P2: the cause of a stand-in failure was
        # discarded ("stand-in failed twice" only).
        def test_a_stand_in_whose_llm_raises_reports_the_cause_in_the_journals_decision
          install_llm_stub!(:fail)
          run = impl_run!
          v = ask_question!
          assert_equal 'deny', v&.dig('hookSpecificOutput', 'permissionDecision'), v.inspect
          assert_includes v.dig('hookSpecificOutput', 'permissionDecisionReason'), 'Queued for the operator: Which port'
          d = run.reload.decisions.last
          assert_equal %w[question operator_item 2], [d['point'], d['class'], d['calls'].to_s]
          assert_equal "#{StandIn::FAILED}: IOError: claude -p exited 1: Credit balance is too low (call 2)", d['reason'],
                       'the last call\'s error, class and message'
          assert_equal [1, 2], llm_calls.map { |c| c['n'] }
          assert(llm_calls.all? { |c| c['isolated'] == true }, 'the default llm asks for isolation')
          assert(run.open_items.any? { |i| i['item_kind'] == 'question' && i['text'].start_with?('Which port') })
          refute_nil d.dig('inputs', 'evidence_file')

          # A hazard the failing stand-in cannot rule ends the run, with the cause.
          out = stop!('Note: the API key was printed to the public CI log while testing.')
          assert_equal 'block', out&.dig('decision'), out.inspect
          run.reload
          assert_equal ['ended', 'hazard (not_ruled)'], [run.status, run.end_reason]
          h = run.decisions.last
          assert_equal 'hazard', h['point']
          assert_equal "#{StandIn::FAILED}: IOError: claude -p exited 1: Credit balance is too low (call 4)", h['reason']
        end

        # The stand-in cannot be built (llm_client's tool is missing): every
        # point fails with that cause (R3 operator_proxy P0's LoadError).
        def test_a_stand_in_that_cannot_load_reports_the_load_error_in_the_decision
          install_llm_stub!(nil)
          run = impl_run!
          v = ask_question!
          assert_equal 'deny', v&.dig('hookSpecificOutput', 'permissionDecision'), v.inspect
          d = run.reload.decisions.last
          assert_equal 'question', d['point']
          assert d['reason'].start_with?("#{StandIn::FAILED}: stand-in unavailable: LoadError: "), d['reason']
          assert_includes d['reason'], 'cannot load such file'
          assert(run.open_items.any? { |i| i['item_kind'] == 'question' })
        end

        # The actor's alert goes to the stand-in from the service
        # (agent_items alert); a raising llm keeps its cause there too, and
        # the run ends on the hazard it could not rule.
        def test_an_alert_ruled_by_a_raising_llm_keeps_the_cause_in_the_decision
          calls = []
          @stand_in = StandIn.new(policy: @policy, instruction_mode: '',
                                  llm: lambda do |system:, user:|
                                    calls << [system.size, user.size]
                                    raise Errno::ECONNREFUSED, "api.anthropic.com:443 (call #{calls.size})"
                                  end)
          run = impl_run!
          text = 'The API key in .env was committed and pushed to the public mirror.'
          out = host_tool('agent_items', 'action' => 'alert', 'run_id' => run.id, 'text' => text)
          assert_equal %w[run_ended not_ruled], [out['status'], out['ruling']], out.inspect
          assert_equal 2, calls.size
          d = run.reload.decisions.last
          assert_equal 'hazard', d['point']
          assert_equal "#{StandIn::FAILED}: Errno::ECONNREFUSED: Connection refused - api.anthropic.com:443 (call 2)", d['reason']
          assert_equal ['ended', 'hazard (not_ruled)'], [run.status, run.end_reason]
        end

        # --- variants of the R3 triggers --------------------------------------------

        # R3 P1 "adoption accepts the phrase asked as a question", with the
        # question typed as Japanese often is, without a question mark (the
        # hooks' and harvest's QUESTION_END count ですか/ますか/でしょうか as one).
        def test_an_adoption_asked_without_a_question_mark_does_not_adopt
          repo!('lib/x.rb' => "X_VALUE = 1\n", 'test/test_x.rb' => "exit 0\n")
          asked = ["adopt policy p1 #{hex} って何ですか", "adopt policy p1 #{hex} と打てば採用されますか",
                   "adopt policy p1 #{hex} を採用すべきでしょうか", "what does adopt policy p1 #{hex} do"]
          adopted = asked.each_with_index.select do |words, i|
            operator_types(words, "p-ask#{i}")
            out = host_tool('agent_items', 'action' => 'adopt_policy', 'policy' => 'p1')
            (out['status'] == 'adopted').tap { File.delete(@paths.adoptions_path) if File.exist?(@paths.adoptions_path) }
          end.map(&:first)
          unless adopted.empty?
            flunk("BUG: policies.rb:68 QUESTION is only ?/？, so a question about the adoption without the mark adopts: #{adopted.first(2).inspect}")
          end
          assert_nil Policies.new(@paths).adopted
        end

        # R3 P1 "adoption accepts a negation", with the operator deferring
        # ("not yet", "on hold", "wait") rather than negating.
        def test_an_adoption_deferred_in_words_does_not_adopt
          repo!('lib/x.rb' => "X_VALUE = 1\n", 'test/test_x.rb' => "exit 0\n")
          deferred = ["adopt policy p1 #{hex} はまだ", "adopt policy p1 #{hex} は保留", "adopt policy p1 #{hex} は待って"]
          adopted = deferred.each_with_index.select do |words, i|
            operator_types(words, "p-defer#{i}")
            out = host_tool('agent_items', 'action' => 'adopt_policy', 'policy' => 'p1')
            (out['status'] == 'adopted').tap { File.delete(@paths.adoptions_path) if File.exist?(@paths.adoptions_path) }
          end.map(&:first)
          unless adopted.empty?
            flunk("BUG: policies.rb:70 NEGATION lacks まだ/保留/待って, so a deferral of the adoption adopts: #{adopted.first(2).inspect}")
          end
          assert_nil Policies.new(@paths).adopted
        end

        # R3 P1 "the listener rule misses explicit binds with other flags":
        # a known bind flag whose value is a URL naming every interface.
        def test_a_bind_flag_given_as_a_url_to_every_interface_is_a_listener
          impl_run!
          missed = ['puma -b tcp://0.0.0.0:9292', 'bundle exec puma -b tcp://0.0.0.0:9292 config.ru',
                    'npx serve --listen tcp://0.0.0.0:3000'].reject do |cmd|
            r = bash!(cmd, execute: false)
            r[:decision] == 'deny' && r[:reason].include?(LISTENS)
          end
          flunk("BUG: guard.rb:418 EVERYWHERE is anchored, so a bind value tcp://0.0.0.0:<port> passes: #{missed.first(2).inspect}") unless missed.empty?
          assert_empty missed
        end
      end
    end
  end
end
