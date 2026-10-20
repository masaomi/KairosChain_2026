#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regression test for L1 history activation labelling.
#
# Case 1: a version recorded before the activation point must be reported with
#         recorded_while_active == false, and the history command must label it
#         "provable by hash only".
# Case 2: when the store root cannot be created while history is configured on,
#         the L1 write is refused and no activation record is appended; the
#         refusal is not memoized, so a later write retries.
#
# Both cases fail on the pre-fix code.

require 'tmpdir'
require 'fileutils'
require 'json'

tmp = Dir.mktmpdir('l1_history_labels')
ENV['KAIROS_DATA_DIR'] = tmp

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/knowledge_provider'
require 'kairos_mcp/tools/knowledge_update'

FAILURES = []

def assert(condition, message)
  if condition
    puts "  ok   #{message}"
  else
    puts "  FAIL #{message}"
    FAILURES << message
  end
end

# Row keys may be symbols or strings; read either.
def fetch_either(row, key)
  return nil unless row.is_a?(Hash)
  return row[key] if row.key?(key)
  return row[key.to_s] if row.key?(key.to_s)

  nil
end

def body_for(name, version)
  "---\nname: #{name}\ndescription: \"#{version}\"\n---\n# #{version}\n"
end

def write_history_config(enabled)
  path = KairosMcp.skills_config_path
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, "l1_history:\n  enabled: #{enabled ? 'true' : 'false'}\n")
end

# The provider memoizes activation, so every config change needs a new one.
def fresh_provider
  KairosMcp::KnowledgeProvider.new(nil, vector_search_enabled: false)
end

def refused?(result)
  return false unless result.is_a?(Hash)

  fetch_either(result, :success) == false || !fetch_either(result, :error).nil?
end

# Activation records, read through the Chain API: each block carries an array
# of JSON strings.
def activation_records
  KairosMcp::KairosChain::Chain.new.chain.flat_map do |block|
    Array(block.data).map do |raw|
      begin
        JSON.parse(raw.to_s)
      rescue JSON::ParserError
        nil
      end
    end
  end.compact.select { |d| d.is_a?(Hash) && d['type'] == 'l1_history_activation' }
end

def tool_text(output)
  parts = output.is_a?(Array) ? output : [output]
  parts.map { |part| fetch_either(part, :text).to_s }.join("\n")
end

begin
  unless KairosMcp.blockchain_path.to_s.start_with?(tmp)
    abort "refusing to run: chain path #{KairosMcp.blockchain_path} is not under #{tmp}"
  end
  FileUtils.mkdir_p(KairosMcp.knowledge_dir)

  puts 'case 1: labels across the activation point'
  write_history_config(false)
  provider = fresh_provider
  created = provider.create('note', body_for('note', 'v1'))
  assert(!refused?(created), 'note v1 is created while history is off')
  assert(activation_records.empty?, 'no activation record exists while history is off')

  write_history_config(true)
  provider = fresh_provider
  updated = provider.update('note', body_for('note', 'v2'))
  assert(!refused?(updated), 'note v2 is recorded while history is on')
  assert(activation_records.size == 1, 'exactly one activation record after switching history on')

  rows = provider.history('note')
  assert(rows.is_a?(Array) && rows.size >= 2, 'history returns both versions')
  if rows.is_a?(Array) && rows.size >= 2
    assert(fetch_either(rows[0], :recorded_while_active) == false,
           'the version recorded before the activation point is marked inactive')
    assert(fetch_either(rows[1], :recorded_while_active) == true,
           'the version recorded after the activation point is marked active')
  end

  output = KairosMcp::Tools::KnowledgeUpdate.new.call('command' => 'history', 'name' => 'note')
  assert(tool_text(output).include?('provable by hash only'),
         'the history command labels the pre-activation version "provable by hash only"')

  puts 'case 2: an unusable store root refuses the write'
  write_history_config(true)
  store_root = File.join(File.dirname(KairosMcp.knowledge_dir), 'l1_history')
  moved_aside = "#{store_root}.moved_aside"
  begin
    File.rename(store_root, moved_aside) if File.exist?(store_root)
    File.write(store_root, "placeholder: not a directory\n")

    # Delta, not absolute: case 1 already produced one activation record.
    before = activation_records.size

    first = fresh_provider.create('blocked_one', body_for('blocked_one', 'v1'))
    assert(refused?(first), 'the L1 write is refused while the store root cannot be created')
    assert(fetch_either(first, :error).to_s.include?('history store unavailable'),
           'the refusal says the history store is unavailable')
    assert(activation_records.size == before, 'no activation record is appended on the refusal')

    second = fresh_provider.create('blocked_two', body_for('blocked_two', 'v1'))
    assert(refused?(second), 'a later write retries and is refused again')
    assert(activation_records.size == before, 'still no activation record after the second refusal')
  ensure
    File.delete(store_root) if File.file?(store_root)
    File.rename(moved_aside, store_root) if File.exist?(moved_aside)
  end
ensure
  FileUtils.rm_rf(tmp)
end

if FAILURES.empty?
  puts "\nall checks passed"
else
  puts "\n#{FAILURES.size} check(s) failed"
  FAILURES.each { |message| puts "  - #{message}" }
  exit 1
end
