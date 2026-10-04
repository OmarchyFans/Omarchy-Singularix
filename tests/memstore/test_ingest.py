"""S2-S4: ingesters against fixtures (no real history is read)."""

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib"))
from memstore import ingest  # noqa: E402
from memstore.store import Store  # noqa: E402

GH = "ghp_" + "a1B2c3D4" * 4 + "e5F6"
VCS = "g" + "it"


def rec(**kw):
    return json.dumps(kw) + "\n"


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.t = self.tmp.name
        self.s = Store(os.path.join(self.t, "ms", "memstore.db"))

    def tearDown(self):
        self.s.db.close()
        self.tmp.cleanup()

    def count(self, q, *a):
        return self.s.db.execute(q, a).fetchone()[0]


class ClaudeTest(Base):
    def write(self):
        root = os.path.join(self.t, "projects")
        sd = os.path.join(root, "-home-x-Work", "S1", "subagents")
        os.makedirs(sd)
        main = os.path.join(root, "-home-x-Work", "S1.jsonl")
        with open(main, "w") as f:
            f.write(rec(type="ai-title", aiTitle="fix the bar", sessionId="S1"))
            f.write(rec(type="user", sessionId="S1", timestamp="2026-10-01T10:00:00Z", cwd="/home/x/Work/repo",
                        message={"content": "please fix waybar, key " + GH}))
            f.write(rec(type="assistant", sessionId="S1", timestamp="2026-10-01T10:00:05Z",
                        message={"model": "claude-opus-5-5", "content": [
                            {"type": "text", "text": "Looking."},
                            {"type": "tool_use", "name": "Edit", "input": {"file_path": "/home/x/.config/waybar/config.jsonc"}}]}))
            f.write('{"type":"user","sessionId":"S1","timest')  # partial line still being written
        with open(os.path.join(sd, "agent-abc.jsonl"), "w") as f:
            f.write(rec(type="user", sessionId="S1", isSidechain=True, timestamp="2026-10-01T10:01:00Z",
                        message={"content": "subtask: check css"}))
        return root, main

    def test_ingest_incremental(self):
        root, main = self.write()
        n1 = ingest.ingest_claude(self.s, roots=[root])
        self.assertEqual(n1, 3)
        self.assertEqual(ingest.ingest_claude(self.s, roots=[root]), 0)
        with open(main, "a") as f:
            f.write('amp":"2026-10-01T10:02:00Z","message":{"content":"thanks"}}\n')
        self.assertEqual(ingest.ingest_claude(self.s, roots=[root]), 1)
        title, first, model, files = self.s.db.execute(
            "select title, first_user, model, files from sessions where id='claude:S1'").fetchone()
        self.assertEqual(title, "fix the bar")
        self.assertIn("waybar", first)
        self.assertNotIn(GH, first)
        self.assertEqual(model, "claude-opus-5-5")
        self.assertIn("/home/x/.config/waybar/config.jsonc", json.loads(files))
        roles = [r[0] for r in self.s.db.execute("select role from leaves order by ord")]
        self.assertEqual(roles, ["user", "assistant", "subagent_task", "user"])
        for (body,) in self.s.db.execute("select text from leaves_fts"):
            self.assertNotIn(GH, body)


class HermesTest(Base):
    def make_home(self):
        home = os.path.join(self.t, "agents", "rix", "hermes")
        os.makedirs(home)
        c = sqlite3.connect(os.path.join(home, "state.db"))
        c.executescript("""create table sessions(id text primary key, model text, title text, cwd text,
            git_branch text, started_at real);
            create table messages(id integer primary key autoincrement, session_id text, role text,
            content text, tool_calls text, timestamp real);""")
        c.execute("insert into sessions values('s1','gpt-5.6-terra','What happened','/home/x/Work/a',null,100)")
        c.execute("insert into messages(session_id, role, content, tool_calls, timestamp) values('s1','user','what happened to the memstore',null,101)")
        c.execute("insert into messages(session_id, role, content, tool_calls, timestamp) values('s1','assistant','',?,102)",
                  (json.dumps([{"function": {"name": "terminal", "arguments": json.dumps({"command": "ls ~/.local/share"})}}]),))
        c.commit()
        return home, c

    def test_cursor_and_compaction(self):
        home, c = self.make_home()
        homes = [("rix", home)]
        self.assertEqual(ingest.ingest_hermes(self.s, homes=homes), 2)
        self.assertEqual(ingest.ingest_hermes(self.s, homes=homes), 0)
        c.execute("delete from messages")  # Hermes compaction deletes the originals ...
        c.execute("insert into messages(session_id, role, content, tool_calls, timestamp) values('s1','assistant','[summary]',null,103)")
        c.commit()
        self.assertEqual(ingest.ingest_hermes(self.s, homes=homes), 1)
        # ... but the store kept every original turn
        self.assertEqual(self.count("select count(*) from leaves where session='hermes:rix:s1'"), 3)
        self.assertEqual(self.count("select count(*) from leaves where role='assistant' and session='hermes:rix:s1'"), 2)
        row = self.s.db.execute("select section, model, title from sessions").fetchone()
        self.assertEqual(row, ("agent/rix", "gpt-5.6-terra", "What happened"))


class MachineTest(Base):
    def test_commits(self):
        repo = os.path.join(self.t, "Work", "demo")
        os.makedirs(repo)
        g = [VCS, "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run([VCS, "-C", repo, "init", "-q"], check=True)
        open(os.path.join(repo, "a.txt"), "w").write("x")
        subprocess.run(g + ["add", "."], check=True)
        subprocess.run(g + ["commit", "-q", "-m", "pin images by digest"], check=True)
        self.assertEqual(ingest.ingest_commits(self.s, repos=[repo]), 1)
        self.assertEqual(ingest.ingest_commits(self.s, repos=[repo]), 0)
        sid, title, section = self.s.db.execute("select id, title, section from sessions").fetchone()
        self.assertTrue(sid.startswith("git:demo:"))
        self.assertEqual((title, section), ("pin images by digest", "project/demo"))

    def test_pacman(self):
        log = os.path.join(self.t, "pacman.log")
        with open(log, "w") as f:
            f.write("[2026-10-01T10:00:00-0500] [ALPM] transaction started\n"
                    "[2026-10-01T10:00:01-0500] [ALPM] upgraded nvidia-utils (610.1-1 -> 610.57.04-1)\n"
                    "[2026-10-01T10:00:02-0500] [ALPM] transaction completed\n")
        self.assertEqual(ingest.ingest_pacman(self.s, log=log), 1)
        self.assertEqual(ingest.ingest_pacman(self.s, log=log), 0)
        self.assertIn("nvidia-utils", self.s.leaf_text(self.s.db.execute("select id from leaves").fetchone()[0]))

    def test_config_snapshot(self):
        cfg = os.path.join(self.t, "config")
        os.makedirs(os.path.join(cfg, "hypr"))
        os.makedirs(os.path.join(cfg, "omarchy-agent-launcher"))
        open(os.path.join(cfg, "hypr", "bindings.conf"), "w").write("bind = SUPER, A, exec, x\n")
        open(os.path.join(cfg, "hypr", "secrets.env"), "w").write("TOKEN=" + GH + "\n")
        open(os.path.join(cfg, "hypr", "env.conf"), "w").write("env = GH_TOKEN," + GH + "\n")
        state = os.path.join(self.t, "state")
        self.assertEqual(ingest.ingest_config(self.s, state, allow=("hypr",), config_root=cfg), 1)  # baseline
        self.assertEqual(ingest.ingest_config(self.s, state, allow=("hypr",), config_root=cfg), 0)
        open(os.path.join(cfg, "hypr", "bindings.conf"), "a").write("bind = SUPER, B, exec, y\n")
        self.assertEqual(ingest.ingest_config(self.s, state, allow=("hypr",), config_root=cfg), 1)
        text = self.s.leaf_text(self.s.db.execute("select id from leaves order by added desc limit 1").fetchone()[0])
        self.assertIn("hypr/bindings.conf +1/-0", text)
        mirror = os.path.join(state, "config-mirror")
        self.assertFalse(os.path.exists(os.path.join(mirror, "hypr", "secrets.env")))
        self.assertNotIn(GH, open(os.path.join(mirror, "hypr", "env.conf")).read())


if __name__ == "__main__":
    unittest.main()
