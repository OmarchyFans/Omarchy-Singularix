import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Agent Launcher: bar button + a single-page setup form in a KeyboardPanel.
//
// The panel owns no agent logic. It reads everything it shows from
// `omarchy-agent-launcher info --json` (agents, runtime status, providers,
// models, skills, saved agents) and submits with
// `omarchy-agent-launcher create … --launch`, passing the API key and the job
// text through the child's environment (never argv). The script then opens
// the session, and any browser sign-in, in a floating terminal.
Panel {
  id: root
  moduleName: "fans.omarchy.agent-launcher"
  ipcTarget: "fans.omarchy.agent-launcher"
  manageIpc: false

  readonly property string launcher: Qt.resolvedUrl("bin/omarchy-agent-launcher").toString().replace(/^file:\/\//, "")
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

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
  property var skills: []
  property string skillFilter: ""
  property string mode: "interactive"
  property string savedName: ""

  // ---- derived ----------------------------------------------------------
  readonly property var agentInfo: findAgent(agent)
  readonly property var providerInfo: findProvider(provider)
  readonly property var providerOptions: providersFor(agent)
  readonly property var authOptions: authOptionsFor(providerInfo)
  readonly property var modelOptions: providerInfo ? providerInfo.models : []
  readonly property var skillList: filteredSkills()
  readonly property var savedOptions: info ? info.saved.map(function(s) { return { value: s.name, label: s.name + "  ·  " + s.agent + " / " + s.runtime + " / " + s.model } }) : []
  readonly property string runtimeStatus: agentInfo && agentInfo.runtimes[runtime] ? agentInfo.runtimes[runtime].status : ""
  readonly property bool runtimeOk: agentInfo && agentInfo.runtimes[runtime] ? agentInfo.runtimes[runtime].ok : false
  readonly property bool showBaseUrl: providerInfo && providerInfo.base_url !== "-"
  readonly property bool editing: nameField.activeFocus || keyField.activeFocus || modelField.activeFocus
    || urlField.activeFocus || filterField.activeFocus || jobEditor.editing
    || providerDrop.popupOpen || modelDrop.popupOpen || savedDrop.popupOpen

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
  onAgentChanged: { provider = firstValue(providerOptions, provider); skills = []; skillFilter = "" }
  onProviderChanged: applyProviderDefaults()
  onInfoChanged: { provider = firstValue(providerOptions, provider); applyProviderDefaults(); savedName = firstValue(savedOptions, savedName) }
  function applyProviderDefaults() {
    auth = firstValue(authOptions, auth)
    if (providerInfo) {
      model = providerInfo.default_model
      baseUrl = providerInfo.base_url === "-" ? "" : providerInfo.base_url
    }
  }

  onOpenedChanged: if (opened) { error = ""; loadInfo() }

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
    var authValue = auth === "saved-key" ? "api-key" : auth
    var argv = [root.launcher, "create", "--json", "--name", n, "--agent", agent, "--runtime", runtime,
                "--provider", provider, "--auth", authValue, "--model", model.trim(), "--mode", mode,
                "--job-env", "--launch"]
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
        root.apiKey = ""
        root.error = ""
        root.close()
      } else {
        var msg = String(createErr.text || "").trim().replace(/^agent-launcher: /, "")
        root.error = msg === "" ? ("launch failed (exit " + code + ")") : msg
      }
    }
  }

  function launchSaved() {
    if (savedName === "") return
    Quickshell.execDetached([root.launcher, "--popup", "launch", savedName])
    root.close()
  }
  function openManager() { Quickshell.execDetached([root.launcher, "--popup", "manage"]); root.close() }
  function backToPanel() { Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱚝"                    // nf-md-robot_happy
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: "Launch an AI agent"
    onPressed: root.toggle()
  }

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

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(840))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editing
      onCloseRequested: root.close()
      onTabRequested: function(direction) { nameField.forceActiveFocus() }
      onReturnRequested: root.submit()

      Flickable {
        id: panelFlick
        anchors.fill: parent
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
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: "Agent Launcher"
            meta: root.loading ? "Reading agents, runtimes, and skills…" : (root.busy ? "Saving and launching…" : "Set up an agent on one page, then launch it")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text { text: "󱚝"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.display }
            }
          }
          PanelSeparator { width: parent.width; foreground: root.foreground }

          // ---- name ---------------------------------------------------
          Column {
            width: parent.width; spacing: Style.spacing.labelGap
            FieldLabel { text: "NAME" }
            Field {
              id: nameField
              width: parent.width
              placeholderText: root.defaultName()
              text: root.name
              onTextEdited: root.name = text
            }
          }

          // ---- agent + runtime ---------------------------------------
          Column {
            width: parent.width; spacing: Style.spacing.labelGap
            FieldLabel { text: "AGENT" }
            ButtonGroup {
              options: [
                { value: "hermes", label: "Hermes Agent" + (root.findAgent("hermes") && root.findAgent("hermes").installed ? "" : "  (not installed locally)") },
                { value: "openclaw", label: "OpenClaw" + (root.findAgent("openclaw") && root.findAgent("openclaw").installed ? "" : "  (not installed locally)") }
              ]
              value: root.agent
              foreground: root.foreground; fontFamily: root.fontFamily
              onChanged: function(v) { root.agent = v }
            }
          }
          Column {
            width: parent.width; spacing: Style.spacing.labelGap
            FieldLabel { text: "RUN IN" }
            ButtonGroup {
              options: [ { value: "local", label: "Local shell" }, { value: "docker", label: "Docker" }, { value: "sprite", label: "Fly.io Sprite" } ]
              value: root.runtime
              foreground: root.foreground; fontFamily: root.fontFamily
              onChanged: function(v) { root.runtime = v }
            }
            Hint { width: parent.width; text: root.runtimeStatus; color: root.runtimeOk ? root.dim : root.urgent }
          }

          // ---- provider + sign-in ------------------------------------
          Column {
            width: parent.width; spacing: Style.spacing.labelGap
            FieldLabel { text: "MODEL PROVIDER" }
            PanelDropdown {
              id: providerDrop
              width: parent.width
              showLabel: false
              options: root.providerOptions
              value: root.provider
              popupParent: keyCatcher
              ownerOpen: root.opened
              foreground: root.foreground; fontFamily: root.fontFamily
              onChanged: function(v) { root.provider = v }
            }
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
              placeholderText: (root.providerInfo ? root.providerInfo.env : "API key") + "  ·  saved once with mode 600, never shown again"
              text: root.apiKey
              onTextEdited: root.apiKey = text
            }
            Hint {
              width: parent.width
              visible: root.auth === "oauth"
              text: "A browser sign-in with your own account runs in the launch terminal the first time."
            }
          }

          // ---- model + base url --------------------------------------
          Column {
            width: parent.width; spacing: Style.spacing.labelGap
            FieldLabel { text: "MODEL" }
            Row {
              width: parent.width; spacing: Style.spacing.controlGap
              PanelDropdown {
                id: modelDrop
                width: Style.space(220)
                showLabel: false
                options: root.modelOptions
                value: root.model
                popupParent: keyCatcher
                ownerOpen: root.opened
                foreground: root.foreground; fontFamily: root.fontFamily
                onChanged: function(v) { root.model = v }
              }
              Field {
                id: modelField
                width: parent.width - modelDrop.width - parent.spacing
                placeholderText: "or type any model id"
                text: root.model
                onTextEdited: root.model = text
              }
            }
            Field {
              id: urlField
              width: parent.width
              visible: root.showBaseUrl
              placeholderText: "endpoint URL"
              text: root.baseUrl
              onTextEdited: root.baseUrl = text
            }
          }

          // ---- skills -------------------------------------------------
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
              height: Math.min(skillColumn.implicitHeight + Style.spacing.md * 2, Style.space(150))
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

          // ---- job ----------------------------------------------------
          Column {
            width: parent.width; spacing: Style.spacing.labelGap
            FieldLabel { text: "JOB DESCRIPTION / INSTRUCTIONS" }
            JobEditor {
              id: jobEditor
              width: parent.width
              height: Style.space(130)
              placeholderText: "What must this agent accomplish? Constraints, inputs, and what \"done\" looks like."
              foreground: root.foreground; fontFamily: root.fontFamily
              onEscaped: root.backToPanel()
            }
          }

          // ---- mode + actions ----------------------------------------
          Column {
            width: parent.width; spacing: Style.spacing.labelGap
            FieldLabel { text: "SESSION" }
            ButtonGroup {
              options: [ { value: "interactive", label: "Interactive chat" }, { value: "unattended", label: "Unattended one-shot" } ]
              value: root.mode
              foreground: root.foreground; fontFamily: root.fontFamily
              onChanged: function(v) { root.mode = v }
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
              tooltipText: "The same form as step-by-step prompts in a terminal"
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: { Quickshell.execDetached([root.launcher, "--popup", "new"]); root.close() }
            }
            Button {
              text: "Reload"
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.loadInfo()
            }
          }

          // ---- saved agents ------------------------------------------
          PanelSeparator { width: parent.width; foreground: root.foreground; visible: root.savedOptions.length > 0 }
          Column {
            width: parent.width; spacing: Style.spacing.labelGap
            visible: root.savedOptions.length > 0
            FieldLabel { text: "SAVED AGENTS" }
            Row {
              width: parent.width; spacing: Style.spacing.controlGap
              PanelDropdown {
                id: savedDrop
                width: parent.width - launchSavedBtn.width - manageBtn.width - parent.spacing * 2
                showLabel: false
                options: root.savedOptions
                value: root.savedName
                popupParent: keyCatcher
                ownerOpen: root.opened
                foreground: root.foreground; fontFamily: root.fontFamily
                onChanged: function(v) { root.savedName = v }
              }
              Button { id: launchSavedBtn; text: "Launch"; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.launchSaved() }
              Button { id: manageBtn; text: "Manage…"; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.openManager() }
            }
          }
          Item { width: 1; height: Style.spacing.sm }
        }
      }
    }
  }
}
