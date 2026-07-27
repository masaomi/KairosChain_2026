#!/usr/bin/env python3
"""Report evidence of activity near each work item, from the L2 context store.

L2 is the source of truth; pm/store.json is a derived memo. This script reads
L2 and reports what it finds. It never writes store.json -- reconciliation is a
separate, human-gated step.

It does not claim that a matched document *belongs* to the item it is reported
under. Tags name subjects; items name work that remains. One document can sit
correctly under several items, so the output is evidence for an operator to
judge, not an attribution. Column names and the docstrings below are held to
that: nothing here is called an item's status.

Design constraints, each established by measurement (2026-07-27, revised the
same day after review):

  1. Match on document name / path / tags only. Body-text matching measured
     roughly 25% precision -- of twelve items whose result it changed, nine
     changed to work belonging elsewhere.
  2. An item that matches nothing is repaired in L2 by labelling the work, not
     by widening the mapping. Widening trades a visible gap for an invisible
     false positive.
  3. The mapping needs exclusion as well as inclusion terms, because L2 names
     nest (plugin_projector is a substring of pm_plugin_projection).
  4. Report what each figure measures. The interval between the memo's last
     touch and L2's last activity measures when someone last wrote something
     down; it does not measure how stale the underlying fact is, and it has
     been observed pointing the wrong way.
  5. A document carries every date it declares. Preferring one field over the
     others reported the earliest date under a name promising the latest;
     twelve documents in this store declare an update later than their
     creation with no separate date field.
  6. Identity is content, not name. Contexts sharing a name across sessions are
     successive revisions, not copies: of twenty-five same-name groups here,
     none were byte-identical. Collapsing by name discards records.
  7. No aggregate field carries a matched record's status. A status line lifted
     whole is a statement about work this scan does not claim to attribute, and
     it crosses the boundary the memo's own read surface is held to. Per-record
     status is available under --item, where each line is plainly one record.

Usage:
    python3 l2_scan.py                 # evidence table
    python3 l2_scan.py --json          # the same, as JSON
    python3 l2_scan.py --item itm_xxx  # one item, listing every matched record
"""

import argparse
import datetime
import glob
import hashlib
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
CONTEXT_GLOB = os.path.join(ROOT, ".kairos", "context", "**", "*.md")
MAPPING_PATH = os.path.join(ROOT, ".kairos", "pm", "l2_mapping.json")
STORE_PATH = os.path.join(ROOT, ".kairos", "pm", "store.json")

DATE_FIELDS = ("date", "created", "updated")


def _frontmatter(text):
    if not text.startswith("---"):
        return ""
    parts = text.split("---", 2)
    return parts[1] if len(parts) > 2 else ""


def _field(fm, key):
    m = re.search(rf"^{key}:\s*(.+)$", fm, re.M)
    return m.group(1).strip().strip("\"'") if m else ""


def _dates_of(fm, path):
    """Every date the document declares, earliest first.

    Constraint 5: a document that was created on one day and updated on
    another was worked on both, so both are kept. The path stamp is a fallback
    only -- roughly a third of contexts declare no date field at all, and the
    session directory is the only evidence they carry.
    """
    found = set()
    for key in DATE_FIELDS:
        m = re.match(r"(\d{4}-\d{2}-\d{2})", _field(fm, key))
        if m:
            found.add(m.group(1))
    if not found:
        m = re.search(r"(20\d{6})", path)
        if m:
            s = m.group(1)
            found.add(f"{s[:4]}-{s[4:6]}-{s[6:]}")
    return sorted(found)


def load_l2():
    """Index every context. Undated documents are kept and counted, not dropped.

    Dropping them silently reported an invisible record as absent work, which
    is one of the errors this scan exists to avoid making.
    """
    docs = []
    undated = 0
    # Sorted: dedup keeps the first record of a given content, so an unsorted
    # walk would let the filesystem decide which of two identical files
    # survives -- and with it the surviving name and path. No such pair exists
    # today; the sort is what keeps that true if one appears.
    for path in sorted(glob.glob(CONTEXT_GLOB, recursive=True)):
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        fm = _frontmatter(text)
        dates = _dates_of(fm, path)
        if not dates:
            undated += 1
        name = _field(fm, "name") or _field(fm, "title") or os.path.splitext(os.path.basename(path))[0]
        rel = os.path.relpath(path, ROOT)
        tags = " ".join(re.findall(r"[\w]+", _field(fm, "tags").lower()))
        docs.append({
            "name": name,
            "path": rel,
            "dates": dates,
            "status": _field(fm, "status"),
            # Constraint 1: the haystack is name + path + tags. Never the body.
            "handle": f"{name} {rel} {tags}".lower(),
            # Constraint 6: identity is content.
            "digest": hashlib.sha256(text.encode("utf-8", "replace")).hexdigest(),
        })
    return docs, undated


def match(docs, include, exclude):
    """Matched records: distinct content, deterministically ordered.

    Two files with identical content are one record however many sessions hold
    them. Two files of the same name with different content are two records,
    because they are revisions and the later one supersedes nothing -- both
    happened. Ordering is (last date, name, path), all three needed: path is
    the only field guaranteed unique, so it is what makes the order total.
    """
    seen = set()
    hits = []
    for doc in docs:
        if any(term in doc["handle"] for term in exclude):
            continue
        if not any(term in doc["handle"] for term in include):
            continue
        if doc["digest"] in seen:
            continue
        seen.add(doc["digest"])
        hits.append(doc)
    return sorted(hits, key=lambda d: (d["dates"][-1] if d["dates"] else "", d["name"], d["path"]))


def derive(docs, mapping, store):
    """One row per store item. Iteration is over the store, not the mapping.

    Iterating the mapping made an item with no mapping entry vanish from the
    output entirely, which is the same silence the mapping exists to remove.
    An item is either matched, unmapped, or mapped-but-unmatched, and all three
    are visible.
    """
    rows = []
    for item_id, item in store["items"].items():
        spec = mapping["items"].get(item_id)
        touched = item["touched_at"][:10]
        row = {
            "id": item_id,
            "title": item["title"],
            "store_status": item["status"],
            "store_touched": touched,
        }
        if spec is None:
            row["needs_mapping"] = True
            rows.append(row)
            continue
        hits = match(docs, spec.get("include", []), spec.get("exclude", []))
        dated = [d for d in hits if d["dates"]]
        row["records"] = len(hits)
        row["undated_records"] = len(hits) - len(dated)
        if not dated:
            # Constraint 2: a gap in L2's labelling, not in the scan -- unless
            # records were found and none of them can be dated, which is a
            # different gap and must not be reported as a missing label.
            row["needs_l2_label" if not hits else "records_all_undated"] = True
            rows.append(row)
            continue
        days = sorted({d for doc in dated for d in doc["dates"]})
        latest = dated[-1]
        row.update({
            "first_activity": days[0],
            "last_activity": days[-1],
            # Distinct days, not record count: review round-trips inflate the
            # count without reflecting how much work was done.
            "active_days": len(days),
            # Named for what it is: a record near the item. Its status is not
            # carried here -- see constraint 7.
            "latest_nearby_record": latest["name"],
            "touch_delta_days": (datetime.date.fromisoformat(days[-1])
                                 - datetime.date.fromisoformat(touched)).days,
        })
        rows.append(row)
    return rows


def report(rows, undated_total):
    matched = [r for r in rows if "last_activity" in r]
    head = "{:<34}{:>4}{:>5}  {:<11}{:<11}{:<11}{:>5}  {}"
    print(head.format("item", "recs", "days", "first", "L2 last", "memo", "delta",
                      "most recent nearby record (not this item's status)"))
    print("=" * 150)
    for r in sorted(matched, key=lambda r: -r["touch_delta_days"]):
        flag = "*" if r["touch_delta_days"] > 0 else (" " if r["touch_delta_days"] == 0 else "<")
        print(head.format(
            r["title"][:34], r["records"], r["active_days"], r["first_activity"],
            r["last_activity"], r["store_touched"], f'{r["touch_delta_days"]:+d}',
            flag + " " + r["latest_nearby_record"][:52]))
    for r in rows:
        if r.get("needs_l2_label"):
            print(head.format(r["title"][:34], "-", "", "", "", r["store_touched"], "",
                              "  no nearby record; needs an L2 name or tag"))
        elif r.get("records_all_undated"):
            print(head.format(r["title"][:34], str(r["records"]), "", "", "", r["store_touched"], "",
                              "  records found, none datable"))
        elif r.get("needs_mapping"):
            print(head.format(r["title"][:34], "-", "", "", "", r["store_touched"], "",
                              "  needs a mapping entry"))
    print("=" * 150)
    deltas = [r["touch_delta_days"] for r in matched]
    ahead = sorted(d for d in deltas if d > 0)
    print(f"{len(matched)}/{len(rows)} items have nearby activity   "
          f"L2 more recent: {len(ahead)}   in step: {sum(1 for d in deltas if d == 0)}   "
          f"memo more recent: {sum(1 for d in deltas if d < 0)}")
    if ahead:
        mid = len(ahead) // 2
        median = ahead[mid] if len(ahead) % 2 else (ahead[mid - 1] + ahead[mid]) / 2
        print(f"memo lag where L2 is more recent: median {median:g}d, max {ahead[-1]}d")
    print(f"{undated_total} indexed contexts declare no date and carry none in their path.")
    print("delta compares when each side was last written to. It does not measure "
          "how stale the underlying fact is, and has been seen pointing the wrong way.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", action="store_true", help="emit the derived aggregate as JSON")
    ap.add_argument("--item", help="show every record matched for one item id")
    args = ap.parse_args()

    with open(MAPPING_PATH, encoding="utf-8") as fh:
        mapping = json.load(fh)
    with open(STORE_PATH, encoding="utf-8") as fh:
        store = json.load(fh)
    docs, undated = load_l2()

    if args.item:
        spec = mapping["items"].get(args.item)
        if spec is None:
            sys.exit(f"no mapping for {args.item}")
        hits = match(docs, spec.get("include", []), spec.get("exclude", []))
        print(f"{args.item}  {spec.get('title', '')}")
        print(f"include={spec.get('include')}  exclude={spec.get('exclude')}")
        print(f"{len(hits)} records near this item (nearness, not attribution):")
        for d in hits:
            span = "/".join(d["dates"]) if d["dates"] else "(undated)"
            print(f"  {span:<34}{d['name'][:60]:<60}  {(d['status'] or '')[:30]}")
        return

    rows = derive(docs, mapping, store)
    if args.json:
        print(json.dumps({
            "source": "L2 context store",
            "claims_attribution": False,
            "contexts_indexed": len(docs),
            "contexts_undated": undated,
            "mapping_version": mapping["version"],
            "items": rows,
        }, ensure_ascii=False, indent=2))
    else:
        print(f"indexed {len(docs)} contexts\n")
        report(rows, undated)


if __name__ == "__main__":
    main()
