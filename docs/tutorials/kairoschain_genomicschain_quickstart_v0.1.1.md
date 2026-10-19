---
name: kairoschain_genomicschain_quickstart
description: "Use when setting up KairosChain for Claude Code on a new machine or project, choosing and projecting an instruction mode, using KairosChain day to day (L2 notes, L1 knowledge, tidy-up, multi-LLM review), or installing and upgrading the GenomicsChain SkillSets. Commands, the order they must run in, and the pitfalls that fail silently."
version: "0.1.1"
layer: L1
tags: [setup, quickstart, kairoschain, genomicschain, claude-code, mcp, instruction-mode, skillset, tips]
---

# KairosChain + GenomicsChain quickstart (Claude Code, stdio)

Written for kairos-chain 3.93.0. Check your version with `kairos-chain --version`.

## 1. Install KairosChain

Requirements: **Ruby 3.3 or newer** (the gem declares `required_ruby_version >= 3.3`; on Ruby 3.2
`gem install` falls back to an old release without the modes used below), Claude Code
(`claude --version`). The gem's executables must be on the `PATH` of the shell Claude Code starts
(with Homebrew Ruby, add its gem `bin` directory).

```sh
gem install kairos-chain
cd /path/to/your/project
git init                   # only if it is not a git repository yet (step 2.4 needs a project marker)
kairos-chain init          # creates .kairos/ and .mcp.json in this directory
claude                     # start Claude Code here; approve the kairos-chain server when asked
```

- `.kairos/` is the data directory: instruction modes (L0), knowledge (L1), session notes (L2),
  installed SkillSets, and the local append-only chain (`.kairos/storage/blockchain.json`).
- `.mcp.json` registers the server for this project over stdio:
  `{"mcpServers": {"kairos-chain": {"command": "kairos-chain", "args": ["--data-dir", "<absolute path>/.kairos"]}}}`.
- Check it works: ask Claude Code to "run chain_status". The reply includes `"valid": true`.
- The first start also installs the core SkillSets (for example `dream`, `llm_client`, `synoptis`).
  Restart Claude Code once afterwards so their tools are listed.
- Alternative to `.mcp.json`, available in all your projects:
  `claude mcp add -s user kairos-chain kairos-chain -- --data-dir /path/to/.kairos`
  (without `-s user` the registration is for the current project only).

Data directory resolution, highest priority first: `--data-dir`, then `KAIROS_DATA_DIR`, then
`./.kairos`.

## 2. Choose an instruction mode, then project it

A fresh instance runs `tutorial`. To have the agent actively suggest saving, promoting, tidying,
review and skills, switch to `proactive_tutorial`.

There is no CLI command for switching. Ask Claude Code:

```
1. "Switch the instruction mode to proactive_tutorial."
   -> the agent calls instructions_update(command: "set_mode", mode_name: "proactive_tutorial", reason: ...)
2. It first shows "Human approval required". Nothing has changed yet. Say yes.
3. It calls again with approved: true -> config.yml changes and the change is recorded on the chain.
   If another mode's body is still projected into CLAUDE.md, the reply tells you to re-project.
4. In a terminal, in the project root:   kairos-chain mode project
   (the folder must contain CLAUDE.md, .git/ or .claude/; otherwise it stops with
   "no plausible consumer project root")
5. Restart Claude Code (exit, then claude).
```

Why step 4 matters: Claude Code passes only the first 4,096 characters of an MCP server's
instructions to the model (2,048 in older versions) and drops the rest. `kairos-chain mode project`
writes the full mode body to `.claude/kairos/instruction_mode.md` and adds an `@`-import of it to
`CLAUDE.md`, so the whole mode reaches the model and its sub-agents. `proactive_tutorial` keeps its
essential rules inside the first 2,048 characters, so it works partly even before projection.

Other mode commands: `kairos-chain mode status`, `kairos-chain mode remove` (undo projection).
Editing `instructions_mode:` in `.kairos/skills/config.yml` by hand also switches the mode, but it
is not recorded on the chain.

## 3. Day-to-day use

Work in Claude Code as usual. KairosChain keeps what is worth keeping:

| When | The agent offers | Tool | On the chain? |
|---|---|---|---|
| A unit of work ends, or the session is long | Save a session note (L2) | `context_save` | No (L2 is a free notebook) |
| The same pattern appears in 2+ past notes | Promote it to reusable knowledge (L1) | `knowledge_update` | Yes, the hash of each change |
| About 10 L2 notes | Scan notes for promotion, merge and archive candidates | `dream_scan` | Yes, a summary block when it finds something |
| About 10 L1 entries | Check L1 for stale or overlapping entries | `skills_audit(command: "check")` | No |
| A hard-to-undo design or code change | Multi-LLM review | `multi_llm_review` | Optional SkillSet |
| A task an installed skill covers | Name the skill | `tool_guide(command: "catalog")` | No |

In `proactive_tutorial` every write waits for your yes, one suggestion comes at a time, and a
declined offer is not repeated until the situation changes.

What is stored and what is sent: notes, knowledge and the chain are files in `.kairos/`. Anything
the agent reads (a file, a `knowledge_get` result, a scan) becomes part of the conversation and is
sent to your model provider, as in any Claude Code session.

Useful prompts:
- "What KairosChain tools do I have?" (the agent calls `tool_guide`)
- "Save a note of what we did today." (L2)
- "Do we have knowledge about X?" (the agent calls `knowledge_list` / `knowledge_get`)

## 4. Install the GenomicsChain SkillSets

GenomicsChain is a set of add-on SkillSets. KairosChain needs no change to host them.
Requirements: kairos-chain 3.58.0 or newer; the `ed25519` and `json-schema` gems (`ed25519` builds a
native extension: on macOS it needs the Xcode Command Line Tools). **Start Claude Code once in the
project before running `install.sh`**: the core SkillSets these packages need (`synoptis`,
`llm_client`) are installed automatically only while no SkillSet is installed yet.

```sh
gem install ed25519 json-schema
git clone https://github.com/masaomi/GenomicsChain_SkillSets.git
cd GenomicsChain_SkillSets
bash install.sh --data-dir /path/to/your/project/.kairos
# restart Claude Code in your project
```

`install.sh` installs `genomicschain_core`, `_tier1`, `_tier2`, `_tier3` and the `mmp` SkillSet,
then checks that all five are listed. Or ask Claude Code to follow the repository README.

Tools you get:

| Tool | What it does | Needs |
|---|---|---|
| `gc_tier1_assess` | Reads a paper and drafts what it claims about reproducibility (unsigned; a person signs off) | An LLM via `llm_client` (default: the Claude Code subscription); the paper's text and IDs, which the agent gathers or asks you for |
| `gc_tier2_scan`, `gc_tier2_adjudicate` | Reads the code a paper points at: declared software, containers, data, how strongly each is pinned. Nothing runs. Parses conda environment and lock files, Snakemake `container:`, Dockerfiles and YAML config; **Nextflow, CWL and WDL are not yet parsed** | Nothing external. Give an absolute path (`~` is not expanded) |
| `gc_tier3_estimate` | Estimates the cost of executing a subject | The `thoa` CLI on `PATH` **and** `THOA_API_KEY` in the server's environment (`thoa run --dry-run`, costs no credits); otherwise it silently uses a measured table |
| `gc_tier3_execute` | Executes a subject and compares output when the paper declares a target | A backend. The default `thoa` backend runs in Thoa's cloud: inputs are uploaded and credits are spent. `local` runs on this machine |

The `gc_*_submit` tools do not appear unless the node is the anchor (`anchor_profile: true`). Leave
it false unless you are deliberately running the one signing node of a deployment.

Upgrade the SkillSets: `git pull`, then `bash install.sh --force --data-dir ...` (`install` copies,
it does not link; `--force` keeps your `config/`).

## 5. Tips

1. **Put `--data-dir` after the subcommand**, or use `KAIROS_DATA_DIR`.
   `kairos-chain skillset list --data-dir DIR` works. `kairos-chain --data-dir DIR skillset list`
   starts the server instead (in a terminal it waits for input) and installs or lists nothing.
2. **After `gem update kairos-chain`**, run `kairos-chain upgrade --apply` in each project, then
   restart Claude Code. New shipped files (for example a new mode) arrive only through this step.
3. **Change knowledge and modes through the agent, not by hand.** Tool calls are recorded on the
   chain; hand edits under `.kairos/` are not.
4. **Keep `.kairos/` out of public repositories.** It holds your notes and may hold a signing key (`mmp`).
   Add it to `.gitignore`, or keep it in a separate private repository.
5. **Use one data directory per project.** Several projects can share one with `--data-dir`, but
   the mode projection is recorded in the data directory, not per project: after projecting in one
   project, the others can end up with no mode body. This guide does not cover that setup.
6. **Optional SkillSets are installed explicitly**: `kairos-chain skillset upgrade` (a preview)
   lists them as `[OPTIONAL]`; then `kairos-chain skillset install <name>` (for example
   `multi_llm_review`). `kairos-chain skillset list` shows installed SkillSets only.

## 6. When something does not work

| Symptom | Check |
|---|---|
| No kairos-chain tools in Claude Code | `claude mcp list`; was the server approved; is `kairos-chain` on PATH for the shell Claude Code starts |
| `dream_scan` or `llm_*` tools missing | Restart Claude Code once after the first start (core SkillSets install on the first start) |
| The mode seems ignored | `kairos-chain mode status`; re-run `kairos-chain mode project` after switching; restart |
| `mode project` says "no plausible consumer project root" | Run it in the project root; `git init` if the folder has no CLAUDE.md, .git/ or .claude/ |
| New SkillSet tools missing | Restart Claude Code; `kairos-chain skillset list --data-dir ...` |
| A SkillSet install "succeeded" but nothing is listed | Argument order (tip 1) |
| Tools behave like an older version after a gem update | `kairos-chain upgrade --apply` in the project, restart |
