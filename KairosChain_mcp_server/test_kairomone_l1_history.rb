#!/usr/bin/env ruby
# frozen_string_literal: true

# Core 3.94+ L1 body history and the dot. All writes go to temporary
# host/instance directories. Runs on every supported core: on a core without
# body history, a dot an earlier Kairomone activated elsewhere is simulated by
# the activation record core would have left on its ledger.
#
# Kairomone 0.8 (design log/kairomone_core_0_8_design_v0.6_FROZEN_20261023.md):
# a backup is signed with the host's archive key, and a move to a fresh host
# restores as stored once the owner copies that key there (M15).
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'kairomone'
require 'tmpdir'
require 'digest'

HISTORY_CORE = KairosMcp::KnowledgeProvider.private_method_defined?(:keep_bodies!) ||
               KairosMcp::KnowledgeProvider.method_defined?(:keep_bodies!)
require 'kairos_mcp/l1_history' if HISTORY_CORE
puts "core #{KairosMcp::VERSION}: L1 body history #{HISTORY_CORE ? 'present' : 'absent'}"

PASSED = []
FAILED = []
def check(name)
  yield
  PASSED << name
  puts "PASS #{name}"
rescue StandardError => e
  FAILED << name
  warn "FAIL #{name}: #{e.class}: #{e.message}\n#{e.backtrace.first(4).join("\n")}"
end

def assert(value, message = 'assertion failed')
  raise message unless value
end

def host_config(host, history_enabled: true)
  File.write(File.join(host, 'skills/config.yml'), <<~YAML)
    state_commit:
      enabled: false
    l1_history:
      enabled: #{history_enabled}
  YAML
end

def fixture
  Dir.mktmpdir('kairomone-l1h-test-') do |host|
    KairosMcp.data_dir = host
    FileUtils.mkdir_p(File.join(host, 'skills'))
    File.write(File.join(host, 'skills/kairos.rb'), '# host immutable Ruby')
    File.write(File.join(host, 'skills/kairos.md'), '# Host philosophy')
    host_config(host)
    store = Kairomone::Instance.new
    store.init(dot_id: 'my_dot', display_name: 'My dot')
    yield store, host
  end
end

def ledger_records(store)
  store.chain.chain.flat_map { |block| Array(block.data) }.filter_map do |entry|
    parsed = JSON.parse(entry) rescue nil
    parsed if parsed.is_a?(Hash)
  end
end

def activations(store)
  ledger_records(store).select { |r| r['type'] == 'l1_history_activation' }.map { |r| r['active'] }
end

def kept?(store, id)
  body = File.binread(File.join(store.root, "knowledge/#{id}/#{id}.md"))
  !KairosMcp::L1History.new(File.join(store.root, 'knowledge')).fetch(Digest::SHA256.hexdigest(body)).nil?
end

def history_files(store)
  Dir.glob(File.join(store.root, 'l1_history/**/*')).select { |f| File.file?(f) }.sort
end

def ledger_bytes(store)
  File.binread(File.join(store.root, 'storage/blockchain.json'))
end

# What Kairomone before 0.6.1 left on core 3.94+: the provider had no
# override, so core activated body history on the dot's own ledger. On an
# older core the same ledger arrives by backup restore; its record is appended
# here in core's shape.
def activate_as_earlier_kairomone(store)
  unless HISTORY_CORE
    store.chain.add_block([{ type: 'l1_history_activation', layer: 'L1', active: true,
                             timestamp: Time.now.utc.iso8601 }.to_json])
  end
  raw = store.send(:document, 'legacy', 'Legacy', 'written before the override', 'L1', Time.now.utc.iso8601)
  plain = KairosMcp::KnowledgeProvider.new(File.join(store.root, 'knowledge'), vector_search_enabled: false,
                                           include_skillset_knowledge: false, storage_backend: store.backend)
  assert plain.create('legacy', raw, reason: 'simulated earlier Kairomone')[:success]
  assert activations(store) == [true]
  assert kept?(store, 'legacy') if HISTORY_CORE
end

def refusal(&block)
  block.call
  nil
rescue Kairomone::Error => e
  e
end

check('a fresh dot never activates body history, whatever the host config says') do
  [true, false].each do |enabled|
    fixture do |store, host|
      host_config(host, history_enabled: enabled)
      assert store.create_knowledge(id: 'first', title: 'First', content: 'body one')[:success]
      assert activations(store).empty?, 'activation record on a fresh dot ledger'
      assert !File.exist?(File.join(store.root, 'l1_history')), 'l1_history/ created under a fresh dot'
    end
  end
end

check('an activated dot records the switch-off once on its own ledger and keeps no new body') do
  fixture do |store, host|
    activate_as_earlier_kairomone(store)
    before = history_files(store)
    host_files = Dir.glob(File.join(host, '*'))
    assert store.create_knowledge(id: 'second', title: 'Second', content: 'body two')[:success]
    assert store.create_knowledge(id: 'third', title: 'Third', content: 'body three')[:success]
    assert activations(store) == [true, false], "activations: #{activations(store).inspect}"
    records = ledger_records(store)
    off = records.index { |r| r['type'] == 'l1_history_activation' && r['active'] == false }
    write = records.index { |r| r['type'] == 'knowledge_update' && r['knowledge_id'] == 'second' }
    assert off && write && off < write, 'switch-off not recorded before the write it guards'
    assert records[off]['reason'] == Kairomone::BodyHistory::SWITCH_OFF_REASON
    assert !kept?(store, 'second') && !kept?(store, 'third') if HISTORY_CORE
    assert history_files(store) == before, 'files written under l1_history/'
    assert Dir.glob(File.join(host, '*')) == host_files, 'host top level changed'
    assert store.chain.valid?
  end
end

check('a backup restore of an activated dot records the switch-off on its first write') do
  fixture do |store, old_host|
    activate_as_earlier_kairomone(store)
    backup = store.create_backup
    Dir.mktmpdir('kairomone-l1h-restore-') do |new_host|
      FileUtils.cp_r(File.join(old_host, 'skills'), File.join(new_host, 'skills'))
      FileUtils.cp_r(File.join(old_host, 'kairomone-keys'), new_host) # the owner copies the archive key
      FileUtils.mkdir_p(File.join(new_host, 'kairomone-inbox'))
      FileUtils.cp(backup[:path], File.join(new_host, 'kairomone-inbox', backup[:file]))
      recovered = Kairomone::Instance.new(host_root: new_host)
      assert recovered.restore_new(file: backup[:file], dot_id: 'my_dot')[:success]
      KairosMcp.data_dir = new_host
      assert !File.exist?(File.join(recovered.root, 'l1_history')) && activations(recovered) == [true]
      assert recovered.create_knowledge(id: 'after_restore', title: 'After', content: 'resumed')[:success]
      assert activations(recovered) == [true, false], "activations: #{activations(recovered).inspect}"
      assert !File.exist?(File.join(recovered.root, 'l1_history'))
      assert recovered.chain.valid?
    end
  end
end

# Faults injected into the switch-off append only.
module SwitchOffFault
  class << self
    attr_accessor :mode, :tripped
  end

  def add_block(data)
    return super unless SwitchOffFault.mode && Array(data).any? { |d| d.to_s.include?('"l1_history_activation"') }

    SwitchOffFault.tripped = true
    case SwitchOffFault.mode
    when :fail then raise 'simulated append failure'
    when :storage_before then raise KairosMcp::Storage::Error, 'simulated: lock unavailable'
    when :storage_after
      super
      raise KairosMcp::Storage::Error, 'simulated: failure after the bytes landed'
    end
  end
end
KairosMcp::KairosChain::Chain.prepend(SwitchOffFault)

check('when the switch-off cannot be recorded, the write is refused and nothing is written') do
  { fail: 'nothing was written', storage_before: 'may or may not' }.each do |mode, words|
    fixture do |store, _|
      activate_as_earlier_kairomone(store)
      ledger = ledger_bytes(store)
      SwitchOffFault.mode = mode
      error = refusal { store.create_knowledge(id: 'blocked', title: 'Blocked', content: 'not written') }
      SwitchOffFault.mode = nil
      assert error && error.message.include?('end of L1 body history') && error.message.include?(words), "#{mode}: #{error.inspect}"
      assert !File.exist?(File.join(store.root, 'knowledge/blocked')), "#{mode}: knowledge file written"
      assert ledger_bytes(store) == ledger, "#{mode}: ledger changed"
    ensure
      SwitchOffFault.mode = nil
    end
  end
end

check('when the ledger cannot be re-read after a storage error, the write is refused with the same notice') do
  fixture do |store, _|
    activate_as_earlier_kairomone(store)
    ledger = ledger_bytes(store)
    store.define_singleton_method(:chain) do
      raise 'simulated: ledger unreadable' if SwitchOffFault.tripped

      super()
    end
    SwitchOffFault.tripped = nil
    SwitchOffFault.mode = :storage_before
    error = refusal { store.create_knowledge(id: 'blocked', title: 'Blocked', content: 'not written') }
    SwitchOffFault.mode = nil
    SwitchOffFault.tripped = nil
    assert error && error.message.include?('may or may not'), error.inspect
    assert !File.exist?(File.join(store.root, 'knowledge/blocked')), 'knowledge file written'
    assert ledger_bytes(store) == ledger, 'ledger changed'
  ensure
    SwitchOffFault.mode = nil
    SwitchOffFault.tripped = nil
  end
end

check('a switch-off that landed despite a storage error lets the write proceed') do
  fixture do |store, _|
    activate_as_earlier_kairomone(store)
    SwitchOffFault.mode = :storage_after
    result = store.create_knowledge(id: 'landed', title: 'Landed', content: 'written')
    SwitchOffFault.mode = nil
    assert result[:success] && result[:recorded_on_chain], result.inspect
    assert activations(store) == [true, false]
  ensure
    SwitchOffFault.mode = nil
  end
end

puts "\n#{PASSED.length} checks passed; #{FAILED.length} failed"
exit(FAILED.empty? ? 0 : 1)
