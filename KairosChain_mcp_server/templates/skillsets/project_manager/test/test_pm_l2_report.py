#!/usr/bin/env python3
"""Tests for scripts/pm_l2_report.py.

Every case here exists because a reviewer demonstrated the defect it pins, so
each one is expected to FAIL against the version of the script that shipped
before them. That is the acceptance criterion for this file: a test that passes
either way is not holding anything.

The context store is synthetic and the derivation is the real `l2_scan` module --
`match` is called for real rather than reimplemented, because the two views
disagreeing about what a term matched is one of the failures being guarded.

Run:
    python3 test/test_pm_l2_report.py
"""

import datetime
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

SKILLSET = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(SKILLSET, "scripts", "pm_l2_report.py")


def load(path, name):
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.dont_write_bytecode = previous


rep = load(SCRIPT, "pm_l2_report_under_test")
scan = load(os.path.join(SKILLSET, "scripts", "l2_scan.py"), "l2_scan_under_test")


def doc(name, dates, status="", tags="", path=None):
    """One indexed context, in the shape l2_scan.load_l2 produces."""
    rel = path or f".kairos/context/s/{name}.md"
    return {
        "name": name, "path": rel, "dates": list(dates), "status": status,
        "handle": f"{name} {rel} {tags}".lower(), "digest": name,
    }


def item(**kw):
    base = {"id": "itm_1", "project_id": "prj_1", "title": "t", "status": "open",
            "deps": [], "salience": "normal", "touched_at": "2026-08-01T00:00:00Z"}
    base.update(kw)
    return base


def store_of(*items):
    return {"projects": {"prj_1": {"id": "prj_1", "name": "P"}},
            "items": {i["id"]: i for i in items}}


NOW = datetime.date(2026, 8, 17)


class StoredValuesAreNotValidated(unittest.TestCase):
    """pm_item writes due and touched_at through with no check beyond a JSON type,
    and the Ruby suite writes the integer 20260701 to both."""

    def test_date_prefix_of_an_integer_is_empty_not_a_crash(self):
        self.assertEqual(rep.date_prefix(20_260_701), "")
        self.assertEqual(rep.date_prefix(None), "")
        self.assertEqual(rep.date_prefix({"a": 1}), "")
        self.assertEqual(rep.date_prefix("2026-08-01T00:00:00Z"), "2026-08-01")

    def test_a_row_builds_for_an_item_whose_touched_at_is_an_integer(self):
        rows = rep.build_rows(scan, {"items": {}},
                              store_of(item(touched_at=20_260_701, due=20_260_701)),
                              [doc("alpha_beta_thing", ["2026-08-10"])], NOW)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["store_touched"], "")

    def test_text_of_coerces_a_non_string_title(self):
        rows = rep.build_rows(scan, {"items": {}}, store_of(item(title=42, notes=None)),
                              [doc("x_y_z_w", ["2026-08-10"])], NOW)
        self.assertEqual(rows[0]["title"], "42")


class ImpossibleDatesDoNotTakeTheRunDown(unittest.TestCase):
    """l2_scan validates a declared date's shape, never its existence."""

    def test_as_date_returns_none_for_a_shape_valid_impossible_date(self):
        self.assertIsNone(rep.as_date("2026-02-30"))
        self.assertIsNone(rep.as_date("2026-13-45"))
        self.assertIsNone(rep.as_date(None))
        self.assertEqual(rep.as_date("2026-08-17"), NOW)

    def test_days_between_guards_both_arguments(self):
        self.assertIsNone(rep.days_between("2026-02-30", NOW))
        self.assertIsNone(rep.days_between("2026-08-01", "2026-02-30"))
        self.assertEqual(rep.days_between("2026-08-01", NOW), 16)

    def test_one_impossible_context_date_does_not_stop_the_report(self):
        docs = [doc("impossible_date_ctx", ["2026-02-30"]), doc("impossible_date_ctx2", ["2026-08-10"])]
        rows = rep.build_rows(scan, {"items": {"itm_1": {"include": ["impossible_date_ctx"]}}},
                             store_of(item()), docs, NOW)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["term_source"], "authored")


class TheOutputPathCannotBeAnInput(unittest.TestCase):
    """The read-only promise used to be prose while open(out, "w") took any path."""

    def test_an_output_path_equal_to_the_memo_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            memo = os.path.join(tmp, "store.json")
            with open(memo, "w", encoding="utf-8") as fh:
                fh.write("{}")
            with self.assertRaises(SystemExit) as cm:
                rep.check_out_path(memo, [("memo", memo)])
            self.assertNotEqual(cm.exception.code, 0)
            with open(memo, encoding="utf-8") as fh:
                self.assertEqual(fh.read(), "{}", "memo was modified")

    def test_a_symlink_to_the_memo_is_refused_too(self):
        with tempfile.TemporaryDirectory() as tmp:
            memo = os.path.join(tmp, "store.json")
            with open(memo, "w", encoding="utf-8") as fh:
                fh.write("{}")
            link = os.path.join(tmp, "link.html")
            os.symlink(memo, link)
            with self.assertRaises(SystemExit):
                rep.check_out_path(link, [("memo", memo)])

    def test_an_ordinary_path_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "r.html")
            self.assertEqual(rep.check_out_path(out, [("memo", os.path.join(tmp, "s.json"))]), out)


class TheMappingsShapeIsNotTrusted(unittest.TestCase):
    """l2_mapping.json is the most hand-edited file in the feature."""

    def test_a_string_include_does_not_become_single_character_terms(self):
        self.assertEqual(rep.term_list("pm_store"), [])
        self.assertEqual(rep.term_list(["a", 3, None, "b", ""]), ["a", "b"])
        self.assertEqual(rep.term_list(None), [])

    def test_a_mapping_with_no_items_key_still_builds_rows(self):
        rows = rep.build_rows(scan, {"version": 1}, store_of(item()),
                              [doc("some_named_ctx", ["2026-08-10"])], NOW)
        self.assertEqual(len(rows), 1)

    def test_a_store_with_no_projects_key_still_builds_rows(self):
        rows = rep.build_rows(scan, {"items": {}}, {"items": {"itm_1": item()}},
                             [doc("some_named_ctx", ["2026-08-10"])], NOW)
        self.assertEqual(rows[0]["project"], "—")

    def test_a_dependency_missing_kind_or_ref_does_not_crash(self):
        rows = rep.build_rows(scan, {"items": {}},
                             store_of(item(deps=[{"ref": "x"}, {"kind": "item"}, "junk"])),
                             [doc("some_named_ctx", ["2026-08-10"])], NOW)
        self.assertEqual(len(rows[0]["blocked_on"]), 2)


class InferenceCannotFlood(unittest.TestCase):
    """A document name is name: or title: or the basename, and a free-text title
    can be one common word. Tier A had no reach cap."""

    def setUp(self):
        # 40 documents whose handles all contain "review", one of them named exactly
        # "review" -- the shape that turned a bare word into a tier-A term.
        self.docs = [doc(f"review_thread_{n}", ["2026-08-01"]) for n in range(40)]
        self.docs.append(doc("review", ["2026-08-02"]))
        self.names = {d["name"].lower() for d in self.docs}
        self.cache = {}

    def reach(self, t):
        if t not in self.cache:
            self.cache[t] = sum(1 for d in self.docs if t in d["handle"])
        return self.cache[t]

    def test_a_bare_document_name_over_the_cap_is_refused(self):
        terms = rep.infer_terms(self.names, self.reach, item(title="the review of things"))
        self.assertNotIn("review", terms,
                         f"'review' reaches {self.reach('review')} documents and must be refused")

    def test_a_narrow_document_name_is_still_accepted(self):
        docs = self.docs + [doc("pm_store_write_guard", ["2026-08-03"])]
        names = {d["name"].lower() for d in docs}
        cache = {}

        def reach(t):
            if t not in cache:
                cache[t] = sum(1 for d in docs if t in d["handle"])
            return cache[t]

        terms = rep.infer_terms(names, reach, item(title="pm_store_write_guard の修正"))
        self.assertIn("pm_store_write_guard", terms)

    def test_a_bare_english_word_is_refused_even_when_narrow(self):
        docs = [doc("one_ctx_only", ["2026-08-01"], tags="store")]
        names = {d["name"].lower() for d in docs}
        terms = rep.infer_terms(names, lambda t: sum(1 for d in docs if t in d["handle"]),
                                item(title="store の話"))
        self.assertEqual(terms, [], "a bare word with no underscore must never be a term")

    def test_the_flood_does_not_reach_a_built_row(self):
        rows = rep.build_rows(scan, {"items": {}}, store_of(item(title="the review of things")),
                              self.docs, NOW)
        self.assertLessEqual(len(rows[0]["records"]), rep.REACH_CAP)


class TheAuthoredExcludeSurvivesTheFallback(unittest.TestCase):
    """Names in this project nest, so exclude states a distinction the include
    terms cannot make on their own."""

    def test_exclude_is_carried_into_inference(self):
        docs = [doc("guard_track_slice_one", ["2026-08-01"]),
                doc("guard_track_inv8_thing", ["2026-08-02"])]
        mapping = {"items": {"itm_1": {"include": ["no_such_term_at_all"], "exclude": ["inv8"]}}}
        rows = rep.build_rows(scan, mapping, store_of(item(title="guard_track_slice_one を直す")),
                              docs, NOW)
        row = rows[0]
        self.assertEqual(row["term_source"], "inferred")
        self.assertEqual(row["terms"]["exclude"], ["inv8"])
        self.assertNotIn("guard_track_inv8_thing", [d["name"] for d in row["records"]])


class ThreeReasonsAreWordedApart(unittest.TestCase):
    """No marker, an unreadable marker, and an undatable record are different facts."""

    def test_a_missing_marker_is_not_reported_as_undatable_records(self):
        docs = [doc("named_ctx_alpha", ["2026-08-07"])]
        mapping = {"items": {"itm_1": {"include": ["named_ctx_alpha"]}}}
        rows = rep.build_rows(scan, mapping, store_of(item(touched_at=None)), docs, NOW)
        row = rows[0]
        self.assertIsNone(row["touch_delta_days"])
        self.assertEqual(row["last_activity"], "2026-08-07")
        reason = rep.unmatched_reason(row)
        self.assertIn("memo 側の最終接触", reason)
        self.assertNotIn("どれも日付が読めない", reason)

    def test_undatable_records_are_reported_as_such(self):
        docs = [doc("named_ctx_beta", [], path=".kairos/context/s/named_ctx_beta.md")]
        mapping = {"items": {"itm_1": {"include": ["named_ctx_beta"]}}}
        rows = rep.build_rows(scan, mapping, store_of(item()), docs, NOW)
        self.assertIn("どれも日付が読めない", rep.unmatched_reason(rows[0]))

    def test_no_terms_is_reported_as_such(self):
        rows = rep.build_rows(scan, {"items": {}}, store_of(item(title="日本語のみ", notes=None)),
                              [doc("unrelated_ctx", ["2026-08-01"])], NOW)
        self.assertEqual(rows[0]["term_source"], "none")
        self.assertIn("照合語", rep.unmatched_reason(rows[0]))

    def test_the_summary_counts_the_unreadable_marker_separately(self):
        docs = [doc("named_ctx_alpha", ["2026-08-07"])]
        mapping = {"items": {"itm_1": {"include": ["named_ctx_alpha"]}}}
        rows = rep.build_rows(scan, mapping, store_of(item(touched_at="2026-13-99")), docs, NOW)
        self.assertEqual(rep.summary(rows)["no_marker"], 1)


class TheRenderedPageIsSafeAndDegenerateInputsRender(unittest.TestCase):
    def _page(self, rows, docs_n=1):
        return rep.render({"rows": rows, "docs": docs_n, "undated": 0,
                           "mapping_version": 1, "store_path": "/x/store.json"},
                          datetime.datetime(2026, 8, 17, 12, 0, 0))

    def test_html_in_operator_text_is_escaped(self):
        payload = '</td></tr><script>alert(1)</script>'
        docs = [doc("named_ctx_alpha", ["2026-08-10"], status='</span><b>PWNED</b>')]
        mapping = {"items": {"itm_1": {"include": ["named_ctx_alpha"]}}}
        rows = rep.build_rows(scan, mapping, store_of(item(title=payload)), docs, NOW)
        page = self._page(rows)
        self.assertNotIn("<script>alert(1)</script>", page)
        self.assertNotIn("<b>PWNED</b>", page)
        self.assertIn("&lt;script&gt;", page)

    def test_terms_are_rendered_as_text_not_a_python_list(self):
        docs = [doc("named_ctx_alpha", ["2026-08-10"])]
        mapping = {"items": {"itm_1": {"include": ["named_ctx_alpha"]}}}
        rows = rep.build_rows(scan, mapping, store_of(item()), docs, NOW)
        page = self._page(rows)
        self.assertNotIn("[&#x27;named_ctx_alpha&#x27;]", page)
        self.assertIn("named_ctx_alpha", page)

    def test_a_page_with_no_items_renders(self):
        self.assertIn("<!DOCTYPE html", self._page([]))

    def test_a_page_where_every_item_is_unmatched_renders(self):
        rows = rep.build_rows(scan, {"items": {}}, store_of(item(title="日本語のみ")),
                              [doc("unrelated_ctx", ["2026-08-01"])], NOW)
        self.assertIn("差を出せなかった項目", self._page(rows))


class RunningTheScriptLeavesNothingBehind(unittest.TestCase):
    """exec_module writes bytecode. The .pyc landed inside the SkillSet, which is
    inside Skillset#all_file_hashes and therefore inside the chain-recorded hash."""

    def test_importing_the_derivation_writes_no_pycache(self):
        with tempfile.TemporaryDirectory() as tmp:
            scripts = os.path.join(tmp, ".kairos", "skillsets", "project_manager", "scripts")
            os.makedirs(os.path.join(tmp, ".kairos", "context", "s"))
            os.makedirs(scripts)
            for f in ("l2_scan.py", "pm_l2_report.py"):
                with open(os.path.join(SKILLSET, "scripts", f), encoding="utf-8") as src, \
                     open(os.path.join(scripts, f), "w", encoding="utf-8") as dst:
                    dst.write(src.read())
            os.makedirs(os.path.join(tmp, ".kairos", "pm"))
            with open(os.path.join(tmp, ".kairos", "pm", "store.json"), "w") as fh:
                json.dump(store_of(item()), fh)
            with open(os.path.join(tmp, ".kairos", "pm", "l2_mapping.json"), "w") as fh:
                json.dump({"version": 1, "items": {}}, fh)
            with open(os.path.join(tmp, ".kairos", "context", "s", "some_named_ctx.md"), "w") as fh:
                fh.write("---\nname: some_named_ctx\ndate: 2026-08-10\n---\nbody\n")
            r = subprocess.run([sys.executable, os.path.join(scripts, "pm_l2_report.py"), "--quiet"],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            left = [p for _, _, fs in os.walk(scripts) for p in fs if p.endswith(".pyc")] + \
                   [d for _, ds, _ in os.walk(scripts) for d in ds if d == "__pycache__"]
            self.assertEqual(left, [], f"bytecode left inside the SkillSet: {left}")


class AbsencesAreReportedNotRaised(unittest.TestCase):
    """The script runs unattended from a SessionStart hook."""

    def _run(self, build):
        with tempfile.TemporaryDirectory() as tmp:
            scripts = os.path.join(tmp, ".kairos", "skillsets", "project_manager", "scripts")
            os.makedirs(os.path.join(tmp, ".kairos", "context", "s"))
            os.makedirs(scripts)
            for f in ("l2_scan.py", "pm_l2_report.py"):
                with open(os.path.join(SKILLSET, "scripts", f), encoding="utf-8") as src, \
                     open(os.path.join(scripts, f), "w", encoding="utf-8") as dst:
                    dst.write(src.read())
            build(tmp)
            return subprocess.run([sys.executable, os.path.join(scripts, "pm_l2_report.py"),
                                   "--quiet"], capture_output=True, text=True)

    def test_a_fresh_instance_with_no_pm_directory_says_so_and_exits_zero(self):
        r = self._run(lambda tmp: None)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("[project_manager]", r.stdout)
        self.assertEqual(r.stderr, "")

    def test_a_malformed_memo_names_the_file_and_exits_nonzero(self):
        def build(tmp):
            os.makedirs(os.path.join(tmp, ".kairos", "pm"))
            with open(os.path.join(tmp, ".kairos", "pm", "store.json"), "w") as fh:
                fh.write("{ not json")
        r = self._run(build)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("store.json", r.stdout)
        self.assertNotIn("Traceback", r.stdout + r.stderr)

    def test_a_missing_mapping_falls_back_to_inference_only(self):
        def build(tmp):
            os.makedirs(os.path.join(tmp, ".kairos", "pm"))
            with open(os.path.join(tmp, ".kairos", "pm", "store.json"), "w") as fh:
                json.dump(store_of(item(title="some_named_ctx の続き")), fh)
            with open(os.path.join(tmp, ".kairos", "context", "s", "some_named_ctx.md"), "w") as fh:
                fh.write("---\nname: some_named_ctx\ndate: 2026-08-10\n---\nbody\n")
        r = self._run(build)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("自動照合", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=1)
