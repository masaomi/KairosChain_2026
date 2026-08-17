#!/usr/bin/env python3
"""Compare the memo against L2, and render the comparison as one HTML page.

Presentation over `l2_scan.py`'s derivation, plus one addition: when the
authored mapping has nothing to say about an item, the search terms are
inferred from the item's own title and notes instead of the item going
unreported. L2 is never asked to change; inference reads the memo.

This script reads the context store, the memo, and the mapping, and writes
exactly one file: the HTML it was asked for. It never writes the memo. That is
checkable by reading this file -- the only `open(..., "w")` below is the output
path.

Where terms come from, in order:

  1. the authored mapping, when it has an entry that matches something. Kept
     first because it is the operator's own judgment and reaches records
     inference cannot: of 53 hand-authored terms, 43 appear nowhere in any item's
     title or notes. They were written from knowledge of the work.
  2. inference from the item's title and notes, in two tiers, when the mapping
     is absent or matched nothing. Every row says which source it used.

Inference is deliberately precision-first, and it refuses far more than it
accepts. Two tiers are allowed:

  tier A -- a token that is itself the name of an existing L2 document. Notes
            routinely carry one; it is the operator writing the correspondence
            down by hand, months before this script existed.
  tier B -- a compound identifier (one containing an underscore) whose substring
            reach across L2 is at or under REACH_CAP.

A bare English word is refused however rare it looks, and that refusal is the
whole of what makes this usable. Measured on 2026-08-17: accepting bare words
returned 51 and 82 records for the two items that in fact have nearly none --
lab-meeting decks, dataset registration, personality profiles -- because a
defect is described with words like store, write, file, tool, config and yaml,
and those match hundreds of unrelated names as substrings. With bare words
refused, the same two items return 2 and 17. Across the 24 items that carry an
authored mapping, inference alone returned 87 records, 86 of them also found by
hand and 1 not -- while missing 210 of the hand-found 296. That trade is the
intended one: misses are acceptable, a flood is not, because a flood asserts a
nearness that is not there.

Usage:
    python3 pm_l2_report.py                # writes <project>/log/pm_l2_report.html
    python3 pm_l2_report.py --quiet        # three lines, for a session-start hook
    python3 pm_l2_report.py --open         # write, then open in a browser
    python3 pm_l2_report.py -o /tmp/x.html
"""

import argparse
import datetime
import html
import importlib.util
import json
import os
import re
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCAN_PATH = os.path.join(HERE, "l2_scan.py")

# The largest number of L2 documents a tier-B term may reach before it is
# refused as too coarse to discriminate. 20 was chosen by measurement: at 20 the
# 24 mapped items yield 87 records with 1 not in the hand set; at 60 they yield
# 109 with the same 1, and the extra 22 come from terms broad enough that the
# next item to use one would flood. The tighter value is kept because a missed
# record is visible as a smaller count and a spurious one is not visible at all.
REACH_CAP = 20

TOKEN = re.compile(r"[a-z][a-z0-9_]{3,}")


def load_scan():
    if not os.path.exists(SCAN_PATH):
        sys.exit(f"derivation not found at {SCAN_PATH}")
    spec = importlib.util.spec_from_file_location("l2_scan", SCAN_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def infer_terms(item, docs, names, reach):
    """Terms read out of the item's own title and notes. See the module docstring."""
    text = f'{item.get("title", "")} {item.get("notes") or ""}'.lower()
    tokens = set(TOKEN.findall(text))
    tier_a = sorted(t for t in tokens if t in names)
    tier_b = sorted(t for t in tokens
                    if "_" in t and t not in names and 0 < reach(t) <= REACH_CAP)
    return tier_a + tier_b


def build_rows(scan, mapping, store, docs, now):
    """One row per memo item. Iteration is over the memo, so no item can vanish."""
    names = {d["name"].lower() for d in docs}
    reach_cache = {}

    def reach(term):
        if term not in reach_cache:
            reach_cache[term] = sum(1 for d in docs if term in d["handle"])
        return reach_cache[term]

    projects = {p["id"]: p["name"] for p in store["projects"].values()}
    rows = []
    for item_id, item in store["items"].items():
        spec = mapping["items"].get(item_id) or {}
        terms = list(spec.get("include", []))
        exclude = list(spec.get("exclude", []))
        records = scan.match(docs, terms, exclude) if terms else []
        source = "authored" if records else None
        if not records:
            terms, exclude = infer_terms(item, docs, names, reach), []
            records = scan.match(docs, terms, []) if terms else []
            source = "inferred" if records else "none"

        touched = (item.get("touched_at") or "")[:10]
        dated = [d for d in records if d["dates"]]
        days = sorted({day for d in dated for day in d["dates"]})
        row = {
            "id": item_id,
            "title": item.get("title", ""),
            "project": projects.get(item.get("project_id"), "—"),
            "store_status": item.get("status", ""),
            "salience": item.get("salience") or "",
            "due": (item.get("due") or "")[:10],
            "blocked_on": [f'{d["kind"]}:{d["ref"]}'
                           for d in item.get("deps", []) if not d.get("resolved")],
            "store_touched": touched,
            "memo_age_days": days_between(touched, now),
            "terms": {"include": terms, "exclude": exclude},
            "term_source": source,
            "records": records,
            "undated_records": len(records) - len(dated),
        }
        if days:
            row.update({
                "first_activity": days[0],
                "last_activity": days[-1],
                # Distinct days, not record count: a review round-trip adds records
                # without adding work.
                "active_days": len(days),
                "latest_nearby_record": dated[-1]["name"],
                "touch_delta_days": days_between(touched, datetime.date.fromisoformat(days[-1])),
            })
        rows.append(row)
    return rows


def days_between(start, end):
    try:
        start = datetime.date.fromisoformat(str(start)[:10])
    except (TypeError, ValueError):
        return None
    return (end - start).days


def collect(scan, now):
    with open(scan.MAPPING_PATH, encoding="utf-8") as fh:
        mapping = json.load(fh)
    with open(scan.STORE_PATH, encoding="utf-8") as fh:
        store = json.load(fh)
    docs, undated = scan.load_l2()
    return {
        "rows": build_rows(scan, mapping, store, docs, now),
        "docs": len(docs),
        "undated": undated,
        "mapping_version": mapping.get("version"),
        "store_path": scan.STORE_PATH,
    }


def summary(rows):
    matched = [r for r in rows if r.get("touch_delta_days") is not None]
    deltas = [r["touch_delta_days"] for r in matched]
    ahead = sorted(d for d in deltas if d > 0)
    return {
        "items": len(rows),
        "matched": len(matched),
        "l2_newer": len(ahead),
        "in_step": sum(1 for d in deltas if d == 0),
        "memo_newer": sum(1 for d in deltas if d < 0),
        # Median over lagging items only: including the rest would report a lag
        # smaller than any lagging item actually has.
        "median_lag": statistics.median(ahead) if ahead else None,
        "max_lag": ahead[-1] if ahead else None,
        "inferred": sum(1 for r in rows if r["term_source"] == "inferred"),
        "no_terms": sum(1 for r in rows if r["term_source"] == "none"),
    }


CSS = """
:root { --bg:#fbfbfa; --fg:#1c1b1a; --dim:#6d6a66; --line:#e2e0dc; --card:#fff;
        --warn:#b3541e; --ok:#3d6b47; --accent:#2f5d8a; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#16151a; --fg:#e8e6e3; --dim:#98948e; --line:#2e2c33; --card:#1e1d23;
          --warn:#e0894f; --ok:#7fae8b; --accent:#7aa7d4; } }
* { box-sizing:border-box }
body { margin:0; padding:28px 22px 60px; background:var(--bg); color:var(--fg);
       font:14px/1.6 -apple-system,"Hiragino Sans","Noto Sans JP",sans-serif; }
.wrap { max-width:1180px; margin:0 auto }
h1 { font-size:19px; margin:0 0 4px; font-weight:650 }
.sub { color:var(--dim); font-size:12.5px; margin-bottom:18px }
.banner { background:var(--card); border:1px solid var(--line); border-left:3px solid var(--accent);
          border-radius:5px; padding:10px 14px; margin-bottom:18px; font-size:13px }
.tiles { display:flex; flex-wrap:wrap; gap:10px; margin-bottom:22px }
.tile { background:var(--card); border:1px solid var(--line); border-radius:6px;
        padding:9px 14px; min-width:112px }
.tile b { display:block; font-size:21px; font-weight:650; line-height:1.25 }
.tile span { color:var(--dim); font-size:11.5px }
h2 { font-size:14.5px; margin:26px 0 9px; font-weight:650 }
table { width:100%; border-collapse:collapse; background:var(--card);
        border:1px solid var(--line); border-radius:6px; overflow:hidden }
th { text-align:left; font-size:11px; font-weight:600; color:var(--dim);
     padding:8px 9px; border-bottom:1px solid var(--line); white-space:nowrap }
td { padding:8px 9px; border-bottom:1px solid var(--line); vertical-align:top; font-size:12.5px }
tr:last-child td { border-bottom:none }
.num { text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap }
.d { color:var(--dim) }
.lag { color:var(--warn); font-weight:600 }
.same { color:var(--ok) }
.title { font-weight:550 }
.chip { display:inline-block; font-size:10.5px; padding:1px 6px; border:1px solid var(--line);
        border-radius:9px; color:var(--dim); margin-right:4px; white-space:nowrap }
.chip.inf { border-color:var(--accent); color:var(--accent) }
.bar { height:3px; background:var(--warn); border-radius:2px; margin-top:3px; opacity:.55 }
details { margin:0 } summary { cursor:pointer; list-style:none }
summary::-webkit-details-marker { display:none }
summary::before { content:"▸ "; color:var(--dim) }
details[open] summary::before { content:"▾ " }
.recs { margin:7px 0 3px; padding:8px 10px; background:var(--bg);
        border:1px solid var(--line); border-radius:5px; font-size:11.5px }
.recs div { padding:1.5px 0 } .recs .st { color:var(--warn) }
.foot { margin-top:30px; color:var(--dim); font-size:11.5px; line-height:1.8;
        border-top:1px solid var(--line); padding-top:14px }
"""


def e(text):
    return html.escape(str(text if text is not None else ""))


def render_records(row):
    """The per-item record list -- the only place a record's own status appears."""
    if not row["records"]:
        return ""
    lines = []
    for d in row["records"]:
        span = "/".join(d["dates"]) if d["dates"] else "(日付なし)"
        st = f' <span class="st">[{e(d["status"])}]</span>' if d["status"] else ""
        lines.append(f'<div><span class="d">{e(span)}</span>　{e(d["name"])}{st}</div>')
    t = row["terms"]
    origin = "手書きの対応表" if row["term_source"] == "authored" else "題名と備考から自動で抽出"
    head = (f'<div class="d">照合語（{origin}） include={e(t["include"])}'
            + (f' exclude={e(t["exclude"])}' if t["exclude"] else "") + '</div>')
    return (f'<details><summary class="d">{len(row["records"])} 件の近傍記録</summary>'
            f'<div class="recs">{head}{"".join(lines)}</div></details>')


def render(data, now):
    s = summary(data["rows"])
    matched = sorted((r for r in data["rows"] if r.get("touch_delta_days") is not None),
                     key=lambda r: (-r["touch_delta_days"], r["id"]))
    others = [r for r in data["rows"] if r.get("touch_delta_days") is None]
    widest = max((r["touch_delta_days"] for r in matched), default=1) or 1

    tiles = [
        (f'{s["matched"]}/{s["items"]}', "近くに記録がある項目"),
        (s["l2_newer"], "L2 のほうが新しい"),
        (f'{s["median_lag"]:g}日' if s["median_lag"] is not None else "—", "ずれの中央値"),
        (f'{s["max_lag"]}日' if s["max_lag"] is not None else "—", "ずれの最大"),
        (s["in_step"], "一致している"),
        (s["memo_newer"], "memo のほうが新しい"),
        (s["inferred"], "自動照合で拾った項目"),
        (s["no_terms"], "照合語が作れない項目"),
    ]
    tile_html = "".join(f'<div class="tile"><b>{e(v)}</b><span>{e(k)}</span></div>'
                        for v, k in tiles)

    rows_html = []
    for r in matched:
        delta = r["touch_delta_days"]
        cls = "lag" if delta > 0 else ("same" if delta == 0 else "d")
        bar = (f'<div class="bar" style="width:{min(100, delta / widest * 100):.0f}%"></div>'
               if delta > 0 else "")
        chips = "".join(f'<span class="chip{c[1]}">{e(c[0])}</span>' for c in filter(None, [
            (r["store_status"], "") if r["store_status"] != "open" else None,
            (r["salience"], "") if r["salience"] == "high" else None,
            (f'締切 {r["due"]}', "") if r["due"] else None,
            *[(f'待ち {b}', "") for b in r["blocked_on"]],
            ("自動照合", " inf") if r["term_source"] == "inferred" else None,
        ]))
        rows_html.append(f"""<tr>
<td><div class="title">{e(r["title"])}</div>{chips}
<div class="d" style="font-size:11px">{e(r["project"])}</div>{render_records(r)}</td>
<td class="num d">{e(r["store_touched"])}<br><span style="font-size:11px">{e(r["memo_age_days"])}日前</span></td>
<td class="num">{e(r["last_activity"])}<br><span class="d" style="font-size:11px">初 {e(r["first_activity"])}</span></td>
<td class="num {cls}">{delta:+d}日{bar}</td>
<td class="num d">{len(r["records"])}</td>
<td class="num d">{e(r["active_days"])}</td>
<td class="d">{e(r["latest_nearby_record"])}</td>
</tr>""")

    other_html = []
    for r in others:
        if r["term_source"] == "none":
            why = "照合語が 1 つも作れない。題名と備考に、L2 の名前と重なる語が無い"
        else:
            why = f'{len(r["records"])} 件見つかったが、どれも日付が読めない'
        other_html.append(f'<tr><td><div class="title">{e(r["title"])}</div>'
                          f'<div class="d" style="font-size:11px">{e(r["project"])}</div></td>'
                          f'<td class="num d">{e(r["store_touched"])}</td>'
                          f'<td class="d">{e(why)}</td></tr>')
    if not other_html:
        other_html.append('<tr><td colspan="3" class="d">なし — 全項目が突き合わせできています。</td></tr>')

    return f"""<!DOCTYPE html><html lang="ja"><meta charset="utf-8">
<title>project_manager — memo と L2 の突き合わせ</title>
<meta name="viewport" content="width=device-width,initial-scale=1"><style>{CSS}</style>
<div class="wrap">
<h1>project_manager — memo と L2 の突き合わせ</h1>
<div class="sub">生成 {e(now.isoformat())}　L2 文脈 {data["docs"]} 件を索引（うち日付を持たないもの {data["undated"]} 件）　対応表 v{e(data["mapping_version"])}</div>
<div class="banner"><b>この頁は読むだけです。</b>memo（<code>{e(os.path.basename(data["store_path"]))}</code>）には何も書いていません。
また、ある記録がある項目に<b>属すること</b>は主張していません。示しているのは「その項目の照合語に名前・経路・tag が一致した記録」であって、
1 つの記録が複数の項目の近くに正しく現れます。反映するかどうかは操作者の判断です。</div>
<div class="tiles">{tile_html}</div>

<h2>近くに記録がある項目（ずれの大きい順）</h2>
<table><tr>
<th>項目</th><th class="num">memo 最終</th><th class="num">L2 最終</th>
<th class="num">差</th><th class="num">記録</th><th class="num">活動日</th><th>直近の近傍記録（この項目の状態ではない）</th>
</tr>{"".join(rows_html)}</table>

<h2>突き合わせができない項目</h2>
<table><tr><th>項目</th><th class="num">memo 最終</th><th>理由</th></tr>{"".join(other_html)}</table>

<div class="foot">
<b>「差」</b>は memo と L2 の<b>どちらが最後に書かれたか</b>を比べた日数です。事実がどれだけ古いかではありません。実際に逆を指した例があります —
memo のほうが新しく見えた 1 件は、L2 が記録した 3 週間後に操作者が手で入れた却下で、事実としては memo のほうが 3 週間古いものでした。<br>
<b>「活動日」</b>は記録の件数ではなく、記録が書かれた<b>異なる日数</b>です。レビューが往復すると件数は増えますが、仕事量は増えていません。<br>
<b>「自動照合」</b>の印がある行は、手書きの対応表に項目が無いか、あっても何も一致しなかったので、その項目の題名と備考から照合語を作った行です。
拾えるのは L2 の文書名そのものと、下線を含む複合語のうち L2 で {REACH_CAP} 件以下にしか現れないものだけで、
<code>store</code> <code>config</code> のような普通の語は拒否します。拒否しないと、記録がほぼ無い項目に 82 件の無関係な文書が並びました。取りこぼしは残ります。<br>
各記録自身の状態は、項目を展開したときの一覧にだけ出ます。要約の列には出しません。1 行が 1 記録だと分かる場所でしか読めないようにするためです。<br>
照合は記録の<b>名前・経路・tag</b> のみで、本文は見ません（本文照合は 2026-07-27 の実測で精度およそ 25%）。
</div></div></html>"""


def default_out(scan):
    """<project root>/log/pm_l2_report.html. ROOT is the derivation's own anchor."""
    return os.path.join(scan.ROOT, "log", "pm_l2_report.html")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", help="output path (default: <project>/log/pm_l2_report.html)")
    ap.add_argument("--quiet", action="store_true", help="three lines, for a session-start hook")
    ap.add_argument("--open", action="store_true", dest="open_after",
                    help="open the written file in the default browser")
    args = ap.parse_args()

    scan = load_scan()
    out = args.out or default_out(scan)
    now = datetime.datetime.now().replace(microsecond=0)
    data = collect(scan, now.date())
    page = render(data, now)

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(page)

    s = summary(data["rows"])
    lag = (f", ずれ中央値 {s['median_lag']:g}日 / 最大 {s['max_lag']}日"
           if s["median_lag"] is not None else "")
    print(f"[project_manager] memo {s['items']} 項目のうち {s['l2_newer']} 件で L2 のほうが新しい{lag}。")
    if not args.quiet:
        print(f"  近くに記録がある項目 {s['matched']}/{s['items']}"
              f"（うち自動照合 {s['inferred']} 件、照合語が作れない {s['no_terms']} 件）")
    print(f"  {out}　memo には何も書いていません。")
    if args.open_after:
        subprocess.run(["open", out], check=False)


if __name__ == "__main__":
    main()
