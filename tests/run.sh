#!/bin/bash
# Drives the new-agent form with scripted answers under throwaway XDG dirs,
# then checks the saved profile, the provisioned agent home, and dry-run
# launches for every agent × runtime. Needs bash, jq, gum (for `gum write`
# is bypassed; only the binary's presence is checked by the launcher).
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export XDG_CONFIG_HOME="$T/config" XDG_DATA_HOME="$T/data" HOME_REAL="$HOME"
export OAL_UI_STUBS="$ROOT/tests/ui-stubs.sh" OAL_ANSWERS="$T/answers" OAL_ASKED="$T/asked"
export EDITOR="$T/fake-editor"
printf '#!/bin/bash\nprintf "# Job\\nWrite release notes for the last tag.\\n" >"$1"\n' >"$EDITOR"; chmod +x "$EDITOR"
L="$ROOT/bin/omarchy-agent-launcher"
pass() { echo "  ok   $*"; }; tfail() { echo "  FAIL $*"; exit 1; }

echo "== form: hermes / local / anthropic api key / skills / editor job / unattended (dry-run launch)"
cat >"$OAL_ANSWERS" <<A
Release Notes Bot
hermes
local
anthropic
new-key
sk-ant-test-123
claude-sonnet-5
n
research/deep-research,software-development/codebase-inspection
editor
unattended
y
A
if command -v hermes >/dev/null; then
  out=$("$L" --dry-run new 2>&1) || { echo "$out"; tfail "form exited non-zero"; }
  grep -q "would launch" <<<"$out" || { echo "$out"; tfail "no launch line"; }
  P="$XDG_CONFIG_HOME/omarchy-agent-launcher/agents/release-notes-bot.json"
  [[ -f $P ]] || tfail "profile not saved"
  [[ $(jq -r .provider "$P") == anthropic && $(jq -r .mode "$P") == unattended ]] || tfail "profile fields"
  [[ $(jq -r '.skills|length' "$P") == 2 ]] || tfail "skills not saved"
  grep -q "^ANTHROPIC_API_KEY=sk-ant-test-123$" "$XDG_CONFIG_HOME/omarchy-agent-launcher/secrets.env" || tfail "secret not saved"
  [[ $(stat -c %a "$XDG_CONFIG_HOME/omarchy-agent-launcher/secrets.env") == 600 ]] || tfail "secrets.env mode"
  grep -q "Write release notes" "$XDG_CONFIG_HOME/omarchy-agent-launcher/agents/release-notes-bot.job.md" || tfail "job not saved"
  grep -q -- "--oneshot --yolo" <<<"$out" || tfail "unattended flags"
  pass "form -> profile, secret, job, dry-run launch"
else
  echo "  skip (hermes not installed): local form test"
fi

echo "== real provisioning (hermes home) without hermes binary involvement"
source "$ROOT/lib/common.sh"; OAL_LIB="$ROOT/lib"; source "$ROOT/lib/providers.sh"
mkdir -p "$OAL_PROFILES"
profile_write prov hermes docker openrouter api-key anthropic/claude-sonnet-5 - interactive ""
secret_set OPENROUTER_API_KEY or-test
printf '# Job\nDo the thing.\n' >"$(job_path prov)"
( source "$ROOT/lib/agents/hermes.sh"; agent_provision prov )
H="$XDG_DATA_HOME/omarchy-agent-launcher/agents/prov/hermes"
grep -q "provider: openrouter" "$H/config.yaml" || tfail "config provider"
grep -q "backend: local" "$H/config.yaml" || tfail "docker runtime must force local terminal backend"
grep -q "Do the thing" "$H/config.yaml" || tfail "job in system prompt"
[[ $(cat "$H/.env") == "OPENROUTER_API_KEY=or-test" ]] || tfail "env file"
[[ $(stat -c %a "$H/.env") == 600 ]] || tfail "env mode"
pass "hermes home provisioned"

profile_write provoc openclaw local openai api-key gpt-5.4 - interactive ""
secret_set OPENAI_API_KEY sk-test
printf '# Job\nDo the other thing.\n' >"$(job_path provoc)"
( source "$ROOT/lib/agents/openclaw.sh"; agent_provision provoc )
O="$XDG_DATA_HOME/omarchy-agent-launcher/agents/provoc/openclaw"
[[ $(jq -r .agents.defaults.model.primary "$O/openclaw.json") == "openai/gpt-5.4" ]] || tfail "openclaw model"
[[ $(jq -r .env.vars.OPENAI_API_KEY "$O/openclaw.json") == sk-test ]] || tfail "openclaw key"
grep -q "Do the other thing" "$O/workspace/AGENTS.md" || tfail "AGENTS.md"
pass "openclaw home provisioned"

echo "== dry-run launches for every agent × runtime"
secret_set SPRITES_TOKEN org/id/secret
for a in hermes openclaw; do for r in local docker sprite; do
  n="m-$a-$r"; profile_write "$n" "$a" "$r" openrouter api-key m - interactive ""; cp "$(job_path prov)" "$(job_path "$n")"
  out=$("$L" --dry-run launch "$n" 2>&1) || { echo "$out"; tfail "dry-run $n"; }
  grep -q "would launch" <<<"$out" || { echo "$out"; tfail "no launch line for $n"; }
  case $r in docker) grep -q "docker run -it --rm" <<<"$out" || tfail "$n docker cmd";; sprite) grep -q "sprite exec --tty" <<<"$out" || tfail "$n sprite cmd";; esac
done; done
pass "6 combinations"

echo "== list / show / remove"
out=$("$L" list); grep -q "^prov " <<<"$out" || tfail "list"
out=$("$L" show prov); grep -q '"agent": "hermes"' <<<"$out" || tfail "show"
printf 'y\n' >"$OAL_ANSWERS"; "$L" remove prov >/dev/null; [[ ! -f $(profile_path prov) && ! -d $H ]] || tfail "remove"
pass "manage commands"
echo "ALL TESTS PASSED"
