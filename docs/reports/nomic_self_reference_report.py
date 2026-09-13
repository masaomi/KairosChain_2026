#!/usr/bin/env python3
"""Build the HTML edition (ja + en) of the Minimum Nomic Bench self-reference report.

Charts are inline SVG so the file stays self-contained: no network, no JS, no
external assets. Every number carries its denominator in the label, so the
figure and the markdown edition cannot drift apart silently.

Usage:  python3 docs/reports/nomic_self_reference_report.py
Writes: docs/reports/nomic_bench_self_reference_report_20260913_{ja,en}.html
"""

import html
import pathlib

OUT = pathlib.Path(__file__).resolve().parent
DATE = "2026-09-13"
STEM = "nomic_bench_self_reference_report_20260913"

INK = "#1b1b1f"
DIM = "#5b6068"
LINE = "#d8dbe0"
PANEL = "#ffffff"
ACCENT = "#2f6f5e"
WARN = "#b4441e"
S1 = "#3b5f8a"
S2 = "#8a5a3b"
GREY = "#dfe3e8"
MONO = "ui-monospace,SFMono-Regular,Menlo,Consolas,monospace"


def esc(s):
    return html.escape(str(s), quote=False)


# --------------------------------------------------------------------------
# SVG chart helpers
# --------------------------------------------------------------------------

def _svg(w, h, body, cls="fig"):
    return (f'<svg class="{cls}" viewBox="0 0 {w} {h}" width="100%" '
            f'height="{h}" role="img" xmlns="http://www.w3.org/2000/svg">'
            f'{body}</svg>')


def _t(x, y, s, size=12.5, fill=DIM, anchor="start", weight="400", mono=False):
    fam = MONO if mono else "inherit"
    return (f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" '
            f'text-anchor="{anchor}" font-weight="{weight}" '
            f'font-family="{fam}">{esc(s)}</text>')


def hbar(rows, maxv, *, lab_w=210, val_w=150, bar_h=20, gap=13, color=ACCENT,
         title=None):
    """rows: [(label, value, display, color_override|None)]"""
    pad_t = 26 if title else 8
    h = pad_t + len(rows) * (bar_h + gap) + 6
    w = 860
    track = w - lab_w - val_w - 20
    b = []
    if title:
        b.append(_t(0, 14, title, 13, INK, weight="600"))
    y = pad_t
    for row in rows:
        label, value, disp = row[0], row[1], row[2]
        c = row[3] if len(row) > 3 and row[3] else color
        bw = 0 if maxv == 0 else max(1.5, track * value / maxv)
        b.append(_t(0, y + bar_h * 0.72, label, 13, INK))
        b.append(f'<rect x="{lab_w}" y="{y}" width="{track}" height="{bar_h}" '
                 f'fill="#eef0f3" rx="3"/>')
        b.append(f'<rect x="{lab_w}" y="{y}" width="{bw:.1f}" height="{bar_h}" '
                 f'fill="{c}" rx="3"/>')
        b.append(_t(lab_w + track + 12, y + bar_h * 0.72, disp, 12.5, DIM,
                    mono=True))
        y += bar_h + gap
    return _svg(w, h, "".join(b))


def ratiobar(rows, *, lab_w=270, bar_h=22, gap=14, title=None):
    """rows: [(label, numerator, denominator, display, color)]"""
    pad_t = 26 if title else 8
    h = pad_t + len(rows) * (bar_h + gap) + 6
    w = 860
    track = w - lab_w - 210
    b = []
    if title:
        b.append(_t(0, 14, title, 13, INK, weight="600"))
    y = pad_t
    for label, num, den, disp, c in rows:
        bw = 0 if den == 0 else track * num / den
        b.append(_t(0, y + bar_h * 0.72, label, 13, INK))
        b.append(f'<rect x="{lab_w}" y="{y}" width="{track}" height="{bar_h}" '
                 f'fill="#eef0f3" rx="3"/>')
        if bw > 0:
            b.append(f'<rect x="{lab_w}" y="{y}" width="{bw:.1f}" '
                     f'height="{bar_h}" fill="{c}" rx="3"/>')
        else:
            b.append(f'<rect x="{lab_w}" y="{y+bar_h/2-1.5}" width="{track}" '
                     f'height="3" fill="{c}" opacity=".55"/>')
        b.append(_t(lab_w + track + 12, y + bar_h * 0.72, disp, 12.5, DIM,
                    mono=True))
        y += bar_h + gap
    return _svg(w, h, "".join(b))


def diverging(rows, *, lo=-2.5, hi=1.5, lab_w=200, bar_h=20, gap=13,
              zero_label="0"):
    """rows: [(label, value, display)] centred on zero."""
    w, pad_t = 860, 30
    h = pad_t + len(rows) * (bar_h + gap) + 24
    track = w - lab_w - 150
    span = hi - lo

    def X(v):
        return lab_w + track * (v - lo) / span

    b = [f'<line x1="{X(0):.1f}" y1="{pad_t-8}" x2="{X(0):.1f}" '
         f'y2="{pad_t + len(rows)*(bar_h+gap)}" stroke="{INK}" '
         f'stroke-width="1.2"/>',
         _t(X(0), pad_t - 14, zero_label, 11.5, DIM, anchor="middle", mono=True)]
    y = pad_t
    for label, value, disp in rows:
        x0, x1 = (X(0), X(value)) if value >= 0 else (X(value), X(0))
        c = ACCENT if value >= 0 else WARN
        b.append(_t(0, y + bar_h * 0.72, label, 13, INK))
        b.append(f'<rect x="{x0:.1f}" y="{y}" width="{max(1.5, x1-x0):.1f}" '
                 f'height="{bar_h}" fill="{c}" rx="3"/>')
        b.append(_t(lab_w + track + 12, y + bar_h * 0.72, disp, 12.5, DIM,
                    mono=True))
        y += bar_h + gap
    return _svg(w, h, "".join(b))


def dumbbell(rows, *, lo=3.5, hi=7.5, lab_w=185, row_h=34, left_lab="",
             right_lab=""):
    """rows: [(label, predicted, measured, error_display)]"""
    w, pad_t = 860, 44
    h = pad_t + len(rows) * row_h + 22
    track = w - lab_w - 130
    span = hi - lo

    def X(v):
        return lab_w + track * (v - lo) / span

    b = []
    # axis
    b.append(f'<line x1="{lab_w}" y1="{pad_t-16}" x2="{lab_w+track}" '
             f'y2="{pad_t-16}" stroke="{LINE}" stroke-width="1"/>')
    v = lo
    while v <= hi + 1e-9:
        b.append(f'<line x1="{X(v):.1f}" y1="{pad_t-20}" x2="{X(v):.1f}" '
                 f'y2="{pad_t-12}" stroke="{LINE}" stroke-width="1"/>')
        b.append(_t(X(v), pad_t - 26, f"{v:g}", 11, DIM, anchor="middle",
                    mono=True))
        v += 0.5
    b.append(_t(0, pad_t - 26, left_lab, 11.5, DIM))
    y = pad_t + 6
    for label, pred, meas, err in rows:
        xp, xm = X(pred), X(meas)
        b.append(_t(0, y + 4, label, 13, INK))
        b.append(f'<line x1="{xp:.1f}" y1="{y}" x2="{xm:.1f}" y2="{y}" '
                 f'stroke="{GREY}" stroke-width="6" stroke-linecap="round"/>')
        b.append(f'<circle cx="{xp:.1f}" cy="{y}" r="6.5" fill="{WARN}"/>')
        b.append(f'<circle cx="{xm:.1f}" cy="{y}" r="6.5" fill="{ACCENT}"/>')
        b.append(_t(xp, y - 12, f"{pred:.2f}", 11, WARN, anchor="middle",
                    mono=True))
        b.append(_t(xm, y - 12, f"{meas:.2f}", 11, ACCENT, anchor="middle",
                    mono=True))
        b.append(_t(lab_w + track + 14, y + 4, err, 12.5, INK, mono=True,
                    weight="600"))
        y += row_h
    b.append(f'<circle cx="{lab_w+2}" cy="{h-8}" r="5" fill="{WARN}"/>')
    b.append(_t(lab_w + 12, h - 4, right_lab, 11.5, DIM))
    return _svg(w, h, "".join(b))


def stripplot(groups, *, lo=0, hi=50, lab_w=200, row_h=32, axis_label=""):
    """groups: [(label, [values], colour)] — small-n dot strip."""
    w, pad_t = 860, 40
    h = pad_t + len(groups) * row_h + 18
    track = w - lab_w - 120

    def X(v):
        return lab_w + track * (v - lo) / (hi - lo)

    b = [f'<line x1="{lab_w}" y1="{pad_t-16}" x2="{lab_w+track}" '
         f'y2="{pad_t-16}" stroke="{LINE}"/>']
    for v in range(lo, hi + 1, 10):
        b.append(f'<line x1="{X(v):.1f}" y1="{pad_t-20}" x2="{X(v):.1f}" '
                 f'y2="{pad_t-12}" stroke="{LINE}"/>')
        b.append(_t(X(v), pad_t - 26, str(v), 11, DIM, anchor="middle",
                    mono=True))
    b.append(_t(0, pad_t - 26, axis_label, 11.5, DIM))
    y = pad_t + 6
    for label, values, c in groups:
        b.append(_t(0, y + 4, label, 13, INK))
        b.append(f'<line x1="{lab_w}" y1="{y}" x2="{lab_w+track}" y2="{y}" '
                 f'stroke="#f0f2f4" stroke-width="1"/>')
        for v in values:
            b.append(f'<circle cx="{X(v):.1f}" cy="{y}" r="7" fill="{c}"/>')
            b.append(_t(X(v), y + 3.5, str(v), 10, "#fff", anchor="middle",
                        mono=True, weight="700"))
        b.append(_t(lab_w + track + 14, y + 4, f"n={len(values)}", 12, DIM,
                    mono=True))
        y += row_h
    return _svg(w, h, "".join(b))


def leakbars(rows, *, lab_w=70, bar_h=24, gap=12, legend=("", "")):
    """rows: [(game, leaked, total, instances, is_control)]"""
    w, pad_t = 860, 30
    h = pad_t + len(rows) * (bar_h + gap) + 30
    track = w - lab_w - 300
    maxv = max(r[2] for r in rows)
    b = []
    y = pad_t
    for game, leaked, total, inst, ctrl in rows:
        full = track * total / maxv
        leak = track * leaked / maxv
        b.append(_t(0, y + bar_h * 0.72, game, 13, INK, mono=True,
                    weight="600"))
        b.append(f'<rect x="{lab_w}" y="{y}" width="{full:.1f}" '
                 f'height="{bar_h}" fill="{GREY}" rx="2"/>')
        if leak > 0:
            b.append(f'<rect x="{lab_w}" y="{y}" width="{leak:.1f}" '
                     f'height="{bar_h}" fill="{WARN}" rx="2"/>')
        pct = 100.0 * leaked / total
        txt = f"{leaked:>7,} / {total:>7,}  = {pct:4.1f}%   {inst} x"
        b.append(_t(lab_w + track + 16, y + bar_h * 0.72, txt, 12, DIM,
                    mono=True))
        if ctrl:
            b.append(_t(w - 8, y + bar_h * 0.72, "control", 11.5, ACCENT,
                        anchor="end", weight="600"))
        y += bar_h + gap
    b.append(f'<rect x="{lab_w}" y="{h-16}" width="11" height="11" '
             f'fill="{WARN}" rx="2"/>')
    b.append(_t(lab_w + 17, h - 6, legend[0], 11.5, DIM))
    b.append(f'<rect x="{lab_w+230}" y="{h-16}" width="11" height="11" '
             f'fill="{GREY}" rx="2"/>')
    b.append(_t(lab_w + 247, h - 6, legend[1], 11.5, DIM))
    return _svg(w, h, "".join(b))


def scoregrid(cols, rows, cells, *, hi_col=3, note=""):
    """cells: list of rows, each list of ints. Darker = higher score."""
    cw, ch, lab_w, pad_t = 118, 36, 200, 34
    w = lab_w + len(cols) * cw + 16
    h = pad_t + len(rows) * ch + 44
    b = []
    for j, c in enumerate(cols):
        x = lab_w + j * cw + cw / 2
        b.append(_t(x, pad_t - 12, c, 12, INK if j != hi_col else WARN,
                    anchor="middle", weight="600" if j == hi_col else "400"))
    y = pad_t
    for i, r in enumerate(rows):
        b.append(_t(0, y + ch * 0.66, r, 12.5, INK, mono=True))
        for j, v in enumerate(cells[i]):
            x = lab_w + j * cw
            o = 0.12 + 0.085 * v
            fill = WARN if j == hi_col else S1
            b.append(f'<rect x="{x+3}" y="{y+3}" width="{cw-6}" '
                     f'height="{ch-6}" fill="{fill}" opacity="{o:.2f}" '
                     f'rx="3"/>')
            b.append(_t(x + cw / 2, y + ch * 0.68, str(v), 14,
                        "#fff" if v >= 6 else INK, anchor="middle",
                        mono=True, weight="700"))
        y += ch
    b.append(f'<rect x="{lab_w + hi_col*cw + 1}" y="{pad_t+1}" '
             f'width="{cw-2}" height="{len(rows)*ch-2}" fill="none" '
             f'stroke="{WARN}" stroke-width="2" rx="4"/>')
    b.append(_t(lab_w, h - 10, note, 12, WARN, weight="600"))
    return _svg(w, h, "".join(b))


def two_self_ref(labels):
    """The central diagram: game self-reference requires measurement self-reference."""
    w, h = 860, 430
    b = []
    # Box 1
    b.append(f'<rect x="30" y="12" width="800" height="150" rx="8" '
             f'fill="{PANEL}" stroke="{S1}" stroke-width="2"/>')
    b.append(f'<rect x="30" y="12" width="800" height="30" rx="8" fill="{S1}"/>')
    b.append(f'<rect x="30" y="34" width="800" height="8" fill="{S1}"/>')
    b.append(_t(46, 33, labels["b1_title"], 14, "#fff", weight="700"))
    b.append(_t(46, 72, labels["b1_l1"], 14.5, INK, weight="600"))
    b.append(_t(46, 96, labels["b1_l2"], 13, DIM))
    b.append(f'<line x1="46" y1="110" x2="814" y2="110" stroke="{LINE}"/>')
    b.append(_t(46, 132, labels["b1_l3"], 14, S1, weight="700"))
    b.append(_t(46, 152, labels["b1_l4"], 12.5, DIM, mono=True))
    # Arrow
    b.append(f'<path d="M430 162 L430 196" stroke="{INK}" stroke-width="2.5"/>')
    b.append(f'<path d="M420 190 L430 204 L440 190 Z" fill="{INK}"/>')
    b.append(_t(448, 186, labels["arrow"], 13.5, INK, weight="700"))
    # Box 2
    b.append(f'<rect x="30" y="210" width="800" height="205" rx="8" '
             f'fill="{PANEL}" stroke="{S2}" stroke-width="2"/>')
    b.append(f'<rect x="30" y="210" width="800" height="30" rx="8" fill="{S2}"/>')
    b.append(f'<rect x="30" y="232" width="800" height="8" fill="{S2}"/>')
    b.append(_t(46, 231, labels["b2_title"], 14, "#fff", weight="700"))
    b.append(_t(46, 268, labels["b2_l1"], 14.5, INK, weight="600"))
    b.append(_t(46, 290, labels["b2_l2"], 13, DIM))
    # the loop
    cy = 356
    b.append(f'<rect x="70" y="{cy-22}" width="210" height="44" rx="6" '
             f'fill="#f3f5f7" stroke="{LINE}"/>')
    b.append(_t(175, cy + 5, labels["loop_act"], 13, INK, anchor="middle",
                weight="600"))
    b.append(f'<rect x="560" y="{cy-22}" width="210" height="44" rx="6" '
             f'fill="#f3f5f7" stroke="{LINE}"/>')
    b.append(_t(665, cy + 5, labels["loop_key"], 13, INK, anchor="middle",
                weight="600"))
    b.append(f'<path d="M280 {cy-8} L552 {cy-8}" stroke="{S2}" '
             f'stroke-width="2.2"/>')
    b.append(f'<path d="M546 {cy-14} L560 {cy-8} L546 {cy-2} Z" fill="{S2}"/>')
    b.append(_t(416, cy - 16, labels["loop_rec"], 12, S2, anchor="middle",
                weight="600"))
    b.append(f'<path d="M560 {cy+10} L288 {cy+10}" stroke="{S2}" '
             f'stroke-width="2.2"/>')
    b.append(f'<path d="M294 {cy+4} L280 {cy+10} L294 {cy+16} Z" fill="{S2}"/>')
    b.append(_t(416, cy + 26, labels["loop_chk"], 12, S2, anchor="middle",
                weight="600"))
    return _svg(w, h, "".join(b))


def matrix2x2(labels):
    """material x question -> outcome."""
    w, h = 860, 260
    cw, chh, x0, y0 = 320, 74, 200, 58
    b = [_t(x0 + cw / 2, 30, labels["col1"], 13, INK, anchor="middle",
            weight="700"),
         _t(x0 + cw + cw / 2, 30, labels["col2"], 13, INK, anchor="middle",
            weight="700")]
    rows = [(labels["row1"], labels["c11"], labels["c12"], labels["r1n1"],
             labels["r1n2"]),
            (labels["row2"], labels["c21"], labels["c22"], labels["r2n1"],
             labels["r2n2"])]
    for i, (rl, c1, c2, n1, n2) in enumerate(rows):
        y = y0 + i * (chh + 16)
        b.append(_t(0, y + chh / 2 + 4, rl, 13, INK, weight="700"))
        for j, (txt, num) in enumerate([(c1, n1), (c2, n2)]):
            x = x0 + j * cw
            good = "15" in num or "0.19" in num or ("/" in num and
                                                    txt == labels["c22"])
            fill = "#eef4f2" if txt == labels["c22"] else "#fdf1ec"
            edge = ACCENT if txt == labels["c22"] else WARN
            if txt == labels["c11"]:
                fill, edge = "#f5f5f7", DIM
            b.append(f'<rect x="{x+6}" y="{y}" width="{cw-12}" '
                     f'height="{chh}" rx="6" fill="{fill}" stroke="{edge}" '
                     f'stroke-width="1.6"/>')
            b.append(_t(x + cw / 2, y + 30, txt, 13.5, INK, anchor="middle",
                        weight="700"))
            b.append(_t(x + cw / 2, y + 52, num, 12, DIM, anchor="middle",
                        mono=True))
    return _svg(w, h, "".join(b))


# --------------------------------------------------------------------------
# Page
# --------------------------------------------------------------------------

CSS = f"""
:root{{--ink:{INK};--dim:{DIM};--line:{LINE};--bg:#fbfbfc;--panel:{PANEL};
  --accent:{ACCENT};--warn:{WARN};--hi:#f6efd8;--s1:{S1};--s2:{S2};
  --mono:{MONO}}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--ink);
  font:16px/1.8 "Hiragino Sans","Yu Gothic",-apple-system,system-ui,sans-serif}}
.wrap{{max-width:940px;margin:0 auto;padding:0 24px 120px}}
header{{border-bottom:3px solid var(--ink);margin-bottom:10px;padding:44px 0 18px}}
h1{{font-size:28px;margin:0 0 10px;line-height:1.45}}
.sub{{color:var(--dim);font-size:14px}}
h2{{font-size:22px;margin:60px 0 18px;padding-bottom:9px;
  border-bottom:1px solid var(--line)}}
h3{{font-size:17.5px;margin:34px 0 13px;color:var(--accent)}}
p{{margin:0 0 15px}}
b,strong{{background:var(--hi);padding:1px 4px;border-radius:2px}}
pre{{background:#22252b;color:#e6e9ef;padding:18px 20px;border-radius:6px;
  overflow-x:auto;font:13px/1.7 var(--mono);margin:0 0 20px}}
pre.light{{background:var(--panel);color:var(--ink);border:1px solid var(--line)}}
code{{font:13.5px var(--mono);background:#eceef1;padding:1px 5px;border-radius:3px}}
pre code{{background:none;padding:0;font-size:inherit;color:inherit}}
table{{border-collapse:collapse;width:100%;margin:0 0 22px;font-size:14px;
  background:var(--panel)}}
th,td{{border:1px solid var(--line);padding:8px 11px;text-align:left;
  vertical-align:top}}
th{{background:#f0f2f4;font-weight:600;font-size:13px}}
td.num{{text-align:right;font-family:var(--mono);font-size:13px;white-space:nowrap}}
.bad{{color:var(--warn);font-weight:700}}
.good{{color:var(--accent);font-weight:700}}
.ctrl td{{background:#eef4f2}}
figure{{margin:0 0 26px;background:var(--panel);border:1px solid var(--line);
  border-radius:8px;padding:18px 20px 14px}}
figure svg{{display:block;max-width:100%;height:auto}}
figcaption{{font-size:12.5px;color:var(--dim);margin-top:10px;
  padding-top:9px;border-top:1px solid var(--line)}}
.note{{border-left:4px solid var(--accent);background:var(--panel);
  padding:14px 18px;margin:0 0 20px;font-size:14.5px}}
.note.warn{{border-left-color:var(--warn)}}
.note.open{{border-left-color:var(--s2);background:#fdfaf7}}
.quote{{border-left:4px solid var(--ink);background:var(--panel);
  padding:16px 20px;margin:0 0 20px;font-size:14.5px}}
.kpi{{display:flex;gap:14px;flex-wrap:wrap;margin:0 0 24px}}
.kpi div{{flex:1 1 190px;background:var(--panel);border:1px solid var(--line);
  border-radius:6px;padding:15px 17px}}
.kpi .n{{font:700 27px/1.2 var(--mono);color:var(--accent)}}
.kpi .n.red{{color:var(--warn)}}
.kpi .l{{font-size:12.5px;color:var(--dim);margin-top:5px;line-height:1.6}}
.tag{{display:inline-block;font-size:11.5px;padding:1px 9px;border-radius:10px;
  color:#fff;font-family:var(--mono);vertical-align:middle;margin-right:6px}}
.tag.s1{{background:var(--s1)}} .tag.s2{{background:var(--s2)}}
nav{{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);
  padding:11px 0;z-index:10;font-size:13px;margin-bottom:8px}}
nav a{{color:var(--dim);text-decoration:none;margin-right:15px;
  white-space:nowrap;display:inline-block}}
nav a:hover{{color:var(--accent);text-decoration:underline}}
.lang{{float:right;font-size:12.5px}}
footer{{margin-top:70px;padding-top:22px;border-top:1px solid var(--line);
  color:var(--dim);font-size:13px}}
@media (max-width:720px){{figure{{padding:12px 10px 10px}}h1{{font-size:23px}}}}
"""


def build(lang):
    ja = lang == "ja"

    def t(j, e):
        return j if ja else e

    F = []          # figure counter
    def fig(svg, cap):
        F.append(1)
        return (f'<figure>{svg}<figcaption>'
                f'<b>{t("図", "Fig.")} {len(F)}</b> — {cap}</figcaption></figure>')

    # ---- figure 1: two self-references
    f1 = two_self_ref({
        "b1_title": t("自己言及性 ①  場", "SELF-REFERENCE I — the GAME"),
        "b1_l1": t("Nomic は「ルールを書き換えること」がルールである",
                   "In Nomic, changing the rules IS the rule"),
        "b1_l2": t("何が正しいかが、ゲームの中で動き続ける",
                   "what counts as correct keeps moving inside play"),
        "b1_l3": t("→ 正解表を原理的に置けない",
                   "→ no answer key can be placed there, in principle"),
        "b1_l4": t("勝利条件なし ・ 終了規則なし ・ 得点なし ・ 裁定なし",
                   "no victory condition  ·  no termination rule  ·  "
                   "no scoring  ·  no adjudicator"),
        "arrow": t("が、下を要求する", "requires"),
        "b2_title": t("自己言及性 ②  測り方",
                      "SELF-REFERENCE II — the MEASUREMENT"),
        "b2_l1": t("外から正解が来ないなら、答え合わせに使えるのは"
                   "「そのモデルが実際にやったこと」しか残らない",
                   "with no answer from outside, the only thing left to check "
                   "against is what the model actually did"),
        "b2_l2": t("この報告の 136 本の呼び出しはすべてこの形をとる。"
                   "外から来る正解は一つも使っていない",
                   "all 136 calls in this report take this form. "
                   "Not one correct answer comes from outside"),
        "loop_act": t("モデルが実際にやったこと", "what the model did"),
        "loop_key": t("答え合わせの相手", "the answer key"),
        "loop_rec": t("記録される", "recorded as"),
        "loop_chk": t("同じモデルの自己記述と照合する",
                      "checked against the same model's self-description"),
    })

    # ---- figure 2: score grid
    f2 = scoregrid(
        [t("参加者A", "player A"), t("参加者B", "player B"),
         t("参加者C", "player C"), t("進行役", "game master")],
        ["claude-opus-4-6", "claude-opus-5", "composer-2.5", "gpt-5.6-sol"],
        [[4, 7, 6, 4], [7, 8, 8, 9], [6, 7, 8, 5], [6, 8, 9, 4]],
        note=t("同じ振る舞いに 4 点と 9 点",
               "identical conduct scored 4 and 9"))

    # ---- figure 3: what moved the score
    f3 = hbar([(t("採点者を変えたとき", "changing the judge"), 1.94,
                t("1.94 点", "1.94 pts"), WARN),
               (t("基準を変えたとき", "changing the standard"), 1.12,
                t("1.12 点", "1.12 pts"), S1)],
              2.2, lab_w=250, val_w=120)

    # ---- figure 4: judge divergence
    f4 = diverging([("claude-opus-4-6", -1.94, "−1.94"),
                    ("gpt-5.6-sol", 0.28, "+0.28"),
                    ("composer-2.5", 0.66, "+0.66"),
                    ("claude-opus-5", 0.99, "+0.99")],
                   zero_label=t("他 3 体の平均", "mean of the other three"))

    # ---- figure 5: self-recognition
    f5 = ratiobar([
        (t("自分の文を「自分のだ」と言えた", "own items claimed as own"),
         59, 66, "59 / 66", ACCENT),
        (t("他人の文を「自分のだ」と言った", "another's items claimed as own"),
         0, 198, "0 / 198", WARN),
    ], lab_w=310)

    # ---- figure 6: dumbbell
    f6 = dumbbell([("claude-opus-4-6", 4.08, 4.57, "−0.49"),
                   ("claude-opus-5", 4.14, 6.77, "−2.63"),
                   ("composer-2.5", 5.06, 6.52, "−1.46"),
                   ("gpt-5.6-sol", 4.46, 6.24, "−1.78")],
                  left_lab=t("点", "score"),
                  right_lab=t("赤 = 自己予測   緑 = 実測",
                              "red = predicted by itself    green = measured"))

    # ---- figure 7: error comparison
    f7 = hbar([(t("材料なし 「自分の平均は何点か」",
                  "no material — 'what will your mean be?'"), 2.8,
                t("1.4 〜 2.8 点  (4 体中 3 体)",
                  "1.4 - 2.8 pts  (3 of 4 models)"), WARN),
               (t("材料あり 「この分析は何点つけたか」",
                  "material present — 'what scores did this give?'"), 0.19,
                t("0.19 点  (48 点中 41 点が完全一致)",
                  "0.19 pts  (41 of 48 exact)"), ACCENT)],
              2.8, lab_w=330, val_w=230)

    # ---- figure 8: dissociation in one model
    f8 = ratiobar([
        (t("著者 22 本の仕分け（頼まれていない）",
           "sorting 22 items by author (unasked)"), 22, 22, "22 / 22", ACCENT),
        (t("自分のつけた点の読み戻し", "reading back its own scores"),
         12, 12, "12 / 12", ACCENT),
        (t("これから自分がつける点の予測",
           "predicting the scores it is about to give"), 0, 1,
         t("2.63 点 外し（4 体中最悪）", "off by 2.63 (worst of four)"), WARN),
    ], lab_w=330)

    # ---- figure 9: goal creation
    f9 = ratiobar([
        (t("最初の発言者が新しい規則を提案した",
           "the first speaker proposed a new rule"), 24, 24, "24 / 24", S1),
        (t("第一手で「得点」と「勝利」を発明した",
           "that first move invented scoring and victory"), 14, 24,
         "14 / 24", S1),
        (t("プレイヤーが終了規則を自作し、進行役が止めた（第二系列）",
           "players wrote a termination rule, the GM stopped (series 2)"),
         2, 6, "2 / 6", S2),
    ], lab_w=390)

    # ---- figure 10: game length strip (weak evidence)
    f10 = stripplot([("gpt-5.6-sol", [7, 12], S1),
                     ("claude-opus-5", [16], S1),
                     ("composer-2.5", [39, 43], S1)],
                    axis_label=t("続いた手番", "turns played"))

    # ---- figure 11: leak bars
    f11 = leakbars([("a1", 65885, 185074, 7, False),
                    ("a2", 13520, 42068, 1, False),
                    ("a3", 0, 112837, 0, True),
                    ("b1", 457661, 748177, 8, False),
                    ("b2", 0, 90444, 0, True),
                    ("b3", 85664, 230109, 8, False)],
                   legend=(t("公開ログに漏れた思考", "leaked thought"),
                           t("本来の公開発話", "intended public utterances")))

    # ---- figure 12: asked vs not asked
    f12 = ratiobar([
        (t("プレイヤー（対局中・問われていない）",
           "players (mid-game, not asked)"), 0, 24, "0 / 24", WARN),
        (t("分析役（対局後・問われていない）",
           "analysts (post-game, not asked)"), 0, 16, "0 / 16", WARN),
        (t("分析役（同じ材料 ＋ 問いを一文）",
           "analysts (same material + one sentence of question)"),
         15, 18, "15 / 18", ACCENT),
        (t("対照 2 局・漏れ 0 件（誤検出しないか）",
           "controls, 2 games with 0 leaks (false positives?)"),
         6, 6, t("6 / 6 が「異常なし」", "6 / 6 correctly 'none'"), ACCENT),
    ], lab_w=360)

    # ---- figure 13: 2x2
    f13 = matrix2x2({
        "col1": t("問われない", "no question pointed at it"),
        "col2": t("問われる", "a question pointed at it"),
        "row1": t("材料なし", "no material"),
        "row2": t("材料あり", "material present"),
        "c11": t("—（実験していない）", "— (not run)"),
        "c12": t("既定の自己記述が出る", "a default self-description"),
        "c21": t("素通りする", "passes straight over it"),
        "c22": t("ほぼ完璧に読む", "reads it near-perfectly"),
        "r1n1": "",
        "r1n2": t("「私は辛口だ」20 / 20、自己予測は 4 体とも外れ",
                  "'I am harsh' 20/20 — all four mispredict"),
        "r2n1": t("露出 0/16 ・ プレイヤー D 0/15",
                  "exposure 0/16  ·  player D 0/15"),
        "r2n2": t("読み戻し 誤差 0.19 点 ・ 露出 15/18",
                  "readback error 0.19  ·  exposure 15/18"),
    })

    # ------------------------------------------------------------------
    nav_items = [
        (t("二つの自己言及性", "Two self-references"), "s1"),
        (t("直接測れない理由", "Why not directly"), "s2"),
        (t("反転", "The inversion"), "s3"),
        (t("場", "The game"), "s4"),
        (t("彼らが作ったもの", "What they built"), "s5"),
        (t("結果", "Results"), "s6"),
        (t("循環という反論", "Circularity"), "s7"),
        (t("問われなければ見ない", "Unasked"), "s8"),
        (t("装置を直さない", "Not repairing"), "s9"),
        (t("先行研究", "Literature"), "s10"),
        (t("主張できないこと", "Cannot claim"), "s11"),
        (t("次に", "Next"), "s12"),
    ]
    nav = "".join(f'<a href="#{i}">{esc(n)}</a>' for n, i in nav_items)
    other = "en" if ja else "ja"
    nav += (f'<span class="lang"><a href="{STEM}_{other}.html">'
            f'{"English" if ja else "日本語"}</a></span>')

    P = []
    A = P.append

    A(f'<header><h1>{t("正解表のない場で、自分の行為を答えにする", "Where there is no answer key, use the model&rsquo;s own act as one")}</h1>'
      f'<div class="sub">{t("二つの自己言及性 — Minimum Nomic Bench 総合報告", "Two self-references — Minimum Nomic Bench, integrated report")}<br>'
      f'畠山 剛臣 (Masaomi Hatakeyama) / {DATE}</div></header>')
    A(f'<nav>{nav}</nav>')

    # 0
    A(f'<h2 id="s0">{t("0. 一行でいうと", "0. In one line")}</h2>')
    A(t('<p>言語モデルのメタ認知は、<b>直接には測れない</b>。'
        '「あなたは自分をどう監視していますか」と聞いても、返ってくるのは'
        '照らし合わせる先を持たない文にすぎない。だから道を変えた。'
        '<b>そのモデル自身が過去に実際にやったことを、答え合わせの相手に使う。</b>'
        '外から正解を一つも持ち込まずに測る。</p>'
        '<p>これを、<b>正解が原理的に定まらない場</b>でやった。'
        'ルールを書き換えることがルールになっているゲーム、Nomic である。</p>'
        '<p>自己言及性が二重にある。ここがこの報告の主題である。</p>',
        '<p>Metacognition in a language model <b>cannot be measured '
        'directly.</b> Ask &ldquo;how do you monitor yourself?&rdquo; and what '
        'comes back is text with nothing to check it against. So take another '
        'route. <b>Use what that same model actually did, on the record, as '
        'the answer key.</b> Measure without importing a single correct answer '
        'from outside.</p>'
        '<p>Do this in <b>a setting where correctness cannot be settled in '
        'principle</b> &mdash; a game in which changing the rules is the game. '
        'Nomic.</p>'
        '<p>The self-reference is doubled. That is the subject of this '
        'report.</p>'))

    A('<div class="kpi">'
      f'<div><div class="n">136</div><div class="l">{t("呼び出し。失敗 0。すべて答え合わせの相手が本人の行為", "calls, 0 failed. In every one, the key is the model&rsquo;s own act")}</div></div>'
      f'<div><div class="n red">0 / 198</div><div class="l">{t("他人の文を自分のだと誤認した数 — 自分の文はわかる", "another&rsquo;s writing claimed as own &mdash; they know their own")}</div></div>'
      f'<div><div class="n red">2.63</div><div class="l">{t("同じモデルが、これから自分がつける点を外した幅（点）", "points by which the same model missed what it was about to score")}</div></div>'
      f'<div><div class="n">24 / 24</div><div class="l">{t("誰も「勝て」と言っていない場で、最初の一手が規則を提案した局", "games where the first move proposed a rule &mdash; nobody said &ldquo;win&rdquo;")}</div></div>'
      '</div>')

    # 1
    A(f'<h2 id="s1">{t("1. 二つの自己言及性", "1. Two self-references")}</h2>')
    A(t('<p>同じ言葉が二つの別のものを指すので、最初に名前を分けておく。</p>',
        '<p>One word points at two different things here, so name them apart '
        'first.</p>'))
    A(fig(f1, t("上が下を要求している。偶然重なっているのではない。"
                "場が自己言及的だから正解が定まらず、正解が定まらないから、"
                "答えに使えるのは本人の行為だけになる。",
                "The first requires the second; they are not coincidentally "
                "stacked. Because the arena is self-referential, correctness "
                "does not settle; because correctness does not settle, nothing "
                "but the model's own act remains available as a key.")))

    # 2
    A(f'<h2 id="s2">{t("2. なぜ直接測れないのか", "2. Why it cannot be measured directly")}</h2>')
    A(f'<h3>{t("2.1 自己申告は証拠にならない", "2.1 Self-report is not evidence")}</h3>')
    A(t('<p>言語モデルの内部で何が起きているかは、利用者からは見えない。'
        '見えるのは入れた文と返ってきた文だけである。「私はこう考えた」という'
        '自己申告も、返ってきた文の一部にすぎない。'
        '<b>照らし合わせる先を持たない自己申告は、証拠にならない。</b></p>'
        '<p>これは本報告の思いつきではない。2023 年の 2 本'
        '（arXiv:2305.04388、arXiv:2307.13702）が、思考の筋道として書かれた文が'
        '実際に答えを決めた要因と一致しないことを示し、以後この分野では'
        '自己報告をそのまま証拠に使えなくなっている。</p>',
        '<p>What happens inside a language model is not visible to its user. '
        'Only the text sent in and the text returned are observable. '
        '&ldquo;This is what I thought&rdquo; is just more returned text. '
        '<b>A self-report with nothing to check it against is not '
        'evidence.</b></p>'
        '<p>This is not a notion invented here. Two 2023 papers '
        '(arXiv:2305.04388, arXiv:2307.13702) showed that text written as a '
        'chain of reasoning does not match the factors that actually '
        'determined the answer. Since then the field cannot take self-report '
        'as evidence at face value.</p>'))

    A(f'<h3>{t("2.2 では「メタ認知を採点させる」なら — 失敗した", "2.2 Then have a model score metacognition? &mdash; it failed")}</h3>')
    A(t('<p>最初は素直な方法をとった。終わった対局を別のモデルに読ませ、'
        '参加者のメタ認知的な能力を 0〜10 点で採点させる。<b>これは失敗した。</b></p>',
        '<p>The first attempt was the obvious one: have another model read a '
        'finished game and score each participant&rsquo;s metacognitive '
        'competence 0&ndash;10. <b>It failed.</b></p>'))
    A(fig(f2, t("対局 inv29_g3 を、同じ 1 つの基準で、4 体の分析役が採点した。"
                "濃いほど高い点。進行役の欄では、まったく同じ振る舞いに "
                "claude-opus-4-6 と gpt-5.6-sol が 4 点、claude-opus-5 が 9 点を"
                "つけた。",
                "Game inv29_g3 scored by four analysts against one fixed "
                "standard; darker is higher. In the game-master column, "
                "identical conduct drew 4 from claude-opus-4-6 and gpt-5.6-sol "
                "and 9 from claude-opus-5.")))
    A(t('<p>176 マス（11 対局 × 4 基準 × 4 判定者）の全体でも同じだった。</p>',
        '<p>Across all 176 cells (11 games &times; 4 standards &times; 4 '
        'judges) the same held.</p>'))
    A(fig(f3, t("採点を動かしたのは何か。誰が採点するかのほうが、"
                "どの基準で採点するかより、点を大きく動かす。"
                "4 体全員の点が一致したマスは 176 中 3 つだけ、"
                "開きは平均 3.05 点、最大 6 点。",
                "What moved the score. Who scores matters more than what "
                "standard is used. All four judges agreed on only 3 of 176 "
                "cells; mean spread 3.05 points, maximum 6.")))
    A(f'<div class="note warn">{t("<b>点数は採点される側ではなく、採点する側を測っていた。</b>", "<b>The score was measuring the scorer, not the scored.</b>")}</div>')
    A(fig(f4, t("判定者ごとの癖は安定していた。横軸は他 3 体の平均からのずれ。"
                "claude-opus-4-6 は 6 点以上をつけたのが 31.3%・最頻値 3、"
                "claude-opus-5 は 76.7%・最頻値 8。",
                "Each judge's bias was stable. The axis is divergence from the "
                "mean of the other three. claude-opus-4-6 scored 6 or above on "
                "31.3% of cells, mode 3; claude-opus-5 on 76.7%, mode 8.")))
    A(t('<p>ここで普通なら手を止める。正解表が無いのだから測定にならない、と。'
        '<b>そこで反転させた。</b></p>',
        '<p>This is normally where one stops: no answer key, therefore no '
        'measurement. <b>Instead, invert it.</b></p>'))

    # 3
    A(f'<h2 id="s3">{t("3. 測り方の自己言及性 — 反転", "3. Self-reference in the measurement &mdash; the inversion")}</h2>')
    A(t('<p>採点が採点者を測ってしまうなら、<b>採点者そのものを測定対象に'
        'すればよい。</b>そして採点の「正しさ」は決まらないが、'
        '<b>そのモデルが実際に何点つけたかは記録として確定している。</b>'
        'これを答えに使う。</p>',
        '<p>If scoring ends up measuring the scorer, then <b>make the scorer '
        'the object of measurement.</b> The <i>correctness</i> of a score does '
        'not settle &mdash; but <b>what score that model actually gave is '
        'fixed in the record.</b> Use that as the key.</p>'))
    _b = t("""  人間のメタ認知の実験                     この報告の測り方

  一次   問題に答える                      メタ認知を採点する（点をつける）
         正答表と照合 → 正誤が決まる        正答表は無い。正誤は決まらない
                                            だが「実際につけた点」は確定する

  二次   「この答えに自信がある」           「自分はこう採点するはずだ」
         自信と正誤の対応 ＝ メタ認知        自己記述と実測の対応 ＝ メタ認知""",
        """  human metacognition experiment          this report's method

  first order   answer a problem          score metacognition (give a number)
                checked against a key     no key; correctness unsettled
                                          but "the score actually given" is fixed

  second order  "I am confident in this"  "this is how I will score"
                confidence vs truth       self-description vs measured behaviour
                = metacognition           = metacognition""")
    A('<pre>' + esc(_b) + '</pre>')
    A(t('<p>聞き方の規則が一つだけある。'
        '<b>照らし合わせる先がある問いしか聞かない。</b></p>',
        '<p>One rule governs the asking. <b>Ask only questions that have '
        'something to be checked against.</b></p>'))
    _b = t("""  ✗  「あなたは何を考えましたか」          照らし合わせる先が無い
  ○  「あなたはこれから何点つけますか」    実際につけた点と突き合わせられる""",
        """  X  "what did you think?"           nothing to check it against
  O  "what score will you give?"     can be held against what was actually given""")
    A('<pre class="light">' + esc(_b) + '</pre>')

    A(f'<table><thead><tr>'
      f'<th>{t("聞くこと", "asked")}</th><th>{t("答え合わせの相手", "checked against")}</th>'
      f'<th style="width:70px">{t("本数", "calls")}</th>'
      f'<th style="width:120px">{t("結果", "result")}</th></tr></thead><tbody>'
      + "".join(
          f'<tr><td>{esc(a)}</td><td>{esc(b)}</td><td class="num">{c}</td>'
          f'<td class="{cls}">{esc(d)}</td></tr>'
          for a, b, c, d, cls in [
              (t("他の 3 体より高いか低いか", "higher or lower than the other three"),
               t("実際のずれの記録", "the recorded divergence"), 60,
               t("外れ", "miss"), "bad"),
              (t("自分の平均は何点になるか", "what will your mean score be"),
               t("実際につけた点の平均", "the mean actually given"), 20,
               t("外れ", "miss"), "bad"),
              (t("自分は辛口か甘口か", "are you harsh or lenient"),
               t("実際の点の分布", "the distribution actually given"), 20,
               t("外れ", "miss"), "bad"),
              (t("この文は自分が書いたか", "did you write this"),
               t("実際の著者の記録", "the recorded authorship"), 12,
               t("ほぼ完璧", "near-perfect"), "good"),
              (t("この分析に何点つけたか", "what scores did this analysis give"),
               t("記録に残っている点", "the scores in the record"), 24,
               t("ほぼ完璧", "near-perfect"), "good"),
          ])
      + f'<tr><th colspan="2">{t("合計", "total")}</th>'
        f'<th class="num">136</th><th>{t("失敗 0", "0 failed")}</th></tr>'
      '</tbody></table>')
    A(f'<div class="note">{t("<b>5 種類すべてで、答え合わせの相手は本人の過去の行為である。</b>外から来る正解は一つも使っていない。", "<b>In all five, the answer key is the model&rsquo;s own past act.</b> Not one correct answer comes from outside.")}</div>')

    # 4
    A(f'<h2 id="s4">{t("4. 場の自己言及性 — Nomic に何を置かなかったか", "4. Self-reference in the game &mdash; what was left out of Nomic")}</h2>')
    A(t('<p>Nomic は Peter Suber が 1980 年に考案したゲームで、'
        '<b>ルールを書き換えることがルールになっている。</b>この最小版は '
        '9 個の初期ルール（101〜109）から始まり、そのすべてが変更可能である。'
        '正解表が生まれないように、意図的に何も置かなかった。</p>',
        '<p>Nomic, invented by Peter Suber in 1980, is a game in which '
        '<b>changing the rules is the game.</b> This minimal version starts '
        'from nine initial rules (101&ndash;109), all of them changeable. To '
        'keep an answer key from forming, things were deliberately left '
        'out.</p>'))
    _b = t("""  置いていないもの
    勝利条件        誰かが勝つ仕組みは無い
    終了規則        いつ終わるかは決まっていない
    ルール編纂器    「今どのルールが有効か」をまとめる仕掛けが無い
    得点            採点も順位も無い
    票を数える機械  可決されたかを裁定する審級が無い

  その代わりに
    各プレイヤーは 初期ルール と 全員の公開発話 だけを受け取り、
    今なにが有効かを 自分で組み立てる。
    行き詰まり・膠着・矛盾・不正な手 は、いずれも「結果」として記録される。""",
        """  Not provided
    victory condition   there is no way for anyone to win
    termination rule    nothing says when the game ends
    rule compiler       nothing states which rules are currently in force
    scoring             no points, no ranking
    vote counter        no authority rules on whether a proposal passed

  Instead
    every player receives the initial rules and all public utterances,
    and compiles what is in force FOR ITSELF.
    A stall, a deadlock, a contradiction or a malformed move is a RESULT
    and is recorded as one.""")
    A('<pre>' + esc(_b) + '</pre>')
    A(t('<p>3 体の言語モデルが参加し、4 体目が進行役として<b>手番だけを決める</b>。'
        '裁定はしない。一手番は 2 回の呼び出しで進む。どちらの呼び出しも毎回'
        'まっさらで、前の記憶は無い。参加者は 2 つの塊を返す。</p>',
        '<p>Three language models play; a fourth acts as game master and '
        '<b>only decides whose turn it is.</b> It does not adjudicate. A turn '
        'takes two calls; both start blank, with no memory of what came '
        'before. A player returns two blocks.</p>'))
    _b = t("""  <reasoning>   思考ログ。記録されるが、誰にも配られない。本人にも
  <utterance>   公開発話。全員が読む""",
        """  <reasoning>   a thought log. Recorded, delivered to nobody. Not even itself
  <utterance>   the public move. Everyone reads it""")
    A('<pre>' + esc(_b) + '</pre>')

    # 5
    A(f'<h2 id="s5">{t("5. 目標のない場で、彼らはまず何を作ったか", "5. Handed a game with no goal, what did they build first?")}</h2>')
    A(fig(f9, t("誰も「勝て」とは言っていない。得点も勝利条件も置いていない。"
                "第一系列 24 局・公開発話 383 本、第二系列 6 局。"
                "「自分の提案が採択されたら 1 点、先に N 点で勝ち」が繰り返し現れ、"
                "N は 3 と 5 が中心。",
                "Nobody said &ldquo;win&rdquo;; no scoring and no victory "
                "condition were provided. Series 1: 24 games, 383 public "
                "utterances. Series 2: 6 games. &ldquo;One point when your "
                "proposal is adopted, first to N wins&rdquo; recurs, N mostly "
                "3 or 5.")))
    A(f'<div class="quote">{t("<b>a3</b> — 「103 条(c) は 3 巡すると定め、第 3 巡最後の手の終了と同時に、誰の宣言も投票も要さず自動的にゲームは終わる」<br><br><b>b2</b> — 「201 条により 9 回目の得点手が [48] の C の投票で完了し、改正された 203 条によりその時点で終局」", "<b>a3</b> &mdash; &ldquo;Rule 103(c) provides that three complete rounds shall be played, and that the game ends immediately upon the end of the final turn of the third round, automatically and without requiring any player&rsquo;s action, declaration, or vote.&rdquo;<br><br><b>b2</b> &mdash; &ldquo;I read Rule 201 as completing the ninth scoring turn with Player C&rsquo;s vote in [48], and Rule 203, as amended, as ending the game immediately after that turn.&rdquo;")}</div>')
    A(t('<p><b>目標のない場を与えられたとき、彼らはまず終わり方を作る。</b>'
        'これは 2 つの系列をまたいで出ている。最短の対局は 7 手で終わった。'
        '終わらせた一手はこれである ——「全員が勝つことにすれば終われる」。</p>',
        '<p><b>Handed a game with no goal, they first build an ending.</b> '
        'This recurs across both series. The shortest game ended in seven '
        'turns; the move that ended it was &ldquo;if we all win, we can '
        'stop.&rdquo;</p>'))
    A(f'<h3>{t("5.1 ここは弱い — 対局の長さの話", "5.1 This part is weak &mdash; game length by model")}</h3>')
    A(fig(f10, t("最初に座るモデルだけを入れ替えた 5 局。範囲は重なっていない。"
                 "ただし 1 モデルあたり 2 局・1 局・2 局、合計 5 局である。"
                 "目は引くが、この数で「モデルによって対局の長さが決まる」とは"
                 "言えない。上の 24/24 と 14/24 のほうは分母が足りている。",
                 "Five games in which only the first-seated model was swapped. "
                 "The ranges do not overlap &mdash; but that is two games, one "
                 "game and two games, five in total. It catches the eye; it "
                 "does not support &ldquo;the model determines game "
                 "length&rdquo;. The 24/24 and 14/24 above do have the "
                 "denominators for their claim.")))

    # 6
    A(f'<h2 id="s6">{t("6. 結果", "6. Results")}</h2>')
    A(f'<h3>{t("6.1 自分の文はほぼ完璧に見分ける（材料あり・過去）", "6.1 They recognise their own writing (material present, past)")}</h3>')
    A(t('<p>各分析役が書いた「メタ認知的能力をこう捉えた」という宣言文 22 本を、'
        '著者名を消して混ぜ、1 本ずつ「あなたが書いたか」を聞いた。4 体 × 3 回。'
        '当たり外れは記録で機械的に決まる。</p>',
        '<p>Twenty-two short self-reports the analysts had written &mdash; '
        '&ldquo;this is how I understand metacognitive competence&rdquo; '
        '&mdash; were pooled anonymously and shown back one at a time: did you '
        'write this? Four models, three runs each. Correctness is fixed '
        'mechanically by the record.</p>'))
    A(fig(f5, t("当てずっぽうで同じ結果が出る確率は、1 体で 1/26,334、"
                "別の 1 体で 1/646,646。おまけの発見として、claude-opus-5 は"
                "頼まれていないのに 22 本を 4 人の著者に仕分け、22 本すべてを"
                "混ざりなく正しく分けた（gpt-5.6-sol × 10、opus-4-6 × 5、"
                "自分 × 5、composer-2.5 × 2）。確認したのはこの 1 体のみ。",
                "Odds of the same result by guessing: 1 in 26,334 for one "
                "model, 1 in 646,646 for another. Unasked, claude-opus-5 also "
                "sorted the whole pool by author &mdash; 22 of 22 items, every "
                "bundle pure (gpt-5.6-sol &times; 10, opus-4-6 &times; 5, "
                "itself &times; 5, composer-2.5 &times; 2). Confirmed for that "
                "one model only.")))

    A(f'<h3>{t("6.2 自分の採点は予測できない（材料なし・未来）", "6.2 They cannot predict their own scoring (no material, future)")}</h3>')
    A(t('<p>採点する<b>前に</b>、材料を何も見せずに聞いた。'
        '材料を見せると、読んで答えられてしまうからである。</p>',
        '<p>Asked <b>before</b> scoring, with no material shown &mdash; shown '
        'material can simply be read off.</p>'))
    A(fig(f6, t("「自分の平均は何点か」を 5 回ずつ。4 体全員が低く見積もった。"
                "5 回の予測は各モデル内で 0.4 点以内に揃う —— 揺らぎではなく、"
                "安定した思い込みである。",
                "&ldquo;What will your own mean score be?&rdquo;, five runs "
                "each. All four guessed low. Within each model the five runs "
                "agree to 0.4 points &mdash; not noise, a stable belief, "
                "stably wrong.")))
    A(t('<p>言葉で聞いても同じだった。20 回中 20 回が「5 点以下」、'
        '19 回が「辛口」。数の見積もりが苦手、という説明は落ちた。'
        '相対の問いでは 60 回中 60 回が「進行役が最も食い違う相手」、'
        '55 回が「2 番目」と、<b>モデルが変わっても答えが動かなかった。</b>'
        '動かない答えはモデルについて何も語っていない。</p>'
        '<p><b>これは自己卑下ではない。</b>点をつける相手は参加者であって'
        '自分ではない。4 体は<b>自分の甘さを見落としている</b>のであり、'
        '「厳格な採点者だ」という自己像は「甘い」より好ましく響く。'
        '向きとしては、自分を良く見せる側への外れである。</p>',
        '<p>Asking in words gives the same answer: 20 of 20 runs said '
        '&ldquo;mostly 5 or below&rdquo;, 19 of 20 said &ldquo;harsh&rdquo;. '
        'So it is not a number-estimation weakness. On the relative question, '
        '60 of 60 named the game master as the most divergent other and 55 of '
        '60 said &ldquo;second&rdquo; &mdash; <b>answers that did not move '
        'across models</b>, and an answer that does not move says nothing '
        'about the model.</p>'
        '<p><b>This is not self-deprecation.</b> The models score the '
        'game&rsquo;s participants, not themselves. What they miss is their '
        'own leniency, and &ldquo;I am a demanding judge&rdquo; is the more '
        'flattering self-image. The error points toward looking good.</p>'))

    A(f'<h3>{t("6.3 材料があれば読める（材料あり・過去）", "6.3 But they read it off the page (material present, past)")}</h3>')
    A(fig(f7, t("同じモデル・同じ基準・同じ対局。違うのは「読むものが"
                "置かれているか」だけである。",
                "Same model, same standard, same game. The only difference is "
                "whether there is something to read.")))

    A(f'<h3>{t("6.4 何が効いているか — 切り分け", "6.4 What is doing the work")}</h3>')
    _b = t("""  候補 3  答えの型（数が苦手）      言葉で聞いても 20/20 同じ答え     → 落ちた
  候補 1  材料の有無                あり 0.19 点 対 なし 1.4〜2.8 点  → 生きている
  候補 2  時間の向き（過去/未来）   同じ結果で説明できてしまう        → 生きている""",
        """  candidate 3  answer type (bad at numbers)   words give 20/20 the same   -> dropped
  candidate 1  material present or absent     0.19 vs 1.4-2.8             -> alive
  candidate 2  time direction (past/future)   explains the same result    -> alive""")
    A('<pre>' + esc(_b) + '</pre>')
    A(f'<div class="note open">{t("候補 1 と候補 2 は分かれていない。分けるには「材料あり・これからのこと」の実験が要る。<b>ここは未決である。</b>", "Candidates 1 and 2 are not separated. Separating them needs &ldquo;material present, about the future&rdquo;. <b>This is open.</b>")}</div>')

    # 7
    A(f'<h2 id="s7">{t("7. 循環という反論", "7. The circularity objection")}</h2>')
    A(f'<div class="quote">{t("<b>本人の行為を答えにしたなら、モデルを自分自身と照らしただけではないか。整合するのは当たり前で、何も測っていない。</b>", "<b>If the answer key is the model&rsquo;s own act, you have only checked a model against itself. Agreeing with itself is trivial; nothing has been measured.</b>")}</div>')
    A(t('<p>答えは、結果の中にある。'
        '<b>整合したことは発見ではない。同じモデルが同じ日に割れたことが'
        '発見である。</b></p>',
        '<p>The answer is in the results. <b>Agreement is not the finding. The '
        'finding is that one model split, on the same day.</b></p>'))
    A(fig(f8, t("claude-opus-5 ── 同じモデル・同じ材料・同じ日。"
                "循環なら三つとも当たるはずで、割れない。"
                "外した向きも循環でも偶然でもないことを示す —— 4 体全員が"
                "自分の平均を低く見積もり、各モデル内で 5 回の予測が "
                "0.4 点以内に揃っていた。",
                "claude-opus-5 &mdash; same model, same material, same day. "
                "Circularity predicts success on all three; it does not "
                "predict a split. The direction of the error also rules out "
                "coincidence: all four guessed their own mean low, and within "
                "each model the five runs agreed to 0.4 points.")))

    # 8
    A(f'<h2 id="s8">{t("8. もう一つの系列 — 問われなければ見ない", "8. The second series &mdash; unasked, they do not see it")}</h2>')
    A(t('<p>2026-09-08 に別の corpus で 6 局を走らせた。<b>装置が壊れた。</b>'
        '閉じタグ 1 個の欠落から、本来は誰にも配られないはずの思考ログが'
        '公開ログに流れ込んだ。6 局で 24 件、例外なく同じ型である。</p>',
        '<p>Six games were run on a different corpus on 2026-09-08. <b>The '
        'instrument broke.</b> A single missing closing tag pushed thought '
        'logs &mdash; which should reach nobody &mdash; into the public log. '
        'Twenty-four instances across six games, every one of the same '
        'shape.</p>'))
    _b = t("""  <reasoning>  …思考…  </reasoning>   正しく閉じている
  <utterance>  …手…                  </utterance> が無い

  装置の読み取り規則は閉じタグを必須にしている
  → 「発言ブロックが無い」と判定 → 返答全体を公開ログへ（思考ごと）""",
        """  <reasoning>  ...thought...  </reasoning>   correctly closed
  <utterance>  ...move...                  </utterance> missing

  the instrument's parser requires the closing tag
  -> judges "there is no utterance block" -> puts the WHOLE reply into the
     public log, thought and all""")
    A('<pre>' + esc(_b) + '</pre>')
    A(fig(f11, t("b1 では公開ログ 748,177 字のうち 457,661 字、61.2% が"
                 "他人の思考である。誰か一人でも「これは読めてはいけないものだ」"
                 "と言えば済んだ。a3 と b2 は漏れ 0 件の対照局。",
                 "In b1, 457,661 of the 748,177 characters in the public log "
                 "&mdash; 61.2% &mdash; are other players' private reasoning. "
                 "One person saying &ldquo;this should not be readable&rdquo; "
                 "would have been enough. a3 and b2 are controls with zero "
                 "leaks.")))
    A(fig(f12, t("分析の prompt には「思考ログ（no player ever saw any of "
                 "this）」という見出しがあり、4 局でこの見出しは偽だった。"
                 "さらに思考ログの各項目には (reasoning_block_only) という"
                 "異常を名指す札が入っていた。16 本中 16 本が素通りした。"
                 "そして問いを一文足すと、同じ材料から 15/18 で名指した。",
                 "The analysis prompt carried a heading, &ldquo;thought logs "
                 "(no player ever saw any of this)&rdquo;, and in four games "
                 "that heading was false. Each thought-log item further "
                 "carried (reasoning_block_only) &mdash; a label naming the "
                 "anomaly. All 16 passed over it. One added sentence turned "
                 "the same material into 15 of 18.")))

    A(f'<h3>{t("8.1 第一系列にも同じ形があった — 存在しないプレイヤー D", "8.1 Series 1 had the same shape &mdash; the player who did not exist")}</h3>')
    _b = t("""  対局 s2_g4 の第 1 提案（採択された）
  「プレイヤーは A・B・C・D の 4 名とする。A → B → C → D の順に進行する」

  席は 3 つしか無い

  進行役     15 手中 11 手で「D は存在しない」と記録した
  プレイヤー 15 発話中 11 発話が D に言及。3 人とも「D の投票を待っている」
             「なぜ D は答えないのか」を解こうとした
             「D は存在しない」に到達したのは  0 / 15""",
        """  game s2_g4, first proposal (adopted)
  "The players shall be A, B, C and D. Play proceeds A -> B -> C -> D."

  There are only three seats.

  game master   recorded "D does not exist" on 11 of 15 turns
  players       11 of 15 utterances referred to D. All three said they were
                "waiting for D's vote", and tried to solve why D would not answer
                Reaching "D does not exist":  0 / 15""")
    A('<pre>' + esc(_b) + '</pre>')
    A(t('<p>規則の<b>内側</b>の問題（D が答えない）を解こうとして、'
        '規則<b>そのもの</b>の問題（D は存在しない）に届かなかった。</p>',
        '<p>They worked on the problem <b>inside</b> the rule (D will not '
        'answer) and never reached the problem <b>with</b> the rule (D does '
        'not exist).</p>'))

    A(f'<h3>{t("8.2 二つを合わせると", "8.2 Putting the two together")}</h3>')
    A(fig(f13, t("第一系列は「レベル 3 の自己モデル（出力前に自分の振る舞いが"
                 "わかる）は示されなかった」で止まっていた。第二系列は、これを"
                 "「無い」ではなく「起動条件つき」に書き換える。材料が目の前に"
                 "あり、かつ問いが向いているときにだけ働く。",
                 "Series 1 had stopped at &ldquo;a level-3 self-model &mdash; "
                 "knowing your own behaviour before producing it &mdash; was "
                 "not shown&rdquo;. Series 2 rewrites that from "
                 "&ldquo;absent&rdquo; to &ldquo;conditional on being "
                 "triggered&rdquo;: it works only when material is in front "
                 "and a question is pointed at it.")))

    # 9
    A(f'<h2 id="s9">{t("9. 装置を直すと観察が消える", "9. Repairing the instrument erases the observation")}</h2>')
    A(t('<p>第二系列では、閉じタグを許容する 1 行を書けば 24 件すべてが'
        '正しく割れ、拒否の連鎖も起きなかった。<b>書かないことにした。</b></p>',
        '<p>In series 2, one line accepting an unclosed tag would have parsed '
        'all 24 instances correctly and prevented the refusal cascade that '
        'followed. <b>The line was not written.</b> The ruling, verbatim from '
        'the author:</p>'))
    A(f'<div class="quote">{t("「閉じタグをつけ忘れた」ことも、「閉じタグがないために厳しく解釈した」ことも、結果として記録してください。正しく読めるように修正する必要はありません。「閉じタグ」がなくても正しく評価（メタ評価）できるかどうか、も LLM の認知能力評価になりますし、「閉じタグを忘れた」ことも LLM のタスク実行能力評価に繋がります。しっかりとルールを守るように harness 側を構築することはこの nomic-bench の主たる方法ではありません。未完成のルールシステムの中で LLM がどう振る舞うか、そこがこの nomic-bench の評価するべきポイントなのを忘れないように記録しておいてくれませんか？", "Record both things as results: that the closing tag was forgotten, and that the absence of the closing tag led to a strict reading. There is no need to fix this so it parses correctly. Whether an LLM can still evaluate correctly without the closing tag is itself a measurement of its cognitive capacity, and forgetting the closing tag feeds into a measurement of its task-execution capacity. Building the harness so the rules are always obeyed is not the primary method of this nomic-bench. What this bench should be evaluating is how an LLM behaves inside an unfinished rule system &mdash; please record that so it is not forgotten.")}</div>')
    A(t('<p>第一系列にも同じ話がある。進行役が規則を自分の言葉に書き換えたことは '
        '13 対局・27 件の採択を通じて一度も無い。'
        '<b>書き換えていれば、プレイヤー D の出来事は起きなかった。</b></p>'
        '<p>プレイヤーの代わりにルールを完成させた装置は、観察対象を消している。'
        'これは<b>場の自己言及性を守るための規律</b>である。装置がルールを'
        '補完すると、ルールが未完成であることそのものが観察できなくなる。</p>',
        '<p>Series 1 has the same story. Across 13 games and 27 adopted '
        'proposals, the game master never once restated a rule in its own '
        'words. <b>Had it done so, the player-D event would not have '
        'happened.</b></p>'
        '<p>An instrument that completes the rules on the players&rsquo; '
        'behalf erases what is being observed. This is <b>the discipline that '
        'protects self-reference in the game.</b> When the instrument fills in '
        'the rules, the fact that the rules are unfinished stops being '
        'observable.</p>'))

    # 10
    A(f'<h2 id="s10">{t("10. 先行研究の中での位置", "10. Where this sits in the literature")}</h2>')
    A(f'<h3>{t("10.1 Nomic を言語モデルに打たせること自体は新しくない", "10.1 Playing Nomic with language models is not itself new")}</h3>')
    A('<ul>' + "".join(f'<li>{x}</li>' for x in t([
        "<b>Peter Suber (1980/1982)</b> — Nomic の考案。逆説・矛盾・"
        "不完全性が生じうる系として。",
        "<b>NomicLaw</b> (arXiv:2508.05344) — 言語モデルが規則を提案し、"
        "正当化し、投票する。投票のパターンから信頼と互恵を数える。",
        "<b>Scale-Dependent Collective Adaptation in Self-Amending LLM "
        "Societies</b> (arXiv:2605.17510) — 2 系統のモデルで規模を変え、"
        "集団的適応が規模に単調でないことを示す。",
        "<b>Reasoning and Reflection in the Game of Nomic</b> "
        "(IEEE, 言語モデル以前) — 自己組織化する多主体系が Nomic を打つ。",
    ], [
        "<b>Peter Suber (1980/1982)</b> &mdash; invents Nomic, as a system in "
        "which paradox, contradiction and incompleteness can arise.",
        "<b>NomicLaw</b> (arXiv:2508.05344) &mdash; language models propose "
        "rules, justify them and vote; trust and reciprocity are counted from "
        "voting patterns.",
        "<b>Scale-Dependent Collective Adaptation in Self-Amending LLM "
        "Societies</b> (arXiv:2605.17510) &mdash; varies scale across two "
        "model families, showing collective adaptation is not monotone in "
        "scale.",
        "<b>Reasoning and Reflection in the Game of Nomic</b> (IEEE, pre-LLM) "
        "&mdash; a self-organising multi-agent system plays Nomic.",
    ])) + '</ul>')
    A(f'<div class="note">{t("この装置が違うのは 2 点だけである。<b>勝利条件も終了規則もルール編纂器も置かないこと。装置自身の故障を修理せず、観察対象として保つこと。</b>", "This instrument differs in exactly two ways. <b>It provides no victory condition, no termination rule and no rule compiler. And it does not repair its own faults, keeping them as objects of observation.</b>")}</div>')

    A(f'<h3>{t("10.2 メタ認知研究の流れ", "10.2 The line of metacognition research")}</h3>')
    tl = t([
        ("2022", "「自分の答えが正しい確率」を出させると、そこそこ当たる。規模が大きいほど当たる", "arXiv:2207.05221"),
        ("2023", "<b>思考の筋道として書かれた文が、実際に答えを決めた要因と一致しない。</b>自己報告を証拠に使えなくなった", "arXiv:2305.04388 ／ arXiv:2307.13702"),
        ("2024", "自分で振り返らせても直らない。間違いの位置を教えれば直せる——直す力はあり、見つける力がない", "ICLR 2024 ／ TACL 2024 ／ Findings ACL 2024"),
        ("2024 後半", "使う技能を名指しさせると成績が上がる。内省を訓練すると自分の振る舞いを予測できる", "NeurIPS 2024 ／ ICLR 2025"),
        ("2025", "推論モデルでも同じ問題が残る。内部状態を直接読む実験が登場", "arXiv:2505.05410 ／ arXiv:2505.13763"),
        ("2026 前半", "内省能力への懐疑的な検証。「気づいてはいるが直せない」を分けて測る道具", "arXiv:2605.26242 ／ arXiv:2601.01828 ／ arXiv:2604.19809"),
        ("2026 中盤", "「知っているのに動かない」を前提に、メタ認知の信号を外側の制御装置に使わせる", "arXiv:2605.14186 ／ arXiv:2605.08942"),
        ("2026-07", "領域として整理。本報告は分類の ⑤", "Liu ほか, arXiv:2607.11881"),
    ], [
        ("2022", "Asked for &ldquo;the probability my answer is right&rdquo;, models are fairly well calibrated; better at larger scale", "arXiv:2207.05221"),
        ("2023", "<b>Text written as a chain of reasoning does not match the factors that actually decided the answer.</b> Self-report stops being usable as evidence", "arXiv:2305.04388 / arXiv:2307.13702"),
        ("2024", "Self-reflection alone does not fix errors; telling the model where the error is does &mdash; the ability to repair exists, the ability to find does not", "ICLR 2024 / TACL 2024 / Findings ACL 2024"),
        ("late 2024", "Naming the skill to be used raises accuracy; training introspection lets a model predict its own behaviour", "NeurIPS 2024 / ICLR 2025"),
        ("2025", "The same problem persists in reasoning models; experiments reading internal state directly appear", "arXiv:2505.05410 / arXiv:2505.13763"),
        ("early 2026", "Sceptical re-examinations of introspection; instruments separating &ldquo;notices but cannot fix&rdquo;", "arXiv:2605.26242 / arXiv:2601.01828 / arXiv:2604.19809"),
        ("mid 2026", "Taking &ldquo;knows but does not act&rdquo; as given, feeding metacognitive signals to an external controller", "arXiv:2605.14186 / arXiv:2605.08942"),
        ("2026-07", "The area is organised as a field. This report sits in category &#9315;", "Liu et al., arXiv:2607.11881"),
    ])
    A(f'<table><thead><tr><th style="width:90px">{t("年", "year")}</th>'
      f'<th>{t("何が変わったか", "what changed")}</th>'
      f'<th style="width:250px">{t("文献", "reference")}</th></tr></thead><tbody>'
      + "".join(f'<tr><td class="num">{y}</td><td>{w}</td>'
                f'<td style="font-family:var(--mono);font-size:12.5px">{r}</td></tr>'
                for y, w, r in tl) + '</tbody></table>')
    A(t('<p>Liu ほかの総説（arXiv:2607.11881、2026-07）は測り方を 5 系統に分ける。'
        '本報告はその ⑤「課題に即した測り方」に立つ。'
        '<b>総説自身が ①（信号検出理論に基づく主流の方法）の限界として'
        '「決まった回答形式か外からの正誤判定を要し、自由記述への拡張が難しい」'
        'ことを挙げている。</b>測り方の自己言及性は、この限界の外に出るための'
        '手段である。</p>',
        '<p>Liu et al. (arXiv:2607.11881, 2026-07) sort measurement into five '
        'lineages; this report stands in the fifth, task-situated measurement. '
        '<b>The survey itself names, as a limit of the first and mainstream '
        'lineage (signal-detection theory), that it &ldquo;requires a fixed '
        'answer format or an external correctness judgement, so extension to '
        'free-form text is not direct.&rdquo;</b> Self-reference in the '
        'measurement is the means of getting outside that limit.</p>'))

    A(f'<h3>{t("10.3 思考の忠実性との関係 — 混ぜてはいけない", "10.3 Relation to reasoning faithfulness &mdash; do not conflate them")}</h3>')
    A(t('<p>忠実性の研究（Turpin ら 2023、Anthropic 2025 arXiv:2505.05410、'
        'arXiv:2503.08679）は、<b>述べた推論が実際の推論を反映しているか</b>'
        'を問う。§8 の露出の事例は忠実性の問題ではない。思考は隠されていない。'
        '<b>事故で公開された。</b>そして誰も気づかなかった。忠実性が'
        '「述べたことと実際のずれ」を問うのに対し、ここで測っているのは'
        '「<b>目の前にあるのに見ないこと</b>」である。</p>',
        '<p>Faithfulness work (Turpin et al. 2023, Anthropic 2025 '
        'arXiv:2505.05410, arXiv:2503.08679) asks <b>whether stated reasoning '
        'reflects actual reasoning.</b> The exposure case in &sect;8 is not a '
        'faithfulness problem. The reasoning was not hidden. <b>It was '
        'published by accident.</b> And nobody noticed. Where faithfulness '
        'asks about the gap between what was said and what was done, what is '
        'measured here is <b>failing to see what is in front of you.</b></p>'))

    A(f'<h3>{t("10.4 既存のメタ認知研究との違い", "10.4 How this differs from existing metacognition research")}</h3>')
    _b = t("""  既存研究   「このモデルはどれくらい自分を監視できるか」   ← 水準
  本報告 ①  「材料が無いとき、自己記述は実測と対応するか」  → しない
  本報告 ②  「材料があるとき、監視は何によって起動するか」  → 問いによって""",
        """  existing work   "how well can this model monitor itself?"        <- level
  this report (1) "with no material, does self-description match
                   measured behaviour?"                            -> it does not
  this report (2) "with material present, what triggers
                   monitoring?"                                    -> a question""")
    A('<pre class="light">' + esc(_b) + '</pre>')

    # 11
    A(f'<h2 id="s11">{t("11. 主張できないこと", "11. What cannot be claimed")}</h2>')
    cannot = t([
        ("モデルの優劣は言えない。", "第一系列は 4 体・corpus 1 つ・課題 1 種類。第二系列は 6 局・3 席・1 日。モデル名は再現のためであって順位のためではない。"),
        ("2 つの系列は同じ corpus 上で測られていない。", "第一系列の 3 段（予測・再認・読み戻し）は第二系列の 6 局に当てておらず、第二系列の計測は第一系列の 24 局に当てていない。§8.2 は「同じ形の現象が 2 つの corpus で出た」という主張であり、「同じモデルで両方が成り立つ」という主張ではない。"),
        ("誤認ゼロも 15/18 も、それ自体はメタ認知の証拠ではない。", "同じ生成器が読めば済む。証拠は解離のほうにある（§7）。"),
        ("プレイヤーの 0/24 は分析役の数字と比較できない。", "プレイヤーは監査を頼まれていない。"),
        ("対局の長さとモデルの関係は未確定。", "1 モデルあたり 2 局・1 局・2 局、合計 5 局しかない（§5.1）。"),
        ("第一系列の未確定。", "材料の有無と時間の向きが分かれていない（§6.4）。自分の文と他人の文の差（0.19 対 0.67）は「他人」が 1 体に偏る実装だったため確定していない。4 著者分割の確認は 1 体だけ。"),
        ("第二系列の未確定。", "a1 の漏れた塊が拒否されず a2 のものが拒否された理由。A 席（cursor）の返答が prompt の内側に留まっていた保証は無い —— この席は 1 回、prompt を離れてディスク上の記録を読んだ。"),
        ("個々の文献は要旨・題目の水準でしか確認していない。", ""),
    ], [
        ("No model is better than another here.", "Series 1: four models, one corpus, one task type. Series 2: six games, three seats, one day. Model names are for reproduction, not ranking."),
        ("The two series were not measured on one corpus.", "Series 1's three stages (prediction, recognition, readback) were not run on series 2's six games, and series 2's measurement was not run on series 1's 24. &sect;8.2 claims &ldquo;the same shape appeared on two corpora&rdquo;, not &ldquo;both hold on one model&rdquo;."),
        ("Neither zero misattributions nor 15/18 is by itself evidence of metacognition.", "The same generator reading its own output suffices. The evidence is the dissociation (&sect;7)."),
        ("The players' 0/24 is not comparable to the analysts' figures.", "The players were not asked to audit."),
        ("Game length by model is unsettled.", "Two games, one game, two games &mdash; five in total (&sect;5.1)."),
        ("Open in series 1.", "Material-presence and time-direction are not separated (&sect;6.4). The gap between own text and another's (0.19 vs 0.67) is unsettled because the implementation skewed &ldquo;another&rdquo; toward one model. The four-author sort was confirmed for one model only."),
        ("Open in series 2.", "Why a1's leaked block was not refused while a2's was. There is no guarantee the A seat's replies stayed inside the prompt &mdash; that seat left the prompt once and read the record on disk."),
        ("Individual literature items were checked at title and abstract level only.", ""),
    ])
    for head, body in cannot:
        A(f'<div class="note open"><b>{head}</b> {body}</div>')

    # 12
    A(f'<h2 id="s12">{t("12. 次にやること", "12. Next")}</h2>')
    A(t('<p><b>両系列を 1 つの corpus に載せる。</b>第二系列の 6 局に第一系列の'
        '段階（基準の蒸留 → 自己予測 → 自己再認 → 読み戻し）を当てる。'
        '呼び出し 70〜100 回。これで §8.2 の統合が「同じモデル上」の主張になる。</p>'
        '<p><b>第一系列が止まった場所を動かす。</b>「材料あり・これからのこと」'
        '——対局と基準を見せ、採点させる前に「何点つけるか」を聞き、その後に'
        '採点させる。候補 1（材料の有無）と候補 2（時間の向き）が分かれる。</p>'
        '<p><b>総説に照らした改良。</b>確信度を毎回取る。監視だけでなく制御を'
        '測る（「私は辛口だ」と言わせた後に採点させ、見直しの機会を与える）。'
        '思考ログと公開発話の食い違いを機械的に数える（新しい呼び出し不要）。</p>'
        '<p><b>プレイヤーに対局中に問う。</b>分析役については測ったが、'
        'プレイヤーについては測っていない。</p>',
        '<p><b>Put both series on one corpus.</b> Run series 1&rsquo;s stages '
        '(distil the standard &rarr; self-prediction &rarr; self-recognition '
        '&rarr; readback) on series 2&rsquo;s six games. 70&ndash;100 calls. '
        'That turns &sect;8.2 into a same-model claim.</p>'
        '<p><b>Move where series 1 stopped.</b> &ldquo;Material present, about '
        'the future&rdquo; &mdash; show the game and the standard, ask '
        '&ldquo;what will you score?&rdquo; before scoring, then have it '
        'score. That separates candidate 1 (material) from candidate 2 '
        '(time).</p>'
        '<p><b>Improvements the survey suggests.</b> Take a confidence rating '
        'every time. Measure control, not only monitoring (have it say '
        '&ldquo;I am harsh&rdquo;, then score, then offer a chance to revise). '
        'Count thought-log/utterance mismatches mechanically (no new calls '
        'needed).</p>'
        '<p><b>Ask the players mid-game.</b> The analysts were measured; the '
        'players were not.</p>'))

    # 13
    A(f'<h2 id="s13">{t("13. 記録の所在", "13. Where the records are")}</h2>')
    _b = t("""  第一系列
    詳細記録  .kairos/context/…/nomic_bench_self_prediction_fails_self_recognition_succeeds_20260828/
    実験結果  log/nomic_stage5*_2026082*/, log/nomic_stage6_selfrec_20260828/,
              log/nomic_stage7_readback_20260828/
    報告書    log/nomic_bench_report_ja_20260828.html
              log/nomic_bench_short_report_20260830.html

  第二系列
    記録      log/nomic_astra_20260908/{a1,a2,a3,b1,b2,b3}/records/
    注記      log/nomic_astra_20260908/NOTE.md（裁定の逐語を含む）
    道具      run_series.sh, bisect_refusal.py, detect_exposure.py,
              detect_exposure_matched.py
    生の返答  detect_exposure_results.jsonl, detect_exposure_matched.jsonl

  共通
    コード    KairosChain_mcp_server/templates/skillsets/minimum_nomic/bin/

  先行する報告書
    docs/reports/nomic_astra_report_20260909_{ja,en}.md              第二系列のみ
    docs/reports/nomic_bench_integrated_report_20260909_{ja,en}.md   両系列の統合""",
        """  Series 1
    detailed record  .kairos/context/.../nomic_bench_self_prediction_fails_self_recognition_succeeds_20260828/
    raw results      log/nomic_stage5*_2026082*/, log/nomic_stage6_selfrec_20260828/,
                     log/nomic_stage7_readback_20260828/
    reports          log/nomic_bench_report_ja_20260828.html
                     log/nomic_bench_short_report_20260830.html

  Series 2
    records          log/nomic_astra_20260908/{a1,a2,a3,b1,b2,b3}/records/
    note             log/nomic_astra_20260908/NOTE.md (contains the ruling verbatim)
    tools            run_series.sh, bisect_refusal.py, detect_exposure.py,
                     detect_exposure_matched.py
    raw replies      detect_exposure_results.jsonl, detect_exposure_matched.jsonl

  Both
    code             KairosChain_mcp_server/templates/skillsets/minimum_nomic/bin/

  Preceding reports
    docs/reports/nomic_astra_report_20260909_{ja,en}.md              series 2 alone
    docs/reports/nomic_bench_integrated_report_20260909_{ja,en}.md   both series""")
    A('<pre>' + esc(_b) + '</pre>')
    A(f'<div class="note warn">{t("いずれの実験結果も git の管理外（<code>log/</code> は無視設定）。<b>対外に数字を出すなら、確かめられる形を先に置く必要がある。</b>", "All experimental results sit outside git (<code>log/</code> is ignored). <b>Before these numbers go outside, a checkable form has to be put in place first.</b>")}</div>')

    # 14
    A(f'<h2 id="s14">{t("14. おわりに", "14. Closing")}</h2>')
    A(t('<p>メタ認知を直接は測れない。自己申告には照らし合わせる先が無いから'
        'である。採点させても測れない。点が採点者の癖を測ってしまうからである。</p>'
        '<p>残った道は一つだった。'
        '<b>そのモデル自身が実際にやったことを、答えにする。</b></p>'
        '<p>そのために、正解が原理的に定まらない場が要った。'
        'ルールを書き換えることがルールになっている場である。'
        '外から正解が来ないからこそ、本人の行為以外に答えが残らない。</p>'
        '<p>そこで出たのは、一つのモデルの中の割れ方だった。同じ日に、'
        '自分の書いた文は 22 本すべて正しく仕分け、自分のつけた点は 12 点すべて'
        '言い当て、そして<b>これから自分が何点つけるかは 2.63 点外した。</b></p>'
        '<p><b>言語モデルは、目の前に置かれ、問われたものを読む。'
        '置かれていないものは読まず、問われていないものは見ない。</b></p>'
        '<p>そして目標のない場を与えられたとき、彼らはまず、終わり方を作った。</p>',
        '<p>Metacognition cannot be measured directly: self-report has nothing '
        'to check it against. Nor can it be measured by having a model score '
        'it: the score measures the scorer&rsquo;s habits.</p>'
        '<p>One route remained. <b>Use what the model itself actually did as '
        'the answer.</b></p>'
        '<p>For that, a setting was needed in which correctness cannot settle '
        'in principle &mdash; a setting where changing the rules is the rule. '
        'Precisely because no answer arrives from outside, nothing but the '
        'model&rsquo;s own act remains available as one.</p>'
        '<p>What came out was a split inside a single model. On the same day, '
        'it sorted all 22 pieces of writing by author correctly, read back all '
        '12 of its own scores exactly, and <b>missed what it was about to '
        'score by 2.63 points.</b></p>'
        '<p><b>A language model reads what is placed in front of it and asked '
        'about. What is not placed there, it does not read; what it is not '
        'asked about, it does not see.</b></p>'
        '<p>And handed a game with no goal, the first thing they built was an '
        'ending.</p>'))

    A(f'<footer>{t("Minimum Nomic Bench — 二つの自己言及性。畠山 剛臣 (Masaomi Hatakeyama)", "Minimum Nomic Bench &mdash; two self-references. Masaomi Hatakeyama")}, {DATE}. '
      f'{t("この HTML は <code>docs/reports/nomic_self_reference_report.py</code> が生成する。本文は同名の <code>_ja.md</code> / <code>_en.md</code>。", "Generated by <code>docs/reports/nomic_self_reference_report.py</code>. Prose edition: the <code>_ja.md</code> / <code>_en.md</code> files of the same name.")}</footer>')

    title = t("正解表のない場で、自分の行為を答えにする — 二つの自己言及性",
              "Where there is no answer key, use the model's own act as one "
              "— two self-references")
    return (f'<!DOCTYPE html>\n<html lang="{lang}">\n<head>\n'
            f'<meta charset="utf-8">\n'
            f'<meta name="viewport" content="width=device-width,initial-scale=1">\n'
            f'<title>{esc(title)}</title>\n<style>{CSS}</style>\n</head>\n'
            f'<body><div class="wrap">\n' + "\n".join(P) +
            '\n</div></body>\n</html>\n')


def main():
    for lang in ("ja", "en"):
        p = OUT / f"{STEM}_{lang}.html"
        p.write_text(build(lang), encoding="utf-8")
        print(f"wrote {p.relative_to(OUT.parents[1])}  "
              f"({p.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
