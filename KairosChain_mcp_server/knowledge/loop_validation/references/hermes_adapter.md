# hermes-agent body adapter — wiring and traps (instance-local)

> **Scope**: this file documents ONE wired body for the loop_validation
> methodology. It is instance-local (masaomi's environment, absolute paths
> included deliberately). If this entry is ever promoted to `templates/`,
> replace paths with placeholders and strip machine-specific values.
> The core methodology (../loop_validation.md) does NOT require hermes.

Provenance: built 2026-06-14 (cycle wrapper, cost recording), revived and
extended 2026-07-03 (verdict step) after fast-forwarding hermes upstream
2,569 commits (0.16.0 → 0.18.0). Live-tested same day. Pre-R-1 history: the
first verified cycles recorded cost/verdict to the sandbox Meta Ledger
(Blocks #22–#24) before the ledger split was corrected; since R-1, cycle
execution events go to the attestation registry and those blocks remain as
immutable history of the pre-correction wiring.

## Layout

| Piece | Path |
|---|---|
| hermes repo (fork) | `/Users/masa/forback/github/hermes-agent` |
| HERMES_HOME (isolated, NOT `~/.hermes`) | `<repo>/.hermes` |
| body cwd (masa mode via AGENTS.md) | `<repo>/kairos_body/` |
| cycle wrapper | `<repo>/kairos_body/kairos_cycle.sh` |
| verdict engine (adapter copy — canonical home is this L1's `scripts/`; re-sync after any engine change, drift risk) | `<repo>/kairos_body/kairos_verdict.py` |
| evidence specs | `<repo>/kairos_body/specs/*.json` |
| sandbox KairosChain data | `<repo>/.kairos` (Meta Ledger: `.kairos/storage/blockchain.json`; attestation registry: `.kairos/synoptis_data/proofs.jsonl`) |
| no-LLM attestation issuer (cycle events) | `<repo>/kairos_body/mcp_attest.py` |
| no-LLM chain writer (capability changes only) | `<repo>/kairos_body/mcp_chain_record.py` |

## Environment

- conda env `hermes_kairos_py3.12`; editable install: `conda run -n hermes_kairos_py3.12 python -m pip install -e '.[mcp]'`
- Default model: `claude-sonnet-4-6` / provider anthropic (swap per call: args 3/4 of the wrapper; Ollama `gpt-oss:20b` registered as free local option).
- KairosChain MCP registration in `.hermes/config.yaml` → `mcp_servers.kairos-chain` with env `RBENV_VERSION: 3.3.7`, `KAIROS_DATA_DIR`/`KAIROS_PROJECT_ROOT: <repo>/.kairos`. (rbenv split: Bash=3.1.3, MCP server=3.3.7 — same as the main instance.)

## Update procedure (from command.log, verified 2026-07-03)

```bash
cd <repo>
git fetch upstream && git merge --ff-only upstream/main
conda run -n hermes_kairos_py3.12 python -m pip install -e '.[mcp]'
HERMES_HOME="$PWD/.hermes" conda run -n hermes_kairos_py3.12 hermes doctor --fix
```

After update, smoke-test one cycle before trusting it: the wrapper depends on
`state.db` `sessions` columns (input_tokens, output_tokens, cache_read_tokens,
cache_write_tokens, tool_call_count, estimated_cost_usd) — survived the
0.16→0.18 jump, but check after every large sync.

## Invocation

```bash
bash kairos_body/kairos_cycle.sh "<task>" [toolsets] [provider] [model] [evidence_spec.json]
# e.g. toolsets "kairos-chain,terminal" for file work; spec optional (attended → none_attended)
```

Four steps, printed as `[1/4]`…`[4/4]`: hermes run (masa mode injected) →
real cost from state.db → mechanical verdict (fail-closed) →
**attestation** for the execution event
(`mcp_attest.py`: subject `cycle://hermes_kairos/<session>`, claim
`cycle_verdict_<verdict>`, actor_role `automated`, 10-year ttl — the
`attestation_issue` default of 24h suits capability probes, not cycle
records; the `evidence` field carries the cost line plus the FULL verdict
JSON including `spec_sha256`, which is how the criteria pin reaches the
record). A spec-less attended run records verdict `none_attended` with the
same five constant keys. R-1 applied and live-verified 2026-07-03: registry proofs
`aa20e3fa` (non_success) / `db4b6e79` (success) issued while the Meta Ledger
block count stayed unchanged. `chain_record` remains available but is
reserved for capability changes a cycle actually causes.

## Traps (each cost real time; do not rediscover)

1. **`claude -p --bare` fails "Not logged in" on OAuth-only setups.** For
   subprocess Claude work, mimic the gem adapter instead: run from an EMPTY
   sandbox cwd (no CLAUDE.md/.claude) with `--no-session-persistence`, HOME
   preserved so OAuth works. (`--bare` needs ANTHROPIC_API_KEY.)
2. **Give hermes ABSOLUTE paths, always.** Its persistent shell keeps cwd
   across sessions: on 2026-07-03 it wrote the work product into a different
   repository while reporting success ("no other files were touched"). The
   mechanical verdict caught it (recorded pre-R-1 as Meta Ledger Block #23;
   today the same verdict would be an attestation). Task text AND spec
   checks must both use absolute paths.
3. **Session id parsing.** The wrapper greps `hermes --resume <id>` from
   stdout; if hermes changes that footer, cost lookup breaks (wrapper exits
   before recording).
4. **Sandbox vs main instance.** This body writes to the SANDBOX chain in
   `hermes-agent/.kairos`, not the main KairosChain_2026 instance. Keep it
   that way until the loop graduates (selective survival: sandbox first).
5. **`hermes doctor` may suggest `pip install -e '.[all]'` (venv path).** The
   conda `.[mcp]` install is the working setup; `.[all]` pulls heavy extras.
   Ignore unless a toolset actually fails to load.

## Governance reminder

Runs through this adapter are ATTENDED (design §5 gate: unattended requires
the full judgment track INV-1→INV-3, which is not yet shipped). The spec and
this repo are inside the body's write reach — acceptable attended, not
sufficient for unattended (INV-1/INV-6 write-reach isolation pending).
