# Omarchy Agent Launcher

**Run AI agents from your desktop.** Press a key and the **Agent Dashboard**
opens: create and launch an agent on one page, see every agent's status, jump
to any agent's chat, follow a sortable event log, and get notified when an
agent needs you. Agents run in a shell on your machine, inside their official
Docker image, or on a [Fly.io Sprite](https://fly.io/sprites) in the cloud.

![The Agent Dashboard](preview.png)

The dashboard is a persistent window (it stays until you close it) with four
pages, switchable with `1`–`4`:

| Page | What it shows |
|------|---------------|
| **Agents** | every saved agent with a status pill (running / blocked / done / idle), its job, last event, task count, and **Chat**, Stop, Edit job, Remove. Enter or Chat focuses the agent's window or reattaches its session. |
| **New agent** | the one-page setup form (below) |
| **Events** | the event log: filter by agent, task, level, or text; click a column header to sort |
| **Notifications** | open blockers (things that need you) with Chat and Resolve, recent warnings, and the desktop-notification toggle |

The bar button opens the dashboard; right-click opens a quick agent switcher;
a red badge counts open blockers.

The **New agent** page asks for:

| Step | Choices |
|------|---------|
| **Agent** | [Hermes Agent](https://github.com/NousResearch/hermes-agent) (Nous Research) · [OpenClaw](https://openclaw.ai) |
| **Runtime** | local shell · Docker container · Fly.io Sprite (needs your Sprites API token) |
| **Model** | **Local GPU (offline)**, Anthropic, OpenAI, OpenAI Codex, Nous Portal, xAI, OpenRouter, Gemini, DeepSeek, local Ollama, or any custom model id. The list is live: the newest models of each provider with **prices per million tokens**, from the open [models.dev](https://models.dev) catalog |
| **Sign-in** | browser OAuth with your own account (where the agent supports it) or an API key, saved once with mode 600 |
| **Skills** | checkboxes over your installed skill library, plus hub install for Hermes |
| **Job** | the instructions / job description, written in `$EDITOR`, typed inline, or taken from a file |
| **Mode** | interactive chat that starts on the job, or an unattended one-shot run |

Every agent gets **its own isolated home** (config, keys, skills, memory)
under `~/.local/share/omarchy-agent-launcher/agents/<name>/`. Your real
`~/.hermes` and `~/.openclaw` are never written; only their skill libraries
are read so you can pick skills. Saved agents can be
relaunched, edited, or destroyed from the same menu.

A project of [omarchy.fans](https://omarchy.fans).

## Install

```bash
omarchy plugin add https://github.com/modpunk/omarchy-agent-launcher
omarchy plugin enable fans.omarchy.agent-launcher
```

`omarchy plugin add` clones the repo into
`~/.config/omarchy/plugins/fans.omarchy.agent-launcher/` and lands it
**disabled** so you can read it first. It runs no code, no installer, no sudo.
Enabling adds a robot button to the bar; clicking it opens the **Agent
Dashboard** window (right click: quick agent switcher). Updating from a
version before 0.5 adds and renames QML files, so run `omarchy restart shell`
once after `omarchy plugin update`.

After an `omarchy plugin update` that adds or renames QML files, run
`omarchy restart shell`: the shell's QML engine caches a plugin folder's type
list, and a stale cache surfaces as a bogus "File name case mismatch" error.

Requirements: Omarchy 4.x, `gum`, `jq` (both ship with Omarchy). Then, per
runtime:

- **local** — the agent itself: `hermes` on PATH (see the Hermes install
  docs) or `openclaw` (`npm install -g openclaw@latest --allow-scripts=openclaw`).
- **docker** — `omarchy install docker`. Omarchy keeps your user out of the
  docker group by default, so the launcher runs `sudo docker` and the
  terminal asks for your password.
- **sprite** — the [Sprites CLI](https://docs.sprites.dev/quickstart/). If the
  CLI isn't signed in yet, the launcher offers `sprite org auth` (browser, your
  Fly.io account) or a pasted API token from <https://sprites.dev/account>,
  stored once in `~/.config/omarchy-agent-launcher/secrets.env` (mode 600).
  A sprite is a persistent Ubuntu 25.10 VM (user `sprite`, home
  `/home/sprite`, Node/Python/git preinstalled) that sleeps when idle and
  keeps its filesystem; you pay for CPU and RAM only while it is awake.

### Keybinding and window rule (recommended)

Plugins cannot ship keybindings, so add one line to `~/.config/hypr/bindings.lua`
(SUPER + ALT + A is unbound by default). It summons the dashboard, so the
widget must be enabled:

```lua
o.bind("SUPER + ALT + A", "Agent dashboard", "omarchy-shell shell summon fans.omarchy.agent-launcher '{}'")
```

The dashboard is a Quickshell window (class `org.quickshell`); Omarchy tiles it
unless you add a rule to `~/.config/hypr/looknfeel.lua`:

```lua
o.window({ class = "^org.quickshell$", title = "^Agent Dashboard$" }, { float = true, center = true, size = { 1180, 760 } })
```

Prefer a terminal? The same setup exists as step-by-step prompts:
`omarchy-agent-launcher --popup new` (also the form's "Terminal wizard" button).

Hyprland reloads on save; verify with `hyprctl configerrors`.

### Omarchy menu entry (optional)

Append the snippet in [`extensions/omarchy-menu.snippet.jsonc`](extensions/omarchy-menu.snippet.jsonc)
to `~/.config/omarchy/extensions/omarchy-menu.jsonc` to get an **Agents**
submenu (new / relaunch / manage) in the Omarchy menu.

### `install.sh` (optional helper)

The repo also carries a small helper that does the optional steps for you,
each only after you confirm: symlink the CLI into `~/.local/bin`, add the
keybinding, add the window rule, add the menu entries. It is not run by
`omarchy plugin add`, and it upgrades an older keybinding line in place.

```bash
~/.config/omarchy/plugins/fans.omarchy.agent-launcher/install.sh
```

## Use

Press the key (or click the bar button). On **New agent**, fill in the page
and click **Launch**: the profile is saved, the agent's home is provisioned,
and its window opens with the session (and the browser sign-in, the first
time). The dashboard switches to **Agents**, where the new row shows its
status; **Chat** brings its window back at any time. Esc closes the dashboard,
`j`/`k` move, Enter opens the selected agent's chat, `r` refreshes.

From a terminal:

```bash
omarchy-agent-launcher                # menu
omarchy-agent-launcher new            # the form
omarchy-agent-launcher launch NAME    # open (or focus) the agent's window and start it
omarchy-agent-launcher chat NAME      # same; reattaches to a running session
omarchy-agent-launcher manage         # show / edit job / sign in / remove / destroy
omarchy-agent-launcher list | show NAME | job NAME | sign-in NAME
omarchy-agent-launcher remove NAME    # forget + delete its local home
omarchy-agent-launcher destroy NAME   # also remove its container / sprite
omarchy-agent-launcher stop NAME      # end the session (the saved agent stays)
omarchy-agent-launcher switch         # graphical picker: jump to an agent's chat
omarchy-agent-launcher status --json  # every agent with status, window, blockers, tasks
omarchy-agent-launcher --dry-run launch NAME   # print every command, run nothing
omarchy-agent-launcher --inline launch NAME    # session in this terminal, not a new window
```

### Sessions persist

Every agent runs inside a **tmux session** (`oal-<name>`) shown in a terminal
window titled `Agent · <name>` with app-id `org.omarchy.agent`, the class
Omarchy's own `omarchy agent` uses, so your window rules apply. That gives you:

- **A chat window that survives.** Close the window, switch workspaces, log
  out of the terminal: the agent keeps running. **Chat** in the panel (or
  `omarchy-agent-launcher chat NAME`) focuses the window if it is open,
  otherwise opens a new one reattached to the same conversation.
- **Sign-in that can't be lost.** The browser sign-in prompt lives in that
  session too. Go to the browser, copy the code, come back through the bar
  button and Chat: the prompt is still waiting for the code.
- **No vanishing windows.** When the agent exits, the window shows a menu:
  continue chatting (the agent resumes its latest conversation), run the job
  again, or close. After an unattended run, "chat" opens a conversation
  that already contains the run.

Without tmux the session still runs, just without the reattach behaviour
(`omarchy pkg add tmux`).

## How each combination runs

| | local | docker | sprite |
|---|---|---|---|
| **Hermes** | `HERMES_HOME=<home> hermes chat -s <skill>… -q <kickoff>` | `nousresearch/hermes-agent` with `<home>` at `/opt/data`, `HERMES_UID/GID` set | clone pinned to a fixed commit, `pip install -e .`, home uploaded as a tarball, `sprite exec --tty` |
| **OpenClaw** | `OPENCLAW_STATE_DIR=<home> openclaw tui --local` | `ghcr.io/openclaw/openclaw` with `<home>` at `/home/node/.openclaw`, key via `--env-file` | `npm install -g openclaw@<version>`, home uploaded, `sprite exec --tty` |

The job description becomes Hermes' `agent.system_prompt` / OpenClaw's
workspace `AGENTS.md`; the session opens with a short kickoff message.
Browser sign-in runs `hermes auth add <provider> --type oauth` or
`openclaw models auth login --provider <id>` inside the chosen runtime
(with `--no-browser` in containers and sprites, which print a URL to open).

### Events, tasks, and blockers

Everything that happens is appended to
`~/.local/state/omarchy-agent-launcher/events.jsonl` (one JSON object per line,
rotated at 2 MiB): agent created, sign-in required / signed in, session started,
session exited, unattended job done, stopped, removed. Events with
`level: blocker` are things that need you (sign-in, a crashed session, a runtime
that could not be prepared); they are kept in `blockers.json` until cleared and,
unless you turn it off (`omarchy-agent-launcher settings set notify_blockers false`),
sent as Omarchy desktop notifications whose click opens the dashboard.

Agents and hooks can post their own events. Inside a local session the plugin's
`bin` is on `PATH` and `OAL_AGENT` holds the agent's name, so an agent (or a
Hermes hook) can run:

```bash
omarchy-agent-launcher event "$OAL_AGENT" note "Parsed 12 issues" --task triage
omarchy-agent-launcher event "$OAL_AGENT" task_done "Release notes drafted" --task notes
omarchy-agent-launcher event "$OAL_AGENT" blocker "Need the deploy token" --level blocker
omarchy-agent-launcher event "$OAL_AGENT" blocker_cleared "" --key need-the-deploy-token
```

A **task** is the agent's job (first line of the job description), any `--task`
name seen in its events, and, for Hermes agents, the cards on the agent's own
kanban board. `status --json` returns all of it per agent.

### Hermes kanban boards

Hermes Agent keeps a SQLite task board at its home directory. Each launched
Hermes agent has its own isolated home, so it has its own board
(`…/agents/<name>/hermes/kanban.db`). Inside its session the agent can run
`hermes kanban create|complete|block …` (its `HERMES_HOME` is already set) and
the launcher mirrors the board **read-only**: cards appear as tasks, status
changes become events, and a card blocked as `needs_input` or `capability`
becomes a blocker until it is completed. The mirror runs whenever the
dashboard refreshes and when a session ends; it never writes to the board.

### Offline agents on your own GPU

Pick **Local GPU (llama.cpp, offline)** as the provider and the agent talks
only to the llama.cpp server on `127.0.0.1` that the Omarchy local agent runs
(the [Omarchy Help](https://github.com/modpunk/omarchy-help) plugin's
`omarchy-local-agent.service`). Nothing leaves the machine: unplug the network
and the agent keeps working. This is the privacy path: a local model cannot
leak your files, keys, or prompts to anyone, and as small models and GPUs
improve it becomes the default way to keep an Omarchy desktop private.

What the launcher does for you:

- discovers the server's URL from `~/.config/omarchy-local-agent/config.json`,
  its loaded model, its context per request, and the GPU (`omarchy-agent-launcher local-server status`);
- starts the service if it is down when you launch a local agent;
- configures Hermes through its LM Studio code path with the server's **real**
  context window (Hermes otherwise insists on 64K) and a placeholder key;
- shows readiness in the New agent page under the provider.

**One thing you must do once.** The help plugin starts llama-server with an 8K
context split over four slots, i.e. 2K tokens per request; a Hermes request is
about 12K tokens. Raise it with:

```bash
omarchy-agent-launcher local-server tune --ctx 32768          # 1 slot, 8-bit KV cache
omarchy-agent-launcher local-server tune --ctx 24576 --kv q4_0 # smaller GPUs
omarchy-agent-launcher local-server untune                    # back to the plugin's own settings
```

`tune` writes a systemd drop-in for `omarchy-local-agent.service`
(`~/.config/systemd/user/omarchy-local-agent.service.d/agent-launcher.conf`)
and restarts it; the help plugin keeps working with the larger window. Fitting
guide for a 4 GB GPU with a 4B Q4 model: 32K with `q8_0` KV is about 3.5 GB;
if the server fails to come up, use `--kv q4_0` or a smaller `--ctx`. A 27B
model does not fit next to a large context on 4 GB. `--model FILE` picks another
`.gguf` from the local agent's models folder.

OpenClaw is pointed at the same server through `OPENAI_BASE_URL`; that path is
untested.

### Models and prices

The model dropdown lists each provider's newest tool-capable models with
input and output prices in USD per million tokens, taken from the open
[models.dev](https://models.dev) catalog (`https://models.dev/api.json`,
fetched at most once a day into `~/.cache/omarchy-agent-launcher/models.json`,
never with your keys). Subscription sign-ins (ChatGPT, xAI browser sign-in,
Nous Portal) show no prices because the plan covers usage; Ollama lists what
`ollama list` reports. Offline, the static suggestions in
[`lib/providers.sh`](lib/providers.sh) are used. "Custom model id…" is always
offered for anything not listed. Set `OAL_MODELS_LIMIT` to change how many
models are shown (default 14).

## What has been tested

Built on Omarchy 4.x with Hermes Agent 0.21 installed locally.

- ✅ The dashboard: loads in the shell, persists when focus moves elsewhere, all four pages render with live data; Stop, Chat, Resolve, and the blocker badge were exercised.
- ✅ Kanban mirror: fixture board → tasks in `status --json`, blocker on a `needs_input` card, idempotent re-sync, blocker cleared when the card completes.
- ✅ Persistent sessions: a launched agent's window was killed outright; its tmux session survived and `chat` reopened a window attached to the same running conversation. Opening it twice focuses the existing window instead of duplicating it.
- ✅ The setup panel: loads in the shell, reads live data from `info --json`, and renders every control (screenshot above is a real capture). Its Launch path was exercised piecewise: the environment handoff (`Process.environment` overlays, PATH intact) and the no-terminal `create … --launch` branch, which opened the floating launch terminal and surfaced a runtime error there. Keyboard entry into fields follows hyprmoncfg's proven KeyboardPanel pattern but was not typed into by hand.

- ✅ Hermes · local: provisioning, config parsing, per-agent secrets, skill copy + preload, and the request path (verified with a deliberately invalid key that produced the provider's "incorrect API key" error).
- ✅ Every agent × runtime combination in `--dry-run` (command generation).
- ⚠️ Docker, Sprite, and OpenClaw paths are written against the official docs and CLIs but were **not exercised end to end** (no docker group, no Sprites account, OpenClaw not installed here). Treat them as beta; issues and PRs welcome.

## Security notes

- Nothing is downloaded and executed by this plugin on your machine. Sprite
  bootstraps clone Hermes at a **pinned commit** and install OpenClaw from npm.
- API keys and the Sprites token live in
  `~/.config/omarchy-agent-launcher/secrets.env` (mode 600). Each agent home
  receives only the single key it needs. API keys never appear on a command line;
  the Sprites CLI takes its token as an argument once, at `sprite auth setup`.
- `sudo` appears exactly once: `sudo docker …` when Omarchy's
  `omarchy-sudo-docker` says the daemon needs it.
- The dashboard (`Dashboard.qml`, `components/`) only runs the plugin's own
  script (`status --json`, `info --json`, `create … --launch`, `chat`, `stop`,
  `event`, `remove --yes`, `settings`) with argv, never a shell string, and
  tails the event log with `tail -F`. The API key and the job text travel in
  the child's environment, never on a command line; the key is written once to
  the mode-600 secrets file.
- Kanban boards are opened with `sqlite3 -readonly`. Desktop notifications go
  through `omarchy-notification-send`.

## Remove

```bash
omarchy plugin remove fans.omarchy.agent-launcher
```

Then, if you used them: delete the `o.bind` line from
`~/.config/hypr/bindings.lua`, the window rule from `~/.config/hypr/looknfeel.lua`,
the `agents.*` entries from `~/.config/omarchy/extensions/omarchy-menu.jsonc`,
and the symlink `~/.local/bin/omarchy-agent-launcher` (`./uninstall.sh` does all
four). Event history lives in `~/.local/state/omarchy-agent-launcher/`.
Saved agents and secrets stay in `~/.config/omarchy-agent-launcher/` and
`~/.local/share/omarchy-agent-launcher/` until you delete them; `destroy`
removes remote containers and sprites first.

## License

MIT. External dependencies: gum (MIT), jq (MIT); at runtime the agents and
CLIs you choose (Hermes Agent — MIT; OpenClaw — MIT; Docker; Sprites CLI).
