import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// One list-style agenda entry in the popout (Tabs, Columns), on one line:
//   lead | KEYWORD [A] title ……………… trail
// `lead` and `trail` are a row block's {text, tone} (Model.layoutModel);
// `tones` maps a tone to its colour. The highlight comes from `hasCursor`
// (keyboard and hover alike, set by the panel), and only then does the
// trail turn into the entry's file:line, the place ↵ jumps to. Clicking the
// keyword chip asks for the state picker instead; while a change is in
// flight the row dims and its lead reads "…". `dense` is the shorter row of
// Columns' right pane.
CursorSurface {
  id: root

  property var item: null
  property var payload: null
  property var lead: null
  property var trail: null
  property bool past: false
  property bool flag: false
  property bool dense: false
  property var tones: ({})
  property string fontFamily: Style.font.family
  property int leadWidth: Style.space(40)
  property bool stateEnabled: false
  property bool pending: false
  // The entry Org's clock runs on: tinted like org-agenda-clocking; its
  // trail is then the time ("◷ 0:23", Model's), shown bold.
  property bool clocked: false

  signal pointerMoved(var area, var mouse)
  signal activated()
  signal keywordClicked()

  readonly property color textColor: Commons.Color.popups.text
  readonly property color mutedColor: Commons.Color.muted
  readonly property string keyword: item && item.todo ? item.todo : ""
  readonly property string keywordHex: keyword ? Model.keywordColor(payload, keyword) : ""
  readonly property color keywordColor: keywordHex !== "" ? keywordHex : mutedColor
  readonly property bool done: !!item && item.done
  readonly property bool leadUrgent: !!lead && (lead.tone === "urgent" || lead.tone === "late")

  function toneColor(cell, fallback) {
    return cell && tones[cell.tone] !== undefined ? tones[cell.tone] : fallback
  }

  foreground: textColor
  // The cursor's highlight wins over the clock's tint.
  color: hasCursor ? fill : clocked ? Util.alpha(Commons.Color.accent, 0.12) : "transparent"
  implicitHeight: dense ? Style.space(23) : Style.spacing.popupRowHeight

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onPositionChanged: function(event) { root.pointerMoved(mouse, event) }
    onClicked: root.activated()
  }

  RowLayout {
    anchors.fill: parent
    anchors.leftMargin: Style.spacing.md
    anchors.rightMargin: Style.spacing.md
    spacing: Style.spacing.lg
    opacity: root.pending ? 0.45 : root.done ? 0.5 : 1

    PlainText {
      Layout.preferredWidth: root.leadWidth
      Layout.alignment: Qt.AlignVCenter
      horizontalAlignment: Text.AlignRight
      text: root.pending ? "…" : root.lead ? root.lead.text : ""
      color: root.pending ? root.mutedColor : root.toneColor(root.lead, root.mutedColor)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.features: { "tnum": 1 }
    }

    // TODO keyword: its Org face colour, on a faint wash of itself.
    Rectangle {
      visible: root.keyword !== ""
      Layout.alignment: Qt.AlignVCenter
      implicitWidth: keywordText.implicitWidth + Style.spacing.md * 2
      implicitHeight: keywordText.implicitHeight + Style.spacing.xxs * 2
      radius: Style.cornerRadius
      color: Util.alpha(root.keywordColor, 0.14)
      border.width: 1
      border.color: Util.alpha(root.keywordColor, 0.35)

      PlainText {
        id: keywordText
        anchors.centerIn: parent
        text: root.keyword
        color: root.keywordColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      // Above the row's own area: a click here changes the state, not opens.
      MouseArea {
        visible: root.stateEnabled
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.keywordClicked()
      }
    }

    PlainText {
      visible: !!root.item && !!root.item.priority
      Layout.alignment: Qt.AlignVCenter
      text: root.item && root.item.priority ? "[" + root.item.priority + "]" : ""
      color: root.item && root.item.priority === "A" ? Commons.Color.accent : root.mutedColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    PlainText {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      text: root.item ? root.item.title : ""
      color: root.past ? root.mutedColor : root.textColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.strikeout: root.done
    }

    // nf-md-flag: the entry carries a deadline.
    PlainText {
      visible: root.flag
      Layout.alignment: Qt.AlignVCenter
      text: String.fromCodePoint(0xf023b)
      color: root.leadUrgent ? Commons.Color.urgent : Commons.Color.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    PlainText {
      Layout.alignment: Qt.AlignVCenter
      Layout.maximumWidth: Style.space(150)
      text: !root.item ? ""
        : root.hasCursor ? Model.rowLocation(root.item) + " " + String.fromCodePoint(0xf0311)   // nf-md-keyboard-return
        : root.trail ? root.trail.text : ""
      color: root.hasCursor ? root.mutedColor : root.toneColor(root.trail, root.mutedColor)
      elide: root.hasCursor ? Text.ElideLeft : Text.ElideRight
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: root.clocked && !root.hasCursor
      font.features: { "tnum": 1 }
    }
  }
}
