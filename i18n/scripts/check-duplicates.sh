#!/usr/bin/env bash
# Find duplicate string values within unified locale files and report which
# key-groups recur across locales. Uses bash + yq + jq only (no Python).
#
# Usage:
#   ./i18n/scripts/check-duplicates.sh
#   ./i18n/scripts/check-duplicates.sh sv da en
#   ./i18n/scripts/check-duplicates.sh --verbose en da
#
# - Within a locale, keys that share the same non-empty scalar value form a group.
# - Key paths are normalized by stripping __MISSING from each segment
#   (so title__MISSING counts as title for grouping).
# - Keys under any __EXTRA segment are ignored entirely.
# - Across locales, each group (set of keys that are equal somewhere) is scored by
#   how many locales have those keys all equal to each other.
# - null / empty values are ignored (avoids clumping all null __MISSING stubs).
# - Default report: per-locale counts + full cross-locale summary.
#   Pass --verbose to list every group per locale.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=catalogs.sh
source "${SCRIPT_DIR}/catalogs.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

print_help() {
  echo "Usage: $0 [--verbose] [locale...]"
  echo "  --verbose  List every duplicate group per locale (default: counts only)"
  echo "  locale...  Only analyze these unified locales (default: all in i18n/locales/)."
}

VERBOSE=0
REQUESTED=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose)
      VERBOSE=1
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
      REQUESTED+=("$1")
      shift
      ;;
  esac
done

# Flatten unified locale JSON → { "dotted.path": value } with normalized path keys.
# shellcheck disable=SC2016
I18N_JQ_FLATTEN='
def norm_seg:
  sub("__MISSING$"; "");
def is_extra($p):
  any($p[]; tostring | endswith("__EXTRA"));
[
  paths as $p
  | select((getpath($p) | type) != "object")
  | select(is_extra($p) | not)
  | {
      path: ($p | map(tostring | norm_seg) | join(".")),
      value: getpath($p)
    }
]
| group_by(.path)
| map(
    (map(select(.value != null and .value != ""))[0] // .[0])
  )
| map(select(.value != null and .value != ""))
| map({key: .path, value: .value})
| from_entries
'

# From flat map → array of sorted path-arrays (duplicate groups).
# shellcheck disable=SC2016
I18N_JQ_GROUPS='
to_entries
| map(select(.value != null and .value != ""))
| group_by(.value)
| map(select(length >= 2) | map(.key) | sort)
| sort_by(-length, join("="))
'

i18n_require_tools
cd "$REPO_ROOT"
i18n_ensure_workdir

[[ -d "${I18N_SOURCE_DIR}" ]] || i18n_die "missing ${I18N_SOURCE_DIR#"${REPO_ROOT}/"}"

mapfile -t ALL_LOCALES < <(i18n_source_locales)
[[ ${#ALL_LOCALES[@]} -gt 0 ]] || i18n_die "no locales in ${I18N_SOURCE_DIR#"${REPO_ROOT}/"}"

LOCALES=()
if [[ ${#REQUESTED[@]} -eq 0 ]]; then
  LOCALES=("${ALL_LOCALES[@]}")
else
  declare -A KNOWN=()
  for loc in "${ALL_LOCALES[@]}"; do
    KNOWN["$loc"]=1
  done
  for loc in "${REQUESTED[@]}"; do
    [[ -n "${KNOWN[$loc]+x}" ]] || i18n_die "unknown locale '${loc}'"
    LOCALES+=("$loc")
  done
fi

TOTAL="${#LOCALES[@]}"
echo "analyzed ${TOTAL} locale(s) under ${I18N_SOURCE_DIR#"${REPO_ROOT}/"}"
echo

GROUPS_ALL="${I18N_WORKDIR}/groups-all.json"
echo '[]' >"$GROUPS_ALL"

echo "== per locale =="
for loc in "${LOCALES[@]}"; do
  yaml="$(i18n_source_file "$loc")"
  json="${I18N_WORKDIR}/raw-${loc}.json"
  flat="${I18N_WORKDIR}/flat-${loc}.json"
  groups="${I18N_WORKDIR}/groups-${loc}.json"

  yq -o=json -I=0 '.' "$yaml" >"$json"
  jq -c "$I18N_JQ_FLATTEN" "$json" >"$flat"
  jq -c "$I18N_JQ_GROUPS" "$flat" >"$groups"

  count="$(jq 'length' "$groups")"
  echo "${loc}: ${count} duplicate group(s)"

  if [[ "$VERBOSE" -eq 1 ]]; then
    jq -r --slurpfile flat "$flat" '
      .[] as $g
      | ($g | join("=")) as $label
      | ($flat[0][$g[0]] | tostring) as $vs
      | "  \($label)\n    value: \($vs | if length > 80 then .[0:77] + "..." else . end)"
    ' "$groups"
  fi

  jq -c -n --slurpfile a "$GROUPS_ALL" --slurpfile b "$groups" '
    ($a[0] + $b[0])
    | unique_by(join("\u0001"))
  ' >"${I18N_WORKDIR}/groups-all-next.json"
  mv "${I18N_WORKDIR}/groups-all-next.json" "$GROUPS_ALL"
done
echo

echo "== cross locale =="

# Merge all flat maps into one object: { locale: { path: value } }
FLATS_OBJ="${I18N_WORKDIR}/flats.json"
echo '{}' >"$FLATS_OBJ"
for loc in "${LOCALES[@]}"; do
  jq -c -n --slurpfile doc "$FLATS_OBJ" --slurpfile flat "${I18N_WORKDIR}/flat-${loc}.json" --arg loc "$loc" \
    '$doc[0] + {($loc): $flat[0]}' >"${I18N_WORKDIR}/flats-next.json"
  mv "${I18N_WORKDIR}/flats-next.json" "$FLATS_OBJ"
done

LOCALE_LIST_JSON="$(printf '%s\n' "${LOCALES[@]}" | jq -R -s -c 'split("\n") | map(select(length>0))')"

jq -r -n \
  --argjson locales "$LOCALE_LIST_JSON" \
  --argjson total "$TOTAL" \
  --slurpfile all "$GROUPS_ALL" \
  --slurpfile flats "$FLATS_OBJ" '
  def has_group($flat; $g):
    ($g | map($flat[.])) as $vals
    | ($vals | all(. != null and . != ""))
      and (($vals | unique | length) == 1);

  def group_label($g): $g | join("=");

  ($all[0]) as $groups
  | ($flats[0]) as $flats
  | [
      $groups[] as $g
      | {
          g: $g,
          matching: [$locales[] as $loc | select(has_group($flats[$loc]; $g)) | $loc],
        }
      | .n = (.matching | length)
      | select(.n > 0)
    ]
  | sort_by(-.n, -(.g | length), group_label(.g)) as $ranked
  | reduce $ranked[] as $row ({prev: -1, out: []};
      .prev as $prev
      | ($row.n) as $n
      | .out += (
          if ($prev != -1 and $prev != $n) then [""] else [] end
          + [
              ($row.matching | join(", ")) as $match
              | ($locales - $row.matching | join(", ")) as $miss
              | if ($miss | length) > 0 then
                  "\($n)/\($total): not \($miss) | \(group_label($row.g)) (\($match))"
                else
                  "\($n)/\($total): \(group_label($row.g)) (\($match))"
                end
            ]
        )
      | .prev = $n
    )
  | .out[]
'

UNIQUE="$(jq 'length' "$GROUPS_ALL")"
echo
echo "summary: ${UNIQUE} unique duplicate group(s) across ${TOTAL} locale(s)"
