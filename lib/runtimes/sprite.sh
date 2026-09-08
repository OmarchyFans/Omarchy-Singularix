#!/bin/bash
# Fly.io Sprite runtime (https://fly.io/sprites): a persistent, isolated Linux
# VM per agent. Needs the `sprite` CLI and a Sprites API token.
#
# Flow: authenticate the CLI once with your token → create the sprite → run
# the agent's pinned bootstrap script inside it → upload the provisioned agent
# home as a tarball → exec the agent with a TTY. Nothing is piped from the
# network into a shell; Hermes is cloned and checked out at a fixed commit,
# OpenClaw comes from npm.
#
# STATUS: written against the documented CLI (sprite create/exec/destroy,
# `exec --tty --file --env`); no Sprites account was available while building
# this, so treat it as beta and report issues.

RUNTIME_LABEL="Fly.io Sprite"
SPRITE_INSTALL_HINT="Install the Sprites CLI from https://docs.sprites.dev/quickstart/ and get a token at https://sprites.dev/account"

sprite_name() { local s; s=$(profile_get "$1" sprite); printf '%s' "${s:-oal-$1}"; }

rt_check() {
  have sprite || { say "sprite CLI not installed"; return 1; }
  if [[ -n $(secret_get SPRITES_TOKEN) ]]; then say "sprite CLI + saved token"; else say "sprite CLI (token needed)"; fi
}

sprite_ensure_token() {
  local tok; tok=$(secret_get SPRITES_TOKEN)
  if [[ -z $tok ]]; then
    say "A Sprites API token is needed (format org/token-id/secret). $SPRITE_INSTALL_HINT"
    tok=$(ask_secret "Sprites API token" "org-slug/…")
    [[ -n $tok ]] || fail "no token given"
    secret_set SPRITES_TOKEN "$tok"
  fi
  run sprite auth setup --token "$tok"
}

sprite_exists() { sprite list --prefix "$1" 2>/dev/null | grep -qw -- "$1"; }

rt_prepare() { # create, bootstrap, upload
  local name=$1 sname; sname=$(sprite_name "$name")
  have sprite || (( OAL_DRY_RUN )) || fail "sprite CLI not installed. $SPRITE_INSTALL_HINT"
  sprite_ensure_token
  profile_set "$name" sprite "\"$sname\""
  if (( OAL_DRY_RUN )) || ! sprite_exists "$sname"; then
    run sprite create --skip-console "$sname"
  else
    info "sprite $sname already exists"
  fi
  local boot; boot=$(agent_sprite_bootstrap)
  run sprite exec -s "$sname" -- bash -lc "$boot"

  local tgz; tgz=$(mktemp --suffix=.tgz)
  if (( OAL_DRY_RUN )); then info "[dry-run] would tar $(agent_home "$name") -> $tgz"; else tar -C "$(agent_home "$name")" -czf "$tgz" .; fi
  local remote; remote=$(agent_sprite_home)
  run sprite exec -s "$sname" --file "$tgz:/tmp/oal-home.tgz" -- \
    bash -lc "mkdir -p $remote && tar -xzf /tmp/oal-home.tgz -C $remote && rm -f /tmp/oal-home.tgz && echo 'agent home uploaded'"
  rm -f "$tgz"
}

remote_cmd() { # remote_cmd <args...> -> one bash -lc string, PATH extended for user installs
  local q; q=$(printf '%q ' "$@")
  printf 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"; %s' "$q"
}

rt_oauth() {
  local sname; sname=$(sprite_name "$1")
  local -a args; mapfile -t args < <(agent_oauth_args "$1" 1)
  say "Sign-in runs inside the sprite; open the URL it prints in your browser."
  run sprite exec --tty -s "$sname" -- bash -lc "$(remote_cmd "$AGENT_BIN" "${args[@]}")"
}

rt_launch() { # rt_launch <name> <inline:0|1>
  local sname; sname=$(sprite_name "$1")
  local -a args; mapfile -t args < <(agent_launch_args "$1")
  local floating=0; [[ $(profile_get "$1" mode) == unattended ]] && floating=1
  launch_session "$2" "$floating" sprite exec --tty -s "$sname" -- bash -lc "$(remote_cmd "$AGENT_BIN" "${args[@]}")"
}

rt_console() { run sprite console -s "$(sprite_name "$1")"; }

rt_destroy() {
  local sname; sname=$(sprite_name "$1")
  have sprite || return 0
  run sprite destroy --force "$sname"
}
