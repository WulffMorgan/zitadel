# Shared inventory / mapper loader for locale tooling.
# Source from other scripts: source "$(dirname "$0")/catalogs.sh"
#
# Requires REPO_ROOT to be set to the monorepo root before sourcing,
# or sets it from the caller's BASH_SOURCE / this file's location.

if [[ -z "${REPO_ROOT:-}" ]]; then
  _catalogs_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "${_catalogs_dir}/../.." && pwd)"
  unset _catalogs_dir
fi

# Settings under i18n/
I18N_DIR="${REPO_ROOT}/i18n"
I18N_SCHEMA_FILE="${I18N_DIR}/schema.yaml"
I18N_MAPPER_FILE="${I18N_DIR}/mapper.yaml"
I18N_SOURCE_DIR="${I18N_DIR}/locales"

# Populated by i18n_load_mapper (route match prefixes in file order).
I18N_ROUTE_MATCHES=()

# Cached mapper JSON path (set by i18n_load_mapper).
I18N_MAPPER_JSON=""

# Load and validate mapper.yaml → work JSON; fill I18N_ROUTE_MATCHES.
i18n_load_mapper() {
  local raw out
  [[ -f "${I18N_MAPPER_FILE}" ]] || {
    echo "error: missing mapper: ${I18N_MAPPER_FILE}" >&2
    return 1
  }

  # workdir may not exist yet when catalogs.sh is sourced; create lightly
  if [[ -z "${I18N_WORKDIR:-}" ]]; then
    I18N_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/i18n-work.XXXXXX")"
    # shellcheck disable=SC2064
    trap 'rm -rf "'"${I18N_WORKDIR}"'"' EXIT
  fi

  raw="${I18N_WORKDIR}/mapper-raw.json"
  out="${I18N_WORKDIR}/mapper.json"
  yq -o=json -I=0 '.' "${I18N_MAPPER_FILE}" >"$raw"

  # Validate + normalize into { routes: [...], aliases: [...] }
  jq -c -e -n --slurpfile doc "$raw" '
    def norm_match:
      sub("\\.\\*\\*$"; "") | sub("\\.\\*$"; "");
    def seg_count:
      if . == "" then 0 else (split(".") | length) end;
    def is_route: has("path") and has("match") and has("format");
    def is_alias: has("unified") and has("mapsTo");
    def has_route($key; $rms):
      any($rms[]; . as $r | $key == $r or ($key | startswith($r + ".")));

    ($doc[0] // []) as $entries
    | if ($entries | type) != "array" then
        error("mapper.yaml must be a list of entries")
      else . end
    | reduce $entries[] as $e
        ({routes: [], aliases: [], route_matches: {}, alias_unified: {}, maps_to_owner: {}};
          if ($e | is_route | not) and ($e | is_alias | not) then
            error("mapper entry must be a route (match/path/format) or alias (unified/mapsTo): \($e)")
          elif ($e | is_route) and ($e | is_alias) then
            error("mapper entry cannot be both route and alias: \($e)")
          elif ($e | is_route) then
            ($e.match | norm_match) as $m
            | if $m == "" then error("route match must be non-empty") else . end
            | if ($e.format != "yaml" and $e.format != "json") then
                error("route \($m): format must be yaml or json")
              else . end
            | if (.route_matches | has($m)) then
                error("duplicate route match: \($m)")
              else . end
            | .route_matches[$m] = true
            | .routes += [{
                match: $m,
                path: $e.path,
                format: $e.format,
                locale_pointer: ($e.locale_pointer // null),
                specificity: ($m | seg_count)
              }]
          else
            ($e.unified | tostring) as $u
            | if $u == "" then error("alias unified must be non-empty") else . end
            | if (.alias_unified | has($u)) then
                error("duplicate alias unified: \($u)")
              else . end
            | if ($e.mapsTo | type) != "array" or ($e.mapsTo | length) == 0 then
                error("alias \($u): mapsTo must be a non-empty array")
              else . end
            | .alias_unified[$u] = true
            | reduce ($e.mapsTo[]) as $t
                (.;
                  ($t | tostring) as $tp
                  | if (.maps_to_owner | has($tp)) then
                      error("mapsTo target \($tp) claimed by multiple aliases")
                    else . end
                  | .maps_to_owner[$tp] = $u
                )
            | .aliases += [{
                unified: $u,
                mapsTo: ($e.mapsTo | map(tostring)),
                specificity: ($u | seg_count)
              }]
          end
        )
    | . as $built
    | ($built.routes | map(.match)) as $rms
    | reduce $built.aliases[] as $a
        ($built;
          reduce $a.mapsTo[] as $t
            (.;
              if has_route($t; $rms) then .
              else error("mapsTo \($t) has no matching route")
              end
            )
        )
    | {routes: .routes, aliases: .aliases}
  ' >"$out" || {
    echo "error: invalid mapper.yaml" >&2
    return 1
  }

  I18N_MAPPER_JSON="$out"
  mapfile -t I18N_ROUTE_MATCHES < <(jq -r '.routes[].match' "$out")
  # Back-compat alias used by older script loops
  I18N_CATALOG_IDS=("${I18N_ROUTE_MATCHES[@]}")
}

# Ensure mapper is loaded (idempotent).
i18n_ensure_mapper() {
  if [[ -z "${I18N_MAPPER_JSON:-}" || ! -f "${I18N_MAPPER_JSON}" ]]; then
    i18n_load_mapper
  fi
}

# Look up a route object by match → stdout JSON.
i18n_route_by_match() {
  local match="$1"
  i18n_ensure_mapper
  jq -c -e --arg m "$match" '.routes[] | select(.match == $m)' "${I18N_MAPPER_JSON}" \
    || {
      echo "error: unknown route match: ${match}" >&2
      return 1
    }
}

# Namespace for a route = match prefix (back-compat name).
i18n_catalog_namespace() {
  local id="$1"
  i18n_route_by_match "$id" >/dev/null || return 1
  printf '%s\n' "$id"
}

# Absolute path for a route: directory (per-locale files) or file (locale_pointer).
i18n_catalog_path() {
  local id="$1"
  local route path_tmpl pointer abs
  route="$(i18n_route_by_match "$id")" || return 1
  path_tmpl="$(jq -r '.path' <<<"$route")"
  pointer="$(jq -r '.locale_pointer // empty' <<<"$route")"
  if [[ -n "$pointer" ]]; then
    abs="${REPO_ROOT}/${path_tmpl}"
    abs="${abs//\/\//\/}"
    printf '%s\n' "$abs"
    return 0
  fi
  # Strip {locale} and filename → directory
  local dir_part
  dir_part="$(dirname "${path_tmpl//\{locale\}/*}")"
  # dirname of "internal/static/i18n/*" → internal/static/i18n
  dir_part="${path_tmpl%%\{locale\}*}"
  dir_part="${dir_part%/}"
  printf '%s\n' "${REPO_ROOT}/${dir_part}"
}

i18n_catalog_format() {
  local id="$1"
  local route
  route="$(i18n_route_by_match "$id")" || return 1
  jq -r '.format' <<<"$route"
}

# Resolve concrete filesystem path for a route + locale.
i18n_route_resolve_path() {
  local id="$1"
  local locale="$2"
  local route path_tmpl pointer
  route="$(i18n_route_by_match "$id")" || return 1
  path_tmpl="$(jq -r '.path' <<<"$route")"
  pointer="$(jq -r '.locale_pointer // empty' <<<"$route")"
  if [[ -n "$pointer" ]]; then
    printf '%s\n' "${REPO_ROOT}/${path_tmpl}"
  else
    printf '%s\n' "${REPO_ROOT}/${path_tmpl//\{locale\}/${locale}}"
  fi
}

# Whether route uses a multi-locale document.
i18n_route_has_locale_pointer() {
  local id="$1"
  local route
  route="$(i18n_route_by_match "$id")" || return 1
  [[ "$(jq -r '.locale_pointer // empty' <<<"$route")" != "" ]]
}

# Print absolute paths of locale files for a route, one per line.
i18n_catalog_files() {
  local id="$1"
  local route path_tmpl pointer abs format dir ext

  route="$(i18n_route_by_match "$id")" || return 1
  path_tmpl="$(jq -r '.path' <<<"$route")"
  pointer="$(jq -r '.locale_pointer // empty' <<<"$route")"
  format="$(jq -r '.format' <<<"$route")"

  if [[ -n "$pointer" ]]; then
    abs="${REPO_ROOT}/${path_tmpl}"
    if [[ -f "$abs" ]]; then
      printf '%s\n' "$abs"
    else
      echo "missing catalog file: ${abs}" >&2
      return 1
    fi
    return 0
  fi

  dir="$(i18n_catalog_path "$id")"
  if [[ ! -d "$dir" ]]; then
    echo "missing catalog directory: ${dir}" >&2
    return 1
  fi
  case "$format" in
    yaml) ext=yaml ;;
    json) ext=json ;;
  esac
  find "$dir" -maxdepth 1 -type f -name "*.${ext}" | LC_ALL=C sort
}

# Print locale codes present in a route, one per line.
i18n_catalog_locales() {
  local id="$1"
  local route path_tmpl pointer abs format file base

  route="$(i18n_route_by_match "$id")" || return 1
  pointer="$(jq -r '.locale_pointer // empty' <<<"$route")"

  if [[ -n "$pointer" ]]; then
    abs="$(i18n_catalog_path "$id")" || return 1
    if [[ ! -f "$abs" ]]; then
      return 0
    fi
    jq -r 'keys[]' "$abs" | LC_ALL=C sort
    return 0
  fi

  format="$(jq -r '.format' <<<"$route")"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    base="$(basename "$file")"
    case "$format" in
      yaml) printf '%s\n' "${base%.yaml}" ;;
      json) printf '%s\n' "${base%.json}" ;;
    esac
  done < <(i18n_catalog_files "$id")
}

# Union of locale codes across all routes, sorted.
i18n_all_locales() {
  local id
  i18n_ensure_mapper
  for id in "${I18N_ROUTE_MATCHES[@]}"; do
    i18n_catalog_locales "$id"
  done | LC_ALL=C sort -u
}

# Absolute path of a unified locale file.
i18n_source_file() {
  local locale="$1"
  echo "${I18N_SOURCE_DIR}/${locale}.yaml"
}

# List unified locale codes (basenames without .yaml).
i18n_source_locales() {
  if [[ ! -d "${I18N_SOURCE_DIR}" ]]; then
    return 0
  fi
  find "${I18N_SOURCE_DIR}" -maxdepth 1 -type f -name '*.yaml' -printf '%f\n' \
    | sed 's/\.yaml$//' \
    | LC_ALL=C sort
}

# Most specific route match for a dotted key → match string on stdout; empty if none.
i18n_best_route_match() {
  local key="$1"
  i18n_ensure_mapper
  jq -r --arg key "$key" '
    [.routes[]
      | select($key == .match or ($key | startswith(.match + ".")))
    ]
    | sort_by(-.specificity)
    | if length == 0 then empty
      elif length > 1 and (.[0].specificity == .[1].specificity) then
        error("ambiguous route match for \($key): \(.[0].match) vs \(.[1].match)")
      else .[0].match
      end
  ' "${I18N_MAPPER_JSON}"
}

# Strip route match prefix from a dotted key → remainder (may be empty for exact match).
i18n_strip_match_prefix() {
  local match="$1"
  local key="$2"
  if [[ "$key" == "$match" ]]; then
    printf '\n'
  elif [[ "$key" == "$match".* ]]; then
    printf '%s\n' "${key#"${match}".}"
  else
    echo "error: key '${key}' does not start with match '${match}'" >&2
    return 1
  fi
}
