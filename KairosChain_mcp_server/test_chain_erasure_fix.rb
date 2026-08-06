#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks for the chain-history-erasure fix (design v0.9 FROZEN, §8).
#
# Two paths erased history before this fix:
#   A — two holders read the ledger at the same length and both saved; the second
#       save replaced the disk sequence with its own, dropping the first's block.
#   B — an unreadable ledger collapsed to nil, the chain rebuilt from genesis,
#       and the next save overwrote 687 blocks with 2. No exception either time.
#
# Every check below names the mechanism it pins in a comment; the falsification
# harness (test_chain_erasure_falsification.rb) removes each mechanism in turn
# and confirms the named check goes red. A green run here proves nothing until
# that harness has run.
#
# Writes only under /tmp: KAIROS_DATA_DIR is set before kairos_mcp is required.

require 'tmpdir'
require 'fileutils'

TEST_ROOT = Dir.mktmpdir('kairos_chain_erasure')
ENV['KAIROS_DATA_DIR'] = TEST_ROOT

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'json'
require 'time'
require 'timeout'
require 'digest'
require 'erb'
require 'open3'
require 'kairos_mcp'

unless KairosMcp.blockchain_path.start_with?('/tmp', '/private/tmp', '/var/folders')
  abort "REFUSING TO RUN: blockchain_path is #{KairosMcp.blockchain_path}, not under a temp dir"
end

require 'kairos_mcp/kairos_chain/chain'
require 'kairos_mcp/kairos_chain/block'
require 'kairos_mcp/kairos_chain/merkle_tree'
require 'kairos_mcp/storage/file_backend'
require 'kairos_mcp/drift_detection/correspondence_checker'
require 'kairos_mcp/tools/base_tool'
require 'kairos_mcp/tools/chain_status'
require 'kairos_mcp/tools/chain_verify'
require 'kairos_mcp/tools/chain_history'
require 'kairos_mcp/tools/formalization_history'
require 'kairos_mcp/admin/router'
require 'kairos_mcp/skills_config'

INTROSPECTION_DIR = File.expand_path('templates/skillsets/introspection', __dir__)
require File.join(INTROSPECTION_DIR, 'lib/introspection/safety_inspector')
require File.join(INTROSPECTION_DIR, 'tools/introspection_check')

Chain = KairosMcp::KairosChain::Chain
Block = KairosMcp::KairosChain::Block
MerkleTree = KairosMcp::KairosChain::MerkleTree
FileBackend = KairosMcp::Storage::FileBackend
StorageError = KairosMcp::Storage::Error
ChainStateError = KairosMcp::KairosChain::ChainStateError

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

$passed = 0
$failed = 0
$section = nil

# KAIROS_ERASURE_ONLY=6c,6d runs just those checks. The falsification harness
# uses it to run one check against one mutated copy of the library.
ONLY = (ENV['KAIROS_ERASURE_ONLY'] || '').split(',').map(&:strip).reject(&:empty?).freeze

def check(description, condition)
  if condition
    puts "  [#{$section}] ✅ #{description}"
    $passed += 1
  else
    puts "  [#{$section}] ❌ #{description}"
    $failed += 1
  end
end

# A section that raises is a red section, not an aborted run: under mutation the
# removed mechanism often surfaces as an exception rather than a false assertion.
def section(id, title)
  return if !ONLY.empty? && !ONLY.include?(id)

  $section = id
  puts "\n#{id}. #{title}"
  yield
rescue StandardError, Timeout::Error => e
  check("section raised #{e.class}: #{e.message}", false)
ensure
  $section = nil
end

# Swallow the warn() lines that classification emits for refused states.
def quiet
  original = $stderr
  $stderr = StringIO.new
  yield
ensure
  $stderr = original
end
require 'stringio'

def workdir(name)
  dir = File.join(TEST_ROOT, name)
  FileUtils.mkdir_p(dir)
  dir
end

def backend_for(dir)
  FileBackend.new(storage_dir: dir, blockchain_file: File.join(dir, 'blockchain.json'))
end

# A healthy ledger of `count` blocks after genesis, written through the real
# append path so the fixture is exactly what the system itself produces.
def seed_ledger(dir, count = 2)
  backend = backend_for(dir)
  count.times { |i| Chain.new(storage_backend: backend).add_block(["seed-#{i}"]) }
  backend
end

def raw_blocks(dir)
  JSON.parse(File.read(File.join(dir, 'blockchain.json')), symbolize_names: true)
end

def write_raw(dir, blocks)
  File.write(File.join(dir, 'blockchain.json'), JSON.pretty_generate(blocks))
end

def ledger_path(dir)
  File.join(dir, 'blockchain.json')
end

# Size + mtime + content when readable. An unopenable fixture still has a stable
# fingerprint, so "the bytes did not move" stays checkable there too.
def ledger_fingerprint(dir)
  path = ledger_path(dir)
  return nil unless File.exist?(path)

  stat = File.stat(path)
  content = begin
    Digest::SHA256.hexdigest(File.read(path))
  rescue SystemCallError
    :unreadable
  end
  [stat.size, stat.mtime.to_f, content]
end

# Assert that an append is refused with ChainStateError of a given state, and
# that the ledger bytes did not move.
def refuses_with(dir, backend, expected_state)
  before = ledger_fingerprint(dir)
  chain = quiet { Chain.new(storage_backend: backend) }
  error = nil
  begin
    quiet { chain.add_block(['must-not-land']) }
  rescue StandardError => e
    error = e
  end
  after = ledger_fingerprint(dir)
  {
    state: chain.load_state,
    error: error,
    matched: error.is_a?(ChainStateError) && error.state == expected_state,
    preserved: before == after
  }
end

# ---------------------------------------------------------------------------
# 1 — two holders at the same length, appending in turn
# Mechanism: appending to the tail on disk (INV-D)
# ---------------------------------------------------------------------------
section('1', 'two holders at the same length both survive') do
  dir = workdir('c1')
  backend = seed_ledger(dir, 1) # genesis + seed-0

  first = Chain.new(storage_backend: backend)
  second = Chain.new(storage_backend: backend)
  check('both holders read the same length', first.chain.length == 2 && second.chain.length == 2)

  first.add_block(['from-first'])
  second.add_block(['from-second'])

  final = Chain.new(storage_backend: backend)
  payloads = final.chain.map { |b| b.data.first }
  check('both blocks survive (path A is closed)',
        payloads.include?('from-first') && payloads.include?('from-second'))
  check('the resulting sequence classifies as readable', final.load_state == :readable)
  check('length is genesis + seed + 2', final.chain.length == 4)
end

# ---------------------------------------------------------------------------
# 2 — one process, two threads, 20 rounds each
# Mechanism: the key (flock)
# ---------------------------------------------------------------------------
section('2', 'two threads, 20 rounds each') do
  dir = workdir('c2')
  backend = backend_for(dir)
  rounds = Integer(ENV['KAIROS_ERASURE_ROUNDS'] || 20)

  Timeout.timeout(120) do
    threads = %w[t1 t2].map do |label|
      Thread.new do
        rounds.times { |i| Chain.new(storage_backend: backend).add_block(["#{label}-#{i}"]) }
      end
    end
    threads.each(&:join)
  end

  final = Chain.new(storage_backend: backend)
  payloads = final.chain.map { |b| b.data.first }
  check("all #{rounds * 2} appends survive",
        rounds.times.all? { |i| payloads.include?("t1-#{i}") && payloads.include?("t2-#{i}") })
  check('no hang (finished inside the timeout)', true)
  check('the resulting sequence classifies as readable', final.load_state == :readable)
rescue Timeout::Error
  check('two threads, 20 rounds: completed without hanging', false)
end

# ---------------------------------------------------------------------------
# 3 — two processes, 20 rounds each (the key file is opened after the fork)
# Mechanism: the key (flock)
# ---------------------------------------------------------------------------
section('3', 'two processes, 20 rounds each') do
  dir = workdir('c3')
  backend = backend_for(dir)
  rounds = Integer(ENV['KAIROS_ERASURE_ROUNDS'] || 20)

  pids = %w[p1 p2].map do |label|
    fork do
      # The lock file handle is opened inside add_block, i.e. after the fork, so
      # the two processes never share a file description.
      rounds.times { |i| Chain.new(storage_backend: backend).add_block(["#{label}-#{i}"]) }
      exit!(0)
    end
  end
  Timeout.timeout(180) { pids.each { |pid| Process.waitpid(pid) } }

  final = Chain.new(storage_backend: backend)
  payloads = final.chain.map { |b| b.data.first }
  check("all #{rounds * 2} appends survive across processes",
        rounds.times.all? { |i| payloads.include?("p1-#{i}") && payloads.include?("p2-#{i}") })
  check('the resulting sequence classifies as readable', final.load_state == :readable)
rescue Timeout::Error
  check('two processes, 20 rounds: completed without hanging', false)
end

# ---------------------------------------------------------------------------
# 4 — unopenable / unparseable / zero-byte
# Mechanism: the read-side contract (nil means absent, and nothing else)
# ---------------------------------------------------------------------------
section('4', 'a ledger that exists but cannot be read') do
  {
    'unparseable' => -> (path) { File.write(path, '{ broken') },
    'zero-byte' => -> (path) { File.write(path, '') },
    'unopenable' => -> (path) { File.write(path, '[]'); File.chmod(0o000, path) }
  }.each do |label, damage|
    dir = workdir("c4_#{label.tr('-', '_')}")
    backend = seed_ledger(dir, 2)
    damage.call(ledger_path(dir))

    result = refuses_with(dir, backend, :unreadable)
    check("#{label}: state is :unreadable", result[:state] == :unreadable)
    check("#{label}: append raises ChainStateError(state: :unreadable)", result[:matched])
    check("#{label}: the ledger bytes did not move", result[:preserved])

    File.chmod(0o644, ledger_path(dir)) if label == 'unopenable'
  end
end

# ---------------------------------------------------------------------------
# 5 — an empty array
# Mechanism: the classification refusal at ②③
# ---------------------------------------------------------------------------
section('5', 'a ledger holding []') do
  dir = workdir('c5')
  backend = seed_ledger(dir, 2)
  write_raw(dir, [])

  result = refuses_with(dir, backend, :empty)
  check('state is :empty', result[:state] == :empty)
  check('append raises ChainStateError(state: :empty)', result[:matched])
  check('the ledger bytes did not move', result[:preserved])
end

# ---------------------------------------------------------------------------
# 6 — index gap, non-zero head, duplicate index
# Mechanism: predicate 2 (indexes run from 0, one at a time)
# ---------------------------------------------------------------------------
section('6', 'broken indexes') do
  {
    'gap' => -> (raw) { raw[0, 2] + [raw[2].merge(index: 9)] },
    'head is not 0' => -> (raw) { raw.drop(1) },
    'duplicate' => -> (raw) { raw[0, 2] + [raw[1]] }
  }.each do |label, mangle|
    dir = workdir("c6_#{label.gsub(/\W/, '_')}")
    backend = seed_ledger(dir, 2)
    write_raw(dir, mangle.call(raw_blocks(dir)))

    result = refuses_with(dir, backend, :corrupt)
    check("#{label}: state is :corrupt", result[:state] == :corrupt)
    check("#{label}: append raises ChainStateError(state: :corrupt)", result[:matched])
  end
end

# ---------------------------------------------------------------------------
# 6b — parseable but the linkage is broken
# Mechanism: predicate 3 (each previous_hash matches the recomputed hash before it)
# ---------------------------------------------------------------------------
section('6b', 'broken linkage') do
  dir = workdir('c6b')
  backend = seed_ledger(dir, 2)
  raw = raw_blocks(dir)
  raw[2] = raw[2].merge(previous_hash: '0' * 64)
  write_raw(dir, raw)

  result = refuses_with(dir, backend, :corrupt)
  check('state is :corrupt', result[:state] == :corrupt)
  check('append raises ChainStateError(state: :corrupt)', result[:matched])
end

# ---------------------------------------------------------------------------
# 6c — the TAIL block's data is rewritten
# Mechanism: predicate 4 (Merkle root recomputation)
# The fixture must be the tail: for any earlier block, predicate 3 fires first
# and predicate 4 would never be reached, so the cell could not be made red alone.
# ---------------------------------------------------------------------------
section('6c', 'the tail block data is rewritten') do
  dir = workdir('c6c')
  backend = seed_ledger(dir, 2)
  healthy = Chain.new(storage_backend: backend)
  check('the untouched fixture is readable', healthy.load_state == :readable)

  raw = raw_blocks(dir)
  tail = raw.last
  # Keep the block self-consistent except for the Merkle root: recompute its hash
  # over the new data so only predicate 4 can catch it.
  tampered = Block.new(
    index: tail[:index],
    timestamp: Time.parse(tail[:timestamp]),
    data: ['tampered'],
    previous_hash: tail[:previous_hash],
    merkle_root: tail[:merkle_root]
  ).to_h
  write_raw(dir, raw[0..-2] + [tampered])

  result = refuses_with(dir, backend, :corrupt)
  check('state is :corrupt', result[:state] == :corrupt)
  check('append raises ChainStateError(state: :corrupt)', result[:matched])
end

# ---------------------------------------------------------------------------
# 6d — a one-block ledger whose single block is a self-consistent fake genesis
# Mechanism: predicate 1 (block 0 is the canonical genesis)
# The fixture must be a single block: with a successor present, predicate 3 fires
# first and this cell could not be made red alone.
# ---------------------------------------------------------------------------
section('6d', 'a lone self-consistent fake genesis') do
  dir = workdir('c6d')
  backend = seed_ledger(dir, 1)
  fake = Block.new(
    index: 0,
    timestamp: Time.at(0).utc,
    data: ['Not The Genesis Block'],
    previous_hash: '0' * 64,
    merkle_root: '0' * 64
  ).to_h
  write_raw(dir, [fake])

  result = refuses_with(dir, backend, :corrupt)
  check('state is :corrupt', result[:state] == :corrupt)
  check('append raises ChainStateError(state: :corrupt)', result[:matched])
end

# ---------------------------------------------------------------------------
# 6e — a non-string element inside data
# Mechanism: totality (an exception raised while evaluating a predicate is
# corruption, not a crash)
# ---------------------------------------------------------------------------
section('6e', 'a non-string element in data') do
  dir = workdir('c6e')
  backend = seed_ledger(dir, 1)
  raw = raw_blocks(dir)
  # Index and linkage stay intact — only the data changes — so predicates 1-3
  # pass and predicate 4's Merkle recomputation is reached. It raises TypeError
  # on a non-string leaf; totality must turn that into :corrupt, not a crash.
  raw[1] = raw[1].merge(data: [42])
  write_raw(dir, raw)

  result = refuses_with(dir, backend, :corrupt)
  check('state is :corrupt (no TypeError escapes)', result[:state] == :corrupt)
  check('append raises ChainStateError(state: :corrupt)', result[:matched])
end

# ---------------------------------------------------------------------------
# 7 — no ledger file at all
# Mechanism: the base at ④, and the key being a separate file
# ---------------------------------------------------------------------------
section('7', 'no ledger file') do
  dir = workdir('c7')
  backend = backend_for(dir)
  # Pre-create the key file: locking the ledger itself would make this append
  # impossible, so its presence must not get in the way.
  File.write("#{ledger_path(dir)}.lock", '')

  chain = Chain.new(storage_backend: backend)
  check('state is :absent before the first append', chain.load_state == :absent)
  chain.add_block(['first'])

  final = Chain.new(storage_backend: backend)
  check('the ledger is genesis + the first block', final.chain.length == 2)
  check('block 0 is the canonical genesis', final.chain.first.hash == Block.genesis.hash)
  check('the pre-existing key file did not get in the way', final.load_state == :readable)
end

# ---------------------------------------------------------------------------
# 8 — a read-only ledger
# Mechanism: the write-side contract (failure raises, never returns false)
# ---------------------------------------------------------------------------
section('8', 'a read-only ledger') do
  dir = workdir('c8')
  backend = seed_ledger(dir, 2)
  File.chmod(0o444, ledger_path(dir))

  chain = Chain.new(storage_backend: backend)
  before_length = chain.chain.length
  error = nil
  begin
    quiet { chain.add_block(['must-not-land']) }
  rescue StandardError => e
    error = e
  end

  check('append raises Storage::Error', error.is_a?(StorageError))
  check('the in-memory sequence did not grow either', chain.chain.length == before_length)
  File.chmod(0o644, ledger_path(dir))
end

# ---------------------------------------------------------------------------
# 9 — the state reaches every reader, and the sequence is a frozen empty array
# Mechanism: the shape of the report
# ---------------------------------------------------------------------------
# Drive every read site against whatever ledger KAIROS_DATA_DIR points at, and
# return what each one reported. This is the acceptance condition of §5.
def tool_text(tool_class, arguments = {})
  tool_class.new(nil).call(arguments).first[:text]
end

def read_site_reports
  {
    chain_status: JSON.parse(tool_text(KairosMcp::Tools::ChainStatus)),
    chain_verify: tool_text(KairosMcp::Tools::ChainVerify),
    chain_history: tool_text(KairosMcp::Tools::ChainHistory, { 'format' => 'json' }),
    chain_history_formatted: tool_text(KairosMcp::Tools::ChainHistory),
    formalization_history: tool_text(KairosMcp::Tools::FormalizationHistory),
    router: KairosMcp::Admin::Router.allocate.send(:fetch_chain_status),
    introspection_check: KairosMcp::SkillSets::Introspection::Tools::IntrospectionCheck
                           .new(nil).send(:check_blockchain),
    safety_inspector: KairosMcp::SkillSets::Introspection::SafetyInspector
                        .new.send(:inspect_blockchain_health)
  }
end

def correspondence_report(dir)
  md = File.join(dir, 'artifact.md')
  File.write(md, 'content') unless File.exist?(md)
  KairosMcp::DriftDetection::CorrespondenceChecker.check_l1(
    name: 'probe', md_file_path: md, storage_backend: backend_for(dir)
  )
end

section('9', 'the state reaches all 11 read sites') do
  default_dir = File.dirname(KairosMcp.blockchain_path)
  FileUtils.mkdir_p(default_dir)

  {
    unreadable: -> { File.write(KairosMcp.blockchain_path, '{ broken') },
    empty: -> { File.write(KairosMcp.blockchain_path, '[]') },
    corrupt: -> { File.write(KairosMcp.blockchain_path, JSON.pretty_generate([{ index: 5 }])) }
  }.each do |expected, damage|
    damage.call
    reports = quiet { read_site_reports }
    chain = quiet { Chain.new }

    check("#{expected}: Chain#chain is an empty frozen array", chain.chain.empty? && chain.chain.frozen?)
    check("#{expected}: Chain#latest_block is nil", chain.latest_block.nil?)
    check("#{expected}: chain_status reports the state", reports[:chain_status]['state'] == expected.to_s)
    check("#{expected}: chain_status latest_block is null", reports[:chain_status]['latest_block'].nil?)
    check("#{expected}: chain_verify says FAILED with the state",
          reports[:chain_verify].include?('FAILED') && reports[:chain_verify].include?(expected.to_s))
    check("#{expected}: chain_history JSON carries the state",
          JSON.parse(reports[:chain_history])['state'] == expected.to_s)
    check("#{expected}: chain_history text names the state",
          reports[:chain_history_formatted].include?(expected.to_s))
    check("#{expected}: formalization_history refuses and names the state",
          reports[:formalization_history].include?(expected.to_s))
    check("#{expected}: admin router reports the state", reports[:router][:state] == expected)
    check("#{expected}: admin router latest_block is nil", reports[:router][:latest_block].nil?)
    check("#{expected}: introspection_check reports the state",
          reports[:introspection_check][:state] == expected)
    check("#{expected}: safety_inspector reports the state",
          reports[:safety_inspector][:state] == expected)
  end

  # correspondence_checker: an unreadable ledger must not be reported as
  # "this artifact was never recorded"...
  cdir = workdir('c9_corr')
  seed_ledger(cdir, 1)
  File.write(ledger_path(cdir), '{ broken')
  result = quiet { correspondence_report(cdir) }
  check('unreadable: correspondence_checker reports :error, not :missing_record',
        result.status == :error && result.message.include?('unreadable'))

  # ...while an absent ledger completes the scan: nothing was ever recorded, so
  # :missing_record is the honest verdict, not :error.
  adir = workdir('c9_corr_absent')
  result = quiet { correspondence_report(adir) }
  check('absent: correspondence_checker reports :missing_record, not :error',
        result.status == :missing_record)
end

# ---------------------------------------------------------------------------
# 9b — an absent ledger reads as "not yet", never as corrupt
# Mechanism: the new read side, including the three ERB surfaces
# ---------------------------------------------------------------------------
def render_erb(relative_path, locals)
  source = File.read(File.expand_path(File.join('lib/kairos_mcp/admin/views', relative_path), __dir__))
  context = Object.new
  context.define_singleton_method(:h) { |s| s.to_s }
  locals.each { |k, v| context.define_singleton_method(k) { v } }
  ERB.new(source).result(context.instance_eval { binding })
end

section('9b', 'an absent ledger reports "not created yet"') do
  FileUtils.rm_f(KairosMcp.blockchain_path)
  reports = quiet { read_site_reports }
  chain = quiet { Chain.new }

  check('state is :absent', chain.load_state == :absent)
  check('chain_verify says "not created yet", not FAILED',
        reports[:chain_verify].include?('not created yet') && !reports[:chain_verify].include?('FAILED'))
  check('chain_history text says "not created yet"',
        reports[:chain_history_formatted].include?('not created yet'))
  check('formalization_history says "not created yet", not "Cannot scan"',
        reports[:formalization_history].include?('not created yet') &&
        !reports[:formalization_history].include?('Cannot scan'))
  check('introspection_check status is not_created_yet',
        reports[:introspection_check][:status] == 'not_created_yet')
  check('admin router reports :absent', reports[:router][:state] == :absent)

  # The other locals these pages need are unrelated to the ledger; empty values
  # render the real template without touching the branch under test.
  other = { tokens: [], skills: [], knowledge: [], context_sessions: [], state: {} }
  chain_view = render_erb('chain.erb', { chain: reports[:router] }.merge(other))
  dashboard_view = render_erb('dashboard.erb', { chain: reports[:router] }.merge(other))
  blocks_view = render_erb('partials/_chain_blocks.erb',
                           blocks: [], load_state: :absent, total: 0, limit: 20, offset: 0)

  check('chain.erb shows "Not created yet", not "Invalid"',
        chain_view.include?('Not created yet') && !chain_view.include?('Invalid'))
  check('dashboard.erb shows "Not created yet", not "Invalid"',
        dashboard_view.include?('Not created yet') && !dashboard_view.include?('Invalid'))
  check('_chain_blocks.erb shows "Chain not created yet", not "No blocks found"',
        blocks_view.include?('Chain not created yet') && !blocks_view.include?('No blocks found'))
rescue StandardError => e
  check("9b raised: #{e.class}: #{e.message}", false)
end

# ---------------------------------------------------------------------------
# 10 — valid? is the single name for "readable"
# ---------------------------------------------------------------------------
section('10', 'valid? is false for unreadable and for absent') do
  dir = workdir('c10')
  backend = seed_ledger(dir, 1)
  File.write(ledger_path(dir), '{ broken')
  check('unreadable → valid? is false', quiet { Chain.new(storage_backend: backend) }.valid? == false)

  FileUtils.rm_f(ledger_path(dir))
  check('absent → valid? is false', Chain.new(storage_backend: backend).valid? == false)
end

# ---------------------------------------------------------------------------
# 12 / 12b — a backend that does not declare the contract
# Mechanism: INV-G, and the dividing line
# ---------------------------------------------------------------------------
# Answers nothing: no #blockchain_file. Returns a perfectly good array.
class SilentBackend < KairosMcp::Storage::Backend
  def initialize(blocks) = @blocks = blocks
  def load_blocks = @blocks
  def save_all_blocks(_blocks) = raise('save must never be reached')
  def backend_type = :silent
end

def silent_backend_over_good_blocks(name)
  seeded = workdir(name)
  seed_ledger(seeded, 2)
  SilentBackend.new(raw_blocks(seeded))
end

section('12', 'an undeclared backend cannot be appended to') do
  backend = silent_backend_over_good_blocks('c12')
  chain = quiet { Chain.new(storage_backend: backend) }

  error = nil
  begin
    quiet { chain.add_block(['must-not-land']) }
  rescue StandardError => e
    error = e
  end
  check('append raises ChainStateError', error.is_a?(ChainStateError))
end

# ---------------------------------------------------------------------------
# 12b — the dividing line: only a backend that declared the contract has its
# return read in three shapes
# ---------------------------------------------------------------------------
section('12b', 'an undeclared backend reads as unreadable whatever it returns') do
  backend = silent_backend_over_good_blocks('c12b')
  chain = quiet { Chain.new(storage_backend: backend) }

  check('a good array from an undeclared backend still reads as :unreadable',
        chain.load_state == :unreadable)
  check('the sequence is empty despite the backend returning blocks', chain.chain.empty?)
end

# ---------------------------------------------------------------------------
# 13 / 13b — the re-entrancy flag
# Mechanism: the flag at ⓪, held at thread level
# ---------------------------------------------------------------------------
# Delegates to a real FileBackend but runs a hook from inside the write, i.e.
# while the flag is up and the key is held.
class HookBackend
  def initialize(inner, &hook)
    @inner = inner
    @hook = hook
  end

  def blockchain_file = @inner.blockchain_file
  def load_blocks = @inner.load_blocks
  def backend_type = @inner.backend_type

  def save_all_blocks(blocks)
    @hook&.call
    @inner.save_all_blocks(blocks)
  end
end

section('13', 'a nested append is refused, not deadlocked') do
  dir = workdir('c13')
  inner = seed_ledger(dir, 1)
  nested_error = nil
  backend = HookBackend.new(inner) do
    begin
      Chain.new(storage_backend: inner).add_block(['nested'])
    rescue StandardError => e
      nested_error = e
    end
  end

  Timeout.timeout(1) { Chain.new(storage_backend: backend).add_block(['outer']) }
  check('the nested append raises ChainStateError within 1 second',
        nested_error.is_a?(ChainStateError))
rescue Timeout::Error
  check('the nested append raises ChainStateError within 1 second (timed out)', false)
end

section('13b', 'the flag is visible across fibers') do
  dir = workdir('c13b')
  inner = seed_ledger(dir, 1)
  fiber_error = nil
  backend = HookBackend.new(inner) do
    Fiber.new do
      begin
        Chain.new(storage_backend: inner).add_block(['from-fiber'])
      rescue StandardError => e
        fiber_error = e
      end
    end.resume
  end

  Timeout.timeout(1) { Chain.new(storage_backend: backend).add_block(['outer']) }
  check("fiber B sees fiber A's flag (ChainStateError, not a deadlock)",
        fiber_error.is_a?(ChainStateError))
rescue Timeout::Error
  check("fiber B sees fiber A's flag (timed out — the flag is fiber-local)", false)
end

# ---------------------------------------------------------------------------
# 14 — the key lands beside the ledger it protects
# Mechanism: the key path is derived from the backend's answer
# ---------------------------------------------------------------------------
section('14', 'the key lands beside the injected ledger') do
  dir = workdir('c14')
  backend = backend_for(dir)
  global_lock = "#{KairosMcp.blockchain_path}.lock"
  FileUtils.rm_f(global_lock)

  Chain.new(storage_backend: backend).add_block(['x'])

  check('the key file is beside the injected ledger', File.exist?("#{ledger_path(dir)}.lock"))
  check('no key file appeared beside the global ledger', !File.exist?(global_lock))
end

# ---------------------------------------------------------------------------
# 16 — the state and the sequence advance only on a successful write
# ---------------------------------------------------------------------------
section('16', 'appending once to an absent ledger advances the same instance') do
  dir = workdir('c16')
  backend = backend_for(dir)
  chain = Chain.new(storage_backend: backend)
  check('state starts at :absent', chain.load_state == :absent)

  chain.add_block(['first'])
  check('valid? is now true', chain.valid?)
  check('state advanced to :readable', chain.load_state == :readable)
  check('the sequence holds 2 blocks (genesis + the first)', chain.chain.length == 2)
end

# ---------------------------------------------------------------------------
# 17 — a backend that answers a relative path
# Mechanism: the absolute-path refusal at ⓪
# ---------------------------------------------------------------------------
class RelativeBackend < KairosMcp::Storage::Backend
  RELATIVE = 'relative_ledger/blockchain.json'
  def blockchain_file = RELATIVE
  def load_blocks = nil
  def save_all_blocks(_blocks) = raise('save must never be reached')
  def backend_type = :relative
end

section('17', 'a backend answering a relative ledger path') do
  dir = workdir('c17')
  error = nil
  Dir.chdir(dir) do
    chain = Chain.new(storage_backend: RelativeBackend.new)
    begin
      chain.add_block(['must-not-land'])
    rescue StandardError => e
      error = e
    end
    check('append raises Storage::Error', error.is_a?(StorageError))
    check('no ledger file was created', !File.exist?(RelativeBackend::RELATIVE))
    check('no key file was created', !File.exist?("#{RelativeBackend::RELATIVE}.lock"))
    check('no directory was created for it', !Dir.exist?('relative_ledger'))
  end
end

# ---------------------------------------------------------------------------
# 18 — the flag comes down on the failure path too
# Mechanism: the ensure at ⑦
# ---------------------------------------------------------------------------
section('18', 'the same thread can append again after a failed append') do
  dir = workdir('c18')
  backend = seed_ledger(dir, 1)
  File.chmod(0o444, ledger_path(dir))

  first_error = nil
  begin
    quiet { Chain.new(storage_backend: backend).add_block(['fails']) }
  rescue StandardError => e
    first_error = e
  end
  check('the first append failed with Storage::Error', first_error.is_a?(StorageError))

  File.chmod(0o644, ledger_path(dir))
  second_error = nil
  begin
    Timeout.timeout(2) { Chain.new(storage_backend: backend).add_block(['succeeds']) }
  rescue StandardError => e
    second_error = e
  end
  check('the same thread can append again', second_error.nil?)
  check('the block landed',
        Chain.new(storage_backend: backend).chain.map { |b| b.data.first }.include?('succeeds'))
end

# ---------------------------------------------------------------------------
# 19 — the key file cannot be opened
# Mechanism: wrapping the key's I/O (no bare Errno escapes)
# ---------------------------------------------------------------------------
section('19', 'the key file cannot be opened') do
  dir = workdir('c19')
  sealed = File.join(dir, 'sealed')
  FileUtils.mkdir_p(sealed)
  backend = FileBackend.new(storage_dir: sealed, blockchain_file: File.join(sealed, 'blockchain.json'))
  File.chmod(0o000, sealed)

  error = nil
  begin
    quiet { Chain.new(storage_backend: backend).add_block(['must-not-land']) }
  rescue StandardError => e
    error = e
  end

  check('append raises Storage::Error', error.is_a?(StorageError))
  check('no bare Errno escapes', !error.is_a?(SystemCallError))
  File.chmod(0o755, sealed)
end

# ---------------------------------------------------------------------------
# 20 — a ledger whose stat fails while read and write still succeed
# Mechanism: absence decided by stat, not by File.exist?
# Found by review R1, measured: the ledger was rebuilt from genesis over 6 real
# blocks, leaving 2. This is Path B, reached through a channel the earlier
# fixtures (unopenable / unparseable / zero-byte) did not cover.
# ---------------------------------------------------------------------------
section('20', 'stat fails but read and write succeed (darwin ACL)') do
  dir = workdir('c20')
  backend = seed_ledger(dir, 4)
  before = File.read(ledger_path(dir))

  # Deny only the attribute read that stat(2) needs. Reading and writing the
  # file's contents stay permitted, so File.exist? lies while nothing else does.
  user = `id -un`.strip
  applied = system("chmod +a '#{user} deny readattr' #{ledger_path(dir)}", out: File::NULL, err: File::NULL)

  unless applied
    check('darwin ACL not available on this platform — check skipped', true)
    next
  end

  begin
    check('File.exist? does lie here (the premise of the check holds)',
          File.exist?(ledger_path(dir)) == false)
    check('File.read still succeeds (so this is not simply an unreadable file)',
          (File.read(ledger_path(dir)).length > 0 rescue false))

    result = refuses_with(dir, backend, :unreadable)
    check('state is :unreadable, not :absent', result[:state] == :unreadable)
    check('append raises ChainStateError(state: :unreadable)', result[:matched])
    check('the ledger was not rebuilt from genesis', File.read(ledger_path(dir)) == before)
  ensure
    system("chmod -N #{ledger_path(dir)}", out: File::NULL, err: File::NULL)
  end
end

# ---------------------------------------------------------------------------
# 20b — an EXISTING ledger inside an unsearchable directory
# Mechanism: the same one. Check 19 only covered an absent ledger there.
# ---------------------------------------------------------------------------
section('20b', 'an existing ledger inside an unsearchable directory') do
  dir = workdir('c20b')
  sealed = File.join(dir, 'sealed')
  FileUtils.mkdir_p(sealed)
  backend = FileBackend.new(storage_dir: sealed, blockchain_file: File.join(sealed, 'blockchain.json'))
  2.times { |i| Chain.new(storage_backend: backend).add_block(["real-#{i}"]) }
  before = File.read(File.join(sealed, 'blockchain.json'))

  File.chmod(0o000, sealed)
  begin
    chain = quiet { Chain.new(storage_backend: backend) }
    check('state is :unreadable, not :absent', chain.load_state == :unreadable)
    error = nil
    begin
      quiet { chain.add_block(['must-not-land']) }
    rescue StandardError => e
      error = e
    end
    check('append is refused', error.is_a?(ChainStateError) || error.is_a?(StorageError))
  ensure
    File.chmod(0o755, sealed)
  end
  check('the ledger is intact', File.read(File.join(sealed, 'blockchain.json')) == before)
end

# ---------------------------------------------------------------------------
# 21 — the default storage backend cannot be constructed
# Mechanism: backend construction inside classify_disk's protected region
# ---------------------------------------------------------------------------
section('21', 'the default backend cannot be constructed') do
  original = KairosMcp::Storage::Backend.method(:default)
  KairosMcp::Storage::Backend.define_singleton_method(:default) do
    raise 'storage backend cannot be built'
  end

  begin
    chain = nil
    raised = nil
    begin
      chain = quiet { Chain.new }
    rescue StandardError => e
      raised = e
    end

    check('Chain.new does not raise', raised.nil?)
    check('state is :unreadable', chain&.load_state == :unreadable)
    check('the sequence is empty', chain&.chain&.empty?)
    check('storage_type answers :unavailable rather than raising',
          (chain.storage_type == :unavailable rescue false))

    append_error = nil
    begin
      quiet { chain.add_block(['must-not-land']) }
    rescue StandardError => e
      append_error = e
    end
    check('append raises ChainStateError', append_error.is_a?(ChainStateError))
  ensure
    KairosMcp::Storage::Backend.define_singleton_method(:default) { original.call }
  end
end

# ---------------------------------------------------------------------------
# 22 — two names for one ledger: a symlink to the ledger FILE, driven
# concurrently
# Mechanism: the key path is canonicalised before ".lock" is appended (FIX C)
# The old fixture ("dir/x.json" vs "dir/./x.json") could not catch a split key:
# the kernel resolves "." inside the LOCK path too, so both spellings opened
# one lock inode even without canonicalisation — which is why the R1
# withdrawal looked justified. "link.json.lock" is its own name; nothing
# resolves it to "real.json.lock", so only a symlink to the ledger file itself
# shows the split. And only concurrently: sequential appends through the two
# names pass even when the lock is split (measured), because each append still
# reads the other's completed write.
# ---------------------------------------------------------------------------
section('22', 'a symlink to the ledger file shares one key (concurrent)') do
  dir = workdir('c22')
  real = File.join(dir, 'real.json')
  link = File.join(dir, 'link.json')
  File.symlink(real, link)

  a = FileBackend.new(storage_dir: dir, blockchain_file: real)
  b = FileBackend.new(storage_dir: dir, blockchain_file: link)
  Chain.new(storage_backend: a).add_block(['seed'])
  rounds = Integer(ENV['KAIROS_ERASURE_ROUNDS'] || 30)

  Timeout.timeout(120) do
    threads = { 'real' => a, 'link' => b }.map do |label, backend|
      Thread.new do
        rounds.times { |i| Chain.new(storage_backend: backend).add_block(["#{label}-#{i}"]) }
      end
    end
    threads.each(&:join)
  end

  final = Chain.new(storage_backend: a)
  payloads = final.chain.map { |x| x.data.first }
  check("all #{rounds * 2} appends through both names survive",
        rounds.times.all? { |i| payloads.include?("real-#{i}") && payloads.include?("link-#{i}") })
  check('the resulting sequence classifies as readable', final.load_state == :readable)
  check('exactly one key file exists for this ledger',
        Dir.glob(File.join(dir, '*.lock')).length == 1)
rescue Timeout::Error
  check('symlink concurrency: completed without hanging', false)
end

# ---------------------------------------------------------------------------
# 23 — closing the key fails while an exception is already on its way out
# Mechanism: the close in the ensure does not replace the pending exception
# ---------------------------------------------------------------------------
section('23', 'a failing key close does not mask the pending exception') do
  dir = workdir('c23')
  backend = seed_ledger(dir, 1)
  File.chmod(0o444, ledger_path(dir))

  # Make every IO#close raise, for the duration of this check only.
  IO.class_eval do
    alias_method :__erasure_original_close, :close
    def close
      raise IOError, 'synthetic close failure'
    end
  end

  error = nil
  begin
    quiet { Chain.new(storage_backend: backend).add_block(['fails']) }
  rescue StandardError => e
    error = e
  ensure
    IO.class_eval do
      alias_method :close, :__erasure_original_close
      remove_method :__erasure_original_close
    end
    File.chmod(0o644, ledger_path(dir))
  end

  check('the caller still receives Storage::Error, not IOError',
        error.is_a?(StorageError) && !error.is_a?(IOError))
  check('the message is the write failure, not the close failure',
        error.message.include?('save blocks'))
end

# ---------------------------------------------------------------------------
# 23b — the same, but the append SUCCEEDS and the caller is already inside a
# rescue handler. Tracking "did the body finish" off $! would read the caller's
# exception here and swallow the close failure.
# ---------------------------------------------------------------------------
section('23b', 'a failing key close is reported when the body succeeded') do
  dir = workdir('c23b')
  backend = seed_ledger(dir, 1)

  IO.class_eval do
    alias_method :__erasure_original_close, :close
    def close
      raise IOError, 'synthetic close failure'
    end
  end

  error = nil
  begin
    # The caller sits inside an active rescue, so $! is non-nil for the whole
    # append even though the append itself is on its normal path.
    raise 'caller was already handling something else'
  rescue StandardError
    begin
      quiet { Chain.new(storage_backend: backend).add_block(['lands']) }
    rescue StandardError => e
      error = e
    end
  ensure
    IO.class_eval do
      alias_method :close, :__erasure_original_close
      remove_method :__erasure_original_close
    end
  end

  check('the close failure is reported, not swallowed', error.is_a?(StorageError))
  check('the message names the close, not the write',
        error.is_a?(StorageError) && error.message.include?('lock close failed'))
  check('the block still landed on disk',
        Chain.new(storage_backend: backend).chain.map { |b| b.data.first }.include?('lands'))
end

# ---------------------------------------------------------------------------
# 24 — a non-UTF-8 String offered to add_block
# Mechanism: build_block brings every String to valid UTF-8 (FIX A) — the
# bytes hashed are the bytes written, or the append raises before any write
# ---------------------------------------------------------------------------
section('24', 'a non-UTF-8 String cannot corrupt the ledger') do
  dir = workdir('c24')
  backend = seed_ledger(dir, 2)

  # A valid ISO-8859-1 string must round-trip: before the fix this single
  # append returned a Block, left 4 blocks on disk, and the reload classified
  # :corrupt — the whole history unreachable with no raise anywhere.
  latin = "S1,Muller\xE9".dup.force_encoding(Encoding::ISO_8859_1)
  Chain.new(storage_backend: backend).add_block([latin])
  final = Chain.new(storage_backend: backend)
  check('after appending a valid ISO-8859-1 string the ledger classifies readable',
        final.load_state == :readable)
  check('the string round-trips as its UTF-8 spelling',
        final.chain.last.data.first == latin.encode(Encoding::UTF_8))

  # A String holding bytes invalid for its own encoding must raise BEFORE
  # anything reaches disk — encode is a no-op for UTF-8-labelled input, so this
  # pins the explicit valid_encoding? refusal.
  before = ledger_fingerprint(dir)
  error = nil
  begin
    Chain.new(storage_backend: backend).add_block(["abc\xFF".dup.force_encoding(Encoding::UTF_8)])
  rescue StandardError => e
    error = e
  end
  check('a String invalid for its own encoding raises EncodingError', error.is_a?(EncodingError))
  check('nothing was written for the refused append', ledger_fingerprint(dir) == before)
  check('the ledger still classifies readable after the refusal',
        Chain.new(storage_backend: backend).load_state == :readable)
end

# ---------------------------------------------------------------------------
# 25 — the data directory cannot be resolved
# Mechanism: Chain.new resolves no paths of its own (FIX B) — the constructor's
# KairosMcp.blockchain_path call sat outside every rescue and raised for
# KAIROS_DATA_DIR='~nosuchuser…'. A subprocess is used because data_dir is
# memoised: this process resolved it at startup and cannot un-resolve it.
# ---------------------------------------------------------------------------
section('25', 'Chain.new returns for an unresolvable data directory') do
  script = <<~RUBY
    $LOAD_PATH.unshift #{File.expand_path('lib', __dir__).inspect}
    require 'kairos_mcp/kairos_chain/chain'
    chain = KairosMcp::KairosChain::Chain.new
    puts "state=\#{chain.load_state}"
  RUBY
  out, status = Open3.capture2e({ 'KAIROS_DATA_DIR' => '~nosuchuser12345/kairos' },
                                'ruby', '-e', script)
  check('Chain.new did not raise (subprocess exited 0)', status.success?)
  check('load_state is :unreadable', out.include?('state=unreadable'))
end

# ---------------------------------------------------------------------------
# 26 — $stderr replaced by a failing writer while classification warns
# Mechanism: diagnostics cannot change the outcome of a classification (FIX D).
# Measured: with $stderr a closed StringIO, warn raised IOError inside
# classify_disk's rescue branch and escaped Chain.new. (Closing the real
# STDERR alone does not reproduce — MRI falls back to the C-level stderr.)
# ---------------------------------------------------------------------------
section('26', 'a failing $stderr does not break "Chain.new never raises"') do
  dir = workdir('c26')
  backend = seed_ledger(dir, 1)
  File.write(ledger_path(dir), '{ broken')

  raised = nil
  chain = nil
  original = $stderr
  begin
    closed = StringIO.new
    closed.close
    $stderr = closed
    begin
      chain = Chain.new(storage_backend: backend)
    rescue StandardError => e
      raised = e
    end
  ensure
    $stderr = original
  end

  check('Chain.new does not raise under a failing $stderr', raised.nil?)
  check('state is still :unreadable', chain&.load_state == :unreadable)
end

# ---------------------------------------------------------------------------
# 27 — the process locale does not decide readability
# Mechanism: the ledger is read as UTF-8 explicitly (FIX E)
# ---------------------------------------------------------------------------
section('27', 'a non-UTF-8 locale reads the same ledger') do
  dir = workdir('c27')
  backend = backend_for(dir)
  Chain.new(storage_backend: backend).add_block(['日本語データ 台帳の記録'])
  before = raw_blocks(dir).length

  # A fresh interpreter, because default_external is fixed at process start
  # from the locale. LANG=C is the launchd / cron / container start condition.
  script = <<~RUBY
    $LOAD_PATH.unshift #{File.expand_path('lib', __dir__).inspect}
    require 'kairos_mcp/kairos_chain/chain'
    require 'kairos_mcp/storage/file_backend'
    backend = KairosMcp::Storage::FileBackend.new(
      storage_dir: #{dir.inspect}, blockchain_file: #{ledger_path(dir).inspect}
    )
    chain = KairosMcp::KairosChain::Chain.new(storage_backend: backend)
    puts "state=\#{chain.load_state} length=\#{chain.chain.length}"
    chain.add_block(['appended under LANG=C'])
    puts "appended=\#{chain.chain.length}"
  RUBY
  env = { 'LANG' => 'C', 'LC_ALL' => nil, 'LC_CTYPE' => nil,
          'KAIROS_DATA_DIR' => TEST_ROOT }
  out, status = Open3.capture2e(env, RbConfig.ruby, '-e', script)

  check('the subprocess exits cleanly under LANG=C', status.success?)
  check('the ledger classifies :readable at its full length under LANG=C',
        out.include?("state=readable length=#{before}"))
  check('an append under LANG=C extends the chain', out.include?("appended=#{before + 1}"))
  after = raw_blocks(dir)
  check('the disk sequence grew by exactly one block', after.length == before + 1)
  check('the Japanese payload round-tripped byte-identically',
        after[1][:data].first == '日本語データ 台帳の記録')
end

# ---------------------------------------------------------------------------
# 28 — two names for a ledger that does not exist yet (fresh install)
# Mechanism: the final component's symlink is resolved without requiring its
# target to exist, so both names take one key (FIX F)
# ---------------------------------------------------------------------------
section('28', 'a symlink to an absent ledger shares one key (concurrent)') do
  dir = workdir('c28')
  real = File.join(dir, 'real.json')
  link = File.join(dir, 'link.json')
  File.symlink(real, link)
  # No seed: the ledger is absent, which is the state R3 measured the split in.

  a = FileBackend.new(storage_dir: dir, blockchain_file: real)
  b = FileBackend.new(storage_dir: dir, blockchain_file: link)
  rounds = Integer(ENV['KAIROS_ERASURE_ROUNDS'] || 30)

  Timeout.timeout(120) do
    pids = { 'real' => a, 'link' => b }.map do |label, backend|
      fork do
        rounds.times { |i| Chain.new(storage_backend: backend).add_block(["#{label}-#{i}"]) }
        exit!(0)
      end
    end
    pids.each { |pid| Process.waitpid(pid) }
  end

  final = Chain.new(storage_backend: a)
  payloads = final.chain.map { |x| x.data.first }
  check("all #{rounds * 2} appends through both names survive from an absent start",
        rounds.times.all? { |i| payloads.include?("real-#{i}") && payloads.include?("link-#{i}") })
  check('the resulting sequence classifies as readable', final.load_state == :readable)
  check('exactly one key file exists for this ledger',
        Dir.glob(File.join(dir, '*.lock')).length == 1)
rescue Timeout::Error
  check('absent-ledger symlink concurrency: completed without hanging', false)
end

# ---------------------------------------------------------------------------

puts "\n#{'=' * 60}"
puts "RESULTS: #{$passed} passed, #{$failed} failed"
puts '=' * 60

FileUtils.remove_entry(TEST_ROOT) if Dir.exist?(TEST_ROOT)
exit($failed.zero? ? 0 : 1)
