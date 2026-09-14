#!/bin/bash
# Sentinel -> harness bridge: puts a Sentinel advisory onto the harness Gantt
# (docs/HARNESS.md) as one edge (or, for a wide fix, a small container of
# edges) under the Sentinel project for its repo, so the harness — not Rix —
# decides when it is done.
#
# Rix's side of an advisory (state/worker/note) lives in
# $OAL_STATE/sentinel-advisories.json (lib/sentinel.sh). This file adds two
# more fields to that same per-advisory object: harness_project, harness_node
# — the mapping that makes `sentinel plan` idempotent (re-running never adds
# a second child) and lets a future `sentinel verify` read the node's state
# with `harness show --project P --node N` instead of re-deriving it.

# POST /api/project/{id}/patch  {action, parent, children, source} — the only
# way a plan is created or extended; the harness validates each edge child
# (a real oracle, 1-2 touches).
harness_bridge_patch() { # <project> <body-json>
  local project=$1 body=$2
  if (( OAL_DRY_RUN )); then say "[dry-run] would POST $(harness_url)/api/project/$project/patch $body"; return 0; fi
  curl -sS -m 5 -H 'X-Harness: 1' -H 'Content-Type: application/json' \
    -X POST -d "$body" "$(harness_url)/api/project/$project/patch" >/dev/null 2>&1
}

# POST /api/project/{id}/assign {node, session}
harness_bridge_assign() { # <project> <node> <session>
  local project=$1 node=$2 session=$3 body
  body=$(jq -nc --arg node "$node" --arg session "$session" '{node:$node, session:$session}')
  if (( OAL_DRY_RUN )); then say "[dry-run] would POST $(harness_url)/api/project/$project/assign $body"; return 0; fi
  curl -sS -m 5 -H 'X-Harness: 1' -H 'Content-Type: application/json' \
    -X POST -d "$body" "$(harness_url)/api/project/$project/assign" >/dev/null 2>&1
}

# The id of a just-added child of <parent> whose title matches, read back via
# `harness show` (the patch endpoint's own response isn't trusted for this).
harness_bridge_find_child() { # <bin> <project> <parent> <title>
  local bin=$1 project=$2 parent=$3 title=$4 node
  node=$("$bin" show --project "$project" --node "$parent" 2>/dev/null) || return 1
  jq -r --arg t "$title" '(.children // [])[] | select(.title == $t) | .id' <<<"$node" | tail -n1
}

# Merge {harness_project, harness_node} into this advisory's record in
# sentinel-advisories.json, alongside Rix's own state/worker/note fields.
sentinel_bridge_record() { # <advisory-id> <project> <node>
  mkdir -p "$OAL_STATE"
  local tmp; tmp=$(mktemp "$OAL_STATE/sentinel-advisories.XXXXXX")
  jq --arg id "$1" --arg p "$2" --arg n "$3" \
    '.[$id] = ((.[$id] // {}) + {harness_project:$p, harness_node:$n})' \
    <<<"$(sentinel_handled_json)" >"$tmp" && mv -f "$tmp" "$OAL_SENTINEL_HANDLED"
}

harness_bridge_estimate_min() { # <severity>
  case "$1" in
    low) printf 15 ;;
    high|critical) printf 60 ;;
    *) printf 30 ;;
  esac
}

# One ADD_CHILDREN edge: {title, kind:edge, oracle, touches, estimate_min, doc}.
harness_bridge_edge_json() { # <title> <doc> <oracle-json> <touches-json-array> <estimate_min>
  jq -nc --arg title "${1:0:120}" --arg doc "$2" --argjson oracle "$3" --argjson touches "$4" --argjson est "$5" \
    '{title:$title, kind:"edge", oracle:$oracle, touches:$touches, estimate_min:$est, doc:$doc}'
}

# sentinel_plan ADVISORY_ID [--project ID] [--assign rix]
#
# Reads the advisory from sentinel_advisories_json (id, title, summary,
# severity, repo_path, a verification command, affected files), picks or
# creates the harness project for its repo (`sentinel-<repo-slug>`, via
# `harness init` when `harness ls --json` has none for that repo), then
# ADD_CHILDREN one edge (title/doc/touches/oracle/estimate_min) under the
# project's root node "P0" — or, when there are more than two affected
# files, one container child under "P0" with up to four edge children of at
# most two touches each. Idempotent: an advisory already recorded with a
# harness_node short-circuits straight to the print (and, with --assign,
# still (re)issues the assign). With --assign, hands the node to the
# registered rix session for that project (the harness decides done, never
# Rix or this script).
sentinel_plan() {
  local id=$1; shift || true
  [[ -n $id ]] || fail "usage: omarchy-agent-launcher sentinel plan ID [--project ID] [--assign rix]"
  local project_override="" assign=""
  while (( $# )); do
    case "$1" in
      --project) project_override=${2:-}; shift 2 ;;
      --assign)  assign=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  sentinel_installed || fail "Sentinel is not installed: https://github.com/OmarchyFans/Omarchy-Rix-Sentinel-mode"
  local bin; bin=$(harness_bin) || return 1

  local adv; adv=$(sentinel_advisories_json | jq -c --arg id "$id" '[.[] | select(.id == $id)][0] // empty')
  [[ -n $adv ]] || fail "no Sentinel advisory $id"

  local title doc severity repo verify_cmd
  title=$(jq -r '(.title // "Sentinel advisory")[0:120]' <<<"$adv")
  severity=$(jq -r '.severity // "medium"' <<<"$adv")
  repo=$(jq -r '.repo_path // .repo // empty' <<<"$adv")
  [[ -n $repo ]] || fail "Sentinel advisory $id has no repo_path; cannot plan a harness project for it"
  verify_cmd=$(jq -r '.verification // .verify_cmd // .oracle_cmd // empty' <<<"$adv")
  doc=$(jq -r --arg id "$id" '(.summary // .description // "") + "\n\nSentinel advisory " + $id' <<<"$adv")
  local -a files=()
  mapfile -t files < <(jq -r '(.affected_files // .files // .touches // [])[]?' <<<"$adv")
  local estimate_min; estimate_min=$(harness_bridge_estimate_min "$severity")

  local handled; handled=$(sentinel_handled_json)
  local existing_node existing_project
  existing_node=$(jq -r --arg id "$id" '.[$id].harness_node // empty' <<<"$handled")
  existing_project=$(jq -r --arg id "$id" '.[$id].harness_project // empty' <<<"$handled")

  local project node created=false
  if [[ -n $existing_node ]]; then
    project=$existing_project; node=$existing_node
  else
    project=${project_override:-$existing_project}
    if [[ -z $project ]]; then project="sentinel-$(slugify "$repo")"; fi
    if ! "$bin" ls --json 2>/dev/null | jq -e --arg p "$project" 'any(.[]?; .id == $p)' >/dev/null 2>&1; then
      if (( OAL_DRY_RUN )); then
        say "[dry-run] would: $bin init --id $project --repo $repo --goal 'resolve Sentinel advisories for $repo' --done-when 'no open Sentinel advisories for $repo'"
      else
        "$bin" init --id "$project" --repo "$repo" --goal "resolve Sentinel advisories for $repo" \
          --done-when "no open Sentinel advisories for $repo" >/dev/null || fail "harness init failed for project $project"
      fi
    fi

    local oracle
    if [[ -n $verify_cmd ]]; then oracle=$(jq -nc --arg cmd "$verify_cmd" '{type:"cmd", cmd:$cmd}')
    else oracle='{"type":"session_ack"}'
    fi

    if (( ${#files[@]} <= 2 )); then
      local touches='[]' child body
      if (( ${#files[@]} > 0 )); then touches=$(printf '%s\n' "${files[@]}" | jq -R . | jq -sc .); fi
      child=$(harness_bridge_edge_json "$title" "$doc" "$oracle" "$touches" "$estimate_min")
      body=$(jq -nc --argjson child "$child" '{action:"ADD_CHILDREN", parent:"P0", children:[$child], source:"cli"}')
      harness_bridge_patch "$project" "$body" || true
      node=$(harness_bridge_find_child "$bin" "$project" P0 "$title") || true
    else
      local container cbody
      container=$(jq -nc --arg title "${title:0:120}" --arg doc "$doc" --argjson est "$estimate_min" \
        '{title:$title, kind:"container", touches:[], estimate_min:$est, doc:$doc}')
      cbody=$(jq -nc --argjson child "$container" '{action:"ADD_CHILDREN", parent:"P0", children:[$child], source:"cli"}')
      harness_bridge_patch "$project" "$cbody" || true
      node=$(harness_bridge_find_child "$bin" "$project" P0 "$title") || true
      [[ -n $node ]] || fail "harness did not report the container node for $id"

      local -a echildren=()
      local i=0 part=1
      while (( i < ${#files[@]} && part <= 4 )); do
        local -a chunk=("${files[@]:i:2}")
        local ctitle ctouches
        ctitle="${title:0:110} (part $part)"
        ctouches=$(printf '%s\n' "${chunk[@]}" | jq -R . | jq -sc .)
        echildren+=("$(harness_bridge_edge_json "$ctitle" "$doc" "$oracle" "$ctouches" "$estimate_min")")
        i=$(( i + 2 )); part=$(( part + 1 ))
      done
      local ebody; ebody=$(printf '%s\n' "${echildren[@]}" | jq -sc --arg parent "$node" '{action:"ADD_CHILDREN", parent:$parent, children:., source:"cli"}')
      harness_bridge_patch "$project" "$ebody" || true
    fi
    [[ -n $node ]] || fail "harness did not report the new node for advisory $id"
    sentinel_bridge_record "$id" "$project" "$node"
    event_emit "${OAL_AGENT:-$RIX_NAME}" note "Sentinel advisory $id planned as $project/$node" --task "Sentinel advisories" --key "sentinel-$id" --source harness
    created=true
  fi

  local assigned=false
  if [[ -n $assign ]]; then
    local sess sid
    sess=$(jq -c --arg p "$project" '.sessions[]? | select(.project == $p and .worker == "rix")' <<<"$(harness_overview_json)" | head -n1)
    sid=$(jq -r '.id // empty' <<<"$sess")
    if [[ -n $sid ]]; then
      if harness_bridge_assign "$project" "$node" "$sid"; then assigned=true; fi
    else
      warn "harness plan: no rix session registered for project $project (omarchy-agent-launcher harness register <profile> $repo)"
    fi
  fi

  if (( JSON )); then
    jq -nc --arg id "$id" --arg project "$project" --arg node "$node" --argjson created "$created" --argjson assigned "$assigned" \
      '{id:$id, project:$project, node:$node, created:$created, assigned:$assigned}'
  else
    say "$id -> project $project, node $node$( [[ $created == true ]] || printf ' (already planned)' )$( [[ $assigned == true ]] && printf ' - assigned to rix' )"
  fi
}
