#!/bin/bash
# Modal (modal.com) backends: a vLLM server in your own Modal workspace, on the
# GPU you pick, either deployed as an app (scales to zero, wakes per request) or
# inside a Sandbox (isolated, fixed lifetime). Only the `modal` CLI talks to
# Modal; this file never stores or prints your Modal token.
#
# Install the CLI:  pipx install modal   (or: uv tool install modal)
# Sign in:          modal setup          (browser; writes ~/.modal.toml)
#
# Everything that reaches the network runs from an explicit command
# (`backends deploy|start|stop|test`), never from `status --json`.

MODAL_TOML="${MODAL_CONFIG_PATH:-$HOME/.modal.toml}"
MODAL_SCRIPTS="$OAL_ROOT/modal"

# GPU catalog: id, VRAM in GB, USD per GPU-hour. Prices from https://modal.com/pricing,
# read 2026-09-08 (Modal bills per second). Refresh here when Modal changes them.
MODAL_GPUS=(
  "T4|16|0.59"
  "L4|24|0.80"
  "A10|24|1.10"
  "L40S|48|1.95"
  "A100-40GB|40|2.10"
  "A100-80GB|80|2.50"
  "RTX-PRO-6000|96|3.03"
  "H100|80|3.95"
  "H200|141|4.54"
  "B200|180|6.25"
  "B300|288|7.10"
)
MODAL_PRICES_DATE="2026-09-08"

modal_gpu_field() { local row; for row in "${MODAL_GPUS[@]}"; do [[ ${row%%|*} == "$1" ]] && { cut -d'|' -f"$2" <<<"$row"; return 0; }; done; return 1; }
modal_gpu_hourly() { modal_gpu_field "$1" 3; }
modal_gpu_vram()   { modal_gpu_field "$1" 2; }
modal_gpus_json() {
  local row; { for row in "${MODAL_GPUS[@]}"; do IFS='|' read -r id vram hourly <<<"$row"
    jq -nc --arg id "$id" --argjson vram "$vram" --argjson hourly "$hourly" --arg m "$(modal_model_suggestion "$id" 1)" \
      '{id:$id, vram_gb:$vram, hourly_usd:$hourly, label:("\($id) · \($vram) GB · $\($hourly)/h"), suggested_model:$m}'; done; } | jq -sc --arg d "$MODAL_PRICES_DATE" '{prices_date:$d, gpus:.}'
}

# A tool-capable open model that fits the VRAM (bf16 unless noted). Any Hugging Face id works.
modal_model_suggestion() { # modal_model_suggestion <gpu> <count>
  local vram; vram=$(modal_gpu_vram "$1") || vram=24; vram=$(( vram * ${2:-1} ))
  if   (( vram >= 240 )); then echo "Qwen/Qwen3-235B-A22B-Instruct-2507-FP8"
  elif (( vram >= 140 )); then echo "NousResearch/Hermes-4-70B"
  elif (( vram >= 80 ));  then echo "Qwen/Qwen3-32B"
  elif (( vram >= 40 ));  then echo "Qwen/Qwen3-14B"
  else                          echo "Qwen/Qwen3-8B"; fi
}

modal_installed() { have modal; }
modal_authed() { [[ -s $MODAL_TOML ]] || [[ -n ${MODAL_TOKEN_ID:-} && -n ${MODAL_TOKEN_SECRET:-} ]]; }
modal_status_json() { # modal_status_json [quick]   (quick: no `modal --version` call; status --json polls this)
  local ver=""; [[ ${1:-} == quick ]] || { modal_installed && ver=$(modal --version 2>/dev/null | head -n1); }
  jq -nc --argjson installed "$(modal_installed && echo true || echo false)" --argjson authed "$(modal_authed && echo true || echo false)" \
    --arg version "$ver" --arg toml "$MODAL_TOML" --arg hint "pipx install modal   # or: uv tool install modal;  then: modal setup" \
    '{installed:$installed, authed:$authed, version:$version, config:$toml, install_hint:$hint}'
}
modal_need() {
  modal_installed || fail "the modal CLI is not installed: pipx install modal  (or: uv tool install modal), then: modal setup"
  modal_authed || fail "modal is not signed in: run  modal setup  (opens the browser, writes $MODAL_TOML)"
}

# Environment the deploy/sandbox scripts read (VAR=value lines). modal_script_env <backend-json>
modal_script_env() {
  local b=$1 id; id=$(jq -r .id <<<"$b")
  printf 'OAL_APP=%s\nOAL_MODEL=%s\nOAL_GPU=%s\nOAL_GPU_COUNT=%s\nOAL_SCALEDOWN_SECONDS=%s\nOAL_TIMEOUT_SECONDS=%s\nOAL_MAX_MODEL_LEN=%s\nOAL_API_KEY=%s\n' \
    "$(jq -r .app <<<"$b")" "$(jq -r .model <<<"$b")" "$(jq -r .gpu <<<"$b")" "$(jq -r .gpu_count <<<"$b")" \
    "$(( $(jq -r '.scaledown_min // 15' <<<"$b") * 60 ))" "$(( $(jq -r '.timeout_hours // 4' <<<"$b") * 3600 ))" \
    "$(jq -r '.model_ctx // 32768' <<<"$b")" "$(secret_get "$(backend_key_var "$id")")"
  local hf; hf=$(secret_get HF_TOKEN); [[ -n $hf ]] && printf 'HF_TOKEN=%s\n' "$hf"
  return 0
}

# Deploy (dedicated) or start (sandbox) a Modal backend. Long: image build + model download.
modal_backend_up() { # modal_backend_up <id>
  local id=$1 b kind; b=$(backends_json | jq -c --arg id "$id" '.[$id] // empty'); [[ -n $b ]] || fail "no such backend: $id"
  kind=$(jq -r .kind <<<"$b"); [[ $kind == modal-* ]] || fail "$id is a $kind backend, nothing to deploy"
  (( OAL_DRY_RUN )) || modal_need
  local -a env; mapfile -t env < <(modal_script_env "$b")
  local -a shown=("${env[@]//OAL_API_KEY=*/OAL_API_KEY=<key>}"); shown=("${shown[@]//HF_TOKEN=*/HF_TOKEN=<token>}")   # for dry-run output only
  say "Backend $id: $(jq -r '"\(.model) on \(.gpu) ×\(.gpu_count) ($\(.gpu_hourly * .gpu_count)/h while a container runs)"' <<<"$b")"
  backend_patch "$id" '{state:"starting"}'
  event_emit "rix" backend_starting "Backend $id: $kind on $(jq -r .gpu <<<"$b") starting" --task "backend $id"
  if [[ $kind == modal-dedicated ]]; then
    local out
    if (( OAL_DRY_RUN )); then run env "${shown[@]}" modal deploy "$MODAL_SCRIPTS/vllm_endpoint.py"; backend_patch "$id" '{state:"configured"}'; return 0; fi
    out=$(env "${env[@]}" modal deploy "$MODAL_SCRIPTS/vllm_endpoint.py" 2>&1 | tee /dev/stderr) || { backend_patch "$id" '{state:"error"}'; event_emit rix blocker "Backend $id failed to deploy on Modal (see the terminal)" --level blocker --key "backend-$id"; return 1; }
    local url; url=$(grep -oE 'https://[A-Za-z0-9._-]+\.modal\.run[^ ]*' <<<"$out" | head -n1)
    [[ -n $url ]] || url=$(env "${env[@]}" modal run "$MODAL_SCRIPTS/vllm_endpoint.py::url" 2>/dev/null | grep -oE 'https://[^ ]+' | tail -n1)
    [[ -n $url ]] || { backend_patch "$id" '{state:"error"}'; fail "deployed, but could not read the endpoint URL; run: modal app list"; }
    backend_mark_started "$id" "$url"
    event_emit rix backend_ready "Backend $id ready at $url" --task "backend $id"; event_emit rix blocker_cleared "" --key "backend-$id"
    say "ready: $url  (first request wakes the container; it sleeps after $(jq -r .scaledown_min <<<"$b") idle minutes)"
  else
    local out
    if (( OAL_DRY_RUN )); then run env "${shown[@]}" modal run "$MODAL_SCRIPTS/vllm_sandbox.py::start"; backend_patch "$id" '{state:"configured"}'; return 0; fi
    out=$(env "${env[@]}" modal run "$MODAL_SCRIPTS/vllm_sandbox.py::start" 2> >(tee /dev/stderr >&2)) || { backend_patch "$id" '{state:"error"}'; event_emit rix blocker "Backend $id: the Modal sandbox did not start (see the terminal)" --level blocker --key "backend-$id"; return 1; }
    local line; line=$(grep -E '^\{.*"sandbox_id"' <<<"$out" | tail -n1)
    [[ -n $line ]] || { backend_patch "$id" '{state:"error"}'; fail "sandbox started but printed no handle; run: modal sandbox list"; }
    backend_mark_started "$id" "$(jq -r .url <<<"$line")"
    backend_patch "$id" "{sandbox_id:$(jq -c .sandbox_id <<<"$line")}"
    event_emit rix backend_ready "Backend $id sandbox ready at $(jq -r .url <<<"$line")" --task "backend $id"; event_emit rix blocker_cleared "" --key "backend-$id"
    say "ready: $(jq -r .url <<<"$line")  (sandbox $(jq -r .sandbox_id <<<"$line"); lives $(jq -r .timeout_hours <<<"$b") h or until stopped; billed the whole time)"
  fi
}

modal_backend_down() { # modal_backend_down <id>
  local id=$1 b kind; b=$(backends_json | jq -c --arg id "$id" '.[$id] // empty'); [[ -n $b ]] || fail "no such backend: $id"
  kind=$(jq -r .kind <<<"$b"); [[ $kind == modal-* ]] || fail "$id is a $kind backend, nothing to stop"
  (( OAL_DRY_RUN )) || modal_need
  if [[ $kind == modal-dedicated ]]; then run modal app stop "$(jq -r .app <<<"$b")" || warn "modal app stop failed (already stopped?)"
  else local sb; sb=$(jq -r '.sandbox_id // empty' <<<"$b"); [[ -n $sb ]] && { run modal sandbox terminate "$sb" || warn "terminate failed (already gone?)"; }; fi
  (( OAL_DRY_RUN )) || backend_mark_stopped "$id"
  event_emit rix backend_stopped "Backend $id stopped" --task "backend $id"
  say "stopped $id"
}

# GET /v1/models with the backend's key. A sleeping dedicated endpoint may take a minute to wake.
modal_backend_test() { # modal_backend_test <id>
  local b; b=$(backend_get "$1") || fail "no such backend: $1"
  local url key; url=$(jq -r '.url // empty' <<<"$b"); [[ -n $url ]] || fail "$1 has no URL (deploy or start it first)"
  key=$(secret_get "$(backend_key_var "$1")")
  url="${url%/}"; [[ $url == */v1 ]] || url="$url/v1"
  if (( OAL_DRY_RUN )); then say "[dry-run] would GET $url/models"; return 0; fi
  local out code
  out=$(curl -sS --max-time 120 -w '\n%{http_code}' -H "Authorization: Bearer $key" "$url/models" 2>&1); code=${out##*$'\n'}
  if [[ $code == 200 ]]; then say "ok: $(jq -r '[.data[].id] | join(", ")' <<<"${out%$'\n'*}" 2>/dev/null || echo "responded")"; backend_patch "$1" '{state:"ready"}'
  else warn "HTTP ${code:-error}: ${out%$'\n'*}"; return 1; fi
}
