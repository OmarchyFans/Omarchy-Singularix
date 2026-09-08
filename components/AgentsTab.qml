import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Agents page: every saved agent with status, last event, task count, and
// row actions. Enter or Chat focuses the agent's window (or reattaches its
// tmux session). Hover moves the cursor (CursorSurface contract).
Item {
  id: tab
  required property var dash

  readonly property var agents: dash.status ? dash.status.agents : []
  readonly property int rowCount: agents.length
  readonly property bool editing: false
  readonly property bool popupOpen: confirm.opened
  property string pendingRemove: ""

  function activate(i) { if (agents[i]) dash.chat(agents[i].name) }
  function select(name) {
    for (var i = 0; i < agents.length; i++) if (agents[i].name === name) { dash.selectedIndex = i; dash.cursorActive = true; list.positionViewAtIndex(i, ListView.Contain); return }
  }
  function timeAgo(t) {
    if (!t) return ""
    var s = Math.max(0, Math.round((Date.now() - t) / 1000))
    if (s < 60) return s + "s ago"
    if (s < 3600) return Math.round(s / 60) + "m ago"
    if (s < 86400) return Math.round(s / 3600) + "h ago"
    return Math.round(s / 86400) + "d ago"
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(10)

    PanelHero {
      width: parent.width
      title: "Agents"
      meta: tab.rowCount === 0 ? "No agents yet — press 2 for New agent" : (dash.runningCount + " running · " + dash.blockerCount + " need you")
      foreground: dash.foreground; fontFamily: dash.fontFamily
      iconComponent: Component { Text { text: "󰙨"; color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.display } }
    }
    PanelSeparator { width: parent.width; foreground: dash.foreground }

    ListView {
      id: list
      width: parent.width
      height: parent.height - y
      clip: true
      spacing: Style.space(6)
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
      model: tab.agents
      delegate: AgentRow { required property var modelData; required property int index; width: list.width; agent: modelData; rowIndex: index }
    }
  }

  component AgentRow: CursorSurface {
    id: row
    property var agent: null
    property int rowIndex: 0
    readonly property bool selected: dash.cursorActive && dash.tab === "agents" && dash.selectedIndex === rowIndex
    hasCursor: selected
    foreground: dash.foreground
    implicitHeight: body.implicitHeight + Style.space(16)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) { dash.cursorActive = true; dash.selectedIndex = row.rowIndex }
      onDoubleClicked: dash.chat(row.agent.name)
    }

    Row {
      id: body
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12); anchors.rightMargin: Style.space(8)
      spacing: Style.space(12)

      Text { text: "󱚝"; color: row.agent && row.agent.status === "running" ? dash.okColor : dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.iconLarge; anchors.verticalCenter: parent.verticalCenter }

      Column {
        width: parent.width - actions.width - parent.spacing * 2 - Style.space(24)
        spacing: Style.spacing.xxs
        Row {
          spacing: Style.spacing.rowGap
          Text { text: row.agent ? row.agent.name : ""; color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.subtitle; font.bold: true; anchors.verticalCenter: parent.verticalCenter }
          StatusPill { status: row.agent ? row.agent.status : "idle"; foreground: dash.foreground; fontFamily: dash.fontFamily; anchors.verticalCenter: parent.verticalCenter }
          Text { visible: row.agent && row.agent.role === "chief-of-staff"; text: "chief of staff"; color: dash.accent; font.family: dash.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; anchors.verticalCenter: parent.verticalCenter }
          Text { visible: row.agent && row.agent.parent !== ""; text: row.agent ? "for " + row.agent.parent : ""; color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
          Text { visible: row.agent && row.agent.window !== ""; text: "window open"; color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
        }
        Text {
          width: parent.width; elide: Text.ElideRight
          text: row.agent ? (row.agent.agent + " · " + row.agent.runtime + " · " + (row.agent.backend || row.agent.provider) + "/" + row.agent.model + " · " + row.agent.mode + (row.agent.tasks ? "  ·  " + row.agent.tasks.length + " task" + (row.agent.tasks.length === 1 ? "" : "s") : "")) : ""
          color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        }
        Text {
          width: parent.width; elide: Text.ElideRight
          visible: row.agent && row.agent.usage && row.agent.usage.sessions > 0
          text: row.agent && row.agent.usage ? (dash.fmtK(row.agent.usage.prompt) + " prompt · " + dash.fmtK(row.agent.usage.output) + " output tokens  ·  " + dash.fmtUsd(row.agent.usage.cost_usd) + (row.agent.usage.cost_unknown ? " (+" + row.agent.usage.cost_unknown + " unpriced)" : "") + "  ·  " + row.agent.usage.sessions + " session" + (row.agent.usage.sessions === 1 ? "" : "s")) : ""
          color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        }
        Text {
          width: parent.width; elide: Text.ElideRight
          text: row.agent ? (row.agent.job_title ? "Job: " + row.agent.job_title : "") : ""
          color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall
        }
        Text {
          width: parent.width; elide: Text.ElideRight
          visible: row.agent && row.agent.last
          text: row.agent && row.agent.last ? (tab.timeAgo(row.agent.last.t) + "  ·  " + row.agent.last.message) : ""
          color: row.agent && row.agent.last && row.agent.last.level === "blocker" ? dash.urgent : dash.dim
          font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        }
      }

      Row {
        id: actions
        spacing: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        Button { text: "Chat"; iconText: "󰭹"; selected: true; tooltipText: "Focus the agent's window, or reattach to its session"; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: dash.chat(row.agent.name) }
        PanelActionButton { iconText: "󰓛"; tooltipText: "Stop the session (keeps the agent)"; visible: row.agent && row.agent.running; hoverColor: dash.urgent; onClicked: dash.act([dash.launcher, "stop", row.agent.name]) }
        PanelActionButton { iconText: "󰷈"; tooltipText: "Edit the job description"; onClicked: dash.act([dash.launcher, "--popup", "job", row.agent.name]) }
        PanelActionButton { iconText: "󰩺"; tooltipText: "Remove this agent"; hoverColor: dash.urgent; onClicked: { tab.pendingRemove = row.agent.name; confirm.opened = true } }
      }
    }
  }

  ConfirmDialog {
    id: confirm
    anchors.fill: parent
    message: "Remove '" + tab.pendingRemove + "'? Its session is stopped and its local home deleted. The event history stays."
    confirmText: "Remove"
    foreground: dash.foreground; fontFamily: dash.fontFamily
    onConfirmed: { opened = false; dash.act([dash.launcher, "remove", "--yes", tab.pendingRemove]); tab.pendingRemove = "" }
    onCanceled: { opened = false; tab.pendingRemove = "" }
  }
}
