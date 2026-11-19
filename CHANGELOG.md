# Changelog

Release history for the `cuaca.weather` bar plugin (versions track the
plugin's `manifest.json`). Built and released in one working session on
2026-10-28; each section notes the release that introduced the change.

## 1.6.3 — 2026-11-19

### Added
- Horizontal wheel paging: two-finger left/right now pages locations
  on both the pill and the popup body — scroll left = next, matching
  the swipe convention. Each wheel event's dominant axis wins (with a
  per-axis pixelDelta fallback), so diagonal gestures resolve cleanly
  and vertical keeps its existing behavior: paging when the card fits,
  native scrolling when it overflows.
- The pill's icon gains a wheel-only overlay (acceptedButtons: NoButton,
  transparent to clicks and hover) because the shell's WidgetButton
  re-emits wheel as wheelMoved(angleDelta.y) — the horizontal axis
  never survives that hop and the shell code is read-only.

## 1.6.2 — 2026-11-19

### Fixed
- Wheel paging starved on touchpads: every wheel path sat behind a
  120-angleDelta accumulator — a mouse-detent assumption — while
  Wayland touchpads deliver streams of small per-frame deltas that
  never reach it. The shell's own volume slider, which steps on any
  nonzero delta, worked on the same events, exposing the split.
  Paging is now slider-style on both the pill and the popup body: any
  nonzero delta pages once (direction from its sign), with
  cycleLocation's 250ms throttle as the rate limiter, and angleDelta
  falls back to pixelDelta so pure-pixel devices still page.
- The popup body's pager moves off WheelHandler (which never fired
  here) onto the existing under-content MouseArea — the slider-proven
  mechanism — and rejects wheel events when the content overflows so
  the Flickable's native momentum scrolling takes over.

## 1.6.1 — 2026-11-18

### Fixed
- The instant paint on cached switches never actually survived: the
  configured-location change handler — which fires synchronously during
  every switch — wiped the just-installed report along with the old
  location's state, so every step still went blank and waited on a full
  network round-trip. The handler now preserves a cached install (its
  report belongs to the target location) and keeps the wipe for
  uncached switches; warnings stay live-only and still clear either way.
- Cached carousel steps no longer play the page-turn dip — the swap is
  instant; the dip now only covers a true miss.

## 1.6.0 — 2026-11-18

### Added
- Per-location report cache (plan-B lite): villages are prefetched by a
  sequential queue on open, on each refresh tick, and whenever recents
  change — only stale or missing entries queue, so popup opens inside a
  refresh epoch cost nothing, and entries dropped from the cap are
  pruned. Every successful live fetch (cuaca or the wttr/open-meteo
  fallback) also learns its location's entry, so a first visit makes
  the next one instant.
- Install-on-cycle: a carousel step whose location is cached paints
  instantly — the body shows the target before the switch completes —
  and the refresh that follows quietly overwrites with fresh data.
  Warnings stay live-only; true cache misses keep the existing
  fetch-then-arrive flow.

### Fixed
- The bar-pill wheel never fired: the shell's WidgetButton consumes
  wheel events and re-emits them as its (until now unheard) wheelMoved
  signal — the paging now rides that signal directly, plus a plain
  onWheel on the temperature area, so the whole pill pages locations.

## 1.5.0 — 2026-11-16

### Added
- Location carousel: a horizontal swipe on the popup body, the wheel
  over the popup (when its content doesn't scroll), and the wheel over
  the bar pill each page through the recorded locations in list order.
  A row of dots under the day strips shows position — the active one
  accented, tap to jump — hidden below two locations. A step is a real
  switch: the same commit path as a LOCATIONS row tap (weather.json
  rewrite, cached-adm4 fast path, refetch), throttled to 250ms and
  wrapped in a quick page-turn dip.

### Changed
- The recents list is insert-only: a switch updates its entry in place
  instead of moving it to the front, so the carousel dots and the
  dropdown rows hold their positions; only brand-new locations prepend
  and the cap still drops the last row.

## 1.4.4 — 2026-11-16

### Fixed
- The 1.4.3 day separators never rendered: the future-strip delegate
  referenced the model `index` without declaring it, and the engine
  (which does not expose delegate roles as context lookups) logged
  `ReferenceError: index is not defined`, leaving the divider guard
  silently false. The index is now a declared required property, the
  same pattern every other delegate in the panel already uses.

## 1.4.3 — 2026-11-16

### Added
- Hairline separators between the popup's day sections: each future-day
  strip (BESOK, LUSA) renders the same foreground @ 12% hairline the
  today/BESOK divider uses, so every day boundary reads as its own
  section. The today/LUSA edge also holds when tomorrow's slot grid is
  empty but the day after still has slots.

## 1.4.2 — 2026-11-15

### Changed
- The LOCATIONS section leads the settings dropdown (above the settings
  rows) and appears once a location is recorded instead of waiting for a
  second entry — a lone row is the current village, accented, mirroring
  the automatic current-place entry established weather UIs keep in
  their location lists.

## 1.4.1 — 2026-11-13

### Added
- Location quick-switch: previously used locations render as tappable
  rows under a LOCATIONS caption at the bottom of the settings dropdown
  (marker + name; the active one accented; hidden until a second entry
  exists). One tap rewrites the location state file through the same
  commit path as an edit and refetches — the row's cached adm4 feeds
  the fetcher directly, skipping the resolve round-trip. A stale adm4
  self-heals: the forecast response corrects the code and three
  forecast failures fall back to wttr.
- Recents live in a new `weather-recents.json` state file (mode 0600,
  same write recipe as the report cache); entries carry name,
  coordinates, and adm4 as a resolution cache — `weather.json` itself
  stays adm4-free. The list is MRU, deduped by adm4 (name fallback),
  capped at four, seeded by each successful cuaca forecast (the
  worker's location block supplies the canonical village name and
  coordinates, updated in place so auto-refreshes never reorder it)
  and by each location commit; typed-name recommits inherit the stored
  adm4 of their village. No delete UI — the oldest falls off the cap.
- manifest 1.4.1; Model.js gains parseRecentLocations +
  recentLocationKey + commitRecentLocation (exports, +9 offline tests).

## 1.4.0 — 2026-10-28

### Added
- The current temperature renders in the bar beside the pill icon
  (stacked under it in vertical bars): integer-rounded, honoring the
  `unit` setting, and empty until a session's first fetch lands so the
  pill stays icon-only in the no-data window. The temp carries the
  icon's click routing: left opens the popup, right toasts the
  conditions, middle refreshes.
- `pillTemp` setting (default `on`) as a fifth row in the gear modal;
  `off` collapses the pill back to the icon alone.
- README dev note: the shell's hot-reload journal line does not
  reliably recompile the popup — restart the session before testing
  Panel/BarWidget changes.

### Changed
- The BMKG condition text ("Hujan Ringan", …) moved from a stray line
  below the hourly slot strip to under the hero icon, as a caption on
  the big condition emoji. Fallback paths are unchanged: with no native
  condition string the text simply stays hidden.
- The hero's location line anchors to the top-right of the hero (8px
  down) instead of centering vertically — with the caption making the
  left block taller, the centered row read as floating mid-height.
- The settings menu opens as a dropdown dropped from a fixed corner
  gear instead of a centered modal: no scrim, ~300px card under the
  gear at the popup's top-right, closed by outside click, outside
  wheel, ESC, or a gear re-click. The reveal is a short slide-down
  from the gear (150ms) and it slides back up as it fades out. The
  five rows are unchanged; a card taller than the popup clamps and
  scrolls its rows inside.
- The gear moved out of the location row to that corner control — the
  row is marker + name + pencil, still fully clickable to edit.
- The forecast row is replaced by per-day hourly strips: tomorrow and
  the day after each get a captioned 3-hourly strip (8 time/icon/temp
  columns) under a caption carrying the day label, the localized day
  name, and the hi/lo summary. Day names follow the `conditionLang`
  setting (SELASA/RABU for `id` instead of the system-locale
  TUESDAY/WEDNESDAY); the today slot strip is unchanged.
- Rain probability in every strip column (today, tomorrow, day after): a
  dimmed percent under the temp that takes the accent tint at 60%+.
- Wind in every strip column: a dimmed direction arrow (theme
  foreground) then the speed, tinted by the wttr.in rainbow in color
  mode (no unit; the number honors the unit setting) — mono keeps the
  dimmed/accent rule at 25 km/h / 16 mph+.
- `colorMode` setting (`mono` default, `color`) as a sixth row in the
  settings dropdown: `color` tints temperature values on the wttr.in
  rainbow (empirically sampled from wttr.in's terminal output) and wind
  speed values (blue-gray, vivid blue when strong); icons, condition
  text, and rain % keep the theme coloring.

### Fixed
- `unit: auto` no longer falls through to the system locale on the cuaca
  path: the BMKG source covers Indonesia only and its report carries no
  country, so an en-US locale showed °F for an Indonesian village. Auto
  now resolves metric there as soon as the village resolves; explicit
  picks and the wttr/Open-Meteo path are unchanged.
- Fixed a runtime TypeError ("incompatible arguments") from the locale
  date-format overload that blanked the future-day strips and, in the
  previous build, the forecast day names: Indonesian weekday names now
  come from a plain table in Model.js.
- Slot strip temps now honor the unit setting — they were permanently
  Celsius (raw BMKG values) even with imperial selected, unlike the hero
  and the forecast row. New `Model.bareTempForSlot` helper with offline
  test coverage.

## 1.3.0 — 2026-10-28

### Added
- Settings controls inside the weather popup, behind a modal. A gear
  glyph in the location row raises the card over the popup content (scrim
  click, the card's ✕, or ESC lower it); the rows inside render from the
  manifest's `barWidget.schema` when the host injects it, falling back to
  an inline mirror of the same four entries: enum fields as segmented
  picks, `refreshMinutes` as a −/+ stepper clamped to 1–120.
- A pencil glyph after the location label. The row itself was always
  clickable to open the editor, but nothing advertised it.

### Changed
- Settings writes route through the scoped plugin surface: the shell's
  settings facade for the widget when one is injected, otherwise the bar
  API's `run()` command channel, which reaches the same `omarchy bar set`
  storage the CLI uses. A value is only mirrored optimistically once a
  write route is confirmed, so a refused write never lies in the UI. The
  CLI commands below stay fully valid.
- The warnings pill dot takes its urgency tone from the bar facade
  (`bar.urgent`, which Bar.qml mirrors per frame) instead of the Commons
  singleton — the same binding that threw `Commons is not defined` when
  a hot reload raced the module table now has no module dependency.

### Fixed
- The location row no longer vanishes before a session's first fetch
  lands: the hero's right column sized itself from the (still empty)
  stats row, collapsed at the popup's right edge, and the scroll clip
  cut the row off entirely. The column now takes the widest of the
  stats, label, and editor rows, so the configured location shows
  immediately at boot.
- Clicking the location opens the editor again: the row-wide click area
  had been anchored inside a Row, whose children reject horizontal
  anchoring — the area stayed 0×0 (the journal's "Cannot specify … fill
  … anchors for items inside Row" warning was the tell). It now hangs
  off a plain wrapper item, with the gear's own area still winning over
  its glyph.
- Restored three glyphs the release had shipped as empty strings,
  rendering at zero width: the pencil cue, the settings gear, and the
  modal's ✕ — with click areas sized from the missing glyphs, the gear
  and the ✕ were dead buttons.

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
