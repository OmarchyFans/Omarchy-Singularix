#!/bin/bash
# Rix: the chief of staff. One Hermes agent (profile "rix", role
# chief-of-staff) that runs on this machine, by default on the local GPU, and
# manages every other agent through this very CLI: it reads `status --json`
# and `usage --json`, hands work to bigger models with `delegate`, reads their
# results with `result`, and can stop or remove agents. Everything Rix can
# do you can do from the dashboard or a terminal; Rix is a user of the CLI,
# not a second control plane.

# Rix was called Jarvis before 0.9. OAL_JARVIS_NAME is still honoured, and
# JARVIS_NAME / jarvis_* stay as aliases for one release so scripts keep working.
RIX_NAME=${OAL_RIX_NAME:-${OAL_JARVIS_NAME:-rix}}
JARVIS_NAME=$RIX_NAME

rix_exists() { profile_exists "$RIX_NAME"; }

# One-time rename of a pre-0.9 "jarvis" chief of staff to "rix": profile, job,
# agent home, worker parents, open blockers, and its tmux server. Past lines in
# events.jsonl keep the old name (they are history). If Jarvis is running, the
# move waits: the running session keeps its name until it is stopped.
rix_migrate() {
  [[ $RIX_NAME == rix ]] || return 0
  profile_exists jarvis || return 0
  profile_exists rix && return 0
  [[ $(profile_get jarvis role 2>/dev/null) == chief-of-staff ]] || return 0
  (( OAL_DRY_RUN )) && return 0
  if session_alive jarvis; then
    warn "Jarvis is now called Rix. Stop the running session to finish the rename: omarchy-agent-launcher stop jarvis"
    RIX_NAME=jarvis; JARVIS_NAME=jarvis
    return 0
  fi
  mv -f "$(profile_path jarvis)" "$(profile_path rix)"
  [[ -f $(job_path jarvis) ]] && mv -f "$(job_path jarvis)" "$(job_path rix)"
  [[ -d $(stage_dir jarvis) && ! -e $(stage_dir rix) ]] && mv "$(stage_dir jarvis)" "$(stage_dir rix)"
  profile_set rix name '"rix"'
  [[ -f $(job_path rix) ]] && sed -i 's/\bJarvis\b/Rix/g; s/\bjarvis\b/rix/g' "$(job_path rix)"
  local soul; soul="$(stage_dir rix)/hermes/SOUL.md"
  [[ -f $soul ]] && sed -i 's/\bJarvis\b/Rix/g; s/"jarvis"/"rix"/g' "$soul"
  local n
  while IFS= read -r n; do
    [[ -n $n && $(profile_get "$n" parent 2>/dev/null) == jarvis ]] && profile_set "$n" parent '"rix"'
  done < <(profile_list)
  if [[ -s $OAL_BLOCKERS ]]; then
    (
      flock -w 5 9 || true
      cp -f "$OAL_BLOCKERS" "$OAL_BLOCKERS.bak"
      local tmp; tmp=$(mktemp "$OAL_BLOCKERS.XXXXXX")
      jq 'with_entries(if .value.agent == "jarvis" then .key |= sub("^jarvis/"; "rix/") | .value.agent = "rix" else . end)' \
        "$OAL_BLOCKERS" >"$tmp" && mv -f "$tmp" "$OAL_BLOCKERS"
    ) 9>"$OAL_EVENTS_LOCK"
  fi
  have tmux && tmux_for jarvis kill-server 2>/dev/null
  rm -f "$(tmux_socket jarvis)"
  event_emit rix note "Jarvis is now called Rix" --task "chief of staff" 2>/dev/null || true
}

# The backend Rix runs on when none is chosen: the local GPU whenever this
# machine has the local llama.cpp server at all (offline, private, $0; if its
# context is still too small, launch raises a blocker that says how to tune it).
# Only without any local server: the first provider you are signed in to.
rix_default_backend() {
  if declare -F local_status_json >/dev/null && local_status_json 2>/dev/null | jq -e '.online or .unit_exists' >/dev/null 2>&1; then echo local; return; fi
  local id
  for id in anthropic openai-codex nous openai openrouter xai gemini deepseek; do
    backend_get "$id" 2>/dev/null | jq -e '.ready' >/dev/null 2>&1 && { echo "$id"; return; }
  done
  echo local
}

rix_job() {
  cat <<'JOB'
# Chief of staff for this Omarchy desktop

You are Rix, the user's chief of staff. You organize their work so they can
hand tasks off and move on. You run on this machine; other agents (workers) run
where you start them. You manage every agent through the `omarchy-agent-launcher`
command (it is on your PATH; the `rix` skill lists the commands).

Standing duties:
1. Know the state: `omarchy-agent-launcher status --json` (agents, blockers, tasks)
   and `omarchy-agent-launcher usage --json` (tokens and USD, total and per task).
2. Brief on request: what is running, what is blocked, what it cost.
3. Delegate work that needs a bigger model or a long run to a worker on the best
   backend (`backends list`, then `delegate`), read its result (`result NAME`),
   and report back. Prefer the cheapest backend that can do the job; say what it
   will cost.
4. Keep the fleet tidy: stop idle sessions, remove finished workers you created.
   Ask before removing anything you did not create.
5. Never spend money silently: before deploying or starting a Modal backend, or
   delegating to a paid model, state the price and wait for a yes.
JOB
}

# Identity file for Rix's Hermes home. rix_soul <name>
rix_soul() {
  cat <<SOUL
# Identity
You are "$1", chief of staff on an Omarchy desktop. Calm, brief, decisive. You
speak in short paragraphs, lead with the answer, and give numbers (tokens, USD)
when you have them. You are the user's memory of what every agent is doing.

# How you work
- Facts come from the launcher: run \`omarchy-agent-launcher status --json\` and
  \`omarchy-agent-launcher usage --json\` rather than guessing.
- You hand off work with \`omarchy-agent-launcher delegate …\` and read it back with
  \`omarchy-agent-launcher result NAME\`. Workers are other agents; you are not one.
- Money needs a yes: state the backend and its price before anything paid starts.
- Post progress for the dashboard:
  omarchy-agent-launcher event "\$OAL_AGENT" note "what happened" [--task NAME]
  omarchy-agent-launcher event "\$OAL_AGENT" blocker "what you need" --level blocker
SOUL
}

# Create (or update) the Rix profile on a backend. rix_setup <backend> [model]
rix_setup() {
  local backend=${1:-$(rix_default_backend)} model=${2:-}
  local r; r=$(backend_resolve "$backend" "$model") || return 1
  local provider auth m base_url
  provider=$(jq -r .provider <<<"$r"); auth=$(jq -r .auth <<<"$r"); m=$(jq -r .model <<<"$r"); base_url=$(jq -r .base_url <<<"$r")
  if [[ -z $m || $m == null ]] && [[ $backend == local ]]; then m="local"; fi   # the local server serves one model; Hermes is told its real name at provisioning
  [[ -n $m && $m != null ]] || fail "backend '$backend' has no default model; pass one: omarchy-agent-launcher rix setup $backend MODEL"
  have hermes || fail "Rix is a Hermes agent and hermes is not installed (see the README)"
  local -a skills=(); [[ -d $HOME/.hermes/skills/productivity/chief-of-staff ]] && skills+=(productivity/chief-of-staff)
  mkdir -p "$OAL_PROFILES"
  local existing_job="" keep_signin=""
  if profile_exists "$RIX_NAME"; then
    [[ -s $(job_path "$RIX_NAME") ]] && existing_job=1
    [[ $(profile_get "$RIX_NAME" provider) == "$provider" && $(profile_get "$RIX_NAME" signed_in) == true ]] && keep_signin=1
  fi
  profile_write "$RIX_NAME" hermes local "$provider" "$auth" "$m" "$base_url" interactive "$(printf '%s\n' "${skills[@]}")"
  [[ -n $keep_signin ]] && profile_set "$RIX_NAME" signed_in true
  profile_set "$RIX_NAME" role '"chief-of-staff"'
  profile_set "$RIX_NAME" backend "$(jq -Rn --arg v "$backend" '$v')"
  [[ -n $existing_job ]] || rix_job >"$(job_path "$RIX_NAME")"
  event_emit "$RIX_NAME" created "Rix set up on $backend/$m" --task "chief of staff"
  if [[ $provider == local ]] && declare -F local_status_json >/dev/null && ! local_status_json | jq -e '.agent_ready' >/dev/null 2>&1; then
    warn "the local GPU server is not ready for agents yet: run  omarchy-agent-launcher local-server tune --ctx 32768  (or pick another backend)"
  fi
  say "Rix runs on $backend / $m  (change with: omarchy-agent-launcher rix setup BACKEND [MODEL])"
}

# Deterministic status brief from the launcher's own data: no model, no cost.
rix_brief() {
  local st us; st=$(cmd_status_json); us=$(usage_json)
  jq -rn --argjson s "$st" --argjson u "$us" --arg j "$RIX_NAME" '
    def usd: if . == null then "$?" else "$" + ((. * 100 | round) / 100 | tostring) end;
    def k: if . >= 1000000 then "\((. / 100000 | round) / 10)M" elif . >= 1000 then "\((. / 100 | round) / 10)K" else tostring end;
    ($s.agents | map(select(.name != $j))) as $a
    | "Rix brief · \(now | strftime("%Y-%m-%d %H:%M"))",
      "  \($a | length) agent(s): \($a | map(select(.running)) | length) running · \($a | map(select(.status == "blocked")) | length) blocked · \($a | map(select(.status == "done")) | length) done",
      "  Usage: \($u.totals.prompt | k) prompt + \($u.totals.output | k) output tokens · \($u.totals.cost_usd | usd) total · today \($u.totals.today_cost_usd | usd)",
      "",
      "Needs you:",
      (if ($s.blockers // 0) == 0 then "  nothing" else ($a[] | .open_blockers[]? | "  \(.agent): \(.message)") end),
      "",
      "Agents:",
      (if ($a | length) == 0 then "  none yet (omarchy-agent-launcher delegate … or the New agent page)" else
        ($a[] | "  \(.name)\t\(.status)\t\(.backend // .provider)/\(.model)\t\(.job_title[:50])" + (if .last then "\t\(.last.message[:60])" else "" end)) end)' | column -t -s $'\t'
}

# One question to Rix, answered in its own home, no window (for scripts and the dashboard).
rix_ask() { # rix_ask "<question>"
  rix_exists || fail "Rix is not set up yet: omarchy-agent-launcher rix setup"
  load_profile_adapters "$RIX_NAME"
  # No window here, so no browser sign-in can happen: provisioning may inherit one, else say so.
  agent_provision "$RIX_NAME" >/dev/null 2>&1 || true
  if [[ $(profile_get "$RIX_NAME" auth) == oauth && $(profile_get "$RIX_NAME" signed_in) != true ]]; then
    fail "Rix is not signed in to $(provider_label "$(profile_get "$RIX_NAME" provider)") yet: open its chat once (omarchy-agent-launcher rix) to sign in"
  fi
  prepare_session "$RIX_NAME" >/dev/null 2>&1 || true
  local -a cmd; mapfile -t cmd < <(rt_env_cmd "$RIX_NAME" chat -s rix -Q --oneshot --run-budget 600 -q "$1")
  export OAL_AGENT="$RIX_NAME" PATH="$OAL_ROOT/bin:$PATH"
  if (( OAL_DRY_RUN )); then say "[dry-run] would ask Rix:"; show_cmd "${cmd[@]}"; return 0; fi
  "${cmd[@]}"
}

rix_status_json() {
  local running=false model="" backend="" provider=""
  if rix_exists; then
    session_alive "$RIX_NAME" && running=true
    model=$(profile_get "$RIX_NAME" model); backend=$(profile_get "$RIX_NAME" backend); provider=$(profile_get "$RIX_NAME" provider)
  fi
  jq -nc --arg name "$RIX_NAME" --argjson configured "$(rix_exists && echo true || echo false)" --argjson running "$running" \
    --arg model "$model" --arg backend "${backend:-$provider}" --arg provider "$provider" --arg default "$(rix_default_backend)" \
    --argjson workers "$(profile_list | while IFS= read -r n; do [[ -n $n && $(profile_get "$n" parent 2>/dev/null) == "$RIX_NAME" ]] && echo "$n"; done | jq -R . | jq -sc .)" \
    '{name:$name, configured:$configured, running:$running, model:$model, backend:$backend, provider:$provider, default_backend:$default, workers:$workers}'
}

# Pre-0.9 names, kept for one release.
jarvis_exists()          { rix_exists "$@"; }
jarvis_default_backend() { rix_default_backend "$@"; }
jarvis_job()             { rix_job "$@"; }
jarvis_soul()            { rix_soul "$@"; }
jarvis_setup()           { rix_setup "$@"; }
jarvis_brief()           { rix_brief "$@"; }
jarvis_ask()             { rix_ask "$@"; }
jarvis_status_json()     { rix_status_json "$@"; }
