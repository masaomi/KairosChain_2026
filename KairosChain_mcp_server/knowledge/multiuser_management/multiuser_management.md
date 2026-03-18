---
name: multiuser_management
description: "Multiuser SkillSet — multi-tenant user management with PostgreSQL, RBAC, and tenant isolation"
version: 1.0
layer: L1
tags: [documentation, readme, multiuser, postgresql, rbac, tenant, authentication]
readme_order: 4.8
readme_lang: en
---

## Multiuser: Multi-Tenant User Management

### What is Multiuser?

Multiuser is an opt-in SkillSet that adds multi-tenant user management to KairosChain with PostgreSQL-backed storage, RBAC (Role-Based Access Control), and tenant isolation. Each user gets their own PostgreSQL schema, ensuring complete data separation between tenants.

Multiuser is implemented as a SkillSet with 6 minimal generic hooks into KairosChain core (Option C architecture), preserving the principle that new capabilities are expressed as SkillSets rather than hard-coded infrastructure. The core modifications are backward-compatible — without the Multiuser SkillSet installed, KairosChain behaves identically to before.

### Architecture

```
KairosChain (MCP Server)
├── [core] L0/L1/L2 + private blockchain
│     ├── Backend.register()          ← Hook 1: Storage backend factory
│     ├── Safety.register_policy()    ← Hook 2: RBAC policy injection
│     ├── ToolRegistry.register_gate()← Hook 3: Authorization gate
│     ├── Protocol.register_filter()  ← Hook 4: Request filter pipeline
│     ├── TokenStore.register()       ← Hook 5: Token store factory
│     └── KairosMcp.register_path_resolver() ← Hook 6: Tenant path resolution
└── [SkillSet: multiuser] Multi-tenant user management
      ├── PgConnectionPool     ← Mutex-based PostgreSQL connection pool
      ├── PgBackend            ← Storage::Backend implementation for PostgreSQL
      ├── TenantManager        ← Schema creation, migrations, tenant lifecycle
      ├── UserRegistry         ← User accounts with auto-tenant provisioning
      ├── TenantTokenStore     ← PostgreSQL-backed token store
      ├── AuthorizationGate    ← Default-deny RBAC enforcement
      ├── RequestFilter        ← Tenant resolution from Bearer token
      └── tools/               ← 3 MCP tools
```

### Prerequisites

- **PostgreSQL** server (installed and running)
- **pg gem**: `gem install pg` (requires `libpq` — PostgreSQL client library)

On macOS with Homebrew:

```bash
brew install postgresql@16
brew services start postgresql@16
gem install pg
```

### Quick Start

#### 1. Install the Multiuser SkillSet

```bash
kairos-chain skillset install templates/skillsets/multiuser
```

#### 2. Configure PostgreSQL connection

Edit `.kairos/skillsets/multiuser/config/multiuser.yml`:

```yaml
postgresql:
  host: 127.0.0.1
  port: 5432
  dbname: kairoschain
  user: postgres
  password: ""
  pool_size: 5
  connect_timeout: 5

token_backend: postgresql
```

#### 3. Create the database and run migrations

```bash
createdb kairoschain
```

Then via MCP:

```
"Run multiuser migrations"
→ multiuser_migrate(command: "run")
```

#### 4. Create the first user

```
"Create an owner user named admin"
→ multiuser_user_manage(command: "create", username: "admin", role: "owner")
```

#### 5. Check status

```
"Check multiuser status"
→ multiuser_status()
```

### MCP Tools

| Tool | Description |
|------|-------------|
| `multiuser_status` | Diagnostic report: PostgreSQL connection, tenant count, user count |
| `multiuser_user_manage` | User lifecycle: `list`, `create`, `delete`, `update_role` |
| `multiuser_migrate` | Database migrations: `status`, `run`, `dry_run` |

### Core Hooks (Option C: Generic Hooks)

The Multiuser SkillSet registers 6 hooks into KairosChain core. These hooks are minimal, generic extension points — any SkillSet can use them, not just Multiuser.

| Hook | Core Class | Purpose |
|------|-----------|---------|
| 1 | `Storage::Backend.register` | Register `PgBackend` as the `'postgresql'` storage backend |
| 2 | `Safety.register_policy` | Inject RBAC policies for `can_modify_l0`, `can_modify_l1`, `can_modify_l2`, `can_manage_tokens` |
| 3 | `ToolRegistry.register_gate` | Authorization gate — default-deny check before every tool call |
| 4 | `Protocol.register_filter` | Tenant resolution from Bearer token in incoming requests |
| 5 | `Auth::TokenStore.register` | Register `TenantTokenStore` as the `'postgresql'` token backend |
| 6 | `KairosMcp.register_path_resolver` | Resolve `knowledge/` and `context/` paths per tenant |

All hooks support `unregister` for clean teardown.

### RBAC (Role-Based Access Control)

| Role | L0 (Core) | L1 (Knowledge) | L2 (Context) | Token Management |
|------|-----------|----------------|--------------|------------------|
| **owner** | Read/Write | Read/Write | Read/Write | Full access |
| **member** | Read only | Read/Write | Read/Write | No access |
| **guest** | Read only | Read only | Read/Write | No access |

### Graceful Degradation

Multiuser is designed to degrade gracefully at each level:

| Condition | Behavior |
|-----------|----------|
| pg gem not installed | `multiuser_status` returns `pg_gem_missing` with install instructions |
| PostgreSQL not running | `multiuser_status` returns `pg_server_unavailable` with setup guidance |
| PostgreSQL config error | `multiuser_status` returns `pg_error` with config file reference |
| Any unexpected error | Caught by `rescue StandardError`, logged with full context |

In all cases, the 3 Multiuser MCP tools remain registered and callable — they return diagnostic information instead of crashing. All other KairosChain tools (34 core tools) continue to function normally.

### Configuration

Configuration file: `.kairos/skillsets/multiuser/config/multiuser.yml`

```yaml
postgresql:
  host: 127.0.0.1          # PostgreSQL host
  port: 5432                # PostgreSQL port
  dbname: kairoschain       # Database name
  user: postgres            # Database user
  password: ""              # Database password
  pool_size: 5              # Connection pool size
  connect_timeout: 5        # Connection timeout (seconds)

token_backend: postgresql   # Token storage backend
```

Database schema uses `public` for shared tables (users, tokens, audit log) and `tenant_{id}` schemas for per-user data (blocks, action_logs, knowledge_meta).
