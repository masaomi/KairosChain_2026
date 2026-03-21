---
name: skillset_implementation_quality_guide
description: Guidelines for implementing SkillSets with quality — design constraint tests, wiring checklists, verification methods per artifact type, and lessons from multi-LLM review experiments
version: 1.0
layer: L1
tags: [skillset, implementation, testing, quality, workflow, TDD, review, best-practice]
---

# SkillSet Implementation Quality Guide

## 1. Design Review vs Implementation Review

Design review and implementation review discover categorically different bug classes. Both are necessary; neither substitutes for the other.

| Review Type | Finds | Cannot Find |
|-------------|-------|-------------|
| Design review | Architectural gaps, missing enforcement paths, protocol-level races, threat model holes | Method name typos, sentinel value confusion, API misuse, dead code wiring |
| Implementation review | Code logic errors, fail-open defaults, resource leaks, namespace mismatches, test gaps | Architectural flaws already baked into the design |

Evidence (Service Grant v1.4 experiment):
- Design review (3 rounds, 3 LLMs): 8 P0/P1 architectural issues
- Implementation review (1 round, 3 LLMs): 6 FAIL + 5 CONCERN code bugs
- Zero overlap between the two sets

## 2. Three Artifact Types and Their Verification

KairosChain SkillSets produce three types of artifacts. Each requires a different verification approach.

### 2.1 Ruby Code (lib/, tools/)

**Verification**: Design Constraint Tests (selective TDD) + unit tests + implementation review

**Workflow**:
1. Extract MUST/MUST NOT conditions from design doc
2. Write constraint tests BEFORE implementation (5-10 tests)
3. Implement the code
4. Add happy-path unit tests AFTER implementation
5. Run implementation review

**When to write tests first** (selective TDD):
- Security invariants: "fail-closed", "denied", "owner-only"
- Sentinel value semantics: nil vs -1 vs 0
- Access control rules

**When NOT to write tests first**:
- Happy paths, internal details, formatting, performance
- These are tested after implementation (standard testing)

**Example** — design says "removed plan = BLOCKED":
```ruby
# Write BEFORE implementing try_consume:
def test_unknown_plan_is_denied
  refute tracker.try_consume(hash, service: 's', action: 'a', plan: 'nonexistent')
end
```

### 2.2 Configuration (YAML, JSON — config/, skillset.json)

**Verification**: Schema validation tests + load tests

Configuration files cannot be TDD'd, but can be validated programmatically.

**Essential config test** — verifies tool registration will work:
```ruby
def test_skillset_json_tool_classes_resolvable
  json = JSON.parse(File.read(File.join(__dir__, '..', 'skillset.json')))
  Dir[File.join(__dir__, '..', 'tools', '*.rb')].each { |f| require f }
  json['tool_classes'].each do |cls|
    assert Object.const_get(cls), "Tool class #{cls} not found"
  end
end
```

**YAML config test** — verifies services and plans are well-formed:
```ruby
def test_config_services_valid
  config = YAML.safe_load(File.read(config_path))
  config['services'].each do |name, svc|
    assert_includes %w[per_action metered subscription free], svc['billing_model']
    assert svc['plans']&.any?, "Service #{name} has no plans"
  end
end
```

**Common config bugs caught by tests**:
- `skillset.json` namespace mismatch (Service Grant FIX-4)
- Missing required fields in YAML
- Invalid enum values

### 2.3 Knowledge / Markdown (knowledge/, docs/)

**Verification**: Meta-validation (lint-like checks) + review

Markdown skills cannot be TDD'd. Instead, use structural validation:

- Referenced file paths exist
- Referenced SkillSets are in `depends_on`
- Code examples in the markdown are syntactically valid
- Internal links resolve

**This is not testing but linting** — checking structural consistency rather than behavioral correctness.

**For LLM-instructional markdown** (skills.md, guides):
- Validation is through **usage**: does an LLM following the instructions produce correct results?
- This is inherently a review/feedback process, not automatable via TDD

## 3. Implementation Workflow (Recommended)

```
[1] Design Phase (high effort, multi-LLM review)
      |
[2] Extract Design Constraints → Write constraint tests (5-10 tests)
      |
[3] Write config validation test (skillset.json, YAML)
      |
[4] Implement in batches of 3-5 files
      |-- After each batch: run tests, check wiring
      |
[5] Write happy-path + edge-case unit tests
      |
[6] Run wiring checklist
      |
[7] Multi-LLM implementation review
      |
[8] Fix plan → Fix → Re-review (if needed)
```

Steps 2 and 3 are the key additions vs. the standard "design then implement" workflow. They take ~15 minutes but prevent the most dangerous bug class (design-implementation semantic inversions).

## 4. Wiring Checklist

Run after implementation, before review:

- [ ] Every object created in `load!` is used in the request path
- [ ] Every `register_policy` has a corresponding `can_X?` call in a tool
- [ ] Every `register_gate` / `register_filter` has a corresponding `unregister_*` in `unload!`
- [ ] `unload!` method names match the actual API (e.g., `close_all` not `close`)
- [ ] `skillset.json` `tool_classes` match actual `Module::Class` paths
- [ ] Tool files use `@safety` (from BaseTool), NOT `@user_context`
- [ ] Sentinel values: nil = "unknown/denied", -1 = "unlimited", 0+ = "limit"
- [ ] No `'default'` fallback strings for service/plan that don't exist in config

## 5. KairosChain-Specific API Patterns

### Safety Policy Pattern
```ruby
# In SkillSet load!:
KairosMcp::Safety.register_policy(:can_do_x) do |user|
  next true if user.nil?        # STDIO: always allowed
  next true if user[:local_dev] # local dev: always allowed
  user[:role] == 'owner'        # HTTP: owner only
end

# In Safety class (core — add instance method):
def can_do_x?
  return true unless @current_user
  policy = self.class.policy_for(:can_do_x)
  policy ? policy.call(@current_user) : false  # default deny for admin ops
end

# In tool call():
unless @safety&.can_do_x?
  return format_result({ error: 'forbidden', message: 'Owner role required' })
end
```

### BaseTool API Reference
- Constructor: `def initialize(safety = nil)` — stores as `@safety`
- User context: `@safety&.current_user` (NOT `@user_context`)
- Pubkey: `@safety&.current_user&.dig(:pubkey_hash)`
- Existing methods: `can_manage_tokens?`, `can_modify_l0?`, `can_modify_l1?`, `can_modify_l2?`

### PgConnectionPool API
- Cleanup: `close_all` (NOT `close`)
- Query: `exec_params(sql, params)`
- Transaction-safe: `with_connection { |conn| ... }`

## 6. Implementation Batch Size

Single-pass implementation of 20+ files causes context decay — later files forget API details of earlier files. "Wiring" between components is the most error-prone step.

Recommended:
- **3-5 files per batch** for interconnected components
- **Run tests after each batch**
- Order: core domain (errors, config) -> business logic (managers, trackers) -> enforcement (gates, middleware) -> tools

## 7. Bug Taxonomy

For post-mortem classification when bugs are found:

| Category | Example | Prevention |
|----------|---------|------------|
| Sentinel confusion | nil treated as unlimited | Design constraint test |
| API mismatch | `close` vs `close_all` | Wiring checklist |
| Dead code | Circuit breaker never called | Wiring checklist |
| Policy gap | Registered but never checked | Wiring checklist |
| Namespace error | skillset.json vs actual class | Config validation test |
| Edge case | Parameterized route segments | Implementation review |
| Info leak | peer_id in error message | Implementation review |
| Config-code mismatch | `'default'` service not in YAML | Design constraint test |
