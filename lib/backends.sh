#!/bin/bash
# Backends: the models Rix (and you) can hand work to.
#
#   ~/.config/omarchy-agent-launcher/backends.json   {"<id>": {...}}
#
# Two kinds:
#   provider   a row of providers.sh (Anthropic, OpenAI, Nous, xAI, …): API key or browser
#              OAuth. Implicit: every provider is a backend with the provider's id.
#   endpoint   any OpenAI-compatible URL + key: a GPU machine on Omarchy.Fans Cloud
#              (its relay URL and ofg_ key), a team vLLM server, a private gateway.
#
# Keys live in secrets.env as BACKEND_<ID>_KEY (mode 600). Hermes reaches endpoint
# backends through its `custom` provider (base_url + OPENAI_API_KEY in the agent's own .env).
#
# Nothing here calls the network; `status --json` may read this file every 30 s.

OAL_BACKENDS="$OAL_CONF/backends.json"
BACKEND_KINDS="provider endpoint"

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
    local signed=${BACKEND_SIGNED-$(backends_signed_providers)}
    if [[ " $signed " == *" $p "* ]]; then auth=oauth; ready=true; state="signed in"
    elif [[ $auth == none ]]; then auth=oauth; state="browser sign-in needed"; fi
  fi
  # The static default model is enough for a list row; only the local server (no
  # static entry) is asked what it serves. The catalog pass costs ~0.2 s per call.
  local model; model=$(provider_default_model "$p"); [[ $model == - ]] && model=$(models_default_for_provider "$p")
  if [[ $p == local ]]; then
    state="local GPU"; ready=false
    declare -F local_status_json >/dev/null && local_status_json | jq -e '.agent_ready' >/dev/null 2>&1 && ready=true
    $ready || state="local GPU · not ready"
  fi
  [[ $p == ollama ]] && { have ollama && ready=true; state="ollama"; }
  jq -nc --arg id "$p" --arg label "$label" --arg provider "$p" --arg auth "$auth" --argjson ready "$ready" --arg state "$state" \
    --arg model "$model" --arg base_url "$(provider_base_url "$p")" --arg env "$env" \
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

# Providers some Hermes home is signed in to (browser OAuth), space-separated.
backends_signed_providers() {
  local n
  for n in $(profile_list); do
    [[ $(profile_get "$n" agent) == hermes && $(profile_get "$n" auth) == oauth && $(profile_get "$n" signed_in) == true && -s $(stage_dir "$n")/hermes/auth.json ]] && profile_get "$n" provider
  done | sort -u | tr '\n' ' '
}

# Every backend: registry entries + implicit providers. backends_list_json
backends_list_json() {
  local id first=1
  local BACKEND_SIGNED; BACKEND_SIGNED=$(backends_signed_providers)   # computed once for every row below
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
    # A provider without any credentials would fail on its first request in a window nobody reads.
    [[ $(jq -r .state <<<"$b") == needs\ * ]] && fail "backend '$1' is not ready: $(jq -r .state <<<"$b") (save the key on the New agent page, or pick another backend)"
    jq -c --arg m "${2:-}" '{provider, auth, model:(if $m != "" then $m else .model end), base_url, backend:.id, context_length:null}' <<<"$b"
  else
    jq -e '.url != null and .url != ""' <<<"$b" >/dev/null || fail "backend '$1' has no URL yet (deploy or start it first: omarchy-agent-launcher backends deploy $1)"
    jq -c --arg m "${2:-}" '{provider:"endpoint", auth:"api-key", model:(if $m != "" then $m else .model end), base_url:(.url | rtrimstr("/") | if endswith("/v1") then . else . + "/v1" end), backend:.id, context_length:(.model_ctx // 32768)}' <<<"$b"
  fi
}

# Add or replace a registry backend from `create`-style OPTS. backend_add_from_opts
#   --id I [--kind endpoint] --label L --model M --url U [--key-env] [--ctx N] [--input-per-m $] [--output-per-m $]
#   --key-env reads the endpoint key from $OAL_BACKEND_KEY (never argv).
backend_add_from_opts() {
  local id kind label model url ctx inm outm
  id=$(slugify "$(opt_value --id || opt_value --name || true)"); [[ -n $id ]] || fail "backends add: --id is required"
  kind=$(opt_value --kind || echo endpoint); [[ $kind == endpoint ]] || fail "backends add: --kind must be endpoint"
  label=$(opt_value --label || echo "$id"); model=$(opt_value --model || true)
  url=$(opt_value --url || true); ctx=$(opt_value --ctx || echo 32768)
  inm=$(opt_value --input-per-m || true); outm=$(opt_value --output-per-m || true)
  [[ $ctx =~ ^[0-9]+$ ]] || fail "backends add: --ctx takes a number"
  [[ -n $url ]] || fail "backends add: --url is required for an endpoint"
  [[ -n $model ]] || fail "backends add: --model is required for an endpoint (the served model id)"
  if opt_flag --key-env; then
    [[ -n ${OAL_BACKEND_KEY:-} ]] || fail "backends add: --key-env given but \$OAL_BACKEND_KEY is empty"
    secret_set "$(backend_key_var "$id")" "$OAL_BACKEND_KEY"
  fi
  local existing; existing=$(backends_json | jq -c --arg id "$id" '.[$id] // {}')
  local b
  b=$(jq -nc --arg id "$id" --arg kind "$kind" --arg label "$label" --arg model "$model" --arg url "$url" \
        --argjson ctx "$ctx" --argjson inm "${inm:-null}" --argjson outm "${outm:-null}" --arg created "$(date -Is)" --argjson old "$existing" '
    $old + {id:$id, kind:$kind, label:$label, model:$model, url:$url, state:"ready", created:($old.created // $created),
            model_ctx:$ctx, input_per_m:$inm, output_per_m:$outm}')
  backend_write "$id" "$b"
  printf '%s\n' "$b"
}

# backend_test <id>: GET <url>/models with the backend's key. The key goes to curl
# through a config on a pipe, never argv.
backend_test() {
  local id=$1 b url key
  b=$(backend_get "$id" 2>/dev/null) || fail "no such backend: $id"
  url=$(jq -r '.url // empty' <<<"$b"); [[ -n $url ]] || fail "backend $id has no URL"
  key=$(secret_get "$(backend_key_var "$id")")
  if (( ${OAL_DRY_RUN:-0} )); then say "[dry-run] would GET ${url%/}/models${key:+ with the saved key}"; return 0; fi
  say "GET ${url%/}/models"
  local out
  if [[ -n $key ]]; then
    out=$(curl -sS --fail-with-body --max-time 30 -K <(printf 'header = "Authorization: Bearer %s"\n' "$key") "${url%/}/models" 2>&1)
  else
    out=$(curl -sS --fail-with-body --max-time 30 "${url%/}/models" 2>&1)
  fi || { warn "backend $id did not answer: ${out:0:300}"; return 1; }
  jq -r '"ok: serves " + ([.data[]?.id] | join(", "))' <<<"$out" 2>/dev/null || say "ok: ${out:0:300}"
}

# For usage --json. Endpoint backends are billed by whoever runs them, so there is
# no GPU time to count here.
backends_usage_json() { printf '[]'; }

backends_print() {
  backends_list_json | jq -r '.[] | "\(.id)\t\(.kind)\t\(.label)\t\(.model)\t" + (if .kind == "provider" then .state else "\(.state)" + (if .url then " · \(.url)" else "" end) end)' | column -t -s $'\t'
}
