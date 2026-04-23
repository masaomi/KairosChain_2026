# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'
require 'time'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # File-backed pending state for two-phase delegation.
      #
      # Single-user, local-only. No locking, no auth — see design v0.2 §8.
      # Tokens are UUID v4. State files live at .kairos/multi_llm_review/pending/.
      module PendingState
        # Strict UUID v4: 8-4-4-4-12 lowercase hex, version nibble 4,
        # variant nibble in {8,9,a,b}.
        TOKEN_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

        module_function

        def root_dir
          File.join(Dir.pwd, '.kairos', 'multi_llm_review', 'pending')
        end

        def generate_token
          SecureRandom.uuid
        end

        def valid_token?(token)
          token.is_a?(String) && TOKEN_RE.match?(token)
        end

        def path_for(token)
          raise ArgumentError, "invalid token format: #{token.inspect}" unless valid_token?(token)
          File.join(root_dir, "#{token}.json")
        end

        # Atomic write: tmp file + rename. Survives mid-write interrupt.
        # Tmp name includes pid AND a random suffix to avoid collisions
        # from concurrent writers with the same pid (fork, thread).
        def write(token, data)
          FileUtils.mkdir_p(root_dir)
          path = path_for(token)
          tmp = nil
          tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
          File.write(tmp, JSON.pretty_generate(data))
          File.rename(tmp, path)
          path
        ensure
          begin
            File.unlink(tmp) if tmp && File.exist?(tmp)
          rescue Errno::ENOENT
            nil
          end
        end

        # Returns parsed Hash, or nil if missing/invalid token or unparseable.
        # Callers that need to distinguish corruption from absence should use
        # load_detailed instead.
        def load(token)
          result = load_detailed(token)
          result[:data]
        end

        # Richer load that distinguishes missing vs corrupt.
        # Returns Hash with :status (:ok | :missing | :invalid_token | :corrupt)
        # and :data (parsed Hash or nil). Corrupt files are also logged.
        def load_detailed(token)
          unless valid_token?(token)
            return { status: :invalid_token, data: nil }
          end
          path = path_for(token)
          unless File.exist?(path)
            return { status: :missing, data: nil }
          end
          data = JSON.parse(File.read(path))
          { status: :ok, data: data }
        rescue JSON::ParserError => e
          warn "[multi_llm_review::PendingState#load] JSON parse error at #{path}: #{e.message}"
          { status: :corrupt, data: nil, error: e.message, path: path }
        rescue Errno::ENOENT
          # TOCTOU: file deleted between exist? and read (e.g. by concurrent
          # cleanup_expired! or external process).
          { status: :missing, data: nil }
        end

        def delete(token)
          return false unless valid_token?(token)
          path = path_for(token)
          return false unless File.exist?(path)
          File.unlink(path)
          true
        rescue Errno::ENOENT
          # TOCTOU: concurrent deletion.
          false
        end

        # Garbage-collect expired pending files. A file is expired iff:
        #   - it is NOT marked collected (collected entries are kept until
        #     deadline + retain_collected_seconds), AND
        #   - now > collect_deadline
        # Collected entries persist for idempotency replay until that retention
        # window also expires.
        #
        # Also removes orphaned .tmp.* files older than 1 hour (crashed writes).
        #
        # Per-file failures are logged to STDERR and counted; they do NOT raise.
        # Returns a Hash {removed:, skipped_errors:}.
        # Stale files with no collect_deadline (schema drift, truncated write,
        # or corrupt JSON) are considered orphaned after this many seconds
        # based on file mtime. Default 24h.
        STALE_NO_DEADLINE_SECONDS = 86_400

        def cleanup_expired!(now: Time.now, retain_collected_seconds: 3600,
                             stale_no_deadline_seconds: STALE_NO_DEADLINE_SECONDS,
                             skip_token: nil)
          return { removed: 0, skipped_errors: 0 } unless Dir.exist?(root_dir)

          removed = 0
          skipped_errors = 0

          Dir.glob(File.join(root_dir, '*.json')).each do |path|
            begin
              basename = File.basename(path, '.json')
              next if skip_token && basename == skip_token

              # Parse attempt. If JSON is unreadable/corrupt, fall back to
              # mtime-based orphan cleanup so we don't accumulate forever.
              data = begin
                JSON.parse(File.read(path))
              rescue JSON::ParserError => e
                skipped_errors += 1
                warn "[multi_llm_review::PendingState#cleanup_expired] corrupt JSON at #{File.basename(path)}: #{e.message}"
                nil
              end

              deadline = nil
              if data.is_a?(Hash)
                deadline = Time.iso8601(data['collect_deadline']) rescue nil
              end

              if deadline
                collected = data['collected'] == true
                cutoff = collected ? deadline + retain_collected_seconds : deadline
                if now > cutoff
                  File.unlink(path)
                  removed += 1
                end
              else
                # No usable deadline (missing field or corrupt JSON).
                # Don't keep forever — treat as orphan after stale window.
                mtime = File.mtime(path) rescue nil
                if mtime && now - mtime > stale_no_deadline_seconds
                  File.unlink(path)
                  removed += 1
                  warn "[multi_llm_review::PendingState#cleanup_expired] removed stale file without deadline: #{File.basename(path)}"
                end
              end
            rescue Errno::ENOENT
              # Concurrent deletion — benign.
              next
            rescue StandardError => e
              skipped_errors += 1
              warn "[multi_llm_review::PendingState#cleanup_expired] skipping #{File.basename(path)}: #{e.class}: #{e.message}"
              warn e.backtrace.first(3).join("\n") if e.backtrace
              next
            end
          end

          # Orphaned tmp files (crashed writes) older than 1 hour.
          Dir.glob(File.join(root_dir, '*.json.tmp.*')).each do |path|
            begin
              mtime = File.mtime(path) rescue nil
              next unless mtime
              if now - mtime > 3600
                File.unlink(path)
                removed += 1
              end
            rescue Errno::ENOENT
              next
            rescue StandardError => e
              skipped_errors += 1
              warn "[multi_llm_review::PendingState#cleanup_expired] tmp skip #{File.basename(path)}: #{e.class}: #{e.message}"
              next
            end
          end

          { removed: removed, skipped_errors: skipped_errors }
        end
      end
    end
  end
end
