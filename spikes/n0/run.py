#!/usr/bin/env python3
"""N0 spike, step 3: run the retrieval arms against the frozen question set.

Arms
  A_leaf   BM25 over leaves (the keyword-search baseline)
  A_unit   BM25 aggregated to C's units (same unit size as the crawls)
  B        crawl of the v1 date tree, titles only
  C        crawl of the v2 project tree, title + preview
  C_hyb    C seeded with A_leaf's hits
  C_choice C with a permuted 'choice' instead of per-child 'noul'
  D, D_hyb C / C_hyb with local-model navigation summaries added to the node view

Usage: run.py calibrate ARM...   (dev questions, sweeps tau, writes tau.json)
       run.py eval ARM...        (eval questions, frozen tau, writes results_<arm>.json)
"""

import json
import math
import os
import pickle
import re
import sqlite3
import sys
import time
import urllib.request

sys.setrecursionlimit(10000)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from trees import Node, flat  # noqa: E402,F401

D = os.environ.get("N0_DIR", os.path.expanduser("~/.local/share/omarchy-memstore/spike-n0"))
SERVER = os.environ.get("N0_SERVER", "http://127.0.0.1:8080")
TOP = 3
BUDGET = int(os.environ.get("N0_BUDGET", "48"))
TAUS = [0.05, 0.15, 0.3, 0.5]
STATS = {"calls": 0, "prompt_n": 0, "cache_n": 0, "ms": 0.0}

SYS_NOUL = ("You route a search through an index of past work sessions on a Linux laptop. "
            "Given what is being looked for and one branch of the index, answer Yes if that branch "
            "probably contains it, otherwise No. Answer with one word.")
SYS_CHOICE = ("You route a search through an index of past work sessions on a Linux laptop. "
              "Given what is being looked for and a list of branches, answer with the letter of the "
              "branch most likely to contain it. Answer with one letter.")


def chat(system, user, allowed):
    body = json.dumps({"messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                       "max_tokens": 1, "temperature": 0, "logprobs": True, "top_logprobs": 20,
                       "cache_prompt": True}).encode()
    req = urllib.request.Request(SERVER + "/v1/chat/completions", body, {"content-type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=120))
    t = r.get("timings", {})
    STATS["calls"] += 1
    STATS["prompt_n"] += t.get("prompt_n", 0)
    STATS["cache_n"] += t.get("cache_n", 0)
    STATS["ms"] += t.get("prompt_ms", 0)
    probs = {}
    for lp in r["choices"][0]["logprobs"]["content"][0]["top_logprobs"]:
        k = lp["token"].strip()
        k = k.capitalize() if k.lower() in ("yes", "no") else k
        if k in allowed:
            probs[k] = probs.get(k, 0) + math.exp(lp["logprob"])
    z = sum(probs.values())
    return {k: probs.get(k, 0) / z if z else 1 / len(allowed) for k in allowed}


def view(n, with_summary=False):
    s = n.title
    if n.preview:
        s += "\n" + n.preview
    if with_summary and n.summary:
        s += "\nSummary: " + n.summary
    return s[:700]


def noul(need, n, with_summary):
    return chat(SYS_NOUL, f"Looking for: {need}\n\nBranch:\n{view(n, with_summary)}\n\nDoes this branch probably contain it?",
                ("Yes", "No"))["Yes"]


def choice_scores(need, children, with_summary):
    letters = [chr(65 + i) for i in range(len(children))]
    scores = [0.0] * len(children)
    for order in (list(range(len(children))), list(reversed(range(len(children))))):
        lines = [f"{letters[k]}) {view(children[i], with_summary).replace(chr(10), ' — ')[:300]}" for k, i in enumerate(order)]
        p = chat(SYS_CHOICE, f"Looking for: {need}\n\nBranches:\n" + "\n".join(lines) + "\n\nWhich branch?", letters)
        for k, i in enumerate(order):
            scores[i] += p[letters[k]] / 2
    return scores


# ------------------------------------------------------------------- keyword baseline

DB = None
WORDS = re.compile(r"[A-Za-z][A-Za-z0-9-]{2,}")
QSTOP = set("where when which what did does we was were the and for our from into that this with get got "
            "how who why keep kept start started stop work worked".split())


def bm25(need, k=24):
    terms = [w for w in WORDS.findall(need.lower()) if w not in QSTOP]
    q = " OR ".join(f'"{w}"' for w in terms)
    return DB.execute("select id, bm25(leaves_fts) from leaves_fts where leaves_fts match ? order by 2 limit ?",
                      (q, k)).fetchall()


# ------------------------------------------------------------------- crawl

class Tree:
    def __init__(self, name):
        self.root = pickle.load(open(os.path.join(D, f"tree_{name}.pkl"), "rb"))
        self.nodes = flat(self.root)
        self.unit_of = {}
        for n in self.nodes.values():
            if n.kind == "unit":
                for lf in n.leaves:
                    self.unit_of[lf] = n


def crawl(tree, need, tau, with_summary=False, seeds=(), use_choice=False):
    budget = BUDGET
    frontier = [(1.0, tree.root)]
    accepted, seen = [], set()
    for lid, _ in seeds:
        u = tree.unit_of.get(lid)
        if u and u.id not in seen and budget > 0:
            seen.add(u.id)
            budget -= 1
            p = noul(need, u, with_summary)
            if p >= tau:
                accepted.append((p, u))
    while frontier and budget > 0 and len(accepted) < TOP * 2:
        frontier.sort(key=lambda x: -x[0])
        score, v = frontier.pop(0)
        if v.tokens <= 3500 or not v.children:
            if v.id not in seen:
                seen.add(v.id)
                accepted.append((score, v))
            continue
        kids = v.children
        if use_choice and len(kids) > 1:
            if budget < 2:
                break
            budget -= 2
            ps = choice_scores(need, kids, with_summary)
            ps = [p * len(kids) / 2 for p in ps]  # rescale so 'twice the average' ~ 1.0
        else:
            ps = []
            for c in kids:
                if budget <= 0:
                    break
                budget -= 1
                ps.append(noul(need, c, with_summary))
        for c, p in zip(kids, ps):
            if p >= tau:
                frontier.append((score * min(1.0, p), c))
    accepted.sort(key=lambda x: -x[0])
    return [u for _, u in accepted[:TOP]], BUDGET - budget


def run_units(arm, need, tau, trees, taus=None):
    """-> ([(sessions, tokens, key)], calls) for one arm and one need."""
    if arm == "A_leaf":
        out = []
        for lid, _ in bm25(need, TOP):
            sess, tok = DB.execute("select session, tokens from leaves where id=?", (lid,)).fetchone()
            out.append(({sess}, tok, lid))
        return out, 0
    if arm == "A_unit":
        best = {}
        for lid, s in bm25(need, 200):
            u = trees["C"].unit_of.get(lid)
            if u and (u.id not in best or s < best[u.id][0]):
                best[u.id] = (s, u)
        return [({*u.sessions}, u.tokens, u.id) for _, u in sorted(best.values(), key=lambda x: x[0])[:TOP]], 0
    if arm.startswith("F_"):
        # Fusion, pre-registered 2026-10-02 after the 25-question eval: interleave keyword hits
        # and the tree crawl's hits as A1, T1, A2, T2 ..., skipping duplicates; keep the top 3.
        tree_arm = arm[2:]
        a, _ = run_units("A_leaf", need, 0, trees)
        t, calls = run_units(tree_arm, need, (taus or {}).get(tree_arm, tau), trees)
        units, seen = [], set()
        for pair in zip(a + [None] * TOP, t + [None] * TOP):
            for u in pair:
                if u and u[2] not in seen and len(units) < TOP:
                    seen.add(u[2])
                    units.append(u)
        return units, calls
    tname = "B" if arm.startswith("B") else ("D" if arm.startswith("D") else "C")
    seeds = bm25(need, 16) if arm.endswith("_hyb") else ()
    got, calls = crawl(trees[tname], need, tau, with_summary=tname == "D", seeds=seeds,
                       use_choice=arm.endswith("_choice"))
    return [(u.sessions, u.tokens, u.id) for u in got], calls


def run_arm(arm, q, tau, trees, taus=None):
    t0 = time.time()
    units, calls = run_units(arm, q["q"], tau, trees, taus)
    gold = set(q["gold"])
    ranks = [i for i, (ss, _, _) in enumerate(units) if ss & gold]
    return {"id": q["id"], "hit1": bool(ranks and ranks[0] == 0), "hit3": bool(ranks),
            "rr": 1 / (ranks[0] + 1) if ranks else 0.0, "calls": calls, "sec": round(time.time() - t0, 2),
            "tokens": sum(t for _, t, _ in units), "n_units": len(units)}


def summarize(rows):
    n = len(rows)
    return {"n": n, "hit@1": round(sum(r["hit1"] for r in rows) / n, 3), "hit@3": round(sum(r["hit3"] for r in rows) / n, 3),
            "mrr": round(sum(r["rr"] for r in rows) / n, 3), "calls": round(sum(r["calls"] for r in rows) / n, 1),
            "sec": round(sum(r["sec"] for r in rows) / n, 2), "tokens": round(sum(r["tokens"] for r in rows) / n)}


def main():
    global DB
    mode, arms = sys.argv[1], sys.argv[2:]
    DB = sqlite3.connect(os.path.join(D, "n0.db"))
    qs = json.load(open(os.path.join(D, os.environ.get("N0_QFILE", "questions.json"))))
    trees = {}
    for name in ("B", "C", "D"):
        p = os.path.join(D, f"tree_{name}.pkl")
        if os.path.exists(p):
            trees[name] = Tree(name)
    tau_path = os.path.join(D, "tau.json")
    taus = json.load(open(tau_path)) if os.path.exists(tau_path) else {}
    for arm in arms:
        STATS.update(calls=0, prompt_n=0, cache_n=0, ms=0.0)
        if mode == "calibrate":
            dev = [q for q in qs if q["dev"]]
            best = None
            for tau in ([0] if arm.startswith("A_") else TAUS):
                rows = [run_arm(arm, q, tau, trees) for q in dev]
                s = summarize(rows)
                print(arm, "tau", tau, json.dumps(s), flush=True)
                key = (s["hit@3"], s["mrr"], -s["calls"])
                if best is None or key > best[0]:
                    best = (key, tau)
            taus[arm] = best[1]
            json.dump(taus, open(tau_path, "w"), indent=1)
        else:
            ev = [q for q in qs if not q["dev"]]
            tag = os.environ.get("N0_TAG", "")
            tau = taus.get(arm, 0.15)
            rows = []
            for q in ev:
                rows.append(run_arm(arm, q, tau, trees, taus))
                print(arm, json.dumps(rows[-1]), flush=True)
            s = summarize(rows)
            s.update(tau=tau, cache_hit=round(STATS["cache_n"] / max(1, STATS["cache_n"] + STATS["prompt_n"]), 3),
                     ms_per_call=round(STATS["ms"] / max(1, STATS["calls"]), 1))
            json.dump({"arm": arm, "summary": s, "rows": rows}, open(os.path.join(D, f"results_{arm}{tag}.json"), "w"), indent=1)
            print("SUMMARY", arm, json.dumps(s), flush=True)


if __name__ == "__main__":
    main()
