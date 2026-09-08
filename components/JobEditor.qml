import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Multi-line editor styled like Ui/TextField (the kit has no text area).
// Scrolls inside a fixed height; Esc hands focus back to the panel.
Item {
  id: root
  property alias text: area.text
  property string placeholderText: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  readonly property bool editing: area.activeFocus
  signal escaped()

  function focusEditor() { area.forceActiveFocus() }

  readonly property bool _hot: hover.hovered
  readonly property var _borderSpec: Border.controlSpec(area.activeFocus ? "focus" : (_hot ? "hover-cursor" : "normal"), foreground, accent)

  implicitHeight: Style.space(120)

  BorderSurface {
    anchors.fill: parent
    color: Style.controlFill(area.activeFocus, root._hot, root.foreground, root.accent)
    borderSpec: root._borderSpec
    radius: Style.cornerRadius
  }
  HoverHandler { id: hover }

  Flickable {
    id: flick
    anchors.fill: parent
    anchors.margins: Style.spacing.xs
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
    TextArea.flickable: TextArea {
      id: area
      wrapMode: TextEdit.Wrap
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      color: root.foreground
      selectionColor: Style.selectionFillFor(root.foreground, root.accent)
      selectedTextColor: root.foreground
      placeholderText: root.placeholderText
      placeholderTextColor: Qt.darker(root.foreground, 1.6)
      leftPadding: Style.spacing.controlPaddingX
      rightPadding: Style.spacing.controlPaddingX
      topPadding: Style.spacing.inputPaddingY
      bottomPadding: Style.spacing.inputPaddingY
      background: null
      Keys.onEscapePressed: function(event) { root.escaped(); event.accepted = true }
    }
  }
}
