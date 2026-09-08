import QtQuick
import qs.Commons
import qs.Ui

// One checkbox row (the check square is the same one Ui/MultiSelect draws).
Item {
  id: root
  property string label: ""
  property bool selected: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  signal toggled()

  implicitHeight: Style.space(24)

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: hover.hovered ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"
  }

  Row {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.md
    spacing: Style.spacing.rowGap

    BorderSurface {
      id: box
      width: Style.space(16)
      height: Style.space(16)
      radius: Math.max(2, Style.cornerRadius / 2)
      anchors.verticalCenter: parent.verticalCenter
      color: root.selected ? Style.selectedFillFor(root.foreground, root.accent) : "transparent"
      borderSpec: Border.controlSpec(root.selected ? "selected" : "normal", root.foreground, root.accent)

      Text {
        anchors.centerIn: parent
        visible: root.selected
        text: "✓"
        color: Style.selectedStateColor(root.foreground, root.accent)
        font.family: root.fontFamily
        font.pixelSize: Math.round(box.height * 0.85)
        font.bold: true
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width - box.width - parent.spacing
      anchors.verticalCenter: parent.verticalCenter
      text: root.label
      color: hover.hovered ? Style.hoverStateColor(root.foreground, root.accent) : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
  }

  HoverHandler { id: hover }
  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.toggled()
  }
}
