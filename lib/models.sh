#!/bin/bash
# Live model catalog for the Agent Launcher, from the open models.dev database
# (https://models.dev — every provider's current models, prices per million
# tokens, context limits, release dates). Fetched at most once a day into
# ~/.cache/omarchy-agent-launcher/models.json; when it cannot be fetched the
# static suggestions in providers.sh are used instead. Read-only, no keys.

MODELS_URL="${OAL_MODELS_URL:-https://models.dev/api.json}"
MODELS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-agent-launcher/models.json"
MODELS_MAX_AGE=$((24 * 3600))
MODELS_LIMIT=${OAL_MODELS_LIMIT:-14}

# models.dev provider key for each launcher provider ("-" = no catalog entry).
models_catalog_key() {
  case "$1" in
    anthropic) echo anthropic ;;  openai|openai-codex) echo openai ;;
    xai|xai-oauth) echo xai ;;    openrouter) echo openrouter ;;
    gemini) echo google ;;        deepseek) echo deepseek ;;
    nous) echo nous ;;            zai) echo zai ;;
    *) echo - ;;
  esac
}

# Some sign-ins reach an endpoint that serves only PART of its vendor's catalog, so the
# catalog alone is not the list of models you can actually run. openai-codex talks to
# https://chatgpt.com/backend-api/codex, which answers
#   "The '<id>' model is not supported when using Codex with a ChatGPT account"
# for everything outside a small set. Live 2026-09-19 the picker offered all 14 OpenAI
# models there and 11 of them were rejected, so the user picked a broken one.
#
# This list is PROBED, not guessed -- a "-codex" name proves nothing either way
# (gpt-5.3-codex is rejected; gpt-5.6-terra is fine). Re-probe when OpenAI moves things,
# one tiny call per candidate against a home that is signed in:
#
#   HERMES_HOME=<agent home>/hermes hermes --provider openai-codex -m <id> -z "say OK"
#
# Probed 2026-09-19 against a ChatGPT account:
#   serves   gpt-5.6-terra, gpt-5.6-luna, gpt-5.5
#   rejects  gpt-6-astra, gpt-5.6-sol, gpt-5.6, gpt-5.4, gpt-5.4-mini, gpt-5.4-nano,
#            gpt-5.3-chat-latest, gpt-5.3-codex, gpt-5.4-codex
#   unknown  gpt-5.5-pro, gpt-5.4-pro -- Hermes' own price guard refuses a -pro model
#            non-interactively (it prices from models.dev, i.e. the API, not the plan),
#            so the endpoint was never reached. Left out rather than guessed.
# "Custom model id…" in the picker stays the escape hatch for anything new.
OAL_CODEX_MODELS="gpt-5.6-terra gpt-5.6-luna gpt-5.5"

# Ids a provider's endpoint is known to serve, space separated, or "" for no restriction.
models_endpoint_allowlist() { # models_endpoint_allowlist <provider>
  case "$1" in
    openai-codex) printf '%s' "$OAL_CODEX_MODELS" ;;
    *)            printf '' ;;
  esac
}

# Refresh the cache if missing or older than a day. Never blocks for long.
models_catalog_refresh() { # models_catalog_refresh [force]
  mkdir -p "$(dirname "$MODELS_CACHE")"
  if [[ ${1:-} != force && -s $MODELS_CACHE ]]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$MODELS_CACHE" 2>/dev/null || echo 0) ))
    (( age < MODELS_MAX_AGE )) && return 0
  fi
  have curl || return 1
  local tmp; tmp=$(mktemp "$(dirname "$MODELS_CACHE")/.models.XXXXXX")
  if curl -fsSL --max-time 8 -o "$tmp" "$MODELS_URL" && jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    mv -f "$tmp" "$MODELS_CACHE"
  else
    rm -f "$tmp"; [[ -s $MODELS_CACHE ]] && touch "$MODELS_CACHE"   # keep the stale copy a day longer
    return 1
  fi
}

models_catalog_available() { [[ -s $MODELS_CACHE ]]; }
models_catalog_updated() { [[ -s $MODELS_CACHE ]] && date -r "$MODELS_CACHE" -Is; }

# JSON array of the newest tool-capable models for a provider:
#   [{id, name, input, output, context, release}]   (prices: USD per 1M tokens, null when unknown)
# Subscription sign-ins (no API key env) carry no prices: usage is covered by the plan.
models_for_provider() { # models_for_provider <provider>
  local p=$1 key; key=$(models_catalog_key "$p")
  local priced=true; [[ $(provider_env "$p") == - ]] && priced=false
  if [[ $p == local ]] && declare -F local_models_json >/dev/null; then local_models_json; return 0; fi
  if [[ $p == endpoint ]]; then   # the served models of every configured backend
    if declare -F backends_json >/dev/null; then backends_json | jq -c '[.[] | select(.kind != "provider") | {id: .model, name: (.model + "  ·  " + .label), input: .input_per_m, output: .output_per_m, context: .model_ctx, release: null}] | unique_by(.id)'
    else printf '[]'; fi
    return 0
  fi
  if [[ $p == ollama ]] && have ollama; then
    ollama list 2>/dev/null | awk 'NR>1 && $1 != "" {print $1}' | jq -R . | jq -sc 'map({id: ., name: ., input: null, output: null, context: null, release: null})'
    return 0
  fi
  if [[ $key != - ]] && models_catalog_available; then
    local out
    out=$(jq -c --arg k "$key" --argjson n "$MODELS_LIMIT" --argjson priced "$priced" '
      (.[$k].models // {}) | to_entries
      | map(select(.value.tool_call == true))
      | sort_by(.value.release_date // "0000") | reverse | .[0:$n]
      | map({id: .key, name: (.value.name // .key),
             input: (if $priced then (.value.cost.input // null) else null end),
             output: (if $priced then (.value.cost.output // null) else null end),
             context: (.value.limit.context // null), release: (.value.release_date // null)})' "$MODELS_CACHE" 2>/dev/null) || out="[]"
    local allow; allow=$(models_endpoint_allowlist "$p")
    if [[ -n $allow ]]; then
      # Keep only ids this endpoint is known to serve, in the allowlist's own order
      # (best first), and keep an allowed id the catalog happens not to list.
      local allowj; allowj=$(printf '%s\n' $allow | jq -R . | jq -sc .)
      out=$(jq -c --argjson a "$allowj" '
        . as $cat
        | [ $a[] | . as $id
            | ($cat | map(select(.id == $id)) | first)
              // {id:$id, name:$id, input:null, output:null, context:null, release:null} ]' <<<"$out") || out="[]"
    fi
    [[ $out != "[]" && -n $out ]] && { printf '%s\n' "$out"; return 0; }
  fi
  # Static fallback from providers.sh.
  provider_models "$p" | jq -R . | jq -sc 'map({id: ., name: ., input: null, output: null, context: null, release: null})'
}

# Human line for a model object: "id  ·  Name  ·  $in / $out per M tokens"
model_line() { # model_line <json-object>
  jq -r '"\(.id)  ·  \(.name)" + (if .input != null then "  ·  $\(.input) in / $\(.output) out per M tokens" else "" end)' <<<"$1"
}

# Default model: the static suggestion if the catalog still lists it, else the newest.
models_default_for_provider() { # models_default_for_provider <provider>
  local p=$1 list; list=$(models_for_provider "$p")
  local preferred; preferred=$(provider_default_model "$p")
  if [[ $preferred != - ]] && jq -e --arg m "$preferred" 'map(.id) | index($m) != null' <<<"$list" >/dev/null; then printf '%s' "$preferred"
  else jq -r '.[0].id // ""' <<<"$list"; fi
}
