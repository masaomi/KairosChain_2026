# DSL/AST Source of Truth Policy

**Date**: 2026-02-25
**Status**: Adopted
**Scope**: DSL/AST Partial Formalization Layer (Phase 1+)

## Principle

> **Ruby DSL (`.rb` files) is the single source of truth for Skill definitions, including their formalized structural layer (`definition` blocks).**

JSON representations — whether produced by MCP tool responses, blockchain records, or serialized snapshots — are **derived outputs**, not authoritative sources.

## Rationale

### 1. Philosophical consistency

KairosChain's generative principle states:

> "Meta-level operations are expressed in the same structure as base-level operations."

Ruby DSL is the medium in which Skills define themselves, evolve themselves, and describe their own formalization decisions. Elevating JSON to source of truth would reduce definitions from *executable self-descriptions* to *inert data*, breaking the self-referential loop at the core of KairosChain's identity.

### 2. Expressiveness

The `definition` block uses Ruby's block syntax to capture partial formalization naturally:

```ruby
definition do
  constraint :explicit_enablement, required: true, condition: "evolution_enabled == true"
  node :review_judgment, type: :SemanticReasoning, prompt: "Human reviews the proposal"
end
```

JSON cannot express this without becoming a serialization format for Ruby semantics — at which point the DSL is the real source regardless.

### 3. MCP boundary provides language independence

The MCP protocol (JSON-RPC) already serializes tool results to JSON. Any LLM or non-Ruby client consuming KairosChain through MCP receives language-agnostic data automatically. There is no need for a separate JSON source of truth because **the protocol boundary already performs the translation**.

### 4. Maintenance simplicity

A single source eliminates synchronization problems. The derivation direction is always:

```
Ruby DSL (.rb)  →  runtime evaluation  →  JSON (MCP response / blockchain record)
```

Never the reverse.

## Implications

| Artifact | Role | Authoritative? |
|----------|------|---------------|
| `skills/*.rb` | Skill definition (content + definition + formalization_notes) | **Yes** |
| MCP tool output (JSON) | Derived view for LLM consumption | No |
| Blockchain records (JSON) | Immutable audit log of formalization decisions | No (historical record) |
| `DefinitionContext#to_h` | Programmatic serialization | No (derived) |

## Boundary condition

If the MCP server is reimplemented in a non-Ruby language, the new implementation must either:

1. Parse the Ruby DSL (e.g., via tree-sitter or subprocess evaluation), or
2. Consume a JSON intermediate representation exported from the canonical Ruby source

In either case, the `.rb` files remain authoritative. The JSON export would be a build artifact, not a co-equal source.

## Relation to existing principles

- **CLAUDE.md** ("This is why Ruby (DSL/AST) was chosen"): This policy makes the implied consequence explicit.
- **kairos.rb:137** ("The content layer is retained as the human-readable source of truth"): That statement addresses content vs. definition layers. This policy addresses the orthogonal question of representation format (Ruby vs. JSON).
