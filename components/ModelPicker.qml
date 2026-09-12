import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Model picker for Rix, fed by `omarchy-agent-launcher models --json`.
//
// Local models come first: a single local model is one row; several sit under a
// "Local models" row that expands with Right or Enter and collapses with Left or
// Escape. Then every vendor, usable ones first: a header per vendor and one row
// per model with its price per million tokens (in / out), the country where the
// vendor processes data, and an IP-safe badge. Rows of a vendor without a key or
// sign-in are dimmed; choosing one emits needsKey instead of failing.
//
// Like PanelDropdown it never assigns backend/model itself: the caller runs the
// setup and the new status flows back in.
Item {
  id: root

  property var tree: null
  property string backend: ""
  property string model: ""
  property Item popupParent: null
  property bool ownerOpen: true
  property color foreground: Color.popups.text
  property color background: Color.popups.background
  property color popupBorder: Color.popups.border
  property color accent: Color.accent
  property color urgent: Color.urgent
  property color safeColor: "#9ece6a"
  property string fontFamily: Style.font.family
  property int rowHeight: Style.spacing.controlHeight
  property int popupRowHeight: Math.max(Style.spacing.popupRowHeight, Style.space(30))
  property int visibleRows: 12
  property int popupWidth: Style.space(860)
  property bool hasCursor: false
  property bool expanded: false

  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property var popupBorderSpec: Border.localOrSurfaceSpec(
    "popups", "border", popupBorder, Color.popups.border, Style.normalBorderWidth)
  readonly property bool popupOpen: menu.opened
  property var rows: []

  signal picked(string backend, string model)
  signal needsKey(string backend, string label, string needs)

  onOwnerOpenChanged: if (!ownerOpen) menu.close()
  onVisibleChanged: if (!visible) menu.close()
  onTreeChanged: rebuild()
  Component.onCompleted: rebuild()

  function open() { menu.open() }
  function close() { menu.close() }
  function toggle() { menu.opened ? menu.close() : menu.open() }

  // ---- data -------------------------------------------------------------------
  function localRows() { return tree && tree.local && tree.local.rows ? tree.local.rows : [] }
  function onlineEntries() { return tree && tree.online ? tree.online : [] }
  function served() { return tree && tree.local && tree.local.served ? tree.local.served : "" }
  function stripGguf(s) { return String(s || "").replace(/\.gguf$/, "") }
  function fmtPrice(v) { return (v === null || v === undefined) ? "" : (v % 1 === 0 ? String(v) : String(Math.round(v * 100) / 100)) }
  function priceText(m) { return (m.input === null || m.input === undefined) ? "" : "$" + fmtPrice(m.input) + " / $" + fmtPrice(m.output) }

  function localRow(r, indent) {
    return { kind: "local", backend: r.backend, model: r.model, label: r.name || stripGguf(r.model),
             detail: r.served ? "serving now" : (r.source === "ollama" ? "Ollama" : "on disk"),
             vendor: r.source === "ollama" ? "Ollama" : "llama.cpp", price: "free", country: "this machine",
             ipSafe: true, badge: "safe", ready: true, needs: "", entryLabel: "Local GPU", indent: indent, served: r.served === true }
  }

  function rebuild() {
    var out = []
    var loc = localRows()
    if (loc.length > 1) {
      out.push({ kind: "group", label: "Local models", detail: loc.length + " on this machine" + (served() !== "" ? "  ·  serving " + stripGguf(served()) : ""),
                 ready: true, indent: false })
      if (expanded) for (var i = 0; i < loc.length; i++) out.push(localRow(loc[i], true))
    } else if (loc.length === 1) {
      out.push(localRow(loc[0], false))
    }
    var on = onlineEntries()
    for (var e = 0; e < on.length; e++) {
      var en = on[e]
      if (!en.models || en.models.length === 0) continue
      out.push({ kind: "vendor", label: en.vendor_label + (en.label && en.label !== en.vendor_label ? "  ·  " + en.label : ""),
                 detail: en.ready ? "ready" : (en.needs || "not set up"), ready: en.ready, indent: false })
      for (var j = 0; j < en.models.length; j++) {
        var m = en.models[j]
        out.push({ kind: "model", backend: en.backend, model: m.id,
                   label: m.name && m.name !== m.id ? m.name : m.id, detail: m.name && m.name !== m.id ? m.id : "",
                   vendor: en.vendor_label, price: priceText(m), country: en.country || "",
                   ipSafe: en.ip_safe, badge: en.badge || "", basis: en.basis || "", ready: en.ready === true, needs: en.needs || "",
                   entryLabel: en.label || en.vendor_label, indent: false })
      }
    }
    rows = out
  }

  function currentLabel() {
    if (backend === "") return "Choose a model"
    if (backend === "local" || backend === "ollama") return "Local  ·  " + stripGguf(backend === "local" && served() !== "" ? served() : model)
    var on = onlineEntries()
    for (var e = 0; e < on.length; e++) if (on[e].backend === backend) return on[e].vendor_label + "  ·  " + model
    return backend + "  ·  " + model
  }

  // ---- cursor -------------------------------------------------------------------
  function selectable(i) { return i >= 0 && i < rows.length && rows[i].kind !== "vendor" }
  function initialIndex() {
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      if ((r.kind === "model" || r.kind === "local") && r.backend === backend && (r.model === model || (backend === "local" && r.served))) return i
    }
    if (backend === "local" && rows.length && rows[0].kind === "group") return 0
    for (var k = 0; k < rows.length; k++) if (selectable(k)) return k
    return -1
  }
  function step(delta) {
    var i = list.currentIndex
    do { i += delta } while (i >= 0 && i < rows.length && !selectable(i))
    if (selectable(i)) { list.currentIndex = i; list.positionViewAtIndex(i, ListView.Contain) }
  }
  function setExpanded(on, cursor) {
    expanded = on
    rebuild()
    Qt.callLater(function() { list.currentIndex = cursor; list.positionViewAtIndex(cursor, ListView.Contain) })
  }
  function inLocalGroup(i) { return i >= 0 && i < rows.length && (rows[i].kind === "group" || (rows[i].kind === "local" && rows[i].indent)) }
  function choose(i) {
    if (i < 0 || i >= rows.length) return
    var r = rows[i]
    if (r.kind === "vendor") return
    if (r.kind === "group") { setExpanded(!expanded, 0); return }
    menu.close()
    if (r.kind === "model" && !r.ready) { root.needsKey(r.backend, r.entryLabel, r.needs); return }
    root.picked(r.backend, r.model)
  }

  function menuPosition() {
    if (!popupParent) return Qt.point(0, trigger.height + Style.spacing.xxs)
    var below = trigger.mapToItem(popupParent, 0, trigger.height + Style.spacing.xxs)
    var w = Math.min(root.popupWidth, popupParent.width - Style.space(16))
    var x = Math.max(Style.space(8), Math.min(below.x, popupParent.width - w - Style.space(8)))
    if (below.y + menu.implicitHeight <= popupParent.height) return Qt.point(x, below.y)
    var above = trigger.mapToItem(popupParent, 0, -menu.implicitHeight - Style.spacing.xxs)
    return Qt.point(x, Math.max(0, above.y))
  }

  implicitWidth: Style.spacing.dropdownWidth
  implicitHeight: rowHeight

  // ---- trigger ------------------------------------------------------------------
  BorderSurface {
    id: trigger
    width: parent.width
    height: root.rowHeight
    radius: Style.cornerRadius
    activeFocusOnTab: true
    readonly property bool focused: activeFocus
    readonly property bool hot: triggerHover.hovered || root.hasCursor
    color: Style.controlFill(focused, hot, root.foreground, root.accent)
    borderSpec: Border.controlSpec(focused ? "focus" : (hot ? "hover-cursor" : "normal"), root.foreground, root.accent)

    HoverHandler { id: triggerHover }

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space || event.key === Qt.Key_Down) {
        root.toggle(); event.accepted = true
      } else if (event.key === Qt.Key_Escape && menu.opened) {
        menu.close(); event.accepted = true
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: chevron.left
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: trigger.borderLeft + Style.spacing.controlPaddingX
      anchors.rightMargin: Style.spacing.md
      text: root.currentLabel()
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
    Text {
      id: chevron
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.rightMargin: trigger.borderRight + Style.spacing.controlGap
      text: menu.opened ? "󰅃" : "󰅀"
      color: Qt.darker(root.foreground, 1.2)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: { trigger.forceActiveFocus(); root.toggle() }
    }
  }

  // ---- popup ----------------------------------------------------------------------
  Popup {
    id: menu
    parent: root.popupParent || root
    readonly property point anchoredPosition: root.menuPosition()
    x: anchoredPosition.x
    y: anchoredPosition.y
    width: root.popupParent ? Math.min(root.popupWidth, root.popupParent.width - Style.space(16)) : root.popupWidth
    implicitHeight: Math.min(Math.max(1, root.rows.length), root.visibleRows) * root.popupRowHeight + Style.space(8)
    padding: Style.spacing.hairline
    leftPadding: Border.left(root.popupBorderSpec) + Style.space(4)
    rightPadding: Border.right(root.popupBorderSpec) + Style.space(4)
    topPadding: Border.top(root.popupBorderSpec) + Style.space(4)
    bottomPadding: Border.bottom(root.popupBorderSpec) + Style.space(4)
    focus: true
    popupType: Popup.Item

    background: BorderSurface {
      color: root.background
      borderSpec: root.popupBorderSpec
      radius: Style.cornerRadius
    }

    onOpened: {
      root.rebuild()
      Qt.callLater(function() {
        list.currentIndex = root.initialIndex()
        if (list.currentIndex >= 0) list.positionViewAtIndex(list.currentIndex, ListView.Center)
        list.forceActiveFocus()
      })
    }

    contentItem: ListView {
      id: list
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      model: root.rows
      currentIndex: -1
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        var i = list.currentIndex
        var r = (i >= 0 && i < root.rows.length) ? root.rows[i] : null
        if (event.key === Qt.Key_Down || event.text === "j") { root.step(1); event.accepted = true }
        else if (event.key === Qt.Key_Up || event.text === "k") { root.step(-1); event.accepted = true }
        else if (event.key === Qt.Key_Right || event.text === "l") {
          if (r && r.kind === "group" && !root.expanded) root.setExpanded(true, i)
          event.accepted = true
        } else if (event.key === Qt.Key_Left || event.text === "h") {
          if (root.expanded && root.inLocalGroup(i)) root.setExpanded(false, 0)
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          if (root.expanded && root.inLocalGroup(i)) root.setExpanded(false, 0)
          else menu.close()
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.choose(i); event.accepted = true
        }
      }

      delegate: Rectangle {
        id: rowItem
        required property var modelData
        required property int index
        readonly property bool isHeader: modelData.kind === "vendor"
        readonly property bool isCurrent: index === list.currentIndex && !isHeader
        readonly property color ink: modelData.ready === false ? root.dim : root.foreground
        width: list.width
        height: root.popupRowHeight
        color: isCurrent ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"
        radius: Style.space(4)
        opacity: modelData.kind === "model" && modelData.ready === false ? 0.6 : 1

        // Vendor header: name, how it signs in, and whether it is usable.
        Row {
          visible: rowItem.isHeader
          anchors.left: parent.left; anchors.leftMargin: Style.space(8)
          anchors.bottom: parent.bottom; anchors.bottomMargin: Style.space(3)
          spacing: Style.space(10)
          Text {
            textFormat: Text.PlainText
            text: String(rowItem.modelData.label || "").toUpperCase()
            color: root.foreground; opacity: 0.8
            font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            text: rowItem.modelData.detail || ""
            color: rowItem.modelData.ready ? root.safeColor : root.dim
            font.family: root.fontFamily; font.pixelSize: Style.font.caption
          }
        }

        // Selectable rows: the local group, local models, and vendor models.
        Item {
          visible: !rowItem.isHeader
          anchors.fill: parent
          anchors.leftMargin: Style.space(8) + (rowItem.modelData.indent ? Style.space(22) : 0)
          anchors.rightMargin: Style.space(8)

          Text {
            id: glyph
            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            width: Style.space(20)
            textFormat: Text.PlainText
            text: rowItem.modelData.kind === "group" ? (root.expanded ? "󰅀" : "󰅂") : (rowItem.modelData.kind === "local" ? "󰢮" : "")
            color: rowItem.isCurrent ? root.accent : root.dim
            font.family: root.fontFamily; font.pixelSize: Style.font.body
          }
          Column {
            anchors.left: glyph.right; anchors.right: columns.left; anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: rowItem.modelData.label || ""
              color: rowItem.isCurrent ? Style.hoverStateColor(root.foreground, root.accent) : rowItem.ink
              font.family: root.fontFamily; font.pixelSize: Style.font.body
              font.bold: rowItem.modelData.kind === "group" || rowItem.modelData.served === true
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              visible: text !== "" && rowItem.modelData.kind !== "model"
              textFormat: Text.PlainText
              text: rowItem.modelData.detail || ""
              color: root.dim
              font.family: root.fontFamily; font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          // Fixed columns: vendor · $in / $out per M · country · badge
          Row {
            id: columns
            visible: rowItem.modelData.kind !== "group"
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)
            Text {
              width: Style.space(120); textFormat: Text.PlainText; anchors.verticalCenter: parent.verticalCenter
              text: rowItem.modelData.kind === "model" && !rowItem.modelData.ready ? (rowItem.modelData.needs || "needs key") : (rowItem.modelData.vendor || "")
              color: rowItem.modelData.kind === "model" && !rowItem.modelData.ready ? root.urgent : root.dim
              font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight
            }
            Text {
              width: Style.space(110); textFormat: Text.PlainText; anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignRight
              text: rowItem.modelData.price || "—"
              color: rowItem.ink
              font.family: root.fontFamily; font.pixelSize: Style.font.caption
            }
            Text {
              width: Style.space(90); textFormat: Text.PlainText; anchors.verticalCenter: parent.verticalCenter
              text: rowItem.modelData.country || "unknown"
              color: root.dim
              font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight
            }
            Item {
              width: Style.space(96); height: badge.height; anchors.verticalCenter: parent.verticalCenter
              Rectangle {
                id: badge
                readonly property string kind: rowItem.modelData.badge || ""
                readonly property color tone: kind === "safe" ? root.safeColor : (kind === "unsafe" ? root.urgent : root.dim)
                visible: kind !== ""
                width: badgeText.implicitWidth + Style.space(12)
                height: badgeText.implicitHeight + Style.space(4)
                radius: height / 2
                color: Qt.rgba(tone.r, tone.g, tone.b, 0.16)
                border.width: 1
                border.color: Qt.rgba(tone.r, tone.g, tone.b, 0.6)
                Text {
                  id: badgeText
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: ({ safe: "IP-safe", unsafe: "not IP-safe", unverified: "unverified", varies: "varies" })[badge.kind] || ""
                  color: badge.tone
                  font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
                }
              }
            }
          }
        }

        MouseArea {
          anchors.fill: parent
          enabled: !rowItem.isHeader
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onPositionChanged: list.currentIndex = rowItem.index
          onClicked: root.choose(rowItem.index)
        }
      }
    }
  }
}
