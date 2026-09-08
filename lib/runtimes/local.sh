#!/bin/bash
# Local runtime: run the agent binary on this machine, in its own home dir.

RUNTIME_LABEL="local shell"

rt_check() { agent_available_local && { say "$AGENT_LABEL installed"; return 0; }; say "$AGENT_LABEL not installed"; return 1; }
rt_prepare() { :; }

rt_env_cmd() { # rt_env_cmd <name> <args...> -> prints command words, one per line
  local name=$1; shift
  printf '%s\n' env
  agent_local_env "$name"
  printf '%s\n' "$AGENT_BIN" "$@"
}

rt_oauth() { # interactive, in the current terminal (opens a browser)
  local -a args cmd; mapfile -t args < <(agent_oauth_args "$1" 0)
  mapfile -t cmd < <(rt_env_cmd "$1" "${args[@]}")
  run "${cmd[@]}"
}

rt_launch() { # rt_launch <name> <inline:0|1>
  local -a args cmd; mapfile -t args < <(agent_launch_args "$1")
  mapfile -t cmd < <(rt_env_cmd "$1" "${args[@]}")
  local floating=0; [[ $(profile_get "$1" mode) == unattended ]] && floating=1
  launch_session "$2" "$floating" "${cmd[@]}"
}

rt_destroy() { :; }
