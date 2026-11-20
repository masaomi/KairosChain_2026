# frozen_string_literal: true

# Test: succession edges on the L2 save path (dream_digest design v0.13, I13).
# An edge is valid when it carries grounds and its formal target exists. A save whose
# succession edge fails either condition is refused and stores nothing; a save that declares
# no succession edge is never refused by this rule.

require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'date'
require 'time'
require_relative 'lib/kairos_mcp/context_graph'

module KairosMcp
  class << self
    attr_accessor :_test_context_dir
  end

  def self.context_dir(user_context: nil)
    @_test_context_dir
  end
end

require_relative 'lib/kairos_mcp/context_manager'

$pass = 0
$fail = 0
$errors = []

def assert(label)
  if yield
    $pass += 1
    puts "  ok  #{label}"
  else
    $fail += 1
    $errors << label
    puts "  FAIL #{label}"
  end
rescue StandardError => e
  $fail += 1
  $errors << "#{label} (#{e.class}: #{e.message})"
  puts "  FAIL #{label} (#{e.class}: #{e.message})"
end

CG = KairosMcp::ContextGraph
SID = 'session_20261120_101010_aaaaaaaa'
OTHER = 'session_20261120_111111_bbbbbbbb'

def node(name, relations = nil)
  front = { 'name' => name }
  front['relations'] = relations if relations
  "---\n#{YAML.dump(front).sub(/\A---\n/, '')}---\nbody of #{name}\n"
end

def stored?(root, sid, name)
  File.file?(File.join(root, sid, name, "#{name}.md"))
end

def with_store
  Dir.mktmpdir do |root|
    KairosMcp._test_context_dir = root
    cm = KairosMcp::ContextManager.new(root)
    cm.save_context(SID, 'old_note', node('old_note'))
    yield cm, root
  end
end

QUOTED = { 'quote' => 'the cut-off is the 25th', 'by' => 'the operator' }.freeze

puts '== The two conditions (ContextGraph) =='
with_store do |_cm, root|
  ok = { 'type' => 'replaces', 'target' => "v1:#{SID}/old_note", 'grounds' => QUOTED }
  assert('grounds and an existing target: valid') { CG.succession_edge_failures(ok, root).empty? }
  assert('corrects is a succession type as well') do
    CG.succession_edge_failures(ok.merge('type' => 'corrects'), root).empty?
  end
  assert('contradicted_by alone is grounds') do
    e = ok.merge('grounds' => { 'contradicted_by' => "v1:#{SID}/elsewhere" })
    CG.succession_edge_failures(e, root).empty?
  end
  assert('no grounds: :no_grounds') do
    CG.succession_edge_failures(ok.reject { |k, _| k == 'grounds' }, root) == [:no_grounds]
  end
  assert('a quotation with no attribution is not grounds') do
    CG.succession_edge_failures(ok.merge('grounds' => { 'quote' => 'words' }), root) == [:no_grounds]
  end
  assert('blank grounds are not grounds') do
    CG.succession_edge_failures(ok.merge('grounds' => { 'quote' => ' ', 'by' => ' ' }), root) == [:no_grounds]
  end
  assert('grounds given as a bare string are not grounds') do
    CG.succession_edge_failures(ok.merge('grounds' => 'because'), root) == [:no_grounds]
  end
  assert('a target that does not exist: :target_missing') do
    CG.succession_edge_failures(ok.merge('target' => "v1:#{SID}/nowhere"), root) == [:target_missing]
  end
  assert('a bare name is not a formal target: :target_missing') do
    CG.succession_edge_failures(ok.merge('target' => 'old_note'), root) == [:target_missing]
  end
  assert('both conditions are reported together') do
    e = { 'type' => 'replaces', 'target' => "v1:#{SID}/nowhere" }
    CG.succession_edge_failures(e, root) == %i[no_grounds target_missing]
  end
  assert('informed_by is not a succession edge') { !CG.succession_edge?('type' => 'informed_by', 'target' => 'v1:a/b') }
  assert('supersedes (a type name the graph does not define) is not a succession edge') do
    !CG.succession_edge?('type' => 'supersedes', 'target' => 'v1:a/b')
  end
end

puts '== Refusal at save (ContextManager) =='
with_store do |cm, root|
  r = cm.save_context(SID, 'new_note', node('new_note', [
    { 'type' => 'replaces', 'target' => "v1:#{SID}/old_note", 'part' => 'the cut-off date', 'grounds' => QUOTED }
  ]))
  assert('a valid succession edge is saved') { r[:success] && stored?(root, SID, 'new_note') }

  r = cm.save_context(SID, 'no_grounds', node('no_grounds', [
    { 'type' => 'replaces', 'target' => "v1:#{SID}/old_note" }
  ]))
  assert('an edge without grounds is refused') { r[:success] == false }
  assert('the refusal returns the reason') { r[:error].include?('SuccessionRefusedError') && r[:error].include?('no grounds') }
  assert('the refusal stores nothing') { !stored?(root, SID, 'no_grounds') && !Dir.exist?(File.join(root, SID, 'no_grounds')) }

  r = cm.save_context(SID, 'no_target', node('no_target', [
    { 'type' => 'corrects', 'target' => "v1:#{SID}/nowhere", 'grounds' => QUOTED }
  ]))
  assert('an edge whose target does not exist is refused') { r[:success] == false && r[:error].include?('does not exist') }
  assert('and stores nothing') { !stored?(root, SID, 'no_target') }

  r = cm.save_context(SID, 'no_target', node('no_target'))
  assert('after a refusal the node can be saved without the edge') { r[:success] && stored?(root, SID, 'no_target') }

  before = File.read(File.join(root, SID, 'new_note', 'new_note.md'))
  r = cm.save_context(SID, 'new_note', node('new_note', [{ 'type' => 'replaces', 'target' => "v1:#{SID}/old_note" }]))
  assert('a refused update leaves the stored node as it was') do
    r[:success] == false && File.read(File.join(root, SID, 'new_note', 'new_note.md')) == before
  end
end

puts '== Saves that declare no succession edge are untouched =='
with_store do |cm, root|
  r = cm.save_context(SID, 'plain', node('plain'))
  assert('a node without relations is saved') { r[:success] }
  r = cm.save_context(SID, 'forward', node('forward', [{ 'type' => 'informed_by', 'target' => "v1:#{SID}/not_yet" }]))
  assert('an informed_by edge to a node that does not exist yet is still saved') { r[:success] && stored?(root, SID, 'forward') }
  r = cm.save_context(SID, 'informal', node('informal', [{ 'type' => 'supersedes', 'target' => "v1:#{SID}/not_yet" }]))
  assert('an edge of a type the graph does not define is still saved') { r[:success] && stored?(root, SID, 'informal') }
end

puts '== A soft-archived target exists =='
with_store do |cm, root|
  stub = "---\nname: old_note\nstatus: soft-archived\n---\n# old_note [ARCHIVED]\n"
  File.write(File.join(root, SID, 'old_note', 'old_note.md'), stub)
  r = cm.save_context(SID, 'after_archive', node('after_archive', [
    { 'type' => 'replaces', 'target' => "v1:#{SID}/old_note", 'grounds' => QUOTED }
  ]))
  assert('an edge to a soft-archived node is saved') { r[:success] }
end

puts '== From a name to formal targets =='
with_store do |cm, root|
  cm.save_context(OTHER, 'old_note', node('old_note'))
  cm.save_context(OTHER, 'unrelated', node('unrelated'))
  assert('every node bearing the name, in the formal form') do
    cm.formal_targets_for('old_note') == ["v1:#{SID}/old_note", "v1:#{OTHER}/old_note"].sort
  end
  assert('a name no node bears yields nothing') { cm.formal_targets_for('nobody') == [] }
  assert('a name that is not one segment yields nothing') do
    cm.formal_targets_for('../old_note') == [] && cm.formal_targets_for('') == [] && cm.formal_targets_for(nil) == []
  end
  r = cm.save_context(SID, 'wrong_session', node('wrong_session', [
    { 'type' => 'replaces', 'target' => 'v1:session_20200101_000000_cccccccc/old_note', 'grounds' => QUOTED }
  ]))
  assert('a refusal for a missing target names the nodes that bear its name') do
    r[:success] == false && r[:error].include?("v1:#{SID}/old_note") && r[:error].include?("v1:#{OTHER}/old_note")
  end
  other_root = Dir.mktmpdir
  begin
    other = KairosMcp::ContextManager.new(other_root)
    assert('the lookup is made under the caller\'s own context root') { other.formal_targets_for('old_note') == [] }
    r = other.save_context(SID, 'elsewhere', node('elsewhere', [
      { 'type' => 'replaces', 'target' => "v1:#{SID}/old_note", 'grounds' => QUOTED }
    ]))
    assert('a target that exists only under another root does not exist for this caller') do
      r[:success] == false && !r[:error].include?('nodes named')
    end
  ensure
    FileUtils.remove_entry(other_root)
  end
end

puts
puts '===== RESULTS ====='
puts "  PASS: #{$pass}"
puts "  FAIL: #{$fail}"
unless $errors.empty?
  puts 'Failures:'
  $errors.each { |e| puts "  - #{e}" }
end
exit($fail.zero? ? 0 : 1)
