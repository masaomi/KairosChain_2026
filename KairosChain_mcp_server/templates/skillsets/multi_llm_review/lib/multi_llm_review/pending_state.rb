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
        def write(token, data)
          FileUtils.mkdir_p(root_dir)
          path = path_for(token)
          tmp = "#{path}.tmp.#{Process.pid}"
          File.write(tmp, JSON.pretty_generate(data))
          File.rename(tmp, path)
          path
        ensure
          File.unlink(tmp) if tmp && File.exist?(tmp)
        end

        # Returns parsed Hash, or nil if missing/invalid token.
        def load(token)
          return nil unless valid_token?(token)
          path = path_for(token)
          return nil unless File.exist?(path)
          JSON.parse(File.read(path))
        rescue JSON::ParserError
          nil
        end

        def delete(token)
          return false unless valid_token?(token)
          path = path_for(token)
          return false unless File.exist?(path)
          File.unlink(path)
          true
        end

        # Garbage-collect expired pending files. A file is expired iff:
        #   - it is NOT marked collected (collected entries are kept until
        #     deadline + retain_collected_seconds), AND
        #   - now > collect_deadline
        # Collected entries persist for idempotency replay until that retention
        # window also expires.
        def cleanup_expired!(now: Time.now, retain_collected_seconds: 3600)
          return 0 unless Dir.exist?(root_dir)
          removed = 0
          Dir.glob(File.join(root_dir, '*.json')).each do |path|
            data = (JSON.parse(File.read(path)) rescue nil)
            next unless data
            deadline = (Time.iso8601(data['collect_deadline']) rescue nil)
            next unless deadline
            collected = data['collected'] == true
            cutoff = collected ? deadline + retain_collected_seconds : deadline
            if now > cutoff
              File.unlink(path)
              removed += 1
            end
          rescue StandardError
            next
          end
          removed
        end
      end
    end
  end
end
