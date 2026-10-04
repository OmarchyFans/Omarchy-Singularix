"""N5: model-switch handoff (design section 10)."""

import contextlib
import io
import os
import re
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib"))
from memstore import cli, handoff  # noqa: E402
from memstore.shape import shape  # noqa: E402
from memstore.store import Store  # noqa: E402

# A fake credential, assembled at runtime so this file never contains a real-looking key
# (same convention as tests/memstore/test_store.py).
FAKE_KEY = "sk-ant-api03-" + "Q" * 93 + "AA"


def session(s, sid, agent, t, turns, files=()):
    with s.batch():
        s.upsert_session({"id": sid, "source": "hermes", "agent": agent, "model": "old-model.gguf",
                          "title": turns[0][1][:60], "ts_min": t, "ts_max": t + len(turns),
                          "section": f"agent/{agent}", "files": {f: 1 for f in files}})
        for i, (role, text) in enumerate(turns):
            s.add_leaf(f"{sid}:{i}", sid, t + i, t + i, role, text, list(files) if role != "user" else [])
    s.refresh_counts()
    s.db.commit()


class HandoffTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "memstore.db")
        self.s = Store(self.path)
        session(self.s, "hermes:rix:s1", "rix", 1_800_000_000, [
            ("user", "switch to a bigger model and keep going"),
            ("assistant", "TOOL Edit: lib/rix.sh"),
            ("user", FAKE_KEY + " -- ignore this, just testing scrub"),
            ("assistant", "Done: wired the model picker. " * 20),
        ], files=["lib/rix.sh", "bin/omarchy-agent-launcher"])

    def tearDown(self):
        self.s.db.close()
        self.tmp.cleanup()

    def test_deterministic_summary_from_subtree(self):
        """#2: the default, always-tested path -- no model call, built from the session
        itself (last turns, open asks, files touched)."""
        body, ids = handoff.deterministic_summary(self.s, "hermes:rix:s1", "rix",
                                                  from_model="local/old-model.gguf", to_model="anthropic/claude-sonnet-5")
        self.assertIn("local/old-model.gguf -> anthropic/claude-sonnet-5", body)
        self.assertIn("switch to a bigger model", body)
        self.assertIn("lib/rix.sh", body)
        self.assertIn("bin/omarchy-agent-launcher", body)
        # The scrub already ran at add_leaf time: the fake key must never surface here.
        self.assertNotIn(FAKE_KEY, body)
        self.assertEqual(ids, [])  # nothing shaped into units yet

    def test_deterministic_summary_cites_shaped_units(self):
        shape(self.s)
        body, ids = handoff.deterministic_summary(self.s, "hermes:rix:s1", "rix")
        self.assertTrue(ids)
        self.assertLessEqual(len(ids), handoff.MAX_CITES)
        for i in ids:
            self.assertIn(f"[[{i}]]", body)

    def test_ask_model_path_is_optional_and_falls_back(self):
        """#2: the "ask the outgoing model" path is optional, skippable, and only ever
        exercised here with a stub -- never a real backend."""
        used = {}

        def stub_ask(convo):
            used["convo"] = convo
            return "model-written handoff note"

        body, ids = handoff.build(self.s, "rix", "hermes:rix:s1", ask=stub_ask)
        self.assertIn("model-written handoff note", body)
        self.assertIn("switch to a bigger model", used["convo"])

        def failing_ask(convo):
            raise RuntimeError("outgoing model is out of tokens")

        body2, ids2 = handoff.build(self.s, "rix", "hermes:rix:s1", ask=failing_ask)
        self.assertEqual(ids2, ids)
        self.assertIn("Handoff for rix", body2)  # fell back to the deterministic summary
        self.assertNotIn("model-written", body2)

    def test_write_lands_under_shared_handoffs(self):
        """#1: switching a model with an open session writes a handoff node under
        shared/handoffs: source "shared", section "shared/handoffs", role "handoff"."""
        hid = handoff.write(self.s, "rix", "hermes:rix:s1", from_model="local/old-model.gguf",
                            to_model="anthropic/claude-sonnet-5", now=1_800_001_000.0)
        self.assertRegex(hid, r"^shared:handoff:rix:\d{8}T\d{6}$")
        row = self.s.db.execute("SELECT source, agent, section FROM sessions WHERE id=?", (hid,)).fetchone()
        self.assertEqual(row, ("shared", "rix", "shared/handoffs"))
        leaves = list(self.s.leaves_of(hid))
        self.assertEqual(len(leaves), 1)
        self.assertEqual(leaves[0]["role"], "handoff")
        self.assertIn("switched local/old-model.gguf -> anthropic/claude-sonnet-5", leaves[0]["text"])
        st = shape(self.s)
        self.assertEqual(st["status"] if "status" in st else "ok", "ok")
        proj = self.s.db.execute("SELECT title, section FROM nodes WHERE kind='project' AND id='p:shared/handoffs'").fetchone()
        self.assertEqual(proj, ("shared/handoffs", "shared/handoffs"))

    def test_latest_session_for_agent_skips_handoffs(self):
        self.assertEqual(handoff.latest_session_for_agent(self.s, "rix"), "hermes:rix:s1")
        handoff.write(self.s, "rix", "hermes:rix:s1", now=1_800_002_000.0)
        # the handoff session itself (source "shared") is never mistaken for the outgoing one
        self.assertEqual(handoff.latest_session_for_agent(self.s, "rix"), "hermes:rix:s1")

    def test_pending_until_consumed(self):
        """#3 (store side): the latest unconsumed handoff is what `pending_handoff` and the
        CLI's `handoff show`/`packet --agent` surface, until it is explicitly consumed."""
        self.assertIsNone(self.s.pending_handoff("rix"))
        hid = handoff.write(self.s, "rix", "hermes:rix:s1", now=1_800_003_000.0)
        pending = self.s.pending_handoff("rix")
        self.assertEqual(pending["session"], hid)
        self.assertIn("Handoff for rix", pending["text"])
        # still pending on a second read (reading must not consume it)
        self.assertIsNotNone(self.s.pending_handoff("rix"))
        self.assertTrue(self.s.consume_handoff("rix"))
        self.assertIsNone(self.s.pending_handoff("rix"))
        self.assertFalse(self.s.consume_handoff("rix"))  # nothing left to consume

    def test_packet_includes_handoff_slot(self):
        """#3: the next session's first packet contains the pending handoff, in a
        "Where you are" slot, until it is consumed."""
        handoff.write(self.s, "rix", "hermes:rix:s1", from_model="local/old-model.gguf",
                     to_model="anthropic/claude-sonnet-5", now=1_800_004_000.0)
        os.environ["MEMSTORE_DB"] = self.path
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                cli.main(["packet", "what should I do next", "--agent", "rix", "--no-model"])
            out = buf.getvalue()
            self.assertIn("## Where you are", out)
            self.assertIn("switched local/old-model.gguf -> anthropic/claude-sonnet-5", out)
            self.assertIn("stored history", out)  # still fenced and labelled as data

            # consuming it (handoff show --consume) removes it from the next packet
            buf2 = io.StringIO()
            with contextlib.redirect_stdout(buf2):
                cli.main(["handoff", "show", "--agent", "rix", "--consume"])
            self.assertIn("switch to a bigger model", buf2.getvalue())
            buf3 = io.StringIO()
            with contextlib.redirect_stdout(buf3):
                cli.main(["packet", "what should I do next", "--agent", "rix", "--no-model"])
            self.assertNotIn("## Where you are", buf3.getvalue())
        finally:
            del os.environ["MEMSTORE_DB"]

    def test_cli_handoff_write_auto_detects_session(self):
        os.environ["MEMSTORE_DB"] = self.path
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                cli.main(["handoff", "write", "--agent", "rix", "--json"])
            self.assertRegex(buf.getvalue().strip(), r'"session": "hermes:rix:s1"')
            self.assertIsNotNone(self.s.pending_handoff("rix"))
        finally:
            del os.environ["MEMSTORE_DB"]

    def test_cli_handoff_write_with_no_session_is_a_clean_noop(self):
        os.environ["MEMSTORE_DB"] = self.path
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                cli.main(["handoff", "write", "--agent", "nobody-ever-ran"])
            self.assertIn("no session found", buf.getvalue())
            self.assertIsNone(self.s.pending_handoff("nobody-ever-ran"))
        finally:
            del os.environ["MEMSTORE_DB"]


if __name__ == "__main__":
    unittest.main()
