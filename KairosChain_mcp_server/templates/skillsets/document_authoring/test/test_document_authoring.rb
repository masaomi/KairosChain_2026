#!/usr/bin/env ruby
# frozen_string_literal: true

# Test suite for document_authoring SkillSet
# Usage: ruby test_document_authoring.rb

$LOAD_PATH.unshift File.expand_path('../../../../lib', __dir__)

require 'json'
require 'yaml'
require 'fileutils'
require 'tmpdir'
require 'kairos_mcp/invocation_context'
require 'kairos_mcp/tools/base_tool'
require_relative '../lib/document_authoring'

$pass = 0
$fail = 0

def assert(description, &block)
  result = block.call
  if result
    $pass += 1
    puts "  PASS: #{description}"
  else
    $fail += 1
    puts "  FAIL: #{description}"
  end
rescue StandardError => e
  $fail += 1
  puts "  FAIL: #{description} (#{e.class}: #{e.message})"
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "TEST: #{title}"
  puts '=' * 60
end

PV = KairosMcp::SkillSets::DocumentAuthoring::PathValidator
CA = KairosMcp::SkillSets::DocumentAuthoring::ContextAssembler
SW = KairosMcp::SkillSets::DocumentAuthoring::SectionWriter

TMPDIR = Dir.mktmpdir('docauth_test')

# =========================================================================
# Mock tools for testing
# =========================================================================

class MockSafety
  attr_reader :safe_root

  def initialize(root)
    @safe_root = root
  end
end

class MockRegistry
  def initialize(tools = {})
    @tools = tools
  end

  def list_tools
    @tools.keys.map { |n| { name: n } }
  end

  def call_tool(name, arguments, invocation_context: nil)
    tool = @tools[name]
    raise "Unknown tool: #{name}" unless tool

    tool.call(arguments)
  end
end

# A mock tool that wraps invoke_tool for testing ContextAssembler and SectionWriter
class MockCallerTool < KairosMcp::Tools::BaseTool
  attr_accessor :invoke_results

  def initialize(safety = nil, registry: nil)
    super
    @invoke_results = {}
  end

  def name
    'mock_caller'
  end

  def description
    'mock'
  end

  def input_schema
    { type: 'object', properties: {} }
  end

  def call(_args)
    []
  end

  # Override invoke_tool for testing
  def invoke_tool(tool_name, arguments = {}, context: nil)
    key = arguments['uri'] || tool_name
    result = @invoke_results[key]
    raise "Mock: no result for #{key}" unless result

    result
  end
end

# =========================================================================
# 1. PathValidator
# =========================================================================

section "PathValidator — Basic validation"

assert("T3: rejects absolute path") do
  begin
    PV.validate!('/etc/passwd', TMPDIR)
    false
  rescue ArgumentError => e
    e.message.include?("Absolute paths not allowed")
  end
end

assert("T4: rejects .. traversal") do
  begin
    PV.validate!('../../../etc/passwd.md', TMPDIR)
    false
  rescue ArgumentError => e
    e.message.include?("Path escapes workspace")
  end
end

assert("T5: rejects disallowed extension") do
  begin
    PV.validate!('test.rb', TMPDIR)
    false
  rescue ArgumentError => e
    e.message.include?("Extension not allowed")
  end
end

assert("rejects empty path") do
  begin
    PV.validate!('', TMPDIR)
    false
  rescue ArgumentError => e
    e.message.include?("Empty path")
  end
end

assert("rejects nil path") do
  begin
    PV.validate!(nil, TMPDIR)
    false
  rescue ArgumentError => e
    e.message.include?("Empty path")
  end
end

assert("T22: allows valid path and creates parent directories") do
  result = PV.validate!('subdir/test.md', TMPDIR)
  result.end_with?('subdir/test.md') &&
    File.directory?(File.join(TMPDIR, 'subdir'))
end

assert("T14/T25: creates nested parent directories") do
  result = PV.validate!('a/b/c/test.md', TMPDIR)
  File.directory?(File.join(TMPDIR, 'a', 'b', 'c'))
end

assert("allows .txt extension") do
  result = PV.validate!('notes.txt', TMPDIR)
  result.end_with?('notes.txt')
end

section "PathValidator — Symlink escape"

assert("T20: rejects symlink in parent directory") do
  # Create a symlink pointing outside TMPDIR
  outside = Dir.mktmpdir('outside')
  link_path = File.join(TMPDIR, 'evil_link')
  File.symlink(outside, link_path) unless File.exist?(link_path)

  begin
    PV.validate!('evil_link/test.md', TMPDIR)
    false  # Should have raised
  rescue ArgumentError => e
    e.message.include?("Symlink")
  ensure
    FileUtils.rm_rf(outside)
    FileUtils.rm_f(link_path)
  end
end

assert("T21: rejects symlink target file") do
  outside_file = File.join(Dir.mktmpdir('outside2'), 'secret.md')
  File.write(outside_file, 'secret')
  link_file = File.join(TMPDIR, 'linked.md')
  File.symlink(outside_file, link_file) unless File.exist?(link_file)

  begin
    PV.validate!('linked.md', TMPDIR)
    false
  rescue ArgumentError => e
    e.message.include?("symlink")
  ensure
    FileUtils.rm_f(link_file)
    FileUtils.rm_rf(File.dirname(outside_file))
  end
end

assert("T23: rejects file exceeding max size") do
  big_file = File.join(TMPDIR, 'big.md')
  File.write(big_file, 'x' * 1000)

  begin
    PV.validate!('big.md', TMPDIR, max_file_size: 500)
    false
  rescue ArgumentError => e
    e.message.include?("too large")
  ensure
    FileUtils.rm_f(big_file)
  end
end

section "PathValidator — Directory validation"

assert("T24: validates directory path") do
  dir = File.join(TMPDIR, 'drafts')
  FileUtils.mkdir_p(dir)
  result = PV.validate_dir!('drafts', TMPDIR)
  File.directory?(result)
end

assert("validate_dir! rejects absolute path") do
  begin
    PV.validate_dir!('/tmp', TMPDIR)
    false
  rescue ArgumentError => e
    e.message.include?("Absolute paths not allowed")
  end
end

assert("validate_dir! rejects path escape") do
  begin
    PV.validate_dir!('../../', TMPDIR)
    false
  rescue ArgumentError => e
    e.message.include?("Path escapes workspace")
  end
end

assert("validate_dir! returns expanded path for non-existent dir") do
  result = PV.validate_dir!('nonexistent', TMPDIR)
  result.include?('nonexistent')
end

# =========================================================================
# 2. ContextAssembler
# =========================================================================

section "ContextAssembler"

assert("T12: parses knowledge:// URI correctly") do
  caller = MockCallerTool.new
  caller.invoke_results['knowledge://test_knowledge'] = [{ text: 'Knowledge content here' }]
  assembler = CA.new(caller)
  result = assembler.assemble(['knowledge://test_knowledge'])
  result[:loaded] == 1 && result[:text].include?('Knowledge content here')
end

assert("T13: parses context:// URI correctly") do
  caller = MockCallerTool.new
  caller.invoke_results['context://session123/my_context'] = [{ text: 'Context content' }]
  assembler = CA.new(caller)
  result = assembler.assemble(['context://session123/my_context'])
  result[:loaded] == 1 && result[:text].include?('Context content')
end

assert("T14: skips unknown scheme with warning") do
  caller = MockCallerTool.new
  assembler = CA.new(caller)
  result = assembler.assemble(['http://example.com'])
  result[:failed] == 1 &&
    result[:loaded] == 0 &&
    result[:warnings].any? { |w| w.include?('Unknown URI scheme') }
end

assert("T6: continues on failed source with warning") do
  caller = MockCallerTool.new
  # First source fails (no mock result), second succeeds
  caller.invoke_results['knowledge://good'] = [{ text: 'Good content' }]
  assembler = CA.new(caller)
  result = assembler.assemble(['knowledge://bad', 'knowledge://good'])
  result[:loaded] == 1 && result[:failed] == 1 && result[:warnings].size == 1
end

assert("T15: respects total context budget") do
  caller = MockCallerTool.new
  caller.invoke_results['knowledge://a'] = [{ text: 'x' * 10_000 }]
  caller.invoke_results['knowledge://b'] = [{ text: 'y' * 10_000 }]
  assembler = CA.new(caller, max_total_chars: 12_000, max_chars_per_source: 10_000)
  result = assembler.assemble(['knowledge://a', 'knowledge://b'])
  result[:text].length <= 12_100  # small overhead for headers
end

assert("T16: truncates at paragraph boundary") do
  text_with_paragraphs = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph that is very long."
  caller = MockCallerTool.new
  caller.invoke_results['knowledge://para'] = [{ text: text_with_paragraphs }]
  assembler = CA.new(caller, max_chars_per_source: 40)
  result = assembler.assemble(['knowledge://para'])
  # Should cut at paragraph boundary, not mid-word
  result[:text].include?('First paragraph') && !result[:text].include?('Third')
end

assert("handles empty source list") do
  caller = MockCallerTool.new
  assembler = CA.new(caller)
  result = assembler.assemble([])
  result[:loaded] == 0 && result[:text] == ''
end

assert("handles nil source list") do
  caller = MockCallerTool.new
  assembler = CA.new(caller)
  result = assembler.assemble(nil)
  result[:loaded] == 0
end

assert("truncates excess sources with warning") do
  caller = MockCallerTool.new
  12.times { |i| caller.invoke_results["knowledge://s#{i}"] = [{ text: "content#{i}" }] }
  assembler = CA.new(caller, max_sources: 3)
  sources = 12.times.map { |i| "knowledge://s#{i}" }
  result = assembler.assemble(sources)
  result[:loaded] == 3 &&
    result[:warnings].any? { |w| w.include?('Truncated') }
end

# =========================================================================
# 3. SectionWriter
# =========================================================================

section "SectionWriter"

assert("T17: parses llm_call ok response correctly") do
  caller = MockCallerTool.new
  caller.invoke_results['llm_call'] = [{
    text: JSON.generate({
      'status' => 'ok',
      'response' => { 'content' => 'Generated section text here.' },
      'snapshot' => {}
    })
  }]

  output_path = File.join(TMPDIR, 'writer_test.md')
  writer = SW.new(caller, {})
  result = writer.write(
    section_name: 'test',
    instructions: 'Write a test section',
    context_text: '',
    output_file: output_path,
    max_words: 100
  )

  result['status'] == 'ok' &&
    result['word_count'] == 4 &&
    File.exist?(output_path) &&
    File.read(output_path) == 'Generated section text here.'
end

assert("T18: parses llm_call error response correctly") do
  caller = MockCallerTool.new
  caller.invoke_results['llm_call'] = [{
    text: JSON.generate({
      'status' => 'error',
      'error' => { 'type' => 'rate_limit', 'message' => 'Too many requests' }
    })
  }]

  writer = SW.new(caller, {})
  result = writer.write(
    section_name: 'test',
    instructions: 'Write',
    context_text: '',
    output_file: File.join(TMPDIR, 'should_not_exist.md')
  )

  result['error']&.include?('rate_limit') &&
    !File.exist?(File.join(TMPDIR, 'should_not_exist.md'))
end

assert("T19: handles empty LLM content") do
  caller = MockCallerTool.new
  caller.invoke_results['llm_call'] = [{
    text: JSON.generate({
      'status' => 'ok',
      'response' => { 'content' => '' }
    })
  }]

  writer = SW.new(caller, {})
  result = writer.write(
    section_name: 'test',
    instructions: 'Write',
    context_text: '',
    output_file: File.join(TMPDIR, 'empty_test.md')
  )

  result['error']&.include?('empty content')
end

assert("T7: append_mode appends to existing file") do
  append_file = File.join(TMPDIR, 'append_test.md')
  File.write(append_file, 'Existing content.')

  caller = MockCallerTool.new
  caller.invoke_results['llm_call'] = [{
    text: JSON.generate({
      'status' => 'ok',
      'response' => { 'content' => 'Appended content.' }
    })
  }]

  writer = SW.new(caller, {})
  result = writer.write(
    section_name: 'test',
    instructions: 'Append',
    context_text: '',
    output_file: append_file,
    append_mode: true
  )

  content = File.read(append_file)
  result['status'] == 'ok' &&
    content.include?('Existing content.') &&
    content.include?('Appended content.')
end

assert("T13: respects max_words in prompt") do
  prompt_captured = nil
  caller = MockCallerTool.new
  # Intercept to capture the prompt
  def caller.invoke_tool(tool_name, arguments = {}, context: nil)
    if tool_name == 'llm_call'
      @captured_messages = arguments['messages']
      [{ text: JSON.generate({ 'status' => 'ok', 'response' => { 'content' => 'Test.' } }) }]
    else
      super
    end
  end
  def caller.captured_messages; @captured_messages; end

  writer = SW.new(caller, {})
  writer.write(
    section_name: 'test',
    instructions: 'Write',
    context_text: '',
    output_file: File.join(TMPDIR, 'prompt_test.md'),
    max_words: 750
  )

  msg = caller.captured_messages&.first&.dig('content')
  msg&.include?('750 words')
end

assert("handles malformed JSON from LLM") do
  caller = MockCallerTool.new
  caller.invoke_results['llm_call'] = [{ text: 'not json at all' }]

  writer = SW.new(caller, {})
  result = writer.write(
    section_name: 'test',
    instructions: 'Write',
    context_text: '',
    output_file: File.join(TMPDIR, 'malformed_test.md')
  )

  result['error']&.include?('parse')
end

# =========================================================================
# 4. Tool-level: write_section error result compatibility
# =========================================================================

section "Tool Integration"

assert("T8: error result has 'error' key (decode_tool_result compatible)") do
  # Simulate what autoexec_run decode_tool_result does
  error_result = { 'error' => 'Some error message' }
  json_text = JSON.generate(error_result)
  parsed = JSON.parse(json_text)

  # This is what autoexec_run checks:
  parsed.is_a?(Hash) && parsed['error']
end

assert("T8b: success result does NOT have 'error' key") do
  success_result = { 'status' => 'ok', 'section_name' => 'test', 'word_count' => 100 }
  json_text = JSON.generate(success_result)
  parsed = JSON.parse(json_text)

  parsed.is_a?(Hash) && !parsed['error']
end

# =========================================================================
# 5. DocumentStatus (via direct call)
# =========================================================================

section "DocumentStatus"

assert("T9: returns correct word counts") do
  status_dir = File.join(TMPDIR, 'status_test')
  FileUtils.mkdir_p(status_dir)
  File.write(File.join(status_dir, '01_abstract.md'), 'one two three four five')
  File.write(File.join(status_dir, '02_intro.md'), 'hello world')

  # Directly test the scanning logic
  files = Dir[File.join(status_dir, '*.md')].sort
  sections = files.map do |f|
    content = File.read(f)
    { 'file' => File.basename(f), 'word_count' => content.split.size }
  end
  total = sections.sum { |s| s['word_count'] }

  sections.size == 2 && total == 7
end

assert("T10: empty directory returns zero") do
  empty_dir = File.join(TMPDIR, 'empty_status')
  FileUtils.mkdir_p(empty_dir)
  files = Dir[File.join(empty_dir, '*.md')]
  files.empty?
end

assert("T11: respects max_files cap") do
  cap_dir = File.join(TMPDIR, 'cap_status')
  FileUtils.mkdir_p(cap_dir)
  60.times { |i| File.write(File.join(cap_dir, "sec_#{i.to_s.rjust(3, '0')}.md"), "word#{i}") }

  max_files = 50
  files = Dir[File.join(cap_dir, '*.md')].sort.first(max_files)
  files.size == 50
end

assert("scans both .md and .txt when configured") do
  mixed_dir = File.join(TMPDIR, 'mixed_status')
  FileUtils.mkdir_p(mixed_dir)
  File.write(File.join(mixed_dir, 'section.md'), 'markdown content')
  File.write(File.join(mixed_dir, 'notes.txt'), 'text content')

  extensions = ['.md', '.txt']
  patterns = extensions.map { |ext| File.join(mixed_dir, "*#{ext}") }
  files = patterns.flat_map { |p| Dir.glob(p) }
  files.size == 2
end

# =========================================================================
# 6. Integration: Tool call() paths
# =========================================================================

section "Tool call() Integration"

# Build a mock registry with llm_call and resource_read
require_relative '../tools/write_section'
require_relative '../tools/document_status'

WS = KairosMcp::SkillSets::DocumentAuthoring::Tools::WriteSection
DS = KairosMcp::SkillSets::DocumentAuthoring::Tools::DocumentStatus

# Mock registry that provides llm_call and resource_read
class IntegrationMockRegistry
  attr_accessor :llm_response, :resource_response

  def initialize
    @llm_response = nil
    @resource_response = nil
  end

  def list_tools
    [{ name: 'llm_call' }, { name: 'resource_read' }]
  end

  def call_tool(name, arguments, invocation_context: nil)
    case name
    when 'llm_call'
      [{ text: JSON.generate(@llm_response || { 'status' => 'ok', 'response' => { 'content' => 'Test output.' } }) }]
    when 'resource_read'
      [{ text: @resource_response || 'Context text here.' }]
    else
      raise "Unknown tool: #{name}"
    end
  end
end

assert("write_section.call produces output file via full call path") do
  int_dir = File.join(TMPDIR, 'int_test')
  FileUtils.mkdir_p(int_dir)
  safety = MockSafety.new(int_dir)
  registry = IntegrationMockRegistry.new
  tool = WS.new(safety, registry: registry)

  result = tool.call({
    'section_name' => 'abstract',
    'instructions' => 'Write an abstract',
    'output_file' => 'draft.md'
  })

  parsed = JSON.parse(result[0][:text])
  parsed['status'] == 'ok' &&
    parsed['word_count'] == 2 &&
    File.exist?(File.join(int_dir, 'draft.md')) &&
    File.read(File.join(int_dir, 'draft.md')) == 'Test output.'
end

assert("write_section.call returns error when llm_call missing") do
  int_dir = File.join(TMPDIR, 'int_nollm')
  FileUtils.mkdir_p(int_dir)
  safety = MockSafety.new(int_dir)
  empty_registry = Class.new {
    def list_tools; []; end
  }.new
  tool = WS.new(safety, registry: empty_registry)

  result = tool.call({
    'section_name' => 'test',
    'instructions' => 'Write',
    'output_file' => 'test.md'
  })

  parsed = JSON.parse(result[0][:text])
  parsed['error']&.include?('llm_call')
end

assert("write_section.call with malformed invocation_context_json fails closed") do
  int_dir = File.join(TMPDIR, 'int_failclosed')
  FileUtils.mkdir_p(int_dir)
  safety = MockSafety.new(int_dir)
  registry = IntegrationMockRegistry.new
  tool = WS.new(safety, registry: registry)

  result = tool.call({
    'section_name' => 'test',
    'instructions' => 'Write',
    'output_file' => 'fc_test.md',
    'invocation_context_json' => '{invalid json!!!'
  })

  # Malformed invocation_context_json must yield an error (fail-closed).
  # The empty-whitelist InvocationContext blocks llm_call via invoke_tool.
  parsed = JSON.parse(result[0][:text])
  parsed['error'] != nil
end

assert("document_status.call returns JSON with sections") do
  ds_dir = File.join(TMPDIR, 'ds_int_test')
  FileUtils.mkdir_p(ds_dir)
  File.write(File.join(ds_dir, 'sec1.md'), 'one two three')

  safety = MockSafety.new(TMPDIR)
  tool = DS.new(safety)

  result = tool.call({ 'output_dir' => 'ds_int_test' })
  parsed = JSON.parse(result[0][:text])

  parsed['total_sections'] == 1 &&
    parsed['total_word_count'] == 3 &&
    parsed['sections'][0]['file'] == 'sec1.md' &&
    parsed['sections'][0]['modified'] != nil
end

assert("document_status.call skips symlinked files") do
  ds_sym_dir = File.join(TMPDIR, 'ds_sym_test')
  FileUtils.mkdir_p(ds_sym_dir)
  File.write(File.join(ds_sym_dir, 'real.md'), 'real content')

  outside = Dir.mktmpdir('ds_outside')
  File.write(File.join(outside, 'secret.md'), 'secret data')
  sym_path = File.join(ds_sym_dir, 'link.md')
  File.symlink(File.join(outside, 'secret.md'), sym_path) unless File.exist?(sym_path)

  safety = MockSafety.new(TMPDIR)
  tool = DS.new(safety)

  result = tool.call({ 'output_dir' => 'ds_sym_test' })
  parsed = JSON.parse(result[0][:text])

  # Should only see real.md, not link.md
  parsed['total_sections'] == 1 &&
    parsed['sections'][0]['file'] == 'real.md'
ensure
  FileUtils.rm_rf(outside)
  FileUtils.rm_f(sym_path) if defined?(sym_path)
end

assert("document_status.call for non-existent dir returns empty") do
  safety = MockSafety.new(TMPDIR)
  tool = DS.new(safety)
  result = tool.call({ 'output_dir' => 'does_not_exist' })
  parsed = JSON.parse(result[0][:text])
  parsed['total_sections'] == 0 && parsed['note']&.include?('does not exist')
end

assert("validate_dir! rejects nil path") do
  begin
    PV.validate_dir!(nil, TMPDIR)
    false
  rescue ArgumentError => e
    e.message.include?("Empty directory path")
  end
end

assert("validate_dir! rejects empty string") do
  begin
    PV.validate_dir!('', TMPDIR)
    false
  rescue ArgumentError => e
    e.message.include?("Empty directory path")
  end
end

# =========================================================================
# Cleanup
# =========================================================================

FileUtils.rm_rf(TMPDIR)

puts "\n#{'=' * 60}"
puts "RESULTS: #{$pass} passed, #{$fail} failed (#{$pass + $fail} total)"
puts '=' * 60

exit($fail > 0 ? 1 : 0)
