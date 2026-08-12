#!/usr/bin/env python3
"""Generic readable-output gate. Ships with KairosChain; carries no mode content.

Every threshold, pattern, and message is supplied by a config file written by
the instruction mode. This file is the machinery; the mode is the content. The
core enforces that a declared norm is checkable, never what the norm says.

Usage (as a Claude Code Stop hook):
    readable_gate.py --config <path/to/gate_config.json>
    stdin  : Stop-hook JSON {transcript_path, stop_hook_active, ...}
    stdout : {"systemMessage": ...} and, on first failure, decision=block
    exit   : always 0 — a gate fault must never wedge a session

Offline calibration:
    readable_gate.py --config <cfg> --report <transcript.jsonl>...
"""

import argparse
import datetime
import json
import os
import re
import signal
import sys
import time

TAIL_BYTES = 512 * 1024
POLL_ATTEMPTS = 15
POLL_DELAY = 0.1

FENCE = re.compile(r"^\s*```")
HEADING = re.compile(r"^#{1,6}\s+\S")
TABLE_SEP = re.compile(r"^\s*\|?[\s:|-]*-[\s:|-]*\|[\s:|-]*$")

DEFAULTS = {
    "max_lines": None,
    "max_headings": None,
    "max_tables": None,
    "announce_patterns": [],
    "shorthand_patterns": [],
    "gloss_patterns": [],
    "specimen_patterns": [],
    "vocab_min_lines": 1,
    "blocking": True,
    # Python's re has no timeout, and a mode-supplied pattern with nested
    # quantifiers backtracks without bound: one such pattern had not returned
    # after two minutes on a 74-character line, burning the hook's whole budget
    # every turn. This is the wall-clock bound; exceeding it fails open.
    "measure_timeout_seconds": 5,
    "log_max_bytes": 1024 * 1024,
    "banner_prefix": "gate",
    "rewrite_instruction": "Rewrite the message to satisfy the rule above.",
    "log_path": None,
}


INT_KEYS = ("max_lines", "max_headings", "max_tables", "vocab_min_lines",
            "measure_timeout_seconds", "log_max_bytes")
LIST_KEYS = ("announce_patterns", "shorthand_patterns", "gloss_patterns",
             "specimen_patterns")
STR_KEYS = ("banner_prefix", "rewrite_instruction", "section", "mode_name")


class Config(object):
    """A mode's gate parameters. Nothing here is decided by the core.

    Every value is type-checked here rather than where it is used. A mode that
    writes `"max_lines": "60"` used to crash the gate on every turn with an
    uncaught TypeError and exit 1 — no verdict, no log line, and the operator's
    only symptom was a hook that had stopped working. Problems are collected,
    not raised: the caller reports them and lets the turn through.
    """

    def __init__(self, raw, path):
        self.problems = []
        if not isinstance(raw, dict):
            self.problems.append("config is %s, expected an object" % type(raw).__name__)
            raw = {}
        raw = self._checked(raw)

        merged = dict(DEFAULTS)
        merged.update(raw)
        self.path = path
        self.mode_name = raw.get("mode_name", "?")
        self.mode_version = raw.get("mode_version", "?")
        self.section = raw.get("section", "")
        self.max_lines = merged["max_lines"]
        self.max_headings = merged["max_headings"]
        self.max_tables = merged["max_tables"]
        self.vocab_min_lines = merged["vocab_min_lines"]
        # Declared by the mode, written into this config by the compiler, and
        # honoured here. A mode that declares blocking:false gets the verdict
        # reported and the turn left alone.
        self.blocking = bool(merged["blocking"])
        self.banner_prefix = merged["banner_prefix"]
        self.rewrite_instruction = merged["rewrite_instruction"]
        self.log_path = merged["log_path"]
        self.announce = _compile_any(merged["announce_patterns"])
        self.shorthand = [re.compile(p) for p in merged["shorthand_patterns"]]
        self.gloss = _compile_any(merged["gloss_patterns"])
        # Spans where a token is being exhibited rather than used — a specimen
        # list. Text explaining the vocabulary rule has to name the shapes it
        # governs, and naming them is not using them.
        self.specimen = [re.compile(p) for p in merged["specimen_patterns"]]
        self.measure_timeout = merged["measure_timeout_seconds"]
        self.log_max_bytes = merged["log_max_bytes"]

    def _checked(self, raw):
        """Drop every value whose type the gate cannot use, and say which."""
        out = {}
        for key, value in raw.items():
            if key in INT_KEYS and not isinstance(value, int) or \
               key in INT_KEYS and isinstance(value, bool):
                self.problems.append("%s is %s, expected a number" % (key, type(value).__name__))
                continue
            if key in LIST_KEYS:
                if not isinstance(value, list) or not all(isinstance(p, str) for p in value):
                    self.problems.append("%s must be a list of strings" % key)
                    continue
                for pattern in value:
                    try:
                        re.compile(pattern)
                    except re.error as exc:
                        self.problems.append("%s contains an invalid regex: %s" % (key, exc))
                        break
                else:
                    out[key] = value
                continue
            if key in STR_KEYS and not isinstance(value, str):
                self.problems.append("%s is %s, expected a string" % (key, type(value).__name__))
                continue
            out[key] = value
        return out


def _compile_any(patterns):
    if not patterns:
        return None
    return re.compile("|".join("(?:%s)" % p for p in patterns))


def load_config(path):
    with open(path, "r", encoding="utf-8") as fh:
        return Config(json.load(fh), path)


# --- transcript reading ------------------------------------------------------


def _tail_records(transcript_path):
    try:
        with open(transcript_path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            truncated = size > TAIL_BYTES
            fh.seek(size - TAIL_BYTES if truncated else 0)
            blob = fh.read().decode("utf-8", "replace")
    except Exception:
        return None
    lines = blob.split("\n")
    # Only a seeked-past head is a partial line. A whole file has none.
    if truncated and len(lines) > 1:
        lines = lines[1:]
    rows = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            continue
    return rows


def _text_of(row):
    # Every level is guarded. _tail_records deliberately tolerates malformed
    # lines, so a record with a null message or a content list holding
    # non-objects reaches here, and assuming shape after tolerating its absence
    # raised AttributeError out of the fail-open path.
    if not isinstance(row, dict):
        return None
    message = row.get("message")
    if not isinstance(message, dict):
        return None
    content = message.get("content", [])
    if isinstance(content, str):
        return content or None
    if not isinstance(content, list):
        return None
    parts = [
        c.get("text", "")
        for c in content
        if isinstance(c, dict) and c.get("type") == "text"
    ]
    return "\n".join(p for p in parts if p) or None


def last_assistant_text(transcript_path):
    """Text of the turn's final assistant message, with the flush race handled.

    One response is written as several records (thinking, text, tool_use) at
    different times. At Stop time the `text` record may not have landed yet, so
    the newest assistant record is often thinking-only. Wait for the text
    rather than judging an earlier message from the same turn.
    """
    for attempt in range(POLL_ATTEMPTS):
        rows = _tail_records(transcript_path)
        if rows is None:
            return None, "unreadable"
        for row in reversed(rows):
            if row.get("type") != "assistant":
                continue
            text = _text_of(row)
            if text:
                return text, "ok" if attempt == 0 else "ok-after-wait"
            break
        else:
            return None, "no-assistant-record"
        time.sleep(POLL_DELAY)
    return None, "race-timeout"


# --- measurement -------------------------------------------------------------


class MeasureTimeout(Exception):
    """Measurement exceeded its wall-clock bound."""


def measure_bounded(text, cfg):
    """measure() under a wall-clock alarm.

    Python's regex engine cannot be interrupted from another thread and has no
    timeout of its own, so the bound is a signal. SIGALRM is Unix-only; where
    it is unavailable the measurement runs unbounded, which is the situation
    that existed everywhere before.
    """
    if not cfg.measure_timeout or not hasattr(signal, "SIGALRM"):
        return measure(text, cfg)

    def fire(_signum, _frame):
        raise MeasureTimeout()

    previous = signal.signal(signal.SIGALRM, fire)
    signal.alarm(cfg.measure_timeout)
    try:
        return measure(text, cfg)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)


def _specimen_spans(line, cfg):
    return [(m.start(), m.end()) for p in cfg.specimen for m in p.finditer(line)]


def measure(text, cfg):
    """Pure. (metrics, failures). The whole judgement lives here."""
    raw = text.split("\n")

    prose, in_fence = [], False
    for line in raw:
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if not in_fence:
            prose.append(line)

    headings = sum(1 for l in prose if HEADING.match(l))
    tables = sum(1 for l in prose if TABLE_SEP.match(l))

    first = next((l for l in raw if l.strip()), "")
    announced = bool(cfg.announce and cfg.announce.search(first))

    seen, unglossed = set(), []
    if cfg.shorthand and len(prose) >= cfg.vocab_min_lines:
        for i, line in enumerate(prose):
            nxt = prose[i + 1] if i + 1 < len(prose) else ""
            spans = _specimen_spans(line, cfg)
            for pat in cfg.shorthand:
                for m in pat.finditer(line):
                    tok = m.group(1) if m.groups() else m.group(0)
                    if tok in seen:
                        continue
                    if any(s <= m.start() and m.end() <= e for s, e in spans):
                        continue  # exhibited, not used — and not "first use"
                    seen.add(tok)
                    after = line[m.end():]
                    if cfg.gloss and not (
                        cfg.gloss.search(after) or cfg.gloss.search(nxt)
                    ):
                        unglossed.append(tok)

    metrics = {
        "lines": len(prose),
        "headings": headings,
        "tables": tables,
        "announced": announced,
        "unglossed": unglossed,
    }

    failures = []
    if cfg.max_lines and metrics["lines"] > cfg.max_lines and not announced:
        failures.append(
            "LENGTH: %d lines (cap %d) with no announcement in the first line."
            % (metrics["lines"], cfg.max_lines)
        )
    if cfg.max_headings and headings > cfg.max_headings:
        failures.append("HEADINGS: %d (cap %d)." % (headings, cfg.max_headings))
    if cfg.max_tables and tables > cfg.max_tables:
        failures.append("TABLES: %d (cap %d)." % (tables, cfg.max_tables))
    if unglossed:
        failures.append(
            "VOCABULARY: first use without an inline gloss: %s."
            % ", ".join(unglossed)
        )
    return metrics, failures


# --- reporting ---------------------------------------------------------------


def note(cfg, verdict, metrics=None):
    """Append-only record of every invocation. Diagnosis depends on this."""
    if not cfg.log_path:
        return
    try:
        stamp = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
        detail = ""
        if metrics:
            detail = "\tlines=%d\theadings=%d\ttables=%d\tunglossed=%s" % (
                metrics["lines"],
                metrics["headings"],
                metrics["tables"],
                ",".join(metrics["unglossed"]) or "-",
            )
        path = os.path.expanduser(cfg.log_path)
        parent = os.path.dirname(path)
        if parent and not os.path.isdir(parent):
            # exist_ok: two sessions ending at once both reach here, and the
            # loser used to lose its record to a swallowed FileExistsError.
            os.makedirs(parent, exist_ok=True)
        # One line per turn with no bound grows without limit. Rotate rather
        # than truncate so the run that crossed the bound is still readable.
        if cfg.log_max_bytes and os.path.exists(path) and \
                os.path.getsize(path) > cfg.log_max_bytes:
            os.replace(path, path + ".1")
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("%s\t%s\t%s%s\n" % (stamp, cfg.mode_name, verdict, detail))
    except Exception:
        pass


def banner(cfg, verdict, metrics, failures, rechecked):
    shape = "%d lines / %d headings / %d tables" % (
        metrics["lines"],
        metrics["headings"],
        metrics["tables"],
    )
    tail = ""
    if failures:
        tail = " — " + " / ".join(f.split(":")[0] for f in failures)
    if rechecked:
        scope = " (recheck, not blocking)"
    elif not cfg.blocking:
        scope = " (advisory)"
    else:
        scope = ""
    return "%s%s: %s (%s)%s" % (cfg.banner_prefix, scope, verdict, shape, tail)


def _all_records(path):
    """Whole-file read. The tail limit exists for the hot path, not for
    calibration — truncating here would silently shrink the denominator."""
    rows = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except Exception:
                    continue
    except Exception:
        return []
    return rows


def report(cfg, paths):
    for path in paths:
        rows = _all_records(path)
        for row in rows:
            if row.get("type") != "assistant":
                continue
            text = _text_of(row)
            if not text:
                continue
            m, f = measure(text, cfg)
            print(
                "%s\tlines=%d\theadings=%d\ttables=%d\tFAIL=%s"
                % (
                    os.path.basename(path)[:8],
                    m["lines"],
                    m["headings"],
                    m["tables"],
                    ";".join(x.split(":")[0] for x in f) or "-",
                )
            )


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--config", required=True)
    ap.add_argument("--report", nargs="*", default=None)
    try:
        args = ap.parse_args()
        cfg = load_config(args.config)
    except SystemExit:
        raise
    except Exception:
        return  # a broken config must not wedge the session

    if args.report is not None:
        report(cfg, args.report)
        return

    if cfg.problems:
        # A mode whose declaration the gate cannot use is told so, and the turn
        # goes through. Enforcing half a config would be worse than enforcing
        # none, and crashing tells the operator nothing.
        note(cfg, "SKIP-bad-config: " + "; ".join(cfg.problems))
        print(json.dumps({
            "systemMessage": "%s: NOT RUN — %s" % (cfg.banner_prefix, "; ".join(cfg.problems))
        }, ensure_ascii=False))
        return

    try:
        payload = json.load(sys.stdin)
    except Exception:
        note(cfg, "SKIP-bad-stdin")
        return

    # A turn is blocked at most once. The rewrite is still measured and
    # reported, so its outcome is visible; it is simply never blocked again.
    rechecked = bool(payload.get("stop_hook_active"))

    text, why = last_assistant_text(payload.get("transcript_path", ""))
    if not text or not text.strip():
        note(cfg, "SKIP-" + why)
        return

    try:
        metrics, failures = measure_bounded(text, cfg)
    except MeasureTimeout:
        note(cfg, "SKIP-measure-timeout")
        print(json.dumps({
            "systemMessage": "%s: NOT RUN — measurement exceeded %ds; check the mode's "
                             "patterns for unbounded backtracking"
                             % (cfg.banner_prefix, cfg.measure_timeout)
        }, ensure_ascii=False))
        return

    verdict = "PASS" if not failures else "FAIL"
    note(cfg, ("RECHECK-" if rechecked else "") + verdict + "-" + why, metrics)

    out = {"systemMessage": banner(cfg, verdict, metrics, failures, rechecked)}
    if failures and not rechecked and cfg.blocking:
        out["decision"] = "block"
        out["reason"] = (
            "Your last message violates %s%s:\n- "
            % (cfg.mode_name, " " + cfg.section if cfg.section else "")
            + "\n- ".join(failures)
            + "\n\n"
            + cfg.rewrite_instruction
        )
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
