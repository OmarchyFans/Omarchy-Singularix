import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Add a backend: any OpenAI-compatible endpoint (URL + key), such as a GPU
// machine on Omarchy.Fans Cloud or a team server. Submits
// `omarchy-agent-launcher backends add …`; the key travels in the child's
// environment (OAL_BACKEND_KEY), never on the command line.
Item {
  id: form
  required property var dash
  signal added()

  property string backendId: ""
  property string label: ""
  property string model: ""
  property string url: ""
  property string key: ""
  property string ctx: "32768"
  property string inPerM: ""
  property string outPerM: ""
  property bool busy: false
  property string error: ""

  readonly property bool editing: idField.activeFocus || labelField.activeFocus || modelField.activeFocus || urlField.activeFocus || keyField.activeFocus
    || ctxField.activeFocus || inField.activeFocus || outField.activeFocus
  readonly property bool popupOpen: false
  implicitHeight: visible ? box.implicitHeight : 0

  function submit() {
    if (busy) return
    error = ""
    var id = backendId.trim()
    if (id === "") { error = "Give the backend a short id (letters, digits, dashes)."; idField.forceActiveFocus(); return }
    if (url.trim() === "") { error = "Paste the endpoint URL."; urlField.forceActiveFocus(); return }
    if (model.trim() === "") { error = "Name the model the endpoint serves."; modelField.forceActiveFocus(); return }
    var argv = [dash.launcher, "backends", "add", "--id", id, "--kind", "endpoint", "--url", url.trim(), "--model", model.trim(),
                "--ctx", ctx.trim() === "" ? "32768" : ctx.trim()]
    if (label.trim() !== "") argv.push("--label", label.trim())
    var env = {}
    if (key.trim() !== "") { argv.push("--key-env"); env.OAL_BACKEND_KEY = key.trim() }
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

      Note {
        width: parent.width
        text: "Any OpenAI-compatible /v1 URL: a GPU machine on Omarchy.Fans Cloud (its relay URL and ofg_ key, see  omarchy-agent-launcher cloud gpus), a team vLLM server, a gateway."
      }

      Row {
        width: parent.width; spacing: Style.space(12)
        readonly property real half: (width - spacing) / 2
        Column {
          width: parent.half; spacing: Style.spacing.labelGap
          Cap { text: "ID" }
          In { id: idField; width: parent.width; placeholderText: "team-llm"; text: form.backendId; onTextEdited: form.backendId = text }
        }
        Column {
          width: parent.half; spacing: Style.spacing.labelGap
          Cap { text: "LABEL (optional)" }
          In { id: labelField; width: parent.width; placeholderText: "shown in lists"; text: form.label; onTextEdited: form.label = text }
        }
      }

      Column {
        width: parent.width; spacing: Style.spacing.labelGap
        Cap { text: "URL" }
        In { id: urlField; width: parent.width; placeholderText: "https://…/v1"; text: form.url; onTextEdited: form.url = text }
        Cap { text: "API KEY (optional, saved once with mode 600)" }
        In { id: keyField; width: parent.width; password: true; placeholderText: "bearer token the server expects"; text: form.key; onTextEdited: form.key = text }
        Cap { text: "SERVED MODEL ID" }
        In { id: modelField; width: parent.width; placeholderText: "Qwen/Qwen3-8B"; text: form.model; onTextEdited: form.model = text }
      }

      Row {
        width: parent.width; spacing: Style.space(12)
        readonly property real third: (width - spacing * 2) / 3
        Column {
          width: parent.third; spacing: Style.spacing.labelGap
          Cap { text: "CONTEXT TOKENS" }
          In { id: ctxField; width: parent.width; text: form.ctx; onTextEdited: form.ctx = text }
        }
        Column {
          width: parent.third; spacing: Style.spacing.labelGap
          Cap { text: "USD / 1M INPUT (optional)" }
          In { id: inField; width: parent.width; placeholderText: "if billed per token"; text: form.inPerM; onTextEdited: form.inPerM = text }
        }
        Column {
          width: parent.third; spacing: Style.spacing.labelGap
          Cap { text: "USD / 1M OUTPUT (optional)" }
          In { id: outField; width: parent.width; placeholderText: "defaults to input"; text: form.outPerM; onTextEdited: form.outPerM = text }
        }
      }

      Text { textFormat: Text.PlainText; width: parent.width; visible: form.error !== ""; text: form.error; color: dash.urgent; font.family: dash.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.Wrap }
      Row {
        spacing: Style.spacing.controlGap
        Button { text: form.busy ? "Saving…" : "Save endpoint"; iconText: "󰆓"; selected: true; enabled: !form.busy; foreground: dash.foreground; fontFamily: dash.fontFamily; onClicked: form.submit() }
        Note { anchors.verticalCenter: parent.verticalCenter; text: "Ready to use as soon as it is saved." }
      }
    }
  }
}
