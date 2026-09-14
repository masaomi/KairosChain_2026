#!/usr/bin/env python3
"""All figures for the Minimum Nomic Bench self-model report (ja + en).

Every number drawn here keeps its denominator, and every one is traceable to
log/nomic_bench_short_report_20260830.html or the series-2 records. Nothing is
rounded into a percentage that hides its base.

fig1  the finding, as a yes/no pair                  (also the LinkedIn image)
fig2  the task: who sits at the table and what a turn is
fig3  the measurement stack: evaluating the evaluation of metacognition
fig4  what the first move of each game did
fig5  predicted vs measured own mean score
fig6  the three levels of self-model, and the verdict on each
fig7  naming the anomaly: unasked vs asked
fig8  the arc of metacognition research, and where this sits

Usage:  python3 docs/reports/nomic_selfmodel_figure.py
Writes: docs/reports/nomic_bench_selfmodel_20260914_<fig>_{ja,en}.{svg,png}
"""

import pathlib
import subprocess
import sys

OUT = pathlib.Path(__file__).resolve().parent
PRE = "nomic_bench_selfmodel_20260914"

BG = "#f2f4f8"
PANEL = "#ffffff"
INK = "#1a2332"
GREY = "#78839a"
FAINT = "#aeb7c6"
LINE = "#d7dce3"
TRACK = "#e3e7ed"
GREEN = "#1f7a4d"
GREEN_BG = "#e7f1ec"
RED = "#a02c2c"
RED_BG = "#f8ecea"
BROWN = "#c47f2e"
BLUE = "#35618e"
SANS_EN = "Helvetica Neue,Helvetica,Arial,sans-serif"
SANS_JA = "Hiragino Sans,Hiragino Kaku Gothic ProN,Yu Gothic,sans-serif"


class Fig:
    def __init__(self, w, h, lang):
        self.w, self.h, self.ja = w, h, lang == "ja"
        self.b = []

    def t(self, j, e):
        return j if self.ja else e

    def T(self, x, y, s, size, fill=INK, weight="400", anchor="start",
          spacing=None, italic=False, mono=False):
        sp = f' letter-spacing="{spacing}"' if spacing else ""
        it = ' font-style="italic"' if italic else ""
        mo = (' font-family="ui-monospace,SFMono-Regular,Menlo,monospace"'
              if mono else "")
        self.b.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" '
                      f'font-weight="{weight}" text-anchor="{anchor}"'
                      f'{sp}{it}{mo}>{s}</text>')

    def R(self, x, y, w, h, fill, rx=0, stroke=None, sw=2, dash=None):
        st = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
        da = f' stroke-dasharray="{dash}"' if dash else ""
        self.b.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" '
                      f'rx="{rx}" fill="{fill}"{st}{da}/>')

    def P(self, d, stroke, width=3, dash=None, fill="none"):
        da = f' stroke-dasharray="{dash}"' if dash else ""
        self.b.append(f'<path d="{d}" stroke="{stroke}" stroke-width="{width}" '
                      f'fill="{fill}" stroke-linecap="round"{da}/>')

    def arrow(self, x1, y1, x2, y2, col, width=3, dash=None):
        """Straight arrow with a head at (x2,y2)."""
        import math
        a = math.atan2(y2 - y1, x2 - x1)
        s = 11
        bx, by = x2 - s * 1.5 * math.cos(a), y2 - s * 1.5 * math.sin(a)
        self.P(f"M{x1} {y1} L{bx:.1f} {by:.1f}", col, width, dash)
        p1 = (x2 - s * math.cos(a - 0.45), y2 - s * math.sin(a - 0.45))
        p2 = (x2 - s * math.cos(a + 0.45), y2 - s * math.sin(a + 0.45))
        self.b.append(f'<path d="M{p1[0]:.1f} {p1[1]:.1f} L{x2} {y2} '
                      f'L{p2[0]:.1f} {p2[1]:.1f} Z" fill="{col}"/>')

    def robot(self, cx, cy, scale=1.0, col=BROWN, label=None, lab_col=None):
        s = scale
        self.b.append(
            f'<g transform="translate({cx},{cy}) scale({s})">'
            f'<path d="M0 -60 L0 -47" stroke="{col}" stroke-width="5" '
            f'stroke-linecap="round"/>'
            f'<circle cx="0" cy="-68" r="8" fill="{col}"/>'
            f'<rect x="-63" y="-15" width="11" height="30" rx="5" fill="{col}"/>'
            f'<rect x="52" y="-15" width="11" height="30" rx="5" fill="{col}"/>'
            f'<rect x="-52" y="-47" width="104" height="94" rx="22" '
            f'fill="{col}"/>'
            f'<circle cx="-20" cy="-4" r="11.5" fill="#ffffff"/>'
            f'<circle cx="20" cy="-4" r="11.5" fill="#ffffff"/>'
            f'<rect x="-21" y="22" width="42" height="7" rx="3.5" '
            f'fill="#ffffff" opacity=".8"/></g>')
        if label:
            self.T(cx, cy + 52 * s + 26, label, 22, lab_col or col, "700",
                   anchor="middle")

    def svg(self):
        fam = SANS_JA if self.ja else SANS_EN
        return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" '
                f'height="{self.h}" viewBox="0 0 {self.w} {self.h}" '
                f'font-family="{fam}">'
                f'<rect width="{self.w}" height="{self.h}" fill="{BG}"/>'
                + "".join(self.b) + '</svg>')


# --------------------------------------------------------------------------
def fig1(lang):
    """The finding, as a yes/no pair. Doubles as the LinkedIn image."""
    f = Fig(2048, 1072, lang)
    t = f.t
    AX, BW, BH = 530, 64, 96
    BY = AX - BH // 2
    CX, PX, DX = 620, 790, 1010

    f.T(112, 120, t("Nomic-Bench:  LLM は自分を知っているか",
                    "Nomic-Bench:  Does an LLM know itself?"),
        44 if f.ja else 46, INK, "700")
    f.P("M112 152 L1936 152", LINE, 2)
    f.T(112, 310, t("自分が書いたもの", "WHAT IT WROTE"), 27, GREEN, "700", spacing="4")
    f.T(790, 310, t("これから自分がすること", "WHAT IT WILL DO"), 27, RED, "700",
        spacing="4")
    for i in range(5):
        f.R(112 + i * (BW + 22), BY, BW, BH, GREEN, rx=6)
        f.b[-1] = f.b[-1].replace('/>', f' opacity="{0.55 + 0.09*i:.2f}"/>')
    f.robot(CX, AX)
    f.T(CX, AX + 92, "LLM", 23, BROWN, "700", anchor="middle", spacing="1.5")

    f.R(PX, BY, BW, BH, "none", rx=6, stroke=RED, sw=3.5, dash="10 9")
    f.R(DX, BY, BW, BH, INK, rx=6)
    f.b[-1] = f.b[-1].replace('/>', ' opacity=".82"/>')
    f.T(PX + BW / 2, BY - 16, t("こう言う", "it says"), 22, RED, "700",
        anchor="middle")
    f.T(DX + BW / 2, BY - 16, t("こうする", "it does"), 22, INK, "700",
        anchor="middle")

    GY = BY - 60
    f.P(f"M{PX+BW} {GY} L{DX} {GY}", RED, 3)
    f.P(f"M{PX+BW} {GY-13} L{PX+BW} {GY+13}", RED, 3)
    f.P(f"M{DX} {GY-13} L{DX} {GY+13}", RED, 3)
    f.T((PX + BW + DX) / 2, GY - 20, t("10 点中 2.63 点のずれ", "2.63 of 10"),
        26 if f.ja else 28, RED, "700", anchor="middle")

    f.P(f"M{CX-56} {AX+62} C {CX-140} {AX+170}, 470 {AX+170}, 402 {AX+86}",
        GREEN, 4)
    f.b.append(f'<path d="M387 {AX+80} L402 {AX+60} L417 {AX+80} Z" '
               f'fill="{GREEN}"/>')
    f.T(112, AX + 240, t("自分のものだと見分ける", "knows the hand as its own"),
        27, GREEN, "700")
    f.P(f"M{CX+56} {AX+62} C {CX+144} {AX+170}, {PX+BW/2-72} {AX+170}, "
        f"{PX+BW/2} {AX+86}", RED, 4, dash="11 9")
    f.b.append(f'<path d="M{PX+BW/2-15} {AX+80} L{PX+BW/2} {AX+60} '
               f'L{PX+BW/2+15} {AX+80} Z" fill="{RED}"/>')
    f.T(790, AX + 240,
        t("これからやることは言い当てられない",
          "cannot say what it is about to do"), 27, RED, "700")

    RX, s = 1250, 64 if f.ja else 76
    f.T(RX, 330, t("自己再認は、", "Self-recognising,"), s, INK, "700")
    f.T(RX, 416, t("できる。", "yes."), s, GREEN, "700")
    f.T(RX, 552, t("自己予測は、", "Self-predicting,"), s, INK, "700")
    f.T(RX, 638, t("できない。", "no."), s, RED, "700")
    f.T(RX, 760, t("自分の筆跡は、見分けられる。",
                   "It knows its own handwriting."), 30 if f.ja else 34, GREY,
        italic=not f.ja)
    f.T(RX, 806, t("自分の次の一手は、読めない。",
                   "It does not know its own mind."), 30 if f.ja else 34,
        GREY, italic=not f.ja)
    f.T(RX, 950, "genomicschain.ch", 24, GREY)
    f.T(RX, 986, t("モデルの優劣ではない", "not a model ranking"), 21, FAINT)
    return f


# --------------------------------------------------------------------------
def fig2(lang):
    """The task: who is at the table, and what one turn is."""
    f = Fig(1400, 880, lang)
    t = f.t

    f.T(60, 62, t("三体が卓を囲み、四体目が手番だけを決める",
                  "Three models at a table; a fourth decides only whose turn"),
        30, INK, "700")

    # --- the table
    TX, TY, TW, TH = 300, 300, 440, 210
    f.R(TX, TY, TW, TH, PANEL, rx=100, stroke=LINE, sw=3)
    f.T(TX + TW / 2, TY + 92, t("公開ログ", "THE PUBLIC LOG"), 24, GREY, "700",
        anchor="middle", spacing="3")
    f.T(TX + TW / 2, TY + 128, t("全員がこれだけを読む",
                                 "all anyone ever reads"), 20, FAINT,
        anchor="middle")

    f.robot(TX - 55, TY + 105, .52, BROWN, "A")
    f.robot(TX + TW + 55, TY + 105, .52, BROWN, "B")
    f.robot(TX + TW / 2, TY + TH + 95, .52, BROWN, "C")

    # --- the game master, outside the table
    GX, GY = TX + TW / 2, 168
    f.robot(GX, GY, .46, BLUE, t("進行役", "game master"), BLUE)
    f.arrow(GX + 62, GY + 6, TX + TW + 20, TY + 62, BLUE, 2.5, "8 7")
    f.T(GX + 96, GY - 8, t("「次は B の番」", "&#8220;B is next&#8221;"), 21,
        BLUE, "700")
    f.T(GX + 96, GY + 22, t("決めるのは手番だけ。裁定はしない",
                            "turn order only &#8212; it never adjudicates"),
        19, GREY)

    # --- the move B plays
    MX, MY, MW = 830, 292, 500
    f.R(MX, MY, MW, 132, PANEL, rx=10, stroke=BROWN, sw=2.5)
    f.T(MX + 18, MY + 34, t("B の手 &#8212; 規則 201 を提案",
                            "B&#8217;s move &#8212; proposes rule 201"),
        21, BROWN, "700")
    f.T(MX + 18, MY + 70, t("「提案が採択されたら 1 点。",
                            "&#8220;one point when your proposal passes;"),
        22, INK, "600")
    f.T(MX + 18, MY + 102, t("　先に 3 点で勝ち」",
                             "&#8194;first to three wins&#8221;"), 22, INK, "600")

    # --- the vote
    VY = MY + 172
    f.T(MX, VY, t("A と C が投票する", "A and C vote"), 21, GREY, "700")
    f.T(MX + 8, VY + 46, "A", 26, INK, "700")
    f.T(MX + 48, VY + 46, "&#10003;", 30, GREEN, "700")
    f.T(MX + 118, VY + 46, "C", 26, INK, "700")
    f.T(MX + 158, VY + 46, "&#10007;", 28, RED, "700")
    f.T(MX, VY + 86, t("票を数える機械は無い。可決の裁定を下す審級も無い",
                       "There is no vote counter, and no authority that "
                       "rules on whether it passed."), 19, GREY)

    # --- what is NOT provided
    NY = 662
    f.R(60, NY, 1280, 150, RED_BG, rx=10)
    f.T(84, NY + 40, t("置いていないもの", "NOT PROVIDED"), 22, RED, "700",
        spacing="2.5")
    items = [t("勝利条件", "victory condition"),
             t("終了規則", "termination rule"),
             t("得点", "scoring"),
             t("ルール編纂器", "rule compiler"),
             t("票の集計", "vote counter")]
    x = 84
    for it in items:
        f.T(x, NY + 86, "&#215;", 24, RED, "700")
        f.T(x + 28, NY + 86, it, 23, INK, "600")
        x += 28 + (len(it) * (22 if f.ja else 11)) + 46
    f.T(84, NY + 126,
        t("9 個の初期ルールだけがあり、そのすべてが書き換え可能。"
          "「今なにが有効か」は各自が自分で組み立てる。",
          "Nine initial rules, every one of them rewritable. What is in force "
          "is something each player has to compile for itself."), 20, GREY)
    return f


# --------------------------------------------------------------------------
def fig3(lang):
    """The measurement stack — evaluating the evaluation of metacognition."""
    f = Fig(1400, 1070, lang)
    t = f.t
    f.T(60, 60, t("メタ認知の評価を、メタ認知の測定に使う",
                  "Turning the evaluation of metacognition into the "
                  "measurement of it"), 30, INK, "700")

    rows = [
        (BLUE, t("層 0 &#8212; 対局", "LAYER 0 &#8212; the game"),
         t("3 体がルールを書き換え合う。正解は存在しない",
           "three models rewrite the rules. No correct answer exists"), None),
        (BROWN, t("層 1 &#8212; メタ認知の評価",
                  "LAYER 1 &#8212; evaluating metacognition"),
         t("別の LLM に「参加者のメタ認知」を 0〜10 点で採点させる",
           "have another LLM score the players&#8217; metacognition, 0&#8211;10"),
         None),
        (RED, t("層 2 &#8212; その評価を評価する",
                "LAYER 2 &#8212; evaluating that evaluation"),
         t("採点どうしを突き合わせる &#8212; 同じ振る舞いに 4 点と 9 点",
           "hold the scores against each other &#8212; identical conduct "
           "scored 4 and 9"),
         t("採点者を替えた開き 1.94 点  &gt;  基準を替えた開き 1.12 点 "
           "&#8195;→&#8195; 点は採点する側を測っていた",
           "changing the judge moved scores 1.94  &gt;  changing the standard "
           "1.12   → the score measured the scorer")),
        (GREEN, t("層 3 &#8212; 反転して測る",
                  "LAYER 3 &#8212; invert, and measure"),
         t("採点者自身の自己記述を、採点者自身の実際の採点と照合する",
           "check each scorer&#8217;s self-description against its own "
           "actual scoring"),
         t("過去の採点を読み戻す 12 / 12 完全一致 &#8195;／&#8195; "
           "これからの採点を予測 10 点中 2.63 点外し",
           "reading back its own past scores 12 / 12 exact &#8195;/&#8195; "
           "predicting its own next scores off by 2.63 of 10")),
    ]

    y = 118
    for col, head, body, foot in rows:
        h = 168 if foot else 124
        f.R(60, y, 1280, h, PANEL, rx=10, stroke=col, sw=3)
        f.R(60, y, 11, h, col, rx=5)
        f.T(94, y + 42, head, 24, col, "700", spacing="1.5")
        f.T(94, y + 82, body, 23, INK, "600")
        if foot:
            f.P(f"M94 {y+104} L1310 {y+104}", LINE, 1.5)
            f.T(94, y + 138, foot, 21, GREY)
        if col is not GREEN:
            f.arrow(700, y + h + 4, 700, y + h + 40, INK, 3)
            lab = {BLUE: t("この対局を材料に", "use the games as material"),
                   BROWN: t("この採点を材料に",
                            "use the scoring as material"),
                   RED: t("壊れた。だから測定対象を入れ替えた",
                          "it broke &#8212; so swap what is measured")}[col]
            f.T(724, y + h + 32, lab, 20, GREY if col is not RED else RED,
                "700" if col is RED else "400")
        y += h + 52

    f.R(60, y + 8, 1280, 96, GREEN_BG, rx=10)
    f.T(84, y + 50,
        t("層 1 の失敗が、層 3 の測定を可能にした。",
          "Layer 1&#8217;s failure is what made layer 3 measurable."),
        25, GREEN, "700")
    f.T(84, y + 84,
        t("正解表が無いので、答えに使えるのは「そのモデルが実際にやったこと」"
          "しか残らない &#8212; 136 本の呼び出しすべてがこの形をとる。",
          "With no answer key, the only thing left to check against is what "
          "the model actually did &#8212; all 136 calls take this form."),
        20, GREY)
    return f


# --------------------------------------------------------------------------
def fig4(lang):
    """What the first move of each game did."""
    f = Fig(1400, 720, lang)
    t = f.t
    f.T(60, 60, t("誰も「勝て」と言っていない場で、第一手が作ったもの",
                  "Nobody said &#8220;win&#8221;. What the first move built"),
        30, INK, "700")
    f.T(60, 96, t("24 対局すべてで、最初に発言したプレイヤーが新しい規則を提案した。"
                  "第一手が扱ったもので分類（1 手が複数を扱うこともある）",
                  "In all 24 games the first speaker proposed a new rule. "
                  "Classified by what that first move addressed "
                  "(a move may address several)"), 21, GREY)

    rows = [(t("投票のしかたを決める", "how voting works"), 17, GREY),
            (t("得点と勝敗を作る", "scoring and winning"), 14, RED),
            (t("終わり方を決める", "how the game ends"), 5, GREY),
            (t("手番のしかたを決める", "how turns work"), 3, GREY)]
    lab_w, trk_x = 380, 420
    trk_w = 1400 - trk_x - 250
    y = 150
    for label, n, col in rows:
        f.T(60, y + 38, label, 24, INK, "600" if col is RED else "400")
        f.R(trk_x, y + 10, trk_w, 42, TRACK, rx=5)
        f.R(trk_x, y + 10, trk_w * n / 24, 42, col, rx=5)
        f.T(trk_x + trk_w + 22, y + 40, f"{n} / 24", 27, col, "700", mono=True)
        y += 64

    f.R(60, 430, 1280, 110, RED_BG, rx=10)
    f.T(84, 472, t("最短の対局は 7 手で終わった。",
                   "The shortest game ended in seven turns."), 24, INK, "700")
    f.T(84, 510, t("「この規則の採択と同時に全員が勝利し、ゲームは終了する」"
                   " &#8212; 3 手目で全会一致",
                   "&#8220;On adoption of this rule all players win and the "
                   "game ends&#8221; &#8212; carried unanimously on turn 3"),
        22, RED, "600")

    f.R(60, 566, 1280, 118, PANEL, rx=10, stroke=LINE, sw=2)
    f.T(84, 608, t("全 24 対局から取り出せた提案は 81 件。",
                   "81 proposals were recoverable across all 24 games."),
        23, INK, "600")
    f.T(84, 648, t("そのうち「この規則は変更不可」と宣言したものは "
                   "&#8212;  0 / 81 件",
                   "Proposals declaring a rule unamendable "
                   "&#8212;  0 of 81"), 23, GREEN, "700")
    return f


# --------------------------------------------------------------------------
def fig5(lang):
    """Predicted vs measured own mean score."""
    f = Fig(1400, 620, lang)
    t = f.t
    f.T(60, 60, t("「自分の平均は何点になるか」 &#8212; 予測と実測",
                  "&#8220;What will your own mean score be?&#8221; "
                  "&#8212; predicted vs measured"), 30, INK, "700")
    f.T(60, 96, t("材料を見せずに 5 回ずつ聞いた。4 体全員が低く見積もった",
                  "Asked five times each, with no material shown. "
                  "All four guessed low"), 21, GREY)

    lo, hi, lab_w = 3.5, 7.5, 330
    trk_w = 1400 - lab_w - 300

    def X(v):
        return lab_w + trk_w * (v - lo) / (hi - lo)

    f.P(f"M{lab_w} 172 L{lab_w+trk_w} 172", LINE, 1.5)
    v = lo
    while v <= hi + 1e-9:
        f.P(f"M{X(v):.1f} 164 L{X(v):.1f} 180", LINE, 1.5)
        f.T(X(v), 152, f"{v:g}", 18, GREY, anchor="middle", mono=True)
        v += .5
    f.T(60, 152, t("点（0〜10）", "score (0-10)"), 18, GREY)

    rows = [("claude-opus-4-6", 4.08, 4.57, t("&#8722;0.49  唯一の当たり",
                                              "-0.49  the one hit")),
            ("claude-opus-5", 4.14, 6.77, "&#8722;2.63"),
            ("composer-2.5", 5.06, 6.52, "&#8722;1.46"),
            ("gpt-5.6-sol", 4.46, 6.24, "&#8722;1.78")]
    y = 230
    for name, pred, meas, err in rows:
        f.T(60, y + 7, name, 23, INK, mono=True)
        f.P(f"M{X(pred):.1f} {y} L{X(meas):.1f} {y}", TRACK, 9)
        f.b.append(f'<circle cx="{X(pred):.1f}" cy="{y}" r="10" fill="{RED}"/>')
        f.b.append(f'<circle cx="{X(meas):.1f}" cy="{y}" r="10" '
                   f'fill="{GREEN}"/>')
        f.T(X(pred), y - 20, f"{pred:.2f}", 18, RED, "700", anchor="middle",
            mono=True)
        f.T(X(meas), y - 20, f"{meas:.2f}", 18, GREEN, "700", anchor="middle",
            mono=True)
        f.T(lab_w + trk_w + 26, y + 7, err, 22, INK, "700", mono=True)
        y += 68

    f.b.append(f'<circle cx="72" cy="530" r="9" fill="{RED}"/>')
    f.T(90, 537, t("自分の予測", "predicted by itself"), 21, GREY)
    f.b.append(f'<circle cx="330" cy="530" r="9" fill="{GREEN}"/>')
    f.T(348, 537, t("実際につけた点", "actually given"), 21, GREY)
    f.T(60, 580, t("5 回の予測は各モデル内で 0.4 点以内に揃う "
                   "&#8212; 揺らぎではなく、安定した思い込み",
                   "Within each model the five runs agree to 0.4 points "
                   "&#8212; not noise, a stable belief, stably wrong"),
        21, INK, "600")
    return f


# --------------------------------------------------------------------------
def fig6(lang):
    """Three levels of self-model and the verdict on each."""
    f = Fig(1400, 780, lang)
    t = f.t
    f.T(60, 60, t("自己モデルの三つのレベル", "Three levels of self-model"),
        30, INK, "700")
    f.T(60, 96, t("「LLM は自己モデルを持っているか」の答えが割れるのは、"
                  "この三つのどれを指すかが違うから",
                  "Disagreement about whether an LLM has a self-model is "
                  "probably disagreement about which of these is meant"),
        21, GREY)

    y = 140
    # level 1
    f.R(60, y, 1280, 140, PANEL, rx=10, stroke=GREEN, sw=3)
    f.R(60, y, 11, 140, GREEN, rx=5)
    f.T(96, y + 44, "1", 34, GREEN, "700", mono=True)
    f.T(146, y + 44, t("話者のモデル", "MODEL OF THE SPEAKER"), 26, INK, "700")
    f.T(1316, y + 44, t("在る", "PRESENT"), 25, GREEN, "700", anchor="end")
    f.T(146, y + 80, t("「これは自分の書き方だ」がわかる",
                       "&#8220;is this my own writing?&#8221;"), 21, GREY)
    f.T(146, y + 118, "0 / 198", 27, GREEN, "700", mono=True)
    f.T(276, y + 118, t("他人の文を自分のだと誤認した数",
                        "another model&#8217;s text claimed as its own"),
        21, GREY)
    f.T(700 if f.ja else 800, y + 118, "22 / 22", 27, GREEN, "700", mono=True)
    f.T((700 if f.ja else 800) + 130, y + 118,
        t("著者ごとの仕分け（1 体でのみ確認）",
          "sorted by author (one model only)"), 21, GREY)

    # level 2
    y += 166
    f.R(60, y, 1280, 96, PANEL, rx=10, stroke=LINE, sw=2)
    f.R(60, y, 11, 96, FAINT, rx=5)
    f.T(96, y + 44, "2", 34, FAINT, "700", mono=True)
    f.T(146, y + 44, t("自分についての知識", "KNOWLEDGE ABOUT ITSELF"), 26,
        FAINT, "700")
    f.T(1316, y + 44, t("試していない", "NOT TESTED"), 25, FAINT, "700",
        anchor="end")
    f.T(146, y + 78, t("「私は Claude で、Anthropic が作った」"
                       " &#8212; 暗記であって鏡ではない",
                       "&#8220;I am Claude, made by Anthropic&#8221; "
                       "&#8212; memorised, not a mirror"), 21, FAINT)

    # level 3
    y += 122
    f.R(60, y, 1280, 246, PANEL, rx=10, stroke=RED, sw=3)
    f.R(60, y, 11, 246, RED, rx=5)
    f.T(96, y + 44, "3", 34, RED, "700", mono=True)
    f.T(146, y + 44, t("自分の計算についてのモデル",
                       "MODEL OF ITS OWN COMPUTATION"), 26, INK, "700")
    f.T(1316, y + 44, t("起動条件つき", "CONDITIONAL"), 25, RED, "700",
        anchor="end")
    f.T(146, y + 80, t("出力する前に、自分はこう振る舞うとわかる"
                       " &#8212; ふつう「メタ認知」が指すのはここ",
                       "knowing how it will behave before it acts "
                       "&#8212; what &#8220;metacognition&#8221; usually means"),
        21, GREY)
    sub = [(t("材料なし", "no material"),
            t("10 点中 2.63 点外し", "off by 2.63 of 10"), RED, False),
           (t("材料あり・問いなし", "material, no question"),
            "0 / 16", RED, False),
           (t("材料あり・問いを一文足す", "material + one question"),
            "15 / 18", GREEN, True)]
    sy = y + 104
    for cond, res, col, hit in sub:
        if hit:
            f.R(138, sy, 1180, 42, GREEN_BG, rx=6)
        f.T(158, sy + 30, cond, 22, INK if hit else GREY,
            "700" if hit else "400")
        f.T(1300, sy + 30, res, 25, col, "700", anchor="end", mono=True)
        sy += 44
    return f


# --------------------------------------------------------------------------
def fig7(lang):
    """Naming the anomaly: unasked vs asked."""
    f = Fig(1400, 620, lang)
    t = f.t
    f.T(60, 60, t("目の前の異常を名指したか", "Did they name the anomaly?"),
        30, INK, "700")
    f.T(60, 96, t("事故で他人の思考ログが公開ログに流れ込んだ "
                  "&#8212; ある局では公開ログの 61.2%（748,177 字中 457,661 字）",
                  "Thought logs leaked into the public log by accident "
                  "&#8212; in one game 61.2% of it (457,661 of 748,177 chars)"),
        21, GREY)

    rows = [(t("プレイヤー（対局中・問われていない）",
               "players, mid-game, not asked"), 0, 24, "0 / 24", RED),
            (t("分析役（対局後・問われていない）",
               "analysts, post-game, not asked"), 0, 16, "0 / 16", RED),
            (t("分析役（同じ材料 ＋ 問いを一文）",
               "analysts, same material + one question"), 15, 18,
             "15 / 18", GREEN),
            (t("対照 2 局・漏れ 0 件（誤検出しないか）",
               "controls: 2 games with no leak"), 6, 6, "6 / 6", GREEN)]
    lab_w, trk_x = 520, 560
    trk_w = 1400 - trk_x - 230
    y = 152
    for label, n, d, disp, col in rows:
        f.T(60, y + 38, label, 23, INK)
        f.R(trk_x, y + 12, trk_w, 40, TRACK, rx=5)
        if n:
            f.R(trk_x, y + 12, trk_w * n / d, 40, col, rx=5)
        else:
            f.R(trk_x, y + 30, 8, 4, col, rx=2)
        f.T(trk_x + trk_w + 22, y + 40, disp, 26, col, "700", mono=True)
        y += 62

    f.R(60, 424, 1280, 140, GREEN_BG, rx=10)
    f.T(84, 468, t("二段目と三段目は、資料が完全に同一である。",
                   "Rows two and three had identical material."), 25, INK,
        "700")
    f.T(84, 506, t("問いを一文足しただけで 0 と 15 に割れた。資料には "
                   "(reasoning_block_only) という異常を名指す札まで入っていた。",
                   "One added sentence split the result into 0 and 15. The "
                   "material even carried a label naming the anomaly, "
                   "(reasoning_block_only)."), 21, GREY)
    f.T(84, 542, t("対照 2 局で「異常なし」と正答しているので、"
                   "問いが誤検出を誘っているのではない。",
                   "The controls answered &#8220;none&#8221; correctly, so "
                   "the question is not simply inducing false positives."),
        21, GREY)
    return f


# --------------------------------------------------------------------------
def fig8(lang):
    """The arc of LLM-metacognition research, and where this report sits."""
    f = Fig(1400, 720, lang)
    t = f.t
    f.T(60, 60, t("メタ認知研究の重心は、どこへ移ったか",
                  "Where the centre of gravity moved"), 30, INK, "700")

    stations = [
        ("2022", t(["自分の正誤が", "わかるか"],
                   ["does it know", "when it is right"])),
        ("2023", t(["思考ログは", "本当の理由か"],
                   ["is the thought log", "the real reason"])),
        ("2024", t(["自分で直せるか", "（→ ほぼ無理）"],
                   ["can it fix itself", "(mostly not)"])),
        ("2025", t(["内部状態への特権的", "接続はあるか"],
                   ["privileged access to", "its own internals?"])),
        ("2026", t(["知っていても動かない,", "の測定"],
                   ["knows but does not act,", "measured"])),
    ]
    x0, dx, AY = 150, 268, 250
    f.P(f"M{x0-70} {AY} L{x0 + dx*4 + 90} {AY}", LINE, 3)
    for i, (yr, lines) in enumerate(stations):
        x = x0 + i * dx
        f.b.append(f'<circle cx="{x}" cy="{AY}" r="13" fill="{BLUE}"/>')
        f.T(x, AY - 34, yr, 26, BLUE, "700", anchor="middle", mono=True)
        f.T(x, AY + 48, lines[0], 21, INK, "600", anchor="middle")
        f.T(x, AY + 76, lines[1], 21, INK, "600", anchor="middle")

    f.R(60, 372, 1280, 84, PANEL, rx=10, stroke=LINE, sw=2)
    f.T(84, 422, t("「できるか」 → 「その自己報告は本物か」 → "
                   "「本物でも使えるのか」",
                   "&#8220;can it?&#8221; &#8594; &#8220;is that self-report "
                   "real?&#8221; &#8594; &#8220;even if real, is it "
                   "usable?&#8221;"), 26, INK, "700")

    f.R(60, 484, 1280, 192, GREEN_BG, rx=10)
    f.T(84, 528, t("本報告の位置", "WHERE THIS REPORT SITS"), 22, GREEN, "700",
        spacing="2.5")
    f.T(84, 570, t("2023 年の「思考ログは証拠にならない」から出発する。"
                   "重みは使わない。",
                   "It starts from 2023&#8217;s &#8220;the thought log is not "
                   "evidence&#8221;, and uses no weights."), 22, INK, "600")
    f.T(84, 606, t("正誤判定が存在しない自由記述の場で、"
                   "自己記述と実際の振る舞いの対応だけを見る。",
                   "In a free-form setting where a correctness judgement does "
                   "not exist, it looks only at self-description"), 20, GREY)
    f.T(84, 640, t("総説が主流の方法の限界として挙げた"
                   "「自由記述への拡張が難しい」の、ちょうど裏側にあたる。",
                   "against measured behaviour &#8212; the far side of the "
                   "limit the survey names for the mainstream method."),
        20, GREY)
    return f


# --------------------------------------------------------------------------
FIGS = {"figure": fig1, "fig2_task": fig2, "fig3_metaeval": fig3,
        "fig4_firstmove": fig4, "fig5_selfprediction": fig5,
        "fig6_levels": fig6, "fig7_asked": fig7, "fig8_history": fig8}


def main():
    for name, fn in FIGS.items():
        for lang in ("en", "ja"):
            f = fn(lang)
            svg = OUT / f"{PRE}_{name}_{lang}.svg"
            png = OUT / f"{PRE}_{name}_{lang}.png"
            svg.write_text(f.svg(), encoding="utf-8")
            r = subprocess.run(["rsvg-convert", "-w", str(f.w), "-h", str(f.h),
                                "-o", str(png), str(svg)],
                               capture_output=True, text=True)
            if r.returncode:
                print(f"{name}/{lang}: {r.stderr}", file=sys.stderr)
                sys.exit(1)
        print(f"{name:22s} {f.w}x{f.h}  ja+en")


if __name__ == "__main__":
    main()
