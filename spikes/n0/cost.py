#!/usr/bin/env python3
"""N0 spike: PageIndex-style search cost of each tree, in tokens (design 5.3).

R(v) = tokens of v's routing view (its children's title + preview); a node that fits the unit
budget is read directly at cost S(v). tree_cost(v) = R(v) + max over children tree_cost(c).
Reports the worst case (root) and the average cost to reach a unit (routing on its path + S).
"""

import json
import os
import pickle
import sys

sys.setrecursionlimit(10000)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from trees import Node  # noqa: E402,F401

D = os.environ.get("N0_DIR", os.path.expanduser("~/.local/share/omarchy-memstore/spike-n0"))
UNIT = 3500


def view_tokens(n):
    return (len(n.title) + len(n.preview or "") + len(n.summary or "")) // 4 + 8


def measure(root):
    costs, routing = [], {}

    def tree_cost(v):
        if v.tokens <= UNIT or not v.children:
            return v.tokens
        r = sum(view_tokens(c) for c in v.children)
        routing[v.id] = r
        return r + max(tree_cost(c) for c in v.children)

    worst = tree_cost(root)

    def walk(v, acc):
        if v.tokens <= UNIT or not v.children:
            costs.append(acc + v.tokens)
            return
        for c in v.children:
            walk(c, acc + routing[v.id])
    walk(root, 0)
    return {"worst_case_tokens": worst, "avg_tokens_to_unit": round(sum(costs) / len(costs)),
            "units_reached": len(costs), "normalized_worst": round(worst / root.tokens, 5)}


for name in sys.argv[1:] or ["B", "C"]:
    p = os.path.join(D, f"tree_{name}.pkl")
    if os.path.exists(p):
        print(name, json.dumps(measure(pickle.load(open(p, "rb")))))
