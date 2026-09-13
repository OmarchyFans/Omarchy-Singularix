### Repository URL

https://github.com/OmarchyFans/omarchy-fans-agent-launcher

### Category

Developer Tools

### Tags

ai, launcher

### Suggest a missing tag

_No response_

### Maintainer notes

Bar widget plus a persistent Quickshell dashboard window (panel kind, keepLoaded) that creates and launches Hermes Agent or OpenClaw locally, in Docker, or on Omarchy.Fans Cloud, with per-agent isolated homes, shows every agent's status, a sortable event log, and blockers (also sent as Omarchy notifications). Sessions persist in tmux. The QML only runs the plugin's own script (`status --json`, `info --json`, `create --launch`, `chat`, `stop`, `event`) via argv and tails a JSONL log; all agent logic is bash inside the plugin folder (bin/, lib/). Hermes kanban boards are read with `sqlite3 -readonly`. PanelDropdown.qml is copied from crmne.hyprmoncfg (MIT, attributed). `sudo` appears once (`sudo docker` when omarchy-sudo-docker says the daemon needs it). The cloud runtime talks only to api.omarchy.fans; nothing is curl-piped into a shell. API keys are stored in a mode-600 file under ~/.config and never passed on a command line. The optional install.sh only appends a keybinding / menu entry after an explicit y/N prompt and takes backups.

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
