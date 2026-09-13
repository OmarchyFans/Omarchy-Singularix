#!/bin/bash
# Omarchy.Fans Cloud runtime: a hosted agent on a cloud machine that sleeps when
# idle, managed through https://api.omarchy.fans. Paid convenience for the
# open-source launcher; this module only ever talks to that API.
#
# Flow: sign in once with the device flow (`cloud login`) → `rt_prepare` asks the
# API for an agent (name, kind, model, provider, job, skills, size, and the
# provider key from secrets.env as `secrets`; the local agent home is never
# uploaded) and waits until it is provisioned → `rt_cmd` attaches to the agent's
# tty over the console WebSocket (needs `websocat`). The machine wakes when the
# console opens or `cloud wake` runs, and sleeps on `cloud sleep` or after
# the idle timeout. Nothing is piped from the network into a shell.
#
# Helpers expected from the launcher (lib/common.sh, lib/providers.sh, lib/backends.sh):
#   say info warn fail run have   OAL_DRY_RUN OAL_SELF OAL_SECRETS
#   secret_get secret_set   profile_get profile_set profile_exists profile_path job_path
#   provider_env (optional)   backend_key_var (optional)
#
# Environment: OFC_API_URL (default https://api.omarchy.fans/v1), OFC_NO_BROWSER=1
# (never open a browser during login), OFC_POLL_INTERVAL (seconds, tests),
# OFC_PREPARE_TIMEOUT (seconds to wait for provisioning, default 600).

# shellcheck disable=SC2034  # read by the launcher's form
RUNTIME_LABEL="Omarchy.Fans Cloud"
OFC_API_URL="${OFC_API_URL:-https://api.omarchy.fans/v1}"
OFC_API_URL="${OFC_API_URL%/}"
OFC_PREPARE_TIMEOUT="${OFC_PREPARE_TIMEOUT:-600}"
OFC_HTTP_TIMEOUT="${OFC_HTTP_TIMEOUT:-60}"
CLOUD_WEBSOCAT_HINT="the console needs websocat: omarchy pkg add websocat"
: "${OAL_DRY_RUN:=0}"

cloud_token()     { secret_get OFC_TOKEN; }
cloud_agent_id()  { profile_get "$1" cloud_agent_id; }
cloud_ws_base()   { printf '%s' "$OFC_API_URL" | sed 's#^http#ws#'; }   # https://… → wss://…
cloud_self()      { printf '%s' "${OAL_SELF:-omarchy-agent-launcher}"; }

# ------------------------------------------------------------------ HTTP ----
# The token and the request body never go on argv (any local user can read a
# process's arguments): the Authorization header comes from a curl config on a
# pipe (-K <(…)), the body from stdin (--data-binary @-). A body can carry the
# agent's provider key.
cloud_curl() { # cloud_curl <curl args…> <<<body   (stdin is the body when args hold --data-binary @-)
  local tok; tok=$(cloud_token)
  if [[ -n $tok ]]; then
    curl -K <(printf 'header = "Authorization: Bearer %s"\n' "$tok") "$@"
  else
    curl "$@"
  fi
}

# cloud_http METHOD PATH [json-body]: raw request. Sets CLOUD_HTTP_CODE (000 when
# the API could not be reached) and CLOUD_HTTP_BODY; prints nothing, returns 0
# whenever an HTTP answer arrived (the caller decides what a 4xx means).
CLOUD_HTTP_CODE=000 CLOUD_HTTP_BODY=""
cloud_http() {
  local method=$1 path=$2 body=${3:-} out
  local -a args=(-s --max-time "$OFC_HTTP_TIMEOUT" -X "$method" -H 'Accept: application/json' -w $'\n%{http_code}')
  [[ -n $body ]] && args+=(-H 'Content-Type: application/json' --data-binary @-)
  if ! out=$(cloud_curl "${args[@]}" "$OFC_API_URL$path" <<<"$body" 2>/dev/null); then CLOUD_HTTP_CODE=000; CLOUD_HTTP_BODY=""; return 1; fi
  CLOUD_HTTP_CODE=${out##*$'\n'}; CLOUD_HTTP_BODY=${out%$'\n'*}
  return 0
}

# cloud_api METHOD PATH [json-body]: JSON on stdout; on any HTTP error prints
# the API's error message to stderr and returns 1.
cloud_api() {
  local method=$1 path=$2 body=${3:-} out
  local -a args=(-s --fail-with-body --max-time "$OFC_HTTP_TIMEOUT" -X "$method" -H 'Accept: application/json')
  [[ -n $body ]] && args+=(-H 'Content-Type: application/json' --data-binary @-)
  if ! out=$(cloud_curl "${args[@]}" "$OFC_API_URL$path" <<<"$body" 2>/dev/null); then
    warn "$method $path failed: $(cloud_error_message "$out")"
    return 1
  fi
  printf '%s\n' "$out"
}
cloud_error_message() { # cloud_error_message <body> -> human message
  local m; m=$(jq -r '.error.message // .error.code // empty' <<<"$1" 2>/dev/null)
  [[ -n $m ]] && { printf '%s' "$m"; return; }
  [[ -n $1 ]] && { printf '%s' "${1:0:200}"; return; }
  printf 'no answer from %s' "$OFC_API_URL"
}
cloud_json_arg() { jq -Rn --arg v "$1" '$v'; }   # a string as a JSON literal (for profile_set)

# ----------------------------------------------------------------- sign-in ----
# Device flow: POST /device/code → show the code and URL → poll /device/token
# until the user approves in the browser → save OFC_TOKEN in secrets.env.
cloud_login() {
  { have curl && have jq; } || fail "cloud login needs curl and jq"
  (( OAL_DRY_RUN )) && { info "[dry-run] would sign in to $OFC_API_URL with the device flow"; return 0; }
  local client; client="agent-launcher@$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "${HOSTNAME:-laptop}")"
  local resp; resp=$(cloud_api POST /device/code "$(jq -nc --arg c "$client" '{client_name:$c, scopes:"agents twins gpu usage"}')") \
    || fail "could not start the sign-in"
  local device_code user_code uri uri_full interval expires
  device_code=$(jq -r '.device_code // empty' <<<"$resp"); user_code=$(jq -r '.user_code // empty' <<<"$resp")
  uri=$(jq -r '.verification_uri // empty' <<<"$resp"); uri_full=$(jq -r '.verification_uri_complete // empty' <<<"$resp")
  interval=$(jq -r '.interval // 5' <<<"$resp"); expires=$(jq -r '.expires_in // 900' <<<"$resp")
  [[ -n $device_code && -n $user_code ]] || fail "unexpected answer from /device/code: $resp"
  say "Sign in to Omarchy.Fans Cloud"
  say "  open     ${uri_full:-$uri}"
  say "  and confirm the code   $user_code"
  if [[ ${OFC_NO_BROWSER:-0} != 1 ]] && have xdg-open; then (xdg-open "${uri_full:-$uri}" >/dev/null 2>&1 &); fi
  local deadline=$(( $(date +%s) + expires ))
  while (( $(date +%s) < deadline )); do
    sleep "${OFC_POLL_INTERVAL:-$interval}"
    cloud_http POST /device/token "$(jq -nc --arg d "$device_code" '{device_code:$d}')" || { warn "cannot reach $OFC_API_URL, retrying"; continue; }
    case $CLOUD_HTTP_CODE in
      200)
        local token; token=$(jq -r '.token // empty' <<<"$CLOUD_HTTP_BODY")
        [[ $token == ofc_* ]] || fail "unexpected token from /device/token"
        secret_set OFC_TOKEN "$token"
        secret_set OFC_TOKEN_ID "$(jq -r '.token_id // empty' <<<"$CLOUD_HTTP_BODY")"
        secret_set OFC_ORG "$(jq -r '.org.slug // empty' <<<"$CLOUD_HTTP_BODY")"
        say "signed in as $(jq -r '"\(.user.login // "?") · org \(.org.slug // "?") (\(.org.tier // "?"))"' <<<"$CLOUD_HTTP_BODY")"
        return 0 ;;
      428) ;;                                                      # authorization_pending
      429) interval=$(( interval + 5 )) ;;                         # slow_down
      410) fail "the sign-in code expired; run again: $(cloud_self) cloud login" ;;
      403) fail "the sign-in was denied" ;;
      *)   fail "unexpected answer $CLOUD_HTTP_CODE from /device/token: $(cloud_error_message "$CLOUD_HTTP_BODY")" ;;
    esac
  done
  fail "timed out waiting for the sign-in approval"
}

cloud_logout() {
  local id; id=$(secret_get OFC_TOKEN_ID)
  if [[ -n $(cloud_token) && -n $id ]] && ! (( OAL_DRY_RUN )); then cloud_api DELETE "/tokens/$id" >/dev/null 2>&1 || true; fi
  cloud_secret_unset OFC_TOKEN; cloud_secret_unset OFC_TOKEN_ID; cloud_secret_unset OFC_ORG
  say "signed out of Omarchy.Fans Cloud"
}
cloud_secret_unset() { # remove one VAR from secrets.env (common.sh has set/get only)
  [[ -n ${OAL_SECRETS:-} && -f $OAL_SECRETS ]] || return 0
  local tmp; tmp=$(mktemp "$(dirname "$OAL_SECRETS")/.secrets.XXXXXX")
  grep -v "^$1=" "$OAL_SECRETS" >"$tmp" || true
  chmod 600 "$tmp"; mv -f "$tmp" "$OAL_SECRETS"
}

cloud_ensure_auth() {
  (( OAL_DRY_RUN )) && { info "[dry-run] would verify the Omarchy.Fans Cloud sign-in"; return 0; }
  [[ -n $(cloud_token) ]] && return 0
  [[ -t 0 ]] || fail "not signed in to Omarchy.Fans Cloud: run  $(cloud_self) cloud login"
  cloud_login
}

# ----------------------------------------------------------------- runtime ----
rt_check() { # cheap: no network (the panel calls this on every open)
  { have curl && have jq; } || { say "curl + jq missing"; return 1; }
  if [[ -n $(cloud_token) ]]; then
    local org; org=$(secret_get OFC_ORG)
    say "signed in${org:+ · org $org}"
  else
    say "sign-in needed ($(cloud_self) cloud login)"; return 1
  fi
}

# The POST /agents body for a saved profile. Secrets: only the provider's key
# (or the backend key as OPENAI_API_KEY for an endpoint backend), never the home.
cloud_create_body() { # cloud_create_body <name> -> JSON
  local name=$1 p job skills size
  p=$(profile_path "$name")
  job=$(cat "$(job_path "$name")" 2>/dev/null || true)
  skills=$(jq -c '.skills // []' "$p")
  size=$(profile_get "$name" size); [[ -n $size ]] || size=s
  jq -nc --arg name "$name" --arg kind "$(profile_get "$name" agent)" --arg model "$(profile_get "$name" model)" \
     --arg provider "$(profile_get "$name" provider)" --arg base_url "$(profile_get "$name" base_url)" \
     --arg role "$(profile_get "$name" role)" --arg job "$job" --arg size "$size" \
     --argjson skills "$skills" --argjson secrets "$(cloud_secrets_json "$name")" '
    {name:$name, agent_kind:(if $kind == "" then "hermes" else $kind end), model:$model, provider:$provider,
     role:(if $role == "" then "worker" else $role end), skills:$skills, job_md:$job, size:$size, secrets:$secrets}
    + (if $base_url != "" and $base_url != "-" then {base_url:$base_url} else {} end)'
}
cloud_secrets_json() { # cloud_secrets_json <name> -> {"VAR":"value"} or {}
  local name=$1 provider var="" val="" backend
  provider=$(profile_get "$name" provider)
  if [[ $provider == endpoint ]]; then
    backend=$(profile_get "$name" backend); var=OPENAI_API_KEY   # the agent's custom provider reads this
    [[ -n $backend ]] && declare -F backend_key_var >/dev/null && val=$(secret_get "$(backend_key_var "$backend")")
  elif declare -F provider_env >/dev/null; then
    var=$(provider_env "$provider" 2>/dev/null || true); [[ $var == - ]] && var=""
    [[ -n $var ]] && val=$(secret_get "$var")
  fi
  if [[ -n $var && -n $val ]]; then jq -nc --arg k "$var" --arg v "$val" '{($k):$v}'; else printf '{}'; fi
}
cloud_redact() { jq -c '.secrets |= with_entries(.value = "<redacted>") | .job_md |= (.[0:60] + (if length > 60 then "…" else "" end))' <<<"$1"; }

rt_prepare() { # create the cloud agent once, then wait until it is provisioned
  local name=$1 id; id=$(cloud_agent_id "$name")
  have curl && have jq || (( OAL_DRY_RUN )) || fail "the cloud runtime needs curl and jq"
  cloud_ensure_auth
  if [[ -n $id ]]; then
    (( OAL_DRY_RUN )) && { info "[dry-run] cloud agent $id exists; would wait for it"; return 0; }
    info "cloud agent $id already exists"
  else
    local body; body=$(cloud_create_body "$name")
    if (( OAL_DRY_RUN )); then info "[dry-run] would POST $OFC_API_URL/agents  $(cloud_redact "$body")"; return 0; fi
    local resp; resp=$(cloud_api POST /agents "$body") || fail "could not create the cloud agent for '$name'"
    id=$(jq -r '.id // empty' <<<"$resp"); [[ $id == agt_* ]] || fail "unexpected answer from POST /agents: ${resp:0:200}"
    profile_set "$name" cloud_agent_id "$(cloud_json_arg "$id")"
    info "cloud agent $id created ($(jq -r '.size // "s"' <<<"$resp") machine)"
  fi
  cloud_wait_ready "$name" "$id"
  # The API takes the mode at wake time; the console alone would start an interactive session.
  if [[ $(profile_get "$name" mode) == unattended ]]; then cloud_wake "$name" unattended >/dev/null || fail "could not start '$name' unattended"; fi
}

cloud_wait_ready() { # cloud_wait_ready <name> <id>: until state != provisioning
  local name=$1 id=$2 deadline=$(( $(date +%s) + OFC_PREPARE_TIMEOUT )) resp state msg
  while :; do
    resp=$(cloud_api GET "/agents/$id") || fail "could not read the cloud agent $id"
    state=$(jq -r '.state // "unknown"' <<<"$resp"); msg=$(jq -r '.state_message // empty' <<<"$resp")
    case $state in
      provisioning) ;;
      error) fail "cloud agent '$name' failed to provision${msg:+: $msg}" ;;
      *) info "cloud agent $id is $state"; return 0 ;;
    esac
    (( $(date +%s) < deadline )) || fail "cloud agent '$name' is still provisioning after ${OFC_PREPARE_TIMEOUT}s"
    sleep "${OFC_POLL_INTERVAL:-5}"
  done
}

rt_oauth() {
  warn "browser sign-in (OAuth) cannot complete on a cloud machine: the callback would land there, not in your browser."
  warn "give '$1' an API-key provider or a backend endpoint instead (the key travels as an agent secret)."
  return 1
}

rt_cmd() { # rt_cmd <name> [resume] -> the attach command, one word per line
  printf '%s\n' "$(cloud_self)" cloud console "$1"
}

rt_console() { cloud_console "$1"; }

# Attach this terminal to the agent's tty over the console WebSocket. Binary
# frames carry bytes; cols/rows go in the query. Closing the window detaches;
# the agent keeps running until it sleeps.
cloud_console() { # cloud_console <name>
  local name=$1 id; id=$(cloud_agent_id "$name")
  [[ -n $id ]] || fail "'$name' has no cloud agent yet; launch it once: $(cloud_self) launch $name"
  local cols rows; cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 120)}; rows=${LINES:-$(tput lines 2>/dev/null || echo 40)}
  local url; url="$(cloud_ws_base)/agents/$id/console?cols=$cols&rows=$rows"
  if (( OAL_DRY_RUN )); then say "[dry-run] would attach: websocat --binary -E -B 65536 '$url&ticket=<one-time ticket>'"; return 0; fi
  have websocat || fail "$CLOUD_WEBSOCAT_HINT"
  cloud_ensure_auth
  # websocat takes headers only from argv, where other local users could read
  # the token. A one-time ticket that expires within a minute goes there instead.
  local ticket; ticket=$(cloud_api POST "/agents/$id/console-ticket" | jq -r '.ticket // empty')
  [[ $ticket == oct_* ]] || fail "could not open the console for '$name' (no console ticket)"
  say "attaching to $name ($id); close the window to detach, the agent keeps running"
  local saved rc; saved=$(stty -g 2>/dev/null || true)
  # shellcheck disable=SC2064  # expand now on purpose: $saved is a local, gone by exit time (stty -g has no spaces)
  if [[ -n $saved ]]; then trap "stty $saved 2>/dev/null" EXIT; stty raw -echo; fi
  websocat --binary -E -B 65536 "$url&ticket=$ticket"; rc=$?
  [[ -n $saved ]] && { stty "$saved" 2>/dev/null; trap - EXIT; }
  return $rc
}

rt_destroy() {
  local name=$1 id; id=$(cloud_agent_id "$name"); [[ -n $id ]] || return 0
  if (( OAL_DRY_RUN )); then say "[dry-run] would POST $OFC_API_URL/agents/$id/destroy"; return 0; fi
  [[ -n $(cloud_token) ]] || { warn "not signed in; cloud agent $id was not destroyed"; return 1; }
  cloud_api POST "/agents/$id/destroy" >/dev/null || return 1
  profile_exists "$name" && profile_set "$name" cloud_agent_id null
  say "cloud agent $id destroyed"
}

# ------------------------------------------------------------ subcommands ----
cloud_agent_json() { # cloud_agent_json <name> -> GET /agents/:id
  local id; id=$(cloud_agent_id "$1"); [[ -n $id ]] || fail "'$1' has no cloud agent yet"
  cloud_api GET "/agents/$id"
}
cloud_wake() { # cloud_wake <name> [interactive|unattended]
  local id; id=$(cloud_agent_id "$1"); [[ -n $id ]] || fail "'$1' has no cloud agent yet"
  if (( OAL_DRY_RUN )); then say "[dry-run] would POST $OFC_API_URL/agents/$id/wake"; return 0; fi
  local resp; resp=$(cloud_api POST "/agents/$id/wake" "$(jq -nc --arg m "${2:-interactive}" '{mode:$m}')") || return 1
  say "$1 is $(jq -r '.state // "?"' <<<"$resp")"
}
cloud_sleep() {
  local id; id=$(cloud_agent_id "$1"); [[ -n $id ]] || fail "'$1' has no cloud agent yet"
  if (( OAL_DRY_RUN )); then say "[dry-run] would POST $OFC_API_URL/agents/$id/sleep"; return 0; fi
  local resp; resp=$(cloud_api POST "/agents/$id/sleep") || return 1
  say "$1 is $(jq -r '.state // "?"' <<<"$resp")"
}
cloud_events() { # cloud_events <name> [since]
  local id; id=$(cloud_agent_id "$1"); [[ -n $id ]] || fail "'$1' has no cloud agent yet"
  cloud_api GET "/agents/$id/events${2:+?since=$2}" | jq -r '.events[] | "\(.at // .created_at // "")\t\(.kind // "")\t\(.message // "")"'
}
cloud_status() { # cloud_status [name]
  { have curl && have jq; } || fail "cloud status needs curl and jq"
  [[ -n $(cloud_token) ]] || fail "not signed in: run  $(cloud_self) cloud login"
  if [[ -n ${1:-} ]]; then
    cloud_agent_json "$1" | jq -r '"\(.name)  \(.state)\(if .state_message then " (" + .state_message + ")" else "" end)  \(.agent_kind) · \(.provider)/\(.model) · size \(.size)",
      "  awake hours this period: \(.usage.awake_hours_period // 0)   cost: $\(.usage.cost_usd // 0)   secrets: \((.secret_keys // []) | join(", "))",
      (.events // [] | .[-5:] | .[] | "  \(.at // .created_at // "")  \(.kind // "")  \(.message // "")")'
    return
  fi
  local me; me=$(cloud_api GET /me) || return 1
  jq -r '"signed in as \(.user.login) · org \(.org.slug) (\(.org.tier)) · agents \(.usage.hosted_agents // 0)/\(.quotas.hosted_agents // "?") · awake hours \(.usage.awake_hours // 0)/\(.quotas.awake_hours // "?")"' <<<"$me"
  local agents; agents=$(cloud_api GET /agents) || return 1
  jq -r '.agents[] | "  \(.name)\t\(.state)\t\(.agent_kind)\t\(.provider)/\(.model)\t\(.size)"' <<<"$agents" | column -t -s $'\t'
}
cloud_pricing() { cloud_api GET /pricing | jq -r '.tiers[] | "\(.name)\t$\(.price_month)/mo\t\(.quotas.hosted_agents) agents\t\(.quotas.awake_hours) awake h\t\(.quotas.storage_gb) GB\tGPU: \(.quotas.gpu_access)"' | column -t -s $'\t'; }
cloud_gpus() { # GET /gpu/catalog (discount applied when signed in)
  cloud_api GET /gpu/catalog | jq -r '.catalog[] | "\(.id)\t\(.name)\t\(.vram_gb) GB\t$\(.price_hour_discounted // .price_hour)/h\t$\(.price_minute)/min" + (if (.discount // 0) > 0 then "\t(\(.discount * 100 | floor)% off)" else "\t" end) + "\tsuggested: \(.suggested_model)"' | column -t -s $'\t'
}
# One line for the setup form, from the public /pricing (5 s budget, never fails).
cloud_price_line() {
  local saved=$OFC_HTTP_TIMEOUT; OFC_HTTP_TIMEOUT=5
  if cloud_http GET /pricing && [[ $CLOUD_HTTP_CODE == 200 ]]; then
    jq -r '(.tiers[] | select(.id == "fan")) as $f | (.tiers[] | select(.id == "plus")) as $p
      | "\($f.quotas.hosted_agents) agent free (\($f.quotas.awake_hours) h/mo) · Plus $\($p.price_month)/mo · $\(.overage.awake_hour)/h over"' <<<"$CLOUD_HTTP_BODY" 2>/dev/null \
      || say "prices at omarchy.fans/pricing"
  else say "prices at omarchy.fans/pricing"; fi
  OFC_HTTP_TIMEOUT=$saved
}

cloud_dispatch() { # cloud_dispatch <subcommand> [args…]  (the bin's `cloud` case arm)
  local sub=${1:-status}; shift || true
  case $sub in
    login)   cloud_login ;;
    logout)  cloud_logout ;;
    status)  cloud_status "${1:-}" ;;
    console) cloud_console "${1:?cloud console needs a name}" ;;
    wake)    cloud_wake "${1:?cloud wake needs a name}" "${2:-interactive}" ;;
    sleep)   cloud_sleep "${1:?cloud sleep needs a name}" ;;
    events)  cloud_events "${1:?cloud events needs a name}" "${2:-}" ;;
    pricing) cloud_pricing ;;
    gpus)    cloud_gpus ;;
    *) fail "usage: $(cloud_self) cloud login|logout|status [NAME]|console NAME|wake NAME [MODE]|sleep NAME|events NAME|pricing|gpus" ;;
  esac
}
