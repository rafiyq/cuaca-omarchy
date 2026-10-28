# cuaca.weather

Weather pill for the Omarchy bar with a detail popup. A user clone of the
upstream `omarchy.weather` plugin, rebuilt around
[cuaca.wilayah.workers.dev](https://github.com/rafiyq/cuaca-worker) (BMKG,
Badan Meteorologi Klimatologi dan Geofisika) with the original worldwide
data path kept as a fallback.

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
- Slot strip: today's remaining 3-hourly slots (time / icon / temp)
- Forecast row: daily hi/lo with each day's icon from the slot nearest noon
- Warning banners above the hero when BMKG publishes CAP warnings

The FEELS read-out from the upstream panel is gone: BMKG publishes no
feels-like temperature.

## Settings

In the widget settings (`weatherSettings` form):

- `unit` — `metric` / `imperial`. Auto-detected otherwise (wttr country, then
  locale). BMKG reports °C/km/h; imperial is converted client-side.
- `refreshMinutes` — poll interval, minimum 1.

## Interaction

- Left-click — toggle popup
- Middle-click — refresh now
- Right-click — toast the current conditions (in-memory data, no system
  script; "Weather unavailable" before the first response)
- Click the location label — edit; village search via `/api/resolve` first,
  Open-Meteo worldwide geocoder on a miss

## IPC

`ipc: cuaca.weather` exposes `open`, `close`, `show`, `hide`, `toggle`,
`edit`, `status`. Popout/tab-switch routing uses the widget shape contract
(`open/close/opened/closeForPopoutSwitch`) forwarded from `BarWidget.qml`.

## State

`~/.local/state/omarchy/settings/weather.json`
(`{"name", "latitude", "longitude"}`) is owned by the system
`omarchy-weather-location` script; the plugin reads it, watches it live, and
never stores the adm4 village code — it is re-resolved on demand.

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

## Deferred ideas

- Settings for condition language (native vs `conditionEn`) and icon scheme
  (nerd-font glyphs vs emoji) — blocked on the shell-side settings form.
- Night icons and day grouping driven by the location's timezone rather than
  slot hours.
- Boot-time hydration of the bar icon from a cache file.
- Syncing the wttr-based `omarchy-weather-status` system script (unset; the
  right-click toast no longer depends on it).
