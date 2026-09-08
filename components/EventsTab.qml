import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Events page: the tailed events.jsonl, filtered by agent / task / level /
// text and sorted by a clickable column (click again to reverse).
Item {
  id: tab
  required property var dash

  property string filterAgent: ""
  property string filterTask: ""
  property string filterLevel: "all"
  property string filterText: ""
  property string sortKey: "t"
  property bool sortAsc: false
  property var visible_: []
  readonly property int rowCount: visible_.length
  readonly property bool editing: search.activeFocus
  readonly property bool popupOpen: agentDrop.popupOpen || taskDrop.popupOpen

  function activate(i) { if (visible_[i]) dash.chat(visible_[i].agent) }
  function fmtTime(t) {
    var d = new Date(t)
    function two(n) { return (n < 10 ? "0" : "") + n }
    var today = new Date(); var sameDay = d.toDateString() === today.toDateString()
    return (sameDay ? "" : two(d.getMonth() + 1) + "-" + two(d.getDate()) + " ") + two(d.getHours()) + ":" + two(d.getMinutes()) + ":" + two(d.getSeconds())
  }
  function distinct(field) {
    var seen = {}, out = []
    for (var i = 0; i < dash.events.length; i++) { var v = dash.events[i][field]; if (v && !seen[v]) { seen[v] = true; out.push(v) } }
    return out.sort()
  }
  readonly property var agentOptions: [{ value: "", label: "All agents" }].concat(distinct("agent").map(function(a) { return { value: a, label: dash.agentByName(a) ? a : a + "  (removed)" } }))
  readonly property var taskOptions: [{ value: "", label: "All tasks" }].concat(distinct("task").map(function(t) { return { value: t, label: t } }))

  function rebuild() {
    var q = filterText.trim().toLowerCase()
    var out = dash.events.filter(function(e) {
      if (filterAgent !== "" && e.agent !== filterAgent) return false
      if (filterTask !== "" && e.task !== filterTask) return false
      if (filterLevel === "warn" && e.level === "info") return false
      if (filterLevel === "blocker" && e.level !== "blocker") return false
      if (q !== "" && (String(e.message) + " " + e.kind + " " + e.agent + " " + e.task).toLowerCase().indexOf(q) < 0) return false
      return true
    })
    var k = sortKey, asc = sortAsc
    out.sort(function(a, b) {
      var x = a[k], y = b[k]
      if (k === "t") { var d = (a.t - b.t) || (a.n - b.n); return asc ? d : -d }
      x = String(x || "").toLowerCase(); y = String(y || "").toLowerCase()
      if (x === y) return (b.t - a.t) || (b.n - a.n)
      return asc ? (x < y ? -1 : 1) : (x < y ? 1 : -1)
    })
    visible_ = out
    if (dash.tab === "events") dash.selectedIndex = Math.max(0, Math.min(dash.selectedIndex, out.length - 1))
  }
  function setSort(k) { if (sortKey === k) sortAsc = !sortAsc; else { sortKey = k; sortAsc = k !== "t" } rebuild() }
  Connections { target: dash; function onEventsVersionChanged() { tab.rebuild() } }
  onFilterAgentChanged: rebuild()
  onFilterTaskChanged: rebuild()
  onFilterLevelChanged: rebuild()
  onFilterTextChanged: rebuild()
  Component.onCompleted: rebuild()

  readonly property var columns: [
    { key: "t", label: "Time", width: 150 }, { key: "agent", label: "Agent", width: 170 },
    { key: "task", label: "Task", width: 170 }, { key: "kind", label: "Kind", width: 130 }, { key: "message", label: "Message", width: 0 }
  ]
  function colWidth(c, total) { var fixed = 0; for (var i = 0; i < columns.length; i++) fixed += Style.space(columns[i].width); return c.width ? Style.space(c.width) : Math.max(Style.space(160), total - fixed) }

  Column {
    anchors.fill: parent
    spacing: Style.space(8)

    PanelHero {
      width: parent.width
      title: "Events"
      meta: tab.rowCount + " of " + dash.events.length + " events"
      foreground: dash.foreground; fontFamily: dash.fontFamily
      iconComponent: Component { Text { text: "󰈙"; color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.display } }
    }
    PanelSeparator { width: parent.width; foreground: dash.foreground }

    Row {
      width: parent.width; spacing: Style.spacing.controlGap
      PanelDropdown { id: agentDrop; width: Style.space(190); showLabel: false; options: tab.agentOptions; value: tab.filterAgent; popupParent: tab; ownerOpen: dash.opened; foreground: dash.foreground; fontFamily: dash.fontFamily; onChanged: function(v) { tab.filterAgent = v } }
      PanelDropdown { id: taskDrop; width: Style.space(190); showLabel: false; options: tab.taskOptions; value: tab.filterTask; popupParent: tab; ownerOpen: dash.opened; foreground: dash.foreground; fontFamily: dash.fontFamily; onChanged: function(v) { tab.filterTask = v } }
      ButtonGroup { options: [{ value: "all", label: "All" }, { value: "warn", label: "Warnings+" }, { value: "blocker", label: "Blockers" }]; value: tab.filterLevel; foreground: dash.foreground; fontFamily: dash.fontFamily; onChanged: function(v) { tab.filterLevel = v } }
      TextField { id: search; width: parent.width - agentDrop.width - taskDrop.width - Style.space(300) - parent.spacing * 3; placeholderText: "search"; foreground: dash.foreground; font.family: dash.fontFamily; verticalPadding: Style.spacing.controlPaddingY; text: tab.filterText; onTextEdited: tab.filterText = text; Keys.onEscapePressed: function(e) { dash.focusCatcher(); e.accepted = true } }
    }

    // sortable header
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
            text: modelData.label + (tab.sortKey === modelData.key ? (tab.sortAsc ? "  ▲" : "  ▼") : "")
            color: tab.sortKey === modelData.key ? dash.foreground : dash.dim
            font.family: dash.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
          }
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: tab.setSort(modelData.key) }
        }
      }
    }
    PanelSeparator { width: parent.width; foreground: dash.foreground }

    ListView {
      id: list
      width: parent.width
      height: parent.height - y
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
      model: tab.visible_
      delegate: EventRow { required property var modelData; required property int index; width: list.width; ev: modelData; rowIndex: index }
    }
  }

  component EventRow: CursorSurface {
    id: row
    property var ev: null
    property int rowIndex: 0
    hasCursor: dash.cursorActive && dash.tab === "events" && dash.selectedIndex === rowIndex
    foreground: dash.foreground
    implicitHeight: Style.space(26)
    MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.ArrowCursor; onContainsMouseChanged: if (containsMouse) { dash.cursorActive = true; dash.selectedIndex = row.rowIndex }; onDoubleClicked: dash.chat(row.ev.agent) }
    Row {
      anchors.fill: parent; spacing: 0
      Repeater {
        model: tab.columns
        delegate: Text {
          required property var modelData
          width: tab.colWidth(modelData, row.width); height: row.height
          leftPadding: Style.spacing.md; rightPadding: Style.spacing.md
          verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
          text: !row.ev ? "" : (modelData.key === "t" ? tab.fmtTime(row.ev.t) : String(row.ev[modelData.key] || ""))
          color: row.ev && row.ev.level === "blocker" ? dash.urgent : (row.ev && row.ev.level === "warn" ? dash.warnColor : (modelData.key === "message" ? dash.foreground : dash.dim))
          font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }
}
