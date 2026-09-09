import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Projects page: one row per registered hermes project (dash.status.projects,
// merged server-side into status --json), showing its derived waterfall
// phase, percent complete, and open blocker count at a glance. Activating a
// row jumps to Events filtered to that project's owning agent — reuses
// EventsTab's existing filter instead of a new drill-down view.
Item {
  id: tab
  required property var dash

  readonly property var rows: dash.status && dash.status.projects ? dash.status.projects : []
  readonly property int rowCount: rows.length
  readonly property bool editing: false
  readonly property bool popupOpen: false

  function activate(i) {
    var r = rows[i]; if (!r) return
    dash.selectTab("events")
    if (dash.eventsTabRef) dash.eventsTabRef.filterAgent = r.agent
  }

  readonly property var columns: [
    { key: "name", label: "Project", width: 220 }, { key: "phase", label: "Phase", width: 0 },
    { key: "percent_done", label: "Progress", width: 160 }, { key: "open_blockers", label: "Blockers", width: 110 }
  ]
  function colWidth(c, total) { var fixed = 0; for (var i = 0; i < columns.length; i++) fixed += Style.space(columns[i].width); return c.width ? Style.space(c.width) : Math.max(Style.space(160), total - fixed) }

  Column {
    anchors.fill: parent
    spacing: Style.space(8)

    PanelHero {
      width: parent.width
      title: "Projects"
      meta: tab.rowCount + " project" + (tab.rowCount === 1 ? "" : "s")
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
      visible: tab.rowCount === 0
      width: parent.width
      text: "No projects yet. Create one with `hermes project create <name>`."
      color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall
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
    implicitHeight: Style.space(34)
    MouseArea {
      anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) { dash.cursorActive = true; dash.selectedIndex = prow.rowIndex }
      onDoubleClicked: tab.activate(prow.rowIndex)
    }
    Row {
      anchors.fill: parent; spacing: 0
      Text {
        width: tab.colWidth(tab.columns[0], prow.width); height: prow.height
        leftPadding: Style.spacing.md; rightPadding: Style.spacing.md
        verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
        text: prow.row ? prow.row.name : ""
        color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
      }
      Text {
        width: tab.colWidth(tab.columns[1], prow.width); height: prow.height
        leftPadding: Style.spacing.md; rightPadding: Style.spacing.md
        verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
        text: prow.row ? String(prow.row.phase || "N/A") : ""
        color: prow.row && prow.row.phase === "Done" ? dash.okColor : dash.dim
        font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall
      }
      Item {
        width: tab.colWidth(tab.columns[2], prow.width); height: prow.height
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: Style.spacing.md
          width: parent.width - Style.spacing.md * 2; height: Style.space(8); radius: height / 2
          color: Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.12)
          Rectangle {
            anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
            width: parent.width * Math.max(0, Math.min(100, prow.row ? prow.row.percent_done : 0)) / 100
            radius: height / 2
            color: prow.row && prow.row.percent_done >= 100 ? dash.okColor : dash.accent
          }
        }
        Text {
          anchors.right: parent.right; anchors.rightMargin: Style.spacing.md; anchors.verticalCenter: parent.verticalCenter
          text: prow.row ? Math.round(prow.row.percent_done) + "%" : ""
          color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        }
      }
      Text {
        width: tab.colWidth(tab.columns[3], prow.width); height: prow.height
        leftPadding: Style.spacing.md; rightPadding: Style.spacing.md
        verticalAlignment: Text.AlignVCenter
        text: prow.row && prow.row.open_blockers > 0 ? String(prow.row.open_blockers) : "—"
        color: prow.row && prow.row.open_blockers > 0 ? dash.urgent : dash.dim
        font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: prow.row && prow.row.open_blockers > 0
      }
    }
  }
}
