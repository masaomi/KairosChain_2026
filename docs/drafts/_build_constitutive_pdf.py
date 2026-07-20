#!/usr/bin/env python3
# Build convenience-copy PDFs (EN canonical + JA reference) for the constitutive-recording note.
# Canonical .md stays figure-free and untouched; figures are inserted only into a throwaway
# build HTML that Chrome renders to PDF. Figures are the convenience-copy supplement (§8):
# not part of the hashed canonical form.
import subprocess, re, os, sys

DRAFTS = "/Users/masa/forback/github/KairosChain_2026/docs/drafts"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

BASE_CSS = open(os.path.join(DRAFTS, ".constitutive_ja.css")).read()

DIAGRAM_CSS = """
:root{
  --human:#2f6f8f; --human-fill:#2f6f8f22; --llm:#b06a2c; --llm-fill:#b06a2c22;
  --cross:#6a4c93; --cross-fill:#6a4c9322; --limit:#a83232; --limit-fill:#a8323215;
  --gov:#2f6f8f; --mid:#6a4c93; --edge:#7a7a8c; --ok:#2e7d52;
}
html{ -webkit-print-color-adjust:exact; print-color-adjust:exact; }
figure{ margin:34px auto; background:var(--box); border:1px solid var(--line);
  border-radius:14px; padding:20px 20px 16px; max-width:820px; page-break-inside:avoid; }
figure h2{ font-size:1.05rem; margin:0 0 .15rem; border:none; padding:0; }
figure .where{ color:var(--muted); font-size:.82rem; margin:0 0 1rem; }
figcaption{ color:var(--muted); font-size:.9rem; margin-top:.75rem; line-height:1.8; }
figcaption b{ color:var(--ink); font-weight:600; }
svg{ width:100%; height:auto; display:block; }
svg text{ font-family:inherit; }
.lab{ fill:var(--ink); } .lab-mut{ fill:var(--muted); }
@page{ size:A4; margin:18mm 15mm; }
@media print{
  body{ background:#fff; }
  body>*{ max-width:none; } .wrap{ max-width:none; } figure{ max-width:none; }
}
"""

CONFIG = {
    "en": {
        "md": "constitutive_recording_by_construction_v1.6_draft.md",
        "diagrams": "constitutive_recording_by_construction_v1.6_diagrams_en.html",
        "out_pdf": "constitutive_recording_by_construction_v1.6.pdf",
        "title": "Another Frame Problem (v1.6)",
        "lang": "en",
        # (needle, back-up-tag) — figure inserted before the block containing needle
        # Fig 4 (three-layer migration) dropped 2026-07-12: §5 no longer tours the layers.
        "anchors": {
            1: ("Three clarifications guard against reading", "<p"),   # outermost frame (§2)
            2: ("Structural self-referentiality</h2>", "<h2"),       # partial outside (end §3)
            3: ("None of the constitutive register itself is claimed as new here", "<p"),  # two meanings (§5)
        },
    },
    "ja": {
        "md": "constitutive_recording_by_construction_v1.6_ja_draft.md",
        "diagrams": "constitutive_recording_by_construction_v1.6_diagrams_ja.html",
        "out_pdf": "constitutive_recording_by_construction_v1.6_ja.pdf",
        "title": "もう一つのフレーム問題（日本語参照訳 v1.6）",
        "lang": "ja",
        "anchors": {
            1: ("主張を実際より大きく、あるいは別物として読まないために、但し書きを三つ。", "<p"),   # 最外の枠 (§2)
            2: ("構造的自己言及性</h2>", "<h2"),                             # 部分的な外 (§3末)
            3: ("構成的な register そのものは、ここでは何ひとつ新しいものとして主張されない。", "<p"),  # 記録の二意味 (§5)
        },
    },
    # agent-SkillSet naturalization variant (§3–§9 revised via the governed agent loop /
    # its sub-author executors). Kept separate from the hermes+kairos autonomous variant.
    "ja_agent": {
        "md": "constitutive_recording_by_construction_v1.6_ja_draft_agent.md",
        "diagrams": "constitutive_recording_by_construction_v1.6_diagrams_ja.html",
        "out_pdf": "constitutive_recording_by_construction_v1.6_ja_agent.pdf",
        "title": "もう一つのフレーム問題（日本語参照訳 v1.6・agent SkillSet 推敲版）",
        "lang": "ja",
        "anchors": {
            1: ("主張を実際より大きく、あるいは別物として読まないために、但し書きを三つ。", "<p"),   # 最外の枠 (§2)
            2: ("構造的自己言及性</h2>", "<h2"),                             # 部分的な外 (§3末)
            3: ("構成的な register そのものは、ここでは何ひとつ新しいものとして主張されない。", "<p"),  # 記録の二意味 (§5)
        },
    },
    # hermes+kairos autonomous naturalization variant (§3–§9 revised via the governed
    # autonomous_growth_loop; §1–§2 + References carried verbatim). Sibling of ja_agent.
    "ja_hermes": {
        "md": "constitutive_recording_by_construction_v1.6_ja_hermes_draft.md",
        "diagrams": "constitutive_recording_by_construction_v1.6_diagrams_ja.html",
        "out_pdf": "constitutive_recording_by_construction_v1.6_ja_hermes.pdf",
        "title": "もう一つのフレーム問題（日本語参照訳 v1.6・hermes+kairos autonomous 推敲版）",
        "lang": "ja",
        "anchors": {
            1: ("主張を実際より大きく、あるいは別物として読まないために、但し書きを三つ。", "<p"),   # 最外の枠 (§2)
            2: ("構造的自己言及性</h2>", "<h2"),                             # 部分的な外 (§3末)
            3: ("構成的な register そのものは、ここでは何ひとつ新しいものとして主張されない。", "<p"),  # 記録の二意味 (§5)
        },
    },
    # agent-SkillSet MEDIUM self-drive variant (§3–§9 revised by the governed agent loop
    # driving itself: resource_read/write_section over context:// staged sources, at
    # risk_budget=medium; §1–§2 + References verbatim). Sibling of ja_agent / ja_hermes.
    "ja_agent_medium": {
        "md": "constitutive_recording_by_construction_v1.6_ja_draft_agent_medium.md",
        "diagrams": "constitutive_recording_by_construction_v1.6_diagrams_ja.html",
        "out_pdf": "constitutive_recording_by_construction_v1.6_ja_agent_medium.pdf",
        "title": "もう一つのフレーム問題（日本語参照訳 v1.6・agent SkillSet 自走 medium 推敲版）",
        "lang": "ja",
        "anchors": {
            1: ("主張を実際より大きく、あるいは別物として読まないために、但し書きを三つ。", "<p"),   # 最外の枠 (§2)
            2: ("構造的自己言及性</h2>", "<h2"),                             # 部分的な外 (§3末)
            3: ("構成的な register という考え自体は、ここで何ひとつ新しいものとして主張しない", "<p"),  # 記録の二意味 (§5, medium naturalized)
        },
    },
    # agent-SkillSet 3.42.1 naturalization variant (§3–§9 revised via write_section called
    # directly as an MCP tool per section, over context:// staged sources, with the
    # truncation root-cause fixed in gem 3.42.1; §1–§2 + References carried verbatim).
    # Sibling of ja_agent / ja_hermes / ja_agent_medium.
    "ja_agent3421": {
        "md": "constitutive_recording_by_construction_v1.6_ja_draft_agent3421.md",
        "diagrams": "constitutive_recording_by_construction_v1.6_diagrams_ja.html",
        "out_pdf": "constitutive_recording_by_construction_v1.6_ja_agent3421.pdf",
        "title": "もう一つのフレーム問題（日本語参照訳 v1.6・agent SkillSet 3.42.1 推敲版）",
        "lang": "ja",
        "anchors": {
            1: ("主張を実際より大きく、あるいは別物として読まないために、但し書きを三つ。", "<p"),   # 最外の枠 (§2)
            2: ("構造的自己言及性</h2>", "<h2"),                             # 部分的な外 (§3末)
            3: ("構成的な register の考え方そのものは、ここで何か新しいものとして主張しているわけではない。", "<p"),  # 記録の二意味 (§5, 3.42.1 naturalized)
        },
    },
    # v1.7 consolidated seihon (canonical) build targets: EN authoritative + JA reference
    # (the ja_agent3421 naturalized translation), §8 rewritten to Option B.
    "seihon_en": {
        "md": "constitutive_recording_by_construction_v1.7_seihon_en.md",
        "diagrams": "constitutive_recording_by_construction_v1.6_diagrams_en.html",
        "out_pdf": "constitutive_recording_by_construction_v1.7_seihon_en.pdf",
        "title": "Another Frame Problem (v1.7)",
        "lang": "en",
        "anchors": {
            1: ("Three clarifications guard against reading", "<p"),
            2: ("Structural self-referentiality</h2>", "<h2"),
            3: ("None of the constitutive register itself is claimed as new here", "<p"),
        },
    },
    "seihon_ja": {
        "md": "constitutive_recording_by_construction_v1.7_seihon_ja.md",
        "diagrams": "constitutive_recording_by_construction_v1.6_diagrams_ja.html",
        "out_pdf": "constitutive_recording_by_construction_v1.7_seihon_ja.pdf",
        "title": "もう一つのフレーム問題（日本語参照訳 v1.7）",
        "lang": "ja",
        "anchors": {
            1: ("主張を実際より大きく、あるいは別物として読まないために、但し書きを三つ。", "<p"),
            2: ("構造的自己言及性</h2>", "<h2"),
            3: ("構成的な register の考え方そのものは、ここで何か新しいものとして主張しているわけではない。", "<p"),
        },
    },
    # v1.7 DEPOSIT build targets: same masters as seihon_*, but with the working
    # editorial-status note stripped (§8: the editorial note is scaffolding, not part
    # of the deposited text). These feed the concatenated EN+JA Zenodo deposit PDF.
    "deposit_en": {
        "md": "constitutive_recording_by_construction_v1.7_seihon_en.md",
        "diagrams": "constitutive_recording_by_construction_v1.6_diagrams_en.html",
        "out_pdf": "constitutive_recording_by_construction_v1.7_deposit_en.pdf",
        "title": "Another Frame Problem (v1.7)",
        "lang": "en",
        "strip_editorial": True,
        "anchors": {
            1: ("Three clarifications guard against reading", "<p"),
            2: ("Structural self-referentiality</h2>", "<h2"),
            3: ("None of the constitutive register itself is claimed as new here", "<p"),
        },
    },
    "deposit_ja": {
        "md": "constitutive_recording_by_construction_v1.7_seihon_ja.md",
        "diagrams": "constitutive_recording_by_construction_v1.6_diagrams_ja.html",
        "out_pdf": "constitutive_recording_by_construction_v1.7_deposit_ja.pdf",
        "title": "もう一つのフレーム問題（日本語参照訳 v1.7）",
        "lang": "ja",
        "strip_editorial": True,
        "anchors": {
            1: ("主張を実際より大きく、あるいは別物として読まないために、但し書きを三つ。", "<p"),
            2: ("構造的自己言及性</h2>", "<h2"),
            3: ("構成的な register の考え方そのものは、ここで何か新しいものとして主張しているわけではない。", "<p"),
        },
    },
    # v1.8 seihon build targets: §2-only revision, multi-LLM review converged
    # (R1 REVISE -> R2 6/6 APPROVE).
    "seihon_en_v18": {
        "md": "constitutive_recording_by_construction_v1.8_seihon_en.md",
        "diagrams": "constitutive_recording_by_construction_v1.6_diagrams_en.html",
        "out_pdf": "constitutive_recording_by_construction_v1.8_seihon_en.pdf",
        "title": "Another Frame Problem (v1.8)",
        "lang": "en",
        "anchors": {
            1: ("Three clarifications guard against reading", "<p"),
            2: ("Structural self-referentiality</h2>", "<h2"),
            3: ("None of the constitutive register itself is claimed as new here", "<p"),
        },
    },
    "seihon_ja_v18": {
        "md": "constitutive_recording_by_construction_v1.8_seihon_ja.md",
        "diagrams": "constitutive_recording_by_construction_v1.6_diagrams_ja.html",
        "out_pdf": "constitutive_recording_by_construction_v1.8_seihon_ja.pdf",
        "title": "もう一つのフレーム問題（日本語参照訳 v1.8）",
        "lang": "ja",
        "anchors": {
            1: ("主張を実際より大きく、あるいは別物として読まないために、但し書きを三つ。", "<p"),
            2: ("構造的自己言及性</h2>", "<h2"),
            3: ("構成的な register の考え方そのものは、ここで何か新しいものとして主張しているわけではない。", "<p"),
        },
    },
    # v1.8 DEPOSIT build targets: convenience-copy PDFs with the editorial note
    # stripped (§8), matching the frozen docs/zenodo/...v1.8.md. Feeds the Zenodo deposit.
    "deposit_en_v18": {
        "md": "constitutive_recording_by_construction_v1.8_seihon_en.md",
        "diagrams": "constitutive_recording_by_construction_v1.6_diagrams_en.html",
        "out_pdf": "constitutive_recording_by_construction_v1.8_deposit_en.pdf",
        "title": "Another Frame Problem (v1.8)",
        "lang": "en",
        "strip_editorial": True,
        "anchors": {
            1: ("Three clarifications guard against reading", "<p"),
            2: ("Structural self-referentiality</h2>", "<h2"),
            3: ("None of the constitutive register itself is claimed as new here", "<p"),
        },
    },
    "deposit_ja_v18": {
        "md": "constitutive_recording_by_construction_v1.8_seihon_ja.md",
        "diagrams": "constitutive_recording_by_construction_v1.6_diagrams_ja.html",
        "out_pdf": "constitutive_recording_by_construction_v1.8_deposit_ja.pdf",
        "title": "もう一つのフレーム問題（日本語参照訳 v1.8）",
        "lang": "ja",
        "strip_editorial": True,
        "anchors": {
            1: ("主張を実際より大きく、あるいは別物として読まないために、但し書きを三つ。", "<p"),
            2: ("構造的自己言及性</h2>", "<h2"),
            3: ("構成的な register の考え方そのものは、ここで何か新しいものとして主張しているわけではない。", "<p"),
        },
    },
}


def renumber(fig, n):
    return re.sub(r'(<h2>)(Figure |図)\d+', lambda m: m.group(1) + m.group(2) + str(n), fig, count=1)


def build(lang):
    cfg = CONFIG[lang]
    md = os.path.join(DRAFTS, cfg["md"])
    tmp_md = None
    # Deposit builds strip the working editorial-status blockquote (§8: not part of the
    # deposited text). The master .md keeps it for review change-history continuity.
    if cfg.get("strip_editorial"):
        text = open(md, encoding="utf-8").read()
        text = "\n".join(l for l in text.split("\n") if not l.startswith("> **Editorial status"))
        tmp_md = os.path.join(DRAFTS, f"_deposit_src_{lang}.md")
        open(tmp_md, "w", encoding="utf-8").write(text)
        md = tmp_md
    # 1. text fragment via pandoc
    frag = subprocess.run(["pandoc", "-f", "markdown", "-t", "html5", "--wrap=none", md],
                          capture_output=True, text=True, check=True).stdout
    if tmp_md:
        os.remove(tmp_md)

    # 2. extract figures (file order: partial, record, outermost, migration)
    figs = re.findall(r'<figure>.*?</figure>', open(os.path.join(DRAFTS, cfg["diagrams"])).read(), re.S)
    assert len(figs) == 4, f"expected 4 figures, got {len(figs)}"
    partial, record, outermost, migration = figs  # migration no longer inserted (fig 4 dropped)
    # reading order -> pdf figure numbers
    ordered = {1: renumber(outermost, 1), 2: renumber(partial, 2),
               3: renumber(record, 3)}

    # 3. insert. Do the heading-anchored one (2) first on the pristine fragment,
    #    so rindex("<h2") cannot catch an already-inserted figure's <h2>.
    for num in (2, 1, 3):
        needle, tag = cfg["anchors"][num]
        pos = frag.index(needle)
        start = frag.rindex(tag, 0, pos)
        frag = frag[:start] + ordered[num] + "\n" + frag[start:]

    # 4. wrap
    doc = f"""<!DOCTYPE html>
<html lang="{cfg['lang']}">
<head>
<meta charset="utf-8">
<meta name="color-scheme" content="light">
<title>{cfg['title']}</title>
<style>
{BASE_CSS}
{DIAGRAM_CSS}
</style>
</head>
<body>
<article>
{frag}
</article>
</body>
</html>
"""
    build_html = os.path.join(DRAFTS, f"_pdfbuild_{lang}.html")
    open(build_html, "w").write(doc)

    # 5. Chrome headless -> PDF
    out_pdf = os.path.join(DRAFTS, cfg["out_pdf"])
    profile = f"/tmp/_chrome_pdf_{lang}"
    subprocess.run(["rm", "-rf", profile], check=False)
    if os.path.exists(out_pdf):
        os.remove(out_pdf)
    # Chrome headless sometimes writes the PDF but does not exit; tolerate that by
    # polling for the output file, then terminating the process.
    proc = subprocess.Popen([CHROME, "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
                             "--no-first-run", "--no-default-browser-check",
                             "--user-data-dir=" + profile, "--virtual-time-budget=8000",
                             "--print-to-pdf=" + out_pdf, "file://" + build_html],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    import time
    for _ in range(60):  # up to ~60s
        if proc.poll() is not None:
            break
        if os.path.exists(out_pdf) and os.path.getsize(out_pdf) > 0:
            time.sleep(1.5)  # let the final flush complete
            proc.terminate()
            break
        time.sleep(1)
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
    if not (os.path.exists(out_pdf) and os.path.getsize(out_pdf) > 0):
        raise RuntimeError(f"Chrome did not produce {out_pdf}")
    os.remove(build_html)
    print(f"[{lang}] {cfg['out_pdf']}: {os.path.getsize(out_pdf)} bytes")


langs = sys.argv[1:] if len(sys.argv) > 1 else ("en", "ja")
for lang in langs:
    build(lang)
print("done")
