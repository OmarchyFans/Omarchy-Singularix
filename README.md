# Omarchy Agent Launcher

**Spin up an AI agent from a keybinding.** Press a key, answer a short form,
and an agent starts working on the job you gave it: in a shell on your
machine, inside its official Docker image, or on a [Fly.io
Sprite](https://fly.io/sprites) in the cloud.

The form asks for:

| Step | Choices |
|------|---------|
| **Agent** | [Hermes Agent](https://github.com/NousResearch/hermes-agent) (Nous Research) · [OpenClaw](https://openclaw.ai) |
| **Runtime** | local shell · Docker container · Fly.io Sprite (needs your Sprites API token) |
| **Model** | Anthropic, OpenAI, OpenAI Codex, Nous Portal, xAI, OpenRouter, Gemini, DeepSeek, local Ollama, or any custom model id |
| **Sign-in** | browser OAuth with your own account (where the agent supports it) or an API key, saved once with mode 600 |
| **Skills** | checkboxes over your installed skill library, plus hub install for Hermes |
| **Job** | the instructions / job description, written in `$EDITOR`, typed inline, or taken from a file |
| **Mode** | interactive chat that starts on the job, or an unattended one-shot run |

Every agent gets **its own isolated home** (config, keys, skills, memory)
under `~/.local/share/omarchy-agent-launcher/agents/<name>/`. Your real
`~/.hermes` and `~/.openclaw` are never read or written. Saved agents can be
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
Enabling adds a robot button to the bar; clicking it opens the launcher in a
floating terminal.

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

### Keybinding (recommended)

Plugins cannot ship keybindings, so add one line to `~/.config/hypr/bindings.lua`
(SUPER + ALT + A is unbound by default; the launcher checks nothing else):

```lua
o.bind("SUPER + ALT + A", "Agent launcher", "~/.config/omarchy/plugins/fans.omarchy.agent-launcher/bin/omarchy-agent-launcher --popup")
```

Hyprland reloads on save; verify with `hyprctl configerrors`.

### Omarchy menu entry (optional)

Append the snippet in [`extensions/omarchy-menu.snippet.jsonc`](extensions/omarchy-menu.snippet.jsonc)
to `~/.config/omarchy/extensions/omarchy-menu.jsonc` to get an **Agents**
submenu (new / relaunch / manage) in the Omarchy menu.

### `install.sh` (optional helper)

The repo also carries a small helper that does the three optional steps for
you, each only after you confirm: symlink the CLI into `~/.local/bin`, append
the keybinding, append the menu entry. It is not run by `omarchy plugin add`.

```bash
~/.config/omarchy/plugins/fans.omarchy.agent-launcher/install.sh
```

## Use

Press the key (or click the bar button). First visit: **New agent…**; later
the menu also lists every saved agent for one-keystroke relaunch and a
**Manage** entry (show, edit job, sign in again, remove, destroy, sprite console).

From a terminal:

```bash
omarchy-agent-launcher                # menu
omarchy-agent-launcher new            # the form
omarchy-agent-launcher launch NAME    # relaunch
omarchy-agent-launcher manage         # show / edit job / sign in / remove / destroy
omarchy-agent-launcher list | show NAME | job NAME | sign-in NAME
omarchy-agent-launcher remove NAME    # forget + delete its local home
omarchy-agent-launcher destroy NAME   # also remove its container / sprite
omarchy-agent-launcher --dry-run launch NAME   # print every command, run nothing
omarchy-agent-launcher --inline launch NAME    # session in this terminal, not a new window
```

Sessions open in a new terminal with app-id `org.omarchy.agent`, the same
class Omarchy's own `omarchy agent` uses, so your window rules apply.
Unattended runs open in a presented floating terminal that stays until you
dismiss it.

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

Model ids drift. The provider table lives in one place,
[`lib/providers.sh`](lib/providers.sh); "Custom…" is always offered.

## What has been tested

Built on Omarchy 4.x with Hermes Agent 0.21 installed locally.

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
- The bar widget is a thin launcher (see `BarWidget.qml`); no network, no
  secrets, nothing parsed inside the shell process.

## Remove

```bash
omarchy plugin remove fans.omarchy.agent-launcher
```

Then, if you used them: delete the `o.bind` line from
`~/.config/hypr/bindings.lua`, the `agents.*` entries from
`~/.config/omarchy/extensions/omarchy-menu.jsonc`, and the symlink
`~/.local/bin/omarchy-agent-launcher` (`./uninstall.sh` does all three).
Saved agents and secrets stay in `~/.config/omarchy-agent-launcher/` and
`~/.local/share/omarchy-agent-launcher/` until you delete them; `destroy`
removes remote containers and sprites first.

## License

MIT. External dependencies: gum (MIT), jq (MIT); at runtime the agents and
CLIs you choose (Hermes Agent — MIT; OpenClaw — MIT; Docker; Sprites CLI).
