"""Per-turn context: the local model crawls the memstore before every Rix turn and offers what
it finds to whatever model Rix runs on (Hermes `pre_llm_call` shell hook; the reply's
`{"context": ...}` is added to that turn's user message).

It stays quiet unless it has something good: short messages ("ok", "go") get nothing, keyword-only
retrieval (local model down or on CPU) gets nothing, only units the local model rates p >= MIN_P
are offered, at most MAX_UNITS per turn in a compact packet, and a unit already offered earlier
in the same session is not offered again. Any failure returns no context: it never blocks a turn.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time

from .navigator import navigate, terms
from .packet import BUDGETS, compile_packet
from .store import DEFAULT_DIR, Store

MIN_P = 0.5
MAX_UNITS = 2
MIN_CHARS = 12
STATE_DIR = os.path.join(DEFAULT_DIR, "context-state")
START = "<memstore-context>"
END = "</memstore-context>"
BLOCK = re.compile(re.escape(START) + r".*?" + re.escape(END), re.S)
BUDGETS.setdefault("ambient", {"total": 1800, "facts": 1400})


def strip(text: str) -> str:
    """Remove injected context blocks, so the recorder never stores its own packets back."""
    return BLOCK.sub("", text or "").strip() if START in (text or "") else (text or "")


def _state_path(agent: str, session: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", f"{agent}--{session or 'none'}")[:150]
    return os.path.join(STATE_DIR, safe + ".json")


def _seen(agent: str, session: str) -> set:
    try:
        with open(_state_path(agent, session)) as fh:
            return set(json.load(fh))
    except (OSError, ValueError):
        return set()


def _remember(agent: str, session: str, ids) -> None:
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    seen = sorted(_seen(agent, session) | set(ids))[-200:]
    old = os.umask(0o077)
    try:
        with open(_state_path(agent, session), "w") as fh:
            json.dump(seen, fh)
    finally:
        os.umask(old)
    cutoff = time.time() - 7 * 86400
    for f in os.listdir(STATE_DIR):
        p = os.path.join(STATE_DIR, f)
        try:
            if os.path.getmtime(p) < cutoff:
                os.remove(p)
        except OSError:
            pass


def ambient(store: Store, message: str, agent: str = "rix", session: str = "", decider=None) -> dict:
    """-> {'context': str ('' when there is nothing worth offering), 'ids': [...], 'why': str}"""
    message = strip(message)
    if len(message.strip()) < MIN_CHARS or len(terms(message)) < 2:
        return {"context": "", "ids": [], "why": "message too short to search on"}
    nav = navigate(store, message, k=6, decider=decider)
    if nav["mode"] != "reranked":
        return {"context": "", "ids": [], "why": f"keyword only ({nav['note']}); offering nothing"}
    seen = _seen(agent, session)
    units = [u for u in nav["units"] if u.get("p", 0) >= MIN_P and u["id"] not in seen][:MAX_UNITS]
    if not units:
        return {"context": "", "ids": [], "why": "nothing relevant enough, or already offered this session"}
    pk = compile_packet(store, message, {"units": units, "mode": "reranked", "note": ""}, consumer="ambient")
    _remember(agent, session, pk["ids"])
    head = ("Background from this machine's memory, offered automatically by the local model. "
            "Use it only if it helps with the message above; cite [[ids]] for anything you take from it. "
            "More: `omarchy-memstore packet \"...\"`, `omarchy-memstore session <id> --full`.")
    return {"context": f"{START}\n{head}\n\n{pk['text']}\n{END}", "ids": pk["ids"], "why": "ok"}


def hook_main(argv=None) -> int:
    """Hermes shell-hook entry: JSON payload on stdin, `{"context": ...}` or `{}` on stdout. Never fails."""
    agent = "rix"
    args = list(argv or [])
    if "--agent" in args and args.index("--agent") + 1 < len(args):
        agent = args[args.index("--agent") + 1]
    try:
        payload = json.load(sys.stdin)
        extra = payload.get("extra") or {}
        msg = extra.get("user_message") or ""
        if isinstance(msg, list):  # multimodal content parts
            msg = " ".join(p.get("text", "") for p in msg if isinstance(p, dict))
        out = ambient(Store(os.environ.get("MEMSTORE_DB") or None), str(msg), agent,
                      str(payload.get("session_id") or extra.get("session_id") or ""))
        print(json.dumps({"context": out["context"]} if out["context"] else {}))
    except Exception:  # noqa: BLE001 -- fail open: a broken hook must never block Rix's turn
        print("{}")
    return 0
