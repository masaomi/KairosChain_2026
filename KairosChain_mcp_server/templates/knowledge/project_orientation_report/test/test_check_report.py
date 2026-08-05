#!/usr/bin/env python3
"""Fixture tests for check_report.py.

Every fixture under fixtures/ is a claim about the gate, and the two directions
are tested together on purpose. Closing an evasion is easy if the checker is
allowed to reject everything; the `good_*` fixtures are what stops that.

Each `bad_*` fixture also declares WHICH check must catch it. A fixture that
fails for an unrelated reason is a false negative wearing a pass, so the name of
the failing check is asserted, not just the exit code.

Run:
    python3 test/test_check_report.py [-v]

Exit code 0 when every fixture behaves as declared, 1 otherwise.
Standard library only; no test framework required.
"""

import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
CHECKER = HERE.parent / "scripts" / "check_report.py"
FIXTURES = HERE / "fixtures"

# fixture name -> substring of the check that must be the one to fail.
# Every entry corresponds to an evasion that was demonstrated against the first
# version of this checker by an independent reviewer, with the evidence recorded
# in references/worked_example.md.
MUST_FAIL = {
    "bad_details_open.html": "preformatted",
    "bad_svg_smuggle.html": "work-internal tokens",
    "bad_empty_visuals.html": "filled visual",
    "bad_placeholder.html": "placeholders",
    "bad_svg_overflow_rect.html": "fit their boxes",
    "bad_svg_transform.html": "fit their boxes",
    "bad_token_forms.html": "work-internal tokens",
    "bad_comment_details.html": "preformatted",
    "bad_whitespace_pre.html": "preformatted",
    "bad_missing_section.html": "sections present",
    # Round 2 added these. Each is a way an author writes a report by accident
    # and gets a wrong answer, not a way an attacker smuggles one past the gate.
    "bad_all_exempt.html": "filled visual",
    "bad_hidden_headings.html": "filled visual",
    "bad_summary_content.html": "placeholders",
    "bad_translate_one_arg.html": "fit their boxes",
    "bad_em_font_size.html": "fit their boxes",
    "bad_stylesheet_pre.html": "preformatted",
    "bad_too_long.html": "length budget",
    "bad_dot_svg.html": "filled visual",
}

# These must pass. Each one is a report a reader would accept and that an
# over-strict gate would wrongly reject.
MUST_PASS = {
    "good_minimal.html": "the smallest report satisfying every rule",
    "good_tspan.html": "manual line breaking, which the skill itself mandates",
    "good_nine_sections.html": "a ninth section the work genuinely needed",
    "good_declared_tokens.html": "innocent look-alikes declared in the head",
}


def run(path, *extra):
    proc = subprocess.run(
        [sys.executable, str(CHECKER), str(path), *extra],
        capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def failing_checks(output):
    return [line.split("—")[0].replace("[NO]", "").strip()
            for line in output.splitlines() if "[NO]" in line]


def main():
    verbose = "-v" in sys.argv
    problems = []
    checked = 0

    on_disk = {p.name for p in FIXTURES.glob("*.html")}
    declared = set(MUST_FAIL) | set(MUST_PASS)
    for name in sorted(on_disk - declared):
        problems.append(f"{name}: fixture on disk with no declared expectation")
    for name in sorted(declared - on_disk):
        problems.append(f"{name}: expectation declared but fixture missing")

    for name, expected_check in sorted(MUST_FAIL.items()):
        if name not in on_disk:
            continue
        checked += 1
        rc, out = run(FIXTURES / name)
        if rc == 0:
            problems.append(f"{name}: expected FAIL, got PASS")
            continue
        fired = failing_checks(out)
        if not any(expected_check in f for f in fired):
            problems.append(
                f"{name}: failed, but not on '{expected_check}' — fired: {fired}")
        elif verbose:
            print(f"  ok  {name}: caught by '{expected_check}'")

    for name, why in sorted(MUST_PASS.items()):
        if name not in on_disk:
            continue
        checked += 1
        rc, out = run(FIXTURES / name)
        if rc != 0:
            problems.append(f"{name}: expected PASS ({why}), got FAIL — "
                            f"{failing_checks(out)}")
        elif verbose:
            print(f"  ok  {name}: {why}")

    # The checker must return a verdict, not a traceback, on input it was not
    # written for.
    for label, argv in [("missing file", ["/nonexistent/report.html"]),
                        ("a directory", [str(FIXTURES)]),
                        ("empty body", [str(FIXTURES / "good_minimal.html"),
                                        "--max-body-chars", "1"])]:
        checked += 1
        rc, out = run(*argv) if False else run(argv[0], *argv[1:])
        if rc != 1:
            problems.append(f"{label}: expected exit 1, got {rc}")
        elif "Traceback" in out:
            problems.append(f"{label}: exited 1 but printed a traceback")
        elif verbose:
            print(f"  ok  {label}: exit 1, no traceback")

    print(f"\n{checked} checks, {len(problems)} problem(s)")
    for p in problems:
        print(f"  FAIL {p}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
