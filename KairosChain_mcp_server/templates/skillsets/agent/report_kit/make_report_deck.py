"""Skeleton of an agent run's report in the layered form (L1 layered_visual_pitch_deck).

Usage:  python3 make_report_deck.py material.json out/deck.html
material.json is agent_status(run_id, report_material: true)["report_material"].

Main slides carry what the operator must act on, first; details pages carry the evidence; the appendix
lists every decision (D#), item (I#), phase, review round and effect, so the deck is complete against the
journal by construction. The report subagent may rewrite the main slides' wording and add figures; it must
keep every id and run check.py until issues=0.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kit
from kit import esc, hslide, page

PER_PAGE = 7


def li(text, limit=220):
    t = str(text or "")
    return f"<li>{esc(t if len(t) <= limit else t[:limit] + ' …')}</li>"


def box(title, items, cls=""):
    body = "".join(items) if items else "<li>なし</li>"
    return f'<div class="box {cls}"><h3>{esc(title)}</h3><ul>{body}</ul></div>'


def item_line(i):
    """An operator item with what the operator needs to act on it."""
    t = f"{i['id']} {i.get('item_kind')}: {i.get('text')}"
    opts = (i.get("detail") or {}).get("options")
    if opts:
        t += " — 選択肢: " + " / ".join(str(o) for o in opts)
    if i.get("command"):
        t += f" — 命令: {i['command']}"
    if i.get("change_file"):
        t += f" — 変更内容: {i['change_file']}"
    return t


def chunks(xs, n=PER_PAGE):
    xs = list(xs)
    return [xs[i:i + n] for i in range(0, len(xs), n)] or [[]]


def main(material_path, out_path):
    m = json.load(open(material_path, encoding="utf-8"))
    rid = m["run_id"]
    kit.FOOT_TITLE = f"agent run {rid}"
    slides = []

    # --- main layer -----------------------------------------------------------------------------
    hazard = m.get("hazard")
    open_items = [i for i in m.get("items", []) if i.get("state") == "open"]
    closures = m.get("provisional_closures", [])
    act = []
    if hazard:
        act.append(li(f"【危険・最優先】{hazard.get('ruling')}: {hazard.get('text')}"))
    act += [li(item_line(i), 900) for i in open_items]
    with_item = {(i.get("state_ref") or {}).get("ref") for i in open_items if i.get("item_kind") == "closure"}
    act += [li(f"仮に閉じた査読 {p}: あなたの言葉で確定か差し戻しを") for p in closures if p not in with_item]
    # Changes to the tests the run is judged by come first after the items (INV-3).
    act += [li(f"固定したテストの変更 {c.get('path')}: {'代役' if c.get('by') != 'operator' else 'あなた'}が承認"
               + (f"（{c.get('decision')}）" if c.get('decision') else "") + " — 違うなら判断 ID を名指しで訂正を", 400)
            for c in m.get("pinned_changes", [])]
    act.append(li(f"別のセッションから答えるときは、run id の末尾 6 文字（{rid[-6:]}）を添えてください（例: 「{rid[-6:]} I3 は凍結」）"))
    for n, part in enumerate(chunks(act), 1):
        slides.append(hslide(f"m{n}", "あなたがすること", f"走行 {esc(rid)} の宿題（{n}）",
                             f'<div class="box o"><ul>{"".join(part) or "<li>なし</li>"}</ul></div>',
                             page=f"main {n}", back=""))

    dec = {d["id"]: d for d in m.get("decisions", [])}
    look = [dec[i] for i in m.get("novel_or_low_confidence", []) if i in dec]
    for n, part in enumerate(chunks(look), 1):
        items = [li(f"{d['id']} [{d.get('point')}] {d.get('question')} → {d.get('answer')} "
                    f"（{d.get('class')}, 確信 {d.get('confidence')}）") for d in part]
        slides.append(hslide(f"mj{n}", "代役の判断", "前例がない、または確信の低い判断",
                             f'<div class="box c"><ul>{"".join(items) or "<li>なし</li>"}</ul></div>',
                             page=f"main j{n}"))

    pp = m.get("plan_parameters") or {}
    pr = m.get("plan_ratified") or {}
    plan_items = [li(f"{k}: {v}") for k, v in (pp.get("args") or {}).items() if k not in ("name",)]
    plan_items.append(li(f"代役の裁定 {pr.get('decision') or '-'}: {pr.get('answer')}"
                         + (f" → 変更 {pr.get('applied')}" if pr.get("applied") else "（変更なし）")))
    slides.append(hslide("mp", "代役が決めた計画", f"テンプレート {esc(pp.get('template') or '-')}",
                         box("計画の値（実行者が出し、代役が裁定）", plan_items), page="main p"))

    phases = m.get("phases", [])
    dl = m.get("design_latest") or {}
    ph_items = ([li(f"設計の最新版: {dl.get('path')}", 400)] if dl.get("path") else []) + \
         [li(f"{p['name']}: {p.get('status')}（{p.get('by') or '-'}{'、仮' if p.get('provisional') else ''}）"
                   + (f" 査読 {p.get('rounds')} 周" if p.get('rounds') else "")) for p in phases]
    checks = [li(f"{c.get('phase')}: {'通過' if c.get('ok') else '不通過'} "
                 + (f"{c.get('ran')} 本" if c.get('ran') is not None else "")
                 + (f"、外したテスト {len(c.get('removed_tests') or [])}" if c.get('removed_tests') else "")
                 + (f"、走行前から失敗 {len(c.get('failing_before_the_run') or [])}" if c.get('failing_before_the_run') else ""))
              for c in m.get("checks", [])]
    slides.append(hslide("mw", "何が変わったか", f"目標: {esc(m.get('goal') or '')}",
                         '<div class="two">' + box("段", ph_items) + box("検査", checks) + "</div>",
                         page="main w"))
    code = m.get("code") or {}
    if code.get("branch"):
        commits = [li(c) for c in (code.get("commits") or [])[:8]]
        stat = (code.get("diffstat") or "").strip().splitlines()
        info = [li(f"枝 {code.get('branch')}（{str(code.get('base'))[:10]}..{str(code.get('head'))[:10]}）"),
                li(f"作業場所 {code.get('worktree')}")] + ([li(stat[-1])] if stat else [])
        slides.append(hslide("mc", "何が変わったか・コード", f"コミット {len(code.get('commits') or [])} 件",
                             '<div class="two">' + box("枝", info) + box("コミット", commits) + "</div>", page="main c"))

    # How each review's P0s moved, round by round (design v0.6.1: closure at no
    # open P0; new P0s drawn by a revision are counted apart).
    trend = [li(f"{r['phase']} 第 {r['round']} 周: 持ち越し {t.get('carried_open', 0)}、直った {t.get('fixed', 0)}、"
                f"反証 {t.get('refuted', 0)}、後回し {t.get('deferred', 0)}、新規（直しが招いた）{t.get('new_from_revision', 0)}、"
                f"新規（その他）{t.get('new_elsewhere', 0)}")
             for r in m.get("review_rounds", []) if (t := r.get("tally"))]
    if trend:
        slides.append(hslide("mt", "査読の P0 の推移", "周ごとの持ち越し・直った・新規", box("周", trend[:12]), page="main t"))

    # --- details layer ----------------------------------------------------------------------------
    for r in m.get("review_rounds", []):
        seats = [li(f"{s.get('seat')}: {s.get('verdict')}") for s in r.get("seats", [])]
        labels = [li(f"{l.get('id')} [{l.get('label')}] {l.get('seat')}: {l.get('text')}"
                     + (f" — 根拠: {l.get('grounds')}" if l.get('grounds') else "")) for l in (r.get("labels") or [])]
        for n, part in enumerate(chunks(labels, 6), 1):
            slides.append(hslide(f"d_{r['phase']}_{r['round']}_{n}", "詳細・査読",
                                 f"{esc(r['phase'])} 第 {r['round']} 周（数えた席 {r.get('counted')}／定足数 {r.get('quorum')}）",
                                 '<div class="two">' + box("席の判定", seats) + box("代役の仕分け", part) + "</div>",
                                 page=f"D {r['phase']} {r['round']}"))
    pins = [li(f"{p.get('path')}（判断 {p.get('decision') or '-'}、{p.get('by') or '代役'}）") for p in m.get("pinned_changes", [])]
    if pins:
        slides.append(hslide("d_pins", "詳細・固定したテストの変更", "代役が認めた変更", box("変更", pins), page="D pins"))

    # --- appendix -----------------------------------------------------------------------------------
    for n, part in enumerate(chunks(m.get("decisions", [])), 1):
        items = [li(f"{d['id']} [{d.get('point')}] {d.get('question')} → {d.get('answer')}（{d.get('class')}, "
                    f"{d.get('confidence')}）{d.get('reason') or ''}", 300) for d in part]
        slides.append(hslide(f"b_dec{n}", "付録・代役の判断（全件）", f"判断 {n}", box("判断", items), page=f"B dec {n}"))
    for n, part in enumerate(chunks(m.get("items", [])), 1):
        items = [li(f"[{i.get('state')}] " + item_line(i), 900) for i in part]
        slides.append(hslide(f"b_items{n}", "付録・宿題（全件）", f"宿題 {n}", box("宿題", items), page=f"B items {n}"))
    for n, part in enumerate(chunks(m.get("effects", [])), 1):
        items = [li(f"#{e.get('seq')} {e.get('tool')}: {e.get('verdict')} {e.get('reason') or e.get('command') or ''}")
                 for e in part]
        slides.append(hslide(f"b_eff{n}", "付録・見張りが見た操作", f"操作 {n}", box("操作", items), page=f"B eff {n}"))
    nc = [li(x) for x in m.get("not_checked", [])] + [li(f"記録の要約値 {m.get('journal_digest')}")]
    slides.append(hslide("b_nc", "付録・確かめていないこと", "この報告が言えないこと", box("未確認", nc), page="B nc"))

    html = page(f"agent run {rid}", slides)
    open(out_path, "w", encoding="utf-8").write(html)
    print(f"{out_path} written: {len(slides)} pages")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
