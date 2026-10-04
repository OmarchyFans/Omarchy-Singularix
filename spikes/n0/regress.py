#!/usr/bin/env python3
"""Regression check for the production memstore against spike N0's frozen question sets.

Rebuilds the N0 window (2026-09-18 .. 2026-10-02 00:29, the spike's own session excluded) with
the production ingest -> shape -> navigate path into a scratch store, then scores the 25
evaluation questions and the 15 validation questions. Bars (S6/N2 done-when): hit@3 >= 0.70 on
the 25 and >= 0.60 on the 15. Prints aggregates only; questions and data stay in N0_DIR.

usage: regress.py [--rebuild]
"""

import json
import os
import sys
import time
from datetime import datetime

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib"))
from memstore.decider import Decider  # noqa: E402
from memstore.ingest import Window, ingest_claude, ingest_commits, ingest_hermes  # noqa: E402
from memstore.navigator import navigate  # noqa: E402
from memstore.shape import shape  # noqa: E402
from memstore.store import Store  # noqa: E402

D = os.environ.get("N0_DIR", os.path.expanduser("~/.local/share/omarchy-memstore/spike-n0"))
DB = os.path.join(D, "regress", "memstore.db")
WIN = Window(since=datetime.fromisoformat("2026-09-18T00:00:00").timestamp(),
             until=datetime.fromisoformat("2026-10-02T00:29:00").timestamp(),
             skip_sessions={"claude:40c600da-5dd1-4937-8395-b0196152f747"})


def build():
    if os.path.exists(DB):
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(DB + suffix):
                os.remove(DB + suffix)
    s = Store(DB)
    t0 = time.time()
    n = {"hermes": ingest_hermes(s, WIN), "claude": ingest_claude(s, WIN), "commits": ingest_commits(s, WIN)}
    with s.batch():
        s.refresh_counts()
    st = shape(s)
    print(json.dumps({"ingested": n, "shape": st, "seconds": round(time.time() - t0)}), flush=True)
    return s


def score(s, qfile, only_eval):
    qs = [q for q in json.load(open(os.path.join(D, qfile))) if not (only_eval and q["dev"])]
    d = Decider()
    rows, t0 = [], time.time()
    for q in qs:
        nav = navigate(s, q["q"], k=3, decider=d)
        gold = set(q["gold"])
        ranks = [i for i, u in enumerate(nav["units"]) if set(u["sessions"]) & gold]
        rows.append({"hit1": bool(ranks and ranks[0] == 0), "hit3": bool(ranks), "mode": nav["mode"]})
    n = len(rows)
    return {"set": qfile, "n": n, "hit@1": round(sum(r["hit1"] for r in rows) / n, 3),
            "hit@3": round(sum(r["hit3"] for r in rows) / n, 3),
            "reranked": sum(r["mode"] == "reranked" for r in rows), "calls": d.calls,
            "sec_per_q": round((time.time() - t0) / n, 2)}


def main():
    s = build() if "--rebuild" in sys.argv or not os.path.exists(DB) else Store(DB)
    a = score(s, "questions.json", True)
    b = score(s, "questions2.json", False)
    a["pass"], b["pass"] = a["hit@3"] >= 0.70, b["hit@3"] >= 0.60
    print(json.dumps(a))
    print(json.dumps(b))


if __name__ == "__main__":
    main()
