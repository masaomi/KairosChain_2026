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
  of its own requirements; a section hidden by an inline style or by a plain
  class rule in the report's own stylesheet; content in a <summary>, which
  renders even when its <details> is collapsed; a token spelled in full-width
  characters, which is what a Japanese input method emits by default (the body
  is NFKC-normalised before the token scan, so Ｆ１ is F1).

OUT OF SCOPE — ways a determined author defeats it, all demonstrated and all
accepted:
  text drawn by a stylesheet's `content:`; an <iframe srcdoc>; a
  zero-width-joiner spelling of a forbidden label; declaring a genuinely
  forbidden label in the allowed-tokens list; a nested <svg> positioned off the
  parent canvas; `textLength` overriding the rendered width.

Closing that second list is not possible with a parser: it requires rendering
the page. Two review rounds each closed the demonstrated escapes and each
uncovered a new class, which is what an unbounded surface looks like. The
tool's value does not depend on closing it — at the check level, 4 of the 7
checks (tokens, visuals, length, preformatted) enforce rules a human reader
hit first; the other 3 checks, and every one of the fixtures, came out of
review rounds and the checker's own design, none from the human reading
rounds.

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
# Three, because the template itself needs three: the cover, the "still
# undecided" section, and the "record discrepancies" section when it states
# there are none. The cap stays so a report cannot declare its way out of
# every section.
MAX_EXEMPT_SECTIONS = 3
MIN_FIGURE_LABEL = 2
# The allowed-tokens declaration is capped for the same reason the section
# exemption is: declaring the requirement away wholesale is not satisfying it.
# The cap is coarse on purpose. It is not calibrated against the 13-token
# report that motivated invariant 7 — those tokens were work-internal and
# UNDECLARED, which no count can tell apart from innocent ones, so the cap
# never fires on that accident — while a realistic technical paragraph
# legitimately declares 13 (SHA-256, Ed25519, TLS-1.3, ...). 16 clears that
# observed legitimate maximum and still refuses a declaration that erases the
# requirement wholesale.
MAX_DECLARED_TOKENS = 16
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

# Elements whose text a reader never sees. A <title> is handled separately:
# a document <title> is window chrome, not body text, but an SVG <title> is
# read aloud by a screen reader, so its text (and an unfilled placeholder in
# it) is content.
INVISIBLE_TAGS = {"script", "style", "head", "template"}

NUM = r"[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?"
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
            # A collapsed <details> still renders its <summary>, so text there
            # is body — but only when that <details> is itself shown. A summary
            # nested inside another collapsed <details> is never rendered.
            seen_owner = False
            n = a.parent
            while n is not None:
                if n.tag == "details":
                    if not seen_owner:
                        seen_owner = True
                    elif "open" not in n.attrs:
                        return True
                n = n.parent
            return False
        if a.tag == "details" and "open" not in a.attrs and i > 0:
            return True
    return False


HIDDEN_STYLE_RE = re.compile(r"(display\s*:\s*none|visibility\s*:\s*hidden)", re.I)


# --- the report's own stylesheet, crudely -----------------------------------
#
# The scan is not a CSS engine. It understands brace-matched rules, drops
# @media blocks that cannot apply on screen, and matches only tag/.class/#id
# selectors with descendant/child combinators. Anything it cannot parse is
# treated conservatively: as applicable for the preformatted check, and as
# not-hiding for the hidden check (wrongly hiding a section would reject a
# correct report).


CSS_COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)


def iter_style_rules(sheet, unconditional_only=False):
    """Yield (selector, declarations) for rules that can apply on screen.

    Comments are stripped first, so a comment before a rule cannot glue
    itself onto the selector and get the rule discarded — both consumers of
    a stylesheet (the preformatted scan and the hiding scan) parse through
    here, so they cannot disagree about one comment.

    With unconditional_only, an @media block contributes only when its
    condition is nothing beyond screen: a width-conditional block
    (max-width: 600px) applies on some screens and not others, and treating
    it as unconditional would hide, from every reader, content a desktop
    reader sees. That is the same conservatism already applied to print-only
    blocks, extended to conditional ones.
    """
    sheet = CSS_COMMENT_RE.sub(" ", sheet)
    out = []
    i, n = 0, len(sheet)
    while i < n:
        open_b = sheet.find("{", i)
        if open_b == -1:
            break
        selector = sheet[i:open_b].strip()
        depth, j = 1, open_b + 1
        while j < n and depth:
            if sheet[j] == "{":
                depth += 1
            elif sheet[j] == "}":
                depth -= 1
            j += 1
        body = sheet[open_b + 1:j - 1]
        if selector.startswith("@"):
            if selector.startswith("@media"):
                cond = selector[len("@media"):].lower()
                if unconditional_only:
                    if cond.strip() in ("", "screen", "all"):
                        out.extend(iter_style_rules(body, True))
                elif not ("print" in cond and "screen" not in cond and "all" not in cond):
                    out.extend(iter_style_rules(body))
            # other at-rules (@font-face, @keyframes, @import) carry nothing
            # this checker looks for
        elif selector:
            out.append((selector, body))
        i = j
    return out


SIMPLE_SEL_RE = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*|\*)?((?:[.#][A-Za-z0-9_-]+)*)$")


def node_matches_simple(node, simple):
    """True/False, or None when the simple selector is beyond this parser."""
    m = SIMPLE_SEL_RE.match(simple)
    if not m or (not m.group(1) and not m.group(2)):
        return None
    tag, quals = m.group(1), m.group(2) or ""
    if tag and tag != "*" and node.tag != tag.lower():
        return False
    classes = set((node.get("class") or "").split())
    for q in re.findall(r"[.#][A-Za-z0-9_-]+", quals):
        if q[0] == "." and q[1:] not in classes:
            return False
        if q[0] == "#" and q[1:] != node.get("id"):
            return False
    return True


def selector_matches_node(selector, node):
    """Can this selector select this node? Unparseable pieces count as yes."""
    parts = [p for p in re.split(r"[\s>]+", selector.strip()) if p]
    if not parts:
        return False
    res = node_matches_simple(node, parts[-1])
    if res is None:
        return True
    if not res:
        return False
    ancestors = list(node.ancestors())
    idx = 0
    for part in reversed(parts[:-1]):
        matched = False
        while idx < len(ancestors):
            r = node_matches_simple(ancestors[idx], part)
            idx += 1
            if r is None:
                return True
            if r:
                matched = True
                break
        if not matched:
            return False
    return True


def hiding_selectors(stylesheets):
    """Plain selectors (tag/.class/#id, no combinators) that hide what they match.

    Only the simple case is resolved — the shipped template styles by class,
    so this is the form class-based hiding takes by accident. Compound
    selectors are left alone, and so are rules inside conditional @media
    blocks: wrongly hiding a section would reject a correct report.
    """
    sels = []
    for sheet in stylesheets:
        for selector, body in iter_style_rules(sheet, unconditional_only=True):
            if not HIDDEN_STYLE_RE.search(body):
                continue
            for part in selector.split(","):
                part = part.strip()
                if part and not re.search(r"[\s>+~\[:]", part):
                    sels.append(part)
    return sels


def is_hidden(node, hidden_sels=()):
    """Hidden by an inline style, the hidden attribute, or a plain
    stylesheet rule (tag/.class/#id) in the report's own <style>.

    Stylesheet hiding through compound selectors is NOT detected — see the
    threat model in the module docstring.
    """
    if "hidden" in node.attrs:
        return True
    if HIDDEN_STYLE_RE.search(node.get("style") or ""):
        return True
    return any(node_matches_simple(node, s) is True for s in hidden_sels)


def title_is_invisible(node):
    # A document <title> is chrome; an SVG <title> is read aloud, so it is
    # content and stays visible to the checks.
    return node.tag == "title" and not any(a.tag == "svg" for a in node.ancestors())


def is_invisible(node, hidden_sels=()):
    for n in [node] + list(node.ancestors()):
        if n.tag in INVISIBLE_TAGS or title_is_invisible(n):
            return True
        if is_hidden(n, hidden_sels):
            return True
    return False


def body_nodes(root, hidden_sels=()):
    """Document-order list of body elements and text nodes."""
    return [n for n in root.iter()
            if n is not root and not in_appendix(n)
            and not is_invisible(n, hidden_sels)]


def rendered_text(nodes):
    # Joined with a separator so adjacent nodes cannot fuse: <td>Ruby</td>
    # <td>3.4.10</td> must not become the phantom token "Ruby3.4.10".
    return "\n".join(n.text for n in nodes if n.tag == "#text")


# --- geometry ---------------------------------------------------------------


def char_width(ch, font_size):
    # "A" (East-Asian ambiguous: → ─ ± ① …) is wide here because the template
    # pins a CJK font family on figure text, where these render full width.
    wide = unicodedata.east_asian_width(ch) in ("W", "F", "A")
    return font_size * (WIDE_RATIO if wide else NARROW_RATIO)


def text_width(s, font_size):
    return sum(char_width(c, font_size) for c in s)


TRANSFORM_FUNC_RE = re.compile(rf"(translate|scale)\(\s*({NUM})\s*(?:[,\s]\s*({NUM})\s*)?\)")


def accumulated_transform(node, stop_tag="svg"):
    """Return (sx, dx, sy, dy, unsupported) for the chain of ancestors.

    Only translate and scale are understood. Anything else (rotate, matrix,
    skew) makes the position unmeasurable, and unmeasurable is reported as a
    failure rather than skipped — a silently skipped element is how the first
    version let genuine overflow through.

    Composition follows the order written: within one attribute the rightmost
    function applies to the point first, and a child's transform applies
    before its ancestors'. `scale(2) translate(150,0)` and
    `translate(300,0) scale(2)` therefore measure as the identical geometry
    they are.
    """
    sx = sy = 1.0
    dx = dy = 0.0
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
        # Innermost first: wrap the mapping built so far in each function.
        for m in reversed(list(TRANSFORM_FUNC_RE.finditer(t))):
            a = float(m.group(2))
            b = float(m.group(3)) if m.group(3) is not None else None
            if m.group(1) == "translate":
                dx += a
                dy += b if b is not None else 0.0
            else:
                ky = b if b is not None else a
                sx, dx = sx * a, dx * a
                sy, dy = sy * ky, dy * ky
    return sx, dx, sy, dy, unsupported


FONT_SIZE_STYLE_RE = re.compile(r"font-size\s*:\s*([^;}]+)", re.I)


def strict_selector_matches(selector, node):
    """Like selector_matches_node, but an unparseable piece counts as no.

    Used where a wrong yes would mis-measure (reading a font-size from a rule
    that does not actually apply), so the conservatism runs the other way
    from the preformatted scan.
    """
    parts = [p for p in re.split(r"[\s>]+", selector.strip()) if p]
    if not parts:
        return False
    if node_matches_simple(node, parts[-1]) is not True:
        return False
    ancestors = list(node.ancestors())
    idx = 0
    for part in reversed(parts[:-1]):
        matched = False
        while idx < len(ancestors):
            if node_matches_simple(ancestors[idx], part) is True:
                idx += 1
                matched = True
                break
            idx += 1
        if not matched:
            return False
    return True


def stylesheet_font_sizes(stylesheets):
    """(selector, px_or_None, raw) for font-size rules in the report's own
    <style>, the same stylesheet the hiding and preformatted scans already
    parse. Only unconditional screen rules contribute — a size that might
    not apply would mis-measure. A matched rule whose value is not an
    absolute px size carries px=None, which the caller reports as
    present-but-unmeasurable."""
    out = []
    for sheet in stylesheets:
        for selector, body in iter_style_rules(sheet, unconditional_only=True):
            m = FONT_SIZE_STYLE_RE.search(body)
            if not m:
                continue
            raw = m.group(1).strip()
            pm = re.fullmatch(r"([0-9]*\.?[0-9]+)px", raw)
            px = float(pm.group(1)) if pm else None
            for part in selector.split(","):
                part = part.strip()
                if part:
                    out.append((part, px, raw))
    return out


def inherited_font_size(node, css_sizes=()):
    """Return (px_size, raw_declaration) — either may be None.

    Only an absolute pixel size can be measured from markup alone. em, rem,
    %, pt are NOT converted to a small number — that would silently
    under-measure. They return (None, raw), which the caller reports as
    present-but-unmeasurable rather than absent.

    Per node, the cascade is honoured where it bites: the style attribute
    wins over the font-size presentation attribute (in CSS an inline style
    always beats a presentation attribute), and a plain rule from the
    report's own stylesheet is read when neither is present.
    """
    for n in [node] + list(node.ancestors()):
        raw = ""
        m = FONT_SIZE_STYLE_RE.search(n.get("style") or "")
        if m:
            raw = m.group(1).strip()
        if not raw:
            raw = (n.get("font-size") or "").strip()
        if raw:
            m = re.fullmatch(r"([0-9]*\.?[0-9]+)(px)?", raw)
            return (float(m.group(1)), raw) if m else (None, raw)
        hit = None
        for sel, px, sraw in css_sizes:
            if strict_selector_matches(sel, n):
                hit = (px, sraw)  # source order: the last matching rule wins
        if hit:
            return hit
        if n.tag == "svg":
            break
    return None, None


def inherited_text_anchor(node):
    # text-anchor inherits in SVG exactly as font-size does, so it is walked
    # the same way: <g text-anchor="middle"><text …> is a middle-anchored text.
    for n in [node] + list(node.ancestors()):
        v = (n.get("text-anchor") or "").strip()
        if v:
            return v
        if n.tag == "svg":
            break
    return "start"


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


def containing_rect(text_node, x, y, left, right, svg):
    """The <rect> in the same figure that plausibly IS this label's box.

    Preferred: the smallest rect that contains the anchor point AND the
    label's whole horizontal span — a rect a label fits inside can be its
    box. Fallback, when no rect contains the span: the smallest rect
    containing the anchor point alone. That is the genuine-overflow case —
    the label sticks out of every rect drawn under it — and it keeps a lone
    box binding its label.

    Without the span condition, a decorative one-colour highlight drawn
    behind the first phrase of a label (the emphasis form the skill's own
    SVG guidance suggests) captured the whole label and failed a figure
    that visibly sits inside its panel.

    The check that matters to a reader is whether a label fits its box, not
    whether it fits the canvas. The first version only compared against the
    viewBox, which left a wide window in which a label overflowed its box and
    still passed.
    """
    best_span = None
    best_anchor = None
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
        sx, dx, sy, dy, _ = accumulated_transform(r)
        rx, ry, rw, rh = rx * sx + dx, ry * sy + dy, rw * sx, rh * sy
        if rw <= 0 or rh <= 0:
            continue
        if rx <= x <= rx + rw and ry <= y <= ry + rh:
            if best_anchor is None or rw < best_anchor[1]:
                best_anchor = (rx, rw, r)
            if rx <= left + 0.5 and right <= rx + rw + 0.5:
                if best_span is None or rw < best_span[1]:
                    best_span = (rx, rw, r)
    return best_span or best_anchor


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


def svg_label_status(nodes):
    """'ok' when a figure carries a usable label, 'short' when every label a
    figure has is under MIN_FIGURE_LABEL characters, 'none' without a figure."""
    status = "none"
    for n in nodes:
        if n.tag != "svg":
            continue
        labels = [node_text(t).strip() for t in n.iter() if t.tag == "text"]
        labels = [s for s in labels if s]
        if any(len(s) >= MIN_FIGURE_LABEL for s in labels):
            return "ok"
        if labels:
            status = "short"
    return status


def has_worked_example(nodes):
    # Invariant 8 accepts 図・表・実際の値による具体例. A worked prose example
    # is declared, not inferred: <p data-example="values">…</p>.
    return any(n.get("data-example") == "values" and node_text(n).strip()
               for n in nodes)


# --- checks -----------------------------------------------------------------


def check_placeholders(text):
    hits = PLACEHOLDER_RE.findall(text)
    if not hits:
        return True, "unfilled placeholders: 0"
    sample = ", ".join(dict.fromkeys(hits[:5]))
    return False, f"unfilled placeholders: {len(hits)} -> {sample}"


def _declaration_covers(text, match, declared):
    """A declared string covers a matched token when it contains the token at
    the match position: declaring "v0.9" covers the "v0" the tokenizer sees in
    "v0.9". The author declares what they actually wrote, not the partial
    string the tokenizer stopped at."""
    tok = match.group(0)
    for d in declared:
        start = 0
        while True:
            k = d.find(tok, start)
            if k == -1:
                break
            s = match.start() - k
            if s >= 0 and text[s:s + len(d)] == d:
                return True
            start = k + 1
    return False


def check_tokens(text, declared):
    # Full-width spellings (Ｆ１ for F1) are what a Japanese input method
    # emits by default, so they are exactly the accident this check exists
    # for, not an accepted escape. NFKC-normalising body and declarations
    # makes the two spellings the same token.
    text = unicodedata.normalize("NFKC", text)
    declared = {unicodedata.normalize("NFKC", d) for d in declared}
    if len(declared) > MAX_DECLARED_TOKENS:
        return False, (f"{len(declared)} tokens declared in orientation-allowed-tokens; "
                       f"at most {MAX_DECLARED_TOKENS} may be. Declaring the "
                       "requirement away is not satisfying it")
    allowed = BUILTIN_ALLOWED_TOKENS | declared
    found = {}
    for m in TOKEN_RE.finditer(text):
        tok = m.group(0)
        if tok in allowed:
            continue
        if _declaration_covers(text, m, declared):
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
    """Ascii art misaligns in the reader's browser, whichever tag carries it.

    A stylesheet rule only counts when it can apply to a body node: a rule
    scoped to the collapsed appendix (`details pre`) or to print styles the
    reader's screen never uses does not preformat anything the reader sees.
    """
    hits = []
    for n in nodes:
        if n.tag == "pre":
            hits.append("<pre>")
        if PRE_STYLE_RE.search(n.get("style") or ""):
            hits.append(f"<{n.tag} style=white-space:pre>")
    elems = [n for n in nodes if n.tag != "#text"]
    for sheet in stylesheets:
        for selector, body in iter_style_rules(sheet):
            if not PRE_STYLE_RE.search(body):
                continue
            sels = [s.strip() for s in selector.split(",") if s.strip()]
            if any(selector_matches_node(s, n) for s in sels for n in elems):
                hits.append(f"a stylesheet rule ({selector!r}) sets white-space: pre "
                            "on body content")
    if not hits:
        return True, "preformatted blocks in body: 0"
    return False, (f"preformatted blocks in body: {len(hits)} "
                   f"-> {', '.join(dict.fromkeys(hits[:5]))} (use <svg> or <table>)")


def check_size(text, limit):
    # Runs of whitespace collapse to one character, as they do in the reader's
    # browser: markup indentation is not rendered text.
    n = len(" ".join(text.split()))
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
    short = []
    required = 0
    exempt = 0
    for s in sections:
        if s["heading"].get("data-visual") == "none":
            exempt += 1
            continue
        required += 1
        if has_content_table(s["nodes"]) or has_worked_example(s["nodes"]):
            continue
        status = svg_label_status(s["nodes"])
        if status == "ok":
            continue
        (short if status == "short" else missing).append(section_title(s))
    if exempt > MAX_EXEMPT_SECTIONS:
        return False, (f"{exempt} sections declare data-visual=\"none\"; at most "
                       f"{MAX_EXEMPT_SECTIONS} may. Declaring the requirement away "
                       "is not satisfying it")
    if required < MIN_VISUAL_SECTIONS:
        return False, (f"only {required} sections are subject to the visual "
                       f"requirement; at least {MIN_VISUAL_SECTIONS} must be")
    if not missing and not short:
        return True, f"sections carrying a filled figure or table: {required}/{required}"
    parts = []
    if missing:
        parts.append(f"sections without one: {len(missing)}/{required} -> "
                     + "; ".join(missing[:5]))
    if short:
        parts.append(f"sections whose figure has only labels shorter than the "
                     f"{MIN_FIGURE_LABEL}-character minimum: {len(short)}/{required} -> "
                     + "; ".join(short[:5]))
    return False, "; ".join(parts)


def check_svg_fit(nodes, stylesheets):
    problems = []
    tightest = None
    svgs = [n for n in nodes if n.tag == "svg"]
    measured = 0
    css_sizes = stylesheet_font_sizes(stylesheets)

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
                fs, fs_raw = inherited_font_size(holder, css_sizes)
                if fs is None and fs_raw is None:
                    fs, fs_raw = inherited_font_size(t, css_sizes)
                if fs is None:
                    if fs_raw is None:
                        problems.append(
                            f"figure {idx}: '{content[:28]}' has no font-size reachable "
                            "from its attributes, inline style, or the report's "
                            "stylesheet, so its width cannot be estimated")
                    else:
                        problems.append(
                            f"figure {idx}: '{content[:28]}' has font-size {fs_raw!r}, "
                            "which is present but not a unit measurable from markup "
                            "(use an absolute px size)")
                    continue
                # In SVG a missing x or y defaults to 0; a transform on an
                # ancestor often supplies the real position.
                x_attr = holder.get("x") if holder.get("x") is not None else t.get("x")
                y_attr = holder.get("y") if holder.get("y") is not None else t.get("y")
                try:
                    x = float(x_attr) if x_attr is not None else 0.0
                    y = float(y_attr) if y_attr is not None else 0.0
                except ValueError:
                    problems.append(f"figure {idx}: '{content[:28]}' has a non-numeric position")
                    continue

                sx, dx, sy, dy, unsupported = accumulated_transform(holder)
                if unsupported:
                    problems.append(
                        f"figure {idx}: '{content[:28]}' sits under an unsupported "
                        f"transform ({unsupported!r}); position cannot be measured")
                    continue
                x = x * sx + dx
                y = y * sy + dy

                anchor = inherited_text_anchor(holder)
                w = text_width(content, fs * sx)
                left = {"start": x, "middle": x - w / 2, "end": x - w}.get(anchor, x)
                right = left + w
                measured += 1

                box = containing_rect(t, x, y, left, right, svg)
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
    nodes = body_nodes(root, hiding_selectors(stylesheets))
    text = html_mod.unescape(rendered_text(nodes))
    sections = split_sections(nodes)

    return [
        ("no unfilled placeholders",) + check_placeholders(text),
        ("no undeclared work-internal tokens",) + check_tokens(text, declared_tokens(root)),
        ("no preformatted blocks",) + check_no_preformatted(nodes, stylesheets),
        ("body within length budget",) + check_size(text, max_chars),
        ("all sections present",) + check_section_count(sections),
        ("every section carries a filled visual",) + check_visuals(sections),
        ("figure labels fit their boxes",) + check_svg_fit(nodes, stylesheets),
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
