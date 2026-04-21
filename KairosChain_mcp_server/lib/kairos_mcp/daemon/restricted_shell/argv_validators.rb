# frozen_string_literal: true

module KairosMcp
  class Daemon
    class RestrictedShell
      # Base validator: blocks shell metacharacters in all args.
      class BaseArgvValidator
        UNIVERSAL_FORBIDDEN = /[;&|`$(){}]|\n|\r/

        def self.validate!(argv)
          argv.each do |arg|
            if arg.match?(UNIVERSAL_FORBIDDEN)
              raise PolicyViolation, "forbidden character in arg: #{arg.inspect}"
            end
          end
          validate_specific!(argv)
        end

        def self.validate_specific!(argv)
          # Override in subclasses
        end
      end

      # Git: allowlisted subcommands + env scrub + forbidden flags.
      class GitArgvValidator < BaseArgvValidator
        ALLOWED_SUBCOMMANDS = %w[status diff log show rev-parse ls-files].freeze
        FORBIDDEN_FLAGS = %w[-c -C --exec-path --git-dir --work-tree].freeze

        def self.validate_specific!(argv)
          # Check global forbidden flags
          argv.each do |arg|
            # Exact match for short flags (-c, -C)
            raise PolicyViolation, "forbidden git flag: #{arg}" if arg == '-c' || arg == '-C'
            # Prefix match for long flags
            %w[--exec-path --git-dir --work-tree].each do |f|
              raise PolicyViolation, "forbidden git flag: #{arg}" if arg.start_with?(f)
            end
          end

          sub = argv.first
          raise PolicyViolation, 'git subcommand required' unless sub
          raise PolicyViolation, "git #{sub} not allowed" unless ALLOWED_SUBCOMMANDS.include?(sub)
        end
      end

      # Pandoc: forbidden filters + engine whitelist.
      class PandocArgvValidator < BaseArgvValidator
        FORBIDDEN_FLAGS = %w[
          --filter --lua-filter -F -L
          --include-in-header --include-before-body --include-after-body -H -B -A
          --data-dir --defaults -d --extract-media
        ].freeze

        ALLOWED_ENGINES = %w[xelatex pdflatex lualatex].freeze

        def self.validate_specific!(argv)
          argv.each_with_index do |arg, i|
            FORBIDDEN_FLAGS.each do |f|
              raise PolicyViolation, "pandoc #{f} forbidden" if arg == f || arg.start_with?("#{f}=")
            end

            # R2 residual: --pdf-engine must be bare name only (no path separators)
            if arg.start_with?('--pdf-engine=')
              engine = arg.split('=', 2).last
              validate_engine!(engine)
            elsif arg == '--pdf-engine' && i + 1 < argv.size
              validate_engine!(argv[i + 1])
            end

            # --pdf-engine-opt: strict allowlist
            if arg.start_with?('--pdf-engine-opt=')
              validate_engine_opt!(arg.split('=', 2).last)
            elsif arg == '--pdf-engine-opt' && i + 1 < argv.size
              validate_engine_opt!(argv[i + 1])
            end

            raise PolicyViolation, "pandoc URL argument forbidden" if arg.match?(%r{\Ahttps?://})
          end
        end

        def self.validate_engine!(engine)
          # R2 fix: reject any path — bare name only
          raise PolicyViolation, "pandoc engine must be bare name, got: #{engine}" if engine.include?('/')
          unless ALLOWED_ENGINES.include?(engine)
            raise PolicyViolation, "pandoc engine not allowed: #{engine} (allowed: #{ALLOWED_ENGINES})"
          end
        end

        def self.validate_engine_opt!(opt)
          allowed = ['-no-shell-escape', '-output-directory']
          unless allowed.any? { |a| opt == a || opt.start_with?("#{a}=") }
            raise PolicyViolation, "pandoc engine option not allowed: #{opt}"
          end
        end
      end

      # Xelatex: require -no-shell-escape, block shell-escape.
      class XelatexArgvValidator < BaseArgvValidator
        FORBIDDEN_FLAGS = %w[--shell-escape -shell-escape --enable-write18].freeze

        def self.validate_specific!(argv)
          argv.each do |arg|
            FORBIDDEN_FLAGS.each do |f|
              raise PolicyViolation, "xelatex #{f} forbidden" if arg == f
            end
          end
          unless argv.include?('-no-shell-escape')
            raise PolicyViolation, 'xelatex requires -no-shell-escape'
          end
        end
      end
    end
  end
end
