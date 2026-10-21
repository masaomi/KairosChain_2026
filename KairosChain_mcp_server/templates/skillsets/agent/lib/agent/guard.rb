# frozen_string_literal: true

require 'digest'
require 'shellwords'
require_relative 'confinement'

module KairosMcp
  module SkillSets
    module Agent
      # The guard (design v0.5.1 INV-2): every tool call of a bound session is
      # placed inside the line or refused. Deny by default: a tool the guard
      # does not know is refused. Inside = touches only what the run created
      # or its worktree and branch hold, reaches no one, touches nothing that
      # governs a run. Paths are placed by their resolved location, so a link
      # never carries a write across the line. Executed code is placed by
      # confinement; a shell command is also read segment by segment so the
      # obvious crossings (push, publish, shared git state) become clear items.
      class Guard
        Verdict = Struct.new(:kind, :reason, :updated_input, :created, :item, :decision,
                             keyword_init: true) do
          %i[allow rewrite refuse decision_point].each do |k|
            define_method("#{k}?") { kind == k }
          end
        end

        READ_ONLY_TOOLS = %w[Read Glob Grep LS NotebookRead ToolSearch Skill TaskOutput TaskStop TaskList TaskGet
                             ListMcpResourcesTool ReadMcpResourceTool ReadMcpResourceDirTool SubagentHandback
                             ListAgents].freeze
        # Tools that run a shell command: read for crossings, then confined.
        SHELL_TOOLS = %w[Bash Monitor].freeze
        SESSION_LOCAL_TOOLS = %w[TodoWrite TodoRead TaskCreate TaskUpdate ScheduleWakeup].freeze
        FILE_WRITE_TOOLS = %w[Edit Write MultiEdit NotebookEdit].freeze
        DECISION_TOOLS = %w[AskUserQuestion ExitPlanMode].freeze
        LOOKUP_TOOLS = %w[WebSearch WebFetch].freeze
        OUTSIDE_TOOLS = %w[EnterWorktree ExitWorktree CronCreate CronDelete RemoteTrigger PushNotification].freeze

        # KairosChain tools a run may call: those that only read local state,
        # and the agent's own. Anything that renders, records, or reaches a
        # peer is outside.
        KAIROS_READ_ONLY = /\A(knowledge_(get|list)|skills_(get|list|dsl_get|dsl_list)|chain_(status|history|verify)|
                              resource_(list|read)|document_status|state_(status|history)|hooks_status|
                              capability_status|tool_guide|pm_(query|digest)|introspection_(check|health)|
                              llm_status|multiuser_status|formalization_history|definition_(verify|drift)|
                              attestation_(list|verify)|chain_migrate_status|cg_status|hermes_status|
                              omakase_status|am_query|safe_file_(read|list)|safe_git_status)\z/x
        AGENT_OWN = /\Aagent_(start|status|advance|items|finish|stop)\z/

        # kill and pkill need no entry: confinement denies signals outside the
        # command's own process group (the host starts each command in its own).
        # rsync is read by its paths (a local copy stays inside).
        COMMAND_OUT = %w[gh scp sftp ssh sendmail mail mutt launchctl crontab sudo su
                         osascript open docker docker-compose podman kubectl at shortcuts].freeze
        BRANCH_LISTING = %w[--contains --no-contains --merged --no-merged --points-at -a --all -r --remotes -l --list
                            -v -vv --verbose --show-current --format].freeze
        CONFIG_WRITES = %w[--add --unset --unset-all --replace-all --rename-section --remove-section -e --edit].freeze

        # deny_patterns: the operator's Bash deny and ask rules as regexps, matched
        # against every command a shell line runs. settings_rules: the
        # operator's other deny and ask rules ({'kind', 'tool', 'spec'}); a
        # guard allow would not suppress the host's prompt for an ask rule, so
        # both are refused and queued (design §8).
        def initialize(run:, paths:, policy:, project_root:, deny_patterns: [], settings_rules: [])
          @run = run
          @paths = paths
          @policy = policy
          @project_root = real(project_root)
          @deny_patterns = deny_patterns
          @settings_rules = settings_rules
        end

        def decide(tool_name, tool_input, cwd: @project_root)
          input = tool_input || {}
          if (rule = settings_rule(tool_name, input, cwd))
            return refuse("the operator's own settings #{rule['kind']} #{rule['tool']}#{rule['spec'] ? "(#{rule['spec']})" : ''}",
                          command: "#{tool_name} #{input['file_path'] || input['url'] || ''}".strip, change: input)
          end
          return Verdict.new(kind: :decision_point, decision: tool_name) if DECISION_TOOLS.include?(tool_name)
          if (read = storage_read(tool_name, input, cwd))
            return refuse("#{read} is the agent's own storage (the operator's words, precedents, journals); " \
                          'a run does not read it', command: "#{tool_name} #{read}")
          end
          return Verdict.new(kind: :allow, reason: 'read-only') if READ_ONLY_TOOLS.include?(tool_name)
          return Verdict.new(kind: :allow, reason: 'session-local') if SESSION_LOCAL_TOOLS.include?(tool_name)
          return refuse("#{tool_name} acts outside the run's places") if OUTSIDE_TOOLS.include?(tool_name)
          return lookup(tool_name) if LOOKUP_TOOLS.include?(tool_name)
          return file_write(tool_name, input, cwd) if FILE_WRITE_TOOLS.include?(tool_name)
          return bash(input, cwd) if SHELL_TOOLS.include?(tool_name)
          return agent_tool(input) if %w[Agent Task].include?(tool_name)
          return send_message(input) if tool_name == 'SendMessage'
          return workflow(input, cwd) if tool_name == 'Workflow'
          return mcp(tool_name, input) if tool_name.start_with?('mcp__')

          refuse("unknown tool #{tool_name}: refused by default")
        end

        # Where a path lands, by its resolved location.
        def place(path)
          abs = real(path)
          wt = @run.worktree && real(@run.worktree)
          in_wt = wt && within?(abs, wt)
          return [:governing, abs] if governing?(abs, in_wt)
          return [(pinned_test?(abs) ? :pinned_test : :worktree), abs] if in_wt
          return [:created, abs] if own_places.any? { |d| within?(abs, d) }
          return [:created, abs] if @run.created_paths.reject { |p| p.start_with?('l2:') }.map { |p| real(p) }.include?(abs)

          repo = real(@run.target_repo.to_s)
          if !File.exist?(abs) && within?(abs, repo)
            # A new hidden file or directory configures tools the operator runs
            # (.envrc, .github, .vscode, .tool-versions): not the run's to add.
            hidden = abs.delete_prefix("#{repo}/").split('/').any? { |seg| seg.start_with?('.') }
            return [(hidden ? :hidden_new : :new_file), abs]
          end

          [:shared, abs]
        end

        # The run's own places outside the worktree: its report directory and
        # its scratch area.
        def own_places
          [File.join(real(@run.target_repo.to_s), 'log', 'agent_runs', @run.id), real(scratch_dir)]
        end

        # A delimiter is a word: quoted, anything up to the quote; bare, a
        # name that may carry - and . (<<END-MSG).
        HEREDOC = /\A<<(-?)[ \t]*(?:(['"])([^'"\n]+)\2|(\\)?([A-Za-z_][A-Za-z0-9_.-]*))/
        # A shell's -c, also among other options (-lc, -ec).
        SHELL_C = /\A-[A-Za-z]*c[A-Za-z]*\z/

        # Shell command segments, split on && || ; | & and newlines outside
        # quotes and substitutions.
        def self.segments(cmd)
          parse(cmd)[:segments]
        end

        # A shell line read as the shell reads it: a backslash-newline joins
        # lines, a comment is skipped, and single-quoted text is text. :inner
        # is what the line also runs as commands: $(...), <(...) and
        # backticks outside single quotes, and the body of a heredoc fed to a
        # shell. Any other heredoc body is data, though under a bare
        # delimiter (<<EOF, not <<'EOF') the shell still runs its $(...) and
        # backticks. With closer ')' the reading is of a $(...) and stops at
        # its closing parenthesis (:stop).
        def self.parse(cmd, i = 0, closer = nil)
          segs = []
          piped = []
          inner = []
          heredocs = []
          cur = +''
          quote = nil
          depth = 0
          while i < cmd.length
            c = cmd[i]
            if quote == "'"
              quote = nil if c == "'"
              cur << c
            elsif cmd[i, 2] == "\\\n"
              i += 1
            elsif c == '\\' && i + 1 < cmd.length
              cur << c << cmd[i + 1]
              i += 1
            elsif cmd[i, 2] == '$(' || c == '`' || (!quote && ['<(', '>('].include?(cmd[i, 2]))
              stop, text = substitution(cmd, i)
              inner << text if text
              cur << cmd[i...stop]
              i = stop
              next
            elsif quote
              quote = nil if c == '"'
              cur << c
            elsif ["'", '"'].include?(c)
              quote = c
              cur << c
            elsif c == '#' && (cur.empty? || cur.end_with?(' ', "\t"))
              i = (cmd.index("\n", i) || cmd.length) - 1
            elsif closer && c == ')' && depth.zero?
              break
            elsif cmd[i, 3] == '<<<'
              cur << '<<<'
              i += 2
            elsif cmd[i, 2] == '<<' && (m = cmd[i..].match(HEREDOC))
              heredocs << { delim: m[3] || m[5], dash: m[1] == '-', quoted: !(m[2] || m[4]).nil?, seg: segs.size }
              cur << m[0]
              i += m[0].length
              next
            elsif c == "\n" && !heredocs.empty?
              segs << cur
              piped << false
              cur = +''
              i = heredoc_bodies(cmd, i + 1, heredocs, segs, piped, inner)
              heredocs = []
              next
            elsif ['&&', '||'].include?(cmd[i, 2])
              segs << cur
              piped << false
              cur = +''
              i += 1
            elsif [';', '|', "\n", '&'].include?(c)
              segs << cur
              piped << (c == '|')
              cur = +''
            else
              depth += { '(' => 1, ')' => -1 }.fetch(c, 0) if closer
              cur << c
            end
            i += 1
          end
          segs << cur
          { segments: segs.map(&:strip).reject(&:empty?), inner: inner, stop: [i, cmd.length].min }
        end

        # Where the substitution at i ends, and the text it runs; an
        # arithmetic $((...)) runs none.
        def self.substitution(cmd, i)
          if cmd[i] == '`'
            j = i + 1
            j += cmd[j] == '\\' ? 2 : 1 while j < cmd.length && cmd[j] != '`'
            return [j + 1, cmd[i + 1...j]]
          end
          if cmd[i, 3] == '$(('
            j = i + 1
            depth = 0
            while j < cmd.length
              depth += { '(' => 1, ')' => -1 }.fetch(cmd[j], 0)
              j += 1
              break if depth.zero?
            end
            return [j, nil]
          end
          stop = parse(cmd, i + 2, ')')[:stop]
          [stop + 1, cmd[i + 2...stop]]
        end

        # Reads the bodies of the heredocs a line opened; returns where the
        # line after them starts.
        def self.heredoc_bodies(cmd, from, heredocs, segs, piped, inner)
          i = from
          heredocs.each do |h|
            body = +''
            while i < cmd.length
              nl = cmd.index("\n", i) || cmd.length
              line = cmd[i...nl]
              i = nl + 1
              break if (h[:dash] ? line.sub(/\A\t+/, '') : line).rstrip == h[:delim]

              body << line << "\n"
            end
            if fed_to_shell?(segs, piped, h[:seg]) then inner << body
            elsif !h[:quoted] then inner.concat(expansions(body))
            end
          end
          i
        end

        # Whether a heredoc opened in segment k is a shell's input, directly
        # or down a pipe (cat <<EOF | sh).
        def self.fed_to_shell?(segs, piped, k)
          loop do
            words = command_words(segs[k].to_s)
            return true if SHELLS.include?(File.basename(words.first.to_s)) && words.none? { |w| SHELL_C.match?(w) }
            return false unless piped[k]

            k += 1
          end
        end

        # The $(...) and backticks in text the shell expands but does not run
        # (a heredoc body under a bare delimiter).
        def self.expansions(text)
          out = []
          i = 0
          while i < text.length
            if text[i] == '\\'
              i += 2
            elsif text[i, 2] == '$(' || text[i] == '`'
              i, run = substitution(text, i)
              out << run if run
            else
              i += 1
            end
          end
          out
        end

        # Words that only lead into the command they precede.
        LEADERS = %w[if then else elif do while until ! time command builtin exec nohup env nice stdbuf caffeinate
                     timeout xargs noglob].freeze
        SHELLS = %w[bash sh zsh dash ksh].freeze

        # The command a segment runs, as words: shell keywords, case
        # patterns, grouping, variable assignments and wrapper words (with
        # their options) removed.
        def self.command_words(segment)
          invocation(segment).last
        end

        # A case pattern before its command (start) rm, *) rm): a word
        # closing on ) with a command after it. A subshell's closing word
        # (make) > log) is followed by nothing or a redirection.
        CASE_PATTERN = /\A[^()$`]+\)\z/

        # A segment as [the variable assignments before its command, the
        # command's words].
        def self.invocation(segment)
          words = begin
            Shellwords.split(segment)
          rescue ArgumentError
            segment.split
          end
          set = []
          loop do
            w = words.first
            break if w.nil?

            if w =~ /\A[({]+\z/
              words.shift
            elsif w =~ /\A[({]+/
              words[0] = w.sub(/\A[({]+/, '')
            elsif w =~ /\A[A-Za-z_][A-Za-z0-9_]*=/
              set << words.shift
            elsif w == 'case'
              words = (at = words.index('in')) ? words.drop(at + 1) : []
            elsif w.match?(CASE_PATTERN) && words[1] && !words[1].match?(/\A\d*[<>&]/)
              words.shift
            elsif LEADERS.include?(w)
              words.shift
              words.shift while words.first.to_s.start_with?('-') || words.first.to_s =~ /\A\d+[smhd]?\z/
            else
              break
            end
          end
          [set, words.map { |x| x.sub(/[)}]+\z/, '') }.reject(&:empty?)]
        end

        # Every command a shell line runs, as word lists: each segment, what
        # its substitutions and shell-fed heredocs run, and what a command
        # hands on to be run (sh -c, eval, find -exec).
        def self.commands(cmd, depth = 0)
          invocations(cmd, depth).map(&:last).reject(&:empty?)
        end

        # The same, as [assignments, words] pairs, one for each segment.
        def self.invocations(cmd, depth = 0)
          return [] if depth > 3

          read = parse(cmd)
          list = read[:segments].map { |seg| invocation(seg) }
          handed = list.flat_map { |_, words| handed_on(words) }
          list + (handed + read[:inner]).flat_map { |c| invocations(c, depth + 1) }
        end

        FIND_EXEC = %w[-exec -execdir -ok -okdir].freeze

        # The command text a command runs in turn: a shell's -c line, eval's
        # arguments, the command after find's -exec (up to its ; or +).
        def self.handed_on(words)
          name = File.basename(words.first.to_s)
          if SHELLS.include?(name)
            at = words.index { |x| SHELL_C.match?(x) }
            at && words[at + 1] ? [words[at + 1]] : []
          elsif name == 'eval'
            [words.drop(1).join(' ')]
          elsif name == 'find'
            words.each_index.select { |i| FIND_EXEC.include?(words[i]) }
                 .map { |i| Shellwords.join(words[(i + 1)..].take_while { |w| !%w[; +].include?(w) }) }
          else
            []
          end
        end

        # The spellings an operator's rule is matched against: the command as
        # written without its leaders, and git without its global options.
        def self.forms(words)
          out = [words.join(' ')]
          out << (['git'] + git_args(words[1..])).join(' ') if File.basename(words.first.to_s) == 'git'
          out
        end

        def self.git_args(args)
          a = args.dup
          while (o = a.first) && o.start_with?('-')
            a.shift
            a.shift if %w[-C -c --git-dir --work-tree --namespace].include?(o)
          end
          a
        end

        # Why a command (as words, or a segment string) crosses the line, or
        # nil. cwd: the directories its relative paths may be read from.
        def self.crossing(command, cwd: nil)
          words = command.is_a?(Array) ? command : command_words(command)
          cmd = File.basename(words.first.to_s)
          return nil if cmd.empty?
          return "#{cmd} acts outside the run's places" if COMMAND_OUT.include?(cmd)
          return git_crossing(words[1..], cwd: cwd) if cmd == 'git'
          return 'publishing a gem' if cmd == 'gem' && %w[push yank owner].include?(words[1])
          return 'publishing a package' if cmd == 'npm' && %w[publish unpublish].include?(words[1])
          return 'a release task' if %w[rake bundle].include?(cmd) && words.include?('release')
          return 'KairosChain installation' if cmd == 'kairos-chain' && %w[upgrade init install].include?(words[1])
          # Confinement cannot keep a listener on loopback (sandbox-exec's bind
          # filter takes no address); a command that says it listens on every
          # interface is refused, so the worktree is not served to the network.
          return 'a server listening on every network interface (bind it to 127.0.0.1)' if listens_everywhere?(words)
          return 'an upload or a write request' if %w[curl wget].include?(cmd) && sends?(cmd, words)
          if cmd == 'rsync'
            return 'rsync --daemon serves on the network' if words.include?('--daemon')
            remote = words.each_cons(2).any? { |prev, w| !RSYNC_VALUE.include?(prev) && w.match?(REMOTE_PATH) }
            return 'rsync to or from another host' if remote
          end

          nil
        end

        BIND_FLAG = /\A--?(host|hostname|bind|bind-address|b|listen|address|addr|ip)\z/
        BIND_FLAG_EQ = /\A--?(host|hostname|bind|bind-address|b|listen|address|addr|ip)=(.+)\z/
        # Flags that name the address only in the program they follow.
        PROGRAM_BIND_FLAGS = { 'php' => '-S', 'next' => '-H', 'jekyll' => '-H', 'flask' => '-h',
                               'http-server' => '-a' }.freeze
        # Every interface, also written as a URL (tcp://0.0.0.0:9292).
        EVERYWHERE = %r{\A([a-z][a-z0-9+.-]*://)?(0\.0\.0\.0|::|\[::\])(:\d+)?/?\z}i
        LOOPBACK = /\A(127\.0\.0\.1|localhost|::1|\[::1\])(:\d+)?\z/
        # Commands that read or print text: an address among their words is text.
        TEXT_COMMANDS = %w[grep egrep fgrep rg ag ack sed awk echo printf curl wget].freeze
        # A variable a server reads its address from (HOST, BIND_ADDR, ...).
        ADDRESS_VAR = /\A(?![A-Za-z0-9_]*(ALLOWED|HOSTS))[A-Za-z0-9_]*(HOST|BIND|ADDR|LISTEN)[A-Za-z0-9_]*=(.*)\z/i

        # A bind flag whose value is every interface; a bare --host (vite and
        # its kind listen on every interface then); or a server that binds
        # every interface by default without a loopback bind.
        def self.listens_everywhere?(words)
          return false if TEXT_COMMANDS.include?(File.basename(words.first.to_s))

          values = bind_values(words)
          return true if values.any? { |v| v.delete(%q('")).match?(EVERYWHERE) }
          # '*' as every interface only after a long bind flag (--ip='*'), not
          # after -b (ls -b *).
          return true if words.any? { |w| w.match?(/\A--(ip|host|bind|listen|bind-address|hostname)=['"]?\*['"]?\z/) } ||
                         words.each_cons(2).any? { |a, b| a.match?(/\A--(ip|host|bind|listen|bind-address|hostname)\z/) && b.delete(%q('")) == '*' }
          return true if words.each_with_index.any? { |w, i| w == '--host' && !words[i + 1].to_s.match?(/\A[^-]/) }

          serves_everywhere_by_default?(words) && values.none? { |v| v.match?(LOOPBACK) }
        end

        # The addresses a command's bind flags name.
        def self.bind_values(words)
          own = words.filter_map { |w| PROGRAM_BIND_FLAGS[File.basename(w).sub(/[\d.]+\z/, '')] }
          words.each_cons(2).filter_map { |a, b| b if a.match?(BIND_FLAG) || own.include?(a) } +
            words.filter_map { |w| w[BIND_FLAG_EQ, 2] || (w[2..] if w.length > 2 && own.include?(w[0, 2])) }
        end

        # python -m http.server and ruby -run -e httpd bind every interface
        # unless told otherwise.
        def self.serves_everywhere_by_default?(words)
          at = words.index { |w| File.basename(w).match?(/\A(python|ruby)[\d.]*\z/) }
          return false unless at

          rest = words[(at + 1)..]
          if File.basename(words[at]).start_with?('python')
            rest.each_cons(2).include?(%w[-m http.server]) || rest.include?('-mhttp.server')
          else
            rest.include?('-run') && (rest.each_cons(2).include?(%w[-e httpd]) || rest.include?('-ehttpd'))
          end
        end

        # An address variable set before a command, or exported, whose value
        # is every interface (HOST=0.0.0.0 npm run dev). Only assignments the
        # shell makes count; the same text in an argument is text.
        def self.sets_everywhere?(set, words)
          given = set + (words.first == 'export' ? words.drop(1) : [])
          given.any? { |a| (v = a[ADDRESS_VAR, 3]) && (v.match?(EVERYWHERE) || (v == '*' && a.match?(/BIND|LISTEN/i))) }
        end

        READ_METHODS = %w[GET HEAD OPTIONS].freeze

        # Whether curl or wget sends a body or asks for a method other than
        # GET, HEAD or OPTIONS.
        def self.sends?(cmd, words)
          body, method = if cmd == 'curl'
                           [/\A-[dFT]|\A--(data|form|upload-file|json)/, /\A(?:-X|--request(?==|\z))=?(.*)\z/]
                         else
                           [/\A--(post|body)-(data|file)/, /\A--method(?==|\z)=?(.*)\z/]
                         end
          return true if words.any? { |w| w.match?(body) }

          words.each_with_index.any? do |w, i|
            (m = w.match(method)) && !READ_METHODS.include?((m[1].empty? ? words[i + 1] : m[1]).to_s.upcase)
          end
        end

        # A path on another host: host:path, user@host:path, host::module,
        # rsync://host/... (a colon before any slash, as rsync reads it).
        REMOTE_PATH = %r{\A(rsync://|[^/-][^/]*:)}
        # rsync options whose value, given as the next word, may hold a colon.
        RSYNC_VALUE = %w[-e --rsh --chown --usermap --groupmap -f --filter --exclude --include -M --remote-option
                         --rsync-path].freeze

        def self.git_crossing(args, cwd: nil)
          a = git_args(args)
          sub = a.shift.to_s
          rest = a
          positional = rest.reject { |w| w.start_with?('-') }
          flags = rest.map { |w| w.split('=').first }
          case sub
          when 'push', 'filter-branch', 'update-ref', 'replace', 'notes', 'gc', 'prune', 'fast-import'
            "git #{sub} changes shared or remote refs"
          when 'tag'
            listing = positional.empty? ||
                      rest.any? { |w| %w[-l --list --contains --no-contains --points-at --merged --no-merged].include?(w.split('=').first) }
            listing ? nil : 'git tag creates or deletes a shared ref'
          when 'remote'
            rest.empty? || %w[-v show get-url].include?(rest.first) ? nil : 'git remote changes the shared remotes'
          when 'config'
            read = (flags & %w[--get --get-all --get-regexp --list -l --show-origin --show-scope]).any? ||
                   positional.size == 1 || %w[get list].include?(positional.first)
            read && (flags & CONFIG_WRITES).empty? ? nil : 'git config changes shared configuration'
          when 'stash'
            %w[list show].include?(rest.first) ? nil : 'git stash writes the shared stash'
          when 'branch'
            mutate = (flags & %w[-d -D -f -m -M -c -C --delete --force --move --copy --set-upstream-to -u
                                 --unset-upstream --edit-description]).any?
            listing = positional.empty? || (flags & BRANCH_LISTING).any?
            !mutate && listing ? nil : 'git branch creates, moves or deletes a shared ref'
          when 'checkout', 'switch'
            return nil if rest.include?('--')

            creates = rest.any? { |w| w =~ /\A-(b|B|c|C|t)\z|\A--(orphan|detach|track)/ }
            # Files named without --: a ref that is not a path followed by
            # paths (git moves no branch when paths are named, so these may
            # be deleted ones), or each one . or a path that exists (- is the
            # previous branch).
            path = ->(p) { p == '.' || Array(cwd).any? { |d| File.exist?(File.expand_path(p, d)) } }
            files = sub == 'checkout' && !rest.include?('-') &&
                    ((positional.size >= 2 && !path.call(positional.first)) || positional.all?(&path))
            creates || !files ? 'git checkout/switch leaves the run branch (use `git checkout <ref> -- <path>` for files)' : nil
          when 'worktree'
            rest.first == 'list' ? nil : 'git worktree changes shared worktrees'
          when 'reflog'
            %w[expire delete].include?(rest.first) ? 'git reflog rewrites shared history' : nil
          end
        end

        private

        def real(path)
          Confinement.real(File.expand_path(path.to_s))
        rescue Confinement::Error, SystemCallError
          File.expand_path(path.to_s)
        end

        # The agent's own storage: the operator's words, the precedent store
        # and its snapshots, the journals. A run reads none of it, by a tool
        # or by a confined command.
        def own_storage
          [@paths.root, File.join(@paths.data_dir, 'storage', 'agent_precedent_snapshots')].map { |d| real(d) }
        end

        STORAGE_READERS = %w[Read NotebookRead Glob Grep LS].freeze

        # Where a read tool would look into the agent's own storage, or nil:
        # its path, or below that path the fixed head of its pattern (Glob)
        # or file filter (Grep). A search from the data directory itself
        # passes through the storage too; one from above it (the project)
        # does not name it.
        def storage_read(tool, input, cwd)
          return nil unless STORAGE_READERS.include?(tool)

          base = File.expand_path((input['file_path'] || input['notebook_path'] || input['path'] || '.').to_s, cwd)
          filter = { 'Glob' => input['pattern'], 'Grep' => input['glob'] }[tool].to_s
          fixed = filter.split('/').take_while { |seg| !seg.match?(/[*?\[{]/) }.join('/')
          head = real(File.expand_path(fixed, base))
          data = real(@paths.data_dir)
          searches = %w[Glob Grep].include?(tool)
          inside = own_storage.any? { |s| within?(head, s) || (searches && within?(head, data) && within?(s, head)) }
          inside ? head : nil
        end

        # A lookup sends text the run composed outside; it is refused in every
        # run (design v0.6.3: public lookup is backlog).
        def lookup(tool)
          refuse("#{tool} sends a request outside; a run does not look things up on the web")
        end

        def file_write(tool, input, cwd)
          path = input['file_path'] || input['notebook_path'] || input['path']
          return refuse("#{tool} without a path") if path.to_s.empty?

          where, abs = place(File.expand_path(path, cwd))
          case where
          when :worktree, :created then Verdict.new(kind: :allow, reason: "#{where}: #{abs}")
          when :new_file then Verdict.new(kind: :allow, reason: "new file the run creates: #{abs}", created: abs)
          when :pinned_test then Verdict.new(kind: :decision_point, decision: 'pinned_test_change', reason: abs)
          when :governing then refuse("#{abs} governs runs (INV-2)", command: "#{tool} #{abs}", change: input)
          when :hidden_new
            refuse("#{abs} would be a new hidden file in the main checkout; such files configure tools the operator runs (INV-2)",
                   command: "#{tool} #{abs}", change: input)
          else refuse("#{abs} is shared state the run did not create (INV-2)", command: "#{tool} #{abs}", change: input)
          end
        end

        def bash(input, cwd)
          cmd = input['command'].to_s
          return refuse('empty command') if cmd.strip.empty?

          invocations = Guard.invocations(cmd)
          commands = invocations.map(&:last).reject(&:empty?)
          spelled = Guard.segments(cmd) + commands.flat_map { |w| Guard.forms(w) }
          if spelled.any? { |f| @deny_patterns.any? { |p| p.match?(f) } }
            return refuse("the operator's own permission rules deny or ask for part of this command", command: cmd)
          end
          if invocations.any? { |set, words| Guard.sets_everywhere?(set, words) }
            return refuse('a server listening on every network interface (bind it to 127.0.0.1); queued for the operator', command: cmd)
          end
          if (why = commands.map { |w| Guard.crossing(w, cwd: [cwd, @run.worktree].compact) }.compact.first)
            return refuse("#{why}; queued for the operator", command: cmd)
          end
          return refuse('confinement unavailable on this host', command: cmd) unless Confinement.available?

          wrapped = Confinement.wrap_command(cmd, writable: writable_places, scratch: scratch_dir,
                                                  worktree: @run.worktree, deny_read: own_storage,
                                                  deny_write: git_admin_files)
          Verdict.new(kind: :rewrite, reason: 'confined', updated_input: input.merge('command' => wrapped))
        rescue Confinement::Error => e
          refuse("cannot confine: #{e.message}", command: cmd)
        end

        def agent_tool(input)
          if %w[remote worktree].include?(input['isolation'].to_s)
            return refuse("an #{input['isolation']}-isolated subagent works outside the run's worktree")
          end

          Verdict.new(kind: :allow, reason: 'subagent under the same hooks')
        end

        # A workflow's agents run under the same hooks, but one isolated in a
        # worktree or remotely works outside the run's worktree; the script
        # (given, at scriptPath, or saved under its name) is read for that.
        def workflow(input, cwd)
          sources = []
          sources << input['script'].to_s if input['script']
          sources << read_script(File.expand_path(input['scriptPath'].to_s, cwd)) if input['scriptPath']
          if input['name'] && !input['script'] && !input['scriptPath']
            saved = [File.join(@project_root, '.claude', 'workflows'), File.expand_path('~/.claude/workflows')]
                    .map { |d| File.join(d, "#{input['name']}.js") }.find { |f| File.file?(f) }
            sources << read_script(saved)
          end
          if sources.empty? || sources.include?(nil)
            return refuse('the workflow script cannot be read, so its agents cannot be placed')
          end
          if (iso = sources.join("\n")[/isolation['"]?\s*:\s*['"](worktree|remote)/, 1])
            return refuse("the workflow asks for #{iso}-isolated agents, which work outside the run's worktree")
          end

          Verdict.new(kind: :allow, reason: 'subagents run under the same hooks')
        end

        def read_script(path)
          path && File.read(path)
        rescue SystemCallError
          nil
        end

        def send_message(input)
          to = input['to'].to_s
          return Verdict.new(kind: :allow, reason: 'message within this session') if to =~ /\A(main|a[0-9a-f]{8,})\z/

          refuse("a message to #{to} leaves this session")
        end

        def mcp(tool_name, input)
          _, server, tool = tool_name.split('__', 3)
          return refuse("MCP server #{server} is outside the line by default") unless server.to_s.downcase.include?('kairos')
          return Verdict.new(kind: :allow, reason: 'agent tool') if AGENT_OWN.match?(tool)
          return Verdict.new(kind: :allow, reason: 'kairos read-only') if KAIROS_READ_ONLY.match?(tool)
          return context_save(input) if tool == 'context_save'
          return refuse('reviews in a run are dispatched by agent_advance (INV-3)') if tool.to_s.start_with?('multi_llm_review')

          refuse("#{tool} changes governing or shared state, or reaches someone (INV-2)")
        end

        def context_save(input)
          name = input['name'].to_s
          existing = Dir.glob(File.join(@paths.data_dir, 'context', '*', name)).any?
          return refuse("L2 entry #{name} exists and was not created by this run") if existing && !@run.created_paths.include?("l2:#{name}")

          Verdict.new(kind: :allow, reason: 'new L2 entry', created: "l2:#{name}")
        end

        EDIT_TOOLS = %w[Edit Write MultiEdit NotebookEdit].freeze
        READ_TOOLS = %w[Read Glob Grep NotebookRead].freeze

        def settings_rule(tool, input, cwd)
          @settings_rules.find do |r|
            rt = r['tool'].to_s.sub(/__\*\z/, '')
            named = rt == tool || tool.start_with?("#{rt}__") ||
                    (rt == 'Edit' && EDIT_TOOLS.include?(tool)) || (rt == 'Read' && READ_TOOLS.include?(tool))
            named && spec_matches?(r['spec'], tool, input, cwd)
          end
        end

        # Path rules in the host's spelling: //abs, ~/home, /project-relative,
        # and cwd-relative; WebFetch(domain:x). An unread spec matches.
        def spec_matches?(spec, tool, input, cwd)
          return true if spec.nil? || spec.empty? || spec == '*'

          if (d = spec[/\Adomain:(.+)\z/, 1])
            host = (input['url'].to_s[%r{\A\w+://([^/:]+)}, 1] || '').downcase
            return host == d.downcase || host.end_with?(".#{d.downcase}")
          end
          path = input['file_path'] || input['notebook_path'] || input['path']
          return true unless path && (EDIT_TOOLS + READ_TOOLS).include?(tool)

          glob = if spec.start_with?('//') then spec[1..]
                 elsif spec.start_with?('~/') then File.expand_path(spec)
                 elsif spec.start_with?('/') then File.join(@project_root, spec)
                 else File.expand_path(spec, cwd)
                 end
          # Both spellings of each: /tmp/x is /private/tmp/x here.
          given = File.expand_path(path, cwd)
          head = glob[/\A[^*?\[{]*\//]
          globs = [glob, head ? File.join(real(head), glob.delete_prefix(head)) : glob].uniq
          flags = File::FNM_PATHNAME | File::FNM_DOTMATCH | File::FNM_EXTGLOB
          globs.product([given, real(given)].uniq).any? do |g, abs|
            File.fnmatch(g, abs, flags) || (g.end_with?('/**') && abs.start_with?(g.delete_suffix('**')))
          end
        end

        def refuse(reason, command: nil, change: nil)
          Verdict.new(kind: :refuse, reason: reason, item: { 'text' => reason, 'command' => command, 'change' => change })
        end

        # Names compare case-insensitively: on this filesystem claude.md opens
        # CLAUDE.md.
        # In the worktree only its own .git and any .claude govern; a .git
        # deeper inside is a fixture or a vendored repository.
        def governing?(abs, in_wt)
          parts = abs.split('/').map(&:downcase)
          return true if Paths::INSTRUCTION_FILES.map(&:downcase).include?(File.basename(abs).downcase)
          if in_wt
            inside = parts.drop(real(@run.worktree).split('/').size)
            return inside.first == '.git' || inside.include?('.claude')
          end
          return true if parts.include?('.git')

          @paths.governing_roots(@project_root).any? { |g| within?(abs, real(g)) }
        end

        def pinned_test?(abs)
          @run.pinned.values.any? { |p| (p['tests'] || {}).keys.map { |k| real(k) }.include?(abs) }
        end

        def within?(inner, outer)
          inner == outer || inner.start_with?(outer.end_with?('/') ? outer : "#{outer}/")
        end

        def scratch_dir
          File.join('/tmp', 'kairos_agent_runs', @run.id, 'scratch')
        end

        # Each created file by itself, never its directory: a directory in the
        # main checkout holds other writers' files.
        def writable_places
          places = [@run.worktree].compact
          places += @run.created_paths.reject { |p| p.start_with?('l2:') }.map { |p| [:literal, p] }
          places << File.join(real(@run.target_repo.to_s), 'log', 'agent_runs', @run.id)
          places + git_places
        end

        def git_places
          admin = git_admin_dir
          return [] unless admin

          Confinement.git_places(git_common_dir(admin), admin, @run.branch.to_s)
        end

        # The repository's common directory, as the admin dir's commondir
        # file names it (relative to the admin dir).
        def git_common_dir(admin)
          File.expand_path(File.read(File.join(admin, 'commondir')).strip, admin)
        rescue SystemCallError
          File.expand_path('../..', admin)
        end

        def git_admin_files
          admin = git_admin_dir
          admin ? Confinement.git_admin_files(admin) : []
        end

        def git_admin_dir
          wt = @run.worktree
          return nil unless wt && File.file?(File.join(wt, '.git'))

          dir = File.read(File.join(wt, '.git'))[/gitdir:\s*(.+)/, 1]&.strip
          dir && File.expand_path(dir, wt)
        rescue Errno::ENOENT, Errno::EISDIR
          nil
        end
      end
    end
  end
end
