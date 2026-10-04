"""Secret scrubbing for everything the memstore stores or hands out.

Vendored from session-harness harness/secrets.py (same author, MIT), which is itself a port of
omarchy-feedback lib/of_redact.py: the detection RULES, scan() and redact() only. Masked
output never matches again, so redact() is idempotent. Plus the memstore's own exclusions:
files whose contents are never read at all.
"""

from __future__ import annotations

import fnmatch
import math
import os
import re
from typing import Any

STARS = "********"
ELLIPSIS = "…"
COMPACT = {"card number", "bank account (IBAN)"}  # masked without their spaces
MAX_ALERT_WHERE = 20


def mask(value: str) -> str:
    v = value.strip()
    if len(v) <= 8:
        return STARS
    keep = 4 if len(v) >= 16 else 2
    return v[:keep] + ELLIPSIS + v[-keep:]


def _luhn(value: str) -> bool:
    digits = [int(c) for c in value if c.isdigit()]
    if not 13 <= len(digits) <= 19 or len(set(digits)) == 1:
        return False
    total = 0
    for i, d in enumerate(reversed(digits)):
        if i % 2:
            d = d * 2 - 9 if d > 4 else d * 2
        total += d
    return total % 10 == 0


def _entropy(value: str) -> float:
    counts: dict[str, int] = {}
    for c in value:
        counts[c] = counts.get(c, 0) + 1
    return -sum(n / len(value) * math.log2(n / len(value)) for n in counts.values())


def _random_token(value: str) -> bool:
    """Long, mixed-alphabet, high-entropy strings: probably a key nobody would type."""
    counts = [len(re.findall(p, value)) for p in (r"[a-z]", r"[A-Z]", r"[0-9]")]
    words = [seg for seg in re.split(r"[-_]", value) if re.fullmatch(r"[a-z]{3,}", seg)]
    return min(counts) >= 2 and _entropy(value) >= 4.0 and len(words) < 2


def _timestamp(value: str) -> bool:
    n = int(value)
    return (len(value) == 10 and 978_307_200 <= n <= 4_102_444_800) or (
        len(value) == 13 and 978_307_200_000 <= n <= 4_102_444_800_000
    )


# (kind, pattern, group, style, alert, check). Earlier rules win where matches overlap.
# style "stars" hides the whole value; "truncate" keeps the ends. alert = ask to rotate.
_V = r"[A-Za-z0-9._~+/=-]"
RULES: list[tuple[str, re.Pattern[str], int, str, bool, Any]] = [
    (
        "private key",
        re.compile(
            r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?"
            r"(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|$)"
        ),
        0,
        "stars",
        True,
        None,
    ),
    (
        "password in a URL",
        re.compile(r"\b[a-z][a-z0-9+.-]*://[^/\s:@]+:([^/\s@]+)@", re.I),
        1,
        "stars",
        True,
        None,
    ),
    (
        "password",
        re.compile(
            r"(?i)(?<![A-Za-z0-9])(?:--?)?(?:pass(?:word|wd|phrase)?|pwd|passcode|pin)="
            r"[\"']?([^\s\"'&,;]{3,})"
        ),
        1,
        "stars",
        True,
        None,
    ),
    (
        "password",
        re.compile(
            r"(?i)(?<![A-Za-z0-9])(?:pass(?:word|wd|phrase)?|pwd|passcode|pin)\s*:\s*[\"']?"
            r"([^\n|;,\"']{3,}?)(?=\s+[-—|·]\s|[\n|;,\"']|\s*$)"
        ),
        1,
        "stars",
        True,
        None,
    ),
    (
        "GitHub token",
        re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{40,255})\b"),
        0,
        "truncate",
        True,
        None,
    ),
    ("GitLab token", re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}\b"), 0, "truncate", True, None),
    ("Anthropic key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}"), 0, "truncate", True, None),
    ("xAI key", re.compile(r"\bxai-[A-Za-z0-9]{20,}\b"), 0, "truncate", True, None),
    (
        "OpenAI-style key",
        re.compile(r"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}"),
        0,
        "truncate",
        True,
        None,
    ),
    ("AWS access key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), 0, "truncate", True, None),
    ("Slack token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"), 0, "truncate", True, None),
    (
        "Stripe key",
        re.compile(r"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"),
        0,
        "truncate",
        True,
        None,
    ),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"), 0, "truncate", True, None),
    ("Hugging Face token", re.compile(r"\bhf_[A-Za-z0-9]{30,}\b"), 0, "truncate", True, None),
    ("npm token", re.compile(r"\bnpm_[A-Za-z0-9]{36}\b"), 0, "truncate", True, None),
    (
        "JSON web token",
        re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"),
        0,
        "truncate",
        True,
        None,
    ),
    (
        "secret",
        re.compile(
            r"(?i)(?<![A-Za-z0-9])(?:--?)?(?:api[_-]?key|apikey|secret(?:[_-]?key)?|"
            r"client[_-]?secret|access[_-]?token|auth[_-]?token|refresh[_-]?token|token|"
            r"private[_-]?key)\s*[:=]\s*[\"']?(" + _V + r"{8,})"
        ),
        1,
        "truncate",
        True,
        None,
    ),
    (
        "bearer token",
        re.compile(
            r"(?i)\b(?:bearer|authorization:\s*(?:bearer|token|basic))\s+(" + _V + r"{12,})"
        ),
        1,
        "truncate",
        True,
        None,
    ),
    (
        "secret in a URL",
        re.compile(
            r"(?i)[?&](?:access_token|id_token|token|api_key|apikey|key|sig|signature|secret|"
            r"password|auth|code)=([^&#\s]{6,})"
        ),
        1,
        "truncate",
        True,
        None,
    ),
    (
        "card number",
        re.compile(r"(?<![\d.])\d(?:[ -]?\d){12,18}(?![\d.])"),
        0,
        "truncate",
        True,
        _luhn,
    ),
    (
        "bank account (IBAN)",
        re.compile(r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,3})?\b"),
        0,
        "truncate",
        True,
        lambda v: len(v.replace(" ", "")) >= 15,
    ),
    ("ID number", re.compile(r"(?<![\d-])\d{3}-\d{2}-\d{4}(?![\d-])"), 0, "truncate", True, None),
    # No "/" and no ".": paths and file names are not keys.
    (
        "possible token",
        re.compile(r"(?<![A-Za-z0-9_+/=.-])[A-Za-z0-9_+=-]{32,}(?![A-Za-z0-9_+/=.-])"),
        0,
        "truncate",
        True,
        _random_token,
    ),
    (
        "identifier",
        re.compile(
            r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"
        ),
        0,
        "truncate",
        False,
        None,
    ),
    ("identifier", re.compile(r"\b[0-9a-f]{32,}\b"), 0, "truncate", False, None),
    (
        "account or ID number",
        re.compile(r"(?<![\d.])\d{9,18}(?![\d.])"),
        0,
        "truncate",
        False,
        lambda v: not _timestamp(v),
    ),
]


def scan(text: str) -> list[tuple[int, int, str, str, bool]]:
    """Spans (start, end, kind, style, alert) of sensitive parts of text, non-overlapping."""
    if not isinstance(text, str) or not text:
        return []
    spans: list[tuple[int, int, str, str, bool]] = []
    for kind, rx, group, style, alert, check in RULES:
        for m in rx.finditer(text):
            s, e = m.span(group)
            if s < 0 or e <= s:
                continue
            value = text[s:e]
            if ELLIPSIS in value or value == STARS:
                continue
            if check and not check(value):
                continue
            if any(s < b and a < e for a, b, *_ in spans):
                continue
            spans.append((s, e, kind, style, alert))
    return sorted(spans)


def redact(text: str, *, alert_only: bool = True) -> tuple[str, list[dict[str, Any]]]:
    """(clean text, findings). Findings: [{"kind", "masked", "alert"}], deduplicated.
    With `alert_only` (the default everywhere the harness scrubs) plain identifiers are
    reported nowhere and left untouched. Idempotent: masked output never matches again."""
    spans = [sp for sp in scan(text) if sp[4] or not alert_only]
    if not spans:
        return text, []
    out: list[str] = []
    pos = 0
    findings: list[dict[str, Any]] = []
    for s, e, kind, style, alert in spans:
        value = text[s:e]
        if kind in COMPACT:
            value = re.sub(r"[ -]", "", value)
        masked = STARS if style == "stars" else mask(value)
        out.append(text[pos:s])
        out.append(masked)
        pos = e
        f = {"kind": kind, "masked": masked, "alert": alert}
        if f not in findings:
            findings.append(f)
    out.append(text[pos:])
    return "".join(out), findings


# Files the Scribe never reads or snapshots, whatever their size or content (design §6).
EXCLUDE_GLOBS = (
    "*secrets.env", "*.env", ".env*", "*auth.json", "*auth.lock", "*.key", "*.pem", "*.p12", "*.pfx",
    "*id_rsa*", "*id_ed25519*", "*credentials*", "*token*", "*cookies*", "*.kdbx", "*keyring*",
    "*/gh/hosts.yml", "*/claude-profiles/profiles/*", "*/.ssh/*", "*/gnupg/*", "*Login Data*",
)


def excluded(path: str) -> bool:
    """True for a path whose contents must never be read into the memstore."""
    p = os.path.expanduser(path)
    name = os.path.basename(p)
    return any(fnmatch.fnmatch(p, g) or fnmatch.fnmatch(name, g) for g in EXCLUDE_GLOBS)


def clean(text: str) -> str:
    """Scrubbed text (alert-level secrets masked)."""
    return redact(text)[0] if text else ""
