#!/usr/bin/env python3
"""The one figure for the Minimum Nomic Bench self-model report (ja + en).

Left: the model stands at "now". Looking back it lands exactly on the record;
looking forward it lands where it SAYS it will be, short of where it actually
goes. That gap is the whole result. Right: the finding as a yes/no pair.

Landscape 2048x1072. Deliberately near-wordless — the numbers live in the
report, not here. The one number shown keeps its scale.

Usage:  python3 docs/reports/nomic_selfmodel_figure.py
Writes: docs/reports/nomic_bench_selfmodel_20260914_figure_{ja,en}.{svg,png}
"""

import pathlib
import subprocess
import sys

OUT = pathlib.Path(__file__).resolve().parent
STEM = "nomic_bench_selfmodel_20260914_figure"
W, H = 2048, 1072

BG = "#f2f4f8"
INK = "#1a2332"
GREEN = "#1f7a4d"
RED = "#a02c2c"
BROWN = "#c47f2e"
GREY = "#78839a"
FAINT = "#aeb7c6"
SANS_EN = "Helvetica Neue,Helvetica,Arial,sans-serif"
SANS_JA = "Hiragino Sans,Hiragino Kaku Gothic ProN,Yu Gothic,sans-serif"


def build(lang):
    ja = lang == "ja"

    def t(j, e):
        return j if ja else e

    b = []

    def T(x, y, s, size, fill=INK, weight="400", anchor="start", spacing=None,
          italic=False):
        sp = f' letter-spacing="{spacing}"' if spacing else ""
        it = ' font-style="italic"' if italic else ""
        b.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" '
                 f'font-weight="{weight}" text-anchor="{anchor}"{sp}{it}>'
                 f'{s}</text>')

    def P(d, stroke, width=3.5, dash=None):
        da = f' stroke-dasharray="{dash}"' if dash else ""
        b.append(f'<path d="{d}" stroke="{stroke}" stroke-width="{width}" '
                 f'fill="none" stroke-linecap="round"{da}/>')

    def head(x, y, col):
        s = 15
        b.append(f'<path d="M{x-s} {y+s*1.3} L{x} {y} L{x+s} {y+s*1.3} Z" '
                 f'fill="{col}"/>')

    # ---------------- left: the diagram ----------------
    AX, BW, BH = 530, 64, 96
    BY = AX - BH // 2
    CX, PX, DX = 620, 790, 1010

    T(112, 310, t("自分の過去", "ITS OWN PAST"), 27, GREEN, "700", spacing="4")
    T(790, 310, t("これからの自分", "ITS OWN NEXT MOVE"), 27, RED, "700",
      spacing="4")

    for i in range(5):
        x = 112 + i * (BW + 22)
        b.append(f'<rect x="{x}" y="{BY}" width="{BW}" height="{BH}" rx="6" '
                 f'fill="{GREEN}" opacity="{0.55 + 0.09*i:.2f}"/>')

    # Flat geometric robot head: antenna, head, side ports, two eyes. Monoline
    # and symmetric, so it reads as an instrument rather than as a character.
    b.append(f'<g transform="translate({CX},{AX})">'
             f'<path d="M0 -60 L0 -47" stroke="{BROWN}" stroke-width="5" '
             f'stroke-linecap="round"/>'
             f'<circle cx="0" cy="-68" r="8" fill="{BROWN}"/>'
             f'<rect x="-63" y="-15" width="11" height="30" rx="5" '
             f'fill="{BROWN}"/>'
             f'<rect x="52" y="-15" width="11" height="30" rx="5" '
             f'fill="{BROWN}"/>'
             f'<rect x="-52" y="-47" width="104" height="94" rx="22" '
             f'fill="{BROWN}"/>'
             f'<circle cx="-20" cy="-4" r="11.5" fill="#ffffff"/>'
             f'<circle cx="20" cy="-4" r="11.5" fill="#ffffff"/>'
             f'<rect x="-21" y="22" width="42" height="7" rx="3.5" '
             f'fill="#ffffff" opacity=".8"/></g>')
    T(CX, AX + 92, "LLM", 23, BROWN, "700", anchor="middle", spacing="1.5")

    b.append(f'<rect x="{PX}" y="{BY}" width="{BW}" height="{BH}" rx="6" '
             f'fill="none" stroke="{RED}" stroke-width="3.5" '
             f'stroke-dasharray="10 9"/>')
    b.append(f'<rect x="{DX}" y="{BY}" width="{BW}" height="{BH}" rx="6" '
             f'fill="{INK}" opacity=".82"/>')
    T(PX + BW / 2, BY - 16, t("こう言う", "it says"), 22, RED, "700",
      anchor="middle")
    T(DX + BW / 2, BY - 16, t("こうする", "it does"), 22, INK, "700",
      anchor="middle")

    GY = BY - 60
    P(f"M{PX+BW} {GY} L{DX} {GY}", RED, 3)
    P(f"M{PX+BW} {GY-13} L{PX+BW} {GY+13}", RED, 3)
    P(f"M{DX} {GY-13} L{DX} {GY+13}", RED, 3)
    T((PX + BW + DX) / 2, GY - 20, t("10 点中 2.63 点のずれ", "2.63 of 10"),
      26 if ja else 28, RED, "700", anchor="middle")

    P(f"M{CX-56} {AX+62} C {CX-140} {AX+170}, 470 {AX+170}, 402 {AX+86}",
      GREEN, 4)
    head(402, AX + 60, GREEN)
    T(112, AX + 240, t("寸分たがわず読み戻す", "reads it back exactly"),
      27, GREEN, "700")

    P(f"M{CX+56} {AX+62} C {CX+144} {AX+170}, {PX+BW/2-72} {AX+170}, "
      f"{PX+BW/2} {AX+86}", RED, 4, dash="11 9")
    head(int(PX + BW / 2), AX + 60, RED)
    T(790, AX + 240,
      t("これからやることは外す", "and misses what it is about to do"),
      27, RED, "700")

    # ---------------- right: the finding ----------------
    RX = 1250
    s = 64 if ja else 76
    T(RX, 330, t("自己再認は、", "Self-recognising,"), s, INK, "700")
    T(RX, 416, t("できる。", "yes."), s, GREEN, "700")
    T(RX, 552, t("自己予測は、", "Self-predicting,"), s, INK, "700")
    T(RX, 638, t("できない。", "no."), s, RED, "700")

    T(RX, 760, t("自分が何をしたかは、正確に知っている。",
                 "It knows exactly what it did."), 30 if ja else 34, GREY,
      italic=not ja)
    T(RX, 806, t("これから何をするかは、知らない。",
                 "It does not know what it will do."), 30 if ja else 34, GREY,
      italic=not ja)

    T(RX, 950, t("Minimum Nomic Bench &#8212; 測定ノート",
                 "Minimum Nomic Bench &#8212; a measurement note"), 24, GREY)
    T(RX, 986, "genomicschain.ch", 24, GREY)
    T(RX, 1022, t("モデルの優劣ではない", "not a model ranking"), 21, FAINT)

    fam = SANS_JA if ja else SANS_EN
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" '
            f'height="{H}" viewBox="0 0 {W} {H}" font-family="{fam}">'
            f'<rect width="{W}" height="{H}" fill="{BG}"/>'
            + "".join(b) + '</svg>')


def main():
    for lang in ("en", "ja"):
        svg = OUT / f"{STEM}_{lang}.svg"
        png = OUT / f"{STEM}_{lang}.png"
        svg.write_text(build(lang), encoding="utf-8")
        r = subprocess.run(["rsvg-convert", "-w", str(W), "-h", str(H),
                            "-o", str(png), str(svg)],
                           capture_output=True, text=True)
        if r.returncode:
            print(r.stderr, file=sys.stderr)
            sys.exit(1)
        print(f"wrote {svg.name}, {png.name} ({png.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
