#!/usr/bin/env bash
# Read runtime catalogs into i18n/locales/<locale>.yaml via mapper routes.
# Key structure from i18n/schema.yaml. Gaps → __MISSING; extras → __EXTRA.
# Alias mismatches → unified__CONFLICT with joined distinct values.
#
# Usage:
#   ./i18n/scripts/import.sh
#   ./i18n/scripts/import.sh sv
#   ./i18n/scripts/import.sh --template en
#   ./i18n/scripts/import.sh sv da --template en

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=catalogs.sh
source "${SCRIPT_DIR}/catalogs.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

print_help() {
  echo "Usage: $0 [--template locale] [locale...]"
  echo "  --template locale  Unified file i18n/locales/<locale>.yaml used for __MISSING values"
  echo "                     (default: none → null). Lookup: bare key, then key__MISSING, else null."
  echo "  locale...          Only import these locales (default: all)."
  echo
  echo "Update key structure with: ./i18n/scripts/update-schema.sh [locale]"
}

TEMPLATE_LOCALE=""
REQUESTED_LOCALES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --template)
      shift
      [[ $# -gt 0 ]] || i18n_die "--template requires a locale (e.g. en)"
      TEMPLATE_LOCALE="$1"
      shift
      ;;
    --template=*)
      TEMPLATE_LOCALE="${1#--template=}"
      [[ -n "$TEMPLATE_LOCALE" ]] || i18n_die "--template requires a locale (e.g. en)"
      shift
      ;;
    -h | --help)
      print_help
      exit 0
      ;;
    -*)
      i18n_die "unknown option: $1 (try --help)"
      ;;
    *)
      REQUESTED_LOCALES+=("$1")
      shift
      ;;
  esac
done

# Build unified JSON for a locale against the schema into $out_file.
build_locale_doc_file() {
  local locale="$1"
  local schema_file="$2"
  local out_file="$3"
  local template_json="${4:-}"
  local runtime_file merged_file

  i18n_ensure_workdir
  runtime_file="${I18N_WORKDIR}/runtime-unified-${locale}.json"
  i18n_build_runtime_unified_file "$locale" "$runtime_file" "import"

  merged_file="${I18N_WORKDIR}/merged-full-${locale}.json"
  if [[ -n "$template_json" && -f "$template_json" ]]; then
    i18n_merge_missing_files "$schema_file" "$runtime_file" "$template_json" >"$merged_file"
  else
    i18n_merge_missing_files "$schema_file" "$runtime_file" >"$merged_file"
  fi

  jq -S . "$merged_file" >"$out_file"
}

main() {
  i18n_require_tools
  cd "$REPO_ROOT"
  mkdir -p "${I18N_SOURCE_DIR}"
  i18n_ensure_workdir
  i18n_require_mapper

  [[ -f "${I18N_SCHEMA_FILE}" ]] || i18n_die "missing ${I18N_SCHEMA_FILE#"${REPO_ROOT}/"} — run ./i18n/scripts/update-schema.sh first"

  local schema_json template_json=""
  schema_json="${I18N_WORKDIR}/schema.json"
  yq -o=json -I=0 '.' "${I18N_SCHEMA_FILE}" >"$schema_json"
  i18n_schema_ensure_alias_homes_file "$schema_json"
  echo "schema: ${I18N_SCHEMA_FILE#"${REPO_ROOT}/"}"
  echo "mapper: ${I18N_MAPPER_FILE#"${REPO_ROOT}/"}"

  if [[ -n "$TEMPLATE_LOCALE" ]]; then
    local tmpl_yaml
    tmpl_yaml="$(i18n_source_file "$TEMPLATE_LOCALE")"
    [[ -f "$tmpl_yaml" ]] || i18n_die "missing template unified file: ${tmpl_yaml#"${REPO_ROOT}/"}"
    template_json="${I18N_WORKDIR}/template-${TEMPLATE_LOCALE}.json"
    yq -o=json -I=0 '.' "$tmpl_yaml" >"$template_json"
    echo "template: ${tmpl_yaml#"${REPO_ROOT}/"} (for __MISSING values)"
  else
    echo "template: none (__MISSING values are null)"
  fi

  local -a all_locales=()
  local -a locales=()
  local locale dest doc_file missing extra conflict
  mapfile -t all_locales < <(i18n_all_locales)
  [[ ${#all_locales[@]} -gt 0 ]] || i18n_die "no locales found in catalogs"

  if [[ ${#REQUESTED_LOCALES[@]} -eq 0 ]]; then
    locales=("${all_locales[@]}")
  else
    local -A known=()
    for locale in "${all_locales[@]}"; do
      known["$locale"]=1
    done
    for locale in "${REQUESTED_LOCALES[@]}"; do
      [[ -n "${known[$locale]+x}" ]] || i18n_die "unknown locale '${locale}' (not present in any runtime catalog)"
      locales+=("$locale")
    done
  fi

  echo "importing ${#locales[@]} locale(s) → ${I18N_SOURCE_DIR#"${REPO_ROOT}/"}/"

  for locale in "${locales[@]}"; do
    doc_file="${I18N_WORKDIR}/doc-${locale}.json"
    build_locale_doc_file "$locale" "$schema_json" "$doc_file" "$template_json"
    missing="$(i18n_count_missing_file "$doc_file")"
    extra="$(i18n_count_extra_file "$doc_file")"
    conflict="$(i18n_count_conflict_file "$doc_file")"
    dest="$(i18n_source_file "$locale")"
    i18n_write_yaml_from_json_file "$doc_file" "$dest"
    echo "${locale}: written (${missing} __MISSING, ${extra} __EXTRA, ${conflict} __CONFLICT)"
  done

  echo "import complete"
}

main "$@"
