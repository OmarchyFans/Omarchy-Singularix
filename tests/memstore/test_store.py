"""S1 + S5: store and scrub."""

import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib"))
from memstore.scrub import clean, excluded  # noqa: E402
from memstore.store import Store  # noqa: E402

# Fake credentials assembled at runtime so this file never contains a real-looking key.
FAKE = {
    "anthropic": "sk-ant-api03-" + "Q" * 93 + "AA",
    "openai": "sk-proj-" + "x1Y2" * 12,
    "github": "ghp_" + "a1B2c3D4" * 4 + "e5F6",
    "aws": "AKIA" + "IOSFODNN7EXAMPLE",
    "private key": "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----",
    "url password": "postgres://admin:hunter2pass@db.example.com/x",
}


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "ms", "memstore.db")
        self.s = Store(self.path)

    def tearDown(self):
        self.s.db.close()
        self.tmp.cleanup()

    def add_batch(self):
        with self.s.batch():
            self.s.upsert_session({"id": "claude:s1", "source": "claude", "agent": "claude-code", "ts_min": 1.0,
                                   "ts_max": 2.0, "section": "claude"})
            n = 0
            for i in range(5):
                n += self.s.add_leaf(f"claude:s1:m:{i}", "claude:s1", float(i), 1.0 + i, "user", f"turn {i} text")
        return n

    def test_modes(self):
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.path)).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)

    def test_reingest_is_a_noop(self):
        self.assertEqual(self.add_batch(), 5)
        self.assertEqual(self.add_batch(), 0)
        self.assertEqual(self.s.db.execute("select count(*) from leaves").fetchone()[0], 5)
        self.assertEqual(self.s.db.execute("select count(*) from leaves_fts").fetchone()[0], 5)

    def test_leaves_are_append_only(self):
        self.add_batch()
        with self.s.batch():
            self.assertFalse(self.s.add_leaf("claude:s1:m:0", "claude:s1", 0.0, 1.0, "user", "rewritten"))
        self.assertEqual(self.s.leaf_text("claude:s1:m:0"), "turn 0 text")

    def test_batch_rolls_back(self):
        with self.assertRaises(RuntimeError):
            with self.s.batch():
                self.s.add_leaf("x:1", "x", 0.0, 0.0, "user", "a")
                raise RuntimeError("crash mid-batch")
        self.assertIsNone(self.s.leaf_text("x:1"))

    def test_session_metadata_merges(self):
        self.add_batch()
        with self.s.batch():
            self.s.upsert_session({"id": "claude:s1", "source": "claude", "agent": "claude-code", "title": "T",
                                   "ts_min": 0.5, "ts_max": 9.0})
        row = self.s.db.execute("select title, ts_min, ts_max from sessions where id='claude:s1'").fetchone()
        self.assertEqual(row, ("T", 0.5, 9.0))

    def test_cursor_roundtrip(self):
        with self.s.batch():
            self.s.set_cursor("claude:/x.jsonl", {"offset": 42})
        self.assertEqual(self.s.cursor("claude:/x.jsonl"), {"offset": 42})

    def test_bm25(self):
        self.add_batch()
        hits = self.s.bm25(["turn", "3"])
        self.assertTrue(hits)


class ScrubTest(unittest.TestCase):
    def test_fake_key_corpus_never_stored(self):
        tmp = tempfile.TemporaryDirectory()
        s = Store(os.path.join(tmp.name, "memstore.db"))
        with s.batch():
            for i, (kind, value) in enumerate(FAKE.items()):
                s.add_leaf(f"t:{i}", "t", float(i), 0.0, "tool", f"here is the {kind}: {value} end")
        s.db.commit()
        raw = open(s.path, "rb").read()
        for p in (s.path + "-wal",):
            if os.path.exists(p):
                raw += open(p, "rb").read()
        for kind, value in FAKE.items():
            secret = value.split("@")[0].split(":")[-1] if kind == "url password" else value
            self.assertNotIn(secret.encode(), raw, kind)
            for i in range(len(FAKE)):
                self.assertNotIn(secret, s.leaf_text(f"t:{i}"), kind)
        s.db.close()
        tmp.cleanup()

    def test_idempotent(self):
        once = clean("token " + FAKE["github"])
        self.assertEqual(clean(once), once)

    def test_exclusions(self):
        for p in ("~/.config/omarchy-agent-launcher/secrets.env", "/x/hermes/auth.json", "~/.ssh/id_ed25519",
                  "~/.config/gh/hosts.yml", "/a/b/.env.local"):
            self.assertTrue(excluded(p), p)
        for p in ("~/.config/hypr/bindings.conf", "~/.config/waybar/config.jsonc"):
            self.assertFalse(excluded(p), p)


if __name__ == "__main__":
    unittest.main()
