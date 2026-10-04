"""N2: the Navigator, exactly as spike N0 measured it (arm C_hyb; docs/spike-n0-results.md).

BM25's top 16 leaves -> their project-tree units (deduplicated, filtered to the caller's
sections) -> one local-model yes/no per unit on its title and preview -> top k by probability.
If the local model is down or on CPU, the units come back in BM25 order and the result says so.
"""

from __future__ import annotations

import re

from .decider import Decider, Unavailable
from .store import Store

SEEDS = 16
TAU = 0.05
WORDS = re.compile(r"[A-Za-z][A-Za-z0-9-]{2,}")
QSTOP = set("where when which what did does we was were the and for our from into that this with get got "
            "how who why keep kept start started stop work worked".split())
SYS_NOUL = ("You route a search through an index of past work sessions on a Linux laptop. "
            "Given what is being looked for and one branch of the index, answer Yes if that branch "
            "probably contains it, otherwise No. Answer with one word.")


def terms(need: str) -> list[str]:
    return [w for w in WORDS.findall(need.lower()) if w not in QSTOP]


def view(node: dict) -> str:
    s = node["title"]
    if node.get("preview"):
        s += "\n" + node["preview"]
    return s[:700]


def allowed(node: dict, sections) -> bool:
    if not sections:
        return True
    return any((node.get("section") or "").startswith(p) for p in sections)


def navigate(store: Store, need: str, k: int = 3, sections=None, decider: Decider | None = None,
             use_model: bool = True) -> dict:
    """-> {'units': [{id, p, title, preview, sessions, tokens}], 'mode': 'reranked'|'keyword', 'note': str}"""
    hits = store.bm25(terms(need), SEEDS)
    units, seen = [], set()
    for lid, _ in hits:
        uid = store.unit_of(lid)
        if not uid or uid in seen:
            continue
        seen.add(uid)
        n = store.node(uid)
        if n and allowed(n, sections):
            units.append(n)
    note, mode = "", "keyword"
    if use_model and units:
        d = decider or Decider()
        h = d.health()
        if h["ok"]:
            try:
                for n in units:
                    n["p"] = d.noul(SYS_NOUL, f"Looking for: {need}\n\nBranch:\n{view(n)}\n\nDoes this branch probably contain it?")
                units = sorted((n for n in units if n["p"] >= TAU), key=lambda n: -n["p"])
                mode = "reranked"
            except Unavailable as e:
                note = f"local model failed mid-run ({e}); keyword order"
        else:
            note = f"{h['reason']}; keyword order"
    if not units and not hits:
        note = note or "no keyword matches"
    return {"units": units[:k], "mode": mode, "note": note, "seeds": len(seen)}
