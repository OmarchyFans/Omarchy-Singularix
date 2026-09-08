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
source "$ROOT/lib/common.sh"; OAL_LIB="$ROOT/lib"; source "$ROOT/lib/providers.sh"; source "$ROOT/lib/models.sh"; source "$ROOT/lib/events.sh"; source "$ROOT/lib/local.sh"
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

echo "== local GPU provider"
ls=$("$L" local-server status --json) || tfail "local-server status must exit 0"
jq -e 'has("online") and has("agent_ready") and has("models")' <<<"$ls" >/dev/null || tfail "local status shape"
out=$("$L" --dry-run local-server tune --ctx 32768 2>&1) || true; grep -q "Drop-in:" <<<"$out" || grep -q "no omarchy-local-agent" <<<"$out" || tfail "tune dry-run"
jq -e '.providers[] | select(.id=="local") | .base_url | endswith("/v1")' "$T/info.json" >/dev/null || tfail "local provider in info"
profile_write loc hermes local local none Qwen-test.gguf "$(jq -r '.providers[] | select(.id=="local") | .base_url' "$T/info.json")" interactive ""
printf '# Offline job\nStay local.\n' >"$(job_path loc)"
( source "$ROOT/lib/agents/hermes.sh"; agent_provision loc )
HL="$XDG_DATA_HOME/omarchy-agent-launcher/agents/loc/hermes"
grep -q "provider: lmstudio" "$HL/config.yaml" || tfail "local -> lmstudio provider"
grep -q "context_length:" "$HL/config.yaml" || tfail "local context_length"
grep -q "^LM_API_KEY=local$" "$HL/.env" || tfail "LM_API_KEY placeholder"
grep -q "auxiliary:" "$HL/config.yaml" || tfail "aux compression hint"
"$L" remove loc --yes >/dev/null
pass "local GPU provider: status, tune dry-run, hermes provisioning"

echo "== usage: fixture Hermes session store"
if command -v sqlite3 >/dev/null; then
  profile_write ub hermes local anthropic oauth claude-sonnet-5 - unattended ""
  printf '# Usage job\nCount tokens.\n' >"$(job_path ub)"
  UDB="$XDG_DATA_HOME/omarchy-agent-launcher/agents/ub/hermes/state.db"; mkdir -p "$(dirname "$UDB")"
  sqlite3 "$UDB" "create table sessions(id text primary key, title text, model text, billing_provider text, started_at real, ended_at real, last_activity_at real,
      message_count int, tool_call_count int, api_call_count int, input_tokens int, output_tokens int, cache_read_tokens int, cache_write_tokens int, reasoning_tokens int,
      estimated_cost_usd real, actual_cost_usd real, cost_status text, parent_session_id text, archived int default 0);
    insert into sessions values('s1','Write the changelog','claude-sonnet-5','anthropic',1700000000,1700000600,1700000600,10,4,6,100,2000,50000,10000,0,0.5,null,'estimated',null,0);
    insert into sessions values('s2','Old archived','claude-sonnet-5','anthropic',1690000000,1690000100,1690000100,1,0,1,5,5,0,0,0,9.9,null,'estimated',null,1);"
  u=$("$L" usage --json) || tfail "usage --json"
  [[ $(jq -r '.totals.prompt' <<<"$u") == 60100 && $(jq -r '.totals.output' <<<"$u") == 2000 ]] || tfail "usage totals: prompt must be input + cache read + cache write"
  [[ $(jq -r '.totals.cost_usd' <<<"$u") == 0.5 ]] || tfail "usage cost"
  [[ $(jq -r '.tasks[0].cost_basis' <<<"$u") == "hermes estimate (plan)" ]] || tfail "cost basis label"
  [[ $(jq -r '.tasks|length' <<<"$u") == 1 ]] || tfail "archived session must be skipped"
  st=$("$L" status --json); [[ $(jq -r '.agents[]|select(.name=="ub")|.usage.cost_usd' <<<"$st") == 0.5 ]] || tfail "usage in status --json"
  jq -e '.usage.totals and (.backends|type=="array") and .jarvis and .modal' <<<"$st" >/dev/null || tfail "status --json: jarvis/usage/backends/modal"
  "$L" usage | grep -q "Write the changelog" || tfail "usage (human)"
  "$L" remove ub --yes >/dev/null
  pass "usage: totals, per task, cost basis, archived skipped, in status"
else
  echo "  skip (sqlite3 not installed): usage"
fi

echo "== backends: registry, Modal dry-run, create --backend, Hermes custom provider"
b=$("$L" backends add --id big --kind modal-dedicated --gpu H100 --gpu-count 2 --model Qwen/Qwen3-32B --ctx 65536) || tfail "backends add"
[[ $(jq -r .gpu_hourly <<<"$b") == 3.95 && $(jq -r .app <<<"$b") == oal-big && $(jq -r .state <<<"$b") == configured ]] || tfail "backend fields"
BIGKEY=$(sed -n 's/^BACKEND_BIG_KEY=//p' "$XDG_CONFIG_HOME/omarchy-agent-launcher/secrets.env"); [[ ${#BIGKEY} -ge 24 ]] || tfail "backend key generated"
OAL_BACKEND_KEY=sk-shared "$L" backends add --id team --kind endpoint --url https://llm.example.com/v1 --model my-model --key-env >/dev/null || tfail "endpoint add"
"$L" backends list --json | jq -e 'map(.id) | index("team") != null and index("anthropic") != null and index("local") != null' >/dev/null || tfail "backends list mixes registry and providers"
"$L" backends add --id bad --kind modal-dedicated --gpu Z9 2>/dev/null && tfail "unknown gpu accepted"
"$L" modal gpus --json | jq -e '.gpus | map(.id) | index("H100") != null and index("T4") != null' >/dev/null || tfail "modal gpus"
out=$("$L" --dry-run backends deploy big 2>&1) || { echo "$out"; tfail "deploy dry-run"; }
grep -q "modal deploy" <<<"$out" && grep -q "OAL_GPU=H100" <<<"$out" && grep -q "OAL_GPU_COUNT=2" <<<"$out" || { echo "$out"; tfail "deploy env"; }
grep -q "$BIGKEY" <<<"$out" && tfail "backend key printed by dry-run"
[[ $(jq -r .big.state "$XDG_CONFIG_HOME/omarchy-agent-launcher/backends.json") == configured ]] || tfail "dry-run must not mark ready"
"$L" backends add --id sb --kind modal-sandbox --gpu L4 --timeout-hours 2 >/dev/null || tfail "sandbox add"
out=$("$L" --dry-run backends start sb 2>&1); grep -q "vllm_sandbox.py::start" <<<"$out" && grep -q "OAL_TIMEOUT_SECONDS=7200" <<<"$out" || tfail "sandbox start dry-run"
[[ $(jq -r .sb.model "$XDG_CONFIG_HOME/omarchy-agent-launcher/backends.json") == "Qwen/Qwen3-8B" ]] || tfail "model suggestion for L4"
"$L" backends deploy team 2>/dev/null && tfail "deploying an endpoint must fail"
printf 'job\n' | "$L" create --json --name onteam --backend team --mode unattended --job-stdin >"$T/c.json" || tfail "create --backend"
[[ $(jq -r .provider "$T/c.json") == endpoint && $(jq -r .backend "$T/c.json") == team && $(jq -r .base_url "$T/c.json") == https://llm.example.com/v1 && $(jq -r .model "$T/c.json") == my-model ]] || tfail "backend resolution"
( source "$ROOT/lib/agents/hermes.sh"; source "$ROOT/lib/backends.sh"; agent_provision onteam )
HT="$XDG_DATA_HOME/omarchy-agent-launcher/agents/onteam/hermes"
grep -q "provider: custom" "$HT/config.yaml" && grep -q 'base_url: "https://llm.example.com/v1"' "$HT/config.yaml" || tfail "custom provider config"
grep -q "^OPENAI_API_KEY=sk-shared$" "$HT/.env" || tfail "backend key in the agent's env"
grep -q "context_length: 32768" "$HT/config.yaml" || tfail "endpoint context length"
printf 'job\n' | "$L" create --name onbig --backend big --mode unattended --job-stdin 2>/dev/null && tfail "create on an undeployed Modal backend must fail"
"$L" backends remove team >/dev/null; grep -q "^BACKEND_TEAM_KEY" "$XDG_CONFIG_HOME/omarchy-agent-launcher/secrets.env" && tfail "key not removed with the backend"
"$L" remove onteam --yes >/dev/null
pass "backends"

echo "== jarvis: setup, delegate, result, brief"
if command -v hermes >/dev/null; then
  "$L" jarvis setup anthropic claude-sonnet-5 >/dev/null || tfail "jarvis setup"
  [[ $(jq -r .role "$(profile_path jarvis)") == chief-of-staff && $(jq -r .backend "$(profile_path jarvis)") == anthropic ]] || tfail "jarvis profile"
  ( source "$ROOT/lib/agents/hermes.sh"; source "$ROOT/lib/backends.sh"; source "$ROOT/lib/jarvis.sh"; OAL_ROOT="$ROOT"; agent_provision jarvis )
  [[ -f $XDG_DATA_HOME/omarchy-agent-launcher/agents/jarvis/hermes/skills/omarchy/jarvis/SKILL.md ]] || tfail "jarvis skill copied into its home"
  grep -q "chief of staff" "$XDG_DATA_HOME/omarchy-agent-launcher/agents/jarvis/hermes/SOUL.md" || tfail "jarvis SOUL"
  out=$("$L" --dry-run --inline launch jarvis 2>&1); grep -q -- "-s jarvis" <<<"$out" || { echo "$out"; tfail "jarvis skill preload flag"; }
  out=$(printf 'Summarize the repo.\n' | "$L" --dry-run delegate --backend anthropic --name summ --task-title "Summarize" --job-stdin 2>&1) || { echo "$out"; tfail "delegate"; }
  [[ $(jq -r .parent "$(profile_path summ)") == jarvis && $(jq -r .role "$(profile_path summ)") == worker && $(jq -r .mode "$(profile_path summ)") == unattended && $(jq -r .task_title "$(profile_path summ)") == Summarize ]] || tfail "delegate profile"
  grep -q "would open window" <<<"$out" || tfail "delegate must launch the worker"
  out=$(printf 'x\n' | "$L" --dry-run delegate --backend anthropic --name summ2 --job-stdin --wait 2>&1); grep -q "would run and wait" <<<"$out" || { echo "$out"; tfail "delegate --wait dry-run"; }
  "$L" result summ >/dev/null 2>&1 && tfail "result without runs must fail"
  out=$(printf 'x\n' | "$L" --dry-run delegate --backend gemini --name nokey --job-stdin 2>&1) && tfail "delegate to a keyless provider must fail"
  grep -q "needs GEMINI_API_KEY" <<<"$out" || { echo "$out"; tfail "keyless provider message"; }
  mkdir -p "$XDG_DATA_HOME/omarchy-agent-launcher/agents/summ/runs"; printf '\033[32mdone\033[0m: 3 files\n' >"$XDG_DATA_HOME/omarchy-agent-launcher/agents/summ/runs/20260908-120000.log"
  "$L" result summ | grep -q "^done: 3 files$" || tfail "result strips ANSI"
  "$L" jarvis brief | grep -q "Jarvis brief" || tfail "jarvis brief"
  st=$("$L" status --json); [[ $(jq -r '.jarvis.configured' <<<"$st") == true && $(jq -r '.jarvis.workers|index("summ") != null' <<<"$st") == true ]] || tfail "jarvis status lists its workers"
  [[ $(jq -r '.agents[]|select(.name=="summ")|.parent' <<<"$st") == jarvis ]] || tfail "worker parent in status"
  "$L" remove summ --yes >/dev/null; "$L" remove summ2 --yes >/dev/null; "$L" remove jarvis --yes >/dev/null
  pass "jarvis"

  echo "== oauth inheritance: a new home copies an existing sign-in for the same provider"
  "$L" backends list --json | jq -e '.[] | select(.id=="anthropic") | .auth == "api-key"' >/dev/null || tfail "without a sign-in anthropic falls back to the saved key"
  "$L" backends list --json | jq -e '.[] | select(.id=="nous") | .ready == false and .auth == "oauth"' >/dev/null || tfail "an OAuth-only provider is not ready before a sign-in"
  profile_write donor hermes local anthropic oauth claude-sonnet-5 - interactive ""; printf '# Donor\nx\n' >"$(job_path donor)"
  profile_set donor signed_in true; mkdir -p "$(stage_dir donor)/hermes"; printf '{"anthropic":{"token":"t"}}\n' >"$(stage_dir donor)/hermes/auth.json"
  "$L" backends list --json | jq -e '.[] | select(.id=="anthropic") | .ready == true and .state == "signed in"' >/dev/null || tfail "anthropic ready after a sign-in"
  printf 'w\n' | "$L" create --name heir --backend anthropic --mode unattended --job-stdin >/dev/null || tfail "create heir"
  ( source "$ROOT/lib/agents/hermes.sh"; source "$ROOT/lib/backends.sh"; source "$ROOT/lib/jarvis.sh"; OAL_ROOT="$ROOT"; agent_provision heir )
  [[ -s $(stage_dir heir)/hermes/auth.json && $(stat -c %a "$(stage_dir heir)/hermes/auth.json") == 600 ]] || tfail "auth.json inherited"
  [[ $(jq -r .signed_in "$(profile_path heir)") == true ]] || tfail "heir marked signed in"
  "$L" jarvis setup anthropic >/dev/null; ( source "$ROOT/lib/agents/hermes.sh"; source "$ROOT/lib/backends.sh"; source "$ROOT/lib/jarvis.sh"; OAL_ROOT="$ROOT"; agent_provision jarvis )
  [[ $(jq -r .signed_in "$(profile_path jarvis)") == true ]] || tfail "jarvis inherits the sign-in"
  "$L" jarvis setup anthropic >/dev/null; [[ $(jq -r .signed_in "$(profile_path jarvis)") == true ]] || tfail "jarvis setup must keep signed_in for the same provider"
  secret_set HF_TOKEN hf_secret_123; out=$("$L" --dry-run backends deploy big 2>&1); grep -q "hf_secret_123" <<<"$out" && tfail "HF_TOKEN printed by dry-run"
  "$L" remove heir --yes >/dev/null; "$L" remove donor --yes >/dev/null; "$L" remove jarvis --yes >/dev/null
  pass "oauth inheritance, backend readiness, HF_TOKEN redaction"
else
  echo "  skip (hermes not installed): jarvis"
fi

echo "== list / show / remove"
out=$("$L" list); grep -q "^prov " <<<"$out" || tfail "list"
out=$("$L" show prov); grep -q '"agent": "hermes"' <<<"$out" || tfail "show"
printf 'y\n' >"$OAL_ANSWERS"; "$L" remove prov >/dev/null; [[ ! -f $(profile_path prov) && ! -d $H ]] || tfail "remove"
"$L" remove provoc --yes >/dev/null || tfail "remove --yes"; [[ ! -f $(profile_path provoc) ]] || tfail "remove --yes left profile"
tail -n 1 "$S/events.jsonl" | grep -q '"kind":"removed"' || tfail "removed event"
pass "manage commands"
echo "ALL TESTS PASSED"
