import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Add a backend: a shared OpenAI-compatible endpoint (URL + key), or a Modal
// vLLM server on a GPU you pick (dedicated app or sandbox). Submits
// `omarchy-agent-launcher backends add …`; the endpoint key travels in the
// child's environment (OAL_BACKEND_KEY), never on the command line.
Item {
  id: form
  required property var dash
  property var gpus: []                 // [{id, vram_gb, hourly_usd, label, suggested_model}] from info --json
  signal added()

  property string kind: "modal-dedicated"
  property string backendId: ""
  property string label: ""
  property string model: ""
  property bool modelTouched: false
  property string url: ""
  property string key: ""
  property string gpu: "L4"
  property int gpuCount: 1
  property string scaledown: "15"
  property string hours: "4"
  property string ctx: "32768"
  property string inPerM: ""
  property string outPerM: ""
  property bool busy: false
  property string error: ""

  readonly property bool isEndpoint: kind === "endpoint"
  readonly property bool editing: idField.activeFocus || labelField.activeFocus || modelField.activeFocus || urlField.activeFocus || keyField.activeFocus
    || scaleField.activeFocus || hoursField.activeFocus || ctxField.activeFocus || inField.activeFocus || outField.activeFocus
  readonly property bool popupOpen: gpuDrop.popupOpen
  readonly property var gpuOptions: gpus.map(function(g) { return { value: g.id, label: g.label } })
  readonly property var gpuInfo: findGpu(gpu)
  readonly property real hourly: gpuInfo ? gpuInfo.hourly_usd * gpuCount : 0
  function findGpu(id) { for (var i = 0; i < gpus.length; i++) if (gpus[i].id === id) return gpus[i]; return null }
  function suggestModel() {
    if (modelTouched || isEndpoint) return
    var vram = (gpuInfo ? gpuInfo.vram_gb : 24) * gpuCount
    model = vram >= 240 ? "Qwen/Qwen3-235B-A22B-Instruct-2507-FP8" : vram >= 140 ? "NousResearch/Hermes-4-70B" : vram >= 80 ? "Qwen/Qwen3-32B" : vram >= 40 ? "Qwen/Qwen3-14B" : "Qwen/Qwen3-8B"
  }
  onGpuChanged: suggestModel()
  onGpuCountChanged: suggestModel()
  onKindChanged: { if (!isEndpoint) suggestModel() }
  Component.onCompleted: suggestModel()
  implicitHeight: visible ? box.implicitHeight : 0

  function submit() {
    if (busy) return
    error = ""
    var id = backendId.trim()
    if (id === "") { error = "Give the backend a short id (letters, digits, dashes)."; idField.forceActiveFocus(); return }
    if (model.trim() === "") { error = "Name the model (a Hugging Face id for Modal, the served model id for an endpoint)."; return }
    var argv = [dash.launcher, "backends", "add", "--id", id, "--kind", kind, "--model", model.trim(), "--ctx", ctx.trim() === "" ? "32768" : ctx.trim()]
    if (label.trim() !== "") argv.push("--label", label.trim())
    var env = {}
    if (isEndpoint) {
      if (url.trim() === "") { error = "Paste the endpoint URL."; urlField.forceActiveFocus(); return }
      argv.push("--url", url.trim())
      if (key.trim() !== "") { argv.push("--key-env"); env.OAL_BACKEND_KEY = key.trim() }
    } else {
      argv.push("--gpu", gpu, "--gpu-count", String(gpuCount), "--scaledown", scaledown.trim() === "" ? "15" : scaledown.trim(), "--timeout-hours", hours.trim() === "" ? "4" : hours.trim())
    }
    if (inPerM.trim() !== "") argv.push("--input-per-m", inPerM.trim())
    if (outPerM.trim() !== "") argv.push("--output-per-m", outPerM.trim())
    addProc.environment = env
    addProc.command = argv
    busy = true
    addProc.running = true
  }
  Process {
    id: addProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: addErr; waitForEnd: true }
    onExited: function(code) {
      form.busy = false
      if (code === 0) { form.key = ""; form.backendId = ""; form.label = ""; form.error = ""; form.added() }
      else form.error = String(addErr.text || "").trim().replace(/^agent-launcher: /, "") || ("add failed (exit " + code + ")")
    }
  }

  component Cap: Text { textFormat: Text.PlainText; color: Qt.darker(form.dash.foreground, 1.4); font.family: form.dash.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
  component Note: Text { textFormat: Text.PlainText; color: form.dash.dim; font.family: form.dash.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
  component In: TextField {
    foreground: form.dash.foreground; font.family: form.dash.fontFamily
    verticalPadding: Style.spacing.controlPaddingY
    Keys.onEscapePressed: function(event) { form.dash.focusCatcher(); event.accepted = true }
  }

  BorderSurface {
    id: box
    width: parent.width
    radius: Style.cornerRadius
    color: Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.04)
    borderSpec: Border.flat(Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.10), 1)
    implicitHeight: col.implicitHeight + Style.space(24)

    Column {
      id: col
      anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
      anchors.margins: Style.space(12)
      spacing: Style.space(8)

      Column {
        width: parent.width; spacing: Style.spacing.labelGap
        Cap { text: "KIND" }
        ButtonGroup {
          options: [ { value: "modal-dedicated", label: "Modal endpoint (scales to zero)" }, { value: "modal-sandbox", label: "Modal sandbox (isolated, fixed lifetime)" }, { value: "endpoint", label: "Shared endpoint (URL + key)" } ]
          value: form.kind
          foreground: dash.foreground; fontFamily: dash.fontFamily
          onChanged: function(v) { form.kind = v }
        }
        Note {
          width: parent.width
          text: form.kind === "modal-dedicated" ? "A vLLM server deployed to your Modal workspace. Wakes on the first request (model load takes a minute or two), sleeps after the idle window; you pay GPU time only while a container runs."
              : form.kind === "modal-sandbox" ? "The same server inside one isolated Modal Sandbox that nothing else shares. Billed from start until you stop it or its lifetime ends; ends early after the idle window."
              : "Any OpenAI-compatible /v1 URL you were given: a Modal endpoint a teammate deployed, a team vLLM server, a gateway."
        }
      }

      Row {
        width: parent.width; spacing: Style.space(12)
        readonly property real half: (width - spacing) / 2
        Column {
          width: parent.half; spacing: Style.spacing.labelGap
          Cap { text: "ID" }
          In { id: idField; width: parent.width; placeholderText: form.isEndpoint ? "team-llm" : "big-qwen"; text: form.backendId; onTextEdited: form.backendId = text }
        }
        Column {
          width: parent.half; spacing: Style.spacing.labelGap
          Cap { text: "LABEL (optional)" }
          In { id: labelField; width: parent.width; placeholderText: "shown in lists"; text: form.label; onTextEdited: form.label = text }
        }
      }

      Column {
        width: parent.width; spacing: Style.spacing.labelGap
        visible: !form.isEndpoint
        Cap { text: "GPU  ·  USD per GPU-hour" }
        PanelDropdown {
          id: gpuDrop
          width: parent.width
          showLabel: false
          options: form.gpuOptions.length ? form.gpuOptions : [{ value: "L4", label: "L4 (GPU table not loaded yet)" }]
          value: form.gpu
          popupParent: form
          ownerOpen: form.visible
          foreground: dash.foreground; fontFamily: dash.fontFamily
          onChanged: function(v) { form.gpu = v }
        }
        Row {
          spacing: Style.spacing.controlGap
          Cap { text: "COUNT"; anchors.verticalCenter: parent.verticalCenter }
          ButtonGroup {
            options: [ { value: "1", label: "1" }, { value: "2", label: "2" }, { value: "4", label: "4" }, { value: "8", label: "8" } ]
            value: String(form.gpuCount)
            foreground: dash.foreground; fontFamily: dash.fontFamily
            onChanged: function(v) { form.gpuCount = parseInt(v) }
          }
          Text { textFormat: Text.PlainText; anchors.verticalCenter: parent.verticalCenter; text: form.gpuInfo ? "  ≈ $" + (Math.round(form.hourly * 100) / 100) + " per hour while running  ·  " + (form.gpuInfo.vram_gb * form.gpuCount) + " GB VRAM" : ""; color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall }
        }
      }

      Column {
        width: parent.width; spacing: Style.spacing.labelGap
        Cap { text: form.isEndpoint ? "SERVED MODEL ID" : "MODEL  ·  Hugging Face id served by vLLM (tool calling on, Hermes parser)" }
        In { id: modelField; width: parent.width; placeholderText: "Qwen/Qwen3-8B"; text: form.model; onTextEdited: { form.model = text; form.modelTouched = true } }
        Note { width: parent.width; visible: !form.isEndpoint; text: "Suggested for the VRAM you picked; change freely. Gated models need HF_TOKEN in secrets.env (omarchy-agent-launcher settings) — see the README." }
      }

      Column {
        width: parent.width; spacing: Style.spacing.labelGap
        visible: form.isEndpoint
        Cap { text: "URL" }
        In { id: urlField; width: parent.width; placeholderText: "https://…modal.run/v1"; text: form.url; onTextEdited: form.url = text }
        Cap { text: "API KEY (optional, saved once with mode 600)" }
        In { id: keyField; width: parent.width; password: true; placeholderText: "bearer token the server expects"; text: form.key; onTextEdited: form.key = text }
      }

      Row {
        width: parent.width; spacing: Style.space(12)
        readonly property real third: (width - spacing * 2) / 3
        Column {
          width: parent.third; spacing: Style.spacing.labelGap; visible: !form.isEndpoint
          Cap { text: "IDLE MINUTES" }
          In { id: scaleField; width: parent.width; text: form.scaledown; onTextEdited: form.scaledown = text }
        }
        Column {
          width: parent.third; spacing: Style.spacing.labelGap; visible: form.kind === "modal-sandbox"
          Cap { text: "LIFETIME HOURS (max 24)" }
          In { id: hoursField; width: parent.width; text: form.hours; onTextEdited: form.hours = text }
        }
        Column {
          width: parent.third; spacing: Style.spacing.labelGap
          Cap { text: "CONTEXT TOKENS" }
          In { id: ctxField; width: parent.width; text: form.ctx; onTextEdited: form.ctx = text }
        }
      }

      Row {
        width: parent.width; spacing: Style.space(12)
        readonly property real half: (width - spacing) / 2
        Column {
          width: parent.half; spacing: Style.spacing.labelGap
          Cap { text: "PRICE PER 1M INPUT TOKENS, USD (optional)" }
          In { id: inField; width: parent.width; placeholderText: form.isEndpoint ? "if the operator charges per token" : "leave empty: cost is GPU time"; text: form.inPerM; onTextEdited: form.inPerM = text }
        }
        Column {
          width: parent.half; spacing: Style.spacing.labelGap
          Cap { text: "PRICE PER 1M OUTPUT TOKENS, USD (optional)" }
          In { id: outField; width: parent.width; placeholderText: "defaults to the input price"; text: form.outPerM; onTextEdited: form.outPerM = text }
        }
      }

      Text { textFormat: Text.PlainText; width: parent.width; visible: form.error !== ""; text: form.error; color: dash.urgent; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.Wrap }
      Row {
        spacing: Style.spacing.controlGap
        Button { text: form.busy ? "Saving…" : (form.isEndpoint ? "Save endpoint" : "Save (deploy later)"); iconText: "󰆓"; selected: true; enabled: !form.busy; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: form.submit() }
        Note { anchors.verticalCenter: parent.verticalCenter; text: form.isEndpoint ? "Ready to use as soon as it is saved." : "Nothing is billed until you press Deploy / Start on the new row." }
      }
    }
  }
}
