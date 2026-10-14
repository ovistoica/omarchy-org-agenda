import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// One pane of the popout: renders a pane's display-ready blocks
// (Model.layoutModel) top to bottom, one component per `kind`:
//   next     the next-up card
//   section  a small-caps header with its count and hint
//   day      Org's day line ("Wednesday  14 October 2026  TODAY  W42") or a
//            compact one ("THU 15 · nothing scheduled")
//   now      Org's now line
//   row      an entry: OrgRow (style "org") or AgendaRow (style "list")
//   chips    habits as a wrapping row of chips
//   message  a muted or error line (a week loading or failing)
// Everything stateful (the cursor, the picker, opening, revealing) is the
// panel's; `panel` is the Panel, read through its public properties.
Column {
  id: list

  property var panel: null
  property var blocks: []

  readonly property color textColor: Commons.Color.popups.text
  readonly property color mutedColor: Commons.Color.muted

  function isHeader(block) { return !!block && (block.kind === "section" || block.kind === "day") }

  // Room above a block: sections and days open a group.
  function gapAbove(index) {
    var b = blocks[index]
    if (index === 0 || !b) return 0
    if (b.kind === "section") return Style.spacing.xxl
    if (b.kind === "day") return b.style === "org" ? Style.spacing.sm : Style.spacing.md
    if (b.kind === "chips" || b.kind === "message") return Style.spacing.xs
    return 0
  }

  // What to scroll into view with a row: its header too when it is the
  // first row under one.
  function topFor(index, self) {
    var prev = index > 0 ? repeater.itemAt(index - 1) : null
    return prev && isHeader(blocks[index - 1]) ? prev : self
  }

  function componentFor(block) {
    if (!block) return null
    switch (block.kind) {
    case "next": return nextComponent
    case "section": return sectionComponent
    case "day": return dayComponent
    case "now": return nowComponent
    case "row": return block.style === "org" ? orgRowComponent : listRowComponent
    case "chips": return chipsComponent
    case "message": return messageComponent
    default: return null
    }
  }

  Repeater {
    id: repeater
    model: list.blocks

    Item {
      id: slot
      required property var modelData
      required property int index
      readonly property int gap: list.gapAbove(index)

      width: list.width
      implicitHeight: gap + blockLoader.height

      Loader {
        id: blockLoader
        // Read by the loaded component through `parent`.
        readonly property var block: slot.modelData
        readonly property int index: slot.index
        y: slot.gap
        width: parent.width
        sourceComponent: list.componentFor(slot.modelData)
      }
    }
  }

  // ---- next up / now: the card.
  Component {
    id: nextComponent

    CursorSurface {
      id: card
      readonly property var block: parent ? parent.block : null
      readonly property var item: block ? block.item : null

      implicitHeight: cardColumn.implicitHeight + Style.spacing.xl * 2
      bordered: true
      foreground: list.textColor
      hasCursor: !!block && list.panel.selected === block.sel
      onHasCursorChanged: if (hasCursor) list.panel.reveal(card, card)
      Component.onCompleted: if (hasCursor) list.panel.reveal(card, card)

      MouseArea {
        id: cardMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPositionChanged: function(mouse) { if (card.block) list.panel.pointed(card.block.sel, cardMouse, mouse) }
        onClicked: list.panel.openItem(card.item)
      }

      Column {
        id: cardColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.xl
        anchors.rightMargin: Style.spacing.xl
        spacing: Style.spacing.xs
        opacity: card.item && list.panel.isPending(card.item) ? 0.45 : 1

        RowLayout {
          width: parent.width
          PlainText {
            Layout.fillWidth: true
            text: card.block ? card.block.caption : ""
            color: Commons.Color.accent
            font.family: list.panel.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: Style.spaceReal(1)
          }
          PlainText {
            visible: card.hasCursor
            text: list.panel.enterGlyph + " Open in Emacs"
            color: list.mutedColor
            font.family: list.panel.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        PlainText {
          width: parent.width
          text: card.item ? card.item.title : ""
          color: list.textColor
          font.family: list.panel.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        PlainText {
          width: parent.width
          text: card.block ? card.block.meta : ""
          color: list.mutedColor
          font.family: list.panel.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Loader {
          id: cardPicker
          property int indent: 0
          active: list.panel.pickerKey === "next"
          visible: active
          width: parent.width
          sourceComponent: list.panel.pickerComponent
          onLoaded: list.panel.reveal(card, card)
        }
      }
    }
  }

  // ---- a section header: TITLE  count ……… hint.
  Component {
    id: sectionComponent

    Item {
      id: section
      readonly property var block: parent ? parent.block : null
      implicitHeight: sectionTitle.implicitHeight + Style.spacing.xs

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.md
        anchors.rightMargin: Style.spacing.md
        spacing: Style.spacing.md

        PanelSectionHeader {
          id: sectionTitle
          Layout.alignment: Qt.AlignVCenter
          text: section.block ? section.block.title.toUpperCase() : ""
          foreground: list.textColor
          fontFamily: list.panel.fontFamily
          font.letterSpacing: Style.spaceReal(1)
        }

        PlainText {
          Layout.alignment: Qt.AlignVCenter
          text: section.block ? String(section.block.count) : ""
          color: section.block && section.block.urgent ? Commons.Color.urgent : list.mutedColor
          font.family: list.panel.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        PlainText {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          horizontalAlignment: Text.AlignRight
          text: section.block ? section.block.hint : ""
          color: list.mutedColor
          font.family: list.panel.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // ---- a day: Org's day line, or the compact caps one.
  Component {
    id: dayComponent

    Item {
      id: day
      readonly property var block: parent ? parent.block : null
      readonly property bool org: !!block && block.style === "org"
      readonly property bool empty: !!block && block.empty

      implicitHeight: org ? Style.space(22) : dayTitle.implicitHeight + Style.spacing.xxs

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.md
        anchors.rightMargin: Style.spacing.md
        spacing: Style.spacing.md

        PlainText {
          id: dayTitle
          Layout.alignment: Qt.AlignVCenter
          text: day.block ? day.block.title : ""
          color: day.org && day.empty ? list.mutedColor : Commons.Color.accent
          font.family: list.panel.fontFamily
          font.pixelSize: day.org ? Style.font.body : Style.font.caption
          font.bold: !(day.org && day.empty)
          font.letterSpacing: day.org ? 0 : Style.spaceReal(1)
        }

        // TODAY: accent pill, the text in the popout's background colour.
        Rectangle {
          visible: day.org && !!day.block && day.block.today
          Layout.alignment: Qt.AlignVCenter
          implicitWidth: todayText.implicitWidth + Style.spacing.md * 2
          implicitHeight: todayText.implicitHeight + Style.spacing.xxs * 2
          radius: Style.cornerRadius
          color: Commons.Color.accent

          PlainText {
            id: todayText
            anchors.centerIn: parent
            text: "TODAY"
            color: Commons.Color.popups.background
            font.family: list.panel.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        PlainText {
          visible: text !== ""
          Layout.alignment: Qt.AlignVCenter
          text: day.block && day.block.hint ? "· " + day.block.hint : ""
          color: list.mutedColor
          font.family: list.panel.fontFamily
          font.pixelSize: Style.font.caption
        }

        PlainText {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          horizontalAlignment: Text.AlignRight
          text: day.block ? day.block.week : ""
          color: list.mutedColor
          font.family: list.panel.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }

  // ---- Org's now line.
  Component {
    id: nowComponent

    Item {
      id: now
      readonly property var block: parent ? parent.block : null
      implicitHeight: Style.space(20)

      PlainText {
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.md
        anchors.rightMargin: Style.spacing.md
        text: now.block ? now.block.text : ""
        color: Commons.Color.accent
        font.family: list.panel.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }

  // ---- an Org-layout entry, and its state picker while open.
  Component {
    id: orgRowComponent

    Column {
      id: rowBlock
      readonly property var block: parent ? parent.block : null
      readonly property int slotIndex: parent ? parent.index : 0

      OrgRow {
        id: orgRow
        width: parent.width
        item: rowBlock.block ? rowBlock.block.item : null
        payload: list.panel.rowPayload(item)
        cat: rowBlock.block ? rowBlock.block.cat : ""
        when: rowBlock.block ? rowBlock.block.when : null
        past: !!rowBlock.block && rowBlock.block.past
        tones: list.panel.tones
        fontFamily: list.panel.fontFamily
        cellWidth: list.panel.orgCell
        hasCursor: !!rowBlock.block && list.panel.selected === rowBlock.block.sel
        stateEnabled: list.panel.canPick(item)
        pending: list.panel.isPending(item)
        onHasCursorChanged: if (hasCursor) list.panel.reveal(list.topFor(rowBlock.slotIndex, orgRow), orgRow)
        Component.onCompleted: if (hasCursor) list.panel.reveal(list.topFor(rowBlock.slotIndex, orgRow), orgRow)
        onPointerMoved: function(area, mouse) { list.panel.pointed(rowBlock.block.sel, area, mouse) }
        onActivated: list.panel.openItem(item)
        onKeywordClicked: list.panel.togglePicker(rowBlock.block.sel)
      }

      Loader {
        id: orgPicker
        property int indent: list.panel.orgPickerIndent
        active: !!rowBlock.block && list.panel.pickerKey === rowBlock.block.key
        visible: active
        width: parent.width
        sourceComponent: list.panel.pickerComponent
        onLoaded: list.panel.reveal(orgRow, orgPicker)
      }
    }
  }

  // ---- a list entry (Tabs, Columns), and its state picker while open.
  Component {
    id: listRowComponent

    Column {
      id: rowBlock
      readonly property var block: parent ? parent.block : null
      readonly property int slotIndex: parent ? parent.index : 0

      AgendaRow {
        id: listRow
        width: parent.width
        item: rowBlock.block ? rowBlock.block.item : null
        payload: list.panel.rowPayload(item)
        lead: rowBlock.block ? rowBlock.block.lead : null
        trail: rowBlock.block ? rowBlock.block.trail : null
        past: !!rowBlock.block && rowBlock.block.past
        flag: !!rowBlock.block && rowBlock.block.flag
        dense: !!rowBlock.block && rowBlock.block.dense
        tones: list.panel.tones
        fontFamily: list.panel.fontFamily
        leadWidth: list.panel.leadWidth
        hasCursor: !!rowBlock.block && list.panel.selected === rowBlock.block.sel
        stateEnabled: list.panel.canPick(item)
        pending: list.panel.isPending(item)
        onHasCursorChanged: if (hasCursor) list.panel.reveal(list.topFor(rowBlock.slotIndex, listRow), listRow)
        Component.onCompleted: if (hasCursor) list.panel.reveal(list.topFor(rowBlock.slotIndex, listRow), listRow)
        onPointerMoved: function(area, mouse) { list.panel.pointed(rowBlock.block.sel, area, mouse) }
        onActivated: list.panel.openItem(item)
        onKeywordClicked: list.panel.togglePicker(rowBlock.block.sel)
      }

      Loader {
        id: listPicker
        property int indent: list.panel.pickerIndent
        active: !!rowBlock.block && list.panel.pickerKey === rowBlock.block.key
        visible: active
        width: parent.width
        sourceComponent: list.panel.pickerComponent
        onLoaded: list.panel.reveal(listRow, listPicker)
      }
    }
  }

  // ---- habits as chips: title, then missed days (urgent) or ✓ when done.
  Component {
    id: chipsComponent

    Column {
      id: chips
      readonly property var block: parent ? parent.block : null
      readonly property var entries: block ? block.chips : []

      Flow {
        width: parent.width
        leftPadding: Style.spacing.md
        rightPadding: Style.spacing.md
        spacing: Style.spacing.sm

        Repeater {
          model: chips.entries

          CursorSurface {
            id: chip
            required property var modelData
            readonly property bool hasMark: modelData.missed !== "" || modelData.done

            implicitWidth: chipRow.implicitWidth + Style.spacing.lg * 2
            implicitHeight: chipRow.implicitHeight + Style.spacing.xs * 2
            bordered: true
            foreground: list.textColor
            hasCursor: list.panel.selected === modelData.sel
            onHasCursorChanged: if (hasCursor) list.panel.reveal(chip, chip)
            Component.onCompleted: if (hasCursor) list.panel.reveal(chip, chip)

            MouseArea {
              id: chipMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onPositionChanged: function(mouse) { list.panel.pointed(chip.modelData.sel, chipMouse, mouse) }
              onClicked: list.panel.openItem(chip.modelData.item)
            }

            Row {
              id: chipRow
              anchors.centerIn: parent
              spacing: Style.spacing.md
              opacity: list.panel.isPending(chip.modelData.item) ? 0.45 : 1

              PlainText {
                width: Math.min(implicitWidth, Style.space(190))
                text: chip.modelData.text
                color: chip.modelData.done ? list.mutedColor : list.textColor
                font.family: list.panel.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              PlainText {
                visible: chip.hasMark
                text: chip.modelData.missed !== "" ? chip.modelData.missed : "✓"
                color: chip.modelData.missed !== "" ? Commons.Color.urgent : list.mutedColor
                font.family: list.panel.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: chip.modelData.missed !== ""
              }
            }
          }
        }
      }

      Loader {
        id: chipsPicker
        property int indent: Style.spacing.md
        active: chips.entries.some(function(c) { return c.key === list.panel.pickerKey })
        visible: active
        width: parent.width
        sourceComponent: list.panel.pickerComponent
        onLoaded: list.panel.reveal(chipsPicker, chipsPicker)
      }
    }
  }

  // ---- a week loading, or why it couldn't be fetched.
  Component {
    id: messageComponent

    Item {
      id: message
      readonly property var block: parent ? parent.block : null
      implicitHeight: messageText.implicitHeight + Style.spacing.lg * 2

      PlainText {
        id: messageText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.md
        anchors.rightMargin: Style.spacing.md
        text: message.block ? message.block.text : ""
        color: message.block && message.block.tone === "error" ? Commons.Color.urgent : list.mutedColor
        font.family: list.panel.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
        maximumLineCount: 4
      }
    }
  }
}
