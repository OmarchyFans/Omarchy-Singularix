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

  // updates: a dot when a newer version is published (docs/update-alerts.md).
  // The dashboard shows the details; this only runs the cached check on load
  // and every six hours so the dot appears without opening the dashboard.
  property string version: ""
  property var updateInfo: null
  readonly property bool updatePending: !!updateInfo && ((updateInfo.update_available === true && updateInfo.dismissed !== updateInfo.latest) || updateInfo.mismatch === true)
  FileView {
    path: Qt.resolvedUrl("manifest.json").toString().replace(/^file:\/\//, "")
    printErrors: false
    onLoaded: {
      try { root.version = String(JSON.parse(text()).version || "") } catch (e) { root.version = "" }
      root.checkUpdates()
    }
  }
  function checkUpdates() {
    if (root.setting("update_check", true) === false || updateProc.running) return
    updateProc.command = [root.launcher, "update-check", root.version]
    updateProc.running = true
  }
  Process {
    id: updateProc
    stdout: StdioCollector { id: updateOut; waitForEnd: true }
    onExited: function(code) { try { root.updateInfo = JSON.parse(String(updateOut.text || "")) } catch (e) { root.updateInfo = null } }
  }
  Timer { interval: 6 * 3600 * 1000; running: true; repeat: true; onTriggered: root.checkUpdates() }
  // The dashboard's Later (and the update itself) rewrite the cache; follow it so
  // the dot does not outlive the decision.
  FileView {
    path: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omarchy-agent-launcher/update-check.json"
    watchChanges: true
    printErrors: false
    onFileChanged: root.checkUpdates()
  }

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
    tooltipText: (root.blockerCount > 0 ? (root.blockerCount + " agent" + (root.blockerCount === 1 ? "" : "s") + " need you · Agent Dashboard") : "Agent Dashboard (right click: switch agent)")
      + (root.updatePending ? " · update waiting" : "")
    onPressed: function(b) {
      if (b === Qt.RightButton) Quickshell.execDetached([root.launcher, "switch"])
      else root.toggleDashboard()
    }

    Rectangle {
      visible: root.updatePending && root.blockerCount === 0
      anchors.top: parent.top; anchors.right: parent.right
      anchors.topMargin: 1; anchors.rightMargin: 0
      width: Style.space(6); height: Style.space(6); radius: height / 2
      color: Color.accent
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
