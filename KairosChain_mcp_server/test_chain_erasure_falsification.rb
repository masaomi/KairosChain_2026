#!/usr/bin/env ruby
# frozen_string_literal: true

# Falsification harness for the chain-history-erasure fix (design v0.9 §8).
#
# A green check suite is not evidence. Each row below removes exactly one
# mechanism from an isolated copy of the library and runs only the checks the
# design nominated for that mechanism. The row passes when those checks go red.
# A row that stays green means the check does not actually pin the mechanism —
# it was passing for some other reason.
#
# One mechanism per row, one row at a time, never in parallel. Fixtures matter:
# 6c must mutate the TAIL block and 6d must use a one-block ledger, or an earlier
# predicate fires first and the cell cannot be made red on its own.
#
# Usage:  ruby test_chain_erasure_falsification.rb [row-number ...]

require 'fileutils'
require 'tmpdir'
require 'open3'

SOURCE_ROOT = __dir__
CHAIN_RB = 'lib/kairos_mcp/kairos_chain/chain.rb'
FILE_BACKEND_RB = 'lib/kairos_mcp/storage/file_backend.rb'

# Each row: the mechanism, the file and text edit that removes it, and the checks
# the design says must go red as a result.
ROWS = [
  {
    id: 1,
    mechanism: 'appending to the tail on disk (INV-D)',
    red: %w[1],
    file: CHAIN_RB,
    from: 'base = state == :readable ? disk_blocks : [Block.genesis]',
    to: 'base = @load_state == :readable ? @chain : [Block.genesis]',
    note: 'reinstates path A: the in-memory sequence replaces the one on disk'
  },
  {
    id: 2,
    mechanism: 'the key',
    red: %w[2 3],
    file: CHAIN_RB,
    from: 'handle.flock(File::LOCK_EX)',
    to: '# flock removed',
    note: 'concurrent appends are no longer serialised'
  },
  {
    id: 3,
    mechanism: 'the key is a separate file (mutation: lock the ledger itself)',
    red: %w[7],
    file: CHAIN_RB,
    from: 'lock_path = "#{canonical}.lock"',
    to: 'lock_path = canonical',
    note: 'opening the key creates a zero-byte ledger, so a fresh install can never be written'
  },
  {
    id: 4,
    mechanism: 'the key file is never unlinked (mutation: unlink at ⑦)',
    red: %w[2 3],
    file: CHAIN_RB,
    from: <<~'RUBY'.chomp,
      result = yield
      completed = true
      result
    RUBY
    to: <<~'RUBY'.chomp,
      result = yield
          completed = true
          begin; File.unlink(lock_path); rescue StandardError; end
          result
    RUBY
    rounds: 200,
    note: 'a later locker takes a different inode and exclusion is lost in silence'
  },
  {
    id: 5,
    mechanism: 'the re-entrancy flag at ⓪',
    red: %w[13],
    file: CHAIN_RB,
    from: 'if Thread.current.thread_variable_get(APPEND_FLAG)',
    to: 'if false',
    note: 'a nested append deadlocks on its own flock instead of being refused'
  },
  {
    id: 6,
    mechanism: 'the flag is thread-level (mutation: Thread#[], which is fiber-local)',
    red: %w[13b],
    file: CHAIN_RB,
    from: 'Thread.current.thread_variable_get(APPEND_FLAG)',
    to: 'Thread.current[APPEND_FLAG]',
    also: [
      ['Thread.current.thread_variable_set(APPEND_FLAG, true)', 'Thread.current[APPEND_FLAG] = true'],
      ['Thread.current.thread_variable_set(APPEND_FLAG, nil)', 'Thread.current[APPEND_FLAG] = nil']
    ],
    note: 'a fiber does not see the flag raised by another fiber on the same thread'
  },
  {
    id: 7,
    mechanism: 'lowering the flag at ⑦ (the ensure)',
    red: %w[18],
    file: CHAIN_RB,
    from: <<~'RUBY'.chomp,
      ensure
          # ⑦ lower the flag — reached only by the call that raised it, because ⓪
          #    raises before this begin block
          Thread.current.thread_variable_set(APPEND_FLAG, nil)
        end
    RUBY
    to: 'end',
    note: 'a failed append leaves the flag up and the thread can never append again'
  },
  {
    id: 8,
    mechanism: "wrapping the key's I/O",
    red: %w[19],
    file: CHAIN_RB,
    from: <<~'RUBY'.chomp,
      rescue SystemCallError, IOError => e
        raise Storage::Error, "ledger lock unavailable (#{lock_path}): #{e.message}"
      end
    RUBY
    to: 'end',
    also: [[
      <<~'RUBY'.chomp,
        rescue SystemCallError, IOError => e
          raise Storage::Error, "ledger lock unavailable (#{lock_path || path}): #{e.message}"
        end
      RUBY
      'end'
    ]],
    note: 'a bare Errno escapes to the caller (both wraps — open and flock — are removed)'
  },
  {
    id: 9,
    mechanism: 'the absolute-path refusal at ⓪',
    red: %w[17],
    file: CHAIN_RB,
    from: <<~'RUBY'.chomp,
      unless path.is_a?(String) && !path.empty? && File.absolute_path?(path)
          raise Storage::Error, "storage backend answered a non-absolute ledger path: #{path.inspect}"
        end
    RUBY
    to: '# absolute-path refusal removed',
    note: 'a CWD-dependent key is accepted, so exclusion is silently lost'
  },
  {
    id: 10,
    mechanism: 'the read-side contract (nil means absent, and nothing else)',
    red: %w[4],
    file: FILE_BACKEND_RB,
    from: <<~'RUBY'.chomp,
      rescue Storage::Error
        raise
      rescue JSON::ParserError, ArgumentError, SystemCallError, IOError, NoMethodError, TypeError => e
        raise Storage::Error, "failed to load blocks from #{@blockchain_file}: #{e.message}"
      end
    RUBY
    to: <<~'RUBY'.chomp,
      rescue StandardError => e
        warn "[FileBackend] Failed to load blocks: #{e.message}"
        nil
      end
    RUBY
    note: 'reinstates path B: a damaged ledger collapses to nil and reads as absent'
  },
  {
    id: 11,
    mechanism: 'the classification refusal at ②③',
    red: %w[5],
    file: CHAIN_RB,
    from: 'unless %i[readable absent].include?(state)',
    to: 'unless %i[readable absent empty corrupt unreadable].include?(state)',
    note: 'every state is accepted for appending'
  },
  {
    id: 12,
    mechanism: 'predicate 1 (block 0 is the canonical genesis)',
    red: %w[6d],
    file: CHAIN_RB,
    from: 'return false unless blocks.first.hash == Block.genesis.hash',
    to: '# predicate 1 removed',
    note: 'a self-consistent fake genesis passes'
  },
  {
    id: 13,
    mechanism: 'predicate 2 (indexes run from 0, one at a time)',
    red: %w[6],
    file: CHAIN_RB,
    from: 'return false unless block.index == i',
    to: '# predicate 2 removed',
    note: 'an index gap passes'
  },
  {
    id: 14,
    mechanism: 'predicate 3 (previous_hash matches the recomputed hash before it)',
    red: %w[6b],
    file: CHAIN_RB,
    from: 'return false unless block.previous_hash == blocks[i - 1].hash',
    to: '# predicate 3 removed',
    note: 'a broken linkage passes'
  },
  {
    id: 15,
    mechanism: 'predicate 4 (Merkle root recomputation)',
    red: %w[6c],
    file: CHAIN_RB,
    from: 'return false unless block.merkle_root == MerkleTree.new(block.data).root',
    to: '# predicate 4 removed',
    note: 'rewritten tail data passes'
  },
  {
    id: 16,
    mechanism: 'totality (a predicate that raises is corruption, not a crash)',
    red: %w[6e],
    file: CHAIN_RB,
    from: <<~'RUBY'.chomp,
      rescue StandardError => e
        # Totality: an exception raised while rebuilding or while evaluating a
        # predicate is itself corruption, not a crash.
        note "[Chain] ledger corrupt: #{e.message}"
        [:corrupt, []]
      end
    RUBY
    to: 'end',
    note: 'a TypeError from a non-string leaf escapes Chain.new'
  },
  {
    id: 17,
    mechanism: 'the write-side contract (failure raises, never returns false)',
    red: %w[8],
    file: FILE_BACKEND_RB,
    from: 'raise Storage::Error, "failed to save blocks to #{@blockchain_file}: #{e.message}"',
    to: 'warn "[FileBackend] Failed to save blocks: #{e.message}"; false',
    note: 'a failed write reads as a benign result and the state advances anyway'
  },
  {
    id: '18a',
    mechanism: 'the state report (mutation: load_state always answers :readable)',
    red: %w[9 9b],
    file: CHAIN_RB,
    from: 'attr_reader :load_state',
    to: 'def load_state = :readable',
    note: 'every reader is told the ledger is fine'
  },
  {
    id: '18b',
    mechanism: 'freezing the sequence outside :readable',
    red: %w[9],
    file: CHAIN_RB,
    from: <<~'RUBY'.chomp,
      def chain
        @load_state == :readable ? @chain : EMPTY_CHAIN
      end
    RUBY
    to: <<~'RUBY'.chomp,
      def chain
        @chain
      end
    RUBY
    also: [[
      <<~'RUBY'.chomp,
        def latest_block
              @load_state == :readable ? @chain.last : nil
            end
      RUBY
      <<~'RUBY'.chomp
        def latest_block
              @chain.last
            end
      RUBY
    ]],
    note: 'readers receive a mutable sequence and a latest_block that is not gated'
  },
  {
    id: 19,
    mechanism: 'valid? unified with the state',
    red: %w[10],
    file: CHAIN_RB,
    from: <<~'RUBY'.chomp,
      def valid?
        @load_state == :readable
      end
    RUBY
    to: <<~'RUBY'.chomp,
      def valid?
        @chain.each_with_index do |block, i|
          next if i.zero?
          return false if block.previous_hash != @chain[i - 1].hash
        end
        true
      end
    RUBY
    note: 'an independent walk over an empty sequence answers true'
  },
  {
    id: 20,
    mechanism: 'INV-G (refuse to append under an undeclared backend)',
    red: %w[12],
    file: CHAIN_RB,
    from: <<~'RUBY'.chomp,
      unless backend.respond_to?(:blockchain_file)
          raise ChainStateError.new(
            "storage backend #{backend.class} does not declare its ledger path",
            state: @load_state
          )
        end
    RUBY
    to: '# INV-G append refusal removed',
    note: 'an undeclared backend raises NoMethodError instead of being refused'
  },
  {
    id: 21,
    mechanism: 'the dividing line (an undeclared backend reads as unreadable)',
    red: %w[12b],
    file: CHAIN_RB,
    from: 'return [:unreadable, []] unless backend.respond_to?(:blockchain_file)',
    to: '# dividing line removed',
    note: 'an undeclared backend’s array is trusted and reads as :readable'
  },
  {
    id: 22,
    mechanism: "the key's path comes from the backend's answer",
    red: %w[14],
    file: CHAIN_RB,
    from: 'lock_path = "#{canonical}.lock"',
    to: 'lock_path = "#{KairosMcp.blockchain_path}.lock"',
    note: 'an injected ledger is guarded by the global key, and vice versa'
  },
  # --- rows added after review R1 -----------------------------------------
  {
    id: 24,
    mechanism: 'absence decided by stat, not by File.exist?',
    red: %w[20 20b],
    file: FILE_BACKEND_RB,
    from: <<~'RUBY'.chomp,
      begin
        File.stat(@blockchain_file)
      rescue Errno::ENOENT, Errno::ENOTDIR
        return nil
      rescue SystemCallError => e
        raise Storage::Error,
              "cannot determine whether ledger #{@blockchain_file} exists: #{e.message}"
      end
    RUBY
    to: 'return nil unless File.exist?(@blockchain_file)',
    note: 'reinstates the measured loss: a stat failure reads as absent and the append rebuilds from genesis'
  },
  {
    id: 25,
    mechanism: 'backend construction inside the protected region',
    red: %w[21],
    file: CHAIN_RB,
    from: <<~'RUBY'.chomp,
      backend = begin
          storage_backend
        rescue StandardError => e
          note "[Chain] storage backend unavailable: #{e.message}"
          return [:unreadable, []]
        end
    RUBY
    to: 'backend = storage_backend',
    note: 'a backend that cannot be built raises out of Chain.new'
  },
  # Row 26 was withdrawn after R1 and is reinstated after R2. The R1 fixture
  # ("dir/x.json" vs "dir/./x.json", a symlinked DIRECTORY) genuinely resolves
  # to one lock inode — the kernel resolves those inside the lock path itself —
  # so the withdrawal looked justified. But the premise was only half refuted:
  # a symlink to the ledger FILE was never tested, and "link.json.lock" is its
  # own name, so the suffix appended before resolution split the key (measured:
  # 2×60 concurrent appends, 21 of 120 blocks lost). Check 22 now uses the
  # file-symlink fixture, concurrently — the sequential version passes even
  # when the lock is split.
  {
    id: 26,
    mechanism: 'the key path is canonicalised before ".lock" is appended',
    red: %w[22],
    file: CHAIN_RB,
    from: <<~'RUBY'.chomp,
      canonical = begin
          File.realpath(path)
        rescue SystemCallError
          begin
            File.realdirpath(path)
          rescue SystemCallError
            File.join(File.realpath(File.dirname(path)), File.basename(path))
          end
        end
        lock_path = "#{canonical}.lock"
    RUBY
    to: 'lock_path = "#{path}.lock"',
    rounds: 60,
    note: 'a symlink to the ledger file takes its own key and exclusion is split'
  },
  {
    id: 27,
    mechanism: 'the key close does not replace the pending exception',
    red: %w[23 23b],
    file: CHAIN_RB,
    from: <<~'RUBY'.chomp,
      begin
        handle.close
      rescue StandardError => e
        raise Storage::Error, "ledger lock close failed (#{lock_path}): #{e.message}" if completed
      end
    RUBY
    to: 'handle.close',
    note: 'a close failure erases the Storage::Error that told the caller to re-read'
  },
  {
    id: 28,
    mechanism: 'body completion tracked explicitly, not read off $!',
    red: %w[23b],
    file: CHAIN_RB,
    from: 'raise Storage::Error, "ledger lock close failed (#{lock_path}): #{e.message}" if completed',
    to: 'raise Storage::Error, "ledger lock close failed (#{lock_path}): #{e.message}" if $!.nil?',
    note: 'under a caller already inside a rescue, $! is non-nil on the normal path and the close failure is swallowed'
  },
  # --- rows added after review R2 -----------------------------------------
  {
    id: 29,
    mechanism: 'every String is brought to valid UTF-8 before hashing',
    red: %w[24],
    file: CHAIN_RB,
    from: 'normalized_data = data.map { |d| d.is_a?(String) ? utf8_for_ledger(d) : d.to_json }',
    to: 'normalized_data = data.map { |d| d.is_a?(String) ? d : d.to_json }',
    note: 'the bytes hashed are no longer the bytes written: one non-UTF-8 append corrupts the ledger on reload'
  },
  {
    id: 30,
    mechanism: 'Chain.new resolves no paths of its own',
    red: %w[25],
    file: CHAIN_RB,
    from: '@chain_file = chain_file',
    to: '@chain_file = chain_file || KairosMcp.blockchain_path',
    note: 'the constructor resolves a path outside every rescue and raises for an unresolvable data dir'
  },
  {
    id: 31,
    mechanism: 'diagnostics cannot change the outcome of a classification',
    red: %w[26],
    file: CHAIN_RB,
    from: <<~'RUBY'.chomp,
      def note(message)
        warn message
      rescue StandardError
        # the diagnostic is lost; the classification is not
      end
    RUBY
    to: <<~'RUBY'.chomp,
      def note(message)
        warn message
      end
    RUBY
    note: 'a failing $stderr makes warn raise inside a rescue branch and escape Chain.new'
  },
  {
    id: 23,
    mechanism: 'the state advance at ⑥',
    red: %w[16],
    file: CHAIN_RB,
    from: '@load_state = :readable',
    to: '# state advance removed',
    note: 'a successful append leaves the instance believing the ledger is absent'
  },
  # --- rows added after review R3 -----------------------------------------
  {
    id: 32,
    mechanism: 'the ledger is read as UTF-8 explicitly, not by locale',
    red: %w[27],
    file: FILE_BACKEND_RB,
    from: 'File.read(@blockchain_file, encoding: Encoding::UTF_8)',
    to: 'File.read(@blockchain_file)',
    note: 'under LANG=C a healthy non-ASCII ledger reads :corrupt and cannot be appended to'
  },
  {
    id: 33,
    mechanism: 'the final component resolves without requiring its target to exist',
    red: %w[28],
    file: CHAIN_RB,
    from: <<~'RUBY'.chomp,
      rescue SystemCallError
            begin
              File.realdirpath(path)
            rescue SystemCallError
              File.join(File.realpath(File.dirname(path)), File.basename(path))
            end
          end
    RUBY
    to: <<~'RUBY'.chomp,
      rescue SystemCallError
            File.join(File.realpath(File.dirname(path)), File.basename(path))
          end
    RUBY
    rounds: 60,
    note: 'while the ledger is absent, a symlinked name keys on its own unresolved basename and the fresh install is written under two keys'
  }
].freeze

# ---------------------------------------------------------------------------

requested = ARGV.map(&:to_s)
rows = requested.empty? ? ROWS : ROWS.select { |r| requested.include?(r[:id].to_s) }
abort "no rows matched #{requested.inspect}" if rows.empty?

scratch = Dir.mktmpdir('kairos_falsify')
at_exit { FileUtils.remove_entry(scratch) if Dir.exist?(scratch) }

FileUtils.cp_r(File.join(SOURCE_ROOT, 'lib'), scratch)
FileUtils.mkdir_p(File.join(scratch, 'templates/skillsets'))
FileUtils.cp_r(File.join(SOURCE_ROOT, 'templates/skillsets/introspection'),
               File.join(scratch, 'templates/skillsets'))
FileUtils.cp(File.join(SOURCE_ROOT, 'test_chain_erasure_fix.rb'), scratch)

PRISTINE = [CHAIN_RB, FILE_BACKEND_RB].to_h { |p| [p, File.read(File.join(scratch, p))] }

def restore(scratch)
  PRISTINE.each { |path, body| File.write(File.join(scratch, path), body) }
end

# A multi-line pattern is matched ignoring how deeply each line is indented, so
# the rows can be written as plain snippets. `^` anchors the flexible part to
# leading indentation only — a single-line pattern is matched literally, because
# it may sit mid-line and swallowing the space before it would break the syntax.
def edit_pattern(pattern)
  return pattern unless pattern.include?("\n")

  Regexp.new(pattern.lines.map { |line| '^[ \t]*' + Regexp.escape(line.chomp.strip) }.join("\n"))
end

# Apply one row's edits. Returns nil on success, or a description of what failed
# to apply — an edit that did not land would make the row a false pass.
def apply(scratch, row)
  edits = [[row[:from], row[:to]]] + (row[:also] || [])
  path = File.join(scratch, row[:file])
  body = File.read(path)

  edits.each do |from, to|
    pattern = edit_pattern(from)
    count = body.scan(pattern).size
    return "edit did not apply (#{count} matches): #{from.lines.first.strip}" unless count >= 1

    body = body.gsub(pattern) { to }
  end

  File.write(path, body)
  syntax, ok = Open3.capture2e('ruby', '-c', path)
  ok.success? ? nil : "mutated file does not parse: #{syntax.strip}"
end

def run_checks(scratch, ids, rounds = nil)
  out, = Open3.capture2e(
    { 'KAIROS_ERASURE_ONLY' => ids.join(','), 'KAIROS_DATA_DIR' => nil,
      'KAIROS_ERASURE_ROUNDS' => rounds&.to_s },
    'ruby', File.join(scratch, 'test_chain_erasure_fix.rb')
  )
  out
end

puts "Falsification — #{rows.size} row(s). One mechanism removed at a time, never in parallel."
puts

results = []

rows.each do |row|
  restore(scratch)
  print format('%-4s %-62s ', row[:id], row[:mechanism][0, 62])

  failure = apply(scratch, row)
  if failure
    puts "SKIPPED — #{failure}"
    results << [row, :not_applied, failure, nil]
    next
  end

  output = run_checks(scratch, row[:red], row[:rounds])
  per_check = row[:red].to_h do |id|
    reds = output.lines.count { |l| l.include?("[#{id}] ❌") }
    greens = output.lines.count { |l| l.include?("[#{id}] ✅") }
    [id, { red: reds, green: greens }]
  end

  all_red = per_check.values.all? { |v| v[:red] >= 1 }
  summary = per_check.map { |id, v| "#{id}: #{v[:red]} red / #{v[:green]} green" }.join(', ')
  first_red = output.lines.find { |l| l.include?('❌') }&.strip

  puts(all_red ? "RED   (#{summary})" : "GREEN (#{summary})  <-- the check does not pin this")
  puts "     first failure: #{first_red}" if first_red
  results << [row, all_red ? :red : :green, summary, first_red]
end

restore(scratch)

puts
puts '=' * 78
puts 'Falsification table'
puts '=' * 78
printf("%-5s %-52s %-8s %s\n", 'row', 'mechanism removed', 'checks', 'measured')
results.each do |row, verdict, summary, _first|
  printf("%-5s %-52s %-8s %s\n",
         row[:id], row[:mechanism][0, 52], row[:red].join(','),
         verdict == :red ? summary : "#{verdict.to_s.upcase} — #{summary}")
end

unpinned = results.reject { |r| r[1] == :red }
puts
if unpinned.empty?
  puts "All #{results.size} rows went red. Every mechanism is pinned by the check named for it."
else
  puts "#{unpinned.size} row(s) did NOT go red — those cells are not evidence:"
  unpinned.each { |row, verdict, summary, _f| puts "  #{row[:id]} #{row[:mechanism]} (#{verdict}): #{summary}" }
end

exit(unpinned.empty? ? 0 : 1)
