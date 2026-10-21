# frozen_string_literal: true

require 'shellwords'
require 'fileutils'

module KairosMcp
  module SkillSets
    module Agent
      # Confined execution (design v0.5.1 INV-2): code a run executes — the
      # host's Bash commands and the SkillSet's own re-run of a phase's check —
      # runs under macOS sandbox-exec. Writable: the run's places only, never
      # the worktree's .git link, instruction files or .claude directories
      # inside it, in any letter case: on this filesystem claude.md opens
      # CLAUDE.md, and the profile spells each name case-blind rather than
      # rely on sandbox-exec matching paths without case (it does here, but
      # does not document it). Network: connections to this host only; unix
      # sockets only inside the run's places (no Docker or other daemons).
      # Listening is not limited: sandbox-exec's address filter takes only *
      # or localhost, and for a local address localhost matches 0.0.0.0 and
      # the LAN address too. No signals outside the command's own process
      # group; no launching of programs that act outside (launchd, Apple
      # events, opening apps or URLs, remote shells, privilege). Every
      # embedded path is realpath-resolved: an unresolved path would silently
      # no-op.
      module Confinement
        class Error < StandardError; end

        SANDBOX_EXEC = '/usr/bin/sandbox-exec'
        DENIED_PROGRAMS = %w[/bin/launchctl /usr/bin/open /usr/bin/osascript /usr/bin/crontab /usr/bin/ssh
                             /usr/bin/scp /usr/bin/sftp /usr/bin/sudo /usr/bin/su /usr/sbin/sshd /usr/bin/at
                             /usr/bin/shortcuts /usr/bin/automator].freeze

        module_function

        def available?
          File.executable?(SANDBOX_EXEC)
        end

        # The resolved location of a path that may not exist yet: the deepest
        # existing ancestor resolved, and a dangling link followed to where a
        # write through it would land.
        def real(path, depth = 0)
          raise Error, "too many links: #{path}" if depth > 40

          File.realpath(path)
        rescue Errno::ENOENT, Errno::ENOTDIR
          if File.symlink?(path)
            return real(File.expand_path(File.readlink(path), File.dirname(path)), depth + 1)
          end

          parent = File.dirname(path)
          raise Error, "unresolvable path: #{path}" if parent == path

          File.join(real(parent, depth + 1), File.basename(path))
        rescue Errno::ELOOP
          raise Error, "link loop: #{path}"
        end

        def sbpl_string(p)
          raise Error, "path unsafe for SBPL: #{p}" if p.match?(/["\\\n]/)

          %("#{p}")
        end

        def sbpl_regex_literal(p)
          Regexp.escape(p).gsub('"', '\\"')
        end

        # A name as a regex matching it in any letter case.
        def sbpl_regex_any_case(name)
          Regexp.escape(name).gsub(/[A-Za-z]/) { |c| "[#{c.upcase}#{c.downcase}]" }
        end

        # writable: directories (subpath) or [:literal, file] pairs.
        def profile(writable:, worktree: nil, deny_read: [], deny_write: [])
          lines = ['(version 1)', '(allow default)', '(deny file-write*)']
          writable.each do |w|
            if w.is_a?(Array) && w.first == :literal
              f = real(w.last)
              lines << "(allow file-write* (literal #{sbpl_string(f)}) (literal #{sbpl_string("#{f}.lock")}))"
            else
              lines << "(allow file-write* (subpath #{sbpl_string(real(w))}))"
            end
          end
          lines << '(allow file-write* (subpath "/dev"))'
          # /bin/bash 3.2 writes here-document bodies to /var/tmp/sh-thd*
          # (it ignores TMPDIR for them) after checking the directory is
          # writable: exactly those, nothing else in /var/tmp.
          lines << '(allow file-write* (literal "/private/var/tmp") (regex #"^/private/var/tmp/sh-thd[^/]*$"))'
          lines << '(deny file-write* (subpath "/dev/disk") (subpath "/dev/rdisk"))'
          if worktree
            wt = real(worktree)
            lines << "(deny file-write* (literal #{sbpl_string(File.join(wt, '.git'))}))"
            lines << %((deny file-write* (regex #"^#{sbpl_regex_literal(wt)}/(.*/)?#{sbpl_regex_any_case('.claude')}/")))
          end
          names = %w[CLAUDE AGENTS GEMINI].map { |n| sbpl_regex_any_case(n) }.join('|')
          lines << %((deny file-write* (regex #"/(#{names})(#{sbpl_regex_any_case('.local')})?#{sbpl_regex_any_case('.md')}$")))
          deny_write.each { |p| lines << "(deny file-write* (literal #{sbpl_string(real(p))}))" }
          deny_read.each { |p| lines << "(deny file-read* (subpath #{sbpl_string(real(p))}))" }
          lines << '(deny network-outbound)'
          # Only a remote loopback address is allowed. A local-address filter
          # must not be added: on macOS 14 `local ip "localhost:*"` also lets
          # connects to external and LAN addresses through. (A loopback connect
          # is refused about once in a hundred; that is the price.)
          lines << '(allow network-outbound (remote ip "localhost:*"))'
          writable.reject { |w| w.is_a?(Array) }.each do |w|
            lines << "(allow network-outbound (remote unix-socket (subpath #{sbpl_string(real(w))})))"
          end
          lines << '(deny signal (target others))'
          lines << "(deny process-exec #{DENIED_PROGRAMS.map { |p| "(literal #{sbpl_string(p)})" }.join(' ')})"
          lines.join("\n") + "\n"
        end

        # A Bash command string rewritten to run confined, with TMPDIR inside
        # the scratch area so temporary files stay in the run's places.
        def wrap_command(command, writable:, scratch:, worktree: nil, deny_read: [], deny_write: [])
          FileUtils.mkdir_p(scratch)
          prof = profile(writable: writable + [scratch], worktree: worktree, deny_read: deny_read, deny_write: deny_write)
          ['env', "TMPDIR=#{real(scratch)}", SANDBOX_EXEC, '-p', prof, '/bin/bash', '-c', command]
            .map { |a| Shellwords.escape(a) }.join(' ')
        end

        # Argument vector for the SkillSet's own confined runs.
        def argv(cmd_argv, writable:, scratch:, worktree: nil, deny_read: [], deny_write: [])
          FileUtils.mkdir_p(scratch)
          prof = profile(writable: writable + [scratch], worktree: worktree, deny_read: deny_read, deny_write: deny_write)
          ['env', "TMPDIR=#{real(scratch)}", SANDBOX_EXEC, '-p', prof, *cmd_argv]
        end

        # The git paths a commit on the run branch needs, in a linked worktree:
        # shared objects, the worktree's own admin directory, and exactly the
        # run branch's ref and reflog (not its siblings).
        def git_places(git_common_dir, worktree_admin_dir, branch)
          [File.join(git_common_dir, 'objects'),
           worktree_admin_dir,
           [:literal, File.join(git_common_dir, 'refs', 'heads', branch)],
           [:literal, File.join(git_common_dir, 'logs', 'refs', 'heads', branch)]]
        end

        # The admin files that say where a linked worktree's repository is and
        # how it is configured: never writable by what the run executes.
        def git_admin_files(worktree_admin_dir)
          %w[commondir gitdir config.worktree].map { |f| File.join(worktree_admin_dir, f) }
        end
      end
    end
  end
end
