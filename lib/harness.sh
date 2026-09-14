#!/bin/bash
# Rix x session-harness (~/Work/session-harness, CLI `harness`, API on
# 127.0.0.1:<ui_port>). The harness is the scheduler and single source of
# truth (project.json): it plans, splits, and assigns work as inbox packets
# under <repo>/.harness/inbox/<sid>/<node>.md. A Rix profile is registered as
# a harness worker session; this file dispatches its packets as detached
# `delegate` jobs and a reaper writes the outbox receipt from the real result
# once each finishes — the harness runs the oracle before anything is `done`.
#
# Money (fail CLOSED, never guess): a backend is `free` only when it is the
# local GPU; `subscription` only when it is a signed-in OAuth provider;
# everything else -- api-key, an unresolvable backend, a missing record, an
# OAuth provider nobody signed in to, or a fallback chain that can hop to an
# api-key provider -- is `metered`. A metered start needs either an approved
# harness budget (dispatch path) or a human-typed `--approved-usd` (direct
# `delegate` / `rix ask` / `rix chat`); short of that we print the estimate
# and refuse. We never guess $0 for a model with no known price.
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
HARNESS_JOBS_DIR="$HARNESS_STATE_DIR/jobs"

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
# harness_backend_cost_class BACKEND -> free | subscription | metered.
# Fails CLOSED: no backend id, an unresolvable backend, an OAuth provider
# nobody is signed in to, or any auth this launcher does not recognize -> metered.
# Only the local GPU is free; only a SIGNED-IN OAuth provider is a subscription.
harness_backend_cost_class() {
  local backend=$1 b provider auth
  [[ -n $backend ]] || { printf 'metered'; return 0; }
  b=$(backend_get "$backend" 2>/dev/null) || { printf 'metered'; return 0; }
  provider=$(jq -r '.provider // ""' <<<"$b" 2>/dev/null); auth=$(jq -r '.auth // "none"' <<<"$b" 2>/dev/null)
  if [[ $provider == local ]]; then
    printf 'free'
  elif [[ $auth == oauth ]]; then
    if [[ " $(backends_signed_providers) " == *" $provider "* ]]; then printf 'subscription'; else printf 'metered'; fi
  else
    printf 'metered'   # api-key, none, or anything unrecognized: fail closed
  fi
}

# The first fallback-chain hop (provider/model) that resolves to an api-key
# backend, or nothing. harness_chain_metered_hop CHAIN
harness_chain_metered_hop() {
  local chain=$1
  [[ -n $chain ]] || return 0
  declare -F fallback_chain_json >/dev/null || return 0
  local entries; entries=$(fallback_chain_json "$chain" 2>/dev/null)
  [[ -n $entries && $entries != "[]" ]] || return 0
  local n; n=$(jq 'length' <<<"$entries" 2>/dev/null); [[ $n =~ ^[0-9]+$ ]] || return 0
  local i provider model hb hauth
  for (( i = 0; i < n; i++ )); do
    provider=$(jq -r ".[$i].provider" <<<"$entries"); model=$(jq -r ".[$i].model" <<<"$entries")
    hb=$(backend_get "$provider" 2>/dev/null) || continue
    hauth=$(jq -r '.auth // "none"' <<<"$hb")
    if [[ $hauth == api-key ]]; then printf '%s/%s' "$provider" "$model"; return 0; fi
  done
  return 0
}

# harness_cost_class PROFILE -> free | subscription | metered, from the
# profile's own backend (fail-closed, see harness_backend_cost_class) AND its
# Hermes fallback_chain: any api-key hop makes the whole profile metered even
# when the primary backend is free or a signed-in subscription.
harness_cost_class() {
  local profile=$1 backend class
  backend=$(profile_get "$profile" backend 2>/dev/null)
  [[ -n $backend ]] || backend=$(profile_get "$profile" provider 2>/dev/null)
  class=$(harness_backend_cost_class "$backend")
  if [[ $class != metered ]]; then
    local chain hop; chain=$(profile_get "$profile" fallback_chain 2>/dev/null)
    if [[ -n $chain ]] && hop=$(harness_chain_metered_hop "$chain") && [[ -n $hop ]]; then
      class=metered
    fi
  fi
  printf '%s' "$class"
}

# Why harness_cost_class picked what it picked (for register's warning and
# for the event trail); never used to decide anything, only to explain.
harness_cost_class_reason() {
  local profile=$1 backend chain hop
  backend=$(profile_get "$profile" backend 2>/dev/null); [[ -n $backend ]] || backend=$(profile_get "$profile" provider 2>/dev/null)
  chain=$(profile_get "$profile" fallback_chain 2>/dev/null)
  if [[ -n $chain ]] && hop=$(harness_chain_metered_hop "$chain") && [[ -n $hop ]]; then
    printf 'fallback chain "%s" can hop to %s (api-key)' "$chain" "$hop"
  elif [[ -z $backend ]]; then
    printf 'no backend recorded on the profile'
  else
    printf 'backend %s' "$backend"
  fi
}

# harness_register_rix PROFILE [REPO] [SLOTS] -- one `harness session add`
# per project in overview.json whose repo_path is REPO (default: $PWD), per
# slot 1..SLOTS (default 1): SLOTS>1 registers "<profile>-1".."<profile>-N"
# so one launcher profile can be N parallel harness workers.
harness_register_rix() {
  local profile=$1 repo=${2:-$PWD} slots=${3:-1}
  [[ $slots =~ ^[0-9]+$ && $slots -ge 1 ]] || slots=1
  profile_exists "$profile" || fail "harness register: no saved agent named '$profile'"
  local bin; bin=$(harness_bin) || return 1
  local backend; backend=$(profile_get "$profile" backend 2>/dev/null)
  [[ -n $backend ]] || backend=$(profile_get "$profile" provider 2>/dev/null)
  local class; class=$(harness_cost_class "$profile")
  local chain; chain=$(profile_get "$profile" fallback_chain 2>/dev/null)
  if [[ -n $chain ]]; then
    local hop; hop=$(harness_chain_metered_hop "$chain")
    [[ -n $hop ]] && warn "harness register: $profile's fallback chain '$chain' can hop to $hop (api-key) -- registering as metered"
  fi
  local -a projects=()
  mapfile -t projects < <(jq -r --arg repo "$repo" '.projects[]? | select(.repo_path == $repo) | .id' <<<"$(harness_overview_json)")
  if (( ${#projects[@]} == 0 )); then
    warn "harness register: no project in overview.json has repo_path $repo"
    return 1
  fi
  local p s label rc=0
  for p in "${projects[@]}"; do
    for (( s = 1; s <= slots; s++ )); do
      label=$profile; (( slots > 1 )) && label="$profile-$s"
      if (( OAL_DRY_RUN )); then
        say "[dry-run] would: $bin session add --project $p --worker rix --label $label --cwd $repo --cost-class $class --backend $backend"
      else
        "$bin" session add --project "$p" --worker rix --label "$label" --cwd "$repo" --cost-class "$class" --backend "$backend" \
          || { warn "harness session add failed for project $p ($label)"; rc=1; }
      fi
    done
  done
  return "$rc"
}

# A session label may be "<profile>" or "<profile>-N" (one of --slots N
# parallel workers registered for the same launcher profile). Resolve it back
# to the real saved profile, or fail. harness_profile_for_label LABEL
harness_profile_for_label() {
  local label=$1
  profile_exists "$label" && { printf '%s' "$label"; return 0; }
  local base=${label%-*} suffix=${label##*-}
  if [[ $suffix =~ ^[0-9]+$ && $base != "$label" ]] && profile_exists "$base"; then printf '%s' "$base"; return 0; fi
  return 1
}

# ------------------------------------------------------------------ money ----
# harness_estimate_from_class CLASS MODEL TEXT-OR-FILE -> USD ("0" for
# free/subscription); non-zero exit when a metered model's price is unknown
# (never guess $0). A delegate is a whole agent loop, not one call: the
# per-turn price is multiplied by settings.json:harness_turn_factor (20).
harness_estimate_from_class() {
  local class=$1 model=$2 packet=$3
  if [[ $class == free || $class == subscription ]]; then printf '0'; return 0; fi
  local text
  if [[ -f $packet ]]; then text=$(cat "$packet" 2>/dev/null); else text=$packet; fi
  local chars=${#text}
  local in_tok=$(( chars / 4 )); (( in_tok == 0 && chars > 0 )) && in_tok=1
  local out_tok=$(( in_tok * 4 ))
  local turns; turns=$(settings_get harness_turn_factor 20); [[ $turns =~ ^[0-9]+$ ]] || turns=20
  local prices; prices=$(declare -F usage_catalog_prices >/dev/null && usage_catalog_prices || printf '{}')
  local price; price=$(jq -c --arg m "$model" \
    '(.[$m] // (to_entries | map(select(.key | ascii_downcase == ($m|ascii_downcase))) | .[0].value) // null)' <<<"$prices")
  local input_p output_p
  input_p=$(jq -r 'if . == null then "" else (.input // "") end' <<<"$price")
  output_p=$(jq -r 'if . == null then "" else (.output // "") end' <<<"$price")
  if [[ -z $input_p || -z $output_p ]]; then return 1; fi
  awk -v it="$in_tok" -v ot="$out_tok" -v ip="$input_p" -v op="$output_p" -v tf="$turns" \
    'BEGIN{printf "%.6f", ((it*ip + ot*op)/1000000) * tf}'
}

# harness_estimate_usd PROFILE PACKET(file-or-text) -> USD, chain-aware
# (harness_cost_class), for the harness dispatch path.
harness_estimate_usd() {
  local profile=$1 packet=$2 class model
  class=$(harness_cost_class "$profile")
  model=$(profile_get "$profile" model 2>/dev/null)
  harness_estimate_from_class "$class" "$model" "$packet"
}

# harness_gate BACKEND MODEL TEXT-OR-FILE APPROVED_USD
# stdout: the USD estimate ("0" for free/subscription, "unknown" when a
# metered model's price cannot be found). exit: 0 = clear to proceed, 3 =
# refused (unmet approval, or unknown price) -- for cmd_delegate and other
# direct (non-harness-dispatch) entry points, backend-only (no fallback chain
# to check yet: the profile does not exist until after this gate clears).
harness_gate() {
  local backend=$1 model=$2 packet=$3 approved=${4:-0}
  local class; class=$(harness_backend_cost_class "$backend")
  local estimate
  if ! estimate=$(harness_estimate_from_class "$class" "$model" "$packet"); then
    printf 'unknown'; return 3
  fi
  printf '%s' "$estimate"
  [[ $class == free || $class == subscription ]] && return 0
  awk -v a="$approved" -v e="$estimate" 'BEGIN{exit !(a+0 >= e+0)}' && return 0
  return 3
}

# harness_gate_profile PROFILE TEXT [--interactive] -- for an already-saved
# profile (Rix itself): 0 = proceed, 3 = refused. With --interactive and a
# tty, offers a y/N confirm instead of a hard refusal (rix chat); rix ask
# never prompts.
harness_gate_profile() {
  local profile=$1 text=$2 interactive=0
  [[ ${3:-} == --interactive ]] && interactive=1
  local class; class=$(harness_cost_class "$profile")
  [[ $class == metered ]] || return 0
  local estimate
  if ! estimate=$(harness_estimate_usd "$profile" "$text"); then
    warn "harness: $profile is on a metered backend with no known price for $(profile_get "$profile" model); refusing to start"
    return 3
  fi
  local approved; approved=$(opt_value --approved-usd 2>/dev/null || echo 0)
  if awk -v a="$approved" -v e="$estimate" 'BEGIN{exit !(a+0 >= e+0)}'; then return 0; fi
  if (( interactive )) && [[ -t 0 && -t 1 ]] && have gum; then
    confirm "$profile runs on a metered backend (~\$$estimate estimate). Continue?" && return 0
    return 3
  fi
  warn "harness: $profile would cost about \$$estimate on a metered backend. Pass --approved-usd $estimate to proceed (or answer the prompt in an interactive chat)."
  return 3
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

# Remove one node's requested.txt dedup entry (it is no longer pending).
harness_prune_requested_key() {
  local project=$1 node=$2 reqf="$HARNESS_STATE_DIR/requested.txt"
  [[ -f $reqf ]] || return 0
  local tmp; tmp=$(mktemp "$HARNESS_STATE_DIR/.requested.XXXXXX")
  grep -vxF "$project:$node" "$reqf" >"$tmp" 2>/dev/null || true
  mv -f "$tmp" "$reqf"
}

# Drop every requested.txt entry for a whole project (approve/decline resolve
# every open request on that project at once).
harness_prune_requested_project() {
  local project=$1 reqf="$HARNESS_STATE_DIR/requested.txt"
  [[ -f $reqf ]] || return 0
  local tmp; tmp=$(mktemp "$HARNESS_STATE_DIR/.requested.XXXXXX")
  grep -v "^$project:" "$reqf" >"$tmp" 2>/dev/null || true
  mv -f "$tmp" "$reqf"
}

# Drop any requested.txt entry whose project no longer lists it as pending
# (the harness's own pending list is the source of truth). Best-effort: a
# harness CLI that has no `cost --project ID --json` pending field is a no-op.
harness_prune_requested_stale() {
  local reqf="$HARNESS_STATE_DIR/requested.txt"
  [[ -s $reqf ]] || return 0
  local bin; bin=$(harness_bin 2>/dev/null) || return 0
  local tmp; tmp=$(mktemp "$HARNESS_STATE_DIR/.requested.XXXXXX")
  local -A pending_cache=()
  local line proj node
  while IFS=: read -r proj node; do
    [[ -n $proj && -n $node ]] || continue
    if [[ -z ${pending_cache[$proj]+x} ]]; then
      pending_cache[$proj]=,$("$bin" cost --project "$proj" --json 2>/dev/null | jq -r '[.pending[]?.node // empty] | join(",")' 2>/dev/null),
    fi
    [[ ${pending_cache[$proj]} == *",$node,"* ]] && printf '%s:%s\n' "$proj" "$node" >>"$tmp"
  done <"$reqf"
  mv -f "$tmp" "$reqf"
}

# The oldest open request on PROJECT (optionally matching USD) via
# `harness cost --project ID --json`'s "pending" list -- the dashboard's
# Approve button does not know the request id either.
harness_resolve_request_id() { # PROJECT [USD]
  local project=$1 usd=${2:-} bin
  bin=$(harness_bin 2>/dev/null) || { printf ''; return 0; }
  local pending; pending=$("$bin" cost --project "$project" --json 2>/dev/null | jq -c '.pending // []' 2>/dev/null)
  [[ -n $pending ]] || pending='[]'
  if [[ -n $usd ]]; then
    jq -r --argjson usd "$usd" '[.[] | select((.estimate_usd // .usd // -1) == $usd)] | sort_by(.at // .requested_at // "") | .[0].id // empty' <<<"$pending" 2>/dev/null
  else
    jq -r 'sort_by(.at // .requested_at // "") | .[0].id // empty' <<<"$pending" 2>/dev/null
  fi
}

# harness_approve PROJECT USD [REASON] [REQUEST_ID] -- only a human runs this
# (refused outright when OAL_AGENT is set: an agent context). Prefers the
# harness CLI itself (it enforces the same agent-context refusal, and is the
# source of truth for the request id); curl is only a fallback, and always
# carries BOTH `X-Harness: 1` and `X-Harness-Approver: human` plus
# {request_id, usd, reason, by:"human"} in the body.
harness_approve() {
  local project=$1 usd=$2 reason=${3:-approved} request=${4:-}
  [[ -n $project && -n $usd ]] || fail "harness approve: needs PROJECT and USD"
  [[ -z ${OAL_AGENT:-} ]] || fail "harness approve: agents cannot approve spending; ask the user to run this"
  [[ -n $request ]] || request=$(harness_resolve_request_id "$project" "$usd")
  local bin; bin=$(harness_bin 2>/dev/null) || bin=""
  local rc=0 out=""
  if [[ -n $bin ]]; then
    if (( OAL_DRY_RUN )); then say "[dry-run] would: $bin approve --project $project --request ${request:-<none>} --usd $usd"; return 0; fi
    out=$("$bin" approve --project "$project" --request "${request:-}" --usd "$usd") || rc=$?
  else
    local body; body=$(jq -nc --arg rid "${request:-}" --argjson usd "$usd" --arg reason "$reason" \
      '{request_id:$rid, usd:$usd, reason:$reason, by:"human"}')
    if (( OAL_DRY_RUN )); then say "[dry-run] would POST $(harness_url)/api/project/$project/approve $body"; return 0; fi
    out=$(curl -sS -m 5 -H 'X-Harness: 1' -H 'X-Harness-Approver: human' -H 'Content-Type: application/json' \
      -X POST -d "$body" "$(harness_url)/api/project/$project/approve") || rc=$?
  fi
  harness_prune_requested_project "$project"
  printf '%s' "$out"
  return "$rc"
}

# harness_decline PROJECT [REQUEST_ID] -- same human-only rule and CLI-first,
# curl-fallback shape as harness_approve.
harness_decline() {
  local project=$1 request=${2:-}
  [[ -n $project ]] || fail "harness decline: needs PROJECT"
  [[ -z ${OAL_AGENT:-} ]] || fail "harness decline: agents cannot decline spending; ask the user to run this"
  [[ -n $request ]] || request=$(harness_resolve_request_id "$project")
  local bin; bin=$(harness_bin 2>/dev/null) || bin=""
  local rc=0 out=""
  if [[ -n $bin ]]; then
    if (( OAL_DRY_RUN )); then say "[dry-run] would: $bin decline --project $project --request ${request:-<none>}"; return 0; fi
    out=$("$bin" decline --project "$project" --request "${request:-}") || rc=$?
  else
    local body; body=$(jq -nc --arg rid "${request:-}" '{request_id:$rid, by:"human"}')
    if (( OAL_DRY_RUN )); then say "[dry-run] would POST $(harness_url)/api/project/$project/cost/decline $body"; return 0; fi
    out=$(curl -sS -m 5 -H 'X-Harness: 1' -H 'X-Harness-Approver: human' -H 'Content-Type: application/json' \
      -X POST -d "$body" "$(harness_url)/api/project/$project/cost/decline") || rc=$?
  fi
  harness_prune_requested_project "$project"
  printf '%s' "$out"
  return "$rc"
}

# --------------------------------------------------------------- dispatch ----
# One packet: cost-gate, claim, launch a DETACHED delegate (no --wait), write
# a job file for the reaper. Never blocks: harness_dispatch_reap writes the
# receipt once the worker actually finishes. Respects $HARNESS_SLOTS_LEFT
# (set by harness_dispatch_once) so at most settings.json:harness_workers run
# at once across the whole sweep.
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
  local class; class=$(harness_cost_class "$profile" 2>/dev/null)
  case "$class" in
    free|subscription|metered) ;;
    *) event_emit "$profile" note "harness: cost class for $profile is unresolvable; refusing $node" --source harness --level warn --ref "$ref:unresolvable"; return 0 ;;
  esac
  local estimate="0"
  if [[ $class == metered ]]; then
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
    harness_prune_requested_key "$proj" "$node"   # was requested, now funded: stop dedup-blocking a future shortfall
  fi
  if (( ${HARNESS_SLOTS_LEFT:-1} <= 0 )); then return 0; fi   # concurrency cap for this sweep; retried next sweep
  if (( OAL_DRY_RUN )); then
    say "[dry-run] would claim $path and delegate $node ($profile on $backend)"
    return 0
  fi
  local claimed="${path}.claimed"
  mv -f "$path" "$claimed" 2>/dev/null || return 0
  local name="hns-$node"
  local content trailer
  content=$(cat "$claimed" 2>/dev/null)
  trailer=$'\n\nWhen finished, print the oracle command output; do not edit files outside touches.'
  local -a saved_opts=("${OPTS[@]}")
  OPTS=(--backend "$backend" --name "$name" --task-title "$node" --model "$model" --job-stdin)
  [[ $class == metered ]] && OPTS+=(--approved-usd "$estimate")   # the harness already approved this budget
  printf '%s%s\n' "$content" "$trailer" | cmd_delegate >/dev/null 2>&1
  local drc=$?
  OPTS=("${saved_opts[@]}")
  if (( drc != 0 )); then
    warn "harness: delegate refused to start $node (exit $drc)"
    mv -f "$claimed" "$path" 2>/dev/null || true   # un-claim so a future sweep can retry
    event_emit "$profile" note "harness: $node did not start (delegate exit $drc)" --source harness --level warn --ref "$ref:failed"
    return 0
  fi
  mkdir -p "$HARNESS_JOBS_DIR/$proj"
  jq -n --arg project "$proj" --arg node "$node" --arg session "$sid" --arg profile "$profile" \
        --arg name "$name" --arg backend "$backend" --arg model "$model" --arg bin "$bin" \
        --argjson started "$(date +%s)" \
        '{project:$project, node:$node, session:$session, profile:$profile, name:$name, backend:$backend, model:$model, bin:$bin, started_at:$started}' \
    >"$HARNESS_JOBS_DIR/$proj/$node.json"
  HARNESS_SLOTS_LEFT=$(( ${HARNESS_SLOTS_LEFT:-1} - 1 ))
  event_emit "$profile" note "harness: started $node ($name)" --source harness --ref "$ref:start"
}

# Reap finished detached jobs: a job is "finished" once its worker's run log
# is newer than when we started it (session_run_once always writes one for
# an unattended run, whether or not its window/tmux session stays open
# afterward). rc-first: only a nonzero exit AND a structured marker in the
# last 20 lines of the log counts as throttled.
harness_dispatch_reap() {
  [[ -d $HARNESS_JOBS_DIR ]] || return 0
  local jf
  while IFS= read -r -d '' jf; do
    local job proj node sid profile name backend model bin started
    job=$(cat "$jf" 2>/dev/null) || { rm -f "$jf"; continue; }
    proj=$(jq -r '.project // empty' <<<"$job"); node=$(jq -r '.node // empty' <<<"$job")
    sid=$(jq -r '.session // empty' <<<"$job"); profile=$(jq -r '.profile // empty' <<<"$job")
    name=$(jq -r '.name // empty' <<<"$job"); backend=$(jq -r '.backend // empty' <<<"$job")
    model=$(jq -r '.model // empty' <<<"$job"); bin=$(jq -r '.bin // empty' <<<"$job")
    started=$(jq -r '.started_at // 0' <<<"$job")
    [[ -n $proj && -n $node && -n $name && -n $bin ]] || { rm -f "$jf"; continue; }
    local dir latest
    dir="$(stage_dir "$name")/runs"
    latest=$(ls -1t "$dir"/*.log 2>/dev/null | head -n1)
    if [[ -z $latest ]]; then continue; fi   # still running
    local mt; mt=$(stat -c %Y "$latest" 2>/dev/null || echo 0)
    (( mt < started )) && continue           # still running (log predates this job)

    local out; out=$(LC_ALL=C sed -E 's/\x1B\[[0-9;?]*[ -\/]*[@-~]//g; s/\r$//' "$latest" 2>/dev/null)
    local code; code=$(events_recent 400 | jq -r --arg n "$name" '[.[] | select(.agent == $n and .kind == "session_exited")] | last | .code // 0' 2>/dev/null)
    [[ $code =~ ^-?[0-9]+$ ]] || code=0
    local status
    if (( code != 0 )) && grep -qiE '429|rate.?limit|usage limit' <<<"$(tail -n 20 <<<"$out")"; then status="throttled"
    elif (( code == 0 )); then status="done"
    else status="failed"
    fi
    local evidence; evidence=$(tail -n 40 <<<"$out")
    local usage_row usd_actual tok_in tok_out
    usage_row=$(declare -F usage_json >/dev/null && usage_json | jq -c --arg n "$name" '.agents[]? | select(.name == $n)' 2>/dev/null)
    usd_actual=$(jq -r '.cost_usd // empty' <<<"$usage_row" 2>/dev/null)
    tok_in=$(jq -r '.prompt // empty' <<<"$usage_row" 2>/dev/null)
    tok_out=$(jq -r '.output // empty' <<<"$usage_row" 2>/dev/null)
    local -a rargs=(receipt --project "$proj" --session "$sid" --node "$node" --status "$status" --evidence "$evidence" --model "$model" --vendor "$backend")
    [[ -n $usd_actual && $usd_actual != null ]] && rargs+=(--usd "$usd_actual")
    [[ -n $tok_in && $tok_in != null ]] && rargs+=(--tokens-in "$tok_in")
    [[ -n $tok_out && $tok_out != null ]] && rargs+=(--tokens-out "$tok_out")
    "$bin" "${rargs[@]}" >/dev/null 2>&1 || warn "harness receipt failed for $node ($status)"
    harness_prune_requested_key "$proj" "$node"
    event_emit "$profile" note "harness: $node $status" --source harness --ref "harness:$proj:$node:$status"
    rm -f "$jf"
  done < <(find "$HARNESS_JOBS_DIR" -mindepth 2 -maxdepth 2 -name '*.json' -print0 2>/dev/null)
}

harness_jobs_running() { find "$HARNESS_JOBS_DIR" -mindepth 2 -maxdepth 2 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

# One sweep: reap finished jobs, then launch up to settings.json:harness_workers
# (default 4) new detached delegates, one per unclaimed packet, across every
# rix session in overview.json whose label is (or is one --slots worker of) a
# saved profile.
harness_dispatch_once() {
  local bin; bin=$(harness_bin) || return 1
  harness_dispatch_reap
  harness_prune_requested_stale
  local slots; slots=$(settings_get harness_workers 4); [[ $slots =~ ^[0-9]+$ ]] || slots=4
  local active; active=$(harness_jobs_running)
  HARNESS_SLOTS_LEFT=$(( slots - active )); (( HARNESS_SLOTS_LEFT < 0 )) && HARNESS_SLOTS_LEFT=0
  (( HARNESS_SLOTS_LEFT <= 0 )) && return 0
  local overview; overview=$(harness_overview_json)
  local sess
  while IFS= read -r sess; do
    [[ -n $sess ]] || continue
    (( HARNESS_SLOTS_LEFT <= 0 )) && break
    local proj sid label profile
    proj=$(jq -r '.project // empty' <<<"$sess")
    sid=$(jq -r '.id // empty' <<<"$sess")
    label=$(jq -r '.label // empty' <<<"$sess")
    [[ -n $proj && -n $sid && -n $label ]] || continue
    profile=$(harness_profile_for_label "$label") || continue
    local inbox; inbox=$("$bin" inbox --project "$proj" --session "$sid" --json 2>/dev/null)
    [[ $inbox == \[* ]] || inbox='[]'
    local pkt
    while IFS= read -r pkt; do
      [[ -n $pkt ]] || continue
      (( HARNESS_SLOTS_LEFT <= 0 )) && break
      harness_dispatch_packet "$bin" "$proj" "$sid" "$profile" "$pkt"
    done < <(jq -c '.[]?' <<<"$inbox")
  done < <(jq -c '.sessions[]? | select(.worker == "rix")' <<<"$overview")
}

# Every 3s until killed (started by harness_serve_start as its own process).
harness_dispatch_loop() {
  trap 'exit 0' TERM INT
  while :; do
    harness_dispatch_once || true
    harness_notify_sync || true
    sleep 3
  done
}

# ----------------------------------------------------------------- status ----
# File/pid based only: serve.pid liveness first, overview.json's mtime
# (<15s old) as a fallback, the pid files under $OAL_STATE/harness/, and the
# detached job/slot count. Never curl.
harness_status_json() {
  local bin; bin=$(harness_bin 2>/dev/null) || bin=""
  local url ddir; url=$(harness_url); ddir=$(harness_data_dir)
  local ov="$ddir/overview.json" alive=false
  local serving_pid=null dispatch_pid=null
  if harness_pid_alive "$HARNESS_STATE_DIR/serve.pid"; then
    alive=true
    serving_pid=$(cat "$HARNESS_STATE_DIR/serve.pid")
  elif [[ -f $ov ]]; then
    local mtime now; mtime=$(stat -c %Y "$ov" 2>/dev/null || echo 0); now=$(date +%s)
    (( now - mtime < 15 )) && alive=true
  fi
  harness_pid_alive "$HARNESS_STATE_DIR/dispatch.pid" && dispatch_pid=$(cat "$HARNESS_STATE_DIR/dispatch.pid")
  local overview; overview=$(harness_overview_json)
  local projects; projects=$(jq '.projects? | length // 0' <<<"$overview" 2>/dev/null); [[ $projects =~ ^[0-9]+$ ]] || projects=0
  local pending; pending=$(jq -c '[.projects[]? | select(.pending_approval != null) | {id, pending_approval}]' <<<"$overview" 2>/dev/null)
  [[ $pending == \[* ]] || pending='[]'
  local slots running; slots=$(settings_get harness_workers 4); [[ $slots =~ ^[0-9]+$ ]] || slots=4
  running=$(harness_jobs_running)
  jq -nc --argjson alive "$alive" --arg url "$url" --arg data_dir "$ddir" --arg bin "$bin" \
    --argjson serving_pid "${serving_pid:-null}" --argjson dispatch_pid "${dispatch_pid:-null}" \
    --argjson projects "$projects" --argjson pending_approvals "$pending" \
    --argjson jobs_running "$running" --argjson jobs_slots "$slots" \
    '{alive:$alive, url:$url, data_dir:$data_dir, bin:$bin, serving_pid:$serving_pid, dispatch_pid:$dispatch_pid,
      projects:$projects, pending_approvals:$pending_approvals, jobs:{running:$jobs_running, slots:$jobs_slots}}'
}

# harness_pending_approvals_json -> [{project, estimate_usd, model, vendor,
# reason, at}] from overview.json's per-project pending_approval. File only.
harness_pending_approvals_json() {
  jq -c '[.projects[]? | select(.pending_approval != null) | {
    project: .id,
    estimate_usd: (.pending_approval.estimate_usd // .pending_approval.usd // null),
    model: (.pending_approval.model // null),
    vendor: (.pending_approval.vendor // null),
    reason: (.pending_approval.reason // ""),
    at: (.pending_approval.at // .pending_approval.requested_at // null)
  }]' <<<"$(harness_overview_json)"
}

# --------------------------------------------------------------- notify ----
# harness_notify_sync -- read overview.json once and make two things
# impossible to miss without any network:
#  * every project with a pending_approval becomes exactly one blocker
#    (key "approval-<project>", agent = its rix session's profile label, or
#    "rix"), resolved the moment the approval disappears (or its identity
#    changes, tracked by `at`/`requested_at`/the estimate itself).
#  * every session in state "throttled" gets one warn-level note per
#    retry_at (never re-toasted for the same retry_at).
# Dedup state lives in $HARNESS_STATE_DIR/notified.txt, not blockers.json --
# the user can Resolve a blocker from the dashboard at any time, and keying
# off blockers.json would just re-emit (and re-toast) it on the next sweep.
# Safe to call every dispatch cycle and from `cmd_harness status`.
harness_notify_sync() {
  mkdir -p "$HARNESS_STATE_DIR"
  local nf="$HARNESS_STATE_DIR/notified.txt"
  touch "$nf"
  local tab; tab=$'\t'
  local overview; overview=$(harness_overview_json)
  local tmp; tmp=$(mktemp "$HARNESS_STATE_DIR/.notified.XXXXXX")

  local proj
  while IFS= read -r proj; do
    [[ -n $proj ]] || continue
    local id pa line
    id=$(jq -r '.id // empty' <<<"$proj")
    [[ -n $id ]] || continue
    pa=$(jq -c '.pending_approval // empty' <<<"$proj")
    line=$(grep -F "approval${tab}${id}${tab}" "$nf" 2>/dev/null | head -n1 || true)
    if [[ -n $pa && $pa != null ]]; then
      local at
      at=$(jq -r '.at // .requested_at // .estimate_usd // .usd // empty' <<<"$pa")
      [[ -n $at ]] || at="pending"
      if [[ -n $line ]] && [[ $(cut -f3 <<<"$line") == "$at" ]]; then
        printf '%s\n' "$line" >>"$tmp"
      else
        local agent estimate model vendor reason
        agent=$(jq -r --arg id "$id" '.sessions[]? | select(.project == $id and .worker == "rix") | .label' <<<"$overview" | head -n1)
        [[ -n $agent ]] || agent=rix
        estimate=$(jq -r '.estimate_usd // .usd // "?"' <<<"$pa")
        model=$(jq -r '.model // "?"' <<<"$pa")
        vendor=$(jq -r '.vendor // "?"' <<<"$pa")
        reason=$(jq -r '.reason // ""' <<<"$pa")
        event_emit "$agent" blocker "Approve \$$estimate for $model via $vendor on $id: $reason" \
          --source harness --level blocker --ref "harness:$id:approval:$at" --key "approval-$id"
        printf 'approval%s%s%s%s%s%s\n' "$tab" "$id" "$tab" "$at" "$tab" "$agent" >>"$tmp"
      fi
    elif [[ -n $line ]]; then
      local cleared_agent; cleared_agent=$(cut -f4 <<<"$line")
      [[ -n $cleared_agent ]] || cleared_agent=rix
      event_emit "$cleared_agent" blocker_cleared "harness: approval on $id resolved" --source harness --key "approval-$id"
    fi
  done < <(jq -c '.projects[]?' <<<"$overview")

  local sess
  while IFS= read -r sess; do
    [[ -n $sess ]] || continue
    local sid label retry line
    sid=$(jq -r '.id // empty' <<<"$sess")
    [[ -n $sid ]] || continue
    label=$(jq -r '.label // empty' <<<"$sess"); [[ -n $label ]] || label=rix
    retry=$(jq -r '.retry_at // empty' <<<"$sess"); [[ -n $retry ]] || retry="unknown"
    line=$(grep -F "throttled${tab}${sid}${tab}" "$nf" 2>/dev/null | head -n1 || true)
    if [[ -n $line ]] && [[ $(cut -f3 <<<"$line") == "$retry" ]]; then
      printf '%s\n' "$line" >>"$tmp"
    else
      event_emit "$label" note "harness: $sid throttled, retrying at $retry" --source harness --level warn --ref "harness:$sid:throttled:$retry"
      printf 'throttled%s%s%s%s\n' "$tab" "$sid" "$tab" "$retry" >>"$tmp"
    fi
  done < <(jq -c '.sessions[]? | select(.state == "throttled")' <<<"$overview")

  mv -f "$tmp" "$nf"
  return 0
}
