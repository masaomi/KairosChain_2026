#!/usr/bin/env ruby
# frozen_string_literal: true

# Live wiring validation for dream_digest — exercises the REAL registration path that the
# unit suite (test_dream_digest.rb) bypasses by instantiating the tool class directly:
#   skillset.json tool_classes string -> Object.const_get -> registry-signature instantiation
#   -> name() dispatch -> full package/write/read/sweep flow -> derived-tier persistence.
# Catches registration typos, constructor-signature drift, and dispatch-key mismatches.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'json'
require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'kairos_mcp/context_manager'
require 'kairos_mcp/knowledge_provider'
require 'kairos_mcp/tools/base_tool'

ss_dir = File.join(__dir__, 'templates', 'skillsets', 'dream')
manifest = JSON.parse(File.read(File.join(ss_dir, 'skillset.json')))
require_relative 'templates/skillsets/dream/lib/dream/digester'
require_relative 'templates/skillsets/dream/tools/dream_digest'

data = Dir.mktmpdir('dd_live')
KairosMcp.data_dir = data
FileUtils.mkdir_p(KairosMcp.context_dir)

fails = 0
ok = lambda do |desc, cond|
  puts((cond ? '  PASS: ' : '  FAIL: ') + desc)
  fails += 1 unless cond
end

puts "dream_digest LIVE wiring validation (Ruby #{RUBY_VERSION})"

# 1. tool_classes string from skillset.json must resolve (registration typo guard).
klass_name = manifest['tool_classes'].find { |c| c.include?('DreamDigest') }
klass = Object.const_get(klass_name)
ok.("skillset.json tool_classes resolves: #{klass_name}", klass.is_a?(Class))

# 2. Must instantiate with the registry's signature: klass.new(@safety, registry: self).
tool = klass.new(nil, registry: nil)
ok.('instantiates via registry signature new(safety, registry:)', !tool.nil?)
ok.("name() is the dispatch key 'dream_digest'", tool.name == 'dream_digest')
ok.('input_schema advertises modes', tool.input_schema[:properties][:mode][:enum].include?('package'))

# 3. Full flow through the tool's public call(), as the MCP server invokes it.
cdir = File.join(KairosMcp.context_dir, 's_live', 'frag1')
FileUtils.mkdir_p(cdir)
File.write(File.join(cdir, 'frag1.md'), "---\ntags:\n  - live\n---\nLive fragment one.")

pkg = tool.call('mode' => 'package', 'topic' => 'Live Topic', 'from_tag' => 'live', 'include_l1' => false)
ok.('package returns content array', pkg.is_a?(Array) && pkg.first[:text].is_a?(String))
ok.('package resolved the tagged fragment', pkg.first[:text].include?('s_live/frag1'))

snap = KairosMcp::SkillSets::Dream::Digester.new
            .package(topic: 'Live Topic', from_tag: 'live', include_l1: false)[:snapshot]
w = tool.call('mode' => 'write', 'topic' => 'Live Topic', 'snapshot' => snap,
              'content' => 'A live digest of one fragment.')
ok.('write reports Written', w.first[:text].include?('Written'))
ok.('read returns the content', tool.call('mode' => 'read', 'topic' => 'Live Topic').first[:text].include?('A live digest'))
ok.('sweep lists the digest', tool.call('mode' => 'sweep').first[:text].include?('live_topic'))

# 4. Persisted in the derived tier under data_dir, never in context/knowledge (I1/I10).
dpath = File.join(KairosMcp.data_dir, 'dream', 'digest', 'live_topic', 'live_topic.md')
ok.('digest persisted in derived tier', File.exist?(dpath))
ok.('digest NOT under context dir', Dir.glob(File.join(KairosMcp.context_dir, '**', 'live_topic.md')).empty?)

FileUtils.remove_entry(data)
puts(fails.zero? ? "\nLIVE VALIDATION: ALL PASS" : "\nLIVE VALIDATION: #{fails} FAILED")
exit(fails.zero? ? 0 : 1)
