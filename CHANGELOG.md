# Changelog

Release history for the `cuaca.weather` bar plugin (versions track the
plugin's `manifest.json`). Built and released in one working session on
2026-10-28; each section notes the release that introduced the change.

## 1.2.2 — 2026-10-28

### Fixed
- Removed `barWidget.defaultSection` from the manifest: the installed
  omarchy 4.0.6 shell validates it against its own section vocabulary,
  where `centerEnd` (documented in the newer upstream reference) does not
  exist — the whole manifest was rejected at rescan and the widget
  disappeared from the bar. Schema, defaults, and settingsForm stay;
  they are not validated and remain forward-compatible.
- Warnings pill dot: `BarWidget.qml` imported `qs.Commons` without the
  `as Commons` alias the Qt 6.12 shell convention requires, so the dot's
  color binding threw `Commons is not defined` at runtime; the aliased
  import was added (matching Panel.qml and first-party widgets).
- README dev section now warns that manifest vocabulary must match the
  installed shell, with the journal warning as the tell; the older
  duplicate Settings section was removed in favor of the canonical one.

## 1.2.1 — 2026-10-28

### Fixed
- Manifest `schema` recast to the canonical Omarchy shape: fields key on
  `key` instead of `name`, `enum`/`integer` types instead of the guessed
  `select`/`number`, plain-string option arrays, and `defaultValue`
  instead of `default`. Added the documented `defaults` map and an
  explicit `defaultSection`, so a future shell settings form renders the
  widget's options without lossy guessing.
- README documents `omarchy bar set` as the settings path (the shell's
  own CLI writes the widget's inline shell.json entry), with hand-editing
  as the fallback.

## 1.2.0 — 2026-10-28

### Added
- Plugin-declared settings: `conditionLang` (native BMKG wording or the
  English alias) and `iconScheme` (Nerd Font glyphs or emoji), read from
  the widget's own inline entry in `~/.config/omarchy/shell.json` and
  declared in the manifest `schema` for whenever a shell settings form
  lands. Scheme changes re-derive the pill label live; the language
  choice applies to both the panel read-out and the status toast.
- Emoji rendering for the entire icon layer — pill, boot hydration,
  today's slot strip, and the forecast row — as the `iconScheme: "emoji"`
  alternative to the Nerd Font mapping.
- Active BMKG warnings surface as a small theme-urgent dot on the bar
  pill; the banner rows with details stay in the panel.
- Boot-time icon cache: the last pill glyph plus its location persist to
  `~/.cache/cuaca.weather/report.json` (mode 0600) and hydrate at shell
  startup until live data replaces them, only on an exact location match.
- Day grouping and "future day" filtering resolve the location's calendar
  date through its IANA timezone (with machine-local fallback), so the
  forecast row stays correct while traveling east or west of BMKG grids.
- Retry timers (bmkg / wttr / open-meteo) fire with ±25% jitter so all
  three recovery paths stop slamming their endpoints on the same beat.

### Verified
- Offline test suite extended to 82 checks (timezone math, cache
  parsing, emoji mappings, scheme routing).

## 1.1.0 — 2026-10-28

### Added
- Offline test suite `tests/model.test.js` — 65 checks over `Model.js`
  helpers, plain node, no package manifest or network access.
- `tests/fixtures/` pinning the cuaca-worker API contract as captured
  in 2026-10 (forecast, nearest, resolve, warnings, including
  defensively-shaped samples); refresh these when the API changes.
- `README.md` documenting the data-source routing, popup contents,
  IPC surface, and the development loop.

### Changed
- Manifest metadata: version bump, author, description pointing at the
  BMKG worker.

## 1.0.0 — 2026-10-28

### Overview
Initial `cuaca.weather` clone of the upstream `omarchy.weather` panel
plugin, rebuilt around BMKG data while keeping the original worldwide
data path as a fallback.

### Added
- BMKG-first data layer via `cuaca.wilayah.workers.dev`: village
  resolution (coordinates to `/api/nearest`, configured name to
  `/api/resolve`, default village Kemayoran when nothing is configured),
  then a single forecast fetch. wttr/Open-Meteo serve locations outside
  BMKG's reach, coordinates beyond the 50 km resolve cap, or any path
  that exhausts its retries.
- Native Indonesian condition text and village-derived location labels;
  the FEELS stat was dropped (BMKG has no feels-like equivalent).
- Location search: cuaca village search first, Open-Meteo geocoder as
  the fallback for worldwide cities.
- BMKG warnings fetched after each successful forecast (defensive
  parsing of CAP-shaped rows) and rendered as banner rows above the
  hero; a dropped response keeps the previous warnings visible.
- Today's remaining 3-hourly forecast slots as a strip under the hero,
  with a RAIN% stat alongside the wind and humidity read-outs.
- Right-click and IPC `status` toast built entirely from live in-memory
  data; the wttr-based system `omarchy-weather-status` script is no
  longer consulted.
