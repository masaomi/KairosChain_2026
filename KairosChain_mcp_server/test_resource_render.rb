# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'

$LOAD_PATH.unshift(File.join(__dir__, 'lib'))
require 'kairos_mcp'
require 'kairos_mcp/tools/resource_render'
require 'kairos_mcp/anthropic_skill_parser'

class TestResourceRender < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('kairos_render_test')
    @original_data_dir = ENV['KAIROS_DATA_DIR']
    ENV['KAIROS_DATA_DIR'] = @tmpdir
    KairosMcp.reset_data_dir!

    # Create knowledge directory structure
    @knowledge_dir = File.join(@tmpdir, 'knowledge', 'test_knowledge')
    @scripts_dir = File.join(@knowledge_dir, 'scripts')
    @assets_dir = File.join(@knowledge_dir, 'assets')
    FileUtils.mkdir_p(@scripts_dir)
    FileUtils.mkdir_p(@assets_dir)

    # Create knowledge MD file
    File.write(File.join(@knowledge_dir, 'test_knowledge.md'), <<~MD)
      ---
      name: test_knowledge
      description: Test knowledge for render tests
      version: "1.0"
      tags: [test]
      ---
      # Test Knowledge
    MD

    # Create a simple render script
    @script_path = File.join(@scripts_dir, 'render_report.rb')
    File.write(@script_path, <<~'RUBY')
      require 'json'
      data = JSON.parse($stdin.read)
      puts "<html><body><h1>#{data['title']}</h1></body></html>"
    RUBY

    # Create a failing script
    @fail_script = File.join(@scripts_dir, 'render_fail.rb')
    File.write(@fail_script, <<~'RUBY')
      $stderr.puts "Something went wrong"
      exit 1
    RUBY

    @tool = KairosMcp::Tools::ResourceRender.new
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
    if @original_data_dir
      ENV['KAIROS_DATA_DIR'] = @original_data_dir
    else
      ENV.delete('KAIROS_DATA_DIR')
    end
    KairosMcp.reset_data_dir!
  end

  def call_tool(args)
    result = @tool.call(args)
    # Extract text from MCP content envelope
    if result.is_a?(Array) && result[0].is_a?(Hash)
      result[0][:text] || result[0]['text']
    elsif result.is_a?(Hash)
      result[:text] || result['text']
    else
      result.to_s
    end
  end

  # --- Happy path ---

  def test_render_success
    data = JSON.generate({ 'title' => 'Test Report' })
    result = call_tool({
      'knowledge' => 'test_knowledge',
      'script' => 'render_report.rb',
      'data' => data
    })

    assert_includes result, 'Resource Rendered'
    assert_includes result, 'knowledge://test_knowledge/assets/report.html'

    # Verify file was created
    output_path = File.join(@assets_dir, 'report.html')
    assert File.exist?(output_path), "Output file should exist at #{output_path}"
    content = File.read(output_path)
    assert_includes content, '<h1>Test Report</h1>'
  end

  def test_render_custom_output_name
    data = JSON.generate({ 'title' => 'Custom' })
    result = call_tool({
      'knowledge' => 'test_knowledge',
      'script' => 'render_report.rb',
      'data' => data,
      'output' => 'my_report.html'
    })

    assert_includes result, 'my_report.html'
    assert File.exist?(File.join(@assets_dir, 'my_report.html'))
  end

  def test_output_name_derived_from_script
    # render_report.rb -> report.html (strip render_ prefix and .rb extension)
    data = JSON.generate({ 'title' => 'Derived' })
    call_tool({
      'knowledge' => 'test_knowledge',
      'script' => 'render_report.rb',
      'data' => data
    })

    assert File.exist?(File.join(@assets_dir, 'report.html'))
  end

  # --- Error cases ---

  def test_missing_knowledge
    result = call_tool({
      'knowledge' => 'nonexistent',
      'script' => 'render_report.rb',
      'data' => '{}'
    })

    assert_includes result, "Error: knowledge 'nonexistent' not found"
  end

  def test_missing_script
    result = call_tool({
      'knowledge' => 'test_knowledge',
      'script' => 'no_such_script.rb',
      'data' => '{}'
    })

    assert_includes result, "Error: script 'no_such_script.rb' not found"
  end

  def test_invalid_json_data
    result = call_tool({
      'knowledge' => 'test_knowledge',
      'script' => 'render_report.rb',
      'data' => 'not json{'
    })

    assert_includes result, 'Error: invalid JSON data'
  end

  def test_script_failure
    result = call_tool({
      'knowledge' => 'test_knowledge',
      'script' => 'render_fail.rb',
      'data' => '{}'
    })

    assert_includes result, 'Error: script exited with code 1'
    assert_includes result, 'Something went wrong'
  end

  def test_path_traversal_blocked
    result = call_tool({
      'knowledge' => 'test_knowledge',
      'script' => '../../etc/passwd',
      'data' => '{}'
    })

    # File.basename normalizes to just "passwd"
    assert_includes result, "Error: script 'passwd' not found"
  end

  # --- Required parameter validation ---

  def test_missing_knowledge_param
    result = call_tool({ 'script' => 'x.rb', 'data' => '{}' })
    assert_includes result, 'Error: knowledge is required'
  end

  def test_missing_script_param
    result = call_tool({ 'knowledge' => 'test_knowledge', 'data' => '{}' })
    assert_includes result, 'Error: script is required'
  end

  def test_missing_data_param
    result = call_tool({ 'knowledge' => 'test_knowledge', 'script' => 'render_report.rb' })
    assert_includes result, 'Error: data is required'
  end

  # --- Assets directory auto-creation ---

  def test_creates_assets_dir_if_missing
    FileUtils.rm_rf(@assets_dir)
    refute File.directory?(@assets_dir)

    data = JSON.generate({ 'title' => 'AutoDir' })
    call_tool({
      'knowledge' => 'test_knowledge',
      'script' => 'render_report.rb',
      'data' => data
    })

    assert File.directory?(@assets_dir)
    assert File.exist?(File.join(@assets_dir, 'report.html'))
  end
end
