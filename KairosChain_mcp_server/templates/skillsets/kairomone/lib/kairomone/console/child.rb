# frozen_string_literal: true

module Kairomone
  module Console
    # How the one Claude Code child is started. Every flag narrows what the
    # child reads or may do; none adds a permission.
    module Child
      SESSION_ID = /\A[0-9A-Za-z][0-9A-Za-z_-]{0,127}\z/

      module_function

      def argv(project:, flag_settings:, resume: nil, claude: 'claude')
        raise Refusal, 'The session to resume must be a Claude Code session id' unless resume.nil? || (resume.is_a?(String) && SESSION_ID.match?(resume))
        raise ArgumentError, 'claude must name an executable' unless claude.is_a?(String) && !claude.empty?
        list = [claude, '-p',
                '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose', '--replay-user-messages',
                '--permission-prompts', 'host', '--permission-prompt-tool', 'stdio', '--permission-mode', 'manual',
                '--setting-sources', '', '--disable-slash-commands', '--tools', Gate::BUILTINS.join(','),
                '--settings', JSON.generate(flag_settings),
                '--mcp-config', File.join(project.dir, '.mcp.json'), '--strict-mcp-config',
                '--append-system-prompt-file', project.skill_md_path]
        list += ['--resume', resume] if resume
        list
      end
    end

    # The watchdog process and the three pipes to the child inside it. Only
    # this object holds the lifeline's write end; it is close-on-exec, so no
    # process the console starts inherits it, and the kernel closes it however
    # the console ends — which is what makes the watchdog sweep its session.
    class ChildProcess
      WATCHDOG = File.join(Kairomone::PACKAGE_ROOT, 'scripts', 'kairomone_console_watchdog.rb')

      attr_reader :pid

      def initialize(argv:, cwd:, env: ENV.to_h, watchdog: WATCHDOG)
        raise ArgumentError, 'argv must be a nonempty list of strings' unless argv.is_a?(Array) && !argv.empty? && argv.all?(String)
        @argv = argv.dup.freeze
        @cwd = cwd
        @env = env.to_h
        @watchdog = watchdog
        @write_lock = Mutex.new
        @wait_lock = Mutex.new
        @status = nil
      end

      # The environment is passed whole and alone (unsetenv_others): the child
      # sees the console's own environment and nothing the console added.
      def start
        raise Error, 'The child was already started' if @pid
        stdin_r, @stdin = IO.pipe
        @stdout, stdout_w = IO.pipe
        @stderr, stderr_w = IO.pipe
        lifeline_r, @lifeline = IO.pipe
        begin
          @pid = Process.spawn(@env, RbConfig.ruby, @watchdog, '--', *@argv,
                               in: stdin_r, out: stdout_w, err: stderr_w, 3 => lifeline_r,
                               chdir: @cwd, unsetenv_others: true, close_others: true)
        rescue StandardError
          [@stdin, @stdout, @stderr, @lifeline].each(&:close)
          raise
        ensure
          [stdin_r, stdout_w, stderr_w, lifeline_r].each(&:close)
        end
        @stdin.sync = true
        @stdout.set_encoding(Encoding::UTF_8)
        @stderr.set_encoding(Encoding::UTF_8)
        self
      end

      # Raises IOError or Errno::EPIPE once the child is gone.
      def write(hash)
        line = JSON.generate(hash, max_nesting: false) + "\n"
        @write_lock.synchronize { @stdin.write(line) }
        true
      end

      def each_line(&block)
        @stdout.each_line(&block)
      rescue IOError
        nil
      end

      # Claude Code's diagnostics. The console never echoes them to its
      # terminal; they reach the page as notices.
      def stderr_lines(&block)
        @stderr.each_line(&block)
      rescue IOError
        nil
      end

      def close_lifeline
        @lifeline.close if @lifeline && !@lifeline.closed?
      rescue IOError
        nil
      end

      def wait
        @wait_lock.synchronize { @status ||= Process.wait2(@pid)[1] }
      end
    end
  end
end
