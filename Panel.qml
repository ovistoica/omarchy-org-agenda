import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Popout content: today's agenda, read from the shared Service. BarWidget
// hosts it in a KeyboardPanel and builds it on first open. Everything shown
// comes from Model (view, panelModel, row helpers); this file lays it out
// and keeps the keyboard cursor. Opening an entry is the Service's job.
//
// The keyboard reaches the next-up card first, then each row of every
// section, in order. Hover moves the same cursor as the arrows, so only one
// row is ever highlighted.
//
// `t` (or a click on a row's keyword chip) opens the state picker under the
// selected entry. While it is open every key goes to it first (forwarded
// below), except ↑↓, which close it and move on.
PanelKeyCatcher {
  id: root

  property var service: null
  property var view: null
  property string fontFamily: Style.font.family

  property int selected: 0
  // Keyboard moves scroll the cursor into view; hover never scrolls.
  property bool followSelection: false
  property var shownKeys: []

  // The open picker: its row's key, the entry it was opened for, and the
  // live StatePicker (null while it is closed or loading).
  property string pickerKey: ""
  property string pickerEntry: ""
  property var picker: null
  readonly property bool pickerOpen: pickerKey !== ""
  readonly property var stateChoices: Model.stateChoices(payload)
  readonly property var pickerItem: {
    var rows = entries.rows
    for (var i = 0; i < rows.length; i++) if (rows[i].key === pickerKey) return rows[i].item
    return null
  }
  readonly property var stateResult: service ? service.stateResult : null

  readonly property color textColor: Commons.Color.popups.text
  readonly property color mutedColor: Commons.Color.muted
  readonly property var payload: view ? view.payload : null
  readonly property string mode: view ? Model.panelMode(view) : "loading"
  readonly property var entries: view && mode === "agenda"
    ? Model.panelModel(view) : ({ next: null, sections: [], rows: [] })
  readonly property var rowKeys: entries.rows.map(function(r) { return r.key })
  readonly property int missingCount: payload && payload.missing ? payload.missing.length : 0
  // Re-read whenever the view changes, which is at least every minute.
  readonly property string todayText: view !== undefined ? Qt.formatDate(new Date(), "ddd d MMM") : ""
  readonly property int leadWidth: Math.ceil(leadMetrics.advanceWidth)
  readonly property int bodyGap: Style.spacing.xxl
  // nf-md-keyboard-return: the bar's Nerd Font has it, unlike a bare ↵,
  // whose fallback glyph overhangs the next word.
  readonly property string enterGlyph: String.fromCodePoint(0xf0311)
  // The picker's chips line up under the rows' keyword chips.
  readonly property int pickerIndent: Style.spacing.md + leadWidth + Style.spacing.lg

  implicitHeight: header.implicitHeight + bodyGap + body.implicitHeight + bodyGap + footer.implicitHeight

  // Back to the top, cursor on the first entry, no picker and no leftover
  // result line: called on each open.
  function reset() {
    selected = 0
    followSelection = false
    pointerGate.reset()
    scroll.contentY = 0
    closePicker()
    clearResult()
  }

  onRowKeysChanged: {
    selected = Model.refocus(shownKeys, rowKeys, selected)
    shownKeys = rowKeys
  }

  // A refresh may drop the picker's row, or put another entry in the
  // next-up card; the picker only ever applies to the entry it opened for.
  onEntriesChanged: {
    if (!pickerOpen) return
    var row = entries.rows.filter(function(r) { return r.key === pickerKey })[0]
    if (!row || Model.entryKey(row.item) !== pickerEntry) closePicker()
  }

  function clearResult() {
    if (service) service.clearStateResult()
  }

  function canPick(item) {
    return !!service && !!payload && stateChoices.length > 0 && Model.canChangeState(item)
  }

  function openPicker(sel) {
    var row = entries.rows[sel]
    if (!row || !canPick(row.item)) return
    if (service.stateBusy) {
      console.warn("org-agenda: a state change is already in progress")
      return
    }
    clearResult()
    followSelection = true
    selected = sel
    pickerEntry = Model.entryKey(row.item)
    pickerKey = row.key
  }

  // The keyword chip toggles the picker for its row.
  function togglePicker(sel) {
    var row = entries.rows[sel]
    if (row && row.key === pickerKey) closePicker()
    else openPicker(sel)
  }

  function closePicker() {
    pickerKey = ""
    pickerEntry = ""
  }

  function pick(keyword) {
    var item = pickerItem
    closePicker()
    if (item && service) service.setState(item, keyword)
  }

  function isPending(item) {
    return !!service && service.stateBusy && service.stateItemKey === Model.entryKey(item)
  }

  // Keys while the picker is open. ↑↓ always leave it; j/k too, unless a
  // keyword uses them as its fast key. Everything else is the picker's or
  // swallowed, so `r`, ↵ and Esc never reach the panel behind it.
  function pickerKeyPressed(event) {
    if (!pickerOpen) return
    var leave = event.key === Qt.Key_Down ? 1 : event.key === Qt.Key_Up ? -1 : 0
    if (leave === 0 && !(picker && picker.handleKey(event)))
      leave = event.text === "j" ? 1 : event.text === "k" ? -1 : 0
    if (leave !== 0) {
      closePicker()
      moveSelection(leave)
    }
    event.accepted = true
  }

  Keys.forwardTo: [pickerKeys]

  Item {
    id: pickerKeys
    Keys.onPressed: function(event) { root.pickerKeyPressed(event) }
  }

  Connections {
    target: root.service
    function onStateNeedsEmacs() { root.closeRequested() }
  }

  function moveSelection(dy) {
    if (rowKeys.length === 0 || dy === 0) return
    followSelection = true
    pointerGate.reset()
    selected = Math.max(0, Math.min(rowKeys.length - 1, selected + dy))
  }

  function pointed(sel, area, mouse) {
    if (!pointerGate.moved(area, mouse)) return
    followSelection = false
    selected = sel
  }

  function openItem(item) {
    if (!item || !service) return
    clearResult()
    service.open(item)
    root.closeRequested()
  }

  function activate() {
    var row = entries.rows[selected]
    if (row) openItem(row.item)
  }

  function openAgenda() {
    if (!service) return
    clearResult()
    service.openAgenda()
    root.closeRequested()
  }

  function refresh() {
    if (!service) return
    clearResult()
    service.pull("manual")
  }

  // Scroll so `bottomItem` is in view and, where it fits, `topItem` too (a
  // section's first row brings its header along).
  function reveal(topItem, bottomItem) {
    if (!followSelection) return
    Qt.callLater(function() {
      if (!topItem || !bottomItem) return
      var margin = Style.space(6)
      var top = topItem.mapToItem(scroll.contentItem, 0, 0).y
      var bottom = bottomItem.mapToItem(scroll.contentItem, 0, 0).y + bottomItem.height
      var maxY = Math.max(0, scroll.contentHeight - scroll.height)
      if (bottom - top > scroll.height) top = bottom - scroll.height + margin
      if (top < scroll.contentY + margin) scroll.contentY = Math.max(0, top - margin)
      else if (bottom > scroll.contentY + scroll.height - margin)
        scroll.contentY = Math.min(maxY, bottom + margin - scroll.height)
    })
  }

  onMoveRequested: function(dx, dy) { root.moveSelection(dy) }
  onActivateRequested: root.activate()
  onTextKey: function(t) {
    if (t === "r" || t === "R") root.refresh()
    else if (t === "t") root.openPicker(root.selected)
  }

  TextMetrics {
    id: leadMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    text: "00:00"
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: root
  }

  // ---- header: the day, and the two things you can do from here.
  RowLayout {
    id: header
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: Style.spacing.lg

    PlainText {
      Layout.alignment: Qt.AlignVCenter
      text: "Today"
      color: root.textColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
    }

    PlainText {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      text: root.todayText
      color: root.mutedColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
    }

    TextAction {
      Layout.alignment: Qt.AlignVCenter
      label: String.fromCodePoint(0xf0450) + " Refresh"   // nf-md-refresh
      fontFamily: root.fontFamily
      onClicked: root.refresh()
    }

    TextAction {
      Layout.alignment: Qt.AlignVCenter
      label: "Agenda"
      fontFamily: root.fontFamily
      onClicked: root.openAgenda()
    }
  }

  // ---- body: capped by the KeyboardPanel, scrolls beyond that.
  Flickable {
    id: scroll
    anchors.top: header.bottom
    anchors.topMargin: root.bodyGap
    anchors.bottom: footer.top
    anchors.bottomMargin: root.bodyGap
    anchors.left: parent.left
    anchors.right: parent.right
    contentWidth: width
    contentHeight: body.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick
    interactive: contentHeight > height
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: body
      width: scroll.width
      spacing: Style.spacing.xxl

      // Next up / Now.
      CursorSurface {
        id: card
        visible: root.entries.next !== null
        width: parent.width
        implicitHeight: cardColumn.implicitHeight + Style.spacing.xl * 2
        bordered: true
        foreground: root.textColor
        hasCursor: root.entries.next !== null && root.selected === 0
        onHasCursorChanged: if (hasCursor) root.reveal(card, card)

        readonly property var next: root.view ? root.view.next : null

        MouseArea {
          id: cardMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onPositionChanged: function(mouse) { root.pointed(0, cardMouse, mouse) }
          onClicked: if (card.next) root.openItem(card.next.item)
        }

        Column {
          id: cardColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.xl
          anchors.rightMargin: Style.spacing.xl
          spacing: Style.spacing.xs
          opacity: card.next && root.isPending(card.next.item) ? 0.45 : 1

          RowLayout {
            width: parent.width
            PlainText {
              Layout.fillWidth: true
              text: card.next && card.next.state === "now" ? "NOW" : "NEXT UP"
              color: Commons.Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: Style.spaceReal(1)
            }
            PlainText {
              visible: card.hasCursor
              text: root.enterGlyph + " Open in Emacs"
              color: root.mutedColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PlainText {
            width: parent.width
            text: card.next ? card.next.item.title : ""
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          PlainText {
            width: parent.width
            text: card.next && root.view ? Model.nextMeta(card.next, root.view.nowMin) : ""
            color: root.mutedColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Loader {
            id: cardPicker
            property int indent: 0
            active: root.pickerKey === "next"
            visible: active
            width: parent.width
            sourceComponent: pickerComponent
            onLoaded: root.reveal(card, card)
          }
        }
      }

      Repeater {
        model: root.entries.sections

        Column {
          id: sectionBlock
          required property var modelData
          width: body.width
          spacing: Style.spacing.xxs

          Item {
            width: parent.width
            implicitHeight: sectionTitle.implicitHeight + Style.spacing.xs

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.md
              anchors.rightMargin: Style.spacing.md
              spacing: Style.spacing.md

              PanelSectionHeader {
                id: sectionTitle
                Layout.alignment: Qt.AlignVCenter
                text: sectionBlock.modelData.title.toUpperCase()
                foreground: root.textColor
                fontFamily: root.fontFamily
                font.letterSpacing: Style.spaceReal(1)
              }

              PlainText {
                Layout.alignment: Qt.AlignVCenter
                text: String(sectionBlock.modelData.count)
                color: sectionBlock.modelData.key === "overdue" ? Commons.Color.urgent : root.mutedColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              PlainText {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                horizontalAlignment: Text.AlignRight
                text: sectionBlock.modelData.hint
                color: root.mutedColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Repeater {
            model: sectionBlock.modelData.rows

            // The row, and its state picker right under it while open.
            Column {
              id: rowBlock
              required property var modelData
              required property int index
              width: sectionBlock.width

              AgendaRow {
                id: row
                width: parent.width
                item: rowBlock.modelData.item
                payload: root.payload
                fontFamily: root.fontFamily
                leadWidth: root.leadWidth
                hasCursor: root.selected === rowBlock.modelData.sel
                stateEnabled: root.canPick(rowBlock.modelData.item)
                pending: root.isPending(rowBlock.modelData.item)
                onHasCursorChanged: if (hasCursor) root.reveal(rowBlock.index === 0 ? sectionBlock : row, row)
                onPointerMoved: function(area, mouse) { root.pointed(rowBlock.modelData.sel, area, mouse) }
                onActivated: root.openItem(rowBlock.modelData.item)
                onKeywordClicked: root.togglePicker(rowBlock.modelData.sel)
              }

              Loader {
                id: rowPicker
                property int indent: root.pickerIndent
                active: root.pickerKey === rowBlock.modelData.key
                visible: active
                width: parent.width
                sourceComponent: pickerComponent
                onLoaded: root.reveal(row, rowPicker)
              }
            }
          }
        }
      }

      // ---- states that replace the agenda.
      PlainText {
        visible: root.mode === "loading" || root.mode === "empty"
        width: parent.width
        topPadding: Style.spacing.huge
        bottomPadding: Style.spacing.huge
        horizontalAlignment: Text.AlignHCenter
        text: root.mode === "loading" ? "Loading agenda…" : "Nothing on the agenda today"
        color: root.mutedColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Column {
        visible: root.mode === "offline" || root.mode === "error"
        width: parent.width
        spacing: Style.spacing.lg

        PlainText {
          width: parent.width
          text: root.mode === "offline" ? "Can't reach your Emacs server" : "Agenda export failed"
          color: root.mode === "error" ? Commons.Color.urgent : root.textColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        PlainText {
          visible: text !== ""
          width: parent.width
          text: !root.view ? "" : root.mode === "error" ? Model.errorMessage(root.view) : root.view.detail
          color: root.mutedColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
          maximumLineCount: 6
        }

        GridLayout {
          visible: root.mode === "offline"
          width: parent.width
          columns: 2
          columnSpacing: Style.spacing.xl
          rowSpacing: Style.spacing.sm

          // Label, fix; label, fix; … one grid cell each.
          Repeater {
            model: ["Right now", "M-x server-start",
                    "Every login", "(server-start) in init.el",
                    "As a service", "systemctl --user enable --now emacs",
                    "Other socket?", "Set “Emacs server socket” in the widget settings"]

            PlainText {
              required property string modelData
              required property int index
              readonly property bool isFix: index % 2 === 1
              Layout.fillWidth: isFix
              Layout.alignment: Qt.AlignTop
              text: modelData
              color: isFix ? root.textColor : root.mutedColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: isFix ? Text.Wrap : Text.NoWrap
              maximumLineCount: 2
            }
          }
        }

        RowLayout {
          width: parent.width
          spacing: Style.spacing.lg

          TextAction {
            label: "Retry"
            fontFamily: root.fontFamily
            onClicked: root.refresh()
          }

          PlainText {
            visible: root.mode === "offline" && !!root.view && root.view.updated !== ""
            Layout.fillWidth: true
            text: root.view ? "Last agenda: " + root.view.updated + " (stale)" : ""
            color: root.mutedColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // ---- footer: provenance and keys.
  Column {
    id: footer
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: Style.spacing.sm

    // The last state change, until the next action or the next open.
    PlainText {
      visible: root.stateResult !== null
      width: parent.width
      text: root.stateResult ? root.stateResult.text : ""
      color: !root.stateResult ? root.mutedColor
        : root.stateResult.tone === "ok" ? Commons.Color.accent
        : root.stateResult.tone === "error" ? Commons.Color.urgent
        : root.mutedColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    PanelSeparator { foreground: root.textColor }

    PlainText {
      visible: root.missingCount > 0
      width: parent.width
      text: String.fromCodePoint(0xf0026) + " " + root.missingCount + " agenda file(s) missing"
      color: root.mutedColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    PlainText {
      visible: root.mode === "agenda" || root.mode === "empty"
      width: parent.width
      text: root.view ? Model.footerLine(root.view) : ""
      color: root.mutedColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    PlainText {
      width: parent.width
      text: root.pickerOpen ? Model.pickerHint(root.stateChoices, root.enterGlyph)
        : root.mode === "agenda"
        ? "↑↓ move · " + root.enterGlyph + " open" + (root.stateChoices.length > 0 ? " · t state" : "")
          + " · r refresh · esc close"
        : "r refresh · esc close"
      color: root.mutedColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Loaded under the row (or inside the next-up card) whose key is
  // `pickerKey`; the Loader's `indent` lines the chips up with its content.
  Component {
    id: pickerComponent

    Item {
      id: pickerHost
      implicitHeight: statePicker.implicitHeight + Style.spacing.xs * 2

      // Clicks between chips stay here instead of opening the entry.
      MouseArea { anchors.fill: parent }

      StatePicker {
        id: statePicker
        x: pickerHost.parent ? pickerHost.parent.indent : 0
        y: Style.spacing.xs
        width: Math.max(0, pickerHost.width - x - Style.spacing.md)
        choices: root.stateChoices
        current: root.pickerItem && root.pickerItem.todo ? root.pickerItem.todo : ""
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        textColor: root.textColor
        mutedColor: root.mutedColor
        accentColor: Commons.Color.accent
        surfaceColor: Util.alpha(root.textColor, 0.04)
        onPicked: function(keyword) { root.pick(keyword) }
        onDismissed: root.closePicker()
        Component.onCompleted: root.picker = statePicker
        Component.onDestruction: if (root.picker === statePicker) root.picker = null
      }
    }
  }

  // Inline components don't see this file's ids, hence the explicit colours.
  component TextAction: BorderSurface {
    id: action
    property string label: ""
    property string fontFamily: Style.font.family
    readonly property color ink: Commons.Color.popups.text
    signal clicked()

    implicitWidth: actionLabel.implicitWidth + Style.spacing.controlPaddingX * 2
    implicitHeight: Math.max(Style.space(22), actionLabel.implicitHeight + Style.spacing.xs * 2)
    radius: Style.cornerRadius
    color: actionMouse.containsMouse ? Style.hoverFillFor(ink, Commons.Color.accent) : "transparent"
    borderSpec: Border.controlSpec(actionMouse.containsMouse ? "hover-cursor" : "normal", ink, Commons.Color.accent)

    PlainText {
      id: actionLabel
      anchors.centerIn: parent
      text: action.label
      color: action.ink
      font.family: action.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: actionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: action.clicked()
    }
  }
}
