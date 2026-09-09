#!/bin/bash
# Local GPU provider: the llama.cpp server run by the Omarchy local agent
# (omarchy-local-agent.service, from the Omarchy Help plugin). It speaks the
# OpenAI-compatible API on 127.0.0.1, so agents can run fully offline: no
# request ever leaves the machine.
#
# The one thing agents need that the help server does not ship with is
# context: Hermes Agent's first request is ~12K tokens and it needs a 64K
# window on paper. `local-server tune` raises the server's context with a
# systemd drop-in (reversible with `untune`); the help plugin keeps working.

LOCAL_AGENT_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-local-agent/config.json"
LOCAL_UNIT="omarchy-local-agent.service"
LOCAL_DROPIN="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/omarchy-local-agent.service.d/agent-launcher.conf"
LOCAL_MODELS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-local-agent/models"
LOCAL_MIN_CTX=${OAL_LOCAL_MIN_CTX:-16384}     # per request; Hermes' base prompt is ~12K tokens

local_server_url() {
  local u=""; [[ -f $LOCAL_AGENT_CONFIG ]] && u=$(jq -r '.server // empty' "$LOCAL_AGENT_CONFIG" 2>/dev/null)
  printf '%s' "${u:-http://127.0.0.1:8080}"
}
local_api_url() { printf '%s/v1' "$(local_server_url)"; }
local_online() { have curl && curl -fs --max-time 2 "$(local_server_url)/health" 2>/dev/null | grep -q '"ok"'; }
local_props_json() { curl -fs --max-time 3 "$(local_server_url)/props" 2>/dev/null || printf '{}'; }
local_unit_active() { have systemctl && systemctl --user is-active --quiet "$LOCAL_UNIT" 2>/dev/null; }
local_unit_exists() { have systemctl && systemctl --user cat "$LOCAL_UNIT" >/dev/null 2>&1; }
local_gguf_files() { [[ -d $LOCAL_MODELS_DIR ]] && find "$LOCAL_MODELS_DIR" -maxdepth 1 -name '*.gguf' -printf '%f\n' 2>/dev/null | sort; }
local_gpu_json() {
  if have nvidia-smi; then
    nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 \
      | awk -F', *' '{printf "{\"name\":\"%s\",\"used_mib\":%d,\"total_mib\":%d}\n", $1, $2, $3}'
  else printf 'null'; fi
}

# Everything the dashboard and status need in one object.
local_status_json() {
  local online=false props n_ctx=0 slots=0 model="" per=0 tuned=false active=false exists=false
  local_online && online=true
  if $online; then
    props=$(local_props_json)
    n_ctx=$(jq -r '.default_generation_settings.n_ctx // 0' <<<"$props"); slots=$(jq -r '.total_slots // 1' <<<"$props")
    model=$(jq -r '.model_path // .default_generation_settings.model // ""' <<<"$props"); model=${model##*/}
    (( slots > 0 )) && per=$(( n_ctx / slots )) || per=$n_ctx
  fi
  [[ -f $LOCAL_DROPIN ]] && tuned=true
  local_unit_active && active=true
  local_unit_exists && exists=true
  jq -nc --arg url "$(local_server_url)" --argjson online "$online" --arg model "$model" --argjson n_ctx "${n_ctx:-0}" \
    --argjson slots "${slots:-0}" --argjson per "${per:-0}" --argjson min "$LOCAL_MIN_CTX" --argjson tuned "$tuned" \
    --argjson active "$active" --argjson exists "$exists" --argjson gpu "$(local_gpu_json)" \
    --argjson files "$(local_gguf_files | jq -R . | jq -sc .)" --arg dropin "$LOCAL_DROPIN" \
    '{url:$url, online:$online, model:$model, n_ctx:$n_ctx, slots:$slots, ctx_per_request:$per, min_ctx:$min,
      agent_ready: ($online and $per >= $min), tuned:$tuned, unit_active:$active, unit_exists:$exists, gpu:$gpu, models:$files, dropin:$dropin}'
}

local_status_line() {
  local s; s=$(local_status_json)
  jq -r 'if .online then "local GPU server ready · \(.model) · \(.ctx_per_request) tokens/request" + (if .agent_ready then "" else " (too small for agents; run: omarchy-agent-launcher local-server tune)" end)
         elif .unit_exists then "local server not running (omarchy-local-agent.service)" else "no local server found (install the Omarchy Help plugin)" end' <<<"$s"
}

# Models for the provider table: what the server serves now, else the gguf files on disk.
local_models_json() {
  local ids; ids=$(curl -fs --max-time 3 "$(local_api_url)/models" 2>/dev/null | jq -c '[.data[]?.id | split("/") | last]' 2>/dev/null) || ids="[]"
  [[ $ids == "[]" || -z $ids ]] && ids=$(local_gguf_files | jq -R . | jq -sc .)
  local per; per=$(local_status_json | jq '.ctx_per_request')
  jq -c --argjson per "${per:-0}" 'map({id: ., name: (. | sub("\\.gguf$"; "")), input: null, output: null, context: (if $per > 0 then $per else null end), release: null})' <<<"$ids"
}

# Start the service if it is down; wait for /health.
local_ensure_running() {
  local_online && return 0
  local_unit_exists || { warn "no local llama-server: install the Omarchy Help plugin (io.github.modpunk.omarchy-help) first"; return 1; }
  run systemctl --user start "$LOCAL_UNIT" || return 1
  (( OAL_DRY_RUN )) && return 0
  local i; for i in $(seq 1 60); do local_online && return 0; sleep 1; done
  warn "local server did not come up within 60 s"; return 1
}

# Raise (or restore) the server's context with a systemd drop-in.
local_tune() { # local_tune <ctx> <kv-type> <slots> [model-file]
  local ctx=${1:-32768} kv=${2:-q8_0} slots=${3:-1} model=${4:-}
  local_unit_exists || fail "no $LOCAL_UNIT to tune; install the Omarchy Help plugin first"
  [[ $ctx =~ ^[0-9]+$ && $ctx -ge 4096 ]] || fail "--ctx must be a number of tokens (e.g. 32768)"
  [[ $kv == q8_0 || $kv == q4_0 || $kv == f16 ]] || fail "--kv must be q8_0, q4_0, or f16"
  local model_arg='${MODEL}'
  if [[ -n $model ]]; then [[ -f $LOCAL_MODELS_DIR/$model ]] || fail "model not found: $LOCAL_MODELS_DIR/$model"; model_arg="$LOCAL_MODELS_DIR/$model"; fi
  local port; port=$(local_server_url | sed -E 's#.*:([0-9]+)/?$#\1#'); [[ $port =~ ^[0-9]+$ ]] || port=8080
  local content
  content=$(cat <<CONF
# Written by Omarchy Agent Launcher (omarchy-agent-launcher local-server tune).
# A larger context so AI agents can use this server too (Hermes needs ~12K
# tokens per request). Reversible: omarchy-agent-launcher local-server untune
[Service]
ExecStart=
ExecStart=/usr/bin/llama-server --model $model_arg --host 127.0.0.1 --port $port --ctx-size $ctx --parallel $slots --flash-attn on --cache-type-k $kv --cache-type-v $kv --threads 8 --n-gpu-layers 99 --cache-reuse 256 --reasoning off --no-webui
CONF
)
  say "Drop-in: $LOCAL_DROPIN"
  say "  context $ctx tokens · $slots slot(s) → $(( ctx / slots )) tokens per request · KV cache $kv${model:+ · model $model}"
  if (( OAL_DRY_RUN )); then say "[dry-run] would write the drop-in, then: systemctl --user daemon-reload && systemctl --user restart $LOCAL_UNIT"; return 0; fi
  mkdir -p "$(dirname "$LOCAL_DROPIN")"
  printf '%s\n' "$content" >"$LOCAL_DROPIN"
  systemctl --user daemon-reload && systemctl --user restart "$LOCAL_UNIT" || fail "restart failed; see: journalctl --user -u $LOCAL_UNIT"
  local i; for i in $(seq 1 90); do local_online && break; sleep 1; done
  if local_online; then say "$(local_status_line)"; local_status_json | jq -r 'if .gpu then "  GPU \(.gpu.name): \(.gpu.used_mib) / \(.gpu.total_mib) MiB used" else empty end'
  else warn "server not healthy after restart (out of VRAM?). Try a smaller --ctx or --kv q4_0, or: omarchy-agent-launcher local-server untune"; journalctl --user -u "$LOCAL_UNIT" --since '-2min' --no-pager 2>/dev/null | grep -i "error\|memory" | tail -5; return 1; fi
}

local_untune() {
  [[ -f $LOCAL_DROPIN ]] || { say "not tuned (no $LOCAL_DROPIN)"; return 0; }
  run rm -f "$LOCAL_DROPIN"
  run systemctl --user daemon-reload
  run systemctl --user restart "$LOCAL_UNIT"
  say "restored the server's own configuration"
}
