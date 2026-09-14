#!/bin/bash
# Rix x session-harness (~/Work/session-harness, CLI `harness`, API on
# 127.0.0.1:<ui_port>). The harness is the scheduler and single source of
# truth (project.json): it plans, splits, and assigns work as inbox packets
# under <repo>/.harness/inbox/<sid>/<node>.md. A Rix profile is registered as
# a harness worker session; this file dispatches its packets as `delegate
# --wait` jobs and writes the outbox receipt from the real result — the
# harness runs the oracle before anything is `done`.
#
# Money: a metered backend never starts work without an approved budget. When
# the project's remaining_usd is short, we ask once (POST cost/request) and
# skip; we never guess a price and never guess $0 for an unpriced model.
#
#   ~/.session-harness/config.toml    ui_port (default 7744)
#   ~/.session-harness/overview.json  {projects[], sessions[], queue[], events[], generated_at}
#                                      each project carries pending_approval and cost{spent_usd,approved_usd,remaining_usd}
#   ~/.session-harness/events.jsonl
#
# `status --json` (and this file's harness_status_json) must stay network-free:
# it reads pid files under $OAL_STATE/harness/ and overview.json's mtime, and
# never calls curl. Every other function here may call the `harness` CLI or
# POST to the API with `X-Harness: 1`.

HARNESS_STATE_DIR="$OAL_STATE/harness"

# ------------------------------------------------------------------ basics ----
harness_bin() {
  local b; b=$(settings_get harness_bin "")
  if [[ -n $b && -x $b ]]; then printf '%s' "$b"; return 0; fi
  if have harness; then command -v harness; return 0; fi
  b="$HOME/Work/session-harness/.venv/bin/harness"
  if [[ -x $b ]]; then printf '%s' "$b"; return 0; fi
  warn "harness CLI not found (set harness_bin in settings.json, put harness on PATH, or install it at ~/Work/session-harness)"
  return 1
}

harness_data_dir() { printf '%s' "${HARNESS_DATA_DIR:-$HOME/.session-harness}"; }

# http://127.0.0.1:<ui_port> from config.toml (default 7744). No network.
harness_url() {
  local cfg port=7744 v
  cfg="$(harness_data_dir)/config.toml"
  if [[ -f $cfg ]]; then
    v=$(sed -n -E 's/^[[:space:]]*ui_port[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$cfg" | head -n1)
    [[ -n $v ]] && port=$v
  fi
  printf 'http://127.0.0.1:%s' "$port"
}

harness_alive() { have curl && curl -sf -m 1 "$(harness_url)/api/status" >/dev/null 2>&1; }

harness_overview_json() {
  local f; f="$(harness_data_dir)/overview.json"
  [[ -s $f ]] && cat "$f" || printf '{}'
}

# ------------------------------------------------------------ serve / stop ----
harness_pid_alive() { [[ -s $1 ]] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }

# setsid harness serve --all under $OAL_STATE/harness/ (pid + log), wait up to
# 5s for overview.json, then start our own dispatch loop the same way.
harness_serve_start() {
  mkdir -p "$HARNESS_STATE_DIR"
  local bin; bin=$(harness_bin) || return 1
  if harness_pid_alive "$HARNESS_STATE_DIR/serve.pid"; then
    : # already running
  elif (( OAL_DRY_RUN )); then
    say "[dry-run] would start: $bin serve --all"
  else
    setsid nohup "$bin" serve --all >"$HARNESS_STATE_DIR/serve.log" 2>&1 </dev/null &
    echo $! >"$HARNESS_STATE_DIR/serve.pid"
    disown 2>/dev/null || true
  fi
  if (( ! OAL_DRY_RUN )); then
    local i f; f="$(harness_data_dir)/overview.json"
    for i in $(seq 1 50); do [[ -s $f ]] && break; sleep 0.1; done
  fi
  if harness_pid_alive "$HARNESS_STATE_DIR/dispatch.pid"; then
    : # already running
  elif (( OAL_DRY_RUN )); then
    say "[dry-run] would start: $OAL_SELF harness dispatch"
  else
    setsid nohup "$OAL_SELF" harness dispatch >"$HARNESS_STATE_DIR/dispatch.log" 2>&1 </dev/null &
    echo $! >"$HARNESS_STATE_DIR/dispatch.pid"
    disown 2>/dev/null || true
  fi
  return 0
}

harness_serve_stop() {
  local f p pid
  for f in dispatch.pid serve.pid; do
    p="$HARNESS_STATE_DIR/$f"
    [[ -s $p ]] || continue
    pid=$(cat "$p" 2>/dev/null)
    [[ -n $pid ]] && kill "$pid" 2>/dev/null
    rm -f "$p"
  done
}

# --------------------------------------------------------------- registry ----
# harness_cost_class PROFILE -> free | subscription | metered, from the
# profile's own backend (or its provider when no backend id was saved).
harness_cost_class() {
  local profile=$1 backend b provider auth
  backend=$(profile_get "$profile" backend 2>/dev/null)
  [[ -n $backend ]] || backend=$(profile_get "$profile" provider 2>/dev/null)
  if [[ -z $backend ]]; then printf 'free'; return 0; fi
  b=$(backend_get "$backend" 2>/dev/null) || { printf 'free'; return 0; }
  provider=$(jq -r '.provider // ""' <<<"$b"); auth=$(jq -r '.auth // "none"' <<<"$b")
  if [[ $provider == local ]]; then printf 'free'
  elif [[ $auth == oauth ]]; then printf 'subscription'
  elif [[ $auth == api-key ]]; then printf 'metered'
  else printf 'free'; fi
}

# harness_register_rix PROFILE [REPO] -- one `harness session add` per project
# in overview.json whose repo_path is REPO (default: $PWD).
harness_register_rix() {
  local profile=$1 repo=${2:-$PWD}
  profile_exists "$profile" || fail "harness register: no saved agent named '$profile'"
  local bin; bin=$(harness_bin) || return 1
  local backend; backend=$(profile_get "$profile" backend 2>/dev/null)
  [[ -n $backend ]] || backend=$(profile_get "$profile" provider 2>/dev/null)
  local class; class=$(harness_cost_class "$profile")
  local -a projects=()
  mapfile -t projects < <(jq -r --arg repo "$repo" '.projects[]? | select(.repo_path == $repo) | .id' <<<"$(harness_overview_json)")
  if (( ${#projects[@]} == 0 )); then
    warn "harness register: no project in overview.json has repo_path $repo"
    return 1
  fi
  local p rc=0
  for p in "${projects[@]}"; do
    if (( OAL_DRY_RUN )); then
      say "[dry-run] would: $bin session add --project $p --worker rix --label $profile --cwd $repo --cost-class $class --backend $backend"
    else
      "$bin" session add --project "$p" --worker rix --label "$profile" --cwd "$repo" --cost-class "$class" --backend "$backend" \
        || { warn "harness session add failed for project $p"; rc=1; }
    fi
  done
  return "$rc"
}

# ------------------------------------------------------------------ money ----
# harness_estimate_usd PROFILE PACKET(file-or-text) -> USD on stdout ("0" for
# free/subscription); non-zero exit and no usable number when the model's
# price is unknown for a metered backend (never guess $0).
harness_estimate_usd() {
  local profile=$1 packet=$2 class
  class=$(harness_cost_class "$profile")
  if [[ $class == free || $class == subscription ]]; then printf '0'; return 0; fi
  local text
  if [[ -f $packet ]]; then text=$(cat "$packet" 2>/dev/null); else text=$packet; fi
  local chars=${#text}
  local in_tok=$(( chars / 4 )); (( in_tok == 0 && chars > 0 )) && in_tok=1
  local out_tok=$(( in_tok * 4 ))
  local model; model=$(profile_get "$profile" model)
  local prices; prices=$(declare -F usage_catalog_prices >/dev/null && usage_catalog_prices || printf '{}')
  local price; price=$(jq -c --arg m "$model" \
    '(.[$m] // (to_entries | map(select(.key | ascii_downcase == ($m|ascii_downcase))) | .[0].value) // null)' <<<"$prices")
  local input_p output_p
  input_p=$(jq -r 'if . == null then "" else (.input // "") end' <<<"$price")
  output_p=$(jq -r 'if . == null then "" else (.output // "") end' <<<"$price")
  if [[ -z $input_p || -z $output_p ]]; then return 1; fi
  awk -v it="$in_tok" -v ot="$out_tok" -v ip="$input_p" -v op="$output_p" 'BEGIN{printf "%.6f", (it*ip + ot*op)/1000000}'
}

# POST /api/project/{id}/cost/request  {node, model, vendor, estimate_usd, reason, by}
harness_cost_request() {
  local project=$1 node=$2 model=$3 vendor=$4 estimate=$5 reason=$6 by=$7
  local body; body=$(jq -nc --arg node "$node" --arg model "$model" --arg vendor "$vendor" \
    --argjson estimate_usd "${estimate:-0}" --arg reason "$reason" --arg by "$by" \
    '{node:$node, model:$model, vendor:$vendor, estimate_usd:$estimate_usd, reason:$reason, by:$by}')
  if (( OAL_DRY_RUN )); then say "[dry-run] would POST $(harness_url)/api/project/$project/cost/request $body"; return 0; fi
  curl -sS -m 5 -H 'X-Harness: 1' -H 'Content-Type: application/json' \
    -X POST -d "$body" "$(harness_url)/api/project/$project/cost/request" >/dev/null 2>&1
}

# harness_approve PROJECT USD [REASON]  -> POST /api/project/{id}/approve
harness_approve() {
  local project=$1 usd=$2 reason=${3:-approved}
  [[ -n $project && -n $usd ]] || fail "harness approve: needs PROJECT and USD"
  local body; body=$(jq -nc --argjson usd "$usd" --arg reason "$reason" '{usd:$usd, reason:$reason}')
  if (( OAL_DRY_RUN )); then say "[dry-run] would POST $(harness_url)/api/project/$project/approve $body"; return 0; fi
  curl -sS -m 5 -H 'X-Harness: 1' -H 'Content-Type: application/json' -X POST -d "$body" "$(harness_url)/api/project/$project/approve"
}

# harness_decline PROJECT  -> POST /api/project/{id}/cost/decline
harness_decline() {
  local project=$1
  [[ -n $project ]] || fail "harness decline: needs PROJECT"
  if (( OAL_DRY_RUN )); then say "[dry-run] would POST $(harness_url)/api/project/$project/cost/decline"; return 0; fi
  curl -sS -m 5 -H 'X-Harness: 1' -X POST "$(harness_url)/api/project/$project/cost/decline"
}

# --------------------------------------------------------------- dispatch ----
# One packet: cost-gate, claim, delegate --wait, receipt, event. Never called
# directly by tests except through harness_dispatch_once.
harness_dispatch_packet() { # <bin> <project> <session> <profile> <packet-json>
  local bin=$1 proj=$2 sid=$3 profile=$4 pkt=$5
  local node path
  node=$(jq -r '.node // .id // empty' <<<"$pkt")
  path=$(jq -r '.path // empty' <<<"$pkt")
  [[ -n $node && -n $path ]] || return 0
  [[ $path == *.claimed ]] && return 0
  [[ -f $path ]] || return 0
  local ref="harness:$proj:$node"
  local backend model
  backend=$(profile_get "$profile" backend 2>/dev/null); [[ -n $backend ]] || backend=$(profile_get "$profile" provider 2>/dev/null)
  model=$(profile_get "$profile" model 2>/dev/null)
  if [[ -z $backend ]]; then
    event_emit "$profile" note "harness: profile $profile has no backend; cannot dispatch $node" --source harness --level warn --ref "$ref:failed"
    return 0
  fi
  local class; class=$(harness_cost_class "$profile")
  if [[ $class == metered ]]; then
    local estimate
    if ! estimate=$(harness_estimate_usd "$profile" "$path"); then
      event_emit "$profile" note "harness: no known price for $model; refusing $node (metered, unknown cost)" --source harness --level warn --ref "$ref:failed"
      return 0
    fi
    local remaining
    remaining=$("$bin" cost --project "$proj" --json 2>/dev/null | jq -r '.remaining_usd // 0' 2>/dev/null)
    [[ $remaining =~ ^-?[0-9.]+$ ]] || remaining=0
    if awk -v r="$remaining" -v e="$estimate" 'BEGIN{exit !(r < e)}'; then
      mkdir -p "$HARNESS_STATE_DIR"
      local reqf="$HARNESS_STATE_DIR/requested.txt" key="$proj:$node"
      touch "$reqf"
      if ! grep -qxF "$key" "$reqf"; then
        harness_cost_request "$proj" "$node" "$model" "$backend" "$estimate" "harness dispatch: $node needs \$$estimate" "$profile"
        printf '%s\n' "$key" >>"$reqf"
        event_emit "$profile" note "harness: requested \$$estimate for $node (project $proj, \$$remaining remaining)" --source harness --ref "$ref:requested"
      fi
      return 0
    fi
  fi
  if (( OAL_DRY_RUN )); then
    say "[dry-run] would claim $path and delegate $node ($profile on $backend)"
    return 0
  fi
  local claimed="${path}.claimed"
  mv -f "$path" "$claimed" 2>/dev/null || return 0
  event_emit "$profile" note "harness: starting $node" --source harness --ref "$ref:start"
  local content trailer result rc status
  content=$(cat "$claimed" 2>/dev/null)
  trailer=$'\n\nWhen finished, print the oracle command output; do not edit files outside touches.'
  local -a saved_opts=("${OPTS[@]}")
  OPTS=(--backend "$backend" --name "hns-$node" --task-title "$node" --model "$model" --job-stdin --wait)
  result=$(printf '%s%s\n' "$content" "$trailer" | cmd_delegate 2>&1); rc=$?
  OPTS=("${saved_opts[@]}")
  if grep -qiE '429|rate limit|usage limit' <<<"$result"; then status="throttled"
  elif (( rc == 0 )); then status="done"
  else status="failed"
  fi
  local evidence; evidence=$(tail -n 40 <<<"$result")
  "$bin" receipt --project "$proj" --session "$sid" --node "$node" --status "$status" --evidence "$evidence" >/dev/null 2>&1 \
    || warn "harness receipt failed for $node ($status)"
  event_emit "$profile" note "harness: $node $status" --source harness --ref "$ref:$status"
}

# One sweep: every rix session in overview.json whose label is a saved
# profile, every unclaimed packet in its inbox.
harness_dispatch_once() {
  local bin; bin=$(harness_bin) || return 1
  local overview; overview=$(harness_overview_json)
  local sess
  while IFS= read -r sess; do
    [[ -n $sess ]] || continue
    local proj sid label
    proj=$(jq -r '.project // empty' <<<"$sess")
    sid=$(jq -r '.id // empty' <<<"$sess")
    label=$(jq -r '.label // empty' <<<"$sess")
    [[ -n $proj && -n $sid && -n $label ]] || continue
    profile_exists "$label" || continue
    local inbox; inbox=$("$bin" inbox --project "$proj" --session "$sid" --json 2>/dev/null)
    [[ $inbox == \[* ]] || inbox='[]'
    local pkt
    while IFS= read -r pkt; do
      [[ -n $pkt ]] || continue
      harness_dispatch_packet "$bin" "$proj" "$sid" "$label" "$pkt"
    done < <(jq -c '.[]?' <<<"$inbox")
  done < <(jq -c '.sessions[]? | select(.worker == "rix")' <<<"$overview")
}

# Every 3s until killed (started by harness_serve_start as its own process).
harness_dispatch_loop() {
  trap 'exit 0' TERM INT
  while :; do
    harness_dispatch_once || true
    sleep 3
  done
}

# ----------------------------------------------------------------- status ----
# File/pid based only: overview.json's mtime (<15s old = alive) and its
# pending_approvals, the pid files under $OAL_STATE/harness/. Never curl.
harness_status_json() {
  local bin; bin=$(harness_bin 2>/dev/null) || bin=""
  local url ddir; url=$(harness_url); ddir=$(harness_data_dir)
  local ov="$ddir/overview.json" alive=false
  if [[ -f $ov ]]; then
    local mtime now; mtime=$(stat -c %Y "$ov" 2>/dev/null || echo 0); now=$(date +%s)
    (( now - mtime < 15 )) && alive=true
  fi
  local serving_pid=null dispatch_pid=null
  harness_pid_alive "$HARNESS_STATE_DIR/serve.pid" && serving_pid=$(cat "$HARNESS_STATE_DIR/serve.pid")
  harness_pid_alive "$HARNESS_STATE_DIR/dispatch.pid" && dispatch_pid=$(cat "$HARNESS_STATE_DIR/dispatch.pid")
  local overview; overview=$(harness_overview_json)
  local projects; projects=$(jq '.projects? | length // 0' <<<"$overview" 2>/dev/null); [[ $projects =~ ^[0-9]+$ ]] || projects=0
  local pending; pending=$(jq -c '[.projects[]? | select(.pending_approval != null) | {id, pending_approval}]' <<<"$overview" 2>/dev/null)
  [[ $pending == \[* ]] || pending='[]'
  jq -nc --argjson alive "$alive" --arg url "$url" --arg data_dir "$ddir" --arg bin "$bin" \
    --argjson serving_pid "${serving_pid:-null}" --argjson dispatch_pid "${dispatch_pid:-null}" \
    --argjson projects "$projects" --argjson pending_approvals "$pending" \
    '{alive:$alive, url:$url, data_dir:$data_dir, bin:$bin, serving_pid:$serving_pid, dispatch_pid:$dispatch_pid,
      projects:$projects, pending_approvals:$pending_approvals}'
}
