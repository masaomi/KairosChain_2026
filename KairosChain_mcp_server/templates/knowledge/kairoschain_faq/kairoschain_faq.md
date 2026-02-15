---
name: kairoschain_faq
description: Frequently asked questions and subtree integration guide
version: 1.0
layer: L1
tags: [documentation, readme, faq, subtree, integration]
readme_order: 6
readme_lang: en
---

## FAQ

### Q: Can LLMs automatically modify L1/L2?

**A:** Yes, LLMs can modify L1/L2 autonomously (or upon user request) using MCP tools.

| Layer | LLM Modification | Conditions |
|-------|------------------|------------|
| **L0** (kairos.rb) | Possible but strict | `evolution_enabled: true` + `approved: true` (human approval) + blockchain record |
| **L1** (knowledge/) | Possible | Hash-only blockchain record, no human approval required |
| **L2** (context/) | Free | No per-operation record, no approval required |

Note: `kairos.md` is read-only and cannot be modified by LLMs.

**StateCommit addendum**: Regardless of per-operation recording, [StateCommit](#q-what-is-statecommit-and-how-does-it-improve-auditability) can capture all layers (including L2) at commit points. Snapshots are stored off-chain; only hash references are recorded on-chain.

**Usage Examples:**
- L2: Temporarily save hypotheses during research with `context_save`
- L1: Persist project coding conventions with `knowledge_update`
- L0: Propose meta-skill changes with `skills_evolve` (human approval required)

---

### Q: How do I decide which layer to store knowledge in?

**A:** Use the built-in `layer_placement_guide` knowledge (L1) for guidance. Here's a quick decision tree:

```
1. Does this modify Kairos's own rules or constraints?
   → YES: L0 (requires human approval)
   → NO: Continue

2. Is this temporary or session-specific?
   → YES: L2 (freely modifiable, no per-operation recording; can be captured by StateCommit)
   → NO: Continue

3. Will this be reused across multiple sessions?
   → YES: L1 (hash reference recorded)
   → NO: L2
```

**Key principle:** When in doubt, start with L2 and promote later.

| Layer | Purpose | Typical Content |
|-------|---------|-----------------|
| L0 | Kairos meta-rules | Safety constraints, evolution rules |
| L1 | Project knowledge | Coding conventions, architecture docs |
| L2 | Temporary work | Hypotheses, session notes, experiments |

**Promotion pattern:** Knowledge can move up as it matures: L2 → L1 → L0

For detailed guidance, use: `knowledge_get name="layer_placement_guide"`

---

### Q: How do I maintain L1 knowledge health? How do I prevent L1 bloat?

**A:** Use the `l1_health_guide` knowledge (L1) and the `skills_audit` tool for periodic maintenance.

**Key Thresholds:**

| Condition | Threshold | Action |
|-----------|-----------|--------|
| Review recommended | 180 days without update | Run `skills_audit` check |
| Archive candidate | 270 days without update | Consider archiving |
| Dangerous patterns | Detected | Update or archive immediately |

**Recommended Audit Schedule:**

| Frequency | Commands |
|-----------|----------|
| Monthly | `skills_audit command="check" layer="L1"` |
| Monthly | `skills_audit command="recommend" layer="L1"` |
| Quarterly | `skills_audit command="conflicts" layer="L1"` |
| On issues | `skills_audit command="dangerous" layer="L1"` |

**Self-Check Checklist (from l1_health_guide):**

- [ ] **Relevance**: Is this knowledge still applicable?
- [ ] **Uniqueness**: Does similar knowledge already exist?
- [ ] **Quality**: Is the information accurate and up-to-date?
- [ ] **Safety**: Does it align with L0 safety constraints?

**Archive Process:**

```bash
# Review knowledge
knowledge_get name="candidate_knowledge"

# Archive with approval
skills_audit command="archive" target="candidate_knowledge" reason="Project completed" approved=true
```

For detailed guidelines, use: `knowledge_get name="l1_health_guide"`

---

### Q: What is Persona Assembly and when should I use it?

**A:** Persona Assembly is an optional feature that provides multi-perspective evaluation when promoting knowledge between layers or auditing knowledge health. It helps surface different viewpoints before human decision-making.

**Assembly Modes:**

| Mode | Description | Token Cost | Use Case |
|------|-------------|------------|----------|
| `oneshot` (default) | Single-round evaluation by all personas | ~500 + 300×N | Routine decisions, quick feedback |
| `discussion` | Multi-round facilitated debate | ~500 + 300×N×R + 200×R | Important decisions, deep analysis |

*N = number of personas, R = number of rounds (default max: 3)*

**When to use each mode:**

| Scenario | Recommended Mode |
|----------|------------------|
| L2 → L1 promotion | oneshot |
| L1 → L0 promotion | **discussion** |
| Archive decision | oneshot |
| Conflict resolution | **discussion** |
| Quick validation | oneshot (kairos only) |
| High-stakes decision | discussion (all personas) |

**Available personas:**

| Persona | Role | Bias |
|---------|------|------|
| `kairos` | Philosophy Advocate / Default Facilitator | Auditability, constraint preservation |
| `conservative` | Stability Guardian | Prefers lower-commitment layers |
| `radical` | Innovation Advocate | Favors action, accepts higher risk |
| `pragmatic` | Cost-Benefit Analyst | Implementation complexity vs. value |
| `optimistic` | Opportunity Seeker | Focuses on potential benefits |
| `skeptic` | Risk Identifier | Looks for problems and edge cases |
| `archivist` | Knowledge Curator | Knowledge freshness, redundancy |
| `guardian` | Safety Watchdog | L0 alignment, security risks |
| `promoter` | Promotion Scout | Identifies promotion candidates |

**Usage:**

```bash
# Oneshot mode (default) - single evaluation
skills_promote command="analyze" source_name="my_knowledge" from_layer="L1" to_layer="L0" personas=["kairos", "conservative", "skeptic"]

# Discussion mode - multi-round with facilitator
skills_promote command="analyze" source_name="my_knowledge" from_layer="L1" to_layer="L0" \
  assembly_mode="discussion" facilitator="kairos" max_rounds=3 consensus_threshold=0.6 \
  personas=["kairos", "conservative", "radical", "skeptic"]

# With skills_audit
skills_audit command="check" with_assembly=true assembly_mode="oneshot"
skills_audit command="check" with_assembly=true assembly_mode="discussion" facilitator="kairos"

# Direct promotion without assembly
skills_promote command="promote" source_name="my_context" from_layer="L2" to_layer="L1" session_id="xxx"
```

**Discussion mode workflow:**

```
Round 1: Each persona states position (SUPPORT/OPPOSE/NEUTRAL)
         ↓
Facilitator: Summarizes agreements/disagreements, identifies concerns
         ↓
Round 2-N: Personas respond to concerns (if consensus < threshold)
         ↓
Final Summary: Consensus status, recommendation, key resolutions
```

**Configuration defaults (from `audit_rules` L0 skill):**

```yaml
assembly_defaults:
  mode: "oneshot"           # Default mode
  facilitator: "kairos"     # Discussion moderator
  max_rounds: 3             # Maximum rounds in discussion
  consensus_threshold: 0.6  # 60% = early termination
```

**Important:** Assembly output is advisory only. Human judgment remains the final authority, especially for L0 promotions.

Persona definitions can be customized in: `knowledge/persona_definitions/`

---

### Q: Is API extension needed for team usage?

**A:** KairosChain now supports **Streamable HTTP transport** for remote/team access. For team usage, the following options are available:

| Method | Additional Implementation | Suitable Scale |
|--------|---------------------------|----------------|
| **Git sharing** | Not required | Small teams (2-5 people) |
| **SSH tunneling** | Not required | LAN teams (2-10 people) |
| **Streamable HTTP** | ✅ Available (`--http` flag) | Medium teams (5-20 people) |
| **MCP over SSE** | Not needed (Streamable HTTP replaces) | When remote connection is needed |

**Git sharing (simplest):**
```
# Manage knowledge/, skills/, data/blockchain.json with Git
# Each member runs the MCP server locally
# Changes are synced via Git
```

**SSH tunneling (LAN teams, no code changes required):**

For teams on the same LAN, you can connect to a remote MCP server via SSH. This requires no additional implementation — just SSH access to the server machine.

**Setup:**

1. Run the MCP server on a shared machine (e.g., `server.local`):
   ```bash
   # On the server machine
   cd /path/to/KairosChain_mcp_server
   # Server is ready (stdio-based, no daemon needed)
   ```

2. Configure MCP client to connect via SSH:

   **For Cursor (`~/.cursor/mcp.json`):**
   ```json
   {
     "mcpServers": {
       "kairos-chain": {
         "command": "ssh",
         "args": [
           "-o", "StrictHostKeyChecking=accept-new",
           "user@server.local",
           "cd /path/to/KairosChain_mcp_server && ruby bin/kairos-chain"
         ]
       }
     }
   }
   ```

   **For Claude Code:**
   ```bash
   claude mcp add kairos-chain ssh -- -o StrictHostKeyChecking=accept-new user@server.local "cd /path/to/KairosChain_mcp_server && ruby bin/kairos-chain"
   ```

3. (Optional) Use SSH key authentication for passwordless access:
   ```bash
   # Generate key if not exists
   ssh-keygen -t ed25519
   
   # Copy to server
   ssh-copy-id user@server.local
   ```

**SSH tunneling advantages:**
- No code changes or HTTP server implementation needed
- Uses existing SSH infrastructure and authentication
- Encrypted communication by default
- Works with stdio-based MCP protocol as-is

**SSH tunneling limitations:**
- Requires SSH access to the server machine
- Each client opens a new server process (no shared state between connections)
- For concurrent writes, use Git to sync `storage/blockchain.json` and `knowledge/`

**When Streamable HTTP is better:**
- Remote access beyond SSH reach (internet-facing)
- Bearer token authentication needed
- Integration with CI/CD or external systems
- See [Optional: Streamable HTTP Transport](#optional-streamable-http-transport-remoteteam-access) for setup details

---

### Q: Is a voting system needed for changes to kairos.rb or kairos.md in team settings?

**A:** It depends on team size and requirements.

**Current implementation (single approver model):**
```yaml
require_human_approval: true  # One person's approval is sufficient
```

**Features that may be needed for team operations:**

| Feature | L0 | L1 | L2 |
|---------|----|----|----| 
| Voting system | Recommended | Optional | Not needed |
| Quorum | Recommended | - | - |
| Proposal period | Recommended | - | - |
| Veto power | Depends | - | - |

**Tools needed in the future (not implemented):**
```
governance_propose    - Create change proposals
governance_vote       - Vote on proposals (approve/reject/abstain)
governance_status     - Check proposal voting status
governance_execute    - Execute proposals that exceed threshold
```

**Special nature of kairos.md:**

Since `kairos.md` corresponds to a "constitution," consensus building outside the system (GitHub Discussion, etc.) is recommended:

1. Propose via GitHub Issue / Discussion
2. Offline discussion with the entire team
3. Reach consensus by unanimity (or supermajority)
4. Manually edit and commit the file

---

### Q: How do I run local tests?

**A:** Run tests with the following commands:

```bash
cd KairosChain_mcp_server
ruby test_local.rb
```

Test coverage:
- Layer Registry operation verification
- List of 18 core MCP tools
- Resource tools (resource_list, resource_read)
- L1 Knowledge read/write
- L2 Context read/write
- L0 Skills DSL (6 skills) loading

After testing, artifacts (`context/test_session`) are created. Delete if not needed:
```bash
rm -rf context/test_session
```

---

### Q: What meta-skills are included in kairos.rb?

**A:** Currently 8 meta-skills are defined:

| Skill | Description | Modifiability |
|-------|-------------|---------------|
| `l0_governance` | L0 self-governance rules | Content only |
| `core_safety` | Safety foundation | Not modifiable (`deny :all`) |
| `evolution_rules` | Evolution rules definition | Content only |
| `layer_awareness` | Layer structure awareness | Content only |
| `approval_workflow` | Approval workflow with checklist | Content only |
| `self_inspection` | Self-inspection capability | Content only |
| `chain_awareness` | Blockchain awareness | Content only |
| `audit_rules` | Knowledge lifecycle audit rules | Content only |

The `l0_governance` skill is special: it defines which skills can exist in L0, implementing the Pure Agent Skill principle of self-referential governance.

See `skills/kairos.rb` for details.

---

### Q: How do I modify L0 skills? What is the procedure?

**A:** L0 modification requires a strict multi-step procedure with human oversight. This is intentional — L0 is the "constitution" of KairosChain.

**Prerequisites:**
- `evolution_enabled: true` in `skills/config.yml` (must be set manually)
- Session evolution count < `max_evolutions_per_session` (default: 3)
- Target skill is not in `immutable_skills` (`core_safety` cannot be modified)
- Change is permitted by the skill's `evolve` block

**Step-by-Step Procedure:**

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Human: Manually set evolution_enabled: true in config.yml    │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. AI: skills_evolve command="propose" skill_id="..." def="..." │
│    - Syntax validation                                          │
│    - l0_governance allowed_skills check                         │
│    - evolve rules check                                         │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. Human: Review with 15-item checklist (approval_workflow)     │
│    - Traceability (3 items)                                     │
│    - Consistency (3 items)                                      │
│    - Scope (3 items)                                            │
│    - Authority (3 items)                                        │
│    - Pure Agent Compliance (3 items)                            │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. AI: skills_evolve command="apply" ... approved=true          │
│    - Creates version snapshot                                   │
│    - Updates kairos.rb                                          │
│    - Records to blockchain                                      │
│    - Kairos.reload!                                             │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 5. Verify: skills_dsl_get, chain_history, chain_verify          │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 6. Human: Set evolution_enabled: false (recommended)            │
└─────────────────────────────────────────────────────────────────┘
```

**Key Points:**

| Aspect | Description |
|--------|-------------|
| **Enabling evolution** | Must be done manually (AI cannot change config.yml) |
| **Approval** | Human must verify 15-item checklist |
| **Recording** | All changes recorded on blockchain |
| **Rollback** | Use `skills_rollback` to restore from snapshot |
| **Immutable** | `core_safety` cannot be changed (`evolve deny :all`) |

**Adding a New L0 Skill Type:**

To add a completely new meta-skill type (e.g., `my_new_meta_skill`):

1. First, evolve `l0_governance` to add it to `allowed_skills` list
2. Then, use `skills_evolve command="add"` to create the new skill

Both steps require human approval and checklist verification.

**L1/L2 are NOT affected:**

| Layer | Tool | Human Approval | Evolution Enable |
|-------|------|----------------|------------------|
| **L0** | `skills_evolve` | Required | Required |
| **L1** | `knowledge_update` | Not required | Not required |
| **L2** | `context_save` | Not required | Not required |

L1 and L2 remain freely modifiable by AI as before.

---

### Q: What is L0 Auto-Check? How does it help with the 15-item checklist?

**A:** L0 Auto-Check is a feature that **automatically verifies mechanical checks** before L0 changes, reducing the human review burden.

**How it works:**

When you run `skills_evolve command="propose"`, the system automatically runs checks defined in the `approval_workflow` skill (which is part of L0). This keeps the check criteria self-referential (Pure Agent Skill compliant).

**Check Categories:**

| Category | Type | Items | Description |
|----------|------|-------|-------------|
| **Consistency** | Mechanical | 4 | In allowed_skills, not immutable, syntax valid, evolve rules |
| **Authority** | Mechanical | 2 | evolution_enabled, within session limit |
| **Scope** | Mechanical | 1 | Rollback possible |
| **Traceability** | Human | 2 | Reason documented, traceable to L0 rule |
| **Pure Compliance** | Human | 2 | No external deps, LLM-independent |

**Example Output:**

```
📋 L0 AUTO-CHECK REPORT
============================================================

✅ All 7 mechanical checks PASSED. 3 items require human verification.

### Consistency
✅ Skill in allowed_skills
   evolution_rules is in allowed_skills
✅ Skill not immutable
   evolution_rules is not immutable
✅ Ruby syntax valid
   Syntax is valid
✅ Evolve rules permit change
   Skill's evolve rules allow modification

### Authority
✅ Evolution enabled
   evolution_enabled: true in config
✅ Within session limit
   1/3 evolutions used

### Scope
✅ Rollback possible
   Version snapshots directory exists

### Traceability
✅ Reason documented
   Reason: Updating for clarity
⚠️ Traceable to L0 rule
   ⚠️ HUMAN CHECK: Verify this change can be traced to an explicit L0 rule.

### Pure Compliance
⚠️ No external dependencies
   ⚠️ HUMAN CHECK: Verify the change doesn't introduce external dependencies.
⚠️ LLM-independent semantics
   ⚠️ HUMAN CHECK: Would different LLMs interpret this change the same way?

------------------------------------------------------------
⚠️  3 item(s) require HUMAN verification.
    Review the ⚠️ items above before approving.
------------------------------------------------------------
```

**Benefits:**

| Without Auto-Check | With Auto-Check |
|-------------------|-----------------|
| Human verifies all 15 items | AI verifies 7 mechanical items |
| Easy to miss syntax errors | Syntax validated automatically |
| Manual l0_governance check | Automatic allowed_skills check |
| No structured report | Clear pass/fail report |

**Usage:**

```bash
# Include reason for better traceability
skills_evolve command="propose" skill_id="evolution_rules" definition="..." reason="Clarify evolution workflow"
```

**Pure Agent Skill Compliance:**

The check logic is defined **within L0** (in the `approval_workflow` skill's behavior block), not in external code. This means the criteria for checking L0 changes are themselves part of L0 — maintaining self-referential integrity.

---

### Q: How does KairosChain decide when to evolve its own skills? Is there a meta-skill for this?

**A:** **KairosChain intentionally does NOT include logic for deciding "when to evolve."** This decision is delegated to the human side (or the AI client interacting with humans).

**Current design responsibilities:**

| Responsibility | Owner | Details |
|----------------|-------|---------|
| **Evolution judgment (when/what)** | Human / AI client | Outside KairosChain |
| **Evolution constraints (allow/deny)** | KairosChain | Validated by internal rules |
| **Evolution approval** | Human | Explicit `approved: true` |
| **Evolution recording** | KairosChain | Automatically recorded on blockchain |

**What is already implemented:**
- ✅ Evolution constraints (`SafeEvolver`)
- ✅ Workflow (propose → review → apply)
- ✅ Layer structure (L0/L1/L2)
- ✅ 8 meta-skills definition

**What is NOT implemented (by design):**
- ❌ "When to evolve" decision logic
- ❌ Self-detection of capability gaps
- ❌ Recognition of learning opportunities
- ❌ Evolution trigger conditions

**Design rationale:**

This is intentional. From `kairos.md` (PHILOSOPHY-020 Minimum-Nomic):

| Approach | Problem |
|----------|---------|
| Completely fixed rules | No adaptation, system becomes obsolete |
| **Unrestricted self-modification** | **Chaos, no accountability** |

To avoid "unrestricted self-modification," KairosChain intentionally delegates evolution triggers to external actors. KairosChain serves as a **gatekeeper** and **recorder**, not an autonomous self-modifier.

**Future extensibility:**

If you want to add a meta-skill for "when to evolve," you could define something like:

```ruby
skill :evolution_trigger do
  version "1.0"
  title "Evolution Trigger Logic"
  
  evolve do
    allow :content      # Trigger conditions can be modified
    deny :behavior      # Decision logic itself is fixed
  end
  
  content <<~MD
    ## Evolution Trigger Conditions
    
    1. When the same error pattern occurs 3+ times
    2. When user explicitly says "remember this"
    3. When new domain knowledge is provided
    → Propose saving to L1
  MD
end
```

However, even with such a meta-skill, **final approval should remain with humans**. This is the core of KairosChain's safety design.

---

### Q: What is Skill-Tool Unification? Can I add MCP tools without editing Ruby files?

**A:** Yes! Skills in `kairos.rb` can now define MCP tools via the `tool` block. This unifies skills and tools in L0-B.

**How it works:**

```ruby
# In kairos.rb
skill :my_custom_tool do
  version "1.0"
  title "My Custom Tool"
  
  # Traditional behavior (for skill introspection)
  behavior do
    { capability: "..." }
  end
  
  # Tool definition (exposed as MCP tool)
  tool do
    name "my_custom_tool"
    description "Does something useful"
    
    input do
      property :arg, type: "string", description: "Argument"
      required :arg
    end
    
    execute do |args|
      # Tool implementation
      { result: process(args["arg"]) }
    end
  end
end
```

**Enable in config:**

```yaml
# skills/config.yml
skill_tools_enabled: true   # Default: false
```

**Key points:**
- Default is **disabled** (conservative)
- Adding/modifying tools requires editing `kairos.rb` (L0 constraints apply)
- Changes require human approval (`approved: true`)
- All changes are recorded on blockchain
- Aligns with Minimum-Nomic: "can change, but recorded"

**Why is this so strict?**

L0 (`kairos.rb`) is intentionally locked with **triple protection**:

| Protection | Setting | Effect |
|------------|---------|--------|
| 1 | `evolution_enabled: false` | Blocks any kairos.rb changes |
| 2 | `require_human_approval: true` | Requires explicit human approval |
| 3 | `skill_tools_enabled: false` | Skills not registered as tools |

**Important:** There is no MCP tool to modify `config.yml`. Even if an LLM is asked to "change these settings," it cannot — humans must manually edit `config.yml`.

This is by design: L0 corresponds to "constitution/law" in the legal analogy. It should rarely change. For frequent tool additions, consider:

- **Current limitation**: Only L0 supports `tool` blocks
- **Future possibility**: L1 tool definition support (lighter constraints, no human approval, hash-only recording)

For most use cases, **L0 tools should not need frequent changes**. The strict lock ensures system integrity.

---

### Q: What is the difference between adding tools via kairos.rb vs tools/ directory?

**A:** There are two ways to add MCP tools to KairosChain:

1. **Via `kairos.rb` (L0)**: Using the `tool` block in skill definitions
2. **Via `tools/` directory**: Adding Ruby files directly to `lib/kairos_mcp/tools/`

**Functional equivalence:** Both methods register MCP tools that can be called by LLMs.

**Key differences:**

| Aspect | `kairos.rb` (L0) | `tools/` directory |
|--------|------------------|-------------------|
| Addition method | Via `skills_evolve` tool | Manual file addition |
| Human approval | **Required** | Not required |
| Blockchain record | **Yes** (full record) | No |
| Activation | `skill_tools_enabled: true` | Always active |
| Under KairosChain management | **Yes** | No |

**Important:** Adding tools directly to `tools/` is **not via KairosChain**. It's a regular code change (tracked by git, but not audited by KairosChain's blockchain).

**Design intent:**

- **Core infrastructure** (`tools/`): Tools necessary for KairosChain itself to function. Should rarely change.
- **Extension tools** (`kairos.rb`): Custom tools added by users. Use when you want change history audited.

In other words:
- `kairos.rb` route: "Strict but auditable"
- `tools/` route: "Free but not audited"

**Future consideration:** L1 tool definition support may be added (lighter constraints, hash-only recording) for tools that are useful but don't need L0's strict controls.

---

### Q: Should KairosChain proactively recommend skill creation to the LLM?

**A:** **No. KairosChain should focus on "recording and constraining," not "recommending when to learn."** The logic for recommending skill creation should be delegated to the LLM/AI agent side (e.g., Cursor Rules, system_prompt).

**Why this separation?**

| Aspect | Implemented in KairosChain | Delegated to LLM/Agent |
|--------|---------------------------|------------------------|
| **Minimum-Nomic Principle** | "Changes should be rare and high-cost" | Agent decides when learning is valuable |
| **Separation of Concerns** | KairosChain = gatekeeper & recorder | LLM = decision-maker for learning triggers |
| **Customizability** | Same constraints for all users | Each user can configure different agent behaviors |
| **Prompt Injection Risk** | Recommendation logic could be attacked | Defense can be handled at agent level |

**KairosChain's role:**
- ✅ Record skill changes immutably
- ✅ Enforce evolution constraints (approval, layer rules)
- ✅ Provide tools for skill management
- ❌ Decide "when" or "what" to learn

**Recommended approach for proactive skill recommendations:**

Configure your AI agent (Cursor Rules, Claude system_prompt, etc.) to include:

```markdown
# Agent Learning Rules

## When to Recommend Skill Creation
- After solving a problem that required multiple iterations
- When the user says "I always forget..." or "This is a common pattern"
- When similar code patterns are generated repeatedly

## Recommendation Format
"I noticed [pattern]. Would you like me to capture this as a KairosChain skill?"

## Then use KairosChain tools:
- L2: `context_save` for temporary hypotheses
- L1: `knowledge_update` for project knowledge (hash-only record)
- L0: `skills_evolve` for meta-skills (requires human approval)
```

This keeps KairosChain as a **neutral infrastructure** while allowing each team/user to define their own learning policies at the agent level.

**Skill promotion triggers (same principle applies):**

KairosChain also does NOT automatically suggest skill promotion (L2→L1→L0). Configure your AI agent to suggest promotions:

```markdown
# Skill Promotion Rules (add to above)

## When to Suggest L2 → L1 Promotion
- Same context referenced 3+ times across sessions
- User says "this is useful" or "I want to keep this"
- Hypothesis validated through actual use

## When to Suggest L1 → L0 Promotion
- Knowledge governs KairosChain's own behavior
- Mature, stable pattern that shouldn't change often
- Team consensus reached (for shared instances)

## Promotion Suggestion Format
"This knowledge has been useful across multiple sessions. 
Would you like to promote it from L2 to L1?"

## Then use KairosChain tools:
- `skills_promote command="analyze"` - With Persona Assembly for deliberation
- `skills_promote command="promote"` - Direct promotion
```

---

### Q: What happens when skills or knowledge contradict each other?

**A:** Currently, KairosChain **does not have automatic contradiction detection** between skills/knowledge. This is a recognized limitation noted in the design paper.

**Why no automatic detection?**

KairosChain intentionally delegates "judgment" to external actors (LLM/human):

| KairosChain's Responsibility | Delegated to External |
|-----------------------------|----------------------|
| Record changes | Judge what to save |
| Enforce constraints | Judge content validity |
| Maintain history | Resolve contradictions |

**Current approach when contradictions occur:**

1. **Implicit layer priority**: `L0 (meta-rules) > L1 (project knowledge) > L2 (temporary context)` — lower layers take precedence
2. **LLM interpretation**: When multiple skills are referenced, the LLM interprets and mediates based on context
3. **Human resolution**: Important contradictions are resolved by humans updating the relevant skills

**Future possibility:**

Contradiction detection could be added as an L1 knowledge or L0 skill:

```markdown
# Contradiction Detection Skill (example)

## Detection Rules
- Same topic with different recommendations
- Conflicting constraint definitions
- Circular dependencies

## Resolution Flow
1. Warn user upon detection
2. Generate discussion via Persona Assembly
3. Human makes final decision
```

However, "what constitutes a contradiction" is itself a philosophical question, and KairosChain's current design intentionally does not make that judgment.

---

### Q: What is StateCommit and how does it improve auditability?

**A:** StateCommit is a feature that creates snapshots of all layers (L0/L1/L2) at specific "commit points" for improved auditability. Unlike individual skill change records, StateCommit captures the **entire system state** at a moment in time.

**Why StateCommit?**

| Existing Records | StateCommit |
|------------------|-------------|
| L0: Full blockchain transaction | Captures all layers together |
| L1: Hash reference only | Includes layer relationships |
| L2: No recording | Shows "why" via commit reason |

**Storage strategy:**
- **Off-chain**: Full snapshot JSON files in `storage/snapshots/`
- **On-chain**: Hash reference and summary only (prevents blockchain bloat)

**Commit types:**

| Type | Trigger | Reason |
|------|---------|--------|
| `explicit` | User calls `state_commit` | Required (user-provided) |
| `auto` | System detects trigger conditions | Auto-generated |

**Auto-commit triggers (OR conditions):**
- L0 change detected
- Promotion (L2→L1 or L1→L0) occurred
- Demotion/archive occurred
- Session end (when MCP server stops)
- L1 changes threshold (default: 5)
- Total changes threshold (default: 10)

**AND condition (empty commit prevention):**
Auto-commit only triggers if the manifest hash differs from the previous commit.

**Configuration (`skills/config.yml`):**

```yaml
state_commit:
  enabled: true
  snapshot_dir: "storage/snapshots"
  max_snapshots: 100

  auto_commit:
    enabled: true
    skip_if_no_changes: true  # AND condition

    on_events:
      l0_change: true
      promotion: true
      demotion: true
      session_end: true

    change_threshold:
      enabled: true
      l1_changes: 5
      total_changes: 10
```

**Usage:**

```bash
# Create explicit commit
state_commit reason="Feature complete"

# Check current status
state_status

# View commit history
state_history

# View specific commit details
state_history hash="abc123"
```

---

### Q: What happens when too many skills accumulate? Is there a cleanup mechanism?

**A:** KairosChain provides the `skills_audit` tool for knowledge lifecycle management across all layers.

**The `skills_audit` tool provides:**

| Command | Description |
|---------|-------------|
| `check` | Health check across L0/L1/L2 layers |
| `stale` | Detect outdated items (layer-specific thresholds) |
| `conflicts` | Detect potential contradictions between knowledge |
| `dangerous` | Detect patterns that may conflict with L0 safety |
| `recommend` | Get promotion/archive recommendations |
| `archive` | Archive L1 knowledge (human approval required) |
| `unarchive` | Restore from archive (human approval required) |

**Layer-specific staleness thresholds:**

| Layer | Threshold | Rationale |
|-------|-----------|-----------|
| L0 | No date check | Stability is a feature, not staleness |
| L1 | 180 days | Project knowledge should be periodically reviewed |
| L2 | 14 days | Temporary contexts should be cleaned up |

**Usage examples:**

```bash
# Run health check across all layers
skills_audit command="check" layer="all"

# Find stale L1 knowledge
skills_audit command="stale" layer="L1"

# Get recommendations for archiving and promotion
skills_audit command="recommend"

# Archive with Persona Assembly for deeper analysis
skills_audit command="check" with_assembly=true assembly_mode="discussion"

# Archive a stale knowledge item (requires human approval)
skills_audit command="archive" target="old_knowledge" reason="Unused for 1 year" approved=true
```

**Archive mechanism:**

- Archived knowledge is moved to `knowledge/.archived/` directory
- Archive metadata (reason, date, superseded_by) is stored in `.archive_meta.yml`
- Archived items are excluded from normal searches but can be restored
- All archive/unarchive operations are recorded on blockchain

**Human oversight:**

Archive and unarchive operations require explicit human approval (`approved: true`). This rule is defined in L0 `audit_rules` skill and is itself configurable (L0-B).

---

### Q: How do I fix a skill when it provides incorrect or outdated information?

**A:** KairosChain provides multiple tools for identifying and fixing problematic knowledge.

**Step 1: Identify issues with `skills_audit`**

```bash
# Check for dangerous patterns (safety conflicts)
skills_audit command="dangerous" layer="L1"

# Check for stale knowledge
skills_audit command="stale" layer="L1"

# Full health check with Persona Assembly
skills_audit command="check" with_assembly=true
```

**Step 2: Review and fix with knowledge tools**

| Tool | Purpose |
|------|---------|
| `knowledge_get` | Retrieve skill content for review |
| `knowledge_update command="update"` | Modify skill (recorded on blockchain) |
| `skills_audit command="archive"` | Archive if obsolete (human approval required) |

**Modification workflow:**

```
1. User: "That answer was wrong. Show me the skill you referenced."
2. LLM: Calls knowledge_get name="skill_name"
3. User: "The section about X is outdated. Fix it."
4. LLM: Proposes modified content
5. User: Approves changes
6. LLM: Calls knowledge_update command="update" content="..." reason="User feedback: outdated info"
```

**For obsolete knowledge (archive instead of delete):**

```bash
# Archive obsolete knowledge (preserves history, removes from active search)
skills_audit command="archive" target="outdated_skill" reason="Superseded by new_skill" approved=true

# Later, if needed, restore from archive
skills_audit command="unarchive" target="outdated_skill" reason="Still relevant" approved=true
```

**Dangerous pattern detection:**

The `skills_audit command="dangerous"` checks for:
- Language suggesting bypassing safety checks
- Hardcoded credentials or API keys
- Patterns that conflict with L0 `core_safety`

**Proactive maintenance:**

Configure your AI agent (Cursor Rules / system_prompt) to suggest periodic audits:

```markdown
# Skill Quality Rules

## Periodic Audit
- Run `skills_audit command="check"` monthly or when issues arise
- Review recommendations from `skills_audit command="recommend"`

## When User Reports Issues
1. Run `skills_audit command="dangerous"` to check for safety issues
2. Use `knowledge_get` to review the specific skill
3. Fix with `knowledge_update` or archive if obsolete
```

---

### Q: What are the advantages and disadvantages of using SQLite?

**A:** SQLite is an optional storage backend for team environments. Here's what you need to know:

**Advantages:**

| Advantage | Description |
|-----------|-------------|
| **Concurrent Access** | Built-in locking prevents data corruption when multiple users access simultaneously |
| **ACID Transactions** | Guarantees data integrity even during crashes |
| **WAL Mode** | Allows concurrent reads and writes (readers don't block writers) |
| **Single File** | Easy backup (just copy the `.db` file) |
| **No Server Required** | Unlike PostgreSQL/MySQL, no separate database server needed |
| **Fast Queries** | Indexed queries are faster than scanning JSON files |

**Disadvantages / Cautions:**

| Disadvantage | Description | Mitigation |
|--------------|-------------|------------|
| **External Dependency** | Requires `sqlite3` gem installation | Use file backend for simple deployments |
| **Network File System** | SQLite is NOT recommended on NFS/network drives | Use local disk or PostgreSQL for network storage |
| **Write Scalability** | Only one writer at a time (WAL helps but has limits) | Fine for small teams (2-10), consider PostgreSQL for larger |
| **Binary Format** | Cannot read data directly without tools | Use `Exporter` to create human-readable files |
| **Gem Updates** | Need to track `sqlite3` gem updates | Pin version in Gemfile, test before updating |

**When to Use SQLite:**

```
Individual use → File backend (default)
     │
     ▼
Small team (2-10 people)
  └─► SQLite backend ✓
     │
     ▼
Large team (10+ people)
  └─► PostgreSQL (future)
```

**Recovery from Issues:**

If SQLite database becomes corrupted or you encounter issues:

```ruby
# 1. Export current data (if possible)
KairosMcp::Storage::Exporter.export(
  db_path: "storage/kairos.db",
  output_dir: "storage/backup"
)

# 2. Delete corrupted database
# rm storage/kairos.db

# 3. Rebuild from files
KairosMcp::Storage::Importer.rebuild_from_files(
  db_path: "storage/kairos.db"
)
```

**Best Practices:**

1. **Regular Exports**: Periodically export to files for human-readable backups
2. **Version Pin**: Pin sqlite3 gem version in Gemfile
3. **Local Disk**: Always use local disk, not network drives
4. **Backup Strategy**: Backup both `.db` file AND exported files

---

### Q: How do I inspect SQLite data without SQL commands?

**A:** Use the built-in Exporter to create human-readable files:

```ruby
require_relative 'lib/kairos_mcp/storage/exporter'

# Export to human-readable JSON/JSONL files
KairosMcp::Storage::Exporter.export(
  db_path: "storage/kairos.db",
  output_dir: "storage/export"
)
```

This creates:
- `blockchain.json` - All blocks in readable JSON
- `action_log.jsonl` - Action logs (one JSON per line)
- `knowledge_meta.json` - Knowledge metadata
- `manifest.json` - Export information

You can then view these files with any text editor or JSON viewer.

**Note:** Knowledge content (`*.md` files) is always stored as files in `knowledge/` directory, regardless of storage backend. SQLite only stores metadata for faster queries.

---

### Q: What is Pure Agent Skill and why does it matter?

**A:** Pure Agent Skill is a design principle that ensures L0's semantic self-containment. It addresses a fundamental question: **How can an AI system govern its own evolution without external dependencies?**

**The Core Principle:**

> All rules, criteria, and justifications for modifying L0 must be explicitly described within L0 itself.

**What "Pure" means in this context:**

Pure does **not** mean:
- Complete absence of side effects
- Byte-level identical outputs

Pure **means**:
- Skill semantics don't change based on which LLM interprets them
- Meaning doesn't vary by who the approver is
- Meaning doesn't depend on execution history or time

**How KairosChain implements this:**

| Before | After |
|--------|-------|
| `config.yml` defined allowed L0 skills (external) | `l0_governance` skill defines this (self-referential) |
| Approval criteria were implicit | `approval_workflow` includes explicit checklist |
| Changes were possible without L0 awareness | L0 governs itself through its own rules |

**The `l0_governance` skill:**

```ruby
skill :l0_governance do
  behavior do
    {
      allowed_skills: [:core_safety, :l0_governance, ...],
      immutable_skills: [:core_safety],
      purity_requirements: { all_criteria_in_l0: true, ... }
    }
  end
end
```

This makes "what can be in L0" part of L0 itself, not external configuration.

**Theoretical Limits (Gödelian):**

Perfect self-containment is theoretically impossible due to:

1. **Halting Problem**: Cannot always mechanically verify if a change satisfies all criteria
2. **Meta-level Dependency**: The interpreter of L0 rules (code/LLM) exists outside L0
3. **Bootstrapping**: Initial L0 must be authored externally

KairosChain acknowledges these limits while aiming for **sufficient Purity**:

> If an independent reviewer, using only L0's documented rules, can reconstruct the justification for any L0 change, then L0 is sufficiently Pure.

**Practical Benefits:**

- **Auditability**: All governance criteria are in one place
- **Resistance to Drift**: Harder to accidentally break governance
- **Explicit Approval Criteria**: Human reviewers have a checklist
- **Self-documenting**: L0 explains itself

For full specification, see `skills/kairos.md` sections [SPEC-010] and [SPEC-020].

---

### Q: Why does KairosChain use Ruby, specifically DSL and AST?

**A:** KairosChain's choice of Ruby DSL/AST is not accidental but essential for self-modifying AI systems. A self-referential skill system must satisfy three constraints simultaneously:

| Requirement | Description | Ruby's Implementation |
|-------------|-------------|----------------------|
| **Static Analyzability** | Security verification before execution | `RubyVM::AbstractSyntaxTree` (standard library) |
| **Runtime Modifiability** | Add/modify skills during operation | `define_method`, `class_eval`, open classes |
| **Human Readability** | Specifications domain experts can read | Natural-language-like DSL syntax |

**Why these three matter for self-reference:**

KairosChain implements a unique self-referential structure where **skills are constrained by skills themselves**. For example, `evolution_rules` skill contains:

```ruby
evolve do
  allow :content
  deny :guarantees, :evolve, :behavior
end
```

This means "the rule about evolving cannot itself be evolved" — a bootstrap constraint that requires:
1. **Parsing** the rule definition (static analysis via AST)
2. **Evaluating** the constraint at runtime (metaprogramming)
3. **Understanding** what the rule means (human-readable DSL)

**Comparison with other languages:**

| Aspect | Lisp/Clojure | Ruby | Python | JavaScript |
|--------|-------------|------|--------|------------|
| **Homoiconicity (code=data)** | ○ Complete | × No | × No | × No |
| **Human readability** | △ S-expressions hard to read | ○ Natural | △ Brackets required | △ Syntax constraints |
| **AST tools in stdlib** | × Not needed but audit-hard | ○ Complete | △ Limited | △ External deps |
| **DSL expressiveness** | ○ | ○ | △ | △ |
| **Production ecosystem** | △ | ○ Proven (Rails, RSpec) | ○ | ○ |

**Theoretically optimal:** Lisp/Clojure (homoiconicity makes self-modification natural)  
**Practically optimal:** **Ruby** (balances readability + analyzability + evolvability)

**The decisive advantage — Separability:**

In KairosChain's self-referential system, the separation of **definition**, **analysis**, and **execution** is crucial:

```ruby
# 1. Definition: Human-readable
skill :evolution_rules do
  evolve { deny :evolve }  # Self-constraint
end

# 2. Analysis: Validate before execution
RubyVM::AbstractSyntaxTree.parse(definition)  # Static analysis

# 3. Execution: Evaluate constraint
skill.evolution_rules.can_evolve?(:evolve)  # => false
```

In Lisp, code=data blurs the boundary between "analysis" and "execution." While this provides freedom, achieving **auditability** requires additional mechanisms.

**Conclusion:** Given KairosChain's goal of "auditable AI skill evolution," Ruby is the **practical optimum** — not the only correct answer, but a realistic choice that satisfies all three constraints simultaneously.

---

### Q: What's the difference between using local skills vs. KairosChain?

**A:** AI agent editors (Cursor, Claude Code, Antigravity, etc.) typically provide a local skills/rules mechanism. Here's a comparison with KairosChain:

**Local Skills (e.g., `.cursor/skills/`, `CLAUDE.md`, agent rules)**

| Pros | Cons |
|------|------|
| Simple — just place files, ready to use | No change history — who/when/why is not tracked |
| Fast — direct file read, no MCP overhead | Too free — unintended modifications can occur |
| Native IDE integration | No layer concept — temporary hypotheses and permanent knowledge mix |
| Standard format (SKILL.md, etc.) | No self-reference — AI cannot inspect/explain its own skills |

**KairosChain (MCP server)**

| Pros | Cons |
|------|------|
| **Auditability** — all changes recorded on blockchain | MCP call overhead — slight latency |
| **Layered architecture** — L0 (meta-rules) / L1 (project knowledge) / L2 (temporary context) | Learning curve — must understand layers and tools |
| **Approval workflow** — L0 changes require human approval | Setup required — MCP server configuration |
| **Self-reference** — AI can inspect, explain, and evolve skills | Complexity — may be overkill for simple use cases |
| **Semantic search** — RAG-enabled meaning-based search | |
| **StateCommit** — system-wide snapshots at any point | |
| **Lifecycle management** — `skills_audit` for detecting/archiving stale knowledge | |

**Usage Guidelines:**

| Scenario | Recommendation |
|----------|----------------|
| Small personal project | Local skills |
| Audit/accountability required | KairosChain |
| Recording AI capability evolution | KairosChain |
| Team knowledge sharing | KairosChain (especially with SQLite backend) |
| Quick prototyping | Local skills → migrate to KairosChain when mature |

**The Essential Difference:**

- **Local Skills**: Function as "convenient documentation"
- **KairosChain**: Functions as an "auditable ledger of AI capability evolution"

KairosChain's philosophy:

> *"KairosChain answers not 'Is this result correct?' but 'How was this intelligence formed?'"*

If you just need to use skills, local skills are sufficient. However, if you need to **explain how the AI learned and evolved**, KairosChain is the appropriate choice.

**Hybrid Approach:**

You can use both simultaneously:
- Local skills for quick, informal knowledge
- KairosChain for knowledge that needs audit trails

KairosChain doesn't replace local skills — it provides an additional layer of auditability and governance when needed.

---

## Subtree Integration Guide

KairosChain_2026 is designed to be embedded into other projects using `git subtree`. This allows each project to:

- Receive framework updates from the upstream KairosChain_2026 repository
- Accumulate project-specific knowledge (L1) locally
- Keep everything in a single repository with no extra clone steps

> **Gem vs Subtree:** If you installed KairosChain as a gem (`gem install kairos-chain`), you do NOT need subtree setup. The gem approach and the subtree approach are independent installation methods. The subtree approach is for users who want the full source code embedded in their project repository. See the [Installation](#installation-gem-or-repository) section for details on the gem approach.

### Why Subtree (Not Submodule)

| Aspect | subtree | submodule |
|--------|---------|-----------|
| Local file additions | Managed naturally by parent repo | Complicated inside submodule |
| `git clone` for teammates | Just works (all files included) | Requires `git submodule init && update` |
| CI/CD | No special setup | Needs submodule initialization step |
| Knowledge accumulation | Commit directly to parent repo | Awkward cross-repo management |
| Accidental upstream push | Safe unless explicit `subtree push` | Easier to push to wrong remote |

### How It Works with KairosChain Layers

```
KairosChain_2026 (upstream)           YourProject (parent repo)
┌──────────────────────────┐          ┌─────────────────────────────────┐
│ L0: Framework code       │ subtree  │ server/                         │
│ L0: Meta-skills          │ --pull-> │   KairosChain_mcp_server/       │
│ L1: Generic templates    │          │     knowledge/                  │
│   example_knowledge/     │          │       example_knowledge/ <- sync│
│   persona_definitions/   │          │       persona_definitions/<-sync│
│                          │          │       your_project/   <- local  │
│                          │          │       your_tools/     <- local  │
│                          │          │     context/          <- L2     │
└──────────────────────────┘          └─────────────────────────────────┘
```

| Layer | Location | Managed By |
|-------|----------|------------|
| L0 (meta-skills, framework) | Upstream KairosChain_2026 | `subtree pull` syncs to all projects |
| L1 (project knowledge) | `knowledge/` in each project | Committed to parent repo only |
| L2 (session context) | `context/` | Ephemeral, gitignored |

### Setup: Adding KairosChain to a New Project

**Step 1: Add subtree**

```bash
git subtree add --prefix=server https://github.com/masaomi/KairosChain_2026 main --squash
```

**Step 2: Register remote (for convenience)**

```bash
git remote add mcp_server https://github.com/masaomi/KairosChain_2026
```

**Step 3: Configure .gitignore**

In `server/.gitignore`, add:

```gitignore
# Bundler
KairosChain_mcp_server/Gemfile.lock
KairosChain_mcp_server/.bundle/
KairosChain_mcp_server/vendor/

# L2 session context (ephemeral)
KairosChain_mcp_server/context/

# Vector search index files (auto-generated)
KairosChain_mcp_server/storage/embeddings/**/*.ann
KairosChain_mcp_server/storage/embeddings/**/*.json
!KairosChain_mcp_server/storage/embeddings/**/.gitkeep

# Action log
KairosChain_mcp_server/skills/action_log.jsonl
```

### Important: Data Directory Configuration for Subtree

Since the gemification update, KairosChain resolves data paths via `KairosMcp.data_dir`, which defaults to `.kairos/` in the current working directory. When using subtree, you **must** specify `--data-dir` to point to the existing data location inside the subtree, otherwise a new empty `.kairos/` directory will be created and your existing `skills/`, `knowledge/`, and `storage/` data will not be found.

**Cursor IDE (`mcp.json`):**

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "server/KairosChain_mcp_server/bin/kairos-chain",
      "args": ["--data-dir", "server/KairosChain_mcp_server"]
    }
  }
}
```

**Claude Code (`.mcp.json`):**

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "server/KairosChain_mcp_server/bin/kairos-chain",
      "args": ["--data-dir", "server/KairosChain_mcp_server"]
    }
  }
}
```

Alternatively, use the environment variable:

```bash
export KAIROS_DATA_DIR=server/KairosChain_mcp_server
```

> **Note:** If you previously ran without `--data-dir` and a `.kairos/` directory was auto-created, you can safely delete it. Your actual data remains in `server/KairosChain_mcp_server/`.

### Daily Operations

**Pull upstream updates:**

```bash
git subtree pull --prefix=server mcp_server main --squash
```

- Files from upstream are updated/merged
- Locally added files (project knowledge) are NOT affected
- If a file exists both locally and upstream with different content, a normal merge conflict occurs — resolve as usual

**Commit project-specific knowledge:**

```bash
# Knowledge files created by MCP server appear as untracked
git add server/KairosChain_mcp_server/knowledge/your_project/
git add server/KairosChain_mcp_server/storage/blockchain.json
git commit -m "Add project-specific knowledge"
```

These commits go to the **parent repo only** — upstream is never affected.

**Push to upstream (CAUTION):**

```bash
# Only if you want to contribute changes back to KairosChain_2026
# Usually NOT needed for project-specific files
git subtree push --prefix=server mcp_server main
```

> **Warning:** Do NOT push unless you intentionally want to send changes to the KairosChain_2026 repository. Project-specific knowledge should stay in the parent repo.

### Conflict Resolution

When `subtree pull` encounters a conflict:

```bash
$ git subtree pull --prefix=server mcp_server main --squash
# CONFLICT (add/add): Merge conflict in server/.../some_file.md

# 1. Open the conflicted file and resolve
# 2. Stage and commit
git add server/KairosChain_mcp_server/...
git commit -m "Resolve subtree merge conflict, keep local changes"
```

**Rule of thumb:** For project knowledge files, prefer local content over upstream content.

### Multi-Project Deployment Example

```
ProjectA/                           ProjectB/
├── .git/                           ├── .git/
└── server/ (subtree)               └── server/ (subtree)
    └── KairosChain_mcp_server/         └── KairosChain_mcp_server/
        ├── knowledge/                      ├── knowledge/
        │   ├── example_knowledge/ (shared) │   ├── example_knowledge/ (shared)
        │   ├── tool_a/       (A-specific)  │   ├── tool_b/       (B-specific)
        │   └── utils_a/      (A-specific)  │   └── utils_b/      (B-specific)
        └── storage/                        └── storage/
            └── blockchain.json (A-specific)    └── blockchain.json (B-specific)
```

Each project independently:
- Pulls framework updates from the same upstream
- Accumulates its own L1 knowledge
- Manages its own blockchain state

### After Subtree Pull: Template Updates

When you pull upstream updates that include changes to template files (`kairos.rb`, `kairos.md`, `config.yml`, etc.), those changes are applied directly to the subtree directory since it contains the full source. However, if you have modified these files locally, you may encounter merge conflicts during `subtree pull`.

For subtree users, the `system_upgrade` MCP tool and `kairos-chain upgrade` CLI command are **not needed** — the subtree pull mechanism itself handles file updates. The upgrade tooling is designed for **gem-based installations** where template files are bundled inside the gem and need to be migrated to the user's data directory.

**Summary of update methods:**

| Installation Method | How to Update | Template Handling |
|---|---|---|
| **Gem** (`gem install`) | `gem update kairos-chain` + `system_upgrade` tool | 3-way hash merge via `.kairos_meta.yml` |
| **Subtree** (`git subtree`) | `git subtree pull` | Standard git merge (resolve conflicts manually) |
| **Repository clone** | `git pull` | Standard git merge (resolve conflicts manually) |

### Reference

- Upstream: `https://github.com/masaomi/KairosChain_2026`
- Subtree prefix: `server/` (or your preferred path)
- Remote alias: `mcp_server`

---
