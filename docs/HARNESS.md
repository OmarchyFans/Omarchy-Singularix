# Rix × session-harness — one orchestrator surface (0.14.1)

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
- **Roles and model policy** (Wave 6, 0.14.0): every Rix session and every task now carries a
  role and a model/vendor label; the harness owns the policy (chains, IP table) and this
  launcher only supplies `--role`/`--model`/`--vendor` and reads back what the harness
  decided. See "Roles and model policy" below and `docs/CONTRACTS.md` §17 in the harness repo
  for the authoritative contract.

## Roles and model policy (0.14.0)

Two independent axes, per `docs/CONTRACTS.md` §17.1 in the harness repo — this launcher does
not decide either one, it only labels and reads them back:

- **Role** — what a task needs: `orchestrator | reasoning | coding | local`, in that tier
  order (`local` lowest). A session's `tier` is the highest role it can fill; it may fill a
  role at or below its tier (escalation, the default) but never above it. A Rix **profile**
  carries the role it should be registered for in its `harness_role` field
  (`orchestrator|reasoning|coding|local`, default `coding`); `harness_register_rix` passes it
  as `--role` on `harness session add` (see below) so the harness can derive `tier`/`ip_safe`.
- **IP class** — who may see a task: `protected` (only an IP-safe model may read/perform/
  orchestrate it) or `open` (any model). Unlabelled means `protected` — the graph fails
  closed. The harness's shipped defaults mark `anthropic`, `openai`, `openai-codex`, `xai`,
  `xai-oauth` and `local` IP-safe; `deepseek`, `zai`, `openrouter`, `gemini`, `nous` and
  `ollama`-remote are not (`harness policy show` prints the table; the user can flip any
  entry in the harness's own config, not here).
- **The orchestrator is never IP-unsafe** — enforced by the harness (`Router`/`Registry`
  refuse it, not this launcher's bash). `harness_register_rix`/`harness role` never
  pre-judge a vendor: they pass `--role`/`--vendor` straight through and, if the harness
  refuses (a `deepseek`/`zai`/`openrouter`/`gemini`/`nous`-backed profile asking for
  `orchestrator`, say), surface its stderr verbatim rather than guessing at the IP table
  ourselves — the harness owns it, we don't duplicate it.

**Defaults for the three chains** the harness ships (`docs/CONTRACTS.md` §17.2, verbatim; the
user can override any hop in the harness's own `[roles]` config, and per-project with
`harness project set --role`):

| role | default chain (first usable wins) |
|---|---|
| `orchestrator` | `anthropic:claude-fable-5-1` → `openai:gpt-5.4` → `local` (always available, offline-capable, weak but private — that is its value) |
| `reasoning` | `anthropic:claude-opus-5` → `openai:gpt-5.4` → `deepseek:deepseek-v4-flash` (cheap, non-IP-safe — fine only for `open`-labelled work) → `local` |
| `coding` | `anthropic:claude-sonnet-5` → `openai-codex:gpt-5.4-codex` → `local` |
| `local` | `local` (a session registered `--role local` only ever fills `local` work) |

`local` in every chain's last hop is why offline orchestration always works; it is never the
*only* option unless nothing above it is reachable. `harness brief --project ID --session
"$HARNESS_SESSION"` prints the effective chain for this project (after any override) plus
which hop the router would pick right now — see "Stateless handoff" in `docs/CONTRACTS.md`
§17.5 and the Rix skill's "Harness — pick up any task fresh" section below.

**Overriding the default agent for a role**: `--role` on `harness register` / `harness role`
(this profile, once); `harness project set --project ID --role ROLE=vendor:model [--ip-class
protected|open]` (this project's default); a node's own `role_override` (human-pinned, highest
precedence) — all three live in the harness, not in a launcher config file (no new policy
store here: `fallback-policy.json` still only governs Hermes's own in-process fallbacks).

**`--role`/`--model`/`--vendor` on `harness session add`/`session set`**: `harness_register_rix`
resolves `--model` from the profile's own `model` field, else the model its resolved backend
actually serves (`harness_profile_model`), and `--vendor` from the profile's `provider` for a
`kind=provider` backend (`anthropic`, `xai`, `local`, …) or the registry backend's own id for a
`kind=endpoint` backend (`harness_profile_vendor`; a registry backend's `provider` field is
literally the string `"endpoint"`, never the real vendor id). `--role` is the 5th argument to
`harness_register_rix`/`omarchy-agent-launcher harness register --role`, defaulting to the
profile's `harness_role`, else `coding`. `omarchy-agent-launcher harness role PROFILE ROLE`
changes a profile's `harness_role` later and pushes `harness session set --role` to every
already-registered live session for it (by label or `--slots` label suffix).

**Orchestration packets** (`docs/CONTRACTS.md` §17.4): the harness hands a `SPLIT`/`PM`/
`COMPOSE` decision to an idle `orchestrator`-tier IP-safe session as an inbox packet named
`<node>.SPLIT.md`/`.PM.md`/`.COMPOSE.md` (or a `.md` row whose `--json inbox` entry carries
`command`) instead of a router call — exactly like a work packet, claimed the same way
(`.md` → `.md.claimed`). `harness_dispatch_packet` detects one (path suffix, or the inbox
row's `command` field — tolerate its absence) and, defensively (the harness only ever assigns
these to an orchestrator session, but we check anyway): skip it unless the SESSION's own
`tier` (falling back to `role`) in `overview.json` is `orchestrator` — **never** the profile's
local `harness_role` field, which can be stale or simply wrong relative to what `harness
session set` last actually accepted for that session (Wave L1 #6/#7). If the inbox row's
`node` still carries the `.<COMMAND>` suffix (`P0.SPLIT`, matching the packet filename, with no
`command` field of its own — the shape the harness hands back today), it is stripped to the
bare node id before either the skip check or the eventual receipt: `harness receipt --node
P0.SPLIT` is "unknown node" to the harness, so the claim would otherwise be repeated forever
(Wave L1 #21). A claimed one is delegated with the packet text plus a trailer naming `harness
brief --project ID --session SID` as the first command to run (Wave L1 #27) and "reply with
exactly one JSON object (the patch) and nothing else after it — the launcher writes the
receipt, not you." On reap, `harness_extract_last_json` pulls the LAST top-level JSON OBJECT
out of the delegate's full reply (python3's own JSON tokenizer when available, immune to a
stray unmatched brace or an odd run of quote characters in prose before the real object, and
never unwrapping a top-level array into one of its elements — see the function's own comment
in `lib/harness.sh`) and `harness receipt --command SPLIT|PM|COMPOSE --patch-file F --status
done` is called with it; a delegate that was itself throttled gets `--status throttled
--retry-after-sec 300` (Wave L1 #2, with a belt-and-braces un-claim + per-session backoff if
that receipt call itself fails); a reply with no parseable JSON gets `--status failed --summary
"no JSON object found…"`, and a delegate that did not finish successfully gets `--summary
"delegate exited …"` (Wave L1 #11: two different messages for two different failures) — never
a guessed/empty patch.

**Reading it back**: `harness_status_json`'s `roles` array is every registered Rix session's
`{session, project, role, tier, model, vendor, ip_safe}` straight from `overview.json`
(nothing re-derived here); `orchestrator` is `overview.json`'s own `projects[].orchestrator`
(the session or router hop that would orchestrate a project right now), keyed by project id.
`overview_path` is always `harness_data_dir/overview.json` (or the configured
`$HARNESS_DATA_DIR`) — never `null`, so `components/PlanTab.qml`'s fallback path is only ever
a belt-and-braces default, not something it actually needs to fall back to.

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
| `harness_register_rix PROFILE [REPO] [SLOTS] [PROJECT_ID] [ROLE]` | `harness session add --worker rix --label PROFILE[-N] --cwd REPO --cost-class $(harness_cost_class PROFILE) --backend <id> --role ROLE --model M --vendor V` for every project whose repo_path is REPO, once per slot `1..SLOTS` (default 1); with `PROJECT_ID` the repo_path lookup is skipped and that one project is targeted directly, defaulting `REPO`/`--cwd` to *that project's own* `repo_path` (not `$PWD`) when no repo is given; `ROLE` defaults to the profile's `harness_role` field, else `coding`; a `session add` failure (e.g. the harness refusing an IP-unsafe vendor as `orchestrator`) surfaces the CLI's stderr verbatim rather than being pre-judged here |
| `harness_profile_for_label LABEL` | resolves a session label (`PROFILE` or `PROFILE-N`) back to its saved profile name |
| `harness_profile_vendor PROFILE` | the vendor id to register: the profile's `provider` for a `kind=provider` backend, or the registry backend's own id for a `kind=endpoint` one (never the literal string `"endpoint"` `backend_get` stamps on those) |
| `harness_profile_model PROFILE` | the profile's own `model` field, else the model its resolved backend actually serves |
| `harness_session_sync PROFILE PROJECT SESSION [ROLE]` | one `harness session set --project P --session S [--role R --tier R] --model M --vendor V --cost-class C` call — `--role`/`--tier` are ALWAYS sent paired (never `--role` alone: the harness's `validate_role` refuses a session whose previously-recorded tier ends up below or above a role sent without a matching tier, Wave L1 #6/#8) |
| `harness_resync_profile PROFILE` | best-effort `harness_session_sync` (no role change) for every already-registered live session of PROFILE — call this wherever a profile's backend/provider/model changes after it may already be a harness worker (Wave L1 #7); never fails the caller |
| `harness_set_role PROFILE ROLE` | sets the profile's `harness_role` and, for every already-registered live session (by label or `--slots` suffix) resolving back to it, runs `harness_session_sync` (`--role`/`--tier` paired); the profile field is persisted only once every live session accepted the change (or there were none), never on a partial failure |
| `harness_estimate_from_class CLASS MODEL TEXT` | chars/4 input tokens × 4 for output × `settings.json:harness_turn_factor` (default 20, a delegate is a whole agent loop, not one call) × models.dev price; `0` for free/subscription; non-zero exit when a metered model's price is unknown (never guess `$0`) |
| `harness_estimate_usd PROFILE PACKET` | `harness_estimate_from_class` using `harness_cost_class PROFILE` |
| `harness_gate BACKEND MODEL TEXT APPROVED_USD` | direct (non-dispatch) entry points' pre-flight: prints the estimate, exit 0 if free/subscription or `APPROVED_USD` covers it, else exit 3 |
| `harness_gate_profile PROFILE TEXT [--interactive]` | same for an already-saved profile; `--interactive` in a tty offers a y/N `gum confirm` instead of a hard refusal (`rix chat`); `rix ask` never prompts |
| `harness_cost_request PROJECT NODE MODEL VENDOR ESTIMATE REASON BY` | `POST /api/project/{id}/cost/request` |
| `harness_prune_requested_key` / `_project` / `_stale` | maintain `$HARNESS_STATE_DIR/requested.txt` (the dedup set of already-asked-for node shortfalls): drop one node's entry once funded, drop a whole project's on approve/decline, drop any entry the harness no longer lists pending |
| `harness_approve PROJECT USD [REASON] [REQUEST_ID]` | resolves the oldest open `pending_approvals` entry matching `USD` via `harness cost --json` when no request id is given, then `POST /approve`; prunes `requested.txt` for the project |
| `harness_decline PROJECT` | CLI `decline` first; on the CLI's own "invalid choice" (the subcommand doesn't exist on an older harness build yet) falls back to `POST /cost/decline`; any OTHER CLI failure (a real refusal) is surfaced as-is, never papered over with curl (Wave L1 #4). Prunes `requested.txt` for the project |
| `harness_record_backoff SESSION RETRY_AFTER_SEC` / `harness_backoff_active SESSION` | belt-and-braces (Wave L1 #2) for a throttled command receipt the harness CLI refuses: remembers not to redispatch onto SESSION until `retry_at` even though the harness itself never learned about the throttle; self-expiring, honoured by `harness_dispatch_packet` |
| `harness_dispatch_packet` | skips outright while `harness_backoff_active` for the session; cost-gates one packet (fail-closed class; metered short-of-`remaining_usd − reserved_usd` → one `cost/request` + skip, deduped via `requested.txt`; a positive `daily_cap_usd` that today's spend + estimate would exceed refuses WITHOUT ever requesting — a cap can't be approved away, Wave L1 #5); strips a `.<COMMAND>` suffix the harness may still put on the inbox row's `node` (`P0.SPLIT` → `P0`) before either skipping or dispatching, so the eventual receipt's `--node` is always the bare id the harness recognizes (Wave L1 #21); an orchestration packet (`<node>.SPLIT\|PM\|COMPOSE.md`, or an inbox row carrying `command`) is skipped defensively unless the SESSION's own `tier` (falling back to `role`, from `overview.json` — never the profile's local `harness_role` field, Wave L1 #6/#7) is `orchestrator`; if slots remain, claims (`.md`→`.md.claimed`) and launches a **detached** `delegate` with `$HARNESS_SESSION`/`$HARNESS_PROJECT` in its environment (Wave L1 #26) and a trailer naming `harness brief` (orchestration) or `harness show` (work packet) as the first command to run (Wave L1 #27); `--approved-usd` pre-filled with the harness's own estimate for a metered call; reads the delegate's tmux server pid and records a job file under `$HARNESS_STATE_DIR/jobs/<project>/<node>.json` (project, node, session, slug, claimed path, pid, started_at, `command`, `vendor`); calls `harness session set --pid N` when a pid was found, else `harness heartbeat` once immediately; never blocks |
| `harness_dispatch_heartbeat` | one sweep over every job file: if its `.md.claimed` no longer exists as itself (the harness withdrew/cancelled it), `harness_job_forget` the delegate (kill its tmux server, remove staged home/profile/job file) and `session set --clear-pid`; otherwise `harness heartbeat --project --session` to keep it out of `stale`, and `touch`es the `.md.claimed` file's mtime (Wave L1 #13: the harness's own claim_timeout safety net trusts that mtime when no pid was recorded) |
| `harness_job_forget SLUG` | kill an `hns-*` delegate's tmux server, remove its staged home/profile/job file — transient per-job agents must not accumulate in the launcher's own agent list |
| `harness_extract_last_json FILE` | the LAST top-level JSON OBJECT in FILE. Prefers python3's real tokenizer (`json.JSONDecoder.raw_decode`), scanning left to right for a `{`/`[` that decodes, recording each success as a TOP-LEVEL candidate and resuming the scan PAST its end (so nothing nested inside — e.g. a `children` array's own objects — is ever a separate candidate); a candidate that is a JSON ARRAY is skipped, never unwrapped into one of its elements, and the LAST object-typed candidate wins. This is immune to two failure modes a hand-rolled bracket-counter had (Wave L1 #24): a stray unmatched `{` in prose later closed by an unrelated `}` swallowing the real object, and an odd number of stray quote characters in prose desyncing manual in-string tracking. Falls back to the original bracket-counting bash algorithm (same known limitations) only when python3 is missing; exit 1 (nothing printed) when nothing parses |
| `harness_dispatch_reap` | for each job file whose worker's run log postdates it (or, in tests, carries a `__oal_rc=<n>` sentinel line trusted outright): reads the real exit code + usage (`usage_json`), classifies `done`/`failed`/`throttled` (a nonzero exit *and* a rate-limit marker in the tail). A job whose `command` field is set (an orchestration packet) instead runs `harness_extract_last_json` on the reply (scanning the last 2000 lines, Wave L1 #8) once `status == done`, writes the found JSON under `$HARNESS_STATE_DIR/patches/<project>/<node>.<CMD>.patch.json`, and calls `harness receipt --command CMD --patch-file F --status done` — or `--status throttled --retry-after-sec 300` when the delegate itself was throttled (Wave L1 #2: belt-and-braces un-claim + `harness_record_backoff` if THAT receipt call fails), or `--status failed --summary "delegate exited …"` for a dead delegate vs. `--summary "no JSON object found…"` for one that finished but replied with none (two different messages for two different failures, Wave L1 #11). Otherwise (a plain work packet) writes `harness receipt` with `--usd/--tokens-in/--tokens-out/--model/--vendor/--evidence` as before, resolving the model via `harness_profile_model` (Wave L1 #12). Either way: `session set --clear-pid`, prune `requested.txt`, `harness_job_forget`, remove the job file |
| `harness_jobs_running` | count of job files (the concurrency accounting for `harness_workers`) |
| `harness_dispatch_once` | heartbeat running jobs (or stop+clear-pid a withdrawn one), reap finished jobs, prune stale requests, compute `HARNESS_SLOTS_LEFT = settings.json:harness_workers (default 4) − running jobs`, then sweep every `rix` session's unclaimed inbox packets across projects (passing each session's `overview.json` `tier // role` through), dispatching up to the remaining slots |
| `harness_dispatch_loop` | every 3 s: `harness_dispatch_once` (which itself heartbeats/reaps first) then `harness_notify_sync`, until stopped |
| `harness_status_json` | `{alive, url, data_dir, bin, overview_path, serving_pid, dispatch_pid, projects: n, pending_approvals: [...], jobs: {running, slots}, roles: [{session, project, role, tier, model, vendor, ip_safe}], orchestrator: {project_id: …}}` — file/pid based, no network beyond one 1 s curl; `overview_path` is always `harness_data_dir/overview.json` (or `$HARNESS_DATA_DIR`), never `null`; a project entry with `orchestrator` set but no `id` is excluded rather than corrupting the map with a literal `"null"` key (Wave L1 #19) |
| `harness_pending_approvals_json` | `[{project, estimate_usd, model, vendor, reason, at}]` from `overview.json`, file only |
| `harness_notify_sync` | one blocker per project with a `pending_approval` (resolved when it clears), one warn-level note per throttled session's `retry_at` — deduped in `$HARNESS_STATE_DIR/notified.txt` so nothing re-toasts; safe every dispatch cycle and from `status` |

`harness cost --project ID --json`'s real shape (Wave L1 #3) is `pending_approvals` (a list, or —
some builds — a map keyed by request id) plus a singular `pending_approval`, `reserved_usd` and a
`daily_cap_usd`/`daily_spent_usd` pair — never the made-up `pending` list this file's cost-reading
functions (`harness_prune_requested_stale`, `harness_resolve_request_id`, the dispatch gate) used
to read exclusively; they now accept every shape (map, list, or the legacy `pending` key).

CLI: `omarchy-agent-launcher harness status|serve|stop|open|projects|register PROFILE [REPO]
[--slots N] [--project ID] [--role R]|role PROFILE ROLE|dispatch [--once]|approve PROJECT USD
[REASON] [--request ID]|decline PROJECT|inbox PROFILE|assign PROJECT NODE [--session SID]` —
`approve`/`decline` are refused outright when `$OAL_AGENT` is set (an agent's own shell must never
fund or reject its own spending). `role` accepts `orchestrator|reasoning|coding|local`. `assign`
(the Plan tab's "Assign to Rix" button, and the Rix skill's own `harness assign`) defaults
`--session` to the first idle `rix` session on the project when omitted — the harness itself
refuses an ineligible one.
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
`omarchy-agent-launcher harness status|register [--role]|role|inbox`. **`approve`/`decline` are
not in Rix's own list any more** (docs/CONTRACTS.md §15): the harness itself refuses a spend
approval from anyone but `by="human"`, and the launcher's CLI refuses both subcommands
outright when `$OAL_AGENT` is set, so Rix can only ever tell the user the estimate and ask
them to run `omarchy-agent-launcher harness approve`/`decline` (or click it on the
dashboard) themselves. Rules: "The harness decides done, never you. Before handing work to
any metered backend, or when the plan shows a pending approval, say the estimate in USD and
ask the user to approve it — you can never approve it yourself." `rix_job` gains a step:
"check `omarchy-agent-launcher harness status`; if a pending approval exists, tell the user
the price and ask; if the plan tab shows failed/blocked nodes, propose the next action".

**0.14.0 — `## Harness — pick up any task fresh`**: every session is stateless between
packets, so the first command on ANY packet is `harness brief --project ID --session
"$HARNESS_SESSION"` (or, for a plain work packet, also `harness show --project ID --node NID
--json`). Roles/IP rules in plain words: fill the role you were registered for, never escalate
above your tier; never label a node `open` unless the user or an IP-safe orchestrator did
(unlabelled means `protected`, the safe default); never send protected content to a
non-IP-safe model; you never `approve`/`decline`, one level higher than before — an
orchestrator plans and routes, it still never funds. Orchestration packets
(`<node>.SPLIT.md`/`.PM.md`/`.COMPOSE.md`, only ever handed to an `orchestrator`-tier
session): answer with exactly one JSON object (the patch) and nothing else after it — the
launcher's dispatcher extracts it and writes the `--command` receipt; do not write the
outbox file or run `receipt` by hand. Also lists `harness policy show`, `harness project set
--role/--ip-class`, `harness assign`.

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
delegate on receipt.

**0.14.0 additions** (same subshell/fixture style): `register` passes `--role coding` by
default, then a profile's `harness_role`, then an explicit `ROLE` argument (highest
precedence), plus `--model`/`--vendor`; a harness CLI refusal (e.g. an IP-unsafe vendor
asking for `orchestrator`) is asserted to surface its stderr verbatim. `harness_set_role`
persists the profile field and pushes `session set --role` to every matching live session
(plain label and `--slots` suffix) but never another profile's session; refuses an unknown
role. `harness_extract_last_json` is unit-tested directly on nested braces, braces inside a
string, a broken/unterminated object before a good one, and two complete candidates (the
LAST one must win). Orchestration dispatch: an inbox row carrying `command: "SPLIT"` is
claimed only by a session whose `overview.json` role is `orchestrator`, delegated, and
reaped into a `--command SPLIT --patch-file F --status done` receipt whose file is the
extracted JSON; a `.PM.md`-suffixed row with no `command` field (tolerate its absence) is
never claimed by a non-orchestrator session/profile (defensive skip, with an explanatory
event); a delegate reply with no JSON object at all reaps to `--status failed --summary
"…"`, no `--patch-file`. `harness_status_json.overview_path` is asserted non-null and equal
to `harness_data_dir/overview.json`; `.roles`/`.orchestrator` are asserted to carry what
`overview.json` says. Version →
0.14.0 in `manifest.json` and `skills/rix/SKILL.md`; deploy once with the flash warning;
shell restart (keepLoaded panel).

**Wave L1 additions** (adversarial review of the roles-policy branch; same subshell/fixture
style): a real-shaped inbox row (`node` carrying the `.SPLIT` suffix, no `command` field)
dispatches/receipts against the bare node id (#21). A throttled orchestration delegate reaps to
`--status throttled --retry-after-sec`, never `--status failed`; a harness CLI that refuses that
receipt is proven to un-claim the packet and back the session off until `retry_at` (#2), the fake
`harness receipt` accepting a forced-failure toggle for exactly this. `cost --json`'s
`pending_approvals` (list or map) and `pending_approval` are read correctly, not just the legacy
`pending` (#3). `harness decline` falls back to curl only on the CLI's "invalid choice", never on
a genuine refusal (#4, two fakes: one missing the subcommand, one that just refuses). The dispatch
gate is proven to subtract `reserved_usd` and to refuse — without ever POSTing `cost/request` — a
node that would exceed a positive `daily_cap_usd` (#5). `harness_set_role`/`harness_session_sync`
are proven to pair `--role`/`--tier` by seeding the fake's own mirror of `validate_role`'s tier
rule with a stale lower tier (a plain `--role` there is refused; paired, it isn't) (#6/#8), and the
dispatch guard is proven to ignore a profile's `harness_role` entirely when the session's own
record disagrees (#6/#7). `harness_resync_profile` and a register call against an
already-registered session are asserted to push a `session set` with the profile's current
model/vendor/cost-class (#7). `harness_extract_last_json` gets two new failing shapes (a stray
brace closed by an unrelated one; an odd run of quote characters before the real object) plus a
top-level-array-only reply, which must be rejected outright (#24). A dead delegate's failed
receipt is asserted to read differently from a no-JSON one (#11); dispatch resolves an
explicit-model-less profile's model the same way `harness_profile_model` does (#12);
`harness_dispatch_heartbeat` is asserted to bump a still-claimed packet's mtime (#13); a
project entry with `orchestrator` set but no `id` is asserted not to corrupt the orchestrator
map (#19); a dispatched delegate's environment and job-body trailer are asserted to carry
`$HARNESS_SESSION`/`$HARNESS_PROJECT` and the right "First run: …" line (#26/#27); and
`omarchy-agent-launcher harness assign PROJECT NODE [--session SID]` is asserted, through the
real CLI, to pick the first idle `rix` session when `--session` is omitted (#10). Bump nothing
(still 0.14.0).
