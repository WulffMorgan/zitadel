# Shared helpers for i18n scripts.
# Source after catalogs.sh: source "$(dirname "$0")/lib.sh"

I18N_MISSING_SUFFIX="__MISSING"
I18N_CONFLICT_SUFFIX="__CONFLICT"
I18N_CONFLICT_JOIN=" | "

i18n_die() {
  echo "error: $*" >&2
  exit 1
}

i18n_require_tools() {
  command -v jq >/dev/null 2>&1 || i18n_die "jq is required on PATH"
  command -v yq >/dev/null 2>&1 || i18n_die "yq (mikefarah v4+) is required on PATH"

  local yq_version
  yq_version="$(yq --version 2>&1 || true)"
  if [[ ! "$yq_version" =~ mikefarah ]] && [[ ! "$yq_version" =~ version\ v?[4-9] ]]; then
    i18n_die "need mikefarah yq v4+ (got: ${yq_version})"
  fi
}

# Work directory for large JSON (avoids ARG_MAX with --argjson).
i18n_ensure_workdir() {
  if [[ -z "${I18N_WORKDIR:-}" ]]; then
    I18N_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/i18n-work.XXXXXX")"
    # shellcheck disable=SC2064
    trap 'rm -rf "'"${I18N_WORKDIR}"'"' EXIT
  fi
}

# Load mapper (routes + aliases) into workdir.
i18n_require_mapper() {
  i18n_ensure_workdir
  i18n_ensure_mapper || i18n_die "failed to load mapper"
}

# Write stdin to a named file under the workdir; prints the path.
i18n_work_file() {
  local name="$1"
  i18n_ensure_workdir
  local path="${I18N_WORKDIR}/${name}"
  cat >"$path"
  printf '%s\n' "$path"
}

# Read a route's locale tree (unprefixed catalog body) into a work file; prints path.
# Empty object if missing. Uses path templates / locale_pointer from mapper.
i18n_catalog_locale_to_file() {
  local id="$1"
  local locale="$2"
  local outname="$3"
  local route format pointer file out abs

  i18n_ensure_workdir
  i18n_require_mapper
  out="${I18N_WORKDIR}/${outname}"
  route="$(i18n_route_by_match "$id")" || return 1
  format="$(jq -r '.format' <<<"$route")"
  pointer="$(jq -r '.locale_pointer // empty' <<<"$route")"
  abs="$(i18n_route_resolve_path "$id" "$locale")"

  if [[ -n "$pointer" ]]; then
    if [[ ! -f "$abs" ]]; then
      echo '{}' >"$out"
    else
      jq -c --arg loc "$locale" '.[$loc] // {}' "$abs" >"$out"
    fi
    printf '%s\n' "$out"
    return 0
  fi

  file="$abs"
  case "$format" in
    yaml)
      if [[ ! -f "$file" ]]; then
        echo '{}' >"$out"
      else
        yq -o=json -I=0 '.' "$file" >"$out"
      fi
      ;;
    json)
      if [[ ! -f "$file" ]]; then
        echo '{}' >"$out"
      else
        jq -c '.' "$file" >"$out"
      fi
      ;;
    *)
      i18n_die "unsupported format: ${format}"
      ;;
  esac
  printf '%s\n' "$out"
}

# Write an unprefixed locale tree to a route destination.
i18n_route_write_locale() {
  local id="$1"
  local locale="$2"
  local body_file="$3"
  local route format pointer abs dest dir tmp next

  i18n_require_mapper
  route="$(i18n_route_by_match "$id")" || return 1
  format="$(jq -r '.format' <<<"$route")"
  pointer="$(jq -r '.locale_pointer // empty' <<<"$route")"
  abs="$(i18n_route_resolve_path "$id" "$locale")"

  if [[ -n "$pointer" ]]; then
    dest="$abs"
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$dest" ]]; then
      jq -c '.' "$dest" >"${I18N_WORKDIR}/multi-doc-${id}.json"
    else
      echo '{}' >"${I18N_WORKDIR}/multi-doc-${id}.json"
    fi
    next="${I18N_WORKDIR}/multi-next-${id}-${locale}.json"
    jq -c -n --slurpfile doc "${I18N_WORKDIR}/multi-doc-${id}.json" --arg loc "$locale" --slurpfile body "$body_file" \
      '$doc[0] + {($loc): $body[0]}' >"$next"
    i18n_write_json_from_json_file "$next" "$dest"
    return 0
  fi

  dest="$abs"
  mkdir -p "$(dirname "$dest")"
  case "$format" in
    yaml) i18n_write_yaml_from_json_file "$body_file" "$dest" ;;
    json) i18n_write_json_from_json_file "$body_file" "$dest" ;;
    *) i18n_die "unsupported format: ${format}" ;;
  esac
}

# Prefix a catalog body with route match → { match: body } file on stdout path printed.
i18n_prefix_route_tree() {
  local match="$1"
  local body_file="$2"
  local out_file="$3"
  jq -c -n --arg ns "$match" --slurpfile body "$body_file" '{($ns): $body[0]}' >"$out_file"
  printf '%s\n' "$out_file"
}

# Extract unprefixed body for a route match from a unified doc file → stdout.
i18n_extract_route_tree() {
  local match="$1"
  local doc_file="$2"
  jq -c --arg ns "$match" '.[$ns] // {}' "$doc_file"
}

# jq helpers: resolve dotted mapper paths against a tree using greedy
# longest-key matching so literal keys that contain dots (e.g. "v2.added")
# are not split into nested objects.
# shellcheck disable=SC2016
I18N_JQ_DOTTED_PATH_DEFS='
def dotted_parts($path):
  $path | split(".") | map(select(length > 0));
# How many leading parts form an existing key at $node? Prefer longer.
def longest_key_len($node; $parts):
  if ($node | type) != "object" or ($parts | length) == 0 then 0
  else
    reduce range(($parts | length); 0; -1) as $n
      (0;
        if . > 0 then .
        else
          ($parts[0:$n] | join(".")) as $cand
          | if ($node | has($cand)) then $n else 0 end
        end
      )
  end;
# Resolve $dotted to an array of real key segments by walking $root.
# When nothing matches, fall back to one segment at a time (create/nested).
def greedy_segs($root; $dotted):
  def walk($node; $parts):
    if ($parts | length) == 0 then []
    else
      (longest_key_len($node; $parts)) as $n
      | if $n > 0 then
          ($parts[0:$n] | join(".")) as $key
          | [$key] + walk($node[$key]; $parts[$n:])
        else
          [$parts[0]] + walk(
            (if ($node | type) == "object" then ($node[$parts[0]] // {}) else {} end);
            $parts[1:]
          )
        end
    end;
  walk($root; dotted_parts($dotted));
def get_dotted($root; $path):
  (greedy_segs($root; $path)) as $segs
  | try ($root | getpath($segs)) catch null;
def prune_empty_ancestors($segs):
  reduce range(($segs | length) - 1; 0; -1) as $i
    (.;
      ($segs[0:$i]) as $p
      | if ($p | length) == 0 then .
        else
          (try getpath($p) catch null) as $v
          | if ($v | type) == "object" and ($v | length) == 0 then delpaths([$p])
            else .
            end
        end
    );
def del_dotted_from($path; $root_for_segs):
  (greedy_segs($root_for_segs; $path)) as $gsegs
  | (dotted_parts($path)) as $nsegs
  | delpaths([$gsegs])
  # If a prior bug left a nested form alongside a literal dotted key, remove both.
  | if $gsegs != $nsegs then delpaths([$nsegs]) else . end
  | prune_empty_ancestors($gsegs)
  | prune_empty_ancestors($nsegs);
def set_dotted_with_ref($path; $value; $ref):
  (greedy_segs($ref; $path)) as $segs
  | setpath($segs; $value);
'

# Expand aliases in doc_file → stdout compact JSON.
# Optional ref_file: tree used to resolve dotted paths (should contain literal
# keys such as "v2.added"). Defaults to doc_file.
i18n_alias_expand_file() {
  local doc_file="$1"
  local ref_file="${2:-$1}"
  local routes_file aliases_file
  i18n_require_mapper
  routes_file="${I18N_WORKDIR}/route-matches.json"
  aliases_file="${I18N_WORKDIR}/aliases.json"
  jq -c '[.routes[].match]' "${I18N_MAPPER_JSON}" >"$routes_file"
  jq -c '.aliases' "${I18N_MAPPER_JSON}" >"$aliases_file"
  # shellcheck disable=SC2016
  jq -c -n --slurpfile doc "$doc_file" --slurpfile ref "$ref_file" \
    --slurpfile aliases "$aliases_file" --slurpfile routes "$routes_file" \
    "${I18N_JQ_DOTTED_PATH_DEFS}"'
    def has_route($key; $routes):
      any($routes[]; . as $r | $key == $r or ($key | startswith($r + ".")));
    # Copy mapsTo (and routed unified) leaves from $src into ., using $resolve for path shape.
    def passthrough_alias($a; $src; $resolve; $routes):
      reduce $a.mapsTo[] as $t
        (.;
          (get_dotted($src; $t)) as $tv
          | if $tv == null then . else set_dotted_with_ref($t; $tv; $resolve) end
        )
      | if has_route($a.unified; $routes) and (($a.mapsTo | index($a.unified)) | not) then
          (get_dotted($src; $a.unified)) as $uv
          | if $uv == null then . else set_dotted_with_ref($a.unified; $uv; $resolve) end
        else .
        end;
    $doc[0] as $doc
    | $ref[0] as $ref
    | $aliases[0] as $aliases
    | $routes[0] as $route_matches
    # Ref is for dotted-path geometry (+ conflict/missing passthrough), not for fan-out values.
    | ($ref * $doc) as $resolve
    | reduce $aliases[] as $a
        ($doc;
          ($a.unified) as $u
          # Value must come from prepared unified only — never from runtime ref.
          # Otherwise stripped __CONFLICT keys get silently re-expanded from catalog.
          | (get_dotted($doc; $u)) as $val
          | if $val != null then
              reduce $a.mapsTo[] as $t
                (.; set_dotted_with_ref($t; $val; $resolve))
              | if has_route($u; $route_matches) then .
                else del_dotted_from($u; $resolve)
                end
            else
              # Conflict, __MISSING, or absent: keep existing runtime mapsTo values.
              passthrough_alias($a; $ref; $resolve; $route_matches)
            end
        )
  '
}

# Collapse aliases. mode: import | die
i18n_alias_collapse_file() {
  local doc_file="$1"
  local mode="${2:-import}"
  local routes_file aliases_file
  i18n_require_mapper
  routes_file="${I18N_WORKDIR}/route-matches.json"
  aliases_file="${I18N_WORKDIR}/aliases.json"
  jq -c '[.routes[].match]' "${I18N_MAPPER_JSON}" >"$routes_file"
  jq -c '.aliases' "${I18N_MAPPER_JSON}" >"$aliases_file"
  # shellcheck disable=SC2016
  jq -c -n --slurpfile doc "$doc_file" --slurpfile aliases "$aliases_file" --slurpfile routes "$routes_file" \
    --arg mode "$mode" --arg join "${I18N_CONFLICT_JOIN}" \
    "${I18N_JQ_DOTTED_PATH_DEFS}"'
    def has_route($key; $routes):
      any($routes[]; . as $r | $key == $r or ($key | startswith($r + ".")));
    def runtime_set($a; $routes):
      (
        $a.mapsTo
        + if has_route($a.unified; $routes) and (($a.mapsTo | index($a.unified)) | not)
          then [$a.unified] else [] end
      ) | unique;

    $doc[0] as $doc
    | $aliases[0] as $aliases
    | $routes[0] as $route_matches
    | reduce $aliases[] as $a
        ($doc;
          . as $before
          | ($a.unified) as $u
          | runtime_set($a; $route_matches) as $keys
          | [$keys[] as $k
              | {key: $k, value: get_dotted($before; $k)}
              | select(.value != null and .value != "")
            ] as $pairs
          | ([$pairs[].value] | unique) as $distinct
          | (reduce $keys[] as $k ($before; if $k == $u then . else del_dotted_from($k; $before) end)) as $cleared
          | if ($distinct | length) == 0 then
              $cleared | del_dotted_from($u; $before)
            elif ($distinct | length) == 1 then
              $cleared | set_dotted_with_ref($u; $distinct[0]; $before)
            elif $mode == "die" then
              error("alias conflict for \($u): \(
                [$pairs[] | "\(.key)=\(.value)"] | join(", ")
              )")
            else
              (greedy_segs($before; $u)) as $usegs
              | if ($usegs | length) == 0 then
                  error("empty path for conflict on \($u)")
                else
                  ($usegs[:-1] + [($usegs[-1] + "__CONFLICT")]) as $cpath
                  | $cleared
                  | del_dotted_from($u; $before)
                  | setpath($cpath; ($distinct | map(tostring) | join($join)))
                end
            end
        )
  '
}

# After export prepare + alias expand: ensure every leaf routes; error listing offenders.
i18n_assert_all_routable_file() {
  local doc_file="$1"
  local routes_file bad
  i18n_require_mapper
  routes_file="${I18N_WORKDIR}/route-matches.json"
  jq -c '[.routes[].match]' "${I18N_MAPPER_JSON}" >"$routes_file"
  bad="$(jq -r -n --slurpfile doc "$doc_file" --slurpfile routes "$routes_file" '
    def has_route($key; $routes):
      any($routes[]; . as $r | $key == $r or ($key | startswith($r + ".")));
    [$doc[0]
      | paths as $p
      | select(getpath($p) | type != "object")
      | ($p | map(tostring) | join("."))
      | select(has_route(.; $routes[0]) | not)
    ] | unique | .[]
  ')"
  if [[ -n "$bad" ]]; then
    echo "error: unroutable key(s) after alias expand:" >&2
    echo "$bad" | sed 's/^/  /' >&2
    return 1
  fi
}

# List source leaf paths that are neither under a route nor an alias unified / __CONFLICT.
i18n_unroutable_source_keys_file() {
  local doc_file="$1"
  local routes_file aliases_file
  i18n_require_mapper
  routes_file="${I18N_WORKDIR}/route-matches.json"
  aliases_file="${I18N_WORKDIR}/alias-unified.json"
  jq -c '[.routes[].match]' "${I18N_MAPPER_JSON}" >"$routes_file"
  jq -c '[.aliases[].unified]' "${I18N_MAPPER_JSON}" >"$aliases_file"
  jq -r -n --slurpfile doc "$doc_file" --slurpfile routes "$routes_file" --slurpfile aliases "$aliases_file" '
    def norm_seg: sub("__MISSING$"; "") | sub("__EXTRA$"; "") | sub("__CONFLICT$"; "");
    def norm_path: split(".") | map(norm_seg) | join(".");
    def has_route($key; $routes):
      any($routes[]; . as $r | $key == $r or ($key | startswith($r + ".")));
    def is_alias_home($key; $aliases):
      any($aliases[]; . as $u | $key == $u or ($key | startswith($u + ".")));
    [$doc[0]
      | paths as $p
      | select(getpath($p) | type != "object")
      | ($p | map(tostring) | join("."))
      | norm_path
      | select((has_route(.; $routes[0]) | not) and (is_alias_home(.; $aliases[0]) | not))
    ] | unique | .[]
  '
}

# jq: turn a value tree into a key-only schema (scalars → null; keep {}).
# shellcheck disable=SC2016
I18N_JQ_TO_SCHEMA='
def to_schema:
  if type == "object" then
    if length == 0 then {}
    else with_entries(.value |= to_schema)
    end
  else
    null
  end;
to_schema
'

# jq: merge locale onto schema template (null leaves).
# shellcheck disable=SC2016
I18N_JQ_MERGE_MISSING='
def is_obj: type == "object";
def prepare_loc($loc):
  if ($loc | type) != "object" then
    {}
  else
    reduce ($loc | keys_unsorted[]) as $k
      ({};
        if ($k | endswith("__MISSING")) then
          .
        elif ($k | endswith("__EXTRA")) then
          .[$k | sub("__EXTRA$"; "")] = $loc[$k]
        elif ($k | endswith("__CONFLICT")) then
          .[$k] = $loc[$k]
        else
          .[$k] = $loc[$k]
        end
      )
  end;
def tmpl_obj($tmpl):
  $tmpl | if is_obj then . else {} end;
def missing_value($tmpl; $k; $fallback):
  tmpl_obj($tmpl) as $t
  | if ($t | has($k)) then $t[$k]
    elif ($t | has($k + "__MISSING")) then $t[$k + "__MISSING"]
    else $fallback
    end;
def merge($schema; $loc; $tmpl):
  if ($schema | is_obj) then
    prepare_loc($loc) as $l
    | tmpl_obj($tmpl) as $t
    | reduce ($schema | keys_unsorted[]) as $k
        ({};
          if ($schema[$k] | is_obj) then
            .[$k] = merge($schema[$k]; $l[$k]; $t[$k])
          elif ($l | has($k)) then
            .[$k] = $l[$k]
          elif ($l | has($k + "__CONFLICT")) then
            .[$k + "__CONFLICT"] = $l[$k + "__CONFLICT"]
          else
            .[$k + "__MISSING"] = missing_value($t; $k; $schema[$k])
          end
        )
    | . as $base
    | reduce ($l | keys_unsorted[] | select(. as $ek |
        ($schema | has($ek) | not)
        and ($ek | endswith("__CONFLICT") | not)
        and (($ek | sub("__CONFLICT$"; "")) as $b | ($schema | has($b) | not))
      )) as $ek
        ($base; .[$ek + "__EXTRA"] = $l[$ek])
  else
    $loc
  end;
def all_keys_end($suf):
  type == "object" and length > 0 and (keys_unsorted | length > 0) and (keys_unsorted | all(endswith($suf)));
def collapse:
  if type != "object" then .
  else
    with_entries(.value |= collapse)
    | with_entries(
        if (.value | all_keys_end("__MISSING")) then
          .key += "__MISSING"
        elif (.value | all_keys_end("__EXTRA")) then
          .key += "__EXTRA"
        else
          .
        end
      )
  end;
merge($en[0]; $loc[0]; $tmpl[0]) | collapse
'

# jq: for export — drop __MISSING / __CONFLICT; unwrap __EXTRA.
# shellcheck disable=SC2016
I18N_JQ_EXPORT_MISSING='
def export_prepare:
  if type != "object" then .
  else
    with_entries(
      select((.key | endswith("__MISSING")) | not)
      | select((.key | endswith("__CONFLICT")) | not)
      | .key |= (if endswith("__EXTRA") then sub("__EXTRA$"; "") else . end)
      | .value |= export_prepare
    )
  end;
export_prepare
'

# shellcheck disable=SC2016
I18N_JQ_COUNT_MISSING='
def leaf_paths:
  paths as $p
  | select(getpath($p) | type != "object")
  | $p;
[leaf_paths | select(map(tostring) | any(endswith("__MISSING")))] | length
'

# shellcheck disable=SC2016
I18N_JQ_COUNT_EXTRA='
def leaf_paths:
  paths as $p
  | select(getpath($p) | type != "object")
  | $p;
[leaf_paths | select(map(tostring) | any(endswith("__EXTRA")))] | length
'

# shellcheck disable=SC2016
I18N_JQ_COUNT_CONFLICT='
def leaf_paths:
  paths as $p
  | select(getpath($p) | type != "object")
  | $p;
[leaf_paths | select(map(tostring) | any(endswith("__CONFLICT")))] | length
'

# shellcheck disable=SC2016
I18N_JQ_LEAF_PATHS='
def leaf_paths:
  paths as $p
  | select(getpath($p) | type != "object")
  | $p
  | map(tostring)
  | join(".");
[leaf_paths] | unique | sort | .[]
'

i18n_merge_missing_files() {
  local schema_file="$1"
  local loc_file="$2"
  local tmpl_file="${3:-}"
  local tmpl

  i18n_ensure_workdir
  if [[ -n "$tmpl_file" && -f "$tmpl_file" ]]; then
    tmpl="$tmpl_file"
  else
    tmpl="${I18N_WORKDIR}/empty-tmpl.json"
    echo '{}' >"$tmpl"
  fi
  jq -c -n --slurpfile en "$schema_file" --slurpfile loc "$loc_file" --slurpfile tmpl "$tmpl" \
    "$I18N_JQ_MERGE_MISSING"
}

i18n_to_schema_file() {
  local file="$1"
  jq -c "$I18N_JQ_TO_SCHEMA" "$file"
}

i18n_schema_to_json_file() {
  local outname="${1:-schema.json}"
  local out
  [[ -f "${I18N_SCHEMA_FILE}" ]] || i18n_die "missing schema: ${I18N_SCHEMA_FILE} (run update-schema.sh)"
  i18n_ensure_workdir
  out="${I18N_WORKDIR}/${outname}"
  yq -o=json -I=0 '.' "${I18N_SCHEMA_FILE}" >"$out"
  printf '%s\n' "$out"
}

i18n_export_missing_file() {
  local file="$1"
  jq -c "$I18N_JQ_EXPORT_MISSING" "$file"
}

i18n_count_missing_file() {
  local file="$1"
  jq "$I18N_JQ_COUNT_MISSING" "$file"
}

i18n_count_extra_file() {
  local file="$1"
  jq "$I18N_JQ_COUNT_EXTRA" "$file"
}

i18n_count_conflict_file() {
  local file="$1"
  jq "$I18N_JQ_COUNT_CONFLICT" "$file"
}

i18n_write_yaml_from_json_file() {
  local src="$1"
  local dest="$2"
  local dir tmp
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  tmp="$(mktemp "${dir}/.i18n-write.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp}'" RETURN
  yq -p=json -o=yaml --indent 2 -P 'sort_keys(..)' "$src" >"$tmp"
  if [[ -s "$tmp" ]] && [[ "$(tail -c1 "$tmp" | wc -l)" -eq 0 ]]; then
    printf '\n' >>"$tmp"
  fi
  mv "$tmp" "$dest"
  trap - RETURN
}

i18n_write_json_from_json_file() {
  local src="$1"
  local dest="$2"
  local dir tmp
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  tmp="$(mktemp "${dir}/.i18n-write.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp}'" RETURN
  jq -S . "$src" >"$tmp"
  mv "$tmp" "$dest"
  trap - RETURN
}

i18n_source_to_json_file() {
  local locale="$1"
  local outname="${2:-source-${locale}.json}"
  local file out
  file="$(i18n_source_file "$locale")"
  [[ -f "$file" ]] || i18n_die "missing unified source: ${file}"
  i18n_ensure_workdir
  out="${I18N_WORKDIR}/${outname}"
  yq -o=json -I=0 '.' "$file" >"$out"
  printf '%s\n' "$out"
}

i18n_wrap_namespace_file() {
  local ns="$1"
  local body_file="$2"
  local out_file="$3"
  jq -c -n --arg ns "$ns" --slurpfile body "$body_file" '{($ns): $body[0]}' >"$out_file"
  printf '%s\n' "$out_file"
}

i18n_merge_json_files() {
  local a="$1"
  local b="$2"
  jq -c -n --slurpfile a "$a" --slurpfile b "$b" '$a[0] * $b[0]'
}

# Ensure every alias unified path exists as a null leaf in a schema JSON file (in-place).
i18n_schema_ensure_alias_homes_file() {
  local schema_file="$1"
  local aliases_file out
  i18n_require_mapper
  aliases_file="${I18N_WORKDIR}/aliases.json"
  jq -c '.aliases' "${I18N_MAPPER_JSON}" >"$aliases_file"
  out="${I18N_WORKDIR}/schema-with-homes.json"
  jq -c -n --slurpfile schema "$schema_file" --slurpfile aliases "$aliases_file" '
    def set_null($path):
      ($path | split(".") | map(select(length > 0))) as $segs
      | if ($segs | length) == 0 then .
        else
          reduce range(0; $segs | length) as $i
            (.;
              ($segs[0:$i+1]) as $p
              | if $i == (($segs | length) - 1) then
                  if (try getpath($p) catch null) == null or ((try getpath($p) catch null) | type) != "object" then
                    setpath($p; null)
                  else .
                  end
                else
                  (try getpath($p) catch null) as $cur
                  | if ($cur | type) == "object" then .
                    else setpath($p; {})
                    end
                end
            )
        end;
    reduce $aliases[0][] as $a
      ($schema[0]; set_null($a.unified))
  ' >"$out"
  mv "$out" "$schema_file"
}

# Prefixed merge of all route catalogs for a locale (no alias collapse).
i18n_build_runtime_raw_file() {
  local locale="$1"
  local out_file="$2"
  local id body_file pref_file acc_file next_file

  i18n_require_mapper
  acc_file="${I18N_WORKDIR}/runtime-raw-acc-${locale}.json"
  echo '{}' >"$acc_file"

  for id in "${I18N_ROUTE_MATCHES[@]}"; do
    body_file="$(i18n_catalog_locale_to_file "$id" "$locale" "raw-body-${locale}-${id}.json")"
    pref_file="${I18N_WORKDIR}/raw-pref-${locale}-${id}.json"
    i18n_prefix_route_tree "$id" "$body_file" "$pref_file" >/dev/null
    next_file="${I18N_WORKDIR}/runtime-raw-acc-${locale}-next.json"
    i18n_merge_json_files "$acc_file" "$pref_file" >"$next_file"
    mv "$next_file" "$acc_file"
  done

  jq -c '.' "$acc_file" >"$out_file"
}

# Build unified runtime doc for a locale: prefix each route tree, merge, collapse aliases.
# mode: import | die (passed to alias collapse)
i18n_build_runtime_unified_file() {
  local locale="$1"
  local out_file="$2"
  local mode="${3:-import}"
  local raw_file collapsed

  i18n_require_mapper
  raw_file="${I18N_WORKDIR}/runtime-raw-${locale}.json"
  i18n_build_runtime_raw_file "$locale" "$raw_file"

  collapsed="${I18N_WORKDIR}/runtime-collapsed-${locale}.json"
  if ! i18n_alias_collapse_file "$raw_file" "$mode" >"$collapsed"; then
    return 1
  fi
  jq -c '.' "$collapsed" >"$out_file"
}
