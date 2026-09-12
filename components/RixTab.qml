import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Rix page: the chief of staff. Top: Rix's state, Chat, a plain brief,
// and a one-question box answered by Rix's own model. Then the numbers
// (prompt / output tokens and USD, total and today), the backends Rix can
// hand work to (with the Modal GPU picker), and every task with its tokens
// and cost. All data comes from `status --json` (dash.status); actions run
// the launcher with argv. Long Modal operations open in a terminal (--popup).
Item {
  id: tab
  required property var dash

  readonly property var rix: dash.status && dash.status.rix ? dash.status.rix : null
  readonly property var usage: dash.usage
  readonly property var totals: usage ? usage.totals : null
  readonly property var backends: dash.status && dash.status.backends ? dash.status.backends : []
  readonly property var modal: dash.status && dash.status.modal ? dash.status.modal : null
  readonly property var info: setupInfo            // `info --json`, for the GPU table
  property var setupInfo: null
  readonly property var launcher: dash.launcher

  // ---- Dashboard contract -------------------------------------------------
  readonly property int rowCount: tasks.length
  readonly property bool editing: askField.activeFocus || addForm.editing
  readonly property bool popupOpen: modelPick.popupOpen || taskAgentDrop.popupOpen || addForm.popupOpen || confirm.opened || switchConfirm.opened
  function activate(i) { if (tasks[i]) dash.chat(tasks[i].agent) }

  // ---- tasks table --------------------------------------------------------
  property string sortKey: "last"
  property bool sortAsc: false
  property string taskAgent: ""
  readonly property var tasks: sortedTasks()
  function sortedTasks() {
    if (!usage) return []
    var out = usage.tasks.filter(function(t) { return taskAgent === "" || t.agent === taskAgent }).slice(0, 300)
    var k = sortKey, asc = sortAsc
    out.sort(function(a, b) {
      var x = a[k], y = b[k]
      if (typeof x === "number" || typeof y === "number" || k === "cost_usd") { x = Number(x || 0); y = Number(y || 0); return asc ? x - y : y - x }
      x = String(x || "").toLowerCase(); y = String(y || "").toLowerCase()
      if (x === y) return b.last - a.last
      return asc ? (x < y ? -1 : 1) : (x < y ? 1 : -1)
    })
    return out
  }
  function setSort(k) { if (sortKey === k) sortAsc = !sortAsc; else { sortKey = k; sortAsc = (k === "agent" || k === "title" || k === "model") } }
  function fmtTime(t) {
    if (!t) return ""
    var d = new Date(t * 1000)
    function two(n) { return (n < 10 ? "0" : "") + n }
    var today = new Date(); var sameDay = d.toDateString() === today.toDateString()
    return (sameDay ? "" : two(d.getMonth() + 1) + "-" + two(d.getDate()) + " ") + two(d.getHours()) + ":" + two(d.getMinutes())
  }
  readonly property var agentOptions: {
    var seen = {}, out = [{ value: "", label: "All agents" }]
    if (usage) for (var i = 0; i < usage.agents.length; i++) out.push({ value: usage.agents[i].name, label: usage.agents[i].name })
    return out
  }

  // ---- backends -----------------------------------------------------------
  // Ready backends, plus the local GPU even when it is not ready yet: it is the default and must stay visible.
  // ---- model picker (what Rix runs on) --------------------------------------
  property var modelTree: null        // `models --json`
  property string keyHint: ""          // shown when a vendor without a key is chosen
  property string pendingLocal: ""     // local model file waiting for the switch confirmation
  function loadModels() { if (modelsProc.running) return; modelsProc.command = [launcher, "models", "--json"]; modelsProc.running = true }
  Process {
    id: modelsProc
    stdout: StdioCollector { id: modelsOut; waitForEnd: true }
    onExited: function(code) { if (code === 0) { try { tab.modelTree = JSON.parse(String(modelsOut.text || "")) } catch (e) {} } }
  }
  Timer { id: modelsRefresh; interval: 2500; onTriggered: tab.loadModels() }
  function pickModel(backend, model) {
    keyHint = ""
    var served = modelTree && modelTree.local ? modelTree.local.served : ""
    if (backend === "local" && served !== "" && model !== served) { pendingLocal = model; switchConfirm.opened = true; return }
    if (backend === "local") dash.act([launcher, "rix", "setup", "local"])
    else dash.act([launcher, "rix", "setup", backend, model])
    modelsRefresh.restart()
  }
  function switchLocal() {
    var loc = info && info.local ? info.local : null
    var argv = ["local-server", "tune", "--model", pendingLocal]
    if (loc && loc.n_ctx > 0) argv.push("--ctx", String(loc.n_ctx))
    if (loc && loc.slots > 0) argv.push("--slots", String(loc.slots))
    if (!rix || rix.backend !== "local") dash.act([launcher, "rix", "setup", "local"])
    popup(argv)
    pendingLocal = ""
    modelsRefresh.restart()
  }
  readonly property var customBackends: backends.filter(function(b) { return b.kind !== "provider" })
  readonly property var providerBackends: backends.filter(function(b) { return b.kind === "provider" })
  property string pendingRemove: ""
  function popup(argv) { Quickshell.execDetached([launcher, "--popup"].concat(argv)); dash.refreshSoon() }

  // ---- brief & ask (Rix's own answers) ---------------------------------
  property string brief: ""
  property string answer: ""
  property bool asking: false
  property bool briefing: false
  function runBrief() { if (briefProc.running) return; briefing = true; briefProc.command = [launcher, "rix", "brief"]; briefProc.running = true }
  function ask() {
    var q = askField.text.trim()
    if (q === "" || askProc.running) return
    asking = true; answer = ""
    askProc.command = [launcher, "rix", "ask", q]
    askProc.running = true
  }
  Process {
    id: briefProc
    stdout: StdioCollector { id: briefOut; waitForEnd: true }
    stderr: StdioCollector { id: briefErr; waitForEnd: true }
    onExited: function(code) { tab.briefing = false; tab.brief = code === 0 ? String(briefOut.text || "").trim() : ("brief failed: " + String(briefErr.text || "").trim()) }
  }
  Process {
    id: askProc
    stdout: StdioCollector { id: askOut; waitForEnd: true }
    stderr: StdioCollector { id: askErr; waitForEnd: true }
    onExited: function(code) {
      tab.asking = false
      var out = String(askOut.text || "").trim()
      tab.answer = code === 0 && out !== "" ? out : ("Rix could not answer (exit " + code + "): " + String(askErr.text || "").trim().split("\n").slice(-3).join(" "))
      dash.refreshSoon()
    }
  }
  function loadInfo() { if (infoProc.running) return; infoProc.command = [launcher, "info", "--json"]; infoProc.running = true }
  Process {
    id: infoProc
    stdout: StdioCollector { id: infoOut; waitForEnd: true }
    onExited: function(code) { if (code === 0) { try { tab.setupInfo = JSON.parse(String(infoOut.text || "")) } catch (e) {} } }
  }
  Connections { target: dash; function onOpenedChanged() { if (dash.opened) { if (!tab.setupInfo) tab.loadInfo(); tab.loadModels() } } }
  Component.onCompleted: if (dash.opened) tab.loadModels()

  // Table pieces (inline components must sit at the root of the file).
  component HeaderCell: Text {
    property string key: ""
    property string label: ""
    property real w: Style.space(80)
    width: w; textFormat: Text.PlainText
    text: label + (tab.sortKey === key ? (tab.sortAsc ? " ▲" : " ▼") : "")
    color: tab.sortKey === key ? dash.foreground : dash.dim
    font.family: dash.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
    elide: Text.ElideRight
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: tab.setSort(parent.key) }
  }
  component Cell: Text { textFormat: Text.PlainText; color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight }
  component Cap: Text {
    textFormat: Text.PlainText
    color: Qt.darker(dash.foreground, 1.4)
    font.family: dash.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
  }
  component Dim: Text { textFormat: Text.PlainText; color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
  component Body: Text { textFormat: Text.PlainText; color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.Wrap }
  component Field: TextField {
    foreground: dash.foreground; font.family: dash.fontFamily
    verticalPadding: Style.spacing.controlPaddingY
    Keys.onEscapePressed: function(event) { dash.focusCatcher(); event.accepted = true }
  }

  // A headline number. Text wears text tokens; nothing is color-coded.
  component StatTile: BorderSurface {
    id: tile
    property string label: ""
    property string value: ""
    property string note: ""
    radius: Style.cornerRadius
    color: Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.04)
    borderSpec: Border.flat(Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.10), 1)
    implicitHeight: tileCol.implicitHeight + Style.space(20)
    Column {
      id: tileCol
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(12)
      spacing: Style.spacing.xxs
      Cap { text: tile.label }
      Text { textFormat: Text.PlainText; text: tile.value; color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.display; font.bold: true }
      Dim { width: parent.width; text: tile.note; elide: Text.ElideRight; wrapMode: Text.NoWrap }
    }
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(10)

    PanelHero {
      width: parent.width
      title: "Rix"
      meta: !tab.rix ? "Loading…"
            : !tab.rix.configured ? "Your chief of staff is not set up yet. Chat sets it up on " + (tab.rix.default_backend === "local" ? "your local GPU (offline, $0)" : tab.rix.default_backend) + "."
            : "Chief of staff on " + tab.rix.backend + " / " + tab.rix.model + "  ·  " + (tab.rix.running ? "running" : "idle") + (tab.rix.workers.length ? "  ·  " + tab.rix.workers.length + " worker" + (tab.rix.workers.length === 1 ? "" : "s") : "")
      foreground: dash.foreground; fontFamily: dash.fontFamily
      iconComponent: Component { Text { text: "󰚩"; color: tab.rix && tab.rix.running ? dash.okColor : dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.display } }
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

        // ---- Rix controls ------------------------------------------
        Row {
          width: parent.width; spacing: Style.spacing.controlGap
          Button { text: tab.rix && tab.rix.configured ? "Chat with Rix" : "Set up and chat"; iconText: "󰭹"; selected: true; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: dash.act([tab.launcher, "rix", "chat"]) }
          Button { text: tab.briefing ? "Briefing…" : "Brief"; iconText: "󰈙"; enabled: !tab.briefing; tooltipText: "Plain status brief from the launcher's data (no model call)"; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: tab.runBrief() }
          PanelActionButton { iconText: "󰓛"; tooltipText: "Stop Rix's session"; visible: tab.rix && tab.rix.running; hoverColor: dash.urgent; onClicked: dash.act([tab.launcher, "stop", tab.rix.name]) }
          Item { width: Style.space(12); height: 1 }
          Cap { text: "RUNS ON"; anchors.verticalCenter: parent.verticalCenter }
          ModelPicker {
            id: modelPick
            width: Style.space(360)
            tree: tab.modelTree
            backend: tab.rix ? tab.rix.backend : ""
            model: tab.rix ? tab.rix.model : ""
            popupParent: tab
            ownerOpen: dash.opened && dash.tab === "rix"
            foreground: dash.foreground; urgent: dash.urgent; fontFamily: dash.fontFamily
            onPicked: function(b, m) { tab.pickModel(b, m) }
            onNeedsKey: function(b, label, needs) { tab.keyHint = label + ": " + (needs || "needs a key or sign-in") + ". Add it on the New agent page, then pick the model again." }
          }
        }
        Row {
          width: parent.width; spacing: Style.spacing.controlGap
          visible: tab.keyHint !== ""
          Dim { anchors.verticalCenter: parent.verticalCenter; text: tab.keyHint; color: dash.urgent }
          Button { text: "New agent page"; iconText: ""; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: { tab.keyHint = ""; dash.selectTab("new") } }
        }
        Dim { width: parent.width; text: "Rix is a Hermes agent on this machine that manages every other agent through the launcher: it reads status and usage, hands work to bigger models with delegate, reads results, and can stop or remove agents. It asks before spending money." }

        BorderSurface {
          width: parent.width
          visible: tab.brief !== ""
          radius: Style.cornerRadius
          color: Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.04)
          borderSpec: Border.flat(Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.10), 1)
          implicitHeight: briefText.implicitHeight + Style.space(20)
          Text { id: briefText; anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; anchors.margins: Style.space(12); textFormat: Text.PlainText; text: tab.brief; color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.Wrap }
        }

        Column {
          width: parent.width; spacing: Style.spacing.labelGap
          Cap { text: "ASK RIX" + (tab.rix && tab.rix.configured ? "  ·  answered by " + tab.rix.backend + " / " + tab.rix.model : "") }
          Row {
            width: parent.width; spacing: Style.spacing.controlGap
            Field {
              id: askField
              width: parent.width - askButton.width - parent.spacing
              enabled: !tab.asking
              placeholderText: "What is everyone working on? What did today cost? Hand the release notes to a bigger model…"
              Keys.onReturnPressed: tab.ask()
            }
            Button { id: askButton; text: tab.asking ? "Thinking…" : "Ask"; iconText: "󰚩"; selected: true; enabled: !tab.asking; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: tab.ask() }
          }
          Body { width: parent.width; visible: tab.answer !== ""; text: tab.answer }
        }

        // ---- the numbers ----------------------------------------------
        Item { width: 1; height: Style.space(4) }
        PanelSectionHeader { text: "TOKENS AND COST  ·  " + (tab.totals ? tab.totals.sessions + " task" + (tab.totals.sessions === 1 ? "" : "s") + " across " + tab.totals.agents + " agent" + (tab.totals.agents === 1 ? "" : "s") : ""); foreground: dash.foreground; fontFamily: dash.fontFamily }
        Row {
          id: tiles
          width: parent.width; spacing: Style.space(10)
          readonly property real w: (width - spacing * 3) / 4
          StatTile { width: tiles.w; label: "PROMPT TOKENS"; value: tab.totals ? dash.fmtK(tab.totals.prompt) : "–"; note: tab.totals ? dash.fmtK(tab.totals.input) + " input · " + dash.fmtK(tab.totals.cache_read) + " cache read · " + dash.fmtK(tab.totals.cache_write) + " cache write" : "" }
          StatTile { width: tiles.w; label: "OUTPUT TOKENS"; value: tab.totals ? dash.fmtK(tab.totals.output) : "–"; note: tab.totals ? (tab.totals.reasoning ? dash.fmtK(tab.totals.reasoning) + " reasoning · " : "") + "today " + dash.fmtK(tab.totals.today_output) : "" }
          StatTile { width: tiles.w; label: "COST (USD)"; value: tab.totals ? dash.fmtUsd(tab.totals.cost_usd) : "–"; note: tab.totals ? "today " + dash.fmtUsd(tab.totals.today_cost_usd) + (tab.totals.gpu_cost_usd ? " · GPU time " + dash.fmtUsd(tab.totals.gpu_cost_usd) : "") + (tab.totals.cost_unknown ? " · " + tab.totals.cost_unknown + " unpriced" : "") : "" }
          StatTile { width: tiles.w; label: "TODAY"; value: tab.totals ? dash.fmtK(tab.totals.today_prompt + tab.totals.today_output) : "–"; note: tab.totals ? dash.fmtK(tab.totals.today_prompt) + " prompt · " + dash.fmtK(tab.totals.today_output) + " output tokens" : "" }
        }
        Dim { width: parent.width; text: "Prompt = input + cache read + cache write, as the provider bills it. Costs come from Hermes' own per-session estimate, else models.dev prices, else the backend's price, else GPU time; the local GPU is $0. Each row says which." }

        // ---- backends -------------------------------------------------
        Item { width: 1; height: Style.space(4) }
        PanelSectionHeader { text: "BACKENDS  ·  where work can go"; foreground: dash.foreground; fontFamily: dash.fontFamily }
        Dim {
          width: parent.width
          text: !tab.modal ? "" : (tab.modal.installed ? (tab.modal.authed ? "Modal CLI installed and signed in. " : "Modal CLI installed; sign in with  modal setup  (or the button below). ") : "For Modal backends install the CLI:  pipx install modal   then  modal setup. ")
                + "Dedicated endpoints scale to zero after the idle window; sandboxes are billed from start to stop. GPU prices from modal.com/pricing" + (tab.info && tab.info.gpus ? " as of " + tab.info.gpus.prices_date : "") + "."
        }
        Repeater {
          model: tab.customBackends
          delegate: BackendRow { required property var modelData; width: inner.width; backend: modelData }
        }
        Row {
          width: parent.width; spacing: Style.spacing.controlGap
          Button { text: addForm.visible ? "Hide form" : "Add backend"; iconText: ""; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: { addForm.visible = !addForm.visible; if (addForm.visible && !tab.setupInfo) tab.loadInfo() } }
          Button { visible: tab.modal && tab.modal.installed && !tab.modal.authed; text: "Sign in to Modal"; iconText: "󰌾"; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: tab.popup(["modal", "setup"]) }
        }
        BackendForm { id: addForm; width: parent.width; visible: false; dash: dash; gpus: tab.info && tab.info.gpus ? tab.info.gpus.gpus : []; onAdded: { visible = false; dash.refreshStatus(); tab.loadInfo() } }

        Cap { text: "PROVIDERS  ·  API key or browser sign-in" }
        Flow {
          width: parent.width; spacing: Style.spacing.sm
          Repeater {
            model: tab.providerBackends
            delegate: Dim {
              required property var modelData
              text: modelData.label + "  ·  " + (modelData.ready ? modelData.state : modelData.state)
              color: modelData.ready ? dash.foreground : dash.dim
            }
          }
        }

        // ---- tasks ----------------------------------------------------
        Item { width: 1; height: Style.space(4) }
        Row {
          width: parent.width; spacing: Style.spacing.controlGap
          PanelSectionHeader { text: "PER TASK  ·  one row per agent session"; foreground: dash.foreground; fontFamily: dash.fontFamily; anchors.verticalCenter: parent.verticalCenter }
          Item { width: Style.space(8); height: 1 }
          PanelDropdown {
            id: taskAgentDrop
            width: Style.space(220)
            showLabel: false
            options: tab.agentOptions
            value: tab.taskAgent
            popupParent: tab
            ownerOpen: dash.opened && dash.tab === "rix"
            foreground: dash.foreground; fontFamily: dash.fontFamily
            onChanged: function(v) { tab.taskAgent = v }
          }
        }
        Row {
          id: header
          width: parent.width; spacing: Style.space(8)
          readonly property real fixed: Style.space(64) + Style.space(110) + Style.space(90) + Style.space(90) + Style.space(80) + Style.space(150) + spacing * 7
          readonly property real titleW: Math.max(Style.space(120), width - fixed - Style.space(150))
          HeaderCell { key: "last"; label: "WHEN"; w: Style.space(64) }
          HeaderCell { key: "agent"; label: "AGENT"; w: Style.space(110) }
          HeaderCell { key: "title"; label: "TASK"; w: header.titleW }
          HeaderCell { key: "model"; label: "MODEL"; w: Style.space(150) }
          HeaderCell { key: "prompt"; label: "PROMPT"; w: Style.space(90) }
          HeaderCell { key: "output"; label: "OUTPUT"; w: Style.space(90) }
          HeaderCell { key: "cost_usd"; label: "USD"; w: Style.space(80) }
        }
        Dim { width: parent.width; visible: tab.tasks.length === 0; text: "No sessions recorded yet. Usage appears here after the first agent session (Hermes agents; OpenClaw keeps no session store)." }
        Repeater {
          model: tab.tasks
          delegate: CursorSurface {
            required property var modelData
            required property int index
            width: inner.width
            hasCursor: dash.cursorActive && dash.tab === "rix" && dash.selectedIndex === index
            foreground: dash.foreground
            implicitHeight: trow.implicitHeight + Style.space(10)
            MouseArea {
              anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.ArrowCursor
              onContainsMouseChanged: if (containsMouse) { dash.cursorActive = true; dash.selectedIndex = index }
              onDoubleClicked: dash.chat(modelData.agent)
            }
            Row {
              id: trow
              anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)
              Cell { width: Style.space(64); text: tab.fmtTime(modelData.last); color: dash.dim }
              Cell { width: Style.space(110); text: modelData.agent }
              Column {
                width: header.titleW; spacing: 0
                Cell { width: parent.width; text: modelData.title }
                Dim { width: parent.width; text: modelData.cost_basis + (modelData.cache_read ? "  ·  " + dash.fmtK(modelData.cache_read) + " cached" : ""); wrapMode: Text.NoWrap; elide: Text.ElideRight }
              }
              Cell { width: Style.space(150); text: modelData.model; color: dash.dim }
              Cell { width: Style.space(90); text: dash.fmtK(modelData.prompt) }
              Cell { width: Style.space(90); text: dash.fmtK(modelData.output) }
              Cell { width: Style.space(80); text: dash.fmtUsd(modelData.cost_usd) }
            }
          }
        }
        Item { width: 1; height: Style.space(8) }
      }
    }
  }

  // One configured backend (endpoint / Modal) with its state and actions.
  component BackendRow: CursorSurface {
    id: brow
    property var backend: null
    foreground: dash.foreground
    hasCursor: false
    implicitHeight: bbody.implicitHeight + Style.space(14)
    Row {
      id: bbody
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12); anchors.rightMargin: Style.space(8)
      spacing: Style.space(12)
      Text { text: brow.backend && brow.backend.kind === "endpoint" ? "󰖟" : "󰢮"; color: brow.backend && brow.backend.ready ? dash.okColor : dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.iconLarge; anchors.verticalCenter: parent.verticalCenter }
      Column {
        width: parent.width - bactions.width - parent.spacing * 2 - Style.space(24)
        spacing: Style.spacing.xxs
        Row {
          spacing: Style.spacing.rowGap
          Text { text: brow.backend ? brow.backend.label : ""; color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.subtitle; font.bold: true; anchors.verticalCenter: parent.verticalCenter }
          StatusPill { status: brow.backend ? (brow.backend.state === "ready" ? "running" : (brow.backend.state === "error" ? "blocked" : brow.backend.state)) : "idle"; foreground: dash.foreground; fontFamily: dash.fontFamily; anchors.verticalCenter: parent.verticalCenter }
        }
        Dim {
          width: parent.width; elide: Text.ElideRight; wrapMode: Text.NoWrap
          text: brow.backend ? (brow.backend.kind + " · " + brow.backend.model + (brow.backend.gpu ? " · " + brow.backend.gpu + " ×" + brow.backend.gpu_count + " · $" + (Math.round(brow.backend.gpu_hourly * brow.backend.gpu_count * 100) / 100) + "/h while running" : "") + (brow.backend.model_ctx ? " · " + dash.fmtK(brow.backend.model_ctx) + " ctx" : "") + (brow.backend.url ? "  ·  " + brow.backend.url : "")) : ""
        }
      }
      Row {
        id: bactions
        spacing: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        Button { visible: brow.backend && brow.backend.kind !== "endpoint" && brow.backend.state !== "ready" && brow.backend.state !== "starting"; text: brow.backend && brow.backend.kind === "modal-sandbox" ? "Start" : "Deploy"; iconText: "󰐊"; selected: true; tooltipText: "Runs in a terminal: image build and model download take minutes; GPU time is billed from here on"; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: tab.popup(["backends", "deploy", brow.backend.id]) }
        PanelActionButton { iconText: "󰓛"; tooltipText: "Stop (Modal: stop the app / terminate the sandbox)"; visible: brow.backend && brow.backend.kind !== "endpoint" && brow.backend.state === "ready"; hoverColor: dash.urgent; onClicked: tab.popup(["backends", "stop", brow.backend.id]) }
        PanelActionButton { iconText: "󰄬"; tooltipText: "Test: GET /v1/models with the backend's key"; visible: brow.backend && brow.backend.url; onClicked: tab.popup(["backends", "test", brow.backend.id]) }
        PanelActionButton { iconText: "󰚩"; tooltipText: "Run Rix on this backend"; visible: brow.backend && brow.backend.ready; onClicked: dash.act([tab.launcher, "rix", "setup", brow.backend.id]) }
        PanelActionButton { iconText: "󰩺"; tooltipText: "Remove this backend (stop it first)"; hoverColor: dash.urgent; onClicked: { tab.pendingRemove = brow.backend.id; confirm.opened = true } }
      }
    }
  }

  ConfirmDialog {
    id: confirm
    anchors.fill: parent
    message: "Remove backend '" + tab.pendingRemove + "'? Its key is forgotten; a running Modal app or sandbox is NOT stopped by this (use Stop first)."
    confirmText: "Remove"
    foreground: dash.foreground; fontFamily: dash.fontFamily
    onConfirmed: { opened = false; dash.act([tab.launcher, "backends", "remove", tab.pendingRemove]); tab.pendingRemove = "" }
    onCanceled: { opened = false; tab.pendingRemove = "" }
  }
  ConfirmDialog {
    id: switchConfirm
    anchors.fill: parent
    message: "Switch the local GPU server to " + String(tab.pendingLocal).replace(/\.gguf$/, "") + "? The server restarts with that model (about a minute); agents using it pause until it is back."
    confirmText: "Switch"
    foreground: dash.foreground; fontFamily: dash.fontFamily
    onConfirmed: { opened = false; tab.switchLocal() }
    onCanceled: { opened = false; tab.pendingLocal = "" }
  }
}
