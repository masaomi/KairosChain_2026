# frozen_string_literal: true

module KairosMcp
  class Daemon
    class RestrictedShell
      # BinaryResolver — resolves short names to absolute paths at exec time.
      # R2 residual: uses File.realpath for homebrew symlinks + prefix check.
      module BinaryResolver
        ALLOWED_BINS = {
          'git' => {
            candidates: %w[/usr/bin/git /opt/homebrew/bin/git /usr/local/bin/git],
            validator: 'KairosMcp::Daemon::RestrictedShell::GitArgvValidator'
          },
          'pandoc' => {
            candidates: %w[/opt/homebrew/bin/pandoc /usr/local/bin/pandoc /usr/bin/pandoc],
            validator: 'KairosMcp::Daemon::RestrictedShell::PandocArgvValidator'
          },
          'xelatex' => {
            candidates: %w[/Library/TeX/texbin/xelatex /usr/bin/xelatex /opt/homebrew/bin/xelatex],
            validator: 'KairosMcp::Daemon::RestrictedShell::XelatexArgvValidator'
          }
        }.freeze

        FORBIDDEN_BINS = {
          'ruby'  => 'interpreter = arbitrary code exec',
          'sh'    => 'shell expansion',
          'bash'  => 'shell expansion',
          'zsh'   => 'shell expansion',
          'curl'  => 'network exfil — use safe_http_*',
          'wget'  => 'network exfil',
          'ssh'   => 'lateral movement',
          'scp'   => 'exfil',
          'rsync' => 'exfil; use safe_file_*'
        }.freeze

        # Trusted prefixes for resolved binary paths.
        TRUSTED_PREFIXES = %w[
          /usr/bin/ /usr/local/bin/ /opt/homebrew/bin/
          /opt/homebrew/Cellar/ /Library/TeX/texbin/
        ].freeze

        def self.resolve!(short_name)
          name = short_name.to_s
          if FORBIDDEN_BINS.key?(name)
            raise PolicyViolation, "binary forbidden: #{name} (#{FORBIDDEN_BINS[name]})"
          end

          spec = ALLOWED_BINS[name]
          raise PolicyViolation, "binary not in allowlist: #{name}" unless spec

          # R2 residual: resolve symlinks via realpath + verify trusted prefix
          path = spec[:candidates].find do |candidate|
            next false unless File.exist?(candidate)
            real = File.realpath(candidate) rescue nil
            next false unless real
            File.executable?(real) && File.file?(real) && trusted_path?(real)
          end
          raise ResolverError, "no candidate for #{name}: tried #{spec[:candidates]}" unless path

          real_path = File.realpath(path)
          { short: name, path: real_path, validator: Object.const_get(spec[:validator]) }
        end

        def self.trusted_path?(path)
          TRUSTED_PREFIXES.any? { |prefix| path.start_with?(prefix) }
        end
      end
    end
  end
end
