import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "cuaca.weather"
  ipcTarget: "cuaca.weather"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    locationFile.reload()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    locationFile.reload()
    root.refresh()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins, while
    // a handoff to a panel that does not manage the flag still leaves it
    // cleared rather than stuck on.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingLocation) root.cancelEditingLocation()
    root.settingsOpen = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // Parsed wttr.in j1 response. Kept on failure so stale data stays visible.
  property var report: null
  property var dailyForecastReport: null

  // Parsed cuaca (BMKG) response, plus the village code the next fetch
  // should use and whether that data path is actually active. Resolution
  // reruns on every location change; reports are kept on failure so stale
  // data stays visible.
  property var bmkgReport: null
  property string resolvedAdm4: ""
  property bool usingCuaca: false
  property var bmkgWarnings: []

  // Configured location, read from the weather.json state file (owned by
  // omarchy-weather-location). The query is the wttr.in path segment
  // (coordinates when stored, else the encoded name) used only by the
  // fallback path; empty means the cuaca default village. The watch makes
  // hand edits take effect live.
  property var configuredLocationState: ({ name: "", latitude: null, longitude: null })
  readonly property string configuredLocation: configuredLocationState.name
  readonly property string locationQuery: Model.wttrLocationQuery(configuredLocationState.name, configuredLocationState.latitude, configuredLocationState.longitude)

  // Quick-switch recents: previously used locations, newest first,
  // capped at four. adm4 rides along as a resolution cache —
  // weather.json itself stays adm4-free — so a switch hands the fetcher
  // the known code and skips the resolve round-trip. Seeded by each
  // successful cuaca forecast (the worker reports the village identity)
  // and by each location commit.
  readonly property string recentsPath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather-recents.json"
  property var recentLocations: []
  // Switch-time hint: the tapped row's adm4, consumed once by the next
  // refresh to skip the resolve round-trip.
  property string pendingAdm4: ""

  // Per-location report cache (plan-B lite): key = Model.recentLocationKey.
  // Villages carry { cuaca: <parsed forecast> }; wttr spots carry
  // { wttr: <parsed>, daily: <open-meteo daily> }. Villages are prefetched
  // by a sequential queue on open, on the refresh timer, and whenever
  // recents change; every successful live fetch also learns its location's
  // entry, so a first visit makes the next one instant. `at` timestamps
  // gate re-prefetching to one refresh epoch.
  property var pageReports: ({})
  property var prefetchQueue: []
  property string prefetchActiveKey: ""

  // True only during the synchronous window in which switchToRecent has
  // installed a cached report and the configured-location assignment
  // fires onLocationQueryChanged: the handler must not wipe the install.
  property bool cachedInstallActive: false

  function storeCachedReport(key, payload) {
    payload.at = Date.now()
    pageReports[key] = payload
  }

  // Keep the previous report visible while the new location loads. The
  // editor remains open with a spinner, so stale data is never presented
  // under the newly configured location label.
  onLocationQueryChanged: {
    if (savingLocation) savingLocationQueryStarted = true
    forecastRetries = 0
    dailyForecastRetries = 0
    bmkgRetries = 0
    forecastProc.running = false
    dailyForecastProc.running = false
    bmkgResolveProc.running = false
    bmkgForecastProc.running = false
    // Warnings are live-only and location-bound: the previous banner
    // must not ride along (cached installs carry none of it).
    bmkgWarnings = []
    if (cachedInstallActive) {
      // The on-screen report belongs to the target location — wiping it
      // would reintroduce the loading window the cache exists to
      // prevent. Keep it; the refresh below only refreshes.
      Qt.callLater(refresh)
      return
    }
    // The new location must resolve on its own terms; mixing the old
    // village's report under it is worse than a blank while loading.
    resolvedAdm4 = ""
    usingCuaca = false
    bmkgReport = null
    Qt.callLater(refresh)
  }

  property FileView locationFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.configuredLocationState = Model.parseLocationFile(text())
      Qt.callLater(root.tryHydrateLabel)
    }
    onLoadFailed: {
      root.configuredLocationState = Model.parseLocationFile("")
      Qt.callLater(root.tryHydrateLabel)
    }
  }

  property FileView recentLocationsFile: FileView {
    path: root.recentsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.recentLocations = Model.parseRecentLocations(text())
      root.schedulePrefetch()
    }
    onLoadFailed: root.recentLocations = Model.parseRecentLocations("")
  }

  // Boot-time icon hydration. Each successful BMKG fetch persists the last
  // bar glyph plus the location it belongs to (mode 0600); at shell startup
  // the cached glyph is shown until live data replaces it — and only when
  // the configured location is identical to the cached one.
  readonly property string cacheDir: (String(Quickshell.env("XDG_CACHE_HOME") || "") !== "" ? Quickshell.env("XDG_CACHE_HOME") : (Quickshell.env("HOME") + "/.cache")) + "/cuaca.weather"
  readonly property string cachePath: cacheDir + "/report.json"
  property var cacheState: null

  property FileView reportCacheFile: FileView {
    path: root.cachePath
    watchChanges: false
    printErrors: false
    onLoaded: {
      root.cacheState = Model.parseReportCache(text())
      root.tryHydrateLabel()
    }
    onLoadFailed: root.cacheState = null
  }

  function tryHydrateLabel() {
    if (!cacheState || root.label !== "") return
    var cached = cacheState.locationState
    if (String(cached.name) !== String(configuredLocationState.name)) return
    if (String(cached.latitude) !== String(configuredLocationState.latitude)) return
    if (String(cached.longitude) !== String(configuredLocationState.longitude)) return
    var icon = Model.currentIcon({ bmkgWeatherCode: cacheState.weatherCode, isDay: cacheState.isDay }, "", root.iconScheme)
    if (icon !== "") root.label = icon
  }

  // Cache writes ride the same channel as reads: a shell printf with the
  // JSON handed over as an argv (no quoting hazards), dirs mode 0755 via
  // mkdir, payload file 0600 via umask.
  function writeReportCache() {
    var current = bmkgCurrent
    if (!current || current.bmkgWeatherCode === undefined || current.bmkgWeatherCode === null) return
    var payload = {
      locationState: { name: configuredLocationState.name, latitude: configuredLocationState.latitude, longitude: configuredLocationState.longitude },
      weatherCode: current.bmkgWeatherCode,
      isDay: current.isDay === true
    }
    cacheWriteProc.command = ["sh", "-c",
      'mkdir -p "$(dirname "$2")" && umask 077 && printf %s "$1" > "$2"',
      "cuaca-cache", JSON.stringify(payload), cachePath]
    cacheWriteProc.running = true
  }

  Process {
    id: cacheWriteProc
  }

  // The first read can race shell startup (observed sporadically), leaving a
  // stored location unhonored until the next file write. One delayed reload
  // self-corrects; if the first read was fine it's a no-op, since identical
  // state doesn't change locationQuery and so triggers no refetch.
  Timer {
    interval: 1500
    running: true
    onTriggered: {
      locationFile.reload()
      reportCacheFile.reload()
      Qt.callLater(root.tryHydrateLabel)
    }
  }

  property int forecastRetries: 0
  property int dailyForecastRetries: 0
  property int bmkgRetries: 0

  // Click-to-edit state for the location label.
  property bool editingLocation: false
  // Whether the settings modal layer is raised over the popup content.
  property bool settingsOpen: false
  property bool savingLocation: false
  property bool savingLocationQueryStarted: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodePendingQuery: ""
  property string geocodeActiveQuery: ""

  // Shared hero/bar icon state, updated with each successful weather response.
  property string label: ""

  // wttr's current conditions when the fallback path runs; open-meteo's
  // (bundled with the much faster daily forecast fetch) fill the hero while
  // wttr is in flight. The cuaca path resolves and fetches first, though —
  // if that succeeded, BMKG's data wins outright.
  readonly property bool hasConfiguredCoordinates: !isNaN(parseFloat(String(configuredLocationState.latitude))) && !isNaN(parseFloat(String(configuredLocationState.longitude)))
  readonly property var openMeteoCurrent: Model.openMeteoCurrentCondition(dailyForecastReport)
  readonly property var bmkgCurrent: Model.bmkgCurrentCondition(bmkgReport)
  readonly property var current: (usingCuaca && bmkgCurrent) ? bmkgCurrent : (hasConfiguredCoordinates && openMeteoCurrent) ? openMeteoCurrent : ((report && report.current_condition && report.current_condition[0]) ? report.current_condition[0] : openMeteoCurrent)
  readonly property var areaInfo: report && report.nearest_area && report.nearest_area[0] ? report.nearest_area[0] : null
  readonly property var forecastDays: buildForecastDays()
  // Remaining slots for today on the cuaca path (current block onward).
  readonly property var todaySlots: Model.bmkgTodaySlots(bmkgReport)
  // Hourly runs for the two future days the cuaca series carries —
  // rendered as captioned strips below the forecast hairline. Empty on
  // the fallback path, so the strips hide (the same rule the today
  // strip follows).
  readonly property var tomorrowSlots: forecastDays.length > 0 ? Model.bmkgSlotsForDate(bmkgReport, forecastDays[0].date) : []
  readonly property var dayAfterSlots: forecastDays.length > 1 ? Model.bmkgSlotsForDate(bmkgReport, forecastDays[1].date) : []

  // Caption model for the future-day strips: label (conditionLang), the
  // localized day name, and the day's hi/lo summary.
  readonly property var futureStripModel: [
    {
      label: futureStripLabel(0),
      day: forecastDays.length > 0 ? dayName(forecastDays[0].date).toUpperCase() : "",
      hi: bareTempForDay(forecastDays.length > 0 ? forecastDays[0] : null, "max"),
      lo: bareTempForDay(forecastDays.length > 0 ? forecastDays[0] : null, "min"),
      hiColor: forecastDays.length > 0 ? tempColorHex(forecastDays[0].maxtempC) : "",
      loColor: forecastDays.length > 0 ? tempColorHex(forecastDays[0].mintempC) : "",
      slots: tomorrowSlots
    },
    {
      label: futureStripLabel(1),
      day: forecastDays.length > 1 ? dayName(forecastDays[1].date).toUpperCase() : "",
      hi: bareTempForDay(forecastDays.length > 1 ? forecastDays[1] : null, "max"),
      lo: bareTempForDay(forecastDays.length > 1 ? forecastDays[1] : null, "min"),
      hiColor: forecastDays.length > 1 ? tempColorHex(forecastDays[1].maxtempC) : "",
      loColor: forecastDays.length > 1 ? tempColorHex(forecastDays[1].mintempC) : "",
      slots: dayAfterSlots
    }
  ]
  readonly property string reportCountry: areaInfo && areaInfo.country && areaInfo.country[0] ? areaInfo.country[0].value : ""
  // The cuaca source covers Indonesia exclusively and its local report
  // carries no country — feed the auto unit decision that fact directly,
  // instead of letting auto fall through to the system locale.
  readonly property string unitCountry: reportCountry !== ""
    ? reportCountry
    : ((usingCuaca && resolvedAdm4 !== "") ? "Indonesia" : "")

  readonly property bool useImperial: Model.shouldUseImperial(setting("unit", ""), Qt.locale().name, unitCountry)

  // Auto-refresh interval in minutes; clamped to a sane minimum.
  readonly property int refreshMinutes: Math.max(1, parseInt(setting("refreshMinutes", 15), 10) || 15)

  // The village the forecast actually came from (cuaca/BMKG path), the
  // user's configured name, or wttr's detected area on the fallback path.
  readonly property var bmkgLocationInfo: (usingCuaca && bmkgReport && bmkgReport.location) ? bmkgReport.location : null
  // Location's own calendar date for "future day" grouping and slot
  // filtering; machine-local date otherwise (wttr path, timezone lookup
  // failures).
  readonly property string todayString: Model.todayInTimeZone(usingCuaca && bmkgLocationInfo ? bmkgLocationInfo.timezone : "", Qt.formatDate(new Date(), "yyyy-MM-dd"))
  readonly property string reportLocation: (bmkgLocationInfo && bmkgLocationInfo.desa) ? String(bmkgLocationInfo.desa) : configuredLocation || (areaInfo && areaInfo.areaName && areaInfo.areaName[0] ? areaInfo.areaName[0].value : "")
  readonly property string reportTempNum:   current ? String(useImperial ? current.temp_F : current.temp_C) : ""
  readonly property string tempUnit:        "°" + (useImperial ? "F" : "C")
  // Compact bar-pill label: "27°C at <location>". Empty until conditions
  // land and the pillTemp setting is on; the temperature is rounded to an
  // integer the way the bar wants it (the popup hero keeps its own
  // display). The location makes multi-location switching readable at a
  // glance — truncated past 14 chars so long village names can't bloat
  // the bar — and drops away while the location is auto/unresolved.
  readonly property string pillLocation: {
    var name = String(configuredLocation || "").trim()
    if (name === "") return ""
    if (name.length > 14) name = name.slice(0, 13) + "…"
    return " at " + name
  }
  readonly property string pillTempText: (String(setting("pillTemp", "on")).toLowerCase() !== "off" && reportTempNum !== "")
    ? roundedTemp(reportTempNum) + tempUnit + pillLocation : ""
  // Hand-editable widget settings (inline on the `{"id": "cuaca.weather"}`
  // bar layout entry in ~/.config/omarchy/shell.json — the settings-form
  // renderer is still shell-side). Condition language: BMKG's native
  // wording is the default, "en" prefers the English alias the worker
  // carries. Icon scheme: nerd-font glyphs are the default, "emoji" swaps
  // the whole icon layer (pill, strip, forecast row) to emoji. Pill temp:
  // "off" hides the bar-side temperature (pillTempText goes empty).
  readonly property string conditionLang: String(setting("conditionLang", "id")).toLowerCase()
  readonly property string colorMode: String(setting("colorMode", "mono")).toLowerCase()

  // Temperature band hex in color mode; "" keeps the theme color.
  function tempColorHex(celsius) {
    if (colorMode !== "color") return ""
    return Model.tempColor(celsius)
  }
  function tempColorOrDefault(celsius, base) {
    var c = tempColorHex(celsius)
    return c !== "" ? c : base
  }
  readonly property string iconScheme: String(setting("iconScheme", "nerd")).toLowerCase()
  // BMKG condition text, honoring the language preference. The fallback
  // sources carry no equivalent string, and a slot without the preferred
  // alias falls back to the native wording rather than an empty row.
  readonly property string reportCondition: (function() {
    if (!current) return ""
    if (conditionLang === "en" && current.bmkgConditionEn) return String(current.bmkgConditionEn)
    return current.bmkgCondition ? String(current.bmkgCondition) : ""
  })()

  // Scoped host facade set onto the widget root when declared, forwarded
  // from BarWidget.injectPanel; carries _updateSettings(), the shell's
  // sanctioned way for a plugin to adjust its own inline shell.json entry
  // (merge semantics, per-key).
  property var shell: null
  property var manifest: null
  property string widgetId: ""  // forwarded moduleName; fallback is the manifest id

  // Settings written by this popup before the host re-injects settings;
  // cleared on that injection so segments re-read the stored values.
  property var settingsOverrides: ({})
  onSettingsChanged: root.settingsOverrides = ({})

  // Effective value for a settings row: optimistic mirror, the injected
  // value, then the schema default.
  function effectiveSetting(name, fallback) {
    if (settingsOverrides[name] !== undefined) return settingsOverrides[name]
    return setting(name, fallback)
  }

  // Write one key. Preferred path is the scoped shell facade when the host
  // provides one to widgets; the everyday path is the bar API's run(), which
  // reaches the same `omarchy bar set` storage the CLI uses. Only after a
  // confirmed route does the value mirror optimistically — a refused write
  // must never lie in the UI.
  function writeSetting(key, value) {
    var targetId = String(root.widgetId || (root.manifest ? root.manifest.id : "cuaca.weather"))
    if (root.shell && typeof root.shell._updateSettings === "function") {
      var patch = ({})
      patch[key] = value
      if (!root.shell._updateSettings(targetId, patch)) return false
    } else if (root.bar && typeof root.bar.run === "function") {
      var literal = String(value)
      var sanitized = literal.replace(/[^a-zA-Z0-9-]/g, "")
      if (literal === "" || literal !== sanitized) return false
      root.bar.run("omarchy bar set " + targetId + " " + key + " " + sanitized)
    } else {
      return false
    }
    var next = ({})
    for (var k in settingsOverrides) next[k] = settingsOverrides[k]
    next[key] = value
    settingsOverrides = next
    return true
  }

  // Rows rendered below the forecast. The manifest carries the canonical
  // list when it is injected; the fallback mirrors the same entries so the
  // form works regardless of host injection order.
  readonly property var settingsRows: (function() {
    var schema = (root.manifest && root.manifest.barWidget && root.manifest.barWidget.schema)
      ? root.manifest.barWidget.schema : null
    if (schema && schema.length) return schema
    return [
      { key: "conditionLang", type: "enum", label: "Condition language", options: ["id", "en"], defaultValue: "id" },
      { key: "iconScheme", type: "enum", label: "Icon set", options: ["nerd", "emoji"], defaultValue: "nerd" },
      { key: "unit", type: "enum", label: "Temperature unit", options: ["auto", "metric", "imperial"], defaultValue: "auto" },
      { key: "pillTemp", type: "enum", label: "Temperature in bar", options: ["on", "off"], defaultValue: "on" },
      { key: "colorMode", type: "enum", label: "Weather colors", options: ["mono", "color"], defaultValue: "mono" },
      { key: "refreshMinutes", type: "integer", label: "Refresh interval (min)", defaultValue: 15, min: 1, max: 120, step: 1 }
    ]
  })()
  readonly property string reportWind:      current ? (useImperial ? (current.windspeedMiles + " mph") : (current.windspeedKmph + " km/h")) : ""
  readonly property string reportHumidity:  current ? (current.humidity + "%") : ""
  // BMKG rain chance for the current slot; absent on the fallback path.
  readonly property string reportRain:      current && current.rainProb !== undefined && current.rainProb !== null ? (current.rainProb + "%") : ""

  function refresh() {
    // Each full refresh cycle gets a fresh retry budget, so an earlier
    // exhausted round (e.g. waking with the network still down) doesn't
    // starve retries for the rest of the session.
    forecastRetries = 0
    dailyForecastRetries = 0
    bmkgRetries = 0
    // The cuaca resolution decides which data path runs for this location.
    refreshBmkg()
    schedulePrefetch()
  }

  // The cuaca (BMKG) worker covers Indonesian villages only. Extending the
  // configured name or coordinates outward first — a village resolves to a
  // BMKG forecast, no match hands the refresh over to wttr/Open-Meteo, and
  // nothing configured at all shows the worker's own default village.
  readonly property string cuacaDefaultAdm4: "31.71.03.1001"  // Kemayoran, Jakarta Pusat

  function refreshBmkg() {
    if (bmkgResolveProc.running || bmkgForecastProc.running) return

    // A quick-switch hands over its known adm4 — skip the resolve
    // round-trip and fetch straight away. A stale code self-heals: the
    // response's own location block corrects a wrong code, and three
    // forecast failures fall through to the wttr path.
    if (pendingAdm4 !== "") {
      resolvedAdm4 = pendingAdm4
      pendingAdm4 = ""
      usingCuaca = true
      fetchBmkgForecast()
      return
    }

    var lat = parseFloat(String(configuredLocationState.latitude))
    var lon = parseFloat(String(configuredLocationState.longitude))
    if (!isNaN(lat) && !isNaN(lon)) {
      bmkgResolveProc.command = ["curl", "-fsS", "--max-time", "5",
        "https://cuaca.wilayah.workers.dev/api/nearest?lat=" + encodeURIComponent(String(lat))
        + "&lon=" + encodeURIComponent(String(lon)) + "&limit=1"]
      bmkgResolveProc.running = true
      return
    }

    var name = configuredLocation.trim()
    if (name !== "") {
      bmkgResolveProc.command = ["curl", "-fsS", "--max-time", "5",
        "https://cuaca.wilayah.workers.dev/api/resolve?q=" + encodeURIComponent(name) + "&limit=1"]
      bmkgResolveProc.running = true
      return
    }

    resolvedAdm4 = cuacaDefaultAdm4
    usingCuaca = true
    fetchBmkgForecast()
  }

  function fetchBmkgForecast() {
    if (resolvedAdm4 === "" || bmkgForecastProc.running) return
    bmkgForecastProc.command = ["curl", "-fsS", "--max-time", "8",
      "https://cuaca.wilayah.workers.dev/api/forecast?adm4=" + encodeURIComponent(resolvedAdm4)]
    bmkgForecastProc.running = true
  }

  // Warnings piggyback on the forecast: fetched only after a successful
  // forecast response pins the village. No retry budget — the endpoint is
  // edge-cached 15 min and the next refresh cycle picks it up again.
  function fetchBmkgWarnings() {
    if (resolvedAdm4 === "" || !usingCuaca || bmkgWarningProc.running) return
    bmkgWarningProc.command = ["curl", "-fsS", "--max-time", "5",
      "https://cuaca.wilayah.workers.dev/api/warnings?adm4=" + encodeURIComponent(resolvedAdm4)]
    bmkgWarningProc.running = true
  }

  function startFallbackRefresh() {
    if (!forecastProc.running) forecastProc.running = true
    // With stored coordinates this fetches open-meteo right away — no need
    // to wait for the slow wttr response. Without them it's a no-op until
    // wttr reports the detected area.
    refreshDailyForecast(null)
  }

  // cuaca can be slow when a forecast isn't edge-cached yet. Retry a few
  // times before falling the location over to wttr/Open-Meteo rather than
  // blanking the popup until the next refresh epoch.
  function scheduleBmkgRetry() {
    if (bmkgRetries >= 3) {
      resolvedAdm4 = ""
      usingCuaca = false
      startFallbackRefresh()
      return
    }
    bmkgRetries++
    jitteredRestart(bmkgRetryTimer)
  }

  Timer {
    id: bmkgRetryTimer
    onTriggered: root.refreshBmkg()
  }

  function refreshDailyForecast(sourceReport) {
    if (dailyForecastProc.running) return

    var lat = parseFloat(String(root.configuredLocationState.latitude))
    var lon = parseFloat(String(root.configuredLocationState.longitude))
    if (isNaN(lat) || isNaN(lon)) {
      var area = sourceReport && sourceReport.nearest_area && sourceReport.nearest_area[0] ? sourceReport.nearest_area[0] : root.areaInfo
      if (!area) return
      lat = parseFloat(String(area.latitude || ""))
      lon = parseFloat(String(area.longitude || ""))
    }
    if (isNaN(lat) || isNaN(lon)) return

    var url = "https://api.open-meteo.com/v1/forecast"
      + "?latitude=" + encodeURIComponent(String(lat))
      + "&longitude=" + encodeURIComponent(String(lon))
      + "&daily=weather_code,temperature_2m_max,temperature_2m_min"
      + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"
      + "&forecast_days=4"
      + "&timezone=auto"
    dailyForecastProc.command = ["curl", "-fsS", "--max-time", "5", url]
    dailyForecastProc.running = true
  }

  // ---- Location editing. Clicking the location label swaps it for a search
  //      field; picking a geocoded suggestion persists name + coordinates to
  //      the module's shell.json entry. An empty commit returns to auto.
  function startEditingLocation() {
    editingLocation = true
    savingLocation = false
    savingLocationQueryStarted = false
    locationSuggestions = []
    suggestionIndex = 0
    Qt.callLater(function() {
      locationField.text = root.configuredLocation
      locationField.selectAll()
      locationField.forceActiveFocus()
    })
  }

  function cancelEditingLocation() {
    editingLocation = false
    savingLocation = false
    savingLocationQueryStarted = false
    locationSuggestions = []
    geocodeDebounce.stop()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function commitLocation() {
    var location = Model.locationCommit(locationField.text, locationSuggestions, suggestionIndex)
    if (location.name === "") {
      clearLocation()
      return
    }
    savingLocation = true
    savingLocationQueryStarted = false
    configuredLocationState = {
      name: location.name,
      latitude: location.latitude,
      longitude: location.longitude
    }
    persistLocation(location.name, location.latitude, location.longitude)
    recordLocationCommit(location.name, location.latitude, location.longitude, location.code)
  }

  function clearLocation() {
    persistLocation("", null, null)
    cancelEditingLocation()
  }

  function pickSuggestion(suggestion) {
    if (!suggestion) return
    savingLocation = true
    savingLocationQueryStarted = false
    configuredLocationState = {
      name: suggestion.name,
      latitude: suggestion.latitude,
      longitude: suggestion.longitude
    }
    persistLocation(suggestion.name, suggestion.latitude, suggestion.longitude)
    recordLocationCommit(suggestion.name, suggestion.latitude, suggestion.longitude, suggestion.code)
  }

  function finishSavingLocation() {
    if (savingLocation && savingLocationQueryStarted) cancelEditingLocation()
  }

  // Right-click / `status` IPC: toast the current conditions from live
  // in-memory data — no system script, works on every path, and reflects
  // whatever the panel is actually showing. Shell-metacharacters are
  // stripped because bar.run hands the string to a shell.
  function notifyStatus() {
    if (!root.bar) return
    var sanitize = function(str) {
      return String(str || "").replace(/[$`"\\\n]/g, "")
    }
    var place = sanitize(reportLocation)
    if (place === "" && !current) {
      root.bar.run("omarchy-notification-send \"Weather unavailable\"")
      return
    }
    var parts = [place !== "" ? place : "Weather"]
    if (reportTempNum !== "") parts.push("Temp " + sanitize(reportTempNum) + sanitize(tempUnit))
    if (reportWind !== "") parts.push("Wind " + sanitize(reportWind))
    if (reportHumidity !== "") parts.push("Humid " + sanitize(reportHumidity))
    if (reportCondition !== "") parts.push(sanitize(reportCondition))
    root.bar.run("omarchy-notification-send \"" + parts.join("  ·  ") + "\"")
  }

  function persistLocation(name, latitude, longitude) {
    if (name && latitude !== null && longitude !== null)
      locationSaveProc.command = ["omarchy-weather-location", "--set", name, latitude + "," + longitude]
    else if (name)
      locationSaveProc.command = ["omarchy-weather-location", "--set", name]
    else
      locationSaveProc.command = ["omarchy-weather-location", "--clear"]
    locationSaveProc.running = true
  }

  // ---- quick-switch recents ----
  // Same shell recipe as the report cache: mode 0600, parents made.
  function saveRecentLocations(list) {
    recentLocations = list
    recentsWriteProc.command = ["sh", "-c",
      'mkdir -p "$(dirname "$2")" && umask 077 && printf %s "$1" > "$2"',
      "cuaca-recents", JSON.stringify(list), recentsPath]
    recentsWriteProc.running = true
  }

  // The commit paths (typed/edited name, picked suggestion) and the
  // quick-switch all funnel here. adm4 arrives with suggestions and
  // recents rows; a typed name stays empty until the forecast pins it.
  function recordLocationCommit(name, latitude, longitude, adm4) {
    if (!name) return
    saveRecentLocations(Model.commitRecentLocation(recentLocations, {
      name: String(name),
      latitude: latitude,
      longitude: longitude,
      adm4: String(adm4 || "")
    }, 4))
  }

  // Refresh-time reconciliation: the forecast response is the worker's
  // own view of the resolved village. Update the matching entry in place
  // (canonical name, coordinates, pinned adm4) or add it — never reorder,
  // so auto-refreshes don't churn the MRU order. This also seeds the
  // default village and gives typed-name commits their adm4.
  function recordResolvedLocation(locationInfo) {
    var adm4 = locationInfo && locationInfo.adm4 ? String(locationInfo.adm4) : ""
    var name = String(locationInfo && locationInfo.desa ? locationInfo.desa : configuredLocationState.name || "").replace(/^\s+|\s+$/g, "")
    if (adm4 === "" || name === "") return
    var entry = {
      name: name,
      latitude: locationInfo && locationInfo.lat !== undefined ? parseFloat(locationInfo.lat) : configuredLocationState.latitude,
      longitude: locationInfo && locationInfo.lon !== undefined ? parseFloat(locationInfo.lon) : configuredLocationState.longitude,
      adm4: adm4
    }
    if (isNaN(entry.latitude)) entry.latitude = null
    if (isNaN(entry.longitude)) entry.longitude = null
    var key = Model.recentLocationKey(entry)
    for (var i = 0; i < recentLocations.length; i++) {
      var row = recentLocations[i]
      if (!row || Model.recentLocationKey(row) !== key) continue
      var merged = { name: name, latitude: entry.latitude, longitude: entry.longitude, adm4: adm4 }
      if (row.name === merged.name && row.adm4 === merged.adm4 && row.latitude === merged.latitude && row.longitude === merged.longitude) return
      var updated = []
      for (var j = 0; j < recentLocations.length; j++) updated.push(recentLocations[j] === row ? merged : recentLocations[j])
      saveRecentLocations(updated)
      return
    }
    saveRecentLocations(Model.commitRecentLocation(recentLocations, entry, 4))
  }

  // Active check shared by the row highlight and the switch guard:
  // adm4-keyed rows match the resolved village, name-only rows the
  // configured label (wttr spots, unresolved commits).
  function isCurrentRecent(entry) {
    if (!entry) return false
    if (String(entry.adm4 || "") !== "") return usingCuaca && String(entry.adm4) === resolvedAdm4
    return String(entry.name) === String(configuredLocationState.name)
  }

  function switchToRecent(entry, dir) {
    if (!entry || !entry.name || isCurrentRecent(entry)) return
    // Page-turn direction: gesture callers (wheel, swipe, pill) pass it
    // through, so a forward wrap keeps sliding forward; taps without a
    // gesture (dots, rows) derive it from the index delta — a dot to
    // the right arrives from the right. Both indices are captured here,
    // before the state swap below moves the current-location identity.
    var prevIndex = currentLocationIndex()
    var key = Model.recentLocationKey(entry)
    var nextIndex = -1
    for (var i = 0; i < recentLocations.length; i++)
      if (Model.recentLocationKey(recentLocations[i]) === key) { nextIndex = i; break }
    if (dir === undefined || dir === 0)
      dir = (prevIndex === -1 || nextIndex === -1) ? 0 : (nextIndex > prevIndex ? 1 : -1)
    // Plan-B lite: a cached report paints the target before the switch
    // completes — no loading window on revisits; the refresh that follows
    // quietly overwrites with fresh data. Villages install their cuaca
    // report, spots the wttr + open-meteo pair.
    var cached = pageReports[Model.recentLocationKey(entry)]
    var installed = false
    if (cached) {
      if (cached.cuaca && String(entry.adm4 || "") !== "") {
        bmkgReport = cached.cuaca
        resolvedAdm4 = String(entry.adm4)
        usingCuaca = true
        label = Model.currentIcon(Model.bmkgCurrentCondition(cached.cuaca), root.label, root.iconScheme)
        installed = true
      } else if (cached.wttr && String(entry.adm4 || "") === "") {
        report = cached.wttr
        if (cached.daily) dailyForecastReport = cached.daily
        usingCuaca = false
        if (cached.daily) label = Model.currentIcon(Model.openMeteoCurrentCondition(cached.daily), root.label, root.iconScheme)
        installed = true
      }
    }
    // The hint must exist before the state assignment: onLocationQueryChanged
    // fires synchronously and schedules the refresh that consumes it.
    pendingAdm4 = String(entry.adm4 || "")
    savingLocation = true
    savingLocationQueryStarted = false
    // That same handler wipes the report for uncached switches (a fresh
    // location must not ride the old village's data). A cached install
    // already shows the target's own report — flag it so the synchronous
    // handler fire preserves the paint, then unflag.
    cachedInstallActive = installed
    configuredLocationState = {
      name: String(entry.name),
      latitude: entry.latitude === undefined ? null : entry.latitude,
      longitude: entry.longitude === undefined ? null : entry.longitude
    }
    cachedInstallActive = false
    // Page turn: the swap has landed — slide the arriving page in from
    // its direction of travel and fade it up.
    if (dir !== 0) {
      pageTurn.direction = dir
      weatherColumn.x = dir * Style.space(24)
      weatherColumn.opacity = 0.25
      pageTurn.restart()
    }
    persistLocation(String(entry.name), entry.latitude === undefined ? null : entry.latitude, entry.longitude === undefined ? null : entry.longitude)
    saveRecentLocations(Model.commitRecentLocation(recentLocations, entry, 4))
    settingsOpen = false
  }

  // Carousel position: wherever the current location sits in the recents
  // list; a current location that is not recorded yet answers -1, and the
  // cycle wraps that to the first entry.
  function currentLocationIndex() {
    for (var i = 0; i < recentLocations.length; i++)
      if (isCurrentRecent(recentLocations[i])) return i
    return -1
  }

  // One carousel step in stored list order (dir -1 = previous, 1 = next,
  // wrapping). A step is a real switch — the same commit path as tapping
  // a LOCATIONS row — throttled so fast spins and flicks can't stack
  // refetches.
  function cycleLocation(dir) {
    var n = recentLocations.length
    if (n < 2) return
    if (cycleThrottle.running) return
    cycleThrottle.restart()
    var target = (currentLocationIndex() + dir + n) % n
    switchToRecent(recentLocations[target], dir)
  }

  Process {
    id: recentsWriteProc
  }

  // ---- per-location report prefetch
  // One sequential Process walks the villages' adm4 codes; each result
  // lands in pageReports so a carousel step paints instantly. Only stale
  // or missing entries queue, so popup opens inside a refresh epoch cost
  // nothing, and entries dropped from the cap are pruned.
  function schedulePrefetch() {
    var keys = {}
    for (var i = 0; i < recentLocations.length; i++) keys[Model.recentLocationKey(recentLocations[i])] = true
    for (var k in pageReports) if (!keys[k]) delete pageReports[k]
    var maxAge = root.refreshMinutes * 60 * 1000
    prefetchQueue = recentLocations
      .filter(function (e) { return String(e.adm4 || "") !== "" })
      .map(function (e) { return { key: Model.recentLocationKey(e), adm4: String(e.adm4) } })
      .filter(function (item) {
        var cached = pageReports[item.key]
        return !cached || !cached.cuaca || !cached.at || Date.now() - cached.at > maxAge
      })
    runNextPrefetch()
  }

  function runNextPrefetch() {
    if (prefetchProc.running || prefetchQueue.length === 0) return
    var item = prefetchQueue.shift()
    prefetchActiveKey = item.key
    prefetchProc.command = ["curl", "-fsS", "--max-time", "8",
      "https://cuaca.wilayah.workers.dev/api/forecast?adm4=" + encodeURIComponent(item.adm4)]
    prefetchProc.running = true
  }

  Process {
    id: prefetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw) {
          try {
            var parsed = JSON.parse(raw)
            if (parsed && parsed.forecast && parsed.forecast.length)
              root.storeCachedReport(root.prefetchActiveKey, { cuaca: parsed })
          } catch (e) {}
        }
        Qt.callLater(root.runNextPrefetch)
      }
    }
  }

  // Debounced location search. The latest query always wins: the cuaca
  // village search runs first, and only a clean miss hands over to
  // Open-Meteo's worldwide geocoder; either stage chains forward if the
  // query moved on while a fetch was in flight.
  function requestGeocode() {
    var query = locationField.text.trim()
    if (query.length < 2) {
      locationSuggestions = []
      return
    }
    geocodePendingQuery = query
    if (!cuacaSearchProc.running && !geocodeProc.running) startLocationSearch()
  }

  function startLocationSearch() {
    geocodeActiveQuery = geocodePendingQuery
    cuacaSearchProc.command = ["curl", "-fsS", "--max-time", "5",
      "https://cuaca.wilayah.workers.dev/api/resolve?q=" + encodeURIComponent(geocodeActiveQuery) + "&limit=6"]
    cuacaSearchProc.running = true
  }

  function startOpenMeteoGeocode() {
    geocodeActiveQuery = geocodePendingQuery
    geocodeProc.command = ["curl", "-fsS", "--max-time", "5",
      "https://geocoding-api.open-meteo.com/v1/search?name=" + encodeURIComponent(geocodeActiveQuery) + "&count=5&language=en&format=json"]
    geocodeProc.running = true
  }

  function buildForecastDays() {
    return Model.buildForecastDays(report, dailyForecastReport, bmkgReport, root.todayString)
  }

  function openMeteoForecastDays() {
    return Model.openMeteoForecastDays(dailyForecastReport, root.todayString)
  }

  function wttrNextForecastDays() {
    return Model.wttrNextForecastDays(report, root.todayString)
  }

  function isFutureForecastDate(dateString) {
    return Model.isFutureForecastDate(dateString, root.todayString)
  }

  function roundedTemp(value) {
    return Model.roundedTemp(value)
  }

  function celsiusToFahrenheit(value) {
    return Model.celsiusToFahrenheit(value)
  }

  function formatTemp(value) {
    return Model.formatTemp(value, useImperial)
  }

  function dayName(dateString) {
    return Model.dayName(dateString, function(date) {
      // The locale-formatDate overload throws in this runtime — the
      // Indonesian names come from a plain table in Model.js instead.
      return conditionLang === "id"
        ? Model.indonesianDayName(date)
        : Qt.formatDate(date, "dddd")
    })
  }

  // Label for a future-day strip. Indonesian day-after is "lusa", so the
  // en fallback keeps its own word.
  function futureStripLabel(index) {
    var en = conditionLang === "en"
    if (forecastDays.length <= index) return en ? "TOMORROW" : "BESOK"
    if (en) return index === 0 ? "TOMORROW" : (index === 1 ? "DAY AFTER" : dayName(forecastDays[index].date).toUpperCase())
    return index === 0 ? "BESOK" : (index === 1 ? "LUSA" : dayName(forecastDays[index].date).toUpperCase())
  }

  // Bare degree value (no unit letter), used in the forecast row.
  function bareTempForDay(day, kind) {
    return Model.bareTempForDay(day, kind, useImperial)
  }

  // Same for a slot-strip column.
  function bareTempForSlot(slot) {
    return Model.bareTempForSlot(slot, useImperial)
  }

  // Strip icon for a raw cuaca slot: night decided by the slot's
  // location-local hour.
  function slotIcon(slot) {
    return Model.bmkgSlotIcon(slot, root.iconScheme)
  }

  function iconForOpenMeteoCode(code) {
    return Model.iconForOpenMeteoCode(code, false, root.iconScheme)
  }

  // Mirrors omarchy-weather-icon's wttr.in code → nerd-font glyph mapping;
  // iconScheme === "emoji" reroutes the whole layer to emoji instead.
  function iconForCode(code, night) {
    return Model.iconForCode(code, night, root.iconScheme)
  }

  // Scheme settings land live: whatever condition the sources currently
  // hold re-renders the pill without waiting for the next fetch.
  function refreshLabelFromCurrent() {
    if (!current) return
    var icon = Model.currentIcon(current, "", root.iconScheme)
    if (icon !== "") root.label = icon
  }
  onIconSchemeChanged: Qt.callLater(root.refreshLabelFromCurrent)

  Process {
    id: forecastProc
    command: ["curl", "-fsS", "--max-time", "10", "https://wttr.in/" + root.locationQuery + "?format=j1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.scheduleForecastRetry()
          return
        }
        try {
          var parsed = JSON.parse(raw)
          root.report = parsed
          if (!root.hasConfiguredCoordinates)
            root.label = Model.provisionalCurrentIcon(parsed.current_condition && parsed.current_condition[0], root.label, root.iconScheme)
          root.forecastRetries = 0
          if (Model.weatherResponseCompletesSave(root.usingCuaca, root.hasConfiguredCoordinates, "wttr"))
            root.finishSavingLocation()
          // Stored coordinates already drove the fast open-meteo fetch from
          // refresh(); only auto-detect needs the area wttr reported.
          if (isNaN(parseFloat(String(root.configuredLocationState.latitude))))
            root.refreshDailyForecast(parsed)
        } catch (e) {
          // Keep last-good report visible, but try again shortly.
          root.scheduleForecastRetry()
        }
      }
    }
  }

  // wttr.in can be slow or flaky, especially for a location it hasn't
  // cached yet. Retry a few times before leaving it to the refresh timer.
  function scheduleForecastRetry() {
    if (forecastRetries >= 3) return
    forecastRetries++
    jitteredRestart(forecastRetryTimer)
  }

  // Retry base interval with ±25% jitter: after a suspend or network flap
  // all three fetch paths recover at once, and fixed timers would slam the
  // endpoints on the same beat every time.
  function jitteredRestart(timer) {
    timer.interval = 2500 + Math.round(2500 * (Math.random() * 0.5 - 0.25))
    timer.restart()
  }

  Timer {
    id: forecastRetryTimer
    onTriggered: if (!forecastProc.running) forecastProc.running = true
  }

  // With configured coordinates this fetch is the only thing that updates the
  // bar icon, so a dropped response (e.g. waking before the network is back)
  // must retry rather than wait out the refresh timer with a stale icon.
  function scheduleDailyForecastRetry() {
    if (dailyForecastRetries >= 3) return
    dailyForecastRetries++
    jitteredRestart(dailyForecastRetryTimer)
  }

  Timer {
    id: dailyForecastRetryTimer
    onTriggered: root.refreshDailyForecast(null)
  }

  // Page-turn for carousel switches: the body dips toward the swipe
  // direction and fades, then settles back while the new location loads.
  // Page turn: the arriving page slides in from its direction of travel
  // and fades up. Purely cosmetic and always started after the state
  // swap, so it can never gate or delay the paint. Rapid paging can't
  // overlap: the 250ms cycle throttle outlasts the 140ms tween.
  ParallelAnimation {
    id: pageTurn
    property int direction: 1
    NumberAnimation { target: weatherColumn; property: "x"; to: 0; duration: 140; easing.type: Easing.OutCubic }
    NumberAnimation { target: weatherColumn; property: "opacity"; to: 1; duration: 140; easing.type: Easing.OutCubic }
  }

  Timer {
    id: cycleThrottle
    interval: 250
  }

  // Village resolution decides the data path. A malformed response means
  // the network hiccuped — retry. A clean "no match" (worldwide city, or
  // coordinates absurdly far from any Indonesian village) is a routing
  // decision: fall back to wttr/Open-Meteo.
  Process {
    id: bmkgResolveProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rows = Model.parseCuacaResults(text)
        var first = rows.length > 0 ? rows[0] : null
        if (first && first.code && !(first.distKm !== undefined && first.distKm > Model.cuacaMaxResolveDistanceKm)) {
          root.resolvedAdm4 = first.code
          root.usingCuaca = true
          root.fetchBmkgForecast()
          return
        }
        root.resolvedAdm4 = ""
        root.usingCuaca = false
        root.startFallbackRefresh()
      }
    }
  }

  Process {
    id: bmkgForecastProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.scheduleBmkgRetry()
          return
        }
        try {
          var parsed = JSON.parse(raw)
          if (!parsed || !parsed.forecast || !parsed.forecast.length) throw new Error("no forecast slots")
          if (parsed.location && parsed.location.adm4) {
            root.resolvedAdm4 = String(parsed.location.adm4)
            root.recordResolvedLocation(parsed.location)
          }
          root.bmkgReport = parsed
          root.storeCachedReport(Model.recentLocationKey({ name: root.configuredLocationState.name, adm4: root.resolvedAdm4 }), { cuaca: parsed })
          root.label = Model.currentIcon(Model.bmkgCurrentCondition(parsed), root.label, root.iconScheme)
          root.writeReportCache()
          root.bmkgRetries = 0
          if (Model.weatherResponseCompletesSave(root.usingCuaca, root.hasConfiguredCoordinates, "bmkg"))
            root.finishSavingLocation()
          root.fetchBmkgWarnings()
        } catch (e) {
          // Keep last-good BMKG report visible, but try again shortly.
          root.scheduleBmkgRetry()
        }
      }
    }
  }

  Process {
    id: bmkgWarningProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // A dropped response (curl -f yields no output) keeps the previous
        // warnings visible instead of pretending all-clear; a parsed
        // success replaces the list, including the all-clear case.
        if (String(text || "").trim() === "") return
        root.bmkgWarnings = Model.parseBmkgWarnings(text)
      }
    }
  }

  Process {
    id: dailyForecastProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.scheduleDailyForecastRetry()
          return
        }
        try {
          var parsed = JSON.parse(raw)
          var parsedCurrent = Model.openMeteoCurrentCondition(parsed)
          root.dailyForecastReport = parsed
          if (!root.usingCuaca)
            root.storeCachedReport(Model.recentLocationKey({ name: root.configuredLocationState.name }), { wttr: root.report, daily: parsed })
          root.label = Model.currentIcon(parsedCurrent, root.label, root.iconScheme)
          root.dailyForecastRetries = 0
          if (Model.weatherResponseCompletesSave(root.usingCuaca, root.hasConfiguredCoordinates, "open-meteo"))
            root.finishSavingLocation()
        } catch (e) {
          // Keep last-good daily forecast visible, but try again shortly.
          root.scheduleDailyForecastRetry()
        }
      }
    }
  }

  Process {
    id: cuacaSearchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rows = root.editingLocation ? Model.parseCuacaResults(text) : []
        if (rows.length === 0 && root.geocodePendingQuery === root.geocodeActiveQuery) {
          // No Indonesian village carries that name: worldwide cities.
          root.startOpenMeteoGeocode()
          return
        }
        root.locationSuggestions = rows
        root.suggestionIndex = 0
        if (root.geocodePendingQuery !== root.geocodeActiveQuery) Qt.callLater(root.startLocationSearch)
      }
    }
  }

  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.locationSuggestions = root.editingLocation ? Model.parseGeocodingResults(text) : []
        root.suggestionIndex = 0
        if (root.geocodePendingQuery !== root.geocodeActiveQuery) Qt.callLater(root.startLocationSearch)
      }
    }
  }

  Timer {
    id: geocodeDebounce
    interval: 300
    onTriggered: root.requestGeocode()
  }

  Process {
    id: locationSaveProc
    onExited: function(exitCode) {
      if (exitCode !== 0 || !root.savingLocation) return

      // FileView handles changed locations. Explicitly refresh here too so
      // saving the already-active location cannot strand the spinner.
      locationFile.reload()
      if (!root.savingLocationQueryStarted) {
        root.savingLocationQueryStarted = true
        root.forecastRetries = 0
        root.dailyForecastRetries = 0
        root.bmkgRetries = 0
        forecastProc.running = false
        dailyForecastProc.running = false
        bmkgResolveProc.running = false
        bmkgForecastProc.running = false
        Qt.callLater(root.refresh)
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function edit(): void { root.openFromHotkey(); root.startEditingLocation() }
    function status(): void { root.notifyStatus() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(weatherColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLocation
      onReturnRequested: if (!root.settingsOpen) root.startEditingLocation()
      onCloseRequested: {
        if (root.settingsOpen) root.settingsOpen = false
        else root.close()
      }
      onTabRequested: function(direction) {
        if (root.settingsOpen) return
        root.switchPanel(direction)
      }

      Flickable {
        id: weatherScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: weatherColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        // Carousel input: the wheel pages horizontally only — two-finger
        // left/right, scroll left = next (matching the swipe), slider-
        // style after the shell's volume-slider precedent. Up/down
        // never pages: over an overflowing card the event is rejected
        // so the Flickable's native wheel scrolling takes over, and
        // over a fitting card it does nothing. A horizontal-dominant
        // swipe anywhere that is not an interactive control pages too
        // (this area sits beneath the content, so clicks pass through
        // to the location editor).
        MouseArea {
          anchors.fill: parent
          enabled: !root.editingLocation
          property real pressX: 0
          property real pressY: 0
          onWheel: function(wheel) {
            // Horizontal only: left/right pages (scroll left = next,
            // matching the swipe). Vertical gestures never page — when
            // the card overflows they are rejected so its own native
            // scrolling takes over, and when it fits they do nothing.
            // The dominance test keeps noisy diagonals from paging.
            var dx = wheel.angleDelta.x !== 0 ? wheel.angleDelta.x : wheel.pixelDelta.x
            var dy = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.pixelDelta.y
            if (dx === 0 || Math.abs(dx) < Math.abs(dy)) return
            wheel.accepted = true
            root.cycleLocation(dx < 0 ? 1 : -1)
          }
          onPressed: function(mouse) { pressX = mouse.x; pressY = mouse.y }
          onReleased: function(mouse) {
            var dx = mouse.x - pressX
            var dy = mouse.y - pressY
            if (Math.abs(dx) > Style.space(48) && Math.abs(dx) > Math.abs(dy) * 2)
              root.cycleLocation(dx < 0 ? 1 : -1)
          }
        }

        Column {
          id: weatherColumn
          width: weatherScroll.width
          spacing: Style.space(14)

      // ---- BMKG warnings (cuaca path only, sourced from /api/warnings).
      //      Severity coloring stays theme-agnostic: sibling tones of the
      //      bar foreground rather than fixed palette colors.
      Column {
        visible: root.bmkgWarnings.length > 0
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: root.bmkgWarnings

          Rectangle {
            required property var modelData
            width: parent.width
            radius: Style.cornerRadius
            color: Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)
            height: warningBody.implicitHeight + Style.space(20)

            Column {
              id: warningBody
              anchors.fill: parent
              anchors.leftMargin: Style.space(14)
              // Right margin clears the fixed corner gear that overlays
              // this band from the settings layer above the scroll.
              anchors.rightMargin: Style.space(44)
              anchors.topMargin: Style.space(10)
              anchors.bottomMargin: Style.space(10)

              Row {
                spacing: Style.space(6)

                Text {
                  text: "⚠"
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  visible: modelData.event !== ""
                  text: modelData.event
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  visible: modelData.severity !== ""
                  text: modelData.severity.toUpperCase()
                  anchors.verticalCenter: parent.verticalCenter
                  color: Qt.darker(root.bar.foreground, 1.3)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: modelData.area !== ""
                text: modelData.area
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                textFormat: Text.PlainText
                visible: modelData.description !== ""
                text: modelData.description
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                width: parent.width
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }

      // ---- Hero row: big icon + temp (condition caption under the icon) on the left; location and stats stacked on the right.
      Item {
        width: parent.width
        height: Math.max(heroLeft.height, heroRight.height)

        Column {
          id: heroLeft
          anchors.left: parent.left
          anchors.leftMargin: Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Row {
            spacing: Style.space(16)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              anchors.verticalCenterOffset: 5
              text: root.label || "—"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              // Decorative condition emoji; intentionally larger than the
              // Style.font.* scale's displayLarge (28).
              font.pixelSize: 64
            }

            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                id: tempBig
                textFormat: Text.PlainText
                text: root.reportTempNum || "—"
                color: root.tempColorOrDefault(current ? current.temp_C : null, root.bar.foreground)
                font.family: root.bar.fontFamily
                // Hero temperature read-out; deliberately oversized, outside
                // the Style.font.* scale.
                font.pixelSize: 56
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                text: root.current ? root.tempUnit : ""
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
                anchors.top: tempBig.top
                anchors.topMargin: Style.space(10)
              }
            }
          }

          // BMKG condition text, native to the cuaca path ("Hujan
          // Ringan", …) — the caption under the hero icon. wttr
          // and Open-Meteo carry no equivalent string, so on the
          // fallback path this line simply stays hidden.
          Text {
            id: conditionText
            visible: root.reportCondition !== ""
            text: root.reportCondition
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
          }
        }

        Column {
          id: heroRight
          // Not just the stats width: pre-fetch the stats are empty, a
          // collapsed column sits at the popup's right edge, and the
          // scroll clip then cuts the location row off entirely. Take the
          // widest of the three candidate rows instead.
          width: Math.max(weatherStats.implicitWidth, locationLabelRow.implicitWidth, locationEditRow.implicitWidth)
          anchors.right: parent.right
          anchors.rightMargin: Style.space(20)
          // Top-anchored, not centered: the caption makes the left block
          // taller than this column, and a centered row read as floating
          // mid-height. The 8px inset drops the label to the icon's top band.
          anchors.top: parent.top
          anchors.topMargin: Style.space(8)
          spacing: Style.space(12)

          Item {
            id: locationRow
            visible: !root.editingLocation && root.reportLocation !== ""
            width: locationLabelRow.implicitWidth
            height: locationLabelRow.implicitHeight

            // Row-wide click target. Anchored to the wrapper, a plain Item,
            // because horizontal anchoring is illegal on children of a Row
            // (the earlier in-row fill anchor silently produced a 0x0 area).
            // The label Row renders after it. The settings gear used to
            // live in this row as well; it moved to a fixed corner control
            // in the settings layer above the scroll content.
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.startEditingLocation()
            }

            Row {
              id: locationLabelRow
              spacing: Style.space(6)

              Text {
                text: ""  // nf-fa-map_marker
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                textFormat: Text.PlainText
                text: (root.reportLocation || "").toUpperCase()
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
                anchors.verticalCenter: parent.verticalCenter
              }
              // Pencil cue: clicking the "hidden" location label opens the
              // editor; this makes that affordance discoverable.
              Text {
                textFormat: Text.PlainText
                text: ""  // nf-fa-pencil
                color: Qt.darker(root.bar.foreground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }

            }
          }

          Row {
            id: locationEditRow
            visible: root.editingLocation
            spacing: Style.space(6)

            TextField {
              id: locationField
              width: Style.space(190)
              enabled: !root.savingLocation
              placeholderText: "Search location"
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily

              onTextChanged: if (root.editingLocation && !root.savingLocation) geocodeDebounce.restart()

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.cancelEditingLocation()
                  event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  if (root.suggestionIndex < root.locationSuggestions.length - 1) root.suggestionIndex++
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  if (root.suggestionIndex > 0) root.suggestionIndex--
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.commitLocation()
                  event.accepted = true
                }
              }
            }

            // Clear back to the cuaca default village (Kemayoran). While a
            // committed location is loading, this same compact affordance
            // becomes a spinner.
            Rectangle {
              width: Style.space(18)
              height: Style.space(18)
              anchors.verticalCenter: parent.verticalCenter
              radius: Math.min(4, Style.cornerRadius)
              color: !root.savingLocation && clearLocationArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent) : "transparent"

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: root.savingLocation ? "󰦖" : "✕"
                font.family: root.bar.fontFamily
                color: Qt.darker(root.bar.foreground, 1.4)
                font.pixelSize: Style.font.bodySmall

                RotationAnimator on rotation {
                  running: root.savingLocation
                  from: 0; to: 360
                  duration: 800
                  loops: Animation.Infinite
                }
              }

              MouseArea {
                id: clearLocationArea
                anchors.fill: parent
                enabled: !root.savingLocation
                hoverEnabled: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.clearLocation()
              }
            }
          }

          Row {
            id: weatherStats
            visible: !!root.current
            spacing: Style.space(36)

            Column {
              spacing: Style.space(5)
              Text {
                text: "WIND"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: root.reportWind
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            Column {
              spacing: Style.space(5)
              Text {
                text: "HUMID"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: root.reportHumidity
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            // BMKG rain chance; hidden on the fallback path, which has no
            // equivalent number.
            Column {
              visible: root.reportRain !== ""
              spacing: Style.space(5)
              Text {
                text: "RAIN"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: root.reportRain
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }
          }
        }
      }

      // ---- Slot strip: today's remaining slots (cuaca path), time /
      //      read left to right from the current 3-hour block.
      Item {
        visible: root.usingCuaca && root.todaySlots.length > 0
        width: parent.width
        height: todayRow.height

        Row {
          id: todayRow
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(18)

          Repeater {
            model: root.todaySlots

            Column {
              required property var modelData
              spacing: Style.space(3)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                // Slot time is location-local; "HH:MM" drops the seconds.
                text: String(modelData.time || "").slice(11, 16)
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: root.slotIcon(modelData)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: root.bareTempForSlot(modelData)
                color: root.tempColorOrDefault(modelData.temp, root.bar.foreground)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }
              readonly property var rain: Model.slotRainProb(modelData)
              Text {
                visible: rain.text !== ""
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: rain.text
                color: rain.wet
                  ? Style.selectedStateColor(root.bar.foreground, Commons.Color.accent)
                  : Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
              readonly property var wind: Model.slotWind(modelData, useImperial)
              Row {
                visible: wind.text !== ""
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(4)

                Text {
                  visible: wind.arrow !== ""
                  textFormat: Text.PlainText
                  text: wind.arrow
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  textFormat: Text.PlainText
                  text: wind.speed
                  color: colorMode === "color" && wind.color !== ""
                    ? wind.color
                    : (wind.strong
                       ? Style.selectedStateColor(root.bar.foreground, Commons.Color.accent)
                       : Qt.darker(root.bar.foreground, 1.5))
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }

      // ---- Geocoding suggestions while the location is being edited.
      Column {
        visible: root.editingLocation && !root.savingLocation && root.locationSuggestions.length > 0
        width: parent.width
        spacing: 0

        Repeater {
          model: root.locationSuggestions

          Rectangle {
            required property var modelData
            required property int index
            width: parent.width
            height: suggestionRow.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: index === root.suggestionIndex ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent) : "transparent"

            Row {
              id: suggestionRow
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: modelData.name
                color: index === root.suggestionIndex ? Style.hoverStateColor(root.bar.foreground, Commons.Color.accent) : root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                textFormat: Text.PlainText
                visible: text !== ""
                text: modelData.description
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onPositionChanged: root.suggestionIndex = index
              onClicked: root.pickSuggestion(modelData)
            }
          }
        }
      }

      Text {
        visible: !root.current
        text: "Fetching forecast…"
        color: Qt.darker(root.bar.foreground, 1.5)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.italic: true
      }

      // ---- Divider between current conditions and forecast. Also covers
      //      the edge where tomorrow's grid is empty but the day after
      //      still has slots — the LUSA strip keeps its top separator.
      Rectangle {
        visible: root.usingCuaca && (root.tomorrowSlots.length > 0 || root.dayAfterSlots.length > 0)
        width: parent.width
        height: Style.spacing.hairline
        color: root.bar.foreground
        opacity: 0.12
      }

      // ---- Future-day strips: tomorrow and the day after, one captioned
      //      3-hourly strip each (cuaca path). The caption carries the day
      //      label + name + hi/lo; the columns are time / icon / temp — the
      //      same rhythm as the today strip above.
      Repeater {
        model: root.futureStripModel

        Item {
          required property var modelData
          required property int index

          // A hairline separates consecutive day strips — same weight as
          // the divider above the first strip; shown only when the
          // previous strip actually rendered.
          readonly property bool showDivider: index > 0 && root.usingCuaca && root.futureStripModel[0].slots.length > 0

          visible: root.usingCuaca && modelData.slots.length > 0
          width: parent.width
          height: (showDivider ? Style.spacing.hairline + Style.space(14) : 0)
                  + stripHead.implicitHeight + Style.space(4) + futureRow.height

          Rectangle {
            visible: parent.showDivider
            anchors.top: parent.top
            width: parent.width
            height: Style.spacing.hairline
            color: root.bar.foreground
            opacity: 0.12
          }

          Row {
            id: stripHead
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: showDivider ? Style.spacing.hairline + Style.space(14) : 0
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.label
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }
            Text {
              visible: modelData.day !== ""
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.day
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }
            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: modelData.hi
                color: modelData.hiColor !== "" ? modelData.hiColor : root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                textFormat: Text.PlainText
                text: modelData.lo
                color: modelData.loColor !== "" ? modelData.loColor : Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          Row {
            id: futureRow
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: stripHead.bottom
            anchors.topMargin: Style.space(4)
            spacing: Style.space(18)

            Repeater {
              model: modelData.slots

              Column {
                required property var modelData
                spacing: Style.space(3)

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  // Slot time is location-local; "HH:MM" drops the seconds.
                  text: String(modelData.time || "").slice(11, 16)
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: root.slotIcon(modelData)
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.display
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: root.bareTempForSlot(modelData)
                  color: root.tempColorOrDefault(modelData.temp, root.bar.foreground)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }
                readonly property var rain: Model.slotRainProb(modelData)
                Text {
                  visible: rain.text !== ""
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: rain.text
                  color: rain.wet
                    ? Style.selectedStateColor(root.bar.foreground, Commons.Color.accent)
                    : Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
                readonly property var wind: Model.slotWind(modelData, useImperial)
                Row {
                  visible: wind.text !== ""
                  anchors.horizontalCenter: parent.horizontalCenter
                  spacing: Style.space(4)

                  Text {
                    visible: wind.arrow !== ""
                    textFormat: Text.PlainText
                    text: wind.arrow
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: wind.speed
                    color: colorMode === "color" && wind.color !== ""
                      ? wind.color
                      : (wind.strong
                         ? Style.selectedStateColor(root.bar.foreground, Commons.Color.accent)
                         : Qt.darker(root.bar.foreground, 1.5))
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }
      }

      // ---- Carousel dots: one per recorded location, the active one
      //      accented; a tap jumps straight there. Hidden below two
      //      locations — a single dot is decoration and the cycle has
      //      nowhere to go.
      Row {
        visible: root.recentLocations.length >= 2
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(8)

        Repeater {
          model: root.recentLocations

          Item {
            id: pageDot
            required property var modelData
            readonly property bool isActive: root.isCurrentRecent(pageDot.modelData)

            width: Style.space(14)
            height: Style.space(14)

            Rectangle {
              anchors.centerIn: parent
              width: Style.space(6)
              height: Style.space(6)
              radius: width / 2
              color: pageDot.isActive ? Commons.Color.accent : root.bar.foreground
              opacity: pageDot.isActive ? 1 : 0.35
              Behavior on opacity { NumberAnimation { duration: 120 } }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.switchToRecent(pageDot.modelData)
            }
          }
        }
      }

    }
  }

      // ---- Settings: a fixed corner gear plus a dropdown menu.
      //      Both live in this layer, declared after the Flickable, so
      //      they paint above the popup's scroll content and stay put
      //      while it scrolls. The gear is always visible; the menu
      //      drops beneath it and closes on outside click, outside
      //      wheel, ESC, or a gear re-click. Rows, optimistic reads,
      //      and write routes are the same machinery the modal used —
      //      presentation changed, behavior not.
      Item {
        id: settingsLayer
        anchors.fill: parent

        // ---- the dropdown: catcher + card, only while open
        Item {
          id: settingsMenu
          anchors.fill: parent
          // The reveal: opacity drives both the fade and the slide. visible
          // rides opacity (not the flag) so the hide animation plays out
          // before the layer actually disappears.
          visible: settingsMenu.opacity > 0
          opacity: root.settingsOpen ? 1 : 0
          Behavior on opacity {
            NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
          }

          // No scrim — the popup stays fully visible behind the menu.
          // The catcher only eats clicks and wheel outside the card.
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.ArrowCursor
            onClicked: root.settingsOpen = false
            onWheel: function(wheel) { wheel.accepted = true; root.settingsOpen = false }
          }

          BorderSurface {
            id: settingsCard
            width: Math.min(parent.width - Style.space(40), Style.space(300))
            height: Math.min(cardContent.implicitHeight + Style.space(28), parent.height - Style.space(48))
            radius: Style.cornerRadius
            color: root.bar.background
            borderSpec: Border.controlSpec("normal", root.bar.foreground, Commons.Color.accent)
            // Right-aligned beneath the gear; clamped so a short popup
            // never pushes the menu past either edge.
            x: Math.max(Style.space(20), parent.width - width - Style.space(20))
            // The reveal: the card starts tucked under the gear and slides
            // down to rest as the menu fades in; back up as it fades out.
            readonly property real restY: Math.min(
              settingsGear.y + settingsGear.height + Style.space(6),
              Math.max(Style.space(12), parent.height - height - Style.space(12)))
            y: restY - Style.space(10) * (1 - settingsMenu.opacity)

            // Wheel guard: wheel over the card never reaches the catcher,
            // so only wheel outside the menu can close it.
            MouseArea {
              anchors.fill: parent
              onWheel: function(wheel) { wheel.accepted = true }
            }

            // The five rows can outgrow a short popup; scroll inside the
            // card rather than clip.
            Flickable {
              id: cardScroll
              anchors.fill: parent
              anchors.margins: Style.space(14)
              contentHeight: cardContent.implicitHeight
              contentWidth: width
              interactive: contentHeight > height
              clip: true

              Column {
                id: cardContent
                width: cardScroll.width
                spacing: Style.space(10)

                // ---- LOCATIONS: quick-switch recents
                // Previously used villages and spots, newest first; one
                // tap switches (weather.json rewrite + refetch, the known
                // adm4 skipping the resolve round-trip). The section leads
                // the card and appears once a location is recorded — a
                // lone row is the current village, accented.
                Column {
                  visible: root.recentLocations.length >= 1
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    text: "LOCATIONS"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                  }

                  Rectangle {
                    width: parent.width
                    height: 1
                    color: root.bar.foreground
                    opacity: 0.12
                  }

                  Repeater {
                    model: root.recentLocations

                    Item {
                      id: recentRow
                      required property var modelData

                      readonly property bool isActive: root.isCurrentRecent(recentRow.modelData)

                      width: parent.width
                      height: recentRowLabel.implicitHeight + Style.space(10)

                      Rectangle {
                        anchors.fill: parent
                        radius: Style.cornerRadius
                        color: recentRowHover.hovered && !recentRow.isActive
                          ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)
                          : "transparent"
                      }

                      HoverHandler { id: recentRowHover }

                      Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(6)

                        Text {
                          textFormat: Text.PlainText
                          text: ""
                          color: recentRow.isActive ? Commons.Color.accent : Qt.darker(root.bar.foreground, 1.4)
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.caption
                          anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                          id: recentRowLabel
                          textFormat: Text.PlainText
                          text: String(recentRow.modelData.name)
                          color: recentRow.isActive ? Commons.Color.accent : root.bar.foreground
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.body
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.switchToRecent(recentRow.modelData)
                      }
                    }
                  }
                }

                Text {
                  id: settingsCaption
                  textFormat: Text.PlainText
                  text: "SETTINGS"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }

                Rectangle {
                  width: parent.width
                  height: 1
                  color: root.bar.foreground
                  opacity: 0.12
                }

                Repeater {
                  model: root.settingsRows

                  Column {
                    id: settingRow
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(6)

                    Text {
                      textFormat: Text.PlainText
                      text: String(settingRow.modelData.label || settingRow.modelData.key || "")
                      color: Qt.darker(root.bar.foreground, 1.4)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    // ---- enum field: one pick per option
                    Row {
                      visible: String(settingRow.modelData.type) !== "integer"
                      spacing: Style.space(6)

                      Repeater {
                        model: (settingRow.modelData.options !== undefined && settingRow.modelData.options !== null)
                          ? settingRow.modelData.options
                          : []

                        BorderSurface {
                          id: segment
                          required property var modelData
                          required property int index

                          readonly property string optionValue: String(modelData)
                          readonly property bool isSelected: String(root.effectiveSetting(settingRow.modelData.key, settingRow.modelData.defaultValue)) === optionValue

                          width: optionText.implicitWidth + Style.space(20)
                          height: optionText.implicitHeight + Style.space(10)
                          radius: Style.cornerRadius
                          color: isSelected
                            ? Style.selectedFillFor(root.bar.foreground, Commons.Color.accent)
                            : (segmentHover.hovered
                              ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)
                              : "transparent")
                          borderSpec: Border.controlSpec(
                            segment.isSelected ? "selected"
                              : (segmentHover.hovered ? "hover-cursor" : "normal"),
                            root.bar.foreground, Commons.Color.accent)

                          Text {
                            id: optionText
                            textFormat: Text.PlainText
                            anchors.centerIn: parent
                            text: segment.optionValue
                            color: segment.isSelected
                              ? Style.selectedStateColor(root.bar.foreground, Commons.Color.accent)
                              : Qt.darker(root.bar.foreground, 1.3)
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.caption
                          }

                          HoverHandler { id: segmentHover }
                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.writeSetting(settingRow.modelData.key, segment.optionValue)
                          }
                        }
                      }
                    }

                    // ---- integer field: − / value / +
                    Row {
                      visible: String(settingRow.modelData.type) === "integer"
                      spacing: Style.space(8)

                      BorderSurface {
                        id: stepButtonMinus
                        width: stepGlyph.implicitWidth + Style.space(16)
                        height: stepGlyph.implicitHeight + Style.space(10)
                        radius: Style.cornerRadius
                        color: minusHover.hovered
                          ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)
                          : "transparent"
                        borderSpec: Border.controlSpec(
                          minusHover.hovered ? "hover-cursor" : "normal",
                          root.bar.foreground, Commons.Color.accent)

                        Text {
                          id: stepGlyph
                          textFormat: Text.PlainText
                          anchors.centerIn: parent
                          text: "−"
                          color: Qt.darker(root.bar.foreground, 1.3)
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.caption
                        }

                        HoverHandler { id: minusHover }
                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            var def = settingRow.modelData
                            var min = def.min !== undefined ? Number(def.min) : 1
                            var max = def.max !== undefined ? Number(def.max) : 60
                            var stepSize = def.step !== undefined ? Number(def.step) : 1
                            var current = Number(root.effectiveSetting(def.key, def.defaultValue)) || 0
                            root.writeSetting(def.key, Math.max(min, current - stepSize))
                          }
                        }
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: String(root.effectiveSetting(settingRow.modelData.key, settingRow.modelData.defaultValue))
                        color: root.bar.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.body
                        width: Style.space(30)
                        horizontalAlignment: Text.AlignHCenter
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      BorderSurface {
                        id: stepButtonPlus
                        width: stepGlyphPlus.implicitWidth + Style.space(16)
                        height: stepGlyphPlus.implicitHeight + Style.space(10)
                        radius: Style.cornerRadius
                        color: plusHover.hovered
                          ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)
                          : "transparent"
                        borderSpec: Border.controlSpec(
                          plusHover.hovered ? "hover-cursor" : "normal",
                          root.bar.foreground, Commons.Color.accent)

                        Text {
                          id: stepGlyphPlus
                          textFormat: Text.PlainText
                          anchors.centerIn: parent
                          text: "+"
                          color: Qt.darker(root.bar.foreground, 1.3)
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.caption
                        }

                        HoverHandler { id: plusHover }
                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            var defPlus = settingRow.modelData
                            var maxPlus = defPlus.max !== undefined ? Number(defPlus.max) : 60
                            var stepPlus = defPlus.step !== undefined ? Number(defPlus.step) : 1
                            var currentPlus = Number(root.effectiveSetting(defPlus.key, defPlus.defaultValue)) || 0
                            root.writeSetting(defPlus.key, Math.min(maxPlus, currentPlus + stepPlus))
                          }
                        }
                      }
                    }
                  }
                }

              }
            }
          }
        }

        // ---- corner gear: fixed, always visible, toggles the menu
        Item {
          id: settingsGear
          width: Style.space(22)
          height: Style.space(22)
          anchors.top: parent.top
          anchors.topMargin: Style.space(10)
          anchors.right: parent.right
          anchors.rightMargin: Style.space(20)

          Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: gearCornerHover.hovered
              ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)
              : "transparent"
          }

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: ""  // nf-fa-gear
            color: gearCornerHover.hovered
              ? Qt.darker(root.bar.foreground, 1.15)
              : Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }

          HoverHandler { id: gearCornerHover }
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.settingsOpen = !root.settingsOpen
          }
        }
      }
    }
  }

}
