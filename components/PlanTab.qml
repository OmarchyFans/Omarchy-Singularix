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

  // ---- staleness (a FileView reload can race a non-atomic write of a
  // partial JSON file; keep the last good snapshot and show a small marker
  // instead of blanking the board) ---------------------------------------
  property real lastGoodAt: 0
  property bool stale: false
  property int staleTick: 0
  Timer { interval: 1000; repeat: true; running: tab.stale; onTriggered: tab.staleTick++ }
  readonly property int staleSeconds: { var _t = tab.staleTick; return tab.lastGoodAt > 0 ? Math.max(0, Math.round((Date.now() - tab.lastGoodAt) / 1000)) : 0 }

  readonly property var projects: overview && overview.projects ? overview.projects : []
  readonly property var sessions: overview && overview.sessions ? overview.sessions : []
  readonly property var queueAll: overview && overview.queue ? overview.queue : []

  // ---- roles/model policy lookups (Wave 6, CONTRACTS.md §17.5-17.7) ---------
  // Short model label: strip a "vendor:" hop prefix, a folded-in "claude-"
  // vendor prefix, and a trailing date suffix. Everything else (gpt-5.4-codex,
  // deepseek-v4-flash) is a model family name, not a vendor prefix -- leave it.
  function shortModel(m) {
    var s = String(m || "").trim()
    if (s === "") return ""
    var colon = s.indexOf(":")
    if (colon >= 0) s = s.slice(colon + 1)
    s = s.replace(/^claude-/, "")
    s = s.replace(/-\d{4}-?\d{2}-?\d{2}$/, "")
    return s
  }

  // sid -> session, built once per overview change (not per-row).
  function sessionByIdMap() {
    var m = {}
    for (var i = 0; i < sessions.length; i++) { var s = sessions[i]; if (s && s.id !== undefined) m[String(s.id)] = s }
    return m
  }
  readonly property var sessionById: sessionByIdMap()

  // {project: {node: waveIndex}}, from projects[].waves (optional, older
  // harness omits it -- every lookup below falls back to -1/"not in a wave").
  function waveIndexMap() {
    var m = {}
    for (var i = 0; i < projects.length; i++) {
      var p = projects[i]
      var waves = (p && p.waves) || []
      var pm = {}
      for (var w = 0; w < waves.length; w++) {
        var arr = waves[w] || []
        for (var j = 0; j < arr.length; j++) pm[String(arr[j])] = w
      }
      m[p.id] = pm
    }
    return m
  }
  readonly property var waveIndexByProject: waveIndexMap()
  function waveOf(row) {
    if (!row) return -1
    var pm = tab.waveIndexByProject[row.project]
    if (!pm) return -1
    var w = pm[String(row.node)]
    return w === undefined ? -1 : w
  }

  // sid of the session named by any project's `orchestrator.kind === "session"`.
  function orchestratorSessionIdSet() {
    var s = {}
    for (var i = 0; i < projects.length; i++) {
      var o = projects[i] && projects[i].orchestrator
      if (o && o.kind === "session" && o.id !== undefined) s[String(o.id)] = true
    }
    return s
  }
  readonly property var orchestratorSessionIds: orchestratorSessionIdSet()

  // Model for a queue row: the row's own field (future-proofing), else the
  // closing attempt's model (`performed_by`, done rows a harness may still
  // list briefly), else the assignee session's registered model. Never
  // invented -- "" when none of those exist.
  function rowModel(row) {
    if (!row) return ""
    if (row.model) return String(row.model)
    if (row.performed_by && row.performed_by.model) return String(row.performed_by.model)
    if (row.assignee) {
      var s = tab.sessionById[String(row.assignee)]
      if (s && s.model) return String(s.model)
    }
    return ""
  }
  function rowVendor(row) {
    if (!row) return ""
    if (row.vendor) return String(row.vendor)
    if (row.performed_by && row.performed_by.vendor) return String(row.performed_by.vendor)
    if (row.assignee) {
      var s = tab.sessionById[String(row.assignee)]
      if (s && s.vendor) return String(s.vendor)
    }
    return ""
  }
  function rowCostClass(row) {
    if (!row) return ""
    if (row.cost_class) return String(row.cost_class)
    if (row.assignee) {
      var s = tab.sessionById[String(row.assignee)]
      if (s && s.cost_class) return String(s.cost_class)
    }
    return ""
  }

  // Every open approval request across every project, plus a synthetic row
  // for a budget overrun (which has no request id of its own). Always a
  // list of rows -- never a single-slot banner, since a project can have
  // several requests open (or none) at once. `pending_approval` (singular)
  // is kept server-side only for compat with older readers; here we read
  // the `pending_approvals` map and fall back to the singular field only
  // when the map itself is absent (an older/partial snapshot).
  function projectApprovalRows(p) {
    var rows = []
    var map = p.pending_approvals
    if (map && typeof map === "object") {
      for (var k in map) {
        var e = map[k]
        if (!e) continue
        rows.push({ kind: "approval", project: p.id, projectTitle: p.title || p.id, id: String(e.id || k), node: e.node, model: e.model, vendor: e.vendor, estimate_usd: e.estimate_usd, reason: e.reason, by: e.by, at: e.at })
      }
    } else if (p.pending_approval) {
      var e2 = p.pending_approval
      rows.push({ kind: "approval", project: p.id, projectTitle: p.title || p.id, id: String(e2.id || "legacy"), node: e2.node, model: e2.model, vendor: e2.vendor, estimate_usd: e2.estimate_usd, reason: e2.reason, by: e2.by, at: e2.at })
    }
    if (p.cost && Number(p.cost.overrun_usd || 0) > 0) {
      rows.push({ kind: "overrun", project: p.id, projectTitle: p.title || p.id, id: "overrun", node: null, model: null, vendor: null, estimate_usd: p.cost.overrun_usd, reason: "budget overrun", by: "", at: "" })
    }
    return rows
  }
  function approvalRowsAll() {
    var out = []
    for (var i = 0; i < projects.length; i++) out = out.concat(projectApprovalRows(projects[i]))
    return out
  }
  readonly property var approvalRows: approvalRowsAll()

  // ---- Dashboard contract -------------------------------------------------
  readonly property var flatRows: computeFlatRows()
  readonly property int rowCount: flatRows.length
  readonly property bool editing: false
  readonly property bool popupOpen: projectDrop.popupOpen || agentDrop.popupOpen || roleDrop.popupOpen || modelDrop.popupOpen
  function activate(i) { var n = flatRows[i]; if (n) selectRow(n) }

  // ---- keyboard shortcuts (routed from Dashboard.qml while dash.tab === "plan") --
  // NOTE: `cycleRoleFilter`/`cycleModelFilter` are wired up the same way as
  // `cycleProjectFilter`/`toggleCriticalOnly` (dash.planTabRef.<fn>() from
  // Dashboard.qml's PanelKeyCatcher.onTextKey) but Dashboard.qml is outside
  // this wave's file ownership -- see the wave report for the two lines the
  // lead needs to add (and why plain "r" collides with the global refresh key).
  function assignSelected() { if (tab.selectedRow) dash.act([dash.launcher, "harness", "assign", tab.selectedRow.project, tab.selectedRow.node]) }
  function cycleProjectFilter() {
    var opts = tab.projectOptionsList
    if (!opts.length) return
    var idx = 0
    for (var i = 0; i < opts.length; i++) if (opts[i].value === tab.projectFilter) { idx = i; break }
    tab.projectFilter = opts[(idx + 1) % opts.length].value
  }
  function cycleRoleFilter() {
    var opts = tab.roleOptionsList
    if (!opts.length) return
    var idx = 0
    for (var i = 0; i < opts.length; i++) if (opts[i].value === tab.roleFilter) { idx = i; break }
    tab.roleFilter = opts[(idx + 1) % opts.length].value
  }
  function cycleModelFilter() {
    var opts = tab.modelOptionsList
    if (!opts.length) return
    var idx = 0
    for (var i = 0; i < opts.length; i++) if (opts[i].value === tab.modelFilter) { idx = i; break }
    tab.modelFilter = opts[(idx + 1) % opts.length].value
  }
  function toggleCriticalOnly() { tab.criticalOnly = !tab.criticalOnly }

  // ---- filters --------------------------------------------------------------
  property string projectFilter: ""
  property string agentFilter: ""
  property string roleFilter: ""
  property string modelFilter: ""
  property bool criticalOnly: false
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

  // Role/model options are pooled from whatever data is on hand: queue rows'
  // own `role` field (when the harness sends it), and every session's
  // `role`/`model` -- so the dropdowns are never empty just because the
  // filtered project's rows don't carry the field themselves.
  function roleOptionsFn() {
    var seen = {}, out = [{ value: "", label: "All roles" }]
    function add(v) { v = String(v || ""); if (v !== "" && !seen[v]) { seen[v] = true; out.push({ value: v, label: v }) } }
    for (var i = 0; i < queueAll.length; i++) add(queueAll[i].role)
    for (var j = 0; j < sessions.length; j++) add(sessions[j].role)
    return out
  }
  readonly property var roleOptionsList: roleOptionsFn()

  function modelOptionsFn() {
    var seen = {}, out = [{ value: "", label: "All models" }]
    function add(v) { v = String(v || ""); if (v !== "" && !seen[v]) { seen[v] = true; out.push({ value: v, label: tab.shortModel(v) }) } }
    for (var i = 0; i < queueAll.length; i++) add(tab.rowModel(queueAll[i]))
    for (var j = 0; j < sessions.length; j++) add(sessions[j].model)
    return out
  }
  readonly property var modelOptionsList: modelOptionsFn()

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
        if (tab.criticalOnly && !q.critical) return false
        if (tab.roleFilter !== "" && String(q.role || "") !== tab.roleFilter) return false
        if (tab.modelFilter !== "" && tab.rowModel(q) !== tab.modelFilter) return false
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
    var residual = 0, blocked = 0, spent = 0, approved = 0, remaining = 0, reserved = 0, overrun = 0, dailySpent = 0, dailyCap = 0
    var wave0 = 0, nextWave = 0, eligibleIdle = 0, concurrencyWave0 = 0, hasWaves = false, hasConcurrency = false
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      residual += Number(p.residual || 0)
      blocked += Number(p.residual_blocked || 0)
      if (p.cost) {
        spent += Number(p.cost.spent_usd || 0)
        approved += Number(p.cost.approved_usd || 0)
        remaining += Number(p.cost.remaining_usd || 0)
        reserved += Number(p.cost.reserved_usd || 0)
        overrun += Number(p.cost.overrun_usd || 0)
        dailySpent += Number(p.cost.daily_spent_usd || 0)
        dailyCap += Number(p.cost.daily_cap_usd || 0)
      }
      if (p.waves) {
        hasWaves = true
        wave0 += ((p.waves[0]) || []).length
        nextWave += ((p.waves[1]) || []).length
      }
      if (p.concurrency) {
        hasConcurrency = true
        eligibleIdle += Number(p.concurrency.eligible_idle || 0)
        concurrencyWave0 += Number(p.concurrency.wave0 || 0)
      }
    }
    return { residual: residual, blocked: blocked, spent: spent, approved: approved, remaining: remaining, reserved: reserved, overrun: overrun, dailySpent: dailySpent, dailyCap: dailyCap,
             wave0: wave0, nextWave: nextWave, eligibleIdle: eligibleIdle, concurrencyWave0: concurrencyWave0, hasWaves: hasWaves, hasConcurrency: hasConcurrency }
  }
  readonly property var agg: aggregate()

  // Accepts epoch seconds or epoch milliseconds (the contract doesn't pin
  // the unit for `at`/`retry_at`; anything past year ~2033 in seconds is
  // almost certainly already milliseconds).
  function fmtHHMM(ts) {
    if (!ts) return "?"
    var n = Number(ts)
    if (!isFinite(n) || n <= 0) return "?"
    var ms = n > 2000000000 ? n : n * 1000
    var d = new Date(ms)
    function two(x) { return (x < 10 ? "0" : "") + x }
    return two(d.getHours()) + ":" + two(d.getMinutes())
  }
  function blockersLine(node) {
    if (!node) return "none"
    if (node.blockers && node.blockers.length) return node.blockers.join(", ")
    if (node.blockers_first) return "gates dependent work (blockers-first)"
    return "none"
  }
  function evidenceLine(node) {
    if (!node || node.state !== "done") return ""
    if (node.evidence) return String(node.evidence)
    var kind = node.evidence_kind || ""
    if (kind === "oracle_ok") return "closed by oracle ok"
    if (kind === "human_ack") return "closed by human ack"
    if (kind === "merged_pr") return "closed by merged PR"
    if (node.evidence_missing) return "no evidence on file"
    return ""
  }
  // Detail line for the inspector: role, ip_class (always shown -- unlabelled
  // means protected, §17.1), model, vendor, cost_class. Model/vendor/cost_class
  // are omitted entirely when nothing on hand names them (no invented data).
  function selectedRowPolicyLine() {
    var r = tab.selectedRow
    if (!r) return ""
    var m = tab.rowModel(r), v = tab.rowVendor(r), c = tab.rowCostClass(r)
    // Nothing on hand at all (older harness, no role/ip_class/model/vendor/
    // cost_class anywhere) -- render exactly like before this wave: no line.
    if (!r.role && !r.ip_class && m === "" && v === "" && c === "") return ""
    var parts = []
    if (r.role) parts.push("role: " + String(r.role))
    parts.push("ip: " + (r.ip_class === "open" ? "open" : "protected"))
    if (m !== "") parts.push("model: " + tab.shortModel(m))
    if (v !== "") parts.push("vendor: " + v)
    if (c !== "") parts.push("cost: " + c)
    return parts.join("  ·  ")
  }

  // ---- sessions grouped by profile (slots "rix-1"/"rix-2" -> "rix" x2) ------
  function sessionGroups() {
    var groups = ({}), order = []
    for (var i = 0; i < sessions.length; i++) {
      var s = sessions[i]
      var label = String(s.label || s.id || "")
      var m = label.match(/^(.*)-(\d+)$/)
      var profile = m ? m[1] : label
      if (!groups[profile]) { groups[profile] = []; order.push(profile) }
      groups[profile].push(s)
    }
    var out = []
    for (var j = 0; j < order.length; j++) out.push({ profile: order[j], members: groups[order[j]] })
    return out
  }
  readonly property var sessionGroupsList: sessionGroups()
  function sessionDotColor(s) {
    var st = s ? s.state : ""
    if (st === "busy") return dash.okColor
    if (st === "throttled") return dash.warnColor
    if (st === "error" || st === "offline") return dash.urgent
    return dash.dim
  }
  // Summarize a group's members into one urgency-ordered line, e.g.
  // "throttled x2 retry 14:32" or "2/3 busy".
  function summarizeGroup(members) {
    var order = ["throttled", "error", "offline", "busy", "stale", "idle"]
    var counts = ({})
    for (var i = 0; i < members.length; i++) { var st = members[i].state || "idle"; counts[st] = (counts[st] || 0) + 1 }
    for (var j = 0; j < order.length; j++) {
      var st2 = order[j]
      if (!counts[st2]) continue
      if (st2 === "throttled") {
        var soonest = 0
        for (var k = 0; k < members.length; k++) if (members[k].state === "throttled") { var r = Number(members[k].retry_at || 0); if (soonest === 0 || (r > 0 && r < soonest)) soonest = r }
        return { text: "throttled" + (counts[st2] > 1 ? " x" + counts[st2] : "") + " retry " + tab.fmtHHMM(soonest), color: dash.warnColor }
      }
      return { text: counts[st2] + "/" + members.length + " " + st2, color: tab.sessionDotColor({ state: st2 }) }
    }
    return { text: members.length + " idle", color: dash.dim }
  }

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
  // "role · tier · shortModel" for a session group's first member, omitting
  // whatever the session doesn't carry (older harness registers with none).
  function sessionPolicyTag(members) {
    if (!members || !members.length) return ""
    var s = members[0]
    var parts = []
    if (s.role) parts.push(String(s.role))
    if (s.tier) parts.push(String(s.tier))
    var m = tab.shortModel(s.model); if (m !== "") parts.push(m)
    return parts.join(" · ")
  }
  // "SPLIT P0.6" when a group member is mid-orchestration: the harness's
  // session row carries `orchestration: {node, command} | null` while a
  // dispatch is outstanding for it (landing alongside this wave's roles/
  // model policy work). "" when no member of the group has one.
  function sessionOrchestrationTag(members) {
    if (!members) return ""
    for (var i = 0; i < members.length; i++) {
      var o = members[i].orchestration
      if (o && o.command) return String(o.command) + (o.node ? " " + String(o.node) : "")
    }
    return ""
  }
  function groupIsOrchestrator(members) {
    if (!members) return false
    for (var i = 0; i < members.length; i++) if (tab.orchestratorSessionIds[String(members[i].id)]) return true
    return false
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
      // A non-atomic writer can be mid-rewrite when we read; JSON.parse
      // throwing here means a torn read, not real data loss. Keep the last
      // good snapshot on screen (with a small "stale Ns" marker) instead of
      // blanking the board, and recover silently on the next successful read.
      try {
        tab.overview = JSON.parse(text() || "{}")
        tab.overviewLoaded = true
        tab.lastGoodAt = Date.now()
        tab.stale = false
      } catch (e) {
        if (tab.overviewLoaded) tab.stale = true
      }
    }
    onLoadFailed: {
      if (tab.overviewLoaded) tab.stale = true
      else { tab.overview = null; tab.overviewLoaded = false }
    }
  }

  // `-F` (== --follow=name --retry) already reopens the file by name if it
  // is rotated/replaced (events.jsonl rotates at 2 MB) or truncated, and
  // retries while it's briefly missing -- no extra rotation handling needed
  // here. We do still restart the process if the *resolved path itself*
  // changes (e.g. status --json starts injecting a real harness.events_path
  // after this tab guessed the default one).
  Process {
    id: eventsTail
    command: ["tail", "-n", "0", "-F", tab.eventsPath]
    stdout: SplitParser { onRead: function(data) { tab.ingestEvent(data) } }
    onExited: eventsTailRestart.restart()
  }
  Timer { id: eventsTailRestart; interval: 1000; onTriggered: eventsTail.running = true }
  onEventsPathChanged: { eventsTail.running = false; eventsTailRestart.restart() }
  Component.onCompleted: eventsTail.running = true

  // ---- approval banner (one row per open request; a project can have several) --
  component ApprovalBanner: BorderSurface {
    id: banner
    property var row: null
    readonly property bool isOverrun: banner.row && banner.row.kind === "overrun"
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
          var r = banner.row
          if (!r) return ""
          if (banner.isOverrun) return r.projectTitle + ": overrun " + dash.fmtUsd(r.estimate_usd) + " — approve or stop"
          return r.projectTitle + ": " + (r.model || "?") + " via " + (r.vendor || "?")
               + " — est. " + dash.fmtUsd(r.estimate_usd) + " — " + (r.reason || "")
        }
        color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall
      }
      Button {
        id: approveBtn; text: "Approve"; bordered: true; selected: true
        foreground: dash.foreground; fontFamily: dash.fontFamily
        onClicked: {
          var r = banner.row
          if (!r) return
          var argv = [dash.launcher, "harness", "approve", r.project, String(r.estimate_usd || 0)]
          if (!banner.isOverrun) argv.push("--request", r.id)
          dash.act(argv)
        }
      }
      Button {
        id: declineBtn; text: banner.isOverrun ? "Stop" : "Decline"; bordered: true
        foreground: dash.urgent; fontFamily: dash.fontFamily
        onClicked: {
          var r = banner.row
          if (!r) return
          var argv = [dash.launcher, "harness", "decline", r.project]
          if (!banner.isOverrun) argv.push("--request", r.id)
          dash.act(argv)
        }
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

    // ---- roles/model policy (Wave 6): wave membership, model label, IP lock --
    readonly property int wave: tab.waveOf(qrow.node)
    readonly property bool wavesLive: tab.harnessAlive && !tab.stale
    readonly property string rowShortModel: qrow.node ? tab.shortModel(tab.rowModel(qrow.node)) : ""
    // Unlabelled means protected (contract §17.1: the graph fails closed).
    readonly property bool ipOpen: !!(qrow.node && qrow.node.ip_class === "open")
    // Dim by wave distance: this wave full, next wave 0.7, anything further
    // out (wave >= 2, or -1 for "not ready / not in a wave") 0.55 -- except
    // a finished row keeps full opacity regardless, since waveOf() also
    // answers -1 once a node leaves the live queue and that must not read
    // as "far future" for a done/failed/cancelled row.
    readonly property real waveOpacity: {
      var st = qrow.node ? qrow.node.state : ""
      if (st === "done" || st === "failed" || st === "cancelled") return 1
      if (qrow.wave === 0) return 1
      if (qrow.wave === 1) return 0.7
      return 0.55
    }

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
        opacity: qrow.waveOpacity
        // Lock glyph before the title (§17.1/§17.6): unlabelled == protected,
        // so absent ip_class shows locked too -- the graph fails closed.
        text: (qrow.ipOpen ? "🔓 " : "🔒 ") + (qrow.node ? (qrow.node.title || qrow.node.node || "") : "")
        color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall
      }
      Item {
        width: qrow.trackWidth; height: parent.height
        opacity: qrow.waveOpacity
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
            text: qrow.node ? ((qrow.node.assignee || "") + (qrow.rowShortModel !== "" ? "  ·  " + qrow.rowShortModel : "")) : ""
            color: "#f5f5f5"; font.family: dash.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
          }
          Text {
            visible: !!(qrow.node && qrow.node.evidence_missing)
            anchors.right: parent.right; anchors.rightMargin: -Style.space(2); anchors.top: parent.top; anchors.topMargin: -Style.space(6)
            text: "⚠"; color: dash.warnColor; font.pixelSize: Style.font.caption; font.bold: true
          }
          Rectangle {
            id: pulseCap
            // Gated on panel visibility too (matches wavePulseBorder below):
            // an Infinite SequentialAnimation must not keep ticking, burning
            // CPU, while the Plan tab isn't even the one on screen.
            visible: !!(qrow.node && qrow.node.state === "running") && dash.opened && dash.tab === "plan"
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
          // Wave-0 outline pulse (§17.5): a subtle border-opacity breathe,
          // ~1.2s period, only while the harness snapshot is live and fresh
          // and the Plan tab is actually the visible panel -- otherwise this
          // Infinite SequentialAnimation runs forever off-screen for nothing.
          Rectangle {
            id: wavePulseBorder
            visible: qrow.wave === 0 && qrow.wavesLive && dash.opened && dash.tab === "plan"
            anchors.fill: parent
            anchors.margins: -2
            radius: parent.radius + 2
            color: "transparent"
            border.width: 2
            border.color: dash.accent
            opacity: 0.85
            SequentialAnimation on opacity {
              running: wavePulseBorder.visible
              loops: Animation.Infinite
              NumberAnimation { to: 0.2; duration: 600 }
              NumberAnimation { to: 0.85; duration: 600 }
            }
          }
        }
      }
      Text {
        width: Style.space(90); height: parent.height
        leftPadding: Style.spacing.md
        verticalAlignment: Text.AlignVCenter
        opacity: qrow.waveOpacity
        text: qrow.node ? (String(qrow.node.state || "") + (qrow.wave === 1 ? "  ·  next" : "")) : ""
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
    function hasOpenApprovals() { return grp.p ? tab.projectApprovalRows(grp.p).length > 0 : false }
    function throttledVendorList() {
      var tv = (grp.p && grp.p.throttled_vendors) || ({})
      var out = []
      for (var v in tv) out.push({ vendor: v, retryLabel: tab.fmtHHMM(tv[v]) })
      return out
    }

    Flow {
      width: parent.width
      spacing: Style.spacing.controlGap
      Text {
        width: Style.space(200)
        elide: Text.ElideRight; textFormat: Text.PlainText
        text: (grp.p ? (grp.p.title || grp.p.id) : "") + (grp.hasOpenApprovals() ? "  ⚠" : "")
        color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.body; font.bold: true
      }
      Item {
        width: Math.max(Style.space(60), parent.width - Style.space(200) - critLabel.width - parent.spacing * 2)
        height: Style.space(8)
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
        textFormat: Text.PlainText
        text: (grp.p && grp.p.critical_path ? grp.p.critical_path.length : 0) + " critical"
        color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
      }
    }

    // Router orchestrator (§17.5-17.6): a session orchestrator is marked on
    // its chip in the sessions lane instead (★ orchestrator); this line only
    // fires for the router-hop case, which has no session row to mark.
    Text {
      width: parent.width
      visible: !!(grp.p && grp.p.orchestrator && grp.p.orchestrator.kind === "router")
      textFormat: Text.PlainText; elide: Text.ElideRight
      text: "orchestrator: router → " + (grp.p && grp.p.orchestrator ? (grp.p.orchestrator.hop || grp.p.orchestrator.model || "?") : "?")
      color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
    }

    Flow {
      width: parent.width
      spacing: Style.spacing.sm
      visible: !!(grp.p && grp.p.cost)
      Text {
        textFormat: Text.PlainText
        text: grp.p && grp.p.cost ? ("spent " + dash.fmtUsd(grp.p.cost.spent_usd) + " / appr " + dash.fmtUsd(grp.p.cost.approved_usd) + " / resv " + dash.fmtUsd(grp.p.cost.reserved_usd) + " / left " + dash.fmtUsd(grp.p.cost.remaining_usd)
              + (grp.p.cost.daily_cap_usd ? "  ·  today " + dash.fmtUsd(grp.p.cost.daily_spent_usd) + " / " + dash.fmtUsd(grp.p.cost.daily_cap_usd) : "")
              + (Number(grp.p.cost.overrun_usd || 0) > 0 ? "  ·  overrun " + dash.fmtUsd(grp.p.cost.overrun_usd) : "")) : ""
        color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
      }
      Repeater {
        model: grp.throttledVendorList()
        delegate: BorderSurface {
          required property var modelData
          radius: Style.cornerRadius
          implicitWidth: tvText.implicitWidth + Style.space(12)
          implicitHeight: tvText.implicitHeight + Style.space(6)
          color: Qt.rgba(dash.warnColor.r, dash.warnColor.g, dash.warnColor.b, 0.14)
          borderSpec: Border.flat(dash.warnColor, 1)
          Text { id: tvText; anchors.centerIn: parent; textFormat: Text.PlainText; text: modelData.vendor + " retry " + modelData.retryLabel; color: dash.warnColor; font.family: dash.fontFamily; font.pixelSize: Style.font.caption }
        }
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

  // ---- one session-group chip (slots of a profile, e.g. rix-1/rix-2, grouped) --
  component SessionGroupChip: BorderSurface {
    id: chip
    property var groupData: null
    readonly property var members: chip.groupData ? chip.groupData.members : []
    readonly property var summary: tab.summarizeGroup(chip.members)
    radius: Style.cornerRadius
    implicitWidth: chipCol.implicitWidth + Style.space(20)
    implicitHeight: Style.space(46)
    color: Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.04)
    borderSpec: Border.flat(chip.summary.text.indexOf("throttled") === 0 ? dash.warnColor : Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.16), 1)

    Column {
      id: chipCol
      anchors.centerIn: parent
      spacing: Style.spacing.xxs
      Row {
        spacing: Style.spacing.xs
        Text { text: tab.workerGlyph(chip.members.length ? chip.members[0].worker : ""); color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
        Text {
          text: (chip.groupData ? chip.groupData.profile : "") + (chip.members.length > 1 ? " (" + chip.members.length + ")" : "")
          color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
          elide: Text.ElideRight; width: Style.space(100)
        }
        // Orchestrator marker (§17.5-17.6): this profile owns the session
        // named by some project's orchestrator.kind === "session".
        Text {
          visible: tab.groupIsOrchestrator(chip.members)
          text: "★ orchestrator"
          color: dash.accent; font.family: dash.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
        }
      }
      Row {
        spacing: Style.spacing.xs
        Rectangle { width: Style.space(6); height: Style.space(6); radius: width / 2; color: chip.summary.color; anchors.verticalCenter: parent.verticalCenter }
        Text { text: chip.summary.text; color: chip.summary.color; font.family: dash.fontFamily; font.pixelSize: Style.font.caption }
        Text {
          readonly property string tag: tab.sessionPolicyTag(chip.members)
          visible: tag !== ""
          text: "· " + tag
          color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        }
        Text {
          visible: chip.members.length > 0
          text: "· " + tab.costClassTag(chip.members.length ? chip.members[0].cost_class : "")
          color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        }
        Text {
          readonly property string orchTag: tab.sessionOrchestrationTag(chip.members)
          visible: orchTag !== ""
          text: "· " + orchTag
          color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        }
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
      meta: tab.projects.length + " project" + (tab.projects.length === 1 ? "" : "s") + (tab.overviewLoaded ? (tab.harnessAlive ? "  ·  harness running" : "  ·  harness offline (last snapshot)") : "") + (tab.stale ? "  ·  stale " + tab.staleSeconds + "s" : "")
      foreground: dash.foreground; fontFamily: dash.fontFamily
      iconComponent: Component { Text { text: "▤"; color: tab.harnessAlive ? dash.okColor : dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.display } }
    }
    PanelSeparator { width: parent.width; foreground: dash.foreground }

    Column {
      width: parent.width; spacing: Style.space(6)
      Repeater { model: tab.approvalRows; delegate: ApprovalBanner { required property var modelData; width: headerCol.width; row: modelData } }
    }

    // Filters + state chips: a Flow (not a Row) so each control wraps onto
    // its own line at narrower widths (1280x800 panel, sidebar included).
    Flow {
      width: parent.width; spacing: Style.spacing.controlGap
      PanelDropdown { id: projectDrop; width: Style.space(190); showLabel: false; options: tab.projectOptionsList; value: tab.projectFilter; popupParent: tab; ownerOpen: dash.opened && dash.tab === "plan"; foreground: dash.foreground; fontFamily: dash.fontFamily; onChanged: function(v) { tab.projectFilter = v } }
      PanelDropdown { id: agentDrop; width: Style.space(190); showLabel: false; options: tab.agentOptionsList; value: tab.agentFilter; popupParent: tab; ownerOpen: dash.opened && dash.tab === "plan"; foreground: dash.foreground; fontFamily: dash.fontFamily; onChanged: function(v) { tab.agentFilter = v } }
      PanelDropdown { id: roleDrop; width: Style.space(150); showLabel: false; options: tab.roleOptionsList; value: tab.roleFilter; popupParent: tab; ownerOpen: dash.opened && dash.tab === "plan"; foreground: dash.foreground; fontFamily: dash.fontFamily; onChanged: function(v) { tab.roleFilter = v } }
      PanelDropdown { id: modelDrop; width: Style.space(190); showLabel: false; options: tab.modelOptionsList; value: tab.modelFilter; popupParent: tab; ownerOpen: dash.opened && dash.tab === "plan"; foreground: dash.foreground; fontFamily: dash.fontFamily; onChanged: function(v) { tab.modelFilter = v } }
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
      Button { text: "Critical only"; bordered: true; selected: tab.criticalOnly; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: tab.toggleCriticalOnly() }
    }
    Flow {
      width: parent.width; spacing: Style.spacing.controlGap
      Text {
        textFormat: Text.PlainText
        text: "Residual " + tab.agg.residual + (tab.agg.blocked > 0 ? " (" + tab.agg.blocked + " blocked)" : "")
              + "  ·  Spent " + dash.fmtUsd(tab.agg.spent) + " / Approved " + dash.fmtUsd(tab.agg.approved) + " / Reserved " + dash.fmtUsd(tab.agg.reserved) + " / Left " + dash.fmtUsd(tab.agg.remaining)
              + (tab.agg.dailyCap > 0 ? "  ·  Today " + dash.fmtUsd(tab.agg.dailySpent) + " / " + dash.fmtUsd(tab.agg.dailyCap) : "")
              + (tab.agg.overrun > 0 ? "  ·  Overrun " + dash.fmtUsd(tab.agg.overrun) : "")
        color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
      }
      // Wave/concurrency pill (§17.5-17.6): absent on an older harness with
      // no `waves`/`concurrency` on any filtered project -- renders nothing.
      BorderSurface {
        id: wavePill
        visible: tab.agg.hasWaves || tab.agg.hasConcurrency
        radius: Style.cornerRadius
        implicitWidth: wavePillText.implicitWidth + Style.space(12)
        implicitHeight: wavePillText.implicitHeight + Style.space(6)
        color: Qt.rgba(dash.accent.r, dash.accent.g, dash.accent.b, 0.10)
        borderSpec: Border.flat(dash.accent, 1)
        Text {
          id: wavePillText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: (tab.agg.hasWaves ? "wave 0: " + tab.agg.wave0 + "  ·  next: " + tab.agg.nextWave : "")
                + (tab.agg.hasWaves && tab.agg.hasConcurrency ? "  ·  " : "")
                + (tab.agg.hasConcurrency ? "concurrency " + tab.agg.eligibleIdle + "/" + tab.agg.concurrencyWave0 : "")
          color: dash.accent; font.family: dash.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
        }
      }
      Button { text: "Open full Gantt"; bordered: true; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: Qt.openUrlExternally(tab.harnessUrl) }
      Button { text: "Start harness"; bordered: true; visible: !tab.harnessAlive; foreground: dash.okColor; fontFamily: dash.fontFamily; onClicked: dash.act([dash.launcher, "harness", "serve"]) }
    }
    PanelSeparator { width: parent.width; foreground: dash.foreground }
  }

  // Sessions lane: always one line -- a horizontally-scrolling Flickable
  // of per-profile group chips (rix-1/rix-2 collapse into "rix (2)"),
  // never wrapped, so it stays a single row at 1280x800.
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
        Repeater { model: tab.sessionGroupsList; delegate: SessionGroupChip { required property var modelData; groupData: modelData } }
        Text {
          visible: tab.sessionGroupsList.length === 0
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
    height: tab.selectedRow ? (tab.selectedRowPolicyLine() !== "" ? Style.space(112) : Style.space(96)) : 0
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
        Text {
          visible: text !== ""
          textFormat: Text.PlainText; elide: Text.ElideRight; width: parent.width
          text: tab.selectedRow ? tab.selectedRowPolicyLine() : ""
          color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        }
        Text {
          textFormat: Text.PlainText; elide: Text.ElideRight; width: parent.width
          text: tab.selectedRow ? "blockers: " + tab.blockersLine(tab.selectedRow) : ""
          color: dash.dim; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        }
        Text {
          visible: tab.selectedRow && tab.evidenceLine(tab.selectedRow) !== ""
          textFormat: Text.PlainText; elide: Text.ElideRight; width: parent.width
          text: tab.selectedRow ? "evidence: " + tab.evidenceLine(tab.selectedRow) : ""
          color: dash.okColor; font.family: dash.fontFamily; font.pixelSize: Style.font.caption
        }
      }
      Button { id: assignBtn; text: "Assign to Rix"; bordered: true; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: tab.assignSelected() }
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
