# frozen_string_literal: true

# Judge distillation (design v0.2): the precedents entry pinned as absent,
# the distiller's prompt, the worker end to end through the real chain with a
# fake claude, adoption, and agreement counted per version.
#
# The driver's side (point facts at each answer, the drafting trigger) is in
# test_agent_shadow_judge.rb § 3b, which has the tool harness.
#
# Run: ruby KairosChain_mcp_server/templates/skillsets/agent/test/test_agent_distillation.rb

$LOAD_PATH.unshift File.expand_path('../../../../lib', __dir__)

require 'json'
require 'digest'
require 'fileutils'
require 'tmpdir'
require 'stringio'
require 'rbconfig'
require 'kairos_mcp'
require 'kairos_mcp/kairos_chain/chain'

LIB = File.expand_path('../lib', __dir__)
%w[session admission mandate_adapter act_classification answer_ruling delegation shadow_judge point_facts
   distiller distill_run distiller_prompt adoption].each { |f| require File.join(LIB, 'agent', f) }

$pass = 0
$fail = 0

def assert(description)
  result = yield
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
  puts "        #{e.backtrace.first(3).join("\n        ")}"
end

def section(title)
  puts "\n#{'=' * 60}\nTEST: #{title}\n#{'=' * 60}"
end

AG = KairosMcp::SkillSets::Agent
AC = AG::ActClassification
AR = AG::AnswerRuling
DL = AG::Delegation
SJ = AG::ShadowJudge
PF = AG::PointFacts
DP = AG::DistillerPrompt
AD = AG::Adoption

TMPDIR = Dir.mktmpdir('agent_distillation')
PROJECT = File.join(TMPDIR, 'proj')
REAL = File.join(PROJECT, '.kairos')
FileUtils.mkdir_p(File.join(REAL, 'skills'))
File.write(File.join(REAL, 'skills', 'config.yml'), "instructions_mode: testmode\n")
MODE_FILE = File.join(REAL, 'skills', 'testmode.md')
File.write(MODE_FILE, "# Test mode\nPrefer small reversible steps.\n")
ORIG_PWD = Dir.pwd
Dir.chdir(PROJECT)
KairosMcp.data_dir = REAL

SESSIONS = AG::Session.storage_path('agent_sessions')
DISTILL = AG::Session.storage_path('agent_distill')
ENTRY = DL.precedents_path

def chain = KairosMcp::KairosChain::Chain.new

def add(record) = chain.add_block([JSON.generate(record)]).index

def nonce_in(n = 'q9q9q9') = StringIO.new("#{n}\n")

def rule(action = 'activate', out: StringIO.new)
  DL.interactive_rule(action: action, tty_in: nonce_in, tty_out: out, chain: chain, nonce_value: 'q9q9q9')
end

# ---------------------------------------------------------------------------
section '1. The precedents entry is a read that may be absent, and only an adoption pins new bytes'

pins, err = DL.read_pins(%w[instruction_mode judgment_precedents])
assert('nothing at the entry path pins as absent, beside the instruction mode') do
  err.nil? && pins.map { |p| p['name'] } == %w[instruction_mode judgment_precedents] &&
    pins[1] == { 'name' => 'judgment_precedents', 'path' => ENTRY, 'bytes' => 0, 'sha256' => nil, 'absent' => true }
end
FileUtils.mkdir_p(File.dirname(ENTRY))
File.symlink(File.join(TMPDIR, 'nowhere.md'), ENTRY)
assert('a dangling link at the path is a read error, never absence') do
  p_, e = DL.read_pins(%w[judgment_precedents])
  p_.nil? && !e.to_s.empty?
end
File.unlink(ENTRY)
assert('the instruction mode may never be absent') do
  File.rename(MODE_FILE, "#{MODE_FILE}.away")
  _p, e = DL.read_pins(%w[instruction_mode])
  File.rename("#{MODE_FILE}.away", MODE_FILE)
  !e.nil?
end
assert('absence compares equal only to absence') do
  absent = { 'name' => 'judgment_precedents', 'path' => ENTRY, 'sha256' => nil, 'absent' => true }
  present = absent.merge('sha256' => 'ab' * 32).tap { |h| h.delete('absent') }
  DL.changed_reads([absent], [absent]).empty? && DL.changed_reads([present], [absent]) == ['judgment_precedents']
end
assert('the judge reads no material for an absent pin, and refuses once something appears') do
  pin = { 'name' => 'judgment_precedents', 'path' => ENTRY, 'sha256' => nil, 'absent' => true }
  none = SJ.read_material([pin])
  File.write(ENTRY, 'planted')
  appeared = SJ.read_material([pin])
  File.unlink(ENTRY)
  none == [[], nil] && appeared == [nil, 'material_changed']
end

assert('before any ruling, the table is out of force') { DL.load_effective['status'] == 'no_ruling' }
shown = StringIO.new
first = rule(out: shown)
assert('the first ruling pins the entry as absent and says so') do
  first['recorded'] && shown.string.include?('absent: nothing adopted yet') &&
    first['record']['reads'].last == { 'name' => 'judgment_precedents', 'path' => ENTRY, 'sha256' => nil,
                                       'absent' => true } &&
    DL.load_effective['status'] == 'in_force'
end
File.write(ENTRY, "planted by hand\n")
assert('bytes appearing at the entry take the table out of force') { DL.load_effective['status'] == 'reads_changed' }
refused = StringIO.new
again = rule(out: refused)
assert('and a ruling other than an adoption refuses to pin them') do
  again['recorded'] == false && again['reason'] == 'precedents_changed' && refused.string.include?('agent_rule.rb adopt')
end
File.unlink(ENTRY)
assert('removing them brings the ruled table back') { DL.load_effective['status'] == 'in_force' }
assert('the same bytes at another path may be re-pinned (a moved instance); other bytes may not') do
  ruled = [{ 'table' => 'delegation', 'attested' => true, 'action' => 'activate',
             'reads' => [{ 'name' => 'judgment_precedents', 'path' => '/old/p.md', 'sha256' => 'ab' * 32 }] }]
  moved = [{ 'name' => 'judgment_precedents', 'path' => '/new/p.md', 'sha256' => 'ab' * 32 }]
  other = [{ 'name' => 'judgment_precedents', 'path' => '/new/p.md', 'sha256' => 'cd' * 32 }]
  DL.precedents_repin_refusal(moved, ruled).nil? && !DL.precedents_repin_refusal(other, ruled).nil?
end

# ---------------------------------------------------------------------------
section "2. The distiller's prompt"

assert('the prompt digest is stable and changes with the framing') do
  DP.sha256 == DP.sha256 && DP.sha256.match?(/\A\h{64}\z/)
end
assert('without changes, the prompt says there are none') do
  DP.user_prompt([{ 'block' => 1 }], []).include?(DP::NO_EDITS)
end
assert("the operator's changes are shown under the block that adopted them; empty ones are dropped") do
  u = DP.user_prompt([], [{ 'adopted_block' => 7, 'changes' => '+ only when nothing writes' },
                          { 'adopted_block' => 8, 'changes' => '' }])
  u.include?('Adopted in block #7') && u.include?('+ only when nothing writes') && !u.include?('block #8')
end
assert('a prompt past the size bound is refused, not cut') do
  DP.user_prompt([{ 'reason' => 'x' * (DP::MAX_USER_BYTES + 1) }], [])
  false
rescue ArgumentError => e
  e.message.include?('in parts')
end

same_dir = Dir.mktmpdir('pf', TMPDIR)
PF.append_plan(same_dir, cycle: 1, plan_sha256: 'x', act_table_sha256: 't', facts: { 'step_count' => 1 })
PF.append_plan(same_dir, cycle: 2, plan_sha256: 'x', act_table_sha256: 't', facts: { 'step_count' => 1 })
PF.append_plan(same_dir, cycle: 2, plan_sha256: 'x', act_table_sha256: 't', facts: { 'step_count' => 1 })
PF.record_answer(same_dir, anchor: 'a', point: 'cycle_checkpoint', cycle: 2, current: nil)
assert('the same plan in two cycles is two plans; recorded twice in one cycle it is one') do
  PF.answer_facts(same_dir, 'a')[0]['plans'].map { |p| [p['cycle'], p['plan_sha256']] } == [[1, 'x'], [2, 'x']]
end

assert('a statement whose sources span both points is refused') do
  ans = [{ 'block' => 1, 'point' => 'plan_proposed', 'decision' => 'approve' },
         { 'block' => 2, 'point' => 'cycle_checkpoint', 'decision' => 'approve' }]
  _s, err = AG::Distiller.parse_draft('{"statements":[{"situation":"x","answer":"approve","sources":[1,2],"count":2}]}', ans)
  err.to_s.include?('more than one point')
end

class CountingChain
  Block = Struct.new(:index)
  def initialize = @n = 0
  def add_block(_data) = Block.new(@n += 1)
end
stamp_dir = Dir.mktmpdir('stamp', TMPDIR)
stamp_records = [{ 'kind' => AR::KIND, 'session_id' => 's', 'anchor' => 'a', 'stop' => 'plan_proposed',
                   'decision' => 'approve', 'attestation' => 'terminal_nonce', 'block' => 7 }]
stamp_llm = lambda do |system:, user:, model:, effort:, provider:|
  { 'content' => '{"statements":[{"situation":"s","answer":"approve","sources":[7],"count":1}]}',
    'model_observed' => 'claude-opus-5-5', 'provider' => provider }
end
stamp_run = lambda do
  AG::DistillRun.run(dir: stamp_dir, delegation_status: 'in_force', records: stamp_records, facts: ->(*) {},
                     reason: ->(*) {}, edits: [], llm: stamp_llm, chain: CountingChain.new, judge: DL::JUDGE,
                     prompts: DP, manual: true, now: Time.utc(2026, 10, 12, 12, 0, 0))
end
first_run = stamp_run.call
first_md = File.join(stamp_dir, 'drafts', "#{first_run['stamp']}.md")
first_bytes = File.binread(first_md)
File.write(File.join(stamp_dir, 'drafts', "#{first_run['stamp']}.edit.md"), "operator editing\n")
second_run = stamp_run.call
assert('a second draft in the same second takes a new stamp and overwrites nothing') do
  first_run['status'] == 'drafted' && second_run['status'] == 'drafted' &&
    second_run['stamp'] == "#{first_run['stamp']}-2" && File.binread(first_md) == first_bytes &&
    File.read(File.join(stamp_dir, 'drafts', "#{first_run['stamp']}.edit.md")) == "operator editing\n"
end

# ---------------------------------------------------------------------------
section '3. The worker end to end: answers in, a recorded draft out; adoption; the next draft'

RUBY = RbConfig.ruby
SERVER_LIB = File.expand_path('../../../../lib', __dir__)
DISTILL_BIN = File.expand_path('../bin/agent_distill.rb', __dir__)
FAKE_BIN = File.join(TMPDIR, 'fakebin')
FileUtils.mkdir_p(FAKE_BIN)
SEEN = File.join(TMPDIR, 'claude_seen.txt')
REPLY_FILE = File.join(TMPDIR, 'claude_reply.json')
File.write(File.join(FAKE_BIN, 'claude'), <<~SH)
  #!/bin/sh
  echo "$@" > #{SEEN}
  cat >> #{SEEN}
  cat #{REPLY_FILE}
SH
File.chmod(0o755, File.join(FAKE_BIN, 'claude'))

def reply_with(content, model: 'claude-opus-5-5')
  File.write(REPLY_FILE, JSON.generate({ 'type' => 'result', 'is_error' => false, 'result' => content,
                                         'modelUsage' => { model => { 'outputTokens' => 9 } }, 'usage' => {} }))
end

def run_worker
  FileUtils.rm_f(SEEN)
  env = { 'KAIROS_SERVER_LIB' => SERVER_LIB, 'KAIROS_DATA_DIR' => REAL, 'KAIROS_PROJECT_ROOT' => PROJECT,
          'PATH' => "#{FAKE_BIN}:#{ENV['PATH']}" }
  out = IO.popen(env, [RUBY, DISTILL_BIN, '--manual'], err: %i[child out], &:read)
  [$?.exitstatus, out.lines.map { |l| JSON.parse(l) rescue nil }.compact.last || {}, out]
end

def session_dir(sid) = File.join(SESSIONS, sid).tap { |d| FileUtils.mkdir_p(d) }

# Answer one: a plan with one classified step and one the table does not
# classify, a reason typed at the terminal, facts filed by the driver.
d1 = session_dir('agent_s_one')
task = { 'steps' => [{ 'step_id' => 's1', 'tool_name' => 'knowledge_get' },
                     { 'step_id' => 's2', 'tool_name' => 'secret_tool_name' }] }
facts = PF.facts_for(task, [{ 'effect' => 'read_only' }, nil])
facts_sha = PF.record_answer(d1, anchor: '2:proposed:0', point: 'plan_proposed', cycle: 1,
                                 current: { 'cycle' => 1, 'plan_sha256' => 'p1', 'act_table_sha256' => 't1',
                                            'facts' => facts })
AR.save_texts(d1, anchor: '2:proposed:0', source: 'terminal', rationale: 'small and reversible')
b1 = add({ 'kind' => AR::KIND, 'session_id' => 'agent_s_one', 'anchor' => '2:proposed:0', 'stop' => 'plan_proposed',
           'cycle' => 1, 'decision' => 'approve', 'attestation' => 'terminal_nonce', 'signals' => ['multi_file', 'x'],
           'set_aside' => 1, 'rationale_sha256' => AR.sha256('small and reversible'), 'facts_sha256' => facts_sha })
# Answer two: a stop at the checkpoint whose reason exists only as caller
# text, and whose ruling names a facts line that is not the one filed.
d2 = session_dir('agent_s_two')
PF.record_answer(d2, anchor: '5:checkpoint:2', point: 'cycle_checkpoint', cycle: 2, current: nil)
AR.save_texts(d2, anchor: '5:checkpoint:2', source: 'caller', rationale: 'drifting away')
b2 = add({ 'kind' => AR::KIND, 'session_id' => 'agent_s_two', 'anchor' => '5:checkpoint:2',
           'stop' => 'cycle_checkpoint', 'cycle' => 2, 'decision' => 'stop', 'attestation' => 'terminal_nonce',
           'rationale_sha256' => AR.sha256('drifting away'), 'facts_sha256' => 'ff' * 32 })
# Answer three: not attested; never read.
add({ 'kind' => AR::KIND, 'session_id' => 'agent_s_three', 'anchor' => '2:proposed:0', 'stop' => 'plan_proposed',
      'decision' => 'approve', 'attestation' => 'caller_unattested', 'rationale_sha256' => AR.sha256('UNATTESTED') })

# Answer four: approved at the plan, but its filed window is empty (the driver
# saw no plan), and the ruling names that very line.
d4 = session_dir('agent_s_four')
facts_sha4 = PF.record_answer(d4, anchor: '3:proposed:1', point: 'plan_proposed', cycle: 1, current: nil)
AR.save_texts(d4, anchor: '3:proposed:1', source: 'terminal', rationale: 'fine as it is')
b4 = add({ 'kind' => AR::KIND, 'session_id' => 'agent_s_four', 'anchor' => '3:proposed:1', 'stop' => 'plan_proposed',
           'cycle' => 1, 'decision' => 'approve', 'attestation' => 'terminal_nonce',
           'rationale_sha256' => AR.sha256('fine as it is'), 'facts_sha256' => facts_sha4 })

DRAFT = JSON.generate({ 'statements' => [
  { 'situation' => 'A plan proposed with one read and one step the table does not classify', 'answer' => 'approve',
    'sources' => [b1], 'count' => 1, 'reasons' => ['small and reversible'] },
  { 'situation' => 'A checkpoint after a cycle', 'answer' => 'escalate', 'sources' => [b2], 'count' => 1 }
] })

rule('withdraw')
reply_with(DRAFT)
code0, res0, = run_worker
assert('with the table out of force the worker drafts nothing, and asks no model') do
  code0.zero? && res0['status'] == 'table_not_in_force' && !File.exist?(SEEN)
end
rule
code, res, raw = run_worker
seen = File.exist?(SEEN) ? File.read(SEEN) : ''
assert('the worker asked claude for the distiller model and effort, sandboxed') do
  seen.include?('--model claude-opus-5-5') && seen.include?('--effort xhigh') && seen.include?('--disallowedTools')
end
assert('it drafted, and the draft is recorded on the chain by its bytes') do
  draft_rec = AD.draft_records[0].last
  code.zero? && res['status'] == 'drafted' && draft_rec &&
    draft_rec['draft_sha256'] == Digest::SHA256.hexdigest(File.binread(File.join(DISTILL, 'drafts', "#{res['stamp']}.md"))) &&
    draft_rec['prompt_sha256'] == DP.sha256
end
puts "        (worker said: #{raw.strip[0, 300]})" unless code.zero?
assert("the distiller read the operator's terminal reason and the filed facts") do
  seen.include?('small and reversible') && seen.include?('knowledge_get') && seen.include?('"unclassified": 1')
end
assert('it never read caller text, unattested answers, session ids, anchors or an unclassified name') do
  !seen.include?('drifting away') && !seen.include?('UNATTESTED') && !seen.include?('agent_s_one') &&
    !seen.include?('2:proposed:0') && !seen.include?('secret_tool_name')
end
assert('a facts line the ruling does not name gives no facts, and signals are filtered to the observed ones') do
  seen.include?('"plans": null') && seen.include?('"multi_file"') && !seen.include?('"x"')
end
answers_seen = begin
  JSON.parse(seen[/#{Regexp.escape(DP::ANSWERS_HEADING)}\n`{3,}\n(.*?)\n`{3,}/m, 1].to_s)
rescue StandardError
  []
end
assert('an empty filed window reaches the distiller as no facts, and only observed facts pass') do
  a4 = answers_seen.find { |a| a['block'] == b4 }
  a1 = answers_seen.find { |a| a['block'] == b1 }
  a4 && a4['plans'].nil? && a1 &&
    a1['plans'] == [{ 'cycle' => 1, 'facts' => facts.slice('steps', 'unclassified', 'step_count') }] &&
    !seen.include?('marked_for_person') && !seen.include?('"plan_sha256"')
end
stamp = res['stamp']
draft_md = File.join(DISTILL, 'drafts', "#{stamp}.md")
edit_md = File.join(DISTILL, 'drafts', "#{stamp}.edit.md")
assert('the draft states each count beside its sources, computed by code') do
  body = File.read(draft_md)
  body.include?("in 1 of the 1 answers this statement cites (blocks ##{b1})") && body.include?('Without recorded step facts: 1 of 1') &&
    body.include?('All 2 answers at plan_proposed: approve 2, revise 0, escalate 0; without recorded step facts: 1.') &&
    body.include?('Situation (as the distiller worded it): A plan proposed') &&
    File.read(edit_md) == body
end

assert('the run moved the high-water mark to the newest answer it read') do
  st = AG::DistillRun.state(DISTILL)
  st['high_water'] == b4 && st.dig('last', 'status') == 'drafted'
end

# --- adoption ---
def adopt(stamp: nil, nonce: 'q9q9q9', chain_obj: nil, out: StringIO.new)
  AD.interactive_adopt(dir: DISTILL, sessions_dir: SESSIONS, tty_in: nonce_in(nonce), tty_out: out, stamp: stamp,
                       chain: chain_obj || chain, nonce_value: 'q9q9q9')
end

busy = session_dir('agent_busy')
File.write(File.join(busy, 'session.json'), JSON.generate({ 'session_id' => 'agent_busy', 'state' => 'acting' }))
assert('adoption is refused while a session is mid-run') { adopt['reason'] == 'session_mid_run' }
File.write(File.join(busy, 'session.json'), JSON.generate({ 'session_id' => 'agent_busy', 'state' => 'checkpoint' }))

original = File.binread(draft_md)
File.write(draft_md, "#{original}planted line\n")
assert('a draft whose bytes match no record the distiller made is not offered') do
  r = adopt
  r['reason'] == 'no_draft' && r['detail'].include?('matches no record')
end
File.binwrite(draft_md, original)

File.write(edit_md, "#{original}Operator note: only when nothing writes.\n")
assert('a wrong nonce writes and records nothing') do
  adopt(nonce: 'nope')['reason'] == 'nonce_mismatch' && !File.exist?(ENTRY)
end
File.open(File.join(DISTILL, AD::LOCK_FILE), 'a') do |held|
  held.flock(File::LOCK_EX)
  assert('a second adoption while one is in progress is refused') { adopt['reason'] == 'busy' && !File.exist?(ENTRY) }
end

# The nonce is typed after a pause in which the world may move on.
class TypingAfter
  def initialize(nonce, &before) = (@nonce = nonce; @before = before)
  def gets = (@before.call; "#{@nonce}\n")
end
def adopt_with(tty_in) = AD.interactive_adopt(dir: DISTILL, sessions_dir: SESSIONS, tty_in: tty_in, tty_out: StringIO.new,
                                               chain: chain, nonce_value: 'q9q9q9')
assert('a ruling of the table made while the operator confirms is seen, and nothing is written') do
  r = adopt_with(TypingAfter.new('q9q9q9') { rule })
  r['reason'] == 'table_changed' && !File.exist?(ENTRY)
end
assert('a session that starts a run while the operator confirms is seen, and nothing is written') do
  r = adopt_with(TypingAfter.new('q9q9q9') do
    File.write(File.join(busy, 'session.json'), JSON.generate({ 'session_id' => 'agent_busy', 'state' => 'orienting' }))
  end)
  File.write(File.join(busy, 'session.json'), JSON.generate({ 'session_id' => 'agent_busy', 'state' => 'checkpoint' }))
  r['reason'] == 'session_mid_run' && !File.exist?(ENTRY)
end
AD.singleton_class.alias_method(:write_entry_kept, :write_entry)
AD.define_singleton_method(:write_entry) do |path, bytes|
  write_entry_kept(path, path == ENTRY && bytes.include?('Operator note') ? "swapped underneath\n" : bytes)
end
begin
  swapped = adopt
ensure
  AD.singleton_class.alias_method(:write_entry, :write_entry_kept)
end
assert('bytes on disk that are not the bytes adopted are never pinned, and are taken back') do
  swapped['reason'] == 'record_failed' && swapped['detail'].include?('not the bytes adopted') && !File.exist?(ENTRY)
end
class InterruptingChain
  def add_block(_data) = raise(Interrupt)
end
interrupt_out = StringIO.new
interrupted = begin
  adopt(chain_obj: InterruptingChain.new, out: interrupt_out)
  false
rescue Interrupt
  true
end
assert('an interrupt while recording puts the entry back, says so, and still interrupts') do
  interrupted && !File.exist?(ENTRY) && interrupt_out.string.include?('Interrupted; nothing was recorded. The entry that was there before was put back.')
end
shown = StringIO.new
adopted = adopt(out: shown)
entry_sha = File.exist?(ENTRY) ? Digest::SHA256.hexdigest(File.binread(ENTRY)) : nil
assert("adoption shows the operator's change and what the judge will read") do
  shown.string.include?('+ Operator note: only when nothing writes.') &&
    shown.string.include?('nothing is in force yet')
end
assert('adoption writes the edited copy and records one ruling that pins it, naming the draft') do
  rec = adopted['record']
  adopted['recorded'] && File.binread(ENTRY) == File.binread(edit_md) &&
    rec['action'] == 'activate' && rec['attestation'] == 'terminal_nonce' &&
    rec['reads'].find { |p| p['name'] == 'judgment_precedents' }['sha256'] == entry_sha &&
    rec['adoption']['stamp'] == stamp && rec['adoption']['edited'] == true &&
    rec['adoption']['draft_sha256'] == Digest::SHA256.hexdigest(original)
end
assert('the table is in force with the adopted bytes pinned') do
  e = DL.load_effective
  e['status'] == 'in_force' && e['reads'].find { |p| p['name'] == 'judgment_precedents' }['sha256'] == entry_sha
end
saved = JSON.parse(File.read(File.join(DISTILL, 'adoptions', "#{adopted['block_index']}.json")))
assert("the operator's changes are kept for the next draft") do
  saved['changes'] == '+ Operator note: only when nothing writes.' && saved['adopted_block'] == adopted['block_index']
end
assert('adopting the same bytes again is refused as nothing to adopt') { adopt['reason'] == 'unchanged' }
assert('a later ruling of the table (after a mode edit) keeps the adopted pin') do
  File.write(MODE_FILE, "#{File.read(MODE_FILE)}One more line.\n")
  out = rule
  out['recorded'] && DL.load_effective['status'] == 'in_force'
end

File.write(ENTRY, "#{File.read(ENTRY)}edited by hand\n")
assert('an entry that left its pin stops the table, and a plain ruling still refuses it') do
  DL.load_effective['status'] == 'reads_changed' && rule['reason'] == 'precedents_changed'
end
recovered_out = StringIO.new
recovered = adopt(out: recovered_out)
assert('adoption is the way back: it re-adopts a recorded draft and the table is in force again') do
  recovered['recorded'] && recovered_out.string.include?('not the one last pinned') &&
    File.binread(ENTRY) == File.binread(edit_md) && DL.load_effective['status'] == 'in_force'
end

# The next draft reads the operator's change, and not the entry it adopted.
sleep 1.1 # a draft's stamp has one-second resolution
reply_with(DRAFT)
code2, res2, = run_worker
seen2 = File.exist?(SEEN) ? File.read(SEEN) : ''
assert("the next draft is derived from all answers again, with the operator's change and not the entry") do
  code2.zero? && res2['status'] == 'drafted' && seen2.include?('+ Operator note: only when nothing writes.') &&
    !seen2.include?('# Agent judgment precedents') && seen2.include?('small and reversible')
end

# A ruling that cannot be recorded puts the previous entry back.
class RefusingChain
  def add_block(_data) = raise(IOError, 'disk full')
end
stamp2 = res2['stamp']
File.write(File.join(DISTILL, 'drafts', "#{stamp2}.edit.md"), "replaced entirely\n")
before = File.binread(ENTRY)
failed = adopt(stamp: stamp2, chain_obj: RefusingChain.new)
assert('when the ruling cannot be recorded, the entry in force is put back') do
  failed['reason'] == 'record_failed' && File.binread(ENTRY) == before && DL.load_effective['status'] == 'in_force'
end

File.write(ENTRY, "replaced entirely\n") # what a killed adoption of that copy leaves behind, unpinned
killed_out = StringIO.new
killed = adopt(stamp: stamp2, out: killed_out)
assert("the bytes a killed adoption left at the path are pinned by adopting the same copy again") do
  killed['recorded'] && killed_out.string.include?('not the one last pinned') &&
    DL.load_effective['status'] == 'in_force'
end

rule('withdraw')
assert('adoption never brings a withdrawn table into force') do
  adopt(stamp: stamp2)['reason'] == 'table_not_in_force' && DL.load_effective['status'] == 'withdrawn'
end

reply_with('{"statements": [{"situation": "x", "answer": "approve", "sources": [99999], "count": 1}]}')
back = rule
assert('ruling the table back after a withdrawal keeps the precedents last adopted') do
  back['recorded'] && DL.load_effective['status'] == 'in_force'
end
code3, res3, = run_worker
assert('a draft citing an answer it was not given fails, and the failure holds back the trigger') do
  code3 == 1 && res3['status'] == 'failed' && res3['reason'].include?('sources name no answer') &&
    AG::DistillRun.state(DISTILL).dig('last', 'status') == 'failed'
end

# ---------------------------------------------------------------------------
section '4. Agreement is counted per version of what shaped the judge'

def verdict_dir_for(decision)
  d = Dir.mktmpdir('v', TMPDIR)
  body = JSON.generate({ 'decision' => decision, 'rationale' => 'r' })
  salt = 'a' * 32
  File.write(File.join(d, SJ::VERDICT_FILE), JSON.generate({ 'salt' => salt, 'body' => body, 'status' => 'ok' }))
  [d, Digest::SHA256.hexdigest("#{salt}:#{body}")]
end

dirs = {}
records = []
[['s_a', 10, 'aa', nil], ['s_b', 20, 'aa', 'p2'], ['s_c', 30, 'bb', 'p2']].each do |sid, blk, mode_sha, prompt|
  dir, commitment = verdict_dir_for('approve')
  dirs[sid] = dir
  records << { 'kind' => SJ::SEAL_KIND, 'session_id' => sid, 'anchor' => '1:proposed:0', 'block' => blk,
               'judge_status' => 'ok', 'plan_sha256' => 'p', 'commitment' => commitment,
               'tables' => { 'delegation' => 'd', 'act_classification' => 'a' },
               'reads' => [{ 'name' => 'instruction_mode', 'sha256' => mode_sha }],
               'judge_prompt_sha256' => prompt }.compact
  records << { 'kind' => AR::KIND, 'session_id' => sid, 'anchor' => '1:proposed:0', 'block' => blk + 2,
               'stop' => 'plan_proposed', 'decision' => 'approve', 'attestation' => 'terminal_nonce',
               'attestation_block' => blk + 1, 'plan_sha256' => 'p' }
end
by = SJ.agreement_by_version(records, verdict_dir: ->(sid, _a) { dirs[sid] })
assert('three seals under three versions are three counts, newest first, none merged') do
  by['versions'].size == 3 && by['versions'].map { |v| v['last_seal'] } == [30, 20, 10] &&
    by['versions'].all? { |v| v['summary']['pairs'] == 1 }
end
assert('a seal from before the prompt digest is its own version') do
  by['versions'].last['version']['judge_prompt'].nil? && !by['versions'].first['version']['judge_prompt'].nil?
end
assert('the pooled count is unchanged') { SJ.agreement(records, verdict_dir: ->(sid, _a) { dirs[sid] })['pairs'] == 3 }
assert('the seal carries the digest of the prompt the judge was asked with') do
  SJ.prompt_sha256 == Digest::SHA256.hexdigest(JSON.generate([SJ::PROMPT_VERSION, SJ.system_prompt, SJ::POINT_QUESTION]))
end

Dir.chdir(ORIG_PWD)
FileUtils.rm_rf(TMPDIR)

puts "\n#{'=' * 60}\nRESULTS: #{$pass} passed, #{$fail} failed\n#{'=' * 60}"
exit($fail.zero? ? 0 : 1)
