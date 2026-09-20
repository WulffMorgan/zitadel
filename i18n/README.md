# ZITADEL i18n

Unified localization tooling for ZITADEL. Edit **one file per language** under `i18n/locales/`, then export into the runtime catalogs that each product loads.

## Why this exists

Translations historically lived in several trees (console JSON, login v1 YAML, notifications, common texts, login v2 JSON, and `internal/query/v2-default.json`). Keeping them in sync by hand is error-prone.

This directory is the **source of truth for string content**:

| Path | Role |
|------|------|
| `locales/<code>.yaml` | Unified catalog per locale (edit here) |
| `mapper.yaml` | Routes unified key prefixes → runtime catalog files |
| `schema.yaml` | Canonical key tree (expected keys; leaves are `null`) |
| `scripts/` | normalize, schema update, import, export, checks |

Runtime catalogs remain **committed** and are what apps embed or ship. After changing unified locales, run `export.sh` and commit both sides so they stay aligned.

## Requirements

- [jq](https://jqlang.github.io/jq/)
- [mikefarah yq](https://github.com/mikefarah/yq) v4+ (not the Python `kislyuk/yq` package)

Run scripts from the repository root (or any cwd; they resolve the repo root themselves):

```bash
./i18n/scripts/normalize.sh
./i18n/scripts/update-schema.sh
./i18n/scripts/import.sh --template en
./i18n/scripts/export.sh
./i18n/scripts/check-keys.sh
./i18n/scripts/check-duplicates.sh
```

## Concepts

### Mapper routes

`mapper.yaml` lists **routes**: each has a `match` prefix, a filesystem `path` (with `{locale}`), and a `format` (`yaml` or `json`). Optional `locale_pointer` is used for multi-locale files such as `internal/query/v2-default.json`.

On import, keys from each catalog are prefixed with the route `match`. On export, keys are split back to the matching catalog.

### Markers

Import annotates gaps and anomalies in unified files:

| Marker | Meaning |
|--------|---------|
| `__MISSING` | Schema key absent (or empty) for this locale. Export **omits** these keys; runtimes should fall back to English / instance default. |
| `__EXTRA` | Runtime key not in the schema (typo, stale, wrong casing). Export would unwrap and write them as normal keys — remove or promote into the canonical schema key before export. |
| `__CONFLICT` | Alias collapse found disagreeing values (see aliases below). |

### English template

```bash
./i18n/scripts/import.sh --template en
```

Fills `__MISSING` values from `i18n/locales/en.yaml` (useful for translators). Without `--template`, missing values are `null`.

### Aliases (optional / experimental)

Alias entries in `mapper.yaml` look like:

```yaml
- unified: common.Some.Key
  mapsTo:
    - common.Some.Key
    - console.SOME.OTHER.KEY
```

They collapse duplicate strings into one unified key on import and fan out on export.

**Current status:** aliases are **commented out**. They were used once as a **gap-fill workaround** (enable → import → export → disable → re-import/export) to copy shared values into sparse catalogs. That is not the ongoing model: re-enabling them naively produces many `__CONFLICT` markers where the same English text did not mean the same thing. Prefer `./i18n/scripts/check-duplicates.sh` if you revisit permanent aliases later.

## Everyday workflows

### Fix or add strings for an existing language

1. Edit `i18n/locales/<code>.yaml` (prefer real keys over leaving `__MISSING`).
2. `./i18n/scripts/export.sh`
3. Commit unified + runtime catalog changes.
4. Optionally `./i18n/scripts/check-keys.sh` (expect remaining `__MISSING` in incomplete locales).

### Add a new language

1. Choose an ISO 639-1 code (e.g. `sv`).
2. Add `i18n/locales/sv.yaml` — easiest path: copy `en.yaml` and translate, or run import after creating empty runtime stubs.
3. Ensure runtime files exist for each route (export can create missing locale files):
   - `internal/static/i18n/sv.yaml`
   - `internal/api/ui/login/static/i18n/sv.yaml`
   - `internal/notification/static/i18n/sv.yaml`
   - `console/src/assets/i18n/sv.json`
   - `apps/login/locales/sv.json` (login v2)
   - locale entry in `internal/query/v2-default.json` (required for login v2 API defaults)
4. `./i18n/scripts/update-schema.sh` if you also added keys; otherwise import/export as needed.
5. `./i18n/scripts/export.sh`
6. Update **static language lists** until generators exist (see [CONTRIBUTING.md](../CONTRIBUTING.md#contribute-translations)):
   - `console/src/app/utils/language.ts`
   - `console/angular.json` (`i18n-iso-countries` prebundle excludes)
   - `console` Angular locale registration (`app.module.ts`)
   - `apps/login/src/lib/i18n.ts` (`LANGS` — login v2 may intentionally be a subset)
   - `internal/api/ui/login/static/templates/external_not_found_option.html`
   - Docs language list in `apps/docs/content/guides/manage/customize/texts.mdx`
7. Use **endonyms** for language names in UI lists (e.g. German → `Deutsch`, Portuguese → `Português`).

### Change the key schema

1. Add/rename keys in English runtime catalogs (or unified `en`), then:
2. `./i18n/scripts/update-schema.sh`
3. `./i18n/scripts/import.sh --template en` (refresh other locales)
4. Translate new `__MISSING` entries
5. `./i18n/scripts/export.sh`

### Normalize formatting only

```bash
./i18n/scripts/normalize.sh
```

Sorts keys and normalizes indentation in **runtime** catalogs (not a substitute for import/export).

## Script reference

| Script | Purpose |
|--------|---------|
| `normalize.sh` | Sort/format runtime catalogs in place |
| `update-schema.sh` | Rebuild `schema.yaml` from English (routes + aliases) |
| `import.sh` | Runtime catalogs → `i18n/locales/*.yaml` |
| `export.sh` | `i18n/locales/*.yaml` → runtime catalogs |
| `check-keys.sh` | Report `__MISSING` / `__EXTRA` / `__CONFLICT` / unroutable keys (exits `1` if any) |
| `check-duplicates.sh` | Find duplicate values (alias candidates) |

## Future work

Possible follow-ups (not required for day-to-day use):

- **CI (warn-only):** soft `check-keys` / export-drift checks that do not fail the overall workflow while locales catch up.
- **CI (hard gate):** fail PRs when `__MISSING` / `__EXTRA` / `__CONFLICT` / unroutable keys appear — once catalogs are in better shape.
- **Gitignored runtime catalogs:** generate catalogs in every build from `i18n/locales/` so the unified files are the only committed SSOT (larger ops change: Docker/Nx/local builds must always run export).
- **Generators for static lists:** derive console/docs/HTML/login language allowlists from `i18n/locales/` (e.g. comment markers in target files) so adding a locale file updates lists automatically.
- **Permanent aliases:** only after stricter duplicate detection; do not uncomment the current block without resolving conflicts.

## See also

- [CONTRIBUTING.md — Contribute Translations](../CONTRIBUTING.md#contribute-translations)
- [Customized texts (docs)](../apps/docs/content/guides/manage/customize/texts.mdx)
