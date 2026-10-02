#!/usr/bin/env python3
"""N0 spike, arm D: local-model navigation summaries on tree C's interior nodes.

Bottom-up, as in PageIndex (utils.py SummaryScheduler / _parent_summary): a node is summarized
from its children's titles and previews (or their summaries once written), never from full
leaf text. Units, episodes and single-commit sessions are not summarized. On failure the
node keeps no summary and the crawl falls back to the preview. Writes tree_D.pkl.

Prompt adapted from VectifyAI/PageIndex (MIT), pageindex/utils.py _parent_summary.
"""

import json
import os
import pickle
import sys
import time
import urllib.request

sys.setrecursionlimit(10000)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from trees import Node, flat  # noqa: E402,F401

D = os.environ.get("N0_DIR", os.path.expanduser("~/.local/share/omarchy-memstore/spike-n0"))
SERVER = os.environ.get("N0_SERVER", "http://127.0.0.1:8080")
KINDS = {"session", "episodes", "period", "workstream", "workstreams", "project", "projects"}
PROMPT = ("You are given one section of an index of past work sessions on a Linux laptop: its title and "
          "the titles and short descriptions of what it contains. Write a concise description of "
          "everything this section covers, so someone can tell whether what they are looking for is "
          "inside. Name concrete topics, tools, projects and problems. At most 60 words. Reply with the "
          "description only.\n\nSection title: {title}\n\nContents:\n{listing}")


def gen(prompt):
    body = json.dumps({"messages": [{"role": "user", "content": prompt}], "max_tokens": 110,
                       "temperature": 0.2}).encode()
    req = urllib.request.Request(SERVER + "/v1/chat/completions", body, {"content-type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=180))
    return r["choices"][0]["message"]["content"].strip()


def listing(n):
    rows = []
    for c in sorted(n.children, key=lambda c: -c.tokens)[:14]:
        desc = c.summary or c.preview or ""
        rows.append(f"- {c.title[:110]}" + (f": {desc[:220]}" if desc else ""))
    return "\n".join(rows)[:5000]


def main():
    t = pickle.load(open(os.path.join(D, "tree_C.pkl"), "rb"))
    order = []

    def post(n):
        for c in n.children:
            post(c)
        if n.kind in KINDS and not (n.kind == "session" and " · commit " in n.title):
            order.append(n)
    post(t)
    t0, done, failed = time.time(), 0, 0
    for n in order:
        try:
            n.summary = gen(PROMPT.format(title=n.title[:150], listing=listing(n)))[:500]
            done += 1
        except Exception as e:  # noqa: BLE001
            failed += 1
            print("fail", n.id[:60], e, flush=True)
        if (done + failed) % 50 == 0:
            print(f"{done + failed}/{len(order)} in {time.time() - t0:.0f}s", flush=True)
    if done == 0:
        raise SystemExit("every summary call failed; not writing tree_D (fail loud)")
    pickle.dump(t, open(os.path.join(D, "tree_D.pkl"), "wb"))
    print(json.dumps({"summarized": done, "failed": failed, "seconds": round(time.time() - t0)}))


if __name__ == "__main__":
    main()
