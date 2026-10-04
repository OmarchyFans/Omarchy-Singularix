"""N6: solver loop v0 (design doc Section 9) -- 10 offline Omarchy-edit tasks on synthetic
fixtures, each must end verified or rolled_back, never with a broken config.

Layer 1 (always runs, no GPU): a scripted stub model, including bad candidates (invalid
syntax, a wrong edit, a path-escape attempt).
Layer 2 (skipped unless MEMSTORE_LIVE=1 and the local model is healthy): the same 10 tasks
against the real local Qwen through llama-server.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import shutil
import sys
import tempfile
import tomllib
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib"))
from memstore import solver  # noqa: E402
from memstore.decider import Decider  # noqa: E402
from memstore.solver import (  # noqa: E402
    SolverSafetyError, Step, check_root_safety, parse_candidates, propose_live, safe_path, solve,
)
from memstore.store import Store  # noqa: E402

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures", "solver")


def make_root(base: str, name: str) -> str:
    dst = os.path.join(base, "roots", name)
    shutil.copytree(FIXTURES, dst)
    return dst


def original_bytes(rel: str) -> bytes:
    return (pathlib.Path(FIXTURES) / rel).read_bytes()


# --------------------------------------------------------------------------------- the 10 tasks

def task_add_keybinding() -> Step:
    rx = re.compile(r"^bind\s*=\s*SUPER,\s*G,\s*exec,\s*firefox\s*$", re.M)

    def accept(text):
        return bool(rx.search(text)), "expected a new 'bind = SUPER, G, exec, firefox' line"

    return Step(id="s1", task="add_keybinding", target="hypr/bindings.conf", file_type="hypr",
               description="Add a new keybinding: pressing SUPER+G should launch `firefox` via the "
                           "`exec` dispatcher. Append one new bind line in the same style as the "
                           "existing ones; do not touch the existing bind lines.", acceptance=accept)


def task_change_gaps() -> Step:
    def accept(text):
        ok = bool(re.search(r"gaps_in\s*=\s*8\b", text)) and bool(re.search(r"gaps_out\s*=\s*16\b", text))
        return ok, "expected gaps_in=8 and gaps_out=16"

    return Step(id="s1", task="change_gaps", target="hypr/looknfeel.conf", file_type="hypr",
               description="Change `gaps_in` to 8 and `gaps_out` to 16 inside the `general` block.",
               acceptance=accept)


def task_change_border_size() -> Step:
    def accept(text):
        return bool(re.search(r"border_size\s*=\s*3\b", text)), "expected border_size=3"

    return Step(id="s1", task="change_border_size", target="hypr/looknfeel.conf", file_type="hypr",
               description="Change `border_size` to 3 inside the `general` block.", acceptance=accept)


def task_set_repeat_rate() -> Step:
    def accept(text):
        ok = bool(re.search(r"repeat_rate\s*=\s*40\b", text)) and bool(re.search(r"repeat_delay\s*=\s*300\b", text))
        return ok, "expected repeat_rate=40 and repeat_delay=300"

    return Step(id="s1", task="set_repeat_rate", target="hypr/input.conf", file_type="hypr",
               description="Change `repeat_rate` to 40 and `repeat_delay` to 300 inside the `input` block.",
               acceptance=accept)


def task_add_monitor_rule() -> Step:
    rx = re.compile(r"^monitor\s*=\s*HDMI-A-1,\s*2560x1440,\s*1920x0,\s*1\s*$", re.M)

    def accept(text):
        return bool(rx.search(text)), "expected monitor=HDMI-A-1,2560x1440,1920x0,1"

    return Step(id="s1", task="add_monitor_rule", target="hypr/monitors.conf", file_type="hypr",
               description="Add a monitor rule for a second monitor `HDMI-A-1` at 2560x1440, placed to "
                           "the right of eDP-1 (position 1920x0), scale 1. Append a new `monitor=` "
                           "line; do not change the existing one.", acceptance=accept)


def task_add_waybar_module() -> Step:
    def accept(text):
        try:
            data = json.loads(solver._strip_jsonc(text))
        except json.JSONDecodeError:
            return False, "not valid JSON(C)"
        return "custom/weather" in data.get("modules-right", []), "expected 'custom/weather' in modules-right"

    return Step(id="s1", task="add_waybar_module", target="waybar/config.jsonc", file_type="jsonc",
               description="Add a `custom/weather` module to the front of `modules-right`.", acceptance=accept)


def task_change_waybar_height() -> Step:
    def accept(text):
        try:
            data = json.loads(solver._strip_jsonc(text))
        except json.JSONDecodeError:
            return False, "not valid JSON(C)"
        return data.get("height") == 34, "expected height=34"

    return Step(id="s1", task="change_waybar_height", target="waybar/config.jsonc", file_type="jsonc",
               description="Change waybar's `height` to 34.", acceptance=accept)


def task_change_font_size() -> Step:
    def accept(text):
        try:
            data = tomllib.loads(text)
        except tomllib.TOMLDecodeError:
            return False, "not valid TOML"
        return data.get("font", {}).get("size") == 12.5, "expected font.size=12.5"

    return Step(id="s1", task="change_font_size", target="alacritty/alacritty.toml", file_type="toml",
               description="Change the terminal font size to 12.5.", acceptance=accept)


def task_add_windowrule() -> Step:
    def accept(text):
        ok = "Picture-in-Picture" in text and "windowrule" in text and "float" in text
        return ok, "expected a float windowrule matching title Picture-in-Picture"

    return Step(id="s1", task="add_windowrule", target="hypr/windowrules.conf", file_type="hypr",
               description="Add a windowrule that floats windows titled 'Picture-in-Picture' (regex "
                           "`^(Picture-in-Picture)$`), written on one line as "
                           "`windowrule { float; match { title = <regex> } }`, like the existing rule. "
                           "Do not remove the existing rule.", acceptance=accept)


def task_impossible() -> Step:
    def accept(_text):
        return False, "unreachable by construction: no dispatcher of this name can ever be valid"

    return Step(id="s1", task="impossible_dispatcher", target="hypr/bindings.conf", file_type="hypr",
               description="Add `bind = SUPER, Z, nonexistent_dispatcher_xyz` so SUPER+Z calls a "
                           "dispatcher literally named `nonexistent_dispatcher_xyz`, which does not "
                           "exist in Hyprland. Do not substitute a real dispatcher for it.",
               acceptance=accept)


TASKS = {
    "add_keybinding": task_add_keybinding,
    "change_gaps": task_change_gaps,
    "change_border_size": task_change_border_size,
    "set_repeat_rate": task_set_repeat_rate,
    "add_monitor_rule": task_add_monitor_rule,
    "add_waybar_module": task_add_waybar_module,
    "change_waybar_height": task_change_waybar_height,
    "change_font_size": task_change_font_size,
    "add_windowrule": task_add_windowrule,
    "impossible_dispatcher": task_impossible,
}


# -------------------------------------------------------------------------- the scripted stub

class StubProposer:
    """One scripted raw-text response per round; the last one repeats if asked for more."""

    def __init__(self, rounds: list[str]):
        self.rounds = rounds
        self.i = 0

    def __call__(self, _packet_text: str) -> str:
        r = self.rounds[min(self.i, len(self.rounds) - 1)]
        self.i += 1
        return r


def cands(*candidates: dict) -> str:
    return json.dumps(list(candidates))


# Scripted rounds per task. Each includes at least one deliberately bad candidate somewhere in
# the suite: a path-escape attempt (add_keybinding), invalid syntax (change_gaps round 0), a
# wrong edit (add_keybinding, add_windowrule), and unparsable JSON (covered in test_parse_*).
STUB_ROUNDS: dict[str, list[str]] = {
    "add_keybinding": [cands(
        {"path": "../outside.conf", "edits": [{"op": "append", "text": "bind = SUPER, G, exec, firefox"}]},
        {"path": "hypr/bindings.conf", "edits": [{"op": "append", "text": "bind = SUPER, G, exec, chromium"}]},
        {"path": "hypr/bindings.conf", "edits": [{"op": "append", "text": "bind = SUPER, G, exec, firefox"}]},
    )],
    "change_gaps": [
        cands({"path": "hypr/looknfeel.conf", "edits": [
            {"op": "replace", "find": "}\n", "replace": ""},  # drops the closing brace: invalid syntax
        ]}),
        cands({"path": "hypr/looknfeel.conf", "edits": [
            {"op": "replace", "find": "gaps_in = 5", "replace": "gaps_in = 8"},
            {"op": "replace", "find": "gaps_out = 10", "replace": "gaps_out = 16"},
        ]}),
    ],
    "change_border_size": [cands({"path": "hypr/looknfeel.conf", "edits": [
        {"op": "replace", "find": "border_size = 2", "replace": "border_size = 3"},
    ]})],
    "set_repeat_rate": [cands({"path": "hypr/input.conf", "edits": [
        {"op": "replace", "find": "repeat_rate = 25", "replace": "repeat_rate = 40"},
        {"op": "replace", "find": "repeat_delay = 600", "replace": "repeat_delay = 300"},
    ]})],
    "add_monitor_rule": [cands({"path": "hypr/monitors.conf", "edits": [
        {"op": "append", "text": "monitor=HDMI-A-1,2560x1440,1920x0,1"},
    ]})],
    "add_waybar_module": [cands({"path": "waybar/config.jsonc", "edits": [
        {"op": "replace", "find": '"modules-right": ["pulseaudio", "battery"]',
         "replace": '"modules-right": ["custom/weather", "pulseaudio", "battery"]'},
    ]})],
    "change_waybar_height": [cands({"path": "waybar/config.jsonc", "edits": [
        {"op": "replace", "find": '"height": 30,', "replace": '"height": 34,'},
    ]})],
    "change_font_size": [cands({"path": "alacritty/alacritty.toml", "edits": [
        {"op": "replace", "find": "size = 10.0", "replace": "size = 12.5"},
    ]})],
    "add_windowrule": [cands(
        {"path": "hypr/windowrules.conf", "edits": [{"op": "append",
         "text": "windowrule { float; match { title = ^(Volume Control)$ } }"}]},  # wrong edit
        {"path": "hypr/windowrules.conf", "edits": [{"op": "append",
         "text": "windowrule { float; match { title = ^(Picture-in-Picture)$ } }"}]},
    )],
    "impossible_dispatcher": [cands({"path": "hypr/bindings.conf", "edits": [
        {"op": "append", "text": "bind = SUPER, Z, nonexistent_dispatcher_xyz"},
    ]})] * 3,
}


class SolverCiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(os.path.join(self.tmp.name, "ms", "memstore.db"))

    def tearDown(self):
        self.store.db.close()
        self.tmp.cleanup()

    def test_ten_tasks_end_verified_or_rolled_back(self):
        for name, builder in TASKS.items():
            with self.subTest(task=name):
                root = make_root(self.tmp.name, name)
                step = builder()
                propose = StubProposer(STUB_ROUNDS[name])
                result = solve(self.store, root, [step], propose, task=name)
                status = result[step.id]
                self.assertIn(status, ("verified", "rolled_back"))
                final = pathlib.Path(root) / step.target
                final_text = final.read_text()
                ok, msg = solver.validate_file(step.file_type, final_text)
                self.assertTrue(ok, f"{name}: final file fails its own validator: {msg}")
                if status == "rolled_back":
                    self.assertEqual(final.read_bytes(), original_bytes(step.target),
                                     f"{name}: rolled-back file is not byte-identical to the original")

    def test_impossible_task_always_rolls_back(self):
        root = make_root(self.tmp.name, "impossible")
        step = task_impossible()
        propose = StubProposer(STUB_ROUNDS["impossible_dispatcher"])
        result = solve(self.store, root, [step], propose, task="impossible_dispatcher")
        self.assertEqual(result[step.id], "rolled_back")
        final = pathlib.Path(root) / step.target
        self.assertEqual(final.read_bytes(), original_bytes(step.target))

    def test_bad_candidates_are_rejected_without_being_applied(self):
        """add_keybinding's round 0 has a path-escape attempt and a wrong edit before the good
        one; both must be rejected and never land on disk, and the good one still wins."""
        root = make_root(self.tmp.name, "bad_candidates")
        step = task_add_keybinding()
        propose = StubProposer(STUB_ROUNDS["add_keybinding"])
        result = solve(self.store, root, [step], propose, task="add_keybinding")
        self.assertEqual(result[step.id], "verified")
        final_text = (pathlib.Path(root) / step.target).read_text()
        self.assertIn("exec, firefox", final_text)
        self.assertNotIn("chromium", final_text)
        escape_target = pathlib.Path(root).parent / "outside.conf"
        self.assertFalse(escape_target.exists(), "a path-escape candidate must never be written to disk")

    def test_lessons_are_recorded_for_a_rolled_back_step(self):
        root = make_root(self.tmp.name, "lessons")
        step = task_impossible()
        propose = StubProposer(STUB_ROUNDS["impossible_dispatcher"])
        solve(self.store, root, [step], propose, task="impossible_dispatcher")
        rows = self.store.db.execute(
            "SELECT body FROM leaves WHERE session='shared:lessons'").fetchall()
        self.assertTrue(rows, "no lessons were promoted to shared/lessons")
        lessons_sess = self.store.db.execute(
            "SELECT section FROM sessions WHERE id='shared:lessons'").fetchone()
        self.assertEqual(lessons_sess[0], "shared/lessons")

    def test_verified_step_is_promoted_to_shared_solutions(self):
        root = make_root(self.tmp.name, "solutions")
        step = task_change_border_size()
        propose = StubProposer(STUB_ROUNDS["change_border_size"])
        solve(self.store, root, [step], propose, task="change_border_size")
        rows = self.store.db.execute("SELECT body FROM leaves WHERE session='shared:solutions'").fetchall()
        self.assertTrue(rows, "no solution was promoted to shared/solutions")

    def test_scratch_tree_records_the_run(self):
        root = make_root(self.tmp.name, "scratch")
        step = task_change_gaps()
        propose = StubProposer(STUB_ROUNDS["change_gaps"])
        solve(self.store, root, [step], propose, task="change_gaps")
        sess = self.store.db.execute("SELECT section FROM sessions WHERE id='scratch:change_gaps'").fetchone()
        self.assertEqual(sess[0], "scratch/change_gaps")
        n = self.store.db.execute("SELECT count(*) FROM leaves WHERE session='scratch:change_gaps'").fetchone()[0]
        self.assertGreater(n, 0)

    def test_dependents_are_retracted_when_a_step_dies(self):
        root = make_root(self.tmp.name, "retraction")
        dead_step = task_impossible()
        dependent = Step(id="s2", task="retraction_demo", target="hypr/looknfeel.conf", file_type="hypr",
                         description="Change border_size to 3 (depends on s1).",
                         acceptance=lambda t: (bool(re.search(r"border_size\s*=\s*3\b", t)), "expected border_size=3"),
                         depends_on=["s1"])
        propose = StubProposer(STUB_ROUNDS["impossible_dispatcher"] + STUB_ROUNDS["change_border_size"])
        result = solve(self.store, root, [dead_step, dependent], propose, task="retraction_demo")
        self.assertEqual(result["s1"], "rolled_back")
        self.assertEqual(result["s2"], "retracted")
        # the retracted step's file must never have been touched
        self.assertEqual((pathlib.Path(root) / dependent.target).read_bytes(), original_bytes(dependent.target))

    def test_refuses_to_edit_live_config_without_apply_live(self):
        live = os.path.expanduser("~/.config")
        with self.assertRaises(SolverSafetyError):
            check_root_safety(live, apply_live=False)
        check_root_safety(live, apply_live=True)  # does not raise; no filesystem access happens here


class ParseCandidatesTest(unittest.TestCase):
    def test_plain_json_list(self):
        raw = json.dumps([{"edits": [{"op": "append", "text": "x"}]}])
        self.assertEqual(len(parse_candidates(raw)), 1)

    def test_fenced_json(self):
        raw = "Here you go:\n```json\n" + json.dumps([{"edits": [{"op": "append", "text": "x"}]}]) + "\n```\nthanks"
        self.assertEqual(len(parse_candidates(raw)), 1)

    def test_prose_around_brackets(self):
        raw = "sure! " + json.dumps([{"edits": [{"op": "append", "text": "x"}]}]) + " hope that helps"
        self.assertEqual(len(parse_candidates(raw)), 1)

    def test_garbage_parses_to_nothing(self):
        self.assertEqual(parse_candidates("not json at all, sorry"), [])
        self.assertEqual(parse_candidates(""), [])

    def test_non_list_top_level_is_rejected(self):
        self.assertEqual(parse_candidates(json.dumps({"edits": [{"op": "append", "text": "x"}]})), [])

    def test_entries_without_edits_are_dropped(self):
        raw = json.dumps([{"nope": True}, {"edits": []}, {"edits": [{"op": "append", "text": "x"}]}])
        self.assertEqual(len(parse_candidates(raw)), 1)

    def test_truncated_to_max_candidates(self):
        raw = json.dumps([{"edits": [{"op": "append", "text": str(i)}]} for i in range(10)])
        self.assertEqual(len(parse_candidates(raw)), solver.MAX_CANDIDATES)


class ValidatorTest(unittest.TestCase):
    def test_structural_hypr_accepts_the_fixtures(self):
        for rel in ("hypr/bindings.conf", "hypr/looknfeel.conf", "hypr/input.conf",
                   "hypr/monitors.conf", "hypr/windowrules.conf"):
            ok, msg = solver._structural_hypr(original_bytes(rel).decode())
            self.assertTrue(ok, f"{rel}: {msg}")

    def test_structural_hypr_rejects_bad_dispatcher(self):
        ok, _ = solver._structural_hypr("bind = SUPER, Z, nonexistent_dispatcher_xyz\n")
        self.assertFalse(ok)

    def test_structural_hypr_rejects_unbalanced_braces(self):
        ok, _ = solver._structural_hypr("general {\n    gaps_in = 5\n")
        self.assertFalse(ok)

    def test_structural_hypr_rejects_short_monitor_line(self):
        ok, _ = solver._structural_hypr("monitor=eDP-1,1920x1080\n")
        self.assertFalse(ok)

    def test_structural_hypr_rejects_short_bind_line(self):
        ok, _ = solver._structural_hypr("bind = SUPERQ\n")
        self.assertFalse(ok)

    def test_structural_hypr_accepts_oneline_windowrule_block(self):
        ok, msg = solver._structural_hypr("windowrule { float; match { title = ^(x)$ } }\n")
        self.assertTrue(ok, msg)

    def test_structural_hypr_rejects_garbage_line(self):
        ok, _ = solver._structural_hypr("this is not hyprland syntax at all\n")
        self.assertFalse(ok)

    def test_falls_back_to_structural_when_hyprland_missing(self):
        import unittest.mock as mock
        with mock.patch("memstore.solver._hyprland_binary", return_value=None):
            ok, msg = solver.validate_hypr(original_bytes("hypr/bindings.conf").decode())
        self.assertTrue(ok)
        self.assertIn("structural", msg)

    def test_validate_jsonc(self):
        ok, _ = solver.validate_jsonc(original_bytes("waybar/config.jsonc").decode())
        self.assertTrue(ok)
        ok, _ = solver.validate_jsonc("{not json")
        self.assertFalse(ok)

    def test_validate_toml(self):
        ok, _ = solver.validate_toml(original_bytes("alacritty/alacritty.toml").decode())
        self.assertTrue(ok)
        ok, _ = solver.validate_toml("[font\nsize = 1")
        self.assertFalse(ok)


class SafePathTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = make_root(self.tmp.name, "safety")

    def tearDown(self):
        self.tmp.cleanup()

    def test_refuses_relative_escape(self):
        with self.assertRaises(SolverSafetyError):
            safe_path(self.root, "../../etc/passwd")

    def test_refuses_absolute_escape(self):
        with self.assertRaises(SolverSafetyError):
            safe_path(self.root, "/etc/passwd")

    def test_refuses_symlink_escape(self):
        outside = os.path.join(self.tmp.name, "outside.conf")
        with open(outside, "w") as fh:
            fh.write("monitor=eDP-1,1920x1080,0x0,1\n")
        link = os.path.join(self.root, "sneaky.conf")
        os.symlink(outside, link)
        with self.assertRaises(SolverSafetyError):
            safe_path(self.root, "sneaky.conf")

    def test_refuses_excluded_path(self):
        with open(os.path.join(self.root, "secrets.env"), "w") as fh:
            fh.write("X=1\n")
        with self.assertRaises(SolverSafetyError):
            safe_path(self.root, "secrets.env")

    def test_accepts_a_real_path_inside_the_root(self):
        p = safe_path(self.root, "hypr/bindings.conf")
        self.assertTrue(p.exists())


# ------------------------------------------------------------------------------------- live layer

LIVE = os.environ.get("MEMSTORE_LIVE") == "1"


@unittest.skipUnless(LIVE, "set MEMSTORE_LIVE=1 (and have a healthy llama-server) to run this")
class SolverLiveTest(unittest.TestCase):
    def setUp(self):
        self.decider = Decider()
        health = self.decider.health()
        if not health["ok"]:
            self.skipTest(f"local model not healthy: {health['reason']}")
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(os.path.join(self.tmp.name, "ms", "memstore.db"))

    def tearDown(self):
        self.store.db.close()
        self.tmp.cleanup()

    def test_ten_tasks_live(self):
        counts = {"verified": 0, "rolled_back": 0}
        lines = []
        propose = propose_live(self.decider)
        for name, builder in TASKS.items():
            root = make_root(self.tmp.name, name)
            step = builder()
            result = solve(self.store, root, [step], propose, task=name)
            status = result[step.id]
            self.assertIn(status, ("verified", "rolled_back"))
            final = pathlib.Path(root) / step.target
            if status == "rolled_back":
                self.assertEqual(final.read_bytes(), original_bytes(step.target),
                                 f"{name}: rolled-back file is not byte-identical to the original")
            else:
                ok, msg = solver.validate_file(step.file_type, final.read_text())
                self.assertTrue(ok, f"{name}: verified file fails its own validator: {msg}")
            counts[status] += 1
            lines.append(f"  {name}: {status}")
        print("\nLIVE SOLVER RESULTS (verified={verified}, rolled_back={rolled_back}):".format(**counts))
        print("\n".join(lines))


if __name__ == "__main__":
    unittest.main()
