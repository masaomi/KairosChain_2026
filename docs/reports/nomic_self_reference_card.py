#!/usr/bin/env python3
"""Build the LinkedIn card for the Minimum Nomic Bench self-reference report.

One square image (1200x1200) carrying the article's whole claim: the two
self-references as the mechanism, and the one-model dissociation as the payoff.
Square because LinkedIn feed images are cropped to square on mobile; every
number keeps its denominator so the card cannot overstate the report.

Usage:  python3 docs/reports/nomic_self_reference_card.py
Writes: docs/reports/nomic_bench_self_reference_20260913_linkedin_{en,ja}.{svg,png}
"""

import pathlib
import subprocess
import sys

OUT = pathlib.Path(__file__).resolve().parent
STEM = "nomic_bench_self_reference_20260913_linkedin"
W = H = 1200

INK = "#17181c"
DIM = "#6a7078"
BG = "#fbfaf7"
PANEL = "#ffffff"
LINE = "#dcdfe4"
GREEN = "#2f6f5e"
RED = "#b4441e"
BLUE = "#3b5f8a"
BROWN = "#8a5a3b"
TRACK = "#e6e9ed"

SANS_EN = "Helvetica Neue,Helvetica,Arial,sans-serif"
SANS_JA = "Hiragino Sans,Hiragino Kaku Gothic ProN,Yu Gothic,sans-serif"
MONO = "SF Mono,Menlo,Consolas,monospace"


def T(x, y, s, size, fill=INK, weight="400", anchor="start", family=None,
      spacing=None):
    sp = f' letter-spacing="{spacing}"' if spacing else ""
    fam = f' font-family="{family}"' if family else ""
    return (f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" '
            f'font-weight="{weight}" text-anchor="{anchor}"{fam}{sp}>'
            f'{s}</text>')


def card(lang):
    ja = lang == "ja"
    sans = SANS_JA if ja else SANS_EN

    def t(j, e):
        return j if ja else e

    b = [f'<rect width="{W}" height="{H}" fill="{BG}"/>',
         f'<rect x="0" y="0" width="{W}" height="14" fill="{INK}"/>']

    # ---- kicker -----------------------------------------------------
    b.append(T(72, 100, t("MINIMUM NOMIC BENCH", "MINIMUM NOMIC BENCH"), 21,
               BROWN, "700", spacing="3.4"))
    b.append(T(W - 72, 100,
               t("136 本の呼び出し ／ 外から来る正解 0",
                 "136 calls  /  zero external answer keys"),
               21, DIM, "500", anchor="end"))
    b.append(f'<line x1="72" y1="124" x2="{W-72}" y2="124" '
             f'stroke="{LINE}" stroke-width="2"/>')

    # ---- headline ---------------------------------------------------
    head = t(["正解表のない場で、", "自分の行為を答えにする"],
             ["How do you measure self-knowledge",
              "when there is no right answer?"])
    y = 208
    for ln in head:
        b.append(T(72, y, ln, 60 if ja else 55, INK, "700"))
        y += 74 if ja else 68

    b.append(T(72, y + 16,
               t("——— メタ認知は直接には測れない。自己申告には照らし合わせる先が無いからだ",
                 "— metacognition cannot be measured directly: self-report has "
                 "nothing to check it against"),
               24, DIM, "400"))

    # ---- box 1: self-reference in the game --------------------------
    y0 = 400
    b.append(f'<rect x="72" y="{y0}" width="{W-144}" height="128" rx="12" '
             f'fill="{PANEL}" stroke="{BLUE}" stroke-width="3"/>')
    b.append(f'<rect x="72" y="{y0}" width="{W-144}" height="46" rx="12" '
             f'fill="{BLUE}"/>')
    b.append(f'<rect x="72" y="{y0+32}" width="{W-144}" height="14" '
             f'fill="{BLUE}"/>')
    b.append(T(96, y0 + 32, t("自己言及性 ①　場", "SELF-REFERENCE I — THE GAME"),
               22, "#fff", "700", spacing="1.6"))
    b.append(T(96, y0 + 84,
               t("Nomic は「ルールを書き換えること」がルール",
                 "In Nomic, changing the rules IS the rule"),
               30, INK, "700"))
    b.append(T(96, y0 + 116,
               t("→ 正解表を原理的に置けない。勝利条件なし・終了規則なし・得点なし",
                 "→ no answer key can exist. No victory condition, no "
                 "termination rule, no scoring"),
               22, BLUE, "600"))

    # ---- arrow ------------------------------------------------------
    ay = y0 + 128
    b.append(f'<path d="M600 {ay+6} L600 {ay+38}" stroke="{INK}" '
             f'stroke-width="4"/>')
    b.append(f'<path d="M586 {ay+32} L600 {ay+52} L614 {ay+32} Z" '
             f'fill="{INK}"/>')
    b.append(T(628, ay + 40, t("が、下を要求する", "so it requires"), 22, INK,
               "700"))

    # ---- box 2: self-reference in the measurement -------------------
    y1 = y0 + 186
    bh = 216
    b.append(f'<rect x="72" y="{y1}" width="{W-144}" height="{bh}" rx="12" '
             f'fill="{PANEL}" stroke="{BROWN}" stroke-width="3"/>')
    b.append(f'<rect x="72" y="{y1}" width="{W-144}" height="46" rx="12" '
             f'fill="{BROWN}"/>')
    b.append(f'<rect x="72" y="{y1+32}" width="{W-144}" height="14" '
             f'fill="{BROWN}"/>')
    b.append(T(96, y1 + 32,
               t("自己言及性 ②　測り方",
                 "SELF-REFERENCE II — THE MEASUREMENT"),
               22, "#fff", "700", spacing="1.6"))

    # the loop
    ly = y1 + 126
    bw2, bh2 = 330, 76
    lx, rx = 110, W - 110 - bw2
    for x, lab in ((lx, t(["モデルが", "実際にやったこと"],
                          ["what the model", "actually DID"])),
                   (rx, t(["答え合わせの", "相手"],
                          ["the ANSWER", "KEY"]))):
        b.append(f'<rect x="{x}" y="{ly-bh2/2}" width="{bw2}" height="{bh2}" '
                 f'rx="10" fill="#f4f6f8" stroke="{LINE}" stroke-width="2"/>')
        b.append(T(x + bw2 / 2, ly - 4, lab[0], 25, INK, "700",
                   anchor="middle"))
        b.append(T(x + bw2 / 2, ly + 26, lab[1], 25, INK, "700",
                   anchor="middle"))
    mid = (lx + bw2 + rx) / 2
    b.append(f'<path d="M{lx+bw2+16} {ly-14} L{rx-28} {ly-14}" '
             f'stroke="{BROWN}" stroke-width="4"/>')
    b.append(f'<path d="M{rx-30} {ly-26} L{rx-8} {ly-14} L{rx-30} {ly-2} Z" '
             f'fill="{BROWN}"/>')
    b.append(T(mid, ly - 26, t("記録される", "recorded as"), 21, BROWN, "700",
               anchor="middle"))
    b.append(f'<path d="M{rx-16} {ly+18} L{lx+bw2+28} {ly+18}" '
             f'stroke="{BROWN}" stroke-width="4"/>')
    b.append(f'<path d="M{lx+bw2+30} {ly+6} L{lx+bw2+8} {ly+18} '
             f'L{lx+bw2+30} {ly+30} Z" fill="{BROWN}"/>')
    b.append(T(mid, ly + 52,
               t("同じモデルの自己記述と照合する",
                 "checked against the same model's self-description"),
               21, BROWN, "700", anchor="middle"))

    # ---- the payoff: one model, one day -----------------------------
    y2 = y1 + bh + 56
    b.append(f'<line x1="72" y1="{y2-22}" x2="{W-72}" y2="{y2-22}" '
             f'stroke="{LINE}" stroke-width="2"/>')
    b.append(T(72, y2 + 16,
               t("同じモデル・同じ日 ── claude-opus-5",
                 "ONE MODEL, ONE DAY — claude-opus-5"),
               25, INK, "700", spacing="1.2"))

    rows = [
        (t("自分の書いた文の仕分け", "sorted its own writing"), 1.0,
         "22 / 22", GREEN),
        (t("自分がつけた点の読み戻し", "read back its own scores"), 1.0,
         "12 / 12", GREEN),
        (t("これから自分がつける点の予測",
           "predicted the scores it was about to give"), 0.0,
         t("2.63 点 外し", "off by 2.63"), RED),
    ]
    lab_w, trk_x = 470, 560
    trk_w = W - 72 - trk_x - 210
    ry = y2 + 62
    for label, frac, disp, col in rows:
        b.append(T(72, ry + 21, label, 24, INK, "500"))
        b.append(f'<rect x="{trk_x}" y="{ry}" width="{trk_w}" height="30" '
                 f'rx="5" fill="{TRACK}"/>')
        if frac > 0:
            b.append(f'<rect x="{trk_x}" y="{ry}" width="{trk_w*frac:.0f}" '
                     f'height="30" rx="5" fill="{col}"/>')
        else:
            # No fraction to fill: this row is an error in points, not a hit
            # rate. Draw a cap so the empty track reads as "no hit", not as a
            # rendering fault.
            b.append(f'<rect x="{trk_x}" y="{ry}" width="7" height="30" '
                     f'rx="3" fill="{col}"/>')
        b.append(T(trk_x + trk_w + 22, ry + 23, disp, 25, col, "700",
                   family=MONO if not ja else None))
        ry += 46

    b.append(T(72, ry + 22,
               t("上の二つは正答の割合、三つ目は点の誤差（当たりが無いので棒は伸びない）",
                 "The top two bars are fractions correct; the third is an "
                 "error in points, so there is no hit to fill."),
               20, DIM, "400"))
    b.append(T(72, ry + 56,
               t("循環なら三つとも当たる。割れたことが発見である。",
                 "Circularity predicts success on all three. "
                 "The split is the finding."),
               24, INK, "700"))

    # ---- footer -----------------------------------------------------
    b.append(f'<rect x="0" y="{H-58}" width="{W}" height="58" fill="{INK}"/>')
    b.append(T(72, H - 21,
               t("畠山 剛臣 (Masaomi Hatakeyama) ／ 2026-09-13",
                 "Masaomi Hatakeyama  /  2026-09-13"),
               21, "#e8e9ec", "500"))
    b.append(T(W - 72, H - 21,
               t("モデルの優劣を測ったものではない",
                 "not a model ranking"),
               21, "#9aa0a8", "400", anchor="end"))

    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" '
            f'height="{H}" viewBox="0 0 {W} {H}" '
            f'font-family="{sans}">' + "".join(b) + '</svg>')


def main():
    for lang in ("en", "ja"):
        svg = OUT / f"{STEM}_{lang}.svg"
        png = OUT / f"{STEM}_{lang}.png"
        svg.write_text(card(lang), encoding="utf-8")
        r = subprocess.run(["rsvg-convert", "-w", str(W), "-h", str(H),
                            "-o", str(png), str(svg)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr, file=sys.stderr)
            sys.exit(1)
        print(f"wrote {svg.name} and {png.name} "
              f"({png.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
