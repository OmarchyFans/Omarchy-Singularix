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
# Resolution: settings.json `harness_bin` (a path, or the word `none` = there is no harness,
# never fall back) -> $OAL_HARNESS_BIN (same two forms; tests/run.sh sets `none` so a
# best-effort hook such as harness_resync_profile can never reach the real CLI and the
# user's live ~/.session-harness -- which it did, relabelling live sessions, on 2026-09-14)
# -> `harness` on PATH -> the dev checkout.
harness_bin() {
  local b; b=$(settings_get harness_bin "")
  if [[ $b == none ]]; then return 1; fi
  if [[ -n $b && -x $b ]]; then printf '%s' "$b"; return 0; fi
  if [[ -n ${OAL_HARNESS_BIN:-} ]]; then
    [[ $OAL_HARNESS_BIN == none ]] && return 1
    [[ -x $OAL_HARNESS_BIN ]] && { printf '%s' "$OAL_HARNESS_BIN"; return 0; }
  fi
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

# harness_session_registered PROJECT LABEL -> 0 when overview.json already lists a rix
# session with that label on that project.
harness_session_registered() {
  local p=$1 l=$2 bin rows
  # Ask the harness itself when it is installed: overview.json is only refreshed while
  # `harness serve` runs, so right after `harness demo --fresh` (or any edit made while serve
  # was stopped) it still lists sessions that no longer exist -- register then skipped the
  # add and the resync failed with "unknown session" (seen live 2026-09-15).
  if bin=$(harness_bin 2>/dev/null) && rows=$("$bin" --json sessions 2>/dev/null) && [[ -n $rows ]]; then
    jq -e --arg p "$p" --arg l "$l" '.[]? | select(.project == $p and .worker == "rix" and .label == $l)' <<<"$rows" >/dev/null 2>&1
    return
  fi
  jq -e --arg p "$p" --arg l "$l" '.sessions[]? | select(.project == $p and .worker == "rix" and .label == $l)' \
    <<<"$(harness_overview_json)" >/dev/null 2>&1
}

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

# The vendor id the harness should record for a profile (policy.py's
# `Config.vendor_ip_safe`/router keys clients by (vendor, model)): the
# profile's own `provider` for a `kind=provider` backend (anthropic, xai,
# local, ...) or the registry backend's own id for a `kind=endpoint` backend
# (backend_get stamps provider:"endpoint" on those, which is not a real
# vendor id -- the backend's own id is). harness_profile_vendor PROFILE
harness_profile_vendor() {
  local profile=$1 backend
  backend=$(profile_get "$profile" backend 2>/dev/null)
  [[ -n $backend ]] || backend=$(profile_get "$profile" provider 2>/dev/null)
  [[ -n $backend ]] || { printf ''; return 0; }
  local b; b=$(backend_get "$backend" 2>/dev/null)
  if [[ -n $b ]]; then
    local kind; kind=$(jq -r '.kind // "provider"' <<<"$b")
    if [[ $kind == provider ]]; then
      local p; p=$(jq -r '.provider // empty' <<<"$b")
      printf '%s' "${p:-$backend}"
      return 0
    fi
  fi
  printf '%s' "$backend"   # endpoint/registry backend: its own id is the vendor
}

# The model the harness should record for a profile: the profile's own
# `model` field, else the model its resolved backend actually serves.
# harness_profile_model PROFILE
harness_profile_model() {
  local profile=$1 model
  model=$(profile_get "$profile" model 2>/dev/null)
  if [[ -z $model ]]; then
    local backend; backend=$(profile_get "$profile" backend 2>/dev/null)
    [[ -n $backend ]] || backend=$(profile_get "$profile" provider 2>/dev/null)
    local b; b=$(backend_get "$backend" 2>/dev/null)
    [[ -n $b ]] && model=$(jq -r '.model // empty' <<<"$b")
  fi
  printf '%s' "$model"
}

# harness_register_rix PROFILE [REPO] [SLOTS] [PROJECT_ID] [ROLE] -- one
# `harness session add` per project whose repo_path resolves (realpath) to
# REPO (default: $PWD), per slot 1..SLOTS (default 1): SLOTS>1 registers
# "<profile>-1".."<profile>-N" so one launcher profile can be N parallel
# harness workers. When PROJECT_ID is given, the repo_path lookup is skipped
# entirely and that one project id is registered against directly (REPO is
# still used as --cwd, defaulting to $PWD) -- for harness builds/projects
# whose overview.json doesn't carry repo_path yet, or a repo living outside
# any project's declared path. ROLE (orchestrator|reasoning|coding|local)
# defaults to the profile's `harness_role` field, else "coding" -- the
# harness derives tier/ip_safe from --role/--model/--vendor; it refuses (and
# we surface its stderr) a non-IP-safe vendor registering as orchestrator,
# since it owns the IP table, not us.
harness_register_rix() {
  local profile=$1 repo=${2:-} slots=${3:-1} project_id=${4:-} role=${5:-}
  [[ $slots =~ ^[0-9]+$ && $slots -ge 1 ]] || slots=1
  profile_exists "$profile" || fail "harness register: no saved agent named '$profile'"
  [[ -n $role ]] || role=$(profile_get "$profile" harness_role 2>/dev/null)
  [[ -n $role ]] || role=coding
  local bin; bin=$(harness_bin) || return 1
  # With --project and no repo given, the session's cwd is that project's repo (the
  # inbox/outbox live there) -- never the shell's cwd.
  if [[ -n $project_id && -z $repo ]]; then
    repo=$("$bin" --json ls 2>/dev/null | jq -r --arg id "$project_id" '.[]? | select(.id == $id) | .repo_path // empty' 2>/dev/null | head -n1)
    [[ -n $repo ]] || fail "harness register: project '$project_id' not found (harness ls)"
  fi
  [[ -n $repo ]] || repo=$PWD
  local backend; backend=$(profile_get "$profile" backend 2>/dev/null)
  [[ -n $backend ]] || backend=$(profile_get "$profile" provider 2>/dev/null)
  local class; class=$(harness_cost_class "$profile")
  local vendor; vendor=$(harness_profile_vendor "$profile")
  local model; model=$(harness_profile_model "$profile")
  local chain; chain=$(profile_get "$profile" fallback_chain 2>/dev/null)
  if [[ -n $chain ]]; then
    local hop; hop=$(harness_chain_metered_hop "$chain")
    [[ -n $hop ]] && warn "harness register: $profile's fallback chain '$chain' can hop to $hop (api-key) -- registering as metered"
  fi
  local -a projects=()
  if [[ -n $project_id ]]; then
    projects=("$project_id")
  else
    local repo_abs; repo_abs=$(realpath -m "$repo" 2>/dev/null || printf '%s' "$repo")
    local id path path_abs
    while IFS=$'\t' read -r id path; do
      [[ -n $id ]] || continue
      path_abs=$(realpath -m "$path" 2>/dev/null || printf '%s' "$path")
      [[ $path_abs == "$repo_abs" ]] && projects+=("$id")
    done < <(jq -r '.projects[]? | select(.repo_path) | [.id, .repo_path] | @tsv' <<<"$(harness_overview_json)")
    if (( ${#projects[@]} == 0 )); then
      warn "harness register: no project in overview.json has repo_path $repo (pass --project ID to register directly)"
      return 1
    fi
  fi
  local p s label rc=0
  for p in "${projects[@]}"; do
    for (( s = 1; s <= slots; s++ )); do
      label=$profile; (( slots > 1 )) && label="$profile-$s"
      # Already registered for this project (overview.json is the harness's own view):
      # skip the add -- `session add` would mint a fresh id like "<label>-2" -- and let the
      # resync below bring the existing session's role/model/vendor/cost class up to date.
      if harness_session_registered "$p" "$label"; then
        info "harness register: $label already registered on $p (resyncing, not adding)"
        continue
      fi
      if (( OAL_DRY_RUN )); then
        say "[dry-run] would: $bin session add --project $p --worker rix --label $label --cwd $repo --cost-class $class --backend $backend --role $role --model $model --vendor $vendor"
      else
        local sess_err
        if ! sess_err=$("$bin" session add --project "$p" --worker rix --label "$label" --cwd "$repo" --cost-class "$class" --backend "$backend" \
              --role "$role" --model "$model" --vendor "$vendor" 2>&1 >/dev/null); then
          # The harness owns the IP table (policy.py): it, not this script, refuses an
          # IP-unsafe vendor registering as orchestrator -- surface its stderr as-is
          # rather than pre-judging the vendor list here.
          warn "harness session add failed for project $p ($label): ${sess_err:-no output}"
          rc=1
        fi
      fi
    done
  done
  # Best-effort resync (#7): if a session for this profile was already
  # registered (a `session add` above failed because it exists, or the
  # harness treated it as a no-op update), make sure its model/vendor/
  # cost-class still reflect the profile's CURRENT backend -- register is the
  # natural point to catch a profile whose backend changed since it first
  # became a harness worker.
  (( OAL_DRY_RUN )) || harness_resync_profile "$profile" || true
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

# harness_session_sync PROFILE PROJECT SESSION [ROLE] -- one `harness session
# set` call carrying --model/--vendor/--cost-class (always) and, when ROLE is
# given, --role ROLE --tier ROLE TOGETHER (never --role alone: the harness's
# `validate_role` refuses a session whose (possibly stale, previously
# recorded) tier ends up below or above the role it's being set to unless the
# tier is given explicitly in the same call -- #7/#8 in the adversarial
# review). Shared by `harness_set_role`, `harness_resync_profile`, and
# `harness_register_rix` (resyncing a session that already exists).
harness_session_sync() {
  local profile=$1 proj=$2 sid=$3 role=${4:-}
  local bin; bin=$(harness_bin 2>/dev/null) || return 1
  local model vendor class
  model=$(harness_profile_model "$profile"); vendor=$(harness_profile_vendor "$profile")
  class=$(harness_cost_class "$profile" 2>/dev/null)
  if (( OAL_DRY_RUN )); then
    say "[dry-run] would: $bin session set --project $proj --session $sid${role:+ --role $role --tier $role} --model $model --vendor $vendor --cost-class $class"
    return 0
  fi
  local -a args=(session set --project "$proj" --session "$sid")
  [[ -n $role ]] && args+=(--role "$role" --tier "$role")
  args+=(--model "$model" --vendor "$vendor")
  [[ -n $class ]] && args+=(--cost-class "$class")
  local sess_err
  if ! sess_err=$("$bin" "${args[@]}" 2>&1 >/dev/null); then
    warn "harness session set failed for $profile (session $sid, project $proj): ${sess_err:-no output}"
    return 1
  fi
  return 0
}

# harness_resync_profile PROFILE -- best-effort: for every already-registered
# live harness session resolving back to PROFILE, re-push its model/vendor/
# cost-class (no role change) via `harness_session_sync`. Call this wherever a
# profile's backend/provider/model changes after it may already be a
# registered harness worker, so the harness's own record of what it's talking
# to never goes stale (#7 in the adversarial review). Never fails the caller.
harness_resync_profile() {
  local profile=$1
  profile_exists "$profile" || return 0
  declare -F harness_bin >/dev/null || return 0
  local bin; bin=$(harness_bin 2>/dev/null) || return 0
  local sess
  while IFS= read -r sess; do
    [[ -n $sess ]] || continue
    local proj sid label resolved
    proj=$(jq -r '.project // empty' <<<"$sess"); sid=$(jq -r '.id // empty' <<<"$sess"); label=$(jq -r '.label // empty' <<<"$sess")
    [[ -n $proj && -n $sid && -n $label ]] || continue
    resolved=$(harness_profile_for_label "$label") || continue
    [[ $resolved == "$profile" ]] || continue
    harness_session_sync "$profile" "$proj" "$sid" || true
  done < <(harness_rix_sessions_json "$bin")
  return 0
}

# harness_rix_sessions_json BIN -> one JSON object per registered rix session (project, id,
# label, ...): the harness CLI's own list when it answers (overview.json is only refreshed
# while serve runs and listed sessions that no longer existed right after `demo --fresh`),
# else overview.json's sessions[].
harness_rix_sessions_json() {
  local bin=$1 rows
  if [[ -n $bin ]] && rows=$("$bin" --json sessions 2>/dev/null) && [[ $rows == \[* ]]; then
    jq -c '.[]? | select(.worker == "rix")' <<<"$rows"
    return 0
  fi
  jq -c '.sessions[]? | select(.worker == "rix")' <<<"$(harness_overview_json)"
}

# harness_set_role PROFILE ROLE -- sets the profile's `harness_role` field
# and, for every already-registered harness session whose label resolves
# back to this profile (overview.json, worker=rix), runs `harness session
# set --role ROLE --tier ROLE` (paired, see harness_session_sync) so a live
# registration picks the new role up immediately (rather than only the next
# `harness register`). The profile field is persisted only once every live
# session accepted the new role (or there were none to update) -- on a
# partial failure the profile keeps its old `harness_role` rather than
# claiming a role the harness never actually applied to a live session.
harness_set_role() {
  local profile=$1 role=$2
  profile_exists "$profile" || fail "harness role: no saved agent named '$profile'"
  case "$role" in orchestrator|reasoning|coding|local) ;; *) fail "harness role: must be orchestrator, reasoning, coding, or local" ;; esac
  local bin; bin=$(harness_bin 2>/dev/null) || { profile_set "$profile" harness_role "$(jq -Rn --arg v "$role" '$v')"; say "set $profile's harness role to $role (no harness CLI found to update live sessions)"; return 0; }
  local rc=0 sess
  while IFS= read -r sess; do
    [[ -n $sess ]] || continue
    local proj sid label resolved
    proj=$(jq -r '.project // empty' <<<"$sess"); sid=$(jq -r '.id // empty' <<<"$sess"); label=$(jq -r '.label // empty' <<<"$sess")
    [[ -n $proj && -n $sid && -n $label ]] || continue
    resolved=$(harness_profile_for_label "$label") || continue
    [[ $resolved == "$profile" ]] || continue
    harness_session_sync "$profile" "$proj" "$sid" "$role" || rc=1
  done < <(jq -c '.sessions[]? | select(.worker == "rix")' <<<"$(harness_overview_json)")
  if (( rc == 0 )); then
    profile_set "$profile" harness_role "$(jq -Rn --arg v "$role" '$v')"
    say "set $profile's harness role to $role"
  else
    warn "harness role: not every live session for $profile accepted role $role; profile's harness_role left unchanged"
  fi
  return "$rc"
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
      # #3: the real harness's `cost --json` carries the open-requests list
      # under `pending_approvals` (an object keyed by request id, or -- some
      # builds -- already a list) and a single `pending_approval`, never the
      # made-up `pending` this used to read exclusively; handle every shape
      # (map, list, or the legacy `pending` key) rather than betting on one.
      pending_cache[$proj]=,$("$bin" cost --project "$proj" --json 2>/dev/null | jq -r \
        '(((.pending_approvals // {}) | if type=="object" then [.[]] else . end) + (if .pending_approval then [.pending_approval] else [] end) + (.pending // [])) | map(.node // empty) | join(",")' 2>/dev/null),
    fi
    [[ ${pending_cache[$proj]} == *",$node,"* ]] && printf '%s:%s\n' "$proj" "$node" >>"$tmp"
  done <"$reqf"
  mv -f "$tmp" "$reqf"
}

# The oldest open request on PROJECT (optionally matching USD) via
# `harness cost --project ID --json`'s `pending_approvals` (object or list)
# plus `pending_approval` and the legacy `pending` -- the dashboard's Approve
# button does not know the request id either.
harness_resolve_request_id() { # PROJECT [USD]
  local project=$1 usd=${2:-} bin
  bin=$(harness_bin 2>/dev/null) || { printf ''; return 0; }
  local pending; pending=$("$bin" cost --project "$project" --json 2>/dev/null | jq -c \
    '((.pending_approvals // {}) | if type=="object" then [.[]] else . end) + (if .pending_approval then [.pending_approval] else [] end) + (.pending // [])' 2>/dev/null)
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
# curl-fallback shape as harness_approve. `harness decline` is landing on the
# harness CLI (mirroring `approve`); until it does, the CLI call fails with
# argparse's "invalid choice" (the subcommand doesn't exist yet) -- that
# specific shape of failure falls back to the curl endpoint (unchanged since
# before `decline` existed); any OTHER CLI failure (a real refusal: no such
# request, etc.) is surfaced as-is, never silently retried over curl.
harness_decline() {
  local project=$1 request=${2:-}
  [[ -n $project ]] || fail "harness decline: needs PROJECT"
  [[ -z ${OAL_AGENT:-} ]] || fail "harness decline: agents cannot decline spending; ask the user to run this"
  [[ -n $request ]] || request=$(harness_resolve_request_id "$project")
  local bin; bin=$(harness_bin 2>/dev/null) || bin=""
  local rc=0 out="" use_curl=0
  if [[ -n $bin ]]; then
    if (( OAL_DRY_RUN )); then say "[dry-run] would: $bin decline --project $project --request ${request:-<none>}"; return 0; fi
    mkdir -p "$HARNESS_STATE_DIR"
    local errf; errf=$(mktemp "$HARNESS_STATE_DIR/.decline-err.XXXXXX" 2>/dev/null) || errf=""
    if out=$("$bin" decline --project "$project" --request "${request:-}" 2>"${errf:-/dev/null}"); then
      :   # CLI decline exists and succeeded
    else
      rc=$?
      local cli_err=""; [[ -n $errf ]] && cli_err=$(cat "$errf" 2>/dev/null)
      [[ -n $errf ]] && rm -f "$errf"
      if grep -qiE 'invalid choice|unrecognized arguments|usage: ' <<<"$cli_err"; then
        use_curl=1
      else
        harness_prune_requested_project "$project"
        printf '%s' "${cli_err:-$out}"
        return "$rc"
      fi
    fi
  else
    use_curl=1
  fi
  if (( use_curl )); then
    rc=0
    local body; body=$(jq -nc --arg rid "${request:-}" '{request_id:$rid, by:"human"}')
    if (( OAL_DRY_RUN )); then say "[dry-run] would POST $(harness_url)/api/project/$project/cost/decline $body"; return 0; fi
    out=$(curl -sS -m 5 -H 'X-Harness: 1' -H 'X-Harness-Approver: human' -H 'Content-Type: application/json' \
      -X POST -d "$body" "$(harness_url)/api/project/$project/cost/decline") || rc=$?
  fi
  harness_prune_requested_project "$project"
  printf '%s' "$out"
  return "$rc"
}

# harness_extract_last_json FILE -> the LAST top-level JSON OBJECT found in
# FILE, printed to stdout (exit 1, nothing printed, when none parses). Prefers
# python3's real JSON tokenizer (json.JSONDecoder.raw_decode) over hand-rolled
# bracket counting: scanning left to right, every `{`/`[` position is tried as
# a raw_decode start; a successful parse is recorded as a TOP-LEVEL candidate
# and the scan resumes PAST its end (so nothing nested inside it -- e.g. a
# `children` array's own objects -- is ever considered separately); a failed
# attempt (a stray `{` in prose, a `function() {`) advances by one character
# and is never "closed" by some unrelated `}` later in the text the way naive
# bracket-pair matching could be tricked into doing (bug (a) in the adversarial
# review: a stray brace swallowing the real object). Real JSON string parsing
# also means prose with an odd number of quote characters before the object
# (bug (b)) can never desync a hand-rolled in-string flag -- there isn't one.
# The LAST candidate (scanning the collected list from the end) that is a
# JSON OBJECT wins; a candidate that is a JSON ARRAY is never unwrapped into
# one of its elements -- it is skipped (and a reply that is nothing but a
# top-level array fails outright, printing nothing, rather than returning a
# guessed element of it). Falls back to a pure-bash approximation (the
# original bracket-counting algorithm, with its known limitations) only when
# python3 is not on PATH. Used to pull an orchestration delegate's patch out
# of a reply that may carry prose before and after the one JSON object asked for.
harness_extract_last_json() {
  local file=$1
  [[ -f $file ]] || return 1
  if have python3; then
    python3 - "$file" <<'PYEOF'
import json
import sys


def main() -> int:
    path = sys.argv[1]
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return 1
    dec = json.JSONDecoder()
    n = len(text)
    candidates = []  # (end, value) -- start is never needed again once found
    i = 0
    while i < n:
        ch = text[i]
        if ch != "{" and ch != "[":
            i += 1
            continue
        try:
            value, end = dec.raw_decode(text, i)
        except ValueError:
            i += 1  # not valid JSON starting here (a stray brace, prose) -- move on
            continue
        candidates.append((end, value))
        i = end  # skip past this top-level span: nested { }/[ ] inside it are
        #          never re-tried as separate (falsely "top-level") candidates
    dicts = [v for _end, v in candidates if isinstance(v, dict)]
    # A patch always has an "action"; an agent transcript is full of other JSON objects
    # (tool calls, file listings) that come AFTER the real answer -- prefer the last
    # object that looks like a patch, then the last object at all.
    for value in reversed(dicts):
        if "action" in value:
            sys.stdout.write(json.dumps(value))
            return 0
    if dicts:
        sys.stdout.write(json.dumps(dicts[-1]))
        return 0
    return 1  # only arrays found (or nothing) -- never guess an array's element


sys.exit(main())
PYEOF
    return $?
  fi
  _harness_extract_last_json_bash_fallback "$file"
}

# Pure-bash fallback for harness_extract_last_json when python3 is missing.
# Known limitations vs. the python path (kept only as a last resort): naive
# LIFO bracket pairing can occasionally let a stray unmatched `{` in prose,
# later closed by an unrelated `}`, swallow a real object that sits between
# them (bug (a) in the adversarial review), and manual backslash-run counting
# for string state can desync on an odd number of stray quote characters
# before the real object (bug (b)) -- both are why python3 is preferred.
_harness_extract_last_json_bash_fallback() {
  local file=$1
  [[ -f $file ]] || return 1
  # LC_ALL=C: bash indexes ${text:i:1} by CHARACTER under a multibyte locale
  # (real per-access work); the C locale makes it byte indexing, O(1) -- and
  # grep's `-b` byte offsets only line up with bash's ${text:pos:1} slicing
  # under a single-byte (C) locale in the first place.
  local LC_ALL=C
  local text; text=$(cat "$file" 2>/dev/null)
  local -a stack=()
  local pairs="" in_str=0 pos ch
  while IFS=: read -r pos ch; do
    [[ -n $pos ]] || continue
    if [[ $ch == '"' ]]; then
      if (( in_str )); then
        local bs=0 p=$(( pos - 1 ))
        while (( p >= 0 )) && [[ ${text:p:1} == '\' ]]; do (( bs++, p-- )); done
        (( bs % 2 == 0 )) && in_str=0   # an odd run of backslashes escapes this quote
      else
        in_str=1
      fi
      continue
    fi
    (( in_str )) && continue   # a brace inside a string is not structure
    if [[ $ch == '{' ]]; then
      stack+=("$pos")
    elif (( ${#stack[@]} > 0 )); then
      pairs+="${stack[-1]}"$'\t'"$pos"$'\n'
      unset 'stack[-1]'
    fi
  done < <(grep -abo '[{}"]' <<<"$text")
  [[ -n $pairs ]] || return 1
  local -a top_ps=() top_pe=()
  local cursor=-1 ps pe
  while IFS=$'\t' read -r ps pe; do
    [[ -n $ps ]] || continue
    (( ps > cursor )) || continue
    top_ps+=("$ps"); top_pe+=("$pe"); cursor=$pe
  done < <(sort -t $'\t' -k1,1n <<<"$pairs")
  local k
  for (( k = ${#top_ps[@]} - 1; k >= 0; k-- )); do
    local candidate=${text:top_ps[k]:top_pe[k]-top_ps[k]+1}
    if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# harness_record_backoff SESSION RETRY_AFTER_SEC -- belt-and-braces for #2: a
# throttled orchestration receipt the harness CLI refused (an older build
# with no `--status throttled`/`--retry-after-sec` for command receipts, say)
# must not still cause the very next sweep to re-dispatch onto the same
# 429'd session. Remembered under the harness state dir, honoured by
# harness_backoff_active (called from harness_dispatch_packet); self-expiring.
harness_record_backoff() {
  local sid=$1 retry_after=${2:-300}
  [[ -n $sid ]] || return 0
  [[ $retry_after =~ ^[0-9]+$ ]] || retry_after=300
  mkdir -p "$HARNESS_STATE_DIR"
  printf '%s\n' "$(( $(date +%s) + retry_after ))" >"$HARNESS_STATE_DIR/backoff.$sid"
}

# 0 (true) while a harness_record_backoff for SESSION has not yet expired;
# self-clears (and returns 1) once it has, so a stale file never lingers.
harness_backoff_active() {
  local sid=$1 f
  [[ -n $sid ]] || return 1
  f="$HARNESS_STATE_DIR/backoff.$sid"
  [[ -f $f ]] || return 1
  local until; until=$(cat "$f" 2>/dev/null)
  [[ $until =~ ^[0-9]+$ ]] || { rm -f "$f"; return 1; }
  if (( $(date +%s) >= until )); then rm -f "$f"; return 1; fi
  return 0
}

# --------------------------------------------------------------- dispatch ----
# One packet: cost-gate, claim, launch a DETACHED delegate (no --wait), write
# a job file for the reaper. Never blocks: harness_dispatch_reap writes the
# receipt once the worker actually finishes. Respects $HARNESS_SLOTS_LEFT
# (set by harness_dispatch_once) so at most settings.json:harness_workers run
# at once across the whole sweep.
#
# Orchestration packets (<node>.SPLIT.md / .PM.md / .COMPOSE.md, or an inbox
# row carrying `command`) are claimed/dispatched exactly like a work packet
# but ask the delegate for one patch JSON instead of oracle output, and the
# reaper writes a `--command` receipt from the LAST balanced JSON object in
# the reply (harness_extract_last_json) instead of the run's evidence tail.
# The harness only ever assigns these to a session with tier=orchestrator,
# but this is defensive: skip (never claim) one for a profile/session that
# is not registered as orchestrator.
harness_dispatch_packet() { # <bin> <project> <session> <profile> <packet-json> [<session-role>]
  local bin=$1 proj=$2 sid=$3 profile=$4 pkt=$5 session_role=${6:-}
  harness_backoff_active "$sid" && return 0   # #2 belt-and-braces: skip a session we recently un-claimed for
  local node path
  node=$(jq -r '.node // .id // empty' <<<"$pkt")
  path=$(jq -r '.path // empty' <<<"$pkt")
  [[ -n $node && -n $path ]] || return 0
  [[ $path == *.claimed ]] && return 0
  [[ -f $path ]] || return 0
  local command; command=$(jq -r '.command // empty' <<<"$pkt")
  if [[ -z $command && $path =~ \.(SPLIT|PM|COMPOSE)\.md$ ]]; then command=${BASH_REMATCH[1]}; fi
  # #21 BLOCKER: the harness may hand back the inbox row's `node` WITH the
  # orchestration command suffix (`P0.SPLIT`, matching the packet filename
  # `P0.SPLIT.md`) and no `command` field of its own -- `harness receipt`
  # only knows the bare node id (`P0`); sending it the suffixed one is
  # "unknown node", the receipt is never written, and the packet gets
  # re-dispatched every claim_timeout forever. Strip the suffix once the
  # command is known (from either source above) -- a no-op when the row
  # already carries the bare node id.
  [[ -n $command && $node == *".$command" ]] && node=${node%.$command}
  local ref="harness:$proj:$node"
  if [[ -n $command ]]; then
    # #7/#8: the profile's own `harness_role` field is never trusted for this
    # gate -- only the harness's own session record (overview.json's `tier`,
    # falling back to `role`) says what a session is actually eligible for
    # right now; the profile field can be stale or simply wrong relative to
    # what `harness session set` last accepted.
    if [[ $session_role != orchestrator ]]; then
      # Dispatch sweeps every 3s (harness_dispatch_loop); without a dedup key an
      # unclaimed orchestration packet would re-emit this note every sweep for as
      # long as it sits there. Same one-line-per-key shape as requested.txt.
      mkdir -p "$HARNESS_STATE_DIR"
      local skipf="$HARNESS_STATE_DIR/orch_skipped.txt" skipkey="$proj:$node"
      touch "$skipf"
      if ! grep -qxF "$skipkey" "$skipf"; then
        event_emit "$profile" note "harness: $node is an orchestration packet ($command) but $profile's harness session is not registered as orchestrator; skipping" \
          --source harness --level warn --ref "$ref:skipped"
        printf '%s\n' "$skipkey" >>"$skipf"
      fi
      return 0
    fi
  fi
  local backend model vendor
  backend=$(profile_get "$profile" backend 2>/dev/null); [[ -n $backend ]] || backend=$(profile_get "$profile" provider 2>/dev/null)
  model=$(harness_profile_model "$profile")   # #12: same fallback (profile model, else its backend's) used everywhere else
  vendor=$(harness_profile_vendor "$profile")
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
    # #5: `cost --json`'s remaining_usd alone overstates what is actually free
    # to spend -- money already reserved for an in-flight call (reserved_usd)
    # is not available twice, and a positive daily_cap_usd is a hard ceiling
    # no approval can lift (unlike a plain shortfall).
    local cost_view; cost_view=$("$bin" cost --project "$proj" --json 2>/dev/null)
    local remaining reserved cap dspent
    remaining=$(jq -r '.remaining_usd // 0' <<<"$cost_view" 2>/dev/null); [[ $remaining =~ ^-?[0-9.]+$ ]] || remaining=0
    reserved=$(jq -r '.reserved_usd // 0' <<<"$cost_view" 2>/dev/null); [[ $reserved =~ ^-?[0-9.]+$ ]] || reserved=0
    cap=$(jq -r '.daily_cap_usd // 0' <<<"$cost_view" 2>/dev/null); [[ $cap =~ ^-?[0-9.]+$ ]] || cap=0
    dspent=$(jq -r '.daily_spent_usd // 0' <<<"$cost_view" 2>/dev/null); [[ $dspent =~ ^-?[0-9.]+$ ]] || dspent=0
    if awk -v c="$cap" -v s="$dspent" -v e="$estimate" 'BEGIN{exit !(c > 0 && (s + e) > c)}'; then
      mkdir -p "$HARNESS_STATE_DIR"
      local capf="$HARNESS_STATE_DIR/orch_skipped.txt" capkey="$proj:$node:dailycap"
      touch "$capf"
      if ! grep -qxF "$capkey" "$capf"; then
        event_emit "$profile" note "harness: $node would push project $proj over its daily cap (\$$cap; already spent \$$dspent today) -- refusing, not requesting (a cap can't be approved away)" \
          --source harness --level warn --ref "$ref:dailycap"
        printf '%s\n' "$capkey" >>"$capf"
      fi
      return 0
    fi
    local avail; avail=$(awk -v r="$remaining" -v rv="$reserved" 'BEGIN{printf "%.6f", r - rv}')
    if awk -v a="$avail" -v e="$estimate" 'BEGIN{exit !(a < e)}'; then
      mkdir -p "$HARNESS_STATE_DIR"
      local reqf="$HARNESS_STATE_DIR/requested.txt" key="$proj:$node"
      touch "$reqf"
      if ! grep -qxF "$key" "$reqf"; then
        harness_cost_request "$proj" "$node" "$model" "$backend" "$estimate" "harness dispatch: $node needs \$$estimate" "$profile"
        printf '%s\n' "$key" >>"$reqf"
        event_emit "$profile" note "harness: requested \$$estimate for $node (project $proj, \$$avail remaining after reservations)" --source harness --ref "$ref:requested"
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
  # #27: the packet trailer names the first command the (stateless-between-
  # packets) delegate must run so it can orient itself before doing anything
  # else -- `harness brief` for an orchestration packet, `harness show` for a
  # plain work packet (see skills/rix/SKILL.md "pick up any task fresh").
  # The delegate works INSIDE the project's repo: every path in the packet is relative to
  # it, and a delegate started in some other directory went looking for the files and
  # wrote into the wrong checkout (seen live 2026-09-15: the dispatcher's own cwd).
  local repo; repo=$(harness_project_repo "$bin" "$proj")
  if [[ -z $repo || ! -d $repo ]]; then
    warn "harness: no repo_path for project $proj; not dispatching $node"
    mv -f "$claimed" "$path" 2>/dev/null || true
    return 0
  fi
  local where=$'\nWorking directory: '"$repo"$' (you are started there; every path below is relative to it; never work in any other checkout).'
  local run_dir=$repo
  if [[ -n $command ]]; then
    # An orchestration delegate reads the packet and answers with a patch; it has no
    # business in the repo at all (a 4B model "orienting" itself re-created the kata under
    # demo_repo/{src,tests} and poisoned every pytest oracle, 2026-09-15). Run it in an
    # empty scratch directory: `harness brief`/`show` still work from anywhere.
    run_dir="$HARNESS_STATE_DIR/orch/$proj/$node"; mkdir -p "$run_dir"
    trailer=$'\n\nFirst run: harness brief --project '"$proj"' --session '"$sid"$'\nThis is a planning task: do NOT read, create, copy or modify any file and do not run tests -- everything you need is in this packet and in `harness brief`/`harness show`. Do not write the outbox receipt file yourself. Your FINAL message must be exactly one JSON object -- the patch, with an "action" key -- with no prose before or after it and no markdown fence; the launcher extracts it and writes the receipt. A reply without such an object fails this packet.'
  else
    trailer=$'\n\nFirst run: harness show --project '"$proj"' --node '"$node"$'\n'"$where"$'\nEdit ONLY the files listed under Touches, in place. Never create new files or directories, never copy or re-create the repo or its tests anywhere else, never search the filesystem for another copy: if a file in Touches is missing, stop and report it. When finished, run the oracle command from the working directory and print its output.'
  fi
  local -a saved_opts=("${OPTS[@]}")
  OPTS=(--backend "$backend" --name "$name" --task-title "$node" --model "$model" --job-stdin)
  [[ $class == metered ]] && OPTS+=(--approved-usd "$estimate")   # the harness already approved this budget
  # started_at is captured BEFORE cmd_delegate runs (not after) so the reaper's
  # non-sentinel fallback (mtime/event-time vs started) can never see a job
  # whose run log was written inside cmd_delegate's own second land before
  # `started`, which would misclassify a freshly-started job as already done.
  local started; started=$(date +%s)
  # #26: $HARNESS_SESSION/$HARNESS_PROJECT are exported for exactly this one
  # cmd_delegate call (temp assignment on a function call, restored after --
  # never leaked into a later packet's dispatch in the same sweep) so a
  # delegate that inherits them (this process's forks: the detached tmux
  # session, then the agent itself) can run `harness brief --session
  # "$HARNESS_SESSION"` as the skill instructs, without the launcher having
  # to pass `--session` through cmd_delegate's own CLI surface.
  # cd in a subshell: cmd_delegate forks the detached agent from the current directory.
  printf '%s%s\n' "$content" "$trailer" | ( cd "$run_dir" && HARNESS_SESSION="$sid" HARNESS_PROJECT="$proj" HARNESS_REPO="$repo" cmd_delegate ) >/dev/null 2>&1
  local drc=$?
  OPTS=("${saved_opts[@]}")
  if (( drc != 0 )); then
    warn "harness: delegate refused to start $node (exit $drc)"
    mv -f "$claimed" "$path" 2>/dev/null || true   # un-claim so a future sweep can retry
    event_emit "$profile" note "harness: $node did not start (delegate exit $drc)" --source harness --level warn --ref "$ref:failed"
    return 0
  fi
  # The delegate is a saved agent under the SLUGIFIED name (cmd_delegate slugifies
  # --name), with its own tmux server. Record the slug, the claimed packet path and the
  # tmux server pid so the sweep can heartbeat the harness session (a job takes minutes;
  # the harness marks a session stale after 45 s of silence and would give the node to
  # someone else while this delegate ran on) and cancel/clean the delegate later.
  local slug pid=""
  slug=$(slugify "$name")
  have tmux && pid=$(tmux -S "$(tmux_socket "$slug")" list-panes -a -F '#{pane_pid}' 2>/dev/null | head -n1 | tr -dc '0-9')
  mkdir -p "$HARNESS_JOBS_DIR/$proj"
  jq -n --arg project "$proj" --arg node "$node" --arg session "$sid" --arg profile "$profile" \
        --arg name "$name" --arg slug "$slug" --arg backend "$backend" --arg model "$model" --arg bin "$bin" \
        --arg claimed "$claimed" --arg pid "$pid" --argjson started "$started" \
        --arg command "$command" --arg vendor "$vendor" \
        '{project:$project, node:$node, session:$session, profile:$profile, name:$name, slug:$slug, backend:$backend, model:$model, bin:$bin, claimed:$claimed, pid:$pid, started_at:$started, command:$command, vendor:$vendor}' \
    >"$HARNESS_JOBS_DIR/$proj/$node.json"
  if [[ -n $pid ]]; then "$bin" session set --project "$proj" --session "$sid" --pid "$pid" >/dev/null 2>&1 || true
  else "$bin" heartbeat --project "$proj" --session "$sid" >/dev/null 2>&1 || true; fi
  HARNESS_SLOTS_LEFT=$(( ${HARNESS_SLOTS_LEFT:-1} - 1 ))
  event_emit "$profile" note "harness: started $node ($name)" --source harness --ref "$ref:start"
}

# Forget a finished or cancelled delegate: its tmux server, staged home, profile and
# job file. Transient `hns-*` agents must not pile up in the launcher's agent list.
harness_job_forget() { # <slug>
  local slug=$1
  [[ -n $slug && $slug == hns-* ]] || return 0
  session_kill "$slug" 2>/dev/null || true
  rm -rf "$(stage_dir "$slug")" 2>/dev/null || true
  rm -f "$(profile_path "$slug")" "$(job_path "$slug")" 2>/dev/null || true
}

# Every sweep, for each running job: if the harness withdrew the packet (the claimed file
# was renamed to *.cancelled or vanished — the node was released, cancelled or reassigned)
# stop the delegate; otherwise tell the harness the session is alive. Without this the
# harness marked the Rix sessions stale mid-job and re-solved their nodes elsewhere
# (observed live on 2026-09-14).
harness_dispatch_heartbeat() {
  [[ -d $HARNESS_JOBS_DIR ]] || return 0
  local jf
  while IFS= read -r -d '' jf; do
    local job proj node sid profile slug bin claimed
    job=$(cat "$jf" 2>/dev/null) || continue
    proj=$(jq -r '.project // empty' <<<"$job"); node=$(jq -r '.node // empty' <<<"$job")
    sid=$(jq -r '.session // empty' <<<"$job"); profile=$(jq -r '.profile // empty' <<<"$job")
    slug=$(jq -r '.slug // empty' <<<"$job"); bin=$(jq -r '.bin // empty' <<<"$job")
    claimed=$(jq -r '.claimed // empty' <<<"$job")
    [[ -n $proj && -n $sid && -n $bin ]] || continue
    if [[ -n $claimed && ! -f $claimed ]]; then
      harness_job_forget "$slug"
      "$bin" session set --project "$proj" --session "$sid" --clear-pid >/dev/null 2>&1 || true
      event_emit "$profile" note "harness: $node withdrawn by the harness; delegate stopped" --source harness --ref "harness:$proj:$node:cancelled"
      rm -f "$jf"
      continue
    fi
    "$bin" heartbeat --project "$proj" --session "$sid" >/dev/null 2>&1 || true
    # #13: the harness's own claim-timeout safety net (workers.claim_timeout_sec,
    # 1800s) treats a `.md.claimed` younger than that as still-alive when no pid
    # was recorded -- keep its mtime fresh every sweep so a delegate running
    # longer than that never gets its node reclaimed out from under it.
    [[ -n $claimed && -f $claimed ]] && touch "$claimed" 2>/dev/null
  done < <(find "$HARNESS_JOBS_DIR" -mindepth 2 -maxdepth 2 -name '*.json' -print0 2>/dev/null)
}

# Reap finished detached jobs. A worker's run log that ends with the
# completion sentinel `__oal_rc=<n>` (a test-only dispatcher writes one; see
# tests/run.sh) is trusted outright -- the exit code AND the throttle marker
# both come from that one already-fully-read log, so there is nothing left to
# race against (no separate events.jsonl lookup, no mtime heuristic). Without
# a sentinel (every real job: session_run_once never writes one) we fall back
# to the original heuristic unchanged: "finished" once the log postdates the
# job, exit code from the last matching session_exited event. rc-first either
# way: only a nonzero exit AND a structured marker in the last 20 lines of
# the log (sentinel line excluded) counts as throttled.
harness_dispatch_reap() {
  [[ -d $HARNESS_JOBS_DIR ]] || return 0
  local jf
  while IFS= read -r -d '' jf; do
    local job proj node sid profile name backend model bin started slug command vendor claimed
    job=$(cat "$jf" 2>/dev/null) || { rm -f "$jf"; continue; }
    slug=$(jq -r '.slug // empty' <<<"$job")
    proj=$(jq -r '.project // empty' <<<"$job"); node=$(jq -r '.node // empty' <<<"$job")
    sid=$(jq -r '.session // empty' <<<"$job"); profile=$(jq -r '.profile // empty' <<<"$job")
    name=$(jq -r '.name // empty' <<<"$job"); backend=$(jq -r '.backend // empty' <<<"$job")
    model=$(jq -r '.model // empty' <<<"$job"); bin=$(jq -r '.bin // empty' <<<"$job")
    started=$(jq -r '.started_at // 0' <<<"$job")
    command=$(jq -r '.command // empty' <<<"$job"); vendor=$(jq -r '.vendor // empty' <<<"$job")
    claimed=$(jq -r '.claimed // empty' <<<"$job")
    [[ -n $vendor ]] || vendor=$backend
    [[ -n $proj && -n $node && -n $name && -n $bin ]] || { rm -f "$jf"; continue; }
    local dir latest
    # the delegate's staged home is under the SLUG (cmd_delegate slugifies --name)
    dir="$(stage_dir "${slug:-$(slugify "$name")}")/runs"
    latest=$(ls -1t "$dir"/*.log 2>/dev/null | head -n1)
    if [[ -z $latest ]]; then continue; fi   # still running: no log yet

    local out; out=$(LC_ALL=C sed -E 's/\x1B\[[0-9;?]*[ -\/]*[@-~]//g; s/\r$//' "$latest" 2>/dev/null)
    local sentinel=""
    [[ $out =~ __oal_rc=(-?[0-9]+)[[:space:]]*$ ]] && sentinel=${BASH_REMATCH[1]}
    if [[ -z $sentinel ]]; then
      local mt; mt=$(stat -c %Y "$latest" 2>/dev/null || echo 0)
      (( mt < started )) && continue   # still running (log predates this job); no sentinel to trust instead
    fi

    local code
    if [[ -n $sentinel ]]; then
      code=$sentinel
      out=$(sed -E '/^__oal_rc=-?[0-9]+[[:space:]]*$/d' <<<"$out")   # keep the marker window free of the sentinel line itself
    else
      # No sentinel (a real job): the run log's mtime alone can't distinguish
      # "finished" from "still writing" once it postdates `started`, so also
      # require a session_exited event timestamped (ms) at or after this job's
      # start -- an unrelated/stale event, or none yet, means still running.
      # Unattended runs log `job_done` (interactive ones `session_exited`); accept both.
      # If neither has landed but the delegate's tmux server is gone, the run is over
      # too (the log is complete once the server exits): exit code unknown -> 1.
      local exit_evt
      exit_evt=$(events_recent 400 | jq -c --arg n "$slug" --argjson s "$((started * 1000))" \
        '[.[] | select(.agent == $n and (.kind == "session_exited" or .kind == "job_done") and (.t // 0) >= $s)] | last' 2>/dev/null)
      if [[ -n $exit_evt && $exit_evt != null ]]; then
        code=$(jq -r '.code // 0' <<<"$exit_evt" 2>/dev/null)
      elif [[ -n $slug ]] && ! session_alive "$slug"; then
        code=1
      else
        continue   # still running
      fi
    fi
    [[ $code =~ ^-?[0-9]+$ ]] || code=0
    local status
    if (( code != 0 )) && grep -qiE '429|rate.?limit|usage limit' <<<"$(tail -n 20 <<<"$out")"; then status="throttled"
    elif (( code == 0 )); then status="done"
    else status="failed"
    fi
    local evidence; evidence=$(tail -n 40 <<<"$out")
    local usage_row usd_actual tok_in tok_out
    usage_row=$(declare -F usage_json >/dev/null && usage_json | jq -c --arg n "${slug:-$name}" '.agents[]? | select(.name == $n)' 2>/dev/null)
    usd_actual=$(jq -r '.cost_usd // empty' <<<"$usage_row" 2>/dev/null)
    tok_in=$(jq -r '.prompt // empty' <<<"$usage_row" 2>/dev/null)
    tok_out=$(jq -r '.output // empty' <<<"$usage_row" 2>/dev/null)
    if [[ -n $command ]]; then
      # Orchestration packet: the CLI verb is --command SPLIT|PM|COMPOSE
      # --patch-file F --status done|failed|throttled -- pull the LAST
      # balanced JSON object out of the delegate's reply and hand the harness
      # that file; a delegate that never produced one, was itself throttled,
      # or did not finish successfully gets a --summary instead of a guessed
      # patch (#11: "delegate exited …" for a dead process vs. "no JSON…" for
      # one that finished but replied with none -- two different failures,
      # two different messages).
      local rstatus="failed" summary="" patch_file="" retry_after=""
      if [[ $status == "done" ]]; then
        local rawlog; rawlog=$(mktemp "$HARNESS_JOBS_DIR/.extract.XXXXXX")
        # The trailer told the delegate to reply with nothing after the patch, so
        # the patch is near the end -- cap what we scan to the last 2000 lines. A
        # full unattended run log can be hundreds of KB, and harness_extract_last_json's
        # per-candidate scan (needed to skip a broken/unterminated object) would
        # otherwise cost real seconds here, holding up the whole reap sweep (and
        # with it harness_dispatch_heartbeat, right after the 45s-stale bug 0.13 fixed).
        printf '%s' "$out" | tail -n 2000 >"$rawlog"
        local json
        if json=$(harness_extract_last_json "$rawlog"); then
          mkdir -p "$HARNESS_STATE_DIR/patches/$proj"
          patch_file="$HARNESS_STATE_DIR/patches/$proj/$node.$command.patch.json"
          printf '%s' "$json" >"$patch_file"
          rstatus="done"
        else
          summary="no JSON object found in the delegate's reply"
        fi
        rm -f "$rawlog"
      elif [[ $status == throttled ]]; then
        rstatus="throttled"; retry_after=300
        summary="delegate throttled (rate limited); will retry"
      else
        summary="delegate exited $status/$code: $(tail -c 200 <<<"$out" | tr '\n' ' ')"
      fi
      local -a cargs=(receipt --project "$proj" --session "$sid" --node "$node" --command "$command" --status "$rstatus" --model "$model" --vendor "$vendor")
      [[ -n $patch_file ]] && cargs+=(--patch-file "$patch_file")
      [[ -n $summary ]] && cargs+=(--summary "$summary")
      [[ $rstatus == throttled && -n $retry_after ]] && cargs+=(--retry-after-sec "$retry_after")
      [[ -n $usd_actual && $usd_actual != null ]] && cargs+=(--usd "$usd_actual")
      [[ -n $tok_in && $tok_in != null ]] && cargs+=(--tokens-in "$tok_in")
      [[ -n $tok_out && $tok_out != null ]] && cargs+=(--tokens-out "$tok_out")
      if ! "$bin" "${cargs[@]}" >/dev/null 2>&1; then
        warn "harness receipt (command) failed for $node ($rstatus)"
        # #2 belt and braces: a throttled receipt the harness didn't accept
        # (e.g. an older CLI with no --status throttled/--retry-after-sec for
        # command receipts yet) must not still get re-dispatched onto the
        # same 429'd backend next sweep -- un-claim the packet so the harness
        # can re-solve or timeout-reclaim it, and record a per-session
        # backoff so THIS dispatcher skips it until retry_at even though the
        # harness itself never learned about the throttle.
        if [[ $rstatus == throttled && -n $claimed && -f $claimed ]]; then
          mv -f "$claimed" "${claimed%.claimed}" 2>/dev/null || true
          harness_record_backoff "$sid" "$retry_after"
        fi
      fi
    else
      local -a rargs=(receipt --project "$proj" --session "$sid" --node "$node" --status "$status" --evidence "$evidence" --model "$model" --vendor "$backend")
      [[ -n $usd_actual && $usd_actual != null ]] && rargs+=(--usd "$usd_actual")
      [[ -n $tok_in && $tok_in != null ]] && rargs+=(--tokens-in "$tok_in")
      [[ -n $tok_out && $tok_out != null ]] && rargs+=(--tokens-out "$tok_out")
      "$bin" "${rargs[@]}" >/dev/null 2>&1 || warn "harness receipt failed for $node ($status)"
    fi
    "$bin" session set --project "$proj" --session "$sid" --clear-pid >/dev/null 2>&1 || true
    harness_prune_requested_key "$proj" "$node"
    event_emit "$profile" note "harness: $node $status" --source harness --ref "harness:$proj:$node:$status"
    harness_job_forget "$(jq -r '.slug // empty' <<<"$job")"
    rm -f "$jf"
  done < <(find "$HARNESS_JOBS_DIR" -mindepth 2 -maxdepth 2 -name '*.json' -print0 2>/dev/null)
}

harness_jobs_running() { find "$HARNESS_JOBS_DIR" -mindepth 2 -maxdepth 2 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

# One sweep: reap finished jobs, then launch up to settings.json:harness_workers
# (default 4) new detached delegates, one per unclaimed packet, across every
# rix session in overview.json whose label is (or is one --slots worker of) a
# saved profile.
# harness_project_repo BIN PROJECT -> the project's repo_path (from `harness --json ls`),
# cached per process; empty when unknown.
declare -A HARNESS_REPO_CACHE=()
harness_project_repo() {
  local bin=$1 proj=$2
  if [[ -z ${HARNESS_REPO_CACHE[$proj]:-} ]]; then
    HARNESS_REPO_CACHE[$proj]=$("$bin" --json ls 2>/dev/null | jq -r --arg id "$proj" '.[]? | select(.id == $id) | .repo_path // empty' 2>/dev/null | head -n1)
    # overview.json knows it too (the harness writes repo_path per project)
    [[ -n ${HARNESS_REPO_CACHE[$proj]} ]] || HARNESS_REPO_CACHE[$proj]=$(jq -r --arg id "$proj" '.projects[]? | select(.id == $id) | .repo_path // empty' <<<"$(harness_overview_json)" 2>/dev/null | head -n1)
  fi
  printf '%s' "${HARNESS_REPO_CACHE[$proj]:-}"
}

# harness_keepalive_sessions BIN OVERVIEW-JSON -- every launcher-owned rix session that is
# not running a job gets this dispatch loop's pid recorded (`session set --pid`) when it has
# none, so the harness's pid-liveness check keeps it alive while the launcher is here to
# dispatch for it (CONTRACTS §9.1). Without this an idle Rix session went stale 45 s after
# registration, the harness released its orchestration packet and handed the work elsewhere
# (seen live 2026-09-15). A job's own pid replaces it while the job runs; the reaper clears
# that, and the next sweep re-records ours.
harness_keepalive_sessions() {
  local bin=$1 overview=$2 sess proj sid label pid
  while IFS= read -r sess; do
    [[ -n $sess ]] || continue
    proj=$(jq -r '.project // empty' <<<"$sess"); sid=$(jq -r '.id // empty' <<<"$sess")
    label=$(jq -r '.label // empty' <<<"$sess"); pid=$(jq -r '.pid // empty' <<<"$sess")
    [[ -n $proj && -n $sid && -n $label ]] || continue
    harness_profile_for_label "$label" >/dev/null 2>&1 || continue
    [[ -z $pid ]] || continue                     # a job's pid (or ours) is already there
    [[ -f "$HARNESS_JOBS_DIR/$proj/$(jq -r '.assigned_nodes[0] // ""' <<<"$sess").json" ]] && continue
    (( OAL_DRY_RUN )) && { say "[dry-run] would: $bin session set --project $proj --session $sid --pid $$"; continue; }
    "$bin" session set --project "$proj" --session "$sid" --pid "$$" >/dev/null 2>&1 || true
  done < <(jq -c '.sessions[]? | select(.worker == "rix")' <<<"$overview")
}

# On loop exit: forget our pid on every session that carries it (a session with no
# launcher behind it must read stale, not alive -- state must not lie).
harness_keepalive_clear() {
  local bin; bin=$(harness_bin 2>/dev/null) || return 0
  local sess proj sid pid
  while IFS= read -r sess; do
    [[ -n $sess ]] || continue
    proj=$(jq -r '.project // empty' <<<"$sess"); sid=$(jq -r '.id // empty' <<<"$sess"); pid=$(jq -r '.pid // empty' <<<"$sess")
    [[ -n $proj && -n $sid && $pid == "$$" ]] || continue
    "$bin" session set --project "$proj" --session "$sid" --clear-pid >/dev/null 2>&1 || true
  done < <(jq -c '.sessions[]? | select(.worker == "rix")' <<<"$(harness_overview_json)")
}

harness_dispatch_once() {
  local bin; bin=$(harness_bin) || return 1
  harness_keepalive_sessions "$bin" "$(harness_overview_json)"
  harness_dispatch_heartbeat
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
    local proj sid label profile sess_role
    proj=$(jq -r '.project // empty' <<<"$sess")
    sid=$(jq -r '.id // empty' <<<"$sess")
    label=$(jq -r '.label // empty' <<<"$sess")
    sess_role=$(jq -r '(.tier // .role) // empty' <<<"$sess")   # tier wins (#7/#8: it's the harness's own eligibility ceiling)
    [[ -n $proj && -n $sid && -n $label ]] || continue
    profile=$(harness_profile_for_label "$label") || continue
    # --json is a GLOBAL flag on the harness CLI, before the subcommand (older
    # and newer harness builds both accept it there; only some newer builds
    # also accept a per-subcommand --json, so the global position is the one
    # that works everywhere). Any non-JSON-array output (including empty, on
    # error) is treated as an empty inbox rather than failing the sweep.
    local inbox; inbox=$("$bin" --json inbox --project "$proj" --session "$sid" 2>/dev/null)
    [[ $inbox == \[* ]] || inbox='[]'
    local pkt
    while IFS= read -r pkt; do
      [[ -n $pkt ]] || continue
      (( HARNESS_SLOTS_LEFT <= 0 )) && break
      harness_dispatch_packet "$bin" "$proj" "$sid" "$profile" "$pkt" "$sess_role"
    done < <(jq -c '.[]?' <<<"$inbox")
  done < <(jq -c '.sessions[]? | select(.worker == "rix")' <<<"$overview")
}

# Every 3s until killed (started by harness_serve_start as its own process).
harness_dispatch_loop() {
  trap 'harness_keepalive_clear; exit 0' TERM INT EXIT
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
  # roles: every registered Rix session's role/tier/model/vendor/ip_safe (as
  # the harness itself recorded them in overview.json, not re-derived here).
  # orchestrator: per project, overview.json's own projects[].orchestrator
  # (the session or router hop that would orchestrate right now), keyed by
  # project id -- omitted for a project that doesn't carry one yet.
  local roles; roles=$(jq -c '[.sessions[]? | select(.worker == "rix") | {
    session: .id, project: .project, role: (.role // null), tier: (.tier // null),
    model: (.model // null), vendor: (.vendor // null), ip_safe: (.ip_safe // null)
  }]' <<<"$overview" 2>/dev/null)
  [[ $roles == \[* ]] || roles='[]'
  local orchestrator; orchestrator=$(jq -c '[.projects[]? | select(.orchestrator != null and .id != null) | {key: .id, value: .orchestrator}] | from_entries' <<<"$overview" 2>/dev/null)
  [[ $orchestrator == \{* ]] || orchestrator='{}'
  jq -nc --argjson alive "$alive" --arg url "$url" --arg data_dir "$ddir" --arg bin "$bin" --arg overview_path "$ov" \
    --argjson serving_pid "${serving_pid:-null}" --argjson dispatch_pid "${dispatch_pid:-null}" \
    --argjson projects "$projects" --argjson pending_approvals "$pending" \
    --argjson jobs_running "$running" --argjson jobs_slots "$slots" \
    --argjson roles "$roles" --argjson orchestrator "$orchestrator" \
    '{alive:$alive, url:$url, data_dir:$data_dir, bin:$bin, overview_path:$overview_path, serving_pid:$serving_pid, dispatch_pid:$dispatch_pid,
      projects:$projects, pending_approvals:$pending_approvals, jobs:{running:$jobs_running, slots:$jobs_slots},
      roles:$roles, orchestrator:$orchestrator}'
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
