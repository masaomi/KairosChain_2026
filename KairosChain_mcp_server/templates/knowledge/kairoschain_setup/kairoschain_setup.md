---
name: kairoschain_setup
description: "KairosChain installation, configuration, and testing guide"
version: 1.0
layer: L1
tags: [documentation, readme, setup, installation, configuration, testing]
readme_order: 2
readme_lang: en
---

## Setup

### Prerequisites

- Ruby 3.0+ (uses standard library only, no gems required for basic functionality)
- Claude Code CLI (`claude`) or Cursor IDE

### Installation

KairosChain can be installed either as a **Ruby gem** (recommended) or by **cloning the repository**.

#### Option A: Install as a Gem (Recommended)

```bash
# Install the gem
gem install kairos_mcp

# Initialize data directory (creates .kairos/ in current directory)
kairos_mcp_server init

# Or initialize at a specific path
kairos_mcp_server init --data-dir /path/to/my-kairos-data

# Test basic execution
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | kairos_mcp_server
```

The gem ships with zero runtime dependencies. Optional features (SQLite, RAG, HTTP) can be added by installing additional gems — see the Optional sections below.

**Data directory resolution** (priority order):
1. `--data-dir` CLI option
2. `KAIROS_DATA_DIR` environment variable
3. `.kairos/` in the current working directory

#### Option B: Clone the Repository

```bash
# Clone the repository
git clone https://github.com/masaomi/KairosChain_2026.git
cd KairosChain_2026/KairosChain_mcp_server

# Make executable
chmod +x bin/kairos_mcp_server

# Test basic execution
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | bin/kairos_mcp_server
```

> **Note**: When running from the repository, the data directory defaults to `.kairos/` in the current working directory. The server will auto-initialize on first run if the data directory doesn't exist.

### Optional: RAG (Semantic Search) Support

KairosChain supports optional semantic search using vector embeddings. This enables finding skills by meaning rather than exact keyword matches (e.g., searching "authentication" can find skills about "login" or "password").

**Without RAG gems:** Regex-based keyword search (default, no installation required)  
**With RAG gems:** Semantic vector search using sentence embeddings

#### Requirements

- C++ compiler (for native extensions)
- ~90MB disk space (for embedding model, downloaded on first use)

#### Installation

```bash
# If using the gem:
gem install hnswlib informers

# If using the repository with Bundler:
cd KairosChain_mcp_server
bundle install --with rag
```

#### Gems Used

| Gem | Version | Purpose |
|-----|---------|---------|
| `hnswlib` | ~> 0.9 | HNSW approximate nearest neighbor search |
| `informers` | ~> 1.0 | ONNX-based sentence embeddings |

#### Supported Layers

| Layer | Target | RAG Support | Index Path |
|-------|--------|-------------|------------|
| **L0** | `skills/kairos.rb` (meta-skills) | Yes | `storage/embeddings/skills/` |
| **L1** | `knowledge/` (project knowledge) | Yes | `storage/embeddings/knowledge/` |
| **L2** | `context/` (temporary context) | No | N/A (regex search only) |

L2 is excluded because temporary contexts are short-lived and typically few in number, making regex search sufficient.

#### Configuration

RAG settings in config (at `<data-dir>/config/config.yml` for gem, or `skills/config.yml` for repo):

```yaml
vector_search:
  enabled: true                                      # Enable if gems available
  model: "sentence-transformers/all-MiniLM-L6-v2"    # Embedding model
  dimension: 384                                     # Must match model
  index_path: "storage/embeddings"                   # Index storage path
  auto_index: true                                   # Auto-rebuild on changes
```

#### Installing RAG Later

If you install RAG gems after already using KairosChain:

1. Install the gems: `bundle install --with rag` or `gem install hnswlib informers`
2. **Restart the MCP server** (reconnect in Cursor/Claude Code)
3. On first search, the index is automatically rebuilt from all skills/knowledge
4. Initial model download (~90MB) and embedding generation will take some time

**Why this works:** The `@available` flag is checked at server startup and cached. FallbackSearch (regex-based) does not persist any index data. When switching to SemanticSearch, the `ensure_index_built` method triggers a full `rebuild_index` on first use, creating embeddings for all existing skills and knowledge.

**What happens to existing data:**
- Skills and knowledge files: Unchanged (source of truth)
- Vector index: Created fresh from current content
- No migration needed: FallbackSearch → SemanticSearch is seamless

#### Verification

```bash
# Check if RAG gems are available
ruby -e "require 'hnswlib'; require 'informers'; puts 'RAG gems installed!'"

# Test RAG with the gem (semantic search of L0 skills)
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{"query":"safety"}}}' | kairos_mcp_server

# Test RAG from the repository
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{"query":"safety"}}}' | bin/kairos_mcp_server
```

> **Note**: The first RAG search will download the embedding model (~90MB) and build the vector index. Subsequent searches will be fast.

#### How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                      Search Query                            │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │  VectorSearch.available?  │
                    └─────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              │                               │
              ▼                               ▼
    ┌─────────────────┐             ┌─────────────────┐
    │ Semantic Search │             │ Fallback Search │
    │ (hnswlib +      │             │ (Regex-based)   │
    │  informers)     │             │                 │
    └─────────────────┘             └─────────────────┘
              │                               │
              └───────────────┬───────────────┘
                              ▼
                    ┌─────────────────┐
                    │  Search Results │
                    └─────────────────┘
```

---

### Optional: SQLite Storage Backend (Team Use)

By default, KairosChain uses file-based storage (JSON/JSONL files). For team environments with concurrent access, you can optionally enable SQLite storage backend.

**Default (File-based):** No configuration required, suitable for individual use  
**SQLite:** Better concurrent access handling, suitable for small team use (2-10 people)

#### When to Use SQLite

| Scenario | Recommended Backend |
|----------|---------------------|
| Individual developer | File (default) |
| Small team (2-10) | **SQLite** |
| Large team (10+) | PostgreSQL (future) |
| CI/CD pipelines | SQLite |

#### Installation

```bash
# If using the gem:
gem install sqlite3

# If using the repository with Bundler:
cd KairosChain_mcp_server
bundle install --with sqlite
```

#### Configuration

Edit the config file to enable SQLite (at `<data-dir>/skills/config.yml` for gem, or `skills/config.yml` for repo):

```yaml
# Storage backend configuration
storage:
  backend: sqlite                         # Change from 'file' to 'sqlite'

  sqlite:
    path: "storage/kairos.db"             # Path to SQLite database file
    wal_mode: true                        # Enable WAL for better concurrency
```

#### Verification

```bash
# Check if SQLite gem is installed
ruby -e "require 'sqlite3'; puts 'SQLite3 gem installed!'"

# Test with the gem
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | kairos_mcp_server

# Test from the repository
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | bin/kairos_mcp_server
```

#### Exporting Data from SQLite to Files

You can export SQLite data to human-readable files for backup or inspection:

```ruby
# In Ruby console or script
require 'kairos_mcp/storage/exporter'  # gem install
# or: require_relative 'lib/kairos_mcp/storage/exporter'  # from repository

# Export all data
KairosMcp::Storage::Exporter.export(
  db_path: "storage/kairos.db",
  output_dir: "storage/export"
)

# Output structure:
# storage/export/
# ├── blockchain.json       # All blocks
# ├── action_log.jsonl      # Action log entries
# ├── knowledge_meta.json   # Knowledge metadata
# └── manifest.json         # Export metadata
```

#### Rebuilding SQLite from Files

If SQLite database becomes corrupted, you can rebuild it from file-based data:

```ruby
# In Ruby console or script
require_relative 'lib/kairos_mcp/storage/importer'

# Rebuild from original file storage
KairosMcp::Storage::Importer.rebuild_from_files(
  db_path: "storage/kairos.db"
)

# Or import from exported files
KairosMcp::Storage::Importer.import(
  input_dir: "storage/export",
  db_path: "storage/kairos.db"
)
```

#### Using MCP Tools for Export/Import

You can also use MCP tools directly from your AI assistant (Cursor/Claude Code):

**Export (read-only, safe):**
```
# In Cursor/Claude Code chat:
"Export the SQLite database to files using chain_export"

# Or call directly:
chain_export output_dir="storage/backup"
```

**Import (requires approval):**
```
# Preview mode (shows impact without making changes):
chain_import source="files" approved=false

# Execute with automatic backup:
chain_import source="files" approved=true

# Import from exported directory:
chain_import source="export" input_dir="storage/backup" approved=true
```

**Safety features of chain_import:**
- Requires `approved=true` to execute (otherwise shows preview)
- Automatically creates backup at `storage/backups/kairos_{timestamp}.db`
- Shows impact summary before execution
- `skip_backup=true` available but NOT recommended

#### Switching Between Backends

**File → SQLite:**
1. Install sqlite3 gem
2. Change `storage.backend` to `sqlite` in config.yml
3. Run `Importer.rebuild_from_files` to migrate data
4. Restart the MCP server

**SQLite → File:**
1. Run `Exporter.export` to export data
2. Copy exported files to original locations:
   - `blockchain.json` → `storage/blockchain.json`
   - `action_log.jsonl` → `skills/action_log.jsonl`
3. Change `storage.backend` to `file` in config.yml
4. Restart the MCP server

#### Migrating to SQLite (Step-by-Step)

If you're already using KairosChain with file-based storage and want to migrate to SQLite:

**Step 1: Install sqlite3 gem**

```bash
cd KairosChain_mcp_server

# Using Bundler (recommended)
bundle install --with sqlite

# Or direct install
gem install sqlite3

# Verify installation
ruby -e "require 'sqlite3'; puts 'SQLite3 ready!'"
```

**Step 2: Update config.yml**

```yaml
# skills/config.yml
storage:
  backend: sqlite                         # Change from 'file' to 'sqlite'

  sqlite:
    path: "storage/kairos.db"
    wal_mode: true
```

**Step 3: Migrate existing data**

```bash
cd KairosChain_mcp_server

ruby -e "
require_relative 'lib/kairos_mcp/storage/importer'

result = KairosMcp::Storage::Importer.rebuild_from_files(
  db_path: 'storage/kairos.db'
)

puts 'Migration completed!'
puts \"Blocks imported: #{result[:blocks]}\"
puts \"Action logs imported: #{result[:action_logs]}\"
puts \"Knowledge metadata imported: #{result[:knowledge_meta]}\"
"
```

**Step 4: Restart MCP server**

Restart Cursor/Claude Code or reconnect the MCP server.

**Step 5: Verify migration**

```bash
# Check chain status (gem or repository)
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# Verify chain integrity
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'
```

**Step 6: Keep original files as backup**

After migration, keep the original files as backup:

```
storage/
├── blockchain.json      # ← Original file (keep as backup)
├── kairos.db            # ← New SQLite database
└── kairos.db-wal        # ← WAL file (auto-generated)

skills/
└── action_log.jsonl     # ← Original file (keep as backup)
```

#### Troubleshooting SQLite

**sqlite3 gem won't load:**

```bash
# Check if installed
gem list sqlite3

# Reinstall if needed
gem uninstall sqlite3
gem install sqlite3
```

**Data not visible after migration:**

```bash
# Re-run migration
ruby -e "
require_relative 'lib/kairos_mcp/storage/importer'
KairosMcp::Storage::Importer.rebuild_from_files(db_path: 'storage/kairos.db')
"
```

**SQLite database corrupted:**

```bash
# Delete corrupted database and rebuild from original files
rm storage/kairos.db storage/kairos.db-wal storage/kairos.db-shm 2>/dev/null

ruby -e "
require_relative 'lib/kairos_mcp/storage/importer'
KairosMcp::Storage::Importer.rebuild_from_files(db_path: 'storage/kairos.db')
"
```

**Reverting to file-based storage:**

```yaml
# Simply change config.yml back
storage:
  backend: file    # Change from 'sqlite' to 'file'
```

The original files (`blockchain.json`, `action_log.jsonl`) will be used automatically.

#### Important Notes

- **Knowledge content (*.md files)**: Always stored in files regardless of backend
- **SQLite stores**: Blockchain, action logs, and knowledge metadata only
- **Human readability**: Use export feature to inspect data without SQL commands
- **Backup**: For SQLite, simply copy the `.db` file; for extra safety, also export to files

---

### Optional: Streamable HTTP Transport (Remote/Team Access)

By default, KairosChain uses stdio transport (local process). For remote access and team sharing, you can optionally enable Streamable HTTP transport with Bearer token authentication.

**Default (stdio):** Local process via stdin/stdout, no additional setup required  
**Streamable HTTP:** Remote access via `POST /mcp`, Bearer token authentication, team sharing

#### When to Use HTTP Transport

| Scenario | Recommended Transport |
|----------|----------------------|
| Individual developer (local Cursor/Claude Code) | stdio (default) |
| Team sharing a single KairosChain instance | **Streamable HTTP** |
| Remote access across network | **Streamable HTTP** |
| CI/CD integration via HTTP | **Streamable HTTP** |

#### Installation

```bash
# If using the gem:
gem install puma rack

# If using the repository with Bundler:
cd KairosChain_mcp_server
bundle install --with http

# For full team setup (HTTP + SQLite for concurrent access):
gem install puma rack sqlite3          # gem
bundle install --with http sqlite      # or Bundler

# Verify installation
ruby -e "require 'puma'; require 'rack'; puts 'HTTP transport gems installed!'"
```

#### Gems Used

| Gem | Version | Purpose |
|-----|---------|---------|
| `puma` | ~> 6.0 | High-performance concurrent web server |
| `rack` | ~> 3.0 | Modular Ruby web server interface |

#### Quick Start

```bash
# Using the gem:
kairos_mcp_server --init-admin
kairos_mcp_server --http --port 8080

# Using the repository:
ruby bin/kairos_mcp_server --init-admin
ruby bin/kairos_mcp_server --http --port 8080

# Test with curl (in another terminal)
curl http://localhost:8080/health
```

#### Setup Steps

**Step 1: Generate an Admin Token**

```bash
# Using the gem:
kairos_mcp_server --init-admin

# Using the repository:
ruby bin/kairos_mcp_server --init-admin
```

Output:
```
============================================================
  KairosChain Admin Token Generated
============================================================

  Token: kc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  User:  admin
  Role:  owner
  Expires: 2026-05-13T10:00:00+01:00

  IMPORTANT: Store this token securely.
  It will NOT be shown again.
============================================================
```

**Step 2: Start the HTTP Server**

```bash
# Using the gem:
kairos_mcp_server --http                                    # default port 8080
kairos_mcp_server --http --port 9090                        # custom port
kairos_mcp_server --http --port 8080 --data-dir /path/to/data  # custom data dir

# Using the repository:
ruby bin/kairos_mcp_server --http
ruby bin/kairos_mcp_server --http --port 9090
ruby bin/kairos_mcp_server --http --host 127.0.0.1 --port 8080
```

**Step 3: Configure Cursor to Connect**

Add to `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "kairos-chain-http": {
      "url": "http://localhost:8080/mcp",
      "headers": {
        "Authorization": "Bearer kc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
      }
    }
  }
}
```

Restart Cursor after saving.

#### Testing the HTTP Transport

**Unit tests (no gems required):**

```bash
ruby test_http.rb
```

**Integration tests (requires puma + rack):**

```bash
ruby test_http.rb --integration
```

**Manual testing with curl:**

```bash
# Health check (no auth required)
curl http://localhost:8080/health

# MCP initialize (with auth)
curl -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-token>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'

# List tools
curl -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-token>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# Call a tool
curl -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-token>" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"hello_world","arguments":{"name":"HTTP"}}}'
```

#### Token Management

After initial setup, manage tokens via the `token_manage` MCP tool:

```bash
# Create a token for a team member
token_manage command="create" user="alice" role="member"

# List active tokens
token_manage command="list"

# Rotate a token (revoke old, create new)
token_manage command="rotate" user="alice"

# Revoke a token
token_manage command="revoke" user="alice"
```

**Token roles (Phase 1: all roles have equal access):**

| Role | Description | Phase 2 Permissions |
|------|-------------|---------------------|
| `owner` | System administrator | Full access + token management |
| `member` | Team member | L1/L2 write, L0 read-only |
| `guest` | External collaborator | Read-only, own L2 only |

**Token expiry:**

| Duration | Option | Use Case |
|----------|--------|----------|
| 90 days (default) | `expires_in="90d"` | Daily use in Cursor |
| 24 hours | `expires_in="24h"` | CI/CD, temporary access |
| 7 days | `expires_in="7d"` | Short-term collaboration |
| No expiry | `expires_in="never"` | Owner tokens only |

#### CLI Options

```
Usage: kairos_mcp_server [command] [options]

Commands:
    init              Initialize data directory with default templates
    upgrade           Preview template migrations after gem update
    upgrade --apply   Apply template migrations

Options:
    --data-dir DIR  Data directory path (default: .kairos/ in current dir)
    --http          Start in Streamable HTTP mode (default: stdio)
    --port PORT     HTTP port (default: 8080)
    --host HOST     HTTP bind host (default: 0.0.0.0)
    --init-admin    Generate initial admin token and exit
    --token-store PATH  Path to token store file
    -v, --version   Show version
    -h, --help      Show help

Environment Variables:
    KAIROS_DATA_DIR   Override data directory path
```

#### Production Deployment with HTTPS

For production use, place a reverse proxy in front of Puma to handle TLS/HTTPS. Puma only handles plain HTTP internally; the reverse proxy terminates SSL.

```
Client (Cursor) ──HTTPS──▶ Reverse Proxy ──HTTP──▶ Puma (:8080)
                           (Caddy/Nginx)
                           TLS termination
```

**Option A: Caddy (Recommended — Simplest)**

Caddy provides automatic HTTPS with Let's Encrypt certificates (zero configuration for TLS).

```bash
# Install Caddy
# macOS
brew install caddy

# Ubuntu/Debian
sudo apt install -y caddy

# Or see: https://caddyserver.com/docs/install
```

Create a `Caddyfile`:

```
kairos.example.com {
    reverse_proxy localhost:8080
}
```

Start Caddy:

```bash
# Foreground (for testing)
caddy run

# As a service (production)
sudo systemctl enable --now caddy
```

That's it. Caddy automatically:
- Obtains a Let's Encrypt certificate for `kairos.example.com`
- Renews it before expiry
- Redirects HTTP to HTTPS
- Handles TLS termination

**Option B: Nginx**

For environments where Nginx is already available or preferred.

```bash
# Install Nginx + Certbot
# macOS
brew install nginx

# Ubuntu/Debian
sudo apt install -y nginx certbot python3-certbot-nginx
```

Create Nginx config (`/etc/nginx/sites-available/kairos`):

```nginx
server {
    listen 80;
    server_name kairos.example.com;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Enable and get SSL certificate:

```bash
# Enable the site
sudo ln -s /etc/nginx/sites-available/kairos /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# Obtain Let's Encrypt certificate (automatic Nginx config update)
sudo certbot --nginx -d kairos.example.com
```

Certbot automatically modifies the Nginx config to add SSL and sets up auto-renewal.

**Option C: Self-Signed Certificate (LAN / Development)**

For LAN teams or development where you don't have a public domain:

```bash
# Generate self-signed certificate (valid for 1 year)
mkdir -p certs
openssl req -x509 -newkey rsa:4096 -keyout certs/key.pem -out certs/cert.pem \
  -days 365 -nodes -subj "/CN=kairos.local"
```

With Caddy (using self-signed cert):

```
kairos.local {
    tls /path/to/certs/cert.pem /path/to/certs/key.pem
    reverse_proxy localhost:8080
}
```

With Nginx:

```nginx
server {
    listen 443 ssl;
    server_name kairos.local;

    ssl_certificate /path/to/certs/cert.pem;
    ssl_certificate_key /path/to/certs/key.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

**Cursor Configuration (HTTPS)**

After setting up HTTPS, update `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "kairos-chain-http": {
      "url": "https://kairos.example.com/mcp",
      "headers": {
        "Authorization": "Bearer kc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
      }
    }
  }
}
```

**Comparison: Caddy vs Nginx**

| Aspect | Caddy | Nginx |
|--------|-------|-------|
| HTTPS setup | Automatic (zero config) | Manual (certbot required) |
| Certificate renewal | Automatic | Automatic (via certbot timer) |
| Configuration | Simple Caddyfile | More verbose |
| Performance | Good | Excellent (battle-tested) |
| Best for | New setups, simplicity | Existing Nginx infrastructure |

#### Configuration

HTTP settings in `skills/config.yml`:

```yaml
http:
  enabled: false                          # Set to true or use --http flag
  port: 8080                              # HTTP listen port
  host: "0.0.0.0"                         # Bind address
  token_store: "storage/tokens.json"      # Token storage path
  default_token_expiry_days: 90           # Default token expiry
```

#### Cleanup After Testing

All generated files are in `.gitignore`. To clean up:

```bash
cd KairosChain_mcp_server

rm -f storage/tokens.json       # Generated tokens
rm -rf vendor/bundle vendor/    # Locally installed gems
rm -rf .bundle/                 # Bundler cache
rm -f Gemfile.lock              # Lock file
```

Verify clean state: `git status` should show `working tree clean`.

#### Future Phases (Not Yet Implemented)

**Phase 2: Role-Based Authorization**
- Layer-specific permissions per role (owner/member/guest)
- `notifications/tools/list_changed` for dynamic tool updates
- Per-user permission overrides

**Phase 3: Wallet / JWT Integration (GenomicsChain)**
- JWT tokens issued by GenomicsChain Rails API
- Wallet-based authentication (MetaMask signature)
- Integration with PoC (Proof of Contribution) token system

---

### Admin UI (Browser-Based Management)

When running in HTTP mode, KairosChain provides a built-in browser-based admin UI at `/admin`. This is a lightweight management interface for server operators — no additional frameworks or gems required.

#### Accessing the Admin UI

1. Start the HTTP server: `kairos_mcp_server --http` (gem) or `ruby bin/kairos_mcp_server --http` (repository)
2. Open `http://localhost:8080/admin` in your browser
3. Log in with an `owner` role Bearer token

#### Available Screens

| Screen | Path | Purpose |
|--------|------|---------|
| **Dashboard** | `/admin` | Chain status, token count, L0/L1 overview, state commit status |
| **Tokens** | `/admin/tokens` | Create, list, revoke, and rotate Bearer tokens |
| **Chain** | `/admin/chain` | Browse block history, view block details, verify chain integrity |
| **Skills** | `/admin/skills` | View L0 DSL skills and their definitions (read-only) |
| **Knowledge** | `/admin/knowledge` | Browse and search L1 knowledge entries (read-only) |
| **Config** | `/admin/config` | View configuration, layer settings, storage info (read-only) |

#### Technical Details

- **Technology**: htmx + PicoCSS + ERB (Ruby stdlib) — no new gems required
- **Authentication**: Session cookie (HMAC-SHA256 signed) wrapping existing Bearer tokens
- **Authorization**: `owner` role only — other roles are redirected to login
- **CSRF Protection**: Token-based protection on all POST requests
- **Data Source**: Calls existing tool classes directly (no MCP protocol overhead)
- **Same Process**: Runs inside the existing Puma/Rack HTTP server

#### Design Philosophy

The admin UI is intentionally minimal. It is a **Phase 1 management tool** (see [MCP-to-SaaS Development Workflow](KairosChain_mcp_server/knowledge/mcp_to_saas_development_workflow/mcp_to_saas_development_workflow.md)). For richer UIs, build a custom SaaS frontend that consumes the Backend API and MCP tools.

---

## Client Configuration

### Claude Code Configuration (Detailed)

Claude Code is a CLI-based AI coding assistant.

#### Step 1: Verify Claude Code Installation

```bash
# Check if Claude Code is installed
claude --version

# If not installed, install from the official site
# https://docs.anthropic.com/claude-code
```

#### Step 2: Register the MCP Server

```bash
# If using the gem (recommended):
claude mcp add kairos-chain kairos_mcp_server

# If using the repository:
claude mcp add kairos-chain ruby /path/to/KairosChain_mcp_server/bin/kairos_mcp_server

# With a custom data directory:
claude mcp add kairos-chain kairos_mcp_server -- --data-dir /path/to/my-kairos-data
```

#### Step 3: Verify Registration

```bash
# List registered MCP servers
claude mcp list

# You should see kairos-chain in the list
```

#### Step 4: Check Configuration File (Optional)

The following configuration is added to `~/.claude.json`:

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "kairos_mcp_server",
      "args": ["--data-dir", "/path/to/my-kairos-data"],
      "env": {}
    }
  }
}
```

For repository-based setup:

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "ruby",
      "args": ["/path/to/KairosChain_mcp_server/bin/kairos_mcp_server"],
      "env": {}
    }
  }
}
```

#### Manual Configuration (Advanced)

To edit the configuration file directly:

```bash
# Open the configuration file
vim ~/.claude.json

# Or use VS Code
code ~/.claude.json
```

### Cursor IDE Configuration (Detailed)

Cursor is a VS Code-based AI coding IDE.

#### Option A: Via GUI (Recommended)

1. Open **Cursor Settings** (Cmd/Ctrl + ,)
2. Navigate to **Tools & MCP**
3. Click **New MCP Server**
4. Enter the server details:
   - **If using the gem:**
     - Name: `kairos-chain`
     - Command: `kairos_mcp_server`
     - Args: `--data-dir /path/to/my-kairos-data` (optional)
   - **If using the repository:**
     - Name: `kairos-chain`
     - Command: `ruby`
     - Args: `/path/to/KairosChain_mcp_server/bin/kairos_mcp_server`

#### Option B: Via Configuration File

#### Step 1: Locate the Configuration File

```bash
# macOS / Linux
~/.cursor/mcp.json

# Windows
%USERPROFILE%\.cursor\mcp.json
```

#### Step 2: Create/Edit the Configuration File

```bash
# Create directory if it doesn't exist
mkdir -p ~/.cursor

# Edit the configuration file
vim ~/.cursor/mcp.json
```

#### Step 3: Add the MCP Server

**If using the gem (recommended):**

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "kairos_mcp_server",
      "args": ["--data-dir", "/path/to/my-kairos-data"],
      "env": {}
    }
  }
}
```

**If using the repository:**

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "ruby",
      "args": ["/path/to/KairosChain_mcp_server/bin/kairos_mcp_server"],
      "env": {}
    }
  }
}
```

**For multiple MCP servers:**

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "kairos_mcp_server",
      "args": ["--data-dir", "/Users/yourname/.kairos"],
      "env": {}
    },
    "sushi-mcp-server": {
      "command": "ruby",
      "args": ["/path/to/SUSHI_self_maintenance_mcp_server/bin/sushi_mcp_server"],
      "env": {}
    }
  }
}
```

#### Step 4: Restart Cursor

After saving the configuration, **you must completely restart Cursor**.

#### Step 5: Verify MCP Server Connection

1. Open Cursor
2. Click the "MCP" icon in the top right (or search "MCP" in the command palette)
3. Verify that `kairos-chain` appears in the list with a green status indicator

---

## Upgrading the Gem

When a new version of `kairos_mcp` is released (with new skills, config keys, bug fixes, etc.), updating the gem code is straightforward:

```bash
gem update kairos_mcp
```

However, your data directory (`.kairos/`) contains template files that were copied at `init` time and may have been customized. The built-in upgrade system uses **3-way hash comparison** to safely migrate these files.

### How It Works

The upgrade system compares three versions of each template file:
- **Original**: The template hash recorded in `.kairos_meta.yml` at init time
- **Current**: Your version in the data directory (possibly customized)
- **New**: The latest template shipped with the gem

Based on this comparison, each file is classified:

| Pattern | User Modified? | Template Changed? | Action |
|---------|---------------|-------------------|--------|
| 0 (unchanged) | No | No | No action needed |
| 1 (auto-updatable) | No | Yes | Safe to auto-update |
| 2 (user-modified) | Yes | No | Keep user version |
| 3 (conflict) | Yes | Yes | Merge / review required |

For **config YAML files** (Pattern 3), a structural merge adds new keys while preserving your values. For **L0 kairos.rb** (Pattern 3), a `skills_evolve` proposal is generated, requiring human approval and blockchain recording.

### Upgrade Commands

#### Via CLI

```bash
# Preview what would change (recommended first step)
kairos_mcp_server upgrade

# Apply the upgrade
kairos_mcp_server upgrade --apply

# With custom data directory
kairos_mcp_server upgrade --data-dir /path/to/data --apply
```

#### Via MCP Tool (from within an AI session)

```
system_upgrade command="check"       # Quick version check
system_upgrade command="preview"     # Detailed file-by-file analysis
system_upgrade command="apply" approved=true   # Apply upgrade
system_upgrade command="status"      # Show current meta status
```

### Version Mismatch Warning

When the MCP server starts and detects a version mismatch between the gem and the data directory, it displays a warning:

```
[KairosChain] Data directory was initialized with v0.9.0, current gem is v0.10.0.
[KairosChain] Run 'system_upgrade command="check"' or 'kairos_mcp_server upgrade' to see available updates.
```

### Upgrade Workflow

1. Update the gem: `gem update kairos_mcp`
2. Preview changes: `kairos_mcp_server upgrade`
3. Review the output (especially any conflicts)
4. Apply: `kairos_mcp_server upgrade --apply`
5. For L0 proposals, use `skills_evolve` to review and approve
6. Restart the MCP server

All upgrade operations are recorded to the KairosChain blockchain for traceability.

---

## Testing the Setup

> **Note**: The examples below show both the gem command (`kairos_mcp_server`) and the repository command (`bin/kairos_mcp_server`). Use whichever matches your installation.

### 1. Basic Command Line Tests

#### Initialize Test

```bash
# Using the gem:
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | kairos_mcp_server

# Using the repository:
cd /path/to/KairosChain_mcp_server
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | bin/kairos_mcp_server

# Expected response (excerpt):
# {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":...}}
```

#### Tools List Test

```bash
# Get list of available tools
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | kairos_mcp_server

# If you have jq, display only tool names
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | kairos_mcp_server 2>/dev/null | jq '.result.tools[].name'
```

#### Hello World Test

```bash
# Call the hello_world tool
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"hello_world","arguments":{}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# Output: Hello from KairosChain MCP Server!
```

### 2. Skills Tools Test

```bash
# Get skills list
echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# Get a specific skill
echo '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"skills_dsl_get","arguments":{"skill_id":"core_safety"}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'
```

### 3. Blockchain Tools Test

```bash
# Check blockchain status
echo '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# Verify chain integrity
echo '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'
```

### 4. Testing with SQLite Backend (Optional)

```bash
# 1. Install sqlite3 gem
gem install sqlite3

# 2. Edit config to enable SQLite
#    Change storage.backend from 'file' to 'sqlite' in <data-dir>/skills/config.yml

# 3. Test chain_status (should show SQLite backend info)
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# 4. Record and verify
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chain_record","arguments":{"logs":["SQLite test record"]}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'
```

### 5. Testing with RAG / Semantic Search (Optional)

```bash
# 1. Install RAG gems
gem install hnswlib informers

# 2. Verify gems are available
ruby -e "require 'hnswlib'; require 'informers'; puts 'RAG gems installed!'"

# 3. Enable RAG in config
#    Set vector_search.enabled to true in <data-dir>/skills/config.yml

# 4. Test semantic search (first run downloads ~90MB embedding model)
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{"query":"safety rules"}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# 5. Test knowledge search
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"knowledge_list","arguments":{"query":"layer placement"}}}' | kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'
```

### 6. Testing HTTP Mode (Optional)

```bash
# 1. Install HTTP gems
gem install puma rack

# 2. Initialize data and generate admin token
kairos_mcp_server init --data-dir /tmp/kairos_test
kairos_mcp_server --init-admin --data-dir /tmp/kairos_test
# Save the displayed token!

# 3. Start HTTP server
kairos_mcp_server --http --port 9090 --data-dir /tmp/kairos_test

# 4. Test from another terminal
curl http://localhost:9090/health

curl -X POST http://localhost:9090/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_TOKEN>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
```

### 7. Testing with Claude Code

```bash
# Launch Claude Code
claude

# Try these prompts in Claude Code:
# "List the available KairosChain tools"
# "Run skills_dsl_list"
# "Check chain_status"
```

### 8. Testing with Cursor

1. Open your project in Cursor
2. Open the chat panel (Cmd/Ctrl + L)
3. Try these prompts:
   - "List all KairosChain skills"
   - "Check the blockchain status"
   - "Show me the core_safety skill content"

### Troubleshooting

#### Server Doesn't Start

```bash
# Check Ruby version
ruby --version  # Requires 3.0+

# Check for syntax errors
ruby -c bin/kairos_mcp_server

# Verify executable permission
ls -la bin/kairos_mcp_server
chmod +x bin/kairos_mcp_server
```

#### JSON-RPC Errors

```bash
# Check stderr for error messages
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | bin/kairos_mcp_server

# Run without suppressing stderr (remove 2>/dev/null)
```

#### Gem Command Not Found

```bash
# If kairos_mcp_server is not found after gem install
# Check if the gem bin directory is in your PATH
gem environment gemdir
# The executable should be in the bin/ directory under that path

# For rbenv users, rehash may be needed
rbenv rehash

# Verify the correct Ruby version has the gem
gem list kairos_mcp
```

#### Cursor Connection Issues

1. Verify the path in `~/.cursor/mcp.json` is an absolute path (for repository setup)
2. Check JSON syntax (missing/extra commas, etc.)
3. Completely quit and restart Cursor

---
