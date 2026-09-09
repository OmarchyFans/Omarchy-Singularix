#!/bin/bash
# Centrally-editable model fallback policy shared across every agent.
#
# One JSON file holds one or more NAMED ordered chains of {provider, model,
# note}. Any agent profile can opt in to a chain via the profile field
# "fallback_chain": "<name>"; agent_provision (lib/agents/hermes.sh) reads it
# and emits Hermes's native top-level `fallback_providers:` config.yaml key
# from it. Editing a chain here and re-provisioning every agent that
# references it is the only way a change takes effect (same
# profile -> provision -> config.yaml pattern as everything else in this
# codebase — see the omarchy-agent-launcher-dev skill).
#
# Why a *shared* file instead of per-agent hand-set fallback_providers: the
# user's accounts and which model currently wins change week to week across
# many vendors; a fallback chain hand-copied into N agents' profiles drifts
# out of sync the first time anyone updates it in only one place.

FALLBACK_POLICY_PATH="$OAL_CONF/fallback-policy.json"

fallback_policy_ensure() {
  [[ -s $FALLBACK_POLICY_PATH ]] && return 0
  mkdir -p "$OAL_CONF"
  printf '{}' >"$FALLBACK_POLICY_PATH"
}

# All chain names. fallback_chains_list
fallback_chains_list() { fallback_policy_ensure; jq -r 'keys[]' "$FALLBACK_POLICY_PATH"; }

# The chain as a JSON array (possibly empty). fallback_chain_json <name>
fallback_chain_json() { fallback_policy_ensure; jq -c --arg n "$1" '.[$n] // []' "$FALLBACK_POLICY_PATH"; }

fallback_chain_exists() { [[ $(fallback_chain_json "$1") != "[]" ]] || fallback_policy_ensure && jq -e --arg n "$1" 'has($n)' "$FALLBACK_POLICY_PATH" >/dev/null 2>&1; }

# Human table for one chain, or all chains when no argument. fallback_print [name]
fallback_print() {
  fallback_policy_ensure
  if [[ -n ${1:-} ]]; then
    jq -r --arg n "$1" '.[$n] // [] | to_entries[] | "\(.key)\t\(.value.provider)\t\(.value.model)\t\(.value.note // "")"' "$FALLBACK_POLICY_PATH" | column -t -s $'\t'
  else
    jq -r 'to_entries[] | "\(.key):"' "$FALLBACK_POLICY_PATH" | while IFS= read -r chain; do
      say "$chain"
      fallback_print "${chain%:}"
      echo
    done
  fi
}

# Every profile name whose fallback_chain field equals <chain>. fallback_agents_using <chain>
fallback_agents_using() {
  local chain=$1 n
  while IFS= read -r n; do
    [[ -n $n ]] || continue
    [[ $(profile_get "$n" fallback_chain) == "$chain" ]] && echo "$n"
  done < <(profile_list)
}

# Re-provision (and note) every agent using a chain, after editing it. fallback_reprovision_affected <chain>
fallback_reprovision_affected() {
  local chain=$1 n any=0
  while IFS= read -r n; do
    [[ -n $n ]] || continue
    any=1
    declare -F agent_provision >/dev/null && agent_provision "$n"
    say "  re-provisioned $n"
  done < <(fallback_agents_using "$chain")
  (( any )) || info "no agent currently uses fallback chain '$chain'"
}

# fallback add <chain> <provider> <model> [note] [--index N]
cmd_fallback_add() {
  local chain=$1 provider=$2 model=$3 note=${4:-}; shift $(( $# >= 4 ? 4 : 3 ))
  local idx=""; while (( $# )); do case $1 in --index) idx=$2; shift 2 ;; *) shift ;; esac; done
  provider_field "$provider" 1 >/dev/null 2>&1 || fail "fallback add: unknown provider '$provider' (see: omarchy-agent-launcher providers list)"
  fallback_policy_ensure
  local tmp; tmp=$(mktemp "$OAL_PROFILES/.tmp.XXXXXX" 2>/dev/null || mktemp)
  jq --arg n "$chain" --arg p "$provider" --arg m "$model" --arg note "$note" --arg idx "${idx:--1}" '
    (.[$n] // []) as $c
    | ($idx | tonumber) as $i
    | {provider:$p, model:$m, note:$note} as $entry
    | .[$n] = (if $i < 0 then $c + [$entry] else ($c[0:$i] + [$entry] + $c[$i:]) end)
  ' "$FALLBACK_POLICY_PATH" >"$tmp" && mv -f "$tmp" "$FALLBACK_POLICY_PATH"
  say "added $provider/$model to chain '$chain'"
  fallback_reprovision_affected "$chain"
}

# fallback remove <chain> <index>
cmd_fallback_remove() {
  local chain=$1 idx=$2
  fallback_policy_ensure
  local tmp; tmp=$(mktemp "$OAL_PROFILES/.tmp.XXXXXX" 2>/dev/null || mktemp)
  jq --arg n "$chain" --argjson i "$idx" '.[$n] = ((.[$n] // []) | del(.[$i]))' "$FALLBACK_POLICY_PATH" >"$tmp" && mv -f "$tmp" "$FALLBACK_POLICY_PATH"
  say "removed entry $idx from chain '$chain'"
  fallback_reprovision_affected "$chain"
}

# fallback reorder <chain> <from-index> <to-index>
cmd_fallback_reorder() {
  local chain=$1 from=$2 to=$3
  fallback_policy_ensure
  local tmp; tmp=$(mktemp "$OAL_PROFILES/.tmp.XXXXXX" 2>/dev/null || mktemp)
  jq --arg n "$chain" --argjson f "$from" --argjson t "$to" '
    (.[$n] // []) as $c
    | ($c[$f]) as $item
    | ($c[0:$f] + $c[$f+1:]) as $without
    | .[$n] = ($without[0:$t] + [$item] + $without[$t:])
  ' "$FALLBACK_POLICY_PATH" >"$tmp" && mv -f "$tmp" "$FALLBACK_POLICY_PATH"
  say "moved entry $from -> $to in chain '$chain'"
  fallback_reprovision_affected "$chain"
}

cmd_fallback() {
  case "${1:-list}" in
    list|ls) fallback_print "${2:-}" ;;
    add)     shift; cmd_fallback_add "$@" ;;
    remove|rm) shift; cmd_fallback_remove "$@" ;;
    reorder) shift; cmd_fallback_reorder "$@" ;;
    *) fail "fallback: unknown subcommand '$1' (list|add|remove|reorder)" ;;
  esac
}

# The Hermes `fallback_providers:` YAML block for one agent, or nothing if it
# has no fallback_chain set or the chain is empty. Skips a chain entry that
# exactly matches the agent's own primary provider+model (no redundant
# self-fallback as the first hop). fallback_providers_yaml <chain> <own-provider> <own-model>
fallback_providers_yaml() {
  local chain=$1 own_provider=$2 own_model=$3
  [[ -n $chain ]] || return 0
  local entries; entries=$(fallback_chain_json "$chain")
  [[ $entries != "[]" && -n $entries ]] || return 0
  local n; n=$(jq 'length' <<<"$entries")
  (( n > 0 )) || return 0
  echo "fallback_providers:"
  local i provider model hp base_url
  for (( i = 0; i < n; i++ )); do
    provider=$(jq -r ".[$i].provider" <<<"$entries")
    model=$(jq -r ".[$i].model" <<<"$entries")
    [[ $provider == "$own_provider" && $model == "$own_model" ]] && continue
    hp=$(provider_hermes "$provider" 2>/dev/null); [[ -n $hp && $hp != - ]] || continue
    echo "  - provider: $hp"
    echo "    model: $(jq -Rn --arg v "$model" '$v')"
    if [[ $provider == local || $provider == endpoint || $provider == ollama ]]; then
      base_url=$(provider_base_url "$provider" 2>/dev/null)
      [[ -n $base_url && $base_url != - ]] && echo "    base_url: $(jq -Rn --arg v "$base_url" '$v')"
    fi
  done
}
