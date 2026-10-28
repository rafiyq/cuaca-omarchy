# cuaca.weather

Weather pill for the Omarchy bar with a detail popup. A user clone of the
upstream `omarchy.weather` plugin, rebuilt around
[cuaca.wilayah.workers.dev](https://github.com/rafiyq/cuaca-worker) (BMKG,
Badan Meteorologi Klimatologi dan Geofisika) with the original worldwide
data path kept as a fallback. Release history lives in `CHANGELOG.md`.

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
- The bar pill shows the current temperature beside the icon once data
  lands (stacked under it in vertical bars), rounded to an integer and
  honoring the unit setting; `pillTemp: off` collapses the pill back to
  the icon. The temp answers to the same three clicks as the icon.

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
"iconScheme": "emoji" }`). The manifest declares the same five keys in the
canonical Omarchy `schema` shape (with a matching `defaults` map), and the
popup carries the controls too, tucked behind a modal: the gear glyph
beside the location label raises a settings card whose rows are rendered
from that same schema, so clicking a segment or stepping the interval
writes the exact same entry keys the CLI does. The CLI is unchanged and
still works headless.

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
