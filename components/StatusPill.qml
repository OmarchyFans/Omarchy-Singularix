import QtQuick
import qs.Commons

// Small rounded status label: running (green) · blocked (urgent) · done · idle (dim).
Rectangle {
  id: pill
  property string status: "idle"
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  readonly property color tone: status === "running" ? "#9ece6a" : (status === "blocked" ? Color.urgent : (status === "done" ? Color.accent : Qt.darker(foreground, 1.4)))
  implicitWidth: label.implicitWidth + Style.space(12)
  implicitHeight: label.implicitHeight + Style.space(4)
  radius: height / 2
  color: Qt.rgba(tone.r, tone.g, tone.b, 0.16)
  border.width: 1
  border.color: Qt.rgba(tone.r, tone.g, tone.b, 0.6)
  Text {
    id: label
    anchors.centerIn: parent
    text: pill.status
    color: pill.tone
    font.family: pill.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }
}
