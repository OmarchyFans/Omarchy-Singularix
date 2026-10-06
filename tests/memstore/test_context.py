"""0.2.0: per-turn context hook and the recent branch (searchable before the next full shape)."""

import contextlib
import io
import json
import os
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib"))
sys.path.insert(0, os.path.dirname(__file__))
from memstore import cli, context, ingest  # noqa: E402
from memstore.navigator import navigate  # noqa: E402
from memstore.shape import fresh, shape  # noqa: E402
from test_retrieval import StubDecider, fixture  # noqa: E402


class ContextTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "memstore.db")
        self.s = fixture(self.path)
        shape(self.s)
        self.state = mock.patch.object(context, "STATE_DIR", os.path.join(self.tmp.name, "state"))
        self.state.start()

    def tearDown(self):
        self.state.stop()
        self.s.db.close()
        self.tmp.cleanup()

    def test_offers_relevant_context_once_per_session(self):
        out = context.ambient(self.s, "where did we fix the duplicate waybar button?", "rix", "S1", decider=StubDecider())
        self.assertTrue(out["context"].startswith(context.START))
        self.assertTrue(out["context"].endswith(context.END))
        self.assertTrue(out["ids"])
        for i in out["ids"]:
            self.assertIn(f"[[{i}]]", out["context"])
        self.assertLessEqual(len(out["ids"]), context.MAX_UNITS)
        again = context.ambient(self.s, "where did we fix the duplicate waybar button?", "rix", "S1", decider=StubDecider())
        self.assertFalse(set(again["ids"]) & set(out["ids"]))  # never repeats a unit within a session
        third = context.ambient(self.s, "where did we fix the duplicate waybar button?", "rix", "S1", decider=StubDecider())
        self.assertFalse(set(third["ids"]) & (set(out["ids"]) | set(again["ids"])))
        other = context.ambient(self.s, "where did we fix the duplicate waybar button?", "rix", "S2", decider=StubDecider())
        self.assertTrue(other["context"])  # a new session gets it again

    def test_stays_quiet(self):
        self.assertEqual(context.ambient(self.s, "ok go", "rix", "S", decider=StubDecider())["context"], "")
        down = context.ambient(self.s, "where did we fix the waybar duplicate", "rix", "S", decider=StubDecider(ok=False))
        self.assertEqual(down["context"], "")
        self.assertIn("keyword only", down["why"])
        weak = context.ambient(self.s, "keyboard backlight default on", "rix", "S", decider=StubDecider(word="zzz"))
        self.assertEqual(weak["context"], "")

    def test_hook_protocol_and_fail_open(self):
        payload = {"hook_event_name": "pre_llm_call", "session_id": "S9",
                   "extra": {"user_message": "where did we fix the duplicate waybar button?", "is_first_turn": True}}
        with mock.patch.dict(os.environ, {"MEMSTORE_DB": self.path}), \
                mock.patch.object(context, "navigate", lambda *a, **k: navigate(self.s, a[1], k=6, decider=StubDecider())):
            for stdin, expect_ctx in ((json.dumps(payload), True), ("not json", False), ("{}", False)):
                buf = io.StringIO()
                with mock.patch("sys.stdin", io.StringIO(stdin)), contextlib.redirect_stdout(buf):
                    self.assertEqual(cli.main(["context-hook", "--agent", "rix"]), 0)
                reply = json.loads(buf.getvalue())
                self.assertEqual("context" in reply, expect_ctx, stdin[:20])

    def test_injected_block_is_not_recorded(self):
        home = os.path.join(self.tmp.name, "rix", "hermes")
        os.makedirs(home)
        c = sqlite3.connect(os.path.join(home, "state.db"))
        c.executescript("""create table sessions(id text primary key, model text, title text, cwd text, git_branch text, started_at real);
            create table messages(id integer primary key autoincrement, session_id text, role text, content text,
            tool_calls text, timestamp real);""")
        c.execute("insert into sessions values('s9','m','t',null,null,1)")
        c.execute("insert into messages(session_id, role, content, timestamp) values('s9','user',?,2)",
                  (f"what changed?\n{context.START}\nBackground ... [[x:u0]]\n{context.END}",))
        c.commit()
        ingest.ingest_hermes(self.s, homes=[("rix", home)])
        lid = self.s.db.execute("select id from leaves where session='hermes:rix:s9'").fetchone()[0]
        self.assertEqual(self.s.leaf_text(lid), "what changed?")
        self.assertNotIn("memstore-context", self.s.full_text(lid))

    def test_rix_config_hook(self):
        cfg = os.path.join(self.tmp.name, "config.yaml")
        open(cfg, "w").write("model:\n  default: x\nhooks_auto_accept: true\n")
        self.assertIn("enabled", cli.rix_hook(cfg, True))
        cli.rix_hook(cfg, True)  # idempotent
        text = open(cfg).read()
        self.assertEqual(text.count("pre_llm_call:"), 1)
        self.assertIn("context-hook --agent rix", text)
        self.assertIn("hooks_auto_accept: true", text)
        cli.rix_hook(cfg, False)
        self.assertEqual(open(cfg).read(), "model:\n  default: x\nhooks_auto_accept: true\n")
        open(cfg, "a").write("hooks:\n  post_tool_call: []\n")
        self.assertIn("by hand", cli.rix_hook(cfg, True))  # never edits someone else's hooks block


class RecentBranchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.s = fixture(os.path.join(self.tmp.name, "memstore.db"))
        shape(self.s)

    def tearDown(self):
        self.s.db.close()
        self.tmp.cleanup()

    def test_new_message_is_searchable_before_reshape(self):
        t = time.time()
        with self.s.batch():
            self.s.upsert_session({"id": "claude:NEW", "source": "claude", "agent": "claude-code", "title": "gpu",
                                   "ts_min": t, "ts_max": t, "section": "claude"})
            self.s.add_leaf("claude:NEW:0", "claude:NEW", t, t, "user", "the nvidia driver vanished after supergfxctl")
        self.assertIsNone(self.s.unit_of("claude:NEW:0"))
        st = fresh(self.s)
        self.assertEqual(st["recent_sessions"], 1)
        unit = self.s.unit_of("claude:NEW:0")
        self.assertTrue(unit.startswith("recent:claude:NEW"))
        self.assertEqual(self.s.node("recent")["parent"], "root")
        nav = navigate(self.s, "nvidia driver supergfxctl", decider=StubDecider(word="nvidia"))
        self.assertEqual(nav["units"][0]["id"], unit)
        fresh(self.s)  # idempotent: rebuilt, not duplicated
        self.assertEqual(self.s.db.execute("select count(*) from nodes where id='recent'").fetchone()[0], 1)
        shape(self.s)  # the full shape folds it into the main tree
        self.assertFalse(self.s.unit_of("claude:NEW:0").startswith("recent:"))
        self.assertIsNone(self.s.node("recent"))
        self.assertEqual(fresh(self.s)["recent_sessions"], 0)


if __name__ == "__main__":
    unittest.main()
