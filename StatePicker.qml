import QtQuick

// Org's fast TODO selection as a row of chips under an agenda entry: each
// keyword in its face colour after its fast key ("d DONE"), the todo states,
// then a thin rule like Org's `|`, then the done states. The current
// keyword carries a dot and stays pickable (Emacs treats it as a no-op).
//
// Self-contained (QtQuick and PlainText only) so it can be tested
// offscreen: the panel passes colours, font and size in.
//
// Keys, through handleKey (the panel forwards them while the picker is
// open; standalone, the picker handles them itself when focused):
//   fast key   picks that keyword. Fast keys are case-sensitive, as in
//              Org, and win over every letter below: when `t` is a fast
//              key it picks, and only Esc dismisses.
//   ← → h l    move the focused chip; ↵ picks it
//   Esc        dismisses; so does `t` when no keyword uses it
Item {
  id: root

  property var choices: []
  property string current: ""
  property string fontFamily: ""
  property real fontSize: 12
  property color textColor: "#cacccc"
  property color mutedColor: "#707880"
  property color accentColor: "#cacccc"
  property color surfaceColor: "transparent"
  // Starts on the current keyword, so ←→ move from where the entry is.
  property int focusIndex: Math.max(0, indexOf(function(c) { return c.keyword === root.current }))

  signal picked(string keyword)
  signal dismissed()

  readonly property int pad: Math.round(fontSize * 0.4)
  readonly property int gap: Math.round(fontSize * 0.5)

  implicitWidth: flow.implicitWidth + pad * 2
  implicitHeight: flow.implicitHeight + pad * 2

  function indexOf(pred) {
    var list = Array.isArray(choices) ? choices : []
    for (var i = 0; i < list.length; i++) if (pred(list[i])) return i
    return -1
  }

  function keyIndex(text) {
    return text && text.length === 1 ? indexOf(function(c) { return c.key === text }) : -1
  }

  function pick(i) {
    if (i >= 0 && i < choices.length) picked(choices[i].keyword)
  }

  function move(d) {
    if (choices.length) focusIndex = Math.max(0, Math.min(choices.length - 1, focusIndex + d))
  }

  function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // Handles one key press; returns (and sets event.accepted to) whether the
  // picker used it.
  function handleKey(event) {
    var chorded = (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) !== 0
    var text = chorded ? "" : String(event.text || "")
    var hit = keyIndex(text)
    var used = true
    if (event.key === Qt.Key_Escape) dismissed()
    else if (hit >= 0) pick(hit)
    else if (event.key === Qt.Key_Left || text === "h") move(-1)
    else if (event.key === Qt.Key_Right || text === "l") move(1)
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) pick(focusIndex)
    else if (text === "t") dismissed()
    else used = false
    event.accepted = used
    return used
  }

  Keys.onPressed: function(event) { root.handleKey(event) }

  Rectangle {
    anchors.fill: parent
    radius: root.pad
    color: root.surfaceColor
  }

  Flow {
    id: flow
    x: root.pad
    y: root.pad
    width: Math.max(0, root.width - root.pad * 2)
    spacing: root.gap

    Repeater {
      model: root.choices

      Row {
        id: cell
        required property var modelData
        required property int index
        readonly property bool opensDone: modelData.done && index > 0 && !root.choices[index - 1].done
        spacing: root.gap

        // Org's `|`: todo states before it, done states after.
        Rectangle {
          visible: cell.opensDone
          anchors.verticalCenter: parent.verticalCenter
          width: 1
          height: Math.round(chip.height * 0.7)
          color: root.tint(root.mutedColor, 0.7)
        }

        Rectangle {
          id: chip
          readonly property color ink: cell.modelData.color ? cell.modelData.color : root.textColor
          readonly property bool focused: root.focusIndex === cell.index
          readonly property bool isCurrent: cell.modelData.keyword === root.current

          width: chipRow.implicitWidth + root.gap * 2
          height: chipRow.implicitHeight + Math.round(root.fontSize * 0.3) * 2
          radius: Math.round(root.fontSize * 0.25)
          color: root.tint(ink, focused ? 0.24 : 0.10)
          border.width: 1
          border.color: focused ? root.accentColor : root.tint(ink, isCurrent ? 0.6 : 0.25)

          Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: Math.round(root.fontSize * 0.4)

            PlainText {
              visible: cell.modelData.key !== ""
              anchors.verticalCenter: parent.verticalCenter
              text: cell.modelData.key
              color: root.mutedColor
              font.family: root.fontFamily
              font.pixelSize: Math.round(root.fontSize * 0.85)
            }

            PlainText {
              anchors.verticalCenter: parent.verticalCenter
              text: cell.modelData.keyword
              color: chip.ink
              font.family: root.fontFamily
              font.pixelSize: root.fontSize
              font.bold: true
            }

            // The entry's state now.
            Rectangle {
              visible: chip.isCurrent
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(4, Math.round(root.fontSize * 0.35))
              height: width
              radius: width / 2
              color: chip.ink
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: root.focusIndex = cell.index
            onClicked: root.pick(cell.index)
          }
        }
      }
    }
  }
}
