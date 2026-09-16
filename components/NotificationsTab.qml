import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Notifications page: open blockers first ("NEEDS YOU"), then recent warnings
// ("RECENT"). Every row is a one-line summary; clicking it (or pressing Enter
// on the cursor row) expands a card underneath with what it is, why it
// matters, what's recommended, and the buttons that act on it -- each named
// by what it actually DOES, with a tooltip saying so, so "click this to find
// out" never becomes the only way to understand a notification.
Item {
  id: tab
  required property var dash

  readonly property var blockerList: Object.keys(dash.blockers).map(function(k) {
    var b = dash.blockers[k]; b.__row = "blocker"; b.__id = "b:" + k; return b
  }).sort(function(a, b) { return b.t - a.t })

  property var localDismissed: ({})
  function warnKey(e) { return "w:" + (e.n !== undefined && e.n !== null ? e.n : (String(e.t) + ":" + String(e.ref || ""))) }
  readonly property var warnings: dash.events.filter(function(e) {
    return e.level === "warn" && !tab.localDismissed[tab.warnKey(e)]
  }).slice(-50).reverse().map(function(e) {
    e.__row = "warning"; e.__id = tab.warnKey(e); return e
  })

  readonly property int rowCount: blockerList.length + warnings.length
  readonly property bool editing: false
  readonly property bool popupOpen: false
  property bool notify: true
  property var expanded: ({})

  function rowAt(i) { return (i >= 0 && i < tab.blockerList.length) ? tab.blockerList[i] : tab.warnings[i - tab.blockerList.length] }
  function isBlockerRow(r) { return !!(r && r.__row === "blocker") }
  function isExpanded(r) { return !!(r && tab.expanded[r.__id]) }
  function toggleExpand(r) {
    if (!r) return
    var m = {}; for (var k in tab.expanded) m[k] = tab.expanded[k]
    m[r.__id] = !m[r.__id]
    tab.expanded = m
  }
  function activate(i) { tab.toggleExpand(tab.rowAt(i)) }
  // Wired from Dashboard.qml's PanelKeyCatcher.onTextKey the same way plan's shortcuts
  // are (dash.tab === "plan" && ... -> dash.planTabRef.<fn>()) -- Dashboard.qml is outside
  // this file's ownership, so the two lines it needs go in the wave report, not here.
  // "h" is unavailable: PanelKeyCatcher already binds it (and Left) to moveRequested(-1,0)
  // before textKey ever fires, so Hand-to-Rix uses "H" (Shift+h passes through untouched).
  function dismissSelected() { if (dash.cursorActive) tab.dismiss(tab.rowAt(dash.selectedIndex)) }
  function handToRixSelected() { if (dash.cursorActive) tab.handToRix(tab.rowAt(dash.selectedIndex)) }

  // Dismiss: a blocker is really cleared (blocker_cleared, same as the old "Resolve");
  // a warning has no persisted state to clear, so it's just hidden from this session's view.
  function dismiss(r) {
    if (!r) return
    if (tab.isBlockerRow(r)) {
      dash.emitEvent(r.agent, "blocker_cleared", "Dismissed from the dashboard", r.key)
    } else {
      var m = {}; for (var k in tab.localDismissed) m[k] = tab.localDismissed[k]
      m[r.__id] = true
      tab.localDismissed = m
    }
  }
  // Hands the notification to Rix as a task and opens Rix's chat -- it does NOT dismiss
  // the notification. A fresh ref (never the source event's own ref) because
  // Dashboard.ingest dedups on ref (seenRefs): reusing the blocker/note's ref here would
  // make this second event a silent no-op the moment the first one had already been seen.
  // --task is required, not cosmetic: cmd_status_json groups an agent's .tasks by the
  // event's own .task field (bin/omarchy-agent-launcher cmd_status_json, $cli grouping) --
  // an event with no --task never appears in Rix's task list at all, so this button would
  // silently do nothing useful without one.
  function handToRix(r) {
    if (!r) return
    var msg = r.message + (r.recommend ? " — " + r.recommend : "")
    var title = String(r.message || "notification").slice(0, 60)
    var argv = [dash.launcher, "event", "rix", "task", msg, "--task", title, "--ref", "handoff:" + r.__id, "--key", "handoff-" + r.__id]
    dash.act(argv)
    dash.chat("rix")
  }
  // Deep-links into Projects: filters to the notification's project and, if its node is
  // still in the board, selects that row too (PlanTab.flatRows / selectRow -- read-only
  // use of what PlanTab already exposes via dash.planTabRef, no PlanTab.qml edit needed).
  function openInProjects(r) {
    if (!r) return
    dash.selectTab("plan")
    if (!dash.planTabRef) return
    if (r.project) dash.planTabRef.projectFilter = r.project
    if (r.node) {
      var rows = dash.planTabRef.flatRows || []
      for (var i = 0; i < rows.length; i++) {
        if (rows[i] && rows[i].node === r.node) { dash.planTabRef.selectRow(rows[i]); break }
      }
    }
  }

  // ---- harness cost-approval rows ------------------------------------------------------
  function isApproval(b) { return !!(b && typeof b.key === "string" && b.key.indexOf("approval-") === 0) }
  function approvalProject(b) {
    if (b && b.project) return b.project
    if (b && typeof b.key === "string" && b.key.indexOf("approval-") === 0) return b.key.slice("approval-".length).split(":")[0]
    if (b && typeof b.ref === "string") { var parts = b.ref.split(":"); if (parts[0] === "harness" && parts.length > 1) return parts[1] }
    return ""
  }
  function approvalUsd(b) {
    var m = /\$([0-9]+(?:\.[0-9]+)?)/.exec((b && b.message) || "")
    return m ? m[1] : "0"
  }
  // the blocker's ref is "harness:<project>[:<request_id>]:approval:<at>" (lib/harness.sh
  // harness_notify_sync): pass the request id through so Approve/Decline hit that request
  function approvalRequest(b) {
    var ref = String((b && b.ref) || "")
    var m = ref.match(/^harness:[^:]+:([0-9a-f]{6,}):approval:/)
    return m ? m[1] : ""
  }
  function approveLabel(b) { return "Approve $" + tab.approvalUsd(b) }
  // Prefer the argv the emitter shipped (--action LABEL=ARGV_JSON, lib/events.sh); fall
  // back to deriving it from the key/ref/message text for an older event or one raised
  // straight from the CLI without --action.
  function actionArgv(b, label) {
    if (b && b.actions) { for (var i = 0; i < b.actions.length; i++) if (b.actions[i] && b.actions[i].label === label) return [dash.launcher].concat(b.actions[i].argv) }
    return null
  }
  function approve(b) {
    var argv = tab.actionArgv(b, tab.approveLabel(b))
    if (!argv) {
      argv = [dash.launcher, "harness", "approve", tab.approvalProject(b), tab.approvalUsd(b)]
      var rid = tab.approvalRequest(b); if (rid !== "") argv.push("--request", rid)
    }
    dash.act(argv)
  }
  function decline(b) {
    var argv = tab.actionArgv(b, "Decline")
    if (!argv) {
      argv = [dash.launcher, "harness", "decline", tab.approvalProject(b)]
      var rid = tab.approvalRequest(b); if (rid !== "") argv.push("--request", rid)
    }
    dash.act(argv)
  }

  // ---- a forgotten hns-* delegate: harness_job_forget already removed its profile, so
  // Chat has nothing to open -- offer its saved run log instead (bin/omarchy-agent-launcher
  // notify runlog/runinfo, backed by $HARNESS_STATE_DIR/runs/<slug>/).
  function isForgottenDelegate(r) {
    return !!(r && typeof r.agent === "string" && r.agent.indexOf("hns-") === 0 && !dash.agentByName(r.agent))
  }
  function viewRunLog(r) { if (r) dash.act([dash.launcher, "--popup", "notify", "runlog", r.agent]) }

  function levelGlyph(r) { return tab.isBlockerRow(r) ? "󰀦" : (r && r.level === "warn" ? "󰀪" : "󰋼") }
  function ageText(r) {
    var ms = Date.now() - Number((r && r.t) || 0)
    var s = Math.max(0, Math.floor(ms / 1000))
    if (s < 60) return s + "s ago"
    var m = Math.floor(s / 60); if (m < 60) return m + "m ago"
    var h = Math.floor(m / 60); if (h < 24) return h + "h ago"
    return Math.floor(h / 24) + "d ago"
  }
  function titleText(r) {
    if (!r) return ""
    var loc = [r.agent, r.project, r.node].filter(function(x) { return !!x }).join(" · ")
    return (loc ? loc + "  ·  " : "") + (r.message || "")
  }

  function loadSetting() { if (!settingProc.running) { settingProc.command = [dash.launcher, "settings", "get", "notify_blockers"]; settingProc.running = true } }
  Process {
    id: settingProc
    stdout: StdioCollector { id: settingOut; waitForEnd: true }
    onExited: { var v = String(settingOut.text || "").trim(); tab.notify = (v !== "false") }
  }
  Connections { target: dash; function onOpenedChanged() { if (dash.opened) tab.loadSetting() } }

  // ---- one row, shared by the blocker and warning Repeaters below (a plain Component,
  // not a named inline `component` type: qmllint cannot resolve CursorSurface outside the
  // full shell runtime, and a NAMED component built on an unresolved base gets flagged
  // itself as unresolved wherever it's instantiated -- a shared Component referenced by
  // id sidesteps that). No per-Repeater indexOffset property either: each row already
  // carries __row ("blocker"/"warning"), enough to compute its own global cursor index.
  Component {
    id: notifRowDelegate
    CursorSurface {
      id: rowItem
      required property var modelData
      required property int index
      readonly property var row: modelData
      readonly property int globalIndex: (row && row.__row === "blocker") ? index : index + tab.blockerList.length
      readonly property bool isOpen: tab.isExpanded(row)
      // Forgotten delegates only: notify runinfo <slug> -> {log, resume} (bin/omarchy-agent-
      // launcher cmd_notify), fetched once per expand -- there is no live profile to Chat
      // with, so this is the only way left to show what to run to pick the conversation
      // back up. Fetched lazily (not for every row up front) since it's a process per row.
      property var runinfo: ({ log: "", resume: "" })
      Process {
        id: runinfoProc
        stdout: StdioCollector { id: runinfoOut; waitForEnd: true }
        onExited: {
          try { rowItem.runinfo = JSON.parse(String(runinfoOut.text || "{}")) }
          catch (e) { rowItem.runinfo = ({ log: "", resume: "" }) }
        }
      }
      onIsOpenChanged: {
        if (isOpen && tab.isForgottenDelegate(row) && row.agent && !runinfoProc.running) {
          runinfoProc.command = [dash.launcher, "notify", "runinfo", row.agent]
          runinfoProc.running = true
        }
      }

      width: inner.width
      hasCursor: dash.cursorActive && dash.tab === "notifications" && dash.selectedIndex === globalIndex
      foreground: dash.foreground
      implicitHeight: body.implicitHeight + Style.space(16)

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onContainsMouseChanged: if (containsMouse) { dash.cursorActive = true; dash.selectedIndex = rowItem.globalIndex }
        onClicked: tab.toggleExpand(rowItem.row)
      }

      Column {
        id: body
        anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(12); anchors.rightMargin: Style.space(12)
        spacing: Style.spacing.xs

        Item {
          width: parent.width
          height: Math.max(glyph.implicitHeight, titleLine.implicitHeight, rightSlot.implicitHeight)
          Text {
            id: glyph
            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            text: tab.levelGlyph(rowItem.row)
            color: tab.isBlockerRow(rowItem.row) ? dash.urgent : dash.warnColor
            font.family: dash.fontFamily; font.pixelSize: Style.font.iconLarge
          }
          // A money decision stays one click away: an open cost request shows Approve/Decline
          // right on the collapsed row (same slot the age used to sit in), not only after
          // expanding. Every other row just shows its age, same as before.
          Item {
            id: rightSlot
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            implicitWidth: tab.isApproval(rowItem.row) ? approvalRow.implicitWidth : age.implicitWidth
            implicitHeight: tab.isApproval(rowItem.row) ? approvalRow.implicitHeight : age.implicitHeight
            width: implicitWidth; height: implicitHeight
            Text {
              id: age
              visible: !tab.isApproval(rowItem.row)
              anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              text: tab.ageText(rowItem.row)
              color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
            }
            Row {
              id: approvalRow
              visible: tab.isApproval(rowItem.row)
              anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm
              Button {
                text: tab.approveLabel(rowItem.row); iconText: "󰄬"; selected: true; foreground: dash.foreground; fontFamily: dash.fontFamily
                tooltipText: "Approves this spend now; the harness runs the node on the metered backend."
                onClicked: tab.approve(rowItem.row)
              }
              Button {
                text: "Decline"; iconText: "󰅖"; foreground: dash.urgent; fontFamily: dash.fontFamily
                tooltipText: "Declines this spend; the harness will not run the node on this metered backend."
                onClicked: tab.decline(rowItem.row)
              }
            }
          }
          Text {
            id: titleLine
            anchors.left: glyph.right; anchors.leftMargin: Style.space(12)
            anchors.right: rightSlot.left; anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: tab.titleText(rowItem.row)
            color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.subtitle; font.bold: true
          }
        }

        Column {
          width: parent.width
          visible: rowItem.isOpen
          topPadding: Style.space(6)
          spacing: Style.spacing.sm

          Text {
            width: parent.width; wrapMode: Text.Wrap
            text: "What: " + ((rowItem.row && rowItem.row.detail) || (rowItem.row && rowItem.row.message) || "")
            color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.body
          }
          Text {
            width: parent.width; wrapMode: Text.Wrap
            visible: !!(rowItem.row && rowItem.row.why)
            text: "Why: " + (rowItem.row ? rowItem.row.why : "")
            color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.body
          }
          Text {
            width: parent.width; wrapMode: Text.Wrap
            visible: !!(rowItem.row && rowItem.row.recommend)
            text: "Recommendation: " + (rowItem.row ? rowItem.row.recommend : "")
            color: dash.accent; font.family: dash.fontFamily; font.pixelSize: Style.font.body
          }
          Text {
            width: parent.width; wrapMode: Text.Wrap
            color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
            text: {
              var r = rowItem.row; if (!r) return ""
              var bits = ["source " + (r.source || "launcher")]
              if (r.ref) bits.push("ref " + r.ref)
              if (r.key) bits.push("key " + r.key)
              if (r.ts) bits.push("first seen " + String(r.ts).replace("T", " ").slice(0, 19))
              return bits.join("  ·  ")
            }
          }
          Text {
            width: parent.width; wrapMode: Text.Wrap
            visible: tab.isForgottenDelegate(rowItem.row) && !!rowItem.runinfo.resume
            text: "Resume: " + rowItem.runinfo.resume + "  (run this yourself in a terminal -- its saved profile is gone, so the dashboard can't reopen it for you)"
            color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
          }

          Row {
            spacing: Style.spacing.sm
            Button {
              text: "Chat"; iconText: "󰭹"; selected: true; foreground: dash.foreground; fontFamily: dash.fontFamily
              tooltipText: "Opens " + ((rowItem.row && rowItem.row.agent) || "the agent") + "'s chat window."
              visible: !tab.isApproval(rowItem.row) && !tab.isForgottenDelegate(rowItem.row)
              onClicked: dash.chat(rowItem.row.agent)
            }
            Button {
              text: "View run log"; iconText: "󰈙"; foreground: dash.foreground; fontFamily: dash.fontFamily
              tooltipText: "Opens this delegate's saved run log; it was cleaned up and has no live chat window."
              visible: tab.isForgottenDelegate(rowItem.row)
              onClicked: tab.viewRunLog(rowItem.row)
            }
            Button {
              text: "Open in Projects"; iconText: "󰙅"; foreground: dash.foreground; fontFamily: dash.fontFamily
              tooltipText: "Opens the Projects tab filtered to this project" + ((rowItem.row && rowItem.row.node) ? " and selects " + rowItem.row.node + "." : ".")
              visible: !!(rowItem.row && (rowItem.row.project || rowItem.row.node))
              onClicked: tab.openInProjects(rowItem.row)
            }
            Button {
              text: tab.approveLabel(rowItem.row); iconText: "󰄬"; selected: true; foreground: dash.foreground; fontFamily: dash.fontFamily
              tooltipText: "Approves this spend now; the harness runs the node on the metered backend."
              visible: tab.isApproval(rowItem.row)
              onClicked: tab.approve(rowItem.row)
            }
            Button {
              text: "Decline"; iconText: "󰅖"; foreground: dash.urgent; fontFamily: dash.fontFamily
              tooltipText: "Declines this spend; the harness will not run the node on this metered backend."
              visible: tab.isApproval(rowItem.row)
              onClicked: tab.decline(rowItem.row)
            }
            Button {
              text: "Hand to Rix"; iconText: "󰬐"; foreground: dash.foreground; fontFamily: dash.fontFamily
              tooltipText: "Creates a task for Rix from this notification and opens Rix's chat. Does not dismiss it."
              onClicked: tab.handToRix(rowItem.row)
            }
            Button {
              text: "Dismiss"; iconText: "󰅖"; foreground: dash.foreground; fontFamily: dash.fontFamily
              tooltipText: tab.isBlockerRow(rowItem.row) ? "Clears this blocker. Nothing is sent to the agent." : "Hides this notification. Nothing is sent to the agent."
              onClicked: tab.dismiss(rowItem.row)
            }
          }
        }
      }
    }
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(10)

    PanelHero {
      width: parent.width
      title: "Notifications"
      meta: tab.rowCount === 0 ? "Nothing needs you right now" : (tab.blockerList.length + " blocker" + (tab.blockerList.length === 1 ? "" : "s") + " waiting")
      foreground: dash.foreground; fontFamily: dash.fontFamily
      iconComponent: Component { Text { text: "󰂚"; color: tab.blockerList.length ? dash.urgent : dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.display } }
    }
    Text {
      width: parent.width; wrapMode: Text.Wrap
      text: "Click a notification for details. Dismiss hides it; Hand to Rix creates a task for Rix; Approve/Decline decide a metered spend."
      color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
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
          delegate: notifRowDelegate
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
        PanelSectionHeader { text: "RECENT"; foreground: dash.foreground; fontFamily: dash.fontFamily }
        Text { visible: tab.warnings.length === 0; text: "No recent warnings."; color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.body }
        Repeater {
          model: tab.warnings
          delegate: notifRowDelegate
        }
        Item { width: 1; height: Style.space(8) }
      }
    }
  }
}
