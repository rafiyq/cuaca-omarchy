import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// One carousel page: the full per-location weather body — warnings
// banner, hero, today strip, geocode suggestions, and the future-day
// strips. The page the Panel currently has configured reads live root
// state (the truth the refreshes maintain); every other page reads the
// per-location report cache the prefetch queue maintains. Settling the
// pager on a page commits it, so a rested page is always live-bound.
Item {
  id: page

  required property var modelData
  required property int index
  // The Panel root: bar facade, settings-derived flags, live state for
  // the configured location, and the per-location report cache.
  property var host: null

  implicitHeight: pageColumn.implicitHeight

  readonly property var entry: modelData
  readonly property string locKey: Model.recentLocationKey(entry)
  readonly property bool entryIsVillage: String(entry.adm4 || "") !== ""
  readonly property bool isCurrent: host ? host.isCurrentRecent(entry) : false
  readonly property var cached: (host && host.pageReports[locKey]) ? host.pageReports[locKey] : ({})
  readonly property var bar: host ? host.bar : null

  // Per-page data. The cuaca cache wins for village pages — a cached
  // forecast keeps the full strip view alive even while the live path is
  // flipped to its wttr fallback (the worker flaps around BMKG's
  // analysis refreshes; without this, every flap collapsed the pages to
  // hero-only). Live state fills the gap when the cache has nothing yet;
  // the refresh keeps both in agreement.
  readonly property var cuacaData: !entryIsVillage ? null
    : (cached.cuaca || (isCurrent ? (host.usingCuaca ? host.bmkgReport : null) : null))
  readonly property var wttrData: isCurrent
    ? (!host.usingCuaca ? (host.report || null) : null)
    : (entryIsVillage ? null : (cached.wttr || null))
  readonly property var dailyData: isCurrent
    ? (!host.usingCuaca ? (cached.daily || host.dailyForecastReport) : null)
    : (entryIsVillage ? null : (cached.daily || null))
  readonly property bool pageIsCuaca: cuacaData !== null
  readonly property var pageWarnings: isCurrent
    ? (cached.warnings && cached.warnings.length ? cached.warnings : host.bmkgWarnings)
    : (cached.warnings || [])

  // Same priority chain the pill uses: cuaca wins, then the open-meteo
  // daily the fallback fetches alongside wttr, then wttr's own current.
  readonly property var pageCurrent: pageIsCuaca
    ? Model.bmkgCurrentCondition(cuacaData)
    : (dailyData
       ? Model.openMeteoCurrentCondition(dailyData)
       : (wttrData && wttrData.current_condition && wttrData.current_condition[0] ? wttrData.current_condition[0] : null))

  readonly property string pageTodayString: Model.todayInTimeZone(
    pageIsCuaca && cuacaData.location ? cuacaData.location.timezone : "",
    Qt.formatDate(new Date(), "yyyy-MM-dd"))
  readonly property var pageForecastDays: Model.buildForecastDays(wttrData, dailyData, cuacaData, pageTodayString)
  readonly property var pageTodaySlots: pageIsCuaca ? Model.bmkgTodaySlots(cuacaData) : []
  readonly property var pageTomorrowSlots: pageForecastDays.length > 0 ? Model.bmkgSlotsForDate(cuacaData, pageForecastDays[0].date) : []
  readonly property var pageDayAfterSlots: pageForecastDays.length > 1 ? Model.bmkgSlotsForDate(cuacaData, pageForecastDays[1].date) : []

  function pageDayName(dateString) {
    return Model.dayName(dateString, function(date) {
      // The locale-formatDate overload throws in this runtime — the
      // Indonesian names come from a plain table in Model.js instead.
      return host.conditionLang === "id"
        ? Model.indonesianDayName(date)
        : Qt.formatDate(date, "dddd")
    })
  }

  function pageFutureStripLabel(i) {
    var en = host.conditionLang === "en"
    if (pageForecastDays.length <= i) return en ? "TOMORROW" : "BESOK"
    if (en) return i === 0 ? "TOMORROW" : (i === 1 ? "DAY AFTER" : pageDayName(pageForecastDays[i].date).toUpperCase())
    return i === 0 ? "BESOK" : (i === 1 ? "LUSA" : pageDayName(pageForecastDays[i].date).toUpperCase())
  }

  function pageBareTempForDay(day, kind) {
    return Model.bareTempForDay(day, kind, host.useImperial)
  }

  function pageBareTempForSlot(slot) {
    return Model.bareTempForSlot(slot, host.useImperial)
  }

  function pageSlotIcon(slot) {
    return Model.bmkgSlotIcon(slot, host.iconScheme)
  }

  function pageTempColorOrDefault(celsius, base) {
    var c = host.tempColorHex(celsius)
    return c !== "" ? c : base
  }

  readonly property var pageFutureStripModel: [
    {
      label: pageFutureStripLabel(0),
      day: pageForecastDays.length > 0 ? pageDayName(pageForecastDays[0].date).toUpperCase() : "",
      hi: pageBareTempForDay(pageForecastDays.length > 0 ? pageForecastDays[0] : null, "max"),
      lo: pageBareTempForDay(pageForecastDays.length > 0 ? pageForecastDays[0] : null, "min"),
      hiColor: pageForecastDays.length > 0 ? host.tempColorHex(pageForecastDays[0].maxtempC) : "",
      loColor: pageForecastDays.length > 0 ? host.tempColorHex(pageForecastDays[0].mintempC) : "",
      slots: pageTomorrowSlots
    },
    {
      label: pageFutureStripLabel(1),
      day: pageForecastDays.length > 1 ? pageDayName(pageForecastDays[1].date).toUpperCase() : "",
      hi: pageBareTempForDay(pageForecastDays.length > 1 ? pageForecastDays[1] : null, "max"),
      lo: pageBareTempForDay(pageForecastDays.length > 1 ? pageForecastDays[1] : null, "min"),
      hiColor: pageForecastDays.length > 1 ? host.tempColorHex(pageForecastDays[1].maxtempC) : "",
      loColor: pageForecastDays.length > 1 ? host.tempColorHex(pageForecastDays[1].mintempC) : "",
      slots: pageDayAfterSlots
    }
  ]

  // The village the forecast actually came from (cuaca path), else the
  // configured name — the same precedence the old hero used.
  readonly property string pageLocation: entryIsVillage
    ? ((cuacaData && cuacaData.location && cuacaData.location.desa) ? String(cuacaData.location.desa) : String(entry.name || ""))
    : String(entry.name || "")
  readonly property string pageTempNum: pageCurrent ? String(host.useImperial ? pageCurrent.temp_F : pageCurrent.temp_C) : ""
  readonly property string pageCondition: (function() {
    if (!pageCurrent) return ""
    if (host.conditionLang === "en" && pageCurrent.bmkgConditionEn) return String(pageCurrent.bmkgConditionEn)
    return pageCurrent.bmkgCondition ? String(pageCurrent.bmkgCondition) : ""
  })()
  readonly property string pageWind: pageCurrent ? (host.useImperial ? (pageCurrent.windspeedMiles + " mph") : (pageCurrent.windspeedKmph + " km/h")) : ""
  readonly property string pageHumidity: pageCurrent ? (pageCurrent.humidity + "%") : ""
  readonly property string pageRain: pageCurrent && pageCurrent.rainProb !== undefined && pageCurrent.rainProb !== null ? (pageCurrent.rainProb + "%") : ""
  readonly property string pageHeroIcon: pageCurrent ? Model.currentIcon(pageCurrent, "", host.iconScheme) : ""

  Column {
    id: pageColumn
    width: page.width
    spacing: Style.space(14)

      // ---- BMKG warnings (cuaca path only, sourced from /api/warnings).
      //      Severity coloring stays theme-agnostic: sibling tones of the
      //      bar foreground rather than fixed palette colors.
      Column {
        visible: page.pageWarnings.length > 0
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: page.pageWarnings

          Rectangle {
            required property var modelData
            width: parent.width
            radius: Style.cornerRadius
            color: Style.hoverFillFor(page.bar.foreground, Commons.Color.accent)
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
                  color: page.bar.foreground
                  font.family: page.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  visible: modelData.event !== ""
                  text: modelData.event
                  anchors.verticalCenter: parent.verticalCenter
                  color: page.bar.foreground
                  font.family: page.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  visible: modelData.severity !== ""
                  text: modelData.severity.toUpperCase()
                  anchors.verticalCenter: parent.verticalCenter
                  color: Qt.darker(page.bar.foreground, 1.3)
                  font.family: page.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: modelData.area !== ""
                text: modelData.area
                color: Qt.darker(page.bar.foreground, 1.4)
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                textFormat: Text.PlainText
                visible: modelData.description !== ""
                text: modelData.description
                color: page.bar.foreground
                font.family: page.bar.fontFamily
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
              text: page.pageHeroIcon || "—"
              color: page.bar.foreground
              font.family: page.bar.fontFamily
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
                text: page.pageTempNum || "—"
                color: page.pageTempColorOrDefault(page.pageCurrent ? page.pageCurrent.temp_C : null, page.bar.foreground)
                font.family: page.bar.fontFamily
                // Hero temperature read-out; deliberately oversized, outside
                // the Style.font.* scale.
                font.pixelSize: 56
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                text: page.pageCurrent ? page.host.tempUnit : ""
                color: page.bar.foreground
                font.family: page.bar.fontFamily
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
            visible: page.pageCondition !== ""
            text: page.pageCondition
            color: Qt.darker(page.bar.foreground, 1.4)
            font.family: page.bar.fontFamily
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
            visible: !page.host.editingLocation && page.pageLocation !== ""
            width: locationLabelRow.implicitWidth
            height: locationLabelRow.implicitHeight

            // Row-wide click target. Anchored to the wrapper, a plain Item,
            // because horizontal anchoring is illegal on children of a Row
            // (the earlier in-row fill anchor silently produced a 0x0 area).
            // The label Row renders after it. Only the configured page
            // opens the editor — settled pages are always the configured
            // one, so the pencil is live wherever the pager rests.
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              enabled: page.isCurrent
              cursorShape: Qt.PointingHandCursor
              onClicked: page.host.startEditingLocation()
            }

            Row {
              id: locationLabelRow
              spacing: Style.space(6)

              Text {
                text: ""  // nf-fa-map_marker
                color: Qt.darker(page.bar.foreground, 1.4)
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                textFormat: Text.PlainText
                text: (page.pageLocation || "").toUpperCase()
                color: Qt.darker(page.bar.foreground, 1.4)
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
                anchors.verticalCenter: parent.verticalCenter
              }
              // Pencil cue: clicking the "hidden" location label opens the
              // editor; this makes that affordance discoverable.
              Text {
                textFormat: Text.PlainText
                visible: page.isCurrent
                text: ""  // nf-fa-pencil
                color: Qt.darker(page.bar.foreground, 1.6)
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }

            }
          }

          Row {
            id: locationEditRow
            visible: page.isCurrent && page.host.editingLocation
            spacing: Style.space(6)

            TextField {
              id: locationField
              width: Style.space(190)
              enabled: !page.host.savingLocation
              placeholderText: "Search location"
              foreground: page.bar.foreground
              font.family: page.bar.fontFamily

              onTextChanged: if (page.host.editingLocation && !page.host.savingLocation) page.host.restartGeocodeDebounce()

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  page.host.cancelEditingLocation()
                  event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  if (page.host.suggestionIndex < page.host.locationSuggestions.length - 1) page.host.suggestionIndex++
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  if (page.host.suggestionIndex > 0) page.host.suggestionIndex--
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  page.host.commitLocation()
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
              color: !page.host.savingLocation && clearLocationArea.containsMouse ? Style.hoverFillFor(page.bar.foreground, Commons.Color.accent) : "transparent"

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: page.host.savingLocation ? "󰦖" : "✕"
                font.family: page.bar.fontFamily
                color: Qt.darker(page.bar.foreground, 1.4)
                font.pixelSize: Style.font.bodySmall

                RotationAnimator on rotation {
                  running: page.host.savingLocation
                  from: 0; to: 360
                  duration: 800
                  loops: Animation.Infinite
                }
              }

              MouseArea {
                id: clearLocationArea
                anchors.fill: parent
                enabled: !page.host.savingLocation
                hoverEnabled: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: page.host.clearLocation()
              }
            }
          }

          Row {
            id: weatherStats
            visible: !!page.pageCurrent
            spacing: Style.space(36)

            Column {
              spacing: Style.space(5)
              Text {
                text: "WIND"
                color: Qt.darker(page.bar.foreground, 1.5)
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: page.pageWind
                color: page.bar.foreground
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            Column {
              spacing: Style.space(5)
              Text {
                text: "HUMID"
                color: Qt.darker(page.bar.foreground, 1.5)
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: page.pageHumidity
                color: page.bar.foreground
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            // BMKG rain chance; hidden on the fallback path, which has no
            // equivalent number.
            Column {
              visible: page.pageRain !== ""
              spacing: Style.space(5)
              Text {
                text: "RAIN"
                color: Qt.darker(page.bar.foreground, 1.5)
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: page.pageRain
                color: page.bar.foreground
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }
          }
        }
      }

      // ---- Slot strip: today's remaining slots (cuaca path), time /
      //      read left to right from the current 3-hour block.
      Item {
        visible: page.pageIsCuaca && page.pageTodaySlots.length > 0
        width: parent.width
        height: todayRow.height

        Row {
          id: todayRow
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(18)

          Repeater {
            model: page.pageTodaySlots

            Column {
              required property var modelData
              spacing: Style.space(3)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                // Slot time is location-local; "HH:MM" drops the seconds.
                text: String(modelData.time || "").slice(11, 16)
                color: Qt.darker(page.bar.foreground, 1.4)
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: page.pageSlotIcon(modelData)
                color: page.bar.foreground
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.display
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: page.pageBareTempForSlot(modelData)
                color: page.pageTempColorOrDefault(modelData.temp, page.bar.foreground)
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.body
              }
              readonly property var rain: Model.slotRainProb(modelData)
              Text {
                visible: rain.text !== ""
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: rain.text
                color: rain.wet
                  ? Style.selectedStateColor(page.bar.foreground, Commons.Color.accent)
                  : Qt.darker(page.bar.foreground, 1.5)
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
              readonly property var wind: Model.slotWind(modelData, page.host.useImperial)
              Row {
                visible: wind.text !== ""
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(4)

                Text {
                  visible: wind.arrow !== ""
                  textFormat: Text.PlainText
                  text: wind.arrow
                  color: page.bar.foreground
                  font.family: page.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  textFormat: Text.PlainText
                  text: wind.speed
                  color: page.host.colorMode === "color" && wind.color !== ""
                    ? wind.color
                    : (wind.strong
                       ? Style.selectedStateColor(page.bar.foreground, Commons.Color.accent)
                       : Qt.darker(page.bar.foreground, 1.5))
                  font.family: page.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }

      // ---- Geocoding suggestions while the location is being edited.
      //      Editing locks the pager to the configured page, so this
      //      renders only there.
      Column {
        visible: page.isCurrent && page.host.editingLocation && !page.host.savingLocation && page.host.locationSuggestions.length > 0
        width: parent.width
        spacing: 0

        Repeater {
          model: page.host.locationSuggestions

          Rectangle {
            required property var modelData
            required property int index
            width: parent.width
            height: suggestionRow.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: index === page.host.suggestionIndex ? Style.hoverFillFor(page.bar.foreground, Commons.Color.accent) : "transparent"

            Row {
              id: suggestionRow
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: modelData.name
                color: index === page.host.suggestionIndex ? Style.hoverStateColor(page.bar.foreground, Commons.Color.accent) : page.bar.foreground
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                textFormat: Text.PlainText
                visible: text !== ""
                text: modelData.description
                color: Qt.darker(page.bar.foreground, 1.5)
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onPositionChanged: page.host.suggestionIndex = index
              onClicked: page.host.pickSuggestion(modelData)
            }
          }
        }
      }

      Text {
        visible: !page.pageCurrent
        text: page.isCurrent ? "Fetching forecast…" : "Not loaded yet"
        color: Qt.darker(page.bar.foreground, 1.5)
        font.family: page.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.italic: true
      }

      // ---- Divider between current conditions and forecast. Also covers
      //      the edge where tomorrow's grid is empty but the day after
      //      still has slots — the LUSA strip keeps its top separator.
      Rectangle {
        visible: page.pageIsCuaca && (page.pageTomorrowSlots.length > 0 || page.pageDayAfterSlots.length > 0)
        width: parent.width
        height: Style.spacing.hairline
        color: page.bar.foreground
        opacity: 0.12
      }

      // ---- Future-day strips: tomorrow and the day after, one captioned
      //      3-hourly strip each (cuaca path). The caption carries the day
      //      label + name + hi/lo; the columns are time / icon / temp — the
      //      same rhythm as the today strip above.
      Repeater {
        model: page.pageFutureStripModel

        Item {
          required property var modelData
          required property int index

          // A hairline separates consecutive day strips — same weight as
          // the divider above the first strip; shown only when the
          // previous strip actually rendered.
          readonly property bool showDivider: index > 0 && page.pageIsCuaca && page.pageFutureStripModel[0].slots.length > 0

          visible: page.pageIsCuaca && modelData.slots.length > 0
          width: parent.width
          height: (showDivider ? Style.spacing.hairline + Style.space(14) : 0)
                  + stripHead.implicitHeight + Style.space(4) + futureRow.height

          Rectangle {
            visible: parent.showDivider
            anchors.top: parent.top
            width: parent.width
            height: Style.spacing.hairline
            color: page.bar.foreground
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
              color: page.bar.foreground
              font.family: page.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }
            Text {
              visible: modelData.day !== ""
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.day
              color: Qt.darker(page.bar.foreground, 1.4)
              font.family: page.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }
            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: modelData.hi
                color: modelData.hiColor !== "" ? modelData.hiColor : page.bar.foreground
                font.family: page.bar.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                textFormat: Text.PlainText
                text: modelData.lo
                color: modelData.loColor !== "" ? modelData.loColor : Qt.darker(page.bar.foreground, 1.5)
                font.family: page.bar.fontFamily
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
                  color: Qt.darker(page.bar.foreground, 1.4)
                  font.family: page.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: page.pageSlotIcon(modelData)
                  color: page.bar.foreground
                  font.family: page.bar.fontFamily
                  font.pixelSize: Style.font.display
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: page.pageBareTempForSlot(modelData)
                  color: page.pageTempColorOrDefault(modelData.temp, page.bar.foreground)
                  font.family: page.bar.fontFamily
                  font.pixelSize: Style.font.body
                }
                readonly property var rain: Model.slotRainProb(modelData)
                Text {
                  visible: rain.text !== ""
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: rain.text
                  color: rain.wet
                    ? Style.selectedStateColor(page.bar.foreground, Commons.Color.accent)
                    : Qt.darker(page.bar.foreground, 1.5)
                  font.family: page.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
                readonly property var wind: Model.slotWind(modelData, page.host.useImperial)
                Row {
                  visible: wind.text !== ""
                  anchors.horizontalCenter: parent.horizontalCenter
                  spacing: Style.space(4)

                  Text {
                    visible: wind.arrow !== ""
                    textFormat: Text.PlainText
                    text: wind.arrow
                    color: page.bar.foreground
                    font.family: page.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: wind.speed
                    color: page.host.colorMode === "color" && wind.color !== ""
                      ? wind.color
                      : (wind.strong
                         ? Style.selectedStateColor(page.bar.foreground, Commons.Color.accent)
                         : Qt.darker(page.bar.foreground, 1.5))
                    font.family: page.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }
      }

    }
}
