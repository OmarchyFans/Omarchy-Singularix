# Marketplace submission (draft)

Submit through the form: https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=submit-plugin.yml
or with the GitHub CLI after `gh auth login`:

```bash
gh issue create --repo omacom/omarchy-plugin-marketplace \
  --title "[Plugin]: Singularix" --body-file SUBMISSION-body.md
```

`SUBMISSION-body.md` must keep these six headings, in this order:

```markdown
### Repository URL

https://github.com/OmarchyFans/Omarchy-Singularix

### Category

Developer Tools

### Tags

ai, launcher, quickshell

### Suggest a missing tag

_No response_

### Maintainer notes

See SUBMISSION-body.md for the current maintainer notes (kept in sync with the code).

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
```

The checklist statements must be confirmed by the repo owner personally before filing.
