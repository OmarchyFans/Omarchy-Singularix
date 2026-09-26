# Changelog

The dashboard reads the newest sections of this file to tell you what changed
when an update is available. Keep one short line per bullet.

## 0.19.9

- **Rix and Sentinel can no longer be removed by accident.** Removing either deletes its sign-ins, memory and history, and it is never the way to switch a model. Rix was removed three times on Sep 19–20, each time followed a few seconds later by a fresh setup. The Agents tab no longer shows Remove for them, and `remove rix` now refuses without an extra `--really`. No agent session can remove Rix, Sentinel, or itself at all.
- **Every removal now names who asked for it** ("Agent removed by the dashboard", "…by agent rix"). Until now the log said only "Agent removed", so nobody could tell after the fact.
- **Z.ai (GLM) is a provider.** A saved `ZAI_API_KEY` had nowhere to show up because there was no Z.ai row. It now appears in the picker with GLM-5.3, 5.2, 5.1 and 4.7 (more from the live catalogue).
- **A local agent tells the truth about its model.** The local GPU server serves one model and ignores the name in a request, so a local agent's profile could name anything and Hermes would print it. One said "astra" while every answer came from the local Qwen. Local agents are now configured with the model the server actually serves.

## 0.19.8

- **Cloud API responses are size-bounded before capture.** HANCORE-linux's second-pass review on #7248 found `cloud_http`/`cloud_api` in `lib/runtimes/cloud.sh` captured a curl response fully into a shell variable with only a time ceiling (`--max-time`), no byte ceiling — a malicious or malfunctioning `api.omarchy.fans` endpoint could stream an unbounded body and exhaust client memory before `jq`/command substitution ever saw it. Both now add `--max-filesize` (default 8MB, `OFC_HTTP_MAX_BYTES` override); curl 8.4+ enforces this even on chunked responses with no Content-Length. Verified against a local test server: an oversized chunked response is refused in milliseconds, a normal response still round-trips correctly.
- The same review's second finding — the one-time console ticket traveling in the `websocat` URL argument, readable by other local accounts via `/proc/<pid>/cmdline` during its ~60s window — remains open. `websocat` has no mechanism to read a connect URL from an environment variable or file instead of argv, and the console relay (`api/src/console.js` in omarchy-fans-cloud) only accepts the ticket via URL query parameter today; closing this needs a paired change to that live, separately-deployed API to accept the ticket over a header or protected channel, which is out of scope for a client-only fix in this plugin.

## 0.19.7

- **Docker runtime images are pinned by digest, not `:latest`.** HANCORE-linux's marketplace security review on #7248 found `nousresearch/hermes-agent:latest` and `ghcr.io/openclaw/openclaw:latest` were mutable references — a registry owner or compromised publishing account could swap the code the plugin runs without touching this repository. Both defaults are now `name@sha256:...` digests, and `agent_docker_image()` refuses to run a configured `OAL_HERMES_IMAGE`/`OAL_OPENCLAW_IMAGE` override that isn't itself digest-pinned.

## 0.19.6

- **The OpenAI subscription backend now offers the models it was actually probed to serve: GPT-5.6 Terra, GPT-5.6 Luna and GPT-5.5.** 0.19.5 guessed from the name that the ChatGPT-account endpoint meant "Codex models", and got it wrong in both directions — it hid Terra, Luna and 5.5, which work, and kept `gpt-5.4-codex`, which that endpoint rejects even though it was this backend's default. The list is now probed, one call per model, and the method is written down next to it so it can be re-checked when OpenAI moves things. `gpt-6-astra` and `gpt-5.6-sol` are rejected there — they need an OpenAI API key, not the subscription. "Custom model id…" remains for anything new.

## 0.19.5

- **What the dashboard says Rix runs on is what Rix is actually running.** Picking a model rewrites the profile, but a session that is already open keeps the configuration it was started with until it restarts — and every label read the profile. So a pick showed as if it had already taken effect: the tmux bar said the new model while Hermes underneath was still on the old one, and the window title stopped matching, so Chat opened a *second* window onto that same session. A session now records what it actually started with, and the status line, window title, `status --json` and the Rix tab all read that. A pick made while Rix is up shows as "… on restart" with a Stop button next to it.
- **The harness is no longer told a model that is not running.** It routes, gates and prices work by its session record, and a model pick was pushed straight into that record while the session kept running something else. It now keeps the running model until the session restarts.
- **The OpenAI subscription backend only offers models it can actually serve.** The ChatGPT-account Codex endpoint answers `400 · not supported when using Codex with a ChatGPT account` for anything but a Codex model, yet the picker listed all 14 OpenAI models there. It now lists Codex models only. The OpenAI API-key backend is unchanged and still offers the full catalogue.

## 0.19.4

- **An agent's session ending is no longer something that "needs you".** Closing an agent window raised a blocker — 42 of the first 99 blockers on this machine, the single biggest source — for an event that asks nothing of you: the launcher never auto-restarts an agent, Chat starts it again, and the note clears itself the moment you do. It is now a plain entry in the event log. The one exception that actually costs something is an **unattended** run that stopped before finishing, since nobody picks that up on its own; that warns (Notifications › Recent), still with no badge.
- **Pressing Stop no longer files "killed from outside" against you.** `stop` killed the session without telling the session's own exit trap it was us, so a stop you asked for came back as an unexplained end. That is why `rix` and `jarvis` kept reappearing in the badge.

## 0.19.3

- **Desktop notifications for blockers are off by default, and never sticky when you turn them on.** The badge on the bar widget already counts everything that needs you, so nothing pops up over your work any more. Blockers were being sent at `critical` urgency, which by spec never expires — that is why they stayed on screen until dismissed. Switch them back on from the Notifications page (or `settings set notify_blockers true`) and you get an ordinary notification that fades on its own after a few seconds.

## 0.19.2

- **The dashboard reads the harness again, and Rix's model picker shows what Rix runs on.** Once the event log passed 128 KiB, `status --json` came out malformed and the dashboard fell back to "could not parse status": the Rix tab's harness section, the Plan tab's Gantt and the picker's current model all went blank, and picking a model looked like it did nothing because the label never changed. The event log, the blockers and each agent's task list now reach `jq` through files instead of the command line (Linux caps one argument at 128 KiB however large `ARG_MAX` is, and the log only rotates at 2 MiB, so this was going to happen to everyone). `rix brief` had the same limit and is fixed too.
- One agent that fails to render no longer takes the whole status document down with it; it is skipped and the rest of the dashboard still loads.

## 0.19.1

- **The harness won't start here while your digital twin is running it in the sandbox.** Take the work back first: `omarchy-digital-twin handoff local`. `harness status` shows when it's on the sandbox.

## 0.19.0

- **Credential alerts reach you as notifications.** When the harness finds a secret (§17.8) it raises a blocker per unresolved alert with what it is (masked, never the value), why it matters (exposed to a model / held in a file / scrubbed before sending), and the rotation guide as click-by-click steps. "Open rotation page" opens the vendor's console (`open-url`, http/https only); "Mark rotated" resolves the alert (`harness secret-rotated`). `harness secrets list|show|scan|resolve` also work from the launcher.
- **Select several notifications and act on them at once.** Tick the box on each row; a bulk bar approves or declines every selected metered request, or dismisses / hands to Rix every selected notification. Select-all and clear included.
- **The sidebar collapses to an icon rail when idle** and expands on hover, focus, or a pin toggle, giving the Gantt and forms more width. Navigation stays one click away with tooltips in the rail.
- **Projects: search and sort in one collapsible section.** A text search across task title, node, agent and model, plus sort by schedule / title / state / model, folded into a "Search & sort" section that stays collapsed (with a summary of what's active) until you open it.

## 0.18.0

- **Singularix.** The plugin is now called Singularix: Singularix.ai technology, available locally as a shell plugin on Omarchy. The GitHub repository moved to `OmarchyFans/Omarchy-Singularix` (the old URL redirects; the update banner and README point at the new one). Bar widget display name and alias `singularix` added; the `agent-launcher`/`agents` aliases and every command, path and keybinding keep working.
- Withdrawal grace is non-blocking: a withdrawn delegate that is still running gets `withdrawn_seen` stamped on its job file and is left alone for `HARNESS_EXIT_GRACE_SEC` (20s) while every other job's heartbeat keeps flowing (0.17.1 waited inline, which could hold the sweep past the harness's 45s stale limit when several withdrawals landed at once). Booked and forgotten once its pane ends or the grace expires.

## 0.17.1

- Money honesty, second half. Hermes writes a delegate's token row to its `state.db` as its **last** act, after the reply. On 2026-09-16 two DeepSeek runs (P0.9/P0.10) wrote their own receipt, the harness closed the nodes and withdrew the packets, and the reaper read usage (nothing yet) and deleted the delegate's home before that final write landed -- Hermes logged "state.db was replaced underneath the gateway" and $0 was booked for metered work. The withdrawal sweep now waits (bounded, `HARNESS_EXIT_GRACE_SEC`, default 20s) for the delegate's tmux session to end on its own before reading usage, and `harness_job_forget` gives a killed pane up to 5s to flush before its home is removed. Test: `harness_wait_delegate_exit` polls until dead, gives up at `max_sec`, ignores an empty slug.
- The two runs above were booked by hand at the harness's pre-run estimate ($0.003183 each) with the evidence saying so; measured figures for them no longer exist.

## 0.17.0

- Agent tmux status line and window name show `<name> · <model> @ <backend>` / `<model>@<backend>` and the task title instead of tmux's default window index, cwd and hostname (the user asked which model `oal-hns-p0-9` was running).

- Notifications: every row now explains itself. `event_emit`/`omarchy-agent-launcher event` gained `--why`, `--recommend`, `--detail`, `--node`/`--project`, and repeatable `--action LABEL=ARGV_JSON`; the harness's own notes (cost approvals, throttled sessions, refused/failed dispatch, daily cap, no known price, withdrawn packets, register refusals) now carry them. Click a notification (or press Enter on it) to expand what it is, why it matters, and what's recommended; buttons are named by effect with a tooltip saying so — **Dismiss** (clears a blocker or hides a warning; sends nothing to the agent), **Hand to Rix** (creates a task for Rix and opens its chat — does not dismiss), **Approve $X / Decline** (run the emitter's own argv when given), **Open in Projects** (deep-links to the project/node), **Chat**. The ambiguous "Resolve" button is gone.
- A `hns-*` harness delegate the reaper cleans up on purpose (job done/failed/throttled, or its node reassigned) no longer raises a "killed from outside" blocker — a marker written right before the launcher kills its own tmux session downgrades that to an info note; a genuine external kill still alarms you. A forgotten delegate's notification offers **View run log** (its saved run log, `omarchy-agent-launcher notify runlog <slug>`) instead of a dead Chat button.
- Money honesty: a delegate that already produced usage before its packet was withdrawn (the harness closed the node from the delegate's own receipt before the launcher's reaper got to it) now still gets a late usage receipt booked — this used to drop the real cost/tokens on the floor. The work-packet trailer now also tells delegates not to write their own receipt.

## 0.16.3

- Metered dispatch: the delegate may spend what the human approved and is free (remaining minus reservations), not the dispatcher's own packet estimate; `cmd_delegate` re-estimated the fuller job text and refused every 3 s. A delegate refusal now backs the session off 5 minutes instead of re-claiming in a hot loop.

## 0.16.2

- `harness status` (text): pending approvals print project, node, estimate and request id (were `null — $?`).

## 0.16.1

- `harness run`: a foreground supervisor for `harness serve --all` + the dispatch loop, meant to be a systemd unit's `ExecStart`. Fixes a live bug (2026-09-16): `harness serve` backgrounded both with `setsid nohup … &` from whatever shell called it, so closing that terminal or ending that session killed both — the Gantt froze silently and sessions went stale.
- `harness service install|uninstall|status`: installs/removes a `systemctl --user` unit (`Restart=on-failure`) running `harness run`; `harness serve`/`stop` now defer to it (`systemctl --user start|stop`) once it's installed and enabled/active, instead of spawning ad hoc. `harness status --json` gains `supervised`/`unit_active`.

## 0.16.0

- Plan tab: Inspector and Sessions are now collapsible (header click, or `i`/`s`) so the Gantt can claim the freed height; a running row only shimmers/pulses when its assignee session's heartbeat is actually fresh (<45s), showing a static "no signal" instead of fake motion once it's stale.
- Delegates run inside the project's repo (`repo_path`), with the working directory named in the packet trailer; a delegate started from the dispatcher's own directory had searched the filesystem and written into another checkout.
- Launcher-owned idle Rix sessions carry the dispatch loop's pid so they stay alive between jobs (an idle orchestrator went stale after 45 s and lost its packet); cleared when the loop exits.
- Orchestration trailer: the final message must be exactly one JSON object; a reply without one fails the packet.
- `harness register`: the harness CLI, not a possibly stale overview.json, decides which labels are already registered.

## 0.15.1

- `harness_bin`: `none` (settings or `OAL_HARNESS_BIN`) means there is no harness and never falls back to PATH or the dev checkout; tests/run.sh sets it and a throwaway `HARNESS_DATA_DIR` from the first line. The `rix setup`/`create`/`delegate` tests had been reaching the real CLI through the new resync hook and relabelling the user's live `rix-1`/`rix-2` sessions (model, vendor, cost class) on every test run.

## 0.15.0

- Plan and Projects are now one tab, "Projects": a selectable project list (progress, status, orchestrator, concurrency, kanban phase) sits above the Gantt; picking a row filters the board.
- Model labels read `local-<name>` / `online-<name>` everywhere (dropdowns, bars, sessions lane, inspector) instead of a local model's raw `.gguf` file path.
- The model and agent filters now match `done` tasks too, so picking a specific model/agent no longer empties the board; a note explains a genuine no-match.
- The update terminal forces a pager-free `git diff` and tells you up front to press `q` if it still pauses, so it never strands you at a silent `(END)`.

## 0.14.1

- `harness register`: a label already registered on the project is resynced (role, tier, model, vendor, cost class), never re-added as `<label>-2` (seen live: `rix-1-2`, `rix-2-2`).

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
