# frozen_string_literal: true

module KairosMcp
  # LifecycleHook protocol (24/7 v0.4 §2.3).
  #
  # A SkillSet advertises one or more lifecycle hooks in its skillset.json:
  #
  #   {
  #     "name": "daemon_runtime",
  #     "lifecycle_hooks": { "daemon_main": "KairosMcp::SkillSets::DaemonRuntime::MainLoop" }
  #   }
  #
  # Only one SkillSet may claim a given hook name. Conflicts raise at load
  # time (Conflict) — silent override would violate the audit guarantees of
  # the Bootstrap layer.
  module LifecycleHook
    class Conflict < StandardError; end
    class NotImplementedHook < StandardError; end
    # Lookup-phase failures (class not defined, not a Class, does not
    # include LifecycleHook when resolved from the constant).
    class UnknownClass < StandardError; end
    class ForbiddenNamespace < StandardError; end
    # R10→R11 (Codex P1): distinct exception for instantiation-phase
    # contract violations — specifically, a `.new` override that returns
    # an object not including LifecycleHook. Distinguishes programmatic
    # callers from lookup failures and lets bin/ map to a different
    # exit code without relying on call-site context.
    class InstanceViolation < StandardError; end

    # Allowlist for class-name resolution (R1 P1, 2-voice security):
    # skillset.json is untrusted input, so `Object.const_get` must not
    # instantiate arbitrary classes. Only classes under these namespaces
    # may be bound to a lifecycle hook.
    ALLOWED_NAMESPACES = [
      'KairosMcp::SkillSets::'
    ].freeze

    # Valid Ruby constant path: Foo::Bar::Baz (no leading colons).
    CLASS_NAME_RE = /\A[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*\z/

    def self.validate_class_name!(class_name)
      name = class_name.to_s
      unless name =~ CLASS_NAME_RE
        raise UnknownClass, "invalid class name: #{class_name.inspect}"
      end
      unless ALLOWED_NAMESPACES.any? { |prefix| name.start_with?(prefix) }
        raise ForbiddenNamespace,
              "class '#{name}' is not under an allowed namespace " \
              "(#{ALLOWED_NAMESPACES.join(', ')})"
      end
      name
    end

    # Contract an implementing class must fulfill.
    # Bootstrap calls run_main_loop(registry:, signal:) and expects the
    # callee to block until signal.shutdown_requested? is true, then return.
    def run_main_loop(registry:, signal:)
      raise NotImplementedHook, "#{self.class} must implement run_main_loop"
    end
  end
end
