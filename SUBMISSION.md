# Marketplace submission (draft)

Submit through the form: https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=submit-plugin.yml
or with the GitHub CLI after `gh auth login`:

```bash
gh issue create --repo omacom/omarchy-plugin-marketplace \
  --title "[Plugin]: Agent Launcher" --body-file SUBMISSION-body.md
```

`SUBMISSION-body.md` must keep these six headings, in this order:

```markdown
### Repository URL

https://github.com/OmarchyFans/omarchy-fans-agent-launcher

### Category

Developer Tools

### Tags

ai, launcher

### Suggest a missing tag

_No response_

### Maintainer notes

Bar widget + terminal form that launches Hermes Agent or OpenClaw locally, in Docker, or on Omarchy.Fans Cloud. The widget is a thin launcher; all logic is bash inside the plugin folder (bin/, lib/). `sudo` appears once (`sudo docker` when omarchy-sudo-docker says so). The cloud runtime talks only to api.omarchy.fans; nothing is curl-piped.

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
```

The checklist statements must be confirmed by the repo owner personally before filing.
