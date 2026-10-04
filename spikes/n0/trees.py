#!/usr/bin/env python3
"""N0 spike, step 2: build the two trees the crawl arms navigate.

Arm B (v1 control): month -> day -> session -> chunk, field titles, no previews.
Arm C (v2): project -> workstream -> session -> episode -> chunk, title + deterministic preview.

Both trees end in the same kind of retrieval unit: a run of consecutive leaves of at most
UNIT_TOKENS tokens. Any node whose whole subtree fits in UNIT_TOKENS is read directly (design
5.3), so B and C hand the consumer the same amount of text per unit. No model is called.
"""

import json
import math
import os
import pickle
import re
import sqlite3
from collections import Counter, defaultdict
from datetime import datetime

D = os.environ.get("N0_DIR", os.path.expanduser("~/.local/share/omarchy-memstore/spike-n0"))
HOME = os.path.expanduser("~")
UNIT_TOKENS = 3500
FANOUT = 16
STOP = set("""this that with from have been were what when where which there their then than they them
will would could should about into your just like also only some more most other over such very here
does done make made need want using used uses file files line lines true false none null self return
import def class print else elif while for and the not are but you all can let get set new now one two
http https www json yaml text type name value data path home modpunk work local share config tool bash
command description output error true false""".split())
WORD = re.compile(r"[A-Za-z][A-Za-z0-9_.-]{3,30}")


class Node:
    __slots__ = ("id", "kind", "title", "preview", "children", "leaves", "tokens", "sessions", "terms",
                 "parent", "summary")

    def __init__(self, nid, kind, title, preview=""):
        self.id, self.kind, self.title, self.preview = nid, kind, title, preview
        self.children, self.leaves, self.tokens, self.sessions = [], [], 0, set()
        self.terms, self.parent, self.summary = Counter(), None, None

    def add(self, child):
        child.parent = self.id
        self.children.append(child)
        self.tokens += child.tokens
        self.sessions |= child.sessions
        self.terms.update(child.terms)


def day(ts):
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d")


def hm(ts):
    return datetime.fromtimestamp(ts).strftime("%H:%M")


NOISE = re.compile(r"(^n?[d-][rwx-]{8,}|^home-modpunk|jsonl$|co-authored-by|noreply|anthropic\.com|^[0-9a-f-]{6,}$|"
                   r"^\d|exit_code|^silent$|^stalled$|^delivery$)")
STOP |= set("content message response final report nothing reply exactly opus sonnet claude user assistant".split())


def leaf_terms(text):
    out = Counter()
    for w in WORD.findall(text[:1500]):
        w = w.lower().strip(".-_")
        if w not in STOP and not NOISE.search(w):
            out[w] += 1
    return out


def chunk_leaves(sess_id, leaves, prefix, title_fn):
    """Consecutive leaves -> unit nodes of <= UNIT_TOKENS tokens."""
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
        n = Node(f"{prefix}:u{i}", "unit", title_fn(u, i, len(units)))
        n.leaves = [lf["id"] for lf in u]
        n.tokens = sum(lf["tokens"] for lf in u)
        n.sessions = {sess_id}
        for lf in u:
            n.terms.update(lf["terms"])
        out.append(n)
    return out


def group(nodes, prefix, kind, title_fn):
    """Fan-out cap: wrap runs of children into group nodes until there are <= FANOUT."""
    while len(nodes) > FANOUT:
        size = math.ceil(len(nodes) / FANOUT)
        grouped = []
        for i in range(0, len(nodes), size):
            run = nodes[i:i + size]
            g = Node(f"{prefix}:g{len(grouped)}:{i}", kind, title_fn(run))
            for c in run:
                g.add(c)
            grouped.append(g)
        nodes = grouped
        prefix += "x"
    return nodes


def distinctive(node, siblings, k=8):
    df = Counter()
    for s in siblings:
        df.update(set(t for t, _ in s.terms.most_common(200)))
    n = len(siblings) + 1
    scored = [(tf * math.log(n / (1 + df[t])), t) for t, tf in node.terms.most_common(200) if df[t] < n - 1 or n <= 2]
    return [t for _, t in sorted(scored, reverse=True)[:k]]


def project_of(path):
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


def load():
    c = sqlite3.connect(os.path.join(D, "n0.db"))
    sessions = {}
    for r in c.execute("select id, source, agent, model, title, first_user, ts_min, ts_max, cwd, branch, worktree, "
                       "n_leaves, files from sessions"):
        sessions[r[0]] = dict(zip(("id", "source", "agent", "model", "title", "first_user", "ts_min", "ts_max",
                                   "cwd", "branch", "worktree", "n", "files"), r))
        sessions[r[0]]["files"] = json.loads(r[12] or "{}")
        sessions[r[0]]["leaves"] = []
    for lid, sess, seq, ts, role, text, tokens, files in c.execute(
            "select id, session, seq, ts, role, text, tokens, files from leaves order by session, seq"):
        if sess in sessions:
            sessions[sess]["leaves"].append({"id": lid, "seq": seq, "ts": ts, "role": role, "tokens": tokens,
                                             "first": text[:100].replace("\n", " "), "terms": leaf_terms(text),
                                             "files": json.loads(files)})
    return {k: v for k, v in sessions.items() if v["leaves"]}


def session_line(s):
    return (s["title"] or s["first_user"] or "").replace("\n", " ")[:70]


# ---------------------------------------------------------------- arm B: v1 date tree

def build_b(sessions):
    by_day = defaultdict(list)
    for s in sessions.values():
        by_day[day(s["ts_min"])].append(s)
    months = defaultdict(list)
    for d in sorted(by_day):
        nodes = []
        for s in sorted(by_day[d], key=lambda s: s["ts_min"]):
            if s["source"] == "g" + "it":
                title = f"commit · {s['id'].split(':')[1]} · {(s['title'] or '')[:80]}"
            else:
                title = (f"{d} · {s['agent']} · {(s['model'] or '-')[:24]} · \"{session_line(s)[:60]}…\" · "
                         f"{len(s['leaves'])} msgs")
            sn = Node("B:" + s["id"], "session", title)
            units = chunk_leaves(s["id"], s["leaves"], "B:" + s["id"],
                                 lambda u, i, n: f"{u[0]['role']} · {hm(u[0]['ts'])} · {u[0]['first'][:80]}")
            for u in group(units, "B:" + s["id"], "range",
                           lambda run: f"turns {run[0].title[:40]} … ({len(run)} parts)"):
                sn.add(u)
            nodes.append(sn)
        n_sess = sum(1 for s in by_day[d] if s["source"] != "g" + "it")
        n_com = len(by_day[d]) - n_sess
        agents = Counter(s["agent"] for s in by_day[d] if s["source"] != "g" + "it").most_common(3)
        repos = Counter(s["id"].split(":")[1] for s in by_day[d] if s["source"] == "g" + "it").most_common(3)
        dn = Node("B:day:" + d, "day", f"{d} · {n_sess} sessions, {n_com} commits · "
                  + ", ".join(a for a, _ in agents + repos))
        for c in group(nodes, "B:day:" + d, "bucket",
                       lambda run: f"{d} · {len(run)} items from {run[0].title[13:40]}…"):
            dn.add(c)
        months[d[:7]].append(dn)
    root = Node("B:root", "root", "all history")
    for m in sorted(months):
        mn = Node("B:month:" + m, "month", f"{m} · {sum(len(x.sessions) for x in months[m])} sessions and commits")
        for c in group(months[m], "B:month:" + m, "bucket", lambda run: f"{run[0].title[:10]} to {run[-1].title[:10]}"):
            mn.add(c)
        root.add(mn)
    return root


# ---------------------------------------------------------------- arm C: v2 project tree

def assign(s):
    w = Counter()
    for f, n in s["files"].items():
        p = project_of(f)
        if p:
            w[p] += n
    if s["source"] == "g" + "it":
        return s["id"].split(":")[1], "commits"
    if w:
        proj = w.most_common(1)[0][0]
    else:
        proj = project_of(s["cwd"] or "") if s["cwd"] and s["cwd"].rstrip("/") not in (HOME, HOME + "/Work") else None
        proj = proj or f"agents/{s['agent']}"
    ws = s["worktree"] or (s["branch"] if s["branch"] and s["branch"] != "HEAD" else None)
    if not ws:
        ws = norm_title(s["title"]) if proj.startswith("agents/") else "main"
    return proj, ws


def episodes(s):
    eps, cur = [], []
    last_ts = None
    for lf in s["leaves"]:
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


def build_c(sessions):
    tree = defaultdict(lambda: defaultdict(list))
    for s in sessions.values():
        p, w = assign(s)
        tree[p][w].append(s)
    projects = []
    for p, wss in tree.items():
        pn = Node("C:p:" + p, "project", p)
        wnodes = []
        for w, ss in wss.items():
            wn = Node(f"C:p:{p}:w:{w}", "workstream", f"{p} · {w}")
            snodes = []
            for s in sorted(ss, key=lambda s: s["ts_min"]):
                if s["source"] == "g" + "it":
                    t = f"{day(s['ts_min'])} · commit {s['id'].split(':')[2][:8]} · {(s['title'] or '')[:90]}"
                else:
                    t = f"{day(s['ts_min'])} · {s['agent']} · {(s['model'] or '-')[:20]} · \"{session_line(s)}\""
                sn = Node("C:" + s["id"], "session", t)
                enodes = []
                for k, e in enumerate(episodes(s)):
                    ask = next((lf["first"] for lf in e if lf["role"] in ("user", "subagent_task")), e[0]["first"])
                    en = Node(f"C:{s['id']}:e{k}", "episode", f"{hm(e[0]['ts'] or s['ts_min'])} · {ask[:90]}",
                              ep_preview(e))
                    for u in chunk_leaves(s["id"], e, en.id, lambda u, i, n: f"part {i + 1}/{n} · {u[0]['first'][:80]}"):
                        u.preview = ep_preview([lf for lf in s["leaves"] if lf["id"] in set(u.leaves)])
                        en.add(u)
                    enodes.append(en)
                for x in group(enodes, sn.id, "episodes",
                               lambda run: f"{run[0].title[:50]} … ({len(run)} episodes)"):
                    sn.add(x)
                files = Counter(os.path.basename(f) for f in s["files"])
                sn.preview = ("files: " + ", ".join(f for f, _ in files.most_common(4))) if files else ""
                snodes.append(sn)
            for x in group(snodes, wn.id, "period",
                           lambda run: f"{run[0].title[:10]} to {run[-1].title[:10]} · {len(run)} items"):
                wn.add(x)
            wnodes.append(wn)
        wnodes.sort(key=lambda n: -n.tokens)
        for x in group(wnodes, pn.id, "workstreams", lambda run: f"{p} · {len(run)} workstreams"):
            pn.add(x)
        projects.append(pn)
    projects.sort(key=lambda n: -n.tokens)
    root = Node("C:root", "root", "all history")
    for x in group(projects, "C:root", "projects", lambda run: "projects: " + ", ".join(n.title for n in run[:6])):
        root.add(x)
    previews(root)
    return root


def previews(node):
    """Distinctive terms vs siblings + member titles, for every interior node above an episode."""
    for ch in node.children:
        if ch.kind in ("unit",):
            continue
        sib = [x for x in node.children if x is not ch]
        terms = distinctive(ch, sib)
        members = [x.title.split(" · ")[-1].strip('"')[:40] for x in sorted(ch.children, key=lambda x: -x.tokens)[:3]]
        extra = []
        if ch.kind in ("project", "workstream", "projects", "workstreams", "period", "episodes"):
            extra.append("includes: " + "; ".join(members))
        base = ch.preview
        ch.preview = " | ".join(x for x in ["about: " + ", ".join(terms)] + extra + [base] if x)[:300]
        if ch.kind not in ("episode",):
            previews(ch)


def flat(root):
    out = {}
    stack = [root]
    while stack:
        n = stack.pop()
        out[n.id] = n
        stack.extend(n.children)
    return out


def stats(root):
    nodes = flat(root)
    units = [n for n in nodes.values() if n.kind == "unit"]
    depth = {}

    def walk(n, d):
        depth[n.id] = d
        for c in n.children:
            walk(c, d + 1)
    walk(root, 0)
    sibling_dupes = sum(len(n.children) - len(set((c.title, c.preview) for c in n.children)) for n in nodes.values())
    return {"nodes": len(nodes), "units": len(units), "max_depth": max(depth.values()),
            "mean_unit_depth": round(sum(depth[u.id] for u in units) / len(units), 2),
            "root_children": len(root.children), "duplicate_sibling_views": sibling_dupes,
            "tokens": root.tokens}


def main():
    import sys
    sys.setrecursionlimit(10000)
    sessions = load()
    b, c = build_b(sessions), build_c(sessions)
    for name, t in (("B", b), ("C", c)):
        pickle.dump(t, open(os.path.join(D, f"tree_{name}.pkl"), "wb"))
        print(name, json.dumps(stats(t)))


if __name__ == "__main__":
    main()
