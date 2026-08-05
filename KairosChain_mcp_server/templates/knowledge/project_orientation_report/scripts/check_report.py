#!/usr/bin/env python3
"""Mechanical acceptance checker for a project orientation report.

Reads one or more HTML reports and decides, without an LLM, whether each one
satisfies the checkable part of the project_orientation_report design.

The subjective question ("can a reader who does not know this work understand it
in one pass?") is NOT checked here and never will be. What is checked is the set
of failures that four rounds of human judgment produced, each of which turned out
to have a mechanical signature.

Usage:
    check_report.py REPORT.html [MORE.html ...] [--max-body-kb 12] [--quiet]

Exit code 0 when every report passes, 1 when any report fails.
Standard library only.
"""

import argparse
import html as html_mod
import re
import sys
import unicodedata

# ---------------------------------------------------------------------------
# Vocabulary allowed to look like a work-internal token
#
# A work-internal token is a label that only means something inside the work
# being reported on (C-1, F5, R4, A2). Those must not appear in the body: the
# reader would have to hold a decoder in their head while reading.
#
# The three names below match the same shape but are layer names in this
# system's permanent vocabulary, so they are allowed.
#
# BEFORE ADDING ANYTHING HERE, WRITE THE REASON ON THE LINE NEXT TO IT.
# Every addition makes the check weaker. A list that grows to a dozen entries
# has stopped being a check.
# ---------------------------------------------------------------------------
TOKEN_ALLOWLIST = {
    "L0",  # layer name — framework / core
    "L1",  # layer name — knowledge
    "L2",  # layer name — context records
}

TOKEN_RE = re.compile(r"\b[A-Z]{1,2}-?[0-9]+\b")

# Sections that carry no figure or table by design.
# Section 0 is the cover (it carries the timestamp frame instead); the "still
# undecided" section is a plain list of open questions. Position is used rather
# than the title, so the check survives retitling.
SECTIONS_WITHOUT_VISUAL = {0, 6}

EXPECTED_SECTION_COUNT = 8
DEFAULT_MAX_BODY_KB = 12.0

# Rough advance width per character, as a multiple of font-size.
WIDE_RATIO = 1.0     # CJK and other full-width characters
NARROW_RATIO = 0.55  # ASCII and other half-width characters


def split_body(source):
    """Return the part a human is expected to read.

    Everything from the first <details> onward is the appendix: exhaustive
    material kept for handoff and for checking details later. It is deliberately
    exempt from every check below.
    """
    cut = source.find("<details")
    return source if cut == -1 else source[:cut]


def strip_to_text(fragment):
    """Drop markup, script, style and svg; return the prose a reader sees."""
    out = re.sub(r"<(script|style|svg)\b.*?</\1>", " ", fragment, flags=re.S | re.I)
    out = re.sub(r"<!--.*?-->", " ", out, flags=re.S)
    out = re.sub(r"<[^>]+>", " ", out)
    return html_mod.unescape(out)


def char_width(ch, font_size):
    """Estimated advance width of one character at the given font size."""
    wide = unicodedata.east_asian_width(ch) in ("W", "F", "A")
    return font_size * (WIDE_RATIO if wide else NARROW_RATIO)


def text_width(s, font_size):
    return sum(char_width(c, font_size) for c in s)


# --- individual checks -----------------------------------------------------


def check_tokens(body):
    text = strip_to_text(body)
    found = {}
    for m in TOKEN_RE.finditer(text):
        tok = m.group(0)
        if tok in TOKEN_ALLOWLIST:
            continue
        found[tok] = found.get(tok, 0) + 1
    if not found:
        return True, "work-internal tokens in body: 0"
    listed = ", ".join(f"{t}x{n}" for t, n in sorted(found.items())[:12])
    more = "" if len(found) <= 12 else f" (+{len(found) - 12} more)"
    return False, f"work-internal tokens in body: {len(found)} kinds -> {listed}{more}"


def check_no_pre(body):
    n = len(re.findall(r"<pre\b", body, flags=re.I))
    if n == 0:
        return True, "<pre> blocks in body: 0"
    return False, f"<pre> blocks in body: {n} (ascii art misaligns; use <svg> or <table>)"


def check_size(body, max_kb):
    raw = len(body.encode("utf-8"))
    stripped = re.sub(r"<(style|svg)\b.*?</\1>", "", body, flags=re.S | re.I)
    prose = len(stripped.encode("utf-8"))
    limit = int(max_kb * 1024)
    label = f"body {prose} B excluding <style>/<svg> (raw {raw} B), limit {limit} B"
    return prose <= limit, label


def split_sections(body):
    """Return the body sliced at each h1/h2 heading, in document order."""
    marks = [m.start() for m in re.finditer(r"<h[12]\b", body, flags=re.I)]
    if not marks:
        return []
    bounds = marks + [len(body)]
    return [body[bounds[i]:bounds[i + 1]] for i in range(len(marks))]


def check_section_count(sections):
    n = len(sections)
    return n == EXPECTED_SECTION_COUNT, (
        f"body sections (h1+h2): {n}, expected {EXPECTED_SECTION_COUNT}")


def check_visuals(sections):
    missing = []
    required = 0
    for i, sec in enumerate(sections):
        if i in SECTIONS_WITHOUT_VISUAL:
            continue
        required += 1
        if re.search(r"<(svg|table)\b", sec, flags=re.I):
            continue
        title = re.sub(r"<[^>]+>", " ", sec[:200]).strip().split("\n")[0][:40]
        missing.append(f"#{i} {title}")
    if not missing:
        return True, f"sections carrying a figure or table: {required}/{required}"
    return False, (f"sections with prose only: {len(missing)}/{required} -> "
                   + "; ".join(missing[:6]))


def check_svg_fit(body):
    problems = []
    svgs = re.findall(r"<svg\b.*?</svg>", body, flags=re.S | re.I)
    tightest = None
    for idx, svg in enumerate(svgs, 1):
        vb = re.search(r'viewBox\s*=\s*"([^"]+)"', svg)
        if not vb:
            problems.append(f"svg #{idx} has no viewBox")
            continue
        parts = vb.group(1).replace(",", " ").split()
        if len(parts) != 4:
            problems.append(f"svg #{idx} viewBox is malformed")
            continue
        vx, _vy, vw, _vh = (float(p) for p in parts)
        default_fs = re.search(r'font-size\s*=\s*"?([0-9.]+)', svg)
        base_fs = float(default_fs.group(1)) if default_fs else 14.0
        for t in re.finditer(r"<text\b([^>]*)>(.*?)</text>", svg, flags=re.S | re.I):
            attrs, inner = t.group(1), t.group(2)
            content = html_mod.unescape(re.sub(r"<[^>]+>", "", inner)).strip()
            if not content:
                continue
            fs_m = re.search(r'font-size\s*=\s*"?([0-9.]+)', attrs)
            fs = float(fs_m.group(1)) if fs_m else base_fs
            x_m = re.search(r'\bx\s*=\s*"?(-?[0-9.]+)', attrs)
            if not x_m:
                continue
            x = float(x_m.group(1))
            anchor_m = re.search(r'text-anchor\s*=\s*"?(start|middle|end)', attrs)
            anchor = anchor_m.group(1) if anchor_m else "start"
            w = text_width(content, fs)
            left = {"start": x, "middle": x - w / 2, "end": x - w}[anchor]
            right = left + w
            slack = min(left - vx, (vx + vw) - right)
            if tightest is None or slack < tightest[0]:
                tightest = (slack, idx, content[:34])
            if right > vx + vw + 0.5 or left < vx - 0.5:
                problems.append(
                    f"svg #{idx} text overflows: '{content[:34]}' "
                    f"spans {left:.0f}..{right:.0f} in viewBox {vx:.0f}..{vx + vw:.0f}")
    if problems:
        return False, "; ".join(problems[:6])
    if tightest is None:
        return True, f"svg figures: {len(svgs)}, no positioned text to measure"
    slack, idx, sample = tightest
    return True, (f"svg figures: {len(svgs)}, tightest margin {slack:.1f} px "
                  f"(svg #{idx}, '{sample}')")


# --- driver ----------------------------------------------------------------


def check_report(path, max_kb):
    try:
        source = open(path, encoding="utf-8").read()
    except OSError as exc:
        return [("file is readable", False, str(exc))]

    body = split_body(source)
    sections = split_sections(body)

    return [
        ("no work-internal tokens",) + check_tokens(body),
        ("no ascii-art blocks",) + check_no_pre(body),
        ("body within length budget",) + check_size(body, max_kb),
        ("all sections present",) + check_section_count(sections),
        ("every section carries a visual",) + check_visuals(sections),
        ("svg text fits its box",) + check_svg_fit(body),
    ]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("reports", nargs="+")
    ap.add_argument("--max-body-kb", type=float, default=DEFAULT_MAX_BODY_KB)
    ap.add_argument("--quiet", action="store_true", help="print failing checks only")
    args = ap.parse_args(argv)

    all_ok = True
    for path in args.reports:
        results = check_report(path, args.max_body_kb)
        failed = [r for r in results if not r[1]]
        verdict = "PASS" if not failed else f"FAIL ({len(failed)}/{len(results)})"
        print(f"\n{path}\n  {verdict}")
        for name, ok, detail in results:
            if args.quiet and ok:
                continue
            print(f"  [{'ok' if ok else 'NO'}] {name} — {detail}")
        all_ok = all_ok and not failed

    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
