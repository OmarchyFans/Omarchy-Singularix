"""N1: decision calls on the local model (design §7.1). No text is generated for decisions.

noul(state, proposition) -> p(Yes)          one forward pass, max_tokens 1, logprobs renormalized
choice(state, question, options) -> [p]     asked twice with the options in reverse order and averaged,
                                            so an option's score does not depend on where it is listed
score(state, criterion, levels) -> [p]      choice over ordered levels (and .expected())
Backend: llama-server's OpenAI-compatible endpoint with logprobs (the running Omarchy local agent).
"""

from __future__ import annotations

import json
import math
import os
import time
import urllib.error
import urllib.request

CONFIG = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "omarchy-local-agent",
                      "config.json")


def server_url() -> str:
    url = os.environ.get("MEMSTORE_SERVER")
    if url:
        return url.rstrip("/")
    try:
        with open(CONFIG) as fh:
            return json.load(fh).get("server", "http://127.0.0.1:8080").rstrip("/")
    except (OSError, ValueError):
        return "http://127.0.0.1:8080"


class Unavailable(RuntimeError):
    """The local model can't be used (down, or too slow to be worth it)."""


class Decider:
    MIN_PROMPT_TPS = 200.0  # below this the server is on CPU; N0 measured ~600-1200 on the GPU, ~25 on CPU

    def __init__(self, url: str | None = None, timeout: float = 60.0):
        self.url = url or server_url()
        self.timeout = timeout
        self.calls = 0
        self.prompt_ms = 0.0
        self._health = None

    def _post(self, system: str, user: str, top: int = 20, max_tokens: int = 1, temperature: float = 0.0,
              logprobs: bool = True) -> dict:
        body = {"messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                "max_tokens": max_tokens, "temperature": temperature, "cache_prompt": True}
        if logprobs:
            body.update(logprobs=True, top_logprobs=top)
        req = urllib.request.Request(self.url + "/v1/chat/completions", json.dumps(body).encode(),
                                     {"content-type": "application/json"})
        try:
            r = json.load(urllib.request.urlopen(req, timeout=self.timeout))
        except (urllib.error.URLError, OSError, ValueError) as e:
            raise Unavailable(f"local model unreachable at {self.url}: {e}") from e
        t = r.get("timings") or {}
        self.calls += 1
        self.prompt_ms += t.get("prompt_ms", 0.0)
        return r

    def health(self) -> dict:
        """{'ok': bool, 'reason': str, 'prompt_tps': float}. Cached per process."""
        if self._health is None:
            try:
                t0 = time.time()
                r = self._post("Answer with one word.", "Health check " + "x " * 120 + "\nSay yes.", top=2)
                t = r.get("timings") or {}
                tps = t.get("prompt_per_second") or 0.0
                ok = tps >= self.MIN_PROMPT_TPS or (t.get("prompt_n", 0) < 50)  # tiny prompt: cache hit, can't tell
                self._health = {"ok": ok, "prompt_tps": round(tps, 1), "seconds": round(time.time() - t0, 2),
                                "reason": "ok" if ok else f"local model is slow ({tps:.0f} tok/s, probably on CPU)"}
            except Unavailable as e:
                self._health = {"ok": False, "prompt_tps": 0.0, "seconds": None, "reason": str(e)}
        return self._health

    def _dist(self, system: str, user: str, allowed: list[str]) -> list[float]:
        r = self._post(system, user)
        probs = {}
        for lp in r["choices"][0]["logprobs"]["content"][0]["top_logprobs"]:
            k = lp["token"].strip()
            if k.lower() in ("yes", "no"):
                k = k.capitalize()
            if k in allowed:
                probs[k] = probs.get(k, 0.0) + math.exp(lp["logprob"])
        z = sum(probs.values())
        return [probs.get(a, 0.0) / z if z else 1 / len(allowed) for a in allowed]

    def noul(self, system: str, user: str) -> float:
        return self._dist(system, user, ["Yes", "No"])[0]

    def choice(self, system: str, question: str, options: list[str]) -> list[float]:
        if len(options) > 26:
            raise ValueError("choice takes at most 26 options; group them first")
        letters = [chr(65 + i) for i in range(len(options))]
        scores = [0.0] * len(options)
        for order in (list(range(len(options))), list(reversed(range(len(options))))):
            lines = [f"{letters[k]}) {options[i]}" for k, i in enumerate(order)]
            p = self._dist(system, f"{question}\n\n" + "\n".join(lines) + "\n\nAnswer with one letter.", letters)
            for k, i in enumerate(order):
                scores[i] += p[k] / 2
        return scores

    def score(self, system: str, question: str, levels: list[str]) -> list[float]:
        return self.choice(system, question, levels)

    @staticmethod
    def expected(dist: list[float]) -> float:
        return sum(i * p for i, p in enumerate(dist))

    def generate(self, system: str, user: str, max_tokens: int = 700) -> str:
        r = self._post(system, user, max_tokens=max_tokens, temperature=0.2, logprobs=False)
        return r["choices"][0]["message"]["content"].strip()
