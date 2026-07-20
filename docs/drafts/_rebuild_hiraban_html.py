#!/usr/bin/env python3
# Rebuild the plain-language companion HTMLs from their markdown sources,
# reusing the existing HTML as a template: head/CSS/docmeta, the two embedded
# SVG figures, and the condensed tail references are kept; only the body text
# between them is regenerated via pandoc so it always mirrors the md.
import subprocess, re, os, sys

DRAFTS = "/Users/masa/forback/github/KairosChain_2026/docs/drafts"

CONFIG = {
    "ja": {
        "md": "constitutive_recording_by_construction_v1.6_hiraban_ja_draft.md",
        "html": "constitutive_recording_by_construction_v1.6_hiraban_ja_with_diagrams.html",
        "md_end": None,  # JA md has no trailing references block
        "fig2_needle": "この区別そのものは、この論文の発明ではない",
        "docmeta_date_old": "2026-07-11<br>",
        "docmeta_date_new": "2026-07-12<br>",
        "docmeta_anchor": "図2点は暫定配置",
        "docmeta_add": "v1.6 継続（2026-07-12）＝正本と相互同期: §5 の橋を §4 由来の導出（洞察／メモは縛らない／記録＝変更を同じ一つの行為に）へ書き直し、§6 は正本への還流元、§7 を「経験が、資本になる」に改題して肯定の主張を先頭に。",
    },
    "en": {
        "md": "constitutive_recording_by_construction_v1.6_hiraban_en_draft.md",
        "html": "constitutive_recording_by_construction_v1.6_hiraban_en_with_diagrams.html",
        "md_end": "\n**References",  # cut before the md's own reference list
        "fig2_needle": "This distinction itself is not this note",
        "docmeta_date_old": "2026-07-11<br>",
        "docmeta_date_new": "2026-07-12<br>",
        "docmeta_anchor": "The two figures are provisionally placed",
        "docmeta_add": "v1.6 continuation (2026-07-12), mutual sync with the canonical: the §5 bridge re-derived from §4 (insight / a memo binds nothing / recording and changing made one act), §6 served as the reflux source for the canonical, and §7 retitled <em>Experience as capital</em>, thesis-first.",
    },
    "ja17": {
        "md": "constitutive_recording_by_construction_v1.7_hiraban_ja.md",
        "html": "constitutive_recording_by_construction_v1.7_hiraban_ja.html",
        "md_end": None,
        "fig2_needle": "この区別そのものは、この論文の発明ではない",
        "docmeta_date_old": "2026-07-11<br>",
        "docmeta_date_new": "2026-07-12<br>",
        "docmeta_anchor": "図2点は暫定配置",
        "docmeta_add": "v1.6 継続（2026-07-12）＝正本と相互同期: §5 の橋を §4 由来の導出（洞察／メモは縛らない／記録＝変更を同じ一つの行為に）へ書き直し、§6 は正本への還流元、§7 を「経験が、資本になる」に改題して肯定の主張を先頭に。",
    },
    "en17": {
        "md": "constitutive_recording_by_construction_v1.7_hiraban_en.md",
        "html": "constitutive_recording_by_construction_v1.7_hiraban_en.html",
        "md_end": "\n**References",
        "fig2_needle": "This distinction itself is not this note",
        "docmeta_date_old": "2026-07-11<br>",
        "docmeta_date_new": "2026-07-12<br>",
        "docmeta_anchor": "The two figures are provisionally placed",
        "docmeta_add": "v1.6 continuation (2026-07-12), mutual sync with the canonical: the §5 bridge re-derived from §4 (insight / a memo binds nothing / recording and changing made one act), §6 served as the reflux source for the canonical, and §7 retitled <em>Experience as capital</em>, thesis-first.",
    },
    "ja18": {
        "md": "constitutive_recording_by_construction_v1.8_hiraban_ja.md",
        "html": "constitutive_recording_by_construction_v1.8_hiraban_ja.html",
        "md_end": None,
        "fig2_needle": "この区別そのものは、この論文の発明ではない",
        "docmeta_date_old": "2026-07-12<br>",
        "docmeta_date_new": "2026-07-20<br>",
        "docmeta_anchor": "図2点は暫定配置",
        "docmeta_add": "v1.8（2026-07-20）＝§2 のみ改訂（拒否は最も自然には提案として吸収されゲームからは抜けない／内容と行為の水準差／入れ子と strange loop の分離／ノミックは境界を顕にする装置／人間・LLM の非対称を近接へ軟化）。multi-LLM review R1 REVISE→R2 6/6 APPROVE で収束。",
    },
    "en18": {
        "md": "constitutive_recording_by_construction_v1.8_hiraban_en.md",
        "html": "constitutive_recording_by_construction_v1.8_hiraban_en.html",
        "md_end": "\n**References",
        "fig2_needle": "This distinction itself is not this note",
        "docmeta_date_old": "2026-07-12<br>",
        "docmeta_date_new": "2026-07-20<br>",
        "docmeta_anchor": "The two figures are provisionally placed",
        "docmeta_add": "v1.8 (2026-07-20): §2 revised only (refusal most naturally absorbed as a proposal, so it does not leave the game; a content/act level difference; nesting separated from the strange loop; Nomic as a device that exposes the boundary; the human/LLM asymmetry softened to proximity). Multi-LLM review converged R1 REVISE → R2 6/6 APPROVE.",
    },
}


def rebuild(lang):
    cfg = CONFIG[lang]
    old = open(os.path.join(DRAFTS, cfg["html"])).read()

    # 1. template parts from the old html
    head = old[: old.index("<h2")]
    tail = old[old.rindex("<hr>"):]
    figs = re.findall(r'<figure class="diagram">.*?</figure>', old, re.S)
    assert len(figs) == 2, f"[{lang}] expected 2 figures, got {len(figs)}"
    fig1, fig2 = figs

    # 2. refresh the docmeta (date + continuation note) — idempotent on re-runs
    if cfg["docmeta_date_old"] in head:
        head = head.replace(cfg["docmeta_date_old"], cfg["docmeta_date_new"])
    else:
        assert cfg["docmeta_date_new"] in head, f"[{lang}] docmeta date not found"
    if cfg["docmeta_add"] not in head:
        assert cfg["docmeta_anchor"] in head, f"[{lang}] docmeta anchor not found"
        head = head.replace(cfg["docmeta_anchor"], cfg["docmeta_add"] + cfg["docmeta_anchor"], 1)

    # 3. body from md via pandoc (from "## 1." to the references cut-off)
    md = open(os.path.join(DRAFTS, cfg["md"])).read()
    start = md.index("## 1.")
    end = md.index(cfg["md_end"], start) if cfg["md_end"] else len(md)
    md_slice = md[start:end].rstrip().rstrip("-").rstrip()  # drop a trailing --- rule if present
    body = subprocess.run(["pandoc", "-f", "markdown", "-t", "html5", "--wrap=none"],
                          input=md_slice, capture_output=True, text=True, check=True).stdout

    # 4. re-insert the two figures at their established anchors
    #    fig1: end of §3 -> immediately before the §4 heading
    pos = body.index(">4.")
    at = body.rindex("<h2", 0, pos)
    body = body[:at] + fig1 + "\n\n" + body[at:]
    #    fig2: inside §5 -> before the paragraph following the bank/marriage examples
    pos = body.index(cfg["fig2_needle"])
    at = body.rindex("<p", 0, pos)
    body = body[:at] + fig2 + "\n\n" + body[at:]

    out = head + body + "\n" + tail
    open(os.path.join(DRAFTS, cfg["html"]), "w").write(out)
    print(f"[{lang}] {cfg['html']}: {len(out)} bytes")


for lang in (sys.argv[1:] or ("ja", "en")):
    rebuild(lang)
print("done")
