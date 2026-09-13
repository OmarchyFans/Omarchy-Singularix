#!/bin/bash
# Token usage and cost for the Agent Launcher.
#
# Source of truth: every Hermes agent home keeps a SQLite session store
# (<home>/state.db) in which Hermes records, per session, the provider's real
# token counts (input, output, cache read, cache write, reasoning) and its own
# cost estimate. We read it read-only (sqlite3 -readonly) and never write.
#
# Definitions used everywhere (dashboard, `usage`, Rix's brief):
#   prompt tokens = input + cache_read + cache_write   (what the provider billed as prompt)
#   task          = one Hermes session; a delegated worker agent is one task whose sessions roll up
#   cost basis    = where a USD figure comes from, one label per row:
#                   actual · hermes estimate · hermes estimate (plan) · backend price ·
#                   models.dev · GPU time (est.) · local GPU · $0 · unknown
#
# OpenClaw keeps no comparable store; its agents report no usage.

USAGE_TASK_LIMIT=${OAL_USAGE_TASK_LIMIT:-400}

# models.dev prices for every model in the cache: {"<model id>": {input, output, cache_read, cache_write}} (USD per 1M)
usage_catalog_prices() {
  [[ -s ${MODELS_CACHE:-} ]] || { printf '{}'; return; }
  jq -c '[ .[] | (.models // {}) | to_entries[] | select(.value.cost != null)
           | {key: .key, value: {input: .value.cost.input, output: .value.cost.output,
                                 cache_read: (.value.cost.cache_read // null), cache_write: (.value.cost.cache_write // null)}} ]
         | reverse | from_entries' "$MODELS_CACHE" 2>/dev/null || printf '{}'
}

# Raw sessions of one Hermes agent home, newest first. usage_sessions_json <name>
usage_sessions_json() {
  local db; db="$(stage_dir "$1")/hermes/state.db"
  { have sqlite3 && [[ -f $db ]]; } || { printf '[]'; return; }
  local out
  out=$(timeout 5 sqlite3 -readonly -json "$db" "select id, coalesce(title,'') as title, coalesce(model,'') as model,
      coalesce(billing_provider,'') as billing_provider, started_at, ended_at, last_activity_at,
      coalesce(message_count,0) as message_count, coalesce(tool_call_count,0) as tool_call_count, coalesce(api_call_count,0) as api_call_count,
      coalesce(input_tokens,0) as input_tokens, coalesce(output_tokens,0) as output_tokens,
      coalesce(cache_read_tokens,0) as cache_read_tokens, coalesce(cache_write_tokens,0) as cache_write_tokens,
      coalesce(reasoning_tokens,0) as reasoning_tokens, estimated_cost_usd, actual_cost_usd, coalesce(cost_status,'') as cost_status,
      coalesce(parent_session_id,'') as parent_session_id
    from sessions where coalesce(archived,0) = 0 order by started_at desc limit $USAGE_TASK_LIMIT" 2>/dev/null) || out=""
  [[ $out == \[* ]] && printf '%s' "$out" || printf '[]'
}

# One agent's usage: {name, ..., tasks:[session rows], totals}. usage_agent_json <name> <prices-file> <now-epoch>
# (prices come as a file: the models.dev map is far too large for an argument)
usage_agent_json() {
  local name=$1 prices_file=$2 now=$3
  local profile; profile=$(cat "$(profile_path "$name")")
  local agent provider auth backend_id backend='null'
  agent=$(jq -r .agent <<<"$profile"); provider=$(jq -r .provider <<<"$profile"); auth=$(jq -r .auth <<<"$profile")
  backend_id=$(jq -r '.backend // ""' <<<"$profile")
  if [[ -n $backend_id ]] && declare -F backend_get >/dev/null; then backend=$(backend_get "$backend_id" 2>/dev/null) || backend=null; fi
  [[ $backend == \{* ]] || backend=null
  local sessions='[]'; [[ $agent == hermes ]] && sessions=$(usage_sessions_json "$name")
  jq -c --arg name "$name" --arg agent "$agent" --arg provider "$provider" --arg auth "$auth" --argjson backend "$backend" \
        --slurpfile pricesf "$prices_file" --argjson now "$now" --argjson profile "$profile" '
    ($pricesf[0] // {}) as $prices |
    def gpu_rate: ($backend.gpu_hourly // 0) * ($backend.gpu_count // 1);
    def price_for($m): ($prices[$m] // ($prices | to_entries | map(select(.key | ascii_downcase == ($m | ascii_downcase))) | .[0].value) // null);
    def cost_of($s):
      if $s.actual_cost_usd != null then {cost: $s.actual_cost_usd, basis: "actual"}
      elif $s.estimated_cost_usd != null then {cost: $s.estimated_cost_usd, basis: (if $auth == "oauth" then "hermes estimate (plan)" else "hermes estimate" end)}
      elif $provider == "local" or $provider == "ollama" then {cost: 0, basis: "local GPU · $0"}
      elif ($backend != null and ($backend.input_per_m // null) != null) then
        {cost: ((($s.input_tokens + $s.cache_read_tokens + $s.cache_write_tokens) * $backend.input_per_m + $s.output_tokens * ($backend.output_per_m // $backend.input_per_m)) / 1000000), basis: "backend price"}
      elif (price_for($s.model)) != null then (price_for($s.model)) as $p |
        {cost: (($s.input_tokens * $p.input + $s.output_tokens * $p.output
                 + $s.cache_read_tokens * ($p.cache_read // $p.input) + $s.cache_write_tokens * ($p.cache_write // $p.input)) / 1000000), basis: "models.dev"}
      elif ($backend != null and gpu_rate > 0) then
        (((($s.ended_at // $s.last_activity_at // $s.started_at) - $s.started_at) | if . < 0 then 0 else . end) as $secs |
         {cost: ($secs / 3600 * gpu_rate), basis: "GPU time (est.)"})
      else {cost: null, basis: "unknown"} end;
    (map(. as $s | cost_of($s) as $c | {
        id: $s.id, agent: $name, title: (if $s.title != "" then $s.title else "session " + $s.id end),
        model: (if $s.model != "" then $s.model else $profile.model end), provider: (if $s.billing_provider != "" then $s.billing_provider else $provider end),
        backend: ($backend.id // $provider),
        started: ($s.started_at | floor), ended: ($s.ended_at // null | if . == null then null else floor end),
        last: (($s.last_activity_at // $s.ended_at // $s.started_at) | floor),
        input: $s.input_tokens, output: $s.output_tokens, cache_read: $s.cache_read_tokens, cache_write: $s.cache_write_tokens,
        reasoning: $s.reasoning_tokens, prompt: ($s.input_tokens + $s.cache_read_tokens + $s.cache_write_tokens),
        api_calls: $s.api_call_count, tool_calls: $s.tool_call_count, messages: $s.message_count,
        cost_usd: $c.cost, cost_basis: $c.basis, parent_session: $s.parent_session_id })) as $tasks
    | {
        name: $name, agent: $agent, provider: $provider, model: $profile.model, auth: $auth,
        role: ($profile.role // "worker"), parent: ($profile.parent // ""), backend: ($backend.id // $provider),
        task_title: ($profile.task_title // ""),
        has_usage: ($agent == "hermes"),
        sessions: ($tasks | length),
        input: ($tasks | map(.input) | add // 0), output: ($tasks | map(.output) | add // 0),
        cache_read: ($tasks | map(.cache_read) | add // 0), cache_write: ($tasks | map(.cache_write) | add // 0),
        reasoning: ($tasks | map(.reasoning) | add // 0), prompt: ($tasks | map(.prompt) | add // 0),
        cost_usd: ($tasks | map(.cost_usd // 0) | add // 0),
        cost_unknown: ($tasks | map(select(.cost_usd == null)) | length),
        cost_bases: ($tasks | map(.cost_basis) | unique),
        last: ($tasks | map(.last) | max // null),
        tasks: $tasks
      }' <<<"$sessions"
}

# The whole picture, one document. usage_json
usage_json() {
  local now pf; now=$(date +%s); pf=$(mktemp "${TMPDIR:-/tmp}/oal-prices.XXXXXX"); usage_catalog_prices >"$pf"
  local n first=1
  {
    printf '{"generated":%s,"agents":[' "$now"
    while IFS= read -r n; do
      [[ -n $n ]] || continue; (( first )) || printf ','; first=0
      usage_agent_json "$n" "$pf" "$now"
    done < <(profile_list)
    printf '],"backends":%s}' "$(declare -F backends_usage_json >/dev/null && backends_usage_json "$now" || printf '[]')"
  } | jq -c --argjson now "$now" '
    (.agents | map(.tasks[]) | sort_by(-.last)) as $tasks
    | ($now - ($now % 86400)) as $midnight
    | . + {
        tasks: $tasks,
        totals: {
          agents: (.agents | length), sessions: ($tasks | length),
          input: ($tasks | map(.input) | add // 0), output: ($tasks | map(.output) | add // 0),
          cache_read: ($tasks | map(.cache_read) | add // 0), cache_write: ($tasks | map(.cache_write) | add // 0),
          reasoning: ($tasks | map(.reasoning) | add // 0), prompt: ($tasks | map(.prompt) | add // 0),
          total: ($tasks | map(.prompt + .output) | add // 0),
          tokens_cost_usd: ($tasks | map(.cost_usd // 0) | add // 0),
          gpu_cost_usd: (.backends | map(.gpu_cost_usd // 0) | add // 0),
          cost_usd: (($tasks | map(.cost_usd // 0) | add // 0) + (.backends | map(.gpu_cost_usd // 0) | add // 0)),
          cost_unknown: ($tasks | map(select(.cost_usd == null)) | length),
          today_cost_usd: ([$tasks[] | select(.last >= $midnight)] | map(.cost_usd // 0) | add // 0),
          today_prompt: ([$tasks[] | select(.last >= $midnight)] | map(.prompt) | add // 0),
          today_output: ([$tasks[] | select(.last >= $midnight)] | map(.output) | add // 0)
        }
      }
    | .agents |= map(del(.tasks))'
  rm -f "$pf"
}

# Human summary. usage_print
usage_print() {
  local u; u=$(usage_json)
  jq -r 'def usd: if . == null then "$?" else "$" + ((. * 10000 | round) / 10000 | tostring) end;
    "Totals: \(.totals.prompt) prompt tokens (\(.totals.input) input + \(.totals.cache_read) cache read + \(.totals.cache_write) cache write) · \(.totals.output) output · \(.totals.cost_usd | usd) over \(.totals.sessions) task(s), \(.totals.agents) agent(s)"
    + (if .totals.gpu_cost_usd > 0 then "  (incl. \(.totals.gpu_cost_usd | usd) GPU time)" else "" end)
    + (if .totals.cost_unknown > 0 then "  · \(.totals.cost_unknown) task(s) with unknown cost" else "" end),
    "Today:  \(.totals.today_prompt) prompt · \(.totals.today_output) output · \(.totals.today_cost_usd | usd)"' <<<"$u"
  echo; echo "Per agent:"
  jq -r 'def usd: if . == null then "$?" else "$" + ((. * 10000 | round) / 10000 | tostring) end;
    .agents[] | "  \(.name)\t\(.role)\t\(.backend)/\(.model)\t\(.prompt) prompt · \(.output) out · \(.cost_usd | usd)\t[\(.cost_bases | join(", "))]" + (if .has_usage then "" else "\t(no usage data for \(.agent))" end)' <<<"$u" | column -t -s $'\t'
  echo; echo "Per task (newest first; a task is one agent session):"
  jq -r 'def usd: if . == null then "$?" else "$" + ((. * 10000 | round) / 10000 | tostring) end;
    .tasks[:40][] | "  \(.last | strftime("%m-%d %H:%M"))\t\(.agent)\t\(.title[:48])\t\(.model)\t\(.prompt) prompt · \(.output) out · \(.cost_usd | usd)\t\(.cost_basis)"' <<<"$u" | column -t -s $'\t'
  jq -r '.backends[] | select(.gpu_cost_usd > 0) | "  backend \(.id): \(.runtime_seconds / 60 | floor) GPU-minutes on \(.gpu) ×\(.gpu_count) ≈ $\((.gpu_cost_usd * 100 | round) / 100)"' <<<"$u"
}
