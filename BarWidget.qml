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
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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

  BarIconButton {
    id: button
    anchors.fill: parent
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
