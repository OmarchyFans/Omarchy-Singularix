import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "components"

// Agent Dashboard: a persistent window (a normal toplevel, not a popup) with
// six pages: Jarvis (the chief of staff: brief, ask, backends, tokens and
// USD per task), Agents (status, switch to chat), New agent (the setup form),
// Events (sortable, filterable log), Notifications (open blockers), Projects
// (per-project waterfall phase, progress, and blockers at a glance).
//
// Host contract (kind "panel", keepLoaded): the shell injects `shell` and
// `manifest`, calls open(payloadJson) / close(), reads `opened`; we call
// shell.hide(id) when the user closes the window (same plumbing as the
// first-party dev gallery). Payload: {"tab": "jarvis|agents|new|events|notifications|projects",
// "agent": "<name>"}.
//
// Data: `omarchy-agent-launcher status --json` (on open, every 30 s while
// visible, after each action), a `tail -F` on events.jsonl, and a watch on
// blockers.json. All actions go through Quickshell.execDetached with argv,
// never a shell string.
Item {
  id: dash
  property var shell: null
  property var manifest: null
  readonly property string pluginId: "fans.omarchy.agent-launcher"
  readonly property bool opened: window.visible
  property bool closingFromHost: false

  readonly property string launcher: Qt.resolvedUrl("bin/omarchy-agent-launcher").toString().replace(/^file:\/\//, "")
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy-agent-launcher"
  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color urgent: Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: Style.font.family
  readonly property color okColor: "#9ece6a"
  readonly property color warnColor: "#e0af68"

  // ---- state shared with the tabs ---------------------------------------
  property string tab: "jarvis"
  property var status: null            // parsed `status --json`
  property var blockers: ({})          // parsed blockers.json
  property var events: []              // ingested events.jsonl lines (capped)
  property int eventsVersion: 0
  property var eventsTabRef: null      // set once EventsTab is instantiated; lets other tabs deep-link with a filter
  property int selectedIndex: 0
  property bool cursorActive: false
  property string requestedAgent: ""
  property string error: ""
  readonly property int blockerCount: Object.keys(blockers).length
  readonly property int runningCount: status ? status.agents.filter(function(a) { return a.running }).length : 0
  readonly property int agentCount: status ? status.agents.length : 0

  readonly property var currentTab: tab === "jarvis" ? jarvisTab : (tab === "new" ? setupForm : (tab === "events" ? eventsTab : (tab === "notifications" ? notifTab : (tab === "projects" ? projectsTab : agentsTab))))
  readonly property var usage: status && status.usage ? status.usage : null
  readonly property real totalCost: usage ? usage.totals.cost_usd : 0

  // Shared number formatting: tokens as 1.8M / 26.6K, money as $1.28 (sub-dollar amounts get three decimals).
  function fmtK(n) {
    n = Number(n || 0)
    if (n >= 1000000) return (Math.round(n / 100000) / 10) + "M"
    if (n >= 1000) return (Math.round(n / 100) / 10) + "K"
    return String(Math.round(n))
  }
  function fmtUsd(v) {
    if (v === null || v === undefined) return "$?"
    v = Number(v)
    if (v === 0) return "$0"
    return "$" + (v < 1 ? v.toFixed(3) : v.toFixed(2))
  }

  // ---- host contract ------------------------------------------------------
  function open(payloadJson) {
    closingFromHost = false
    var wanted = "", agent = ""
    if (payloadJson) {
      try { var p = JSON.parse(String(payloadJson)); if (p && typeof p.tab === "string") wanted = p.tab; if (p && typeof p.agent === "string") agent = p.agent } catch (e) {}
    }
    if (["jarvis", "agents", "new", "events", "notifications", "projects"].indexOf(wanted) >= 0) tab = wanted
    if (agent !== "") requestedAgent = agent
    window.visible = true
    refreshStatus()
    focusTimer.restart()
  }
  function close() { closingFromHost = true; window.visible = false; closingFromHost = false }
  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else window.visible = false
  }
  function focusCatcher() { Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }
  function selectTab(name) { tab = name; selectedIndex = 0; cursorActive = false; focusCatcher() }

  // ---- backend --------------------------------------------------------------
  function refreshStatus() {
    if (statusProc.running) return
    statusProc.command = [launcher, "status", "--json"]
    statusProc.running = true
  }
  function act(argv) { Quickshell.execDetached(argv); refreshTimer.restart() }
  function refreshSoon() { refreshTimer.restart() }
  function chat(name) { if (name) act([launcher, "chat", name]) }
  function emitEvent(agent, kind, message, key) {
    var argv = [launcher, "event", agent, kind, message]
    if (key) argv.push("--key", key)
    act(argv)
  }
  function agentByName(name) {
    if (!status) return null
    for (var i = 0; i < status.agents.length; i++) if (status.agents[i].name === name) return status.agents[i]
    return null
  }

  Process {
    id: statusProc
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) { dash.error = "status failed: " + String(statusErr.text || "").trim(); return }
      try { dash.status = JSON.parse(String(statusOut.text || "")); dash.error = "" }
      catch (e) { dash.error = "could not parse status: " + e }
      if (dash.requestedAgent !== "" && dash.tab === "agents") { agentsTab.select(dash.requestedAgent); dash.requestedAgent = "" }
    }
  }
  Timer { id: statusTimer; interval: 30000; repeat: true; running: window.visible; onTriggered: dash.refreshStatus() }
  Timer { id: refreshTimer; interval: 1200; onTriggered: dash.refreshStatus() }
  Timer {
    id: focusTimer; interval: 150
    // Focus through the launcher: Hyprland's dispatch is Lua on current Omarchy,
    // and `focus-window` switches to the dashboard's workspace if it is elsewhere.
    onTriggered: { Quickshell.execDetached([dash.launcher, "focus-window", "Agent Dashboard"]); dash.focusCatcher() }
  }

  // Live event tail. Started once (keepLoaded keeps this item alive), restarted if tail exits.
  property var pending: []
  property var seenRefs: ({})
  property int counter: 0
  function ingest(line) {
    var s = String(line || "").trim()
    if (s === "") return
    var ev
    try { ev = JSON.parse(s) } catch (e) { return }
    if (!ev || typeof ev !== "object") return
    if (ev.ref && ev.ref !== "") { if (seenRefs[ev.ref]) return; seenRefs[ev.ref] = true }
    ev.n = ++counter
    pending.push(ev)
    flushTimer.restart()
  }
  Timer {
    id: flushTimer; interval: 30
    onTriggered: {
      if (dash.pending.length === 0) return
      var next = dash.events.concat(dash.pending)
      dash.pending = []
      if (next.length > 6000) next = next.slice(next.length - 5000)
      dash.events = next
      dash.eventsVersion++
    }
  }
  Process {
    id: tailProc
    command: ["tail", "-n", "+1", "-F", dash.stateDir + "/events.jsonl"]
    stdout: SplitParser { onRead: function(data) { dash.ingest(data) } }
    onExited: tailRestart.restart()
  }
  Timer { id: tailRestart; interval: 1000; onTriggered: tailProc.running = true }
  Component.onCompleted: tailProc.running = true

  FileView {
    id: blockersFile
    path: dash.stateDir + "/blockers.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { dash.blockers = JSON.parse(text() || "{}") } catch (e) { dash.blockers = ({}) } }
    onLoadFailed: dash.blockers = ({})
  }

  // ---- window -----------------------------------------------------------------
  FloatingWindow {
    id: window
    visible: false                       // keepLoaded mounts us at shell start
    title: "Agent Dashboard"
    color: dash.background
    implicitWidth: 1180
    implicitHeight: 760
    minimumSize: Qt.size(900, 600)

    onVisibleChanged: {
      if (!visible && !dash.closingFromHost && dash.shell && typeof dash.shell.hide === "function") dash.shell.hide(dash.pluginId)
    }

    FocusScope {
      anchors.fill: parent
      focus: true

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        blocked: (dash.currentTab && (dash.currentTab.editing || dash.currentTab.popupOpen)) === true
        onCloseRequested: dash.requestClose()
        onMoveRequested: function(dx, dy) {
          if (!dash.cursorActive) { dash.cursorActive = true; return }
          var n = dash.currentTab && dash.currentTab.rowCount !== undefined ? dash.currentTab.rowCount : 0
          if (n <= 0) return
          dash.selectedIndex = Math.max(0, Math.min(n - 1, dash.selectedIndex + dy))
        }
        onActivateRequested: if (dash.cursorActive && dash.currentTab && typeof dash.currentTab.activate === "function") dash.currentTab.activate(dash.selectedIndex)
        onReturnRequested: if (dash.cursorActive && dash.currentTab && typeof dash.currentTab.activate === "function") dash.currentTab.activate(dash.selectedIndex)
        onTabRequested: function(direction) {
          var order = ["jarvis", "agents", "new", "events", "notifications", "projects"]
          var i = (order.indexOf(dash.tab) + (direction < 0 ? -1 : 1) + order.length) % order.length
          dash.selectTab(order[i])
        }
        onTextKey: function(t) {
          if (t === "1") dash.selectTab("jarvis")
          else if (t === "2") dash.selectTab("agents")
          else if (t === "3") dash.selectTab("new")
          else if (t === "4") dash.selectTab("events")
          else if (t === "5") dash.selectTab("notifications")
          else if (t === "6") dash.selectTab("projects")
          else if (t === "r" || t === "R") dash.refreshStatus()
          else if (t === "n" || t === "N") dash.selectTab("new")
        }

        Row {
          anchors.fill: parent

          // ---- sidebar ---------------------------------------------------
          Rectangle {
            id: sidebar
            width: Style.space(200)
            height: parent.height
            color: Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.04)

            Column {
              anchors.fill: parent
              anchors.margins: Style.space(14)
              spacing: Style.space(6)

              Row {
                spacing: Style.spacing.rowGap
                Text { text: "󱚝"; color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.display }
                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  Text { text: "Agents"; color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.title; font.bold: true }
                  Text { text: "omarchy.fans"; color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption }
                }
              }
              Item { width: 1; height: Style.space(8) }

              component NavButton: Button {
                property string tabId: ""
                property int badge: 0
                property color badgeColor: dash.accent
                width: sidebar.width - Style.space(28)
                leftAlign: true
                selected: dash.tab === tabId
                foreground: dash.foreground; fontFamily: dash.fontFamily
                onClicked: dash.selectTab(tabId)
                Rectangle {
                  visible: parent.badge > 0
                  anchors.right: parent.right; anchors.rightMargin: Style.spacing.controlPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(Style.space(18), badgeText.implicitWidth + Style.space(8)); height: Style.space(18); radius: height / 2
                  color: parent.badgeColor
                  Text { id: badgeText; anchors.centerIn: parent; text: parent.parent.badge; color: dash.background; font.family: dash.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                }
              }
              NavButton { tabId: "jarvis"; iconText: "󰚩"; text: "Jarvis" }
              NavButton { tabId: "agents"; iconText: "󰙨"; text: "Agents"; badge: dash.runningCount; badgeColor: dash.okColor }
              NavButton { tabId: "new"; iconText: ""; text: "New agent" }
              NavButton { tabId: "events"; iconText: "󰈙"; text: "Events" }
              NavButton { tabId: "notifications"; iconText: "󰂚"; text: "Notifications"; badge: dash.blockerCount; badgeColor: dash.urgent }
              NavButton { tabId: "projects"; iconText: "󰙅"; text: "Projects" }

              Item { width: 1; height: Style.space(16) }
              Text {
                width: parent.width; wrapMode: Text.Wrap
                text: (dash.agentCount + " agent" + (dash.agentCount === 1 ? "" : "s") + "  ·  " + dash.runningCount + " running") + (dash.blockerCount ? "\n" + dash.blockerCount + " need" + (dash.blockerCount === 1 ? "s" : "") + " you" : "")
                      + (dash.usage ? "\n" + dash.fmtK(dash.usage.totals.prompt + dash.usage.totals.output) + " tokens  ·  " + dash.fmtUsd(dash.totalCost) : "")
                color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
              }
              Text {
                visible: dash.error !== ""
                width: parent.width; wrapMode: Text.Wrap
                text: dash.error; color: dash.urgent; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
              }
              Item { width: 1; height: Style.space(16) }
              Text {
                width: parent.width; wrapMode: Text.Wrap
                text: "1-6 pages · j/k move · Enter chat · r refresh · Esc close"
                color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- pages -----------------------------------------------------
          Item {
            id: content
            width: parent.width - sidebar.width
            height: parent.height

            JarvisTab { id: jarvisTab; anchors.fill: parent; anchors.margins: Style.space(18); visible: dash.tab === "jarvis"; dash: dash }
            AgentsTab { id: agentsTab; anchors.fill: parent; anchors.margins: Style.space(18); visible: dash.tab === "agents"; dash: dash }
            SetupForm {
              id: setupForm; anchors.fill: parent; anchors.margins: Style.space(18); visible: dash.tab === "new"; dash: dash
              onCreated: function(name) { dash.requestedAgent = name; dash.selectTab("agents"); dash.refreshStatus() }
            }
            EventsTab { id: eventsTab; anchors.fill: parent; anchors.margins: Style.space(18); visible: dash.tab === "events"; dash: dash; Component.onCompleted: dash.eventsTabRef = eventsTab }
            NotificationsTab { id: notifTab; anchors.fill: parent; anchors.margins: Style.space(18); visible: dash.tab === "notifications"; dash: dash }
            ProjectsTab { id: projectsTab; anchors.fill: parent; anchors.margins: Style.space(18); visible: dash.tab === "projects"; dash: dash }
          }
        }
      }
    }
  }
}
