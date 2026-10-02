#!/usr/bin/env python3
"""N0 spike, step 1: ingest 14 days of history into a private scratch DB.

Sources: Claude Code transcripts (subagent files attach to their parent session), Hermes
state.db sessions in every agent home, and commits in every ~/Work repo. Every text is scrubbed
with the session harness's secrets.redact() before it is written. No model is called.

Throwaway prototype for design docs/design-pageindex-memstore.md section 14.1, not the Scribe.
"""

import glob
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from collections import Counter
from datetime import datetime

sys.path.insert(0, os.path.expanduser("~/Work/session-harness"))
from harness.secrets import redact  # noqa: E402

HOME = os.path.expanduser("~")
OUT = os.environ.get("N0_DIR", os.path.join(HOME, ".local/share/omarchy-memstore/spike-n0"))
SINCE = datetime.fromisoformat(os.environ.get("N0_SINCE", "2026-09-18")).timestamp()
CAP = {"user": 6000, "assistant": 4000, "tool_use": 600, "tool": 1500, "commit": 2000}
PATH_RE = re.compile(r"(?:/home/modpunk|~)/[\w.@%+=:,/-]+")


def scrub(text):
    return redact(text)[0] if text else ""


def tok(text):
    return max(1, len(text) // 4)


def files_in(*texts):
    out = []
    for t in texts:
        for m in PATH_RE.findall(t or ""):
            out.append(m.replace("~/", HOME + "/", 1).rstrip(".,:;)'\""))
    return out


def iso(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


class DB:
    def __init__(self, path):
        self.c = sqlite3.connect(path)
        self.c.executescript("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, source TEXT, agent TEXT, model TEXT,
          title TEXT, first_user TEXT, ts_min REAL, ts_max REAL, cwd TEXT, branch TEXT, worktree TEXT,
          n_leaves INT, files TEXT);
        CREATE TABLE IF NOT EXISTS leaves(id TEXT PRIMARY KEY, session TEXT, seq INT, ts REAL,
          role TEXT, text TEXT, tokens INT, files TEXT);
        """)
        self.n_scrubbed = 0

    def session(self, s):
        self.c.execute("INSERT OR REPLACE INTO sessions VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", (
            s["id"], s["source"], s["agent"], s.get("model"), s.get("title"), s.get("first_user"),
            s["ts_min"], s["ts_max"], s.get("cwd"), s.get("branch"), s.get("worktree"),
            s["n"], json.dumps(s["files"])))

    def leaf(self, lid, sess, seq, ts, role, text, files):
        text = text[: CAP.get(role, 2000)]
        clean = scrub(text)
        if clean != text:
            self.n_scrubbed += 1
        self.c.execute("INSERT OR REPLACE INTO leaves VALUES(?,?,?,?,?,?,?,?)",
                       (lid, sess, seq, ts, role, clean, tok(clean), json.dumps(sorted(set(files)))))


def worktree_of(cwd):
    m = re.search(r"/\.claude/worktrees/([^/]+)", cwd or "")
    return m.group(1) if m else None


def ingest_claude(db):
    roots = [os.path.join(HOME, ".claude/projects")] + glob.glob(
        os.path.join(HOME, ".config/claude-profiles/profiles/*/projects"))
    files = []
    for r in roots:
        files += [f for f in glob.glob(os.path.join(r, "**/*.jsonl"), recursive=True)
                  if os.path.getmtime(f) >= SINCE]
    sessions = {}
    for f in sorted(files):
        sub = "/subagents/" in f
        try:
            fh = open(f, encoding="utf-8", errors="replace")
        except OSError:
            continue
        for ln, line in enumerate(fh):
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            sid = r.get("sessionId")
            if not sid:
                continue
            s = sessions.setdefault(sid, {"id": "claude:" + sid, "source": "claude", "agent": "claude-code",
                                          "ts_min": None, "ts_max": None, "n": 0, "files": Counter(),
                                          "seq": 0, "title": None, "first_user": None, "cwd": None,
                                          "branch": None, "worktree": None, "model": None})
            t = r.get("type")
            if t == "ai-title" and r.get("aiTitle"):
                s["title"] = r["aiTitle"]
                continue
            if t not in ("user", "assistant"):
                continue
            ts = iso(r.get("timestamp", "")) or 0
            if ts and ts < SINCE:
                continue
            cwd = r.get("cwd")
            if cwd and not sub and not s["cwd"]:
                s["cwd"] = cwd
            if r.get("gitBranch") and r["gitBranch"] != "HEAD":
                s["branch"] = r["gitBranch"]
            wt = worktree_of(cwd)
            if wt and not s["worktree"]:
                s["worktree"] = wt
            content = (r.get("message") or {}).get("content")
            role, parts, touched = None, [], []
            if t == "user":
                if isinstance(content, str):
                    role, parts = "user", [content]
                elif isinstance(content, list):
                    for b in content:
                        if b.get("type") == "text":
                            role = role or "user"
                            parts.append(b.get("text", ""))
                        elif b.get("type") == "tool_result":
                            role = role or "tool"
                            c = b.get("content")
                            if isinstance(c, list):
                                c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
                            parts.append(("ERROR " if b.get("is_error") else "") + str(c or "")[: CAP["tool"]])
                if role == "user" and sub:
                    role = "subagent_task"
            else:
                s["model"] = s["model"] or (r.get("message") or {}).get("model")
                role = "assistant"
                for b in content or []:
                    bt = b.get("type")
                    if bt == "text":
                        parts.append(b.get("text", ""))
                    elif bt == "tool_use":
                        inp = b.get("input") or {}
                        p = inp.get("file_path") or inp.get("path") or inp.get("notebook_path")
                        if p:
                            touched.append(p)
                        arg = inp.get("command") or p or json.dumps(inp)[:300]
                        parts.append(f"TOOL {b.get('name')}: {str(arg)[:CAP['tool_use']]}")
            text = "\n".join(x for x in parts if x).strip()
            if not text or not role:
                continue
            if role == "user" and not s["first_user"] and not text.startswith("<"):
                s["first_user"] = text[:200]
            touched += files_in(text if role != "tool" else "")
            for p in touched:
                s["files"][p] += 1
            s["seq"] += 1
            s["n"] += 1
            s["ts_min"] = min(filter(None, [s["ts_min"], ts])) if ts else s["ts_min"]
            s["ts_max"] = max(filter(None, [s["ts_max"], ts])) if ts else s["ts_max"]
            db.leaf(f"{s['id']}:{'sub' if sub else 'm'}:{os.path.basename(f)[:12]}:{ln}", s["id"], s["seq"],
                    ts, role, text, touched)
    kept = 0
    for s in sessions.values():
        if s["n"] == 0 or not s["ts_min"]:
            continue
        s["files"] = dict(s["files"].most_common(60))
        db.session(s)
        kept += 1
    return kept


def ingest_hermes(db):
    homes = [os.path.join(HOME, ".hermes")] + glob.glob(
        os.path.join(HOME, ".local/share/omarchy-agent-launcher/agents/*/hermes"))
    kept = 0
    for h in homes:
        path = os.path.join(h, "state.db")
        if not os.path.exists(path):
            continue
        agent = "hermes" if h.endswith("/.hermes") else h.split("/agents/")[1].split("/")[0]
        c = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        for sid, model, title, cwd, branch, started in c.execute(
                "select id, model, title, cwd, git_branch, started_at from sessions where started_at>=?", (SINCE,)):
            s = {"id": f"hermes:{agent}:{sid}", "source": "hermes", "agent": agent, "model": model,
                 "title": title, "first_user": None, "ts_min": None, "ts_max": None, "cwd": cwd,
                 "branch": branch, "worktree": worktree_of(cwd), "n": 0, "files": Counter()}
            for mid, role, content, calls, ts in c.execute(
                    "select id, role, content, tool_calls, timestamp from messages where session_id=? order by id", (sid,)):
                parts, touched = [content or ""], []
                if calls:
                    try:
                        for tc in json.loads(calls):
                            fn = tc.get("function") or {}
                            args = fn.get("arguments") or ""
                            try:
                                a = json.loads(args)
                            except (json.JSONDecodeError, TypeError):
                                a = {}
                            p = a.get("path") or a.get("file_path") if isinstance(a, dict) else None
                            if p:
                                touched.append(p)
                            arg = (a.get("command") if isinstance(a, dict) else None) or p or args[:300]
                            parts.append(f"TOOL {fn.get('name')}: {str(arg)[:CAP['tool_use']]}")
                    except (json.JSONDecodeError, TypeError):
                        pass
                text = "\n".join(x for x in parts if x).strip()
                if not text:
                    continue
                r = "tool" if role == "tool" else role
                if r == "user" and not s["first_user"]:
                    s["first_user"] = text[:200]
                touched += files_in(text if r != "tool" else "")
                for p in touched:
                    s["files"][p] += 1
                s["n"] += 1
                s["ts_min"] = min(filter(None, [s["ts_min"], ts]))
                s["ts_max"] = max(filter(None, [s["ts_max"], ts]))
                db.leaf(f"{s['id']}:{mid}", s["id"], s["n"], ts, r, text, touched)
            if s["n"]:
                s["files"] = dict(s["files"].most_common(60))
                db.session(s)
                kept += 1
        c.close()
    return kept


def ingest_git(db):
    kept = 0
    for d in sorted(glob.glob(os.path.join(HOME, "Work/*/"))):
        if not os.path.isdir(os.path.join(d, ".git")):
            continue
        repo = os.path.basename(d.rstrip("/"))
        out = subprocess.run(["git", "-C", d, "log", "--all", f"--since=@{int(SINCE)}", "--name-only",
                              "--format=%x1e%H%x1f%ct%x1f%s%x1f%b%x1f"], capture_output=True, text=True).stdout
        for rec in out.split("\x1e")[1:]:
            head, _, names = rec.rpartition("\x1f")
            sha, ct, subj, body = (head.split("\x1f") + ["", "", "", ""])[:4]
            files = [os.path.join(d, n) for n in names.split("\n") if n.strip()]
            ts = float(ct)
            sid = f"git:{repo}:{sha[:10]}"
            text = f"commit {sha[:10]} in {repo}: {subj}\n{body.strip()}\nfiles: " + ", ".join(
                os.path.relpath(f, d) for f in files[:20])
            db.leaf(sid + ":0", sid, 1, ts, "commit", text, files)
            db.session({"id": sid, "source": "git", "agent": "git", "model": None, "title": subj,
                        "first_user": None, "ts_min": ts, "ts_max": ts, "cwd": d, "branch": None,
                        "worktree": None, "n": 1, "files": {f: 1 for f in files[:60]}})
            kept += 1
    return kept


def main():
    os.makedirs(OUT, mode=0o700, exist_ok=True)
    os.chmod(OUT, 0o700)
    path = os.path.join(OUT, "n0.db")
    if os.path.exists(path):
        os.remove(path)
    db = DB(path)
    os.chmod(path, 0o600)
    t0 = time.time()
    n = {"claude": ingest_claude(db), "hermes": ingest_hermes(db), "git": ingest_git(db)}
    db.c.commit()
    db.c.executescript("""
      CREATE VIRTUAL TABLE leaves_fts USING fts5(id UNINDEXED, text, tokenize='porter unicode61');
      INSERT INTO leaves_fts SELECT id, text FROM leaves;""")
    db.c.commit()
    leaves, toks = db.c.execute("select count(*), sum(tokens) from leaves").fetchone()
    print(json.dumps({"sessions": n, "leaves": leaves, "tokens": toks, "scrubbed_leaves": db.n_scrubbed,
                      "seconds": round(time.time() - t0, 1), "db": path}))


if __name__ == "__main__":
    main()
