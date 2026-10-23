#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
# A checkout can locate its sibling core; an installed SkillSet uses the
# installed kairos-chain gem or an explicitly provided Ruby load path (-I).
source_core = File.expand_path('../../../../lib', __dir__)
$LOAD_PATH.unshift(source_core) if File.file?(File.join(source_core, 'kairos_mcp.rb'))
begin
  require_relative '../lib/kairomone'
rescue LoadError => e
  warn "KairosChain core is unavailable: #{e.message}. Install kairos-chain >= 3.92.0, or pass -I /path/to/KairosChain_mcp_server/lib."
  exit 1
end

options = {}
parser = OptionParser.new do |p|
  p.banner = 'Usage: kairomone.rb list|init|status|observe|growth status|run-start|run-stop|run-status|request|claim|heartbeat|commit|fail|' \
             'profession list|select|knowledge create|get|list|backup create|verify|restore|restore-new|missing|l0 rebaseline [options]'
  p.on('--kairomone ID', 'Listing ID of the Kairomone (needed for writes when the host lists several)') { |v| options[:kairomone] = v }
  p.on('--json-stdin', 'Read companion arguments as bounded JSON, never shell text') { options[:json_stdin] = true }
  p.on('--dot-id ID') { |v| options[:dot_id] = v }
  p.on('--name NAME') { |v| options[:display_name] = v }
  p.on('--title TITLE') { |v| options[:title] = v }
  p.on('--content TEXT') { |v| options[:content] = v }
  p.on('--id ID') { |v| options[:id] = v }
  p.on('--file BASENAME') { |v| options[:file] = v }
  p.on('--target-id ID', 'restore: listing ID for the restored Kairomone') { |v| options[:target_id] = v }
  p.on('--instance ID', 'status: a listed Kairomone, or a 0.6 read-only recovery copy') { |v| options[:instance] = v }
  p.on('--owner-words TEXT') { |v| options[:owner_words] = v }
  p.on('--cycles N', Integer) { |v| options[:cycles] = v }
  p.on('--end-at TIME') { |v| options[:end_at] = v }
  p.on('--run-id ID') { |v| options[:run_id] = v }
  p.on('--token TOKEN') { |v| options[:token] = v }
  p.on('--request-id ID') { |v| options[:request_id] = v }
  p.on('--topic TEXT') { |v| options[:topic] = v }
  p.on('--profession-id ID') { |v| options[:profession_id] = v }
  p.on('--bias-applied') { options[:bias_applied] = true }
  p.on('--worker-id ID') { |v| options[:worker_id] = v }
  p.on('--lease-seconds N', Integer) { |v| options[:lease_seconds] = v }
  p.on('--claim-token TOKEN') { |v| options[:claim_token] = v }
  p.on('--reason TEXT') { |v| options[:reason] = v }
  p.on('--kind KIND', 'missing: profile, professions or art') { |v| options[:kind] = v }
  p.on('--sha256 HEX', 'missing: the lost piece') { |v| options[:sha256] = v }
  p.on('--evidence-json JSON') { |v| options[:evidence] = JSON.parse(v) }
  p.on('--html', 'Generate fixed offline status.html snapshot') { options[:render_html] = true }
  p.on('-h', '--help') { puts p; exit }
end

# A terminal is the path for an owner's ruling: the console's child has no
# controlling terminal; a shell command that opens a pseudo-terminal can give
# it one, which the standing rule forbids. This is a path, not proof of a person.
def terminal!(what)
  File.open('/dev/tty', 'r+')
rescue SystemCallError => e
  raise Kairomone::Error, "#{what} needs a terminal (/dev/tty: #{e.class}). Run it yourself in a terminal, in the project folder."
end

begin
  # Shell arguments are UTF-8 for this CLI even under cron/launchd's C locale,
  # where Ruby otherwise labels their bytes ASCII-8BIT. Reject invalid bytes.
  ARGV.map! do |argument|
    text = argument.dup.force_encoding(Encoding::UTF_8)
    raise Kairomone::Error, 'CLI arguments must be valid UTF-8' unless text.valid_encoding?
    text
  end
  command = ARGV.shift
  subcommand = ARGV.shift if %w[knowledge backup profession growth companion l0].include?(command)
  parser.parse!(ARGV)
  raise Kairomone::Error, "Unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?
  raise Kairomone::Error, '--instance is available only for read-only status' if options[:instance] && command != 'status'

  host = Kairomone::Host.new
  # The Kairomone this command is about (design v0.6 M2): named, or the only one.
  store = lambda do
    if command == 'status' && options[:instance]
      next Kairomone::Instance.new(kairomone: options[:instance]) if host.listed?(options[:instance])
      next Kairomone::Instance.new(restored_id: options[:instance])
    end
    Kairomone::Instance.new(kairomone: options[:kairomone])
  end
  if command == 'companion'
    raise Kairomone::Error, 'Companion commands accept only --json-stdin and --kairomone' unless (options.keys - %i[json_stdin kairomone]).empty?
    payload = options[:json_stdin] ? $stdin.read(32_769) : '{}'
    raise Kairomone::Error, 'Companion input exceeds 32 KiB' if payload.bytesize > 32_768
    begin
      input = JSON.parse(payload)
    rescue JSON::ParserError
      raise Kairomone::Error, 'Invalid companion JSON'
    end
    raise Kairomone::Error, 'Companion input must be an object' unless input.is_a?(Hash)
    methods = { 'status' => :companion_status, 'history' => :companion_history, 'configure' => :configure_companion, 'context' => :companion_context, 'remember' => :remember_companion, 'recover' => :recover_companion_memory, 'revoke' => :revoke_companion_memory }
    method = methods[subcommand]
    raise Kairomone::Error, 'Expected companion status, history, configure, context, remember, recover or revoke' unless method
    target = store.call
    allowed = target.method(method).parameters.map { |_kind, key| key.to_s }
    raise Kairomone::Error, 'Unexpected companion input fields' unless (input.keys - allowed).empty?
    result = target.public_send(method, **input.transform_keys(&:to_sym))
    puts JSON.pretty_generate(result)
    exit
  end
  raise Kairomone::Error, '--json-stdin is companion-only' if options[:json_stdin]
  growth = -> { store.call.autonomy }
  reads = [['status', nil], ['knowledge', 'get'], ['knowledge', 'list'], ['profession', 'list'], ['growth', 'status'], ['backup', 'verify']]
  result = begin
    case [command, subcommand]
           when ['list', nil] then { success: true, kairomones: host.summaries }
           when ['init', nil] then Kairomone::Instance.new(bind: false).init(dot_id: options[:dot_id], display_name: options[:display_name])
           when ['status', nil] then store.call.status(render_html: options[:render_html] == true)
           when ['observe', nil] then store.call.observe(title: options[:title], content: options[:content])
           when ['knowledge', 'create'] then store.call.create_knowledge(id: options[:id], title: options[:title], content: options[:content])
           when ['knowledge', 'get'] then store.call.read_knowledge(id: options[:id])
           when ['knowledge', 'list'] then store.call.list_knowledge
           when ['profession', 'list'] then { success: true, profession: store.call.profession_status }
           when ['profession', 'select'] then store.call.select_profession(id: options[:id])
           when ['growth', 'status'] then growth.call.status
           when ['growth', 'run-start'] then growth.call.run_start(owner_words: options[:owner_words], cycles: options[:cycles], end_at: options[:end_at])
           when ['growth', 'run-stop'] then growth.call.run_stop(reason: options.fetch(:reason, 'Owner stop'))
           when ['growth', 'run-status'] then growth.call.run_status(run_id: options[:run_id])
           when ['growth', 'request'] then growth.call.request(run_id: options[:run_id], token: options[:token], request_id: options[:request_id], topic: options[:topic], profession_id: options[:profession_id], bias_applied: options.fetch(:bias_applied, false))
           when ['growth', 'claim'] then growth.call.claim(run_id: options[:run_id], token: options[:token], worker_id: options[:worker_id], lease_seconds: options.fetch(:lease_seconds, 300))
           when ['growth', 'heartbeat'] then growth.call.heartbeat(run_id: options[:run_id], token: options[:token], claim_token: options[:claim_token])
           when ['growth', 'commit'] then growth.call.commit(run_id: options[:run_id], token: options[:token], claim_token: options[:claim_token], evidence: options[:evidence])
           when ['growth', 'fail'] then growth.call.fail(run_id: options[:run_id], token: options[:token], claim_token: options[:claim_token], reason: options[:reason])
           when ['growth', 'configure'], ['growth', 'stop']
             raise Kairomone::Error, "growth #{subcommand} belonged to the 0.6 lifetime budget, which 0.8 removed; use growth run-start / run-stop"
           when ['backup', 'create'] then store.call.create_backup
           when ['backup', 'verify'] then store.call.verify_backup(file: options[:file])
           when ['backup', 'restore'], ['backup', 'restore-new']
             # A restore is done at a terminal. An archive this host signed
             # restores as stored; any other is shown first and restores only
             # when the owner types the confirmation shown.
             tty = terminal!("backup #{subcommand}")
             begin
               file = options[:file]
               raise Kairomone::Error, 'Backup filename must be a basename ending in .kairomone.json' unless file.is_a?(String) && Kairomone::Paths::BACKUP_NAME.match?(file)
               # restore: a file in the named Kairomone's backups/; restore-new: a
               # file in the host kairomone-inbox/, checked against --dot-id.
               bytes = if subcommand == 'restore'
                         Kairomone::Paths.read(store.call.root, "backups/#{file}", limit: Kairomone::Instance::ARCHIVE_LIMIT)
                       else
                         Kairomone::Paths.read(host.host_root, "kairomone-inbox/#{file}", limit: Kairomone::Instance::ARCHIVE_LIMIT)
                       end
               confirm = lambda do |lines|
                 nonce = Kairomone::Instance.rebaseline_nonce
                 lines.each { |line| tty.puts line }
                 tty.print "Type #{nonce} to restore this archive as a new Kairomone (anything else cancels): "
                 tty.flush
                 tty.gets.to_s.strip == nonce
               end
               expected = subcommand == 'restore-new' ? options[:dot_id] : nil
               raise Kairomone::Error, 'restore-new needs --dot-id' if subcommand == 'restore-new' && expected.nil?
               host.restore(bytes, trust: confirm, listing_id: options[:target_id], expected_identity: expected)
             ensure
               tty.close
             end
           when ['backup', 'missing']
             tty = terminal!('backup missing')
             begin
               store.call.record_missing_interactive(pieces: [{ kind: options[:kind], sha256: options[:sha256] }],
                                                     reason: options.fetch(:reason, 'No reason given at the terminal'), tty_in: tty, tty_out: tty)
             ensure
               tty.close
             end
           when ['l0', 'rebaseline']
             # The ruling reads its nonce back at the terminal and refuses without
             # one, so no MCP call reaches it. This is a path, not proof of a person.
             tty = terminal!('l0 rebaseline')
             begin
               store.call.rebaseline_l0_interactive(tty_in: tty, tty_out: tty, reason: options.fetch(:reason, Kairomone::Instance::DEFAULT_REBASELINE_REASON))
             ensure
               tty.close
             end
           else raise Kairomone::Error, parser.to_s
           end
  rescue Kairomone::AmbiguousError
    raise unless reads.include?([command, subcommand])

    { success: true, several: true, kairomones: host.summaries, note: 'Several Kairomones live here; name one with --kairomone ID' }
  end
  puts JSON.pretty_generate(result)
  exit 1 if result[:success] == false || result[:error]
rescue StandardError => e
  puts JSON.pretty_generate(success: false, error: e.message)
  exit 1
end
