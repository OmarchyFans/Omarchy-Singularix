import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The "New agent" page of the Agent Dashboard: one form, every parameter.
//
// It owns no agent logic. It reads everything it shows from
// `omarchy-agent-launcher info --json` (agents, runtime status, providers,
// models with prices, skills) and submits with
// `omarchy-agent-launcher create … --launch`, passing the API key and the job
// text through the child's environment (never argv). The script then opens
// the agent's persistent tmux window, with any browser sign-in inside it.
Item {
  id: root
  required property var dash          // the Dashboard root: launcher, colors, tab, focusCatcher()
  signal created(string name)

  readonly property string launcher: dash.launcher
  readonly property color foreground: dash.foreground
  readonly property color urgent: dash.urgent
  readonly property color dim: dash.dim
  readonly property string fontFamily: dash.fontFamily
  readonly property bool opened: dash.opened && dash.tab === "new"

  // ---- data from the backend ------------------------------------------
  property var info: null
  property bool loading: false
  property bool busy: false
  property string error: ""

  // ---- form state -------------------------------------------------------
  property string name: ""
  property string agent: "hermes"
  property string runtime: "local"
  property string provider: "anthropic"
  property string auth: "oauth"
  property string apiKey: ""
  property string model: ""
  property string baseUrl: ""
  property string backend: ""          // a lib/backends.sh entry, when provider is "endpoint"
  property var skills: []
  property string skillFilter: ""
  property string mode: "interactive"

  // ---- derived ----------------------------------------------------------
  readonly property var agentInfo: findAgent(agent)
  readonly property var providerInfo: findProvider(provider)
  readonly property var providerOptions: providersFor(agent)
  readonly property var authOptions: authOptionsFor(providerInfo)
  readonly property var modelOptions: modelOptionsFor(providerInfo)
  property bool customModel: false
  function fmtPrice(v) { return (v === null || v === undefined) ? "" : (v % 1 === 0 ? String(v) : String(Math.round(v * 100) / 100)) }
  function modelOptionsFor(p) {
    var out = []
    if (p) for (var i = 0; i < p.models.length; i++) {
      var m = p.models[i]
      var label = m.name && m.name !== m.id ? m.name + "  ·  " + m.id : m.id
      if (m.input !== null && m.input !== undefined) label += "  ·  $" + fmtPrice(m.input) + " in / $" + fmtPrice(m.output) + " out per M"
      out.push({ value: m.id, label: label })
    }
    out.push({ value: "__custom__", label: "Custom model id…" })
    return out
  }
  readonly property var skillList: filteredSkills()
  readonly property string runtimeStatus: agentInfo && agentInfo.runtimes[runtime] ? agentInfo.runtimes[runtime].status : ""
  readonly property bool runtimeOk: agentInfo && agentInfo.runtimes[runtime] ? agentInfo.runtimes[runtime].ok : false
  readonly property bool isEndpoint: provider === "endpoint"
  readonly property var backendOptions: backendOptionsFor(info)
  readonly property bool showBaseUrl: providerInfo && providerInfo.base_url !== "-" && !isEndpoint
  readonly property bool editing: nameField.activeFocus || keyField.activeFocus || modelField.activeFocus
    || urlField.activeFocus || filterField.activeFocus || jobEditor.editing
  readonly property bool popupOpen: providerDrop.popupOpen || modelDrop.popupOpen || backendDrop.popupOpen
  function backendOptionsFor(inf) {
    var out = []
    if (inf && inf.backends) for (var i = 0; i < inf.backends.length; i++) {
      var b = inf.backends[i]
      if (b.kind === "provider") continue
      out.push({ value: b.id, label: b.label + "  ·  " + b.model + "  ·  " + (b.ready ? "ready" : b.state) })
    }
    return out
  }
  function findBackend(id) {
    if (!info || !info.backends) return null
    for (var i = 0; i < info.backends.length; i++) if (info.backends[i].id === id) return info.backends[i]
    return null
  }
  onBackendChanged: { var b = findBackend(backend); if (b) { model = b.model; customModel = false } }

  function findAgent(id) {
    if (!info) return null
    for (var i = 0; i < info.agents.length; i++) if (info.agents[i].id === id) return info.agents[i]
    return null
  }
  function findProvider(id) {
    if (!info) return null
    for (var i = 0; i < info.providers.length; i++) if (info.providers[i].id === id) return info.providers[i]
    return null
  }
  function providersFor(agentId) {
    if (!info) return []
    var out = []
    for (var i = 0; i < info.providers.length; i++) {
      var p = info.providers[i]
      var supported = agentId === "hermes" ? p.hermes !== "-" : p.openclaw !== "-"
      if (supported) out.push({ value: p.id, label: p.label })
    }
    return out
  }
  function authOptionsFor(p) {
    if (!p) return []
    var out = []
    var oauth = agent === "hermes" ? p.hermes_oauth : p.openclaw_oauth
    if (oauth) out.push({ value: "oauth", label: "Browser sign-in" })
    if (p.env !== "-") {
      if (p.saved_key) out.push({ value: "saved-key", label: "Saved " + p.env })
      out.push({ value: "api-key", label: p.saved_key ? "New API key" : "API key" })
    }
    if (out.length === 0) out.push({ value: "none", label: "No sign-in needed" })
    return out
  }
  function filteredSkills() {
    if (!agentInfo) return []
    var q = skillFilter.trim().toLowerCase()
    return agentInfo.skills.filter(function(s) { return q === "" || s.toLowerCase().indexOf(q) >= 0 })
  }
  function hasSkill(s) { return skills.indexOf(s) >= 0 }
  function toggleSkill(s) {
    var next = skills.slice()
    var at = next.indexOf(s)
    if (at >= 0) next.splice(at, 1); else next.push(s)
    skills = next
  }
  function firstValue(options, current) {
    for (var i = 0; i < options.length; i++) if (options[i].value === current) return current
    return options.length ? options[0].value : ""
  }
  function defaultName() {
    var d = new Date()
    function two(n) { return (n < 10 ? "0" : "") + n }
    return "agent-" + two(d.getMonth() + 1) + two(d.getDate()) + two(d.getHours()) + two(d.getMinutes())
  }

  // Keep dependent fields valid as the user moves through the form.
  // Change handlers call the functions directly: readonly bindings may not
  // have re-evaluated yet when a handler runs, and a stale [] would wipe the
  // selection.
  onAgentChanged: { skills = []; skillFilter = ""; provider = firstValue(providersFor(agent), provider); applyProviderDefaults() }
  onProviderChanged: applyProviderDefaults()
  onInfoChanged: {
    provider = firstValue(providersFor(agent), provider)
    applyProviderDefaults()
  }
  function applyProviderDefaults() {
    var p = findProvider(provider)
    auth = firstValue(authOptionsFor(p), auth)
    customModel = false
    if (p) {
      model = p.default_model
      baseUrl = p.base_url === "-" ? "" : p.base_url
    }
    if (provider === "endpoint") { var opts = backendOptionsFor(info); backend = firstValue(opts, backend); var b = findBackend(backend); if (b) model = b.model }
  }

  onOpenedChanged: if (opened) { error = ""; if (!info) loadInfo() }

  // ---- backend calls ----------------------------------------------------
  function loadInfo() {
    if (infoProc.running) return
    loading = true
    infoProc.command = [root.launcher, "info", "--json"]
    infoProc.running = true
  }

  Process {
    id: infoProc
    stdout: StdioCollector { id: infoOut; waitForEnd: true }
    stderr: StdioCollector { id: infoErr; waitForEnd: true }
    onExited: function(code) {
      root.loading = false
      if (code !== 0) { root.error = "info failed: " + String(infoErr.text || "").trim(); return }
      try { root.info = JSON.parse(String(infoOut.text || "")) }
      catch (e) { root.error = "could not parse launcher info: " + e }
    }
  }

  function submit() {
    if (busy) return
    error = ""
    var n = name.trim() === "" ? defaultName() : name.trim()
    var jobText = jobEditor.text.trim()
    if (jobText === "") { error = "Write a job description first."; jobEditor.focusEditor(); return }
    if (model.trim() === "") { error = "Pick or type a model id."; return }
    if (!runtimeOk) { error = "Runtime not ready: " + runtimeStatus; return }
    if (isEndpoint && backend === "") { error = "Add a backend on the Rix page first (a Modal endpoint or a shared URL)."; return }
    var authValue = auth === "saved-key" ? "api-key" : auth
    var argv = [root.launcher, "create", "--json", "--name", n, "--agent", agent, "--runtime", runtime,
                "--provider", provider, "--auth", authValue, "--model", model.trim(), "--mode", mode,
                "--job-env", "--launch"]
    if (isEndpoint) argv.push("--backend", backend)
    if (showBaseUrl && baseUrl.trim() !== "") argv.push("--base-url", baseUrl.trim())
    for (var i = 0; i < skills.length; i++) argv.push("--skill", skills[i])
    var env = { OAL_JOB: jobText }
    if (auth === "api-key") {
      if (apiKey.trim() === "") { error = "Paste an API key, or choose another sign-in."; keyField.forceActiveFocus(); return }
      argv.push("--api-key-env")
      env.OAL_API_KEY = apiKey.trim()
    }
    createProc.environment = env
    createProc.command = argv
    busy = true
    createProc.running = true
  }

  Process {
    id: createProc
    stdout: StdioCollector { id: createOut; waitForEnd: true }
    stderr: StdioCollector { id: createErr; waitForEnd: true }
    onExited: function(code) {
      root.busy = false
      if (code === 0) {
        var createdName = ""
        try { createdName = String(JSON.parse(String(createOut.text || "")).name || "") } catch (e) {}
        root.apiKey = ""
        root.error = ""
        root.created(createdName)
      } else {
        var msg = String(createErr.text || "").trim().replace(/^agent-launcher: /, "")
        root.error = msg === "" ? ("launch failed (exit " + code + ")") : msg
      }
    }
  }

  function backToPanel() { dash.focusCatcher() }

  // Small reusable label above a control.
  component FieldLabel: Text {
    textFormat: Text.PlainText
    color: Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }
  component Hint: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.Wrap
  }
  component Field: TextField {
    foreground: root.foreground
    font.family: root.fontFamily
    verticalPadding: Style.spacing.controlPaddingY
    Keys.onEscapePressed: function(event) { root.backToPanel(); event.accepted = true }
  }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        anchors.rightMargin: Style.spacing.md
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(8)

          PanelHero {
            width: parent.width
            title: "New agent"
            meta: root.loading ? "Reading agents, runtimes, and skills…" : (root.busy ? "Saving and launching…" : "Set up an agent on one page, then launch it")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text { text: "󱚝"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.display }
            }
          }
          PanelSeparator { width: parent.width; foreground: root.foreground }

          Row {
            id: columns
            width: parent.width
            spacing: Style.space(18)
            readonly property real colWidth: (width - spacing) / 2

            // ---- left: what runs, where, with which model -------------
            Column {
              width: columns.colWidth
              spacing: Style.space(8)

              Column {
                width: parent.width; spacing: Style.spacing.labelGap
                FieldLabel { text: "NAME" }
                Field { id: nameField; width: parent.width; placeholderText: root.defaultName(); text: root.name; onTextEdited: root.name = text }
              }
              Column {
                width: parent.width; spacing: Style.spacing.labelGap
                FieldLabel { text: "AGENT" }
                ButtonGroup {
                  options: [ { value: "hermes", label: "Hermes Agent" }, { value: "openclaw", label: "OpenClaw" } ]
                  value: root.agent
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onChanged: function(v) { root.agent = v }
                }
              }
              Column {
                width: parent.width; spacing: Style.spacing.labelGap
                FieldLabel { text: "RUN IN" }
                ButtonGroup {
                  options: [ { value: "local", label: "Local" }, { value: "docker", label: "Docker" }, { value: "sprite", label: "Fly.io Sprite" } ]
                  value: root.runtime
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onChanged: function(v) { root.runtime = v }
                }
                Hint {
                  width: parent.width
                  text: (root.agentInfo && !root.agentInfo.installed && root.runtime === "local" ? root.agentInfo.label + " is not installed locally. " : "") + root.runtimeStatus
                  color: root.runtimeOk ? root.dim : root.urgent
                }
              }
              Column {
                width: parent.width; spacing: Style.spacing.labelGap
                FieldLabel { text: "MODEL PROVIDER" }
                Hint {
                  width: parent.width
                  visible: root.provider === "local" && root.info && root.info.local
                  color: root.info && root.info.local && root.info.local.agent_ready ? root.dim : root.urgent
                  text: !(root.info && root.info.local) ? "" :
                        (!root.info.local.online ? (root.info.local.unit_exists ? "Local server not running; it is started on launch." : "No local llama.cpp server found: install the Omarchy Help plugin.")
                        : (root.info.local.agent_ready
                           ? "Offline: " + root.info.local.model + " on " + (root.info.local.gpu ? root.info.local.gpu.name : "the GPU") + " · " + root.info.local.ctx_per_request + " tokens per request. Nothing leaves this machine."
                           : "Local server serves only " + root.info.local.ctx_per_request + " tokens per request; agents need " + root.info.local.min_ctx + ". Run:  omarchy-agent-launcher local-server tune --ctx 32768"))
                }
                PanelDropdown {
                  id: providerDrop
                  width: parent.width
                  showLabel: false
                  options: root.providerOptions
                  value: root.provider
                  popupParent: root
                  ownerOpen: root.opened
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onChanged: function(v) { root.provider = v }
                }
              }
              Column {
                width: parent.width; spacing: Style.spacing.labelGap
                visible: root.isEndpoint
                FieldLabel { text: "BACKEND" }
                Hint { width: parent.width; visible: root.backendOptions.length === 0; color: root.urgent; text: "No endpoint backends yet. Add a Modal endpoint, sandbox, or shared URL on the Rix page." }
                PanelDropdown {
                  id: backendDrop
                  width: parent.width
                  visible: root.backendOptions.length > 0
                  showLabel: false
                  options: root.backendOptions
                  value: root.backend
                  popupParent: root
                  ownerOpen: root.opened
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onChanged: function(v) { root.backend = v }
                }
                Hint { width: parent.width; visible: root.backend !== "" && root.findBackend(root.backend) && !root.findBackend(root.backend).ready; color: root.urgent; text: "This backend is not running yet; deploy or start it on the Rix page before launching." }
              }
              Column {
                width: parent.width; spacing: Style.spacing.labelGap
                FieldLabel { text: "SIGN-IN" }
                ButtonGroup {
                  options: root.authOptions
                  value: root.auth
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onChanged: function(v) { root.auth = v }
                }
                Field {
                  id: keyField
                  width: parent.width
                  visible: root.auth === "api-key"
                  password: true
                  placeholderText: (root.providerInfo ? root.providerInfo.env : "API key") + " (saved once, mode 600)"
                  text: root.apiKey
                  onTextEdited: root.apiKey = text
                }
                Hint { width: parent.width; visible: root.auth === "oauth"; text: "Browser sign-in with your own account runs in the launch terminal the first time." }
              }
              Column {
                width: parent.width; spacing: Style.spacing.labelGap
                FieldLabel { text: "MODEL" + (root.info && root.info.catalog.source === "models.dev" ? "  ·  prices per 1M tokens (models.dev)" : "") }
                PanelDropdown {
                  id: modelDrop
                  width: parent.width
                  showLabel: false
                  options: root.modelOptions
                  value: root.customModel ? "__custom__" : root.model
                  popupParent: root
                  ownerOpen: root.opened
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onChanged: function(v) {
                    if (v === "__custom__") { root.customModel = true; root.model = ""; Qt.callLater(function() { modelField.forceActiveFocus() }) }
                    else { root.customModel = false; root.model = v }
                  }
                }
                Field { id: modelField; width: parent.width; visible: root.customModel; placeholderText: "model id, exactly as the provider names it"; text: root.model; onTextEdited: root.model = text }
                Field { id: urlField; width: parent.width; visible: root.showBaseUrl; placeholderText: "endpoint URL"; text: root.baseUrl; onTextEdited: root.baseUrl = text }
              }
            }

            // ---- right: skills, job, session ---------------------------
            Column {
              width: columns.colWidth
              spacing: Style.space(8)

              Column {
                width: parent.width; spacing: Style.spacing.labelGap
                FieldLabel { text: "SKILLS TO PRELOAD" + (root.skills.length ? "  ·  " + root.skills.length + " selected" : "") }
                Field {
                  id: filterField
                  width: parent.width
                  visible: root.agentInfo && root.agentInfo.skills.length > 8
                  placeholderText: "filter skills"
                  text: root.skillFilter
                  onTextEdited: root.skillFilter = text
                }
                Hint {
                  width: parent.width
                  visible: !root.agentInfo || root.agentInfo.skills.length === 0
                  text: root.agent === "hermes" ? "No skills found in ~/.hermes/skills." : "No skills found in ~/.openclaw/skills."
                }
                BorderSurface {
                  width: parent.width
                  visible: root.skillList.length > 0
                  height: Math.min(skillColumn.implicitHeight + Style.spacing.md * 2, Style.space(176))
                  radius: Style.cornerRadius
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
                  borderSpec: Border.flat(Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10), 1)
                  Flickable {
                    anchors.fill: parent
                    anchors.margins: Style.spacing.md
                    contentWidth: width
                    contentHeight: skillColumn.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentHeight > height
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    Column {
                      id: skillColumn
                      width: parent.width
                      Repeater {
                        model: root.skillList
                        delegate: SkillRow {
                          required property string modelData
                          width: skillColumn.width
                          label: modelData
                          selected: root.hasSkill(modelData)
                          foreground: root.foreground; fontFamily: root.fontFamily
                          onToggled: root.toggleSkill(modelData)
                        }
                      }
                    }
                  }
                }
              }
              Column {
                width: parent.width; spacing: Style.spacing.labelGap
                FieldLabel { text: "JOB DESCRIPTION / INSTRUCTIONS" }
                JobEditor {
                  id: jobEditor
                  width: parent.width
                  height: Style.space(150)
                  placeholderText: "What must this agent accomplish? Constraints, inputs, and what \"done\" looks like."
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onEscaped: root.backToPanel()
                }
              }
              Column {
                width: parent.width; spacing: Style.spacing.labelGap
                FieldLabel { text: "SESSION" }
                ButtonGroup {
                  options: [ { value: "interactive", label: "Interactive chat" }, { value: "unattended", label: "Unattended run" } ]
                  value: root.mode
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onChanged: function(v) { root.mode = v }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.error !== ""
            text: root.error
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }
          Row {
            width: parent.width; spacing: Style.spacing.controlGap
            Button {
              text: root.busy ? "Launching…" : "Launch"
              iconText: "󱚝"
              selected: true
              enabled: !root.busy && !root.loading
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.submit()
            }
            Button {
              text: "Terminal wizard"
              tooltipText: "The same setup as step-by-step prompts in a terminal"
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: Quickshell.execDetached([root.launcher, "--popup", "new"])
            }
            Button { text: "Reload"; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.loadInfo() }
          }

          Item { width: 1; height: Style.spacing.sm }
        }
  }
}
