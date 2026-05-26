# frozen_string_literal: true

require 'digest'

module KairosMcp
  module SkillSets
    module KairosHookProjector
      # Structural guarantee of zero side effect on a configurable set of
      # watched paths, per design v0.2 §7.2 DoD-0-4 and Inv-6.
      #
      # Usage:
      #   assertion = BootTimeAssertion.new(watch_paths: [...])
      #   assertion.snapshot_pre!
      #   <do read-only work>
      #   assertion.verify_post!   # raises StructuralAssertionFailure on any drift
      #
      # The assertion captures (sha256, mtime_ns, size) for each watched path,
      # or :absent if the path does not exist. Any pre/post mismatch is treated
      # as a structural violation: absent->present, present->absent,
      # content change, or mtime advance.
      class BootTimeAssertion
        class StructuralAssertionFailure < StandardError; end

        attr_reader :watch_paths

        def initialize(watch_paths:)
          @watch_paths = Array(watch_paths).map(&:to_s)
          @pre = nil
          @post = nil
        end

        def snapshot_pre!
          @pre = snapshot
          self
        end

        def verify_post!
          raise 'snapshot_pre! must be called before verify_post!' if @pre.nil?

          @post = snapshot
          diffs = diff(@pre, @post)
          return self if diffs.empty?

          raise StructuralAssertionFailure,
                "stage 0 side-effect-zero violation: #{diffs.inspect}"
        end

        def snapshots
          { pre: @pre, post: @post }
        end

        private

        def snapshot
          @watch_paths.each_with_object({}) do |path, acc|
            acc[path] = if File.exist?(path)
                         { sha256: Digest::SHA256.file(path).hexdigest,
                           mtime_ns: File.stat(path).mtime.to_r * 1_000_000_000,
                           size: File.size(path) }
                       else
                         :absent
                       end
          end
        end

        def diff(pre, post)
          pre.keys.each_with_object([]) do |path, drifts|
            a = pre[path]
            b = post[path]
            next if a == b

            drifts << { path: path, pre: a, post: b }
          end
        end
      end
    end
  end
end
