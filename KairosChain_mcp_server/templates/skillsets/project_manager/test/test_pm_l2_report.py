#!/usr/bin/env python3
"""Tests for scripts/pm_l2_report.py.

Every case exists because a reviewer demonstrated the defect it pins. The bar is
not that a case is red against some earlier version — it is that **breaking the
guard by one line makes this suite red**. An audit of the previous version of this
file applied 65 one-line mutations and 36 survived, so the cases that survived
mutation have been rewritten rather than added to. Four habits came out of that
audit and are followed here:

  1. Guards are exercised through `main()`, not only as functions. Two mutations
     to `main` — deleting the output-path guard's call, and shortening its
     protected list — left the old suite green, because nothing ran `main`.
  2. A fixture must not be able to satisfy the assertion on its own. The old
     impossible-date case built two documents, the second matching the same term,
     so the valid date sorted last and the impossible one never reached the parse
     point; the pre-fix call site stayed green.
  3. Aggregation is tested with several items. Every case in the old suite built at
     most one row, so counting every row as matched, taking the median over all
     deltas, and reversing the sort order were all green.
  4. Messages and exit codes are asserted by content, not by "non-zero" or "the
     prefix is present". Emptying a diagnostic and changing an exit code to 137
     were both green.

The context store is synthetic; the derivation is the real `l2_scan` module, so
`match` is driven rather than reimplemented.

Run:
    python3 test/test_pm_l2_report.py
"""

import datetime
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

SKILLSET = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(SKILLSET, "scripts")


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


rep = load(os.path.join(SCRIPTS, "pm_l2_report.py"), "pm_l2_report_under_test")
scan = load(os.path.join(SCRIPTS, "l2_scan.py"), "l2_scan_under_test")
NOW = datetime.date(2026, 8, 17)


def doc(name, dates, status="", tags="", path=None, digest=None):
    """One indexed context, in the shape l2_scan.load_l2 produces.

    digest defaults to name+path, not name: two contexts sharing a name with
    different content are two records, and a name-keyed digest collapsed them.
    """
    rel = path or f".kairos/context/s/{name}.md"
    return {
        "name": name, "path": rel, "dates": list(dates), "status": status,
        "handle": f"{name} {rel} {tags}".lower(), "digest": digest or f"{name}|{rel}",
    }


def item(n=1, **kw):
    base = {"id": f"itm_{n}", "project_id": "prj_1", "title": f"t{n}", "status": "open",
            "deps": [], "salience": "normal", "touched_at": "2026-08-01T00:00:00Z"}
    base.update(kw)
    return base


def store_of(*items):
    return {"projects": {"prj_1": {"id": "prj_1", "name": "P"}},
            "items": {i["id"]: i for i in items}}


class Instance:
    """A throwaway data directory laid out the way the script expects.

    The script derives every path from its own location, so a copy under a
    directory of any name is a complete instance. Used to drive main() in a
    subprocess, which is the only way the wiring gets exercised.
    """

    def __init__(self, tmp, data_dir_name=".kairos"):
        self.root = tmp
        self.data = os.path.join(tmp, data_dir_name)
        self.scripts = os.path.join(self.data, "skillsets", "project_manager", "scripts")
        os.makedirs(self.scripts)
        os.makedirs(os.path.join(self.data, "context", "s"))
        for f in ("l2_scan.py", "pm_l2_report.py"):
            with open(os.path.join(SCRIPTS, f), encoding="utf-8") as src, \
                 open(os.path.join(self.scripts, f), "w", encoding="utf-8") as dst:
                dst.write(src.read())

    def pm(self, store=None, mapping=None):
        os.makedirs(os.path.join(self.data, "pm"), exist_ok=True)
        if store is not None:
            self.write_json(os.path.join(self.data, "pm", "store.json"), store)
        if mapping is not None:
            self.write_json(os.path.join(self.data, "pm", "l2_mapping.json"), mapping)

    def context(self, name, body):
        with open(os.path.join(self.data, "context", "s", f"{name}.md"), "w",
                  encoding="utf-8") as fh:
            fh.write(body)

    @staticmethod
    def write_json(path, value):
        with open(path, "w", encoding="utf-8") as fh:
            if isinstance(value, str):
                fh.write(value)
            else:
                json.dump(value, fh)

    def run(self, *args):
        return subprocess.run([sys.executable, os.path.join(self.scripts, "pm_l2_report.py"),
                               *args], capture_output=True, text=True)

    @property
    def out_path(self):
        return os.path.join(self.data, "log", "pm_l2_report.html")


class TheProgramCannotBeAimedAtAnInput(unittest.TestCase):
    """There is no output-path argument. Comparing paths failed three ways -- a
    case-only difference, a hardlink, and any read input the check did not know
    about -- so the argument was deleted instead of guarded a fourth time."""

    def test_no_argument_can_set_the_output_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            inst = Instance(tmp)
            inst.pm(store_of(item()), {"version": 1, "items": {}})
            r = inst.run("-o", os.path.join(inst.data, "pm", "store.json"))
            self.assertNotEqual(r.returncode, 0, "-o was accepted")
            self.assertIn("unrecognized arguments", r.stderr)
            with open(os.path.join(inst.data, "pm", "store.json"), encoding="utf-8") as fh:
                json.load(fh)  # still valid JSON

    def test_the_memo_is_byte_identical_across_a_successful_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            inst = Instance(tmp)
            inst.pm(store_of(item(title="named_ctx_alpha の件")), {"version": 1, "items": {}})
            inst.context("named_ctx_alpha", "---\nname: named_ctx_alpha\ndate: 2026-08-10\n---\nb\n")
            memo = os.path.join(inst.data, "pm", "store.json")
            with open(memo, "rb") as fh:
                before = fh.read()
            r = inst.run("--quiet")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            with open(memo, "rb") as fh:
                self.assertEqual(fh.read(), before)

    def test_the_page_goes_beside_the_data_dir_it_was_run_from(self):
        with tempfile.TemporaryDirectory() as tmp:
            inst = Instance(tmp)
            inst.pm(store_of(item()), {"version": 1, "items": {}})
            r = inst.run("--quiet")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertTrue(os.path.exists(inst.out_path), r.stdout)
            self.assertIn(inst.out_path, r.stdout)

    def test_a_relocated_data_dir_is_found_whatever_it_is_called(self):
        """The derivation appended a literal .kairos, so a relocated instance
        reported itself empty at exit 0 on every session."""
        with tempfile.TemporaryDirectory() as tmp:
            inst = Instance(tmp, data_dir_name="kairosdata")
            inst.pm(store_of(item(title="named_ctx_alpha の件")), {"version": 1, "items": {}})
            inst.context("named_ctx_alpha", "---\nname: named_ctx_alpha\ndate: 2026-08-10\n---\nb\n")
            r = inst.run("--quiet")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertNotIn("見つかりません", r.stdout)
            self.assertIn("memo 1 項目", r.stdout)
            self.assertTrue(os.path.exists(inst.out_path))


class StoredValuesHaveNoGuaranteedType(unittest.TestCase):
    """pm_item writes due and touched_at through with no check beyond a JSON type,
    and this SkillSet's Ruby suite writes the integer 20260701 to both."""

    def test_date_prefix_of_a_non_string_is_empty(self):
        for value in (20_260_701, None, {"a": 1}, [1], 3.5, True):
            self.assertEqual(rep.date_prefix(value), "", repr(value))
        self.assertEqual(rep.date_prefix("2026-08-01T00:00:00Z"), "2026-08-01")

    def test_a_row_builds_when_touched_at_and_due_are_integers(self):
        rows = rep.build_rows(scan, {"items": {}},
                              store_of(item(touched_at=20_260_701, due=20_260_701)),
                              [doc("alpha_beta_thing", ["2026-08-10"])], NOW)
        self.assertEqual(rows[0]["store_touched"], "")
        self.assertEqual(rows[0]["due"], "")

    def test_the_whole_program_survives_an_integer_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            inst = Instance(tmp)
            inst.pm(store_of(item(touched_at=20_260_701)), {"version": 1, "items": {}})
            r = inst.run("--quiet")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertNotIn("Traceback", r.stderr)

    def test_a_non_string_title_is_coerced(self):
        rows = rep.build_rows(scan, {"items": {}}, store_of(item(title=42, notes=None)),
                              [doc("x_y_z_w", ["2026-08-10"])], NOW)
        self.assertEqual(rows[0]["title"], "42")

    def test_a_non_object_projects_or_items_value_does_not_raise(self):
        for bad in ([{"id": "x"}], "string", 42, None):
            rows = rep.build_rows(scan, {"items": {}},
                                  {"projects": bad, "items": {"itm_1": item()}},
                                  [doc("x_y_z_w", ["2026-08-10"])], NOW)
            self.assertEqual(rows[0]["project"], "—", repr(bad))
            self.assertEqual(rep.build_rows(scan, {"items": {}},
                                            {"projects": {}, "items": bad},
                                            [doc("x_y_z_w", ["2026-08-10"])], NOW), [])

    def test_a_dependency_missing_kind_or_ref_does_not_raise(self):
        rows = rep.build_rows(scan, {"items": {}},
                              store_of(item(deps=[{"ref": "x"}, {"kind": "item"}, "junk"])),
                              [doc("x_y_z_w", ["2026-08-10"])], NOW)
        self.assertEqual(len(rows[0]["blocked_on"]), 2)


class ADateIsParsedInOnePlace(unittest.TestCase):
    """l2_scan validates that a declared date looks like a date, never that it
    exists, and the path fallback formats any 20nnnnnn run into a dashed date."""

    def test_as_date_rejects_shape_valid_impossible_dates(self):
        for bad in ("2026-02-30", "2026-13-45", "2026-00-01", None, 42, "", "not-a-date"):
            self.assertIsNone(rep.as_date(bad), repr(bad))
        self.assertEqual(rep.as_date("2026-08-17"), NOW)

    def test_as_date_narrows_a_datetime_to_a_date(self):
        """A datetime satisfies isinstance against date; returning one unchanged
        let days_between raise on the subtraction."""
        got = rep.as_date(datetime.datetime(2026, 8, 17, 12, 30))
        self.assertEqual(got, NOW)
        self.assertNotIsInstance(got, datetime.datetime)
        self.assertEqual(rep.days_between("2026-08-01", datetime.datetime(2026, 8, 17, 12)), 16)

    def test_days_between_guards_both_ends(self):
        self.assertIsNone(rep.days_between("2026-02-30", NOW))
        self.assertIsNone(rep.days_between("2026-08-01", "2026-02-30"))
        self.assertEqual(rep.days_between("2026-08-01", NOW), 16)

    def test_a_single_impossible_context_date_does_not_stop_the_program(self):
        """One document only, so the impossible date IS the latest and does reach
        the parse point. The two-document version of this case was green against
        the pre-fix code."""
        with tempfile.TemporaryDirectory() as tmp:
            inst = Instance(tmp)
            inst.pm(store_of(item(title="bad_date_ctx の件")),
                    {"version": 1, "items": {"itm_1": {"include": ["bad_date_ctx"]}}})
            inst.context("bad_date_ctx", "---\nname: bad_date_ctx\ndate: 2026-02-30\n---\nb\n")
            r = inst.run("--quiet")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertNotIn("Traceback", r.stderr)
            with open(inst.out_path, encoding="utf-8") as fh:
                self.assertIn("L2 の最新日付が読めない", fh.read())


class InferenceCannotFloodAndSaysWhenItRefuses(unittest.TestCase):
    """Three separate holes were closed here: bare words, an uncapped
    document-name tier, and a capped-per-term but uncapped row."""

    def setUp(self):
        # 40 handles containing "review", one document named exactly "review".
        self.docs = [doc(f"review_thread_{n}", ["2026-08-01"]) for n in range(40)]
        self.docs.append(doc("review", ["2026-08-02"]))
        self.names = {d["name"].lower() for d in self.docs}
        self.cache = {}

    def reach(self, t):
        if t not in self.cache:
            self.cache[t] = sum(1 for d in self.docs if t in d["handle"])
        return self.cache[t]

    def test_a_document_name_over_the_cap_is_refused(self):
        terms = rep.infer_terms(self.names, self.reach, item(title="the review of things"))
        self.assertNotIn("review", terms,
                         f"'review' reaches {self.reach('review')} documents")

    def test_a_narrow_document_name_is_accepted(self):
        docs = self.docs + [doc("pm_store_write_guard", ["2026-08-03"])]
        names = {d["name"].lower() for d in docs}
        reach = lambda t: sum(1 for d in docs if t in d["handle"])  # noqa: E731
        self.assertIn("pm_store_write_guard",
                      rep.infer_terms(names, reach, item(title="pm_store_write_guard の修正")))

    def test_a_bare_english_word_is_refused_even_when_narrow(self):
        docs = [doc("one_ctx_only", ["2026-08-01"], tags="store")]
        names = {d["name"].lower() for d in docs}
        reach = lambda t: sum(1 for d in docs if t in d["handle"])  # noqa: E731
        self.assertEqual(rep.infer_terms(names, reach, item(title="store の話")), [])

    def test_many_terms_each_under_the_cap_do_not_flood_the_row(self):
        """Each term reaches at most 3 documents; their union is 30. The row cap is
        what stops this -- per-term caps did not."""
        docs = [doc(f"topic_{g}_thread_{n}", ["2026-08-01"]) for g in range(10) for n in range(3)]
        title = " ".join(f"topic_{g}_thread_0" for g in range(10))
        store = store_of(item(title=title, notes=" ".join(f"topic_{g}" for g in range(10))))
        rows = rep.build_rows(scan, {"items": {}}, store, docs, NOW)
        row = rows[0]
        self.assertEqual(row["term_source"], "too_broad",
                         f'{len(row["records"])} records slipped through')
        self.assertEqual(row["records"], [])
        self.assertGreater(row["inferred_hits"], rep.REACH_CAP)
        self.assertIn("自動照合の語が広すぎる", rep.unmatched_reason(row))
        self.assertEqual(rep.summary(rows)["too_broad"], 1)

    def test_a_row_just_inside_the_cap_is_still_reported(self):
        docs = [doc(f"topic_a_thread_{n}", ["2026-08-01"]) for n in range(rep.REACH_CAP)]
        rows = rep.build_rows(scan, {"items": {}},
                              store_of(item(title="topic_a_thread_0 の件", notes="topic_a")),
                              docs, NOW)
        self.assertEqual(rows[0]["term_source"], "inferred")
        self.assertEqual(len(rows[0]["records"]), rep.REACH_CAP)

    def test_an_authored_mapping_is_not_capped(self):
        """The cap is on inference. The operator's own terms are their judgment."""
        docs = [doc(f"authored_thread_{n}", ["2026-08-01"]) for n in range(rep.REACH_CAP + 12)]
        rows = rep.build_rows(scan, {"items": {"itm_1": {"include": ["authored_thread"]}}},
                              store_of(item()), docs, NOW)
        self.assertEqual(rows[0]["term_source"], "authored")
        self.assertEqual(len(rows[0]["records"]), rep.REACH_CAP + 12)


class TheAuthoredExcludeStopsAtTheAuthoredTerms(unittest.TestCase):
    """Carrying it into inference was itself an earlier fix, and it traded one wrong
    answer for another: an exclude term is a substring of document names, and an
    inferred term is usually the item's own record name."""

    def test_the_exclude_is_not_applied_to_inferred_terms(self):
        docs = [doc("guard_track_inv8_thing", ["2026-08-02"])]
        mapping = {"items": {"itm_1": {"include": ["no_such_term"], "exclude": ["inv8"]}}}
        rows = rep.build_rows(scan, mapping,
                              store_of(item(title="guard_track_inv8_thing を直す")), docs, NOW)
        row = rows[0]
        self.assertEqual(row["term_source"], "inferred")
        self.assertEqual(row["terms"]["exclude"], [])
        self.assertEqual([d["name"] for d in row["records"]], ["guard_track_inv8_thing"],
                         "the item's own record was suppressed by a carried exclude")

    def test_the_exclude_still_applies_to_the_authored_terms(self):
        docs = [doc("guard_track_slice_one", ["2026-08-01"]),
                doc("guard_track_inv8_thing", ["2026-08-02"])]
        mapping = {"items": {"itm_1": {"include": ["guard_track"], "exclude": ["inv8"]}}}
        rows = rep.build_rows(scan, mapping, store_of(item()), docs, NOW)
        row = rows[0]
        self.assertEqual(row["term_source"], "authored")
        self.assertEqual([d["name"] for d in row["records"]], ["guard_track_slice_one"])
        self.assertEqual(row["terms"]["exclude"], ["inv8"])

    def test_the_page_states_that_the_exclude_was_not_carried(self):
        docs = [doc("guard_track_inv8_thing", ["2026-08-02"])]
        mapping = {"items": {"itm_1": {"include": ["no_such_term"], "exclude": ["inv8"]}}}
        rows = rep.build_rows(scan, mapping,
                              store_of(item(title="guard_track_inv8_thing を直す")), docs, NOW)
        self.assertIn("自動照合には適用しません", rep.render_terms(rows[0]))


class TheMappingsShapeIsNotTrusted(unittest.TestCase):
    def test_a_string_include_does_not_become_single_character_terms(self):
        self.assertEqual(rep.term_list("pm_store"), [])
        self.assertEqual(rep.term_list(["a", 3, None, "b", ""]), ["a", "b"])
        self.assertEqual(rep.term_list(None), [])

    def test_a_string_include_does_not_reach_the_page_as_authored(self):
        docs = [doc(f"unrelated_{n}", ["2026-08-01"]) for n in range(30)]
        rows = rep.build_rows(scan, {"items": {"itm_1": {"include": "unrelated"}}},
                              store_of(item(title="日本語のみ")), docs, NOW)
        self.assertNotEqual(rows[0]["term_source"], "authored")
        self.assertEqual(rows[0]["records"], [])

    def test_a_mapping_with_no_items_key_still_builds_rows(self):
        rows = rep.build_rows(scan, {"version": 1}, store_of(item()),
                              [doc("some_named_ctx", ["2026-08-10"])], NOW)
        self.assertEqual(len(rows), 1)

    def test_a_non_object_mapping_items_value_still_builds_rows(self):
        rows = rep.build_rows(scan, {"items": "oops"}, store_of(item()),
                              [doc("some_named_ctx", ["2026-08-10"])], NOW)
        self.assertEqual(len(rows), 1)


class FiveReasonsAreWordedApart(unittest.TestCase):
    """Which side is broken is the whole content of this line. Collapsing any two
    of these produced a false statement twice."""

    def _row(self, docs, mapping, **item_kw):
        return rep.build_rows(scan, mapping, store_of(item(**item_kw)), docs, NOW)[0]

    def test_an_unreadable_memo_marker_blames_the_memo(self):
        row = self._row([doc("named_ctx_alpha", ["2026-08-07"])],
                        {"items": {"itm_1": {"include": ["named_ctx_alpha"]}}},
                        touched_at=None)
        self.assertEqual(row["last_activity"], "2026-08-07")
        self.assertTrue(row["latest_parses"])
        self.assertFalse(row["marker_parses"])
        self.assertIn("直すのは memo の側", rep.unmatched_reason(row))

    def test_an_unreadable_l2_date_blames_l2(self):
        row = self._row([doc("named_ctx_beta", ["2026-02-30"])],
                        {"items": {"itm_1": {"include": ["named_ctx_beta"]}}})
        self.assertEqual(row["store_touched"], "2026-08-01")
        self.assertTrue(row["marker_parses"])
        self.assertFalse(row["latest_parses"])
        reason = rep.unmatched_reason(row)
        self.assertIn("直すのは L2 の側", reason)
        self.assertNotIn("memo 側の最終接触", reason)

    def test_undated_records_are_reported_as_such(self):
        row = self._row([doc("named_ctx_gamma", [])],
                        {"items": {"itm_1": {"include": ["named_ctx_gamma"]}}})
        self.assertIn("どれも日付を持たない", rep.unmatched_reason(row))

    def test_no_terms_is_reported_as_such(self):
        row = self._row([doc("unrelated_ctx", ["2026-08-01"])], {"items": {}},
                        title="日本語のみ", notes=None)
        self.assertEqual(row["term_source"], "none")
        self.assertIn("照合語が 1 つも作れない", rep.unmatched_reason(row))

    def test_the_five_counters_do_not_overlap(self):
        """Item 5 is broken on BOTH sides. It must be counted once, under L2, since
        that is the side the reason names -- otherwise the memo tile absorbs rows
        whose memo is not the problem."""
        docs = [doc("ctx_marker_bad", ["2026-08-07"]), doc("ctx_l2_bad", ["2026-02-30"]),
                doc("ctx_undated", []), doc("ctx_ok", ["2026-08-10"]),
                doc("ctx_both_bad", ["2026-02-30"])]
        mapping = {"items": {
            "itm_1": {"include": ["ctx_marker_bad"]}, "itm_2": {"include": ["ctx_l2_bad"]},
            "itm_3": {"include": ["ctx_undated"]}, "itm_4": {"include": ["ctx_ok"]},
            "itm_5": {"include": ["ctx_both_bad"]}}}
        store = store_of(item(1, touched_at=None), item(2), item(3), item(4),
                         item(5, touched_at=None), item(6, title="日本語のみ"))
        rows = rep.build_rows(scan, mapping, store, docs, NOW)
        s = rep.summary(rows)
        self.assertEqual(
            (s["matched"], s["no_marker"], s["bad_l2_date"], s["no_terms"], s["items"]),
            (1, 1, 2, 1, 6))
        both = next(r for r in rows if r["id"] == "itm_5")
        self.assertIn("直すのは L2 の側", rep.unmatched_reason(both))

    def test_a_non_object_item_value_is_skipped_rather_than_read(self):
        rows = rep.build_rows(scan, {"items": {}},
                              {"projects": {}, "items": {"itm_1": "junk", "itm_2": item(2)}},
                              [doc("x_y_z_w", ["2026-08-10"])], NOW)
        self.assertEqual([r["id"] for r in rows], ["itm_2"])


class AggregationIsComputedOverEveryRow(unittest.TestCase):
    """Every case in the previous suite built one row, so counting all rows as
    matched, taking the median over all deltas, and reversing the order were green."""

    def _rows(self):
        docs = [doc("ctx_lag_big", ["2026-08-15"]), doc("ctx_lag_small", ["2026-08-03"]),
                doc("ctx_in_step", ["2026-08-01"]), doc("ctx_memo_ahead", ["2026-07-01"]),
                doc("ctx_none_marker", ["2026-08-07"])]
        mapping = {"items": {f"itm_{n}": {"include": [t]} for n, t in enumerate(
            ["ctx_lag_big", "ctx_lag_small", "ctx_in_step", "ctx_memo_ahead",
             "ctx_none_marker"], start=1)}}
        store = store_of(item(1), item(2), item(3), item(4), item(5, touched_at=None))
        return rep.build_rows(scan, mapping, store, docs, NOW)

    def test_the_counters_split_lagging_in_step_and_memo_ahead(self):
        s = rep.summary(self._rows())
        self.assertEqual((s["items"], s["matched"], s["l2_newer"], s["in_step"],
                          s["memo_newer"], s["no_marker"]), (5, 4, 2, 1, 1, 1))

    def test_the_median_is_taken_over_lagging_items_only(self):
        """Lags are 14 and 2, so the median over lagging items is 8. The median over
        all four deltas would be 1, which is smaller than either lagging item."""
        s = rep.summary(self._rows())
        self.assertEqual((s["median_lag"], s["max_lag"]), (8, 14))

    def test_the_table_is_ordered_by_lag_descending(self):
        page = rep.render({"rows": self._rows(), "docs": 5, "undated": 0,
                           "mapping_version": 1, "store_path": "/x/store.json"},
                          datetime.datetime(2026, 8, 17, 12, 0, 0))
        # Split on the headings, not the labels: the same words appear on the tiles.
        body = page.split("<h2>差を出せた項目")[1].split("<h2>差を出せなかった項目")[0]
        self.assertLess(body.index("+14日"), body.index("+2日"))
        self.assertLess(body.index("+2日"), body.index("+0日"))

    def test_an_in_step_item_stays_in_the_comparison_table(self):
        rows = self._rows()
        in_step = next(r for r in rows if r.get("touch_delta_days") == 0)
        self.assertIsNotNone(in_step["touch_delta_days"])
        page = rep.render({"rows": rows, "docs": 5, "undated": 0, "mapping_version": 1,
                           "store_path": "/x/store.json"},
                          datetime.datetime(2026, 8, 17, 12, 0, 0))
        after = page.split("差を出せなかった項目")[1]
        self.assertNotIn(in_step["title"], after)


class TheRenderedPageIsSafe(unittest.TestCase):
    def _page(self, rows):
        return rep.render({"rows": rows, "docs": 1, "undated": 0, "mapping_version": 1,
                           "store_path": "/x/store.json"},
                          datetime.datetime(2026, 8, 17, 12, 0, 0))

    def test_markup_is_escaped_in_the_comparison_table(self):
        docs = [doc("named_ctx_alpha", ["2026-08-10"], status='</span><b>PWNED</b>')]
        rows = rep.build_rows(scan, {"items": {"itm_1": {"include": ["named_ctx_alpha"]}}},
                              store_of(item(title='</td></tr><script>alert(1)</script>')),
                              docs, NOW)
        page = self._page(rows)
        self.assertNotIn("<script>alert(1)</script>", page)
        self.assertNotIn("<b>PWNED</b>", page)
        self.assertIn("&lt;script&gt;", page)

    def test_markup_is_escaped_in_the_no_comparison_table_too(self):
        rows = rep.build_rows(scan, {"items": {}},
                              store_of(item(title='<script>alert("unmatched")</script>')),
                              [doc("unrelated_ctx", ["2026-08-01"])], NOW)
        self.assertIsNone(rows[0].get("touch_delta_days"))
        page = self._page(rows)
        self.assertNotIn('<script>alert("unmatched")</script>', page)
        self.assertIn("&lt;script&gt;", page)

    def test_a_records_own_status_appears_only_inside_a_details_block(self):
        docs = [doc("named_ctx_alpha", ["2026-08-10"], status="FROZEN")]
        rows = rep.build_rows(scan, {"items": {"itm_1": {"include": ["named_ctx_alpha"]}}},
                              store_of(item()), docs, NOW)
        page = self._page(rows)
        self.assertIn("FROZEN", page)
        stripped = re.sub(r"<details>.*?</details>", "", page, flags=re.S)
        self.assertNotIn("FROZEN", stripped)

    def test_terms_are_shown_as_text_even_when_nothing_matched(self):
        rows = rep.build_rows(scan, {"items": {}},
                              store_of(item(title="日本語のみ")),
                              [doc("unrelated_ctx", ["2026-08-01"])], NOW)
        page = self._page(rows)
        self.assertIn("照合語", page)
        self.assertNotIn("[&#x27;", page)

    def test_one_absurd_lag_renders_without_error_and_flattens_the_rest(self):
        """Accepted behaviour, not a fixed defect. A context declaring 9999-12-31
        parses, so its lag dwarfs the others and their bars go to zero width. The
        bars are relative to the widest lag, which is what they say they are; the
        wrong number is in L2, and the row still shows its own +N日 figure. Recorded
        as accepted rather than given a scaling rule, which would be arbitrary."""
        docs = [doc("ctx_far", ["9999-12-31"]), doc("ctx_near", ["2026-08-15"])]
        mapping = {"items": {"itm_1": {"include": ["ctx_far"]},
                             "itm_2": {"include": ["ctx_near"]}}}
        rows = rep.build_rows(scan, mapping, store_of(item(1), item(2)), docs, NOW)
        page = self._page(rows)
        widths = [int(w) for w in re.findall(r'class="bar" style="width:(\d+)%', page)]
        self.assertEqual(widths, [100, 0])
        self.assertIn("+14日", page)   # the figure itself is still readable


class RunningTheProgramLeavesNothingBehind(unittest.TestCase):
    def test_a_run_writes_no_bytecode_inside_the_skillset(self):
        with tempfile.TemporaryDirectory() as tmp:
            inst = Instance(tmp)
            inst.pm(store_of(item()), {"version": 1, "items": {}})
            env = dict(os.environ)
            env.pop("PYTHONDONTWRITEBYTECODE", None)   # the guard, not the environment
            r = subprocess.run([sys.executable, os.path.join(inst.scripts, "pm_l2_report.py"),
                                "--quiet"], capture_output=True, text=True, env=env)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            left = [p for _, ds, fs in os.walk(inst.scripts)
                    for p in list(fs) + list(ds) if p.endswith(".pyc") or p == "__pycache__"]
            self.assertEqual(left, [], f"bytecode left inside the SkillSet: {left}")


class AbsencesAreReportedNotRaised(unittest.TestCase):
    def test_a_fresh_instance_names_the_missing_file_and_exits_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = Instance(tmp).run("--quiet")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("store.json", r.stdout)
            self.assertIn("見つかりません", r.stdout)

    def test_a_malformed_memo_names_the_file_and_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as tmp:
            inst = Instance(tmp)
            inst.pm("{ not json", {"version": 1, "items": {}})
            r = inst.run("--quiet")
            self.assertEqual(r.returncode, 1)
            self.assertIn("store.json", r.stdout)
            self.assertIn("読めません", r.stdout)
            self.assertNotIn("Traceback", r.stdout + r.stderr)

    def test_a_store_that_is_not_an_object_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            inst = Instance(tmp)
            inst.pm("[1, 2, 3]", {"version": 1, "items": {}})
            r = inst.run("--quiet")
            self.assertEqual(r.returncode, 1)
            self.assertIn("object ではありません", r.stdout)

    def test_an_empty_store_says_so_and_exits_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            inst = Instance(tmp)
            inst.pm({"projects": {}, "items": {}}, {"version": 1, "items": {}})
            r = inst.run("--quiet")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("項目がまだありません", r.stdout)

    def test_a_missing_mapping_really_falls_back_to_inference(self):
        """The previous version of this case asserted a substring that the
        mapping-absent notice prints regardless, so it passed with inference
        switched off entirely. It now asserts the inferred record count."""
        with tempfile.TemporaryDirectory() as tmp:
            inst = Instance(tmp)
            inst.pm(store_of(item(title="some_named_ctx の続き")))
            inst.context("some_named_ctx", "---\nname: some_named_ctx\ndate: 2026-08-10\n---\nb\n")
            r = inst.run()   # not --quiet: the count is on the second line
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("自動照合 1", r.stdout)
            with open(inst.out_path, encoding="utf-8") as fh:
                page = fh.read()
            self.assertIn("some_named_ctx", page)
            self.assertIn("1 件の近傍記録", page)

    def test_an_absent_derivation_is_reported_not_raised(self):
        with tempfile.TemporaryDirectory() as tmp:
            inst = Instance(tmp)
            inst.pm(store_of(item()), {"version": 1, "items": {}})
            os.remove(os.path.join(inst.scripts, "l2_scan.py"))
            r = inst.run("--quiet")
            self.assertEqual(r.returncode, 1)
            self.assertIn("l2_scan.py", r.stdout)
            self.assertNotIn("Traceback", r.stderr)

    def test_a_broken_derivation_is_reported_not_raised(self):
        with tempfile.TemporaryDirectory() as tmp:
            inst = Instance(tmp)
            inst.pm(store_of(item()), {"version": 1, "items": {}})
            with open(os.path.join(inst.scripts, "l2_scan.py"), "w", encoding="utf-8") as fh:
                fh.write("this is not python(\n")
            r = inst.run("--quiet")
            self.assertEqual(r.returncode, 1)
            self.assertIn("l2_scan.py", r.stdout)
            self.assertNotIn("Traceback", r.stderr)


class TheOutputLinesAreAContract(unittest.TestCase):
    """Emptying a diagnostic and changing an exit code to 137 were both green."""

    def _run(self, *args):
        tmp = tempfile.mkdtemp()
        inst = Instance(tmp)
        inst.pm(store_of(item(title="named_ctx_alpha の件")), {"version": 1, "items": {}})
        inst.context("named_ctx_alpha", "---\nname: named_ctx_alpha\ndate: 2026-08-10\n---\nb\n")
        return inst, inst.run(*args)

    def test_quiet_prints_two_lines_and_names_the_output(self):
        inst, r = self._run("--quiet")
        lines = [l for l in r.stdout.splitlines() if l.strip()]
        self.assertEqual(len(lines), 2, r.stdout)
        self.assertIn("項目のうち", lines[0])
        self.assertIn(inst.out_path, lines[1])

    def test_the_default_prints_three_lines_with_the_five_causes(self):
        inst, r = self._run()
        lines = [l for l in r.stdout.splitlines() if l.strip()]
        self.assertEqual(len(lines), 3, r.stdout)
        for label in ("自動照合", "語が広すぎ", "L2 の日付が読めない",
                      "memo の最終接触が読めない", "照合語が作れない"):
            self.assertIn(label, lines[1])


class TheSuiteRunsAnywhere(unittest.TestCase):
    """It ships inside the gem, so it must pass with no instance present at all."""

    def test_the_module_under_test_does_not_read_the_live_store_at_import(self):
        self.assertTrue(callable(rep.build_rows))
        self.assertTrue(rep.OUT_PATH.endswith(os.path.join("log", "pm_l2_report.html")))


if __name__ == "__main__":
    unittest.main(verbosity=1)
