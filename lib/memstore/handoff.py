"""N5: model-switch handoff (design section 10, the 09-28 failure).

Trigger: a profile's model/backend changes while its session is still alive (`rix setup`,
or any future fallback-policy switch, lib/rix.sh). The deterministic path below is the
only one exercised by tests and the only one on by default: it never calls a model, so a
switch is never blocked by one being slow, out of tokens, or a remote model tests must
never call. An "ask the outgoing model" path exists for interactive use only: it takes an
injectable `ask` callable, is never wired to a live Decider by default, and is never
exercised with a real backend in tests (section 10, points 1-2).
"""

from __future__ import annotations

import time
from datetime import datetime, timezone
from typing import Callable

from .store import Store

MAX_CITES = 8
RECENT_LEAVES = 40


def _session_leaves(store: Store, session_id: str, n: int = RECENT_LEAVES) -> list[dict]:
    return list(store.leaves_of(session_id))[-n:]


def _open_asks(leaves: list[dict], k: int = 3) -> list[str]:
    asks = [lf["text"].strip().splitlines()[0][:160] for lf in leaves
            if lf["role"] in ("user", "subagent_task") and lf["text"].strip() and not lf["text"].startswith("<")]
    return asks[-k:]


def _files_touched(leaves: list[dict], k: int = 12) -> list[str]:
    out: list[str] = []
    for lf in leaves:
        for f in lf.get("files") or []:
            if f not in out:
                out.append(f)
    return out[:k]


def _cited_units(store: Store, session_id: str, limit: int = MAX_CITES) -> list[str]:
    """Units from the last shape run that this session's leaves belong to, newest first.
    Empty if the tree has not been shaped since this session gained leaves: a switch must
    never wait on a shape run, so this degrades gracefully rather than blocking."""
    rows = store.db.execute("SELECT id, ts_max FROM nodes WHERE kind='unit' AND sessions LIKE ?",
                            (f'%"{session_id}"%',)).fetchall()
    rows.sort(key=lambda r: (r[1] or 0), reverse=True)
    return [r[0] for r in rows[:limit]]


def latest_session_for_agent(store: Store, agent: str, exclude_source: str = "shared") -> str | None:
    """The agent's own most recent session (never a handoff session itself)."""
    row = store.db.execute(
        "SELECT id FROM sessions WHERE agent=? AND source!=? AND ts_max IS NOT NULL "
        "ORDER BY ts_max DESC LIMIT 1", (agent, exclude_source)).fetchone()
    return row[0] if row else None


def deterministic_summary(store: Store, session_id: str, agent: str, from_model: str = "",
                          to_model: str = "") -> tuple[str, list[str]]:
    """Build a handoff body straight from the session subtree: the last N turns, open
    asks, files touched and cited unit ids. No model call (section 10, point 2 -- the
    default, always-tested path). -> (markdown body, cited unit ids)."""
    leaves = _session_leaves(store, session_id)
    ids = _cited_units(store, session_id)
    asks = _open_asks(leaves)
    files = _files_touched(leaves)
    switched = f" switched {from_model} -> {to_model}." if from_model or to_model else " switched models."
    lines = [f"Handoff for {agent}: session {session_id}{switched}"]
    if asks:
        lines.append("Last asks:")
        lines += [f"- {a}" for a in asks]
    if files:
        lines.append("Files touched: " + ", ".join(files))
    if ids:
        lines.append("Recent context:")
        lines += [f"- [[{i}]]" for i in ids]
    else:
        lines.append("(no shaped units yet for this session; run `omarchy-memstore shape` for citations)")
    return "\n".join(lines), ids


def model_summary(ask: Callable[[str], str], store: Store, session_id: str) -> str | None:
    """Optional: ask the outgoing model for its own handoff note (section 10, point 1).
    `ask` is an injectable callable (conversation text) -> note text; callers wire it to a
    live Decider themselves. Any failure here falls back to the deterministic summary, so
    an unreachable or out-of-tokens model never blocks the switch."""
    leaves = _session_leaves(store, session_id, n=20)
    convo = "\n".join(f"{lf['role']}: {lf['text'][:300]}" for lf in leaves)
    try:
        note = ask(convo)
    except Exception:  # noqa: BLE001 -- any failure here must fall back, never crash the switch
        return None
    return note.strip() if note and note.strip() else None


def build(store: Store, agent: str, session_id: str, from_model: str = "", to_model: str = "",
         ask: Callable[[str], str] | None = None) -> tuple[str, list[str]]:
    """-> (body, cited ids). Tries `ask` first only when one is given; always falls back
    to the deterministic summary, so a switch is never blocked by a model being
    unavailable (the usual case -- out of tokens, or a remote model never called in tests)."""
    body, ids = deterministic_summary(store, session_id, agent, from_model, to_model)
    if ask is not None:
        note = model_summary(ask, store, session_id)
        if note:
            cites = ("\n\nCited: " + ", ".join(f"[[{i}]]" for i in ids)) if ids else ""
            return note + cites, ids
    return body, ids


def write(store: Store, agent: str, session_id: str, from_model: str = "", to_model: str = "",
         ask: Callable[[str], str] | None = None, now: float | None = None) -> str:
    """Compose and store the handoff under shared/handoffs (storage conventions): a
    session `shared:handoff:<agent>:<YYYYmmddTHHMMSS>`, source "shared", one leaf with
    role "handoff" (scrubbed like any other leaf). Marks it the pending handoff for
    `agent`. -> the new handoff session id."""
    body, _ids = build(store, agent, session_id, from_model, to_model, ask)
    ts = now if now is not None else time.time()
    hid = f"shared:handoff:{agent}:{datetime.fromtimestamp(ts, tz=timezone.utc).strftime('%Y%m%dT%H%M%S')}"
    with store.batch():
        store.upsert_session({"id": hid, "source": "shared", "agent": agent,
                              "title": f"handoff for {agent}", "ts_min": ts, "ts_max": ts,
                              "section": "shared/handoffs"})
        store.add_leaf(f"{hid}:0", hid, ts, ts, "handoff", body)
        store.add_handoff(agent, hid, ts)
    return hid
