### Repository URL

https://github.com/OmarchyFans/Omarchy-Singularix

### Category

Developer Tools

### Tags

ai, launcher, quickshell

### Suggest a missing tag

_No response_

### Maintainer notes

Singularix is a bar widget plus a persistent Quickshell dashboard window (panel kind, keepLoaded): Singularix.ai technology, available locally as an Omarchy shell plugin. It creates and launches Hermes Agent or OpenClaw locally, in Docker, or on Omarchy.Fans Cloud, each agent in its own isolated home, and shows every agent's status, tokens and USD, an event log, and notifications (also sent as Omarchy notifications). Sessions persist in tmux. Rix, a chief-of-staff agent on the local GPU, can hand work to bigger models through the separately installed session-harness (github.com/OmarchyFans/session-harness, optional); metered API spend always needs the human's approval in the dashboard first.

This resubmits #5591, which I withdrew while the runtimes were reworked. The `remote-git-execution-unpinned` finding from that baseline (an unpinned `git clone` of Hermes) is gone: the plugin no longer installs Hermes or OpenClaw, it prints the official install command and stops.

What the baseline will see: the QML only runs the plugin's own script via argv (`status --json`, `info --json`, `create --launch`, `chat`, `stop`, `event`, `harness ...`) and tails a JSONL log; all logic is bash inside the plugin folder (bin/, lib/). `install.sh` is optional and not run by `omarchy plugin add`: it appends a keybinding, a window rule and menu entries only after a y/N prompt per step (or `--yes`), with backups; `uninstall.sh` reverses it. `harness service install` is an explicit user command that writes a systemd user unit under ~/.config/systemd/user running the plugin's own script. The update banner fetches this repository's manifest from raw.githubusercontent.com read-only (curl, 5 s, 200 KB cap) and never executes anything. Hermes kanban boards and token usage are read with `sqlite3 -readonly`. `sudo` appears once (`sudo docker`, only when omarchy-sudo-docker says the daemon needs it). API keys live in a mode-600 file under ~/.config and are never passed on a command line; the harness config references environment variable names only. PanelDropdown.qml is copied from crmne.hyprmoncfg (MIT, attributed). Nothing is curl-piped into a shell.

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
