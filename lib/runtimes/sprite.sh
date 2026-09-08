#!/bin/bash
# Fly.io Sprite runtime (https://fly.io/sprites): a persistent, isolated Linux
# VM per agent. Needs the `sprite` CLI and a Sprites API token.
#
# Flow: authenticate the CLI once (browser or token) → create the sprite → run
# the agent's pinned bootstrap script inside it → upload the provisioned agent
# home as a tarball → exec the agent with a TTY. Nothing is piped from the
# network into a shell; Hermes is cloned and checked out at a fixed commit,
# OpenClaw comes from npm.
#
# Sprites facts this relies on (docs.sprites.dev): Ubuntu 25.10, user `sprite`
# with home /home/sprite, sudo + apt available, Node/npm/Python/git preinstalled,
# the filesystem persists while a sprite sleeps when idle, and a `--tty` exec
# session counts as activity that keeps it awake.
#
# STATUS: written against the documented CLI (sprite create/exec/destroy,
# `exec --tty --file --env`); no Sprites account was available while building
# this, so treat it as beta and report issues.

RUNTIME_LABEL="Fly.io Sprite"
SPRITE_INSTALL_HINT="Install the Sprites CLI from https://docs.sprites.dev/quickstart/ and get a token at https://sprites.dev/account"

sprite_name() { local s; s=$(profile_get "$1" sprite); printf '%s' "${s:-oal-$1}"; }

rt_check() {
  have sprite || { say "sprite CLI not installed"; return 1; }
  if sprite_authenticated || [[ -n $(secret_get SPRITES_TOKEN) ]]; then say "sprite CLI signed in"; else say "sprite CLI (sign-in needed)"; fi
}

# Authenticate the CLI once. Already signed in (e.g. via `sprite org auth`
# with your Fly.io account) means nothing to do; otherwise offer the browser
# flow or a pasted API token (https://sprites.dev/account).
sprite_authenticated() { timeout 5 sprite list >/dev/null 2>&1; }   # info --json calls this on every panel open
sprite_ensure_auth() {
  (( OAL_DRY_RUN )) && { info "[dry-run] would verify sprite CLI auth"; return 0; }
  sprite_authenticated && return 0
  local tok; tok=$(secret_get SPRITES_TOKEN)
  if [[ -n $tok ]]; then run sprite auth setup --token "$tok"; sprite_authenticated && return 0; fi
  local pick; pick=$(choose "The Sprites CLI is not signed in. How do you want to authenticate?" \
    "browser  Sign in with your Fly.io account (sprite org auth)" \
    "token    Paste a Sprites API token from https://sprites.dev/account")
  case "${pick%% *}" in
    browser) run sprite org auth ;;
    token)   tok=$(ask_secret "Sprites API token" "org-slug/…"); [[ -n $tok ]] || fail "no token given"
             secret_set SPRITES_TOKEN "$tok"; run sprite auth setup --token "$tok" ;;
    *) exit 130 ;;
  esac
  sprite_authenticated || fail "sprite CLI still not authenticated"
}

sprite_exists() { sprite list --prefix "$1" 2>/dev/null | grep -qw -- "$1"; }

rt_prepare() { # create, bootstrap, upload
  local name=$1 sname; sname=$(sprite_name "$name")
  have sprite || (( OAL_DRY_RUN )) || fail "sprite CLI not installed. $SPRITE_INSTALL_HINT"
  sprite_ensure_auth
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

rt_cmd() { # rt_cmd <name> [resume]
  local sname; sname=$(sprite_name "$1")
  local -a args; mapfile -t args < <(agent_launch_args "$1" "${2:-0}")
  printf '%s\n' sprite exec --tty -s "$sname" -- bash -lc "$(remote_cmd "$AGENT_BIN" "${args[@]}")"
}

rt_console() { run sprite console -s "$(sprite_name "$1")"; }

rt_destroy() {
  local sname; sname=$(sprite_name "$1")
  have sprite || return 0
  run sprite destroy --force "$sname"
}
