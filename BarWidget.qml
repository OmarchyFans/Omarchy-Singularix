import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button for the Agent Dashboard. Left click toggles the dashboard window
// (the shell routes this plugin id to the panel loader because it also
// declares kind "panel"); right click opens the quick switcher. A small badge
// shows how many blockers need the user, read from blockers.json.
BarWidget {
  id: root
  moduleName: "fans.omarchy.agent-launcher"

  readonly property string pluginId: "fans.omarchy.agent-launcher"
  readonly property string launcher: Qt.resolvedUrl("bin/omarchy-agent-launcher").toString().replace(/^file:\/\//, "")
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy-agent-launcher"
  property int blockerCount: 0

  // The shell keeps the panel's open state; this widget only asks it to toggle.
  readonly property bool opened: false
  function open() { toggleDashboard() }
  function close() {}

  function toggleDashboard() {
    if (root.bar && root.bar.shell && typeof root.bar.shell.toggle === "function") root.bar.shell.toggle(pluginId, "{}")
    else if (root.bar && typeof root.bar.run === "function") root.bar.run("omarchy-shell shell toggle " + pluginId + " '{}'")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    path: root.stateDir + "/blockers.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { root.blockerCount = Object.keys(JSON.parse(text() || "{}")).length } catch (e) { root.blockerCount = 0 } }
    onLoadFailed: root.blockerCount = 0
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱚝"                    // nf-md-robot_happy
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.blockerCount > 0 ? (root.blockerCount + " agent" + (root.blockerCount === 1 ? "" : "s") + " need you · Agent Dashboard") : "Agent Dashboard (right click: switch agent)"
    onPressed: function(b) {
      if (b === Qt.RightButton) Quickshell.execDetached([root.launcher, "switch"])
      else root.toggleDashboard()
    }

    Rectangle {
      visible: root.blockerCount > 0
      anchors.top: parent.top; anchors.right: parent.right
      anchors.topMargin: 1; anchors.rightMargin: 0
      width: Style.space(9); height: Style.space(9); radius: height / 2
      color: root.bar ? root.bar.urgent : Color.urgent
      Text {
        anchors.centerIn: parent
        text: root.blockerCount > 9 ? "9" : root.blockerCount
        color: Color.background
        font.family: Style.font.family; font.pixelSize: Style.space(7); font.bold: true
      }
    }
  }
}
