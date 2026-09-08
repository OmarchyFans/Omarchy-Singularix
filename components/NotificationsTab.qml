import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Notifications page: open blockers first (each with Chat and Resolve), then
// recent warnings, plus the desktop-notification toggle.
Item {
  id: tab
  required property var dash

  readonly property var blockerList: Object.keys(dash.blockers).map(function(k) { return dash.blockers[k] }).sort(function(a, b) { return b.t - a.t })
  readonly property var warnings: dash.events.filter(function(e) { return e.level === "warn" }).slice(-50).reverse()
  readonly property int rowCount: blockerList.length
  readonly property bool editing: false
  readonly property bool popupOpen: false
  property bool notify: true

  function activate(i) { if (blockerList[i]) dash.chat(blockerList[i].agent) }
  function resolve(b) { dash.emitEvent(b.agent, "blocker_cleared", "Resolved from the dashboard", b.key) }
  function loadSetting() { if (!settingProc.running) { settingProc.command = [dash.launcher, "settings", "get", "notify_blockers"]; settingProc.running = true } }
  Process {
    id: settingProc
    stdout: StdioCollector { id: settingOut; waitForEnd: true }
    onExited: { var v = String(settingOut.text || "").trim(); tab.notify = (v !== "false") }
  }
  Connections { target: dash; function onOpenedChanged() { if (dash.opened) tab.loadSetting() } }

  Column {
    anchors.fill: parent
    spacing: Style.space(10)

    PanelHero {
      width: parent.width
      title: "Notifications"
      meta: tab.rowCount === 0 ? "Nothing needs you right now" : (tab.rowCount + " blocker" + (tab.rowCount === 1 ? "" : "s") + " waiting")
      foreground: dash.foreground; fontFamily: dash.fontFamily
      iconComponent: Component { Text { text: "󰂚"; color: tab.rowCount ? dash.urgent : dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.display } }
    }
    PanelSeparator { width: parent.width; foreground: dash.foreground }

    Flickable {
      width: parent.width
      height: parent.height - y
      contentWidth: width
      contentHeight: inner.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: inner
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader { text: "NEEDS YOU"; foreground: dash.foreground; fontFamily: dash.fontFamily }
        Text { visible: tab.blockerList.length === 0; text: "No open blockers."; color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.body }
        Repeater {
          model: tab.blockerList
          delegate: CursorSurface {
            required property var modelData
            required property int index
            width: inner.width
            hasCursor: dash.cursorActive && dash.tab === "notifications" && dash.selectedIndex === index
            foreground: dash.foreground
            implicitHeight: brow.implicitHeight + Style.space(16)
            MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.ArrowCursor; onContainsMouseChanged: if (containsMouse) { dash.cursorActive = true; dash.selectedIndex = index } }
            Row {
              id: brow
              anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12); anchors.rightMargin: Style.space(8)
              spacing: Style.space(12)
              Text { text: "󰀦"; color: dash.urgent; font.family: dash.fontFamily; font.pixelSize: Style.font.iconLarge; anchors.verticalCenter: parent.verticalCenter }
              Column {
                width: parent.width - bactions.width - parent.spacing * 2 - Style.space(24)
                spacing: Style.spacing.xxs
                Text { width: parent.width; elide: Text.ElideRight; text: modelData.agent + (modelData.task ? "  ·  " + modelData.task : ""); color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.subtitle; font.bold: true }
                Text { width: parent.width; wrapMode: Text.Wrap; text: modelData.message; color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.body }
                Text { text: modelData.ts + "  ·  " + modelData.kind; color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption }
              }
              Row {
                id: bactions
                spacing: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                Button { text: "Chat"; iconText: "󰭹"; selected: true; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: dash.chat(modelData.agent) }
                Button { text: "Resolve"; iconText: "󰄬"; tooltipText: "Clear this blocker"; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: tab.resolve(modelData) }
              }
            }
          }
        }

        Item { width: 1; height: Style.space(6) }
        Toggle {
          width: inner.width
          label: "Desktop notifications for blockers"
          description: "Send an Omarchy notification whenever an agent needs you; clicking it opens this page."
          checked: tab.notify
          foreground: dash.foreground; fontFamily: dash.fontFamily
          onClicked: { tab.notify = !tab.notify; dash.act([dash.launcher, "settings", "set", "notify_blockers", tab.notify ? "true" : "false"]) }
        }

        Item { width: 1; height: Style.space(6) }
        PanelSectionHeader { text: "RECENT WARNINGS"; foreground: dash.foreground; fontFamily: dash.fontFamily }
        Text { visible: tab.warnings.length === 0; text: "No warnings."; color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.body }
        Repeater {
          model: tab.warnings
          delegate: Text {
            required property var modelData
            width: inner.width; elide: Text.ElideRight
            text: modelData.ts.replace("T", " ").slice(0, 19) + "  ·  " + modelData.agent + (modelData.task ? " · " + modelData.task : "") + "  ·  " + modelData.message
            color: dash.warnColor; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall
          }
        }
        Item { width: 1; height: Style.space(8) }
      }
    }
  }
}
