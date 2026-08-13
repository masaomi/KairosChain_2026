#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: L1/L2 store access stays inside its store root
#
# Regression tests for the 2026-08-04 path-traversal finding: URI segments and
# knowledge/context names were joined onto a store root with File.join and never
# checked, so "knowledge://../storage/tokens.json" read the instance token store.
#
# Invariant under test: every path the L1/L2 layers open, create, move, or
# delete resolves inside the store root it was addressed against, and every
# caller-supplied name denotes one directory rather than a route.
#
# These tests drive the real ResourceRegistry / KnowledgeProvider /
# ContextManager. They do not re-implement either guard.
#
# Two rules this file exists to obey, both learned from earlier versions of it
# that looked green while missing real defects:
#
# 1. EVERY NEGATIVE MUST TARGET SOMETHING THAT EXISTS AND IS REACHABLE.
#    A refusal only proves containment if the thing refused was reachable
#    without the guard. An earlier version asserted nil for URIs resolving to
#    paths nothing had created, so those assertions passed with the guards
#    removed — they measured absence, not defence. The fixture is laid out to
#    match where each URI resolves, which is why the data dir is nested one
#    level inside the temp dir: a two-levels-up escape has to land on a planted
#    file rather than on the system temp directory.
#
# 2. EVERY DESTRUCTIVE CASE GETS ITS OWN STORE.
#    With the guards disabled, the first store-wiping call destroys the fixture,
#    and every later assertion in the same store then passes trivially because
#    there is nothing left to damage. Sharing one store across destructive cases
#    hid 15 assertions behind the first one. `fresh_store` gives each its own.
#
#   <tmp>/                       outside.txt, "...md"   <- two levels up from a store
#     data/                      "...md", tokens.json   <- one level up from a store
#       storage/                 tokens.json, storage.md (a parseable entry, so a
#                                traversal that reaches it returns content)
#       knowledge/<entry>/
#         .archived/
#       context/<session>/<ctx>/
#
# Falsification: run this file against a COPY of lib/ under /tmp with a guard
# forced to return true. Every negative must go red. Do not mutate the working
# tree to do this — an interrupted run would leave containment disabled.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'kairos_mcp'
require 'kairos_mcp/path_containment'
require 'kairos_mcp/resource_registry'
require 'kairos_mcp/knowledge_provider'
require 'kairos_mcp/context_manager'
require 'tmpdir'
require 'fileutils'

@failures = 0
@passes = 0

def assert(cond, msg)
  if cond
    print '.'
    @passes += 1
  else
    puts "\nFAIL: #{msg}"
    @failures += 1
  end
end

SESSION = 'session_fixture'
CONTEXT = 'fixture_context'
KNOWLEDGE = 'fixture_knowledge'
SECRET = '{"secret":"do-not-read"}'

# A name that is ".." plus the ".md" suffix the readers append. A URI whose name
# component is ".." addresses exactly this file.
DOTDOT_MD = '...md'

def frontmatter(name)
  "---\nname: #{name}\ndescription: fixture entry\n---\n\nbody\n"
end

def build_fixture(tmp)
  data = File.join(tmp, 'data')

  kroot = File.join(data, 'knowledge')
  croot = File.join(data, 'context')

  kdir = File.join(kroot, KNOWLEDGE)
  FileUtils.mkdir_p(File.join(kdir, 'scripts'))
  FileUtils.mkdir_p(File.join(kroot, '.archived'))
  File.write(File.join(kdir, "#{KNOWLEDGE}.md"), frontmatter(KNOWLEDGE))
  File.write(File.join(kdir, 'scripts', 'run.py'), "print('ok')\n")

  cdir = File.join(croot, SESSION, CONTEXT)
  FileUtils.mkdir_p(File.join(cdir, 'scripts'))
  File.write(File.join(cdir, "#{CONTEXT}.md"), frontmatter(CONTEXT))
  File.write(File.join(cdir, 'scripts', 'go.sh'), "echo ok\n")

  # Bait for the dot-segment cases. A name of "." or ".." makes a reader address
  # the store root (or the session root) as though it were an entry, and the
  # readers look for "<name>.md" there — which for ".." is the file "..md" — or
  # fall back to the first *.md they find. Without these, those negatives would
  # be refused by the absence of a parseable file rather than by a guard, and
  # they would stay green with the guards removed.
  # The parser looks for "<basename-of-dir>.md". For a directory addressed as
  # "<root>/<session>/..", the basename is ".." and the file it wants is
  # "...md" sitting in the root.
  File.write(File.join(kroot, '..md'), frontmatter('bait_l1_root'))
  File.write(File.join(croot, '..md'), frontmatter('bait_l2_root'))
  File.write(File.join(croot, DOTDOT_MD), frontmatter('bait_l2_root_dotdot'))
  File.write(File.join(croot, SESSION, '..md'), frontmatter('bait_session'))
  File.write(File.join(croot, SESSION, "#{SESSION}.md"), frontmatter('bait_session_named'))
  File.write(File.join(data, 'data.md'), frontmatter('bait_above_stores'))

  # Bait for a multi-segment knowledge name: "a/b" must be refused as a name,
  # not merely fail to exist.
  FileUtils.mkdir_p(File.join(kroot, 'a', 'b'))
  File.write(File.join(kroot, 'a', 'b', 'b.md'), frontmatter('b'))

  # Targets outside the stores, planted where the negative cases resolve.
  # storage/ is a PARSEABLE entry directory: without a guard, a traversal that
  # reaches it returns a skill rather than nil, so the negatives about it are
  # about refusal and not about a failed parse.
  FileUtils.mkdir_p(File.join(data, 'storage'))
  File.write(File.join(data, 'storage', 'storage.md'), frontmatter('storage'))
  File.write(File.join(data, 'storage', 'tokens.json'), SECRET)
  File.write(File.join(data, 'storage', 'outside.txt'), SECRET)
  File.write(File.join(data, 'tokens.json'), SECRET)       # <- symlink + ".." lands here
  File.write(File.join(data, DOTDOT_MD), SECRET)           # <- knowledge://.. lands here
  File.write(File.join(tmp, 'outside.txt'), SECRET)        # <- two levels up
  File.write(File.join(tmp, DOTDOT_MD), SECRET)            # <- context://../.. lands here

  data
end

# Yields a store nobody else has touched. Every destructive assertion runs in
# one of these, so a mutant that succeeds in wiping a store cannot thereby make
# the next assertion pass for want of anything left to wipe.
def fresh_store
  Dir.mktmpdir do |tmp|
    data = build_fixture(tmp)
    yield(
      tmp,
      data,
      KairosMcp::ContextManager.new(File.join(data, 'context')),
      KairosMcp::KnowledgeProvider.new(File.join(data, 'knowledge'), vector_search_enabled: false)
    )
  end
end

# True while the L2 store still holds what the fixture put there. Checks the
# CONTENTS: FileUtils.rm_rf("<root>/.") empties a directory while leaving the
# node, so asserting the node exists proves nothing.
def l2_intact?(data)
  croot = File.join(data, 'context')
  md = File.join(croot, SESSION, CONTEXT, "#{CONTEXT}.md")
  root_bait = File.join(croot, '..md')
  dotdot_bait = File.join(croot, DOTDOT_MD)

  File.file?(md) && File.read(md) == frontmatter(CONTEXT) &&
    File.file?(root_bait) && File.read(root_bait) == frontmatter('bait_l2_root') &&
    File.file?(dotdot_bait) && File.read(dotdot_bait) == frontmatter('bait_l2_root_dotdot') &&
    Dir.children(croot).sort == ['..md', DOTDOT_MD, SESSION].sort
end

# True while the planted out-of-store entry is untouched.
def outside_intact?(data)
  md = File.join(data, 'storage', 'storage.md')
  tok = File.join(data, 'storage', 'tokens.json')
  File.file?(md) && File.file?(tok) && File.read(tok) == SECRET
end

Dir.mktmpdir do |tmp|
  data = build_fixture(tmp)
  KairosMcp.data_dir = data

  kroot = File.join(data, 'knowledge')
  croot = File.join(data, 'context')

  # ==========================================================================
  # Section 1: every negative's target exists and is readable right now
  # ==========================================================================
  puts "\n[Section 1] fixture sanity — the targets are real"

  [
    File.join(data, 'storage', 'tokens.json'),
    File.join(data, 'storage', 'outside.txt'),
    File.join(data, 'tokens.json'),
    File.join(data, DOTDOT_MD),
    File.join(tmp, 'outside.txt'),
    File.join(tmp, DOTDOT_MD)
  ].each do |t|
    assert File.file?(t) && File.read(t) == SECRET, "outside target must exist and be readable: #{t}"
  end

  assert File.file?(File.join(data, 'storage', 'storage.md')),
         'the out-of-store entry must be parseable, so a traversal reaching it returns content'

  registry = KairosMcp::ResourceRegistry.new

  # ==========================================================================
  # Section 2: legitimate URIs still resolve (no over-blocking)
  # ==========================================================================
  puts "\n[Section 2] legitimate resource URIs still read"

  main = registry.read("knowledge://#{KNOWLEDGE}")
  assert main && main[:content].include?('body'), 'knowledge main md must still read'

  script = registry.read("knowledge://#{KNOWLEDGE}/scripts/run.py")
  assert script && script[:content].include?('ok'), 'knowledge script must still read'

  ctx = registry.read("context://#{SESSION}/#{CONTEXT}")
  assert ctx && ctx[:content].include?('body'), 'context main md must still read'

  ctx_script = registry.read("context://#{SESSION}/#{CONTEXT}/scripts/go.sh")
  assert ctx_script && ctx_script[:content].include?('ok'), 'context script must still read'

  # ==========================================================================
  # Section 3: escaping URIs return nil — and each one reaches a planted file
  #
  # Each entry is [uri, the path it actually resolves to]. The resolved path is
  # asserted to exist first, so a nil read cannot be explained by absence.
  # ==========================================================================
  puts "\n[Section 3] escaping resource URIs are refused"

  escapes = [
    ['knowledge://../storage/tokens.json',                                      File.join(data, 'storage', 'tokens.json')],
    ['knowledge://../../outside.txt',                                           File.join(tmp, 'outside.txt')],
    ['knowledge://../outside.txt',                                              File.join(data, DOTDOT_MD)],
    ["knowledge://#{KNOWLEDGE}/scripts/../../../storage/tokens.json",           File.join(data, 'storage', 'tokens.json')],
    ["knowledge://#{KNOWLEDGE}/../../storage/tokens.json",                      File.join(data, 'storage', 'tokens.json')],
    ["context://#{SESSION}/#{CONTEXT}/../../../storage/tokens.json",            File.join(data, 'storage', 'tokens.json')],
    ["context://#{SESSION}/#{CONTEXT}/scripts/../../../../storage/tokens.json", File.join(data, 'storage', 'tokens.json')],
    ["context://#{SESSION}/../../storage/tokens.json",                          File.join(data, 'storage', 'tokens.json')],
    ['context://../../outside.txt',                                             File.join(tmp, DOTDOT_MD)]
  ]

  escapes.each do |uri, resolves_to|
    assert File.file?(resolves_to), "precondition: #{uri} must address an existing file (#{resolves_to})"
    assert registry.read(uri).nil?, "must refuse #{uri}"
  end

  # ==========================================================================
  # Section 4: a symlink planted inside a store does not widen it
  # ==========================================================================
  puts "\n[Section 4] in-store symlink pointing outside is refused"

  kscripts = File.join(kroot, KNOWLEDGE, 'scripts')
  symlinks_available = true
  begin
    File.symlink(File.join(data, 'storage', 'tokens.json'), File.join(kscripts, 'link.json'))
  rescue NotImplementedError, Errno::EPERM
    symlinks_available = false
    puts "\nSKIP: symlinks unavailable on this platform"
  end

  if symlinks_available
    assert File.read(File.join(kscripts, 'link.json')) == SECRET, 'precondition: the symlink reaches the secret'
    assert registry.read("knowledge://#{KNOWLEDGE}/scripts/link.json").nil?,
           'symlink escaping the store must be refused'
  end

  # ==========================================================================
  # Section 5: KnowledgeProvider name resolution
  #
  # Every traversal here reaches data/storage, which holds a parseable entry —
  # so without a guard these return a skill, not nil.
  # ==========================================================================
  puts "\n[Section 5] KnowledgeProvider name resolution is bounded"

  kp = KairosMcp::KnowledgeProvider.new(kroot, vector_search_enabled: false)

  assert kp.get(KNOWLEDGE), 'legitimate knowledge name must still resolve'
  assert File.directory?(File.join(data, 'storage')),
         'precondition: the traversal target is a real, parseable entry directory'
  assert kp.get('../storage').nil?, 'get must refuse a traversing name'
  assert kp.get('../../').nil?, 'get must refuse a traversing name'

  # .archived/ exists, so these address knowledge/.archived/../../storage,
  # which is the planted entry — reachable without the guard.
  assert File.directory?(File.join(kroot, '.archived')), 'precondition: the archive directory exists'
  assert kp.get_archived('../../storage').nil?, 'get_archived must refuse a traversing name'
  assert kp.archived?('../../storage') == false, 'archived? must refuse a traversing name'

  fresh_store do |_t, d, _cm, k|
    created = k.create('../evil_knowledge', frontmatter('evil'))
    assert created[:success] == false, 'create must refuse a traversing name'
    assert !File.exist?(File.join(d, 'evil_knowledge')), 'create must not have written outside the store'
  end

  # ".." always exists, so a bare success:false could come from the
  # "already exists" branch rather than from a guard. The reason is asserted.
  fresh_store do |_t, _d, _cm, k|
    kp_dot = k.create('..', frontmatter('x'))
    assert kp_dot[:error].to_s.include?('Invalid knowledge name'),
           'knowledge create ".." must be refused as an invalid name, not as an existing one'
  end

  assert kp.get('.').nil?, 'knowledge get must refuse "." as a name'
  assert kp.get('a/b').nil?, 'knowledge get must refuse a multi-segment name'

  # ==========================================================================
  # Section 6: ContextManager — each destructive case in its own store
  # ==========================================================================
  puts "\n[Section 6] ContextManager write and delete are bounded"

  fresh_store do |_t, _d, cm, _k|
    ok = cm.save_context(SESSION, 'new_context', frontmatter('new_context'))
    assert ok[:success] == true, 'legitimate save_context must still succeed'
  end

  fresh_store do |_t, d, cm, _k|
    bad = cm.save_context('..', 'evil_context', frontmatter('evil_context'))
    assert bad[:success] == false, 'save_context must refuse a traversing session_id'
    assert !File.exist?(File.join(d, 'evil_context')), 'save_context must not have written outside the store'
  end

  fresh_store do |_t, d, cm, _k|
    bad2 = cm.save_context(SESSION, '../../evil2', frontmatter('evil2'))
    assert bad2[:success] == false, 'save_context must refuse a traversing name'
    assert !File.exist?(File.join(d, 'evil2')), 'save_context must not have written outside the store'
  end

  fresh_store do |_t, _d, cm, _k|
    assert cm.get_context('..', 'storage').nil?, 'get_context must refuse a traversing session_id'
    assert cm.list_contexts_in_session('../..') == [], 'list_contexts_in_session must refuse a traversal'
  end

  fresh_store do |_t, d, cm, _k|
    del = cm.delete_context('..', 'storage')
    assert del[:success] == false, 'delete_context must refuse a traversing session_id'
    assert outside_intact?(d), 'delete_context must not have removed the outside tree'
  end

  fresh_store do |_t, d, cm, _k|
    del2 = cm.delete_session('../storage')
    assert del2[:success] == false, 'delete_session must refuse a traversing session_id'
    assert outside_intact?(d), 'delete_session must not have removed the outside tree'
  end

  fresh_store do |_t, d, cm, _k|
    sub = cm.create_subdir('..', 'storage', 'scripts')
    assert sub[:success] == false, 'create_subdir must refuse a traversing session_id'
    assert !File.exist?(File.join(d, 'storage', 'scripts')),
           'create_subdir must not have created a directory outside the store'
  end

  # ==========================================================================
  # Section 6b: dot-segment names collapse onto the store root
  #
  # R1 finding: containment alone accepts these, because the store root IS
  # inside the store. On a delete path that means the whole store. Each case
  # gets its own store so a successful wipe cannot mask the next case.
  # ==========================================================================
  puts "\n[Section 6b] dot-segment names cannot address the store root"

  fresh_store do |_t, d, cm, _k|
    r = cm.delete_context(SESSION, '..')
    assert r[:success] == false, 'delete_context must refuse ".." as a name'
    assert l2_intact?(d), 'delete_context ".." must leave every session and its contents'
  end

  fresh_store do |_t, d, cm, _k|
    r = cm.delete_context(SESSION, '.')
    assert r[:success] == false, 'delete_context must refuse "." as a name'
    assert l2_intact?(d), 'delete_context "." must leave the session and its contents'
  end

  fresh_store do |_t, d, cm, _k|
    r = cm.delete_session('.')
    assert r[:success] == false, 'delete_session must refuse "." as a session id'
    assert l2_intact?(d), 'delete_session "." must leave every session and its contents'
  end

  fresh_store do |_t, d, cm, _k|
    r = cm.delete_session('..')
    assert r[:success] == false, 'delete_session must refuse ".." as a session id'
    assert l2_intact?(d), 'delete_session ".." must leave every session and its contents'
  end

  fresh_store do |_t, d, cm, _k|
    r = cm.save_context(SESSION, '..', frontmatter('x'))
    assert r[:success] == false, 'save_context must refuse ".." as a name'
    assert l2_intact?(d), 'save_context ".." must not have rewritten anything in the store'
  end

  # The escape that needs no symlink: the guarded leaf path and the paths the
  # method actually operates on (mkdir_p of session_dir, and the parser's
  # second join of `name`) were three different things. Five levels up from
  # <context>/p1/p2/p3/p4 is <data>, i.e. outside the L2 store.
  fresh_store do |_t, d, cm, _k|
    deep = cm.save_context('p1/p2/p3/p4', '../../../../../OWNED', frontmatter('OWNED'))
    assert deep[:error].to_s.include?('Invalid session_id/name'),
           'save_context must be refused by the guard, not by a crash further in'
    assert !File.exist?(File.join(d, 'OWNED')), 'save_context must not have written above the store'
    assert !File.exist?(File.join(d, 'context', 'p1')),
           'save_context must not have created the intermediate session dir'
  end

  fresh_store do |_t, _d, cm, _k|
    assert cm.get_context(SESSION, '..').nil?, 'get_context must refuse ".." as a name'
    assert cm.list_contexts_in_session('.') == [], 'list_contexts_in_session must refuse "."'
  end

  fresh_store do |_t, d, cm, _k|
    r = cm.create_subdir(SESSION, '..', 'scripts')
    assert r[:success] == false, 'create_subdir must refuse ".." as a name'
    # <context>/<session>/.. is the L2 ROOT, so that is where an unguarded
    # mkdir_p would land — not under the session.
    assert !File.exist?(File.join(d, 'context', 'scripts')),
           'create_subdir ".." must not have created a directory at the store root'
  end

  # These address the planted "...md" files, so a nil is a refusal.
  assert File.file?(File.join(data, DOTDOT_MD)), 'precondition: knowledge://.. addresses a real file'
  assert registry.read('knowledge://..').nil?, 'knowledge:// must refuse ".."'
  assert registry.read('knowledge://.').nil?, 'knowledge:// must refuse "."'
  assert registry.read("context://#{SESSION}/.").nil?, 'context:// must refuse "." as a name'

  # ==========================================================================
  # Section 6c: a symlink inside the store, followed by ".."
  #
  # R1 finding: collapsing ".." lexically before resolving symlinks makes the
  # guard answer about a path the kernel never opens. `out` points at
  # data/storage, so out/.. is data, and the URI addresses data/tokens.json —
  # which the fixture plants, so the refusal is a refusal.
  # ==========================================================================
  puts "\n[Section 6c] symlink followed by \"..\" is refused"

  if symlinks_available
    File.symlink(File.join(data, 'storage'), File.join(kscripts, 'out'))

    reachable = File.join(kscripts, 'out', '..', 'tokens.json')
    assert File.file?(reachable) && File.read(reachable) == SECRET,
           'precondition: symlink + ".." reaches the planted secret'

    assert registry.read("knowledge://#{KNOWLEDGE}/scripts/out/../tokens.json").nil?,
           'symlink + ".." must be refused through the registry'

    assert !KairosMcp::PathContainment.contained?(kroot, reachable),
           'contained? must refuse symlink + ".."'

    # Same shape where the final component does not exist yet (create path).
    assert !KairosMcp::PathContainment.contained?(kroot, File.join(kscripts, 'out', '..', 'not_created_yet.md')),
           'contained? must refuse symlink + ".." for a missing target'

    # A dangling symlink out of the store: the target does not exist yet, so a
    # walk that reads ENOENT as "not created" would approve it and a write
    # would land outside.
    dangling = File.join(kscripts, 'dangling.md')
    File.symlink(File.join(data, 'not_yet_outside.md'), dangling)
    assert !KairosMcp::PathContainment.contained?(kroot, dangling),
           'contained? must refuse a dangling symlink pointing outside'

    # ...but a dangling symlink whose target is INSIDE the store is legitimate.
    inward = File.join(kscripts, 'inward.md')
    File.symlink(File.join(kscripts, 'not_yet_inside.md'), inward)
    assert KairosMcp::PathContainment.contained?(kroot, inward),
           'a dangling symlink pointing inside the store must still be allowed'
  end

  # ==========================================================================
  # Section 7: the predicate itself, at its boundaries
  # ==========================================================================
  puts "\n[Section 7] PathContainment boundaries"

  pc = KairosMcp::PathContainment
  assert pc.contained?(kroot, kroot), 'the base itself is contained'
  assert pc.contained?(kroot, File.join(kroot, KNOWLEDGE)), 'a child is contained'
  assert pc.contained?(kroot, File.join(kroot, 'not_yet_created', 'f.md')), 'a not-yet-created child is contained'
  assert !pc.contained?(kroot, File.join(kroot, '..', 'storage')), 'a parent-escaping path is not contained'
  assert !pc.contained?(kroot, "#{kroot}_sibling"), 'a sibling sharing the name prefix is not contained'
  assert !pc.contained?(File.join(data, 'no_such_base'), data), 'a missing base fails closed'

  # Fail closed rather than raise into a caller expecting a boolean.
  # Built by concatenation: File.join itself raises on a NUL byte, so joining
  # here would test Ruby rather than the predicate.
  assert !pc.contained?(kroot, "#{kroot}/a\0b"), 'a NUL byte fails closed'
  assert !pc.contained?(kroot, nil), 'a nil path fails closed'
  assert !pc.contained?(nil, kroot), 'a nil base fails closed'

  # An intermediate component that is a file, not a directory.
  assert !pc.contained?(kroot, File.join(kroot, KNOWLEDGE, "#{KNOWLEDGE}.md", 'x')),
         'a non-directory ancestor fails closed'

  # base == "/" would build the prefix "//" and match nothing.
  assert pc.contained?('/', '/etc'), 'root as base still contains its children'

  # safe_segment?: one ordinary directory name, nothing else
  assert pc.safe_segment?('loop_validation'), 'an ordinary name is a segment'
  assert pc.safe_segment?('a.b-c_1'), 'punctuation in a name is fine'
  ['.', '..', '', 'a/b', '/abs', "a\0b", nil, 42].each do |bad|
    assert !pc.safe_segment?(bad), "#{bad.inspect} is not a segment"
  end
end

# ============================================================================
# Section 8: admin static route (no authentication on this route)
#
# Each traversal is paired with the file it actually resolves to, and that file
# is asserted to exist first. STATIC_DIR is lib/kairos_mcp/admin/static, so
# three levels up is lib/ and four is the gem root.
# ============================================================================
puts "\n[Section 8] admin serve_static is bounded"

require 'kairos_mcp/admin/helpers'

class StaticProbe
  include KairosMcp::Admin::Helpers
end

probe = StaticProbe.new
static_dir = KairosMcp::Admin::Helpers::STATIC_DIR

# A "sub/../" prefix is deliberately absent: static/ has no subdirectory, so the
# OS cannot resolve a path through a component that does not exist, and the 404
# would come from the filesystem rather than from the guard. That case was in an
# earlier version and passed with the guards removed.
[
  ['../../../kairos_mcp.rb',        File.expand_path('lib/kairos_mcp.rb', __dir__)],
  ['../../../../Gemfile',           File.expand_path('Gemfile', __dir__)],
  ['../../admin/router.rb',         File.expand_path('lib/kairos_mcp/admin/router.rb', __dir__)]
].each do |f, resolves_to|
  assert File.file?(resolves_to), "precondition: #{f} must address an existing file (#{resolves_to})"
  status, = probe.serve_static(f)
  assert status == 404, "serve_static must refuse #{f}"
end

if Dir.exist?(static_dir)
  legit = Dir.children(static_dir).find { |f| File.file?(File.join(static_dir, f)) }
  if legit
    status, = probe.serve_static(legit)
    assert status == 200, 'serve_static must still serve a legitimate static file'
  end
end

# ============================================================================
# Section 9: an external SkillSet's knowledge is readable, never writable
#
# get(name) searches external SkillSet directories after the main store, and
# that is correct — it is how shipped knowledge is read. The mutators inherited
# that reach: update / archive / delete acted on whatever base_path get had
# resolved, so an ordinary name with no ".." and no symlink in it rewrote,
# moved or removed files belonging to an installed SkillSet.
# ============================================================================
puts "\n[Section 9] external SkillSet knowledge is read-only"

SHIPPED = 'shipped_entry'

def with_external_skillset
  Dir.mktmpdir do |tmp|
    kroot = File.join(tmp, 'knowledge')
    ext = File.join(tmp, 'skillset_pkg', 'knowledge')
    entry = File.join(ext, SHIPPED)
    FileUtils.mkdir_p(entry)
    FileUtils.mkdir_p(kroot)
    File.write(File.join(entry, "#{SHIPPED}.md"), frontmatter(SHIPPED))
    # An unrelated file beside the entry: rm_rf takes it too.
    File.write(File.join(entry, 'BYSTANDER.txt'), 'not part of the entry')

    kp = KairosMcp::KnowledgeProvider.new(kroot, vector_search_enabled: false,
                                                 include_skillset_knowledge: false)
    kp.add_external_dir(ext, source: 'skillset:test', only: [SHIPPED])
    yield kp, entry
  end
end

# Reading must keep working — the fix must not close the read path.
with_external_skillset do |kp, entry|
  skill = kp.get(SHIPPED)
  assert skill, 'external SkillSet knowledge must still be readable'
  assert skill.base_path == entry, 'precondition: get resolves into the external directory'
end

with_external_skillset do |kp, entry|
  md = File.join(entry, "#{SHIPPED}.md")
  before = File.read(md)
  r = kp.update(SHIPPED, "---\nname: #{SHIPPED}\ndescription: rewritten\n---\n\nATTACKER BODY\n")
  assert r[:success] == false, 'update must refuse an entry outside the knowledge store'
  assert File.read(md) == before, 'update must not have rewritten the SkillSet file'
end

with_external_skillset do |kp, entry|
  r = kp.delete(SHIPPED)
  assert r[:success] == false, 'delete must refuse an entry outside the knowledge store'
  assert File.directory?(entry), 'delete must not have removed the SkillSet directory'
  assert File.file?(File.join(entry, 'BYSTANDER.txt')), 'delete must not have taken the neighbouring file'
end

with_external_skillset do |kp, entry|
  r = kp.archive(SHIPPED, reason: 'test')
  assert r[:success] == false, 'archive must refuse an entry outside the knowledge store'
  assert File.directory?(entry), 'archive must not have moved the SkillSet directory out of the SkillSet'
  assert File.file?(File.join(entry, "#{SHIPPED}.md")), 'archive must have left the entry intact'
end

# ============================================================================
# Section 10: an entry's markdown file lives inside that entry's directory
#
# The parser picks the md file two ways — "<dirname>.md" by name, and the first
# *.md the glob finds. Either can be a symlink out of the store. ResourceRegistry
# defends its own read; the parser did not, so KnowledgeProvider#get and
# ContextManager#get_context returned out-of-store content.
# ============================================================================
puts "\n[Section 10] an entry's md file cannot point out of the entry"

Dir.mktmpdir do |tmp|
  begin
    secret = File.join(tmp, 'outside_secret.md')
    File.write(secret, "---\nname: stolen\ndescription: out of store\n---\n\nSECRET BODY\n")

    kroot = File.join(tmp, 'knowledge')

    # (a) the named branch: <entry>/<entry>.md is a symlink pointing out
    named = File.join(kroot, 'victim_named')
    FileUtils.mkdir_p(named)
    File.symlink(secret, File.join(named, 'victim_named.md'))

    # (b) the glob branch: no <entry>.md, so the parser takes the first *.md,
    #     which is a symlink pointing out
    globbed = File.join(kroot, 'victim_globbed')
    FileUtils.mkdir_p(globbed)
    File.symlink(secret, File.join(globbed, 'anything.md'))

    kp2 = KairosMcp::KnowledgeProvider.new(kroot, vector_search_enabled: false,
                                                  include_skillset_knowledge: false)

    assert File.read(File.join(named, 'victim_named.md')).include?('SECRET BODY'),
           'precondition: the named-branch symlink reaches the outside file'
    assert File.read(File.join(globbed, 'anything.md')).include?('SECRET BODY'),
           'precondition: the glob-branch symlink reaches the outside file'

    assert kp2.get('victim_named').nil?,
           'get must refuse an entry whose named md file points out of the entry'
    assert kp2.get('victim_globbed').nil?,
           'get must refuse an entry whose glob-found md file points out of the entry'
    assert kp2.list.none? { |e| e[:name] == 'stolen' },
           'list must not surface an entry read from outside the store'

    # The same shape at L2: a context whose md file is a symlink out.
    croot = File.join(tmp, 'context')
    cdir = File.join(croot, 'sess', 'victim_ctx')
    FileUtils.mkdir_p(cdir)
    File.symlink(secret, File.join(cdir, 'victim_ctx.md'))
    cm2 = KairosMcp::ContextManager.new(croot)
    assert cm2.get_context('sess', 'victim_ctx').nil?,
           'get_context must refuse a context whose md file points out of the entry'

    # A legitimate entry in the same store still reads.
    ok_dir = File.join(kroot, 'ok_entry')
    FileUtils.mkdir_p(ok_dir)
    File.write(File.join(ok_dir, 'ok_entry.md'), frontmatter('ok_entry'))
    assert kp2.get('ok_entry'), 'a legitimate entry must still be readable'
  rescue NotImplementedError, Errno::EPERM
    puts "\nSKIP: symlinks unavailable on this platform"
  end
end

# ============================================================================
# Section 11: the store's own reserved name is not an entry name
#
# ".archived" is where the L1 store keeps archived entries. Accepted as an
# ordinary name, it can be claimed on a fresh store before the archive
# directory first exists; a later delete of that "entry" then removes the whole
# archive and is recorded as the deletion of one entry.
# ============================================================================
puts "\n[Section 11] the archive directory is not an entry"

ARCHIVED = KairosMcp::KnowledgeProvider::ARCHIVED_DIR

Dir.mktmpdir do |tmp|
  kroot = File.join(tmp, 'knowledge')
  FileUtils.mkdir_p(kroot)
  kp3 = KairosMcp::KnowledgeProvider.new(kroot, vector_search_enabled: false,
                                                include_skillset_knowledge: false)

  r = kp3.create(ARCHIVED, frontmatter('claimed'))
  assert r[:success] == false, 'create must refuse the reserved archive name'
  assert !File.exist?(File.join(kroot, ARCHIVED, "#{ARCHIVED}.md")),
         'create must not have claimed the archive directory'
end

# The dangerous half, on a store where the name was claimed before this guard
# existed: the archive holds real entries and must survive.
#
# One store per call, for the reason given at the top of this file: with the
# guards off, `delete` empties the archive, and `update` and `archive` in the
# same store would then pass for want of anything left to damage.
def with_claimed_archive
  Dir.mktmpdir do |tmp|
    kroot = File.join(tmp, 'knowledge')
    archive = File.join(kroot, ARCHIVED)
    entry_md = File.join(archive, 'already_archived', 'already_archived.md')
    FileUtils.mkdir_p(File.dirname(entry_md))
    # Claimed by hand, the way a pre-guard store would look.
    File.write(File.join(archive, "#{ARCHIVED}.md"), frontmatter('claimed'))
    File.write(entry_md, frontmatter('already_archived'))

    kp = KairosMcp::KnowledgeProvider.new(kroot, vector_search_enabled: false,
                                                 include_skillset_knowledge: false)
    yield kp, archive, entry_md
  end
end

with_claimed_archive do |kp, archive, entry_md|
  assert File.file?(entry_md), 'precondition: the archive holds a real entry'
  r = kp.delete(ARCHIVED)
  assert r[:success] == false, 'delete must refuse the reserved archive name'
  assert File.directory?(archive), 'the archive directory must survive a delete'
  assert File.file?(entry_md), 'the archived entry must survive a delete'
end

with_claimed_archive do |kp, _archive, entry_md|
  before = File.read(File.join(File.dirname(entry_md), '..', "#{ARCHIVED}.md"))
  r = kp.update(ARCHIVED, frontmatter('rewritten'))
  assert r[:success] == false, 'update must refuse the reserved archive name'
  assert File.read(File.join(File.dirname(entry_md), '..', "#{ARCHIVED}.md")) == before,
         'update must not have rewritten anything in the archive'
end

# There is deliberately no `archive(".archived")` case here. It would move the
# archive directory into itself, which the filesystem refuses on its own, so the
# assertion would pass with every guard disabled and would measure nothing. The
# reserved-name guard still covers that call; it is simply not observable from a
# test, and a green assertion that cannot fail is worse than an absent one.

# ============================================================================
# Section 12: a mutation is bounded at every path it touches, not just at the
# entry it was addressed to
#
# `owned?` bounds base_path. `archive` then writes .archive_meta.yml and moves
# into the archive directory, and neither of those IS base_path — so an entry
# that passes every ownership check still carried two writes out of the store.
# ============================================================================
puts "\n[Section 12] archive and unarchive are bounded at every path they touch"

# (a) the metadata file inside an owned entry is a symlink pointing out
Dir.mktmpdir do |tmp|
  begin
    kroot = File.join(tmp, 'knowledge')
    entry = File.join(kroot, 'bait')
    outside = File.join(tmp, 'outside', 'pwn.yml')
    FileUtils.mkdir_p(File.dirname(outside))
    FileUtils.mkdir_p(entry)
    File.write(File.join(entry, 'bait.md'), frontmatter('bait'))
    File.write(outside, "untouched\n")
    File.symlink(outside, File.join(entry, '.archive_meta.yml'))

    kp5 = KairosMcp::KnowledgeProvider.new(kroot, vector_search_enabled: false,
                                                  include_skillset_knowledge: false)
    assert kp5.get('bait'), 'precondition: the entry is owned and readable'

    kp5.archive('bait', reason: 'INJECTED-REASON', superseded_by: 'INJECTED')
    assert File.read(outside) == "untouched\n",
           'archive must not write metadata through a symlink out of the store'
  rescue NotImplementedError, Errno::EPERM
    puts "\nSKIP: symlinks unavailable on this platform"
  end
end

# (b) the archive directory itself is a symlink pointing out. Containment asked
#     against THAT root would answer about the wrong directory.
Dir.mktmpdir do |tmp|
  begin
    kroot = File.join(tmp, 'knowledge')
    outside_archive = File.join(tmp, 'outside_archive')
    FileUtils.mkdir_p(outside_archive)
    victim = File.join(kroot, 'victim')
    FileUtils.mkdir_p(victim)
    File.write(File.join(victim, 'victim.md'), frontmatter('victim'))
    File.symlink(outside_archive, File.join(kroot, ARCHIVED))

    kp6 = KairosMcp::KnowledgeProvider.new(kroot, vector_search_enabled: false,
                                                  include_skillset_knowledge: false)

    r = kp6.archive('victim', reason: 'test')
    assert r[:success] == false, 'archive must refuse when the archive root escapes the store'
    assert File.directory?(victim), 'archive must not have moved the entry out of the store'
    assert Dir.children(outside_archive).empty?, 'nothing must have landed outside the store'

    # The reverse: an outside directory must not be brought in as L1 knowledge.
    foreign = File.join(outside_archive, 'foreign')
    FileUtils.mkdir_p(foreign)
    File.write(File.join(foreign, 'foreign.md'), frontmatter('foreign'))

    r2 = kp6.unarchive('foreign', reason: 'test')
    assert r2[:success] == false, 'unarchive must refuse when the archive root escapes the store'
    assert !File.exist?(File.join(kroot, 'foreign')), 'unarchive must not have brought an outside tree in'
    assert kp6.list.none? { |e| e[:name] == 'foreign' }, 'the outside tree must not be listed as L1'
  rescue NotImplementedError, Errno::EPERM
    puts "\nSKIP: symlinks unavailable on this platform"
  end
end

# (c) unarchive with a traversing name. This method moves AND deletes, and had
#     no assertion at all until R3 pointed that out.
Dir.mktmpdir do |tmp|
  # Nested one level so BOTH ends of an unguarded move stay inside this temp
  # directory. With the store at the top level, an unguarded unarchive sends the
  # tree to the system temp root, where it survives the run and makes the next
  # one pass for the wrong reason — the mutation run would poison itself.
  kroot = File.join(tmp, 'data', 'knowledge')
  outside_tree = File.join(tmp, 'data', 'storage')
  FileUtils.mkdir_p(File.join(kroot, ARCHIVED))
  FileUtils.mkdir_p(outside_tree)
  File.write(File.join(outside_tree, 'tokens.json'), SECRET)
  File.write(File.join(outside_tree, 'storage.md'), frontmatter('storage'))

  kp7 = KairosMcp::KnowledgeProvider.new(kroot, vector_search_enabled: false,
                                                include_skillset_knowledge: false)

  assert File.directory?(outside_tree), 'precondition: the outside tree exists and is parseable'

  r = kp7.unarchive('../../storage', reason: 'test')
  assert r[:success] == false, 'unarchive must refuse a traversing name'
  # The damage check is on the SOURCE. Asserting that nothing arrived in the
  # store is not the same claim: an unguarded move sends the tree to a
  # destination that is also outside, so the store stays empty either way.
  assert File.file?(File.join(outside_tree, 'tokens.json')),
         'unarchive must not have moved the outside tree'
  assert File.directory?(outside_tree), 'the outside tree must still be where it was'

  # The reserved name has to be present in the archive for its refusal to mean
  # anything: without this, "not found" answers before any guard does.
  FileUtils.mkdir_p(File.join(kroot, ARCHIVED, ARCHIVED))
  File.write(File.join(kroot, ARCHIVED, ARCHIVED, "#{ARCHIVED}.md"), frontmatter('claimed'))
  # The archive directory always exists, so a bare success:false here could come
  # from the "already exists" branch rather than from a guard. The reason is
  # asserted, the way it is for create.
  r2 = kp7.unarchive(ARCHIVED, reason: 'test')
  assert r2[:success] == false && r2[:error].to_s.include?('reserved'),
         'unarchive must refuse the reserved archive name as reserved, not as an existing entry'
  FileUtils.rm_rf(File.join(kroot, ARCHIVED, ARCHIVED))

  # ...and the legitimate round trip still works.
  kp7.create('round_trip', frontmatter('round_trip'))
  a = kp7.archive('round_trip', reason: 'test')
  assert a[:success] == true, 'a legitimate archive must still succeed'
  u = kp7.unarchive('round_trip', reason: 'test')
  assert u[:success] == true, 'a legitimate unarchive must still succeed'
  assert File.file?(File.join(kroot, 'round_trip', 'round_trip.md')),
         'the entry must be back in the store'
end

# ============================================================================
# Section 13: listing agrees with reading
#
# A listing that advertises what the read path refuses discloses the size and
# timestamp of files outside the store. ContextManager#context_dirs was given a
# containment filter; the L1 enumerators and ResourceRegistry's were not.
# ============================================================================
puts "\n[Section 13] enumeration is bounded the same way reading is"

Dir.mktmpdir do |tmp|
  begin
    data = File.join(tmp, 'data')
    kroot = File.join(data, 'knowledge')
    croot = File.join(data, 'context')
    outside_entry = File.join(tmp, 'outside', 'private_notes')
    FileUtils.mkdir_p(outside_entry)
    FileUtils.mkdir_p(kroot)
    FileUtils.mkdir_p(File.join(croot, 'sess'))
    File.write(File.join(outside_entry, 'private_notes.md'),
               "---\nname: private_notes\ndescription: CONFIDENTIAL-OUTSIDE\n---\n\nbody\n")

    legit = File.join(kroot, 'legit')
    FileUtils.mkdir_p(legit)
    File.write(File.join(legit, 'legit.md'), frontmatter('legit'))

    File.symlink(outside_entry, File.join(kroot, 'private_notes'))

    # The L2 half needs its own bait: the registry lists a context by looking
    # for "<name>.md" inside it, so a symlinked context directory is only
    # listable when that exact file exists there. Without this the assertion
    # below would pass with the filter removed — it would measure the missing
    # file, not the guard.
    outside_ctx = File.join(tmp, 'outside', 'private_ctx')
    FileUtils.mkdir_p(outside_ctx)
    File.write(File.join(outside_ctx, 'private_ctx.md'),
               "---\nname: private_ctx\ndescription: CONFIDENTIAL-OUTSIDE\n---\n\nbody\n")
    File.symlink(outside_ctx, File.join(croot, 'sess', 'private_ctx'))

    # ...and a legitimate context beside it, so the L2 listing is not empty for
    # an unrelated reason.
    legit_ctx = File.join(croot, 'sess', 'legit_ctx')
    FileUtils.mkdir_p(legit_ctx)
    File.write(File.join(legit_ctx, 'legit_ctx.md'), frontmatter('legit_ctx'))

    kp8 = KairosMcp::KnowledgeProvider.new(kroot, vector_search_enabled: false,
                                                  include_skillset_knowledge: false)
    names = kp8.list.map { |e| e[:name] }
    assert names.include?('legit'), 'the legitimate entry must still be listed'
    assert !names.include?('private_notes'),
           'list must not surface an entry that resolves outside the store'
    assert kp8.get('private_notes').nil?, 'precondition: get already refuses it'

    KairosMcp.data_dir = data
    reg2 = KairosMcp::ResourceRegistry.new
    uris = reg2.list.map { |r| r[:uri] }
    assert uris.include?('knowledge://legit'), 'the legitimate URI must still be listed'
    assert uris.none? { |u| u.include?('private_notes') },
           'resource_list must not surface an L1 entry that resolves outside the store'
    assert uris.include?('context://sess/legit_ctx'), 'the legitimate context must still be listed'
    assert uris.none? { |u| u.include?('private_ctx') },
           'resource_list must not surface an L2 context that resolves outside the store'
    assert reg2.read('context://sess/private_ctx').nil?, 'and the L2 read path refuses it too'
    assert reg2.read('knowledge://private_notes').nil?, 'and the read path still refuses it'

    # The archive directory is the store's own, not an entry.
    FileUtils.mkdir_p(File.join(kroot, ARCHIVED, 'gone'))
    File.write(File.join(kroot, ARCHIVED, "#{ARCHIVED}.md"), frontmatter('claimed'))
    reg3 = KairosMcp::ResourceRegistry.new
    # No listing assertion for the archive directory: Dir's "*" does not match a
    # leading dot, so it never appears there and the assertion could not fail.
    assert reg3.read("knowledge://#{ARCHIVED}").nil?,
           'resource_read must refuse the archive directory as an entry name'
  rescue NotImplementedError, Errno::EPERM
    puts "\nSKIP: symlinks unavailable on this platform"
  ensure
    KairosMcp.reset_data_dir!
  end
end

# ============================================================================
# Section 14: an entry's subdirectory listing does not reach outside it
# ============================================================================
puts "\n[Section 14] subdirectory listings are bounded"

Dir.mktmpdir do |tmp|
  begin
    data = File.join(tmp, 'data')
    croot = File.join(data, 'context')
    cdir = File.join(croot, 'sess', 'ctx')
    FileUtils.mkdir_p(cdir)
    File.write(File.join(cdir, 'ctx.md'), frontmatter('ctx'))

    outside_assets = File.join(tmp, 'outside_assets')
    FileUtils.mkdir_p(outside_assets)
    File.write(File.join(outside_assets, 'leak.txt'), SECRET)
    File.symlink(outside_assets, File.join(cdir, 'assets'))

    cm3 = KairosMcp::ContextManager.new(croot)
    assert cm3.list_assets('sess', 'ctx').empty?,
           'list_assets must not surface files outside the context'

    # A dangling symlink occupying a subdir name must not raise out of a method
    # whose contract is a result hash.
    File.symlink(File.join(tmp, 'nope'), File.join(cdir, 'scripts'))
    r = cm3.create_subdir('sess', 'ctx', 'scripts')
    assert r.is_a?(Hash) && r[:success] == false,
           'create_subdir must return a failure result rather than raising'
  rescue NotImplementedError, Errno::EPERM
    puts "\nSKIP: symlinks unavailable on this platform"
  end
end

# ============================================================================
# Section 15: reserved names, and a refusal that a caller can act on
# ============================================================================
puts "\n[Section 15] backup names are reserved too, and refusals are typed"

Dir.mktmpdir do |tmp|
  kroot = File.join(tmp, 'knowledge')
  FileUtils.mkdir_p(kroot)
  kp9 = KairosMcp::KnowledgeProvider.new(kroot, vector_search_enabled: false,
                                                include_skillset_knowledge: false)

  # Names matching the backup pattern are filtered out of every enumeration, so
  # an entry created under one would be recorded and retrievable while being
  # invisible to knowledge_list and to audit.
  r = kp9.create('stealth.bak.1', frontmatter('stealth'))
  assert r[:success] == false, 'create must refuse a name the store filters from listings'
  assert !File.exist?(File.join(kroot, 'stealth.bak.1')), 'and must not have created it'

  # A non-String name must produce a refusal, not a TypeError out of File.join.
  bad = kp9.create(42, frontmatter('x'))
  assert bad.is_a?(Hash) && bad[:success] == false, 'create must refuse a non-string name as a result, not an exception'
end

# An entry that exists but is not ours: the caller has to be able to tell the
# difference between "cannot write" and "does not exist", because the remedy
# differs — this is what promote-to-L1 decides on.
with_external_skillset do |kp, _entry|
  skill = kp.get(SHIPPED)
  assert skill, 'precondition: the external entry resolves'
  assert kp.owned?(skill) == false, 'owned? must report an external entry as not ours'
end

Dir.mktmpdir do |tmp|
  kroot = File.join(tmp, 'knowledge')
  FileUtils.mkdir_p(kroot)
  kp10 = KairosMcp::KnowledgeProvider.new(kroot, vector_search_enabled: false,
                                                 include_skillset_knowledge: false)
  kp10.create('mine', frontmatter('mine'))
  assert kp10.owned?(kp10.get('mine')) == true, 'owned? must report a main-store entry as ours'
end

KairosMcp.reset_data_dir!

puts "\n"
puts "#{@passes} passed, #{@failures} failed"
exit(@failures.zero? ? 0 : 1)
