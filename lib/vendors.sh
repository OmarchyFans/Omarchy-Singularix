#!/bin/bash
# Vendor facts for the model picker: where each API vendor processes data, whether
# it trains on API data by default, and the "IP-safe" badge derived from both.
#
# Facts live in data/vendors.json, keyed by the models.dev provider id, each with
# the vendor's own source pages and the date they were reviewed. Nothing here is
# a legal opinion; a fact that could not be confirmed on the vendor's own pages is
# null, and a null fact is shown as "unverified", never guessed.
#
# Badge and ip_safe (derived, never stored):
#   unsafe / false      any processing country is outside the safe jurisdictions,
#                       or the vendor trains on API data by default (opt-out only)
#   safe / true         does not train on API data by default and every
#                       processing country is a safe jurisdiction
#   unverified / null   the vendor does not publish one of those facts
#   varies / null       aggregators (data goes to whichever upstream serves it)

OAL_VENDORS_FILE="${OAL_VENDORS_FILE:-$OAL_ROOT/data/vendors.json}"
# Jurisdictions with enforceable IP protection for foreign customers. EU = the
# EU as a whole; member states are listed too because vendors name them.
OAL_IP_SAFE_JURISDICTIONS="${OAL_IP_SAFE_JURISDICTIONS:-US,CA,GB,EU,AT,BE,BG,HR,CY,CZ,DK,EE,FI,FR,DE,GR,HU,IE,IT,LV,LT,LU,MT,NL,PL,PT,RO,SK,SI,ES,SE,CH,NO,IS,JP,KR,AU,NZ,SG}"

vendors_json() { [[ -s $OAL_VENDORS_FILE ]] && cat "$OAL_VENDORS_FILE" || printf '{}'; }

# One vendor with the derived fields. vendor_json <models.dev provider id>
#   -> {id, label, country, countries, trains_on_api_data, aggregator, ip_safe, basis, sources, reviewed}
#   badge: "safe" | "unsafe" | "unverified" (a required fact is not published) |
#          "varies" (aggregator) | null (no entry for this vendor)
vendor_json() {
  vendors_json | jq -c --arg id "$1" --arg safe "$OAL_IP_SAFE_JURISDICTIONS" '
    ($safe | split(",")) as $ok
    | (.[$id] // {}) as $v
    | ($v.processing_countries // null) as $pc
    | ($v.stored_countries // null) as $sc
    | (if ($v | length) == 0 then null
       elif $v.aggregator == true then "varies"
       elif $pc != null and ($pc | any(. as $c | $ok | index($c) | not)) then "unsafe"
       elif $v.trains_on_api_data == true then "unsafe"
       elif $v.trains_on_api_data == false and $pc != null then "safe"
       else "unverified" end) as $badge
    | {
        id: $id,
        label: ($v.label // null),
        countries: $pc,
        country: (if ($v | length) == 0 then null
                  elif $v.aggregator == true then "varies"
                  elif $pc != null then ($pc | join(", "))
                  elif $sc != null then "stored " + ($sc | join(", "))
                  elif $v.hq_country != null then "HQ " + $v.hq_country
                  else "unknown" end),
        trains_on_api_data: (if $v | has("trains_on_api_data") then $v.trains_on_api_data else null end),
        aggregator: ($v.aggregator // false),
        basis: ($v.basis // null),
        sources: ($v.sources // []),
        reviewed: ($v.reviewed // null),
        badge: $badge,
        ip_safe: (if $badge == "safe" then true elif $badge == "unsafe" then false else null end)
      }'
}

# The model picker tree (the Rix page reads this via `models --json`):
# {
#   local:  {served, rows: [{backend, model, name, served, source}]},
#   online: [{backend, provider, label, vendor, vendor_label, ready, state, needs,
#             country, ip_safe, badge, basis, aggregator, trains_on_api_data, sources, reviewed,
#             models: [{id, name, input, output, context}]}]
# }
# Online entries: one per API provider row (usable ones first), then your registry
# backends (endpoints and GPU servers) as their own entries. Selecting a row runs
# `rix setup <backend> <model>`.
models_tree_json() {
  local served="" files="[]" ollama="[]"
  if declare -F local_online >/dev/null && local_online; then
    served=$(local_models_json 2>/dev/null | jq -r '.[0].id // ""')
  fi
  declare -F local_gguf_files >/dev/null && files=$(local_gguf_files | jq -R . | jq -sc .)
  if have ollama; then
    ollama=$(ollama list 2>/dev/null | awk 'NR>1 && $1 != "" {print $1}' | jq -R . | jq -sc .)
  fi
  local local_json
  local_json=$(jq -nc --arg served "$served" --argjson files "$files" --argjson ollama "$ollama" '
    {served: $served,
     rows: (
       ($files | map({backend: "local", model: ., name: (sub("\\.gguf$"; "")), served: (. == $served), source: "llama.cpp"}))
       + (if ($served != "" and ($files | index($served) | not)) then [{backend: "local", model: $served, name: ($served | sub("\\.gguf$"; "")), served: true, source: "llama.cpp"}] else [] end)
       + ($ollama | map({backend: "ollama", model: ., name: ., served: false, source: "ollama"}))
     )}')

  local BACKEND_SIGNED; BACKEND_SIGNED=$(backends_signed_providers)
  local p id entries=()
  for p in $(providers_all_ids); do
    case $p in local|ollama|endpoint) continue ;; esac
    local b key vendor models
    b=$(backend_from_provider "$p") || continue
    key=$(models_catalog_key "$p")
    vendor=$(vendor_json "$key")
    models=$(models_for_provider "$p" 2>/dev/null) || models="[]"
    entries+=("$(jq -nc --argjson b "$b" --argjson v "$vendor" --argjson m "$models" --arg key "$key" '
      {backend: $b.id, provider: $b.provider, label: $b.label, vendor: $key,
       vendor_label: ($v.label // $b.label), ready: $b.ready, state: $b.state,
       needs: (if $b.ready then "" else $b.state end),
       country: $v.country, ip_safe: $v.ip_safe, badge: $v.badge, basis: $v.basis, aggregator: $v.aggregator,
       trains_on_api_data: $v.trains_on_api_data, sources: $v.sources, reviewed: $v.reviewed,
       models: ($m | map({id, name, input, output, context}))}')")
  done
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    local b; b=$(backend_get "$id" 2>/dev/null) || continue
    entries+=("$(jq -nc --argjson b "$b" '
      {backend: $b.id, provider: "endpoint", label: ($b.label // $b.id), vendor: "endpoint",
       vendor_label: "Your backends", ready: $b.ready, state: ($b.state // ""),
       needs: (if $b.ready then "" else "not running: backends start " + $b.id end),
       country: null, ip_safe: null, badge: null, basis: "A backend you run or were given; its location is whatever you chose.",
       aggregator: false, trains_on_api_data: null, sources: [], reviewed: null,
       models: [{id: $b.model, name: $b.model, input: ($b.input_per_m // null), output: ($b.output_per_m // null), context: ($b.model_ctx // null)}]}')")
  done < <(backend_ids)

  local online="[]"
  (( ${#entries[@]} )) && online=$(printf '%s\n' "${entries[@]}" | jq -sc 'sort_by(if .ready then 0 else 1 end)')
  jq -nc --argjson l "$local_json" --argjson o "$online" '{local: $l, online: $o}'
}

# Plain listing for a terminal.
models_tree_print() {
  models_tree_json | jq -r '
    def price: if .input == null then "" else "  $\(.input) / $\(.output) per M" end;
    def badge: {"safe": "  [IP-safe]", "unsafe": "  [not IP-safe]", "unverified": "  [IP unverified]", "varies": "  [IP varies]"}[.badge // ""] // "";
    "Local models" + (if .local.served != "" then " (serving \(.local.served))" else "" end),
    (.local.rows[] | "  \(.model)" + (if .served then "  *" else "" end)),
    "",
    (.online[] | "\(.vendor_label) · \(.label)  [\(if .ready then "ready" else .needs end)]  \(.country // "?")\(badge)",
      (.models[] | "  \(.id)\(price)"))'
}
