# cuaca.weather

Weather pill for the Omarchy bar with a detail popup. A user clone of the
upstream `omarchy.weather` plugin, rebuilt around
[cuaca.wilayah.workers.dev](https://github.com/rafiyq/cuaca-worker) (BMKG,
Badan Meteorologi Klimatologi dan Geofisika) with the original worldwide
data path kept as a fallback. Release history lives in `CHANGELOG.md`.

## Install

Requires an Omarchy install with the Quattro shell (plugin support) and
`curl`.

```bash
git clone https://github.com/rafiyq/cuaca-omarchy ~/.config/omarchy/plugins/cuaca.weather
omarchy-shell shell rescanPlugins
omarchy plugin enable cuaca.weather
omarchy bar move cuaca.weather
```

Open the detail popup from the pill (left-click); the location label
inside it opens the search editor. Widget settings — units, icon set,
condition language, refresh interval — live in the popup's gear menu,
with the defaults declared in `manifest.json`. Shell commands:
`omarchy-shell shell summon cuaca.weather '{}'` opens the popup and
`omarchy-shell shell hide cuaca.weather` closes it.

## Data sources

| Location resolves to | Source |
|---|---|
| Indonesian village | **cuaca/BMKG** — 3-hourly slots for today + 3-day forecast, warnings |
| Anywhere else | wttr.in + Open-Meteo (original upstream behavior) |
| Nothing configured | cuaca's default village (Kemayoran, Jakarta Pusat) |

Resolution rules, in `refresh()` order:

1. Coordinates stored → `/api/nearest` finds the village. Coordinates absurdly
   far from any Indonesian village (> 50 km, e.g. other continents) fall
   through to the worldwide path.
2. Name-only → `/api/resolve?limit=1`. No match anywhere in Indonesia →
   worldwide path.
3. Nothing stored → default village code `31.71.03.1001`.

If the BMKG forecast fetch exhausts its retry budget, the location drops to
the wttr/Open-Meteo path instead of blanking out.

## Popup contents (cuaca path)

- Hero: day/night icon, temperature, wind, humidity, rain chance, BMKG's
  native Indonesian condition text (`Hujan Ringan`, …)
- Slot strip: today's remaining 3-hourly slots (time / icon / temp / rain %
  / wind)
- Future-day strips: tomorrow and the day after, one captioned 3-hourly
  strip each — day label + name + hi/lo over 8
  time/icon/temp/rain-%/wind columns
- Quick-switch recents: previously used locations as tappable rows under
  a LOCATIONS caption leading the settings dropdown (above the settings
  rows); the section appears once a location is recorded — a lone row is
  the current village, accented — and one tap rewrites the location and
  refetches (the cached adm4 skips the resolve round-trip)
- Warning banners above the hero when BMKG publishes CAP warnings

The FEELS read-out from the upstream panel is gone: BMKG publishes no
feels-like temperature.

## Interaction

- Left-click — toggle popup
- Middle-click — refresh now
- Right-click — toast the current conditions (in-memory data, no system
  script; "Weather unavailable" before the first response)
- Click the location label — edit; village search via `/api/resolve` first,
  Open-Meteo worldwide geocoder on a miss
- Tapping a LOCATIONS row in the settings dropdown switches to that
  location instantly (cached adm4, no resolve round-trip; the dropdown
  closes)
- The popup is a true location carousel: drag the body and the pages
  slide side by side — hold a partial drag to peek, release to commit
  the nearest page — or scroll over it left/right (up/down never
  pages); the bar pill pages the same way, and arrow keys page while
  the popup is open. Each step pages through the recorded locations in
  list order. The indicator
  sits pinned at the card's bottom — a sliding accent pill over dim
  dots, tap a dot to jump; a step is a real switch, same path as a row
  tap, painting from the per-location cache. Reports are prefetched for
  the recorded villages (and
  learned from every fetch), so revisits paint instantly — the warning
  banner included — and the fetch that follows only refreshes in the
  background. Switches keep the list
  order — only new locations prepend (insert-only recents)
- The bar pill shows the current temperature and location beside the
  icon — `27°C at Bangkle` — once data lands (stacked under it in
  vertical bars), rounded to an integer and honoring the unit setting;
  the name truncates past 14 characters and drops away while the
  location is auto. `pillTemp: off` collapses the pill back to the
  icon. The temp answers to the same three clicks as the icon.

## IPC

`ipc: cuaca.weather` exposes `open`, `close`, `show`, `hide`, `toggle`,
`edit`, `status`. Popout/tab-switch routing uses the widget shape contract
(`open/close/opened/closeForPopoutSwitch`) forwarded from `BarWidget.qml`.

## State

`~/.local/state/omarchy/settings/weather.json`
(`{"name", "latitude", "longitude"}`) is owned by the system
`omarchy-weather-location` script; the plugin reads it, watches it live, and
never stores the adm4 village code — it is re-resolved on demand.

For boot performance the last bar glyph is cached in
`~/.cache/cuaca.weather/report.json` (mode 0600, written after every
successful BMKG fetch). At shell startup the cached icon shows until live
data replaces it, and only when the configured location matches the cached
one. Day grouping and "future" filtering use the location's own IANA
timezone from the BMKG response, so dates stay correct while traveling.

## Development

Pure-JS logic lives in `Model.js` (parsing, normalization, units, icons) and
is unit-tested offline. Fixtures under `tests/fixtures/` pin the cuaca-worker
response shapes captured 2026-10.

```
node tests/model.test.js
```

When the cuaca-worker API changes shape, refresh fixtures from the live API
and re-run. Commits favor separate fetch-layer vs UI changes; the shell
plumbing in `Panel.qml`/`BarWidget.qml` (popout coordination, file watch,
IPC) mirrors upstream `omarchy.weather` and should be re-diffed against it
periodically.

Manifest vocabulary must be valid in the *installed* omarchy version, not
just the upstream docs: newer references document fields the current shell
rejects outright (4.0.6 refuses `barWidget.defaultSection: "centerEnd"`
and unloads the whole plugin at rescan). Signs of a rejected manifest:
the widget vanishes from the bar and
`PluginRegistry: invalid ...` lines in `journalctl --user`.

One more workflow note: the shell's `Local plugin changed, reloading`
journal line does not reliably recompile the popup component. After
editing `Panel.qml` or `BarWidget.qml`, restart the shell session before
testing — stale QML warnings citing line numbers that no longer exist in
the edited file are the tell that you are looking at old bytes.

## Settings

Stored inline on the `cuaca.weather` bar layout entry in
`~/.config/omarchy/shell.json`. Set them with the shell's own CLI:

```bash
omarchy bar set cuaca.weather conditionLang en     # id | en
omarchy bar set cuaca.weather iconScheme emoji     # nerd | emoji
omarchy bar set cuaca.weather unit auto            # auto | metric | imperial
omarchy bar set cuaca.weather pillTemp on          # on | off
omarchy bar set cuaca.weather refreshMinutes 30 --json
```

or hand-edit the entry (`{ "id": "cuaca.weather", "conditionLang": "en",
"iconScheme": "emoji" }`). The manifest declares the same six keys in the
canonical Omarchy `schema` shape (with a matching `defaults` map), and the
popup carries the controls too: the corner gear glyph (top-right of the
popup) drops a settings card whose rows are rendered from that same
schema, so clicking a segment or stepping the interval writes the exact
same entry keys the CLI does. The CLI is unchanged and still works
headless.

- `conditionLang` — `id` (native BMKG wording, default) or `en` (the
  English alias the worker carries, falling back to native when absent);
  also picks the forecast day names (SELASA/RABU vs TUESDAY/WEDNESDAY).
- `iconScheme` — `nerd` (Nerd Font glyphs, default) or `emoji`, swapping
  the pill, slot strip, and forecast row together; changes apply live
  without waiting for the next fetch.
- `unit` — `auto`, `metric`, or `imperial` (`auto` is the default: the
  forecast location's country first, then the system locale; US, Liberia,
  Myanmar and en-US/en-LR/my locales get Fahrenheit). The cuaca/BMKG path
  carries no country in its report, so auto treats it as Indonesia
  (metric) once the village resolves.
- `pillTemp` — `on` (default) or `off`; hides the bar-side temperature and
  collapses the pill back to the icon alone.
- `colorMode` — `mono` (default) or `color`; `color` tints the temperature
  values on the wttr.in rainbow (magenta → azure → cyan → green → yellow
  → orange → red, ~3° per band from -37 to +37) and the wind speed
  values (blue-gray, vivid blue when strong at 25 km/h / 16 mph+).
  Icons, condition text, and rain % keep the theme coloring.
- `refreshMinutes` — auto-refresh interval, default 15, clamped to a
  minimum of 1.

## Deferred ideas

- If the shell ever renders a native settings UI for third-party widgets,
  this plugin's own popup rows could be retired in favor of it.
- A user-level `omarchy-weather-status` shadow script dead-ended: PATH
  resolves `/usr/share/omarchy/bin` ahead of `~/.local/bin`.

## Credits

- [cuaca-worker](https://github.com/rafiyq/cuaca-worker) — the companion
  BMKG village-level forecast worker (`cuaca.wilayah.workers.dev`) this
  plugin is built around, also by rafiyq.
- The built-in `omarchy.weather` plugin — the upstream this clone
  evolved from; the worldwide wttr/Open-Meteo fallback is its original
  behavior.

License: [MIT](LICENSE).

## Remove

Remove the widget from your bar layout, delete the plugin directory,
and rescan:

```bash
omarchy-shell shell rescanPlugins
rm -rf ~/.config/omarchy/plugins/cuaca.weather
```

Weather data and preferences written under
`~/.local/state/omarchy/settings/` (`weather.json`,
`weather-recents.json`) can be deleted with it if you want a clean
slate.
