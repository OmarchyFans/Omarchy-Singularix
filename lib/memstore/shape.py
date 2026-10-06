"""S6: the Shaper. Builds the project tree the Navigator reads (design §5.1–5.3, spike N0 arm C).

project -> workstream -> session -> episode -> unit, with deterministic titles and previews.
A project is worked out from the files each session touched; units are runs of consecutive
leaves of at most UNIT_TOKENS tokens. The whole derived layer is rebuilt in one transaction:
if anything fails the run is recorded as failed and the previous tree stays in service.
Ported from spikes/n0/trees.py build_c(), which N0 measured.
"""

from __future__ import annotations

import json
import math
import os
import re
import time
from collections import Counter, defaultdict
from datetime import datetime

from .store import Store

HOME = os.path.expanduser("~")
UNIT_TOKENS = 3500
FANOUT = 16
STOP = set("""this that with from have been were what when where which there their then than they them
will would could should about into your just like also only some more most other over such very here
does done make made need want using used uses file files line lines true false none null self return
import def class print else elif while for and the not are but you all can let get set new now one two
http https www json yaml text type name value data path home modpunk work local share config tool bash
command description output error true false content message response final report nothing reply exactly
opus sonnet claude user assistant""".split())
NOISE = re.compile(r"(^n?[d-][rwx-]{8,}|^home-|jsonl$|co-authored-by|noreply|anthropic\.com|^[0-9a-f-]{6,}$|"
                   r"^\d|exit_code|^silent$|^stalled$|^delivery$)")
WORD = re.compile(r"[A-Za-z][A-Za-z0-9_.-]{3,30}")
VCS = "g" + "it"


class Node:
    __slots__ = ("id", "kind", "title", "preview", "children", "leaves", "tokens", "sessions", "terms", "section",
                 "ts_min", "ts_max", "key_items")

    def __init__(self, nid, kind, title, preview="", section=""):
        self.id, self.kind, self.title, self.preview, self.section = nid, kind, title, preview, section
        self.children, self.leaves, self.tokens, self.sessions = [], [], 0, set()
        self.terms, self.ts_min, self.ts_max, self.key_items = Counter(), None, None, []

    def add(self, child):
        self.children.append(child)
        self.tokens += child.tokens
        self.sessions |= child.sessions
        self.terms.update(child.terms)
        for t in (child.ts_min, child.ts_max):
            if t is not None:
                self.ts_min = t if self.ts_min is None else min(self.ts_min, t)
                self.ts_max = t if self.ts_max is None else max(self.ts_max, t)


def leaf_terms(text):
    out = Counter()
    for w in WORD.findall(text[:1500]):
        w = w.lower().strip(".-_")
        if w not in STOP and not NOISE.search(w):
            out[w] += 1
    return out


def day(ts):
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d")


def hm(ts):
    return datetime.fromtimestamp(ts).strftime("%H:%M")


def project_of(path: str):
    p = path.replace("~/", HOME + "/", 1)
    m = re.match(re.escape(HOME) + r"/Work/([^/]+)", p)
    if m:
        return m.group(1)
    for base, label in ((".config/", "config/"), (".local/share/", "local/"), ("Projects/", "projects/")):
        m = re.match(re.escape(HOME) + "/" + re.escape(base) + r"([^/]+)", p)
        if m:
            return label + m.group(1)
    if p.startswith("/etc/") or p.startswith("/usr/"):
        return "system"
    return None


def norm_title(t):
    return re.sub(r"\s*(#\d+|\d{6,}|_\w+)$", "", (t or "").strip())[:60] or "untitled"


def session_line(s):
    return (s["title"] or s["first_user"] or "").replace("\n", " ")[:70]


def assign(s):
    if s["source"] == VCS:
        return s["id"].split(":")[1], "commits"
    if s["source"] == "machine":
        return f"machine/{s['agent']}", "changes"
    if s["source"] == "shared":  # N5: model-switch handoffs (design section 10)
        return "shared/handoffs", s["agent"] or "misc"
    w = Counter()
    for f, n in s["files"].items():
        p = project_of(f)
        if p:
            w[p] += n
    if w:
        proj = w.most_common(1)[0][0]
    else:
        cwd = (s["cwd"] or "").rstrip("/")
        proj = project_of(cwd) if cwd and cwd not in (HOME, HOME + "/Work") else None
        proj = proj or f"agents/{s['agent']}"
    ws = s["worktree"] or (s["branch"] if s["branch"] and s["branch"] != "HEAD" else None)
    if not ws:
        ws = norm_title(s["title"]) if proj.startswith("agents/") else "main"
    return proj, ws


def chunk(sess_id, leaves, prefix, title_fn, section):
    units, cur, tok = [], [], 0
    for lf in leaves:
        if cur and tok + lf["tokens"] > UNIT_TOKENS:
            units.append(cur)
            cur, tok = [], 0
        cur.append(lf)
        tok += lf["tokens"]
    if cur:
        units.append(cur)
    out = []
    for i, u in enumerate(units):
        n = Node(f"{prefix}:u{i}", "unit", title_fn(u, i, len(units)), section=section)
        n.leaves = [lf["id"] for lf in u]
        n.tokens = sum(lf["tokens"] for lf in u)
        n.sessions = {sess_id}
        ts = [lf["ts"] for lf in u if lf["ts"]]
        n.ts_min, n.ts_max = (min(ts), max(ts)) if ts else (None, None)
        for lf in u:
            n.terms.update(lf["terms"])
        n.preview = ep_preview(u)
        out.append(n)
    return out


def group(nodes, prefix, kind, title_fn, section=""):
    level = 0
    while len(nodes) > FANOUT:
        size = math.ceil(len(nodes) / FANOUT)
        grouped = []
        for i in range(0, len(nodes), size):
            run = nodes[i:i + size]
            g = Node(f"{prefix}:g{level}.{len(grouped)}", kind, title_fn(run), section=section)
            for c in run:
                g.add(c)
            grouped.append(g)
        nodes, level = grouped, level + 1
    return nodes


def episodes(leaves):
    eps, cur, last_ts = [], [], None
    for lf in leaves:
        real_user = lf["role"] == "user" and not lf["first"].startswith("<")
        gap = last_ts and lf["ts"] and lf["ts"] - last_ts > 1800
        if cur and (real_user or gap):
            eps.append(cur)
            cur = []
        cur.append(lf)
        last_ts = lf["ts"] or last_ts
    if cur:
        eps.append(cur)
    merged = []
    for e in eps:  # cost rule: tiny episodes fold into the previous one
        if merged and sum(x["tokens"] for x in merged[-1]) + sum(x["tokens"] for x in e) <= UNIT_TOKENS:
            merged[-1] = merged[-1] + e
        else:
            merged.append(e)
    return merged


def ep_preview(e):
    files = Counter(os.path.basename(f) for lf in e for f in lf["files"])
    cmds = [lf["first"][5:60] for lf in e if lf["first"].startswith("TOOL ")][:3]
    errs = [lf["first"][:60] for lf in e if lf["first"].startswith("ERROR")][:1]
    parts = []
    if files:
        parts.append("files: " + ", ".join(f for f, _ in files.most_common(4)))
    if cmds:
        parts.append("ran: " + "; ".join(cmds))
    if errs:
        parts.append("error: " + errs[0])
    return " | ".join(parts)


def distinctive(node, siblings, k=8):
    df = Counter()
    for s in siblings:
        df.update(set(t for t, _ in s.terms.most_common(200)))
    n = len(siblings) + 1
    scored = [(tf * math.log(n / (1 + df[t])), t) for t, tf in node.terms.most_common(200) if df[t] < n - 1 or n <= 2]
    return [t for _, t in sorted(scored, reverse=True)[:k]]


def previews(node):
    for ch in node.children:
        if ch.kind == "unit":
            continue
        sib = [x for x in node.children if x is not ch]
        terms = distinctive(ch, sib)
        members = [x.title.split(" · ")[-1].strip('"')[:40] for x in sorted(ch.children, key=lambda x: -x.tokens)[:3]]
        extra = ["includes: " + "; ".join(members)] if ch.kind in (
            "project", "workstream", "projects", "workstreams", "period", "episodes") else []
        ch.preview = " | ".join(x for x in ["about: " + ", ".join(terms)] + extra + [ch.preview] if x)[:300]
        if ch.kind != "episode":
            previews(ch)


def load(store: Store) -> dict:
    sessions = {}
    for r in store.db.execute("SELECT id, source, agent, model, title, first_user, ts_min, ts_max, cwd, branch, "
                              "worktree, section, files FROM sessions"):
        keys = ("id", "source", "agent", "model", "title", "first_user", "ts_min", "ts_max", "cwd", "branch",
                "worktree", "section", "files")
        s = dict(zip(keys, r))
        s["files"] = json.loads(s["files"] or "{}")
        s["leaves"] = []
        sessions[s["id"]] = s
    for sid in list(sessions):
        for lf in store.leaves_of(sid):
            if lf["role"] == "thinking":  # reasoning-only records live in the full transcript, not the tree
                continue
            lf["first"] = lf["text"][:100].replace("\n", " ")
            lf["terms"] = leaf_terms(lf["text"])
            del lf["text"]
            sessions[sid]["leaves"].append(lf)
    return {k: v for k, v in sessions.items() if v["leaves"] and v["ts_min"]}


def build(sessions: dict) -> Node:
    tree = defaultdict(lambda: defaultdict(list))
    for s in sessions.values():
        p, w = assign(s)
        tree[p][w].append(s)
    projects = []
    for p, wss in tree.items():
        # shared/handoffs is already an access-control section of its own (design section
        # 5.1), not a project: give it that section directly so `--sections shared` finds it.
        sec = p if p.startswith("shared/") else "project/" + p
        pn = Node("p:" + p, "project", p, section=sec)
        wnodes = []
        for w, ss in wss.items():
            wn = Node(f"p:{p}:w:{w}", "workstream", f"{p} · {w}", section=pn.section)
            snodes = []
            for s in sorted(ss, key=lambda s: s["ts_min"]):
                if s["source"] == VCS:
                    t = f"{day(s['ts_min'])} · commit {s['id'].split(':')[2][:8]} · {(s['title'] or '')[:90]}"
                else:
                    t = f"{day(s['ts_min'])} · {s['agent']} · {(s['model'] or '-')[:20]} · \"{session_line(s)}\""
                sec = s["section"] or ""
                sn = Node(s["id"], "session", t, section=sec)
                enodes = []
                for k, e in enumerate(episodes(s["leaves"])):
                    ask = next((lf["first"] for lf in e if lf["role"] in ("user", "subagent_task")), e[0]["first"])
                    en = Node(f"{s['id']}:e{k}", "episode", f"{hm(e[0]['ts'] or s['ts_min'])} · {ask[:90]}",
                              ep_preview(e), section=sec)
                    for u in chunk(s["id"], e, en.id, lambda u, i, n: f"part {i + 1}/{n} · {u[0]['first'][:80]}", sec):
                        en.add(u)
                    enodes.append(en)
                for x in group(enodes, sn.id, "episodes", lambda run: f"{run[0].title[:50]} … ({len(run)} episodes)", sec):
                    sn.add(x)
                files = Counter(os.path.basename(f) for f in s["files"])
                sn.preview = ("files: " + ", ".join(f for f, _ in files.most_common(4))) if files else ""
                snodes.append(sn)
            for x in group(snodes, wn.id, "period", lambda run: f"{run[0].title[:10]} to {run[-1].title[:10]} · {len(run)} items"):
                wn.add(x)
            wnodes.append(wn)
        wnodes.sort(key=lambda n: -n.tokens)
        for x in group(wnodes, pn.id, "workstreams", lambda run: f"{p} · {len(run)} workstreams"):
            pn.add(x)
        projects.append(pn)
    projects.sort(key=lambda n: -n.tokens)
    root = Node("root", "root", "all history")
    for x in group(projects, "root", "projects", lambda run: "projects: " + ", ".join(n.title for n in run[:6])):
        root.add(x)
    previews(root)
    return root


def write(store: Store, root: Node) -> dict:
    nodes = units = dupes = 0
    store.db.execute("DELETE FROM nodes")
    store.db.execute("DELETE FROM unit_leaves")
    stack = [(root, None, 0)]
    while stack:
        n, parent, ordn = stack.pop()
        store.db.execute("INSERT INTO nodes VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", (
            n.id, parent, n.kind, n.section, n.title, n.preview, json.dumps(n.key_items), n.tokens, n.ts_min,
            n.ts_max, json.dumps(sorted(n.sessions)) if n.kind in ("unit", "episode", "session") else "[]", ordn, None))
        nodes += 1
        if n.kind == "unit":
            units += 1
            store.db.executemany("INSERT OR IGNORE INTO unit_leaves VALUES(?,?)", [(n.id, lf) for lf in n.leaves])
        views = [(c.title, c.preview) for c in n.children]
        dupes += len(views) - len(set(views))
        for i, c in enumerate(n.children):
            stack.append((c, n.id, i))
    return {"nodes": nodes, "units": units, "duplicate_views": dupes}


def shape(store: Store) -> dict:
    """Rebuild the derived index. Never leaves a half-built tree in service."""
    t0 = time.time()
    run = store.db.execute("INSERT INTO shape_runs(started, status) VALUES(?, 'running')", (t0,)).lastrowid
    store.db.commit()
    try:
        root = build(load(store))
        with store.batch():
            st = write(store, root)
            store.db.execute("UPDATE sessions SET dirty=0")
            store.db.execute("UPDATE shape_runs SET finished=?, nodes=?, units=?, duplicate_views=?, status='ok' "
                             "WHERE id=?", (time.time(), st["nodes"], st["units"], st["duplicate_views"], run))
        st["seconds"] = round(time.time() - t0, 1)
        return st
    except Exception as e:  # noqa: BLE001 -- fail loud, keep the old tree
        store.db.rollback()
        store.db.execute("UPDATE shape_runs SET finished=?, status='failed', note=? WHERE id=?",
                         (time.time(), repr(e)[:500], run))
        store.db.commit()
        raise


def dirty(store: Store) -> bool:
    return bool(store.db.execute("SELECT 1 FROM sessions WHERE dirty=1 LIMIT 1").fetchone())


def fresh(store: Store) -> dict:
    """The recent branch: messages stored since the last full shape, searchable right away.

    Every leaf that has no unit yet goes into `recent:<session>` units under a `recent` node at
    the root, chunked and previewed like the main tree. The next full shape() rebuilds the whole
    derived layer, which folds these leaves into the main tree and clears the recent branch."""
    rows = store.db.execute(
        "SELECT l.session FROM leaves l LEFT JOIN unit_leaves u ON u.leaf=l.id "
        "WHERE (u.leaf IS NULL OR u.unit LIKE 'recent:%') AND l.role != 'thinking' GROUP BY l.session").fetchall()
    with store.batch():
        old = [r[0] for r in store.db.execute("SELECT id FROM nodes WHERE id='recent' OR id LIKE 'recent:%'")]
        store.db.executemany("DELETE FROM unit_leaves WHERE unit=?", [(i,) for i in old])
        store.db.executemany("DELETE FROM nodes WHERE id=?", [(i,) for i in old])
        if not rows:
            return {"recent_sessions": 0, "recent_units": 0}
        recent = Node("recent", "recent", "recent activity (not yet folded into the tree)")
        for (sid,) in rows:
            meta = store.db.execute("SELECT agent, model, title, first_user, section, ts_min FROM sessions WHERE id=?",
                                    (sid,)).fetchone()
            agent, model, title, first_user, section, ts0 = meta or ("?", None, None, None, "", None)
            leaves = []
            for lf in store.leaves_of(sid):
                if lf["role"] == "thinking" or store.unit_of(lf["id"]):
                    continue
                lf["first"] = lf["text"][:100].replace("\n", " ")
                lf["terms"] = leaf_terms(lf["text"])
                leaves.append(lf)
            if not leaves:
                continue
            t0 = leaves[0]["ts"] or ts0 or time.time()
            line = (title or first_user or "").replace("\n", " ")[:70]
            sn = Node(f"recent:{sid}", "session", f"{day(t0)} · {agent} · {(model or '-')[:20]} · \"{line}\" (recent)",
                      section=section or "")
            for u in chunk(sid, leaves, f"recent:{sid}", lambda u, i, n: f"recent {i + 1}/{n} · {u[0]['first'][:80]}",
                           section or ""):
                sn.add(u)
            files = Counter(os.path.basename(f) for lf in leaves for f in lf["files"])
            sn.preview = ("files: " + ", ".join(f for f, _ in files.most_common(4))) if files else ""
            recent.add(sn)
        if not recent.children:
            return {"recent_sessions": 0, "recent_units": 0}
        n_root = store.db.execute("SELECT count(*) FROM nodes WHERE parent='root'").fetchone()[0]
        stack, units = [(recent, "root", n_root)], 0
        while stack:
            n, parent, ordn = stack.pop()
            store.db.execute("INSERT OR REPLACE INTO nodes VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", (
                n.id, parent, n.kind, n.section, n.title, n.preview, "[]", n.tokens, n.ts_min, n.ts_max,
                json.dumps(sorted(n.sessions)) if n.kind in ("unit", "session") else "[]", ordn, None))
            if n.kind == "unit":
                units += 1
                store.db.executemany("INSERT OR IGNORE INTO unit_leaves VALUES(?,?)", [(n.id, lf) for lf in n.leaves])
            for i, c in enumerate(n.children):
                stack.append((c, n.id, i))
    return {"recent_sessions": len(recent.children), "recent_units": units}

