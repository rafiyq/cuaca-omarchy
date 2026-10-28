// weather.json holds {"name": ..., "latitude": ..., "longitude": ...} (see
// omarchy-weather-location, which owns the format). Missing, blank, or
// unparseable falls back to the cuaca worker's default village (Kemayoran).
// Coordinates anywhere in the world are supported: point resolution against
// the cuaca API decides between BMKG data (Indonesia) and the wttr/Open-Meteo
// worldwide path.
function parseLocationFile(raw) {
  var unset = { name: "", latitude: null, longitude: null }
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return unset

    var latitude = parseFloat(data.latitude)
    var longitude = parseFloat(data.longitude)
    var hasCoordinates = !isNaN(latitude) && !isNaN(longitude)
    return {
      name: typeof data.name === "string" ? data.name.replace(/^\s+|\s+$/g, "") : "",
      latitude: hasCoordinates ? latitude : null,
      longitude: hasCoordinates ? longitude : null
    }
  } catch (e) {
    return unset
  }
}

// wttr.in path segment for a configured location: exact coordinates when
// both are present, the URL-encoded name as a fallback (hand-edited
// weather.loc files may only carry a name), empty for IP auto-detect.
// Only reaches wttr when the cuaca path was tried first and found nothing.
function wttrLocationQuery(location, latitude, longitude) {
  var lat = parseFloat(String(latitude))
  var lon = parseFloat(String(longitude))
  if (!isNaN(lat) && !isNaN(lon)) return lat + "," + lon

  var name = String(location || "").replace(/^\s+|\s+$/g, "")
  return name === "" ? "" : encodeURIComponent(name)
}

// ---- cuaca.wilayah.workers.dev (BMKG weather for Indonesia).
//      Locations are villages keyed by an adm4 code; /api/resolve on a name
//      and /api/nearest on coordinates both answer with the same result
//      shape, so one parser covers both. Locations outside Indonesia have
//      no match (or an absurdly distant nearest village) and the caller
//      falls back to wttr/Open-Meteo.

// Guard for the coordinates → village lookup: /api/nearest always returns
// the closest Indonesian village, even for coordinates on other continents.
// Anything farther than this is effectively "not in Indonesia".
var cuacaMaxResolveDistanceKm = 50

// Cuaca resolve/nearest response → suggestion rows. Both carry
// {results: [{code, name, district, city, province, lat, lon, dist_km?}];
// nearest additionally has dist_km. Kept as suggestion-shaped rows so the
// location picker treats cuaca villages and Open-Meteo cities alike.
function parseCuacaResults(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var results = data.results
    if (!results || !results.length) return []

    var out = []
    for (var i = 0; i < results.length; i++) {
      var r = results[i]
      if (!r || !r.code || !r.name || r.lat === undefined || r.lon === undefined) continue
      var region = [r.district, r.city, r.province].filter(function(part) { return !!part }).join(", ")
      var row = {
        code: String(r.code),
        name: String(r.name),
        description: region,
        latitude: r.lat,
        longitude: r.lon
      }
      var dist = parseFloat(String(r.dist_km))
      if (!isNaN(dist)) row.distKm = dist
      out.push(row)
    }
    return out
  } catch (e) {
    return []
  }
}

// BMKG weather codes follow WMO semantics but use values the wttr-based
// icon table lacks. Aliased onto the Open-Meteo icon mapping; other values
// pass through (the glyph function already defaults sensibly).
function normalizeBmkgCode(code) {
  if (code === undefined || code === null || code === "") return null
  var c = parseInt(String(code), 10)
  if (isNaN(c)) return null
  if (c === 60) return 61      // drizzle → light rain
  if (c === 97) return 95      // thundery hail → storm
  if (c === 5 || c === 10) return 45  // both fog variants
  return c
}

function bmkgSlotHour(slot) {
  // Slot time is location-local wall clock, "YYYY-MM-DD HH:mm:ss". Local
  // timezone means hour < 6 or >= 18 is night for icon purposes without
  // any timezone arithmetic.
  var hour = parseInt(String(slot && slot.time ? slot.time : "0").slice(11, 13), 10)
  return isNaN(hour) ? 12 : hour
}

function slotIsDay(hour) {
  return hour >= 6 && hour < 18
}

// First slot of the conform response = current conditions (BMKG starts the
// series at the current 3-hour block). Normalized to wttr's
// current_condition shape so the panel treats all three sources
// interchangeably. BMKG reports metric (°C, km/h) and has no feels-like;
// the FEELS read-out it fed upstream is dropped from the panel.
function bmkgCurrentCondition(bmkgReport) {
  var slots = bmkgReport && bmkgReport.forecast ? bmkgReport.forecast : []
  var slot = slots.length > 0 ? slots[0] : null
  if (!slot || slot.temp === undefined || slot.temp === null) return null

  var hour = bmkgSlotHour(slot)
  return {
    temp_C: roundedTemp(slot.temp),
    temp_F: roundedTemp(celsiusToFahrenheit(slot.temp)),
    FeelsLikeC: null,
    FeelsLikeF: null,
    windspeedKmph: roundedTemp(slot.windSpeed),
    windspeedMiles: roundedTemp(parseFloat(String(slot.windSpeed)) * 0.621371),
    humidity: roundedTemp(slot.humidity),
    rainProb: roundedTemp(slot.rainProb),
    bmkgWeatherCode: normalizeBmkgCode(slot.weather),
    bmkgCondition: typeof slot.condition === "string" ? slot.condition : "",
    bmkgConditionEn: typeof slot.conditionEn === "string" ? slot.conditionEn : "",
    isDay: slotIsDay(hour)
  }
}

// Flat 3-hourly slots → per-day rows matching the Open-Meteo shape the
// forecast row consumes: future dates only, daily hi/lo, and the weather
// code of the slot nearest noon as the representative day icon.
function bmkgForecastDays(bmkgReport, todayString) {
  var slots = bmkgReport && bmkgReport.forecast ? bmkgReport.forecast : []
  if (!slots.length) return []

  var byDate = []
  var index = {}
  for (var i = 0; i < slots.length; i++) {
    var date = String(slots[i].time || "").slice(0, 10)
    if (!date || !isFutureForecastDate(date, todayString)) continue
    if (index[date] === undefined) {
      index[date] = byDate.length
      byDate.push({ date: date, slots: [] })
    }
    byDate[index[date]].slots.push(slots[i])
  }

  var result = []
  for (var d = 0; d < byDate.length && result.length < 3; d++) {
    var slotsForDay = byDate[d].slots
    if (!slotsForDay.length) continue

    var hi = null
    var lo = null
    var iconSlot = slotsForDay[0]
    var iconDist = 9999
    for (var s = 0; s < slotsForDay.length; s++) {
      var slot = slotsForDay[s]
      var t = parseFloat(String(slot.temp))
      if (!isNaN(t)) {
        if (hi === null || t > hi) hi = t
        if (lo === null || t < lo) lo = t
      }
      var dist = Math.abs(bmkgSlotHour(slot) * 100 - 1200)
      if (dist < iconDist) {
        iconDist = dist
        iconSlot = slot
      }
    }

    result.push({
      date: byDate[d].date,
      maxtempC: roundedTemp(hi),
      mintempC: roundedTemp(lo),
      maxtempF: roundedTemp(celsiusToFahrenheit(hi)),
      mintempF: roundedTemp(celsiusToFahrenheit(lo)),
      bmkgWeatherCode: normalizeBmkgCode(iconSlot.weather)
    })
  }
  return result
}

// Remaining slots for the day the series starts on (the current 3-hour
// block onward). The slot strip only ever needs today; future days live in
// the forecast row.
function bmkgTodaySlots(bmkgReport) {
  var slots = bmkgReport && bmkgReport.forecast ? bmkgReport.forecast : []
  if (!slots.length) return []

  var today = String(slots[0].time || "").slice(0, 10)
  var out = []
  for (var i = 0; i < slots.length; i++) {
    if (String(slots[i].time || "").slice(0, 10) !== today) break
    out.push(slots[i])
  }
  return out
}

// Strip/hero icon for a raw slot: location-local hour decides night.
function bmkgSlotIcon(slot, scheme) {
  return iconForOpenMeteoCode(normalizeBmkgCode(slot.weather), !slotIsDay(bmkgSlotHour(slot)), scheme)
}

// BMKG warning rows (CAP parsed at the worker). The endpoint answers empty
// between events, and event payloads come in richer and leaner variants
// depending on data availability, so every key is tolerated. Only rows that
// carry something to show are kept.
function parseBmkgWarnings(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var list = data.warnings
    if (!list || !list.length) return []

    var out = []
    for (var i = 0; i < list.length; i++) {
      var r = list[i]
      if (!r || typeof r !== "object") continue
      var row = {
        event: firstString(r.event, r.headline, r.title),
        severity: firstString(r.severity, r.level),
        area: firstString(r.area, r.areaDesc),
        onset: firstString(r.onset, r.time, r.effective),
        description: firstString(r.description, r.desc)
      }
      if (row.event === "" && row.description === "" && row.area === "") continue
      out.push(row)
    }
    return out
  } catch (e) {
    return []
  }
}

function firstString() {
  for (var i = 0; i < arguments.length; i++) {
    var v = arguments[i]
    if (typeof v === "string" && v !== "") return v
    if (typeof v === "number") return String(v)
  }
  return ""
}

// Boot-time icon cache (~/.cache/cuaca.weather/report.json), written by
// the panel after each successful BMKG fetch. Null when absent, junky, or
// missing the weather code hydration needs.
function parseReportCache(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return null
    var code = parseInt(String(data.weatherCode === undefined || data.weatherCode === null ? "" : data.weatherCode), 10)
    if (isNaN(code)) return null
    return {
      locationState: parseLocationFile(JSON.stringify(data.locationState || null)),
      weatherCode: code,
      isDay: Number(data.isDay) === 1
    }
  } catch (e) {
    return null
  }
}

// Open-Meteo geocoding response → suggestion rows for the location picker.
function parseGeocodingResults(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var results = data.results
    if (!results || !results.length) return []

    var out = []
    for (var i = 0; i < results.length; i++) {
      var r = results[i]
      if (!r || !r.name || r.latitude === undefined || r.longitude === undefined) continue
      var region = [r.admin1, r.country].filter(function(part) { return !!part }).join(", ")
      out.push({
        name: String(r.name),
        description: region,
        latitude: r.latitude,
        longitude: r.longitude
      })
    }
    return out
  } catch (e) {
    return []
  }
}

function locationCommit(text, suggestions, selectedIndex) {
  var name = String(text || "").replace(/^\s+|\s+$/g, "")
  if (name === "") return { name: "", latitude: null, longitude: null }

  var choices = suggestions || []
  var index = Math.max(0, Math.min(parseInt(selectedIndex, 10) || 0, choices.length - 1))
  var suggestion = choices[index]
  if (suggestion) return suggestion

  return { name: name, latitude: null, longitude: null }
}

function isFutureForecastDate(dateString, todayString) {
  if (!dateString) return false
  return String(dateString).slice(0, 10) > String(todayString || "")
}

// Machine-local dates drift from the forecast location's calendar the
// moment the user travels east or west of BMKG's grids ("today" in Tokyo
// while BMKG's Jakarta is still yesterday). Resolve the location's date
// through its IANA zone; any failure — including QML engines without the
// Intl API — silently keeps the caller's fallback.
function todayInTimeZone(tzName, fallbackToday) {
  var tz = String(tzName || "").trim()
  if (tz === "") return fallbackToday
  try {
    if (typeof Intl === "undefined" || !Intl.DateTimeFormat) return fallbackToday
    var fmt = new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" })
    var parts = fmt.formatToParts(new Date())
    var year = "", month = "", day = ""
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].type === "year") year = parts[i].value
      else if (parts[i].type === "month") month = parts[i].value
      else if (parts[i].type === "day") day = parts[i].value
    }
    if (year && month && day) return year + "-" + month + "-" + day
    return fallbackToday
  } catch (e) {
    return fallbackToday
  }
}

function roundedTemp(value) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  return isNaN(n) ? "" : String(Math.round(n))
}

function celsiusToFahrenheit(value) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  return isNaN(n) ? "" : (n * 9 / 5) + 32
}

function formatTemp(value, useImperial) {
  if (value === undefined || value === null || value === "") return ""
  return value + "°" + (useImperial ? "F" : "C")
}

function normalizedUnit(value) {
  return String(value || "").replace(/^\s+|\s+$/g, "").toLowerCase()
}

function localeUsesImperial(localeName) {
  var name = String(localeName || "").replace(".", "_")
  return /^en[_-]US($|[_.-])/.test(name) || /^en[_-]LR($|[_.-])/.test(name) || /^my($|[_.-])/.test(name)
}

function countryUsesImperial(countryName) {
  var country = String(countryName || "")
    .replace(/^\s+|\s+$/g, "")
    .replace(/[._-]+/g, " ")
    .toLowerCase()
  if (!country) return null
  if (country === "us" || country === "usa" || country === "united states" || country === "united states of america") return true
  if (country === "liberia" || country === "myanmar" || country === "burma") return true
  return false
}

function shouldUseImperial(unitOverride, localeName, countryName) {
  var unit = normalizedUnit(unitOverride)
  if (unit === "imperial") return true
  if (unit === "metric") return false

  var countryPreference = countryUsesImperial(countryName)
  if (countryPreference !== null) return countryPreference

  return localeUsesImperial(localeName)
}

function dayName(dateString, formatter) {
  if (!dateString) return ""
  var d = new Date(dateString + "T12:00:00")
  if (isNaN(d.getTime())) return ""
  if (formatter) return formatter(d)
  return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][d.getDay()]
}

function openMeteoForecastDays(dailyForecastReport, todayString) {
  var daily = dailyForecastReport && dailyForecastReport.daily ? dailyForecastReport.daily : null
  if (!daily || !daily.time) return []

  var result = []
  for (var i = 0; i < daily.time.length && result.length < 3; ++i) {
    var date = daily.time[i]
    if (!isFutureForecastDate(date, todayString)) continue

    var maxC = daily.temperature_2m_max ? daily.temperature_2m_max[i] : ""
    var minC = daily.temperature_2m_min ? daily.temperature_2m_min[i] : ""
    result.push({
      date: date,
      maxtempC: roundedTemp(maxC),
      mintempC: roundedTemp(minC),
      maxtempF: roundedTemp(celsiusToFahrenheit(maxC)),
      mintempF: roundedTemp(celsiusToFahrenheit(minC)),
      openMeteoWeatherCode: daily.weather_code ? daily.weather_code[i] : null
    })
  }
  return result
}

// Open-Meteo bundles current conditions with the daily forecast request and
// answers far faster than wttr.in. Normalize them to wttr's
// current_condition shape so the panel can use either source
// interchangeably. Open-Meteo reports metric (°C, km/h).
function openMeteoCurrentCondition(dailyForecastReport) {
  var current = dailyForecastReport && dailyForecastReport.current ? dailyForecastReport.current : null
  if (!current || current.temperature_2m === undefined || current.temperature_2m === null) return null
  return {
    temp_C: roundedTemp(current.temperature_2m),
    temp_F: roundedTemp(celsiusToFahrenheit(current.temperature_2m)),
    FeelsLikeC: roundedTemp(current.apparent_temperature),
    FeelsLikeF: roundedTemp(celsiusToFahrenheit(current.apparent_temperature)),
    windspeedKmph: roundedTemp(current.wind_speed_10m),
    windspeedMiles: roundedTemp(current.wind_speed_10m * 0.621371),
    humidity: roundedTemp(current.relative_humidity_2m),
    openMeteoWeatherCode: current.weather_code,
    isDay: current.is_day
  }
}

function currentIcon(current, fallback, scheme) {
  if (!current) return fallback || ""
  if (current.bmkgWeatherCode !== undefined && current.bmkgWeatherCode !== null)
    return iconForOpenMeteoCode(current.bmkgWeatherCode, !current.isDay, scheme)
  if (current.openMeteoWeatherCode !== undefined && current.openMeteoWeatherCode !== null)
    return iconForOpenMeteoCode(current.openMeteoWeatherCode, Number(current.isDay) === 0, scheme)
  if (current.weatherCode !== undefined && current.weatherCode !== null)
    return iconForCode(current.weatherCode, false, scheme)
  return fallback || ""
}

// wttr.in has no day/night flag. Use its icon only to fill an empty initial
// state, never to replace a day/night-aware icon resolved by Open-Meteo.
function provisionalCurrentIcon(current, resolvedIcon, scheme) {
  return resolvedIcon || currentIcon(current, "", scheme)
}

// Which response completes a location save depends on the active path: the
// cuaca fetch is the fast one there; without it the old contract applies
// (open-meteo when coordinates drive the fetch, wttr otherwise).
function weatherResponseCompletesSave(usingCuaca, hasConfiguredCoordinates, source) {
  if (usingCuaca) return source === "bmkg"
  return hasConfiguredCoordinates ? source === "open-meteo" : source === "wttr"
}

function wttrNextForecastDays(report, todayString) {
  var days = report && report.weather ? report.weather : []
  var result = []
  for (var i = 0; i < days.length && result.length < 3; ++i) {
    if (isFutureForecastDate(days[i].date, todayString)) result.push(days[i])
  }
  return result
}

// Source precedence: BMKG (Indonesia) when it resolved, then the fast
// Open-Meteo daily fetch, then wttr's daily block.
function buildForecastDays(report, dailyForecastReport, bmkgReport, todayString) {
  var days = bmkgForecastDays(bmkgReport, todayString)
  if (days.length > 0) return days
  days = openMeteoForecastDays(dailyForecastReport, todayString)
  return days.length > 0 ? days : wttrNextForecastDays(report, todayString)
}

function bareTempForDay(day, kind, useImperial) {
  if (!day) return ""
  var v = useImperial
    ? (kind === "max" ? day.maxtempF : day.mintempF)
    : (kind === "max" ? day.maxtempC : day.mintempC)
  if (v === undefined || v === null || v === "") return ""
  return v + "°"
}

function dayIcon(day, scheme) {
  if (!day) return ""
  if (day.bmkgWeatherCode !== undefined && day.bmkgWeatherCode !== null)
    return iconForOpenMeteoCode(day.bmkgWeatherCode, false, scheme)
  if (day.openMeteoWeatherCode !== undefined && day.openMeteoWeatherCode !== null)
    return iconForOpenMeteoCode(day.openMeteoWeatherCode, false, scheme)
  if (!day.hourly || day.hourly.length === 0) return ""

  var best = day.hourly[0]
  var bestDist = 9999
  for (var i = 0; i < day.hourly.length; ++i) {
    var t = parseInt(String(day.hourly[i].time || "0"), 10)
    var dist = Math.abs(t - 1200)
    if (dist < bestDist) {
      bestDist = dist
      best = day.hourly[i]
    }
  }
  return iconForCode(best.weatherCode, false, scheme)
}

function iconForOpenMeteoCode(code, night, scheme) {
  var c = parseInt(String(code || "0"), 10)
  if (c === 0) return iconForCode(113, night, scheme)
  if (c === 1 || c === 2) return iconForCode(116, night, scheme)
  if (c === 3) return iconForCode(119, night, scheme)
  if (c === 45 || c === 48) return iconForCode(143, night, scheme)
  if (c === 51 || c === 53 || c === 55 || c === 56 || c === 57 || c === 61) return iconForCode(266, night, scheme)
  if (c === 63 || c === 65 || c === 66 || c === 67 || c === 80 || c === 81 || c === 82) return iconForCode(308, night, scheme)
  if (c === 71 || c === 73 || c === 75 || c === 77 || c === 85 || c === 86) return iconForCode(338, night, scheme)
  if (c === 95 || c === 96 || c === 99) return iconForCode(389, night, scheme)
  return iconForCode(119, night, scheme)
}

// Emoji look-alike of the nerd-font map: same wttr-style codes, same
// day/night intent, for setups where the nerd glyphs render as tofu. Only
// reached when the widget's iconScheme setting says "emoji".
function emojiForCode(code, night) {
  var c = parseInt(String(code || "0"), 10)
  switch (c) {
    case 113: return night ? "🌙" : "☀️"
    case 116: return night ? "🌙" : "⛅"
    case 119: case 122: return "☁️"
    case 143: case 248: case 260: return "🌫️"
    case 176: case 263: case 353: return "🌦️"
    case 179: case 227: case 230: case 323: case 326: case 368:
    case 329: case 332: case 335: case 338: case 371: return "❄️"
    case 182: case 185: case 281: case 284: case 311: case 314:
    case 317: case 320: case 350: case 362: case 365: case 374: case 377:
    case 266: case 293: case 296: case 299: case 302: case 305:
    case 308: case 356: case 359: return "🌧️"
    case 200: case 386: case 389: case 392: case 395: return "⛈️"
    default: return "☁️"
  }
}

function iconForCode(code, night, scheme) {
  if (scheme === "emoji") return emojiForCode(code, night)
  var c = parseInt(String(code || "0"), 10)
  switch (c) {
    case 113: return night ? "" : ""
    case 116: return night ? "" : ""
    case 119: case 122: return ""
    case 143: case 248: case 260: return night ? "\ue346" : "\ue313"
    case 176: case 263: case 353: return night ? "" : ""
    case 179: case 227: case 230: case 323: case 326: case 368: return night ? "" : ""
    case 182: case 185: case 281: case 284: case 311: case 314:
    case 317: case 320: case 350: case 362: case 365: case 374: case 377: return ""
    case 200: case 386: case 389: case 392: case 395: return ""
    case 266: case 293: case 296: case 299: case 302: case 305: case 308: case 356: case 359: return ""
    case 329: case 332: case 335: case 338: case 371: return ""
    default: return ""
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    parseLocationFile: parseLocationFile,
    wttrLocationQuery: wttrLocationQuery,
    cuacaMaxResolveDistanceKm: cuacaMaxResolveDistanceKm,
    parseCuacaResults: parseCuacaResults,
    normalizeBmkgCode: normalizeBmkgCode,
    bmkgCurrentCondition: bmkgCurrentCondition,
    bmkgForecastDays: bmkgForecastDays,
    parseGeocodingResults: parseGeocodingResults,
    locationCommit: locationCommit,
    isFutureForecastDate: isFutureForecastDate,
    roundedTemp: roundedTemp,
    celsiusToFahrenheit: celsiusToFahrenheit,
    formatTemp: formatTemp,
    normalizedUnit: normalizedUnit,
    localeUsesImperial: localeUsesImperial,
    countryUsesImperial: countryUsesImperial,
    shouldUseImperial: shouldUseImperial,
    dayName: dayName,
    todayInTimeZone: todayInTimeZone,
    openMeteoForecastDays: openMeteoForecastDays,
    openMeteoCurrentCondition: openMeteoCurrentCondition,
    bmkgTodaySlots: bmkgTodaySlots,
    bmkgSlotIcon: bmkgSlotIcon,
    parseBmkgWarnings: parseBmkgWarnings,
    parseReportCache: parseReportCache,
    emojiForCode: emojiForCode,
    currentIcon: currentIcon,
    provisionalCurrentIcon: provisionalCurrentIcon,
    weatherResponseCompletesSave: weatherResponseCompletesSave,
    wttrNextForecastDays: wttrNextForecastDays,
    buildForecastDays: buildForecastDays,
    bareTempForDay: bareTempForDay,
    dayIcon: dayIcon,
    iconForOpenMeteoCode: iconForOpenMeteoCode,
    iconForCode: iconForCode
  }
}
