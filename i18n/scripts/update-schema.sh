#!/usr/bin/env bash
# Rebuild i18n/schema.yaml from a locale's runtime catalogs (null leaves).
# Routes + aliases from mapper.yaml. Alias value conflicts abort.
#
# Usage:
#   ./i18n/scripts/update-schema.sh        # default: en
#   ./i18n/scripts/update-schema.sh en
#   ./i18n/scripts/update-schema.sh sv

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=catalogs.sh
source "${SCRIPT_DIR}/catalogs.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

print_help() {
  echo "Usage: $0 [locale]"
  echo "  locale  Runtime locale used as key structure (default: en)"
}

LOCALE="en"
for arg in "$@"; do
  case "$arg" in
    -h | --help)
      print_help
      exit 0
      ;;
    -*)
      i18n_die "unknown option: ${arg}"
      ;;
    *)
      LOCALE="$arg"
      ;;
  esac
done

build_schema_from_locale() {
  local locale="$1"
  local out_file="$2"
  local id body_file pref_file acc_file next_file collapsed schema_json

  i18n_require_mapper
  acc_file="${I18N_WORKDIR}/schema-acc.json"
  echo '{}' >"$acc_file"

  for id in "${I18N_ROUTE_MATCHES[@]}"; do
    body_file="$(i18n_catalog_locale_to_file "$id" "$locale" "src-${locale}-${id}.json")"
    if [[ "$(jq -r 'type' "$body_file")" == "object" && "$(jq 'length' "$body_file")" -eq 0 ]]; then
      body_file="$(i18n_catalog_locale_to_file "$id" "en" "src-en-fallback-${id}.json")"
      echo "  ${id}: ${locale} empty/missing, using en for structure" >&2
    fi
    pref_file="${I18N_WORKDIR}/schema-pref-${id}.json"
    i18n_prefix_route_tree "$id" "$body_file" "$pref_file" >/dev/null
    next_file="${I18N_WORKDIR}/schema-acc-next.json"
    i18n_merge_json_files "$acc_file" "$pref_file" >"$next_file"
    mv "$next_file" "$acc_file"
  done

  collapsed="${I18N_WORKDIR}/schema-collapsed.json"
  if ! i18n_alias_collapse_file "$acc_file" "die" >"$collapsed" 2>"${I18N_WORKDIR}/schema-collapse.err"; then
    cat "${I18N_WORKDIR}/schema-collapse.err" >&2
    i18n_die "update-schema aborted due to alias conflict"
  fi

  schema_json="${I18N_WORKDIR}/schema-nullified.json"
  i18n_to_schema_file "$collapsed" >"$schema_json"
  i18n_schema_ensure_alias_homes_file "$schema_json"
  jq -S . "$schema_json" >"$out_file"
}

main() {
  i18n_require_tools
  cd "$REPO_ROOT"
  mkdir -p "${I18N_DIR}"
  i18n_ensure_workdir
  i18n_require_mapper

  local schema_json id count
  schema_json="${I18N_WORKDIR}/schema.json"

  echo "updating schema from runtime locale '${LOCALE}' → ${I18N_SCHEMA_FILE#"${REPO_ROOT}/"}"
  build_schema_from_locale "$LOCALE" "$schema_json"
  i18n_write_yaml_from_json_file "$schema_json" "${I18N_SCHEMA_FILE}"

  echo "schema leaf counts by route:"
  for id in "${I18N_ROUTE_MATCHES[@]}"; do
    count="$(jq --arg ns "$id" '
      .[$ns] // {}
      | [paths as $p | select(getpath($p) | type != "object") | $p]
      | length
    ' "$schema_json")"
    echo "  ${id}: ${count}"
  done

  # Alias / synthetic top-level keys (not a route match) — one line each.
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    count="$(jq --arg ns "$id" '
      [.[$ns] // {} | paths as $p | select(getpath($p) | type != "object") | $p]
      | length
    ' "$schema_json")"
    echo "  ${id}: ${count} (alias/synthetic)"
  done < <(jq -r --argjson routes "$(jq -c '[.routes[].match]' "${I18N_MAPPER_JSON}")" '
    keys_unsorted[]
    | select((. as $k | $routes | index($k)) | not)
  ' "$schema_json")

  echo "schema update complete"
}

main "$@"
