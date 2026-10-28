// Offline unit tests for Model.js — no network needed, fixtures pin the
// cuaca-worker response contract. Run: node tests/model.test.js

const path = require("path")
const fs = require("fs")
const Model = require(path.join(__dirname, "..", "Model.js"))

let failures = 0
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected)
  if (!ok) failures++
  console.log((ok ? "PASS" : "FAIL") + "  " + name + (ok ? "" : "  got=" + JSON.stringify(actual) + " want=" + JSON.stringify(expected)))
}

function fixture(name) {
  return JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", name), "utf8"))
}

const bmkg = fixture("bmkg.json")
const nearest = fixture("nearest.json")
const resolve = fixture("resolve.json")
const warnings = fixture("warnings.json")

const TODAY = bmkg.forecast[0].time.slice(0, 10)

// ---- parseLocationFile ----
check("parseLocationFile: unset", Model.parseLocationFile(""), { name: "", latitude: null, longitude: null })
check("parseLocationFile: junk", Model.parseLocationFile("not json"), { name: "", latitude: null, longitude: null })
// weather.json shape (what omarchy-weather-location writes from a picked
// cuaca row): latitude/longitude keys, not the API's lat/lon.
const weatherJsonRow = nearest.results[0]
check("parseLocationFile: valid", Model.parseLocationFile(JSON.stringify({
  name: weatherJsonRow.name, latitude: weatherJsonRow.lat, longitude: weatherJsonRow.lon
})), { name: "Kemayoran", latitude: weatherJsonRow.lat, longitude: weatherJsonRow.lon })

// ---- wttrLocationQuery (fallback path) ----
check("wttrLocationQuery: coords", Model.wttrLocationQuery("x", "-6.16", "106.84"), "-6.16,106.84")
check("wttrLocationQuery: name", Model.wttrLocationQuery("Singapore", null, null), "Singapore")
check("wttrLocationQuery: empty", Model.wttrLocationQuery("", null, null), "")

// ---- parseCuacaResults ----
const nearestRows = Model.parseCuacaResults(JSON.stringify(nearest))
check("parseCuacaResults nearest: count", nearestRows.length, 1)
check("parseCuacaResults nearest: row", nearestRows[0], {
  code: "31.71.03.1001", name: "Kemayoran",
  description: "Kemayoran, Kota Administrasi Jakarta Pusat, Provinsi Daerah Khusus Ibukota Jakarta",
  latitude: -6.16472149956286, longitude: 106.84538416386849, distKm: 0.00296313562625917
})
const resolveRows = Model.parseCuacaResults(JSON.stringify(resolve))
check("parseCuacaResults resolve: count", resolveRows.length, 3)
check("parseCuacaResults resolve: no distKm on resolve rows", resolveRows[0].distKm === undefined, true)
check("parseCuacaResults: empty results", Model.parseCuacaResults('{"results": []}'), [])
check("parseCuacaResults: junk", Model.parseCuacaResults("<html>"), [])

// ---- distance cap: /api/nearest always returns a village, even for
// coordinates on other continents — the cap separates "resolved" from "abroad"
const london = { results: [{ code: "52.01.08.2001", name: "Blang Lancang", district: "Kuta", city: "Kabupaten Aceh Besar", province: "Provinsi Aceh", lat: 5.4, lon: 95.6, dist_km: 11500 }] }
const londonRows = Model.parseCuacaResults(JSON.stringify(london))
check("distance cap: far nearest exceeds limit", londonRows[0].distKm > Model.cuacaMaxResolveDistanceKm, true)

// ---- normalizeBmkgCode ----
check("normalizeBmkgCode: 60→61", Model.normalizeBmkgCode(60), 61)
check("normalizeBmkgCode: 97→95", Model.normalizeBmkgCode(97), 95)
check("normalizeBmkgCode: 5→45", Model.normalizeBmkgCode(5), 45)
check("normalizeBmkgCode: 10→45", Model.normalizeBmkgCode(10), 45)
check("normalizeBmkgCode: passthru 61", Model.normalizeBmkgCode(61), 61)
check("normalizeBmkgCode: null", Model.normalizeBmkgCode(null), null)

// ---- bmkgCurrentCondition ----
const current = Model.bmkgCurrentCondition(bmkg)
const slot0 = bmkg.forecast[0]
check("bmkgCurrent: first slot is current", current.temp_C, String(Math.round(slot0.temp)))
check("bmkgCurrent: temp_F", current.temp_F, String(Math.round(slot0.temp * 9 / 5 + 32)))
check("bmkgCurrent: humidity", current.humidity, String(slot0.humidity))
// Round-to-integer convention, shared with the open-meteo normalization
// (wttr reports integer speeds; hero read-outs stay consistent).
check("bmkgCurrent: wind km/h (rounded)", current.windspeedKmph, String(Math.round(slot0.windSpeed)))
check("bmkgCurrent: wind mph", current.windspeedMiles, String(Math.round(slot0.windSpeed * 0.621371)))
const slotHour = parseFloat(String(slot0.time).slice(11, 13))
check("bmkgCurrent: isDay matches slot hour", current.isDay, (slotHour >= 6 && slotHour < 18))
check("bmkgCurrent: condition preserved", current.bmkgCondition, slot0.condition)
check("bmkgCurrent: code normalized", current.bmkgWeatherCode, Model.normalizeBmkgCode(slot0.weather))
check("bmkgCurrent: rainProb", current.rainProb, String(slot0.rainProb))
check("bmkgCurrent: empty forecast", Model.bmkgCurrentCondition({ forecast: [] }), null)
check("bmkgCurrent: null report", Model.bmkgCurrentCondition(null), null)

// ---- bmkgTodaySlots ----
const todaySlots = Model.bmkgTodaySlots(bmkg)
const todayCount = bmkg.forecast.filter(s => s.time.slice(0, 10) === TODAY).length
check("bmkgTodaySlots: today only", todaySlots.length, todayCount)
check("bmkgTodaySlots: first is current slot", todaySlots[0].time, slot0.time)
check("bmkgTodaySlots: none cross to tomorrow", todaySlots.every(s => s.time.slice(0, 10) === TODAY), true)
check("bmkgTodaySlots: empty", Model.bmkgTodaySlots({ forecast: [] }), [])

// ---- bmkgSlotIcon (night from location-local slot hour) ----
const nightSlot = { time: "2026-10-28 22:00:00", weather: 1 }
const daySlot = { time: "2026-10-28 10:00:00", weather: 1 }
check("bmkgSlotIcon: 22h night differs from 10h day",
  Model.bmkgSlotIcon(nightSlot) !== Model.bmkgSlotIcon(daySlot), true)
check("bmkgSlotIcon: matches mapper",
  Model.bmkgSlotIcon(daySlot), Model.iconForOpenMeteoCode(Model.normalizeBmkgCode(1), false))

// ---- bmkgForecastDays ----
const days = Model.bmkgForecastDays(bmkg, TODAY)
const futureDates = [...new Set(bmkg.forecast.map(s => s.time.slice(0, 10)))].filter(d => d > TODAY)
check("bmkgDays: future-only days", days.length, futureDates.length)
console.log("       dates in response:", JSON.stringify([...new Set(bmkg.forecast.map(s => s.time.slice(0, 10)))]))
for (const day of days) {
  const slots = bmkg.forecast.filter(s => s.time.slice(0, 10) === day.date)
  check(`bmkgDays ${day.date}: maxtempC`, day.maxtempC, String(Math.max(...slots.map(s => s.temp))))
  check(`bmkgDays ${day.date}: mintempC`, day.mintempC, String(Math.min(...slots.map(s => s.temp))))
  check(`bmkgDays ${day.date}: maxtempF`, day.maxtempF, String(Math.round(Math.max(...slots.map(s => s.temp)) * 9 / 5 + 32)))
  // Icon slot nearest noon
  const noonSlot = slots.reduce((best, s) => Math.abs(parseInt(s.time.slice(11, 13)) * 100 - 1200) < Math.abs(parseInt(best.time.slice(11, 13)) * 100 - 1200) ? s : best)
  check(`bmkgDays ${day.date}: noon-nearest icon code`, day.bmkgWeatherCode, Model.normalizeBmkgCode(noonSlot.weather))
}
check("bmkgDays: empty", Model.bmkgForecastDays({ forecast: [] }, "2000-01-01"), [])

// ---- buildForecastDays precedence ----
const bmkgOnly = Model.buildForecastDays(null, null, bmkg, TODAY)
check("buildForecastDays: bmkg wins", bmkgOnly.length > 0 && days.map(d => d.date).join(","), [bmkgOnly[0].date].concat(days.slice(1).map(d => d.date)).join(","))

// ---- parseBmkgWarnings ----
const warningRows = Model.parseBmkgWarnings(JSON.stringify(warnings))
check("parseBmkgWarnings: usable rows kept", warningRows.length, 3)  // event-bearing rows kept; blanks/nulls/scalars dropped
check("parseBmkgWarnings: row1 full keys", warningRows[0], {
  event: "Hujan Petir", severity: "moderate", area: "DKI Jakarta",
  onset: "2026-11-01 00:00:00", description: "Potensi hujan petir intensitas sedang"
})
check("parseBmkgWarnings: row2 desc synonyms", warningRows[1], {
  event: "", severity: "severe", area: "Bandung", onset: "", description: "Angin kencang"
})
check("parseBmkgWarnings: row3 onset synonyms", warningRows[2], {
  event: "Ombak Tinggi", severity: "", area: "", onset: "2026-11-02 06:00", description: ""
})
check("parseBmkgWarnings: empty", Model.parseBmkgWarnings(JSON.stringify(fixture("warnings-empty.json"))), [])
check("parseBmkgWarnings: junk", Model.parseBmkgWarnings("<html>"), [])

// ---- currentIcon bmkg branch ----
const iconCode = Model.currentIcon(current, "")
const expectedIcon = Model.iconForOpenMeteoCode(current.bmkgWeatherCode, !current.isDay)
check("currentIcon: bmkg branch used", iconCode, expectedIcon)
check("currentIcon: fallback when null", Model.currentIcon(null, "␦"), "␦")

// ---- weatherResponseCompletesSave ----
check("save completion: cuaca path bmkg", Model.weatherResponseCompletesSave(true, true, "bmkg"), true)
check("save completion: cuaca path wttr ignored", Model.weatherResponseCompletesSave(true, true, "wttr"), false)
check("save completion: fallback coords open-meteo", Model.weatherResponseCompletesSave(false, true, "open-meteo"), true)
check("save completion: fallback name wttr", Model.weatherResponseCompletesSave(false, false, "wttr"), true)

// ---- legacy behavior intact ----
const omCur = Model.openMeteoCurrentCondition({ current: { temperature_2m: 30, apparent_temperature: 34, wind_speed_10m: 10, relative_humidity_2m: 70, weather_code: 0, is_day: 1 } })
check("openMeteoCurrentCondition intact", [omCur.temp_C, omCur.temp_F, omCur.humidity], ["30", "86", "70"])
check("dayName", Model.dayName("2026-10-28", d => d.getDay ? "ok" : "bad"), "ok")
check("shouldUseImperial: override", [Model.shouldUseImperial("imperial", "id_ID", ""), Model.shouldUseImperial("metric", "en_US", "")], [true, false])
check("shouldUseImperial: country", [Model.shouldUseImperial("", "", "United States"), Model.shouldUseImperial("", "", "Indonesia")], [true, false])

// ---- locationCommit with cuaca rows ----
const committed = Model.locationCommit("Kemayoran", resolveRows, 0)
check("locationCommit: picks suggestion", [committed.name, committed.code], ["Kemayoran", "31.71.03.1001"])
check("locationCommit: bare text", Model.locationCommit("Bali", [], 0), { name: "Bali", latitude: null, longitude: null })

console.log(failures === 0 ? "\nALL PASS" : "\n" + failures + " FAILURES")
process.exit(failures === 0 ? 0 : 1)
