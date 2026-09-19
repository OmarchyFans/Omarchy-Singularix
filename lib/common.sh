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

# ---- agent windows ---------------------------------------------------------
# Every agent session runs inside a tmux session named oal-<name>, shown in a
# terminal window titled "Agent · <name> · <model> @ <backend>" with app-id
# org.omarchy.agent (the class Omarchy's own `omarchy agent` uses, so users'
# window rules apply). Closing the window only detaches: the sign-in prompt
# or the chat keeps running, and opening the agent again focuses the window
# or reattaches.
# The model/backend suffix is folded in here (not appended separately at the
# call sites) because window_address()/window_address_by_title() and bin's
# own window lookup all match a window by recomputing this same string, and
# tmux is pinned to drive the terminal's live title to this exact value
# (see open_agent_window) so a user's own tmux title-format config can never
# hide the window from that lookup. The model/backend in it are the LIVE ones
# (agent_field_now), not the profile's: when a pick changed the profile under an
# open window, this lookup stopped matching and Chat opened a second window onto
# the very session whose model it claimed to have changed (2026-09-19).
# ---- what a LIVE session is actually running --------------------------------
# A profile is what the agent will run NEXT time. It is not what a session that
# is already up is running: `rix setup` (or any backend change) rewrites the
# profile, but the Hermes process keeps the config.yaml it was provisioned with
# until it restarts. Every label used to read the profile, so on 2026-09-19 the
# user picked gpt-6-astra, the tmux bar said astra, and Hermes underneath was
# still on local Qwen -- with the harness told astra too.
#
# So `session` stamps what it actually provisioned, and every label, the status
# document and harness_resync_profile read the stamp while the session is alive.
# Expanded at call time, not here: lib/events.sh sets OAL_STATE and is sourced
# after this file.
run_stamp_dir()  { printf '%s/running' "$OAL_STATE"; }
run_stamp_path() { printf '%s/running/%s.json' "$OAL_STATE" "$1"; }
# Record what this session is running. Called from session_run_once right after
# prepare_session (agent_provision) has written the agent's real config.
run_stamp_write() { # run_stamp_write <name>
  local name=$1
  local dir; dir=$(run_stamp_dir)
  mkdir -p "$dir" 2>/dev/null || return 0
  local tmp; tmp=$(mktemp "$dir/.stamp.XXXXXX" 2>/dev/null) || return 0
  jq -nc --arg provider "$(profile_get "$name" provider)" --arg model "$(profile_get "$name" model)" \
     --arg backend "$(profile_get "$name" backend)" --arg started "$(date -Is)" \
     '{provider:$provider, model:$model, backend:$backend, started:$started}' >"$tmp" 2>/dev/null \
    && mv -f "$tmp" "$(run_stamp_path "$name")" || rm -f "$tmp"
}
run_stamp_clear() { rm -f "$(run_stamp_path "$1")" 2>/dev/null || true; }
# The stamp only speaks for a session that is still up; a leftover from a crash
# must never outrank the profile.
run_stamp_get() { # run_stamp_get <name> <key>
  local f; f=$(run_stamp_path "$1")
  [[ -f $f ]] && session_alive "$1" || return 1
  local v; v=$(jq -r --arg k "$2" '.[$k] // empty' "$f" 2>/dev/null) || return 1
  [[ -n $v ]] || return 1
  printf '%s' "$v"
}
# Field of a live session if we know it, else the profile's (what it will use next).
agent_field_now() { # agent_field_now <name> <key>
  run_stamp_get "$1" "$2" || profile_get "$1" "$2"
}
# True when a live session is running something other than what the profile now says.
agent_change_pending() { # agent_change_pending <name>
  local rm rb
  rm=$(run_stamp_get "$1" model) || return 1
  rb=$(run_stamp_get "$1" backend) || rb=""
  [[ $rm != "$(profile_get "$1" model)" || $rb != "$(profile_get "$1" backend)" ]]
}

window_title() { printf 'Agent · %s · %s @ %s' "$1" "$(tmux_model_short "$(agent_field_now "$1" model)")" "$(tmux_backend_short "$1")"; }
tmux_session() { printf 'oal-%s' "$1"; }
# Each agent gets its own tmux server on a socket under the launcher's state
# directory. Session names are global on the default server, so anything else
# using tmux (a test run with a temporary config, another launcher config,
# the user's own tmux) could see or kill an agent's session by name; and with
# Omarchy's `detach-on-destroy off`, a window whose session ends would switch
# to another agent's session. A private server per agent rules both out.
tmux_socket() { printf '%s/tmux/%s.sock' "${OAL_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-agent-launcher}" "$(tmux_session "$1")"; }
tmux_for() { # tmux_for <name> <tmux args...>
  local name=$1; shift
  mkdir -p "$(dirname "$(tmux_socket "$name")")"
  tmux -S "$(tmux_socket "$name")" "$@"
}

# ---- tmux status line: which model an agent is running -------------------
# The tmux default status line only shows window index + cwd basename and
# the hostname (e.g. "1:demo_repo" ... "on milton"), which is the same on
# every agent. These fill it in with the profile's model and backend/provider
# instead, on the agent's own private server only (never the user's default
# tmux server) so the user's tmux theme colours are left untouched.
#
# Strip a leading vendor path ("anthropic/claude-sonnet-5" -> "claude-sonnet-5"),
# a ".gguf" extension, and a trailing quantisation suffix ("-Q4_K_M", "-f16").
tmux_model_short() { # tmux_model_short <model>
  local m=$1
  m=${m##*/}
  m=${m%.gguf}
  m=$(sed -E 's/-[Qq][0-9]+(_[A-Za-z0-9]+)*$//; s/-[Ff]16$//' <<<"$m")
  printf '%s' "$m"
}
# Backend/provider label for the status line: the resolved backend id if the
# profile has one (endpoint backends, or "local"), else its provider id.
tmux_backend_short() { # tmux_backend_short <name>
  local name=$1 backend; backend=$(agent_field_now "$name" backend)
  [[ -n $backend ]] || backend=$(agent_field_now "$name" provider)
  printf '%s' "${backend:-?}"
}
tmux_status_left() { # tmux_status_left <name> -> "<name> · <model> @ <backend>"
  local name=$1 model; model=$(tmux_model_short "$(agent_field_now "$name" model)")
  printf '%s · %s @ %s' "$(tmux_escape_format "$name")" "$(tmux_escape_format "${model:-?}")" "$(tmux_escape_format "$(tmux_backend_short "$name")")"
}
# <task title (harness delegates) or job title> · %H:%M (tmux expands %H:%M
# itself: status-right is run through strftime, and both status strings go
# through tmux's own format parser, so a literal "#" or "%" in free text
# (a job title, in particular) must be doubled or it is read as a tmux
# format/command substitution, not shown as-is).
tmux_escape_format() { sed 's/#/##/g; s/%/%%/g' <<<"$1"; }
tmux_status_right() { # tmux_status_right <name>
  local name=$1 tt; tt=$(profile_get "$name" task_title)
  [[ -n $tt ]] || tt=$(job_title "$name")
  printf '%s · %%H:%%M' "$(tmux_escape_format "${tt:-$name}")"
}
tmux_window_name() { # tmux_window_name <name> -> "<model>@<backend>"
  local name=$1 model; model=$(tmux_model_short "$(agent_field_now "$name" model)")
  printf '%s@%s' "${model:-$name}" "$(tmux_backend_short "$name")"
}
# Push the status line + window name onto a name's tmux server, if its
# session is already up. Safe to call whenever (a no-op otherwise); called
# both right after the session is created (open_agent_window, below) and
# again whenever `session` (re)starts an agent's chat, so a long-lived server
# picks up a profile change (agent_provision in lib/agents/hermes.sh).
tmux_apply_status() { # tmux_apply_status <name>
  have tmux || return 0
  session_alive "$1" || return 0
  local name=$1 session; session=$(tmux_session "$name")
  tmux_for "$name" \
    set-option -t "$session" status-left "$(tmux_status_left "$name")" \
    ";" set-option status-right "$(tmux_status_right "$name")" \
    ";" set-option status-left-length 60 \
    ";" set-option status-right-length 60 \
    ";" rename-window "$(tmux_window_name "$name")" \
    >/dev/null 2>&1 || true
}
window_address() {
  have hyprctl || return 0
  hyprctl clients -j 2>/dev/null | jq -r --arg t "$(window_title "$1")" \
    '.[] | select(.class=="org.omarchy.agent" and (.initialTitle==$t or .title==$t)) | .address' | head -n1
}
# Address of any window whose current or initial title is exactly TITLE.
window_address_by_title() {
  have hyprctl || return 0
  hyprctl clients -j 2>/dev/null | jq -r --arg t "$1" '.[] | select(.initialTitle==$t or .title==$t) | .address' | head -n1
}
# Focus a window by address, switching to its workspace. Hyprland's dispatch is
# Lua on current Omarchy (`hl.dsp.focus`); the old `focuswindow address:` form is
# rejected there, and a rejected dispatch can still exit 0, so check the effect
# and only then try the old form for older Hyprland builds.
focus_address() { # focus_address <address>
  local addr=$1
  if (( OAL_DRY_RUN )); then run hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })"; return 0; fi
  have hyprctl || return 1
  hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >/dev/null 2>&1 || true
  [[ $(hyprctl activewindow -j 2>/dev/null | jq -r '.address // ""') == "$addr" ]] && return 0
  hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1 || true
  [[ $(hyprctl activewindow -j 2>/dev/null | jq -r '.address // ""') == "$addr" ]]
}
session_alive() { have tmux && tmux_for "$1" has-session -t "$(tmux_session "$1")" 2>/dev/null; }

# Focus the agent's window if it is open; otherwise open a terminal attached
# to its tmux session (created on demand around `<launcher> session <name>`).
open_agent_window() { # open_agent_window <name>
  local name=$1 addr
  addr=$(window_address "$name")
  if [[ -n $addr ]]; then
    focus_address "$addr" || warn "could not focus the window for $name ($addr)"
    return 0
  fi
  local -a inner
  if have tmux; then
    mkdir -p "$(dirname "$(tmux_socket "$name")")"
    # tmux retitles its terminal (set-titles, often '#h:#W' in the user's config),
    # which would hide the window from window_address and make every Chat open a
    # duplicate. Pin the title on this agent's private server only.
    inner=(tmux -S "$(tmux_socket "$name")" new-session -A -s "$(tmux_session "$name")" -- "$OAL_SELF" session "$name"
           ";" set-option -g set-titles on ";" set-option -g set-titles-string "$(window_title "$name")"
           ";" set-option -t "$(tmux_session "$name")" status-left "$(tmux_status_left "$name")"
           ";" set-option status-right "$(tmux_status_right "$name")"
           ";" set-option status-left-length 60
           ";" set-option status-right-length 60
           ";" rename-window "$(tmux_window_name "$name")")
  else
    warn "tmux not found; the session will not survive closing its window (omarchy pkg add tmux)"
    inner=("$OAL_SELF" session "$name")
  fi
  if (( OAL_DRY_RUN )); then say "[dry-run] would open window '$(window_title "$name")':"; show_cmd "${inner[@]}"; return 0; fi
  have xdg-terminal-exec || fail "xdg-terminal-exec not found; run inline instead: $OAL_SELF --inline launch $name"
  local -a launch=(xdg-terminal-exec "--app-id=org.omarchy.agent" "--title=$(window_title "$name")" -e "${inner[@]}")
  if have uwsm-app; then setsid uwsm-app -- "${launch[@]}" >/dev/null 2>&1 </dev/null &
  else setsid "${launch[@]}" >/dev/null 2>&1 </dev/null & fi
  disown 2>/dev/null || true
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

# First non-empty line of the job description, without a leading "#".
job_title() { sed -n '/[^[:space:]]/{s/^#\+[[:space:]]*//;p;q}' "$(job_path "$1")" 2>/dev/null | cut -c1-120; }

# Kill the agent's tmux session (the window closes with it; its private server exits with its last session).
session_kill() { have tmux && tmux_for "$1" kill-session -t "$(tmux_session "$1")" 2>/dev/null; }

# Agents that keep a task board override this (hermes: kanban). JSON array.
agent_tasks_json() { printf '[]'; }

profile_summary() { # one line for menus
  jq -r '"\(.name)  ·  \(.agent) · \(.runtime) · \(.provider)/\(.model) · \(.mode)"' "$(profile_path "$1")"
}

# ------------------------------------------------------------- utilities ----
# shellcheck source=/dev/null
load_agent()   { source "$OAL_LIB/agents/$1.sh"; }
# shellcheck source=/dev/null
load_runtime() { source "$OAL_LIB/runtimes/$1.sh"; }

# Kickoff message every session starts with; the job itself is in the agent's
# system prompt / workspace instructions.
KICKOFF_INTERACTIVE="Read your job description in your instructions. Introduce yourself in two sentences, list the first three steps you will take, then begin."
KICKOFF_UNATTENDED="Carry out the job described in your instructions now, end to end. Report what you did and anything that still needs a human."
