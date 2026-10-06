"""S2-S4: the Scribe's sources. Deterministic, incremental, no model calls (design §6).

Every source keeps a cursor in the store, so each run reads only what is new. Every text goes
through Store.add_leaf, which scrubs it. Session ids match the N0 spike's so its question sets
stay valid for regression checks: claude:<sessionId>, hermes:<agent>:<sid>, git:<repo>:<sha10>.
"""

from __future__ import annotations

import glob
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
from collections import Counter
from datetime import datetime

from .context import strip as strip_context
from .scrub import clean, excluded
from .store import Store

HOME = os.path.expanduser("~")
CAP = {"user": 6000, "assistant": 4000, "tool_use": 600, "tool": 1500, "commit": 2000, "change": 2400,
       "subagent_task": 6000, "packages": 3000}
PATH_RE = re.compile(r"(?:/home/[A-Za-z0-9_.-]+|~)/[\w.@%+=:,/-]+")
GIT = "g" + "it"


def _iso(ts: str):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None


def _paths(text: str) -> list[str]:
    out = []
    for m in PATH_RE.findall(text or ""):
        out.append(m.replace("~/", HOME + "/", 1).rstrip(".,:;)'\""))
    return out


def _worktree(cwd):
    m = re.search(r"/\.claude/worktrees/([^/]+)", cwd or "")
    return m.group(1) if m else None


class Window:
    """Optional [since, until) bound, used to rebuild the N0 window for regression checks."""

    def __init__(self, since: float | None = None, until: float | None = None, skip_sessions=()):
        self.since, self.until, self.skip = since, until, set(skip_sessions)

    def ok(self, ts) -> bool:
        if ts is None:
            return True
        return (self.since is None or ts >= self.since) and (self.until is None or ts < self.until)


# ---------------------------------------------------------------------- S3: Claude Code

def claude_roots() -> list[str]:
    return [os.path.join(HOME, ".claude/projects")] + sorted(
        glob.glob(os.path.join(HOME, ".config/claude-profiles/profiles/*/projects")))


def ingest_claude(store: Store, win: Window | None = None, roots: list[str] | None = None) -> int:
    win = win or Window()
    added = 0
    for root in roots or claude_roots():
        for path in sorted(glob.glob(os.path.join(root, "**/*.jsonl"), recursive=True)):
            added += _claude_file(store, path, win)
    return added


_SEEN: dict[str, int] = {}  # path -> size at our last read, so a 2-second poll skips unchanged files cheaply


def _claude_file(store: Store, path: str, win: Window) -> int:
    try:
        size = os.path.getsize(path)
    except OSError:
        return 0
    if _SEEN.get(path) == size:
        return 0
    _SEEN[path] = size
    key = "claude:" + path
    cur = store.cursor(key, {"offset": 0})
    if size < cur["offset"]:  # rewritten file: start over (leaf ids are offsets, so INSERT OR IGNORE keeps us safe)
        cur = {"offset": 0}
    if size == cur["offset"]:
        return 0
    sub = "/subagents/" in path
    tag = ("sub-" + os.path.basename(path)[:-6]) if sub else "m"
    before = store.added
    sessions: dict[str, dict] = {}
    files: dict[str, Counter] = {}
    with open(path, "rb") as fh, store.batch():
        fh.seek(cur["offset"])
        pos = cur["offset"]
        for raw in fh:
            if not raw.endswith(b"\n"):
                break  # partial last line: next run picks it up
            line_off, pos = pos, pos + len(raw)
            try:
                r = json.loads(raw)
            except json.JSONDecodeError:
                continue
            sid = r.get("sessionId")
            if not sid or ("claude:" + sid) in win.skip:
                continue
            s = sessions.setdefault(sid, {"id": "claude:" + sid, "source": "claude", "agent": "claude-code",
                                          "section": "claude", "ts_min": None, "ts_max": None})
            t = r.get("type")
            if t == "ai-title" and r.get("aiTitle"):
                s["title"] = r["aiTitle"]
                continue
            if t not in ("user", "assistant"):
                continue
            ts = _iso(r.get("timestamp", ""))
            if not win.ok(ts):
                continue
            cwd = r.get("cwd")
            if cwd and not sub:
                s.setdefault("cwd", cwd)
            if r.get("gitBranch") and r["gitBranch"] != "HEAD":
                s["branch"] = r["gitBranch"]
            if _worktree(cwd):
                s.setdefault("worktree", _worktree(cwd))
            role, text, full, touched = _claude_record(r, t, sub)
            if not text and full:
                role, text = "thinking", ""  # reasoning-only record: kept in full, not in the search tree
            if not text and not full:
                continue
            if role == "user" and not s.get("first_user") and not text.startswith("<"):
                s["first_user"] = text[:200]
            if t == "assistant" and not sub:  # a subagent's model is not the session's
                s["model"] = (r.get("message") or {}).get("model") or s.get("model")
            touched += _paths(text) if role != "tool" else []
            touched = [p for p in touched if not excluded(p)]
            files.setdefault(s["id"], Counter()).update(touched)
            if ts:
                s["ts_min"] = min(x for x in (s["ts_min"], ts) if x is not None)
                s["ts_max"] = max(x for x in (s["ts_max"], ts) if x is not None)
            store.add_leaf(f"claude:{sid}:{tag}:{line_off}", s["id"], ts or 0.0, ts, role,
                           text[: CAP.get(role, 2000)], touched, full=full)
        for s in sessions.values():
            if s["ts_min"] is not None or s.get("title"):
                store.upsert_session(s)
                store.merge_files(s["id"], files.get(s["id"], {}))
        store.set_cursor(key, {"offset": pos})
    return store.added - before


def _claude_record(r: dict, t: str, sub: bool):
    """-> (role, short view, full uncompacted text, files touched). The short view is what search,
    the tree and packets use (unchanged since 0.1.0); the full text keeps everything."""
    content = (r.get("message") or {}).get("content")
    role, parts, full, touched = None, [], [], []
    if t == "user":
        if isinstance(content, str):
            content = strip_context(content)
            role, parts, full = "user", [content], [content]
        elif isinstance(content, list):
            for b in content:
                if b.get("type") == "text":
                    role = role or "user"
                    parts.append(b.get("text", ""))
                    full.append(b.get("text", ""))
                elif b.get("type") == "tool_result":
                    role = role or "tool"
                    c = b.get("content")
                    if isinstance(c, list):
                        c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
                    out = ("ERROR " if b.get("is_error") else "") + str(c or "")
                    parts.append(out[: CAP["tool"]])
                    full.append(out)
        if role == "user" and sub:
            role = "subagent_task"
    else:
        role = "assistant"
        for b in content or []:
            bt = b.get("type")
            if bt == "text":
                parts.append(b.get("text", ""))
                full.append(b.get("text", ""))
            elif bt == "thinking" and b.get("thinking"):
                full.append("[thinking]\n" + b["thinking"])
            elif bt == "tool_use":
                inp = b.get("input") or {}
                p = inp.get("file_path") or inp.get("path") or inp.get("notebook_path")
                if p:
                    touched.append(p)
                arg = inp.get("command") or p or json.dumps(inp)[:300]
                parts.append(f"TOOL {b.get('name')}: {str(arg)[: CAP['tool_use']]}")
                full.append(f"TOOL {b.get('name')}: " + json.dumps(inp, ensure_ascii=False))
    return (role, "\n".join(x for x in parts if x).strip(), "\n".join(x for x in full if x).strip(), touched)


# ---------------------------------------------------------------------- S2: Hermes

def hermes_homes() -> list[tuple[str, str]]:
    out = [("hermes", os.path.join(HOME, ".hermes"))]
    for h in sorted(glob.glob(os.path.join(HOME, ".local/share/omarchy-agent-launcher/agents/*/hermes"))):
        out.append((h.split("/agents/")[1].split("/")[0], h))
    return out


def ingest_hermes(store: Store, win: Window | None = None, homes=None) -> int:
    win = win or Window()
    before = store.added
    for agent, home in homes or hermes_homes():
        path = os.path.join(home, "state.db")
        if not os.path.exists(path):
            continue
        key = "hermes:" + agent
        last = store.cursor(key, {"msg_id": 0})["msg_id"]
        try:
            c = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
            cols = {r[1] for r in c.execute("PRAGMA table_info(messages)")}
            reason = "coalesce(m.reasoning_content, m.reasoning)" if {"reasoning", "reasoning_content"} <= cols \
                else ("m.reasoning" if "reasoning" in cols else "NULL")
            rows = c.execute(f"SELECT m.id, m.session_id, m.role, m.content, m.tool_calls, m.timestamp, {reason} "
                             "FROM messages m WHERE m.id > ? ORDER BY m.id LIMIT 20000", (last,)).fetchall()
            meta = {}
            for sid in {r[1] for r in rows}:
                m = c.execute("SELECT model, title, cwd, git_branch, started_at FROM sessions WHERE id=?",
                              (sid,)).fetchone()
                meta[sid] = m or (None, None, None, None, None)
            c.close()
        except sqlite3.Error:
            continue
        files: dict[str, Counter] = {}
        sess: dict[str, dict] = {}
        with store.batch():
            for mid, sid, role, content, calls, ts, reasoning in rows:
                last = max(last, mid)
                s_id = f"hermes:{agent}:{sid}"
                if s_id in win.skip or not win.ok(ts):
                    continue
                model, title, cwd, branch, _ = meta[sid]
                s = sess.setdefault(s_id, {"id": s_id, "source": "hermes", "agent": agent, "model": model,
                                           "title": title, "cwd": cwd, "branch": branch,
                                           "worktree": _worktree(cwd), "section": f"agent/{agent}",
                                           "ts_min": None, "ts_max": None})
                text, touched = _hermes_text(content, calls)
                full = _hermes_full(content, calls, reasoning)
                if not text and not full:
                    continue
                r = "tool" if role == "tool" else role
                if r == "user" and not s.get("first_user"):
                    s["first_user"] = text[:200]
                touched += _paths(text) if r != "tool" else []
                touched = [p for p in touched if not excluded(p)]
                files.setdefault(s_id, Counter()).update(touched)
                if ts:
                    s["ts_min"] = min(x for x in (s["ts_min"], ts) if x is not None)
                    s["ts_max"] = max(x for x in (s["ts_max"], ts) if x is not None)
                store.add_leaf(f"{s_id}:{mid}", s_id, float(ts or mid), ts, r if text else "thinking",
                               text[: CAP.get(r, 2000)], touched, full=full)
            for s in sess.values():
                store.upsert_session(s)
                store.merge_files(s["id"], files.get(s["id"], {}))
            store.set_cursor(key, {"msg_id": last})
    return store.added - before


def _hermes_text(content, calls):
    parts, touched = [strip_context(content or "")], []
    if calls:
        try:
            for tc in json.loads(calls):
                fn = tc.get("function") or {}
                args = fn.get("arguments") or ""
                try:
                    a = json.loads(args)
                except (json.JSONDecodeError, TypeError):
                    a = {}
                p = (a.get("path") or a.get("file_path")) if isinstance(a, dict) else None
                if p:
                    touched.append(p)
                arg = (a.get("command") if isinstance(a, dict) else None) or p or args[:300]
                parts.append(f"TOOL {fn.get('name')}: {str(arg)[: CAP['tool_use']]}")
        except (json.JSONDecodeError, TypeError, AttributeError):
            pass
    return "\n".join(x for x in parts if x).strip(), touched


def _hermes_full(content, calls, reasoning) -> str:
    """The whole message: content, every tool call with its full arguments, and reasoning."""
    parts = [strip_context(content or "")]
    if calls:
        try:
            for tc in json.loads(calls):
                fn = tc.get("function") or {}
                parts.append(f"TOOL {fn.get('name')}: {fn.get('arguments') or ''}")
        except (json.JSONDecodeError, TypeError, AttributeError):
            parts.append(str(calls))
    if reasoning:
        parts.append("[thinking]\n" + str(reasoning))
    return "\n".join(x for x in parts if x).strip()


# ---------------------------------------------------------------------- S4: machine changes

def work_repos() -> list[str]:
    return sorted(d.rstrip("/") for d in glob.glob(os.path.join(HOME, "Work/*/")) if os.path.isdir(os.path.join(d, ".git")))


def ingest_commits(store: Store, win: Window | None = None, repos=None) -> int:
    win = win or Window()
    before = store.added
    for d in repos or work_repos():
        repo = os.path.basename(d)
        key = "commits:" + repo
        since = store.cursor(key, {"since": 0})["since"]
        args = [GIT, "-C", d, "log", "--all", "--name-only", "--format=%x1e%H%x1f%ct%x1f%s%x1f%b%x1f"]
        if since:
            args.insert(5, f"--since=@{int(since) - 86400}")
        try:
            out = subprocess.run(args, capture_output=True, text=True, timeout=120).stdout
        except (OSError, subprocess.TimeoutExpired):
            continue
        newest = since
        with store.batch():
            for rec in out.split("\x1e")[1:]:
                head, _, names = rec.rpartition("\x1f")
                sha, ct, subj, body = (head.split("\x1f") + ["", "", "", ""])[:4]
                if not sha or not ct:
                    continue
                ts = float(ct)
                newest = max(newest, ts)
                sid = f"git:{repo}:{sha[:10]}"
                if not win.ok(ts) or sid in win.skip:
                    continue
                files = [os.path.join(d, n) for n in names.split("\n") if n.strip()]
                text = (f"commit {sha[:10]} in {repo}: {subj}\n{body.strip()}\nfiles: "
                        + ", ".join(os.path.relpath(f, d) for f in files[:20]))
                full = (f"commit {sha} in {repo}: {subj}\n{body.strip()}\nfiles:\n"
                        + "\n".join(os.path.relpath(f, d) for f in files))
                if store.add_leaf(sid + ":0", sid, ts, ts, "commit", text[: CAP["commit"]], files, full=full):
                    store.upsert_session({"id": sid, "source": "git", "agent": "git", "title": subj, "ts_min": ts,
                                          "ts_max": ts, "cwd": d, "section": f"project/{repo}",
                                          "files": {f: 1 for f in files[:60]}})
            store.set_cursor(key, {"since": newest})
    return store.added - before


PACMAN_RE = re.compile(r"^\[([^\]]+)\] \[ALPM\] (.*)$")


def ingest_pacman(store: Store, win: Window | None = None, log: str = "/var/log/pacman.log") -> int:
    win = win or Window()
    if not os.access(log, os.R_OK):
        return 0
    key = "pacman:" + log
    cur = store.cursor(key, {"offset": 0, "pending": []})
    if os.path.getsize(log) < cur["offset"]:
        cur = {"offset": 0, "pending": []}
    before = store.added
    pending, start = cur.get("pending", []), cur.get("start")
    with open(log, "rb") as fh, store.batch():
        fh.seek(cur["offset"])
        pos = cur["offset"]
        for raw in fh:
            if not raw.endswith(b"\n"):
                break
            pos += len(raw)
            m = PACMAN_RE.match(raw.decode("utf-8", "replace").rstrip("\n"))
            if not m:
                continue
            ts, msg = _iso(m.group(1)), m.group(2)
            if msg == "transaction started":
                pending, start = [], ts
            elif msg == "transaction completed" and pending:
                t0 = start or ts
                if win.ok(t0):
                    day = datetime.fromtimestamp(t0).strftime("%Y-%m-%d")
                    sid = f"machine:pacman:{day}"
                    text = "pacman transaction:\n" + "\n".join(pending)
                    store.upsert_session({"id": sid, "source": "machine", "agent": "pacman",
                                          "title": f"package changes {day}", "ts_min": t0, "ts_max": ts,
                                          "section": "machine", "files": {"/usr/lib/pacman": 1}})
                    store.add_leaf(f"{sid}:{int(t0)}:{hashlib.sha1(text.encode()).hexdigest()[:8]}", sid, t0, t0, "packages", text[: CAP["packages"]],
                                   ["/usr/lib/pacman"])
                pending = []
            elif re.match(r"(installed|upgraded|removed|downgraded|reinstalled) ", msg):
                pending.append(msg)
        store.set_cursor(key, {"offset": pos, "pending": pending, "start": start})
    return store.added - before


CONFIG_ALLOW = ("hypr", "waybar", "omarchy", "alacritty", "kitty", "ghostty", "foot", "walker", "mako", "uwsm",
                "systemd/user", "environment.d", "fish", "starship.toml", "btop", "fastfetch", "swayosd",
                "elephant", "chromium-flags.conf", "xdg-terminals.list", "mimeapps.list")
TEXT_EXT_SKIP = re.compile(r"\.(png|jpe?g|gif|webp|svg|ico|mp4|webm|ttf|otf|woff2?|zip|gz|xz|zst|db|sqlite|so|bin)$", re.I)


def ingest_config(store: Store, state_dir: str, allow=CONFIG_ALLOW, config_root: str | None = None) -> int:
    """Snapshot allowlisted ~/.config text files (scrubbed) into a private mirror repo; one leaf per changed file."""
    root = config_root or os.path.join(HOME, ".config")
    mirror = os.path.join(state_dir, "config-mirror")
    os.makedirs(mirror, mode=0o700, exist_ok=True)
    want = {}
    for a in allow:
        p = os.path.join(root, a)
        cands = [p] if os.path.isfile(p) else []
        for dp, dns, fns in os.walk(p, followlinks=False):
            rel_dp = os.path.relpath(dp, root)
            if rel_dp.startswith("omarchy/plugins") and rel_dp.count("/") >= 2:
                dns[:] = []  # plugin repos: only their manifest.json (below)
            dns[:] = [d for d in dns if not d.startswith(".")]
            for f in fns:
                if rel_dp.startswith("omarchy/plugins/") and f != "manifest.json":
                    continue
                cands.append(os.path.join(dp, f))
        for f in cands:
            if os.path.islink(f) or excluded(f) or TEXT_EXT_SKIP.search(f):
                continue
            try:
                if os.path.getsize(f) > 262144:
                    continue
                with open(f, "rb") as fh:
                    data = fh.read()
            except OSError:
                continue
            if b"\0" in data[:4096]:
                continue
            want[os.path.relpath(f, root)] = clean(data.decode("utf-8", "replace"))
    # mirror = exactly the wanted set
    for dp, _, fns in os.walk(mirror):
        if "/.git" in dp + "/" and (dp.endswith("/.git") or "/.git/" in dp + "/"):
            continue
        for f in fns:
            rel = os.path.relpath(os.path.join(dp, f), mirror)
            if rel.startswith(".git"):
                continue
            if rel not in want:
                os.remove(os.path.join(dp, f))
    for rel, text in want.items():
        dst = os.path.join(mirror, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        try:
            with open(dst, encoding="utf-8", errors="replace") as fh:
                if fh.read() == text:
                    continue
        except OSError:
            pass
        with open(dst, "w", encoding="utf-8") as fh:
            fh.write(text)
    g = [GIT, "-C", mirror, "-c", "user.name=memstore", "-c", "user.email=memstore@localhost",
         "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"]
    first = not os.path.isdir(os.path.join(mirror, ".git"))
    if first:
        subprocess.run([GIT, "-C", mirror, "init", "-q"], check=True)
    subprocess.run(g + ["add", "-A"], check=True)
    if not subprocess.run(g + ["status", "--porcelain"], capture_output=True, text=True).stdout.strip():
        return 0
    subprocess.run(g + ["commit", "-q", "--no-verify", "-m", "snapshot"], check=True)
    sha = subprocess.run(g + ["rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    ts = float(subprocess.run(g + ["log", "-1", "--format=%ct"], capture_output=True, text=True).stdout.strip())
    day = datetime.fromtimestamp(ts).strftime("%Y-%m-%d")
    sid = f"machine:config:{day}"
    before = store.added
    with store.batch():
        store.upsert_session({"id": sid, "source": "machine", "agent": "config", "title": f"config changes {day}",
                              "ts_min": ts, "ts_max": ts, "section": "machine"})
        if first:
            names = sorted(want)
            text = f"baseline snapshot of {len(names)} config files:\n" + "\n".join(names[:300])
            full = f"baseline snapshot of {len(names)} config files:\n" + "\n".join(names)
            store.add_leaf(f"{sid}:{sha[:10]}:baseline", sid, ts, ts, "change", text[: CAP["change"]],
                           [os.path.join(root, n) for n in names[:60]], full=full)
        else:
            stat = subprocess.run(g + ["show", "--numstat", "--format=", "HEAD"], capture_output=True,
                                  text=True).stdout.strip().splitlines()
            for line in stat:
                parts = line.split("\t")
                if len(parts) != 3:
                    continue
                add, rem, rel = parts
                diff = subprocess.run(g + ["show", "--format=", "-U1", "HEAD", "--", rel], capture_output=True,
                                      text=True).stdout
                text = f"change ~/.config/{rel} +{add}/-{rem}\n" + "\n".join(diff.splitlines()[4:])
                store.add_leaf(f"{sid}:{sha[:10]}:{rel}", sid, ts, ts, "change", text[: CAP["change"]],
                               [os.path.join(root, rel)], full=text)
    return store.added - before


def ingest_all(store: Store, state_dir: str, win: Window | None = None, sources=("hermes", "claude", "commits",
                                                                                 "pacman", "config")) -> dict:
    out = {}
    if "hermes" in sources:
        out["hermes"] = ingest_hermes(store, win)
    if "claude" in sources:
        out["claude"] = ingest_claude(store, win)
    if "commits" in sources:
        out["commits"] = ingest_commits(store, win)
    if "pacman" in sources:
        out["pacman"] = ingest_pacman(store, win)
    if "config" in sources and win is None:
        try:
            out["config"] = ingest_config(store, state_dir)
        except (OSError, subprocess.CalledProcessError) as e:
            out["config"] = f"error: {e}"
    with store.batch():
        store.refresh_counts()
    return out


def remove_tree(path: str) -> None:
    shutil.rmtree(path, ignore_errors=True)
