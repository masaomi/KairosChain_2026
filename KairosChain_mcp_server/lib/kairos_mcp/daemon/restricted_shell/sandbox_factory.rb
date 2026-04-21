# frozen_string_literal: true

require 'tmpdir'
require 'erb'

module KairosMcp
  class Daemon
    class RestrictedShell
      # SandboxFactory — generates platform-appropriate sandbox wrapping.
      module SandboxFactory
        def self.wrap(bin_path:, argv:, cwd:, allowed_paths:, network:)
          if macos?
            wrap_macos(bin_path, argv, cwd, allowed_paths, network)
          else
            # No sandbox available — require explicit opt-in
            unless ENV['KAIROS_SANDBOX_FALLBACK'] == 'unsafe_ok_i_know'
              raise SandboxError, 'no sandbox driver; set KAIROS_SANDBOX_FALLBACK=unsafe_ok_i_know'
            end
            SandboxContext.new(cmd: [bin_path, *argv], driver: :none_exec_only)
          end
        end

        def self.macos?
          RUBY_PLATFORM.include?('darwin') && File.executable?('/usr/bin/sandbox-exec')
        end

        def self.wrap_macos(bin_path, argv, cwd, allowed_paths, network)
          tmpdir = Dir.mktmpdir('kairos_sbpl')
          begin
            profile = render_sbpl(cwd: cwd, allowed_paths: allowed_paths, network: network)
            profile_path = File.join(tmpdir, 'profile.sb')
            File.write(profile_path, profile)
            cmd = ['/usr/bin/sandbox-exec', '-f', profile_path, bin_path, *argv]
            SandboxContext.new(cmd: cmd, driver: :sandbox_exec, tmpdir: tmpdir)
          rescue StandardError => e
            FileUtils.rm_rf(tmpdir) rescue nil
            raise SandboxError, "SBPL setup failed: #{e.message}"
          end
        end

        def self.render_sbpl(cwd:, allowed_paths:, network:)
          # F2 fix: validate + escape paths for SBPL injection prevention
          all_paths = [cwd, *allowed_paths]
          all_paths.each do |p|
            if p.match?(/["\\()\n\r]/)
              raise SandboxError, "path contains SBPL-unsafe characters: #{p.inspect}"
            end
          end
          allowed_read = allowed_paths.map { |p| "(subpath \"#{p}\")" }.join("\n  ")
          network_clause = network == :allow ? '(allow network-outbound)' : ''

          <<~SBPL
            (version 1)
            (deny default)
            (allow process-fork process-exec
              (subpath "/usr/bin")
              (subpath "/usr/local/bin")
              (subpath "/opt/homebrew/bin")
              (subpath "/opt/homebrew/Cellar")
              (subpath "/Library/TeX/texbin"))
            (allow file-read*
              (subpath "/usr/lib")
              (subpath "/usr/share")
              (subpath "/System/Library")
              (subpath "/Library/Fonts")
              (subpath "/opt/homebrew/lib")
              (subpath "/opt/homebrew/share")
              (subpath "/opt/homebrew/Cellar")
              #{allowed_read})
            (allow file-write*
              (subpath "#{cwd}"))
            (allow file-read-metadata
              (subpath "/usr")
              (subpath "/System")
              (subpath "/Library")
              (subpath "/opt/homebrew")
              #{allowed_read})
            (allow file-read* (literal "/dev/random") (literal "/dev/urandom") (literal "/dev/null"))
            (allow file-write-data (literal "/dev/null"))
            #{network_clause}
            (allow mach-lookup
              (global-name "com.apple.system.logger")
              (global-name "com.apple.system.notification_center"))
          SBPL
        end
      end
    end
  end
end
