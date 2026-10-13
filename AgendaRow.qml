import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// One agenda entry in the popout, on a single line:
//   time | KEYWORD [A] title ……………… category
// The highlight comes from `hasCursor` (keyboard and hover alike, set by the
// panel), and only then does the right column turn into the entry's
// file:line, the place ↵ jumps to.
CursorSurface {
  id: root

  property var item: null
  property var payload: null
  property string fontFamily: Style.font.family
  property int leadWidth: Style.space(40)

  signal pointerMoved(var area, var mouse)
  signal activated()

  readonly property color textColor: Commons.Color.popups.text
  readonly property color mutedColor: Commons.Color.muted
  readonly property var lead: item ? Model.rowLead(item) : ({ text: "", urgent: false })
  readonly property string keyword: item && item.todo ? item.todo : ""
  readonly property string keywordHex: keyword ? Model.keywordColor(payload, keyword) : ""
  readonly property color keywordColor: keywordHex !== "" ? keywordHex : mutedColor
  readonly property bool done: !!item && item.done
  readonly property bool deadline: !!item && Model.isDeadline(item)

  foreground: textColor
  implicitHeight: Style.spacing.popupRowHeight

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
    opacity: root.done ? 0.5 : 1

    PlainText {
      Layout.preferredWidth: root.leadWidth
      Layout.alignment: Qt.AlignVCenter
      horizontalAlignment: Text.AlignRight
      text: root.lead.text
      color: root.lead.urgent ? Commons.Color.urgent : root.mutedColor
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
      color: root.textColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.strikeout: root.done
    }

    // nf-md-flag: the entry carries a deadline.
    PlainText {
      visible: root.deadline
      Layout.alignment: Qt.AlignVCenter
      text: String.fromCodePoint(0xf023b)
      color: root.lead.urgent ? Commons.Color.urgent : Commons.Color.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    PlainText {
      Layout.alignment: Qt.AlignVCenter
      Layout.maximumWidth: Style.space(150)
      text: !root.item ? ""
        : root.hasCursor ? Model.rowLocation(root.item) + " " + String.fromCodePoint(0xf0311)   // nf-md-keyboard-return
        : Model.rowTrail(root.item)
      color: root.mutedColor
      elide: root.hasCursor ? Text.ElideLeft : Text.ElideRight
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
