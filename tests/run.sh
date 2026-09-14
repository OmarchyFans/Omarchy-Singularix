#!/bin/bash
# Drives the new-agent form with scripted answers under throwaway XDG dirs,
# then checks the saved profile, the provisioned agent home, and dry-run
# launches for every agent × runtime. Needs bash, jq, gum (for `gum write`
# is bypassed; only the binary's presence is checked by the launcher).
set -euo pipefail
# The suite may run inside a launcher-spawned agent session; its OAL_* environment
# (OAL_AGENT, OAL_POPUP, …) must not leak into the commands under test — e.g.
# cmd_delegate's `${OAL_AGENT:-}` fallback would otherwise pick up the
# caller's identity instead of the test's, giving worker profiles the wrong
# parent.
unset "${!OAL_@}" 2>/dev/null || true
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export XDG_CONFIG_HOME="$T/config" XDG_DATA_HOME="$T/data" XDG_STATE_HOME="$T/state" HOME_REAL="$HOME"
export OAL_SENTINEL_BIN=oal-test-no-sentinel   # never the real Sentinel install; the sentinel block uses a stub
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

echo "== focus-window uses Hyprland's Lua dispatch"
out=$("$L" --dry-run focus-window "Agent Dashboard" 2>&1) || { echo "$out"; tfail "focus-window dry-run"; }
grep -q 'hl.dsp.focus' <<<"$out" || { echo "$out"; tfail "focus-window must use hl.dsp.focus"; }
pass "focus-window dispatch"

echo "== dry-run launches for every agent × runtime"
for a in hermes openclaw; do for r in local docker cloud; do
  n="m-$a-$r"; profile_write "$n" "$a" "$r" openrouter api-key m - interactive ""; cp "$(job_path prov)" "$(job_path "$n")"
  inl=$("$L" --dry-run --inline launch "$n" 2>&1) || { echo "$inl"; tfail "dry-run $n"; }
  grep -q "would launch" <<<"$inl" || { echo "$inl"; tfail "no launch line for $n"; }
  out=$("$L" --dry-run launch "$n" 2>&1) || { echo "$out"; tfail "dry-run window $n"; }
  grep -q "would open window" <<<"$out" || { echo "$out"; tfail "no window line for $n"; }
  # The session must live on this config's own tmux socket, never the default server
  # (a test run or another config could otherwise see or kill a real agent by name).
  if command -v tmux >/dev/null; then grep -q -- "-S $XDG_STATE_HOME/omarchy-agent-launcher/tmux/oal-$n.sock" <<<"$out" || { echo "$out"; tfail "tmux socket for $n"; }; fi
  # The private server pins the terminal title, so Chat finds the window instead of opening a duplicate.
  if command -v tmux >/dev/null; then grep -q "set-titles-string" <<<"$out" || { echo "$out"; tfail "title pin for $n"; }; fi
  case $r in docker) grep -q "docker run -it --rm" <<<"$inl" || tfail "$n docker cmd";; cloud) grep -q "cloud console $n" <<<"$inl" || { echo "$inl"; tfail "$n cloud cmd"; };; esac
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

echo "== models --json: picker tree, prices, vendor facts, IP-safe badge"
mkdir -p "$T/cache/omarchy-agent-launcher"
cat >"$T/cache/omarchy-agent-launcher/models.json" <<'J'
{"anthropic":{"models":{"claude-sonnet-5":{"name":"Claude Sonnet 5","tool_call":true,"release_date":"2026-05-01","cost":{"input":3,"output":15},"limit":{"context":1000000}}}},
 "deepseek":{"models":{"deepseek-chat":{"name":"DeepSeek Chat","tool_call":true,"release_date":"2026-01-01","cost":{"input":0.27,"output":1.1},"limit":{"context":128000}}}},
 "openrouter":{"models":{"x/y":{"name":"Y","tool_call":true,"release_date":"2026-01-01","cost":{"input":1,"output":2},"limit":{"context":8000}}}}}
J
XDG_CACHE_HOME="$T/cache" "$L" models --json >"$T/models.json" 2>/dev/null || tfail "models --json"
jq -e 'has("local") and (.local | has("served") and has("rows")) and (.online | length > 0)' "$T/models.json" >/dev/null || tfail "models tree shape"
jq -e '.online | all(has("backend") and has("vendor") and has("ready") and has("needs") and has("country") and has("ip_safe") and has("badge") and has("models"))' "$T/models.json" >/dev/null || tfail "online entry keys"
jq -e '.online[] | select(.backend == "anthropic") | .ready == true and (.models[0] | .id == "claude-sonnet-5" and .input == 3 and .output == 15)' "$T/models.json" >/dev/null || tfail "anthropic ready with catalog prices"
jq -e '.online[] | select(.backend == "deepseek") | .ip_safe == false and .badge == "unsafe" and .country == "CN"' "$T/models.json" >/dev/null || tfail "deepseek not IP-safe"
jq -e '.online[] | select(.backend == "openrouter") | .ip_safe == null and .badge == "varies"' "$T/models.json" >/dev/null || tfail "openrouter aggregator badge"
jq -e '.online[] | select(.backend == "xai") | .ip_safe == null and .badge == "unverified"' "$T/models.json" >/dev/null || tfail "xai unverified"
jq -e '[.online[].ready] | . == (sort | reverse)' "$T/models.json" >/dev/null || tfail "ready entries not first"
jq -e 'to_entries | all(.value | has("label") and has("processing_countries") and has("trains_on_api_data") and has("basis") and (.sources | length > 0) and .reviewed != null)' "$ROOT/data/vendors.json" >/dev/null || tfail "vendors.json facts incomplete"
printf '{"acme":{"label":"Acme","processing_countries":["JP"],"trains_on_api_data":false},"bad":{"label":"Bad","processing_countries":["US","CN"],"trains_on_api_data":false}}' >"$T/vendors.json"
OAL_ROOT="$ROOT" OAL_VENDORS_FILE="$T/vendors.json"; source "$ROOT/lib/vendors.sh"
jq -e '.ip_safe == true and .badge == "safe" and .country == "JP"' <<<"$(vendor_json acme)" >/dev/null || tfail "safe derivation"
jq -e '.ip_safe == false and .badge == "unsafe"' <<<"$(vendor_json bad)" >/dev/null || tfail "unsafe jurisdiction derivation"
jq -e '.badge == null' <<<"$(vendor_json nobody)" >/dev/null || tfail "unknown vendor has no badge"
unset OAL_VENDORS_FILE
XDG_CACHE_HOME="$T/cache" "$L" models 2>/dev/null | grep -q "not IP-safe" || tfail "models plain listing"
pass "models tree, catalog prices, badges, ready-first order"

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
if command -v tmux >/dev/null; then
  # A real session on the private socket is seen; removing the profile kills only that server.
  SOCK="$XDG_STATE_HOME/omarchy-agent-launcher/tmux/oal-issue-triage.sock"; mkdir -p "$(dirname "$SOCK")"
  tmux -S "$SOCK" new-session -d -s oal-issue-triage -- sleep 300
  [[ $("$L" status --json | jq -r '.agents[] | select(.name=="issue-triage") | .running') == true ]] || tfail "running via private socket"
  "$L" stop issue-triage >/dev/null; tmux -S "$SOCK" has-session -t oal-issue-triage 2>/dev/null && tfail "stop must kill the private session"
  grep -q '"kind":"stopped"' "$S/events.jsonl" || tfail "stopped event"
fi
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
  jq -e '.usage.totals and (.backends|type=="array") and .rix' <<<"$st" >/dev/null || tfail "status --json: rix/usage/backends"
  "$L" usage | grep -q "Write the changelog" || tfail "usage (human)"
  "$L" remove ub --yes >/dev/null
  pass "usage: totals, per task, cost basis, archived skipped, in status"
else
  echo "  skip (sqlite3 not installed): usage"
fi

echo "== backends: endpoint registry, test, create --backend, Hermes custom provider"
OAL_BACKEND_KEY=sk-shared "$L" backends add --id team --kind endpoint --url https://llm.example.com/v1 --model my-model --key-env >"$T/team.json" || tfail "endpoint add"
[[ $(jq -r .kind "$T/team.json") == endpoint && $(jq -r .state "$T/team.json") == ready && $(jq -r .url "$T/team.json") == https://llm.example.com/v1 ]] || tfail "endpoint fields"
grep -q "sk-shared" "$T/team.json" && tfail "backend key echoed by add"
"$L" backends list --json | jq -e 'map(.id) | index("team") != null and index("anthropic") != null and index("local") != null' >/dev/null || tfail "backends list mixes registry and providers"
"$L" backends add --id gpu --kind dedicated --url https://x/v1 --model m 2>/dev/null && tfail "a non-endpoint kind was accepted"
"$L" backends add --id nourl --model m 2>/dev/null && tfail "an endpoint without --url was accepted"
out=$("$L" --dry-run backends test team 2>&1) || { echo "$out"; tfail "backends test dry-run"; }
grep -q "would GET https://llm.example.com/v1/models with the saved key" <<<"$out" || { echo "$out"; tfail "backends test plan"; }
grep -q "sk-shared" <<<"$out" && tfail "backend key printed by dry-run"
printf 'job\n' | "$L" create --json --name onteam --backend team --mode unattended --job-stdin >"$T/c.json" || tfail "create --backend"
[[ $(jq -r .provider "$T/c.json") == endpoint && $(jq -r .backend "$T/c.json") == team && $(jq -r .base_url "$T/c.json") == https://llm.example.com/v1 && $(jq -r .model "$T/c.json") == my-model ]] || tfail "backend resolution"
( source "$ROOT/lib/agents/hermes.sh"; source "$ROOT/lib/backends.sh"; agent_provision onteam )
HT="$XDG_DATA_HOME/omarchy-agent-launcher/agents/onteam/hermes"
grep -q "provider: custom" "$HT/config.yaml" && grep -q 'base_url: "https://llm.example.com/v1"' "$HT/config.yaml" || tfail "custom provider config"
grep -q "^OPENAI_API_KEY=sk-shared$" "$HT/.env" || tfail "backend key in the agent's env"
grep -q "context_length: 32768" "$HT/config.yaml" || tfail "endpoint context length"
"$L" backends remove team >/dev/null; grep -q "^BACKEND_TEAM_KEY" "$XDG_CONFIG_HOME/omarchy-agent-launcher/secrets.env" && tfail "key not removed with the backend"
"$L" remove onteam --yes >/dev/null
profile_write oldrt hermes gone openrouter api-key m - interactive ""; cp "$(job_path prov)" "$(job_path oldrt)"
out=$("$L" --dry-run launch oldrt 2>&1) && tfail "a profile with a removed runtime must not launch"
grep -q "recreate it on local, docker, or cloud" <<<"$out" || { echo "$out"; tfail "removed-runtime message"; }
rm -f "$(profile_path oldrt)" "$(job_path oldrt)"
pass "backends"

echo "== cloud runtime: omarchy.fans API (fake), device sign-in, create, console ticket, destroy"
if command -v python3 >/dev/null && command -v curl >/dev/null; then
(
  set -uo pipefail
  PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  LOG="$T/cloud-requests.jsonl"; : >"$LOG"
  python3 "$ROOT/tests/fake_api.py" "$PORT" "$LOG" &
  API_PID=$!
  trap 'kill $API_PID 2>/dev/null' EXIT
  for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$PORT/v1/pricing" >/dev/null 2>&1 && break; sleep 0.1; done
  export OFC_API_URL="http://127.0.0.1:$PORT/v1" OFC_NO_BROWSER=1 OFC_POLL_INTERVAL=0 OFC_PREPARE_TIMEOUT=20
  source "$ROOT/lib/backends.sh"
  source "$ROOT/lib/runtimes/cloud.sh"
  requests() { jq -c "select(.method == \"$1\" and (.path | test(\"$2\")))" "$LOG"; }

  out=$(rt_check) && tfail "cloud rt_check must fail before sign-in"
  grep -q "sign-in needed" <<<"$out" || tfail "cloud rt_check hint: $out"
  jq -e '.agents[] | select(.id=="hermes") | .runtimes.cloud.ok == false' <<<"$("$L" info --json)" >/dev/null || tfail "info --json reports the cloud runtime"

  out=$(cloud_login 2>&1) || { echo "$out"; tfail "cloud login"; }
  grep -q "H7K4-QX9M" <<<"$out" && grep -q "signed in as milton" <<<"$out" || tfail "device flow output: $out"
  grep -q "^OFC_TOKEN=ofc_test_token_123$" "$OAL_SECRETS" || tfail "OFC_TOKEN not saved"
  [[ $(requests POST '/v1/device/token$' | wc -l) == 3 ]] || tfail "device flow polls"
  out=$(rt_check) || tfail "cloud rt_check after sign-in"; grep -q "signed in · org milton" <<<"$out" || tfail "rt_check line: $out"

  # create: validation, then a real profile on the cloud runtime
  printf 'job\n' | "$L" create --name cl-bad --agent hermes --runtime cloud --provider local --job-stdin 2>/dev/null && tfail "cloud + local provider must be refused"
  printf 'job\n' | "$L" create --name cl-bad --agent hermes --runtime cloud --provider anthropic --auth oauth --job-stdin 2>/dev/null && tfail "cloud + browser sign-in must be refused"
  printf 'job\n' | "$L" create --name cl-bad --agent hermes --runtime cloud --provider openrouter --size xl --job-stdin 2>/dev/null && tfail "bad --size accepted"
  printf 'job\n' | "$L" create --name cl-bad --agent hermes --runtime local --provider openrouter --size m --job-stdin 2>/dev/null && tfail "--size outside cloud accepted"
  secret_set OPENROUTER_API_KEY or-test-key
  printf '# Job\nResearch the last release.\n' | "$L" create --json --name researcher --agent hermes --runtime cloud --provider openrouter --auth api-key \
    --model anthropic/claude-sonnet-5 --size m --skill research/deep-research --mode interactive --job-stdin >"$T/cl.json" || tfail "create --runtime cloud"
  [[ $(jq -r .runtime "$T/cl.json") == cloud && $(jq -r .size "$T/cl.json") == m ]] || tfail "cloud profile"

  n_before=$(wc -l <"$LOG")
  out=$("$L" --dry-run --inline launch researcher 2>&1) || { echo "$out"; tfail "cloud dry-run launch"; }
  grep -q "would POST .*/agents" <<<"$out" && grep -q '<redacted>' <<<"$out" || { echo "$out"; tfail "cloud dry-run plan"; }
  grep -q "or-test-key\|ofc_test_token_123" <<<"$out" && tfail "dry-run printed a secret"
  grep -q "cloud console researcher" <<<"$out" || { echo "$out"; tfail "cloud session command"; }
  [[ $(wc -l <"$LOG") == "$n_before" ]] || tfail "dry-run hit the API"

  out=$(rt_prepare researcher 2>&1) || { echo "$out"; tfail "cloud rt_prepare"; }
  grep -q "cloud agent agt_1 created" <<<"$out" && grep -q "agt_1 is sleeping" <<<"$out" || tfail "prepare output: $out"
  create=$(requests POST '/v1/agents$')
  jq -e '.body | .name == "researcher" and .provider == "openrouter" and .size == "m" and .secrets == {"OPENROUTER_API_KEY":"or-test-key"}
    and (.job_md | test("Research the last release")) and (has("home") | not)' <<<"$create" >/dev/null || { echo "$create"; tfail "POST /agents body"; }
  jq -e '.auth == "Bearer ofc_test_token_123"' <<<"$create" >/dev/null || tfail "bearer token not sent from the curl config pipe"
  rt_prepare researcher >/dev/null 2>&1 || tfail "second rt_prepare"
  [[ $(requests POST '/v1/agents$' | wc -l) == 1 ]] || tfail "second prepare must not POST again"

  printf 'Nightly report.\n' | "$L" create --name batch --agent hermes --runtime cloud --provider openrouter --auth api-key --model m --mode unattended --job-stdin >/dev/null || tfail "create unattended cloud agent"
  rt_prepare batch >/dev/null 2>&1 || tfail "rt_prepare unattended"
  requests POST '/v1/agents/agt_2/wake$' | jq -e '.body.mode == "unattended"' >/dev/null || tfail "an unattended cloud agent must wake unattended"
  rt_destroy batch >/dev/null; "$L" remove batch --yes >/dev/null
  out=$(cloud_wake researcher) && [[ $out == "researcher is awake" ]] || tfail "wake: $out"
  out=$("$L" cloud status researcher) || tfail "cloud status NAME"; grep -q "secrets: OPENROUTER_API_KEY" <<<"$out" || tfail "status: $out"
  out=$(cloud_sleep researcher) && [[ $out == "researcher is sleeping" ]] || tfail "sleep: $out"
  out=$("$L" cloud pricing) || tfail "cloud pricing"; grep -qE 'Plus +\$5/mo' <<<"$out" || tfail "pricing: $out"
  out=$("$L" cloud gpus) || tfail "cloud gpus"; grep -q "Compact 24 GB" <<<"$out" || tfail "gpus: $out"

  # console: a one-time ticket in the URL, never the token on websocat's argv
  mkdir -p "$T/fakebin"
  printf '#!/bin/bash\nprintf "%%s\\n" "$@" >"%s/websocat.argv"\n' "$T" >"$T/fakebin/websocat"; chmod +x "$T/fakebin/websocat"
  PATH="$T/fakebin:$PATH" rt_console researcher </dev/null >/dev/null 2>&1 || tfail "console with a fake websocat"
  [[ -n $(requests POST '/v1/agents/agt_1/console-ticket$') ]] || tfail "console ticket not requested"
  grep -q "ticket=oct_test_ticket" "$T/websocat.argv" || { cat "$T/websocat.argv"; tfail "ticket not in the console URL"; }
  grep -q "ofc_test_token_123\|Authorization" "$T/websocat.argv" && tfail "token on websocat argv"
  ! grep -nE 'Bearer \$\(cloud_token\)|--data-binary "\$body"' "$ROOT/lib/runtimes/cloud.sh" || tfail "cloud.sh puts the token or a body on argv"

  out=$(rt_destroy researcher) && [[ $out == "cloud agent agt_1 destroyed" ]] || tfail "destroy: $out"
  [[ -z $(profile_get researcher cloud_agent_id) ]] || tfail "cloud_agent_id not cleared"
  "$L" remove researcher --yes >/dev/null
  out=$(cloud_logout 2>&1) || tfail "logout exit"
  [[ $out == "signed out of Omarchy.Fans Cloud" ]] || tfail "logout: $out"
  grep -q "^OFC_TOKEN=" "$OAL_SECRETS" && tfail "token still saved after logout"
  [[ -n $(requests POST '/v1/tokens/self/revoke$') ]] || tfail "token not revoked through /tokens/self/revoke"
  [[ -z $(requests DELETE '/v1/tokens/') ]] || tfail "a CLI token must not call DELETE /tokens/:id"
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ofc_test_token_123" "$OFC_API_URL/me"); [[ $code == 401 ]] || tfail "revoked token still works ($code)"
  # an already-revoked token gets 401: that counts as signed out, not as a failure
  secret_set OFC_TOKEN ofc_test_token_123
  out=$(cloud_logout 2>&1) && [[ $out == "signed out of Omarchy.Fans Cloud" ]] || tfail "logout with a dead token: $out"
  # an unreachable server: forget the token here, but say it was not revoked
  secret_set OFC_TOKEN ofc_unrevoked_example
  out=$(OFC_API_URL=http://127.0.0.1:9/v1 OFC_HTTP_TIMEOUT=3 cloud_logout 2>&1) || tfail "logout exit when offline"
  grep -q "signed out on this computer" <<<"$out" && grep -q "revoke it under Tokens" <<<"$out" || tfail "offline logout message: $out"
  grep -q "^OFC_TOKEN=" "$OAL_SECRETS" && tfail "token kept after offline logout"
  exit 0
) || exit 1
pass "cloud runtime: sign-in, create validation, prepare, wake/sleep, ticketed console, destroy, logout"
else
  echo "  skip (python3 or curl missing): cloud runtime"
fi

echo "== supplier-neutral: no cloud supplier names ship in the plugin"
# Spelled with brackets so this file does not match itself.
if grep -rniwE 's[p]rites?|m[o]dal|f[l]y|f[l]yctl' "$ROOT" --exclude-dir=.git --exclude-dir=.claude; then tfail "supplier names found"; fi
pass "no supplier names"

echo "== rix migration: a pre-0.9 jarvis chief of staff becomes rix"
profile_write jarvis hermes local anthropic api-key claude-sonnet-5 - interactive ""
profile_set jarvis role '"chief-of-staff"'
printf '# Chief of staff\nYou are Jarvis, the chief of staff.\n' >"$(job_path jarvis)"
mkdir -p "$(stage_dir jarvis)/hermes"; printf 'You are "jarvis", chief of staff.\n' >"$(stage_dir jarvis)/hermes/SOUL.md"
profile_write worker1 hermes local anthropic api-key claude-sonnet-5 - unattended ""
profile_set worker1 parent '"jarvis"'
event_emit jarvis blocker "Needs a decision" --level blocker --key decide >/dev/null 2>&1
"$L" list >/dev/null 2>&1 || tfail "list after migration"
profile_exists rix && ! profile_exists jarvis || tfail "profile moved to rix"
[[ $(jq -r .name "$(profile_path rix)") == rix ]] || tfail "profile name is rix"
grep -q "You are Rix" "$(job_path rix)" || tfail "job renamed"
[[ -d $(stage_dir rix) && ! -d $(stage_dir jarvis) ]] || tfail "agent home moved"
grep -q '"rix"' "$(stage_dir rix)/hermes/SOUL.md" || tfail "SOUL renamed"
[[ $(jq -r .parent "$(profile_path worker1)") == rix ]] || tfail "worker parent rewritten"
jq -e 'has("rix/decide") and (has("jarvis/decide") | not) and .["rix/decide"].agent == "rix"' "$OAL_BLOCKERS" >/dev/null || { cat "$OAL_BLOCKERS"; tfail "blocker rekeyed"; }
"$L" list >/dev/null 2>&1; profile_exists rix || tfail "migration must be idempotent"
"$L" remove worker1 --yes >/dev/null; "$L" remove rix --yes >/dev/null; rm -f "$OAL_BLOCKERS" "$OAL_BLOCKERS.bak"
pass "rix migration"

echo "== rix: setup, delegate, result, brief"
if command -v hermes >/dev/null; then
  "$L" rix setup anthropic claude-sonnet-5 >/dev/null || tfail "rix setup"
  [[ $(jq -r .role "$(profile_path rix)") == chief-of-staff && $(jq -r .backend "$(profile_path rix)") == anthropic ]] || tfail "rix profile"
  ( source "$ROOT/lib/agents/hermes.sh"; source "$ROOT/lib/backends.sh"; source "$ROOT/lib/rix.sh"; OAL_ROOT="$ROOT"; agent_provision rix )
  [[ -f $XDG_DATA_HOME/omarchy-agent-launcher/agents/rix/hermes/skills/omarchy/rix/SKILL.md ]] || tfail "rix skill copied into its home"
  grep -q "chief of staff" "$XDG_DATA_HOME/omarchy-agent-launcher/agents/rix/hermes/SOUL.md" || tfail "rix SOUL"
  out=$("$L" --dry-run --inline launch rix 2>&1); grep -q -- "-s rix" <<<"$out" || { echo "$out"; tfail "rix skill preload flag"; }
  out=$(printf 'Summarize the repo.\n' | "$L" --dry-run delegate --backend anthropic --name summ --task-title "Summarize" --approved-usd 999 --job-stdin 2>&1) || { echo "$out"; tfail "delegate"; }
  [[ $(jq -r .parent "$(profile_path summ)") == rix && $(jq -r .role "$(profile_path summ)") == worker && $(jq -r .mode "$(profile_path summ)") == unattended && $(jq -r .task_title "$(profile_path summ)") == Summarize ]] || tfail "delegate profile"
  grep -q "would open window" <<<"$out" || tfail "delegate must launch the worker"
  out=$(printf 'x\n' | "$L" --dry-run delegate --backend anthropic --name summ2 --approved-usd 999 --job-stdin --wait 2>&1); grep -q "would run and wait" <<<"$out" || { echo "$out"; tfail "delegate --wait dry-run"; }
  "$L" result summ >/dev/null 2>&1 && tfail "result without runs must fail"
  out=$(printf 'x\n' | "$L" --dry-run delegate --backend gemini --name nokey --job-stdin 2>&1) && tfail "delegate to a keyless provider must fail"
  grep -q "needs GEMINI_API_KEY" <<<"$out" || { echo "$out"; tfail "keyless provider message"; }
  mkdir -p "$XDG_DATA_HOME/omarchy-agent-launcher/agents/summ/runs"; printf '\033[32mdone\033[0m: 3 files\n' >"$XDG_DATA_HOME/omarchy-agent-launcher/agents/summ/runs/20260908-120000.log"
  "$L" result summ | grep -q "^done: 3 files$" || tfail "result strips ANSI"
  "$L" rix brief | grep -q "Rix brief" || tfail "rix brief"
  st=$("$L" status --json); [[ $(jq -r '.rix.configured' <<<"$st") == true && $(jq -r '.rix.workers|index("summ") != null' <<<"$st") == true ]] || tfail "rix status lists its workers"
  [[ $(jq -r '.agents[]|select(.name=="summ")|.parent' <<<"$st") == rix ]] || tfail "worker parent in status"
  # "jarvis" is the pre-0.9 name: the subcommand and the status key still work.
  "$L" jarvis brief | grep -q "Rix brief" || tfail "jarvis alias: brief"
  [[ $("$L" jarvis status | jq -r .name) == rix ]] || tfail "jarvis alias: status"
  [[ $(jq -r '.jarvis.name' <<<"$st") == rix ]] || tfail "status --json keeps a jarvis key"
  "$L" remove summ --yes >/dev/null; "$L" remove summ2 --yes >/dev/null; "$L" remove rix --yes >/dev/null
  pass "rix"

  echo "== oauth inheritance: a new home copies an existing sign-in for the same provider"
  "$L" backends list --json | jq -e '.[] | select(.id=="anthropic") | .auth == "api-key"' >/dev/null || tfail "without a sign-in anthropic falls back to the saved key"
  "$L" backends list --json | jq -e '.[] | select(.id=="nous") | .ready == false and .auth == "oauth"' >/dev/null || tfail "an OAuth-only provider is not ready before a sign-in"
  profile_write donor hermes local anthropic oauth claude-sonnet-5 - interactive ""; printf '# Donor\nx\n' >"$(job_path donor)"
  profile_set donor signed_in true; mkdir -p "$(stage_dir donor)/hermes"; printf '{"anthropic":{"token":"t"}}\n' >"$(stage_dir donor)/hermes/auth.json"
  "$L" backends list --json | jq -e '.[] | select(.id=="anthropic") | .ready == true and .state == "signed in"' >/dev/null || tfail "anthropic ready after a sign-in"
  printf 'w\n' | "$L" create --name heir --backend anthropic --mode unattended --job-stdin >/dev/null || tfail "create heir"
  ( source "$ROOT/lib/agents/hermes.sh"; source "$ROOT/lib/backends.sh"; source "$ROOT/lib/rix.sh"; OAL_ROOT="$ROOT"; agent_provision heir )
  [[ -s $(stage_dir heir)/hermes/auth.json && $(stat -c %a "$(stage_dir heir)/hermes/auth.json") == 600 ]] || tfail "auth.json inherited"
  [[ $(jq -r .signed_in "$(profile_path heir)") == true ]] || tfail "heir marked signed in"
  "$L" rix setup anthropic >/dev/null; ( source "$ROOT/lib/agents/hermes.sh"; source "$ROOT/lib/backends.sh"; source "$ROOT/lib/rix.sh"; OAL_ROOT="$ROOT"; agent_provision rix )
  [[ $(jq -r .signed_in "$(profile_path rix)") == true ]] || tfail "rix inherits the sign-in"
  "$L" rix setup anthropic >/dev/null; [[ $(jq -r .signed_in "$(profile_path rix)") == true ]] || tfail "rix setup must keep signed_in for the same provider"
  "$L" remove heir --yes >/dev/null; "$L" remove donor --yes >/dev/null; "$L" remove rix --yes >/dev/null
  pass "oauth inheritance, backend readiness"
else
  echo "  skip (hermes not installed): rix"
fi

echo "== sentinel: Rix reads advisories, records who handles them, Sentinel verifies"
st=$("$L" status --json); [[ $(jq -r '.sentinel.installed' <<<"$st") == false ]] || tfail "sentinel not installed by default in tests"
out=$("$L" sentinel advisories 2>&1) && tfail "sentinel without an install must fail"
grep -q "Sentinel is not installed" <<<"$out" || { echo "$out"; tfail "install hint"; }
SD="$T/sentinel-stub"; mkdir -p "$SD" "$T/bin"
cat >"$SD/f.json" <<'JSON'
{"a1":{"id":"a1","severity":"high","arena":"codebase","asset":"repo-1","title":"Leaked key in config.js","status":"open","advised_at":"2026-09-13T01:00:00Z","advisory":"/adv/a1.md"},
 "a2":{"id":"a2","severity":"critical","arena":"attack-vectors","asset":"domain-1","title":"No DMARC record","status":"open","advised_at":"2026-09-13T02:00:00Z","advisory":"/adv/a2.md"},
 "a3":{"id":"a3","severity":"medium","arena":"codebase","asset":"repo-1","title":"Unpinned action","status":"open"}}
JSON
cat >"$T/bin/sentinel-stub" <<STUB
#!/bin/bash
F="$SD/f.json"; a=(); for x in "\$@"; do [[ \$x == --json || \$x == --all ]] || a+=("\$x"); done
case \${a[0]} in
  advisories) jq -c '[.[] | select(.advisory) | {id, severity, arena, title, status, advised_at, advisory}]' "\$F" ;;
  findings)   jq -c '[.[]]' "\$F" ;;
  advisory)   jq -e --arg id "\${a[1]}" '.[\$id].advisory' "\$F" >/dev/null && echo "# Sentinel advisory for Rix · \${a[1]}" ;;
  show)       jq -e --arg id "\${a[1]}" '.[\$id]' "\$F" ;;
  scan)       echo "scan \${a[1]}" >>"$SD/scans"; [[ -f "$SD/fixed" ]] && while read -r id; do jq --arg id "\$id" '.[\$id].status = "fixed"' "\$F" >"\$F.t" && mv "\$F.t" "\$F"; done <"$SD/fixed"; echo '{}' ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$T/bin/sentinel-stub"
export OAL_SENTINEL_BIN="$T/bin/sentinel-stub"
st=$("$L" status --json)
jq -e '.sentinel.installed and .sentinel.pending == 2 and .sentinel.assigned == 0' <<<"$st" >/dev/null || { jq .sentinel <<<"$st"; tfail "status --json sentinel counts"; }
adv=$("$L" sentinel advisories --json)
[[ $(jq -r '.[0].id' <<<"$adv") == a2 && $(jq length <<<"$adv") == 2 ]] || { echo "$adv"; tfail "advisories: critical first, only advised findings"; }
"$L" sentinel read a1 | grep -q "Sentinel advisory for Rix · a1" || tfail "sentinel read"
"$L" sentinel assign a1 >/dev/null 2>&1 && tfail "assign needs a worker"
"$L" sentinel assign nope fix-nope >/dev/null 2>&1 && tfail "assign an unknown advisory must fail"
"$L" sentinel assign a1 fix-a1 >/dev/null || tfail "sentinel assign"
[[ $("$L" sentinel advisories --json | jq -r '.[] | select(.id=="a1") | "\(.rix_state) \(.worker)"') == "assigned fix-a1" ]] || tfail "assigned state"
grep -q '"key":"sentinel-a1"' "$XDG_STATE_HOME/omarchy-agent-launcher/events.jsonl" || tfail "assign posts an event"
"$L" sentinel verify a1 >/dev/null && tfail "verify must fail while Sentinel still reports the finding open"
grep -q '^scan codebase$' "$SD/scans" || tfail "verify asks Sentinel to re-scan the finding's arena"
[[ $("$L" sentinel advisories --json | jq -r '.[] | select(.id=="a1") | .rix_state') == assigned ]] || tfail "still assigned after a failed verify"
echo a1 >"$SD/fixed"
"$L" sentinel verify a1 | grep -q "a1 verified" || tfail "verify after the fix"
"$L" sentinel advisories --json | jq -e 'all(.[]; .id != "a1")' >/dev/null || tfail "verified advisories leave the default list"
[[ $("$L" sentinel advisories --json --all | jq -r '.[] | select(.id=="a1") | .rix_state') == verified ]] || tfail "--all shows verified"
"$L" sentinel decline a2 >/dev/null 2>&1 && tfail "decline needs a reason"
"$L" sentinel decline a2 "user: domain sends no mail yet, revisit at launch" >/dev/null || tfail "sentinel decline"
[[ $("$L" sentinel advisories --json --all | jq -r '.[] | select(.id=="a2") | .rix_state') == declined ]] || tfail "declined state"
"$L" rix brief | grep -q "Sentinel advises: 0 pending" || { "$L" rix brief; tfail "brief shows Sentinel advisories"; }
( source "$ROOT/lib/rix.sh"; source "$ROOT/lib/sentinel.sh"; rix_sentinel_duty ) | grep -q "never does the work" || tfail "Rix duty text"
grep -q "sentinel advisories" "$ROOT/skills/rix/SKILL.md" || tfail "Rix skill teaches the sentinel commands"
if command -v hermes >/dev/null; then
  "$L" rix setup anthropic >/dev/null; grep -q '^## Sentinel advisories' "$(job_path rix)" || tfail "new Rix job includes the Sentinel duty"
  printf '# Chief of staff\nold job\n' >"$(job_path rix)"
  ( source "$ROOT/lib/agents/hermes.sh"; source "$ROOT/lib/backends.sh"; source "$ROOT/lib/rix.sh"; source "$ROOT/lib/sentinel.sh"; OAL_ROOT="$ROOT"; agent_provision rix ) >/dev/null
  [[ $(grep -c '^## Sentinel advisories' "$(job_path rix)") == 1 ]] || tfail "an existing Rix job gets the duty appended"
  ( source "$ROOT/lib/agents/hermes.sh"; source "$ROOT/lib/backends.sh"; source "$ROOT/lib/rix.sh"; source "$ROOT/lib/sentinel.sh"; OAL_ROOT="$ROOT"; agent_provision rix ) >/dev/null
  [[ $(grep -c '^## Sentinel advisories' "$(job_path rix)") == 1 ]] || tfail "the duty is appended only once"
  "$L" remove rix --yes >/dev/null
fi
export OAL_SENTINEL_BIN=oal-test-no-sentinel
pass "sentinel advisories"

echo "== list / show / remove"
out=$("$L" list); grep -q "^prov " <<<"$out" || tfail "list"
out=$("$L" show prov); grep -q '"agent": "hermes"' <<<"$out" || tfail "show"
printf 'y\n' >"$OAL_ANSWERS"; "$L" remove prov >/dev/null; [[ ! -f $(profile_path prov) && ! -d $H ]] || tfail "remove"
"$L" remove provoc --yes >/dev/null || tfail "remove --yes"; [[ ! -f $(profile_path provoc) ]] || tfail "remove --yes left profile"
tail -n 1 "$S/events.jsonl" | grep -q '"kind":"removed"' || tfail "removed event"
pass "manage commands"
echo "== update: the update check against file:// fixtures (docs/update-alerts.md)"
R="$T/raw"; mkdir -p "$R"
export OMARCHY_PLUGIN_UPDATE_RAW="file://$R" XDG_CACHE_HOME="$T/cache"
jq '.version = "9.9.9"' "$ROOT/manifest.json" >"$R/manifest.json"
printf '# Changelog\n\n## 9.9.9\n\n- Newest thing\n\n## 9.9.8\n\n- Older thing\n\n## 0.1.0\n\n- Ancient\n' >"$R/CHANGELOG.md"
out=$("$L" update-check 0.11.0) || tfail "update-check exited"
[[ $(jq -r .latest <<<"$out") == 9.9.9 && $(jq -r .update_available <<<"$out") == true && $(jq -r '.notes|join(",")' <<<"$out") == "Newest thing,Older thing" ]] || tfail "update-check: $out"
[[ $(jq -r .mismatch <<<"$out") == true ]] || tfail "older dashboard is a mismatch: $out"
out=$("$L" update-check); [[ $(jq -r .mismatch <<<"$out") == false ]] || tfail "same version, no mismatch: $out"
out=$(OMARCHY_PLUGIN_UPDATE_RAW=file:///nonexistent "$L" update-check); [[ $(jq -r .latest <<<"$out") == 9.9.9 ]] || tfail "offline answer from cache: $out"
"$L" update-dismiss 9.9.9 || tfail "update-dismiss"
[[ $("$L" update-check | jq -r .dismissed) == 9.9.9 ]] || tfail "dismissed not recorded"
"$L" settings set update_check false >/dev/null
out=$("$L" update-check --force); [[ $(jq -r .enabled <<<"$out") == false ]] || tfail "opt-out via settings: $out"
"$L" settings set update_check true >/dev/null
out=$(OMARCHY_PLUGIN_UPDATE_PRINT=1 "$L" update-run all); [[ $(jq -r '.argv[-1]' <<<"$out") == all && $(jq -r '.argv[0]' <<<"$out") == *omarchy-launch-tui ]] || tfail "update-run argv: $out"
echo 'not json' >"$T/cache/omarchy-agent-launcher/update-check.json"
"$L" update-dismiss 1.2.3 && [[ $("$L" update-check --force | jq -r .dismissed) == 1.2.3 ]] || tfail "a broken cache file is replaced, not kept"
out=$("$L" --dry-run update-run); [[ $(jq -r '.argv[-1]' <<<"$out") == all ]] || tfail "--dry-run prints the argv: $out"
unset OMARCHY_PLUGIN_UPDATE_RAW
pass "check, notes, cache, offline, dismiss, opt-out, run, broken cache, dry-run"

echo "== harness: cmd_delegate refuses a metered backend without --approved-usd"
# "anthropic" has carried a saved ANTHROPIC_API_KEY since the very first (form)
# test in this file, so backend_get reports auth=api-key -> metered, with no
# sign-in involved.
rm -f "$(profile_path gated-worker)" "$(job_path gated-worker)" 2>/dev/null
rc=0; out=$(printf 'hello\n' | "$L" --dry-run delegate --backend anthropic --name gated-worker --job-stdin 2>&1) || rc=$?
[[ $rc == 3 ]] || { echo "$out"; tfail "delegate without --approved-usd on a metered backend must exit 3, got $rc"; }
grep -qiE 'would cost about \$|no known price' <<<"$out" || { echo "$out"; tfail "delegate refusal must print the estimate"; }
[[ ! -f $(profile_path gated-worker) ]] || tfail "a refused delegate must not create a profile"
out2=$(printf 'hello\n' | "$L" --dry-run delegate --backend anthropic --name gated-worker --approved-usd 999 --job-stdin 2>&1) || { echo "$out2"; tfail "delegate with a covering --approved-usd must proceed"; }
grep -q "would open window" <<<"$out2" || { echo "$out2"; tfail "an approved delegate must still launch"; }
"$L" remove gated-worker --yes >/dev/null 2>&1 || true
pass "cmd_delegate: refused (exit 3, estimate printed) without --approved-usd on a metered backend; proceeds once approved"

echo "== harness: approve/decline are human-only (refused with OAL_AGENT set)"
out=$(OAL_AGENT=some-worker "$L" harness approve p-anything 5 2>&1) && tfail "harness approve must refuse when OAL_AGENT is set"
grep -qi "agents cannot approve" <<<"$out" || { echo "$out"; tfail "approve refusal message"; }
out2=$(OAL_AGENT=some-worker "$L" harness decline p-anything 2>&1) && tfail "harness decline must refuse when OAL_AGENT is set"
grep -qi "agents cannot decline" <<<"$out2" || { echo "$out2"; tfail "decline refusal message"; }
pass "harness approve/decline refuse an agent context (OAL_AGENT set); only a human may run them"

echo "== harness: cost class, price estimate, dispatch loop, network-free status"
(
  source "$ROOT/lib/backends.sh"
  source "$ROOT/lib/usage.sh"
  source "$ROOT/lib/fallback.sh"
  source "$ROOT/lib/harness.sh"
  OPTS=(); CMD=(); OAL_SELF="$L"
  HD="$T/harness-test"; mkdir -p "$HD/fakebin" "$HD/inbox"
  export HARNESS_DATA_DIR="$HD/data"; mkdir -p "$HARNESS_DATA_DIR"
  SESSADD="$HD/session-add.log"; : >"$SESSADD"
  RECEIPTS="$HD/receipts.log"; : >"$RECEIPTS"
  CURLLOG="$HD/curl.log"; : >"$CURLLOG"
  DELEGATE_LOG="$HD/delegate.log"; : >"$DELEGATE_LOG"
  APPROVELOG="$HD/approve.log"; : >"$APPROVELOG"
  HEARTBEATLOG="$HD/heartbeat.log"; : >"$HEARTBEATLOG"
  ORDERLOG="$HD/order.log"; : >"$ORDERLOG"

  # ---- fake `harness` CLI: records session-add/receipt calls, answers inbox/cost --
  cat >"$HD/fakebin/harness" <<'FAKE'
#!/bin/bash
# The real harness CLI takes --json as a GLOBAL flag before the subcommand
# (`harness --json inbox ...`); strip it here so this fake dispatches on the
# subcommand the same way regardless of where the caller put --json.
while [[ ${1:-} == --json ]]; do shift; done
printf '%s\n' "$*" >>"__ORDERLOG__"
case "$1" in
  session)
    printf '%s\n' "$*" >>"__SESSADD__"
    echo ok ;;
  heartbeat)
    printf '%s\n' "$*" >>"__HEARTBEATLOG__"
    echo ok ;;
  inbox)
    proj=""
    while (( $# )); do case "$1" in --project) proj=$2; shift 2 ;; *) shift ;; esac; done
    cat "__HD__/inbox/$proj.json" 2>/dev/null || echo '[]' ;;
  cost)
    proj=""
    while (( $# )); do case "$1" in --project) proj=$2; shift 2 ;; *) shift ;; esac; done
    b=$(cat "__HD__/budget-$proj" 2>/dev/null || echo 0)
    p=$(cat "__HD__/pending-$proj.json" 2>/dev/null || echo '[]')
    printf '{"remaining_usd": %s, "pending": %s}\n' "$b" "$p" ;;
  receipt)
    node="" status="" usd="" tin="" tout="" command="" patch="" summary=""
    while (( $# )); do case "$1" in
      --node) node=$2; shift 2 ;; --status) status=$2; shift 2 ;;
      --usd) usd=$2; shift 2 ;; --tokens-in) tin=$2; shift 2 ;; --tokens-out) tout=$2; shift 2 ;;
      --command) command=$2; shift 2 ;; --patch-file) patch=$2; shift 2 ;; --summary) summary=$2; shift 2 ;;
      *) shift ;; esac; done
    printf 'node=%s status=%s usd=%s tin=%s tout=%s command=%s patch=%s summary=%s\n' \
      "$node" "$status" "$usd" "$tin" "$tout" "$command" "$patch" "$summary" >>"__RECEIPTS__"
    echo ok ;;
  approve|decline)
    printf '%s\n' "$*" >>"__APPROVELOG__"
    echo ok ;;
  ls) cat "__HD__/ls-response.json" 2>/dev/null || echo '[]' ;;
  *) echo '{}' ;;
esac
FAKE
  sed -i "s#__SESSADD__#$SESSADD#g; s#__HD__#$HD#g; s#__RECEIPTS__#$RECEIPTS#g; s#__APPROVELOG__#$APPROVELOG#g; s#__HEARTBEATLOG__#$HEARTBEATLOG#g; s#__ORDERLOG__#$ORDERLOG#g" "$HD/fakebin/harness"
  chmod +x "$HD/fakebin/harness"

  # ---- fake curl: logs URL, whether X-Harness/X-Harness-Approver were sent, and the body --
  cat >"$HD/fakebin/curl" <<'FAKE2'
#!/bin/bash
args=("$@"); url="${args[-1]}"; body="" hh=no ha=no
for ((i=0; i<${#args[@]}; i++)); do
  [[ ${args[i]} == -d ]] && body=${args[i+1]}
  [[ ${args[i]} == "X-Harness: 1" ]] && hh=yes
  [[ ${args[i]} == "X-Harness-Approver: human" ]] && ha=yes
done
printf '%s\t%s\t%s\t%s\n' "$url" "$hh" "$ha" "$body" >>"__CURLLOG__"
echo '{}'
FAKE2
  sed -i "s#__CURLLOG__#$CURLLOG#g" "$HD/fakebin/curl"
  chmod +x "$HD/fakebin/curl"

  # ---- fake cmd_delegate: simulates a DETACHED launch (harness_dispatch_packet
  # no longer waits). It records the call, then -- unless the job asks to look
  # "still running" -- writes the COMPLETE run log a real unattended worker
  # would produce in ONE printf, ending with the completion sentinel
  # (`__oal_rc=<n>`) harness_dispatch_reap trusts outright: no events.jsonl
  # lookup, no mtime race, nothing left to be flaky about. --------------------
  cmd_delegate() {
    local backend="" name="" model="" i=0 n=${#OPTS[@]}
    while (( i < n )); do
      case "${OPTS[i]}" in
        --backend) backend=${OPTS[i+1]}; ((i+=2)) ;;
        --name)    name=${OPTS[i+1]};    ((i+=2)) ;;
        --model)   model=${OPTS[i+1]};   ((i+=2)) ;;
        --task-title|--approved-usd) ((i+=2)) ;;
        --job-stdin|--wait) ((i+=1)) ;;
        *) ((i+=1)) ;;
      esac
    done
    local job; job=$(cat)
    printf 'backend=%s name=%s model=%s\n' "$backend" "$name" "$model" >>"$DELEGATE_LOG"
    if grep -q STILL_RUNNING_MARKER <<<"$job"; then return 0; fi   # no run log yet: reaper must skip it
    # cmd_delegate slugifies --name for the staged home; a fake that staged under
    # the raw $name masked a real bug (harness_dispatch_reap looking for the log
    # under the slugified name, e.g. "hns-p0-2-1" for "hns-P0.2.1").
    local rundir; rundir="$(stage_dir "$(slugify "$name")")/runs"; mkdir -p "$rundir"
    local code=0 body
    if grep -q RATE_LIMIT_MARKER <<<"$job"; then body="429 too many requests, please slow down"; code=1
    elif grep -q FAIL_MARKER <<<"$job"; then body="boom: something broke"; code=1
    elif grep -q FALSE_POSITIVE_MARKER <<<"$job"; then body="mentions a usage limit in passing but the run actually succeeded"; code=0
    elif grep -q SPLIT_REPLY_MARKER <<<"$job"; then
      # An orchestration delegate's reply: prose, then a BROKEN object that never
      # closes (tests that a broken candidate before the good one doesn't win or
      # corrupt the scan), then the real patch (nested braces via `children`, a
      # brace-looking substring inside a quoted string), then trailing prose.
      body=$'Thinking about the decomposition...\n{"action": "SPLIT", "broken": true\nmore reasoning here, this object never closes\n{"action":"SPLIT","node":"P0","children":[{"id":"P0.1","title":"a } b { c"},{"id":"P0.2"}]}\nDone.'
      code=0
    elif grep -q SPLIT_NO_JSON_MARKER <<<"$job"; then
      body="just prose, no JSON object anywhere in this reply"; code=0
    else body="done: ok"; code=0
    fi
    printf '%s\n__oal_rc=%s\n' "$body" "$code" >"$rundir/$(date +%Y%m%d-%H%M%S)-$RANDOM.log"
    return 0
  }

  export PATH="$HD/fakebin:$PATH"
  settings_set harness_bin "$HD/fakebin/harness"

  # ---- cost class mapping -----------------------------------------------------------
  profile_write hns-free hermes local local none model-x - interactive ""
  [[ $(harness_cost_class hns-free) == free ]] || tfail "cost class: local backend must be free"

  profile_write hns-sub hermes local anthropic oauth claude-sonnet-5 - interactive ""
  profile_set hns-sub signed_in true
  mkdir -p "$(stage_dir hns-sub)/hermes"; printf '{"anthropic":{"token":"t"}}\n' >"$(stage_dir hns-sub)/hermes/auth.json"
  [[ $(harness_cost_class hns-sub) == subscription ]] || tfail "cost class: oauth backend must be subscription"

  backend_write hnsteam '{"id":"hnsteam","kind":"endpoint","label":"hnsteam","model":"m","url":"https://hns.example.com/v1","state":"ready","model_ctx":32768}'
  profile_write hns-met hermes local endpoint api-key m - interactive ""
  profile_set hns-met backend '"hnsteam"'
  [[ $(harness_cost_class hns-met) == metered ]] || tfail "cost class: api-key backend must be metered"
  pass "harness cost class: local -> free, oauth -> subscription, api-key -> metered"

  # ---- fail-closed: unknown/unresolvable, oauth-not-signed-in, and a metered fallback hop --
  profile_write hns-norecord hermes local "" none "" - interactive ""
  [[ $(harness_cost_class hns-norecord) == metered ]] || tfail "cost class: no backend record must fail closed to metered"

  profile_write hns-badauth hermes local ollama none model-y - interactive ""
  [[ $(harness_cost_class hns-badauth) == metered ]] || tfail "cost class: an auth this launcher does not recognize must fail closed to metered"

  profile_write hns-nosignin hermes local nous oauth model-z - interactive ""
  [[ $(harness_cost_class hns-nosignin) == metered ]] || tfail "cost class: an OAuth provider nobody signed in to must fail closed to metered"

  printf '{"mychain":[{"provider":"local","model":"x"},{"provider":"hnsteam","model":"m"}]}' >"$OAL_CONF/fallback-policy.json"
  profile_write hns-chain hermes local local none model-x - interactive ""
  profile_set hns-chain fallback_chain '"mychain"'
  [[ $(harness_cost_class hns-chain) == metered ]] || tfail "cost class: a fallback chain hop to an api-key provider must make the whole profile metered"
  grep -q "hnsteam" <<<"$(harness_cost_class_reason hns-chain)" || tfail "cost class reason should name the metered chain hop"
  rm -f "$OAL_CONF/fallback-policy.json"
  pass "harness cost class fails CLOSED: no record, unrecognized auth, oauth-not-signed-in, metered fallback hop"

  # ---- price estimate ----------------------------------------------------------------
  MODELS_CACHE="$HD/models.json"
  cat >"$MODELS_CACHE" <<'JSON'
{"testvendor":{"models":{"test-model":{"name":"Test Model","tool_call":true,"cost":{"input":2,"output":8}}}}}
JSON
  profile_write hns-est hermes local endpoint api-key test-model - interactive ""
  profile_set hns-est backend '"hnsteam"'
  profile_write hns-unk hermes local endpoint api-key unknown-model - interactive ""
  profile_set hns-unk backend '"hnsteam"'
  PKT="$HD/pkt-est.md"; printf '%040d' 0 >"$PKT"   # 40 bytes -> 10 input tokens, 40 output headroom
  got=$(harness_estimate_usd hns-est "$PKT") || tfail "estimate should succeed for a priced metered model"
  awk -v g="$got" 'BEGIN{ if (g < 0.00679 || g > 0.00681) exit 1; exit 0 }' || tfail "estimate math: got $got, want ~0.0068 (10*\$2 in + 40*\$8 out per 1M, x20 turn factor)"
  [[ $(harness_estimate_usd hns-free "$PKT") == 0 ]] || tfail "estimate: free backend must be 0"
  [[ $(harness_estimate_usd hns-sub "$PKT") == 0 ]] || tfail "estimate: subscription backend must be 0"
  harness_estimate_usd hns-unk "$PKT" >/dev/null 2>&1 && tfail "estimate must refuse an unpriced metered model, never guess \$0"
  pass "harness price estimate: chars/4 in tokens, x4 output headroom, unpriced model refused"

  # ---- dispatch_once: subscription runs free, funded metered runs, underfunded asks --
  # (detached: dispatch_once only LAUNCHES; harness_dispatch_reap writes the receipt
  # once each worker's run log shows up.)
  PKT_SUB="$HD/pkt-sub.md";   printf 'sub job body\n'  >"$PKT_SUB"
  PKT_POOR="$HD/pkt-poor.md"; printf 'poor job body\n' >"$PKT_POOR"
  PKT_RICH="$HD/pkt-rich.md"; printf 'rich job body\n' >"$PKT_RICH"
  printf '[{"node":"sub-node","path":"%s"}]'  "$PKT_SUB"  >"$HD/inbox/p-sub.json"
  printf '[{"node":"poor-node","path":"%s"}]' "$PKT_POOR" >"$HD/inbox/p-poor.json"
  printf '[{"node":"rich-node","path":"%s"}]' "$PKT_RICH" >"$HD/inbox/p-rich.json"
  echo 0 >"$HD/budget-p-poor"
  echo 5 >"$HD/budget-p-rich"
  printf '[{"node":"poor-node"}]' >"$HD/pending-p-poor.json"   # the harness's own pending list still lists it
  jq -n --arg t "$(date -Is)" '{
    projects: [
      {id:"p-sub",  repo_path:"/tmp/proj-sub"},
      {id:"p-poor", repo_path:"/tmp/proj-poor"},
      {id:"p-rich", repo_path:"/tmp/proj-rich", pending_approval:{estimate_usd:0.5, reason:"test"}}
    ],
    sessions: [
      {id:"s-sub",  project:"p-sub",  worker:"rix", label:"hns-sub"},
      {id:"s-poor", project:"p-poor", worker:"rix", label:"hns-est"},
      {id:"s-rich", project:"p-rich", worker:"rix", label:"hns-est"}
    ],
    queue: [], events: [], generated_at: $t
  }' >"$HARNESS_DATA_DIR/overview.json"

  s=$(harness_status_json)
  [[ $(jq -r .alive <<<"$s") == true ]] || tfail "status alive must be true with a fresh overview.json"
  [[ $(jq -r '.pending_approvals|length' <<<"$s") == 1 ]] || tfail "status must surface p-rich's pending approval"
  [[ $(jq -r '.pending_approvals[0].id' <<<"$s") == p-rich ]] || tfail "pending approval project id"
  [[ $(jq -r .serving_pid <<<"$s") == null && $(jq -r .dispatch_pid <<<"$s") == null ]] || tfail "no serve/dispatch pid files yet"

  harness_dispatch_once || true
  [[ $(wc -l <"$DELEGATE_LOG") == 2 ]] || { cat "$DELEGATE_LOG"; tfail "expected 2 delegate calls (subscription + funded metered)"; }
  grep -q "name=hns-sub-node"  "$DELEGATE_LOG" || tfail "subscription packet not delegated"
  grep -q "name=hns-rich-node" "$DELEGATE_LOG" || tfail "funded metered packet not delegated"
  ! grep -q "poor-node" "$DELEGATE_LOG" || tfail "underfunded metered packet must not be delegated"
  [[ -f ${PKT_SUB}.claimed  && ! -f $PKT_SUB  ]] || tfail "subscription packet not claimed"
  [[ -f ${PKT_RICH}.claimed && ! -f $PKT_RICH ]] || tfail "rich packet not claimed"
  [[ -f $PKT_POOR ]] || tfail "underfunded packet must stay unclaimed until approved"
  [[ $(harness_jobs_running) == 2 ]] || tfail "2 detached job files expected after launching sub-node and rich-node"
  n_req=$(grep -c "cost/request" "$CURLLOG" || true)
  [[ $n_req == 1 ]] || { cat "$CURLLOG"; tfail "expected exactly one cost/request POST"; }
  grep "cost/request" "$CURLLOG" | grep -q "p-poor" || tfail "cost/request must be for the underfunded project"
  grep "cost/request" "$CURLLOG" | awk -F'\t' '{print $2}' | grep -q yes || tfail "cost/request must carry X-Harness: 1"

  harness_dispatch_reap
  [[ $(wc -l <"$RECEIPTS") == 2 ]] || { cat "$RECEIPTS"; tfail "expected 2 receipts after reaping"; }
  grep -q "node=sub-node status=done"  "$RECEIPTS" || tfail "subscription receipt not done"
  grep -q "node=rich-node status=done" "$RECEIPTS" || tfail "rich receipt not done"
  [[ $(harness_jobs_running) == 0 ]] || tfail "job files must be removed once reaped"

  harness_dispatch_once || true
  [[ $(wc -l <"$DELEGATE_LOG") == 2 ]] || tfail "second sweep must not re-delegate claimed/finished packets"
  n_req2=$(grep -c "cost/request" "$CURLLOG" || true)
  [[ $n_req2 == 1 ]] || tfail "second sweep must not re-request an already-requested packet (the harness's pending list still lists it)"
  pass "harness dispatch_once/reap: subscription and funded metered run detached; underfunded metered requests budget once"

  # ---- register (incl. --slots), approve, decline; requested.txt pruned on approve ---
  harness_register_rix hns-sub /tmp/proj-sub >/dev/null || tfail "register failed"
  grep -q -- "--project p-sub" "$SESSADD" || tfail "register did not add a session for p-sub"
  grep -q -- "--label hns-sub" "$SESSADD" || tfail "register label"
  grep -q -- "--cost-class subscription" "$SESSADD" || tfail "register cost class"

  : >"$SESSADD"
  harness_register_rix hns-sub /tmp/proj-sub 2 >/dev/null || tfail "register --slots failed"
  grep -q -- "--label hns-sub-1" "$SESSADD" || tfail "register --slots 2: session 1 missing"
  grep -q -- "--label hns-sub-2" "$SESSADD" || tfail "register --slots 2: session 2 missing"
  [[ $(harness_profile_for_label hns-sub-1) == hns-sub ]] || tfail "a slot label must resolve back to the real profile"

  grep -qxF "p-poor:poor-node" "$HARNESS_STATE_DIR/requested.txt" || tfail "requested.txt should still list the underfunded packet before approval"
  harness_approve p-poor 0.0002 "go ahead" >/dev/null   # a harness binary is on PATH: this goes through the CLI, not curl
  grep -q -- "--project p-poor" "$APPROVELOG" || { cat "$APPROVELOG"; tfail "approve must call the harness CLI when it is available"; }
  grep -qxF "p-poor:poor-node" "$HARNESS_STATE_DIR/requested.txt" 2>/dev/null && tfail "requested.txt must be pruned once its project is approved"
  harness_decline p-rich >/dev/null
  grep -q -- "--project p-rich" "$APPROVELOG" || { cat "$APPROVELOG"; tfail "decline must call the harness CLI when it is available"; }
  pass "harness register (incl. --slots N -> <profile>-1..N), approve/decline prefer the harness CLI, approve prunes requested.txt"

  # ---- approve/decline curl fallback: X-Harness + X-Harness-Approver, request_id body --
  (
    PATH=$(printf '%s' "$PATH" | sed "s#$HD/fakebin:##")   # no harness CLI on PATH: force the curl fallback
    HOME="$T/fake-home-approve"; mkdir -p "$HOME"           # and no real ~/Work/session-harness fallback either
    OAL_PATH_NO_HARNESS="$T/nobin"; mkdir -p "$OAL_PATH_NO_HARNESS"
    PATH="$OAL_PATH_NO_HARNESS:$PATH"
    cp "$HD/fakebin/curl" "$OAL_PATH_NO_HARNESS/curl"
    settings_set harness_bin ""
    : >"$CURLLOG"
    harness_approve p-fallback 1.5 "manual test" req-1 >/dev/null
    line=$(grep "/api/project/p-fallback/approve" "$CURLLOG" | tail -n1)
    [[ -n $line ]] || { cat "$CURLLOG"; tfail "curl fallback: approve did not POST"; }
    [[ $(cut -f2 <<<"$line") == yes ]] || tfail "curl fallback: approve must carry X-Harness: 1"
    [[ $(cut -f3 <<<"$line") == yes ]] || tfail "curl fallback: approve must carry X-Harness-Approver: human"
    body=$(cut -f4 <<<"$line")
    jq -e '.request_id == "req-1" and .usd == 1.5 and .by == "human"' <<<"$body" >/dev/null || { echo "$body"; tfail "curl fallback: approve body must be {request_id, usd, reason, by:human}"; }
    harness_decline p-fallback req-2 >/dev/null
    dline=$(grep "/api/project/p-fallback/cost/decline" "$CURLLOG" | tail -n1)
    [[ -n $dline ]] || { cat "$CURLLOG"; tfail "curl fallback: decline did not POST"; }
    [[ $(cut -f3 <<<"$dline") == yes ]] || tfail "curl fallback: decline must carry X-Harness-Approver: human"
    dbody=$(cut -f4 <<<"$dline")
    jq -e '.request_id == "req-2" and .by == "human"' <<<"$dbody" >/dev/null || { echo "$dbody"; tfail "curl fallback: decline body must be {request_id, by:human}"; }
    settings_set harness_bin "$HD/fakebin/harness"
  ) || exit 1
  pass "harness approve/decline curl fallback: X-Harness + X-Harness-Approver headers, request_id body"

  # ---- reap: rc-first throttle detection (marker alone, or rc alone, is not enough) --
  PKT_T1="$HD/pkt-t1.md"; printf 'RATE_LIMIT_MARKER please retry\n' >"$PKT_T1"
  PKT_T2="$HD/pkt-t2.md"; printf 'FAIL_MARKER nothing special\n' >"$PKT_T2"
  PKT_T3="$HD/pkt-t3.md"; printf 'FALSE_POSITIVE_MARKER usage limit mentioned in passing\n' >"$PKT_T3"
  printf '[{"node":"t1","path":"%s"},{"node":"t2","path":"%s"},{"node":"t3","path":"%s"}]' \
    "$PKT_T1" "$PKT_T2" "$PKT_T3" >"$HD/inbox/p-throttle.json"
  jq -n --arg t "$(date -Is)" '{
    projects: [ {id:"p-throttle", repo_path:"/tmp/proj-throttle"} ],
    sessions: [ {id:"s-throttle", project:"p-throttle", worker:"rix", label:"hns-free"} ],
    queue: [], events: [], generated_at: $t
  }' >"$HARNESS_DATA_DIR/overview.json"
  harness_dispatch_once || true
  harness_dispatch_reap
  grep -q "node=t1 status=throttled" "$RECEIPTS" || { cat "$RECEIPTS"; tfail "rc-first: nonzero exit + a structured marker must be throttled"; }
  grep -q "node=t2 status=failed"    "$RECEIPTS" || { cat "$RECEIPTS"; tfail "rc-first: nonzero exit without a marker must be failed, not throttled"; }
  grep -q "node=t3 status=done"      "$RECEIPTS" || { cat "$RECEIPTS"; tfail "rc-first: a marker in a SUCCESSFUL (exit 0) run must not be throttled"; }
  pass "harness reap: rc-first throttle detection"

  # ---- concurrency: harness_workers caps detached jobs; the reaper drains them ------
  settings_set harness_workers 2
  : >"$DELEGATE_LOG"; : >"$RECEIPTS"
  PKT_C1="$HD/pkt-c1.md"; printf 'c1 body\n' >"$PKT_C1"; PKT_C2="$HD/pkt-c2.md"; printf 'c2 body\n' >"$PKT_C2"
  PKT_C3="$HD/pkt-c3.md"; printf 'c3 body\n' >"$PKT_C3"; PKT_C4="$HD/pkt-c4.md"; printf 'c4 body\n' >"$PKT_C4"
  printf '[{"node":"c1","path":"%s"},{"node":"c2","path":"%s"},{"node":"c3","path":"%s"},{"node":"c4","path":"%s"}]' \
    "$PKT_C1" "$PKT_C2" "$PKT_C3" "$PKT_C4" >"$HD/inbox/p-conc.json"
  jq -n --arg t "$(date -Is)" '{
    projects: [ {id:"p-conc", repo_path:"/tmp/proj-conc"} ],
    sessions: [ {id:"s-conc", project:"p-conc", worker:"rix", label:"hns-free"} ],
    queue: [], events: [], generated_at: $t
  }' >"$HARNESS_DATA_DIR/overview.json"

  harness_dispatch_once || true
  [[ $(wc -l <"$DELEGATE_LOG") == 2 ]] || { cat "$DELEGATE_LOG"; tfail "concurrency: only harness_workers(2) jobs may launch per sweep"; }
  [[ $(harness_jobs_running) == 2 ]] || tfail "concurrency: 2 job files expected after the first sweep"
  s2=$(harness_status_json)
  [[ $(jq -r '.jobs.running' <<<"$s2") == 2 && $(jq -r '.jobs.slots' <<<"$s2") == 2 ]] || { echo "$s2"; tfail "status must report jobs.running/jobs.slots"; }

  harness_dispatch_reap
  [[ $(wc -l <"$RECEIPTS") == 2 ]] || { cat "$RECEIPTS"; tfail "concurrency: 2 receipts expected after reaping the first batch"; }
  [[ $(harness_jobs_running) == 0 ]] || tfail "concurrency: job files must be removed once reaped"

  harness_dispatch_once || true
  [[ $(wc -l <"$DELEGATE_LOG") == 4 ]] || { cat "$DELEGATE_LOG"; tfail "concurrency: the freed slots must launch the 2 remaining packets"; }
  harness_dispatch_reap
  [[ $(wc -l <"$RECEIPTS") == 4 ]] || { cat "$RECEIPTS"; tfail "concurrency: 4 total receipts expected"; }
  [[ $(harness_jobs_running) == 0 ]] || tfail "concurrency: no jobs should remain running"
  pass "harness concurrency: 4 packets over harness_workers=2 -> two capped sweeps, reaper drains each"
  settings_set harness_workers 4

  # ---- reap: receipt carries the delegate's ACTUAL cost from usage --json ----------
  usage_json() { jq -nc --arg n hns-usage1 '{agents:[{name:$n, cost_usd:0.0042, prompt:123, output:45}]}'; }
  : >"$DELEGATE_LOG"; : >"$RECEIPTS"
  PKT_U="$HD/pkt-usage1.md"; printf 'usage test body\n' >"$PKT_U"
  printf '[{"node":"usage1","path":"%s"}]' "$PKT_U" >"$HD/inbox/p-usage.json"
  jq -n --arg t "$(date -Is)" '{
    projects: [ {id:"p-usage", repo_path:"/tmp/proj-usage"} ],
    sessions: [ {id:"s-usage", project:"p-usage", worker:"rix", label:"hns-free"} ],
    queue: [], events: [], generated_at: $t
  }' >"$HARNESS_DATA_DIR/overview.json"
  harness_dispatch_once || true
  harness_dispatch_reap
  grep -q "node=usage1 status=done usd=0.0042 tin=123 tout=45" "$RECEIPTS" || { cat "$RECEIPTS"; tfail "receipt must carry the worker's actual usage (--usd/--tokens-in/--tokens-out)"; }
  pass "harness reap: receipt carries the delegate's actual cost from usage --json"
  unset -f usage_json; source "$ROOT/lib/usage.sh"   # restore the real usage.sh function

  # ---- status --json with no harness installed: still network-free ------------------
  (
    PATH=$(printf '%s' "$PATH" | sed "s#$HD/fakebin:##")
    HOME="$T/fake-home"; mkdir -p "$HOME"
    export HARNESS_DATA_DIR="$HD/empty-data"; mkdir -p "$HARNESS_DATA_DIR"
    settings_set harness_bin ""
    before=$(wc -l <"$CURLLOG")
    s2=$(harness_status_json)
    [[ $(jq -r .alive <<<"$s2") == false ]] || tfail "alive must be false with no overview.json"
    [[ $(jq -r .bin <<<"$s2") == "" ]] || tfail "bin must be empty when the harness CLI cannot be found"
    after=$(wc -l <"$CURLLOG")
    [[ $before == "$after" ]] || tfail "status --json must never call curl"
  ) || exit 1
  pass "harness status --json is network-free with no harness installed"

  # ---- harness_notify_sync: one blocker per pending approval, cleared when it's
  #      gone; one throttled note per retry_at; idempotent; never calls curl -----------
  jq -n --arg t "$(date -Is)" '{
    projects: [
      {id:"p-sub",  repo_path:"/tmp/proj-sub"},
      {id:"p-poor", repo_path:"/tmp/proj-poor"},
      {id:"p-rich", repo_path:"/tmp/proj-rich", pending_approval:{estimate_usd:0.5, model:"test-model", vendor:"testvendor", reason:"test", at:"2026-01-01T00:00:00Z"}}
    ],
    sessions: [
      {id:"s-sub",  project:"p-sub",  worker:"rix", label:"hns-sub"},
      {id:"s-poor", project:"p-poor", worker:"rix", label:"hns-est"},
      {id:"s-rich", project:"p-rich", worker:"rix", label:"hns-est", state:"throttled", retry_at:"2026-01-01T00:05:00Z"}
    ],
    queue: [], events: [], generated_at: $t
  }' >"$HARNESS_DATA_DIR/overview.json"

  curl_before=$(wc -l <"$CURLLOG")
  harness_notify_sync
  [[ $(blockers_json | jq '[.[] | select(.key=="approval-p-rich")] | length') == 1 ]] || tfail "notify_sync: expected exactly one approval blocker for p-rich"
  [[ $(blockers_json | jq -r '.[] | select(.key=="approval-p-rich") | .agent') == hns-est ]] || tfail "notify_sync: approval blocker agent must be the project's rix session label"
  n_appr1=$(grep -c '"key":"approval-p-rich"' "$OAL_EVENTS" || true)
  [[ $n_appr1 == 1 ]] || tfail "notify_sync: expected exactly one approval event, got $n_appr1"
  n_throttle1=$(grep -c "throttled, retrying at 2026-01-01T00:05:00Z" "$OAL_EVENTS" || true)
  [[ $n_throttle1 == 1 ]] || tfail "notify_sync: expected exactly one throttled note, got $n_throttle1"

  harness_notify_sync
  harness_notify_sync
  [[ $(blockers_json | jq '[.[] | select(.key=="approval-p-rich")] | length') == 1 ]] || tfail "notify_sync: rerun must stay idempotent (still exactly one blocker)"
  n_appr2=$(grep -c '"key":"approval-p-rich"' "$OAL_EVENTS" || true)
  [[ $n_appr2 == "$n_appr1" ]] || tfail "notify_sync: rerun with an unchanged approval must not re-emit the blocker event"
  n_throttle2=$(grep -c "throttled, retrying at 2026-01-01T00:05:00Z" "$OAL_EVENTS" || true)
  [[ $n_throttle2 == 1 ]] || tfail "notify_sync: rerun must not re-emit the same throttled note"
  curl_after=$(wc -l <"$CURLLOG")
  [[ $curl_before == "$curl_after" ]] || tfail "notify_sync must never call curl"
  pass "harness_notify_sync: one approval blocker + one throttled note, idempotent on rerun, no network"

  jq '(.projects[] | select(.id=="p-rich")) |= del(.pending_approval)' "$HARNESS_DATA_DIR/overview.json" >"$HD/overview-cleared.json"
  mv -f "$HD/overview-cleared.json" "$HARNESS_DATA_DIR/overview.json"
  harness_notify_sync
  [[ $(blockers_json | jq '[.[] | select(.key=="approval-p-rich")] | length') == 0 ]] || tfail "notify_sync must resolve the blocker once the approval disappears"
  grep -q '"kind":"blocker_cleared".*"key":"approval-p-rich"' "$OAL_EVENTS" || tfail "notify_sync must log blocker_cleared for the resolved approval"
  pass "harness_notify_sync: clears the blocker when the approval disappears"

  # ---- dispatch_packet: job file records slug/claimed/started_at; the harness sees
  #      either `session set --pid` or `heartbeat` for the dispatched session ---------
  : >"$DELEGATE_LOG"; : >"$SESSADD"; : >"$HEARTBEATLOG"
  PKT_J1="$HD/pkt-j1.md"; printf 'j1 body\n' >"$PKT_J1"
  printf '[{"node":"j1","path":"%s"}]' "$PKT_J1" >"$HD/inbox/p-j1.json"
  jq -n --arg t "$(date -Is)" '{
    projects: [ {id:"p-j1", repo_path:"/tmp/proj-j1"} ],
    sessions: [ {id:"s-j1", project:"p-j1", worker:"rix", label:"hns-free"} ],
    queue: [], events: [], generated_at: $t
  }' >"$HARNESS_DATA_DIR/overview.json"
  harness_dispatch_once || true
  JF1="$HARNESS_JOBS_DIR/p-j1/j1.json"
  [[ -f $JF1 ]] || tfail "dispatch: expected a job file for the claimed j1 packet"
  jf1=$(cat "$JF1")
  [[ -n $(jq -r '.slug // empty' <<<"$jf1") ]] || tfail "job file must record slug"
  [[ -n $(jq -r '.claimed // empty' <<<"$jf1") ]] || tfail "job file must record claimed"
  [[ $(jq -r '.started_at // empty' <<<"$jf1") =~ ^[0-9]+$ ]] || tfail "job file must record a numeric started_at"
  grep -q -- "--session s-j1 --pid" "$SESSADD" || grep -q -- "--session s-j1" "$HEARTBEATLOG" \
    || { cat "$SESSADD" "$HEARTBEATLOG"; tfail "the harness must see either session set --pid or heartbeat for the dispatched session"; }
  pass "harness_dispatch_packet: job file has slug/claimed/started_at; session pid or heartbeat recorded"

  # ---- harness_dispatch_heartbeat: claimed packet still present -> heartbeat only,
  #      job file survives ------------------------------------------------------------
  : >"$HEARTBEATLOG"
  harness_dispatch_heartbeat
  [[ -f $JF1 ]] || tfail "job file must survive a heartbeat sweep while the claimed packet is still present"
  grep -q -- "--project p-j1 --session s-j1" "$HEARTBEATLOG" || { cat "$HEARTBEATLOG"; tfail "harness_dispatch_heartbeat must heartbeat a still-claimed session"; }
  pass "harness_dispatch_heartbeat: claimed packet present -> heartbeat recorded, job file survives"

  # ---- harness_dispatch_heartbeat: the harness withdrew the packet (renamed out from
  #      under the job's recorded .claimed path) -> forget the delegate, clear the pid,
  #      emit a cancelled event, and remove the transient profile/stage dir -----------
  slug1=$(jq -r '.slug' "$JF1")
  mkdir -p "$(stage_dir "$slug1")"; touch "$(stage_dir "$slug1")/marker"
  printf '{}' >"$(profile_path "$slug1")"
  mv -f "${PKT_J1}.claimed" "${PKT_J1}.claimed.cancelled"
  : >"$SESSADD"
  harness_dispatch_heartbeat
  [[ ! -f $JF1 ]] || tfail "withdrawn packet: the job file must be removed"
  grep -q -- "--project p-j1 --session s-j1 --clear-pid" "$SESSADD" || { cat "$SESSADD"; tfail "withdrawn packet must call session set --clear-pid"; }
  grep -q "harness:p-j1:j1:cancelled" "$OAL_EVENTS" || tfail "withdrawn packet must emit a harness:<proj>:<node>:cancelled event"
  [[ ! -d $(stage_dir "$slug1") ]] || tfail "harness_job_forget must remove the transient stage dir"
  [[ ! -f $(profile_path "$slug1") ]] || tfail "harness_job_forget must remove the transient profile"
  pass "harness_dispatch_heartbeat: withdrawn packet -> job forgotten, session cleared, cancelled event, stage/profile removed"

  # ---- harness_dispatch_reap: a finished job -> receipt written, then session set
  #      --clear-pid, and its stage dir removed ---------------------------------------
  : >"$DELEGATE_LOG"; : >"$RECEIPTS"; : >"$SESSADD"
  PKT_J2="$HD/pkt-j2.md"; printf 'j2 body\n' >"$PKT_J2"
  printf '[{"node":"j2","path":"%s"}]' "$PKT_J2" >"$HD/inbox/p-j2.json"
  jq -n --arg t "$(date -Is)" '{
    projects: [ {id:"p-j2", repo_path:"/tmp/proj-j2"} ],
    sessions: [ {id:"s-j2", project:"p-j2", worker:"rix", label:"hns-free"} ],
    queue: [], events: [], generated_at: $t
  }' >"$HARNESS_DATA_DIR/overview.json"
  harness_dispatch_once || true
  JF2="$HARNESS_JOBS_DIR/p-j2/j2.json"
  [[ -f $JF2 ]] || tfail "j2 job file must exist after dispatch"
  slug2=$(jq -r '.slug' "$JF2")
  [[ -d $(stage_dir "$slug2") ]] || tfail "stage dir should exist for the running job"
  : >"$ORDERLOG"
  harness_dispatch_reap
  grep -q "node=j2 status=done" "$RECEIPTS" || { cat "$RECEIPTS"; tfail "reap of a finished job must write a receipt"; }
  grep -q -- "--project p-j2 --session s-j2 --clear-pid" "$SESSADD" || { cat "$SESSADD"; tfail "reap must call session set --clear-pid"; }
  n_receipt=$(grep -n "^receipt --project p-j2 --session s-j2 --node j2" "$ORDERLOG" | tail -n1 | cut -d: -f1)
  n_clearpid=$(grep -n "^session set --project p-j2 --session s-j2 --clear-pid" "$ORDERLOG" | tail -n1 | cut -d: -f1)
  [[ -n $n_receipt && -n $n_clearpid && $n_receipt -lt $n_clearpid ]] || { cat "$ORDERLOG"; tfail "reap must call receipt BEFORE session set --clear-pid"; }
  [[ ! -d $(stage_dir "$slug2") ]] || tfail "reap must remove the stage dir via harness_job_forget"
  [[ ! -f $JF2 ]] || tfail "job file must be removed after reap"
  pass "harness_dispatch_reap: finished job -> receipt then session set --clear-pid, stage dir removed"

  # ---- harness_register_rix: --project with no repo resolves --cwd from `harness --json ls` --
  profile_write rix hermes local local none model-x - interactive ""
  REPO5="$HD/repo-parse-cookie"; mkdir -p "$REPO5"
  jq -n --arg id parse_cookie --arg repo "$REPO5" '[{id:$id, repo_path:$repo}]' >"$HD/ls-response.json"
  : >"$SESSADD"
  harness_register_rix rix "" 1 parse_cookie >/dev/null || tfail "register --project (no repo) failed"
  grep -q -- "--project parse_cookie" "$SESSADD" || { cat "$SESSADD"; tfail "register --project: session add must target the given project id"; }
  grep -q -- "--cwd $REPO5" "$SESSADD" || { cat "$SESSADD"; tfail "register --project (no repo): --cwd must come from harness --json ls's repo_path"; }
  rm -f "$(profile_path rix)"
  pass "harness_register_rix: --project with no repo resolves --cwd from harness --json ls"

  # ---- reap: a dotted/uppercase node name stages its run log under the SLUGIFIED
  #      name (cmd_delegate slugifies --name); the reaper must look there too -------
  : >"$DELEGATE_LOG"; : >"$RECEIPTS"
  PKT_J3="$HD/pkt-j3.md"; printf 'j3 body\n' >"$PKT_J3"
  printf '[{"node":"P0.2.1","path":"%s"}]' "$PKT_J3" >"$HD/inbox/p-j3.json"
  jq -n --arg t "$(date -Is)" '{
    projects: [ {id:"p-j3", repo_path:"/tmp/proj-j3"} ],
    sessions: [ {id:"s-j3", project:"p-j3", worker:"rix", label:"hns-free"} ],
    queue: [], events: [], generated_at: $t
  }' >"$HARNESS_DATA_DIR/overview.json"
  harness_dispatch_once || true
  JF3="$HARNESS_JOBS_DIR/p-j3/P0.2.1.json"
  [[ -f $JF3 ]] || tfail "j3 (dotted node name) job file must exist after dispatch"
  slug3=$(jq -r '.slug' "$JF3")
  [[ $slug3 == hns-p0-2-1 ]] || tfail "job file slug must be the slugified name, got $slug3"
  [[ -d $(stage_dir "$slug3")/runs ]] || tfail "the fake delegate must stage its run log under the slugified name"
  harness_dispatch_reap
  grep -q "node=P0.2.1 status=done" "$RECEIPTS" || { cat "$RECEIPTS"; tfail "reap must find the run log staged under the slugified name"; }
  [[ ! -f $JF3 ]] || tfail "job file must be removed after reap"
  pass "harness_dispatch_reap: finds a dotted/uppercase node's run log via the slugified stage dir"

  # ---- reap: a job file with no `slug` field (an older job) must still find the
  #      run log by deriving slugify(name) --------------------------------------------
  : >"$RECEIPTS"
  PKT_J4="$HD/pkt-j4.md"; printf 'j4 body\n' >"$PKT_J4"
  printf '[{"node":"P0.2.2","path":"%s"}]' "$PKT_J4" >"$HD/inbox/p-j4.json"
  jq -n --arg t "$(date -Is)" '{
    projects: [ {id:"p-j4", repo_path:"/tmp/proj-j4"} ],
    sessions: [ {id:"s-j4", project:"p-j4", worker:"rix", label:"hns-free"} ],
    queue: [], events: [], generated_at: $t
  }' >"$HARNESS_DATA_DIR/overview.json"
  harness_dispatch_once || true
  JF4="$HARNESS_JOBS_DIR/p-j4/P0.2.2.json"
  [[ -f $JF4 ]] || tfail "j4 job file must exist after dispatch"
  jq 'del(.slug)' "$JF4" >"$JF4.tmp" && mv -f "$JF4.tmp" "$JF4"   # simulate an older job file with no slug field
  jq -e '.slug == null' "$JF4" >/dev/null || tfail "setup: job file must have no slug field"
  harness_dispatch_reap
  grep -q "node=P0.2.2 status=done" "$RECEIPTS" || { cat "$RECEIPTS"; tfail "reap must derive slugify(name) when the job file has no slug field"; }
  [[ ! -f $JF4 ]] || tfail "job file must be removed after reap"
  pass "harness_dispatch_reap: a job file with no slug field still finds the run log via slugify(name)"

  # ==== W5a: roles/policy (harness_role, --role/--model/--vendor, orchestration
  #      packets, harness_extract_last_json, status --json roles/orchestrator) =====

  # ---- register: --role defaults to coding, then to the profile's harness_role,
  #      then an explicit ROLE argument wins; --model/--vendor always passed -------
  : >"$SESSADD"
  harness_register_rix hns-sub /tmp/proj-sub 1 p-role-default >/dev/null || tfail "register (role default) failed"
  grep -q -- "--role coding" "$SESSADD" || { cat "$SESSADD"; tfail "register must default --role to coding when the profile has no harness_role"; }
  grep -q -- "--model claude-sonnet-5" "$SESSADD" || { cat "$SESSADD"; tfail "register must pass --model"; }
  grep -q -- "--vendor anthropic" "$SESSADD" || { cat "$SESSADD"; tfail "register must pass --vendor (the profile's provider id for a kind=provider backend)"; }

  profile_write hns-role-test2 hermes local anthropic none claude-opus-5 - interactive ""
  profile_set hns-role-test2 harness_role '"orchestrator"'
  : >"$SESSADD"
  harness_register_rix hns-role-test2 /tmp/proj-rt2 1 p-role-fromprofile >/dev/null || tfail "register (role from profile) failed"
  grep -q -- "--role orchestrator" "$SESSADD" || { cat "$SESSADD"; tfail "register must default --role from the profile's harness_role"; }

  : >"$SESSADD"
  harness_register_rix hns-free /tmp/proj-free 1 p-role-explicit orchestrator >/dev/null || tfail "register (explicit role) failed"
  grep -q -- "--role orchestrator" "$SESSADD" || { cat "$SESSADD"; tfail "register: an explicit ROLE argument must override the profile's harness_role"; }
  grep -q -- "--vendor local" "$SESSADD" || { cat "$SESSADD"; tfail "register: a local-backend profile's vendor must be local"; }
  pass "harness register: --role coding default -> profile harness_role -> explicit ROLE argument (highest precedence); --model/--vendor always passed"

  # ---- register: the harness CLI's own refusal (e.g. an IP-unsafe vendor asking
  #      for orchestrator) is surfaced verbatim via stderr, never pre-judged here --
  (
    cat >"$HD/fakebin/harness-refuse" <<'FAKE3'
#!/bin/bash
while [[ ${1:-} == --json ]]; do shift; done
case "$1" in
  session)
    if [[ "$*" == *"--role orchestrator"* ]]; then
      echo "refused: vendor is not IP-safe for role orchestrator" >&2
      exit 1
    fi
    echo ok ;;
  *) echo '{}' ;;
esac
FAKE3
    chmod +x "$HD/fakebin/harness-refuse"
    settings_set harness_bin "$HD/fakebin/harness-refuse"
    err=$(harness_register_rix hns-free /tmp/proj-free 1 p-refuse orchestrator 2>&1) && tfail "register must fail when the harness CLI refuses"
    grep -q "refused: vendor is not IP-safe" <<<"$err" || { echo "$err"; tfail "register must surface the harness CLI's stderr verbatim"; }
    settings_set harness_bin "$HD/fakebin/harness"
  )
  pass "harness register: a harness CLI refusal (e.g. IP-unsafe orchestrator) is surfaced via stderr, not pre-judged in bash"

  # ---- harness role: persists the profile field and pushes --role to every live
  #      session (incl. a --slots label) whose label resolves back to this profile,
  #      never to another profile's session; refuses an unknown role -------------
  : >"$SESSADD"
  profile_write hns-role hermes local local none model-x - interactive ""
  jq -n --arg t "$(date -Is)" '{
    projects: [ {id:"p-role", repo_path:"/tmp/proj-role"} ],
    sessions: [
      {id:"s-role-1", project:"p-role", worker:"rix", label:"hns-role"},
      {id:"s-role-2", project:"p-role", worker:"rix", label:"hns-role-1"},
      {id:"s-role-other", project:"p-role", worker:"rix", label:"hns-free"}
    ],
    queue: [], events: [], generated_at: $t
  }' >"$HARNESS_DATA_DIR/overview.json"
  harness_set_role hns-role orchestrator >/dev/null || tfail "harness_set_role failed"
  [[ $(profile_get hns-role harness_role) == orchestrator ]] || tfail "harness_set_role must persist the profile's harness_role field"
  grep -q -- "--session s-role-1 --role orchestrator" "$SESSADD" || { cat "$SESSADD"; tfail "harness_set_role must push session set --role to a plain-labelled live session"; }
  grep -q -- "--session s-role-2 --role orchestrator" "$SESSADD" || { cat "$SESSADD"; tfail "harness_set_role must push session set --role to a --slots N session (label PROFILE-N)"; }
  ! grep -q -- "--session s-role-other" "$SESSADD" || { cat "$SESSADD"; tfail "harness_set_role must never touch a session belonging to a different profile"; }
  ( harness_set_role hns-role bogus-role ) >/dev/null 2>&1 && tfail "harness_set_role must refuse an unknown role"
  pass "harness_set_role: persists the profile field, pushes session set --role to every matching live session only, refuses an unknown role"

  # ---- sequence: harness role sets the field, then a later register (no explicit
  #      ROLE) picks it straight up -- --vendor local --role orchestrator together --
  : >"$SESSADD"
  harness_register_rix hns-role /tmp/proj-role 1 p-role-seq >/dev/null || tfail "register after harness role failed"
  grep -q -- "--role orchestrator" "$SESSADD" || { cat "$SESSADD"; tfail "register after 'harness role' must pick up --role orchestrator from the profile"; }
  grep -q -- "--vendor local" "$SESSADD" || { cat "$SESSADD"; tfail "register after 'harness role' must still carry --vendor local (a local-backend profile)"; }
  pass "harness role then register: a local-backend profile set to orchestrator via harness_set_role later registers --role orchestrator --vendor local"

  # ---- harness_extract_last_json: the LAST balanced top-level JSON object wins
  #      over nested braces, braces inside strings, and a broken object before it --
  EJF="$HD/extract-test.txt"
  printf 'noise\n{"action": "SPLIT", "broken": true\nmore prose, this object never closes\n{"action":"SPLIT","node":"P0","children":[{"id":"P0.1","title":"a } b { c"},{"id":"P0.2"}]}\ntrailing prose' >"$EJF"
  got=$(harness_extract_last_json "$EJF") || tfail "harness_extract_last_json must find the good top-level object past a broken one"
  [[ $(jq -r '.action' <<<"$got") == SPLIT ]] || { echo "$got"; tfail "extracted JSON must be a full object with .action"; }
  [[ $(jq -r '.node' <<<"$got") == P0 ]] || { echo "$got"; tfail "extracted JSON must be the OUTER object, not the inner nested {\"id\":\"P0.1\"}"; }
  [[ $(jq '.children | length' <<<"$got") == 2 ]] || { echo "$got"; tfail "extracted JSON must include both children (nested braces preserved, not truncated)"; }

  EJF2="$HD/extract-empty.txt"; printf 'no json anywhere in this text\n' >"$EJF2"
  harness_extract_last_json "$EJF2" >/dev/null 2>&1 && tfail "harness_extract_last_json must fail (nonzero exit, nothing printed) when nothing parses"

  EJF3="$HD/extract-multi.txt"; printf '{"first": true} some text in between {"second": true, "picked": "last"}' >"$EJF3"
  got3=$(harness_extract_last_json "$EJF3") || tfail "harness_extract_last_json must find a top-level object when there are two complete candidates"
  [[ $(jq -r '.picked // empty' <<<"$got3") == last ]] || { echo "$got3"; tfail "harness_extract_last_json must return the LAST top-level object, not the first"; }
  pass "harness_extract_last_json: last top-level object wins over nested braces, in-string braces, a broken object before it, and an earlier complete one"

  # ---- harness_extract_last_json: stays fast on a realistic (~100KiB) run log,
  #      brace-heavy prefix included (a code snippet's `function() {`, unclosed) --
  EJF4="$HD/extract-big.txt"
  { yes 'tool output line, includes a stray brace from a code snippet: function() {' | head -n 1500; printf '{"action":"SPLIT","node":"Pbig"}'; } >"$EJF4"
  t0=$(date +%s%N)
  got4=$(harness_extract_last_json "$EJF4") || tfail "harness_extract_last_json must still find the object behind a large brace-heavy prefix"
  t1=$(date +%s%N)
  [[ $(jq -r '.node' <<<"$got4") == Pbig ]] || { echo "$got4"; tfail "harness_extract_last_json must return the real object, not get lost in the prefix"; }
  ms=$(( (t1 - t0) / 1000000 ))
  (( ms < 5000 )) || tfail "harness_extract_last_json took ${ms}ms on a ~100KiB brace-heavy log (must stay well under a dispatch sweep)"
  pass "harness_extract_last_json: correct and fast (${ms}ms) on a large brace-heavy log"

  # ---- orchestration packet dispatch (SPLIT): only an orchestrator session/profile
  #      claims it (here: overview session role, defensive-checked independently of
  #      the profile field); the reaper extracts the last balanced JSON object from
  #      the delegate's reply and writes a --command receipt with --patch-file -----
  : >"$DELEGATE_LOG"; : >"$RECEIPTS"
  profile_write hns-orch hermes local local none model-x - interactive ""
  PKT_SPLIT="$HD/pkt-split.md"; printf 'SPLIT_REPLY_MARKER Decompose P0 into two children.\n' >"$PKT_SPLIT"
  printf '[{"node":"P0","path":"%s","command":"SPLIT"}]' "$PKT_SPLIT" >"$HD/inbox/p-split.json"
  jq -n --arg t "$(date -Is)" '{
    projects: [ {id:"p-split", repo_path:"/tmp/proj-split"} ],
    sessions: [ {id:"s-split", project:"p-split", worker:"rix", label:"hns-orch", role:"orchestrator", tier:"orchestrator", model:"model-x", vendor:"local", ip_safe:true} ],
    queue: [], events: [], generated_at: $t
  }' >"$HARNESS_DATA_DIR/overview.json"
  harness_dispatch_once || true
  grep -q "name=hns-P0" "$DELEGATE_LOG" || { cat "$DELEGATE_LOG"; tfail "an orchestrator session must claim and delegate the SPLIT packet"; }
  [[ -f ${PKT_SPLIT}.claimed ]] || tfail "the SPLIT packet must be claimed"
  harness_dispatch_reap
  splitline=$(grep "node=P0 " "$RECEIPTS" | tail -n1)
  [[ -n $splitline ]] || { cat "$RECEIPTS"; tfail "a SPLIT receipt is expected"; }
  grep -q "command=SPLIT" <<<"$splitline" || { echo "$splitline"; tfail "the SPLIT receipt must carry --command SPLIT"; }
  grep -q "status=done" <<<"$splitline" || { echo "$splitline"; tfail "the SPLIT receipt must be status=done once a JSON patch was extracted"; }
  splitpatch=$(sed -E 's/.*patch=([^ ]*).*/\1/' <<<"$splitline")
  [[ -s $splitpatch ]] || { echo "$splitline"; tfail "the SPLIT patch file must exist and be non-empty"; }
  [[ $(jq -r '.action' "$splitpatch") == SPLIT ]] || { cat "$splitpatch"; tfail "the SPLIT patch file must parse as JSON with .action == SPLIT"; }
  [[ $(jq -r '.node' "$splitpatch") == P0 ]] || { cat "$splitpatch"; tfail "the SPLIT patch must be the LAST balanced object (P0), not the broken/earlier one"; }
  pass "harness dispatch: an orchestration packet (SPLIT) is claimed by an orchestrator session; the reaper writes a --command receipt whose --patch-file is the last balanced JSON object"

  # ---- orchestration packet dispatch: a non-orchestrator profile/session must
  #      never claim one, even when detected by path suffix alone (no `command`
  #      field on the inbox row -- tolerate its absence per CONTRACTS.md §17.7) ---
  : >"$DELEGATE_LOG"
  PKT_SPLIT2="$HD/pkt-split2.PM.md"; printf 'PM_REPLY_MARKER Plan the next wave.\n' >"$PKT_SPLIT2"
  printf '[{"node":"P1","path":"%s"}]' "$PKT_SPLIT2" >"$HD/inbox/p-split2.json"
  jq -n --arg t "$(date -Is)" '{
    projects: [ {id:"p-split2", repo_path:"/tmp/proj-split2"} ],
    sessions: [ {id:"s-split2", project:"p-split2", worker:"rix", label:"hns-free"} ],
    queue: [], events: [], generated_at: $t
  }' >"$HARNESS_DATA_DIR/overview.json"
  harness_dispatch_once || true
  [[ $(wc -l <"$DELEGATE_LOG") == 0 ]] || { cat "$DELEGATE_LOG"; tfail "a non-orchestrator profile/session must not claim an orchestration packet (path-suffix .PM.md, no command field)"; }
  [[ -f $PKT_SPLIT2 ]] || tfail "the orchestration packet must remain unclaimed when skipped defensively"
  grep -q "not registered as orchestrator" "$OAL_EVENTS" || tfail "the defensive skip must emit an explanatory event"
  pass "harness dispatch: a non-orchestrator profile/session never claims an orchestration packet, detected by path suffix alone when the inbox row carries no command field"

  # ---- orchestration packet: the delegate's reply has no JSON object at all ->
  #      --status failed --summary, no --patch-file; status --json roles/orchestrator/
  #      overview_path are populated from overview.json (file-only, never null) -----
  : >"$DELEGATE_LOG"; : >"$RECEIPTS"
  PKT_NOJSON="$HD/pkt-nojson.md"; printf 'SPLIT_NO_JSON_MARKER just prose, no JSON anywhere in this reply.\n' >"$PKT_NOJSON"
  printf '[{"node":"P2","path":"%s","command":"SPLIT"}]' "$PKT_NOJSON" >"$HD/inbox/p-nojson.json"
  jq -n --arg t "$(date -Is)" '{
    projects: [ {id:"p-nojson", repo_path:"/tmp/proj-nojson", orchestrator:{"session":"s-nojson","model":"model-x"}} ],
    sessions: [ {id:"s-nojson", project:"p-nojson", worker:"rix", label:"hns-orch", role:"orchestrator", tier:"orchestrator", model:"model-x", vendor:"local", ip_safe:true} ],
    queue: [], events: [], generated_at: $t
  }' >"$HARNESS_DATA_DIR/overview.json"
  harness_dispatch_once || true
  harness_dispatch_reap
  nojsonline=$(grep "node=P2 " "$RECEIPTS" | tail -n1)
  [[ -n $nojsonline ]] || { cat "$RECEIPTS"; tfail "a P2 receipt is expected"; }
  grep -q "status=failed" <<<"$nojsonline" || { echo "$nojsonline"; tfail "no JSON in the reply -> the receipt status must be failed"; }
  grep -q "command=SPLIT" <<<"$nojsonline" || { echo "$nojsonline"; tfail "the failed receipt must still carry --command SPLIT"; }
  nojsonpatch=$(sed -E 's/.*patch=([^ ]*).*/\1/' <<<"$nojsonline")
  [[ -z $nojsonpatch ]] || { echo "$nojsonline"; tfail "a failed (no-JSON) receipt must not carry --patch-file"; }
  nojsonsummary=$(sed -E 's/.*summary=(.*)$/\1/' <<<"$nojsonline")
  [[ -n $nojsonsummary ]] || { echo "$nojsonline"; tfail "a failed (no-JSON) receipt must carry --summary"; }
  pass "harness dispatch: no JSON object in the delegate's reply -> --command receipt with --status failed --summary, no --patch-file"

  statusj=$(harness_status_json)
  op=$(jq -r '.overview_path' <<<"$statusj")
  [[ -n $op && $op != null ]] || { echo "$statusj"; tfail "harness_status_json.overview_path must always be the real path, never null"; }
  [[ $op == "$HARNESS_DATA_DIR/overview.json" ]] || { echo "$statusj"; tfail "harness_status_json.overview_path must be harness_data_dir/overview.json"; }
  [[ $(jq -r '.roles[] | select(.session=="s-nojson") | .role' <<<"$statusj") == orchestrator ]] || { echo "$statusj"; tfail "harness_status_json.roles must carry each registered rix session's role"; }
  [[ $(jq -r '.roles[] | select(.session=="s-nojson") | .model' <<<"$statusj") == model-x ]] || { echo "$statusj"; tfail "harness_status_json.roles must carry model/vendor/tier/ip_safe from overview.json"; }
  [[ $(jq -r '.orchestrator["p-nojson"].session' <<<"$statusj") == s-nojson ]] || { echo "$statusj"; tfail "harness_status_json.orchestrator must map project id -> overview.json's projects[].orchestrator"; }
  pass "harness_status_json: overview_path always non-null; roles/orchestrator surfaced from overview.json"

  lst=$("$L" status --json)
  lop=$(jq -r '.harness.overview_path' <<<"$lst")
  [[ -n $lop && $lop != null ]] || { echo "$lst" | head -c 2000; tfail "'omarchy-agent-launcher status --json'.harness.overview_path must be non-null (wired through cmd_status_json)"; }
  pass "status --json: .harness.overview_path is non-null through the real CLI, not just the bash function"

  exit 0
) || exit 1

echo "== sentinel → harness: put a Sentinel advisory on the Gantt"
(
  source "$ROOT/lib/common.sh"; OAL_LIB="$ROOT/lib"
  source "$ROOT/lib/events.sh"
  source "$ROOT/lib/harness.sh"
  source "$ROOT/lib/sentinel.sh"
  source "$ROOT/lib/harness_bridge.sh"
  OPTS=(); CMD=(); JSON=0; OAL_DRY_RUN=0; OAL_SELF="$L"
  export OAL_AGENT=test-rix OAL_SENTINEL_BIN=true   # sentinel_installed only needs `have` to succeed; advisories are stubbed below
  SB="$T/sentinel-bridge"; mkdir -p "$SB/fakebin" "$SB/nodes"
  export HARNESS_DATA_DIR="$SB/data"; mkdir -p "$HARNESS_DATA_DIR"
  INITLOG="$SB/init.log"; : >"$INITLOG"
  LSFLAG="$SB/ls-created"
  CURLLOG="$SB/curl.log"; : >"$CURLLOG"

  # ---- fake `harness`: records init argv, ls flips [] -> [project] after init, show reads a fixture per node --
  cat >"$SB/fakebin/harness" <<'FAKE'
#!/bin/bash
case "$1" in
  init)
    printf '%s\n' "$*" >>"__INITLOG__"
    touch "__LSFLAG__"
    echo ok ;;
  ls)
    if [[ -f "__LSFLAG__" ]]; then echo '[{"id":"sentinel-repo1","repo_path":"repo1"}]'
    else echo '[]'
    fi ;;
  show)
    shift; proj="" node=""
    while (( $# )); do case "$1" in --project) proj=$2; shift 2 ;; --node) node=$2; shift 2 ;; *) shift ;; esac; done
    cat "__SB__/nodes/$node.json" 2>/dev/null || echo "{\"id\":\"$node\",\"children\":[]}" ;;
  *) echo '{}' ;;
esac
FAKE
  sed -i "s#__INITLOG__#$INITLOG#g; s#__LSFLAG__#$LSFLAG#g; s#__SB__#$SB#g" "$SB/fakebin/harness"
  chmod +x "$SB/fakebin/harness"

  # ---- fake curl: logs URL, whether X-Harness was sent, and the POST body ----------
  cat >"$SB/fakebin/curl" <<'FAKE2'
#!/bin/bash
args=("$@"); url="${args[-1]}"; body="" hh=no
for ((i=0; i<${#args[@]}; i++)); do
  [[ ${args[i]} == -d ]] && body=${args[i+1]}
  [[ ${args[i]} == "X-Harness: 1" ]] && hh=yes
done
printf '%s\t%s\t%s\n' "$url" "$hh" "$body" >>"__CURLLOG__"
echo '{}'
FAKE2
  sed -i "s#__CURLLOG__#$CURLLOG#g" "$SB/fakebin/curl"
  chmod +x "$SB/fakebin/curl"

  export PATH="$SB/fakebin:$PATH"
  settings_set harness_bin "$SB/fakebin/harness"
  patch_line() { awk -F'\t' '$1 ~ /\/patch$/ {print $3}' "$CURLLOG" | sed -n "${1}p"; }

  # ---- one advisory, <=2 files, has a verification command -------------------------
  cat >"$SB/nodes/P0.json" <<'JSON'
{"id":"P0","children":[{"id":"n-edge-1","title":"Leaked key in config.js"}]}
JSON
  sentinel_advisories_json() {
    cat <<'JSON'
[{"id":"a1","severity":"high","title":"Leaked key in config.js","summary":"A secret key is committed in config.js.",
  "repo_path":"repo1","verification":"grep -q ok config.js","affected_files":["config.js"]}]
JSON
  }
  out=$(sentinel_plan a1)
  grep -q "a1 -> project sentinel-repo1, node n-edge-1" <<<"$out" || { echo "$out"; tfail "plan output"; }
  [[ $(wc -l <"$INITLOG") == 1 ]] || { cat "$INITLOG"; tfail "harness init must be called exactly once"; }
  grep -q -- "--repo repo1" "$INITLOG" || tfail "init repo"
  body1=$(patch_line 1)
  jq -e 'type == "object"' <<<"$body1" >/dev/null || { echo "$body1"; tfail "ADD_CHILDREN body must be valid JSON"; }
  [[ $(jq '.children | length' <<<"$body1") == 1 ]] || tfail "one edge child for a single advisory"
  [[ $(jq -r '.parent' <<<"$body1") == P0 ]] || tfail "children added under P0"
  [[ $(jq -r '.children[0].oracle.type' <<<"$body1") == cmd ]] || tfail "cmd oracle when a verification command exists"
  [[ $(jq -r '.children[0].oracle.cmd' <<<"$body1") == "grep -q ok config.js" ]] || tfail "oracle cmd carried through"
  [[ $(jq -r '.children[0].touches | length' <<<"$body1") == 1 ]] || tfail "one touch"
  node1=$(jq -r --arg id a1 '.[$id].harness_node' "$XDG_STATE_HOME/omarchy-agent-launcher/sentinel-advisories.json")
  [[ $node1 == n-edge-1 ]] || tfail "advisory -> node mapping recorded"

  # ---- idempotent: re-running must not add another child ---------------------------
  before=$(wc -l <"$CURLLOG")
  out2=$(sentinel_plan a1)
  grep -q "already planned" <<<"$out2" || { echo "$out2"; tfail "second run should say already planned"; }
  after=$(wc -l <"$CURLLOG")
  [[ $before == "$after" ]] || tfail "second run must not POST again"
  [[ $(wc -l <"$INITLOG") == 1 ]] || tfail "second run must not call harness init again"
  pass "sentinel plan: creates the project once, one cmd-oracle edge under P0, idempotent re-run"

  # ---- no verification command -> session_ack oracle; severity -> estimate_min -----
  cat >"$SB/nodes/P0.json" <<'JSON'
{"id":"P0","children":[{"id":"n-edge-1","title":"Leaked key in config.js"},{"id":"n-edge-2","title":"Unpinned action"}]}
JSON
  sentinel_advisories_json() {
    cat <<'JSON'
[{"id":"a2","severity":"low","title":"Unpinned action","repo_path":"repo1","affected_files":["/.github/workflows/ci.yml"]}]
JSON
  }
  sentinel_plan a2 >/dev/null
  body2=$(patch_line 2)
  [[ $(jq -r '.children[0].oracle.type' <<<"$body2") == session_ack ]] || tfail "session_ack oracle when no verification command"
  [[ $(jq -r '.children[0].estimate_min' <<<"$body2") == 15 ]] || tfail "low severity -> 15 min estimate"
  [[ $(wc -l <"$INITLOG") == 1 ]] || tfail "same repo must reuse the existing project, no second init"
  pass "sentinel plan: session_ack oracle without a verification command; severity maps to estimate_min"

  # ---- more than two files -> a container with up to 4 edge children, <=2 touches each --
  cat >"$SB/nodes/P0.json" <<'JSON'
{"id":"P0","children":[{"id":"c-3","title":"Widely scattered secret"}]}
JSON
  sentinel_advisories_json() {
    cat <<'JSON'
[{"id":"a3","severity":"medium","title":"Widely scattered secret","repo_path":"repo1",
  "verification":"scripts/verify.sh","affected_files":["a.js","b.js","c.js","d.js"]}]
JSON
  }
  sentinel_plan a3 >/dev/null
  body3=$(patch_line 3)   # the container child, added under P0
  body4=$(patch_line 4)   # the edge children, added under the container
  [[ $(jq -r '.parent' <<<"$body3") == P0 ]] || tfail "the container is added under P0"
  [[ $(jq -r '.children[0].kind' <<<"$body3") == container ]] || tfail "more than 2 files -> a container child"
  [[ $(jq -r '.parent' <<<"$body4") == c-3 ]] || tfail "edge children are added under the container node"
  [[ $(jq '.children | length' <<<"$body4") == 2 ]] || tfail "4 files chunked into edge children of at most 2 touches"
  jq -e 'all(.children[]; .kind == "edge" and (.touches | length) <= 2 and .oracle.type == "cmd")' <<<"$body4" >/dev/null \
    || { echo "$body4"; tfail "each edge child: kind edge, <=2 touches, a real (cmd) oracle"; }
  pass "sentinel plan: more than two files -> a container with edge children of at most two touches each"
  exit 0
) || exit 1

echo "ALL TESTS PASSED"
