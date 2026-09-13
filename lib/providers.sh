#!/bin/bash
# Provider table for the Agent Launcher. Sourced by bin/omarchy-agent-launcher.
#
# One line per provider, pipe-separated:
#   id | label | api key env var ("-" = none) | hermes provider id | hermes oauth (y/n)
#      | openclaw provider id ("-" = unsupported) | openclaw oauth (y/n)
#      | base url ("-" = provider default) | default model | comma-separated model suggestions
#
# Model ids drift; this table is the single place to edit them. "Custom…" is
# always offered in the form, so a stale entry never blocks a launch.
#
# OAuth notes:
#   hermes   : `hermes -p <profile> auth add <provider> --type oauth` opens a browser.
#              Capable: anthropic, nous, openai-codex, xai-oauth, qwen-oauth, minimax-oauth.
#   openclaw : `openclaw models auth login --provider <id>`; OpenAI uses PKCE in a
#              browser, Anthropic uses a `claude setup-token` token.
PROVIDERS=(
  "anthropic|Anthropic (Claude)|ANTHROPIC_API_KEY|anthropic|y|anthropic|y|-|claude-sonnet-5|claude-opus-5,claude-sonnet-5,claude-haiku-4-5-20251001"
  "openai|OpenAI (API key)|OPENAI_API_KEY|openai-api|n|openai|n|-|gpt-5.4|gpt-5.4,gpt-5.4-mini,o4-mini"
  "openai-codex|OpenAI (ChatGPT subscription, OAuth)|-|openai-codex|y|openai|y|-|gpt-5.4-codex|gpt-5.4-codex,gpt-5.4"
  "nous|Nous Portal (OAuth)|NOUS_API_KEY|nous|y|-|n|-|hermes-4-405b|hermes-4-405b,hermes-4-70b"
  "xai|xAI (Grok)|XAI_API_KEY|xai|n|xai|n|-|grok-4.6|grok-4.6,grok-4.6-fast,grok-4"
  "xai-oauth|xAI (Grok, browser sign-in)|-|xai-oauth|y|-|n|https://api.x.ai/v1|grok-4.6|grok-4.6,grok-4.6-fast"
  "openrouter|OpenRouter|OPENROUTER_API_KEY|openrouter|n|openrouter|n|-|anthropic/claude-sonnet-5|anthropic/claude-sonnet-5,openai/gpt-5.4,google/gemini-3-pro,deepseek/deepseek-v4"
  "gemini|Google Gemini|GEMINI_API_KEY|gemini|n|google|n|-|gemini-3-pro|gemini-3-pro,gemini-3-flash"
  "deepseek|DeepSeek|DEEPSEEK_API_KEY|deepseek|n|deepseek|n|-|deepseek-chat|deepseek-chat,deepseek-reasoner"
  "ollama|Ollama (local, no key)|-|custom|n|ollama|n|http://localhost:11434/v1|qwen3:8b|qwen3:8b,llama3.3:70b,gpt-oss:20b"
  "local|Local GPU (llama.cpp, offline)|-|lmstudio|n|openai|n|http://127.0.0.1:8080/v1|-|-"
  "endpoint|Backend endpoint (OpenAI-compatible: cloud GPU machine, shared server)|-|custom|n|-|n|-|-|-"
)
# "endpoint" = a backend from lib/backends.sh (a GPU machine on Omarchy.Fans Cloud, or any
# OpenAI-compatible URL you were given). URL, model, and key come from the backend entry;
# Hermes reaches it through its `custom` provider. Hermes only.
# "local" = the llama.cpp server of the Omarchy local agent (lib/local.sh). Its
# URL and models are discovered live; Hermes reaches it through its LM Studio
# code path (same OpenAI-compatible API, and the only path that accepts a
# window below 64K when the real size is given).

provider_field() { # provider_field <id> <n>   (1-based column)
  local row
  for row in "${PROVIDERS[@]}"; do
    [[ ${row%%|*} == "$1" ]] || continue
    cut -d'|' -f"$2" <<<"$row"
    return 0
  done
  return 1
}
provider_label()     { provider_field "$1" 2; }
provider_env()       { provider_field "$1" 3; }
provider_hermes()    { provider_field "$1" 4; }
provider_hermes_oauth()   { [[ $(provider_field "$1" 5) == y ]]; }
provider_openclaw()  { provider_field "$1" 6; }
provider_openclaw_oauth() { [[ $(provider_field "$1" 7) == y ]]; }
provider_base_url()  { if [[ $1 == local ]] && declare -F local_api_url >/dev/null; then local_api_url; else provider_field "$1" 8; fi; }
provider_default_model() { provider_field "$1" 9; }
provider_models()    { provider_field "$1" 10 | tr ',' '\n'; }

# Providers an agent can actually use.
providers_for_agent() { # providers_for_agent <hermes|openclaw>
  local row id
  for row in "${PROVIDERS[@]}"; do
    id=${row%%|*}
    case "$1" in
      hermes)   [[ $(provider_hermes "$id") != - ]] && echo "$id" ;;
      openclaw) [[ $(provider_openclaw "$id") != - ]] && echo "$id" ;;
    esac
  done
}
