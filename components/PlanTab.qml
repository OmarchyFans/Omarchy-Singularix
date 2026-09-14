import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Plan page: the harness Gantt. Data comes from the session-harness's own
// overview.json (FileView, watched) plus a `tail -F` on events.jsonl for
// animation deltas (assign/done/release/throttled flash the matching row —
// the FileView, not the tail, is what rebuilds the model). No network from
// QML: the harness process (`harness serve --all`) and the launcher's own
// `harness dispatch` loop write those files; the CLI subcommands invoked
// here (`harness approve|decline|assign|serve`) talk to the harness itself.
//
// Path resolution: `status --json`.harness.{overview_path,events_path,
// data_dir,url,alive} when the launcher has started injecting it (see
// docs/HARNESS.md); otherwise ~/.session-harness/{overview,events.jsonl}.
Item {
  id: tab
  required property var dash

  // ---- harness plumbing (from status --json, with a same-default fallback) --
  readonly property var harness: dash.status && dash.status.harness ? dash.status.harness : null
  readonly property bool harnessAlive: !!(harness && harness.alive)
  readonly property string harnessUrl: (harness && harness.url) || "http://127.0.0.1:7744"
  readonly property string dataDir: (harness && harness.data_dir) || (Quickshell.env("HOME") + "/.session-harness")
  readonly property string overviewPath: (harness && harness.overview_path) || (tab.dataDir + "/overview.json")
  readonly property string eventsPath: (harness && harness.events_path) || (tab.dataDir + "/events.jsonl")

  property var overview: null
  property bool overviewLoaded: false

  readonly property var projects: overview && overview.projects ? overview.projects : []
  readonly property var sessions: overview && overview.sessions ? overview.sessions : []
  readonly property var queueAll: overview && overview.queue ? overview.queue : []
  readonly property var pendingApprovalProjects: projects.filter(function(p) { return !!p.pending_approval })

  // ---- Dashboard contract -------------------------------------------------
  readonly property var flatRows: computeFlatRows()
  readonly property int rowCount: flatRows.length
  readonly property bool editing: false
  readonly property bool popupOpen: projectDrop.popupOpen || agentDrop.popupOpen
  function activate(i) { var n = flatRows[i]; if (n) selectRow(n) }

  // ---- filters --------------------------------------------------------------
  property string projectFilter: ""
  property string agentFilter: ""
  property var activeStates: ({ ready: true, running: true, blocked: true, done: true, failed: true })
  function toggleState(s) { var m = {}; for (var k in activeStates) m[k] = activeStates[k]; m[s] = !m[s]; activeStates = m }
  function stateOk(s) { return activeStates[s] !== undefined ? !!activeStates[s] : true }

  function stateColor(s) {
    if (s === "blocked") return "#6b7280"
    if (s === "ready") return "#d9a400"
    if (s === "running") return "#3b82f6"
    if (s === "done") return "#22a06b"
    if (s === "failed") return "#e5484d"
    if (s === "cancelled") return "#8b8b8b"
    return dash.dim
  }

  function projectOptionsFn() {
    var out = [{ value: "", label: "All projects" }]
    for (var i = 0; i < projects.length; i++) out.push({ value: projects[i].id, label: projects[i].title || projects[i].id })
    return out
  }
  readonly property var projectOptionsList: projectOptionsFn()

  function agentOptionsFn() {
    var seen = {}, out = [{ value: "", label: "All agents" }]
    for (var i = 0; i < sessions.length; i++) {
      var s = sessions[i]
      var label = s.label || s.worker || s.id
      var val = String(s.id || label)
      if (val !== "" && !seen[val]) { seen[val] = true; out.push({ value: val, label: String(label) }) }
    }
    return out
  }
  readonly property var agentOptionsList: agentOptionsFn()

  function projectMaxEf(pid) {
    var m = 1
    for (var i = 0; i < queueAll.length; i++) if (queueAll[i].project === pid) { var v = Number(queueAll[i].ef || 0); if (v > m) m = v }
    return m
  }
  function groupedProjects() {
    var out = []
    var list = projectFilter === "" ? projects : projects.filter(function(p) { return p.id === projectFilter })
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      var rows = queueAll.filter(function(q) {
        if (q.project !== p.id) return false
        if (agentFilter !== "" && q.assignee !== agentFilter) return false
        if (!stateOk(q.state)) return false
        return true
      })
      rows.sort(function(a, b) { if (!!a.critical !== !!b.critical) return a.critical ? -1 : 1; return (a.es || 0) - (b.es || 0) })
      out.push({ project: p, rows: rows, maxEf: tab.projectMaxEf(p.id) })
    }
    return out
  }
  readonly property var groups: groupedProjects()
  function computeFlatRows() { var out = []; for (var i = 0; i < groups.length; i++) out = out.concat(groups[i].rows); return out }

  function aggregate() {
    var list = projectFilter === "" ? projects : projects.filter(function(p) { return p.id === projectFilter })
    var residual = 0, blocked = 0, spent = 0, approved = 0, remaining = 0
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      residual += Number(p.residual || 0)
      blocked += Number(p.residual_blocked || 0)
      if (p.cost) { spent += Number(p.cost.spent_usd || 0); approved += Number(p.cost.approved_usd || 0); remaining += Number(p.cost.remaining_usd || 0) }
    }
    return { residual: residual, blocked: blocked, spent: spent, approved: approved, remaining: remaining }
  }
  readonly property var agg: aggregate()

  function workerGlyph(w) {
    var s = String(w || "").toLowerCase()
    if (s.indexOf("claude") >= 0 || s === "cc") return "[CC]"
    if (s.indexOf("codex") >= 0 || s === "cx") return "[CX]"
    if (s.indexOf("gemini") >= 0 || s === "gk") return "[GK]"
    if (s.indexOf("rix") >= 0 || s === "rx") return "[RX]"
    if (s.indexOf("qwen") >= 0 || s === "qw") return "[QW]"
    if (s.indexOf("human") >= 0 || s === "hu") return "[HU]"
    return s === "" ? "[?]" : "[" + s.slice(0, 2).toUpperCase() + "]"
  }
  function costClassTag(c) {
    if (c === "free") return "free"
    if (c === "subscription") return "sub"
    if (c === "metered") return "$"
    return String(c || "—")
  }

  // ---- row selection + event-driven flash -----------------------------------
  property var selectedRow: null
  function selectRow(node) { selectedRow = node }
  signal rowFlash(string key)
  function ingestEvent(line) {
    var s = String(line || "").trim()
    if (s === "") return
    var ev
    try { ev = JSON.parse(s) } catch (e) { return }
    if (!ev || typeof ev !== "object" || !ev.node) return
    var kind = String(ev.event || "")
    if (kind !== "assign" && kind !== "done" && kind !== "release" && kind !== "session.throttled") return
    tab.rowFlash(String(ev.project || "") + "::" + String(ev.node))
  }

  function emptyMessage() {
    if (!overviewLoaded && !harnessAlive) return "Harness not installed, or no data yet at " + tab.overviewPath + ".\nRun `harness serve --all`, or click “Start harness” below."
    if (overviewLoaded && projects.length === 0) return "No projects yet. Create one with `harness project create <name>`."
    return ""
  }
  readonly property string empty: emptyMessage()

  FileView {
    id: overviewFile
    path: tab.overviewPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { tab.overview = JSON.parse(text() || "{}"); tab.overviewLoaded = true }
      catch (e) { tab.overview = null; tab.overviewLoaded = false }
    }
    onLoadFailed: { tab.overview = null; tab.overviewLoaded = false }
  }

  Process {
    id: eventsTail
    command: ["tail", "-n", "0", "-F", tab.eventsPath]
    stdout: SplitParser { onRead: function(data) { tab.ingestEvent(data) } }
    onExited: eventsTailRestart.restart()
  }
  Timer { id: eventsTailRestart; interval: 1000; onTriggered: eventsTail.running = true }
  Component.onCompleted: eventsTail.running = true

  // ---- approval banner (one per project with a pending request) -------------
  component ApprovalBanner: BorderSurface {
    id: banner
    property var project: null
    width: parent ? parent.width : implicitWidth
    radius: Style.cornerRadius
    color: Qt.rgba(dash.urgent.r, dash.urgent.g, dash.urgent.b, 0.10)
    borderSpec: Border.flat(dash.urgent, 2)
    implicitHeight: bannerRow.implicitHeight + Style.space(16)
    Row {
      id: bannerRow
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(12)
      spacing: Style.spacing.controlGap
      Text {
        width: parent.width - approveBtn.width - declineBtn.width - parent.spacing * 2
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: {
          if (!banner.project || !banner.project.pending_approval) return ""
          var pa = banner.project.pending_approval
          return (banner.project.title || banner.project.id) + ": " + pa.model + " via " + pa.vendor
               + " — est. " + dash.fmtUsd(pa.estimate_usd) + " — " + pa.reason
        }
        color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall
      }
      Button {
        id: approveBtn; text: "Approve"; bordered: true; selected: true
        foreground: dash.foreground; fontFamily: dash.fontFamily
        onClicked: dash.act([dash.launcher, "harness", "approve", banner.project.id, String(banner.project.pending_approval.estimate_usd || 0)])
      }
      Button {
        id: declineBtn; text: "Decline"; bordered: true
        foreground: dash.urgent; fontFamily: dash.fontFamily
        onClicked: dash.act([dash.launcher, "harness", "decline", banner.project.id])
      }
    }
  }

  // ---- one Gantt row (a queue node) ------------------------------------------
  component QueueRow: CursorSurface {
    id: qrow
    property var node: null
    property real maxEf: 1
    hasCursor: dash.cursorActive && dash.tab === "plan" && dash.selectedIndex === tab.flatRows.indexOf(qrow.node)
    foreground: dash.foreground
    implicitHeight: Style.space(30)

    readonly property real trackLeft: Style.space(150)
    readonly property real trackWidth: Math.max(Style.space(60), qrow.width - trackLeft - Style.space(90))
    readonly property real scale: trackWidth / Math.max(1, maxEf)
    readonly property color rowStateColor: node ? tab.stateColor(node.state) : dash.dim
    readonly property string rowKey: node ? (String(node.project || "") + "::" + String(node.node || "")) : ""

    property real flashOpacity: 0
    SequentialAnimation {
      id: flashAnim
      NumberAnimation { target: qrow; property: "flashOpacity"; to: 0.55; duration: 60 }
      NumberAnimation { target: qrow; property: "flashOpacity"; to: 0; duration: 540 }
    }
    Connections {
      target: tab
      function onRowFlash(key) { if (key === qrow.rowKey) flashAnim.restart() }
    }

    MouseArea {
      anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) { dash.cursorActive = true; dash.selectedIndex = tab.flatRows.indexOf(qrow.node) }
      onClicked: tab.selectRow(qrow.node)
    }

    Rectangle {
      anchors.fill: parent
      color: dash.urgent
      opacity: qrow.flashOpacity
      visible: opacity > 0.01
    }

    Row {
      anchors.fill: parent; spacing: 0
      Text {
        width: qrow.trackLeft; height: parent.height
        leftPadding: Style.spacing.md; rightPadding: Style.spacing.sm
        verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
        text: qrow.node ? (qrow.node.title || qrow.node.node || "") : ""
        color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall
      }
      Item {
        width: qrow.trackWidth; height: parent.height
        Rectangle {
          id: bar
          y: (parent.height - height) / 2
          height: Style.space(18)
          x: Math.max(0, (qrow.node ? Number(qrow.node.es || 0) : 0) * qrow.scale)
          width: Math.max(Style.space(14), ((qrow.node ? Number(qrow.node.ef || 0) : 0) - (qrow.node ? Number(qrow.node.es || 0) : 0)) * qrow.scale)
          radius: Style.cornerRadius
          color: qrow.rowStateColor
          border.width: qrow.node && qrow.node.critical ? 2 : 0
          border.color: dash.accent

          Behavior on x { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
          Behavior on width { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
          Behavior on color { ColorAnimation { duration: 250 } }

          Text {
            anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.xs; anchors.rightMargin: Style.spacing.xs
            textFormat: Text.PlainText; elide: Text.ElideRight
            text: qrow.node ? (qrow.node.assignee || "") : ""
            color: "#f5f5f5"; font.family: dash.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
          }
          Text {
            visible: !!(qrow.node && qrow.node.evidence_missing)
            anchors.right: parent.right; anchors.rightMargin: -Style.space(2); anchors.top: parent.top; anchors.topMargin: -Style.space(6)
            text: "⚠"; color: dash.warnColor; font.pixelSize: Style.font.caption; font.bold: true
          }
          Rectangle {
            id: pulseCap
            visible: !!(qrow.node && qrow.node.state === "running")
            width: Style.space(4); height: parent.height
            anchors.right: parent.right
            radius: width / 2
            color: "#ffffff"; opacity: 0.4
            SequentialAnimation on opacity {
              running: pulseCap.visible
              loops: Animation.Infinite
              NumberAnimation { to: 0.9; duration: 500 }
              NumberAnimation { to: 0.25; duration: 500 }
            }
          }
        }
      }
      Text {
        width: Style.space(90); height: parent.height
        leftPadding: Style.spacing.md
        verticalAlignment: Text.AlignVCenter
        text: qrow.node ? String(qrow.node.state || "") : ""
        color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
      }
    }
  }

  // ---- one project's header + its rows ---------------------------------------
  component ProjectGroup: Column {
    id: grp
    property var group: null
    width: parent ? parent.width : implicitWidth
    spacing: Style.space(4)

    readonly property var p: group ? group.project : null
    readonly property real gMaxEf: group ? Math.max(1, group.maxEf) : 1

    function progressPct() {
      var v = Number((grp.p && grp.p.progress) || 0)
      return v <= 1 ? v * 100 : v
    }

    Row {
      width: parent.width
      spacing: Style.spacing.controlGap
      Text {
        width: Style.space(200); anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight; textFormat: Text.PlainText
        text: (grp.p ? (grp.p.title || grp.p.id) : "") + (grp.p && grp.p.pending_approval ? "  ⚠" : "")
        color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.body; font.bold: true
      }
      Item {
        width: Math.max(Style.space(60), parent.width - Style.space(200) - critLabel.width - parent.spacing * 2)
        height: Style.space(8); anchors.verticalCenter: parent.verticalCenter
        Rectangle {
          anchors.fill: parent; radius: height / 2
          color: Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.12)
          Rectangle {
            anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
            radius: height / 2
            width: parent.width * Math.max(0, Math.min(100, grp.progressPct())) / 100
            color: dash.accent
          }
        }
      }
      Text {
        id: critLabel
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: (grp.p && grp.p.critical_path ? grp.p.critical_path.length : 0) + " critical"
        color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
      }
    }

    Repeater {
      model: grp.group ? grp.group.rows : []
      delegate: QueueRow { required property var modelData; width: grp.width; node: modelData; maxEf: grp.gMaxEf }
    }
    Text {
      visible: grp.group && grp.group.rows.length === 0
      text: "No matching tasks for the current filters."
      color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
      topPadding: Style.space(4); bottomPadding: Style.space(4)
    }
  }

  // ---- one session chip -------------------------------------------------------
  component SessionChip: BorderSurface {
    id: chip
    property var session: null
    radius: Style.cornerRadius
    implicitWidth: chipCol.implicitWidth + Style.space(20)
    implicitHeight: Style.space(46)
    color: Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.04)
    borderSpec: Border.flat(chip.session && chip.session.state === "throttled" ? dash.warnColor : Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.16), 1)

    readonly property color dotColor: {
      var s = chip.session ? chip.session.state : ""
      if (s === "busy") return dash.okColor
      if (s === "throttled") return dash.warnColor
      if (s === "error" || s === "offline") return dash.urgent
      return dash.dim
    }

    Column {
      id: chipCol
      anchors.centerIn: parent
      spacing: Style.spacing.xxs
      Row {
        spacing: Style.spacing.xs
        Text { text: tab.workerGlyph(chip.session ? chip.session.worker : ""); color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
        Text { text: chip.session ? String(chip.session.label || chip.session.id || "") : ""; color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight; width: Style.space(90) }
      }
      Row {
        spacing: Style.spacing.xs
        Rectangle { width: Style.space(6); height: Style.space(6); radius: width / 2; color: chip.dotColor; anchors.verticalCenter: parent.verticalCenter }
        Text {
          text: chip.session ? (chip.session.state === "throttled" ? "throttled · retry" : String(chip.session.state || "")) : ""
          color: chip.session && chip.session.state === "throttled" ? dash.warnColor : dash.dim
          font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        }
        Text {
          text: chip.session ? "· " + tab.costClassTag(chip.session.cost_class) : ""
          color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        }
      }
      Text {
        visible: !!(chip.session && chip.session.assigned_nodes && chip.session.assigned_nodes.length > 0)
        text: chip.session && chip.session.assigned_nodes ? chip.session.assigned_nodes.join(", ") : ""
        color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        elide: Text.ElideRight; width: Style.space(120)
      }
    }
  }

  // ------------------------------------------------------------------ layout --
  Column {
    id: headerCol
    anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
    spacing: Style.space(8)

    PanelHero {
      width: parent.width
      title: "Plan"
      meta: tab.projects.length + " project" + (tab.projects.length === 1 ? "" : "s") + (tab.overviewLoaded ? (tab.harnessAlive ? "  ·  harness running" : "  ·  harness offline (last snapshot)") : "")
      foreground: dash.foreground; fontFamily: dash.fontFamily
      iconComponent: Component { Text { text: "▤"; color: tab.harnessAlive ? dash.okColor : dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.display } }
    }
    PanelSeparator { width: parent.width; foreground: dash.foreground }

    Column {
      width: parent.width; spacing: Style.space(6)
      Repeater { model: tab.pendingApprovalProjects; delegate: ApprovalBanner { required property var modelData; width: headerCol.width; project: modelData } }
    }

    Row {
      width: parent.width; spacing: Style.spacing.controlGap
      PanelDropdown { id: projectDrop; width: Style.space(190); showLabel: false; options: tab.projectOptionsList; value: tab.projectFilter; popupParent: tab; ownerOpen: dash.opened && dash.tab === "plan"; foreground: dash.foreground; fontFamily: dash.fontFamily; onChanged: function(v) { tab.projectFilter = v } }
      PanelDropdown { id: agentDrop; width: Style.space(190); showLabel: false; options: tab.agentOptionsList; value: tab.agentFilter; popupParent: tab; ownerOpen: dash.opened && dash.tab === "plan"; foreground: dash.foreground; fontFamily: dash.fontFamily; onChanged: function(v) { tab.agentFilter = v } }
      Row {
        spacing: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        Repeater {
          model: [
            { key: "ready", label: "Ready" },
            { key: "running", label: "Running" },
            { key: "blocked", label: "Blocked" },
            { key: "done", label: "Done" },
            { key: "failed", label: "Failed" }
          ]
          delegate: Button {
            required property var modelData
            text: modelData.label; bordered: true
            selected: tab.activeStates[modelData.key]
            foreground: dash.foreground; fontFamily: dash.fontFamily
            onClicked: tab.toggleState(modelData.key)
          }
        }
      }
    }
    Row {
      width: parent.width; spacing: Style.spacing.controlGap
      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "Residual " + tab.agg.residual + (tab.agg.blocked > 0 ? " (" + tab.agg.blocked + " blocked)" : "") + "  ·  Spent " + dash.fmtUsd(tab.agg.spent) + " / Approved " + dash.fmtUsd(tab.agg.approved) + " / Left " + dash.fmtUsd(tab.agg.remaining)
        color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
      }
      Item { width: Style.space(8); height: 1 }
      Button { text: "Open full Gantt"; bordered: true; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: Qt.openUrlExternally(tab.harnessUrl) }
      Button { text: "Start harness"; bordered: true; visible: !tab.harnessAlive; foreground: dash.okColor; fontFamily: dash.fontFamily; onClicked: dash.act([dash.launcher, "harness", "serve"]) }
    }
    PanelSeparator { width: parent.width; foreground: dash.foreground }
  }

  Rectangle {
    id: sessionsLane
    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
    height: Style.space(60)
    color: Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.04)
    Flickable {
      anchors.fill: parent; anchors.margins: Style.space(8)
      contentWidth: chipsRow.implicitWidth; contentHeight: height
      clip: true; boundsBehavior: Flickable.StopAtBounds
      Row {
        id: chipsRow
        height: parent.height; spacing: Style.spacing.sm
        Repeater { model: tab.sessions; delegate: SessionChip { required property var modelData; session: modelData } }
        Text {
          visible: tab.sessions.length === 0
          anchors.verticalCenter: parent.verticalCenter
          text: "No sessions registered with the harness."
          color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        }
      }
    }
  }

  Rectangle {
    id: inspector
    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: sessionsLane.top
    height: tab.selectedRow ? Style.space(60) : 0
    visible: height > 1
    clip: true
    color: Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.05)
    Behavior on height { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

    Row {
      anchors.fill: parent; anchors.margins: Style.space(10)
      spacing: Style.spacing.controlGap
      visible: tab.selectedRow !== null
      Column {
        width: parent.width - assignBtn.width - ganttBtn.width - closeBtn.width - parent.spacing * 3
        spacing: Style.spacing.xxs
        Text {
          textFormat: Text.PlainText; elide: Text.ElideRight; width: parent.width
          text: tab.selectedRow ? (tab.selectedRow.title || tab.selectedRow.node) + "  ·  " + tab.selectedRow.state : ""
          color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.body; font.bold: true
        }
        Text {
          textFormat: Text.PlainText; elide: Text.ElideRight; width: parent.width
          text: tab.selectedRow ? "oracle: " + (tab.selectedRow.oracle_type || "—") + "  ·  blockers-first: " + (tab.selectedRow.blockers_first ? "yes" : "no") + "  ·  assignee: " + (tab.selectedRow.assignee || "unassigned") : ""
          color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        }
      }
      Button { id: assignBtn; text: "Assign to Rix"; bordered: true; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: if (tab.selectedRow) dash.act([dash.launcher, "harness", "assign", tab.selectedRow.project, tab.selectedRow.node]) }
      Button { id: ganttBtn; text: "Open in Gantt"; bordered: true; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: if (tab.selectedRow) Qt.openUrlExternally(tab.harnessUrl + "#node=" + encodeURIComponent(tab.selectedRow.node)) }
      Button { id: closeBtn; text: "✕"; bordered: true; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: tab.selectedRow = null }
    }
  }

  Flickable {
    id: board
    anchors.top: headerCol.bottom; anchors.topMargin: Style.space(8)
    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: inspector.top
    clip: true
    contentWidth: width
    contentHeight: groupsCol.implicitHeight
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: groupsCol
      width: board.width
      spacing: Style.space(16)

      Text {
        visible: tab.empty !== ""
        width: parent.width
        text: tab.empty
        color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
        topPadding: Style.space(12)
      }
      Repeater {
        model: tab.groups
        delegate: ProjectGroup { required property var modelData; width: groupsCol.width; group: modelData }
      }
      Item { width: 1; height: Style.space(8) }
    }
  }
}
