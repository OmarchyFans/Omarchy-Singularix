# Rix × session-harness — one orchestrator surface (0.13.0)

The Agent Launcher (Rix) and the session-harness (`~/Work/session-harness`, CLI
`harness`, API on `127.0.0.1:7744`) become one surface. Wave 5b (adversarial review of the
money path) tightened this: cost class is decided fail-CLOSED, spend is reserved before a
metered call and settled with the actual cost after, approvals need an id and a real human,
and no request is silently dropped or double-counted. See `docs/CONTRACTS.md` §15–§16 in
the harness repo for the authoritative contract this file summarizes for the launcher side.

- **Rix orchestrates, but never approves**: Rix's skill may run the harness CLI to plan,
  split, assign, ack, fail and read `cost`; it no longer runs `approve` — only a human, at
  a real terminal or the dashboard, funds spend (`harness/budget.py` rejects `by != "human"`
  outright). The harness stays the scheduler and the single source of truth (`project.json`);
  Rix supplies judgement and talks to the user in the launcher.
- **Rix works**: a Rix profile is registered as a harness worker session (`worker: rix`) on
  whatever backend the launcher chose. Cost class is decided **fail CLOSED**
  (`harness_backend_cost_class`): `free` only for the local GPU, `subscription` only for an
  OAuth provider the user is actually signed in to, everything else — an API key, an
  unresolvable backend, an OAuth provider nobody signed in to, or a Hermes fallback chain
  that can hop to an api-key provider (`harness_chain_metered_hop`) — is `metered`. The
  harness assigns edges to it by writing inbox packets; the launcher's dispatch loop claims
  a packet, launches a **detached** `delegate` (no `--wait`) and a reaper picks up the
  result once the worker's run log lands, writing the outbox receipt (with actual
  `--usd`/`--tokens-in`/`--tokens-out`) from it; the harness runs the real oracle before
  anything is `done`. While the job runs the dispatcher keeps the session alive (pid or a
  heartbeat every sweep) — see "Worker liveness protocol" below; without it the harness
  marks the session `stale` at `workers.stale_after_sec` (45s) into a job that runs minutes.
- **The dashboard shows the Gantt**: a `plan` tab renders every project's task queue from
  the harness's `overview.json`, filterable per project / per agent / per state, animated
  as the scheduler assigns and completes work, with the task queue, the sessions lane and a
  cost/approval banner. "Open full Gantt" opens the browser UI.
- **No surprise expenditure**: subscriptions first; a metered backend never starts work
  without an approved budget; the dashboard shows the pending request with the estimate and
  Approve/Decline; Rix must say the price and get a yes. A metered `delegate`/`rix ask`/
  `rix chat --yolo` outside the harness dispatch path needs `--approved-usd` typed by a
  human (or an interactive y/N in a `rix chat` tty) or it stops and prints the estimate —
  never a silent `$0` for an unpriced model. The harness's own budget adds a reservation
  (closes the check-then-spend race), a per-project/per-node daily cap, and an overrun
  request when the actual cost of a call exceeds what was reserved.

## Data flow (no network from QML — FileView/Process only)

```text
harness serve --all  ──writes──►  ~/.session-harness/overview.json   ◄── FileView (plan tab)
                     ──appends─►  ~/.session-harness/events.jsonl    ◄── tail -F (animation deltas)
                     ──writes──►  <repo>/.harness/inbox/<sid>/<node>.md
omarchy-agent-launcher harness dispatch  (loop; started by `harness serve` wrapper)
    per sweep: heartbeat every running job's session (or stop the delegate + clear-pid if
    the harness withdrew its claimed packet) → reap finished detached jobs (write their
    harness receipt, clear-pid) → cost-gate each unclaimed packet of a rix session → claim +
    record pid/heartbeat + detached `delegate` (up to harness_workers concurrent) → job file
    for the reaper; also runs harness_notify_sync (blockers/toasts) each loop iteration
omarchy-agent-launcher harness approve <project> <usd> [--request ID]
    ──► POST /approve  (human-only: refused when $OAL_AGENT is set; needs header
         X-Harness-Approver: human — the CLI/dashboard prove a human is present, budget.py
         itself only checks by == "human")
```

`status --json` stays network-free: the plan tab never calls the API; the CLI subcommands
do (curl to 127.0.0.1 with `X-Harness: 1`) and the harness binary does.

## lib/harness.sh (bash) — public functions

| function | does |
|---|---|
| `harness_bin` | `$OAL_CONF/settings.json:harness_bin` → `command -v harness` → `~/Work/session-harness/.venv/bin/harness`; empty + message when absent |
| `harness_data_dir` | `$HARNESS_DATA_DIR` or `~/.session-harness` |
| `harness_url` | `http://127.0.0.1:<port>` from `~/.session-harness/config.toml` (`ui_port`, default 7744) |
| `harness_alive` | `curl -s -m 1 <url>/api/status` ok |
| `harness_serve_start` / `harness_serve_stop` | `setsid harness serve --all` under `$OAL_STATE/harness/` (pid file + log) then the dispatch loop; stop kills both |
| `harness_overview_json` | cat `overview.json` (or `{}`) |
| `harness_backend_cost_class BACKEND` | **fail-CLOSED**: `free` only for `provider=local`; `subscription` only for `auth=oauth` on a provider actually in `backends_signed_providers`; every other case (api-key, no backend, an unresolved backend, an unsigned OAuth provider) → `metered` |
| `harness_chain_metered_hop CHAIN` | the first hop in a Hermes `fallback_chain` that resolves to an `auth=api-key` backend, or empty — used so a chain that *can* fall back to a paid vendor is never registered as free/subscription |
| `harness_cost_class PROFILE` | `harness_backend_cost_class` on the profile's own backend, upgraded to `metered` if `harness_chain_metered_hop` finds a paid hop in its fallback chain |
| `harness_cost_class_reason PROFILE` | why (never used to decide, only to explain in `register`'s warning / the event trail) |
| `harness_register_rix PROFILE [REPO] [SLOTS] [PROJECT_ID]` | `harness session add --worker rix --label PROFILE[-N] --cwd REPO --cost-class $(harness_cost_class PROFILE) --backend <id>` for every project whose repo_path is REPO, once per slot `1..SLOTS` (default 1); with `PROJECT_ID` the repo_path lookup is skipped and that one project is targeted directly, defaulting `REPO`/`--cwd` to *that project's own* `repo_path` (not `$PWD`) when no repo is given |
| `harness_profile_for_label LABEL` | resolves a session label (`PROFILE` or `PROFILE-N`) back to its saved profile name |
| `harness_estimate_from_class CLASS MODEL TEXT` | chars/4 input tokens × 4 for output × `settings.json:harness_turn_factor` (default 20, a delegate is a whole agent loop, not one call) × models.dev price; `0` for free/subscription; non-zero exit when a metered model's price is unknown (never guess `$0`) |
| `harness_estimate_usd PROFILE PACKET` | `harness_estimate_from_class` using `harness_cost_class PROFILE` |
| `harness_gate BACKEND MODEL TEXT APPROVED_USD` | direct (non-dispatch) entry points' pre-flight: prints the estimate, exit 0 if free/subscription or `APPROVED_USD` covers it, else exit 3 |
| `harness_gate_profile PROFILE TEXT [--interactive]` | same for an already-saved profile; `--interactive` in a tty offers a y/N `gum confirm` instead of a hard refusal (`rix chat`); `rix ask` never prompts |
| `harness_cost_request PROJECT NODE MODEL VENDOR ESTIMATE REASON BY` | `POST /api/project/{id}/cost/request` |
| `harness_prune_requested_key` / `_project` / `_stale` | maintain `$HARNESS_STATE_DIR/requested.txt` (the dedup set of already-asked-for node shortfalls): drop one node's entry once funded, drop a whole project's on approve/decline, drop any entry the harness no longer lists pending |
| `harness_approve PROJECT USD [REASON] [REQUEST_ID]` | resolves the oldest open `pending_approvals` entry matching `USD` via `harness cost --json` when no request id is given, then `POST /approve`; prunes `requested.txt` for the project |
| `harness_decline PROJECT` | `POST /cost/decline`; prunes `requested.txt` for the project |
| `harness_dispatch_packet` | cost-gates one packet (fail-closed class; metered + short → one `cost/request` + skip, deduped via `requested.txt`); if slots remain, claims (`.md`→`.md.claimed`) and launches a **detached** `delegate` (`--approved-usd` pre-filled with the harness's own estimate for a metered call), reads the delegate's tmux server pid and records a job file under `$HARNESS_STATE_DIR/jobs/<project>/<node>.json` (project, node, session, slug, claimed path, pid, started_at); calls `harness session set --pid N` when a pid was found, else `harness heartbeat` once immediately; never blocks |
| `harness_dispatch_heartbeat` | one sweep over every job file: if its `.md.claimed` no longer exists as itself (the harness withdrew/cancelled it), `harness_job_forget` the delegate (kill its tmux server, remove staged home/profile/job file) and `session set --clear-pid`; otherwise `harness heartbeat --project --session` to keep it out of `stale` |
| `harness_job_forget SLUG` | kill an `hns-*` delegate's tmux server, remove its staged home/profile/job file — transient per-job agents must not accumulate in the launcher's own agent list |
| `harness_dispatch_reap` | for each job file whose worker's run log postdates it (or, in tests, carries a `__oal_rc=<n>` sentinel line trusted outright): reads the real exit code + usage (`usage_json`), classifies `done`/`failed`/`throttled` (a nonzero exit *and* a rate-limit marker in the tail), writes `harness receipt` with `--usd/--tokens-in/--tokens-out/--model/--vendor`, `session set --clear-pid`, prunes `requested.txt`, `harness_job_forget`s the delegate, removes the job file |
| `harness_jobs_running` | count of job files (the concurrency accounting for `harness_workers`) |
| `harness_dispatch_once` | heartbeat running jobs (or stop+clear-pid a withdrawn one), reap finished jobs, prune stale requests, compute `HARNESS_SLOTS_LEFT = settings.json:harness_workers (default 4) − running jobs`, then sweep every `rix` session's unclaimed inbox packets across projects, dispatching up to the remaining slots |
| `harness_dispatch_loop` | every 3 s: `harness_dispatch_once` (which itself heartbeats/reaps first) then `harness_notify_sync`, until stopped |
| `harness_status_json` | `{alive, url, data_dir, bin, serving_pid, dispatch_pid, projects: n, pending_approvals: [...], jobs: {running, slots}}` — file/pid based, no network beyond one 1 s curl |
| `harness_pending_approvals_json` | `[{project, estimate_usd, model, vendor, reason, at}]` from `overview.json`, file only |
| `harness_notify_sync` | one blocker per project with a `pending_approval` (resolved when it clears), one warn-level note per throttled session's `retry_at` — deduped in `$HARNESS_STATE_DIR/notified.txt` so nothing re-toasts; safe every dispatch cycle and from `status` |

CLI: `omarchy-agent-launcher harness status|serve|stop|open|projects|register PROFILE [REPO]
[--slots N] [--project ID]|dispatch [--once]|approve PROJECT USD [REASON] [--request ID]|
decline PROJECT|inbox PROFILE` — `approve`/`decline` are refused outright when `$OAL_AGENT`
is set (an agent's own shell must never fund or reject its own spending).
`harness serve` is also started by `rix chat`/`rix open` when `settings.json:harness_autostart` is true.

## Worker liveness protocol (assign → claim → pid/heartbeat → receipt → clear)

Fixes a live defect (2026-09-14): a Rix delegate running a multi-minute job went `stale` at
`workers.stale_after_sec` (45s) of harness-side silence, its node was released and re-solved
by the harness itself, and the original delegate kept running with no one collecting its
result. Every dispatcher (the launcher's `harness_dispatch_*` functions) now follows this
sequence for each node it takes off a session's inbox — full contract in the harness repo's
`docs/CONTRACTS.md` §9.1/§16:

1. **Assign** — the harness writes `<repo>/.harness/inbox/<sid>/<node>.md` and puts the node
   `running`, assigned to `sid`.
2. **Claim** — the dispatcher renames it to `<node>.md.claimed` before acting on it
   (`harness_dispatch_packet`).
3. **Pid / heartbeat** — the dispatcher records the delegate's real tmux-server pid on the
   session (`harness session set --project P --session S --pid N`) when it can read one,
   else calls `harness heartbeat --project P --session S` once immediately and again every
   dispatch sweep (`harness_dispatch_heartbeat`; a `--every N [--until-gone]` daemon form of
   `harness heartbeat` is landing for dispatchers that don't want to loop it by hand). The
   harness's `RixAdapter.heartbeat` treats the session alive on a live `/proc/<pid>` *or* a
   `.md.claimed` packet younger than `workers.claim_timeout_sec` (1800s) — the claimed-file
   check is the safety net when no pid was recorded.
4. **Withdraw or receipt** — each sweep, if the job's recorded `.md.claimed` path no longer
   exists (the harness renamed it `.md.claimed.cancelled` — released, reassigned, or its
   parent finished), the dispatcher kills the delegate (`harness_job_forget`) instead of
   letting it run to completion orphaned; otherwise, once the run log shows it finished, it
   writes `harness receipt --status done|failed|progress|throttled ... --usd U --tokens-in N
   --tokens-out N --model M --vendor V` (`harness_dispatch_reap`).
5. **Clear** — either way, `harness session set --project P --session S --clear-pid` and
   `harness_job_forget` drop the pid and any transient `hns-*` scratch agent, so nothing
   from a finished or cancelled job lingers in the launcher's own agent list.

`harness sessions [--json]` (cross-project) now shows each session's `pid` and
`heartbeat_age` (seconds since `last_heartbeat`, or `"never"`), so a stuck/dead session is
visible without cross-referencing job files by hand.

## lib/harness_bridge.sh (Sentinel → harness bridge)

`omarchy-agent-launcher sentinel plan ID [--project ID] [--assign rix]` puts a Sentinel
advisory onto the harness Gantt as one edge (≤2 affected files) or a small container of
≤4 two-file edges (more files), under a `sentinel-<repo-slug>` project for the advisory's
repo (`harness init` on first use). Idempotent: `sentinel_bridge_record` stores
`{harness_project, harness_node}` on the advisory in `$OAL_STATE/sentinel-advisories.json`
(alongside Rix's own `state`/`worker`/`note` fields), so re-running `sentinel plan` on an
already-planned advisory short-circuits to the same node (still (re)issuing `--assign` if
asked) instead of adding a duplicate. `--assign` hands the node to the repo's registered
`rix` session via `POST /assign` — the harness decides done, never Sentinel or this script.
The oracle is `{type: cmd, cmd: <advisory's verification command>}` when the advisory names
one, else `{type: session_ack}`.

## Rix skill additions (skills/rix/SKILL.md, keep the closed set)

`## Plan (harness)`: `harness ls`, `harness show --project ID`, `harness audit --project ID`,
`harness tick --project ID`, `harness split --project ID --node N`, `harness assign
--project ID --node N --session S`, `harness ack/fail …`, `harness cost --project ID`,
`omarchy-agent-launcher harness status|register|inbox`. **`approve`/`decline` are not in
Rix's own list any more** (docs/CONTRACTS.md §15): the harness itself refuses a spend
approval from anyone but `by="human"`, and the launcher's CLI refuses both subcommands
outright when `$OAL_AGENT` is set, so Rix can only ever tell the user the estimate and ask
them to run `omarchy-agent-launcher harness approve`/`decline` (or click it on the
dashboard) themselves. Rules: "The harness decides done, never you. Before handing work to
any metered backend, or when the plan shows a pending approval, say the estimate in USD and
ask the user to approve it — you can never approve it yourself." `rix_job` gains a step:
"check `omarchy-agent-launcher harness status`; if a pending approval exists, tell the user
the price and ask; if the plan tab shows failed/blocked nodes, propose the next action".

## components/PlanTab.qml (the Gantt)

- Data: `FileView { path: harness_data_dir/overview.json; watchChanges: true }` (path from
  `status --json`.harness.overview_path, injected server-side without network) + `Process
  tail -F events.jsonl` for deltas. Fallback text when the harness is not running with a
  "Start harness" button (`act(["harness","serve"])`).
- Layout (dark, dense, same tokens as the other tabs): header row = project filter
  (All + each project), agent filter (All + each session label / worker), state chips
  (ready/running/blocked/done/failed), residual + spent/approved USD, "Open full Gantt".
  Body = rows grouped by project: one row per unfinished edge from `queue` (sorted
  critical-first), bar x/width from `es`/`ef` scaled to the widest project finish, bar
  colour by state (reuse the harness palette), assignee label inside, critical outline, ⚠
  for done-without-evidence. `Behavior on x/width { NumberAnimation 350ms }`,
  `Behavior on color { ColorAnimation }`, a pulse on the live end of running bars, and a
  short glow on the row when an `assign`/`done` event arrives. Sessions lane at the
  bottom: one chip per session (worker, label, state incl. throttled, cost class, node).
  Approval banner when any project has `pending_approval`: model, estimate USD, reason,
  Approve (`act(["harness","approve",project,usd])`) / Decline.
- Row click → inspector strip (title, oracle, blockers, assignee) + "Assign to Rix"
  (`act(["harness","assign",…])` via the CLI) — no network from QML.

## Tests / release

`tests/run.sh` section `== harness` sourcing `lib/harness.sh` with a fake `harness` on PATH
(a bash stub that records args and prints canned JSON) and a fake `curl`: fail-closed cost
class (no backend, unsigned OAuth, api-key, a fallback chain with a paid hop → all
`metered`; only local → `free`, only a signed-in OAuth provider → `subscription`), turn-factor
estimate math, `dispatch_once` claims a packet + launches a detached delegate + a later
`dispatch_reap` writes the receipt (with usd/tokens) via the stub once the fake run log
lands, metered + short budget → one deduped `cost/request` + no delegate, `harness_workers`
caps concurrent dispatches, `--slots N` registers `PROFILE-1..N`, `--project ID` registers
directly against a project id using its own `repo_path` as cwd, `approve`/`decline`
refuse when `OAL_AGENT` is set, `harness_notify_sync` emits exactly one blocker per pending
approval and one note per throttled `retry_at` (no re-toast on a second sweep); liveness:
`harness_dispatch_packet` records a pid, `harness_dispatch_heartbeat` heartbeats a running
job or stops+clear-pids a withdrawn one, `harness_dispatch_reap` clear-pids and forgets the
delegate on receipt. Version →
0.13.0 in `manifest.json` and `skills/rix/SKILL.md`; README section "Rix × harness"; deploy
once with the flash warning; shell restart (keepLoaded panel).
