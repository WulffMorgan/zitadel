#!/usr/bin/env bash
# Compare unified locale files against i18n/schema.yaml.
# Reports __MISSING, __EXTRA, __CONFLICT, and unroutable keys (not under a
# route match and not an alias unified home). Exit 1 if any remain.
#
# Usage:
#   ./i18n/scripts/check-keys.sh
#   ./i18n/scripts/check-keys.sh --summary

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=catalogs.sh
source "${SCRIPT_DIR}/catalogs.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

print_help() {
  echo "Usage: $0 [--summary]"
  echo "  --summary  Per-locale counts only (no key lists). Useful for CI logs."
}

SUMMARY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --summary)
      SUMMARY=1
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
      i18n_die "unexpected argument: $1 (try --help)"
      ;;
  esac
done

main() {
  i18n_require_tools
  cd "$REPO_ROOT"
  i18n_ensure_workdir
  i18n_require_mapper

  [[ -f "${I18N_SCHEMA_FILE}" ]] || i18n_die "missing schema: ${I18N_SCHEMA_FILE} (run update-schema.sh)"

  local schema_json_file locales locale loc_json_file
  schema_json_file="$(i18n_schema_to_json_file schema.json)"

  mapfile -t locales < <(i18n_source_locales)
  [[ ${#locales[@]} -gt 0 ]] || i18n_die "no files in ${I18N_SOURCE_DIR}"

  local missing_total=0
  local extra_total=0
  local conflict_total=0
  local unroutable_total=0

  for locale in "${locales[@]}"; do
    loc_json_file="$(i18n_source_to_json_file "$locale" "source-${locale}.json")"

    local report
    report="$(jq -r -n --slurpfile en "$schema_json_file" --slurpfile loc "$loc_json_file" '
      def leaves:
        [
          paths as $p
          | select(getpath($p) | type != "object")
          | $p
          | map(tostring)
          | join(".")
        ];
      def norm_path:
        split(".") | map(sub("__MISSING$"; "") | sub("__EXTRA$"; "") | sub("__CONFLICT$"; "")) | join(".");
      ($en[0]) as $e
      | ($loc[0]) as $l
      | ($e | leaves) as $ep
      | ($l | leaves) as $lp
      | ($lp | map(norm_path) | map({(.): true}) | add // {}) as $lmap
      | ($lp | map(select(split(".") | map(tostring) | any(endswith("__MISSING"))))) as $missing
      | ($lp | map(select(split(".") | map(tostring) | any(endswith("__EXTRA"))))) as $extra
      | ($lp | map(select(split(".") | map(tostring) | any(endswith("__CONFLICT"))))) as $conflict
      | ($ep
          | map(select($lmap[.] | not))
          | map(. + " (absent)")
        ) as $absent
      | {
          missing: ($missing + $absent | unique | sort),
          extra: ($extra | unique | sort),
          conflict: ($conflict | unique | sort)
        }
      | "MISSING_COUNT\t\(.missing | length)",
        "EXTRA_COUNT\t\(.extra | length)",
        "CONFLICT_COUNT\t\(.conflict | length)",
        (.missing[] | "MISSING\t\(.)"),
        (.extra[] | "EXTRA\t\(.)"),
        (.conflict[] | "CONFLICT\t\(.)")
    ')"

    local miss_c=0 extra_c=0 conflict_c=0
    local -a miss_lines=() extra_lines=() conflict_lines=()
    local kind val
    while IFS=$'\t' read -r kind val; do
      [[ -n "${kind:-}" ]] || continue
      case "$kind" in
        MISSING_COUNT) miss_c="$val" ;;
        EXTRA_COUNT) extra_c="$val" ;;
        CONFLICT_COUNT) conflict_c="$val" ;;
        MISSING) miss_lines+=("$val") ;;
        EXTRA) extra_lines+=("$val") ;;
        CONFLICT) conflict_lines+=("$val") ;;
      esac
    done <<<"$report"

    local -a unroutable_lines=()
    local u
    while IFS= read -r u; do
      [[ -n "$u" ]] || continue
      unroutable_lines+=("$u")
    done < <(i18n_unroutable_source_keys_file "$loc_json_file")
    local unrout_c="${#unroutable_lines[@]}"

    if [[ "$SUMMARY" -eq 0 ]]; then
      if [[ "$miss_c" -gt 0 || "$extra_c" -gt 0 || "$conflict_c" -gt 0 || "$unrout_c" -gt 0 ]]; then
        echo "== ${locale} =="
        if [[ "$miss_c" -gt 0 ]]; then
          echo "  missing (${miss_c}):"
          local m
          for m in "${miss_lines[@]}"; do
            echo "    ${m}"
          done
        fi
        if [[ "$extra_c" -gt 0 ]]; then
          echo "  extra (${extra_c}):"
          local e
          for e in "${extra_lines[@]}"; do
            echo "    ${e}"
          done
        fi
        if [[ "$conflict_c" -gt 0 ]]; then
          echo "  conflict (${conflict_c}):"
          local c
          for c in "${conflict_lines[@]}"; do
            echo "    ${c}"
          done
        fi
        if [[ "$unrout_c" -gt 0 ]]; then
          echo "  unroutable (${unrout_c}):"
          for u in "${unroutable_lines[@]}"; do
            echo "    ${u}"
          done
        fi
      fi
    fi

    if [[ "$miss_c" -eq 0 && "$extra_c" -eq 0 && "$conflict_c" -eq 0 && "$unrout_c" -eq 0 ]]; then
      echo "${locale}: ok"
    else
      echo "${locale}: ${miss_c} missing, ${extra_c} extra, ${conflict_c} conflict, ${unrout_c} unroutable"
    fi
    missing_total=$((missing_total + miss_c))
    extra_total=$((extra_total + extra_c))
    conflict_total=$((conflict_total + conflict_c))
    unroutable_total=$((unroutable_total + unrout_c))
  done

  echo "summary: ${missing_total} __MISSING/absent, ${extra_total} __EXTRA, ${conflict_total} __CONFLICT, ${unroutable_total} unroutable"
  if [[ "$missing_total" -gt 0 || "$extra_total" -gt 0 || "$conflict_total" -gt 0 || "$unroutable_total" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
