#!/usr/bin/env python3
"""INV-1 evidence-grounded verdict: mechanical checks, fail-closed, no LLM.

Runs the checks declared in an evidence spec (JSON, authored before the
run), collects evidence from their observable results, and computes a
verdict without any LLM involvement. Implements the first slice of the
Autonomous Growth Loop governance design (v0.3.1 FROZEN, 2026-07-03):

- INV-1: verdict consumes mechanically collected evidence only; where
  collection fails or returns empty, the verdict is non_success — no
  absence of evidence defaults to a pass (fail-closed).
- INV-6 (verdict half): the caller records this verdict, together with the
  cycle's actual cost, as an ATTESTATION (execution event; the Meta Ledger
  is reserved for capability changes — R-1). The spec's sha256 is included
  so the record pins WHICH criteria judged the run.

Spec format (JSON object):
{
  "task_ref": "human-readable reference to the goal",
  "workdir": "/absolute/path (optional; cwd for checks)",
  "checks": [
    {"name": "...", "command": "shell command; exit 0 = pass",
     "timeout": 120}
  ]
}

Usage: python3 kairos_verdict.py <spec.json>
Prints a single JSON object to stdout and ALWAYS exits 0 — the verdict
lives in the JSON, not the exit code, so callers cannot confuse engine
failure with check failure. Every output carries the same keys:
{verdict, reason, checks, spec_sha256, task_ref} (null where unknown).
Any malformed spec shape (non-object spec, non-list checks, non-object
check entry) and any engine exception yield non_success, never a crash.
Evidence capture: stdout/stderr truncated to 200 chars per check;
per-check timeout defaults to 120 s.
"""
import hashlib
import json
import subprocess
import sys

DEFAULT_TIMEOUT = 120
STDOUT_HEAD = 200


def result(verdict, reason, checks=None, spec_sha256=None, task_ref=None):
    return {
        "verdict": verdict,
        "reason": reason,
        "checks": checks or [],
        "spec_sha256": spec_sha256,
        "task_ref": task_ref,
    }


def non_success(reason, checks=None, spec_sha256=None, task_ref=None):
    return result("non_success", reason, checks, spec_sha256, task_ref)


def run_checks(spec, spec_sha256):
    task_ref = spec.get("task_ref")
    checks = spec.get("checks")
    if not isinstance(checks, list) or not checks:
        return non_success("empty or non-list check list",
                           spec_sha256=spec_sha256, task_ref=task_ref)

    workdir = spec.get("workdir") or None
    evidence = []
    all_passed = True
    for c in checks:
        if not isinstance(c, dict):
            evidence.append({"name": "unnamed",
                             "error": "check entry is not an object"})
            all_passed = False
            continue
        name = c.get("name", "unnamed")
        cmd = c.get("command")
        if not cmd:
            evidence.append({"name": name, "error": "missing command"})
            all_passed = False
            continue
        try:
            timeout = c.get("timeout", DEFAULT_TIMEOUT)
            if not isinstance(timeout, (int, float)) or timeout <= 0:
                timeout = DEFAULT_TIMEOUT
            r = subprocess.run(
                cmd,
                shell=True,
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd=workdir,
            )
            evidence.append({
                "name": name,
                "exit": r.returncode,
                "stdout": r.stdout[:STDOUT_HEAD],
                "stderr": r.stderr[:STDOUT_HEAD],
            })
            if r.returncode != 0:
                all_passed = False
        except Exception as e:
            evidence.append({"name": name, "error": str(e)})
            all_passed = False

    if all_passed:
        return result("success", "all declared checks passed",
                      evidence, spec_sha256, task_ref)
    return non_success("one or more declared checks did not pass",
                       evidence, spec_sha256, task_ref)


def main():
    if len(sys.argv) < 2:
        print(json.dumps(non_success("no evidence spec argument")))
        return 0

    spec_sha256 = None
    try:
        try:
            with open(sys.argv[1], "rb") as f:
                raw = f.read()
            spec_sha256 = hashlib.sha256(raw).hexdigest()
            spec = json.loads(raw)
        except Exception as e:
            # Distinct reason for record consumers: file I/O failure or
            # JSON-parse failure (an empty file lands here — it is readable
            # but not parseable as JSON).
            print(json.dumps(non_success(f"spec unreadable: {e}",
                                         spec_sha256=spec_sha256)))
            return 0
        if not isinstance(spec, dict):
            print(json.dumps(non_success("spec is not a JSON object",
                                         spec_sha256=spec_sha256)))
            return 0
        print(json.dumps(run_checks(spec, spec_sha256)))
    except Exception as e:
        print(json.dumps(non_success(f"engine exception: {e}",
                                     spec_sha256=spec_sha256)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
