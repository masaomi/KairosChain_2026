# frozen_string_literal: true

# Independent end-to-end regression: only fresh temporary hosts are touched.
# Uses the real public Skillset loader, ToolRegistry, canonical providers, and CLI.
#
# Kairomone 0.8 (design log/kairomone_core_0_8_design_v0.6_FROZEN_20261023.md):
# init lists the individual under kairomones/<id>/ (M1) with a profile version
# instead of profile.json (M4); kairomone_list, kairomone_create and
# kairomone_profile join the tools (M3); with two
# individuals on the host (after a restore) every call names one (M2); a
# restore makes a separate listed twin that appends its own record (Inv 1,
# M15); backups are signed with the host's archive key (kairomone-keys/, a
# host-level Kairomone file like the inbox), and the fresh host restores the
# archive as stored once the owner copies that key there; each L1 create adds
# an identity record before its update block (Inv 3).
#
# Changed in run C (run_20261023_100956_bec01a): kairomone_art joins the tools
# (design M3, phase 5), so the registered list names twelve. No other check
# in this file changed.
#
# Changed in run D (run_20261023_130838_773740): kairomone_exchange and
# kairomone_fusion join the tools (design M3, phases 8 and 9), so the
# registered list names fourteen. No other check in this file changed.

require 'json'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'open3'
require 'yaml'
require 'timeout'
CORE = __dir__
REPO = File.expand_path('..', CORE)
$LOAD_PATH.unshift(File.join(CORE, 'lib'))
require 'kairos_mcp'
require 'kairos_mcp/initializer'
require 'kairos_mcp/tool_registry'
require 'kairos_mcp/state_commit/pending_changes'
require 'kairos_mcp/skillset_manager'
PACKAGE = File.join(CORE, 'templates', 'skillsets', 'kairomone')
$passes = 0
# Install through core's standard SkillSet lifecycle (what `kairos-chain
# skillset install <path>` calls). The lifecycle record goes to the chain of
# the current data_dir, so switch to the target host for the duration.
def install_package(host)
  previous = KairosMcp.data_dir
  KairosMcp.data_dir = host
  KairosMcp::SkillSetManager.new(skillsets_dir: File.join(host, 'skillsets')).install(PACKAGE)
ensure
  KairosMcp.data_dir = previous
end
def check(label)
  raise "FAIL: #{label}" unless yield
  $passes += 1
  puts "PASS: #{label}"
end
def invoke(reg, name, args={})
  JSON.parse(reg.call_tool(name, args).first.fetch(:text))
end
def tree(path, exclude: [])
  Dir.glob(File.join(path,'**','*'), File::FNM_DOTMATCH).sort.each_with_object({}) do |p,h|
    rel=p.delete_prefix(path+'/')
    next if ['.','..'].include?(File.basename(p)) || exclude.any?{|x| rel==x || rel.start_with?(x+'/')}
    h[rel] = File.directory?(p) ? 'directory' : Digest::SHA256.file(p).hexdigest
  end
end

def refused
  yield; false
rescue Kairomone::Error,Errno::ENOENT
  true
end
def fresh
  Dir.mktmpdir('kairomone-attack-') do |tmp|
    host=File.join(tmp,'host'); FileUtils.mkdir_p(host); KairosMcp.data_dir=host
    i=Kairomone::Instance.new(host_root:host); i.init(dot_id:'test',display_name:'Test')
    yield i,host,tmp
  end
end
Dir.mktmpdir('kairomone-independent-') do |tmp|
  host=File.join(tmp,'host')
  KairosMcp.data_dir=host
  KairosMcp::Initializer.run(quiet:true)
  config=YAML.safe_load_file(KairosMcp.skills_config_path)
  config['state_commit']={'enabled'=>true,'auto_commit'=>{'enabled'=>true,'skip_if_no_changes'=>false,'change_threshold'=>{'enabled'=>true,'l1_changes'=>1,'total_changes'=>1}}}
  File.write(KairosMcp.skills_config_path, config.to_yaml)
  installed=install_package(host)
  check('fresh package installed through core SkillSetManager') { installed[:success] && installed[:name]=='kairomone' }
  plugin=File.join(host,'skillsets','kairomone')
  check('install recorded as a skillset_event on the host chain') do
    blocks=JSON.parse(File.read(File.join(host,'storage','blockchain.json')))
    blocks.flat_map{|b| b['data']}.any?{|d| (r=JSON.parse(d) rescue nil) && r['type']=='skillset_event' && r['skillset_name']=='kairomone' && r['action']=='install'}
  end
  ss=KairosMcp::Skillset.new(plugin)
  check('real Skillset loads installed package') { ss.valid? && ss.load! && ss.loaded? }
  reg=KairosMcp::ToolRegistry.new
  names=reg.list_tools.map{|t|t[:name]}.grep(/^kairomone_/).sort
  check('all fourteen tools registered by real ToolRegistry') { names==%w[kairomone_art kairomone_backup kairomone_companion kairomone_create kairomone_exchange kairomone_fusion kairomone_growth kairomone_init kairomone_knowledge kairomone_list kairomone_observe kairomone_profession kairomone_profile kairomone_status] }
  outside=%w[kairomone kairomones kairomone-restored kairomone-keys]
  base=tree(host,exclude:outside)
  own=File.join(host,'kairomones','review_dot')
  pending=KairosMcp::StateCommit::PendingChanges.all
  check('host auto state-commit enabled') { KairosMcp::SkillsConfig.state_commit_enabled? && KairosMcp::SkillsConfig.state_commit_auto_enabled? }
  hostile="芽 <script>window.pwned=true</script> & \" <img onerror='alert(1)'>"
  init=invoke(reg,'kairomone_init',{'dot_id'=>'review_dot','display_name'=>hostile})
  check('tool initializes owned profile') { init['success'] && init['initialized'] }
  original=tree(own)
  repeat=invoke(reg,'kairomone_init',{'dot_id'=>'review_dot','display_name'=>'replacement'})
  check('repeated init byte-preserves all owned content') { repeat['preserved'] && tree(own)==original }
  check('different dot id refused') { invoke(reg,'kairomone_init',{'dot_id'=>'other','display_name'=>'Other'})['success']==false }
  %w[../escape /tmp/escape . .. A slash/name].each do |id|
    check("unsafe knowledge ID refused: #{id}") { invoke(reg,'kairomone_knowledge',{'command'=>'create','id'=>id,'title'=>'unsafe','content'=>'unsafe'})['success']==false }
  end
  obs=invoke(reg,'kairomone_observe',{'title'=>hostile,'content'=>"Body of observation\n日本語"})
  check('L2 canonical observation saved without chain record') { obs['success'] && obs['canonical'] && obs['recorded_on_chain']==false }
  check('L2 uses canonical ContextManager directory') { File.file?(File.join(own,'context','kairomone',obs['id'],obs['id']+'.md')) }
  create_args={'command'=>'create','id'=>'review_knowledge','title'=>hostile,'content'=>"Knowledge body.\n日本語"}
  know=invoke(reg,'kairomone_knowledge',create_args)
  check('L1 successful only with verified chain record') { know['success'] && know['canonical'] && know['recorded_on_chain'] && !know['pending'] }
  got=invoke(reg,'kairomone_knowledge',{'command'=>'get','id'=>'review_knowledge'})
  check('L1 get returns exact user content and recording') { got['success'] && got['content']==create_args['content'] && got['recorded'] }
  owned_before=tree(own)
  repeat=invoke(reg,'kairomone_knowledge',create_args)
  check('identical L1 retry adds no files or ledger blocks') { repeat['preserved'] && tree(own)==owned_before }
  conflict=invoke(reg,'kairomone_knowledge',create_args.merge('content'=>'replacement'))
  check('existing L1 overwrite refused byte-for-byte') { conflict['success']==false && tree(own)==owned_before }
  check('host global pending state-commit unchanged') { KairosMcp::StateCommit::PendingChanges.all==pending }
  check('host L0/config/knowledge/context/ledger unchanged by runtime tools') { tree(host,exclude:outside)==base }
  provider=KairosMcp::KnowledgeProvider.new(nil,vector_search_enabled:false)
  check('host knowledge provider does not discover owned user entry') { provider.get('review_knowledge').nil? }
  st=invoke(reg,'kairomone_status',{'render_html'=>true})
  check('status counts and integrity derive from owned providers') { st.dig('knowledge','count')==1 && st.dig('observations','count')==1 && st.dig('integrity','state')=='readable' && st.dig('integrity','valid')==true && st.dig('integrity','host_l0','state')=='unchanged' }
  html=File.read(st.fetch('html_path'),encoding:'UTF-8')
  check('HTML contains escaped hostile JSON and no executable user string') { html.include?('\\u003cscript\\u003e') && !html.include?(hostile) && !html.include?('__KAIROMONE_STATUS_JSON__') }
  scripts=html.scan(/<script(?:\s[^>]*)?>(.*?)<\/script>/m).flatten
  check('rendered HTML retains exactly JSON script and static script') { scripts.length==2 }
  backup=invoke(reg,'kairomone_backup',{'command'=>'create'})
  check('owned backup creates and verifies') { backup['success'] && backup['verified'] }
  file=backup.fetch('file')
  archive=JSON.parse(File.read(backup.fetch('path')))
  check('backup only includes profile, canonical records, owned ledger') { archive['files'].map{|x|x['path']}.sort==["profile/#{st.dig('profile','sha256')}.json",'storage/blockchain.json',"context/kairomone/#{obs['id']}/#{obs['id']}.md",'knowledge/review_knowledge/review_knowledge.md'].sort }
  check('backup is signed with the host archive key, which it never carries') { archive.dig('signature','algorithm')=='HMAC-SHA256' && File.file?(File.join(host,'kairomone-keys','archive.key')) && !File.read(backup.fetch('path')).include?(Base64.strict_encode64(File.binread(File.join(host,'kairomone-keys','archive.key')))) }
  check('backup verification succeeds through registered tool') { invoke(reg,'kairomone_backup',{'command'=>'verify','file'=>file})['verified'] }
  active=tree(own)
  restore=invoke(reg,'kairomone_backup',{'command'=>'restore','file'=>file,'target_id'=>'recovery'})
  check('restore publishes a separate listed twin') { restore['success'] && restore.dig('kairomone','listing_id')=='recovery' && restore.dig('kairomone','identity')=='review_dot' }
  check('restore leaves the source individual byte-identical') { active==tree(own) }
  restored=tree(restore.fetch('path'))
  check('restored canonical status validates via real tool') { invoke(reg,'kairomone_status',{'kairomone'=>'recovery'}).dig('integrity','valid')==true }
  check('with two individuals a write without a name is refused and a read lists them') { invoke(reg,'kairomone_observe',{'title'=>'x','content'=>'y'})['success']==false && invoke(reg,'kairomone_status',{})['kairomones'].map{|k|k['listing_id']}==%w[recovery review_dot] }
  repeat=invoke(reg,'kairomone_backup',{'command'=>'restore','kairomone'=>'review_dot','file'=>file,'target_id'=>'recovery'})
  check('restore never overwrites existing target') { repeat['success']==false && tree(restore['path'])==restored }
  check('traversal restore target refused') { invoke(reg,'kairomone_backup',{'command'=>'restore','kairomone'=>'review_dot','file'=>file,'target_id'=>'../escape'})['success']==false }
  check('traversal backup filename refused') { invoke(reg,'kairomone_backup',{'command'=>'verify','kairomone'=>'review_dot','file'=>'../'+file})['success']==false }
  tampered=Marshal.load(Marshal.dump(archive)); tampered['files'].first['content_base64']=Base64.strict_encode64('tamper')
  File.write(File.join(own,'backups','tampered.kairomone.json'),JSON.generate(tampered))
  check('tampered backup rejected before restore publication') { invoke(reg,'kairomone_backup',{'command'=>'restore','kairomone'=>'review_dot','file'=>'tampered.kairomone.json','target_id'=>'bad_restore'})['success']==false && !File.exist?(File.join(host,'kairomones','bad_restore')) }
  traversed=Marshal.load(Marshal.dump(archive)); traversed['files'].first['path']='../escape'
  traversed['manifest_sha256']=Digest::SHA256.hexdigest(JSON.generate(traversed['files'].map{|e|e.slice('path','size','sha256')}))
  File.write(File.join(own,'backups','traversal.kairomone.json'),JSON.generate(traversed))
  check('checksum-recomputed archive traversal rejected') { invoke(reg,'kairomone_backup',{'command'=>'restore','kairomone'=>'review_dot','file'=>'traversal.kairomone.json','target_id'=>'bad_path'})['success']==false && !File.exist?(File.join(host,'kairomones','bad_path')) }
  source_ledger=File.join(own,'storage','blockchain.json'); ledger=File.binread(source_ledger)
  File.write(source_ledger,'corrupt')
  check('corrupt owned ledger reported invalid') { corrupt=invoke(reg,'kairomone_status',{'kairomone'=>'review_dot'}); corrupt.dig('integrity','valid')==false && corrupt.dig('integrity','state')!='readable' }
  check('L1 fails closed on corrupt ledger without content write') { invoke(reg,'kairomone_knowledge',create_args.merge('id'=>'blocked','kairomone'=>'review_dot'))['success']==false && !File.exist?(File.join(own,'knowledge','blocked')) && File.read(source_ledger)=='corrupt' }
  File.binwrite(source_ledger,ledger)
  user_reg=KairosMcp::ToolRegistry.new(user_context:{user:'test',role:'owner'})
  check('authenticated multiuser invocation refused clearly') { r=invoke(user_reg,'kairomone_status'); r['success']==false && r['error'].include?('multiuser') }
  cli=File.join(plugin,'scripts','kairomone.rb')
  out,err,process=Open3.capture3({'KAIROS_DATA_DIR'=>host},RbConfig.ruby,'-I',File.join(CORE,'lib'),cli,'status','--kairomone','review_dot')
  check('installed-package CLI uses unchanged public core load path') { process.success? && JSON.parse(out).dig('integrity','valid')==true }
  check('host bytes remain identical after backup/restore/CLI') { tree(host,exclude:outside)==base }


  # Recover the portable archive into an entirely fresh active instance, then
  # prove that the recovery can accept new canonical records through the CLI.
  original_host = tree(host)
  new_host = File.join(tmp, 'fresh-host')
  install_package(new_host)
  new_cli = File.join(new_host, 'skillsets/kairomone/scripts/kairomone.rb')
  inbox = File.join(new_host, 'kairomone-inbox')
  FileUtils.mkdir_p(inbox)
  FileUtils.cp_r(File.join(host, 'kairomone-keys'), new_host) # the owner copies the archive key
  recovered_root = File.join(new_host, 'kairomones', 'review_dot')
  FileUtils.cp(backup['path'], File.join(inbox, file))
  inbox_hash = Digest::SHA256.file(File.join(inbox, file)).hexdigest
  new_host_base = tree(new_host)
  run_recovered = lambda do |*arguments|
    if arguments.first(2) == %w[backup restore-new]
      # A restore needs a controlling terminal, so it runs under a pty.
      require 'pty'
      stdout = +''
      PTY.spawn({ 'KAIROS_DATA_DIR' => new_host }, RbConfig.ruby, '-I', File.join(CORE, 'lib'), new_cli, *arguments) do |reader, _writer, pid|
        begin
          stdout << reader.read
        rescue Errno::EIO
          nil
        end
        _, outcome = Process.wait2(pid)
        return [JSON.parse(stdout), outcome, '']
      end
    end
    stdout, stderr, outcome = Open3.capture3(
      { 'KAIROS_DATA_DIR' => new_host }, RbConfig.ruby, '-I', File.join(CORE, 'lib'), new_cli, *arguments
    )
    [JSON.parse(stdout), outcome, stderr]
  end
  wrong, outcome, = run_recovered.call('backup', 'restore-new', '--file', file, '--dot-id', 'wrong_dot')
  check('fresh-host recovery checks the expected dot identity before activation') do
    !outcome.success? && wrong['success'] == false && !File.exist?(recovered_root)
  end
  bad, outcome, = run_recovered.call('backup', 'restore-new', '--file', '../' + file, '--dot-id', 'review_dot')
  check('fresh-host recovery refuses source traversal') do
    !outcome.success? && bad['success'] == false && !File.exist?(recovered_root)
  end
  portable, outcome, errors = run_recovered.call('backup', 'restore-new', '--file', file, '--dot-id', 'review_dot')
  check("fresh-host CLI restores a verified active instance: #{errors}") { outcome.success? && portable['success'] && portable['active'] && portable['trust'] == 'signed' }
  check('fresh-host recovery byte-preserves every archived canonical file and archived block') do
    archive['files'].all? do |entry|
      stored = Base64.strict_decode64(entry['content_base64'])
      now = File.binread(File.join(recovered_root, entry['path']))
      entry['path'] == 'storage/blockchain.json' ? JSON.parse(now).first(JSON.parse(stored).length) == JSON.parse(stored) : now == stored
    end
  end
  new_entry, outcome, = run_recovered.call('knowledge', 'create', '--id', 'after_recovery', '--title', 'Recovered', '--content', 'New canonical knowledge')
  check('recovered active instance accepts a newly recorded L1 entry') { outcome.success? && new_entry['success'] && new_entry['recorded_on_chain'] }
  new_observation, outcome, = run_recovered.call('observe', '--title', 'Recovered', '--content', 'New L2 context')
  check('recovered active instance accepts new L2 context') { outcome.success? && new_observation['success'] }
  recovered_status, outcome, = run_recovered.call('status')
  check('recovered active instance has complete old-plus-new records and valid chain') do
    outcome.success? && recovered_status.dig('knowledge', 'count') == 2 &&
      recovered_status.dig('observations', 'count') == 2 && recovered_status.dig('integrity', 'valid')
  end
  active_recovered = tree(recovered_root)
  denied, outcome, = run_recovered.call('backup', 'restore-new', '--file', file, '--dot-id', 'review_dot')
  check('fresh-host restore refuses to overwrite a now-existing active instance') do
    !outcome.success? && denied['success'] == false && active_recovered == tree(recovered_root)
  end
  check('recovery preserves its source archive and every original-host byte') do
    inbox_hash == Digest::SHA256.file(File.join(inbox, file)).hexdigest && original_host == tree(host)
  end
  check('recovery adds no host core or L0 configuration') do
    new_host_base == tree(new_host, exclude: %w[kairomone kairomones kairomone-restored .kairomone-restore.lock])
  end
  KairosMcp.data_dir = host

  %w[storage/blockchain.json storage/blockchain.json.lock storage/action_log.jsonl .lock].each do |rel|
    fresh do |i,host,tmp|
      outside=File.join(tmp,'outside'); File.write(outside,'do not change')
      target=File.join(i.root,rel); File.unlink(target) if File.exist?(target); File.link(outside,target)
      check("hardlinked #{rel} refused") { refused { i.create_knowledge(id:'blocked',title:'blocked',content:'blocked') } }
      check("hardlinked #{rel} preserves external bytes") { File.read(outside)=='do not change' && !File.exist?(File.join(i.root,'knowledge','blocked')) }
    end
  end
  %w[storage/blockchain.json storage/blockchain.json.lock .lock].each do |rel|
    fresh do |i,host,tmp|
      target=File.join(i.root,rel); File.unlink(target) if File.exist?(target); File.mkfifo(target)
      check("FIFO #{rel} refused without blocking") { Timeout.timeout(2) { refused { i.create_knowledge(id:'blocked',title:'blocked',content:'blocked') } } }
    end
  end
  fresh do |i,host,tmp|
    outside=File.join(tmp,'outside'); FileUtils.mkdir_p(outside)
    File.symlink(outside,File.join(i.root,'knowledge','evil'))
    check('symlinked knowledge directory fails before external write') { refused { i.create_knowledge(id:'evil',title:'evil',content:'evil') } && Dir.empty?(outside) }
  end
  fresh do |i,host,tmp|
    result=i.create_knowledge(id:'present',title:'Present',content:'Present')
    check('setup canonical L1') { result[:success] }
    FileUtils.remove_entry(File.join(i.root,'knowledge','present'))
    s=i.status
    check('deleted knowledge with retained ledger is invalid and pending') { s.dig(:integrity,:valid)==false && s.dig(:integrity,:pending_count)>0 }
    check('backup refuses orphaned ledger') { refused { i.create_backup } }
  end
  fresh do |i,host,tmp|
    results=12.times.map do |n|
      Thread.new { Kairomone::Instance.new(host_root:host).create_knowledge(id:"entry_#{n}",title:"Entry #{n}",content:"Content #{n}") }
    end.map(&:value)
    s=i.status
    # genesis, the entry records, then an identity record and an update block per creation
    check('concurrent independent instances serialize 12 L1 creations') { results.all?{|r|r[:success]} && s.dig(:knowledge,:count)==12 && s.dig(:integrity,:block_count)==26 && s.dig(:integrity,:valid) && s.dig(:integrity,:pending_count)==0 }
  end

end


KairosMcp.reset_data_dir!
puts "REGISTERED INTEGRATION: #{$passes} checks passed."
