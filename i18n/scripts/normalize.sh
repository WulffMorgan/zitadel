#!/usr/bin/env bash
# Normalize all ZITADEL translation catalogs in place:
# recursive alphabetical key sort, 2-space indent, trailing newline.
#
# Usage (from anywhere):
#   ./i18n/scripts/normalize.sh
#
# Requires: mikefarah yq (v4+) and jq on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=catalogs.sh
source "${SCRIPT_DIR}/catalogs.sh"

die() {
  echo "error: $*" >&2
  exit 1
}

require_tools() {
  command -v jq >/dev/null 2>&1 || die "jq is required on PATH"
  command -v yq >/dev/null 2>&1 || die "yq (mikefarah v4+) is required on PATH"

  # mikefarah yq reports "yq (https://github.com/mikefarah/yq/) version v4.x"
  # kislyuk/yq (apt) is a different tool and does not support sort_keys(..).
  local yq_version
  yq_version="$(yq --version 2>&1 || true)"
  if [[ ! "$yq_version" =~ mikefarah ]] && [[ ! "$yq_version" =~ version\ v?[4-9] ]]; then
    die "need mikefarah yq v4+ (got: ${yq_version})"
  fi
}

# Write normalized content via a temp file in the same directory, then replace.
normalize_json() {
  local file="$1"
  local dir tmp
  dir="$(dirname "$file")"
  tmp="$(mktemp "${dir}/.i18n-normalize.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp}'" RETURN

  if ! jq -S . "$file" >"$tmp"; then
    rm -f "$tmp"
    die "failed to parse JSON: ${file}"
  fi
  # jq -S already emits a trailing newline.
  mv "$tmp" "$file"
  trap - RETURN
}

normalize_yaml() {
  local file="$1"
  local dir tmp
  dir="$(dirname "$file")"
  tmp="$(mktemp "${dir}/.i18n-normalize.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp}'" RETURN

  # -P pretty-prints; sort_keys(..) sorts recursively; --indent 2.
  if ! yq --indent 2 -P 'sort_keys(..)' "$file" >"$tmp"; then
    rm -f "$tmp"
    die "failed to parse YAML: ${file}"
  fi
  # Ensure exactly one trailing newline.
  if [[ -s "$tmp" ]] && [[ "$(tail -c1 "$tmp" | wc -l)" -eq 0 ]]; then
    printf '\n' >>"$tmp"
  fi
  mv "$tmp" "$file"
  trap - RETURN
}

main() {
  require_tools
  cd "$REPO_ROOT"
  # catalogs.sh loads mapper into a workdir
  i18n_load_mapper || die "failed to load mapper"

  local total=0
  local id path format file count

  for id in "${I18N_ROUTE_MATCHES[@]}"; do
    count=0
    format="$(i18n_catalog_format "$id")"
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      case "$format" in
        json) normalize_json "$file" ;;
        yaml) normalize_yaml "$file" ;;
        *) die "unsupported format: ${format}" ;;
      esac
      count=$((count + 1))
      total=$((total + 1))
    done < <(i18n_catalog_files "$id")

    path="$(i18n_catalog_path "$id")"
    echo "${id}: ${count} file(s) (${path#"${REPO_ROOT}/"})"
  done

  echo "normalized ${total} file(s)"
}

main "$@"
