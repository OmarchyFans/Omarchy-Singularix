"""S1: the store. One SQLite file, two layers (design §5).

Leaves are verbatim, scrubbed, append-only and permanent: a leaf id is written once and never
changed. Sessions hold per-session metadata the sources keep updating (title, time range,
files touched). Nodes and unit_leaves are the derived index the Shaper rebuilds; their ids are
content keys, so a rebuild keeps every id that still means the same thing.
"""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import time
import zlib
from contextlib import contextmanager

from .scrub import clean

DEFAULT_DIR = os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")), "omarchy-memstore")
SCHEMA_VERSION = 1

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS cursors(source TEXT PRIMARY KEY, cursor TEXT, updated REAL);
CREATE TABLE IF NOT EXISTS sessions(
  id TEXT PRIMARY KEY, source TEXT, agent TEXT, model TEXT, title TEXT, first_user TEXT,
  ts_min REAL, ts_max REAL, cwd TEXT, branch TEXT, worktree TEXT, section TEXT,
  n_leaves INTEGER DEFAULT 0, files TEXT DEFAULT '{}', dirty INTEGER DEFAULT 1);
CREATE TABLE IF NOT EXISTS leaves(
  id TEXT PRIMARY KEY, session TEXT NOT NULL, ord REAL NOT NULL, ts REAL, role TEXT,
  body BLOB NOT NULL, chars INTEGER, tokens INTEGER, files TEXT, hash TEXT, added REAL);
CREATE INDEX IF NOT EXISTS leaves_session ON leaves(session, ord);
CREATE VIRTUAL TABLE IF NOT EXISTS leaves_fts USING fts5(id UNINDEXED, text, tokenize='porter unicode61');
CREATE TABLE IF NOT EXISTS nodes(
  id TEXT PRIMARY KEY, parent TEXT, kind TEXT, section TEXT, title TEXT, preview TEXT,
  key_items TEXT, tokens INTEGER, ts_min REAL, ts_max REAL, sessions TEXT, ord INTEGER, run INTEGER);
CREATE INDEX IF NOT EXISTS nodes_parent ON nodes(parent, ord);
CREATE TABLE IF NOT EXISTS unit_leaves(unit TEXT, leaf TEXT, PRIMARY KEY(unit, leaf));
CREATE INDEX IF NOT EXISTS unit_leaves_leaf ON unit_leaves(leaf);
CREATE TABLE IF NOT EXISTS shape_runs(
  id INTEGER PRIMARY KEY, started REAL, finished REAL, nodes INTEGER, units INTEGER,
  duplicate_views INTEGER, status TEXT, note TEXT);
CREATE TABLE IF NOT EXISTS handoffs(id TEXT PRIMARY KEY, agent TEXT, created REAL, consumed REAL);
CREATE INDEX IF NOT EXISTS handoffs_agent ON handoffs(agent, consumed);
"""


def tokens_of(text: str) -> int:
    return max(1, len(text) // 4)


class Store:
    def __init__(self, path: str | None = None):
        d = os.path.dirname(path) if path else DEFAULT_DIR
        os.makedirs(d, mode=0o700, exist_ok=True)
        os.chmod(d, 0o700)
        self.path = path or os.path.join(DEFAULT_DIR, "memstore.db")
        old = os.umask(0o077)
        try:
            self.db = sqlite3.connect(self.path, timeout=30)
        finally:
            os.umask(old)
        os.chmod(self.path, 0o600)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.db.executescript(SCHEMA)
        self.db.execute("INSERT OR IGNORE INTO meta VALUES('schema', ?)", (str(SCHEMA_VERSION),))
        self.db.commit()
        self.added = 0

    # ------------------------------------------------------------ writes

    @contextmanager
    def batch(self):
        """One transaction per batch: a crash mid-batch leaves no partial rows."""
        try:
            yield self
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise

    def add_leaf(self, lid: str, session: str, ord_: float, ts: float | None, role: str, text: str,
                 files: list[str] | None = None) -> bool:
        """Append one leaf. Scrubbed before it is written. Returns False if it already exists."""
        body = clean(text)
        h = hashlib.sha256(body.encode()).hexdigest()[:16]
        cur = self.db.execute(
            "INSERT OR IGNORE INTO leaves(id, session, ord, ts, role, body, chars, tokens, files, hash, added) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (lid, session, ord_, ts, role, zlib.compress(body.encode(), 6), len(body), tokens_of(body),
             json.dumps(sorted(set(files or []))), h, time.time()))
        if cur.rowcount:
            self.db.execute("INSERT INTO leaves_fts(id, text) VALUES(?,?)", (lid, body))
            self.db.execute("UPDATE sessions SET dirty=1 WHERE id=?", (session,))
            self.added += 1
            return True
        return False

    def upsert_session(self, s: dict) -> None:
        """Session metadata is not history: it is overwritten as sources learn more. Scrubbed too."""
        s = dict(s)
        for k in ("title", "first_user", "cwd", "branch", "worktree"):
            if s.get(k):
                s[k] = clean(str(s[k]))
        self.db.execute(
            "INSERT INTO sessions(id, source, agent, model, title, first_user, ts_min, ts_max, cwd, branch, "
            "worktree, section, files, dirty) VALUES(:id,:source,:agent,:model,:title,:first_user,:ts_min,"
            ":ts_max,:cwd,:branch,:worktree,:section,:files,1) ON CONFLICT(id) DO UPDATE SET "
            "model=coalesce(excluded.model, model), title=coalesce(excluded.title, title), "
            "first_user=coalesce(first_user, excluded.first_user), "
            "ts_min=min(coalesce(ts_min, excluded.ts_min), coalesce(excluded.ts_min, ts_min)), "
            "ts_max=max(coalesce(ts_max, excluded.ts_max), coalesce(excluded.ts_max, ts_max)), "
            "cwd=coalesce(cwd, excluded.cwd), branch=coalesce(excluded.branch, branch), "
            "worktree=coalesce(worktree, excluded.worktree), "
            "files=CASE WHEN excluded.files='{}' THEN files ELSE excluded.files END, dirty=1",
            {k: s.get(k) for k in ("id", "source", "agent", "model", "title", "first_user", "ts_min", "ts_max",
                                   "cwd", "branch", "worktree", "section")} | {
                "files": json.dumps(s.get("files") or {})})

    def merge_files(self, session: str, counts: dict) -> None:
        row = self.db.execute("SELECT files FROM sessions WHERE id=?", (session,)).fetchone()
        cur = json.loads(row[0]) if row and row[0] else {}
        for k, v in counts.items():
            cur[k] = cur.get(k, 0) + v
        top = dict(sorted(cur.items(), key=lambda kv: -kv[1])[:80])
        self.db.execute("UPDATE sessions SET files=? WHERE id=?", (json.dumps(top), session))

    def refresh_counts(self) -> None:
        self.db.execute("UPDATE sessions SET n_leaves=(SELECT count(*) FROM leaves WHERE leaves.session=sessions.id) "
                        "WHERE dirty=1")

    # -------------------------------------------------------- N5: handoffs
    def add_handoff(self, agent: str, session_id: str, ts: float | None = None) -> None:
        """Record a new pending handoff for an agent (design section 10 / storage
        conventions). A later write for the same agent just adds a newer row;
        pending_handoff always returns the newest unconsumed one."""
        self.db.execute("INSERT OR REPLACE INTO handoffs(id, agent, created, consumed) VALUES(?,?,?,NULL)",
                        (session_id, agent, ts if ts is not None else time.time()))

    def pending_handoff(self, agent: str) -> dict | None:
        """-> {'session', 'created', 'text'} for the newest unconsumed handoff, or None."""
        row = self.db.execute("SELECT id, created FROM handoffs WHERE agent=? AND consumed IS NULL "
                              "ORDER BY created DESC LIMIT 1", (agent,)).fetchone()
        if not row:
            return None
        sid, created = row
        text = "\n".join(lf["text"] for lf in self.leaves_of(sid))
        return {"session": sid, "created": created, "text": text}

    def consume_handoff(self, agent: str) -> bool:
        cur = self.db.execute("UPDATE handoffs SET consumed=? WHERE agent=? AND consumed IS NULL",
                              (time.time(), agent))
        return bool(cur.rowcount)

    def cursor(self, source: str, default=None):
        row = self.db.execute("SELECT cursor FROM cursors WHERE source=?", (source,)).fetchone()
        return json.loads(row[0]) if row else default

    def set_cursor(self, source: str, value) -> None:
        self.db.execute("INSERT OR REPLACE INTO cursors VALUES(?,?,?)", (source, json.dumps(value), time.time()))

    # ------------------------------------------------------------ reads

    def leaf_text(self, lid: str) -> str | None:
        row = self.db.execute("SELECT body FROM leaves WHERE id=?", (lid,)).fetchone()
        return zlib.decompress(row[0]).decode() if row else None

    def leaves_of(self, session: str):
        for lid, ord_, ts, role, body, tokens, files in self.db.execute(
                "SELECT id, ord, ts, role, body, tokens, files FROM leaves WHERE session=? ORDER BY ord, id",
                (session,)):
            yield {"id": lid, "ord": ord_, "ts": ts, "role": role, "text": zlib.decompress(body).decode(),
                   "tokens": tokens, "files": json.loads(files or "[]")}

    def node(self, nid: str) -> dict | None:
        row = self.db.execute("SELECT id, parent, kind, section, title, preview, key_items, tokens, ts_min, ts_max, "
                              "sessions FROM nodes WHERE id=?", (nid,)).fetchone()
        if not row:
            return None
        keys = ("id", "parent", "kind", "section", "title", "preview", "key_items", "tokens", "ts_min", "ts_max",
                "sessions")
        n = dict(zip(keys, row))
        n["key_items"] = json.loads(n["key_items"] or "[]")
        n["sessions"] = json.loads(n["sessions"] or "[]")
        return n

    def children(self, nid: str) -> list[dict]:
        ids = [r[0] for r in self.db.execute("SELECT id FROM nodes WHERE parent=? ORDER BY ord", (nid,))]
        return [self.node(i) for i in ids]

    def unit_of(self, leaf_id: str) -> str | None:
        row = self.db.execute("SELECT unit FROM unit_leaves WHERE leaf=?", (leaf_id,)).fetchone()
        return row[0] if row else None

    def unit_leaves(self, unit_id: str) -> list[str]:
        return [r[0] for r in self.db.execute(
            "SELECT ul.leaf FROM unit_leaves ul JOIN leaves l ON l.id=ul.leaf WHERE ul.unit=? ORDER BY l.ord, l.id",
            (unit_id,))]

    def bm25(self, query_terms: list[str], k: int = 16) -> list[tuple[str, float]]:
        if not query_terms:
            return []
        q = " OR ".join('"' + t.replace('"', "") + '"' for t in query_terms)
        return self.db.execute("SELECT id, bm25(leaves_fts) FROM leaves_fts WHERE leaves_fts MATCH ? "
                               "ORDER BY 2 LIMIT ?", (q, k)).fetchall()

    def stats(self) -> dict:
        one = lambda q: self.db.execute(q).fetchone()[0]  # noqa: E731
        by_source = dict(self.db.execute("SELECT source, count(*) FROM sessions GROUP BY source").fetchall())
        run = self.db.execute("SELECT id, finished, nodes, units, status, note FROM shape_runs "
                              "ORDER BY id DESC LIMIT 1").fetchone()
        cursors = dict(self.db.execute("SELECT source, updated FROM cursors").fetchall())
        return {"path": self.path, "sessions": by_source, "leaves": one("SELECT count(*) FROM leaves"),
                "tokens": one("SELECT coalesce(sum(tokens),0) FROM leaves"),
                "nodes": one("SELECT count(*) FROM nodes"),
                "last_shape": dict(zip(("id", "finished", "nodes", "units", "status", "note"), run)) if run else None,
                "last_ingest": max(cursors.values()) if cursors else None,
                "bytes": os.path.getsize(self.path)}
