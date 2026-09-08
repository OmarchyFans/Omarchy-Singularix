import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar button for the Agent Launcher. One click opens the launcher form in a
// floating Omarchy terminal. Everything interactive (the gum form, provider
// sign-in, Docker and Sprite provisioning) lives in bin/omarchy-agent-launcher
// inside this plugin folder, so this widget stays a thin, side-effect-free
// launcher: no network, no secrets, nothing parsed inside the shell process.
//
// The launch string is a fixed literal built from the plugin's own on-disk
// path, so routing it through bar.run (`bash -lc <command>`) carries no
// injection surface. `omarchy-shell shell toggle fans.omarchy.agent-launcher`
// (the documented keybinding) lands in open() below.
BarWidget {
  id: root
  moduleName: "fans.omarchy.agent-launcher"

  property bool opened: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string launcher: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/fans.omarchy.agent-launcher/bin/omarchy-agent-launcher"

  function open() { launch() }
  function close() { opened = false }

  function launch() {
    if (root.bar && typeof root.bar.run === "function")
      root.bar.run("'" + launcher + "' --popup")
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱚝"                    // nf-md-robot_happy
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: "Launch an AI agent"
    onPressed: root.launch()
  }
}
