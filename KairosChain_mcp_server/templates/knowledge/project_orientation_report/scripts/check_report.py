#!/usr/bin/env python3
"""Mechanical acceptance checker for a project orientation report.

Decides, without an LLM, whether an HTML orientation report satisfies the
checkable part of the project_orientation_report skill.

What it will never decide: whether a reader who does not know the work can say,
after one pass, what the problem now is. That stays with a human.

Design note — why this parses instead of pattern-matching
---------------------------------------------------------
The first version of this script matched tags with regular expressions and
measured raw markup. Reviewers defeated every content check by moving the
content somewhere the regex did not look: into `<details open>` (visible to the
reader, invisible to the checker), into `<svg>` (stripped before scanning), or
behind an `<details` written inside a comment. The lesson is that a gate which
reads markup measures the author's tag choices, not the reader's experience.

So this version builds a document tree with the standard library's HTML parser
and measures **what a reader sees**: text that is rendered, in the region that
is rendered, including text inside figures. Relocating content no longer helps,
because the measurement follows the content.

What this is and is not — read before filing a bug
--------------------------------------------------
This is a **lint over accidental failure modes**, not a boundary against an
adversary. The author of a report is the agent writing it for its own operator.
Nobody is trying to smuggle an unreadable report past it.

IN SCOPE — ways an author gets a wrong answer while writing normally:
  ascii art in any tag that renders preformatted; unfilled template slots;
  labels that overflow their box; a legal SVG transform spelled a way the
  measurement misses; a relative font unit; a report that declares its way out
  of its own requirements; a section hidden by an inline style; content in a
  <summary>, which renders even when its <details> is collapsed.

OUT OF SCOPE — ways a determined author defeats it, all demonstrated and all
accepted:
  text drawn by a stylesheet's `content:`; an <iframe srcdoc>; full-width or
  zero-width-joiner spellings of a forbidden label; declaring a genuinely
  forbidden label in the allowed-tokens list; a nested <svg> positioned off the
  parent canvas; `textLength` overriding the rendered width.

Closing that second list is not possible with a parser: it requires rendering
the page. Two review rounds each closed the demonstrated escapes and each
uncovered a new class, which is what an unbounded surface looks like. The
tool's value does not depend on closing it — every failure it catches is a
failure a human reader actually hit.

**A pass is not evidence that a report is readable.** It means a handful of
known ways of being unreadable are absent. The judgement stays with a human.

Usage:
    check_report.py REPORT.html [MORE.html ...] [--max-body-chars N] [--quiet]

Exit code 0 when every report passes, 1 when any report fails or cannot be read.
Standard library only.
"""

import argparse
import html as html_mod
import re
import sys
import unicodedata
from html.parser import HTMLParser

# --- vocabulary -------------------------------------------------------------
#
# A work-internal token is a label that only means something inside the work
# being reported on: C-1, F5, R4, A2, step-3. A reader who meets one has to
# hold a decoder in their head, so the body must not contain any.
#
# Detection is deliberately broad and therefore catches innocent look-alikes
# (A4, Q3, gpt-5, v2). Those are not silently allowed. The report declares them,
# once, in its own head:
#
#     <meta name="orientation-allowed-tokens" content="A4, Q3, gpt-5">
#
# Declaring is the point. A fixed allowlist inside this script would grow until
# it allowed everything; a declaration is per-report, visible in the artifact,
# and costs the author one line of thought per token.
#
# Only the three layer names are built in, because they are permanent vocabulary
# of this system rather than of any one piece of work.
BUILTIN_ALLOWED_TOKENS = {
    "L0",  # layer name — framework / core
    "L1",  # layer name — knowledge
    "L2",  # layer name — context records
}

TOKEN_RE = re.compile(r"(?<![0-9A-Za-z])(?:#[0-9]+|[A-Za-z]{1,4}[-‐-―]?[0-9]+)(?![0-9A-Za-z])")

# Unfilled template placeholders. The template ships with 《…》 in every slot,
# so an untouched template must not pass.
PLACEHOLDER_RE = re.compile(r"《[^》]{0,80}》")

MIN_SECTION_COUNT = 8
MAX_EXEMPT_SECTIONS = 2
MIN_FIGURE_LABEL = 4
MIN_VISUAL_SECTIONS = 5
DEFAULT_MAX_BODY_CHARS = 6000

# Advance width per character as a multiple of font-size. Deliberately rough:
# the check exists to catch labels that are obviously too long for their box,
# not to typeset.
WIDE_RATIO = 1.0     # CJK and other full-width characters
NARROW_RATIO = 0.55  # ASCII and other half-width characters

VOID_TAGS = {
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
    "param", "source", "track", "wbr",
    # SVG shapes, which are usually written self-closing but not always
    "path", "line", "rect", "circle", "ellipse", "polygon", "polyline", "use",
    "stop", "image",
}

# Elements whose text a reader never sees.
INVISIBLE_TAGS = {"script", "style", "title", "head", "template"}

NUM = r"[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?"
TRANSLATE_RE = re.compile(rf"translate\(\s*({NUM})\s*(?:[,\s]\s*({NUM})\s*)?\)")
SCALE_RE = re.compile(rf"scale\(\s*({NUM})\s*(?:[,\s]\s*({NUM})\s*)?\)")
SUPPORTED_TRANSFORM_RE = re.compile(r"^\s*(?:translate\([^)]*\)|scale\([^)]*\)|\s)*\s*$")


# --- document tree ----------------------------------------------------------


class Node:
    __slots__ = ("tag", "attrs", "children", "parent", "text")

    def __init__(self, tag, attrs=None, parent=None, text=None):
        self.tag = tag
        self.attrs = attrs or {}
        self.children = []
        self.parent = parent
        self.text = text

    def get(self, name, default=None):
        return self.attrs.get(name, default)

    def iter(self):
        yield self
        for c in self.children:
            yield from c.iter()

    def ancestors(self):
        n = self.parent
        while n is not None:
            yield n
            n = n.parent


class TreeBuilder(HTMLParser):
    """Build a forgiving element tree.

    Comments are dropped, which is what closes the "write `<details` inside a
    comment and the rest of the document stops being checked" hole: a comment
    never becomes a node, so it can never open a region.
    """

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("#document")
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = Node(tag, dict(attrs), self.stack[-1])
        self.stack[-1].children.append(node)
        if tag not in VOID_TAGS:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        node = Node(tag, dict(attrs), self.stack[-1])
        self.stack[-1].children.append(node)

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return
        # Stray close tag: ignore rather than corrupt the tree.

    def handle_data(self, data):
        if data.strip():
            self.stack[-1].children.append(Node("#text", parent=self.stack[-1], text=data))


def parse(source):
    b = TreeBuilder()
    b.feed(source)
    b.close()
    return b.root


# --- body / appendix --------------------------------------------------------


def in_appendix(node):
    """True when the node sits inside a collapsed `<details>`.

    A `<details open>` renders expanded, so its content is part of what the
    reader reads and stays in the body. Only collapsed appendices are exempt.
    """
    chain = [node] + list(node.ancestors())
    for i, a in enumerate(chain):
        if a.tag == "summary":
            # A collapsed <details> still renders its <summary>. Text there is
            # read by the reader, so it is body, not appendix.
            return False
        if a.tag == "details" and "open" not in a.attrs and i > 0:
            return True
    return False


HIDDEN_STYLE_RE = re.compile(r"(display\s*:\s*none|visibility\s*:\s*hidden)", re.I)


def is_hidden(node):
    """Hidden by an inline style or the hidden attribute.

    Stylesheet-driven hiding is NOT detected — see the threat model in the
    module docstring. Inline hiding is the form that happens by accident.
    """
    if "hidden" in node.attrs:
        return True
    return bool(HIDDEN_STYLE_RE.search(node.get("style") or ""))


def is_invisible(node):
    if node.tag in INVISIBLE_TAGS:
        return True
    if is_hidden(node):
        return True
    return any(a.tag in INVISIBLE_TAGS or is_hidden(a) for a in node.ancestors())


def body_nodes(root):
    """Document-order list of body elements and text nodes."""
    return [n for n in root.iter()
            if n is not root and not in_appendix(n) and not is_invisible(n)]


def rendered_text(nodes):
    return "".join(n.text for n in nodes if n.tag == "#text")


# --- geometry ---------------------------------------------------------------


def char_width(ch, font_size):
    wide = unicodedata.east_asian_width(ch) in ("W", "F")
    return font_size * (WIDE_RATIO if wide else NARROW_RATIO)


def text_width(s, font_size):
    return sum(char_width(c, font_size) for c in s)


def accumulated_transform(node, stop_tag="svg"):
    """Return (dx, dy, sx, unsupported) for the chain of ancestors.

    Only translate and scale are understood. Anything else (rotate, matrix,
    skew) makes the position unmeasurable, and unmeasurable is reported as a
    failure rather than skipped — a silently skipped element is how the first
    version let genuine overflow through.
    """
    dx = dy = 0.0
    sx = 1.0
    unsupported = None
    chain = [node] + [a for a in node.ancestors()]
    for n in chain:
        if n.tag == stop_tag:
            break
        t = n.get("transform")
        if not t:
            continue
        if not SUPPORTED_TRANSFORM_RE.match(t):
            unsupported = t
            continue
        for m in TRANSLATE_RE.finditer(t):
            dx += float(m.group(1))
            dy += float(m.group(2) or 0.0)
        for m in SCALE_RE.finditer(t):
            sx *= float(m.group(1))
    return dx, dy, sx, unsupported


def inherited_font_size(node):
    for n in [node] + list(node.ancestors()):
        fs = (n.get("font-size") or "").strip()
        if fs:
            # Only an absolute pixel size can be measured from markup alone.
            # em, rem, %, and stylesheet-driven sizes are NOT converted to a
            # small number — that would silently under-measure. They return
            # None, which the caller reports as "cannot be measured".
            m = re.fullmatch(r"([0-9]*\.?[0-9]+)(px)?", fs)
            return float(m.group(1)) if m else None
        if n.tag == "svg":
            break
    return None


def node_text(node):
    return "".join(c.text for c in node.iter() if c.tag == "#text")


def text_lines(text_node):
    """Split a <text> into rendered lines.

    A <tspan> carrying its own x or dy is a manual line break — which the skill
    itself mandates, because SVG text does not wrap. Measuring the concatenation
    of all tspans as one string is how the first version rejected correct
    figures.
    """
    spans = [c for c in text_node.children if c.tag == "tspan"]
    positioned = [s for s in spans if s.get("x") is not None or s.get("dy") is not None]
    if positioned:
        return [(s, node_text(s)) for s in positioned if node_text(s).strip()]
    whole = node_text(text_node)
    return [(text_node, whole)] if whole.strip() else []


def containing_rect(text_node, x, y, svg):
    """Smallest <rect> in the same figure whose box contains the anchor point.

    The check that matters to a reader is whether a label fits its box, not
    whether it fits the canvas. The first version only compared against the
    viewBox, which left a wide window in which a label overflowed its box and
    still passed.
    """
    best = None
    for r in svg.iter():
        if r.tag != "rect":
            continue
        try:
            rx = float(r.get("x", 0))
            ry = float(r.get("y", 0))
            rw = float(r.get("width", 0))
            rh = float(r.get("height", 0))
        except ValueError:
            continue
        dx, dy, sx, _ = accumulated_transform(r)
        rx, ry, rw = rx * sx + dx, ry + dy, rw * sx
        if rw <= 0 or rh <= 0:
            continue
        if rx <= x <= rx + rw and ry <= y <= ry + rh:
            if best is None or rw < best[1]:
                best = (rx, rw, r)
    return best


# --- sections ---------------------------------------------------------------


def split_sections(nodes):
    """Slice the body at each h1/h2 heading, in document order."""
    sections = []
    current = None
    for n in nodes:
        if n.tag in ("h1", "h2"):
            current = {"heading": n, "nodes": []}
            sections.append(current)
        elif current is not None:
            current["nodes"].append(n)
    return sections


def section_title(section):
    return " ".join(node_text(section["heading"]).split())[:44]


def has_content_table(nodes):
    for n in nodes:
        if n.tag != "table":
            continue
        rows = [r for r in n.iter() if r.tag == "tr"]
        filled = [r for r in rows if node_text(r).strip()]
        if len(rows) >= 2 and len(filled) >= 2:
            return True
    return False


def has_content_svg(nodes):
    for n in nodes:
        if n.tag != "svg":
            continue
        labels = [t for t in n.iter()
                  if t.tag == "text" and len(node_text(t).strip()) >= MIN_FIGURE_LABEL]
        if labels:
            return True
    return False


# --- checks -----------------------------------------------------------------


def check_placeholders(text):
    hits = PLACEHOLDER_RE.findall(text)
    if not hits:
        return True, "unfilled placeholders: 0"
    sample = ", ".join(dict.fromkeys(hits[:5]))
    return False, f"unfilled placeholders: {len(hits)} -> {sample}"


def check_tokens(text, declared):
    allowed = BUILTIN_ALLOWED_TOKENS | declared
    found = {}
    for m in TOKEN_RE.finditer(text):
        tok = m.group(0)
        if tok in allowed:
            continue
        found[tok] = found.get(tok, 0) + 1
    if not found:
        note = f" ({len(declared)} declared)" if declared else ""
        return True, f"undeclared work-internal tokens: 0{note}"
    listed = ", ".join(f"{t}x{n}" for t, n in sorted(found.items())[:10])
    more = "" if len(found) <= 10 else f" (+{len(found) - 10} more)"
    return False, (f"undeclared work-internal tokens: {len(found)} kinds -> {listed}{more}"
                   " (rename them, or declare innocent look-alikes in "
                   '<meta name="orientation-allowed-tokens">)')


PRE_STYLE_RE = re.compile(r"white-space\s*:\s*pre\s*(?:;|$|\})", re.I)


def check_no_preformatted(nodes, stylesheets):
    """Ascii art misaligns in the reader's browser, whichever tag carries it."""
    hits = []
    for n in nodes:
        if n.tag == "pre":
            hits.append("<pre>")
        if PRE_STYLE_RE.search(n.get("style") or ""):
            hits.append(f"<{n.tag} style=white-space:pre>")
    for sheet in stylesheets:
        if PRE_STYLE_RE.search(sheet):
            hits.append("a stylesheet rule sets white-space: pre")
    if not hits:
        return True, "preformatted blocks in body: 0"
    return False, (f"preformatted blocks in body: {len(hits)} "
                   f"-> {', '.join(dict.fromkeys(hits[:5]))} (use <svg> or <table>)")


def check_size(text, limit):
    n = len(text.strip())
    return n <= limit, f"rendered body text: {n} characters, limit {limit}"


def check_section_count(sections):
    n = len(sections)
    return n >= MIN_SECTION_COUNT, (
        f"body sections (h1+h2): {n}, at least {MIN_SECTION_COUNT} required")


def check_visuals(sections):
    """Every section needs a figure or a table with something in it.

    Exemption is declared on the heading — `<h2 data-visual="none">` — rather
    than inferred from position. Position broke as soon as a report grew a
    section, and it silently moved the exemption onto the wrong one.
    """
    missing = []
    required = 0
    exempt = 0
    for s in sections:
        if s["heading"].get("data-visual") == "none":
            exempt += 1
            continue
        required += 1
        if has_content_table(s["nodes"]) or has_content_svg(s["nodes"]):
            continue
        missing.append(section_title(s))
    if exempt > MAX_EXEMPT_SECTIONS:
        return False, (f"{exempt} sections declare data-visual=\"none\"; at most "
                       f"{MAX_EXEMPT_SECTIONS} may. Declaring the requirement away "
                       "is not satisfying it")
    if required < MIN_VISUAL_SECTIONS:
        return False, (f"only {required} sections are subject to the visual "
                       f"requirement; at least {MIN_VISUAL_SECTIONS} must be")
    if not missing:
        return True, f"sections carrying a filled figure or table: {required}/{required}"
    return False, (f"sections without one: {len(missing)}/{required} -> "
                   + "; ".join(missing[:5]))


def check_svg_fit(nodes):
    problems = []
    tightest = None
    svgs = [n for n in nodes if n.tag == "svg"]
    measured = 0

    for idx, svg in enumerate(svgs, 1):
        vb = svg.get("viewBox") or svg.get("viewbox")
        if not vb:
            problems.append(f"figure {idx} has no viewBox")
            continue
        parts = vb.replace(",", " ").split()
        try:
            vx, _vy, vw, _vh = (float(p) for p in parts)
        except ValueError:
            problems.append(f"figure {idx} has a malformed viewBox ({vb!r})")
            continue
        if vw <= 0:
            problems.append(f"figure {idx} has a non-positive viewBox width")
            continue

        for t in [n for n in svg.iter() if n.tag == "text"]:
            for holder, content in text_lines(t):
                content = content.strip()
                if not content:
                    continue
                fs = inherited_font_size(holder) or inherited_font_size(t)
                if fs is None:
                    problems.append(
                        f"figure {idx}: '{content[:28]}' has no font-size attribute, "
                        "so its width cannot be estimated (CSS font-size is not visible here)")
                    continue
                x_attr = holder.get("x") if holder.get("x") is not None else t.get("x")
                y_attr = holder.get("y") if holder.get("y") is not None else t.get("y")
                if x_attr is None:
                    problems.append(
                        f"figure {idx}: '{content[:28]}' has no x, so it cannot be measured")
                    continue
                try:
                    x = float(x_attr)
                    y = float(y_attr) if y_attr is not None else 0.0
                except ValueError:
                    problems.append(f"figure {idx}: '{content[:28]}' has a non-numeric position")
                    continue

                dx, dy, sx, unsupported = accumulated_transform(holder)
                if unsupported:
                    problems.append(
                        f"figure {idx}: '{content[:28]}' sits under an unsupported "
                        f"transform ({unsupported!r}); position cannot be measured")
                    continue
                x = x * sx + dx
                y = y + dy

                anchor = (holder.get("text-anchor") or t.get("text-anchor") or "start")
                w = text_width(content, fs * sx)
                left = {"start": x, "middle": x - w / 2, "end": x - w}.get(anchor, x)
                right = left + w
                measured += 1

                box = containing_rect(t, x, y, svg)
                if box is not None:
                    bx, bw, _ = box
                    lo, hi, what = bx, bx + bw, "its box"
                else:
                    lo, hi, what = vx, vx + vw, "the figure"
                slack = min(left - lo, hi - right)
                if tightest is None or slack < tightest[0]:
                    tightest = (slack, idx, content[:30])
                if right > hi + 0.5 or left < lo - 0.5:
                    problems.append(
                        f"figure {idx}: '{content[:30]}' spans {left:.0f}..{right:.0f} "
                        f"but {what} is {lo:.0f}..{hi:.0f}")

    if problems:
        extra = "" if len(problems) <= 6 else f" (+{len(problems) - 6} more)"
        return False, "; ".join(problems[:6]) + extra
    if tightest is None:
        return True, f"figures: {len(svgs)}, no positioned label to measure"
    slack, idx, sample = tightest
    return True, (f"figures: {len(svgs)}, {measured} labels measured, "
                  f"tightest margin {slack:.1f} px (figure {idx}, '{sample}')")


# --- driver -----------------------------------------------------------------


def declared_tokens(root):
    out = set()
    for n in root.iter():
        if n.tag == "meta" and n.get("name") == "orientation-allowed-tokens":
            for tok in (n.get("content") or "").replace(",", " ").split():
                out.add(tok)
    return out


def check_report(path, max_chars):
    try:
        with open(path, encoding="utf-8") as fh:
            source = fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        return [("file is readable", False, f"{type(exc).__name__}: {exc}")]

    try:
        root = parse(source)
    except Exception as exc:  # a malformed document is a failing report, not a crash
        return [("file parses as HTML", False, f"{type(exc).__name__}: {exc}")]

    stylesheets = [node_text(n) for n in root.iter() if n.tag == "style"]
    nodes = body_nodes(root)
    text = html_mod.unescape(rendered_text(nodes))
    sections = split_sections(nodes)

    return [
        ("no unfilled placeholders",) + check_placeholders(text),
        ("no undeclared work-internal tokens",) + check_tokens(text, declared_tokens(root)),
        ("no preformatted blocks",) + check_no_preformatted(nodes, stylesheets),
        ("body within length budget",) + check_size(text, max_chars),
        ("all sections present",) + check_section_count(sections),
        ("every section carries a filled visual",) + check_visuals(sections),
        ("figure labels fit their boxes",) + check_svg_fit(nodes),
    ]


def main(argv=None):
    ap = argparse.ArgumentParser(description="Check an orientation report.")
    ap.add_argument("reports", nargs="+")
    ap.add_argument("--max-body-chars", type=int, default=DEFAULT_MAX_BODY_CHARS)
    ap.add_argument("-q", "--quiet", action="store_true",
                    help="print failing checks only")
    args = ap.parse_args(argv)

    if args.max_body_chars <= 0:
        print("--max-body-chars must be positive", file=sys.stderr)
        return 1

    all_ok = True
    for path in args.reports:
        try:
            results = check_report(path, args.max_body_chars)
        except Exception as exc:  # never let a caller see a traceback instead of a verdict
            results = [("checker completed", False, f"internal error: {type(exc).__name__}: {exc}")]
        failed = [r for r in results if not r[1]]
        verdict = "PASS" if not failed else f"FAIL ({len(failed)}/{len(results)})"
        print(f"\n{path}\n  {verdict}")
        for name, ok, detail in results:
            if args.quiet and ok:
                continue
            print(f"  [{'ok' if ok else 'NO'}] {name} — {detail}")
        all_ok = all_ok and not failed

    return 0 if all_ok else 1


def _run():
    try:
        code = main()
        sys.stdout.flush()
        return code
    except BrokenPipeError:
        # A caller piping to head/less closed the pipe. Report the verdict the
        # docstring promises, not a traceback with an unrelated exit code.
        try:
            sys.stdout.close()
        except BrokenPipeError:
            pass
        return 1
    except KeyboardInterrupt:
        return 1


if __name__ == "__main__":
    sys.exit(_run())
