---
name: mcp_to_saas_development_workflow
description: Standard development workflow for evolving MCP-first prototypes into SaaS products with Backend API separation
version: "1.0"
layer: L1
tags: [architecture, workflow, development, saas, mcp, api, best-practice]
---

# MCP-to-SaaS Development Workflow

A phased approach for building products that start with KairosChain MCP tools as the core, then progressively separate Backend API and SaaS UI layers. This workflow is designed for teams (e.g., GenomicsChain) who want to validate ideas quickly through MCP-first prototyping and later scale into production SaaS products.

## Philosophy

**Start with MCP tools → Extract proven logic into API → Add SaaS UI → Integrate.**

The key insight is that MCP tools already encode validated business logic. Rather than designing an API from scratch (which risks mismatch with reality), we extract the API from working MCP tools. This ensures the API reflects actual usage patterns.

## The Four Phases

```
Phase 1: MCP-First MVP
  └─ All logic lives in MCP tools

Phase 2: API Extraction
  └─ Separate CRUD logic into Backend API
  └─ MCP tools become API wrapper + AI-native tools

Phase 3: SaaS UI
  └─ UI uses API directly for routine operations
  └─ UI uses MCP tool calls for AI-assisted operations

Phase 4: Integration & Optimization
  └─ Unified architecture with clear boundaries
```

## Phase 1: MCP-First MVP

### Goal

Validate the core functionality using KairosChain MCP tools. All business logic lives in MCP tools, accessed via MCP clients (Cursor, Claude Code, etc.).

### Architecture

```
┌──────────────────────────┐
│  MCP Client (Cursor etc) │
│         ↓ MCP protocol   │
│  KairosChain MCP Server  │
│  (all logic in tools)    │
│         ↓                │
│  File System / SQLite    │
└──────────────────────────┘
  + htmx admin UI (same process, optional)
```

### Key Activities

- Implement domain logic as MCP tools (inheriting `BaseTool`)
- Define L0 skill-tools in DSL for dynamic/experimental operations
- Use Streamable HTTP transport for remote/team access
- Add a lightweight admin UI (htmx) for basic management
- Validate with real users via MCP clients

### Exit Criteria

- Core operations are working and validated by users
- Tool boundaries are well understood
- You can identify which tools are pure CRUD vs. AI-dependent

## Phase 2: API Extraction

### Goal

Separate deterministic business logic into a Backend API. MCP tools that wrap CRUD operations become thin API wrappers. Tools that inherently require AI reasoning remain as MCP tools.

### Architecture

```
┌──────────────┐     ┌──────────────┐
│  MCP Client  │     │ Backend API  │
│      ↓       │     │  (CRUD)      │──→ DB
│  MCP Tools   │     └──────────────┘
│  ├─ Wrappers ────→ API calls
│  └─ AI-native│ (tools that need LLM stay as-is)
└──────────────┘
```

### The Critical Decision: API-able vs. MCP-native

For each existing MCP tool, ask: **"Does this tool fundamentally require LLM reasoning, or is it a deterministic operation?"**

| Classification | Description | Example Tools |
|---------------|-------------|---------------|
| **API-able** | Deterministic CRUD, read-only queries, standard management ops | `knowledge_update` (create/delete), `chain_status`, `chain_history`, `token_manage`, `resource_list`, `resource_read` |
| **Partially API-able** | Core operation is CRUD, but some modes need AI | `skills_evolve` (apply/reset → API; propose → MCP), `context_save` (save → API; content generation → MCP) |
| **MCP-native** | Inherently requires LLM reasoning or multi-step AI interaction | `skills_audit` (Persona Assembly), `skills_promote` (multi-perspective analysis), semantic search with reasoning |

### Key Activities

- Extract the Provider/Manager layer (e.g., `KnowledgeProvider`, `ContextManager`, `Chain`) into API service endpoints
- Rewrite API-able MCP tools as thin wrappers that call the Backend API
- Keep MCP-native tools unchanged
- For partially API-able tools, split: deterministic paths call API, AI paths remain in MCP
- Design API authentication (transition from Bearer tokens to OAuth/JWT if needed)

### Implementation Pattern

```ruby
# Before (Phase 1): MCP tool does everything
class KnowledgeUpdate < BaseTool
  def call(arguments)
    KnowledgeProvider.create(name, content, reason)  # direct file/DB access
  end
end

# After (Phase 2): MCP tool wraps API
class KnowledgeUpdate < BaseTool
  def call(arguments)
    api_client.post("/api/v1/knowledge", {
      name: arguments["name"],
      content: arguments["content"],
      reason: arguments["reason"]
    })
  end
end
```

### Exit Criteria

- Backend API is running and serves all deterministic operations
- MCP tools for CRUD are now API wrappers
- MCP-native tools remain functional
- Both MCP clients and API clients can perform deterministic operations

## Phase 3: SaaS UI

### Goal

Add a user-facing SaaS UI that leverages both the Backend API (for routine operations) and MCP tool calls (for AI-assisted operations that cannot be handled by conventional deterministic processing alone).

### Architecture

```
┌──────────────┐     ┌──────────────────┐
│  MCP Client  │     │     SaaS UI      │
│      ↓       │     │    ↓         ↓   │
│  MCP Tools   │     │ API direct  MCP   │
│  ├─ Wrappers ────→ │ calls      calls │
│  └─ AI-native│     └──────────────────┘
│      ↓       │           ↓
│  Backend API ←───────────┘
│      ↓       │
│     DB       │
└──────────────┘
```

### Two Interaction Patterns in the SaaS UI

#### Pattern A: API Direct Calls (Routine Operations)

Standard web application interactions with no AI involvement:

- Browsing knowledge entries, chain history, token lists
- Creating/updating/deleting resources via forms
- Dashboard and monitoring views
- User management and settings

These are conventional CRUD operations handled by the Backend API.

#### Pattern B: MCP Tool Calls (AI-Assisted Operations)

Operations where AI reasoning is essential and deterministic API calls alone are insufficient:

- Skill evolution proposals (requires LLM analysis)
- Multi-perspective audits (Persona Assembly)
- Semantic search with context-aware reasoning
- Automated knowledge promotion analysis
- Natural language pipeline generation (e.g., GenomicsChain)

The SaaS UI invokes these via MCP protocol, which routes to MCP-native tools.

### Key Activities

- Build SaaS frontend (e.g., Next.js, or framework of choice)
- Implement conventional CRUD pages using Backend API
- Implement AI-assisted features using MCP tool calls
- Design UX that clearly distinguishes routine vs. AI-assisted operations
- Handle MCP response streaming for AI operations

### Exit Criteria

- SaaS UI is functional for both routine and AI-assisted operations
- Users can perform all operations through the UI
- The boundary between API-direct and MCP-call is clear in the UX

## Phase 4: Integration & Optimization

### Goal

Unify the architecture, optimize performance, and establish clear operational boundaries.

### Architecture

```
┌───────────────────────────────────┐
│  MCP Clients      SaaS UI        │
│      ↓             ↓        ↓    │
│  MCP Tools     API direct  MCP   │
│  (AI-native)   (CRUD)     calls  │
│      ↓             ↓        ↓    │
│      Backend API (unified)       │
│              ↓                   │
│             DB                   │
└───────────────────────────────────┘
```

### Key Activities

- Optimize API performance (caching, connection pooling, etc.)
- Consolidate authentication (unified OAuth/JWT across API and MCP)
- Add monitoring and observability
- Document the final architecture for team onboarding
- Consider scaling strategies (horizontal API scaling, MCP server federation)
- Blockchain recording strategy: decide if API-side or MCP-side records

### Exit Criteria

- Stable, production-ready system
- Clear documentation for operators and developers
- Monitoring and alerting in place

## Leveraging Existing KairosChain Abstractions

The current KairosChain architecture already provides useful seams for this workflow:

| Existing Abstraction | Role in This Workflow |
|---------------------|----------------------|
| `BaseTool` interface (`name`, `description`, `input_schema`, `call`) | Tool implementations can be swapped without affecting MCP clients |
| `Storage::Backend` (FileBackend, SqliteBackend) | Add `ApiBackend` for Phase 2 API integration |
| Provider/Manager layer (`KnowledgeProvider`, `ContextManager`, `Chain`) | Directly extractable as API service layer |
| L0 skill-tool DSL (`execute` block) | Repoint to API calls by updating DSL definition |
| `ToolRegistry` dynamic registration | Swap tool implementations at runtime if needed |

## Anti-Patterns to Avoid

### "Big Bang API Design"

**Problem:** Designing the entire Backend API upfront before validating with MCP tools.

**Why it fails:** API designed in isolation often mismatches real usage patterns.

**Solution:** Follow this workflow — let MCP tool usage inform API design.

### "Force Everything into API"

**Problem:** Trying to make every MCP tool into an API endpoint, including AI-native ones.

**Why it fails:** AI-native operations don't fit REST conventions well. Forcing them into API creates awkward async polling patterns.

**Solution:** Keep the MCP-native / API-able distinction. Some operations belong in MCP permanently.

### "Premature SaaS UI"

**Problem:** Building the SaaS UI before the API is stable.

**Why it fails:** API changes cascade into UI rewrites.

**Solution:** Phase 2 (API extraction) must reach exit criteria before Phase 3 begins.

### "Ignoring the Admin UI"

**Problem:** Skipping the htmx admin UI in Phase 1 because "we'll have a SaaS UI later."

**Why it fails:** You lose visibility into system state during the critical MVP validation period.

**Solution:** Build a lightweight admin UI in Phase 1. It can be retired or kept as an internal tool.

## Applicability

This workflow is designed for projects that:

- Use KairosChain as their knowledge and agent framework
- Need to evolve from developer-oriented MCP tools to user-facing SaaS products
- Have operations that span both deterministic (CRUD) and AI-assisted (LLM) domains
- Want to validate core functionality before investing in full SaaS infrastructure

### GenomicsChain Example

```
Phase 1: MCP tools for NFT minting, pipeline execution, data management
Phase 2: REST API for dataset CRUD, pipeline status, NFT management
         MCP tools remain for: AI-guided pipeline selection, semantic data search
Phase 3: Web UI for researchers (browse datasets, run pipelines, manage NFTs)
         AI features: natural language pipeline configuration, automated QC
Phase 4: Production platform with unified auth, monitoring, scaling
```

---

*This guide is stored in L1 because it documents a reusable development workflow applicable across KairosChain-based projects. It does not govern KairosChain's own rules (which would require L0).*
