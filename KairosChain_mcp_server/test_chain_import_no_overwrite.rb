#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit D / invariant D1: import never overwrites an existing chain.
# Standalone: ruby KairosChain_mcp_server/test_chain_import_no_overwrite.rb

require 'tmpdir'
require 'fileutils'

tmp = Dir.mktmpdir('kairos_import_d')
ENV['KAIROS_DATA_DIR'] = tmp # must be set before kairos_mcp is loaded

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'

unless KairosMcp.blockchain_path.to_s.start_with?(tmp)
  FileUtils.rm_rf(tmp)
  abort "ABORT: KAIROS_DATA_DIR was not honoured (#{KairosMcp.blockchain_path})"
end

require 'kairos_mcp/storage/importer'

@passes = 0
@failures = []

def assert(condition, label)
  if condition
    @passes += 1
    puts "  ok   #{label}"
  else
    @failures << label
    puts "  FAIL #{label}"
  end
end

importer = KairosMcp::Storage::Importer

begin
  # (1) Nothing to protect.
  assert(importer.existing_chain_refusal(File.join(tmp, 'absent.db')).nil?,
         '(1) absent path -> nil')

  empty = File.join(tmp, 'empty.db')
  FileUtils.touch(empty)
  assert(File.size(empty).zero?, '(1) fixture is zero bytes')
  assert(importer.existing_chain_refusal(empty).nil?, '(1) zero-byte file -> nil')

  # (2) A non-empty target is refused by every entry point and left byte-identical.
  occupied = File.join(tmp, 'occupied.db')
  File.binwrite(occupied, 'not-a-database-but-not-empty')
  before = File.binread(occupied)

  input_dir = File.join(tmp, 'input')
  FileUtils.mkdir_p(input_dir)

  res = importer.import(input_dir: input_dir, db_path: occupied)
  assert(res.is_a?(Hash) && res[:refused] == true, '(2) import -> refused: true')
  assert(res.is_a?(Hash) && res[:success] == false, '(2) import -> success: false')
  assert(res.is_a?(Hash) && res[:error].to_s.include?('new data directory'),
         '(2) refusal says where to import instead')

  res = importer.rebuild_from_files(db_path: occupied)
  assert(res.is_a?(Hash) && res[:refused] == true, '(2) rebuild_from_files -> refused: true')

  raised = begin
    importer.import_blockchain(db_path: occupied, blockchain_file: File.join(tmp, 'chain.json'))
    nil
  rescue ArgumentError => e
    e
  end
  assert(!raised.nil?, '(2) import_blockchain raises ArgumentError')

  assert(File.exist?(occupied), '(2) target still exists')
  assert(File.binread(occupied) == before, '(2) target bytes unchanged')

  # (3) Real SQLite targets, when the gem is present.
  sqlite = begin
    require 'sqlite3'
    true
  rescue LoadError
    false
  end

  if sqlite
    with_row = File.join(tmp, 'with_row.db')
    db = SQLite3::Database.new(with_row)
    db.execute('CREATE TABLE blocks (idx INTEGER, data TEXT)')
    db.execute("INSERT INTO blocks (idx, data) VALUES (1, 'x')")
    db.close
    ref = importer.existing_chain_refusal(with_row)
    assert(ref.is_a?(Hash) && ref[:refused] == true, '(3) one block row -> refused')
    assert(ref.is_a?(Hash) && ref[:error].to_s.include?('1 blocks'),
           '(3) refusal names the block count')

    no_rows = File.join(tmp, 'no_rows.db')
    db = SQLite3::Database.new(no_rows)
    db.execute('CREATE TABLE blocks (idx INTEGER, data TEXT)')
    db.close
    assert(importer.existing_chain_refusal(no_rows).nil?, '(3) empty blocks table -> nil')
  else
    puts '  SKIP: sqlite3 not available'
  end

  # (4) The tool description no longer threatens existing data.
  tool_src = File.read(File.expand_path('lib/kairos_mcp/tools/chain_import.rb', __dir__))
  assert(!tool_src.include?('overwrite existing data'),
         '(4) chain_import.rb drops the overwrite-existing-data wording')
ensure
  FileUtils.rm_rf(tmp)
end

puts
puts "passes: #{@passes}  failures: #{@failures.size}"
@failures.each { |f| puts "  - #{f}" }
exit(@failures.empty? ? 0 : 1)
