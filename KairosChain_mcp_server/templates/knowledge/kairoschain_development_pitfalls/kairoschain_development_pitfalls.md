---
title: KairosChain Development Pitfalls
description: Failure modes you cannot infer from reading the code — silent gem-packaging omissions, CWD-dependent data dir resolution, unreachable SkillSet-local knowledge, and return-shape traps. Read before adding a SkillSet, an L1 entry, or a tool.
version: "0.1.0"
tags:
  - development
  - pitfalls
  - packaging
  - data_dir
  - knowledge_provider
  - api
---

# KairosChain Development Pitfalls

## Scope

This entry holds only what **cannot be learned by reading the code you are about
to touch** — cases where the wrong choice fails silently, or where the failure
surfaces far from its cause. Everything that a reader can see for themselves in
the file they are editing is deliberately excluded.

Each item states the observable failure first, then the mechanism, then the rule.
Items are verified against the codebase at the version noted in § Verification.

Related entries (do not duplicate their content here):

- API shapes for tools and pools (`@safety`, `close_all`, the Safety policy
  pattern) → `skillset_implementation_quality_guide` § 5.
- Reviewer subprocess invocation traps (`--bare`, `[1m]` model-ID suffix) →
  `multi_llm_review_workflow`.

Machine-specific facts (Ruby version pins, local service ports, personal paths)
do **not** belong here. They are instance-local and belong in the operator's own
notes.

---

## 1. Only `templates/` reaches users. `knowledge/` does not ship

**Failure**: you add a SkillSet or an L1 knowledge entry, tests pass, the dev
instance sees it, you release the gem — and no user ever receives it. Nothing
errors.

**Mechanism**: the gemspec collects `lib/**/*.rb`, `lib/**/*.erb`, `bin/*`,
`templates/**/*`, `templates/**/.*`, and three top-level files. The dev-repo
`KairosChain_mcp_server/knowledge/` directory is not in that list, so it is
absent from the built gem. The dev repo keeps working because its own
`.kairos/knowledge/` was seeded earlier and is read directly.

**Rule**:

| Intent | Correct location |
|---|---|
| L1 entry every instance should have | `templates/knowledge/{name}/` |
| SkillSet distributed to all users | `templates/skillsets/{name}/` |
| Dev-repo-only scratch entry | `knowledge/{name}/` (accepting it ships nowhere) |

`templates/knowledge/` is the only distribution path: `kairos init` copies it into
a new instance, and `system_upgrade` 3-way merges it into an existing one.

**Live consequence**: `skillset_implementation_quality_guide` and
`kairoschain_meta_philosophy` exist only under `knowledge/`. They are therefore
unreachable by `knowledge_get` from any instance, including the dev instance —
even though other entries reference them as baseline reading.

## 2. `.kairos/` resolves against the current working directory

**Failure**: a script run from a subdirectory reports an empty knowledge layer, a
fresh blockchain, or missing skills — and then silently creates a second data
directory rather than failing.

**Mechanism**: `KairosMcp.data_dir` resolves in three steps — an explicit
`KairosMcp.data_dir =` assignment, then `KAIROS_DATA_DIR`, then `.kairos/` in the
process's current working directory. Nothing validates that the resolved
directory is the intended one, and `KnowledgeProvider#initialize` calls
`FileUtils.mkdir_p` on the knowledge dir, so a wrong resolution materialises as a
new empty tree instead of an error.

**Rule**: run Ruby directly from the project root, or set `KAIROS_DATA_DIR`
explicitly.

```
cd <project root> && ruby -I KairosChain_mcp_server/lib ...
```

Any `.kairos/` in a subdirectory, and any `KairosChain_mcp_server/storage/blockchain.json`,
is an artefact of this resolution rule, not a second legitimate store. Delete
such directories when found, after confirming the canonical root-level `.kairos/`
holds the real data.

## 3. Knowledge a SkillSet ships but does not declare is invisible

**Failure**: you add an entry under a SkillSet's `knowledge/`, it sits next to
entries that resolve fine, and `knowledge_get` reports "not found" for yours
alone.

**Mechanism**: `knowledge_dirs` in `skillset.json` is the declaration of what a
SkillSet contributes to L1, and only declared entries are exposed. Proximity on
disk is deliberately not a declaration — otherwise a SkillSet could widen the
knowledge layer by dropping a directory in place, without the manifest recording
that it did.

**Rule**: adding the directory is half the change; declaring it in
`knowledge_dirs` is the other half. When an entry resolves for a colleague and not
for you, compare the manifest before comparing the content.

`hestia` shipped `hestia_chain_migration` undeclared from its introduction until
2026-07-26, which is how this failure mode was found.

## 4. A truthy return is not necessarily a success

**Failure**: an authentication failure is treated as a successful
authentication, because the returned object is truthy.

**Mechanism**: `PlaceRouter#authenticate!` returns `{ peer_id:, auth_token: }` on
success and a Rack response triple `[status, headers, [body]]` on every failure
path (missing token, invalid token, rate limit). Both are truthy.

**Rule**: branch on the shape, not on truthiness. The correct pattern is already
in the caller:

```ruby
auth_result = authenticate!(env)
return auth_result if auth_result.is_a?(Array)   # failure — already a Rack response
peer_id = auth_result[:peer_id]
```

When writing any method that mixes a success payload with a pre-built error
response, document the two shapes at the definition site — the caller cannot
infer the convention from the call.

## 5. `instructions_mode` has silently reverted after upgrade

**Observation** (2026-07-03): after a `system_upgrade`, the active instruction
mode changed from `masa` to `tutorial` with no record of the change and no
message. It went unnoticed for roughly three weeks, during which the instance
operated without its instance constitution.

**Mechanism**: not established. The reverting write has not been isolated to a
specific code path, so no fix is claimed here and no cause should be quoted as
fact. Treat the behaviour as observed-and-unexplained.

**Rule**: after any `system_upgrade`, read back the active mode before continuing
work, and treat a mode change you did not request as an incident rather than a
cosmetic difference. A mode revert is not visible in the diff of any file the
upgrade reports touching.

A related class of bug — upgrade overwriting user-owned `config/` files — was
fixed in gem 3.52.2 by excluding existing `config/` from the upgrade diff, with a
regression test. That fix does not cover the mode revert.

---

## Verification

Facts in §§ 1–4 were verified by reading the current source: the gemspec file
list and `gem contents kairos-chain`; `KairosMcp.data_dir` resolution and
`KnowledgeProvider#initialize`; SkillSet knowledge registration against
`test_skillset_knowledge_registration.rb`; and `PlaceRouter#authenticate!` with
its call site.

An earlier § 3 recorded that SkillSet-bundled knowledge was unreachable
altogether — the manifest field was read by nothing, and per-call provider
construction discarded load-time registrations. That defect was fixed on
2026-07-26 by resolving `knowledge_dirs` at provider construction, so the item was
deleted per § Maintenance and replaced with the failure mode the fix leaves
behind.

§ 5 records an operational observation whose cause is not established; it is
marked as such deliberately rather than repaired with a plausible-sounding
mechanism.

## Maintenance

Add an item only when it meets the § Scope test: the failure is silent, or its
cause is remote from its symptom. When an item's underlying defect is fixed,
delete the item rather than annotating it as historical — a pitfalls list that
accumulates resolved entries stops being read.
