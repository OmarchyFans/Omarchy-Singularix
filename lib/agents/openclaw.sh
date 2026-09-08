#!/bin/bash
# OpenClaw adapter (https://openclaw.ai).
#
# Every launched agent gets its own OpenClaw state dir under
#   ~/.local/share/omarchy-agent-launcher/agents/<name>/openclaw
# used as OPENCLAW_STATE_DIR locally, mounted at /home/node/.openclaw in the
# official image, and uploaded to ~/.openclaw on a Sprite. The job description
# becomes the workspace AGENTS.md; skills go to <workspace>/skills.
#
# STATUS: built from OpenClaw's documented CLI surface; OpenClaw was not
# installed on the machine this plugin was developed on. Please report issues.

AGENT_BIN=openclaw
AGENT_LABEL="OpenClaw"
OPENCLAW_IMAGE="${OAL_OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"
OPENCLAW_NPM_VERSION="${OAL_OPENCLAW_NPM_VERSION:-latest}"

agent_available_local() { have openclaw; }
agent_install_hint() {
  say "OpenClaw is not installed. Install it with:  npm install -g openclaw@latest --allow-scripts=openclaw   (see https://docs.openclaw.ai/install), then rerun."
}

agent_home() { printf '%s/openclaw' "$(stage_dir "$1")"; }

# Skill names from the user's global OpenClaw skill dirs.
agent_skills_list() {
  local d
  for d in "$HOME/.openclaw/skills" "$HOME/.openclaw/workspace/skills"; do
    [[ -d $d ]] || continue
    find "$d" -mindepth 2 -maxdepth 2 -name SKILL.md -printf '%P\n' 2>/dev/null | sed 's#/SKILL.md$##'
  done | sort -u
}
agent_skill_source() {
  local d
  for d in "$HOME/.openclaw/skills/$1" "$HOME/.openclaw/workspace/skills/$1"; do
    [[ -d $d ]] && { printf '%s' "$d"; return; }
  done
  printf '%s/.openclaw/skills/%s' "$HOME" "$1"
}
agent_skill_short() { printf '%s' "$1"; }

agent_provision() { # agent_provision <name>
  local name=$1 home; home=$(agent_home "$name"); local ws="$home/workspace"
  local provider model base_url auth var key skill
  provider=$(profile_get "$name" provider); model=$(profile_get "$name" model)
  base_url=$(profile_get "$name" base_url); auth=$(profile_get "$name" auth)
  local op; op=$(provider_openclaw "$provider")

  run mkdir -p "$ws/skills" "$ws/memory"
  (( OAL_DRY_RUN )) && { info "[dry-run] would write $home/openclaw.json and $ws/{AGENTS.md,SOUL.md,IDENTITY.md}"; return 0; }
  chmod 700 "$home"

  var=$(provider_env "$provider"); key=""
  [[ $auth == api-key && $var != - ]] && key=$(secret_get "$var")

  # Only documented keys: agents.defaults.model.primary and env.vars.
  jq -n --arg m "$op/$model" --arg var "$var" --arg key "$key" --arg url "$base_url" '
    {agents: {defaults: {model: {primary: $m}}}}
    | if ($key != "" and $var != "-") then .env.vars[$var] = $key else . end
    | if ($url != "-" and $url != "") then .env.vars["OLLAMA_HOST"] = $url else . end
  ' >"$home/openclaw.json"
  chmod 600 "$home/openclaw.json"
  ( umask 077; write_env_file "$home/.oal.env" "$([[ $var != - ]] && printf '%s' "$var")" "$key" )

  cp -f "$(job_path "$name")" "$ws/AGENTS.md"
  [[ -f $ws/SOUL.md ]] || cat >"$ws/SOUL.md" <<SOUL
# Soul
You are "$name", an autonomous agent launched from an Omarchy desktop. Your
job is in AGENTS.md. Be direct, report progress, and ask before doing
anything irreversible.
SOUL
  [[ -f $ws/IDENTITY.md ]] || printf '# Identity\nName: %s\nVibe: focused, concise\nEmoji: 🦞\n' "$name" >"$ws/IDENTITY.md"

  while IFS= read -r skill; do
    [[ -n $skill ]] || continue
    if [[ -d $(agent_skill_source "$skill") ]]; then
      cp -R "$(agent_skill_source "$skill")" "$ws/skills/$skill"
    else
      warn "skill not found locally, skipped: $skill"
    fi
  done < <(profile_skills "$name")
}

agent_oauth_args() { # agent_oauth_args <name> <no_browser>
  local provider; provider=$(profile_get "$1" provider)
  printf '%s\n' models auth login --provider "$(provider_openclaw "$provider")"
  [[ $provider == anthropic ]] && printf '%s\n' --method setup-token
  return 0
}

agent_launch_args() { # agent_launch_args <name> [resume]
  local mode resume=${2:-0}; mode=$(profile_get "$1" mode)
  if (( resume )); then
    printf '%s\n' tui --local
  elif [[ $mode == unattended ]]; then
    printf '%s\n' agent --local --message "$KICKOFF_UNATTENDED"
  else
    printf '%s\n' tui --local --message "$KICKOFF_INTERACTIVE"
  fi
}

agent_local_env() {
  local home; home=$(agent_home "$1")
  printf 'OPENCLAW_STATE_DIR=%s\nOPENCLAW_WORKSPACE_DIR=%s/workspace\n' "$home" "$home"
}

agent_docker_image() { printf '%s' "$OPENCLAW_IMAGE"; }
agent_docker_home()  { printf '/home/node/.openclaw'; }
agent_docker_flags() { printf '%s\n' --env-file "$(agent_home "$1")/.oal.env"; }
agent_docker_entry() { printf '%s\n' node openclaw.mjs; }   # image CMD is `node openclaw.mjs gateway`

agent_sprite_home() { printf '$HOME/.openclaw'; }
agent_sprite_bootstrap() {
  cat <<BOOT
set -e
export PATH="\$HOME/.npm-global/bin:\$HOME/.local/bin:\$PATH"
if ! command -v openclaw >/dev/null 2>&1; then
  echo "== installing OpenClaw (npm openclaw@$OPENCLAW_NPM_VERSION)"
  mkdir -p "\$HOME/.npm-global"
  npm config set prefix "\$HOME/.npm-global"
  npm install -g "openclaw@$OPENCLAW_NPM_VERSION" --allow-scripts=openclaw
fi
openclaw --version || true
BOOT
}
