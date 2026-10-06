"""Full, uncompacted chat text (0.2.0): kept alongside the short view, scrubbed, backfillable."""

import contextlib
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib"))
from memstore import cli, ingest  # noqa: E402
from memstore.shape import shape  # noqa: E402
from memstore.store import Store  # noqa: E402

GH = "ghp_" + "a1B2c3D4" * 4 + "e5F6"
LONG = "line of build output\n" * 400  # ~8 KB, far over the 1,500-char tool cap


def rec(**kw):
    return json.dumps(kw) + "\n"


class FullTextTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.t = self.tmp.name
        self.path = os.path.join(self.t, "ms", "memstore.db")
        self.s = Store(self.path)
        self.root = os.path.join(self.t, "projects")
        os.makedirs(os.path.join(self.root, "p"))
        self.f = os.path.join(self.root, "p", "S.jsonl")
        with open(self.f, "w") as fh:
            fh.write(rec(type="user", sessionId="S", timestamp="2026-10-05T10:00:00Z", message={"content": "build it"}))
            fh.write(rec(type="assistant", sessionId="S", timestamp="2026-10-05T10:00:01Z", message={"content": [
                {"type": "thinking", "thinking": "I should run make first."}]}))
            fh.write(rec(type="assistant", sessionId="S", timestamp="2026-10-05T10:00:02Z", message={"content": [
                {"type": "tool_use", "name": "Write", "input": {"file_path": "/tmp/x.py", "content": "print(1)\n" * 300}}]}))
            fh.write(rec(type="user", sessionId="S", timestamp="2026-10-05T10:00:03Z", message={"content": [
                {"type": "tool_result", "content": LONG + "token " + GH}]}))

    def tearDown(self):
        self.s.db.close()
        self.tmp.cleanup()

    def leaf(self, role):
        return self.s.db.execute("select id from leaves where role=? order by ord", (role,)).fetchone()[0]

    def test_full_kept_short_view_unchanged(self):
        ingest.ingest_claude(self.s, roots=[self.root])
        tool = self.leaf("tool")
        short, full = self.s.leaf_text(tool), self.s.full_text(tool)
        self.assertLessEqual(len(short), 1500)
        self.assertIn(LONG.strip(), full)
        self.assertNotIn(GH, full)  # scrubbed
        fts = self.s.db.execute("select text from leaves_fts where id=?", (tool,)).fetchone()[0]
        self.assertEqual(fts, short)  # search still indexes the short view only
        write = self.leaf("assistant")
        self.assertIn('"content": "print(1)', self.s.full_text(write))  # full tool input
        self.assertLess(len(self.s.leaf_text(write)), 700)

    def test_thinking_kept_but_not_in_tree(self):
        ingest.ingest_claude(self.s, roots=[self.root])
        th = self.leaf("thinking")
        self.assertIn("run make first", self.s.full_text(th))
        shape(self.s)
        self.assertIsNone(self.s.unit_of(th))
        self.assertIsNotNone(self.s.unit_of(self.leaf("tool")))

    def test_backfill_fills_old_leaves_once(self):
        # a store written by 0.1.0: short view only
        ingest.ingest_claude(self.s, roots=[self.root])
        self.s.db.execute("delete from leaf_full")
        self.s.db.commit()
        self.assertFalse(self.s.has_full(self.leaf("tool")))
        self.s.db.execute("delete from cursors")
        self.s.db.commit()
        ingest._SEEN.clear()
        n_leaves = self.s.db.execute("select count(*) from leaves").fetchone()[0]
        ingest.ingest_claude(self.s, roots=[self.root])
        self.assertTrue(self.s.has_full(self.leaf("tool")))
        self.assertEqual(self.s.db.execute("select count(*) from leaves").fetchone()[0], n_leaves)
        before = self.s.db.execute("select count(*) from leaf_full").fetchone()[0]
        self.s.db.execute("delete from cursors")
        self.s.db.commit()
        ingest._SEEN.clear()
        ingest.ingest_claude(self.s, roots=[self.root])
        self.assertEqual(self.s.db.execute("select count(*) from leaf_full").fetchone()[0], before)

    def test_hermes_reasoning_and_full_args(self):
        home = os.path.join(self.t, "rix", "hermes")
        os.makedirs(home)
        c = sqlite3.connect(os.path.join(home, "state.db"))
        c.executescript("""create table sessions(id text primary key, model text, title text, cwd text, git_branch text, started_at real);
            create table messages(id integer primary key autoincrement, session_id text, role text, content text,
            tool_calls text, timestamp real, reasoning text, reasoning_content text);""")
        c.execute("insert into sessions values('s1','m','t',null,null,1)")
        args = json.dumps({"command": "ls " + "x" * 2000})
        c.execute("insert into messages(session_id, role, content, tool_calls, timestamp, reasoning) values('s1','assistant','ok',?,2,'because')",
                  (json.dumps([{"function": {"name": "terminal", "arguments": args}}]),))
        c.commit()
        ingest.ingest_hermes(self.s, homes=[("rix", home)])
        lid = self.s.db.execute("select id from leaves").fetchone()[0]
        full = self.s.full_text(lid)
        self.assertIn("x" * 2000, full)
        self.assertIn("[thinking]\nbecause", full)
        self.assertLess(len(self.s.leaf_text(lid)), 1000)

    def test_cli_session_and_content_full(self):
        ingest.ingest_claude(self.s, roots=[self.root])
        shape(self.s)
        os.environ["MEMSTORE_DB"] = self.path
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                cli.main(["session", "claude:S", "--full"])
            out = buf.getvalue()
            self.assertIn("turns 1-4 of 4", out)
            self.assertIn("run make first", out)
            self.assertIn(LONG.strip()[:200], out)
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                cli.main(["session", "claude:S", "--limit", "2"])
            self.assertIn("--from 2 --limit 2", buf.getvalue())
            with self.assertRaises(SystemExit):
                cli.main(["session", "claude:nope"])
            with self.assertRaises(SystemExit):
                cli.main(["session", "claude:S", "--sections", "agent/rix"])
            unit = self.s.unit_of(self.leaf("tool"))
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                cli.main(["content", unit, "--full"])
            self.assertIn(LONG.strip()[-200:], buf.getvalue())
        finally:
            del os.environ["MEMSTORE_DB"]


if __name__ == "__main__":
    unittest.main()
