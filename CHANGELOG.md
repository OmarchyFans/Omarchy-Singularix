# Changelog

The dashboard reads the newest sections of this file to tell you what changed
when an update is available. Keep one short line per bullet.

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
  dispatch loop under `~/.local/state/omarchy-agent-launcher/harness/`), `harness_register_rix`,
  `harness_cost_class`, `harness_estimate_usd`, `harness_dispatch_once`/`_loop` (cost-gate →
  claim → `delegate --wait` → `harness receipt`), `harness_approve`/`harness_decline`,
  `harness_status_json` (file/pid-based, never blocks on the network beyond one 1s status ping).
- **`omarchy-agent-launcher harness`** subcommand: `status|serve|stop|open|projects|
  register PROFILE [REPO]|dispatch [--once]|approve PROJECT USD [REASON]|decline PROJECT|
  inbox PROFILE`. `settings.json:harness_autostart` (default `false`) starts `harness serve`
  automatically on `rix chat`/`rix open`.
- **Cost-gated dispatch**: a `metered` Rix profile's packet is never run until its estimated
  price (chars/4 tokens × models.dev price, ×4 output headroom) fits the project's remaining
  budget; short by even a cent, or unpriced, it posts one `cost/request` and waits — never
  guesses `$0`. Subscriptions first; a metered backend never starts work without an approved
  budget; no surprise expenditures.
- **`skills/rix/SKILL.md`**: new "Plan (harness)" section — `harness ls/show/audit/tick/split/
  assign/ack/fail/cost` plus the launcher's own `harness status|register|approve|decline`.
  Rule: the harness decides done, never Rix; say the estimate in USD and get a yes before
  `harness approve` or any metered backend.
- **`status --json`** gains a `harness` field (`harness_status_json`) alongside the existing
  `sentinel` field, so Rix (and the dashboard) can read both in one call.
- Settings keys: `harness_bin` (path override for the CLI), `harness_autostart` (bool, default
  `false`).
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
