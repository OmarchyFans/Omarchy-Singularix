#!/bin/bash
# Rix's coding fleet (P0.10): one harness-registered delegate SESSION per
# ready subscription/metered backend, so the session pool the harness round-
# robins across (P0.1 routing.md §1b: rank_sessions) actually exists without
# a human clicking through the New agent form five times.
#
# Reads P0.6's backend policy (tier/ip_safe/metered, lib/backends.sh) purely
# to (a) skip a backend that needs sign-in (`ready`) and (b) sanity-check
# that the backend's own policy table actually claims the role we are about
# to register it for -- a defensive belt, since the harness (policy.py) is
# still the one that derives ip_safe/metered/tier authoritatively at
# registration time (P0.1 §4: "ip_safe is derived, never trusted from the
# caller upward"). Nothing here invents a model id: every target either uses
# the backend's own default model (providers.sh, the one place ids are
# edited) or, for the one case that needs a *different* model on the same
# backend (Opus on the shared `anthropic` backend), the exact id already
# named in providers.sh's own model-suggestions column.
#
# Each target becomes a plain launcher profile (agent=hermes, runtime=local,
# mode=unattended, role=worker, parent=rix) plus a `harness register` against
# it -- register's own label rule (harness.sh:harness_register_rix, slots=1)
# is what guarantees "label == profile name": this file only ever calls it
# with the default slot count, never --slots N, so it can never mint a
# "<profile>-N" label that harness_profile_for_label would still resolve,
# but which a careless caller elsewhere could mismatch against. Keeping
# slots=1 here is the whole trick -- see harness.sh:493-502.

# backend | profile | role | model-override ("" = the backend's own default)
RIX_FLEET_TARGETS=(
  "anthropic|rix-sonnet|coding|"
  "anthropic|rix-opus|reasoning|claude-opus-5"
  "openai-codex|rix-codex|coding|"
  "xai-oauth|rix-grok|coding|"
  "deepseek|rix-deepseek|coding|"
)

# The job description written once per fleet profile (never overwritten on a
# re-register, so a human's edits to it stick): fleet sessions are policy
# records the harness dispatch loop hands per-packet work to
# (lib/harness.sh's own comment: "dispatches its packets as detached
# delegate jobs") -- this file is only what a human sees if they open the
# profile's window directly. rix_fleet_job PROFILE ROLE
rix_fleet_job() {
  cat <<JOB
# Rix fleet worker: $1 ($2 tier)

You are a harness delegate session in Rix's coding fleet, registered by
\`rix fleet register\`. You do not pick your own work: the session-harness
dispatch loop hands you one inbox packet at a time (already cost-cleared)
and reads back your real result as the outbox receipt once you finish.

Do exactly what the packet asks, nothing more. If you are blocked, say so
plainly and stop rather than guessing.
JOB
}

# Create or refresh one fleet profile from a RIX_FLEET_TARGETS row.
# _rix_fleet_setup_profile BACKEND PROFILE ROLE MODEL_OVERRIDE
_rix_fleet_setup_profile() {
  local backend=$1 profile=$2 role=$3 model_override=$4
  local r; r=$(backend_resolve "$backend" "$model_override") || return 1
  local provider auth model base_url
  provider=$(jq -r .provider <<<"$r"); auth=$(jq -r .auth <<<"$r")
  model=$(jq -r .model <<<"$r"); base_url=$(jq -r .base_url <<<"$r")
  mkdir -p "$OAL_PROFILES"
  profile_write "$profile" hermes local "$provider" "$auth" "$model" "$base_url" unattended ""
  profile_set "$profile" backend "$(jq -Rn --arg v "$backend" '$v')"
  profile_set "$profile" role '"worker"'
  profile_set "$profile" parent "$(jq -Rn --arg v "$RIX_NAME" '$v')"
  profile_set "$profile" harness_role "$(jq -Rn --arg v "$role" '$v')"
  profile_set "$profile" fleet true
  [[ -s $(job_path "$profile") ]] || rix_fleet_job "$profile" "$role" >"$(job_path "$profile")"
  event_emit "$profile" created "Rix fleet: $profile on $backend/$model ($role)" --task "rix fleet" 2>/dev/null || true
  return 0
}

# rix_fleet_register [PROJECT_ID] [REPO] -- one launcher profile + one
# `harness register` per ready RIX_FLEET_TARGETS row. PROJECT_ID/REPO are
# passed straight through to harness_register_rix (empty REPO defaults to
# $PWD, same as `harness register` itself); PROJECT_ID skips the repo_path
# lookup, same meaning as `harness register --project`.
rix_fleet_register() {
  local project_id=${1:-} repo=${2:-}
  harness_bin >/dev/null 2>&1 || fail "rix fleet register: harness CLI not found (see: omarchy-agent-launcher harness status)"
  local row backend profile role model_override
  local ok=0 skipped=0 failed=0
  for row in "${RIX_FLEET_TARGETS[@]}"; do
    IFS='|' read -r backend profile role model_override <<<"$row"
    local b; b=$(backend_get "$backend" 2>/dev/null)
    if [[ -z $b ]]; then
      warn "rix fleet register: unknown backend '$backend', skipping $profile"
      ((skipped++)); continue
    fi
    if [[ $(jq -r '.ready // false' <<<"$b") != true ]]; then
      say "rix fleet register: skip $profile -- $backend needs sign-in ($(jq -r '.state // "not ready"' <<<"$b"))"
      ((skipped++)); continue
    fi
    # Defensive cross-check against P0.6's own policy table: a role this
    # backend's tier list doesn't claim to serve is a config bug, not
    # something to silently register anyway.
    if ! jq -e --arg r "$role" '(.tier // []) | index($r)' <<<"$b" >/dev/null 2>&1; then
      warn "rix fleet register: $backend's policy tier $(jq -c '.tier // []' <<<"$b") does not include '$role'; skipping $profile"
      ((skipped++)); continue
    fi
    if ! _rix_fleet_setup_profile "$backend" "$profile" "$role" "$model_override"; then
      warn "rix fleet register: could not resolve $backend for $profile"
      ((failed++)); continue
    fi
    if harness_register_rix "$profile" "$repo" 1 "$project_id" ""; then
      ((ok++))
    else
      ((failed++))
    fi
  done
  say "rix fleet register: $ok registered, $skipped skipped (needs sign-in / policy mismatch), $failed failed"
  (( failed == 0 ))
}

# Every saved profile this file created (profile field fleet=true), whether
# or not it is currently a live harness session. rix_fleet_status_json
rix_fleet_status_json() {
  local sessions_live="[]" bin
  if bin=$(harness_bin 2>/dev/null); then
    sessions_live=$("$bin" --json sessions 2>/dev/null)
    [[ $sessions_live == \[* ]] || sessions_live=$(jq -c '.sessions // []' <<<"$(harness_overview_json)")
  else
    sessions_live=$(jq -c '.sessions // []' <<<"$(harness_overview_json)")
  fi
  local n out="[]"
  while IFS= read -r n; do
    [[ -n $n ]] || continue
    [[ $(profile_get "$n" fleet 2>/dev/null) == true ]] || continue
    local backend role model vendor sess
    backend=$(profile_get "$n" backend 2>/dev/null); [[ -n $backend ]] || backend=$(profile_get "$n" provider 2>/dev/null)
    role=$(profile_get "$n" harness_role 2>/dev/null)
    model=$(declare -F harness_profile_model >/dev/null && harness_profile_model "$n" || profile_get "$n" model)
    vendor=$(declare -F harness_profile_vendor >/dev/null && harness_profile_vendor "$n" || printf '%s' "$backend")
    sess=$(jq -c --arg l "$n" '[.[]? | select(.worker == "rix" and .label == $l)] | first // null' <<<"$sessions_live" 2>/dev/null)
    [[ -n $sess ]] || sess=null
    out=$(jq -c --arg name "$n" --arg backend "$backend" --arg role "$role" --arg model "$model" --arg vendor "$vendor" \
      --argjson session "$sess" \
      '. + [{profile:$name, backend:$backend, role:$role, model:$model, vendor:$vendor, registered:($session != null), session:$session}]' \
      <<<"$out")
  done < <(profile_list)
  printf '%s' "$out"
}

# Human-readable table: profile, backend, role, model, harness state.
rix_fleet_status() {
  local rows; rows=$(rix_fleet_status_json)
  if [[ $(jq 'length' <<<"$rows") == 0 ]]; then
    say "no fleet sessions yet (omarchy-agent-launcher rix fleet register)"
    return 0
  fi
  { printf 'PROFILE\tBACKEND\tROLE\tMODEL\tHARNESS\tSTATE\n'
    jq -r '.[] | [.profile, .backend, .role, .model,
             (if .registered then "registered" else "not registered" end),
             (.session.state // "-")] | @tsv' <<<"$rows"
  } | column -t -s $'\t'
}

# ==========================================================================
# P0.21 -- the no-`--backend` router: `cmd_delegate` asks this for a backend
# when the caller doesn't name one, instead of failing outright.
#
# Reuses exactly RIX_FLEET_TARGETS (above) as the routing table -- the same
# role->backend mapping `rix fleet register` already registered sessions
# for, so "dispatch to that backend's fleet session" is true by construction:
# whatever this picks is one of rix-sonnet/rix-codex/rix-grok/rix-opus/
# rix-deepseek's own backend, already a registered harness session per
# P0.10, not a new ad hoc target invented here.
#
# Deliberately does NOT read P0.6's `.tier`/`.ip_safe`/`.metered` backend
# fields (those aren't merged live yet, and `rix_fleet_register`'s own use of
# them is only a defensive cross-check, not the source of truth). Readiness
# comes straight from `backend_get`'s `.ready` -- already live, unmodified,
# the same field `rix_fleet_register` gates on -- and cost class from the
# already-live `harness_backend_cost_class` (harness.sh), so this works
# whether or not P0.6/P0.10 have been merged, as long as rix_fleet.sh (this
# file) is sourced and the launcher's own OAuth sign-in / saved keys reflect
# reality (same state `backends list` already shows a human).
#
# Two axes, per P0.1 routing.md §1b/§1c/§2 (mirrors `policy.node_role` /
# `policy.node_ip_class` on the harness side -- this is the launcher's own
# best-effort echo of that split for an AD HOC `delegate`, not a replacement
# for the harness's own `session_can_take`/`rank_sessions`, which still
# governs anything dispatched through `harness_dispatch_packet`):
#   role:     coding (default) | reasoning
#   ip_class: protected (default, fail closed like policy.py's
#             default_ip_class) | open
#
# protected -- DeepSeek (not ip_safe) is never a candidate, no matter what
# else is or isn't ready: a protected node may only go to an ip-safe
# session, same as `session_can_take`'s protected-node rule (policy.py
# #4, "protected node -> session must be ip_safe" -- DeepSeek off
# protected nodes). open -- DeepSeek becomes eligible, but only as
# overflow (last in candidate order): P0.1 §1c is explicit that DeepSeek
# is "overflow, never a preferred target".
#
# Round robin ("coding round-robin across Sonnet/Codex/Grok", P0.1 §1b) is a
# persisted per-(role,ip_class) cursor under $OAL_DATA, advanced on every
# pick over the READY candidates in RIX_FLEET_TARGETS' own fixed order
# (Sonnet, Codex, Grok) -- a simple, deterministic stand-in for the harness's
# own `rank_sessions` "fewest recent packets" fairness (P0.8), which lives in
# the python session-pool and isn't reachable from this ad hoc CLI path.
# Good enough for "rotate, don't always pick the same one" on a command a
# human or Rix runs by hand; the real fairness guarantee for harness-
# dispatched work is still `rank_sessions` itself, untouched by this file.
RIX_FLEET_RR_FILE="$OAL_DATA/rix_fleet_rr.json"

# _rix_fleet_rr_next KEY COUNT -> next 0-based index into a COUNT-long
# candidate list, advancing and persisting KEY's cursor. COUNT<=0 -> "0"
# without touching the state file (nothing to rotate over).
_rix_fleet_rr_next() {
  local key=$1 count=$2
  (( count > 0 )) || { printf '0'; return 0; }
  mkdir -p "$(dirname "$RIX_FLEET_RR_FILE")"
  local cur
  cur=$([[ -s $RIX_FLEET_RR_FILE ]] && jq -r --arg k "$key" '.[$k] // 0' "$RIX_FLEET_RR_FILE" 2>/dev/null)
  [[ $cur =~ ^[0-9]+$ ]] || cur=0
  local tmp; tmp=$(mktemp "$(dirname "$RIX_FLEET_RR_FILE")/.rix_fleet_rr.XXXXXX")
  { [[ -s $RIX_FLEET_RR_FILE ]] && cat "$RIX_FLEET_RR_FILE" || printf '{}'; } \
    | jq --arg k "$key" --argjson v "$(( cur + 1 ))" '.[$k] = $v' >"$tmp" && mv -f "$tmp" "$RIX_FLEET_RR_FILE"
  printf '%s' "$(( cur % count ))"
}

# rix_fleet_pick_backend [ROLE] [IP_CLASS] -> one JSON object on stdout:
#   {backend, model, profile, role, ip_class, cost_class}
# `model` is the fleet target's own model override (e.g. rix-opus's
# claude-opus-5), or null when the backend's own default model applies --
# callers should use it only when the caller didn't already pass --model.
# No ready, eligible target -> prints nothing to stdout, one reason line to
# stderr, returns 1 (so `pick=$(rix_fleet_pick_backend ...) || fail "..."`
# reads cleanly at the call site, same convention as `backend_resolve`).
rix_fleet_pick_backend() {
  local role=${1:-coding} ip_class=${2:-protected}
  case "$role" in coding|reasoning) ;; *) warn "rix fleet: unknown role '$role' (coding|reasoning)"; return 1 ;; esac
  case "$ip_class" in protected|open) ;; *) warn "rix fleet: unknown ip_class '$ip_class' (protected|open)"; return 1 ;; esac

  local -a safe=() overflow=()
  local row rbackend rprofile rrole rmodel
  for row in "${RIX_FLEET_TARGETS[@]}"; do
    IFS='|' read -r rbackend rprofile rrole rmodel <<<"$row"
    [[ $rrole == "$role" ]] || continue
    if [[ $rbackend == deepseek ]]; then overflow+=("$row"); else safe+=("$row"); fi
  done
  if (( ${#safe[@]} == 0 )) && { (( ${#overflow[@]} == 0 )) || [[ $ip_class != open ]]; }; then
    warn "rix fleet: no fleet target for role=$role ip_class=$ip_class"
    return 1
  fi

  # Subscription-first (P0.1 routing.md §3): collect the ready ip-safe
  # candidates first and, if any exist, round-robin over ONLY those --
  # DeepSeek must never be folded into the same rotation as an equal peer,
  # or it would win its regular turn on protected AND open nodes alike
  # instead of staying overflow. Only when every safe candidate is unready
  # (and ip_class == open, so a non-ip-safe session is even allowed) do we
  # fall through to DeepSeek at all -- a separate round-robin key, so a
  # human alternating between "nothing ready" and "ready again" doesn't
  # perturb the safe rotation's own cursor.
  local -a ready=() ready_profiles=() ready_models=(); local rr_key=''
  for row in "${safe[@]}"; do
    IFS='|' read -r rbackend rprofile rrole rmodel <<<"$row"
    local b; b=$(backend_get "$rbackend" 2>/dev/null) || continue
    [[ $(jq -r '.ready // false' <<<"$b" 2>/dev/null) == true ]] || continue
    ready+=("$rbackend"); ready_profiles+=("$rprofile"); ready_models+=("$rmodel")
  done
  if (( ${#ready[@]} )); then
    rr_key="rr:$role:$ip_class:safe"
  elif [[ $ip_class == open ]]; then
    for row in "${overflow[@]}"; do
      IFS='|' read -r rbackend rprofile rrole rmodel <<<"$row"
      local b; b=$(backend_get "$rbackend" 2>/dev/null) || continue
      [[ $(jq -r '.ready // false' <<<"$b" 2>/dev/null) == true ]] || continue
      ready+=("$rbackend"); ready_profiles+=("$rprofile"); ready_models+=("$rmodel")
    done
    rr_key="rr:$role:$ip_class:overflow"
  fi
  if (( ${#ready[@]} == 0 )); then
    warn "rix fleet: no ready backend for role=$role ip_class=$ip_class (needs sign-in -- see: omarchy-agent-launcher backends list, or pass --backend explicitly)"
    return 1
  fi

  local idx; idx=$(_rix_fleet_rr_next "$rr_key" "${#ready[@]}")
  local backend=${ready[idx]} profile=${ready_profiles[idx]} model=${ready_models[idx]}
  local class; class=$(harness_backend_cost_class "$backend")
  jq -nc --arg backend "$backend" --arg model "$model" --arg profile "$profile" \
    --arg role "$role" --arg ip_class "$ip_class" --arg cost_class "$class" \
    '{backend:$backend, model:(if $model=="" then null else $model end),
      profile:$profile, role:$role, ip_class:$ip_class, cost_class:$cost_class}'
}
