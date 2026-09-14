import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Projects page: "projects" means one thing here. Merges the harness's own
// projects (source "harness": id/title/status/residual/progress/next node/
// cost/pending-approval count, read straight from the harness's
// overview.json — same FileView contract as PlanTab) with the launcher's
// sqlite rollups (source "kanban": name/phase/percent_done/open_blockers).
// A kanban project sharing a title with a harness project is folded into
// that harness row (the kanban phase shown as a secondary line) rather than
// listed twice. Activating a harness row deep-links to the Plan tab
// pre-filtered to that project; a kanban-only row keeps the old EventsTab
// deep link.
Item {
  id: tab
  required property var dash

  // ---- harness plumbing (same resolution as PlanTab) -----------------------
  readonly property var harness: dash.status && dash.status.harness ? dash.status.harness : null
  readonly property bool harnessAlive: !!(harness && harness.alive)
  readonly property string dataDir: (harness && harness.data_dir) || (Quickshell.env("HOME") + "/.session-harness")
  readonly property string overviewPath: (harness && harness.overview_path) || (tab.dataDir + "/overview.json")

  property var overview: null
  property bool overviewLoaded: false
  readonly property var harnessProjects: overview && overview.projects ? overview.projects : []
  readonly property var queueAll: overview && overview.queue ? overview.queue : []
  readonly property var kanbanProjects: dash.status && dash.status.projects ? dash.status.projects : []

  readonly property bool editing: false
  readonly property bool popupOpen: false

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

  function stateColor(s) {
    if (s === "blocked") return "#6b7280"
    if (s === "pending approval") return dash.warnColor
    if (s === "ready") return "#d9a400"
    if (s === "running") return "#3b82f6"
    if (s === "done") return dash.okColor
    if (s === "failed") return dash.urgent
    return dash.dim
  }

  // earliest / most-critical unfinished queue node for a harness project
  function nextNodeFor(pid) {
    var best = null
    for (var i = 0; i < queueAll.length; i++) {
      var q = queueAll[i]
      if (q.project !== pid) continue
      if (q.state === "done" || q.state === "cancelled") continue
      if (!best) { best = q; continue }
      if (!!q.critical !== !!best.critical) { if (q.critical) best = q; continue }
      if (Number(q.es || 0) < Number(best.es || 0)) best = q
    }
    return best
  }

  function harnessStatusFor(p, next) {
    if (p.pending_approval) return "pending approval"
    if (Number(p.residual || 0) <= 0) return "done"
    if (next) return String(next.state || "ready")
    return "ready"
  }

  function buildRows() {
    var out = []
    var kanbanByKey = {}
    for (var i = 0; i < kanbanProjects.length; i++) {
      var kp = kanbanProjects[i]
      kanbanByKey[String(kp.name || "").trim().toLowerCase()] = kp
    }
    var matched = {}
    for (var j = 0; j < harnessProjects.length; j++) {
      var hp = harnessProjects[j]
      var title = hp.title || hp.id
      var key = String(title).trim().toLowerCase()
      var kb = kanbanByKey[key]
      if (kb) matched[key] = true
      var next = nextNodeFor(hp.id)
      var progress = Number(hp.progress || 0); if (progress <= 1) progress *= 100
      var cost = hp.cost || {}
      out.push({
        source: "harness", id: hp.id, name: title,
        status: harnessStatusFor(hp, next),
        residual: Number(hp.residual || 0), residualBlocked: Number(hp.residual_blocked || 0),
        progress: progress,
        nextTitle: next ? (next.title || next.node || "") : "",
        spent: Number(cost.spent_usd || 0), approved: Number(cost.approved_usd || 0),
        pendingCount: hp.pending_approval ? 1 : 0,
        kanbanPhase: kb ? (kb.phase || "") : "",
        openBlockers: 0,
        agent: kb ? kb.agent : ""
      })
    }
    for (var k = 0; k < kanbanProjects.length; k++) {
      var kp2 = kanbanProjects[k]
      var key2 = String(kp2.name || "").trim().toLowerCase()
      if (matched[key2]) continue
      out.push({
        source: "kanban", id: kp2.name, name: kp2.name,
        status: kp2.phase || "N/A",
        residual: -1, residualBlocked: 0,
        progress: Number(kp2.percent_done || 0),
        nextTitle: "", spent: -1, approved: -1,
        pendingCount: 0, kanbanPhase: "",
        openBlockers: Number(kp2.open_blockers || 0),
        agent: kp2.agent
      })
    }
    // pending approvals first, then running, then least-progressed first
    out.sort(function(a, b) {
      var ap = a.pendingCount > 0 ? 0 : 1, bp = b.pendingCount > 0 ? 0 : 1
      if (ap !== bp) return ap - bp
      var ar = a.status === "running" ? 0 : 1, br = b.status === "running" ? 0 : 1
      if (ar !== br) return ar - br
      return a.progress - b.progress
    })
    return out
  }
  readonly property var rows: buildRows()
  readonly property int rowCount: rows.length

  function activate(i) {
    var r = rows[i]; if (!r) return
    if (r.source === "harness") {
      dash.selectTab("plan")
      // Dashboard does not yet expose a planTabRef (only eventsTabRef exists
      // today) — once it does (same Component.onCompleted pattern as
      // EventsTab), set its `projectFilter` here to pre-filter the Plan tab.
      if (dash.planTabRef && r.id) dash.planTabRef.projectFilter = r.id
    } else {
      dash.selectTab("events")
      if (dash.eventsTabRef) dash.eventsTabRef.filterAgent = r.agent
    }
  }

  function emptyMessage() {
    if (tab.rowCount > 0) return ""
    if (!overviewLoaded && !harnessAlive) return "No projects yet, and the harness isn't running (no data at " + tab.overviewPath + "). Create one with `hermes project create <name>`, or start the harness from the Plan tab."
    return "No projects yet. Create one with `hermes project create <name>` or `harness project create <name>`."
  }
  readonly property string empty: emptyMessage()

  readonly property var columns: [
    { key: "name", label: "Project", width: 200 }, { key: "source", label: "Source", width: 76 },
    { key: "status", label: "Status", width: 0 }, { key: "progress", label: "Progress", width: 130 },
    { key: "next", label: "Next / Blockers", width: 190 }, { key: "cost", label: "Spent / Approved", width: 150 },
    { key: "pending", label: "Pending", width: 80 }
  ]
  function colWidth(c, total) { var fixed = 0; for (var i = 0; i < columns.length; i++) fixed += Style.space(columns[i].width); return c.width ? Style.space(c.width) : Math.max(Style.space(160), total - fixed) }

  Column {
    anchors.fill: parent
    spacing: Style.space(8)

    PanelHero {
      width: parent.width
      title: "Projects"
      meta: tab.rowCount + " project" + (tab.rowCount === 1 ? "" : "s") + (tab.overviewLoaded ? (tab.harnessAlive ? "  ·  harness running" : "  ·  harness offline (last snapshot)") : "")
      foreground: dash.foreground; fontFamily: dash.fontFamily
      iconComponent: Component { Text { text: "󰙅"; color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.display } }
    }
    PanelSeparator { width: parent.width; foreground: dash.foreground }

    Row {
      id: header
      width: parent.width; spacing: 0
      Repeater {
        model: tab.columns
        delegate: Item {
          required property var modelData
          width: tab.colWidth(modelData, header.width); height: Style.space(24)
          Text {
            anchors.left: parent.left; anchors.leftMargin: Style.spacing.md; anchors.verticalCenter: parent.verticalCenter
            text: modelData.label
            color: dash.dim
            font.family: dash.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
          }
        }
      }
    }
    PanelSeparator { width: parent.width; foreground: dash.foreground }

    Text {
      visible: tab.empty !== ""
      width: parent.width
      text: tab.empty
      color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall
      wrapMode: Text.Wrap
      topPadding: Style.space(12)
    }

    ListView {
      id: list
      width: parent.width
      height: parent.height - y
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
      model: tab.rows
      delegate: ProjectRow { required property var modelData; required property int index; width: list.width; row: modelData; rowIndex: index }
    }
  }

  component ProjectRow: CursorSurface {
    id: prow
    property var row: null
    property int rowIndex: 0
    hasCursor: dash.cursorActive && dash.tab === "projects" && dash.selectedIndex === rowIndex
    foreground: dash.foreground
    implicitHeight: prow.row && prow.row.kanbanPhase ? Style.space(46) : Style.space(34)
    MouseArea {
      anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) { dash.cursorActive = true; dash.selectedIndex = prow.rowIndex }
      onDoubleClicked: tab.activate(prow.rowIndex)
    }
    Row {
      anchors.fill: parent; spacing: 0
      Column {
        width: tab.colWidth(tab.columns[0], prow.width)
        anchors.verticalCenter: parent.verticalCenter
        Text {
          width: parent.width
          leftPadding: Style.spacing.md; rightPadding: Style.spacing.md
          elide: Text.ElideRight
          text: prow.row ? prow.row.name : ""
          color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
        }
        Text {
          visible: !!(prow.row && prow.row.kanbanPhase)
          width: parent.width
          leftPadding: Style.spacing.md; rightPadding: Style.spacing.md
          elide: Text.ElideRight
          text: prow.row ? "kanban: " + prow.row.kanbanPhase : ""
          color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        }
      }
      Text {
        width: tab.colWidth(tab.columns[1], prow.width); height: prow.height
        leftPadding: Style.spacing.md; rightPadding: Style.spacing.md
        verticalAlignment: Text.AlignVCenter
        text: prow.row ? prow.row.source : ""
        color: prow.row && prow.row.source === "harness" ? dash.accent : dash.dim
        font.family: dash.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
      }
      Text {
        width: tab.colWidth(tab.columns[2], prow.width); height: prow.height
        leftPadding: Style.spacing.md; rightPadding: Style.spacing.md
        verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
        text: prow.row ? String(prow.row.status || "N/A") : ""
        color: prow.row ? tab.stateColor(prow.row.status) : dash.dim
        font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall
      }
      Item {
        width: tab.colWidth(tab.columns[3], prow.width); height: prow.height
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: Style.spacing.md
          width: parent.width - Style.spacing.md * 2; height: Style.space(8); radius: height / 2
          color: Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.12)
          Rectangle {
            anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
            width: parent.width * Math.max(0, Math.min(100, prow.row ? prow.row.progress : 0)) / 100
            radius: height / 2
            color: prow.row && prow.row.progress >= 100 ? dash.okColor : dash.accent
          }
        }
        Text {
          anchors.right: parent.right; anchors.rightMargin: Style.spacing.md; anchors.verticalCenter: parent.verticalCenter
          text: prow.row ? Math.round(prow.row.progress) + "%" : ""
          color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        }
      }
      Text {
        width: tab.colWidth(tab.columns[4], prow.width); height: prow.height
        leftPadding: Style.spacing.md; rightPadding: Style.spacing.md
        verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
        text: {
          if (!prow.row) return ""
          if (prow.row.source === "harness") {
            var t = prow.row.nextTitle ? prow.row.nextTitle : "—"
            return t + (prow.row.residualBlocked > 0 ? "  (" + prow.row.residualBlocked + " blocked)" : "")
          }
          return prow.row.openBlockers > 0 ? prow.row.openBlockers + " blocker" + (prow.row.openBlockers === 1 ? "" : "s") : "—"
        }
        color: prow.row && ((prow.row.source === "harness" && prow.row.residualBlocked > 0) || (prow.row.source === "kanban" && prow.row.openBlockers > 0)) ? dash.urgent : dash.dim
        font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall
      }
      Text {
        width: tab.colWidth(tab.columns[5], prow.width); height: prow.height
        leftPadding: Style.spacing.md; rightPadding: Style.spacing.md
        verticalAlignment: Text.AlignVCenter
        text: prow.row && prow.row.source === "harness" ? dash.fmtUsd(prow.row.spent) + " / " + dash.fmtUsd(prow.row.approved) : "—"
        color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
      }
      Text {
        width: tab.colWidth(tab.columns[6], prow.width); height: prow.height
        leftPadding: Style.spacing.md; rightPadding: Style.spacing.md
        verticalAlignment: Text.AlignVCenter
        text: prow.row && prow.row.pendingCount > 0 ? String(prow.row.pendingCount) : "—"
        color: prow.row && prow.row.pendingCount > 0 ? dash.urgent : dash.dim
        font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: prow.row && prow.row.pendingCount > 0
      }
    }
  }
}
