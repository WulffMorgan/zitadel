#!/usr/bin/env bash
# Write unified i18n/locales/<locale>.yaml back to runtime catalogs via mapper routes.
# Creates missing locale destination files.
# __MISSING / __CONFLICT keys are omitted; __EXTRA written under bare names.
# Aliases expand (unified → mapsTo) before routing. Conflicted/missing aliases
# do not fan out; each mapsTo leaf is passed through from the current runtime.
#
# Usage: ./i18n/scripts/export.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=catalogs.sh
source "${SCRIPT_DIR}/catalogs.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

main() {
  i18n_require_tools
  cd "$REPO_ROOT"
  i18n_ensure_workdir
  i18n_require_mapper

  [[ -d "${I18N_SOURCE_DIR}" ]] || i18n_die "missing ${I18N_SOURCE_DIR} (run import.sh first)"

  local locales locale loc_file prepared expanded id body_file ref_file
  mapfile -t locales < <(i18n_source_locales)
  [[ ${#locales[@]} -gt 0 ]] || i18n_die "no unified locale files"

  local count=0
  for locale in "${locales[@]}"; do
    loc_file="$(i18n_source_to_json_file "$locale" "export-source-${locale}.json")"
    prepared="${I18N_WORKDIR}/export-prepared-${locale}.json"
    i18n_export_missing_file "$loc_file" >"$prepared"

    # Reference tree from runtime catalogs (keeps literal dotted keys for path resolve).
    ref_file="${I18N_WORKDIR}/export-ref-${locale}.json"
    i18n_build_runtime_raw_file "$locale" "$ref_file"
    # If a catalog is empty for this locale, merge en so path shapes still resolve.
    if [[ "$(jq 'length' "$ref_file")" -eq 0 ]]; then
      i18n_build_runtime_raw_file "en" "$ref_file"
    fi

    expanded="${I18N_WORKDIR}/export-expanded-${locale}.json"
    i18n_alias_expand_file "$prepared" "$ref_file" >"$expanded"
    i18n_assert_all_routable_file "$expanded" || i18n_die "export aborted for locale ${locale}"

    for id in "${I18N_ROUTE_MATCHES[@]}"; do
      body_file="${I18N_WORKDIR}/export-body-${locale}-${id}.json"
      i18n_extract_route_tree "$id" "$expanded" >"$body_file"
      i18n_route_write_locale "$id" "$locale" "$body_file"
    done

    count=$((count + 1))
    echo "exported ${locale}"
  done

  echo "export complete (${count} locale(s))"
}

main "$@"
