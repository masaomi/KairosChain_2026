#!/usr/bin/env python3
"""Compare the memo against L2, and render the comparison as one HTML page.

Presentation over `l2_scan.py`'s derivation, plus one addition: when the authored
mapping has nothing to say about an item, the search terms are inferred from the
item's own title and notes instead of the item going unreported. L2 is never asked
to change; inference reads the memo.

Read-only, and the reading is what enforces it rather than a comparison. There is
no way to name an output path: the page always goes to `<data dir>/reports/`, so
no argument can point a write at the memo, the mapping, an L2 context, or
`config/pm.yml`. An earlier version took `-o` and guarded it by comparing resolved
paths, which failed three ways — a case-only difference on a case-insensitive
filesystem, a hardlink, and any read input that was not one of the two it knew
about. Deleting the argument closed all three; a fourth guard would not have.

Paths come from this file's own location and not from any hardcoded directory
name. The script lives at `<data dir>/skillsets/project_manager/scripts/`, so the
data dir is three levels up whatever it is called. `l2_scan` derives its own paths
by appending a literal `.kairos`, which reported a populated instance as empty
whenever the data dir had been relocated under another name, so its four path
constants are re-pointed here after import.

It runs unattended from a SessionStart hook, so an exception is a defect. Every
absence and every malformed input is reported in one line and exits: an absent
memo is not an error (a fresh instance has none), a malformed one is. Stored values
are not trusted to have a type: `pm_item` writes `due` and `touched_at` through
with no check beyond a JSON type, and this SkillSet's own Ruby suite writes the
integer 20260701 to both.

Where terms come from, in order:

  1. the authored mapping, when it has an entry that matches something. Kept first
     because it is the operator's own judgment and reaches records inference
     cannot: of 53 hand-authored terms, 43 appear nowhere in any item's title or
     notes. They were written from knowledge of the work.
  2. inference from the item's title and notes, when the mapping is absent or
     matched nothing. Every row says which source it used.

An authored `exclude` is NOT applied to inferred terms, and the page says so on
the row. It was written to separate the authored include terms from a neighbouring
subject whose name nests inside them; an inferred term is usually the item's own
record name, which is what the exclude term is a substring of, so carrying it over
suppressed the item's own primary record. Carrying it was itself a fix in an
earlier round, and it turned out to trade one wrong answer for another.

Inference is precision-first and refuses far more than it accepts. Two tiers, both
capped by how many documents a term reaches:

  tier A -- a token that is itself the name of an existing L2 document.
  tier B -- a compound identifier (one containing an underscore).

A bare English word is refused however rare it looks. And the ROW is capped, not
only each term: if the union of everything the inferred terms match exceeds
REACH_CAP, inference is refused for that item and the row says the terms were too
broad. Truncating instead would have been silent, and it would have moved
`last_activity` and the headline figures with it.

Three measurements stand behind those rules, each from a reviewer who ran the code:

  - Accepting bare words returned 51 and 82 records for the two items that in fact
    have nearly none, because a defect is described with words like store, write,
    file, tool, config and yaml, and those match hundreds of unrelated names as
    substrings. With bare words refused, the same two return 2 and 17.
  - Leaving tier A uncapped reopened the hole through a different door. A document
    name is `name:` or `title:` or the basename, and 321 of 1177 contexts take it
    from a free-text `title:`. One context titled `Review` made `review` a term
    reaching 351 records; titled `Context`, 1178 -- the whole store.
  - Capping each term and not the row left it open a third time. Twelve terms each
    under the cap unioned to 124 of 1179 documents for one item, and a note of the
    ordinary shape already reached 23.

The per-term cap costs nothing measurable: of 1125 distinct document names none
reaches more than 20, and across the 28 live items every inferred union is at most
20 today, so the row cap refuses nothing that currently works.

Usage:
    python3 pm_l2_report.py            # writes <data dir>/reports/pm_l2_report.html
    python3 pm_l2_report.py --quiet     # two lines instead of three, for the hook
    python3 pm_l2_report.py --open      # write, then open in a browser
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
# <data dir>/skillsets/project_manager/scripts -> <data dir>. Derived from this
# file's position rather than from the name ".kairos", which is relocatable.
DATA_DIR = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
OUT_PATH = os.path.join(DATA_DIR, "reports", "pm_l2_report.html")

# The largest number of L2 documents a term may reach, and also the largest number
# of records an inferred row may end up with. See the module docstring for what an
# uncapped tier A and an uncapped row each did.
REACH_CAP = 20

TOKEN = re.compile(r"[a-z][a-z0-9_]{3,}")

PREFIX = "[project_manager]"


def say(message):
    print(f"{PREFIX} {message}")


def stop(message, code):
    """One line, then exit. Code 0 for an absence that is not a fault."""
    say(message)
    sys.exit(code)


def load_scan():
    """Import the derivation and re-point it at this data dir.

    dont_write_bytecode is set around the import so a read-only report does not
    leave a .pyc inside the SkillSet: that file is inside Skillset#all_file_hashes
    and therefore inside content_hash, the value recorded on chain, which made the
    recorded hash a function of the local CPython build. The flag is restored
    afterwards so importing this module does not change a caller's environment.
    """
    if not os.path.exists(SCAN_PATH):
        stop(f"導出 l2_scan.py が {SCAN_PATH} に見つかりません。SkillSet が壊れています。", 1)
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec = importlib.util.spec_from_file_location("l2_scan", SCAN_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except Exception as exc:  # noqa: BLE001 -- an unattended run reports, never traces
        stop(f"導出 l2_scan.py を読み込めません: {type(exc).__name__}: {exc}", 1)
    finally:
        sys.dont_write_bytecode = previous
    module.ROOT = os.path.dirname(DATA_DIR)
    module.CONTEXT_GLOB = os.path.join(DATA_DIR, "context", "**", "*.md")
    module.MAPPING_PATH = os.path.join(DATA_DIR, "pm", "l2_mapping.json")
    module.STORE_PATH = os.path.join(DATA_DIR, "pm", "store.json")
    return module


def read_json(path, label, missing_ok=False):
    """Load one JSON file, or stop with one line saying which file and why."""
    if not os.path.exists(path):
        if missing_ok:
            return None
        stop(f"{label}が見つかりません（{path}）。", 0)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError) as exc:
        stop(f"{label}を読めません（{path}）: {type(exc).__name__}: {exc}", 1)
    if not isinstance(data, dict):
        stop(f"{label}が object ではありません（{path}）。", 1)
    return data


def sub_dict(container, key):
    """A nested object, or {}. A truthy non-object reached .values() and raised."""
    value = container.get(key)
    return value if isinstance(value, dict) else {}


def text_of(value):
    """Operator free text as a string. The store validates nothing it stores."""
    return value if isinstance(value, str) else ("" if value is None else str(value))


def date_prefix(value):
    """The YYYY-MM-DD head of a stored timestamp, or "" if it is not a string."""
    return value[:10] if isinstance(value, str) else ""


def term_list(value):
    """A mapping entry's include/exclude as a list of strings, or [].

    `l2_mapping.json` is hand-edited and nothing checks its shape. `list("pm_store")`
    is eight single-character terms, one of which matched 1177 of 1177 documents
    while displaying as the operator's own authored mapping.
    """
    if not isinstance(value, list):
        return []
    return [t for t in value if isinstance(t, str) and t]


def infer_terms(names, reach, item):
    """Terms read out of the item's own title and notes. See the module docstring."""
    text = f'{text_of(item.get("title"))} {text_of(item.get("notes"))}'.lower()
    tokens = set(TOKEN.findall(text))
    capped = [t for t in tokens if 0 < reach(t) <= REACH_CAP]
    tier_a = sorted(t for t in capped if t in names)
    tier_b = sorted(t for t in capped if "_" in t and t not in names)
    return tier_a + tier_b


def as_date(value):
    """A date, or None. Every date in this file is parsed here and nowhere else.

    `datetime` is excluded deliberately: it satisfies isinstance against `date`,
    and returning one lets `days_between` raise on the subtraction.
    """
    if isinstance(value, datetime.datetime):
        return value.date()
    if isinstance(value, datetime.date):
        return value
    try:
        return datetime.date.fromisoformat(str(value)[:10])
    except (TypeError, ValueError):
        return None


def days_between(start, end):
    start, end = as_date(start), as_date(end)
    if start is None or end is None:
        return None
    return (end - start).days


def build_rows(scan, mapping, store, docs, now):
    """One row per memo item. Iteration is over the memo, so no item can vanish."""
    names = {d["name"].lower() for d in docs}
    reach_cache = {}

    def reach(term):
        if term not in reach_cache:
            reach_cache[term] = sum(1 for d in docs if term in d["handle"])
        return reach_cache[term]

    mapped = sub_dict(mapping, "items")
    projects = {p.get("id"): text_of(p.get("name"))
                for p in sub_dict(store, "projects").values() if isinstance(p, dict)}
    rows = []
    for item_id, item in sub_dict(store, "items").items():
        if not isinstance(item, dict):
            continue
        spec = mapped.get(item_id) if isinstance(mapped.get(item_id), dict) else {}
        terms = term_list(spec.get("include"))
        exclude = term_list(spec.get("exclude"))
        records = scan.match(docs, terms, exclude) if terms else []
        source = "authored" if records else None
        if not records:
            # The authored exclude stops here. It was written against the authored
            # include terms; an inferred term is usually the item's own record name,
            # which the exclude term is a substring of, so applying it here dropped
            # the item's own primary record.
            exclude = []
            terms = infer_terms(names, reach, item)
            records = scan.match(docs, terms, []) if terms else []
            if not records:
                source = "none"
            elif len(records) > REACH_CAP:
                # Refused rather than truncated: truncation is silent, and it moves
                # last_activity and the headline figures with it.
                source, records = "too_broad", []
            else:
                source = "inferred"

        touched = date_prefix(item.get("touched_at"))
        deps = item.get("deps") if isinstance(item.get("deps"), list) else []
        dated = [d for d in records if d["dates"]]
        days = sorted({day for d in dated for day in d["dates"]})
        latest = as_date(days[-1]) if days else None
        row = {
            "id": item_id,
            "title": text_of(item.get("title")),
            "project": projects.get(item.get("project_id")) or "—",
            "store_status": text_of(item.get("status")),
            "salience": text_of(item.get("salience")),
            "due": date_prefix(item.get("due")),
            "blocked_on": [f'{text_of(d.get("kind"))}:{text_of(d.get("ref"))}'
                           for d in deps if isinstance(d, dict) and not d.get("resolved")],
            "store_touched": touched,
            "memo_age_days": days_between(touched, now),
            "terms": {"include": terms, "exclude": exclude},
            "term_source": source,
            "records": records,
            "inferred_hits": len(scan.match(docs, terms, [])) if source == "too_broad" else None,
            "latest_parses": latest is not None,
            "marker_parses": as_date(touched) is not None,
        }
        if days:
            row.update({
                "first_activity": days[0],
                "last_activity": days[-1],
                # Distinct days, not record count: a review round-trip adds records
                # without adding work.
                "active_days": len(days),
                "latest_nearby_record": dated[-1]["name"],
                "touch_delta_days": days_between(touched, latest),
            })
        rows.append(row)
    return rows


def unmatched_reason(row):
    """Why a row has no comparison. Five causes, each worded for its own side.

    Collapsing any two of these has produced a false statement twice: records that
    were perfectly datable reported as undatable, and then a memo marker blamed for
    a date that L2 had written wrong. Which side is broken is the whole content of
    this line, so each side gets its own sentence.
    """
    if row["term_source"] == "none":
        return "照合語が 1 つも作れない。題名と備考に、L2 の名前と重なる語が無い"
    if row["term_source"] == "too_broad":
        return (f'自動照合の語が広すぎる（{row["inferred_hits"]} 件に当たったので使わない）。'
                f'対応表に語を書けば拾える')
    if not row["records"]:
        return "照合語に当たる記録が無い"
    if not row.get("last_activity"):
        return f'{len(row["records"])} 件見つかったが、どれも日付を持たない'
    if not row["latest_parses"]:
        return (f'記録は {len(row["records"])} 件あるが、最新として書かれた日付 '
                f'{row["last_activity"]} が日付として読めない。直すのは L2 の側')
    return (f'記録は {len(row["records"])} 件あり最新は {row["last_activity"]} だが、'
            f'memo 側の最終接触が読めない。直すのは memo の側')


def collect(scan, now):
    mapping = read_json(scan.MAPPING_PATH, "対応表 l2_mapping.json", missing_ok=True)
    if mapping is None:
        # A fresh instance has no mapping and does not need one: every item falls
        # through to inference. Absence is the first-run state, not a fault.
        mapping = {"items": {}}
        say("対応表 l2_mapping.json がまだありません。全項目を自動照合で扱います。")
    store = read_json(scan.STORE_PATH, "memo store.json")
    if not sub_dict(store, "items"):
        stop("memo に項目がまだありません。比べるものが無いので何も出しません。", 0)
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
        "too_broad": sum(1 for r in rows if r["term_source"] == "too_broad"),
        "no_terms": sum(1 for r in rows if r["term_source"] == "none"),
        "bad_l2_date": sum(1 for r in rows if r.get("last_activity") and not r["latest_parses"]),
        "no_marker": sum(1 for r in rows if r.get("last_activity")
                         and r["latest_parses"] and not r["marker_parses"]),
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


def terms_text(terms):
    """Terms as reading text. A Python list repr is not operator-facing prose."""
    return "、".join(terms) if terms else "なし"


def render_terms(row):
    """The search terms, shown for every row including the ones that matched nothing.

    A row that reports "no term could be built" while not showing what it tried is
    a claim the operator cannot check at the point where it is wrong.
    """
    origin = "手書きの対応表" if row["term_source"] == "authored" else "題名と備考から自動で抽出"
    out = f'<div class="d">照合語（{origin}）: {e(terms_text(row["terms"]["include"]))}'
    if row["terms"]["exclude"]:
        out += f'　除外: {e(terms_text(row["terms"]["exclude"]))}'
    elif row["term_source"] not in ("authored", "none"):
        out += "　除外: なし（手書きの除外語は自動照合には適用しません）"
    return out + "</div>"


def render_records(row):
    """The per-item record list -- the only place a record's own status appears."""
    if not row["records"]:
        return f'<div class="recs">{render_terms(row)}</div>'
    lines = []
    for d in row["records"]:
        span = "/".join(d["dates"]) if d["dates"] else "(日付なし)"
        st = f' <span class="st">[{e(d["status"])}]</span>' if d["status"] else ""
        lines.append(f'<div><span class="d">{e(span)}</span>　{e(d["name"])}{st}</div>')
    return (f'<details><summary class="d">{len(row["records"])} 件の近傍記録</summary>'
            f'<div class="recs">{render_terms(row)}{"".join(lines)}</div></details>')


def render(data, now):
    s = summary(data["rows"])
    matched = sorted((r for r in data["rows"] if r.get("touch_delta_days") is not None),
                     key=lambda r: (-r["touch_delta_days"], r["id"]))
    others = [r for r in data["rows"] if r.get("touch_delta_days") is None]
    widest = max((r["touch_delta_days"] for r in matched), default=1) or 1

    tiles = [
        (f'{s["matched"]}/{s["items"]}', "差を出せた項目"),
        (s["l2_newer"], "L2 のほうが新しい"),
        (f'{s["median_lag"]:g}日' if s["median_lag"] is not None else "—", "ずれの中央値"),
        (f'{s["max_lag"]}日' if s["max_lag"] is not None else "—", "ずれの最大"),
        (s["in_step"], "一致している"),
        (s["memo_newer"], "memo のほうが新しい"),
        (s["inferred"], "自動照合で拾った項目"),
        (s["too_broad"], "自動照合の語が広すぎた"),
        (s["bad_l2_date"], "L2 の最新日付が読めない"),
        (s["no_marker"], "memo の最終接触が読めない"),
        (s["no_terms"], "照合語が作れない"),
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
            (r["store_status"], "") if r["store_status"] not in ("open", "") else None,
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

    other_html = ["".join([
        "<tr>",
        f'<td><div class="title">{e(r["title"])}</div>'
        f'<div class="d" style="font-size:11px">{e(r["project"])}</div>{render_records(r)}</td>',
        f'<td class="num d">{e(r["store_touched"]) or "（無し）"}</td>',
        f'<td class="d">{e(unmatched_reason(r))}</td>',
        "</tr>",
    ]) for r in others]
    if not other_html:
        other_html.append('<tr><td colspan="3" class="d">なし — 全項目で差が出せています。</td></tr>')

    return f"""<!DOCTYPE html><html lang="ja"><meta charset="utf-8">
<title>project_manager — memo と L2 の突き合わせ</title>
<meta name="viewport" content="width=device-width,initial-scale=1"><style>{CSS}</style>
<div class="wrap">
<h1>project_manager — memo と L2 の突き合わせ</h1>
<div class="sub">生成 {e(now.isoformat())}　L2 文脈 {data["docs"]} 件を索引（うち日付を持たないもの {data["undated"]} 件）　対応表 v{e(data["mapping_version"])}</div>
<div class="banner"><b>この頁は読むだけです。</b>出力先は固定で、引数では変えられません。だから memo（<code>{e(os.path.basename(data["store_path"]))}</code>）にも、対応表にも、L2 の文脈にも、書き込む経路がありません。
また、ある記録がある項目に<b>属すること</b>は主張していません。示しているのは「その項目の照合語に名前・経路・tag が一致した記録」であって、
1 つの記録が複数の項目の近くに正しく現れます。反映するかどうかは操作者の判断です。</div>
<div class="tiles">{tile_html}</div>

<h2>差を出せた項目（ずれの大きい順）</h2>
<table><tr>
<th>項目</th><th class="num">memo 最終</th><th class="num">L2 最終</th>
<th class="num">差</th><th class="num">記録</th><th class="num">活動日</th><th>直近の近傍記録（この項目の状態ではない）</th>
</tr>{"".join(rows_html)}</table>

<h2>差を出せなかった項目</h2>
<table><tr><th>項目</th><th class="num">memo 最終</th><th>理由</th></tr>{"".join(other_html)}</table>

<div class="foot">
<b>「差」</b>は memo と L2 の<b>どちらが最後に書かれたか</b>を比べた日数です。事実がどれだけ古いかではありません。実際に逆を指した例があります —
memo のほうが新しく見えた 1 件は、L2 が記録した 3 週間後に操作者が手で入れた却下で、事実としては memo のほうが 3 週間古いものでした。<br>
<b>「活動日」</b>は記録の件数ではなく、記録が書かれた<b>異なる日数</b>です。レビューが往復すると件数は増えますが、仕事量は増えていません。<br>
<b>「自動照合」</b>の印がある行は、手書きの対応表に項目が無いか、あっても何も一致しなかったので、その項目の題名と備考から照合語を作った行です。
拾えるのは L2 の文書名そのものと、下線を含む複合語で、いずれも L2 で {REACH_CAP} 件以下にしか当たらないものだけです。
<code>store</code> <code>config</code> のような普通の語は拒否します。さらに、<b>その行が集めた記録の合計</b>も {REACH_CAP} 件以下でなければ、自動照合そのものを使いません。
上限を語ごとにしか掛けなかったとき、各語は上限内なのに合計 124 件になった例があります。切って見せるのではなく使わないのは、切ると
「最新の記録」と見出しの数字が黙って動くからです。<br>
<b>手書きの除外語は、自動照合には適用しません。</b>除外語は手書きの照合語に対して書かれたもので、自動で選ばれた語は多くの場合その項目自身の記録名です。
適用すると、その項目自身の記録が落ちました。<br>
差が出せない理由は5つに書き分けています。照合語が作れない／自動照合の語が広すぎる／記録が日付を持たない／<b>L2 の最新日付が読めない</b>／<b>memo 側の最終接触が読めない</b>。
最後の2つは壊れている側が違うので、同じ文にしません。<br>
各記録自身の状態は、項目を展開したときの一覧にだけ出ます。要約の列には出しません。1 行が 1 記録だと分かる場所でしか読めないようにするためです。<br>
照合は記録の<b>名前・経路・tag</b> のみで、本文は見ません（本文照合は 2026-07-27 の実測で精度およそ 25%）。
</div></div></html>"""


def open_in_browser(path):
    """Best effort. macOS has `open`, Linux has `xdg-open`, and the gem ships to both."""
    for binary in ("open", "xdg-open"):
        try:
            subprocess.run([binary, path], check=False)
            return
        except (FileNotFoundError, OSError):
            continue
    say("開くための open / xdg-open が見つかりません。上の経路を手で開いてください。")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quiet", action="store_true",
                    help="two lines instead of three, for a session-start hook")
    ap.add_argument("--open", action="store_true", dest="open_after",
                    help="open the written page in the default browser")
    args = ap.parse_args()

    scan = load_scan()
    now = datetime.datetime.now().replace(microsecond=0)
    data = collect(scan, now.date())
    page = render(data, now)

    try:
        os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
        with open(OUT_PATH, "w", encoding="utf-8") as fh:
            fh.write(page)
    except OSError as exc:
        stop(f"出力を書けません（{OUT_PATH}）: {type(exc).__name__}: {exc}", 1)

    s = summary(data["rows"])
    lag = (f"、ずれ中央値 {s['median_lag']:g}日 / 最大 {s['max_lag']}日"
           if s["median_lag"] is not None else "")
    say(f"memo {s['items']} 項目のうち {s['l2_newer']} 件で L2 のほうが新しい{lag}"
        f"（帰属は主張しません。近くに何が書かれたかだけです）。")
    if not args.quiet:
        print(f"  差を出せた項目 {s['matched']}/{s['items']}"
              f"（自動照合 {s['inferred']}、語が広すぎ {s['too_broad']}、"
              f"L2 の日付が読めない {s['bad_l2_date']}、memo の最終接触が読めない {s['no_marker']}、"
              f"照合語が作れない {s['no_terms']}）")
    print(f"  {OUT_PATH}")
    if args.open_after:
        open_in_browser(OUT_PATH)


if __name__ == "__main__":
    main()
