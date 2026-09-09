# Design: Model Fallback Policy (Project A)

Status: DRAFT for Phase 2 Design, board `oal-fallback`.
Depends on: Requirements (complete, see attached requirements doc).

## Root cause of the triggering incident (confirmed, not assumed)

jarvis's live profile (`~/.config/omarchy-agent-launcher/agents/jarvis.json`)
currently shows `provider: local`, `auth: none`, model
`Qwen3.8-4B-Distill-Q4_K_M.gguf`, `created: 2026-09-09T08:47`. This is a
**manual downgrade performed today**, not an automatic fallback. jarvis's
`config.yaml` has **no `fallback_providers` block at all** — Hermes's
native per-turn fallback mechanism was never configured for jarvis, so
there was nothing to catch the fable5.1 quota exhaustion automatically.
The "ran out of tokens, dropped to local model" incident is a straight
consequence of a missing config, not a Hermes bug and not a scenario
Hermes's fallback mechanism was ever asked to handle.

## What Hermes's native fallback actually does (confirmed from official docs)

- Configured via top-level `fallback_providers:` list in `config.yaml`
  (ordered; each entry needs `provider` + `model`; first entry tried
  first). CLI helper: `hermes fallback add/list/remove/clear`.
- Triggers on: HTTP 429 (after retries) — but see below; 500/502/503
  (after retries); 401/403 (immediately); 404 (immediately); malformed/
  empty responses (repeated).
- **Critical nuance**: transient 429 rate limits (with a short
  `Retry-After`) do NOT trigger fallback — Hermes respects the explicit
  provider choice and just retries. Only **daily/monthly quota
  exhaustion, payment errors (402), and connection failures** bypass that
  gate. Hermes recognizes provider-specific quota-exhaustion phrases
  (e.g. Bedrock "daily limit", Vertex "RESOURCE_EXHAUSTED", generic
  "daily quota"/"quota_exceeded"). If Anthropic/OAuth-plan quota
  exhaustion isn't in that recognized set, that's the one thing worth a
  live-verification spike before trusting this blindly for Claude
  subscription plans specifically.
- **Reset-aware**: for subscription plans with known reset windows
  (explicitly named in the docs: "Claude Pro/Max's 5-hour blocks"),
  Hermes skips doomed retries and stays on the fallback until the
  primary's reset time passes, then automatically switches back next
  turn. This is exactly the "fable5.1 runs out, use opus5 until reset,
  then go back to fable5.1" behavior the user described — Hermes already
  implements it natively, IF fallback_providers is configured.
- Turn-scoped, not session-scoped: primary is retried fresh every new
  user message.
- Per current docs, fallback IS inherited by subagent delegation and cron
  jobs (this corrects an earlier, more limited search result found during
  Requirements — the full docs page is authoritative and says both
  "inherit the parent/configured fallback_providers chain").
- Auxiliary tasks (compression, vision, web extract, etc.) have their own
  independent `auxiliary.<task>.fallback_chain`, falling back through
  `fallback_providers` before Hermes's built-in discovery chain.
- Known real upstream bug (#32790, filed against Hermes 0.14.0): when an
  OAuth-backed plan (e.g. ChatGPT/Codex subscription) hits a 429 quota
  exhaustion, Hermes's error classification mislabels it in logs/chat as
  "no credentials, run hermes auth" instead of "quota exhausted, resets
  at X" — cosmetically confusing but does NOT prevent the fallback
  mechanism itself from firing correctly per the bug's own description
  (the reporter's 2-tier fallback chain "swallowed the impact on
  user-facing replies"). Not a blocker for this design; worth a note in
  the runbook so nobody panics and re-auths unnecessarily.

## Confirmed model identifiers in this environment

Provider `anthropic` catalog (from live models.dev cache) includes, among
others: `claude-fable-5-1`, `claude-opus-5`, `claude-sonnet-5`. jarvis's
local fallback is `Qwen3.8-4B-Distill-Q4_K_M.gguf` served via the local
llama.cpp/LM Studio-compatible server (provider `local` in this
launcher's terms, which Hermes sees as a `custom`/`lmstudio`-shaped
OpenAI-compatible endpoint at `http://127.0.0.1:8080/v1`).

## Decision: centrally-editable fallback chain (per user's explicit requirement)

User confirmed the fallback sequence changes week to week as better
models replace existing ones, across many vendor accounts (Anthropic,
OpenAI, xAI, OpenRouter, DeepSeek, z.ai, Modal.com), and must be editable
by the user AND jarvis, covering every model in the fleet — not a value
hardcoded per-agent.

**Design**: one shared JSON file,
`~/.config/omarchy-agent-launcher/fallback-policy.json`, holding one or
more **named chains** (most fleets need only one, "default", but naming
allows a future per-role override without a schema change):

```json
{
  "default": [
    {"provider": "anthropic", "model": "claude-fable-5-1", "note": "primary — ultra reasoning"},
    {"provider": "anthropic", "model": "claude-opus-5",    "note": "fallback 1"},
    {"provider": "anthropic", "model": "claude-sonnet-5",  "note": "fallback 2"},
    {"provider": "local",     "model": "Qwen3.8-4B-Distill-Q4_K_M.gguf", "note": "ultimate free local fallback"}
  ]
}
```

Each agent's JSON profile gets one new optional field:
`"fallback_chain": "default"` (name into the shared file; omitted =
no fallback configured, preserving today's opt-in behavior for agents
that shouldn't have one, e.g. short-lived worker subagents spun up with
an explicit cheap model on purpose).

`agent_provision` (in `lib/agents/hermes.sh`) gains logic: if the
profile's `fallback_chain` is set and resolves to a non-empty list in
`fallback-policy.json`, emit a top-level `fallback_providers:` block in
the generated `config.yaml`, **skipping the chain's own first entry if it
matches the agent's own primary provider+model** (avoids a redundant
self-fallback entry when an agent's primary already *is* the chain's
head, as jarvis's will be). Reuses the exact `provider_hermes`-style
mapping already used for the primary model line — no new provider-name
translation logic needed.

New CLI surface (`bin/omarchy-agent-launcher fallback ...`), mirroring
existing patterns (`providers list`, `backends list`):
- `fallback list` — print the current named chain(s) as a table.
- `fallback set <chain-name> <index> <provider> <model>` — replace one
  entry (or `fallback add`/`fallback remove --index N` for full CRUD).
- `fallback reorder <chain-name> <model-id> <new-index>` — move one
  entry, since the user's stated need is mostly reordering as new models
  win, not full replacement.
Every mutating subcommand re-provisions every agent whose profile
references the edited chain, consistent with this codebase's existing
profile -> provision -> config.yaml regeneration pattern (see
omarchy-agent-launcher-dev skill) — no agent should carry a stale
fallback chain after an edit.

jarvis, being the CoS with standing permission to manage the fleet, can
run these same CLI commands itself (it already runs
`omarchy-agent-launcher` for every other fleet operation per its own job
description) — no separate "jarvis-only" API needed.

## Coverage gaps Hermes doesn't handle automatically (still need policy, not code)

- **Subagent/cron override case**: while fallback IS inherited, a
  subagent/cron job explicitly given a *different* primary provider/model
  (for cost optimization, per Hermes's own `delegation.provider` /
  `delegation.model` override docs) does NOT get today's shared chain
  unless that override is itself drawn from `fallback-policy.json`. Policy:
  when delegating/cron-scheduling with an explicit override, prefer
  picking that override from the same `fallback-policy.json` list so the
  whole fleet stays consistent with "what's currently the best model,"
  rather than a hand-picked one-off id that can go stale.
- **Complete outage of every entry in the chain** (all four fail): Hermes
  falls through to normal error handling (retries, then a visible error).
  Policy: this is exactly the scenario that should raise a real desktop
  blocker notification (per the existing waterfall-kanban-pm /
  `omarchy-agent-launcher event ... blocker` pipeline) rather than
  failing silently in a terminal nobody's watching. This needs a shell
  hook or a periodic health-check (`agent:step`/`agent:end` hook counting
  consecutive fallback-chain exhaustion) — deferred to Implementation
  detail, not a schema change.

## Answers to Requirements-phase open questions

1. **OAuth quota exhaustion trigger shape**: unresolved by docs review
   alone — needs a live verification step in Implementation/Verification
   (deliberately trigger fable5.1's quota limit once fallback_providers is
   configured, confirm the switch actually fires). Flagged, not blocking
   Design sign-off.
2. **Symmetric vs. linear fallback for opus5/sonnet5**: resolved as
   **linear**, matching Hermes's actual mechanism (an ordered list, tried
   top to bottom) — true bidirectional "whichever ran out, use the other"
   isn't how Hermes's list works, and reproducing that would need a shell
   hook Hermes doesn't need for the reset-aware behavior it already has.
   Adopted chain: fable5.1 -> opus5 -> sonnet5 -> local qwen (per the
   example above), which satisfies "opus5's fallback is sonnet5" as one
   direction of that pair while keeping the config simple and native.
3. **Subagent/cron policy**: resolved above — inherited natively;
   override case handled via the "override from fallback-policy.json"
   convention.
4. **Desktop notification on fallback trigger**: resolved above — full
   chain exhaustion gets a blocker notification (rare, worth interrupting
   for); a single-hop fallback (still degraded but working) does NOT get
   a notification by default, to avoid alert fatigue — logged only. Open
   to revisiting if the user wants every hop surfaced.
5. **Centrally editable store**: resolved — `fallback-policy.json` +
   `fallback` CLI subcommand family, as designed above.
6. **Coordination with Project D's model-selector UI**: the same
   `fallback-policy.json` data (and the same model catalog data Project D
   already needs from `models_for_provider`) should back both features —
   Project D's popup can read/write the same file via the same CLI. Noted
   for Project D's own Design phase; no action needed here.

## Deliverable for Implementation phase

1. `fallback-policy.json` schema + seed file with the `default` chain
   above (based on today's actual accounts/models).
2. `lib/agents/hermes.sh`: `agent_provision` emits `fallback_providers:`
   from the profile's `fallback_chain` field.
3. New `lib/fallback.sh` (or extend `lib/providers.sh`) with the CLI
   subcommand family + re-provision-on-edit behavior.
4. Set jarvis's and this agent's (`agent-09072350`) profiles to
   `fallback_chain: "default"`, restore jarvis's primary provider back to
   `anthropic`/`claude-fable-5-1` (undoing today's manual downgrade) now
   that the fallback chain will catch future exhaustion automatically,
   re-provision, and verify the resulting config.yaml.
5. `bash -n` + `tests/run.sh` per the engineering skill's standing
   workflow.
6. Live verification: confirm `hermes fallback list` (or direct
   config.yaml read) on both agents shows the expected chain post-
   provision.
