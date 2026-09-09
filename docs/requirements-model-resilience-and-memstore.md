# Requirements: Model Resilience, History, and PageIndex Memstore

Status: DRAFT — awaiting user approval. Nothing described here has been built.
Scope confirmed with user: 4 separate projects, build order A -> D -> B -> C
(A can run in parallel with D; C depends on B).

---

## Project A: Model outage / fallback policy  (BUILD FIRST)

### Problem
Fable5.1 (jarvis's model) ran out of tokens mid-session with no defined
fallback behavior. Need a documented, enforced chain: fable5.1 -> opus5 <-> sonnet5
(mutual fallback) -> local qwen3.8-4B-distilled (ultimate free local fallback).

### What already exists in Hermes (confirmed via docs, not yet inspected live
in this agent's own config.yaml)
- Native `fallback_providers` list in `config.yaml`. Auto-triggers per-turn on:
  429 (after retries), 500/502/503 (after retries), 401/403 (immediate),
  malformed/empty responses (repeated). Resets each new user turn (tries
  primary again).
- Credential pools (rotate multiple keys for the *same* provider) tried
  before cross-provider fallback.
- **Gaps confirmed in docs**: fallback does NOT apply to auxiliary tasks
  (vision/compression/web extract — these have their own independent
  provider chain, though it consults the main `fallback_providers` chain
  before falling back to built-in discovery). **Correction from Design
  phase**: subagent delegation and cron jobs DO inherit the parent/
  configured `fallback_providers` chain per the authoritative docs page
  (an earlier, more limited web-search snippet found during initial
  Requirements research was wrong on this point — see
  `docs/design-project-a-fallback-policy.md` for the corrected, sourced
  detail).
- Fallback resets prompt cache -> first message on both failover and
  recovery is full-price, uncached. Worth knowing, not a blocker.
- "Ran out of tokens" for an OAuth/subscription model (fable5.1) may not be
  a 429-shaped error Hermes fallback logic recognizes as such — this needs
  live verification, not assumed.

### User clarification (2026-09-09)
User holds multiple vendor accounts with frontier-level models beyond the
original four (Anthropic, OpenAI, xAI, OpenRouter, DeepSeek, z.ai, plus
Modal.com for self-hosted GPU backends). The fallback *sequence* is
explicitly volatile — "changes from week to week as new better performing
models replace the existing ones" — so it must be a **user/jarvis-editable
ordered list covering every model in the agent launcher**, not a value
hardcoded into this doc or into any one agent's config. This pushes the
design toward a single shared, centrally-editable fallback-policy artifact
(e.g. one file/table the launcher reads and every agent's config.yaml is
generated from) rather than per-agent hand-set `fallback_providers` lists
that drift out of sync with each other.

### Open questions to resolve in Design phase
1. Is jarvis's fable5.1 auth OAuth/subscription-based? If so, does a quota
   exhaustion surface as HTTP 429, or as some other failure shape Hermes's
   fallback trigger list doesn't catch? (Directly relevant to why this
   incident wasn't auto-handled.)
2. Should the fallback chain be symmetric (opus5 <-> sonnet5 whichever ran
   out falls back to the other) or fable5.1 -> opus5 -> sonnet5 -> qwen3.8
   strictly linear? User said "the fallback from opus5 is sonnet5 or vice
   versa" — needs to be pinned down as one specific direction or true
   mutual fallback (which Hermes's single ordered list doesn't directly
   support — would need per-model conditional logic, likely a shell hook).
3. Subagent delegation and cron jobs need an explicit written policy since
   Hermes provides none automatically — draft in Design phase.
4. Does the user want a *desktop notification* when fallback triggers (so
   they know a session degraded to a cheaper/slower model), separate from
   just it silently working? (Ties to existing waterfall-kanban-pm
   notification pipeline already used for blockers.)
5. Design a single editable fallback-sequence store (format TBD: JSON/YAML
   under `~/.config/omarchy-agent-launcher/`) that both the user (via CLI/
   dashboard) and jarvis (programmatically) can reorder, covering every
   vendor account currently configured — and a mechanism to regenerate
   every affected agent's `fallback_providers` config.yaml block from it,
   consistent with this codebase's existing profile -> provision ->
   config.yaml regeneration pattern (see omarchy-agent-launcher-dev skill).
6. Should Project D's model-selector matrix UI double as the editor for
   this fallback sequence (drag-to-reorder in the same popup), or is that
   a separate CLI/dashboard surface? Worth deciding jointly with Project D
   since they share the same underlying model-catalog data.

### Deliverable
Written fallback policy (doc) + config.yaml `fallback_providers` entries
per agent + any shell-hook logic needed for cases Hermes doesn't cover
natively + verification that a real triggered fallback actually works
(live test, not just config review).

---

## Project D: Model-selector UI with cost/perf matrix (PARALLEL WITH A)

### Requirement
Click the model name in an agent's terminal/dashboard -> popup showing a
matrix of available models: tokens/sec, cost per M tokens in/out
(including KV-cache cost), model name, quantization. User selects, session
continues on the new model.

### What already exists
- `lib/models.sh`: live model catalog from models.dev
  (`models_for_provider`), refreshed daily, gives id/name/input-cost/
  output-cost/context/release per model. Cache read/write cache pricing is
  present in `usage.sh`'s price map (`cache_read`, `cache_write`) but NOT
  currently surfaced in `models_for_provider`'s output — would need adding.
- **Gap**: no tokens/sec (throughput) or quantization data anywhere in the
  codebase or models.dev's schema as sampled. This is a new data source
  question for Design phase — options: a static hand-maintained table,
  live benchmarking, or a third-party benchmark API (e.g. artificial
  analysis-style). Needs research before Design can finish.
- Dashboard: `components/AgentsTab.qml` shows model as plain text
  (`row.agent.backend + "/" + row.agent.model`), not clickable. No popup
  component for model selection currently exists; `PanelDropdown.qml` and
  `ConfirmDialog` exist as UI patterns to reuse.
- **Runtime fact (from skill notes)**: a running Hermes CLI session does
  NOT hot-reload config.yaml — switching a model requires either an
  in-session `/model` command (if Hermes supports it — needs verification)
  or a stop+relaunch, which would lose in-memory context (though full-text
  history from Project B would let it resume from stored history).

### Open questions
1. Confirmed: UI location decided "during design" — need to actually look
   at whether Hermes's CLI has a live `/model` switch command (may make
   this much simpler than a dashboard popup) before committing to a
   QuickShell popup implementation.
2. Where does tokens/sec + quantization data come from?
3. Does switching model mid-session need to preserve conversation context
   automatically (ties directly to Project B), or is losing in-memory
   context (but keeping full-text history retrievable) acceptable?
4. Per user clarification on Project C: a model switch is the trigger
   point for the outgoing model to write a PageIndex handoff note. This
   UI is therefore the natural place to invoke that write (e.g. "prepare
   handoff" step before the popup confirms the switch) — Project D's
   implementation should not be finalized independently of Project C's
   handoff-note mechanism; coordinate the two designs even though C
   doesn't start implementation until later.

### Deliverable
Design doc answering the above, then implementation only after Design
approval.

---

## Project B: Full-text chat history storage (FOUNDATION for C)

### Problem confirmed via research
This is not just a preference — it's compensating for a **known, currently
open Hermes upstream bug** (GitHub issues #86234, #38392, #10719 and
related PRs). Context compaction in Hermes's `agent/context_compressor.py`
**physically deletes** original message rows once compacted; the
`compacted=1` non-destructive marker was designed but never actually wired
up end-to-end (confirmed via issue thread as of latest verification
checked). A lossy LLM-generated summary replaces the deleted turns. Hermes
maintainers acknowledge this as data loss, not yet fixed upstream.

### What already exists
- `state.db`'s `messages` table stores full untruncated content per
  message — this is the correct source table, while it still holds data.
- Hermes's `agent:end`/`agent:start` hooks truncate `message`/`response`
  to 500 chars — NOT sufficient for full-text capture on their own.
- Compression threshold is fixed at 85% of model context length; fires
  automatically once `len(history) >= 4`. Not configurable per the docs
  sampled (needs confirming — may be a hidden config key).

### Design direction (not yet approved)
Two viable approaches, to weigh in Design phase:
1. **Continuous export**: a periodic (e.g. cron, or a plugin hook on
   `agent:step`/`agent:end`) job that reads new rows from `state.db`'s
   `messages` table and appends them to an external append-only store,
   run frequently enough that compaction (which needs `len(history) >= 4`
   and 85% context fill) can't outrun the export window.
2. **Disable/raise Hermes's internal compression threshold** per agent
   (if configurable) as a stopgap, relying on Hermes's native SQLite
   `messages` table as the full-text store directly — simpler, but doesn't
   solve unbounded context growth or the eventual need for search across
   history, which Project C (PageIndex) exists to solve anyway.
Recommendation for Design phase to evaluate: do (1) regardless, since it's
also the ingestion pipeline Project C's PageIndex needs — a scheduled
exporter that feeds PageIndex's index-build step is likely the same
component as the full-text archival mechanism.

### Open questions
1. Is Hermes's compression threshold/enable-flag configurable per-agent?
   (Direct research needed before Design.)
2. Retention: forever, or a rotation window? Where does the archive live
   (local disk path, size budget)?
3. Does full-text storage apply retroactively to existing sessions
   (`state.db` still has them intact where compaction hasn't run yet), or
   only prospectively from when this ships?

### Deliverable
Design doc + a working exporter (state.db -> external append-only
full-text store) verified against a live session, before Project C starts.

---

## Project C: PageIndex encrypted memstore + jarvis gatekeeping (DEPENDS ON B)

### Purpose, clarified by user (2026-09-09) — read this before Design
The primary problem PageIndex solves is **NOT** "store chat history
somewhere encrypted." It solves two specific, higher-value problems:

1. **Drift from lossy compaction ("the telephone game")**: every time
   Hermes compacts a session into a summary (see Project B's findings —
   this already loses fidelity even before the upstream data-loss bug is
   fixed), context degrades a little more each time it's re-summarized.
   PageIndex, being a full-text hierarchical index rather than another
   lossy summary layer, is the mechanism that stops that degradation —
   a model resuming work reasons over the original structured index, not
   over a summary-of-a-summary.
2. **Low-friction model handoff**: when switching models (whether via
   Project D's UI or an automatic Project A fallback), the **outgoing
   model must write a brief, explicit handoff note** — pointing at
   specific sections/nodes in that agent's PageIndex — telling the
   incoming model exactly what to read to get up to speed. This is an
   active behavior the model performs at hand-off time, not a passive
   background export. Needs a concrete trigger point (a hook on
   model-switch, or a convention baked into every agent's system prompt)
   and a defined handoff-note format/location so any model can reliably
   find and consume it.
3. **Cross-session solved-problems knowledge base**: PageIndex sections
   should accumulate hard-won lessons and solutions ("we already solved
   this once") so a future session (any agent, or jarvis on their behalf)
   can retrieve the existing solution instead of re-deriving it —
   directly reducing token spend on recurring problem classes. This is
   conceptually the same pattern as this Hermes profile's own skill
   system (skill_manage/skill_view), but scoped to project- and
   problem-specific knowledge rather than reusable general procedures —
   worth explicitly deciding in Design whether these should be two
   separate mechanisms or whether skills and PageIndex should overlap /
   cross-reference each other.

Encryption-at-rest and jarvis's cross-agent gatekeeping (described below)
remain real requirements, but they are a property of *how* this store is
protected, not the reason it exists.

### What PageIndex actually is (confirmed, not assumed)
Open-source (VectifyAI/PageIndex, MIT license, ~35k GitHub stars). Builds a
hierarchical tree index over documents/corpora and retrieves via LLM
reasoning over that tree instead of vector similarity search — no vector
DB, no chunking; retrieval is traceable/explainable. As of Aug 2026 it
ships `pip install pageindex` with a **local mode**: index, retrieve, and
chat entirely on-machine with your own LLM key (no cloud dependency
required) — directly usable for a private, local, per-agent memstore.
There's also a "PageIndex File System" layer for reasoning across an
entire multi-document corpus, which maps well onto "index every agent's
full chat history as a corpus."

### Design intent (from user's description, to formalize in Design phase)
- Each agent gets its own sandboxed section of the PageIndex store,
  populated from Project B's full-text export.
- jarvis has cross-section read access; other agents do not see each
  other's sections directly.
- An agent wanting cross-agent info asks jarvis, who searches on its
  behalf and gatekeeps (decides what's safe to reveal, filtering
  proprietary/sensitive info) — using the **local model** for that
  gatekeeping work specifically (not a cloud model), per user's design.
- Store is encrypted at rest. **Confirmed unlock mechanism**: NOT a static
  key the agent holds. Instead, an unlock/decrypt request opens a Chromium
  tab where the user authenticates via their password manager's passkey
  (WebAuthn) feature — i.e., app-layer encryption gated by a live WebAuthn
  ceremony, not a stored secret.

### Open questions (substantial — this is the least-specified project)
1. **WebAuthn architecture**: passkeys are bound to a relying party (RP)
   origin (a real or local domain) and normally authenticate a *login*,
   not directly "release a symmetric decryption key." Realistic pattern:
   run a small local web service (RP) that (a) performs the WebAuthn
   ceremony, (b) on success, uses a server-side wrapped key (e.g. a key
   encrypted with a passkey-derived credential, or held in an OS
   keyring/TPM and simply gated behind the WebAuthn check) to decrypt the
   memstore for that request. This needs real design — "passkey unlocks a
   file" is not an out-of-the-box browser API; it needs a local
   authenticating service in between. Needs a research/spike in Design
   phase before committing to an implementation approach.
2. Per-request unlock (every agent read triggers a Chromium tab), or
   unlock-once-per-session/timeboxed grant? A per-read WebAuthn prompt
   would make the memstore nearly unusable for routine jarvis lookups —
   needs explicit UX decision.
3. What counts as "proprietary" for jarvis's gatekeeping filter — a rule
   list, a classifier, or jarvis's own judgment per-request? Needs
   examples from the user to design the filter.
4. Does PageIndex's local mode support incremental updates (append new
   chat turns) or is it a batch reindex — matters a lot for freshness vs.
   cost if we're indexing continuously.
5. Per-agent PageIndex "section" — separate PageIndex instances per agent
   home, or one instance with an access-control layer bolted on top? The
   project itself doesn't ship multi-tenant ACLs; this is something we'd
   build.

### Deliverable
Design doc resolving the above (with a WebAuthn spike), THEN
implementation — this is explicitly the most speculative project and
should not start Design until B ships and A+D free up capacity.
