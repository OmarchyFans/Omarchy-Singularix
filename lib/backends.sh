#!/bin/bash
# Backends: the models Jarvis (and you) can hand work to.
#
#   ~/.config/omarchy-agent-launcher/backends.json   {"<id>": {...}}
#
# Four kinds:
#   provider         a row of providers.sh (Anthropic, OpenAI, Nous, xAI, …): API key or browser
#                    OAuth. Implicit: every provider is a backend with the provider's id.
#   endpoint         any OpenAI-compatible URL + key: a Modal endpoint somebody shares with you,
#                    a team vLLM server, a private gateway.
#   modal-dedicated  a vLLM server we deploy to your Modal workspace (modal/vllm_endpoint.py) on
#                    the GPU you choose; scales to zero when idle, wakes on the next request.
#   modal-sandbox    the same server inside a Modal Sandbox (modal/vllm_sandbox.py): isolated,
#                    lives for a fixed time, never shared, terminated explicitly.
#
# Keys live in secrets.env as BACKEND_<ID>_KEY (mode 600). Hermes reaches endpoint/modal
# backends through its `custom` provider (base_url + OPENAI_API_KEY in the agent's own .env).
#
# Nothing here calls Modal or the network; `status --json` may read this file every 30 s.
# lib/modal.sh does the deploy/stop/test work and updates the state fields.

OAL_BACKENDS="$OAL_CONF/backends.json"
BACKEND_KINDS="provider endpoint modal-dedicated modal-sandbox"

backends_json() { [[ -s $OAL_BACKENDS ]] && cat "$OAL_BACKENDS" || printf '{}'; }
backend_key_var() { printf 'BACKEND_%s_KEY' "$(tr '[:lower:]-' '[:upper:]_' <<<"$1")"; }
backend_exists() { backends_json | jq -e --arg id "$1" 'has($id)' >/dev/null; }
backend_ids() { backends_json | jq -r 'keys[]'; }

backend_write() { # backend_write <id> <json-object>
  mkdir -p "$OAL_CONF"; local tmp; tmp=$(mktemp "$OAL_CONF/.backends.XXXXXX")
  backends_json | jq --arg id "$1" --argjson b "$2" '.[$id] = $b' >"$tmp" && mv -f "$tmp" "$OAL_BACKENDS"
}
backend_patch() { # backend_patch <id> <jq-object-expression>   e.g. '{state:"ready", url:"https://…"}'
  local tmp; tmp=$(mktemp "$OAL_CONF/.backends.XXXXXX")
  backends_json | jq --arg id "$1" ".[\$id] += ($2)" >"$tmp" && mv -f "$tmp" "$OAL_BACKENDS"
}
backend_delete() {
  local tmp; tmp=$(mktemp "$OAL_CONF/.backends.XXXXXX")
  backends_json | jq --arg id "$1" 'del(.[$id])' >"$tmp" && mv -f "$tmp" "$OAL_BACKENDS"
  local var; var=$(backend_key_var "$1")
  if [[ -f $OAL_SECRETS ]] && grep -q "^$var=" "$OAL_SECRETS"; then
    tmp=$(mktemp "$OAL_CONF/.secrets.XXXXXX"); grep -v "^$var=" "$OAL_SECRETS" >"$tmp" || true; chmod 600 "$tmp"; mv -f "$tmp" "$OAL_SECRETS"
  fi
}

# A provider row as an implicit backend object. backend_from_provider <provider-id>
backend_from_provider() {
  local p=$1 label env auth=none ready=false state="no sign-in"
  label=$(provider_label "$p") || return 1
  env=$(provider_env "$p")
  [[ $p == endpoint ]] && return 1        # not a backend by itself: its entries live in the registry
  if [[ $env != - ]]; then
    if [[ -n $(secret_get "$env") ]]; then auth=api-key; ready=true; state="API key saved"; else state="needs $env"; fi
  fi
  if provider_hermes_oauth "$p"; then
    # A browser sign-in some Hermes home already has wins over a saved key (it is
    # the user's own plan): new homes inherit it (lib/agents/hermes.sh). Without
    # one, OAuth is offered but not "ready": the first launch needs the browser.
    if ( load_agent hermes; hermes_provider_signed_in "$p" ) 2>/dev/null; then auth=oauth; ready=true; state="signed in"
    elif [[ $auth == none ]]; then auth=oauth; state="browser sign-in needed"; fi
  fi
  if [[ $p == local ]]; then
    state="local GPU"; ready=false
    declare -F local_status_json >/dev/null && local_status_json | jq -e '.agent_ready' >/dev/null 2>&1 && ready=true
    $ready || state="local GPU · not ready"
  fi
  [[ $p == ollama ]] && { have ollama && ready=true; state="ollama"; }
  jq -nc --arg id "$p" --arg label "$label" --arg provider "$p" --arg auth "$auth" --argjson ready "$ready" --arg state "$state" \
    --arg model "$(models_default_for_provider "$p")" --arg base_url "$(provider_base_url "$p")" --arg env "$env" \
    '{id:$id, label:$label, kind:"provider", provider:$provider, auth:$auth, model:$model, base_url:$base_url,
      key_var:(if $env == "-" then "" else $env end), ready:$ready, state:$state, hermes:true}'
}

# One backend, registry first, then providers. backend_get <id> -> JSON object (exit 1 if unknown)
backend_get() {
  local b; b=$(backends_json | jq -c --arg id "$1" '.[$id] // empty')
  if [[ -n $b ]]; then
    jq -c --arg var "$(backend_key_var "$1")" --argjson has_key "$([[ -n $(secret_get "$(backend_key_var "$1")") ]] && echo true || echo false)" \
      '. + {key_var:$var, has_key:$has_key, ready:(.state == "ready" and .url != null and .url != ""), hermes:true, provider:"endpoint", auth:"api-key"}' <<<"$b"
    return 0
  fi
  backend_from_provider "$1"
}

# Every backend: registry entries + implicit providers. backends_list_json
backends_list_json() {
  local id first=1
  {
    printf '['
    while IFS= read -r id; do [[ -n $id ]] || continue; (( first )) || printf ','; first=0; backend_get "$id"; done < <(backend_ids)
    for id in $(providers_all_ids); do
      local pb; pb=$(backend_from_provider "$id") || continue
      (( first )) || printf ','; first=0; printf '%s' "$pb"
    done
    printf ']'
  } | jq -c .
}
providers_all_ids() { local row; for row in "${PROVIDERS[@]}"; do echo "${row%%|*}"; done; }

# What `create` needs for a backend: provider, auth, model, base_url, backend id. backend_resolve <id> [model]
backend_resolve() {
  local b; b=$(backend_get "$1") || fail "unknown backend '$1' (see: omarchy-agent-launcher backends list)"
  local kind; kind=$(jq -r .kind <<<"$b")
  if [[ $kind == provider ]]; then
    jq -c --arg m "${2:-}" '{provider, auth, model:(if $m != "" then $m else .model end), base_url, backend:.id, context_length:null}' <<<"$b"
  else
    jq -e '.url != null and .url != ""' <<<"$b" >/dev/null || fail "backend '$1' has no URL yet (deploy or start it first: omarchy-agent-launcher backends deploy $1)"
    jq -c --arg m "${2:-}" '{provider:"endpoint", auth:"api-key", model:(if $m != "" then $m else .model end), base_url:(.url | rtrimstr("/") | if endswith("/v1") then . else . + "/v1" end), backend:.id, context_length:(.model_ctx // 32768)}' <<<"$b"
  fi
}

# Add or replace a registry backend from `create`-style OPTS. backend_add_from_opts
#   --id I --kind endpoint|modal-dedicated|modal-sandbox --label L --model M [--url U] [--key-env]
#   [--gpu G] [--gpu-count N] [--scaledown MIN] [--timeout-hours H] [--ctx N] [--input-per-m $] [--output-per-m $]
#   --key-env reads the endpoint key from $OAL_BACKEND_KEY (never argv); modal kinds generate one.
backend_add_from_opts() {
  local id kind label model url gpu count scaledown hours ctx inm outm
  id=$(slugify "$(opt_value --id || opt_value --name || true)"); [[ -n $id ]] || fail "backends add: --id is required"
  kind=$(opt_value --kind || echo endpoint); [[ " $BACKEND_KINDS " == *" $kind "* && $kind != provider ]] || fail "backends add: --kind must be endpoint, modal-dedicated, or modal-sandbox"
  label=$(opt_value --label || echo "$id"); model=$(opt_value --model || true)
  url=$(opt_value --url || true); gpu=$(opt_value --gpu || echo L4); count=$(opt_value --gpu-count || echo 1)
  scaledown=$(opt_value --scaledown || echo 15); hours=$(opt_value --timeout-hours || echo 4); ctx=$(opt_value --ctx || echo 32768)
  inm=$(opt_value --input-per-m || true); outm=$(opt_value --output-per-m || true)
  [[ $count =~ ^[1-8]$ ]] || fail "backends add: --gpu-count must be 1-8"
  [[ $scaledown =~ ^[0-9]+$ && $hours =~ ^[0-9]+$ && $ctx =~ ^[0-9]+$ ]] || fail "backends add: --scaledown, --timeout-hours, --ctx take numbers"
  if [[ $kind == endpoint ]]; then
    [[ -n $url ]] || fail "backends add: --url is required for an endpoint"
    [[ -n $model ]] || fail "backends add: --model is required for an endpoint (the served model id)"
  else
    declare -F modal_gpu_hourly >/dev/null || fail "modal support not loaded"
    modal_gpu_hourly "$gpu" >/dev/null || fail "backends add: unknown --gpu '$gpu' (see: omarchy-agent-launcher modal gpus)"
    [[ -n $model ]] || model=$(modal_model_suggestion "$gpu" "$count")
  fi
  local var; var=$(backend_key_var "$id")
  if opt_flag --key-env; then
    [[ -n ${OAL_BACKEND_KEY:-} ]] || fail "backends add: --key-env given but \$OAL_BACKEND_KEY is empty"
    secret_set "$var" "$OAL_BACKEND_KEY"
  elif [[ $kind != endpoint && -z $(secret_get "$var") ]]; then
    secret_set "$var" "$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)"   # the server's API key
  fi
  local hourly=null; [[ $kind != endpoint ]] && hourly=$(modal_gpu_hourly "$gpu")
  local existing; existing=$(backends_json | jq -c --arg id "$id" '.[$id] // {}')
  local b
  b=$(jq -nc --arg id "$id" --arg kind "$kind" --arg label "$label" --arg model "$model" --arg url "$url" --arg gpu "$gpu" \
        --argjson count "$count" --argjson scaledown "$scaledown" --argjson hours "$hours" --argjson ctx "$ctx" \
        --argjson inm "${inm:-null}" --argjson outm "${outm:-null}" --argjson hourly "$hourly" --arg created "$(date -Is)" --argjson old "$existing" '
    $old + {id:$id, kind:$kind, label:$label, model:$model, created:($old.created // $created)}
    + (if $kind == "endpoint" then {url:$url, state:"ready", gpu:null, gpu_count:null, gpu_hourly:null}
       else {gpu:$gpu, gpu_count:$count, gpu_hourly:$hourly, scaledown_min:$scaledown, timeout_hours:$hours, app:("oal-" + $id),
             state:($old.state // "configured"), url:($old.url // null)} end)
    + {model_ctx:$ctx, input_per_m:$inm, output_per_m:$outm, runtime_seconds:($old.runtime_seconds // 0), started_at:($old.started_at // null)}')
  backend_write "$id" "$b"
  printf '%s\n' "$b"
}

# GPU-time bookkeeping (sandboxes are billed from start to terminate; dedicated endpoints
# scale to zero, so their GPU time is estimated per task in lib/usage.sh instead).
backend_mark_started() { backend_patch "$1" "{state:\"ready\", started_at:$(date +%s), url:$(jq -Rn --arg v "$2" '$v')}"; }
backend_mark_stopped() {
  local b; b=$(backends_json | jq -c --arg id "$1" '.[$id] // {}')
  local add=0 st; st=$(jq -r '.started_at // empty' <<<"$b")
  if [[ -n $st && $(jq -r .kind <<<"$b") == modal-sandbox ]]; then add=$(( $(date +%s) - st )); (( add < 0 )) && add=0; fi
  backend_patch "$1" "{state:\"stopped\", started_at:null, runtime_seconds:((.runtime_seconds // 0) + $add), sandbox_id:null}"
}

# For usage --json: [{id, kind, gpu, gpu_count, gpu_hourly, state, runtime_seconds, gpu_cost_usd, cost_basis}]
backends_usage_json() { # backends_usage_json <now-epoch>
  backends_json | jq -c --argjson now "$1" '[ .[] | select(.kind != "endpoint")
    | (.runtime_seconds // 0) as $acc
    | (if .kind == "modal-sandbox" and .started_at != null and .state == "ready" then ($now - .started_at) else 0 end) as $live
    | {id, kind, label, gpu, gpu_count, gpu_hourly, state, model, url, runtime_seconds:($acc + $live),
       gpu_cost_usd:(if .kind == "modal-sandbox" then (($acc + $live) / 3600 * (.gpu_hourly // 0) * (.gpu_count // 1)) else 0 end),
       cost_basis:(if .kind == "modal-sandbox" then "GPU time (est.)" else "GPU time per task (est.)" end)} ]'
}

backends_print() {
  backends_list_json | jq -r '.[] | "\(.id)\t\(.kind)\t\(.label)\t\(.model)\t" + (if .kind == "provider" then .state else "\(.state)" + (if .gpu then " · \(.gpu) ×\(.gpu_count) · $\(.gpu_hourly * .gpu_count)/h" else "" end) + (if .url then " · \(.url)" else "" end) end)' | column -t -s $'\t'
}
