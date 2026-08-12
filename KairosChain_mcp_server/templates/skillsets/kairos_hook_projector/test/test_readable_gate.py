#!/usr/bin/env python3
"""Tests for the shipped readable_gate measurement.

Run: /usr/bin/python3 test_readable_gate.py

The gate holds no thresholds of its own, so every case here supplies its own
config. The one exception is the shipped example, which is loaded from disk —
a worked example that does not work is worse than no example.
"""

import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "hooks"))

import readable_gate as G  # noqa: E402

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        return
    FAILURES.append("%s%s" % (name, (": " + detail) if detail else ""))


def cfg(**overrides):
    raw = {"mode_name": "test", "section": "§ Test"}
    raw.update(overrides)
    return G.Config(raw, "<inline>")


def measure(text, **overrides):
    return G.measure(text, cfg(**overrides))


def decide(text, rechecked=False, **overrides):
    """Drive the real script end to end and return what it emitted.

    Deliberately a subprocess: an in-test reimplementation of main() cannot
    fail when main() breaks. The first version of these tests copied the
    decision logic instead of driving it, and a mutation that removed the
    blocking check left them green.

    The hard timeout is here as well as inside the gate. A mutation that
    removes the gate's own bound must fail this suite, not hang it — a
    falsification harness that never returns cannot report anything, and one
    that is killed mid-run leaves the source mutated.
    """
    raw = {"mode_name": "test", "section": "§ Test"}
    raw.update(overrides)
    tmp = tempfile.mkdtemp()
    cfg_path = os.path.join(tmp, "cfg.json")
    tx_path = os.path.join(tmp, "t.jsonl")
    with open(cfg_path, "w", encoding="utf-8") as fh:
        json.dump(raw, fh)
    with open(tx_path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(
            {"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}}
        ) + "\n")

    script = os.path.join(os.path.dirname(HERE), "hooks", "readable_gate.py")
    try:
        proc = subprocess.run(
            [sys.executable, script, "--config", cfg_path],
            input=json.dumps({"transcript_path": tx_path, "stop_hook_active": rechecked}),
            capture_output=True, text=True, timeout=30,
        )
    except subprocess.TimeoutExpired:
        raise AssertionError("gate did not return within 30s")
    if proc.returncode != 0:
        raise AssertionError("gate exited %d: %s" % (proc.returncode, proc.stderr[:300]))
    return json.loads(proc.stdout) if proc.stdout.strip() else {}


# --- shape limits ------------------------------------------------------------

def test_limits_are_off_when_the_mode_does_not_set_them():
    m, f = measure("\n".join("line %d" % i for i in range(500)))
    check("no thresholds means no failures", f == [], repr(f))
    check("metrics still measured", m["lines"] == 500, m["lines"])


def test_each_limit_fires_independently():
    long_text = "\n".join("line %d" % i for i in range(70))
    _, f = measure(long_text, max_lines=60)
    check("length fires", any(x.startswith("LENGTH") for x in f), repr(f))

    _, f = measure("# a\n## b\n### c\n#### d\n", max_headings=3)
    check("headings fire", any(x.startswith("HEADINGS") for x in f), repr(f))

    tables = "\n".join(["| a | b |", "|---|---|", "| 1 | 2 |"] * 3)
    _, f = measure(tables, max_tables=2)
    check("tables fire", any(x.startswith("TABLES") for x in f), repr(f))


def test_announcement_exempts_length_only():
    long_text = "This answer is long.\n" + "\n".join("line %d" % i for i in range(70))
    _, f = measure(long_text, max_lines=60, max_headings=3,
                   announce_patterns=[r"(?i:\blong\b)"])
    check("announcement exempts length", f == [], repr(f))


def test_fenced_code_does_not_count_toward_length():
    text = "intro\n```\n" + "\n".join("x" for _ in range(200)) + "\n```\nend\n"
    m, f = measure(text, max_lines=60)
    check("code block excluded", f == [], repr(f))
    check("prose lines counted", m["lines"] == 3, m["lines"])


# --- vocabulary: the case that misfired in production ------------------------

MASA_SHORTHAND = (
    r"(?<![A-Za-z0-9_])([A-Z]{1,4}★|[A-Z]{2,5}-\d+|[PR]\d+"
    r"|(?![vV]\d)[a-z]\d{1,2})(?![A-Za-z0-9_.]\d*)"
)
GLOSS = [r"[（(＝=]", "——", "—", r"\bとは\b"]
SPECIMEN = (
    r"[（(]\s*[`'\"]?(?:[A-Z]{2,5}-\d+|[a-z]\d{1,2})[`'\"]?"
    r"(?:\s*[、,／/]\s*[`'\"]?(?:[A-Z]{2,5}-\d+|[a-z]\d{1,2})[`'\"]?)+\s*[）)]"
)


def vocab(text):
    _, f = measure(text, shorthand_patterns=[MASA_SHORTHAND],
                   gloss_patterns=GLOSS, vocab_min_lines=1)
    return f


def spec(text):
    _, f = measure(text, shorthand_patterns=[MASA_SHORTHAND], gloss_patterns=GLOSS,
                   specimen_patterns=[SPECIMEN], vocab_min_lines=1)
    return f


def test_coined_shorthand_without_a_gloss_is_caught():
    for token in ["t0", "a9", "INV-22", "P0", "R2"]:
        f = vocab("%s が壊れます。\n" % token)
        check("catches %s" % token, any("VOCABULARY" in x for x in f), repr(f))


def test_an_inline_gloss_clears_it():
    f = vocab("INV-22（事後の読み手を禁じる規則）が効きます。\n")
    check("gloss on the same line clears", f == [], repr(f))
    f = vocab("t0 は次の行で説明します。\n打ち手が最初に発話した時刻（手番の起点）。\n")
    check("gloss on the next line clears", f == [], repr(f))


def test_identifiers_are_not_coined_shorthand():
    # 2026-08-12: an unbounded \d+ flagged `c341361` — a git commit id — and
    # blocked a message that merely cited one. Bounding the digit count is the
    # fix; these are the shapes that must stay silent.
    for token in ["c341361", "f149134", "4867dbb", "7c84f718", "3.64.0", "v0.4.6"]:
        f = vocab("commit %s を参照。\n" % token)
        check("ignores identifier %s" % token, f == [], "%s -> %r" % (token, f))


def test_a_specimen_list_exhibits_tokens_rather_than_using_them():
    # 2026-08-12: the gate blocked the message that explained the vocabulary
    # rule, because explaining it requires naming the shapes it governs.
    f = spec("本物の略号は短く（`t0`、`a9`）、識別子は長い。\n")
    check("specimen list is exempt", f == [], repr(f))


def test_a_specimen_exemption_does_not_leak_to_real_use():
    for text in ["`t0` を日付けることは例外ではない。\n",
                 "（INV-24 が防ごうとした失敗）\n",
                 "五席すべてが「`t0` を置ける者がいない」を挙げました。\n"]:
        f = spec(text)
        check("still caught: %s" % text[:18],
              any("VOCABULARY" in x for x in f), "%s -> %r" % (text[:18], f))


def test_a_single_token_in_an_aside_is_a_citation_not_a_specimen():
    f = spec("この失敗は（INV-24）で防げます。\n")
    check("one token in an aside stays subject to the rule",
          any("VOCABULARY" in x for x in f), repr(f))


def test_only_the_first_use_is_reported():
    f = vocab("t0 が壊れ、t0 がまた壊れ、t0 が三度壊れる。\n")
    check("one report per token", sum(x.count("t0") for x in f) == 1, repr(f))


def test_short_notes_are_below_the_vocabulary_floor():
    _, f = measure("R2 の改訂に入ります。\n", shorthand_patterns=[MASA_SHORTHAND],
                   gloss_patterns=GLOSS, vocab_min_lines=8)
    check("a one-line progress note is not an explanation", f == [], repr(f))


# --- the decision seam: driven, never reimplemented ---------------------------

def test_blocking_false_reports_without_stopping_the_turn():
    # mode_hooks/_schema.json documents `blocking` as "whether a failure stops
    # the turn (true) or is reported only (false)", and the compiler writes it
    # into every gate config. Until 2026-08-12 nothing read it.
    bad = "# a\n## b\n### c\n#### d\n"
    out = decide(bad, max_headings=3, blocking=False)
    check("advisory does not block", "decision" not in out, repr(out))
    check("advisory still reports FAIL", "FAIL" in out["systemMessage"], out["systemMessage"])
    check("advisory is labelled", "advisory" in out["systemMessage"], out["systemMessage"])


def test_blocking_defaults_to_true():
    out = decide("# a\n## b\n### c\n#### d\n", max_headings=3)
    check("omitted blocking still blocks", out.get("decision") == "block", repr(out))


def test_a_rewrite_is_measured_and_reported_but_never_blocked_again():
    out = decide("# a\n## b\n### c\n#### d\n", rechecked=True, max_headings=3)
    check("recheck does not block", "decision" not in out, repr(out))
    check("recheck still reports", "FAIL" in out.get("systemMessage", ""), repr(out))
    check("recheck is labelled", "recheck" in out.get("systemMessage", ""), repr(out))


def test_a_passing_message_never_blocks_either_way():
    for blocking in (True, False):
        out = decide("短い応答。\n", max_headings=3, blocking=blocking)
        check("pass never blocks (blocking=%s)" % blocking, "decision" not in out, repr(out))


# --- round 2 hardening -------------------------------------------------------

def test_a_runaway_pattern_is_bounded_and_never_blocks():
    # A "coined term before a colon" rule with nested quantifiers backtracks
    # without bound. Before the alarm it burned the hook's whole budget on an
    # ordinary prose line, every turn, and the gate silently stopped enforcing.
    started = time.time()
    out = decide(
        "This is an ordinary prose line that should not take two minutes to scan\n",
        shorthand_patterns=[r"(\w+\s?)+:"], gloss_patterns=[r"[(（]"],
        vocab_min_lines=1, measure_timeout_seconds=2, max_headings=1,
    )
    elapsed = time.time() - started
    check("bounded", elapsed < 20, "took %.1fs" % elapsed)
    check("does not block on timeout", "decision" not in out, repr(out))
    check("says why", "NOT RUN" in out.get("systemMessage", ""), repr(out))


def test_a_wrong_typed_threshold_reports_instead_of_crashing():
    # `"max_lines": "60"` used to raise TypeError on every turn: exit 1, no
    # verdict, and no line in the log the operator would look at.
    out = decide("# a\n## b\n### c\n#### d\n", max_lines="60", max_headings="3")
    check("no block", "decision" not in out, repr(out))
    check("names both bad keys",
          "max_lines" in out.get("systemMessage", "") and
          "max_headings" in out.get("systemMessage", ""), repr(out))


def test_an_invalid_pattern_reports_instead_of_silently_disabling():
    out = decide("some text\n", announce_patterns=["(unclosed"])
    check("reports the invalid regex", "NOT RUN" in out.get("systemMessage", ""), repr(out))


def test_a_pattern_list_given_as_a_bare_string_is_refused():
    # A bare string iterates into single-character patterns, so the gate would
    # have run with rules nobody wrote.
    out = decide("some text\n", shorthand_patterns=r"P\d")
    check("refuses a string where a list is required",
          "NOT RUN" in out.get("systemMessage", ""), repr(out))


def _run_raw(content, config):
    tmp = tempfile.mkdtemp()
    cfg_path = os.path.join(tmp, "cfg.json")
    tx_path = os.path.join(tmp, "t.jsonl")
    open(cfg_path, "w").write(json.dumps(config))
    open(tx_path, "w").write(content)
    script = os.path.join(os.path.dirname(HERE), "hooks", "readable_gate.py")
    return subprocess.run(
        [sys.executable, script, "--config", cfg_path],
        input=json.dumps({"transcript_path": tx_path, "stop_hook_active": False}),
        capture_output=True, text=True, timeout=30)


def test_malformed_transcript_records_do_not_raise():
    for content in [None, "plain string", [None, 7], [{"type": "text"}]]:
        line = json.dumps({"type": "assistant", "message": {"content": content}}) + "\n"
        proc = _run_raw(line, {"mode_name": "t", "max_headings": 1})
        check("content=%r exits 0" % (content,), proc.returncode == 0, proc.stderr[:200])
        check("content=%r emits no block" % (content,),
              "block" not in proc.stdout, proc.stdout[:200])


def test_a_record_that_is_not_an_object_fails_open():
    """A JSON line that parses to a scalar or list is still a malformed record.

    Placement is load-bearing. last_assistant_text scans reversed(rows), so a
    malformed row BEFORE the newest assistant record is never examined and the
    case passes for the wrong reason. It must be at or after it.
    """
    good = json.dumps(
        {"type": "assistant", "message": {"content": [{"type": "text", "text": "ok"}]}})
    for row in ['"a string"', "42", "[1,2]", "null", "true"]:
        for label, lines in [("last", [good, row]), ("only", [row])]:
            proc = _run_raw("\n".join(lines) + "\n", {"mode_name": "t", "max_headings": 1})
            check("row=%s (%s) exits 0" % (row, label),
                  proc.returncode == 0, proc.stderr[-200:])
            check("row=%s (%s) emits no block" % (row, label),
                  "block" not in proc.stdout, proc.stdout[:200])


def test_the_report_path_also_survives_a_record_that_is_not_an_object():
    """--report reads through a second reader, which had the same defect.

    _tail_records was guarded and _all_records was not. Calibration over a
    transcript holding one bare scalar crashed where the hot path no longer
    does. Fixing one reader and leaving its twin is the failure this asserts
    against.
    """
    good = json.dumps(
        {"type": "assistant", "message": {"content": [{"type": "text", "text": "ok"}]}})
    tmp = tempfile.mkdtemp()
    cfg_path = os.path.join(tmp, "cfg.json")
    tx_path = os.path.join(tmp, "t.jsonl")
    with open(cfg_path, "w", encoding="utf-8") as fh:
        json.dump({"mode_name": "t", "max_headings": 1}, fh)
    with open(tx_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join([good, "42", '"a string"', "null", good]) + "\n")

    script = os.path.join(os.path.dirname(HERE), "hooks", "readable_gate.py")
    proc = subprocess.run(
        [sys.executable, script, "--config", cfg_path, "--report", tx_path],
        capture_output=True, text=True, timeout=30)

    check("report exits 0", proc.returncode == 0, proc.stderr[-200:])
    check("report still measured the good records",
          proc.stdout.count("lines=") == 2, repr(proc.stdout))


def test_a_broken_transcript_fails_open():
    for raw in ["", "{ not json\n"]:
        proc = _run_raw(raw, {"mode_name": "t", "max_headings": 1})
        check("broken transcript exits 0", proc.returncode == 0, proc.stderr[:200])
        check("broken transcript emits no block", "block" not in proc.stdout, proc.stdout[:200])


# --- the shipped example must actually work ---------------------------------

def strip_comments(obj):
    if isinstance(obj, dict):
        return {k: strip_comments(v) for k, v in obj.items() if not k.startswith("_")}
    if isinstance(obj, list):
        return [strip_comments(v) for v in obj]
    return obj


def test_shipped_example_params_drive_the_gate():
    path = os.path.join(os.path.dirname(HERE), "mode_hooks", "_EXAMPLE.json")
    doc = strip_comments(json.load(open(path, encoding="utf-8")))
    params = doc["hooks"]["Stop"][0]["params"]

    _, f = measure("INV-5 が壊れます。\n" * 10, **params)
    check("example catches coined shorthand", any("VOCABULARY" in x for x in f), repr(f))

    _, f = measure("commit c341361 を参照。\n" * 10, **params)
    check("example ignores a commit id", f == [], repr(f))


def main():
    tests = [(k, v) for k, v in sorted(globals().items()) if k.startswith("test_")]
    for name, t in tests:
        # A raising test is a failing test, not a reason to abandon the rest.
        try:
            t()
        except Exception as exc:  # noqa: BLE001
            FAILURES.append("%s raised %s: %s" % (name, type(exc).__name__, exc))
    print("%d tests, %d failures" % (len(tests), len(FAILURES)))
    for f in FAILURES:
        print("  FAIL %s" % f)
    sys.exit(1 if FAILURES else 0)


if __name__ == "__main__":
    main()
