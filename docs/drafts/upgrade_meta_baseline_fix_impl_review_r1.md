# Implementation review R1 — `.kairos_meta.yml` baseline is written from the wrong side

Ruby 3.4, minitest. Repository: KairosChain. Gem: `kairos-chain` 3.58.1 (this fix
targets 3.58.2). Change size: one file, 13 insertions / 5 deletions, plus one new
test file.

## Review spec (pre-declared, frozen for this round)

**Pass condition.** APPROVE requires that the change, as written, restores the
invariant in §1 without breaking the four classifications in §2, and that the new
test would fail if the change were reverted.

**P0-eligible target.** Only these two files:

- `KairosChain_mcp_server/lib/kairos_mcp/tools/system_upgrade.rb` (the diff in §3)
- `KairosChain_mcp_server/test_upgrade_meta_baseline.rb` (the new test, §4)

**Appendix — advisory only, not P0.** Everything else: `upgrade_analyzer.rb`,
`initializer.rb`, the rest of `system_upgrade.rb`, the release process, and the
surrounding SkillSet-upgrade code. Findings against these are recorded and queued,
not fixed in this loop.

**Already ruled, out of scope — re-proposing these is advisory, not P0:**

1. *No migration/repair step for instances whose stored baseline already points at
   their own file.* Such an instance takes at most one more wrong overwrite after
   installing this fix, then stabilises. A `baseline_source` provenance marker was
   considered and declined by the operator on 2026-08-03.
2. *The L1 `knowledge_hashes` writer is fixed in the same change*, deliberately —
   same defect, same one-line shape, eight lines away.
3. *No change to `UpgradeAnalyzer`.* The reader is correct; only the writer was wrong.

**Fix cap.** At most 5 fixes in the following round, each stating what it newly
claims.

**Threshold.** Roster 4 (orchestrator excluded), rule `3/4 APPROVE`. If findings
are exhausted without reaching it, the loop closes by operator freeze declaration.

## 1. The invariant

`.kairos_meta.yml` stores `template_hashes` and `knowledge_hashes`. These are the
**common ancestor** of a three-way comparison performed by `UpgradeAnalyzer` on
every gem upgrade:

```
stored baseline (the gem template the user's file descends from)
   |
   +-- vs the instance file  .kairos/skills/config.yml      -> user_modified?
   +-- vs the gem template   templates/skills/config.yml    -> template_changed?

  !user_modified && !template_changed -> unchanged
  !user_modified &&  template_changed -> auto_updatable  (file is OVERWRITTEN)
   user_modified && !template_changed -> user_modified    (file is kept)
   user_modified &&  template_changed -> conflict         (structural YAML merge)
```

`Initializer#write_meta` writes this baseline from the template side, and has done
so since the feature was introduced (commit `ea10f2b`, never since modified).
`SystemUpgrade#update_meta` — which rewrites the same baseline at the end of every
`upgrade --apply` — wrote it from the **instance file** instead.

**Consequence.** After any upgrade, the baseline equals the instance file. On the
following upgrade `user_modified` is necessarily false, so a user-edited file whose
template differs is classified `auto_updatable` and silently overwritten.

**Observed.** `skills/config.yml` carries `instructions_mode`. The instance value
`masa` reverted to the template value `tutorial` five times between 2026-06-09 and
2026-08-03, with no record on the audit chain (the supported path,
`instructions_update set_mode`, does record). The first occurrence went unnoticed
for three weeks. The triggering condition is *the previous upgrade reported KEPT*:
a protected run is what arms the next one, which is why it looks intermittent.

Measured on the live instance 2026-08-03, before the fix:

| value | sha256 (first 8) |
|---|---|
| stored baseline for `skills/config.yml` | `9aee181d` |
| gem template `templates/skills/config.yml` | `9aee181d` — identical |
| instance `.kairos/skills/config.yml` (mode `masa`) | `97e475f3` |

Blast radius is not only `instructions_mode`: all eight entries of
`KairosMcp::TEMPLATE_FILES` take this path, `config/safety.yml` included.

## 2. What must keep working

The four classifications above, unchanged. In particular a genuine new gem template
must still reach `auto_updatable` when the user has not edited the file, and a
`config_yaml` conflict must still route to the structural merge.

## 3. The change

```diff
--- a/KairosChain_mcp_server/lib/kairos_mcp/tools/system_upgrade.rb
+++ b/KairosChain_mcp_server/lib/kairos_mcp/tools/system_upgrade.rb
@@ -738,20 +738,28 @@ module KairosMcp
         meta['template_hashes'] = {}
         meta['knowledge_hashes'] = {}
 
-        # Record current state of all L0 template files in data directory
-        KairosMcp::TEMPLATE_FILES.each do |template_name, accessor|
-          path = KairosMcp.send(accessor)
+        # Record the gem template each L0 file now descends from.
+        #
+        # These hashes are the common ancestor of UpgradeAnalyzer's three-way
+        # comparison, so they must come from the template side. Hashing the
+        # user's own file here collapses the ancestor onto one side: on the next
+        # upgrade `user_modified` is necessarily false, and a user-modified file
+        # is classified auto_updatable and overwritten. Mirrors
+        # Initializer#write_meta, which has always hashed the template.
+        KairosMcp::TEMPLATE_FILES.each do |template_name, _accessor|
+          path = File.join(KairosMcp.templates_dir, template_name)
           if File.exist?(path)
             meta['template_hashes'][template_name] =
               "sha256:#{Digest::SHA256.file(path).hexdigest}"
           end
         end
 
-        # Record current state of L1 knowledge (hash the main .md file)
+        # Record L1 knowledge templates (hash the main .md file). Same ancestor
+        # rule as above — the template side, not the user's copy.
         knowledge_templates_dir = File.join(KairosMcp.templates_dir, 'knowledge')
         if File.directory?(knowledge_templates_dir)
           Dir.children(knowledge_templates_dir).sort.each do |name|
-            md_path = File.join(KairosMcp.knowledge_dir, name, "#{name}.md")
+            md_path = File.join(knowledge_templates_dir, name, "#{name}.md")
             if File.exist?(md_path)
               meta['knowledge_hashes'][name] =
                 "sha256:#{Digest::SHA256.file(md_path).hexdigest}"
```

`update_meta` is called once, at the end of `handle_apply`, after all file actions
and after `UpgradeAnalyzer#analyze` has already classified everything. It has no
other caller.

Note the resulting timing: within a single `apply`, analysis reads the *old*
baseline and `update_meta` then writes the *new* one. So the first upgrade after
installing this fix still classifies using whatever the old code stored.

## 4. The new test

`KairosChain_mcp_server/test_upgrade_meta_baseline.rb`, 6 tests, 12 assertions.
It drives the real `Initializer`, the real `update_meta` (via `send`, it is
private), and the real `UpgradeAnalyzer`; the classification logic is not
re-implemented in the test. A fake gem templates directory is substituted with
`KairosMcp.stub(:templates_dir, ...)` and the data directory is a `Dir.mktmpdir`.

```ruby
  def test_update_meta_records_the_gem_template_not_the_user_file
    with_templates do
      init!
      set_mode('masa')

      update_meta!('9.9.9')

      assert_equal template_hash(CONFIG), meta['template_hashes'][CONFIG],
                   'baseline must be the gem template the user file descends from'
      refute_equal user_hash(CONFIG), meta['template_hashes'][CONFIG],
                   'baseline must not be rebuilt from the user file'
    end
  end

  def test_user_modification_survives_repeated_upgrades
    with_templates do
      init!
      set_mode('masa')

      # Each cycle mirrors handle_apply: analyze first, then update_meta.
      # The gem template is untouched across cycles, so every cycle must
      # classify the file as user_modified. Before the fix, cycle 1 passed
      # and cycle 2 reported :auto_updatable — the observed alternation.
      3.times do |i|
        assert_equal :user_modified, pattern(CONFIG),
                     "cycle #{i + 1}: user-modified config must be kept"
        update_meta!("9.9.#{i}")
      end

      assert_equal 'masa', YAML.safe_load(File.read(user_path(CONFIG)))['instructions_mode']
    end
  end

  def test_knowledge_user_modification_survives_repeated_upgrades
    with_templates do
      init!
      File.write(user_knowledge_path, "# demo\n\nedited by the user\n")

      3.times do |i|
        assert_equal :user_modified, knowledge_status(KNOWLEDGE),
                     "cycle #{i + 1}: user-modified knowledge must be kept"
        update_meta!("9.9.#{i}")
      end
    end
  end

  def test_genuine_template_change_still_auto_updates
    with_templates do
      init!
      update_meta!('9.9.0')          # user has not touched config.yml
      bump_template(CONFIG, 'tutorial', extra: "new_key: 1\n")

      assert_equal :auto_updatable, pattern(CONFIG)
    end
  end

  def test_both_sides_changed_is_a_conflict
    with_templates do
      init!
      set_mode('masa')
      update_meta!('9.9.0')          # arms the defect: baseline was rebuilt here
      bump_template(CONFIG, 'tutorial', extra: "new_key: 1\n")

      assert_equal :conflict, pattern(CONFIG),
                   'user edit + template change must reach the structural merge, not auto-update'
    end
  end

  def test_untouched_file_is_unchanged
    with_templates do
      init!
      update_meta!('9.9.0')

      assert_equal :unchanged, pattern(CONFIG)
    end
  end
```

Helpers, for completeness:

```ruby
  def init!
    initializer = KairosMcp::Initializer.new(quiet: true)
    initializer.send(:create_directories)
    initializer.send(:copy_templates)
    initializer.send(:copy_knowledge_templates)
    initializer.send(:write_meta)
  end

  def update_meta!(version)
    KairosMcp::Tools::SystemUpgrade.new.send(:update_meta, version)
  end

  def analyzer
    a = KairosMcp::UpgradeAnalyzer.new
    a.analyze
    a
  end

  def pattern(template_name)       = analyzer.results[template_name][:pattern]
  def knowledge_status(name)       = analyzer.knowledge_results[name][:status]
  def with_templates(&block)       = KairosMcp.stub(:templates_dir, @templates_dir, &block)
  def meta                         = YAML.safe_load(File.read(KairosMcp.meta_path))
```

(The four one-line helpers above are written as ordinary `def ... end` methods in
the file; they are compressed here for reading only.)

`setup` deletes `ENV['KAIROS_DATA_DIR']`, calls `KairosMcp.reset_data_dir!`, builds
the fake templates, and sets `KairosMcp.data_dir = <tmp>/data`; `teardown` restores
the env var, resets again, and removes the tmpdir.

## 5. Evidence

| run | result |
|---|---|
| new test against the **unfixed** code | 6 runs, 8 assertions, **4 failures**. `test_user_modification_survives_repeated_upgrades` failed at **cycle 2** with `:auto_updatable`; the knowledge test failed at cycle 2 with `:updated`; `test_both_sides_changed_is_a_conflict` returned `:auto_updatable`; the baseline test returned the instance file's hash |
| `raise` inserted at the top of `update_meta`, test re-run | every test that calls `update_meta` errored with `RuntimeError: SEAM PROBE` — the test does drive the real method rather than passing incidentally. The probe was reverted afterwards. (Output was truncated at 5 matching lines, so the exact error count was not read; all 6 tests call `update_meta`) |
| new test against the **fixed** code | 6 runs, 12 assertions, 0 failures |
| `test_local.rb`, `test_skillset_manager.rb`, `test_08_hestia_adapter.rb`, `test_09_meeting_place.rb` | no new failures |
| `test_p2p_skillset_exchange.rb` | 1 failure, `FAIL: MMP has 7 tool classes`. Confirmed pre-existing by re-running under `git stash`; unrelated to this change |

The observed cycle-2 flip matches the failure pattern recorded from production
across five occurrences, which is the reason the test runs three cycles rather
than one.

## 6. Questions I want answered

1. Is there any caller or code path, other than `handle_apply`, that depends on
   `update_meta` recording the instance file's state? (I found none; `update_meta`
   has one caller.)
2. Does writing the template hash unconditionally — including for a template that
   is absent from the instance directory — create a wrong classification on the
   next run? See the `unless result[:user_exists]` early return in
   `UpgradeAnalyzer#analyze_file`.
3. `update_meta` rebuilds `template_hashes` and `knowledge_hashes` from scratch
   (`meta['template_hashes'] = {}`) on every call. With the fix, an entry for a
   template that the gem has since removed disappears from the baseline. Is that
   the wanted behaviour, or should stale entries be preserved?
4. Is the three-cycle loop in the two "survives repeated upgrades" tests the right
   shape, or would an explicit two-phase assertion be clearer about *which* cycle
   used to break?
