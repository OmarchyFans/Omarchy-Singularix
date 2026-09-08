#!/bin/bash
# Docker runtime: run the agent's official image with the agent home mounted.
#
# Omarchy keeps users out of the root-equivalent docker group by default and
# reaches the daemon through sudo instead; `omarchy-sudo-docker` answers
# whether that is needed here. The form runs in a terminal, so a password
# prompt is fine.

RUNTIME_LABEL="Docker container"

docker_needs_sudo() {
  if have omarchy-sudo-docker; then omarchy-sudo-docker; else [[ ! -w ${OMARCHY_DOCKER_SOCKET:-/var/run/docker.sock} ]]; fi
}
docker_cmd() { if docker_needs_sudo; then printf '%s\n' sudo docker; else printf '%s\n' docker; fi; }

rt_check() {
  have docker || { say "docker not installed (omarchy install docker)"; return 1; }
  if docker_needs_sudo; then say "docker via sudo"; else say "docker ready"; fi
}
rt_prepare() { :; }   # the image is pulled on first `docker run`

container_name() { printf 'oal-%s' "$1"; }

rt_run_cmd() { # rt_run_cmd <name> <args...> -> command words, one per line
  local name=$1; shift
  docker_cmd
  printf '%s\n' run -it --rm --name "$(container_name "$name")" \
    -v "$(agent_home "$name"):$(agent_docker_home)"
  # A localhost endpoint (Ollama, llama.cpp) lives on the host, not in the container.
  case "$(profile_get "$name" base_url)" in *localhost*|*127.0.0.1*) printf '%s\n' --network host ;; esac
  agent_docker_flags "$name"
  printf '%s\n' "$(agent_docker_image)"
  agent_docker_entry
  printf '%s\n' "$@"
}

rt_oauth() {
  local -a args cmd; mapfile -t args < <(agent_oauth_args "$1" 1)   # no browser inside the container
  mapfile -t cmd < <(rt_run_cmd "$1" "${args[@]}")
  say "Sign-in runs inside the container; open the URL it prints in your browser."
  run "${cmd[@]}"
}

rt_cmd() { # rt_cmd <name> [resume]
  local -a args; mapfile -t args < <(agent_launch_args "$1" "${2:-0}")
  rt_run_cmd "$1" "${args[@]}"
}

rt_destroy() {
  local -a d; mapfile -t d < <(docker_cmd)
  run "${d[@]}" rm -f "$(container_name "$1")" >/dev/null 2>&1 || true
}
