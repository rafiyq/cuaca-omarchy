# UI Wireframes

ASCII reference drawings of every surface the plugin renders, annotated with
the real pixel values from the code. Use them to eyeball whether the live UI
matches the intent; any deviation is a bug candidate, not a taste question.

Drawn from the code at v1.4.0 (2026-10-28). If the code changes, re-diff
these against the bindings — stale wireframes are worse than none.

## 1 — Bar pill, horizontal bar (3 states)

```
 pillTemp: on + data landed        no-data window / pillTemp: off     with active BMKG warnings
 ┌──────────┬───────────────────┐  ┌────────┐                         ┌∙────────┬────────→│←────────┐
 │  (icon)  │ 28°C at Bangkle   │  │ (icon) │                         ││ (icon) │ 28°C at Bangkle   │
 └──────────┴───────────────────┘  └────────┘                         └─────────┴───────────────────┘
    21px    gap 6   caption 10px  21px only                          21px
```

- Icon slot = `Style.bar.statusSlot` = 21px fixed; glyph = current conditions
  (nerd font or emoji per `iconScheme`).
- Temp + location = `28°C at Bangkle` (integer-rounded, unit from the `unit`
  setting; the name truncates past 14 chars), caption 10px, full foreground.
  Empty until the first fetch of a session lands, or forever with `pillTemp:
  off` — the pill stays icon-only either way.
- Warning dot = 5×5, radius 2.5, top-right of the icon button (5px margins),
  1px border in bar background, urgent tone. It hugs the icon, not the pill —
  it does not move when the temp widens the root.
- The temp answers to the same clicks as the icon: left opens the popup,
  right toasts the conditions, middle refreshes.

## 2 — Bar pill, vertical bar

```
   ┌────────┐
   │ (icon) │   ← 21px slot, horizontally centered
   ├─┬──────────────────┤     gap 3px
   │ │ 28°C at Bangkle  │   ← caption 10px, centered under the icon
   └─┴──────────────────┘
```

## 3 — Popup, normal (data loaded)

```
 ┌─────────────────────────────────────────────────────────────┐
 │  ⚠ warning banner (only when BMKG publishes CAP warnings)   │
 │                                                             │
 │   (icon)   28 °C              BANGKLE ✎                     │ ← location row; ⚙ = fixed corner gear
 │    64px    Hujan Ringan       WIND   HUMID   RAIN           │    top-right, 20px margin;
 │                              12 km/h  70%    60%            │    stats under it
 │    ↑ condition caption under the hero icon (hidden when the source
 │      has no native string); temp 56px bold, unit °C at its top (+10px)
 │                                                             │
 │  HARI INI                                                   │ ← today's remaining slots,
 │     11:00      14:00      17:00      20:00                  │    cuaca only, 18px apart
 │      (i)        (i)        (i)        (i)   ← icon          │
 │      28°       27°       26°       25°                      │
 │      72%       40%       15%       10%                      │ ← rain %, dimmed; accent ≥ 60%
 │   ↑ 12   ↗ 18    → 9                                        │ ← wind: arrow + speed, no unit; accent ≥ 25 km/h
 │                                                             │
 │  ─────────────── hairline (foreground @ 12%) ─────────────  │   18px apart
 │                                                             │
 │  BESOK · SELASA                              30° 24°        │ ← future strips: caption
 │     00  03  06  09  12  15  18  21                          │    = label + day name
 │     (i) (i) (i) (i) (i) (i) (i) (i)   ← icon                │    (conditionLang) + hi/lo;
 │     27° 26° 28° 28° 28° 27° 26° 26°                         │    8 slots per day,
 │     80% 75% 60% 40% 30% 20% 10%  5%                         │
 │   ↑ 12  ↗ 15  → 18  ↘ 22  ↓ 25  ↙ 28  ← 30  ↖ 32            │
 │                                                             │    night icons included
 │  ─────────────── hairline (foreground @ 12%) ─────────────  │   ← day separators: same weight between every section
 │                                                             │
 │  LUSA · RABU                                28° 23°         │
 │     00  03  06  09  12  15  18  21                          │
 │     (i) (i) (i) (i) (i) (i) (i) (i)                         │
 │     27° 26° 28° 28° 28° 27° 26° 26°                         │
 │     80% 75% 60% 40% 30% 20% 10%  5%                         │
 │   ↑ 12  ↗ 15  → 18  ↘ 22  ↓ 25  ↙ 28  ← 30  ↖ 32            │
 │                                                             │
 │                           ● ○ ○ ○                           │  ← carousel dots: one per
 │                                                             │     location, active accented;
 │                                                             │     tap jumps; swipe/scroll pages
 └─────────────────────────────────────────────────────────────┘
```

- Hero: icon 64px (deliberately off the Style.font scale, nudged +5px down),
  temp 56px bold, unit at display size anchored top+10 next to it.
- Location row: marker + `BANGKLE` (uppercase, letter-spacing 1) + pencil,
  6px gaps. The whole row is clickable -> editor. The settings gear moved
  out of the row to a fixed corner control at the popup's top-right.
- The hero's right column takes the widest of stats / label row / editor row —
  that Math.max is the v1.3.0 fix that keeps this row visible pre-fetch.
- Stats: `WIND / HUMID / RAIN` labels (11px, dimmed x1.5, letter-spaced) over
  title-size values; the row is hidden entirely until `current` exists.
- Condition text ("Hujan Ringan") is the caption under the hero icon: the
  second child of the hero's left column, left-aligned with the icon, just
  below the icon+temp row. It honors `conditionLang` (native BMKG wording
  or the English alias, falling back to native when the alias is absent)
  and stays hidden on the wttr/Open-Meteo fallback path.
- Slot strip: today's remaining 3-hourly slots (time / icon / temp / rain
  % / wind), cuaca path only — centered as a block, 18px between columns,
  3px inside each. Temps honor the unit setting (`Model.bareTempForSlot`);
  rain % is dimmed and takes the accent tint at 60%+; wind (unit-honoring)
  is dimmed and accents at 25 km/h / 16 mph+.
- Future-day strips: one captioned 3-hourly strip per day (tomorrow, day
  after) — the caption carries the day label + localized day name
  (`conditionLang`) + the hi/lo summary; 8 time/icon/temp/rain-%/wind
  columns each.
- `colorMode: color` tints temperature values on the wttr.in rainbow (magenta → azure → cyan → green → yellow → orange → red, ~3° per band from -37 to +37) and wind speed (blue-gray, vivid blue when strong); `mono` keeps the theme siblings everywhere.

## 4 — Popup, pre-fetch (the regression case)

```
 ┌──────────────────────────────┐
 │      BANGKLE ✎     ← visible NOW, from configuredLocation   │
 │                              │
 │  (icon)  —                   │ ← tempBig shows the "—" placeholder
 │                              │
 │  Fetching forecast…          │ ← italic, 11px, dimmed
 └──────────────────────────────┘
```

This is the state that used to clip the location row off the popup's right
edge. If the row is missing here after a shell restart, the fix regressed.

## 5 — Popup, editing location

```
 │   [ Search location___________]  [⟳/↺]   │ ← TextField 190px + clear 18×18
 │   ┌──────────────────────────────────┐   │   (becomes a spinner while saving;
 │   │ Bangkle                Kec. …    │   │    hover fill + hand cursor)
 │   │ ▸ selected row: accent fill      │   │
 │   │ Another village        Kab. …    │   │ ← suggestions: name + dimmed
 │   └──────────────────────────────────┘   │   description, 16px left inset,
 │      ↑/↓ walk · Enter commit · Esc cancel│   hover row = highlight, click = pick
```

- The clear button returns to the cuaca default village; suggestions render
  as full-width rows below the editor row, only while not saving.

## 6 — Popup, settings dropdown open (corner gear, no scrim)

```
    ⚙  ← corner gear: fixed at the popup's top-right (20px margin, ~10px down),
          22px circular hover fill; always visible, re-click toggles the menu
    ┌──────────────────────────────────┐  ← card drops from beneath the gear:
    │ LOCATIONS                        │
    │ ──────────────────────────────── │
    │ ⌖ Soropaten                      │  ← quick-switch recents: tap switches (stable order);
    │ ⌖ Bangkle                        │     active accented; appears once a location
    │                                  │     is recorded — a lone row is the current village
    │ SETTINGS                         │     ~300px (min parent−40), right
    │ ──────────────────────────────── │     edge at the 20px margin, 6px
    │ Condition language               │     below the gear, y clamped to
    │ [ id ]  [ en ]                   │     the popup's bottom edge
    │ Icon set                         │
    │ [ nerd ]  [ emoji ]              │  ← segments: label + 20px h-pad,
    │ Temperature unit                 │     10px v-pad, accent fill when
    │ [ auto ] [ metric ] [ imperial ] │     selected, hover fill otherwise
    │ Temperature in bar               │
    │ [ on ]  [ off ]                  │  ← the v1.4.0 row
    │ Weather colors                   │
    │ [ mono ]  [ color ]              │  ← the colorMode row: mono = theme
    │ Refresh interval (minutes)       │     siblings (default), color = temp/
    │     [ − ]   15   [ + ]           │          wind tinted; 8px gaps, clamped 1–120
    └──────────────────────────────────┘  ← card taller than the popup? it
                                            clamps and its rows scroll inside
    no scrim — the popup stays fully visible behind the menu
    reveal: the card slides down from under the gear (150ms, OutCubic)
    and slides back up as it fades out
    closes: outside click · outside wheel · ESC · gear re-click
```

- Rows render from the manifest schema (injected) or the inline mirror of the
  same six entries; order is schema order: conditionLang, iconScheme, unit,
  pillTemp, colorMode, refreshMinutes.
- Writes persist through the shell settings facade or `bar.run("omarchy bar
  set ...")`; the value only mirrors optimistically after the route confirms.

## 7 — Right-click toast

Not drawn — it is the host toast surface, not custom UI. Content: a summary
of the live conditions (temp with unit, wind, humidity, rain as available);
"Weather unavailable" before the first response.

## Comparison checklist

1. Pill: temp beside the icon, 6px gap; dot still hugging the icon's corner.
2. Pre-fetch popup (open immediately after a shell restart): location row
   present — the v1.3.0 regression case.
3. Hero: unit rides the temp's top-left (+10px); icon sits slightly lower
   than center (+5px); condition caption under the hero icon; location
   line top-aligned with the icon band — and nothing trailing the slot
   strip.
4. Stats: wide 36px columns, tiny dimmed labels over bigger values.
5. Settings: corner gear top-right (hover circle); dropdown card ~300px
   under it, SETTINGS + hairline, six rows in schema order, no scrim.
6. Editor: field + clear button inline, suggestions as full-width rows below,
   selected row accent-filled.
7. Future strips: BESOK/LUSA captions with day name + hi/lo; 8 slot columns
8. Dropdown: LOCATIONS rows lead the card (above the six setting rows), active one accented, visible once a location is recorded; tapping one closes the dropdown and refetches.
   accented; tapping one closes the dropdown and refetches.
   each (time/icon/temp/rain %/wind), night icons included; a hairline
   separates every pair of day sections (same weight as the divider above
   BESOK).
9. Carousel: real sliding pages — drag the body and both pages move;
   hold a partial drag to peek, release commits the nearest page.
   Left/right scroll and arrow keys page too (up/down never pages);
   the bar pill pages the same way. A pinned sliding pill at the
   card's bottom shows position, tap a dot to jump; switches update
   in place (insert-only).
