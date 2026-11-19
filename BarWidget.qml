import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "cuaca.weather"

  // Scoped host facade (set by the shell when this property exists) and the
  // plugin manifest, both forwarded to the panel for the settings UI.
  property var shell: null
  property var manifest: null

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("shell" in target) target.shell = root.shell
    if ("manifest" in target) target.manifest = root.manifest
    if ("widgetId" in target) target.widgetId = root.moduleName
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  // Toast the panel's live conditions; falls back to the generic message
  // the panel renders when nothing has loaded yet.
  function notifyStatus() {
    if (panelLoader.item && panelLoader.item.notifyStatus) panelLoader.item.notifyStatus()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root). Open maps to the
  // panel's hotkey path so summoning suppresses the center hover reveal,
  // matching what the old per-plugin IpcHandler did.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  visible: panelLoader.item && panelLoader.item.label !== ""
  // The pill is the icon slot plus, once data lands and pillTemp is on, a
  // compact temperature: beside the icon in horizontal bars, stacked under
  // it in vertical ones.
  readonly property bool tempShown: panelLoader.item ? panelLoader.item.pillTempText !== "" : false
  implicitWidth: root.vertical
    ? Math.max(button.implicitWidth, tempArea.visible ? tempArea.implicitWidth : 0)
    : button.implicitWidth + (tempArea.visible ? Style.space(6) + tempArea.implicitWidth : 0)
  implicitHeight: root.vertical
    ? button.implicitHeight + (tempArea.visible ? Style.space(3) + tempArea.implicitHeight : 0)
    : Math.max(button.implicitHeight, tempArea.visible ? tempArea.implicitHeight : 0)

  // Active BMKG warnings surface as a small theme-urgent dot on the pill;
  // the banner rows with the details live in the panel.
  readonly property bool warningsActive: panelLoader.item
    ? (panelLoader.item.bmkgWarnings && panelLoader.item.bmkgWarnings.length > 0) : false

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Wheel over the pill pages through locations without opening the
  // popup (the Wetter-extension gesture). The icon's wheel rides the
  // NoButton overlay below; the temperature area has its own onWheel.
  // Slider-style: any nonzero horizontal delta pages once — no
  // 120-detent accumulator, which a touchpad's small per-frame
  // angleDelta never reaches (the shell's volume slider, stepping on
  // any nonzero delta, is the working precedent on this input).
  // cycleLocation's 250ms throttle is the rate limiter.
  // Horizontal only: left/right pages (scroll left = next, matching
  // the swipe); up/down never does. The dominance test keeps noisy
  // diagonals from paging, and pixelDelta covers pure-pixel devices.
  function pageByWheelEvent(wheel) {
    var dx = wheel.angleDelta.x !== 0 ? wheel.angleDelta.x : wheel.pixelDelta.x
    var dy = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.pixelDelta.y
    if (dx === 0 || Math.abs(dx) < Math.abs(dy)) return
    pageByWheel(dx)
  }

  function pageByWheel(delta) {
    if (!delta) return
    if (panelLoader.item && panelLoader.item.cycleLocation) panelLoader.item.cycleLocation(delta < 0 ? 1 : -1)
  }

  BarIconButton {
    id: button
    // Anchored, not filled: with the temperature beside or under it the
    // root is larger than the slot, and a fill would stretch the fixed
    // glyph slot. x defaults to 0; horizontal mode is left-aligned at the
    // root's edge.
    anchors.horizontalCenter: root.vertical ? parent.horizontalCenter : undefined
    bar: root.bar
    text: panelLoader.item ? panelLoader.item.label : ""
    slotSize: Style.bar.statusSlot
    // Tooltip suppressed because the panel is the detail view.
    tooltipText: ""

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.notifyStatus()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }

  // Wheel-only overlay on the icon: the shell's WidgetButton re-emits
  // wheel as wheelMoved(angleDelta.y) — vertical-only, and paging is
  // horizontal-only now — so this overlay is the icon's wheel path.
  // With acceptedButtons: NoButton it takes wheel events with both
  // axes intact while presses and hover fall through to the button
  // beneath (clicks, middle-click refresh, tooltip).
  MouseArea {
    anchors.fill: button
    acceptedButtons: Qt.NoButton
    onWheel: function(wheel) { root.pageByWheelEvent(wheel) }
  }

  // Pill temperature: a plain wrapper item sized from the text, with the
  // MouseArea inside it. (The popup's location row taught the lesson: a
  // positioner child rejects horizontal anchoring, but a plain Item takes
  // it fine.) The area forwards the icon button's routing so the whole
  // pill feels clickable.
  Item {
    id: tempArea
    visible: root.tempShown
    implicitWidth: tempText.implicitWidth
    implicitHeight: tempText.implicitHeight
    width: implicitWidth
    height: implicitHeight

    anchors.left: root.vertical ? undefined : button.right
    anchors.leftMargin: Style.space(6)
    anchors.verticalCenter: root.vertical ? undefined : button.verticalCenter
    anchors.top: root.vertical ? button.bottom : undefined
    anchors.topMargin: Style.space(3)
    anchors.horizontalCenter: root.vertical ? button.horizontalCenter : undefined

    Text {
      id: tempText
      anchors.fill: parent
      textFormat: Text.PlainText
      text: panelLoader.item ? panelLoader.item.pillTempText : ""
      color: root.bar ? root.bar.foreground : "transparent"
      font.family: root.bar ? root.bar.fontFamily : ""
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onWheel: function(wheel) { root.pageByWheelEvent(wheel) }
      onPressed: function(b) {
        if (!root.bar) return
        if (b === Qt.RightButton) root.notifyStatus()
        else if (b === Qt.MiddleButton) root.refresh()
        else root.togglePanel()
      }
    }
  }

  Rectangle {
    visible: root.warningsActive
    anchors.top: button.top
    anchors.right: button.right
    anchors.topMargin: Style.space(5)
    anchors.rightMargin: Style.space(5)
    width: 5
    height: 5
    radius: 2.5
    // Urgency tone from the bar facade (Bar.qml mirrors its own color each
    // frame) rather than the Commons singleton — one less module alias that
    // can race a hot reload.
    color: !root.bar ? "transparent"
      : (root.bar.urgent.a > 0 ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.3))
    border.color: root.bar ? root.bar.background : "transparent"
    border.width: 1
  }
}
