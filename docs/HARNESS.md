# Rix × session-harness — one orchestrator surface (0.13.0)

The Agent Launcher (Rix) and the session-harness (`~/Work/session-harness`, CLI
`harness`, API on `127.0.0.1:7744`) become one surface:

- **Rix orchestrates**: Rix's skill may run the harness CLI to plan, split, assign, ack,
  fail and approve; the harness stays the scheduler and the single source of truth
  (`project.json`); Rix supplies judgement and talks to the user in the launcher.
- **Rix works**: a Rix profile is registered as a harness worker session (`worker: rix`)
  on whatever backend the launcher chose — local GPU (`free`), a browser/OAuth sign-in
  (`subscription`), or an API key (`metered`). The harness assigns edges to it by writing
  inbox packets; the launcher dispatches each packet as a `delegate --wait` job and writes
  the outbox receipt from the result; the harness runs the real oracle before anything is
  `done`.
- **The dashboard shows the Gantt**: a new `plan` tab renders every project's task queue
  from the harness's `overview.json`, filterable per project / per agent / per state,
  animated as the scheduler assigns and completes work, with the task queue, the sessions
  lane and a cost/approval banner. "Open full Gantt" opens the browser UI.
- **No surprise expenditure**: subscriptions first; a metered backend never starts work
  without an approved budget; the dashboard shows the pending request with the estimate
  and Approve/Decline; Rix must say the price and get a yes.

## Data flow (no network from QML — FileView/Process only)

```text
harness serve --all  ──writes──►  ~/.session-harness/overview.json   ◄── FileView (plan tab)
                     ──appends─►  ~/.session-harness/events.jsonl    ◄── tail -F (animation deltas)
                     ──writes──►  <repo>/.harness/inbox/<sid>/<node>.md
omarchy-agent-launcher harness dispatch  (loop; started by `harness serve` wrapper)
    for each new packet of a rix session: cost gate → delegate --wait → result → harness receipt
omarchy-agent-launcher harness approve <project> <usd>  ──►  POST /approve (X-Harness)
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
| `harness_register_rix PROFILE [REPO]` | `harness session add --worker rix --label PROFILE --cwd REPO --cost-class $(harness_cost_class PROFILE) --backend <id>` for every project whose repo_path is REPO (or `--project`) |
| `harness_cost_class PROFILE` | from the profile's backend: local → `free`; `auth=oauth` → `subscription`; `auth=api-key` → `metered` |
| `harness_estimate_usd PROFILE PACKET` | chars/4 tokens × models.dev price (`lib/models.sh`/`usage.sh` price map) × 4 for output headroom; `0` for free/subscription |
| `harness_dispatch_once` | for each project in overview, each `rix` session whose label is a launcher profile, each unclaimed packet (`harness inbox --json`): if `metered` and `remaining_usd < estimate` → `POST cost/request` once and skip; else claim (rename `.md`→`.md.claimed`), `delegate --backend <b> --job-stdin --wait < packet` , then `harness receipt --status done|failed --evidence "<last 40 lines of result>"`; log `event --source harness` |
| `harness_dispatch_loop` | every 3 s `harness_dispatch_once` until stopped |
| `harness_approve PROJECT USD [REASON]` / `harness_decline PROJECT` | POST approve/decline |
| `harness_status_json` | `{alive, url, data_dir, bin, serving_pid, dispatch_pid, projects: n, pending_approvals: [...]}` — file/pid based, no network beyond one 1 s curl |

CLI: `omarchy-agent-launcher harness status|serve|stop|open|projects|register <profile> [repo]|dispatch [--once]|approve <project> <usd> [reason]|decline <project>|inbox <profile>`.
`harness serve` is also started by `rix chat` when `settings.json:harness_autostart` is true.

## Rix skill additions (skills/rix/SKILL.md, keep the closed set)

`## Plan (harness)`: `harness ls`, `harness show --project ID`, `harness audit --project ID`,
`harness tick --project ID`, `harness split --project ID --node N`, `harness assign
--project ID --node N --session S`, `harness ack/fail …`, `harness cost --project ID`,
`omarchy-agent-launcher harness status|register|approve|decline`. Rules: "The harness
decides done, never you. Before `harness approve` or any metered backend say the estimate
in USD and get a yes. Never approve on the user's behalf." `rix_job` gains a step: "check
`omarchy-agent-launcher harness status`; if a pending approval exists, tell the user the
price and ask; if the plan tab shows failed/blocked nodes, propose the next action".

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

`tests/run.sh` section `== harness` sourcing `lib/harness.sh` with a fake `harness` on
PATH (a bash stub that records args and prints canned JSON) and a fake `curl`: cost
class mapping, estimate math, dispatch_once claims a packet + calls delegate + writes the
receipt via the stub, metered + no budget → cost/request + no delegate, approve posts with
the header. Version → 0.13.0 in `manifest.json` and `skills/rix/SKILL.md`; README section
"Rix × harness"; deploy once with the flash warning; shell restart (keepLoaded panel).
