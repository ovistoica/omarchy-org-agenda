import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Popout content: the agenda in one of three layouts, read from the shared
// Service. BarWidget hosts it in a KeyboardPanel, builds it on first open
// and owns the `layout` setting (it persists a change asked for here).
// Everything shown comes from Model.layoutModel; this file draws the chrome
// (header, tabs, footer), hands each pane's blocks to a BlockList, and
// keeps the keyboard cursor. Opening an entry is the Service's job.
//
//   Org      the Org week agenda, today first
//   Tabs     Today · Week · Overdue
//   Columns  Today on the left; Overdue and the week on the right
//
// Keys come from Model.keyAction. The cursor (`selected`) indexes
// model.rows; hover moves it too, so only one row is ever highlighted, and
// it follows its entry across layouts, tabs, weeks and refreshes.
//
// `t` (or a click on a row's keyword) opens the state picker under the
// selected entry. While it is open every key goes to it first (forwarded
// below), except ↑↓, which close it and move on.
//
// While Org's clock or an org-pomodoro phase runs, a strip under the
// header shows it in every layout (Model.timerState), with Out, Jump and
// ● controls. I O X J P act on it as in Org's agenda; stopping a pomodoro
// asks first (`confirming`) when org-pomodoro would.
PanelKeyCatcher {
  id: root

  property var service: null
  property var view: null
  property string fontFamily: Style.font.family
  // From the widget's settings; a change asked for here goes out through
  // layoutRequested and comes back in this binding.
  property string layout: "Org"
  // Whether the popout is open: another week is only fetched while it is.
  property bool shown: false

  signal layoutRequested(string layout)

  // Session state: which tab, which week. Both reset on open.
  property string tab: "today"
  property int offset: 0

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
  readonly property var pickerItem: {
    for (var i = 0; i < rows.length; i++) if (rows[i].key === pickerKey) return rows[i].item
    return null
  }
  // The picker offers the keywords of the payload its entry came from.
  readonly property var stateChoices: Model.stateChoices(pickerItem ? rowPayload(pickerItem) : payload)
  readonly property var stateResult: service ? service.stateResult : null

  readonly property color textColor: Commons.Color.popups.text
  readonly property color mutedColor: Commons.Color.muted
  readonly property color urgentColor: Commons.Color.urgent
  // Commons has no orange or yellow; Org's late (scheduled earlier) and
  // soon (deadline coming) faces are the urgent colour turned warmer.
  readonly property var tones: ({
    normal: textColor,
    muted: mutedColor,
    urgent: urgentColor,
    accent: Commons.Color.accent,
    late: warmer(urgentColor, 0.06, urgentColor),
    soon: warmer(urgentColor, 0.11, textColor)
  })

  // ---- timers. Only with an agenda that is current (status ok): an old
  // clock may have stopped since.
  readonly property bool timersLive: !!view && view.status === "ok" && !!payload
  readonly property bool clocking: timersLive && !!payload.clock
  readonly property var pomodoroInfo: timersLive && payload.pomodoro ? payload.pomodoro : null
  readonly property bool pomodoroAvailable: !!pomodoroInfo && pomodoroInfo.available === true
  readonly property string pomodoroState: pomodoroInfo ? pomodoroInfo.state : "none"
  // P's stop question is open: the footer asks, P again stops.
  property bool confirming: false
  readonly property string pomodoroStep: Model.pomodoroStep(view, confirming) || ""
  readonly property var selectedItem: rows[selected] ? rows[selected].item : null
  // Seconds only while the popout is open and a pomodoro or break counts;
  // the view's own timer moves by the minute.
  readonly property bool countsSeconds: shown && !!view && !!view.timer && view.timer.kind !== "clock"
  readonly property var timer: !view || !view.timer ? null
    : secondsClock.enabled ? Model.timerState(view, secondsClock.date, true) : view.timer
  readonly property color stripColor: timer && tones[timer.tone] !== undefined ? tones[timer.tone] : Commons.Color.accent
  // The clocked Org row's time, in the colour of its list-row trail.
  readonly property color clockColor: view && view.timer && tones[view.timer.tone] !== undefined
    ? tones[view.timer.tone] : Commons.Color.accent
  readonly property string confirmText: Model.actionMessage("stop", { result: "confirm" }).text

  onPomodoroStateChanged: confirming = false
  onLayoutChanged: confirming = false
  onTabChanged: confirming = false
  onOffsetChanged: confirming = false

  // A wall clock, not a poll: it reads the time and never calls Emacs.
  SystemClock {
    id: secondsClock
    precision: SystemClock.Seconds
    enabled: root.countsSeconds
  }

  readonly property var payload: view ? view.payload : null
  readonly property var weekPayload: service ? service.week : null
  readonly property var model: view
    ? Model.layoutModel(view, { layout: layout, tab: tab, offset: offset, week: weekPayload,
                                weekError: service ? service.weekError : "" })
    : ({ layout: layout, tab: tab, tabs: [], nav: { offset: 0, label: "", range: "" },
         panes: [], rows: [], empty: true })
  readonly property var rows: model.rows
  readonly property var rowKeys: rows.map(function(r) { return r.key })
  readonly property string mode: {
    if (!view) return "loading"
    var m = Model.panelMode(view)
    return m === "agenda" || m === "empty" ? (model.empty ? "empty" : "agenda") : m
  }
  readonly property bool hasAgenda: mode === "agenda" || mode === "empty"

  // The week to fetch, or noWeek: changes only when another one is needed.
  readonly property int noWeek: 1000
  readonly property int wantedWeek: {
    if (!shown || !service || !hasAgenda) return noWeek
    var w = Model.weekWanted(offset, weekPayload)
    return w === null ? noWeek : w
  }
  onWantedWeekChanged: if (wantedWeek !== noWeek) service.fetchWeek(wantedWeek)

  readonly property int missingCount: payload && payload.missing ? payload.missing.length : 0
  // Re-read whenever the view changes, which is at least every minute.
  readonly property string todayText: view !== undefined ? Qt.formatDate(new Date(), "ddd d MMM") : ""
  readonly property int leadWidth: Math.ceil(leadMetrics.advanceWidth)
  // Org's 12-column cells.
  readonly property int orgCell: Math.ceil(orgMetrics.advanceWidth)
  readonly property int bodyGap: Style.spacing.xxl
  readonly property int paneGap: Style.space(16)
  readonly property int paneWidth: model.panes.length > 1
    ? Math.floor((width - (paneGap * 2 + 1) * (model.panes.length - 1)) / model.panes.length) : width
  // nf-md-keyboard-return: the bar's Nerd Font has it, unlike a bare ↵,
  // whose fallback glyph overhangs the next word.
  readonly property string enterGlyph: String.fromCodePoint(0xf0311)
  // The picker's chips line up under the rows' keywords.
  readonly property int pickerIndent: Style.spacing.md + leadWidth + Style.spacing.lg
  readonly property int orgPickerIndent: Style.spacing.md + orgCell * 2
  readonly property Component pickerComponent: pickerComponentDef

  implicitHeight: header.implicitHeight
    + (strip.visible ? Style.spacing.lg + strip.implicitHeight : 0)
    + (tabBar.visible ? Style.spacing.lg + tabBar.implicitHeight : 0)
    + bodyGap + body.implicitHeight + bodyGap + footer.implicitHeight

  // The same hue family, turned towards orange/yellow; `fallback` for a
  // colourless urgent.
  function warmer(c, turn, fallback) {
    return c.hslHue < 0 || c.hslSaturation < 0.15 ? fallback
      : Qt.hsla((c.hslHue + turn) % 1, c.hslSaturation, c.hslLightness, 1)
  }

  // This week, the first tab, the top, cursor on the first entry, no
  // picker and no leftover result line: called on each open.
  function reset() {
    tab = "today"
    offset = 0
    selected = 0
    followSelection = false
    pointerGate.reset()
    scroll.contentY = 0
    closePicker()
    clearResult()
    confirming = false
  }

  onShownChanged: if (!shown) {
    offset = 0
    confirming = false
  }

  onRowKeysChanged: {
    selected = Model.refocus(shownKeys, rowKeys, selected)
    shownKeys = rowKeys
  }

  // A refresh may drop the picker's row, or put another entry in the
  // next-up card; the picker only ever applies to the entry it opened for.
  onRowsChanged: {
    if (!pickerOpen) return
    var row = rows.filter(function(r) { return r.key === pickerKey })[0]
    if (!row || Model.entryKey(row.item) !== pickerEntry) closePicker()
  }

  // The payload a row's entry came from: the bar's, or a fetched week's.
  function rowPayload(item) {
    return Model.payloadFor(item, [payload, weekPayload]) || payload
  }

  function clearResult() {
    if (service) service.clearStateResult()
  }

  function canPick(item) {
    return !!service && !!item && Model.canChangeState(item)
      && Model.stateChoices(rowPayload(item)).length > 0
  }

  function openPicker(sel) {
    var row = rows[sel]
    if (!row || !canPick(row.item)) return
    if (service.stateBusy) {
      console.warn("org-agenda: a state change is already in progress")
      return
    }
    clearResult()
    confirming = false
    followSelection = true
    selected = sel
    pickerEntry = Model.entryKey(row.item)
    pickerKey = row.key
  }

  // The keyword toggles the picker for its row.
  function togglePicker(sel) {
    var row = rows[sel]
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
    // P raced a change in Emacs: it now wants the stop confirmed.
    function onPomodoroNeedsConfirm() {
      root.clearResult()
      root.confirming = true
    }
    // A push or a pull may have changed the week being browsed too.
    function onPayloadChanged() {
      if (root.shown && root.offset !== 0 && root.hasAgenda) root.service.fetchWeek(root.offset)
    }
  }

  // ---- keys: PanelKeyCatcher's signals, through Model.keyAction. Esc
  // never gets here: the catcher closes the popout itself.
  onMoveRequested: function(dx, dy) {
    root.dispatch(dy > 0 ? "Down" : dy < 0 ? "Up" : dx > 0 ? "Right" : "Left", "")
  }
  onActivateRequested: root.dispatch("Return", "")
  onTextKey: function(t) { root.dispatch("", t) }

  function dispatch(key, text) {
    var a = Model.keyAction({ layout: layout, tab: tab, pickerOpen: pickerOpen, clocking: clocking,
                              pomodoro: pomodoroState, pomodoroAvailable: pomodoroAvailable,
                              confirming: confirming }, key, text)
    if (!a) return
    if (a.cancelConfirm) confirming = false
    else if (a.clock) clockAction(a.clock)
    else if (a.pomodoro === "stop") stopPomodoro()
    else if (a.pomodoro) pomodoroPressed()
    else if (a.move !== undefined) moveSelection(a.move)
    else if (a.open) activate()
    else if (a.state) openPicker(selected)
    else if (a.refresh) refresh()
    else if (a.close) closeRequested()
    else if (a.layout) chooseLayout(Model.nextLayout(layout))
    else if (a.week !== undefined) browse(a.week, a.tab || "")
    else if (a.tab) chooseTab(a.tab)
    else if (a.pane) movePane(a.pane)
  }

  // I on the selected entry; O, X on the running clock; J jumps to it and
  // gets out of the way, as ↵ does.
  function clockAction(what) {
    if (!service) return
    confirming = false
    if (what === "in") {
      if (selectedItem) service.clockIn(selectedItem)
    } else if (what === "out") {
      service.clockOut()
    } else if (what === "cancel") {
      service.clockCancel()
    } else if (what === "goto") {
      clearResult()
      service.clockGoto()
      root.closeRequested()
    }
  }

  // P (or ●): whatever org-pomodoro's next step is (Model.pomodoroStep).
  function pomodoroPressed() {
    if (!service) return
    var step = Model.pomodoroStep(view, confirming)
    if (step === "start") {
      if (selectedItem) service.pomodoro(selectedItem, false)
    } else if (step === "break") {
      service.pomodoro(null, false)
    } else if (step === "ask") {
      clearResult()
      confirming = true
    } else if (step === "stop") {
      stopPomodoro()
    }
  }

  function stopPomodoro() {
    confirming = false
    if (service) service.pomodoro(null, true)
  }

  function moveSelection(dy) {
    if (rowKeys.length === 0 || dy === 0) return
    followSelection = true
    pointerGate.reset()
    selected = Math.max(0, Math.min(rowKeys.length - 1, selected + dy))
  }

  // Columns: the same position in the other pane.
  function movePane(dir) {
    var next = Model.paneSel(model, selected, dir)
    if (next === selected) return
    followSelection = true
    pointerGate.reset()
    selected = next
  }

  function toTop() {
    followSelection = false
    selected = 0
    scroll.contentY = 0
  }

  function chooseLayout(next) {
    if (next === layout) return
    closePicker()
    followSelection = true
    root.layoutRequested(next)
  }

  function chooseTab(next) {
    if (next === tab) return
    closePicker()
    tab = next
    toTop()
  }

  // f (+1), b (-1), . (0); in Tabs, f and b also show the week tab. Org's
  // list and the week tab are all that week, so they start at the top.
  function browse(step, toTab) {
    if (!hasAgenda) return
    var next = Model.browseOffset(offset, step)
    var tabChanged = toTab !== "" && toTab !== tab
    if (next === offset && !tabChanged) return
    closePicker()
    if (tabChanged) tab = toTab
    offset = next
    if (layout !== "Columns") toTop()
  }

  // The bar's overdue badge: this week, Tabs on Overdue, the cursor on the
  // first overdue entry and scrolled to it.
  function focusOverdue() {
    var ui = Model.overdueUi({ layout: layout, tab: tab, offset: offset })
    closePicker()
    if (ui.tab) tab = ui.tab
    offset = ui.offset
    var at = rowKeys.indexOf(Model.overdueFocus(model))
    pointerGate.reset()
    followSelection = at >= 0
    if (at < 0) scroll.contentY = 0
    // Through -1, so the row sees its cursor arrive and scrolls to it.
    selected = -1
    selected = Math.max(0, at)
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
    var row = rows[selected]
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
  // row brings its section or day header along).
  function reveal(topItem, bottomItem) {
    if (!followSelection) return
    Qt.callLater(function() {
      if (!topItem || !bottomItem || !topItem.parent || !bottomItem.parent) return
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

  // The widest list lead: a date ("27 Oct") is a cell wider than a time
  // ("13:00") in Omarchy's monospace font.
  TextMetrics {
    id: leadMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    text: "30 May"
  }

  // Org's %-12:c and %?-12t cells: twelve characters, plus a gap so a full
  // cell never touches the next one.
  TextMetrics {
    id: orgMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    text: "0000000000000"
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: root
  }

  // ---- header: the day, the week, the layout, and what you can do from here.
  RowLayout {
    id: header
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: Style.spacing.md

    PlainText {
      Layout.alignment: Qt.AlignVCenter
      Layout.rightMargin: Style.spacing.xs
      text: root.todayText
      color: root.textColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
    }

    // ‹ This week · 12–18 Oct ›; the label goes back to this week.
    RowLayout {
      id: navigator
      visible: root.hasAgenda
      Layout.alignment: Qt.AlignVCenter
      // Shrinks (the label elides) only when the header is too narrow.
      Layout.fillWidth: true
      Layout.minimumWidth: 0
      Layout.maximumWidth: implicitWidth
      spacing: Style.spacing.xs

      NavArrow {
        glyph: "‹"
        tip: "Previous week (b)"
        fontFamily: root.fontFamily
        onClicked: root.browse(-1, root.layout === "Tabs" ? "week" : "")
      }

      // "This week" (or "Next week", "W44") then its days, muted; only the
      // days elide when the header runs out of room.
      PlainText {
        Layout.alignment: Qt.AlignVCenter
        Layout.leftMargin: Style.spacing.xxs
        text: root.model.nav.label
        color: root.model.nav.offset === 0 ? root.mutedColor : root.textColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: root.model.nav.offset !== 0

        MouseArea {
          id: navTitleMouse
          anchors.fill: parent
          enabled: root.model.nav.offset !== 0
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.browse(0, "")
        }

        PanelToolTip {
          visible: navTitleMouse.enabled && navTitleMouse.containsMouse
          text: "Back to this week (.)"
          fontFamily: root.fontFamily
        }
      }

      PlainText {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        Layout.maximumWidth: implicitWidth
        Layout.rightMargin: Style.spacing.xxs
        Layout.alignment: Qt.AlignVCenter
        text: root.model.nav.range
        color: root.mutedColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall

        MouseArea {
          anchors.fill: parent
          enabled: root.model.nav.offset !== 0
          cursorShape: Qt.PointingHandCursor
          onClicked: root.browse(0, "")
        }
      }

      NavArrow {
        glyph: "›"
        tip: "Next week (f)"
        fontFamily: root.fontFamily
        onClicked: root.browse(1, root.layout === "Tabs" ? "week" : "")
      }
    }

    Item {
      Layout.fillWidth: true
    }

    // Org | Tabs | Columns
    BorderSurface {
      id: switcher
      Layout.alignment: Qt.AlignVCenter
      implicitWidth: segments.implicitWidth
      implicitHeight: segments.implicitHeight
      radius: Style.cornerRadius
      color: "transparent"
      borderSpec: Border.controlSpec("normal", root.textColor, Commons.Color.accent)
      clip: true

      Row {
        id: segments

        Repeater {
          model: Model.LAYOUTS

          Rectangle {
            id: segment
            required property string modelData
            required property int index
            readonly property bool on: root.layout === modelData

            implicitWidth: segmentText.implicitWidth + Style.spacing.md * 2
            implicitHeight: Math.max(Style.space(22), segmentText.implicitHeight + Style.spacing.xs * 2)
            color: on ? Util.alpha(root.textColor, 0.14)
              : segmentMouse.containsMouse ? Style.hoverFillFor(root.textColor, Commons.Color.accent)
              : "transparent"

            Rectangle {
              visible: segment.index > 0
              width: 1
              height: parent.height
              color: Util.alpha(root.textColor, 0.18)
            }

            PlainText {
              id: segmentText
              anchors.centerIn: parent
              text: segment.modelData
              color: segment.on ? root.textColor : root.mutedColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: segment.on
            }

            MouseArea {
              id: segmentMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.chooseLayout(segment.modelData)
            }
          }
        }
      }

      HoverHandler { id: switcherHover }

      PanelToolTip {
        visible: switcherHover.hovered
        text: "Layout (v)"
        fontFamily: root.fontFamily
      }
    }

    TextAction {
      Layout.alignment: Qt.AlignVCenter
      label: String.fromCodePoint(0xf0450)   // nf-md-refresh
      labelSize: Style.font.title
      square: true
      tip: "Refresh (r)"
      fontFamily: root.fontFamily
      onClicked: root.refresh()
    }

    TextAction {
      Layout.alignment: Qt.AlignVCenter
      label: "Agenda"
      tip: "Open the agenda in Emacs"
      fontFamily: root.fontFamily
      onClicked: root.openAgenda()
    }
  }

  // ---- the running timer, in every layout; nothing while none runs.
  //   CAPTION  title ………………  0:23 / 1:00 effort   Out  Jump  ●
  //   ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬ (progress, when there is any)
  Rectangle {
    id: strip
    visible: root.timer !== null
    anchors.top: header.bottom
    anchors.topMargin: Style.spacing.lg
    anchors.left: parent.left
    anchors.right: parent.right
    implicitHeight: stripColumn.implicitHeight + Style.spacing.md * 2
    height: visible ? implicitHeight : 0
    radius: Style.cornerRadius
    color: Util.alpha(root.stripColor, 0.08)
    border.width: 1
    border.color: Util.alpha(root.stripColor, 0.45)

    readonly property bool hasTitle: !!root.timer && root.timer.title !== ""
    readonly property bool isBreak: !!root.timer
      && (root.timer.kind === "short-break" || root.timer.kind === "long-break")

    Column {
      id: stripColumn
      anchors.top: parent.top
      anchors.topMargin: Style.spacing.md
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.xxl
      anchors.rightMargin: Style.spacing.md
      spacing: Style.spacing.sm

      RowLayout {
        width: parent.width
        height: Style.space(22)
        spacing: Style.spacing.xl

        PlainText {
          Layout.alignment: Qt.AlignVCenter
          text: root.timer ? root.timer.caption : ""
          color: root.stripColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: Style.spaceReal(1.2)
        }

        // The clocked entry; a click jumps there (J). A phase without a
        // clock says so quietly, a break says nothing.
        PlainText {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          Layout.alignment: Qt.AlignVCenter
          text: strip.hasTitle ? root.timer.title : strip.isBreak ? "" : "not clocked"
          color: strip.hasTitle ? root.textColor : root.mutedColor
          font.family: root.fontFamily
          font.pixelSize: strip.hasTitle ? Style.font.body : Style.font.bodySmall

          MouseArea {
            id: stripTitleMouse
            anchors.fill: parent
            enabled: root.clocking
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.clockAction("goto")
          }

          PanelToolTip {
            visible: stripTitleMouse.enabled && stripTitleMouse.containsMouse
            text: "Jump to the clocked entry (J)"
            fontFamily: root.fontFamily
          }
        }

        // 0:23 / 1:00 effort · 12:41 left · +3:05 over
        Row {
          Layout.alignment: Qt.AlignVCenter

          PlainText {
            id: stripTime
            text: root.timer ? root.timer.time.text : ""
            color: root.timer && root.timer.time.tone === "urgent" ? root.urgentColor : root.textColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            font.features: { "tnum": 1 }
          }

          PlainText {
            anchors.baseline: stripTime.baseline
            text: root.timer ? root.timer.extra : ""
            color: root.mutedColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.features: { "tnum": 1 }
          }
        }

        Row {
          Layout.alignment: Qt.AlignVCenter
          spacing: Style.spacing.xs

          StripAction {
            visible: root.clocking
            label: "Out"
            tip: "Clock out (O)"
            fontFamily: root.fontFamily
            onClicked: root.clockAction("out")
          }

          StripAction {
            visible: root.clocking
            label: "Jump"
            tip: "Jump to the clocked entry (J)"
            fontFamily: root.fontFamily
            onClicked: root.clockAction("goto")
          }

          // org-pomodoro's next step; starting needs an entry to start on.
          StripAction {
            readonly property bool needsEntry: root.pomodoroStep === "start"
            visible: root.pomodoroAvailable
            label: "●"
            labelColor: root.urgentColor
            available: !needsEntry || (!!root.selectedItem && Model.canChangeState(root.selectedItem))
            tip: !available ? "Select an entry to start a pomodoro on"
              : needsEntry ? "Start a pomodoro on the selected entry (P)"
              : root.pomodoroStep === "break" ? "Start the break (P)"
              : root.confirming ? "Stop the pomodoro (P again)"
              : "Stop the pomodoro (P)"
            fontFamily: root.fontFamily
            onClicked: root.confirming ? root.stopPomodoro() : root.pomodoroPressed()
          }
        }
      }

      Rectangle {
        visible: !!root.timer && root.timer.progress !== null
        width: parent.width - Style.spacing.md
        height: 3
        radius: 2
        color: Util.alpha(root.textColor, 0.12)

        Rectangle {
          width: Math.round(parent.width * (root.timer && root.timer.progress !== null ? root.timer.progress : 0))
          height: parent.height
          radius: 2
          color: root.stripColor
        }
      }
    }
  }

  // ---- Tabs: Today · Week · Overdue, with their counts.
  Row {
    id: tabBar
    visible: root.layout === "Tabs" && root.mode === "agenda" && root.model.tabs.length > 0
    anchors.top: strip.visible ? strip.bottom : header.bottom
    anchors.topMargin: Style.spacing.lg
    anchors.left: parent.left
    spacing: Style.spacing.md

    Repeater {
      model: root.model.tabs

      BorderSurface {
        id: tabButton
        required property var modelData
        required property int index
        readonly property bool on: root.tab === modelData.key

        implicitWidth: tabRow.implicitWidth + Style.spacing.xl * 2
        implicitHeight: tabRow.implicitHeight + Style.spacing.sm * 2
        radius: Style.cornerRadius
        color: on ? Util.alpha(root.textColor, 0.14)
          : tabMouse.containsMouse ? Style.hoverFillFor(root.textColor, Commons.Color.accent) : "transparent"
        borderSpec: Border.controlSpec(on ? "selected" : "normal", root.textColor, Commons.Color.accent)

        Row {
          id: tabRow
          anchors.centerIn: parent
          spacing: Style.spacing.md

          PlainText {
            anchors.verticalCenter: parent.verticalCenter
            text: tabButton.modelData.title
            color: tabButton.on ? root.textColor : root.mutedColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: tabButton.on
          }

          // Overdue's count is an urgent pill, like the bar's badge.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: Math.max(implicitHeight, countText.implicitWidth + Style.spacing.md * 2)
            implicitHeight: countText.implicitHeight + Style.spacing.xxs * 2
            radius: Style.cornerRadius
            color: tabButton.modelData.urgent ? root.urgentColor : "transparent"

            PlainText {
              id: countText
              anchors.centerIn: parent
              text: String(tabButton.modelData.count)
              color: tabButton.modelData.urgent ? Commons.Color.popups.background : root.mutedColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: tabButton.modelData.urgent
            }
          }
        }

        MouseArea {
          id: tabMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.chooseTab(tabButton.modelData.key)
        }
      }
    }
  }

  // ---- body: capped by the KeyboardPanel, scrolls beyond that.
  Flickable {
    id: scroll
    anchors.top: tabBar.visible ? tabBar.bottom : strip.visible ? strip.bottom : header.bottom
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

      // One pane, or two side by side with a hairline between them.
      Row {
        id: panes
        visible: root.mode === "agenda"
        width: parent.width

        Repeater {
          model: root.mode === "agenda" ? root.model.panes : []

          Row {
            id: paneSlot
            required property var modelData
            required property int index

            Item {
              visible: paneSlot.index > 0
              width: root.paneGap * 2 + 1

              Rectangle {
                x: root.paneGap
                width: 1
                height: panes.height
                color: Util.alpha(root.textColor, 0.12)
              }
            }

            Column {
              width: root.paneWidth
              spacing: Style.spacing.xs

              PlainText {
                visible: paneSlot.modelData.title !== ""
                leftPadding: Style.spacing.md
                text: paneSlot.modelData.title.toUpperCase()
                color: root.mutedColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: Style.spaceReal(1.5)
              }

              BlockList {
                width: parent.width
                panel: root
                blocks: paneSlot.modelData.blocks
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
        text: root.mode === "loading" ? "Loading agenda…" : "Nothing on the agenda this week"
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

    // The last state change or timer action, until the next action or the
    // next open.
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
      visible: root.hasAgenda
      width: parent.width
      text: root.view ? Model.footerLine(root.view) : ""
      color: root.mutedColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // The keys, or the pomodoro's stop question while it is open.
    PlainText {
      width: parent.width
      text: root.confirming ? root.confirmText
        : root.pickerOpen ? Model.pickerHint(root.stateChoices, root.enterGlyph)
        : root.hasAgenda ? Model.layoutHints(root.layout, { clocking: root.clocking,
                                                            pomodoroAvailable: root.pomodoroAvailable })
                             .replace("↵", root.enterGlyph)
        : "r refresh · esc close"
      font.bold: root.confirming
      color: root.confirming ? root.urgentColor : root.mutedColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Loaded under the row (or inside the next-up card, or under the habit
  // chips) whose key is `pickerKey`; the Loader's `indent` lines the chips
  // up with its content.
  Component {
    id: pickerComponentDef

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
    property string tip: ""
    property string fontFamily: Style.font.family
    property int labelSize: Style.font.bodySmall
    // An icon button: as wide as it is high.
    property bool square: false
    readonly property color ink: Commons.Color.popups.text
    signal clicked()

    implicitWidth: square ? implicitHeight : actionLabel.implicitWidth + Style.spacing.lg * 2
    implicitHeight: Style.space(24)
    radius: Style.cornerRadius
    color: actionMouse.containsMouse ? Style.hoverFillFor(ink, Commons.Color.accent) : "transparent"
    borderSpec: Border.controlSpec(actionMouse.containsMouse ? "hover-cursor" : "normal", ink, Commons.Color.accent)

    PlainText {
      id: actionLabel
      anchors.centerIn: parent
      text: action.label
      color: action.ink
      font.family: action.fontFamily
      font.pixelSize: action.labelSize
    }

    MouseArea {
      id: actionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: action.clicked()
    }

    PanelToolTip {
      visible: action.tip !== "" && actionMouse.containsMouse
      text: action.tip
      fontFamily: action.fontFamily
    }
  }

  // A small text control in the timer strip. Not `available`: dimmed and
  // inert, its tip saying why.
  component StripAction: BorderSurface {
    id: control
    property string label: ""
    property string tip: ""
    property string fontFamily: Style.font.family
    property bool available: true
    readonly property color ink: Commons.Color.popups.text
    property color labelColor: ink
    readonly property bool hot: available && controlMouse.containsMouse
    signal clicked()

    implicitWidth: Math.max(implicitHeight, controlLabel.implicitWidth + Style.spacing.lg * 2)
    implicitHeight: Style.space(20)
    radius: Style.cornerRadius
    color: hot ? Style.hoverFillFor(ink, Commons.Color.accent) : "transparent"
    borderSpec: Border.controlSpec(hot ? "hover-cursor" : "normal", ink, Commons.Color.accent)

    PlainText {
      id: controlLabel
      anchors.centerIn: parent
      text: control.label
      color: control.labelColor
      opacity: control.available ? 1 : 0.4
      font.family: control.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: controlMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: control.available ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (control.available) control.clicked()
    }

    PanelToolTip {
      visible: control.tip !== "" && controlMouse.containsMouse
      text: control.tip
      fontFamily: control.fontFamily
    }
  }

  // ‹ or › of the week navigator.
  component NavArrow: Item {
    id: arrow
    property string glyph: ""
    property string tip: ""
    property string fontFamily: Style.font.family
    readonly property color ink: Commons.Color.popups.text
    signal clicked()

    Layout.alignment: Qt.AlignVCenter
    implicitWidth: Math.max(Style.space(16), arrowText.implicitWidth + Style.spacing.sm * 2)
    implicitHeight: Style.space(22)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: arrowMouse.containsMouse ? Style.hoverFillFor(arrow.ink, Commons.Color.accent) : "transparent"
    }

    PlainText {
      id: arrowText
      anchors.centerIn: parent
      text: arrow.glyph
      color: arrow.ink
      font.family: arrow.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
    }

    MouseArea {
      id: arrowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: arrow.clicked()
    }

    PanelToolTip {
      visible: arrow.tip !== "" && arrowMouse.containsMouse
      text: arrow.tip
      fontFamily: arrow.fontFamily
    }
  }
}
