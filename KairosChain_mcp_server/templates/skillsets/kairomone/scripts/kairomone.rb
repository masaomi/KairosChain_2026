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
  p.banner = 'Usage: kairomone.rb init|status|observe|growth status|configure|request|claim|heartbeat|commit|fail|stop|profession list|select|knowledge create|get|list|backup create|verify|restore|restore-new|l0 rebaseline [options]'
  p.on('--json-stdin', 'Read companion arguments as bounded JSON, never shell text') { options[:json_stdin] = true }
  p.on('--dot-id ID') { |v| options[:dot_id] = v }
  p.on('--name NAME') { |v| options[:display_name] = v }
  p.on('--title TITLE') { |v| options[:title] = v }
  p.on('--content TEXT') { |v| options[:content] = v }
  p.on('--id ID') { |v| options[:id] = v }
  p.on('--file BASENAME') { |v| options[:file] = v }
  p.on('--target-id ID') { |v| options[:target_id] = v }
  p.on('--instance ID', 'Read-only status for a restored target') { |v| options[:restored_id] = v }
  p.on('--request-id ID') { |v| options[:request_id] = v }
  p.on('--topic TEXT') { |v| options[:topic] = v }
  p.on('--max-cycles N', Integer) { |v| options[:max_cycles] = v }
  p.on('--already-used N', Integer) { |v| options[:already_used] = v }
  p.on('--resume') { options[:resume] = true }
  p.on('--profession-id ID') { |v| options[:profession_id] = v }
  p.on('--bias-applied') { options[:bias_applied] = true }
  p.on('--worker-id ID') { |v| options[:worker_id] = v }
  p.on('--lease-seconds N', Integer) { |v| options[:lease_seconds] = v }
  p.on('--claim-token TOKEN') { |v| options[:claim_token] = v }
  p.on('--reason TEXT') { |v| options[:reason] = v }
  p.on('--evidence-json JSON') { |v| options[:evidence] = JSON.parse(v) }
  p.on('--html', 'Generate fixed offline status.html snapshot') { options[:render_html] = true }
  p.on('-h', '--help') { puts p; exit }
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
  if options[:restored_id] && command != 'status'
    raise Kairomone::Error, '--instance is available only for read-only status'
  end
  store = Kairomone::Instance.new(restored_id: options[:restored_id])
  if command == 'companion'
    raise Kairomone::Error, 'Companion commands accept only --json-stdin' unless (options.keys - [:json_stdin]).empty?
    payload = options[:json_stdin] ? $stdin.read(32_769) : '{}'
    raise Kairomone::Error, 'Companion input exceeds 32 KiB' if payload.bytesize > 32_768
    begin
      input = JSON.parse(payload)
    rescue JSON::ParserError
      raise Kairomone::Error, 'Invalid companion JSON'
    end
    raise Kairomone::Error, 'Companion input must be an object' unless input.is_a?(Hash)
    methods = { 'status' => :companion_status, 'configure' => :configure_companion, 'context' => :companion_context, 'remember' => :remember_companion, 'recover' => :recover_companion_memory, 'revoke' => :revoke_companion_memory }
    method = methods[subcommand]
    raise Kairomone::Error, 'Expected companion status, configure, context, remember, recover or revoke' unless method
    allowed = store.method(method).parameters.map { |_kind, key| key.to_s }
    raise Kairomone::Error, 'Unexpected companion input fields' unless (input.keys - allowed).empty?
    result = store.public_send(method, **input.transform_keys(&:to_sym))
    puts JSON.pretty_generate(result)
    exit
  end
  raise Kairomone::Error, '--json-stdin is companion-only' if options[:json_stdin]
  result = case [command, subcommand]
           when ['init', nil] then store.init(dot_id: options[:dot_id], display_name: options[:display_name])
           when ['status', nil] then store.status(render_html: options[:render_html] == true)
           when ['observe', nil] then store.observe(title: options[:title], content: options[:content])
           when ['knowledge', 'create'] then store.create_knowledge(id: options[:id], title: options[:title], content: options[:content])
           when ['knowledge', 'get'] then store.read_knowledge(id: options[:id])
           when ['knowledge', 'list'] then store.list_knowledge
           when ['profession', 'list'] then { success: true, profession: store.profession_status }
           when ['profession', 'select'] then store.select_profession(id: options[:id])
           when ['growth', 'status'] then store.autonomy.status
           when ['growth', 'configure'] then store.autonomy.configure(max_cycles: options.fetch(:max_cycles, 10), already_used: options.fetch(:already_used, 0))
           when ['growth', 'request'] then store.autonomy.request(request_id: options[:request_id], topic: options[:topic], max_cycles: options.fetch(:max_cycles, 10), already_used: options.fetch(:already_used, 0), resume: options.fetch(:resume, false), profession_id: options.fetch(:profession_id, 'generalist'), bias_applied: options.fetch(:bias_applied, false))
           when ['growth', 'claim'] then store.autonomy.claim(worker_id: options[:worker_id], lease_seconds: options.fetch(:lease_seconds, 300))
           when ['growth', 'heartbeat'] then store.autonomy.heartbeat(claim_token: options[:claim_token])
           when ['growth', 'commit'] then store.autonomy.commit(claim_token: options[:claim_token], evidence: options[:evidence])
           when ['growth', 'fail'] then store.autonomy.fail(claim_token: options[:claim_token], reason: options[:reason])
           when ['growth', 'stop'] then store.autonomy.stop(reason: options.fetch(:reason, 'Explicit stop'))
           when ['backup', 'create'] then store.create_backup
           when ['backup', 'verify'] then store.verify_backup(file: options[:file])
           when ['backup', 'restore'], ['backup', 'restore-new']
             # A restore is done at a terminal, like the L0 ruling: the console's
             # child has no controlling terminal; a shell command that opens a
             # pseudo-terminal can give it one, which the standing rule forbids.
             begin
               File.open('/dev/tty', 'r+').close
             rescue SystemCallError => e
               raise Kairomone::Error, "backup #{subcommand} needs a terminal (/dev/tty: #{e.class}). Run it yourself in a terminal, in the project folder."
             end
             if subcommand == 'restore'
               store.restore_backup(file: options[:file], target_id: options[:target_id])
             else
               store.restore_new(file: options[:file], dot_id: options[:dot_id])
             end
           when ['l0', 'rebaseline']
             # The ruling reads its nonce back at the terminal and refuses without
             # one, so no MCP call reaches it. This is a path, not proof of a person.
             tty = begin
               File.open('/dev/tty', 'r+')
             rescue SystemCallError => e
               raise Kairomone::Error, "l0 rebaseline needs a terminal (/dev/tty: #{e.class}). Run it yourself in a terminal, in the project folder."
             end
             begin
               store.rebaseline_l0_interactive(tty_in: tty, tty_out: tty, reason: options.fetch(:reason, Kairomone::Instance::DEFAULT_REBASELINE_REASON))
             ensure
               tty.close
             end
           else raise Kairomone::Error, parser.to_s
           end
  puts JSON.pretty_generate(result)
  exit 1 if result[:success] == false || result[:error]
rescue StandardError => e
  puts JSON.pretty_generate(success: false, error: e.message)
  exit 1
end
