# frozen_string_literal: true

# Shared fixtures for the Kairomone 0.9 suites (test_kairomone_09_*.rb),
# design log/kairomone_0_9_screens_and_generated_growth_design_v0.2_20261102.md.
require_relative 'support_08'

module Kairomone09Support
  include Kairomone08Support

  BASE_08 = '53c9830' # Kairomone 0.8.0 on main, the base of 0.9
  PROFILE = { 'name' => 'Momo', 'kind' => 'animal', 'kind_label' => 'Fox', 'appearance' => 'A small round fox',
              'personality' => %w[curious], 'voice' => 'Soft', 'interests' => %w[stories] }.freeze
  CRAFT = { 'description' => 'Learns from the living world', 'focus' => %w[ecology botany],
            'habits' => { 'sources' => 'primary', 'depth' => 'deep', 'reflection' => 'narrative', 'stance' => 'practical' } }.freeze
  FORM = 'A small round fox'

  def setup = fresh_host
  def teardown = FileUtils.remove_entry_secure(@host)

  # A Kairomone as 0.9's kairomone_create makes it: no profession.
  def create(id = 'momo', profile: PROFILE)
    Kairomone::Host.new.create(listing_id: id, profile: profile.merge('name' => profile['name'] || id.capitalize), material_kind: 'free_text')
    Kairomone::Instance.new(host_root: @host, kairomone: id)
  end

  def grow_to(store, level, prefix: 'fact')
    n = 0
    n += 1 while store.progression_status[:level] < level && store.create_knowledge(id: "#{prefix}_#{n}", title: "#{prefix} #{n}", content: "Distinct #{prefix} #{n}")
  end

  # Exactly this level: L1 entries (50 XP) while they fit, then L2 (10 XP).
  def grow_exactly(store, level, prefix: 'exact')
    target = (level - 1) * Kairomone::Progression::XP_PER_LEVEL
    n = 0
    while (xp = store.progression_status[:total_xp]) < target
      n += 1
      if xp + Kairomone::Progression::L1_XP <= target
        store.create_knowledge(id: "#{prefix}_#{n}", title: "#{prefix} #{n}", content: "Distinct #{prefix} #{n}")
      else
        store.observe(id: "#{prefix}_obs_#{n}", title: "#{prefix} #{n}", content: "Distinct observation #{prefix} #{n}")
      end
    end
    raise "grew past #{level}" unless store.progression_status[:level] == level
  end

  def candidates(prefix) = 3.times.map { |i| CRAFT.merge('name' => "#{prefix} #{i}") }

  def evidence(content: 'What the cycle learned', title: 'Synthesis', finding: 'A finding', url: 'https://example.com/a',
               reference: 'fixture fetch')
    excerpt = "Synthetic excerpt for #{content}"
    { 'knowledge' => { 'title' => title, 'content' => content }, 'finding' => finding, 'uncertainty' => 'u', 'counterexample' => 'c',
      'sources' => [{ 'url' => url, 'title' => 'Fixture', 'retrieved_at' => Time.now.utc.iso8601, 'excerpt' => excerpt,
                      'retrieval_reference' => reference, 'excerpt_sha256' => Digest::SHA256.hexdigest(excerpt) }] }
  end

  # One completed cycle in a one-cycle run.
  def one_cycle(store, id, subjects: %w[geology], topic: 'A topic', methods_applied: nil, **evidence_args)
    growth = store.autonomy
    run = growth.run_start(owner_words: 'One cycle', cycles: 1)
    step = { run_id: run[:run_id], token: run[:token] }
    growth.request(**step, request_id: id, topic: topic, subjects: subjects)
    claim = growth.claim(**step, worker_id: 'worker')
    growth.commit(**step, claim_token: claim['claim_token'], evidence: evidence(**{ content: "Learned in #{id}" }.merge(evidence_args)),
                  methods_applied: methods_applied)
  end

  def lean(store, id, words, subjects) = store.companion_lean(request_id: id, owner_words: words, subjects: subjects)

  def records(store, type) = Kairomone::Records.of_type(store.chain, type)

  def archive_of(path) = JSON.parse(File.read(path))

  def resign(archive, key = File.binread(File.join(@host, 'kairomone-keys/archive.key')))
    archive['manifest_sha256'] = Kairomone::Instance.manifest_hash(archive['files'])
    archive['signature'] = { 'algorithm' => 'HMAC-SHA256', 'key_sha256' => Kairomone::ArchiveKey.fingerprint(key),
                             'value' => Kairomone::ArchiveKey.sign(key, archive['manifest_sha256']) }
    archive
  end

  def file_entry(path, bytes)
    { 'path' => path, 'size' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes), 'content_base64' => Base64.strict_encode64(bytes) }
  end

  # The Kairomone 0.8.0 library, from git, for cross-version checks.
  def lib_08
    @@lib_08 ||= begin
      repo = File.expand_path('../../../../..', __dir__)
      names, status = Open3.capture2('git', '-C', repo, 'ls-tree', '-r', '--name-only', BASE_08, 'KairosChain_mcp_server/templates/skillsets/kairomone/lib',
                                     'KairosChain_mcp_server/templates/skillsets/kairomone/templates')
      raise "git cannot read #{BASE_08}" unless status.success? && !names.empty?

      dir = Dir.mktmpdir('kairomone-08-lib-')
      names.split("\n").each do |name|
        body, ok = Open3.capture2('git', '-C', repo, 'show', "#{BASE_08}:#{name}")
        raise "git show #{name} failed" unless ok.success?

        target = File.join(dir, name.delete_prefix('KairosChain_mcp_server/templates/skillsets/kairomone/'))
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, body)
      end
      File.join(dir, 'lib')
    end
  rescue StandardError => e
    skip "0.8.0 code unavailable: #{e.message}"
  end

  # Runs Ruby under the 0.8.0 library against a host; returns the JSON it prints.
  def with_08(host, script)
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', File.expand_path('../../../../lib', __dir__), '-I', lib_08, '-e',
                                      "require 'kairomone'; require 'json'; host = ARGV[0]; KairosMcp.data_dir = host; #{script}", host)
    raise "0.8.0 run failed: #{out} #{err}" unless status.success?

    JSON.parse(out)
  end
end
