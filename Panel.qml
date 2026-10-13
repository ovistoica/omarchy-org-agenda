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
// unfolded section, in order. Overdue starts folded; Tab or a click on its
// header unfolds it. Hover moves the same cursor as the arrows, so only one
// row is ever highlighted.
PanelKeyCatcher {
  id: root

  property var service: null
  property var view: null
  property string fontFamily: Style.font.family

  property bool overdueOpen: false
  property int selected: 0
  // Keyboard moves scroll the cursor into view; hover never scrolls.
  property bool followSelection: false
  property var shownKeys: []

  readonly property color textColor: Commons.Color.popups.text
  readonly property color mutedColor: Commons.Color.muted
  readonly property var payload: view ? view.payload : null
  readonly property string mode: view ? Model.panelMode(view) : "loading"
  readonly property var entries: view && mode === "agenda"
    ? Model.panelModel(view, overdueOpen) : ({ next: null, sections: [], rows: [] })
  readonly property var rowKeys: entries.rows.map(function(r) { return r.key })
  readonly property bool hasOverdue: entries.sections.some(function(s) { return s.foldable })
  readonly property int missingCount: payload && payload.missing ? payload.missing.length : 0
  // Re-read whenever the view changes, which is at least every minute.
  readonly property string todayText: view !== undefined ? Qt.formatDate(new Date(), "ddd d MMM") : ""
  readonly property int leadWidth: Math.ceil(leadMetrics.advanceWidth)
  readonly property int bodyGap: Style.spacing.xxl
  // nf-md-keyboard-return: the bar's Nerd Font has it, unlike a bare ↵,
  // whose fallback glyph overhangs the next word.
  readonly property string enterGlyph: String.fromCodePoint(0xf0311)

  implicitHeight: header.implicitHeight + bodyGap + body.implicitHeight + bodyGap + footer.implicitHeight

  // Back to the top, folded, cursor on the first entry: called on each open.
  function reset() {
    overdueOpen = false
    selected = 0
    followSelection = false
    pointerGate.reset()
    scroll.contentY = 0
  }

  onRowKeysChanged: {
    selected = Model.refocus(shownKeys, rowKeys, selected)
    shownKeys = rowKeys
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

  function toggleOverdue() {
    if (!hasOverdue) return
    followSelection = true
    pointerGate.reset()
    overdueOpen = !overdueOpen
  }

  function openItem(item) {
    if (!item || !service) return
    service.open(item)
    root.closeRequested()
  }

  function activate() {
    var row = entries.rows[selected]
    if (row) openItem(row.item)
  }

  function openAgenda() {
    if (!service) return
    service.openAgenda()
    root.closeRequested()
  }

  function refresh() {
    if (service) service.pull("manual")
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
  onTabRequested: function(direction) { root.toggleOverdue() }
  onTextKey: function(t) { if (t === "r" || t === "R") root.refresh() }

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

              PlainText {
                visible: sectionBlock.modelData.foldable
                Layout.alignment: Qt.AlignVCenter
                text: sectionBlock.modelData.folded ? "▸" : "▾"
                color: root.mutedColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

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

            MouseArea {
              anchors.fill: parent
              enabled: sectionBlock.modelData.foldable
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleOverdue()
            }
          }

          Repeater {
            model: sectionBlock.modelData.rows

            AgendaRow {
              id: row
              required property var modelData
              required property int index
              width: sectionBlock.width
              item: modelData.item
              payload: root.payload
              fontFamily: root.fontFamily
              leadWidth: root.leadWidth
              hasCursor: root.selected === modelData.sel
              onHasCursorChanged: if (hasCursor) root.reveal(index === 0 ? sectionBlock : row, row)
              onPointerMoved: function(area, mouse) { root.pointed(row.modelData.sel, area, mouse) }
              onActivated: root.openItem(row.modelData.item)
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
      text: root.mode === "agenda"
        ? "↑↓ move · " + root.enterGlyph + " open" + (root.hasOverdue ? " · tab fold" : "") + " · r refresh · esc close"
        : "r refresh · esc close"
      color: root.mutedColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
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
