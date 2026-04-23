# frozen_string_literal: true

# Phase 1 Step 1.1 tests — Bootstrap layer (24/7 v0.4 §2.2–§2.3).
# Covers: LifecycleHook protocol, SignalHandle, ToolRegistry hook
# registration + conflict detection, bin/kairos-chain-daemon dry-run paths.

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/signal_handle'
require 'kairos_mcp/lifecycle_hook'
require 'kairos_mcp/tool_registry'
require 'kairos_mcp/skillset'

class TestSignalHandle < Minitest::Test
  def test_starts_unset
    h = KairosMcp::SignalHandle.new
    refute h.shutdown_requested?
    refute h.reload_requested?
    refute h.diagnostic_requested?
  end

  def test_request_shutdown_sets_flag
    h = KairosMcp::SignalHandle.new
    h.request_shutdown
    assert h.shutdown_requested?
  end

  def test_request_shutdown_is_idempotent
    h = KairosMcp::SignalHandle.new
    2.times { h.request_shutdown }
    assert h.shutdown_requested?
  end

  def test_reload_flag_independently
    h = KairosMcp::SignalHandle.new
    h.request_reload
    assert h.reload_requested?
    refute h.shutdown_requested?
  end

  def test_diagnostic_flag_independently
    h = KairosMcp::SignalHandle.new
    h.request_diagnostic
    assert h.diagnostic_requested?
    refute h.shutdown_requested?
  end

  def test_consume_reload_returns_and_clears
    h = KairosMcp::SignalHandle.new
    h.request_reload
    assert h.consume_reload!
    refute h.reload_requested?
    refute h.consume_reload!  # second consume is a no-op
  end

  def test_consume_diagnostic_returns_and_clears
    h = KairosMcp::SignalHandle.new
    h.request_diagnostic
    assert h.consume_diagnostic!
    refute h.diagnostic_requested?
  end

  def test_reload_ticket_does_not_lose_edge_between_read_and_clear
    # R2 Codex P1 — simulate: consumer reads seen, trap fires and
    # increments seen, consumer then accumulates. Next consume picks up
    # the missed edge. Prior bool implementation would lose it.
    h = KairosMcp::SignalHandle.new
    h.request_reload                # seen=1, consumed=0
    # Emulate the race by forcing the two steps of consume to straddle
    # a new trap: we can't interleave directly in single-threaded test
    # code, so we simulate by calling request_reload mid-consume via a
    # method that stubs the second step.
    seen_at_read = h.instance_variable_get(:@reload_seen)
    h.request_reload                # trap fires → seen=2
    diff = seen_at_read - h.instance_variable_get(:@reload_consumed)
    h.instance_variable_set(:@reload_consumed,
      h.instance_variable_get(:@reload_consumed) + diff)
    # After this simulated race, consumed=1, seen=2 — the second edge
    # must still be observable on a subsequent consume.
    assert h.reload_requested?, 'edge missed — ticket counter broken'
    assert h.consume_reload!
    refute h.reload_requested?
  end

  def test_multiple_reloads_before_consume_collapse_to_one_true
    h = KairosMcp::SignalHandle.new
    5.times { h.request_reload }
    assert h.consume_reload!
    refute h.consume_reload!  # all 5 edges collapsed to a single consume
  end
end

class TestLifecycleHookProtocol < Minitest::Test
  def test_default_raises_not_implemented
    klass = Class.new { include KairosMcp::LifecycleHook }
    assert_raises(KairosMcp::LifecycleHook::NotImplementedHook) do
      klass.new.run_main_loop(registry: nil, signal: nil)
    end
  end

  def test_conflict_is_a_standard_error
    assert_kind_of Class, KairosMcp::LifecycleHook::Conflict
    assert_operator KairosMcp::LifecycleHook::Conflict, :<, StandardError
  end

  def test_validate_class_name_accepts_allowed_namespace
    assert_equal 'KairosMcp::SkillSets::Fake::MainLoop',
      KairosMcp::LifecycleHook.validate_class_name!('KairosMcp::SkillSets::Fake::MainLoop')
  end

  def test_validate_class_name_rejects_foreign_namespace
    assert_raises(KairosMcp::LifecycleHook::ForbiddenNamespace) do
      KairosMcp::LifecycleHook.validate_class_name!('Evil::Backdoor')
    end
  end

  def test_validate_class_name_rejects_malformed
    assert_raises(KairosMcp::LifecycleHook::UnknownClass) do
      KairosMcp::LifecycleHook.validate_class_name!('not a class')
    end
  end
end

# Helper: a ToolRegistry with no SkillSets loaded (bypasses register_tools).
class BareRegistry < KairosMcp::ToolRegistry
  def register_tools
    # no-op for unit tests — we only exercise lifecycle_hook methods
  end
end

module KairosMcp
  module SkillSets
    module Fake
    end
  end
end

module KairosMcp::SkillSets::Fake
  class MainLoop
    include KairosMcp::LifecycleHook
    def run_main_loop(registry:, signal:)
      :ran
    end
  end

  class Other
    include KairosMcp::LifecycleHook
    def run_main_loop(registry:, signal:)
      :other
    end
  end

  class NotAHook
    # deliberately does NOT include LifecycleHook
  end

  class NeedsArg
    include KairosMcp::LifecycleHook
    def initialize(required)
      @required = required
    end
  end

  # R5 edge cases — must all be rejected by the :req/:keyreq check.
  class NeedsArgPlusSplat  # arity = -2
    include KairosMcp::LifecycleHook
    def initialize(required, *rest); end
  end

  class NeedsKeywordArg
    include KairosMcp::LifecycleHook
    def initialize(required:); @required = required; end
  end

  class SplatOnly  # arity = -1; must be accepted
    include KairosMcp::LifecycleHook
    def initialize(*args); end
  end

  class OptionalOnly  # arity = -1; must be accepted
    include KairosMcp::LifecycleHook
    def initialize(a = 1); @a = a; end
  end

  # R6 (Codex P1): custom `.new` override. initialize takes a required
  # arg, but `.new` takes none and supplies the default — the lifecycle
  # hook loader must see `.new`'s signature, not `initialize`'s.
  class CustomNewAcceptsZero
    include KairosMcp::LifecycleHook
    def self.new
      allocate.tap { |o| o.send(:initialize, :default) }
    end
    def initialize(required); @required = required; end
  end

  # Opposite: initialize accepts zero, but `.new` requires an arg.
  class CustomNewRequiresArg
    include KairosMcp::LifecycleHook
    def self.new(token)
      allocate.tap { |o| o.send(:initialize); o.instance_variable_set(:@t, token) }
    end
    def initialize; end
  end

  # R7 (4-voice P1/P2): inherited custom `.new`. Parent overrides `.new`
  # with required arg; child inherits it. `singleton_class.instance_methods(false)`
  # would miss this; `method(:new).owner != Class` catches it.
  class InheritedCustomNewParent
    def self.new(token)
      allocate.tap { |o| o.send(:initialize); o.instance_variable_set(:@t, token) }
    end
    def initialize; end
  end

  class InheritedCustomNewChild < InheritedCustomNewParent
    include KairosMcp::LifecycleHook
    # No own .new; inherits parent's
  end

  # R7 (4.7 P3): forwarding `.new` (only rest/keyrest/block) must fall
  # back to inspecting `initialize` — otherwise a required-arg
  # initializer would incorrectly pass because `.new`'s parameters list
  # has no `:req`.
  class ForwarderNewWithRequiredInit
    include KairosMcp::LifecycleHook
    def self.new(*args, **kwargs, &blk)
      super
    end
    def initialize(required); @required = required; end
  end

  # R9 (4.7 P3): pathological `.new` returns an unrelated object that
  # does NOT include LifecycleHook. find_lifecycle_hook must detect this.
  class PathologicalNew
    include KairosMcp::LifecycleHook
    def self.new; 'not an instance'; end
    def initialize; end
  end

  # R12→R13 (2-voice P1): `.new` returns a BasicObject descendant that
  # does not respond to .class, .is_a?, .inspect. Guard must not blow up.
  class PathologicalNewBasicObject
    include KairosMcp::LifecycleHook
    def self.new
      Class.new(BasicObject).new
    end
    def initialize; end
  end
end

class TestToolRegistryLifecycleHooks < Minitest::Test
  def setup
    @r = BareRegistry.new
  end

  def test_find_returns_nil_when_unregistered
    assert_nil @r.find_lifecycle_hook(:daemon_main)
  end

  def test_register_and_find
    @r.register_lifecycle_hook(:daemon_main, 'KairosMcp::SkillSets::Fake::MainLoop',
                               skillset_name: 'daemon_runtime')
    instance = @r.find_lifecycle_hook(:daemon_main)
    assert_instance_of KairosMcp::SkillSets::Fake::MainLoop, instance
    assert_equal :ran, instance.run_main_loop(registry: @r, signal: nil)
  end

  def test_string_hook_name_is_symbolized
    @r.register_lifecycle_hook('daemon_main', 'KairosMcp::SkillSets::Fake::MainLoop',
                               skillset_name: 'daemon_runtime')
    refute_nil @r.find_lifecycle_hook(:daemon_main)
    refute_nil @r.find_lifecycle_hook('daemon_main')
  end

  def test_conflict_between_skillsets_raises
    @r.register_lifecycle_hook(:daemon_main, 'KairosMcp::SkillSets::Fake::MainLoop',
                               skillset_name: 'daemon_runtime')
    err = assert_raises(KairosMcp::LifecycleHook::Conflict) do
      @r.register_lifecycle_hook(:daemon_main, 'KairosMcp::SkillSets::Fake::Other',
                                 skillset_name: 'rival_runtime')
    end
    assert_match(/daemon_runtime/, err.message)
    assert_match(/rival_runtime/, err.message)
  end

  def test_reregister_same_skillset_same_class_is_idempotent
    @r.register_lifecycle_hook(:daemon_main, 'KairosMcp::SkillSets::Fake::Other',
                               skillset_name: 'daemon_runtime')
    @r.register_lifecycle_hook(:daemon_main, 'KairosMcp::SkillSets::Fake::Other',
                               skillset_name: 'daemon_runtime')
    assert_equal [:daemon_main], @r.lifecycle_hook_names
  end

  def test_reregister_same_skillset_different_class_raises
    # R1 P2 (3-voice): silent overwrite within same skillset was allowed.
    @r.register_lifecycle_hook(:daemon_main, 'KairosMcp::SkillSets::Fake::MainLoop',
                               skillset_name: 'daemon_runtime')
    err = assert_raises(KairosMcp::LifecycleHook::Conflict) do
      @r.register_lifecycle_hook(:daemon_main, 'KairosMcp::SkillSets::Fake::Other',
                                 skillset_name: 'daemon_runtime')
    end
    assert_match(/different class/, err.message)
  end

  def test_register_rejects_class_outside_namespace
    # R1 P1 (2-voice security): skillset.json is untrusted.
    assert_raises(KairosMcp::LifecycleHook::ForbiddenNamespace) do
      @r.register_lifecycle_hook(:daemon_main, 'Evil::Backdoor',
                                 skillset_name: 'malicious')
    end
  end

  def test_find_raises_unknown_class_when_constant_missing
    # R1 P1 (3-voice): NameError must surface as UnknownClass.
    @r.register_lifecycle_hook(:daemon_main,
      'KairosMcp::SkillSets::Fake::NotDefinedYet',
      skillset_name: 'daemon_runtime')
    assert_raises(KairosMcp::LifecycleHook::UnknownClass) do
      @r.find_lifecycle_hook(:daemon_main)
    end
  end

  def test_find_raises_when_class_does_not_include_lifecycle_hook
    # Guard against hooking a random class with a compatible namespace.
    @r.register_lifecycle_hook(:daemon_main, 'KairosMcp::SkillSets::Fake::NotAHook',
                               skillset_name: 'daemon_runtime')
    assert_raises(KairosMcp::LifecycleHook::UnknownClass) do
      @r.find_lifecycle_hook(:daemon_main)
    end
  end

  def test_find_lets_constructor_argumenterror_propagate
    # R8: static constructor-signature inspection removed (R5–R7 review
    # history — forwarder semantics are undecidable statically). A hook
    # whose .new raises propagates the original exception; bin/ rescues
    # at the entry point and exits 3 with a readable message.
    @r.register_lifecycle_hook(:daemon_main, 'KairosMcp::SkillSets::Fake::NeedsArg',
                               skillset_name: 'daemon_runtime')
    assert_raises(ArgumentError) { @r.find_lifecycle_hook(:daemon_main) }
  end

  def test_find_accepts_splat_only_initializer
    @r.register_lifecycle_hook(:daemon_main,
      'KairosMcp::SkillSets::Fake::SplatOnly',
      skillset_name: 'daemon_runtime')
    refute_nil @r.find_lifecycle_hook(:daemon_main)
  end

  def test_find_accepts_optional_only_initializer
    @r.register_lifecycle_hook(:daemon_main,
      'KairosMcp::SkillSets::Fake::OptionalOnly',
      skillset_name: 'daemon_runtime')
    refute_nil @r.find_lifecycle_hook(:daemon_main)
  end

  def test_find_respects_custom_self_new_accepts_zero
    @r.register_lifecycle_hook(:daemon_main,
      'KairosMcp::SkillSets::Fake::CustomNewAcceptsZero',
      skillset_name: 'daemon_runtime')
    refute_nil @r.find_lifecycle_hook(:daemon_main)
  end

  def test_lifecycle_hook_class_returns_class_without_instantiating
    # R8→R9: class lookup is separable from instantiation.
    @r.register_lifecycle_hook(:daemon_main, 'KairosMcp::SkillSets::Fake::MainLoop',
                               skillset_name: 'daemon_runtime')
    klass = @r.lifecycle_hook_class(:daemon_main)
    assert_equal KairosMcp::SkillSets::Fake::MainLoop, klass
  end

  def test_lifecycle_hook_class_returns_nil_when_unregistered
    assert_nil @r.lifecycle_hook_class(:nonexistent)
  end

  def test_find_rejects_pathological_new_returning_wrong_type
    # R9→R11: distinct InstanceViolation (was UnknownClass). The class
    # IS known; the violation is at instantiation.
    @r.register_lifecycle_hook(:daemon_main,
      'KairosMcp::SkillSets::Fake::PathologicalNew',
      skillset_name: 'daemon_runtime')
    err = assert_raises(KairosMcp::LifecycleHook::InstanceViolation) do
      @r.find_lifecycle_hook(:daemon_main)
    end
    assert_match(/does not include KairosMcp::LifecycleHook/, err.message)
  end

  def test_find_rejects_basicobject_return_from_new_without_crashing
    # R12→R13 (2-voice P1): BasicObject descendant from .new must be
    # rejected cleanly — guard formatting must not call methods that
    # would themselves raise on BasicObject.
    @r.register_lifecycle_hook(:daemon_main,
      'KairosMcp::SkillSets::Fake::PathologicalNewBasicObject',
      skillset_name: 'daemon_runtime')
    err = assert_raises(KairosMcp::LifecycleHook::InstanceViolation) do
      @r.find_lifecycle_hook(:daemon_main)
    end
    assert_match(/does not include KairosMcp::LifecycleHook/, err.message)
    assert_match(/PathologicalNewBasicObject\.new returned/, err.message)
  end

  def test_find_does_not_mask_internal_argumenterror
    # R3→R4 preserved: if a valid zero-arg hook raises ArgumentError
    # internally during initialize, it must propagate.
    ns = KairosMcp::SkillSets::Fake
    unless ns.const_defined?(:RaisesInside)
      ns.const_set(:RaisesInside, Class.new do
        include KairosMcp::LifecycleHook
        def initialize
          raise ArgumentError, 'internal boom'
        end
      end)
    end
    @r.register_lifecycle_hook(:daemon_main, 'KairosMcp::SkillSets::Fake::RaisesInside',
                               skillset_name: 'daemon_runtime')
    err = assert_raises(ArgumentError) { @r.find_lifecycle_hook(:daemon_main) }
    assert_equal 'internal boom', err.message
  end
end

class TestSkillsetLifecycleHooksField < Minitest::Test
  def test_returns_declared_hooks
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'skillset.json'), JSON.generate(
        'name' => 'daemon_runtime',
        'version' => '0.1.0',
        'lifecycle_hooks' => { 'daemon_main' => 'Fake::MainLoop' }
      ))
      ss = KairosMcp::Skillset.new(dir)
      assert_equal({ 'daemon_main' => 'Fake::MainLoop' }, ss.lifecycle_hooks)
    end
  end

  def test_returns_empty_hash_when_absent
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'skillset.json'), JSON.generate(
        'name' => 'plain', 'version' => '0.1.0'
      ))
      assert_equal({}, KairosMcp::Skillset.new(dir).lifecycle_hooks)
    end
  end

  def test_non_hash_value_is_coerced_to_empty
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'skillset.json'), JSON.generate(
        'name' => 'broken', 'version' => '0.1.0',
        'lifecycle_hooks' => ['not a hash']
      ))
      assert_equal({}, KairosMcp::Skillset.new(dir).lifecycle_hooks)
    end
  end

  def test_non_string_values_are_dropped
    # R1 P3 (4.7): malformed hooks (non-string values) must not blow up
    # downstream in Object.const_get.
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'skillset.json'), JSON.generate(
        'name' => 'partial', 'version' => '0.1.0',
        'lifecycle_hooks' => {
          'daemon_main' => 'KairosMcp::SkillSets::X::Y',
          'bad_entry'   => 123,
          'empty'       => ''
        }
      ))
      hooks = KairosMcp::Skillset.new(dir).lifecycle_hooks
      assert_equal({ 'daemon_main' => 'KairosMcp::SkillSets::X::Y' }, hooks)
    end
  end
end

class TestDaemonBinary < Minitest::Test
  BIN = File.expand_path('bin/kairos-chain-daemon', __dir__)

  def test_help_exits_zero
    Dir.mktmpdir do |dir|
      out, status = Open3.capture2('ruby', BIN, '--help', chdir: dir)
      assert status.success?, "help should succeed; got #{status}\n#{out}"
      assert_match(/Usage: kairos-chain-daemon/, out)
    end
  end

  def test_no_runtime_installed_exits_2
    Dir.mktmpdir do |dir|
      out, err, status = Open3.capture3('ruby', BIN, '--data-dir', dir, chdir: dir)
      assert_equal 2, status.exitstatus,
                   "stdout=#{out.inspect} stderr=#{err.inspect}"
      assert_match(/daemon runtime SkillSet not installed/, err)
    end
  end

  def test_empty_data_dir_exits_4
    # R1 P3 (4.7): --data-dir '' must fail fast at startup.
    Dir.mktmpdir do |dir|
      out, err, status = Open3.capture3('ruby', BIN, '--data-dir', '', chdir: dir)
      assert_equal 4, status.exitstatus,
                   "stdout=#{out.inspect} stderr=#{err.inspect}"
      assert_match(/must not be empty/, err)
    end
  end

  def test_nonexistent_data_dir_parent_exits_4
    Dir.mktmpdir do |dir|
      bad = File.join(dir, 'does', 'not', 'exist', 'kairos')
      out, err, status = Open3.capture3('ruby', BIN, '--data-dir', bad, chdir: dir)
      assert_equal 4, status.exitstatus,
                   "stdout=#{out.inspect} stderr=#{err.inspect}"
      assert_match(/parent does not exist/, err)
    end
  end

  def test_data_dir_pointing_to_regular_file_exits_4
    # R2 P3 (Codex/4.7): --data-dir must be a directory, not a file.
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'not-a-dir.txt')
      File.write(file, 'x')
      out, err, status = Open3.capture3('ruby', BIN, '--data-dir', file, chdir: dir)
      assert_equal 4, status.exitstatus,
                   "stdout=#{out.inspect} stderr=#{err.inspect}"
      assert_match(/is not a directory/, err)
    end
  end

  def test_hook_instantiation_failure_exits_3
    # R8→R9 (3-voice): bin/'s narrow StandardError rescue must convert
    # a hook class whose .new raises into exit 3 with a readable message.
    # Fixture: a skillset whose lifecycle_hook class inherits the
    # allowed namespace but has a required-arg initializer.
    Dir.mktmpdir do |data_dir|
      skillset_dir = File.join(data_dir, 'skillsets', 'broken_daemon')
      FileUtils.mkdir_p(File.join(skillset_dir, 'lib'))
      File.write(File.join(skillset_dir, 'skillset.json'), JSON.generate(
        'name' => 'broken_daemon',
        'version' => '0.1.0',
        'layer' => 'L1',
        'lifecycle_hooks' => {
          'daemon_main' => 'KairosMcp::SkillSets::BrokenDaemon::MainLoop'
        }
      ))
      File.write(File.join(skillset_dir, 'lib', 'broken_daemon.rb'), <<~RUBY)
        require 'kairos_mcp/lifecycle_hook'
        module KairosMcp
          module SkillSets
            module BrokenDaemon
              class MainLoop
                include KairosMcp::LifecycleHook
                def initialize(required_token); @t = required_token; end
              end
            end
          end
        end
      RUBY

      out, err, status = Open3.capture3('ruby', BIN, '--data-dir', data_dir,
                                        chdir: data_dir)
      # R10 (P3 4.7): instantiation failure exits 9 (distinct from lookup=3).
      assert_equal 9, status.exitstatus,
                   "stdout=#{out.inspect} stderr=#{err.inspect}"
      assert_match(/instantiation failed/, err)
      assert_match(/ArgumentError/, err)
    end
  end

  def test_hook_pathological_new_wrong_type_exits_9
    # R10 (Codex P1 / 4.6 P2): pathological .new guard must apply on the
    # bin/ path, not just via find_lifecycle_hook.
    Dir.mktmpdir do |data_dir|
      skillset_dir = File.join(data_dir, 'skillsets', 'broken_type')
      FileUtils.mkdir_p(File.join(skillset_dir, 'lib'))
      File.write(File.join(skillset_dir, 'skillset.json'), JSON.generate(
        'name' => 'broken_type', 'version' => '0.1.0', 'layer' => 'L1',
        'lifecycle_hooks' => {
          'daemon_main' => 'KairosMcp::SkillSets::BrokenType::MainLoop'
        }
      ))
      File.write(File.join(skillset_dir, 'lib', 'broken_type.rb'), <<~RUBY)
        require 'kairos_mcp/lifecycle_hook'
        module KairosMcp
          module SkillSets
            module BrokenType
              class MainLoop
                include KairosMcp::LifecycleHook
                def self.new; 'not a hook instance'; end
              end
            end
          end
        end
      RUBY

      out, err, status = Open3.capture3('ruby', BIN, '--data-dir', data_dir,
                                        chdir: data_dir)
      assert_equal 9, status.exitstatus,
                   "stdout=#{out.inspect} stderr=#{err.inspect}"
      assert_match(/produced wrong type/, err)
    end
  end
end
