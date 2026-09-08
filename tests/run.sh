#!/bin/bash
# Drives the new-agent form with scripted answers under throwaway XDG dirs,
# then checks the saved profile, the provisioned agent home, and dry-run
# launches for every agent × runtime. Needs bash, jq, gum (for `gum write`
# is bypassed; only the binary's presence is checked by the launcher).
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export XDG_CONFIG_HOME="$T/config" XDG_DATA_HOME="$T/data" XDG_STATE_HOME="$T/state" HOME_REAL="$HOME"
export OAL_OFFLINE=1 OAL_UI_STUBS="$ROOT/tests/ui-stubs.sh" OAL_ANSWERS="$T/answers" OAL_ASKED="$T/asked"
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
  grep -q "would open window" <<<"$out" || { echo "$out"; tfail "no window line"; }
  P="$XDG_CONFIG_HOME/omarchy-agent-launcher/agents/release-notes-bot.json"
  [[ -f $P ]] || tfail "profile not saved"
  [[ $(jq -r .provider "$P") == anthropic && $(jq -r .mode "$P") == unattended ]] || tfail "profile fields"
  [[ $(jq -r '.skills|length' "$P") == 2 ]] || tfail "skills not saved"
  grep -q "^ANTHROPIC_API_KEY=sk-ant-test-123$" "$XDG_CONFIG_HOME/omarchy-agent-launcher/secrets.env" || tfail "secret not saved"
  [[ $(stat -c %a "$XDG_CONFIG_HOME/omarchy-agent-launcher/secrets.env") == 600 ]] || tfail "secrets.env mode"
  grep -q "Write release notes" "$XDG_CONFIG_HOME/omarchy-agent-launcher/agents/release-notes-bot.job.md" || tfail "job not saved"
  out=$("$L" --dry-run --inline launch release-notes-bot 2>&1) || tfail "inline dry-run"
  grep -q -- "--oneshot --yolo" <<<"$out" || tfail "unattended flags"
  out=$("$L" --dry-run --inline launch release-notes-bot 2>&1); grep -q -- "-s deep-research" <<<"$out" || tfail "skill preload flag"
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
  inl=$("$L" --dry-run --inline launch "$n" 2>&1) || { echo "$inl"; tfail "dry-run $n"; }
  grep -q "would launch" <<<"$inl" || { echo "$inl"; tfail "no launch line for $n"; }
  out=$("$L" --dry-run launch "$n" 2>&1) || { echo "$out"; tfail "dry-run window $n"; }
  grep -q "would open window" <<<"$out" || { echo "$out"; tfail "no window line for $n"; }
  case $r in docker) grep -q "docker run -it --rm" <<<"$inl" || tfail "$n docker cmd";; sprite) grep -q "sprite exec --tty" <<<"$inl" || tfail "$n sprite cmd";; esac
done; done
pass "6 combinations"

echo "== non-interactive API: info --json and create"
"$L" info --json >"$T/info.json" || tfail "info --json"
[[ $(jq -r '.agents|length' "$T/info.json") == 2 && $(jq -r '.providers|length' "$T/info.json") -ge 8 ]] || tfail "info content"
jq -e '.agents[0].runtimes.local.status|length>0' "$T/info.json" >/dev/null || tfail "runtime status"
jq -e '.providers[0].models | length > 0 and all(has("id") and has("input"))' "$T/info.json" >/dev/null || tfail "model objects"
jq -e '.providers[0].default_model | length > 0' "$T/info.json" >/dev/null || tfail "default model"
printf '# Job\nTriage issues.\n' | OAL_API_KEY=sk-test-999 "$L" create --json --name "Issue Triage" --agent hermes --runtime local \
  --provider anthropic --api-key-env --model claude-sonnet-5 --skill software-development/dogfood --mode unattended --job-stdin >"$T/created.json" || tfail "create"
[[ $(jq -r .name "$T/created.json") == issue-triage && $(jq -r .auth "$T/created.json") == api-key ]] || tfail "create profile"
grep -q "^ANTHROPIC_API_KEY=sk-test-999$" "$XDG_CONFIG_HOME/omarchy-agent-launcher/secrets.env" || tfail "create key"
grep -q "Triage issues" "$XDG_CONFIG_HOME/omarchy-agent-launcher/agents/issue-triage.job.md" || tfail "create job"
out=$(printf 'job\n' | "$L" --dry-run create --name t2 --agent openclaw --runtime docker --provider ollama --auth none --mode interactive --job-stdin --launch 2>&1) || tfail "create --launch"
grep -q "would open window\|would launch" <<<"$out" || tfail "create --launch output"
"$L" create --name x --agent hermes --runtime local --provider openai --auth api-key --mode interactive --job-file /dev/null 2>/dev/null && tfail "create should reject empty job"
pass "info --json, create, create --launch, validation"

echo "== events, blockers, status, settings, rotation, stop, switch"
S="$XDG_STATE_HOME/omarchy-agent-launcher"
grep -q '"kind":"created"' "$S/events.jsonl" || tfail "create did not log an event"
out=$("$L" --dry-run event issue-triage blocker "Need the deploy token" --task deploy --level blocker 2>&1) || tfail "event blocker"
grep -q "omarchy-notification-send" <<<"$out" || tfail "blocker toast (dry-run) missing"
[[ $(jq -r '."issue-triage/need-the-deploy-token".task' "$S/blockers.json") == deploy ]] || tfail "blockers.json entry"
st=$("$L" status --json) || tfail "status --json"
[[ $(jq -r '.blockers' <<<"$st") == 1 ]] || tfail "status blockers count"
[[ $(jq -r '.agents[] | select(.name=="issue-triage") | .status' <<<"$st") == blocked ]] || tfail "status blocked"
[[ $(jq -r '.agents[] | select(.name=="issue-triage") | .running' <<<"$st") == false ]] || tfail "running must be false without tmux session"
[[ $(jq -r '.agents[] | select(.name=="issue-triage") | .window' <<<"$st") == "" ]] || tfail "window must be empty"
[[ $(jq -r '.agents[] | select(.name=="issue-triage") | .job_title' <<<"$st") == "Job" ]] || tfail "job_title"
jq -e '.agents[] | select(.name=="issue-triage") | .tasks | map(select(.source=="cli" and .title=="deploy")) | length == 1' <<<"$st" >/dev/null || tfail "cli task"
"$L" event issue-triage blocker_cleared "pasted" --key need-the-deploy-token >/dev/null || tfail "blocker_cleared"
[[ $(jq 'length' "$S/blockers.json") == 0 ]] || tfail "blocker not cleared"
"$L" settings set notify_blockers false >/dev/null; [[ $("$L" settings get notify_blockers) == false ]] || tfail "settings false"
out=$("$L" --dry-run event issue-triage blocker "quiet" --level blocker 2>&1); grep -q "notification-send" <<<"$out" && tfail "toast sent despite notify_blockers=false"
"$L" event issue-triage blocker_cleared "" >/dev/null
OAL_EVENTS_MAX_BYTES=100 "$L" event issue-triage note "rotate me please, this line is long enough to exceed the tiny cap" >/dev/null
[[ -f $S/events.1.jsonl ]] || tfail "rotation"
out=$("$L" stop issue-triage 2>&1); grep -q "not running" <<<"$out" || tfail "stop when idle"
out=$("$L" --dry-run switch 2>&1) || tfail "switch dry-run"; grep -q "issue-triage" <<<"$out" || tfail "switch rows"
pass "events, blockers, status, settings, rotation, stop, switch"

echo "== kanban mirror (sqlite fixture)"
if command -v sqlite3 >/dev/null; then
  profile_write kb hermes local ollama none qwen3:8b http://localhost:11434/v1 interactive ""
  printf '# Board job\nWork the board.\n' >"$(job_path kb)"
  ( source "$ROOT/lib/agents/hermes.sh"; agent_provision kb )
  KDB="$XDG_DATA_HOME/omarchy-agent-launcher/agents/kb/hermes/kanban.db"
  sqlite3 "$KDB" "create table tasks(id text primary key, title text, status text, block_kind text, last_failure_error text, created_at text, started_at text, completed_at text);
    create table task_events(id integer primary key autoincrement, task_id text, run_id integer, kind text, payload text, created_at text);
    insert into tasks values('t1','Write the changelog','running',null,null,'2026-09-08T10:00:00','2026-09-08T10:01:00',null);
    insert into tasks values('t2','Get the signing key','blocked','needs_input','no key in env','2026-09-08T10:00:00',null,null);
    insert into tasks values('t3','Old card','done',null,null,'2026-09-08T09:00:00',null,'2026-09-08T09:30:00');
    insert into task_events(task_id,kind,payload,created_at) values('t2','commented','{\"body\":\"waiting on the user\"}','2026-09-08T10:05:00');"
  "$L" kanban-sync kb || tfail "kanban-sync"
  st=$("$L" status --json)
  jq -e '.agents[] | select(.name=="kb") | .tasks | map(select(.source=="kanban")) | length == 3' <<<"$st" >/dev/null || tfail "kanban tasks in status"
  [[ $(jq -r '.agents[] | select(.name=="kb") | .status' <<<"$st") == blocked ]] || tfail "needs_input card must block the agent"
  jq -e '."kb/kanban:t2"' "$S/blockers.json" >/dev/null || tfail "kanban blocker key"
  n1=$(grep -c '"source":"kanban"' "$S/events.jsonl"); (( n1 >= 3 )) || tfail "kanban events mirrored ($n1)"
  "$L" kanban-sync kb; n2=$(grep -c '"source":"kanban"' "$S/events.jsonl"); [[ $n1 == "$n2" ]] || tfail "kanban-sync not idempotent ($n1 -> $n2)"
  sqlite3 "$KDB" "update tasks set status='done', completed_at='2026-09-08T11:00:00' where id='t2';"
  "$L" kanban-sync kb; jq -e '."kb/kanban:t2"' "$S/blockers.json" >/dev/null && tfail "kanban blocker not cleared on done"
  grep -q '"kind":"task_done".*Get the signing key' "$S/events.jsonl" || tfail "task_done for t2"
  "$L" remove kb --yes >/dev/null
  pass "kanban mirror: tasks, blocker, idempotent cursor, clear on done"
else
  echo "  skip (sqlite3 not installed): kanban mirror"
fi

echo "== list / show / remove"
out=$("$L" list); grep -q "^prov " <<<"$out" || tfail "list"
out=$("$L" show prov); grep -q '"agent": "hermes"' <<<"$out" || tfail "show"
printf 'y\n' >"$OAL_ANSWERS"; "$L" remove prov >/dev/null; [[ ! -f $(profile_path prov) && ! -d $H ]] || tfail "remove"
"$L" remove provoc --yes >/dev/null || tfail "remove --yes"; [[ ! -f $(profile_path provoc) ]] || tfail "remove --yes left profile"
tail -n 1 "$S/events.jsonl" | grep -q '"kind":"removed"' || tfail "removed event"
pass "manage commands"
echo "ALL TESTS PASSED"
