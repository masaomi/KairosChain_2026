# frozen_string_literal: true

require 'io/wait'

module Kairomone
  module Console
    # How the owner opens and stops the console (design 0.9 Inv 10, N8).
    # Without --open the one-time URL is printed at the owner's terminal, as
    # in 0.8. With --open it goes only to the browser: no start URL or session
    # secret reaches terminal output, a log, a pipe or the hosted session's
    # context, however the console is started, and a console that cannot hand
    # its URL to the browser stops. --detach (only with --open) leaves the
    # console running in the background, writing its lines only through the
    # filter below; --stop signals the process the console lock names, and
    # only when that process is the console script.
    module Launch
      # The console script as a command line names it: an argument that is
      # the script, by itself or at the end of a path.
      CONSOLE_SCRIPT = %r{(?:\A|[\s/])kairomone_console\.rb(?:\s|\z)}
      # The start URL's shape, dropped even when its value is not one the
      # filter has seen (a URL of another console).
      URL_SHAPE = %r{127\.0\.0\.1:\d+/#}
      PS = File.executable?('/bin/ps') ? '/bin/ps' : 'ps'
      STOP_WAIT_SECONDS = 20
      REPORT_WAIT_SECONDS = 90

      class BrowserFailure < Kairomone::Error; end

      # Hands a URL to the system browser: macOS open, else xdg-open, or the
      # program a test names. The URL is its one argument, with no shell; its
      # output goes nowhere, since a launcher may echo what it was given. A
      # launcher still running after the wait holds the browser it started
      # (xdg-open's fallback waits for it), so that counts as opened.
      class Opener
        WAIT_SECONDS = 15

        def self.system_command = RUBY_PLATFORM.include?('darwin') ? 'open' : 'xdg-open'

        def initialize(command: nil, wait: WAIT_SECONDS)
          @command = command.nil? || command.empty? ? self.class.system_command : command
          @wait = wait
        end

        # nil once the browser has the URL; otherwise why not, never naming the URL.
        def open(url)
          name = File.basename(@command)
          pid = begin
            Process.spawn(@command, url, in: File::NULL, out: File::NULL, err: File::NULL, close_others: true)
          rescue SystemCallError => e
            return "#{name} could not be started (#{e.class.name.split('::').last})"
          end
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @wait
          loop do
            _, status = Process.wait2(pid, Process::WNOHANG)
            return status.success? ? nil : "#{name} ended with #{status.exitstatus ? "status #{status.exitstatus}" : "signal #{status.termsig}"}" if status
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              Process.detach(pid)
              return nil
            end
            sleep 0.05
          end
        end
      end

      # Drops every line that holds a value the console's Secret issued, or
      # the start URL's shape; passes every other line unchanged.
      class OutputFilter
        def initialize(secret)
          @secret = secret
        end

        def pass?(line) = !(@secret.holds_any?(line) || URL_SHAPE.match?(line.to_s.b))

        # Points this process's standard output and error — whatever writes
        # to them, Ruby's own warnings included — at a pipe whose lines reach
        # the log only through pass?. The detached console has no terminal.
        def capture!(log)
          reader, writer = IO.pipe
          $stdout.reopen(writer)
          $stderr.reopen(writer)
          writer.close
          $stdout.sync = true
          $stderr.sync = true
          @log = log
          @thread = Thread.new do
            reader.each_line { |line| @log.write(line) if pass?(line) }
          rescue IOError, SystemCallError
            nil
          ensure
            reader.close unless reader.closed?
          end
          self
        end

        # Lets what was written reach the log before the process ends.
        def finish
          return unless @thread

          $stdout.flush
          $stderr.flush
          $stdout.reopen(File::NULL, 'w')
          $stderr.reopen(File::NULL, 'w')
          @thread.join(2)
        rescue IOError, SystemCallError
          nil
        end
      end

      module_function

      # The detached console leaves the terminal's session, reads nothing
      # from the terminal and keeps none of the descriptors the starting
      # process' caller reads (a pipe to Claude Code's ! included), so that
      # caller finishes when the starting process does.
      def detach_self!
        Process.setsid
        $stdin.reopen(File::NULL)
      end

      # The starting process of --detach waits for the one line the detached
      # console reports, prints it and returns the exit status. Nothing it
      # prints can hold the URL: the detached console sends status words and
      # refusals only, through its filter.
      def await_detached(reader, pid, out:, err:, stop_hint:, wait: REPORT_WAIT_SECONDS)
        line = reader.wait_readable(wait) ? reader.gets : :timeout
        reader.close
        case line
        when :timeout
          signal(pid, 'TERM')
          err.call("The console did not open your browser within #{wait} s, so it was stopped.")
          1
        when nil
          err.call('The console ended before it opened your browser; see the console log in the data directory\'s run/ folder.')
          1
        else
          word, detail = line.chomp.split("\t", 2)
          case word
          when 'opened'
            out.call("Opened in your browser. The console runs in the background; stop it with: #{stop_hint}")
            0
          when 'browser'
            err.call("Your browser could not be opened (#{detail}), so the console stopped. Start it without --open to see its URL at your terminal.")
            1
          when 'refused'
            err.call(detail.to_s)
            1
          else
            err.call("The console stopped after an internal error (#{detail}).")
            1
          end
        end
      end

      # The PID the console lock names, once it is checked to be the console
      # script: TERM, then wait for it to end. => what to tell the owner.
      def stop(project, wait: STOP_WAIT_SECONDS)
        pid = project.running_console_pid
        command = command_line(pid)
        unless console_command?(command)
          raise Refusal, "The process the console lock names (PID #{pid}) is not the Kairomone console script; nothing was signalled"
        end

        signal(pid, 'TERM')
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
        sleep 0.1 while alive?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        alive?(pid) ? "Asked the Kairomone console (PID #{pid}) to stop; it has not ended yet." : "Kairomone console stopped (PID #{pid})."
      end

      # A ruby process whose arguments include the console script. ps joins
      # the arguments with spaces, so a Ruby whose path holds one is
      # recognised by that path (this Ruby's, which kairomone.rb console
      # starts the console with); any other by its first word.
      def console_command?(command, ruby: RbConfig.ruby)
        return false unless command.is_a?(String) && !command.empty?

        interpreter = (ruby.is_a?(String) && !ruby.empty? && (command == ruby || command.start_with?("#{ruby} "))) ||
                      File.basename(command.split(/\s+/, 2).first.to_s).start_with?('ruby')
        interpreter && CONSOLE_SCRIPT.match?(command)
      end

      def command_line(pid)
        out = IO.popen([PS, '-ww', '-o', 'command=', '-p', pid.to_s], err: File::NULL, &:read)
        out.to_s.strip
      rescue SystemCallError, IOError
        ''
      end

      def alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def signal(pid, name)
        Process.kill(name, pid)
      rescue SystemCallError
        nil
      end
    end
  end
end
