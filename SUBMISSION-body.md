### Repository URL

https://github.com/modpunk/omarchy-agent-launcher

### Category

Developer Tools

### Tags

ai, launcher

### Suggest a missing tag

_No response_

### Maintainer notes

Bar widget with a single-page Quickshell setup panel (plus a terminal wizard) that launches Hermes Agent or OpenClaw locally, in Docker, or on a Fly.io Sprite, with per-agent isolated homes. The QML panel only runs the plugin's own script (`info --json`, `create --launch`); all agent logic is bash inside the plugin folder (bin/, lib/). PanelDropdown.qml is copied from crmne.hyprmoncfg (MIT, attributed). `sudo` appears once (`sudo docker` when omarchy-sudo-docker says the daemon needs it). The Sprite bootstrap clones Hermes at a pinned 40-character commit and installs OpenClaw from npm; nothing is curl-piped into a shell. API keys are stored in a mode-600 file under ~/.config and never passed on a command line. The optional install.sh only appends a keybinding / menu entry after an explicit y/N prompt and takes backups.

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
