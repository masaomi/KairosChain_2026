#!/usr/bin/env ruby
# frozen_string_literal: true

# All writes go to temporary host/instance directories. No existing personal
# records, source L0, installed profiles, or connected services are touched.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
$LOAD_PATH.unshift File.expand_path('templates/skillsets/kairomone/lib', __dir__)
require 'kairomone'
require 'tmpdir'
require 'open3'
require 'kairos_mcp/skillset'
require 'kairos_mcp/tool_registry'

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

def refuses
  begin
    yield
  rescue Kairomone::Error, Errno::ENOENT
    return true
  end
  raise 'Expected safe refusal'
end

def fixture
  Dir.mktmpdir('kairomone-test-') do |host|
    KairosMcp.data_dir = host
    FileUtils.mkdir_p(File.join(host, 'skills'))
    File.write(File.join(host, 'skills/kairos.rb'), '# host immutable Ruby')
    File.write(File.join(host, 'skills/kairos.md'), '# Host philosophy')
    File.write(File.join(host, 'skills/config.yml'), <<~YAML)
      state_commit:
        enabled: true
        auto_commit:
          enabled: true
    YAML
    store = Kairomone::Instance.new
    store.init(dot_id: 'my_dot', display_name: 'My dot 🌿')
    yield store, host
  end
end

def populate(store)
  assert store.create_knowledge(id: 'first', title: '日本語 <test>', content: '知識 🌿 & <script>not code</script>')[:success]
  assert store.observe(title: 'Observation', content: 'L2 hypothesis')[:success]
end

def host_files(host)
  Dir.glob(File.join(host, '**/*'), File::FNM_DOTMATCH).select { |path| File.file?(path) && !path.start_with?(File.join(host, 'kairomone') + '/') && !path.start_with?(File.join(host, 'kairomone-restored') + '/') }.to_h { |path| [path.delete_prefix(host + '/'), File.binread(path)] }
end

def rewrite_archive(store, file)
  path = File.join(store.root, 'backups', file)
  value = JSON.parse(File.binread(path))
  yield value
  File.write(path, JSON.generate(value))
end

check('repeat initialization preserves profile and dot binding') do
  fixture do |store, _|
    before = File.binread(File.join(store.root, 'profile.json'))
    result = store.init(dot_id: 'my_dot', display_name: 'Different ignored name')
    assert result[:preserved] && !result[:initialized]
    assert before == File.binread(File.join(store.root, 'profile.json'))
    refuses { store.init(dot_id: 'other_dot', display_name: 'Other') }
  end
end

check('canonical L1/L2 unicode roundtrip; host L0 and auto-commit state untouched') do
  fixture do |store, host|
    before = host_files(host)
    populate(store)
    item = store.read_knowledge(id: 'first')
    assert item[:content].include?('知識 🌿') && item[:recorded]
    assert store.knowledge_provider.is_a?(KairosMcp::KnowledgeProvider)
    assert store.context_manager.is_a?(KairosMcp::ContextManager)
    assert store.chain.valid? && store.chain.chain.length == 2
    status = store.status
    assert status[:knowledge][:count] == 1 && status[:observations][:count] == 1
    assert status[:integrity][:host_l0][:state] == 'unchanged'
    assert before == host_files(host), 'Unexpected host changes with state_commit enabled'
    ordinary = KairosMcp::KnowledgeProvider.new(nil, vector_search_enabled: false, include_skillset_knowledge: false)
    assert ordinary.get('first').nil?, 'Host ordinary provider must not pretend to see dedicated store'
  end
end

check('knowledge retries preserve data and never overwrite a different body') do
  fixture do |store, _|
    populate(store)
    chain = File.binread(File.join(store.root, 'storage/blockchain.json'))
    result = store.create_knowledge(id: 'first', title: '日本語 <test>', content: '知識 🌿 & <script>not code</script>')
    assert result[:success] && result[:preserved]
    refuses { store.create_knowledge(id: 'first', title: 'other', content: 'replacement') }
    assert chain == File.binread(File.join(store.root, 'storage/blockchain.json'))
  end
end

check('bounded inputs, invalid UTF-8 and traversal IDs are refused') do
  fixture do |store, _|
    %w[../escape /absolute bad/name . ..].each { |id| refuses { store.create_knowledge(id: id, title: 'a', content: 'b') } }
    refuses { store.observe(title: 'a', content: 'x' * 16_385) }
    refuses { store.create_knowledge(id: 'bad', title: 'a', content: "\xff".dup.force_encoding('UTF-8')) }
    assert store.status[:knowledge][:count].zero? && store.status[:observations][:count].zero?
  end
end

check('corrupt ledger refuses new L1 before content is written') do
  fixture do |store, _|
    populate(store)
    ledger = File.join(store.root, 'storage/blockchain.json')
    File.write(ledger, '{broken')
    refuses { store.create_knowledge(id: 'second', title: 't', content: 'c') }
    assert !File.exist?(File.join(store.root, 'knowledge/second'))
    assert File.read(ledger) == '{broken'
    assert !store.status[:integrity][:valid]
    refuses { store.create_backup }
  end
end

check('upstream swallowed ledger write failure is reported pending, not success') do
  fixture do |original, host|
    failing = Class.new(KairosMcp::Storage::FileBackend) do
      def save_all_blocks(_blocks)
        raise KairosMcp::Storage::Error, 'simulated disk write failure'
      end
    end.new(storage_dir: File.join(original.root, 'storage'), blockchain_file: File.join(original.root, 'storage/blockchain.json'), action_log_file: File.join(original.root, 'storage/action_log.jsonl'))
    store = Kairomone::Instance.new(host_root: host, backend: failing)
    result = store.create_knowledge(id: 'pending', title: 'Pending', content: 'Preserve me')
    assert !result[:success] && result[:pending] && result[:data_written] && !result[:recorded_on_chain]
    assert original.read_knowledge(id: 'pending')[:content] == 'Preserve me'
    assert original.status[:integrity][:pending_count] == 1
    retry_result = original.create_knowledge(id: 'pending', title: 'Pending', content: 'Preserve me')
    assert retry_result[:pending] && !retry_result[:success]
    refuses { original.create_backup }
  end
end

check('content tampering and missing L1 files fail correspondence') do
  fixture do |store, _|
    populate(store)
    md = File.join(store.root, 'knowledge/first/first.md')
    original = File.binread(md)
    File.write(md, original + 'tampered')
    assert store.status[:integrity][:pending_count] == 1
    refuses { store.create_backup }
    FileUtils.rm_rf(File.dirname(md))
    assert store.status[:integrity][:pending_count] == 1
    refuses { store.create_backup }
  end
end

check('owned backup verifies and restores byte-identically to a new read-only target') do
  fixture do |store, host|
    populate(store)
    File.write(File.join(host, 'private-account-token.txt'), 'NEVER_IN_BACKUP')
    File.write(File.join(store.root, 'storage/private-token.txt'), 'NEVER_IN_BACKUP')
    backup = store.create_backup
    assert backup[:verified]
    raw = File.binread(backup[:path])
    assert !raw.include?('NEVER_IN_BACKUP') && !raw.include?('private-token')
    restore = store.restore_backup(file: backup[:file], target_id: 'recovered')
    assert restore[:restored] && !restore[:active_instance_changed]
    recovered = Kairomone::Instance.new(host_root: host, restored_id: 'recovered')
    assert recovered.status[:integrity][:valid]
    assert recovered.read_knowledge(id: 'first')[:content] == store.read_knowledge(id: 'first')[:content]
    files = JSON.parse(raw)['files']
    files.each { |entry| assert File.binread(File.join(restore[:path], entry['path'])) == Base64.strict_decode64(entry['content_base64']) }
    refuses { store.restore_backup(file: backup[:file], target_id: 'recovered') }
    refuses { recovered.observe(title: 'No', content: 'Cannot write') }
    refuses { store.restore_backup(file: backup[:file], target_id: '../escape') }
  end
end

check('empty initialized instance can roundtrip without inventing a ledger') do
  fixture do |store, host|
    backup = store.create_backup
    store.restore_backup(file: backup[:file], target_id: 'empty')
    restored = Kairomone::Instance.new(host_root: host, restored_id: 'empty')
    assert restored.status[:integrity][:state] == 'absent'
    assert !File.exist?(File.join(restored.root, 'storage/blockchain.json'))
  end
end

check('archive checksum tamper refuses without creating the target') do
  fixture do |store, host|
    populate(store)
    backup = store.create_backup
    rewrite_archive(store, backup[:file]) { |a| a['files'][0]['content_base64'] = Base64.strict_encode64('tampered') }
    refuses { store.verify_backup(file: backup[:file]) }
    refuses { store.restore_backup(file: backup[:file], target_id: 'bad') }
    assert !File.exist?(File.join(host, 'kairomone-restored/bad'))
  end
end

check('archive traversal, duplicates, symlink metadata and oversized entries are refused') do
  fixture do |store, host|
    populate(store)
    backup = store.create_backup
    path = backup[:path]
    original = File.binread(path)
    attacks = [
      ->(a) { a['files'][0]['path'] = '../outside' },
      ->(a) { a['files'] << a['files'][0].dup },
      ->(a) { a['files'][0]['type'] = 'symlink' },
      ->(a) { a['files'][0]['size'] = Kairomone::Instance::TOTAL_LIMIT + 1 }
    ]
    attacks.each do |attack|
      File.binwrite(path, original)
      rewrite_archive(store, backup[:file], &attack)
      refuses { store.restore_backup(file: backup[:file], target_id: 'attack') }
      assert !File.exist?(File.join(host, 'outside'))
      assert !File.exist?(File.join(host, 'kairomone-restored/attack'))
    end
    refuses { store.verify_backup(file: '../profile.json') }
    refuses { store.verify_backup(file: '/tmp/backup.kairomone.json') }
  end
end

check('symlink and hardlink writes cannot escape through the store or ledger') do
  fixture do |store, host|
    sentinel = File.join(host, 'sentinel')
    File.write(sentinel, 'unchanged')
    FileUtils.rm_rf(File.join(store.root, 'knowledge'))
    File.symlink(host, File.join(store.root, 'knowledge'))
    refuses { store.create_knowledge(id: 'escape', title: 'a', content: 'b') }
    assert File.read(sentinel) == 'unchanged'
  end
  fixture do |store, host|
    sentinel = File.join(host, 'sentinel')
    File.write(sentinel, 'unchanged')
    File.link(sentinel, File.join(store.root, 'storage/blockchain.json'))
    refuses { store.create_knowledge(id: 'escape', title: 'a', content: 'b') }
    assert File.read(sentinel) == 'unchanged'
  end
  fixture do |store, host|
    sentinel = File.join(host, 'sentinel')
    File.write(sentinel, 'unchanged')
    File.unlink(File.join(store.root, '.lock'))
    File.link(sentinel, File.join(store.root, '.lock'))
    refuses { store.observe(title: 'a', content: 'b') }
    assert File.read(sentinel) == 'unchanged'
  end
end

check('host layer lock is honored without changing configuration') do
  fixture do |store, host|
    config = File.join(host, 'skills/config.yml')
    File.write(config, "layers:\n  L1:\n    enabled: true\n    mutable: false\n  L2:\n    enabled: false\n    mutable: true\n")
    refuses { store.create_knowledge(id: 'locked', title: 'a', content: 'b') }
    refuses { store.observe(title: 'a', content: 'b') }
    assert store.status[:knowledge][:count].zero?
  end
end

check('L0 fingerprint change is explicit and files remain untouched') do
  fixture do |store, host|
    File.write(File.join(host, 'skills/kairos.md'), '# Changed by test operator')
    assert store.status[:integrity][:host_l0][:state] == 'changed'
    assert File.read(File.join(host, 'skills/kairos.md')) == '# Changed by test operator'
  end
end

check('real Skillset and ToolRegistry load all seven tools; runtime survives package removal') do
  fixture do |store, host|
    package = File.expand_path('templates/skillsets/kairomone', __dir__)
    installed = File.join(host, 'skillsets/kairomone')
    FileUtils.mkdir_p(File.dirname(installed))
    FileUtils.cp_r(package, installed)
    script = <<~'SCRIPT'
      require 'kairos_mcp'
      require 'kairos_mcp/skillset'
      require 'kairos_mcp/tool_registry'
      installed = File.join(KairosMcp.data_dir, 'skillsets/kairomone')
      skillset = KairosMcp::Skillset.new(installed)
      raise 'Invalid SkillSet' unless skillset.valid? && !skillset.knowledge_only?
      skillset.load!
      registry = KairosMcp::ToolRegistry.new
      names = registry.list_tools.map { |tool| tool[:name] || tool['name'] }
      %w[kairomone_init kairomone_status kairomone_observe kairomone_knowledge kairomone_backup kairomone_profession kairomone_growth].each { |name| raise "Missing registry tool #{name}" unless names.include?(name) }
      response = registry.call_tool('kairomone_status', {})
      raise 'Uninitialized registry profile' unless JSON.parse(response.first[:text])['initialized']
    SCRIPT
    output, errors, status = Open3.capture3({ 'KAIROS_DATA_DIR' => host }, RbConfig.ruby, '-I', File.expand_path('lib', __dir__), '-e', script)
    assert status.success?, "Registry subprocess failed: #{output} #{errors}"
    populate(store)
    FileUtils.rm_rf(installed)
    assert store.read_knowledge(id: 'first')[:recorded]
    assert !store.root.start_with?(package + '/')
  end
end

check('authenticated multiuser tool use refuses rather than sharing one profile') do
  fixture do |_store, _host|
    require_relative 'templates/skillsets/kairomone/tools/kairomone_tools'
    safety = Object.new
    def safety.current_user; { user_id: 'someone' }; end
    tool = KairosMcp::SkillSets::KairomoneSkillSet::Tools::Init.new(safety)
    result = JSON.parse(tool.call('dot_id' => 'someone', 'display_name' => 'Someone').first[:text])
    assert result['success'] == false && result['error'].include?('multiuser')
  end
end

check('CLI subprocess uses selected host data and supports the full basic path') do
  Dir.mktmpdir('kairomone-cli-') do |host|
    cli = File.expand_path('templates/skillsets/kairomone/scripts/kairomone.rb', __dir__)
    env = { 'KAIROS_DATA_DIR' => host }
    run = lambda do |*args|
      output, errors, status = Open3.capture3(env, RbConfig.ruby, cli, *args)
      assert status.success?, "CLI failed: #{output} #{errors}"
      JSON.parse(output)
    end
    assert run.call('init', '--dot-id', 'cli_dot', '--name', 'CLI dot')['success']
    assert run.call('knowledge', 'create', '--id', 'cli_note', '--title', 'Title', '--content', 'Body')['recorded_on_chain']
    assert run.call('knowledge', 'get', '--id', 'cli_note')['content'] == 'Body'
    assert run.call('observe', '--title', 'Seen', '--content', 'Today')['success']
    assert File.file?(run.call('status', '--html')['html_path'])
    file = run.call('backup', 'create')['file']
    assert run.call('backup', 'verify', '--file', file)['verified']
    assert run.call('backup', 'restore', '--file', file, '--target-id', 'cli_restore')['restored']
    assert run.call('status', '--instance', 'cli_restore')['integrity']['valid']
  end
end

check('portable fresh-host recovery resumes canonical writes and preserves the original') do
  fixture do |store, old_host|
    populate(store)
    backup = store.create_backup
    old_snapshot = Dir.glob(File.join(old_host, '**/*'), File::FNM_DOTMATCH).select { |f| File.file?(f) }.to_h { |f| [f, File.binread(f)] }
    Dir.mktmpdir('kairomone-portable-') do |new_host|
      FileUtils.cp_r(File.join(old_host, 'skills'), File.join(new_host, 'skills'))
      FileUtils.mkdir_p(File.join(new_host, 'kairomone-inbox'))
      FileUtils.cp(backup[:path], File.join(new_host, 'kairomone-inbox', backup[:file]))
      recovered = Kairomone::Instance.new(host_root: new_host)
      refuses { recovered.restore_new(file: backup[:file], dot_id: 'wrong_dot') }
      assert !File.exist?(recovered.root)
      result = recovered.restore_new(file: backup[:file], dot_id: 'my_dot')
      assert result[:success] && result[:active]
      assert result[:integrity][:host_l0][:state] == 'unchanged'
      assert recovered.read_knowledge(id: 'first')[:recorded]
      KairosMcp.data_dir = new_host
      assert recovered.create_knowledge(id: 'after_recovery', title: 'New', content: 'Resumed successfully')[:recorded_on_chain]
      assert recovered.observe(title: 'After recovery', content: 'New L2')[:success]
      refuses { recovered.restore_new(file: backup[:file], dot_id: 'my_dot') }
      old_snapshot.each { |path, bytes| assert File.binread(path) == bytes, "Original modified: #{path}" }
      assert File.binread(File.join(new_host, 'kairomone-inbox', backup[:file])) == File.binread(backup[:path])
    end
  end
end

check('fresh-host recovery reports changed L0 honestly and leaves it untouched') do
  fixture do |store, _|
    populate(store)
    backup = store.create_backup
    Dir.mktmpdir('kairomone-l0-different-') do |host|
      FileUtils.mkdir_p(File.join(host, 'skills'))
      File.write(File.join(host, 'skills/kairos.rb'), '# Different host law')
      File.write(File.join(host, 'skills/kairos.md'), '# Different host philosophy')
      FileUtils.mkdir_p(File.join(host, 'kairomone-inbox'))
      FileUtils.cp(backup[:path], File.join(host, 'kairomone-inbox', backup[:file]))
      recovered = Kairomone::Instance.new(host_root: host)
      result = recovered.restore_new(file: backup[:file], dot_id: 'my_dot')
      assert result[:integrity][:host_l0][:state] == 'changed' && result[:l0_warning]
      assert File.read(File.join(host, 'skills/kairos.rb')) == '# Different host law'
      assert File.read(File.join(host, 'skills/kairos.md')) == '# Different host philosophy'
      assert recovered.profile['host_l0_baseline'] == store.profile['host_l0_baseline']
    end
  end
end

check('CLI Unicode roundtrip works under the C locale') do
  Dir.mktmpdir('kairomone-cli-locale-') do |host|
    cli = File.expand_path('templates/skillsets/kairomone/scripts/kairomone.rb', __dir__)
    env = { 'KAIROS_DATA_DIR' => host, 'LC_ALL' => 'C', 'LANG' => 'C' }
    [['init', '--dot-id', 'locale_dot', '--name', '日本語 🌿'],
     ['knowledge', 'create', '--id', 'unicode', '--title', '名前', '--content', '知識 🌿']].each do |args|
      output, errors, status = Open3.capture3(env, RbConfig.ruby, cli, *args)
      assert status.success?, "C-locale CLI failed: #{output} #{errors}"
    end
    output, errors, status = Open3.capture3(env, RbConfig.ruby, cli, 'knowledge', 'get', '--id', 'unicode')
    assert status.success?, errors
    item = JSON.parse(output)
    assert item['content'] == '知識 🌿' && item['recorded']
  end
end

puts "\n#{PASSED.length} checks passed; #{FAILED.length} failed"
exit(FAILED.empty? ? 0 : 1)
