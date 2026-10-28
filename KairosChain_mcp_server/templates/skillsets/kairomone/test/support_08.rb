# frozen_string_literal: true

# Shared fixtures for the Kairomone 0.8 suites (test_kairomone_08_*.rb).
$LOAD_PATH.unshift File.expand_path('../../../../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'kairomone'
require 'minitest'
require 'tmpdir'
require 'open3'
require 'kairos_mcp/tools/base_tool'
require_relative '../tools/kairomone_tools'
require_relative 'legacy_fixture'

module Kairomone08Support
  TOOLS = KairosMcp::SkillSets::KairomoneSkillSet::Tools
  BASE_061 = 'ba6ef0a' # Kairomone 0.6.1 on branch kairomone-claude-code

  def fresh_host
    @host = Dir.mktmpdir('kairomone-08-')
    KairosMcp.data_dir = @host
    FileUtils.mkdir_p(File.join(@host, 'skills'))
    File.write(File.join(@host, 'skills/kairos.rb'), '# synthetic L0 rules')
    File.write(File.join(@host, 'skills/kairos.md'), '# synthetic philosophy')
  end

  # What kairomone_create will do: assemble under the registry lock, list by one rename.
  def make(id, name = id.capitalize)
    host = Kairomone::Host.new(host_root: @host)
    host.with_registry_lock { host.assemble(id) { |s| s.open_new!(identity: id, origin: 'create', listing_id: id, name: name) } }
    Kairomone::Instance.new(host_root: @host, kairomone: id)
  end

  def tool(klass, args)
    JSON.parse(TOOLS.const_get(klass).new(nil).call(args).first[:text])
  end

  def listing = Kairomone::Host.new(host_root: @host).listing.map { |l| l[:listing_id] }

  def types(store) = store.chain.chain.drop(1).flat_map { |b| b.data.map { |d| JSON.parse(d)['type'] } }

  # The 0.6.1 SkillSet library, from git, for compatibility checks.
  def lib_061
    @@lib_061 ||= begin
      repo = File.expand_path('../../../../..', __dir__)
      names, status = Open3.capture2('git', '-C', repo, 'ls-tree', '-r', '--name-only', BASE_061, 'KairosChain_mcp_server/templates/skillsets/kairomone/lib')
      raise "git cannot read #{BASE_061}" unless status.success? && !names.empty?

      dir = Dir.mktmpdir('kairomone-061-lib-')
      names.split("\n").each do |name|
        body, ok = Open3.capture2('git', '-C', repo, 'show', "#{BASE_061}:#{name}")
        raise "git show #{name} failed" unless ok.success?

        target = File.join(dir, name.delete_prefix('KairosChain_mcp_server/templates/skillsets/kairomone/'))
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, body)
      end
      File.join(dir, 'lib')
    end
  rescue StandardError => e
    skip "0.6.1 code unavailable: #{e.message}"
  end

  # Runs Ruby under the 0.6.1 library against a host; returns the parsed JSON it prints.
  def with_061(host, script)
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', File.expand_path('../../../../lib', __dir__), '-I', lib_061, '-e',
                                      "require 'kairomone'; require 'json'; host = ARGV[0]; KairosMcp.data_dir = host; #{script}", host)
    raise "0.6.1 run failed: #{out} #{err}" unless status.success?

    JSON.parse(out)
  end
end
