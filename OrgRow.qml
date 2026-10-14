import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// One entry of the Org layout, laid out like `org-agenda-prefix-format'
// " %i %-12:c%?-12t% s":
//   category:   13:00-13:30 TODO [#A] title
// The category and time/leader are fixed-width cells (`cellWidth`, twelve
// characters of the popout font, measured by the panel), so the columns
// line up whatever the font. `when` is the block's {text, tone}; `tones`
// maps a tone to its colour. A row that is over (`past`) is muted. As with
// the list rows, the highlight comes from `hasCursor`, the keyword asks for
// the state picker, and the cursor shows where ↵ jumps to.
CursorSurface {
  id: root

  property var item: null
  property var payload: null
  property string cat: ""
  property var when: null
  property bool past: false
  property var tones: ({})
  property string fontFamily: Style.font.family
  property int cellWidth: Style.space(84)
  property bool stateEnabled: false
  property bool pending: false
  // The entry Org's clock runs on: tinted like org-agenda-clocking, with
  // its time (`clock`, "◷ 0:23") at the right end in `clockColor`.
  property bool clocked: false
  property string clock: ""
  property color clockColor: Commons.Color.accent

  signal pointerMoved(var area, var mouse)
  signal activated()
  signal keywordClicked()

  readonly property color textColor: Commons.Color.popups.text
  readonly property color mutedColor: Commons.Color.muted
  readonly property string keyword: item && item.todo ? item.todo : ""
  readonly property string keywordHex: keyword ? Model.keywordColor(payload, keyword) : ""
  readonly property bool done: !!item && item.done
  readonly property color whenColor: past || !when || tones[when.tone] === undefined ? mutedColor : tones[when.tone]

  // Org pads its cells with spaces; the cells here have a width instead.
  function trimmed(s) { return String(s || "").replace(/\s+$/, "") }

  foreground: textColor
  // The cursor's highlight wins over the clock's tint.
  color: hasCursor ? fill : clocked ? Util.alpha(Commons.Color.accent, 0.12) : "transparent"
  implicitHeight: Style.space(22)

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
    spacing: 0
    opacity: root.pending ? 0.45 : root.done ? 0.5 : 1

    PlainText {
      Layout.preferredWidth: root.cellWidth
      Layout.alignment: Qt.AlignVCenter
      text: root.trimmed(root.cat)
      color: root.mutedColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    PlainText {
      Layout.preferredWidth: root.cellWidth
      Layout.alignment: Qt.AlignVCenter
      text: root.pending ? "…" : root.when ? root.trimmed(root.when.text) : ""
      color: root.whenColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    // The keyword in its Org face colour; a click opens the state picker.
    PlainText {
      visible: root.keyword !== ""
      Layout.alignment: Qt.AlignVCenter
      Layout.rightMargin: Style.spacing.md
      text: root.keyword
      color: root.keywordHex !== "" ? root.keywordHex : root.mutedColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true

      MouseArea {
        visible: root.stateEnabled
        anchors.fill: parent
        anchors.margins: -Style.spacing.xxs
        cursorShape: Qt.PointingHandCursor
        onClicked: root.keywordClicked()
      }
    }

    PlainText {
      visible: !!root.item && !!root.item.priority
      Layout.alignment: Qt.AlignVCenter
      Layout.rightMargin: Style.spacing.md
      text: root.item && root.item.priority ? "[#" + root.item.priority + "]" : ""
      color: root.item && root.item.priority === "A" ? Commons.Color.accent : root.mutedColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
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

    PlainText {
      visible: root.clock !== ""
      Layout.alignment: Qt.AlignVCenter
      Layout.leftMargin: Style.spacing.lg
      text: root.clock
      color: root.clockColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      font.features: { "tnum": 1 }
    }

    PlainText {
      visible: root.hasCursor
      Layout.alignment: Qt.AlignVCenter
      Layout.leftMargin: Style.spacing.lg
      Layout.maximumWidth: Style.space(150)
      text: root.item ? Model.rowLocation(root.item) + " " + String.fromCodePoint(0xf0311)   // nf-md-keyboard-return
                      : ""
      color: root.mutedColor
      elide: Text.ElideLeft
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
