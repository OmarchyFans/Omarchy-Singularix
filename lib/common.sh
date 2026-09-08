#!/bin/bash
# Shared helpers for the Agent Launcher. Sourced by bin/omarchy-agent-launcher.
# Everything here is plain bash + jq + gum; nothing is downloaded or executed
# from the network by this file.

OAL_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-agent-launcher"
OAL_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-agent-launcher"
OAL_PROFILES="$OAL_CONF/agents"      # <name>.json (settings) + <name>.job.md (job description)
OAL_SECRETS="$OAL_CONF/secrets.env"  # KEY=value, mode 0600, shared across agents
OAL_DRY_RUN=${OAL_DRY_RUN:-0}

# ---------------------------------------------------------------- output ----
say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf 'agent-launcher: %s\n' "$*" >&2; }
fail() { warn "$*"; exit 1; }
hr()   { printf '\n'; }

# Run a provisioning command, or print it under --dry-run.
run() {
  if (( OAL_DRY_RUN )); then
    printf '[dry-run] %q' "$1"; printf ' %q' "${@:2}"; printf '\n'
    return 0
  fi
  "$@"
}

# Print a command the way run() would, without executing (for summaries).
show_cmd() { printf '  $ %q' "$1"; printf ' %q' "${@:2}"; printf '\n'; }

# Launch an interactive session in its own terminal window. Sessions share the
# org.omarchy.agent app-id with Omarchy's own `omarchy-agent`, so users' window
# rules for agent windows apply here too. --inline runs in the current terminal.
launch_session() { # launch_session <inline:0|1> <floating:0|1> <cmd...>
  local inline=$1 floating=$2; shift 2
  if (( OAL_DRY_RUN )); then
    say "[dry-run] would launch:"; show_cmd "$@"; return 0
  fi
  if (( inline )); then
    exec "$@"
  elif (( floating )); then
    # Presented terminal: shows the Omarchy logo, runs the job, waits on the
    # "done" screen so unattended output stays readable.
    local quoted; quoted=$(printf '%q ' "$@")
    exec omarchy-launch-floating-terminal-with-presentation "$quoted"
  else
    exec omarchy-launch-tui --app-id=org.omarchy.agent "$@"
  fi
}

# ------------------------------------------------------------------ gum ----
have() { command -v "$1" >/dev/null 2>&1; }
need() { local c; for c in "$@"; do have "$c" || fail "missing required tool: $c"; done; }

choose()  { gum choose --header "$1" "${@:2}"; }                 # single
choose_many() { gum choose --no-limit --header "$1" "${@:2}"; }  # checkboxes
ask()     { gum input --header "$1" --placeholder "${2:-}" --value "${3:-}"; }
ask_secret() { gum input --password --header "$1" --placeholder "${2:-}"; }
confirm() { gum confirm "$1"; }
title()   { gum style --bold --foreground 212 "$1"; }

# ---------------------------------------------------------------- names ----
slugify() { # lowercase, [a-z0-9-], collapsed
  local s; s=$(tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  printf '%s' "${s:0:40}"
}

# -------------------------------------------------------------- secrets ----
secrets_init() { mkdir -p "$OAL_CONF"; [[ -f $OAL_SECRETS ]] || { : >"$OAL_SECRETS"; chmod 600 "$OAL_SECRETS"; }; }
secret_get() { # secret_get VAR -> value or empty
  secrets_init
  sed -n "s/^$1=//p" "$OAL_SECRETS" | head -n1
}
secret_set() { # secret_set VAR VALUE
  secrets_init
  local tmp; tmp=$(mktemp "$OAL_CONF/.secrets.XXXXXX")
  grep -v "^$1=" "$OAL_SECRETS" >"$tmp" || true
  printf '%s=%s\n' "$1" "$2" >>"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$OAL_SECRETS"
}

# Write a 0600 env file with exactly one variable (for docker --env-file etc.).
write_env_file() { # write_env_file <path> VAR VALUE
  [[ -n $2 ]] || { : >"$1"; chmod 600 "$1"; return; }
  ( umask 077; printf '%s=%s\n' "$2" "$3" >"$1" )
}

# ------------------------------------------------------------- profiles ----
profile_path() { printf '%s/%s.json' "$OAL_PROFILES" "$1"; }
job_path()     { printf '%s/%s.job.md' "$OAL_PROFILES" "$1"; }
stage_dir()    { printf '%s/agents/%s' "$OAL_DATA" "$1"; }

profile_exists() { [[ -f $(profile_path "$1") ]]; }
profile_list()   { [[ -d $OAL_PROFILES ]] || return 0; find "$OAL_PROFILES" -maxdepth 1 -name '*.json' -printf '%f\n' | sed 's/\.json$//' | sort; }
profile_get()    { jq -r --arg k "$2" '.[$k] // empty' "$(profile_path "$1")"; }
profile_skills() { jq -r '.skills[]? // empty' "$(profile_path "$1")"; }
profile_set()    { # profile_set <name> <key> <json-value>
  local p; p=$(profile_path "$1"); local tmp; tmp=$(mktemp "$OAL_PROFILES/.tmp.XXXXXX")
  jq --arg k "$2" --argjson v "$3" '.[$k]=$v' "$p" >"$tmp" && mv -f "$tmp" "$p"
}

# profile_write <name> <agent> <runtime> <provider> <auth> <model> <base_url> <mode> <skills-newline-list>
profile_write() {
  mkdir -p "$OAL_PROFILES"
  local skills_json; skills_json=$(printf '%s\n' "$9" | sed '/^$/d' | jq -R . | jq -s .)
  jq -n --arg name "$1" --arg agent "$2" --arg runtime "$3" --arg provider "$4" \
        --arg auth "$5" --arg model "$6" --arg base_url "$7" --arg mode "$8" \
        --argjson skills "$skills_json" --arg created "$(date -Is)" \
        '{name:$name, agent:$agent, runtime:$runtime, provider:$provider, auth:$auth,
          model:$model, base_url:$base_url, mode:$mode, skills:$skills, created:$created}' \
     >"$(profile_path "$1")"
}

profile_summary() { # one line for menus
  jq -r '"\(.name)  ·  \(.agent) · \(.runtime) · \(.provider)/\(.model) · \(.mode)"' "$(profile_path "$1")"
}

# ------------------------------------------------------------- utilities ----
load_agent()   { source "$OAL_LIB/agents/$1.sh"; }
load_runtime() { source "$OAL_LIB/runtimes/$1.sh"; }

# Kickoff message every session starts with; the job itself is in the agent's
# system prompt / workspace instructions.
KICKOFF_INTERACTIVE="Read your job description in your instructions. Introduce yourself in two sentences, list the first three steps you will take, then begin."
KICKOFF_UNATTENDED="Carry out the job described in your instructions now, end to end. Report what you did and anything that still needs a human."
