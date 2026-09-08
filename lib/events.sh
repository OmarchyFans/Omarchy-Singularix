#!/bin/bash
# Event log, blockers, and settings for the Agent Launcher.
#
#   ~/.local/state/omarchy-agent-launcher/events.jsonl   append-only log, one JSON object per line
#   ~/.local/state/omarchy-agent-launcher/blockers.json  open blockers, {"<agent>/<key>": {...}}
#   ~/.config/omarchy-agent-launcher/settings.json       user settings (notify_blockers, ...)
#
# Everything is local: jq, flock, and (for toasts) omarchy-notification-send.

OAL_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-agent-launcher"
OAL_EVENTS="$OAL_STATE/events.jsonl"
OAL_BLOCKERS="$OAL_STATE/blockers.json"
OAL_EVENTS_LOCK="$OAL_STATE/events.lock"
OAL_EVENTS_MAX_BYTES=${OAL_EVENTS_MAX_BYTES:-2097152}
OAL_PLUGIN_ID="fans.omarchy.agent-launcher"

# ---- settings -----------------------------------------------------------------
settings_get() { # settings_get <key> <default>
  local f="$OAL_CONF/settings.json"
  if [[ -f $f ]]; then jq -r --arg k "$1" --arg d "$2" '(if has($k) then .[$k] else $d end) | tostring' "$f" 2>/dev/null || printf '%s' "$2"
  else printf '%s' "$2"; fi
}
settings_set() { # settings_set <key> <value>  (true/false/numbers stay typed)
  mkdir -p "$OAL_CONF"; local f="$OAL_CONF/settings.json" tmp
  [[ -s $f ]] || printf '{}\n' >"$f"
  tmp=$(mktemp "$OAL_CONF/.settings.XXXXXX")
  jq --arg k "$1" --arg v "$2" '.[$k] = (if $v == "true" then true elif $v == "false" then false elif ($v|test("^-?[0-9]+$")) then ($v|tonumber) else $v end)' "$f" >"$tmp" && mv -f "$tmp" "$f"
}

# ---- blockers ---------------------------------------------------------------
blockers_json() { [[ -s $OAL_BLOCKERS ]] && cat "$OAL_BLOCKERS" || printf '{}'; }
blockers_count() { blockers_json | jq 'length'; }

# Apply one event to blockers.json (caller holds the events lock).
blockers_apply() { # blockers_apply <event-json>
  local ev=$1 cur new tmp
  cur=$(blockers_json)
  new=$(jq -c --argjson e "$ev" '
    ($e.agent + "/" + $e.key) as $id
    | if $e.level == "blocker" then .[$id] = {t:$e.t, ts:$e.ts, agent:$e.agent, key:$e.key, kind:$e.kind, task:$e.task, message:$e.message, ref:$e.ref}
      elif $e.kind == "blocker_cleared" then (if $e.key != "" then del(.[$id]) else with_entries(select(.value.agent != $e.agent)) end)
      elif $e.kind == "signed_in" then del(.[$e.agent + "/signin"])
      elif $e.kind == "session_started" then del(.[$e.agent + "/exit"]) | del(.[$e.agent + "/prepare"])
      elif ($e.kind == "removed" or $e.kind == "destroyed") then with_entries(select(.value.agent != $e.agent))
      else . end' <<<"$cur") || return 0
  [[ $new == "$cur" ]] && return 0
  tmp=$(mktemp "$OAL_STATE/.blockers.XXXXXX"); printf '%s\n' "$new" >"$tmp"; mv -f "$tmp" "$OAL_BLOCKERS"
}

# ---- emit ---------------------------------------------------------------------
# event_emit <agent> <kind> <message> [--task T] [--level info|warn|blocker] [--key K] [--code N] [--source S] [--ref R]
event_emit() {
  local agent=$1 kind=$2 message=$3; shift 3
  local task="" level=info key="" code=0 source=launcher ref=""
  while (($#)); do
    case "$1" in
      --task) task=$2; shift 2 ;; --level) level=$2; shift 2 ;; --key) key=$2; shift 2 ;;
      --code) code=$2; shift 2 ;; --source) source=$2; shift 2 ;; --ref) ref=$2; shift 2 ;;
      *) warn "event: unknown option $1"; return 2 ;;
    esac
  done
  [[ $level == info || $level == warn || $level == blocker ]] || { warn "event: level must be info, warn, or blocker"; return 2; }
  [[ $level == blocker && -z $key ]] && key=$(slugify "$message")
  local t ts line
  t=$(date +%s%3N); ts=$(date -Is)
  line=$(jq -nc --argjson t "$t" --arg ts "$ts" --arg agent "$agent" --arg kind "$kind" --arg level "$level" \
    --arg key "$key" --arg task "$task" --arg message "$message" --argjson code "${code:-0}" --arg source "$source" --arg ref "$ref" \
    '{t:$t, ts:$ts, agent:$agent, kind:$kind, level:$level, key:$key, task:$task, message:$message, code:$code, source:$source, ref:$ref}')
  mkdir -p "$OAL_STATE"
  {
    flock -w 5 9 || true
    printf '%s\n' "$line" >>"$OAL_EVENTS"
    local size; size=$(stat -c %s "$OAL_EVENTS" 2>/dev/null || echo 0)
    if (( size > OAL_EVENTS_MAX_BYTES )); then mv -f "$OAL_EVENTS" "$OAL_STATE/events.1.jsonl"; fi
    blockers_apply "$line"
  } 9>"$OAL_EVENTS_LOCK"
  if [[ $level == blocker && $(settings_get notify_blockers true) == true ]]; then
    local -a toast=(omarchy-notification-send -u critical -g "󱚝" "$agent: $message" "${task:+task $task · }open the Agent Dashboard"
                    --exec omarchy-shell shell summon "$OAL_PLUGIN_ID" "{\"tab\":\"notifications\",\"agent\":\"$agent\"}")
    if (( OAL_DRY_RUN )); then run "${toast[@]}"
    elif have omarchy-notification-send; then "${toast[@]}" >/dev/null 2>&1 || true; fi
  fi
  return 0
}

# Recent events as a JSON array (bad lines skipped). events_recent [n]
events_recent() { [[ -f $OAL_EVENTS ]] || { printf '[]'; return; }; tail -n "${1:-2000}" "$OAL_EVENTS" | jq -R 'fromjson? // empty' | jq -sc .; }
