# Changelog

The dashboard reads the newest sections of this file to tell you what changed
when an update is available. Keep one short line per bullet.

## 0.14.0 — Roles and model policy (2026-09-14)

- **Profile field `harness_role`** (`orchestrator|reasoning|coding|local`, default `coding`):
  `harness_register_rix PROFILE [REPO] [SLOTS] [PROJECT_ID] [ROLE]` now passes `--role`
  (`ROLE`, else the profile's `harness_role`, else `coding`), `--model` (the profile's own
  model, else its backend's), and `--vendor` (the profile's provider id for a `kind=provider`
  backend, or the registry backend's own id for a `kind=endpoint` one) on `harness session
  add`, so the harness can derive `tier`/`ip_safe` itself. `omarchy-agent-launcher harness
  register PROFILE [--project ID] [--slots N] [--role R]` and a new `omarchy-agent-launcher
  harness role PROFILE ROLE` (persists the field, pushes `session set --role` to every
  already-registered live session for that profile). A harness refusal — an IP-unsafe vendor
  asking for `orchestrator`, which the harness (not this launcher) decides — surfaces its
  stderr verbatim rather than being pre-judged in bash.
- **Orchestration packets**: `harness_dispatch_packet` detects `<node>.SPLIT.md`/`.PM.md`/
  `.COMPOSE.md` (or an inbox row carrying `command`, tolerating its absence), claims/delegates
  them exactly like a work packet but asks for exactly one JSON patch in reply, and skips
  (defensively — the harness only ever assigns these to an `orchestrator`-tier session) one
  for a profile/session that isn't registered orchestrator. `harness_dispatch_reap` extracts
  the LAST top-level JSON object from the delegate's reply (`harness_extract_last_json` —
  see the Wave L1 bullet below for how it actually finds it) and calls `harness receipt
  --command SPLIT|PM|COMPOSE --patch-file F --status done`, or `--status failed --summary
  "…"` when no JSON parsed.
- **`harness_status_json`**: gains `roles` (every registered Rix session's
  `{session, project, role, tier, model, vendor, ip_safe}` from `overview.json`) and
  `orchestrator` (`overview.json`'s `projects[].orchestrator`, keyed by project id); fixes
  `overview_path` to always be the real `harness_data_dir/overview.json` path, never `null`.
- **Rix skill** (`skills/rix/SKILL.md`, → 0.14.0): new "Harness — pick up any task fresh"
  section — `harness brief`/`harness show --node` as the first command on any packet, roles
  and IP-safety rules in plain words, how to answer an orchestration packet (one JSON patch,
  nothing else — the launcher writes the receipt), `harness policy show`, `harness project
  set --role/--ip-class`.
- **`docs/HARNESS.md`**: new "Roles and model policy" section (the two axes, the three
  default chains, how to override per profile/project/node, IP classes, the orchestration
  packet flow, `harness brief`).
- **Wave L1 fixes (adversarial review)** — BLOCKER: a real-shaped inbox row (`node` carrying the
  `.SPLIT`/`.PM`/`.COMPOSE` suffix, no `command` field of its own) now dispatches and receipts
  against the bare node id; `harness receipt --node P0.SPLIT` ("unknown node", never recorded,
  re-dispatched forever) can no longer happen.
- A throttled orchestration delegate now reaps to `--status throttled --retry-after-sec`, never
  `--status failed`; if the harness CLI refuses that receipt, the launcher un-claims the packet
  and backs the session off (a new per-session backoff file, honoured by the dispatch loop) so it
  isn't immediately re-dispatched onto the same 429'd backend.
- `cost --json`'s real shape — `pending_approvals` (list or map) and `pending_approval` — is read
  correctly everywhere this file reads pending requests (it used to read only a legacy `pending`
  key, silently wiping the requested-budget dedup and breaking `harness approve` without
  `--request`).
- `harness decline` now calls the harness CLI's own `decline` subcommand first, falling back to
  the `POST /cost/decline` endpoint only when the CLI says the subcommand doesn't exist yet
  (argparse's "invalid choice") — a genuine refusal from the CLI is surfaced as-is, never papered
  over with a curl POST.
- The dispatch cost gate now subtracts `reserved_usd` from `remaining_usd` (money already reserved
  for an in-flight call isn't free to spend twice) and refuses — without ever POSTing
  `cost/request`, since a cap can't be approved away — a node that would push a project's metered
  spend over a positive `daily_cap_usd`.
- `harness role`/`harness_set_role` now send `--role`/`--tier` PAIRED on every `harness session
  set` (a new `harness_session_sync` helper, also used by a new best-effort `harness_resync_profile`
  called from `harness register` and wherever a profile's backend changes): sending `--role` alone
  used to get refused by the harness's `validate_role` whenever a session's previously-recorded
  tier disagreed, silently no-op'ing the role change. The orchestration dispatch guard now trusts
  only the harness's own session record (`tier`/`role` from `overview.json`), never a profile's
  local (possibly stale) `harness_role` field.
- `harness_extract_last_json` is rewritten on python3's own JSON tokenizer (falling back to the
  original bracket-counting bash algorithm only when python3 is missing): immune to a stray
  unmatched brace in prose later closed by an unrelated one (used to swallow the real object) and
  to an odd number of stray quote characters before it (used to desync manual in-string tracking);
  a reply that is only a top-level JSON array is now rejected outright instead of silently
  returning one of its elements.
- Minor: a failed orchestration receipt now says whether the delegate itself died (`"delegate
  exited …"`) or just replied with no JSON, instead of one message for both; dispatch resolves an
  explicit-model-less profile's model the same way everywhere (`harness_profile_model`);
  `harness_dispatch_heartbeat` now refreshes a still-claimed packet's mtime every sweep so the
  harness's claim-timeout safety net can't reclaim a delegate running longer than that; a project
  entry with `orchestrator` set but no `id` no longer corrupts `harness_status_json`'s orchestrator
  map; a dispatched delegate's environment now carries `$HARNESS_SESSION`/`$HARNESS_PROJECT`, and
  its packet trailer names `harness brief` or `harness show` as the first command to run.
- New `omarchy-agent-launcher harness assign PROJECT NODE [--session SID]` (PlanTab's "Assign to
  Rix" and the Rix skill both already called this; the CLI had no case for it): `--session`
  defaults to the first idle `rix` session on the project when omitted.
- `skills/rix/SKILL.md`: fixed `harness ack`/`harness fail` to their real signatures (`--project
  ID --node N [--evidence E]` / `--project ID --node N --reason "…"`), and listed `harness assign`
  under Rix's own CLI.

## 0.13.0 — Rix × session-harness (2026-09-13)

- **Plan tab** (`components/PlanTab.qml`): renders every served project's task queue from the
  session-harness's `overview.json` (`FileView`, watched) plus a `tail -F` on `events.jsonl` for
  animation deltas — no network from QML. Header: project filter, agent filter, state chips
  (ready/running/blocked/done/failed), residual + spent/approved USD, "Open full Gantt". Rows
  group by project, one per unfinished edge, animated on assign/done/release. Sessions lane at
  the bottom. Approval banner when a project has a `pending_approval` (model, estimate, reason,
  Approve/Decline). Fallback text + "Start harness" button when the harness isn't running. The
  dashboard nav gets a "Plan" tab with an urgent badge showing the pending-approval count
  (`Dashboard.qml`).
- **`lib/harness.sh`**: `harness_bin` (settings → PATH → `~/Work/session-harness/.venv/bin/harness`),
  `harness_serve_start`/`harness_serve_stop` (own `harness serve --all` + the launcher's own
  dispatch loop under `~/.local/state/omarchy-agent-launcher/harness/`), `harness_register_rix`
  (now `[--slots N]`, one session per slot), `harness_cost_class`, `harness_estimate_usd`,
  `harness_dispatch_once`/`_loop`/`_reap`, `harness_approve`/`harness_decline`,
  `harness_status_json` (file/pid-based, never blocks on the network beyond one 1s status ping).
- **`omarchy-agent-launcher harness`** subcommand: `status|serve|stop|open|projects|
  register PROFILE [REPO] [--slots N]|dispatch [--once]|approve PROJECT USD [REASON]
  [--request ID]|decline PROJECT|inbox PROFILE`. `settings.json:harness_autostart` (default
  `false`) starts `harness serve` automatically on `rix chat`/`rix open`.
- **Cost class fails CLOSED** (adversarial review, wave 5b): `harness_backend_cost_class` is
  `free` only for the local GPU and `subscription` only for an OAuth provider the user is
  actually signed in to — an API key, a missing/unresolvable backend, an unsigned OAuth
  provider, or *any* auth this launcher doesn't recognize is `metered`. `harness_cost_class`
  additionally walks the profile's Hermes `fallback_chain` (`harness_chain_metered_hop`): a
  chain that can hop to an api-key provider registers the whole profile `metered` even when
  its primary backend is free or a signed-in subscription.
- **Detached dispatch + reaper**: `harness_dispatch_packet` no longer blocks on
  `delegate --wait` — it launches a detached `delegate` job (recorded under
  `$OAL_STATE/harness/jobs/<project>/<node>.json`) and `harness_dispatch_reap` writes the
  `harness receipt` (now carrying the worker's actual `--usd/--tokens-in/--tokens-out`, plus
  `--model/--vendor`) once the worker's run log lands, classifying `done`/`failed`/`throttled`
  from the real exit code. `settings.json:harness_workers` (default 4) caps how many run at
  once across a whole sweep.
- **Worker liveness protocol** (assign → claim → pid/heartbeat → receipt → clear): fixes a
  live defect where a Rix session went `stale` 45s into a multi-minute delegate job, had its
  node released and re-solved by the harness, while the delegate kept running orphaned.
  `harness_dispatch_packet` now records the delegate's tmux pid (`harness session set
  --project P --session S --pid N`) or heartbeats it (`harness heartbeat --project P
  --session S [--pid N] [--note]`); `harness_dispatch_heartbeat` re-heartbeats every running
  job each sweep, or stops the delegate and `--clear-pid`s the session if the harness
  withdrew its claimed packet (`.md.claimed.cancelled`); `harness_dispatch_reap` also
  `--clear-pid`s and `harness_job_forget`s the transient `hns-*` agent once a receipt is
  written, so scratch agents never pile up. `register --project ID` now uses that project's
  own repo as cwd instead of `$PWD`. `harness sessions --json` gains `pid`/`heartbeat_age`.
- **Cost-gated dispatch, deduped**: a `metered` Rix profile's packet is never run until its
  estimated price (chars/4 tokens × `settings.json:harness_turn_factor`, default 20, × models.dev
  price) fits the project's remaining budget; short by even a cent, or unpriced, it posts one
  `cost/request` (deduped in `$OAL_STATE/harness/requested.txt`, pruned once funded, resolved,
  or no longer pending) and waits — never guesses `$0`. A direct `delegate`/`rix ask`/
  `rix chat --yolo` on a metered backend needs a human-typed `--approved-usd` (or an
  interactive y/N in `rix chat`) or it stops and prints the estimate (exit 3). Subscriptions
  first; a metered backend never starts work without an approved budget; no surprise
  expenditures.
- **Approvals are human-only**: `omarchy-agent-launcher harness approve/decline` refuse
  outright when `$OAL_AGENT` is set (an agent's own shell can never fund or reject its own
  spending) and resolve the harness's own keyed `pending_approvals` entry (`--request ID`,
  or the oldest match on amount). `skills/rix/SKILL.md`'s "Plan (harness)" section drops
  `approve`/`decline` from Rix's own command list — only a human approves spend; Rix's job is
  to say the estimate and ask.
- **`harness prices`** (models.dev-backed cache under the harness's own data dir) resolves a
  price for any model id the hand-entered `[prices]` table doesn't cover, so `harness_estimate_usd`
  has fewer "unknown price" refusals to report.
- **Sentinel → harness bridge** (`lib/harness_bridge.sh`, `omarchy-agent-launcher sentinel plan
  ID [--project ID] [--assign rix]`): puts a Sentinel advisory onto the harness Gantt as one
  edge or a small container of edges under a `sentinel-<repo-slug>` project, idempotently
  (re-running finds the same node instead of duplicating it), optionally assigning it to the
  repo's registered `rix` session — the harness still decides done, never Sentinel or Rix.
- **Local server per-slot context fix** (`lib/local.sh`): current llama.cpp already reports
  `default_generation_settings.n_ctx` **per slot**, so `local_status_json` no longer divides it
  by `total_slots` again (that double-counted and under-reported `ctx_per_request` with
  `--parallel N > 1`); an older build that still reports the *total* is detected by
  cross-checking `/slots[0].n_ctx` when more than one slot is configured, falling back to
  `n_ctx / total_slots` only if that endpoint is unavailable.
- **`status --json`** gains a `harness` field (`harness_status_json`, now including
  `jobs: {running, slots}`) alongside the existing `sentinel` field, so Rix (and the dashboard)
  can read both in one call.
- Settings keys: `harness_bin` (path override for the CLI), `harness_autostart` (bool, default
  `false`), `harness_turn_factor` (int, default `20`), `harness_workers` (int, default `4`).
- Contract: `docs/CONTRACTS.md` §15–§16 (session-harness repo) now specify reservations
  (`reserve`/`settle`, closing the check-then-spend race), a daily spend cap
  (`[routing] daily_cap_usd`), keyed/idempotent approval requests
  (`project.pending_approvals`), per-vendor throttling (`project.throttled_vendors`, never
  crossing subscription → metered), inbox claim timeouts (`workers.claim_timeout_sec`), and
  eight new `harness audit` codes covering the money path and stale claims. §9.1/§16 now
  also specify the worker liveness protocol above and `project.scheduler = manual|auto`
  (`harness project set --project ID --scheduler manual|auto`) for a receipts/oracle-only
  tick on a project an external dispatcher fully drives.
- README: revised "Rix × session-harness" section to match the shipped CLI and rule wording.

## 0.12.1

- Signing out of Omarchy.Fans Cloud revokes the token on the server, and says so plainly when it could not

## 0.12.0

- The dashboard tells you when a new version is out, shows what changed, and updates in one click
- A dot on the bar button says an update is waiting
- `omarchy-agent-launcher update-check`, `update-dismiss` and `update-run` from the command line

## 0.11.0

- Rix reads Sentinel's advisories and orchestrates them

## 0.10.0

- Omarchy.Fans Cloud runtime: hosted agents that sleep when idle

## 0.9.0

- Model picker on the Rix page: local models first, vendors with prices, data location and IP-safe badge
