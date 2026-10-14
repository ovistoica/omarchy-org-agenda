import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import qs.Ui as Ui
import "Model.js" as Model

// Bar label for today's Org agenda. One of these exists per monitor; all of
// them read the one Service, which does every pull. What to show comes from
// Model.view (via service.view), so this file only lays it out.
//
// Left click opens the popout (a click on the overdue badge opens it on
// Overdue), middle click opens the agenda in Emacs, and right click asks
// Emacs for a fresh export. The popout's layout is this widget's `layout`
// setting; switching it in the popout saves it here.
//
// The root is qualified because this plugin's own Panel.qml (the popout
// content) would otherwise shadow the shell's Panel.
Ui.Panel {
  id: root
  moduleName: "ovistoica.org-agenda"
  // The service owns the one IpcHandler; one per monitor would collide.
  manageIpc: false

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("ovistoica.org-agenda") : null
  readonly property var view: service ? service.view : null
  readonly property var label: view ? view.label : ({ mode: "loading", text: "", badge: 0, alert: false })

  readonly property bool vertical: bar ? bar.vertical : false
  // Qt 6.12 has its own Color type, so the palette is always qualified.
  readonly property color foreground: bar ? bar.barForeground : Commons.Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Commons.Color.urgent

  readonly property string mode: label.mode
  readonly property bool showsText: ["next", "now", "today", "count", "timer"].indexOf(mode) >= 0
  // A running clock or pomodoro, {glyph, time, tone}, in every label mode:
  // before the title in Next item, instead of the count in Count, after
  // the icon in Icon.
  readonly property var timer: label.timer ? label.timer : null
  readonly property color timerColor: !timer ? foreground
    : timer.tone === "urgent" ? urgentColor
    : timer.tone === "accent" ? Commons.Color.accent
    : foreground
  // Nerd Font MD: calendar-check normally, calendar-remove when Emacs is gone.
  readonly property string glyph: String.fromCodePoint(mode === "offline" ? 0xf00f4 : 0xf00ef)
  readonly property color glyphColor: mode === "error" ? urgentColor : foreground
  readonly property real glyphOpacity: mode === "loading" || mode === "offline" ? 0.5 : 1
  readonly property string titleText: mode === "now" ? label.text.replace(/^now /, "") : label.text

  readonly property real openPanelIndicatorWidth: vertical ? Style.bar.iconSlot : content.implicitWidth

  function configureService() {
    if (service) service.configure(root.settings)
  }

  onServiceChanged: configureService()
  onSettingsChanged: configureService()
  Component.onCompleted: configureService()

  readonly property string layout: Model.normalizeSettings(root.settings).layout

  // The popout's content is built on first open and kept from then on.
  property bool panelBuilt: false
  // Set by a click on the overdue badge, for the open it causes.
  property bool overdueOnOpen: false

  onOpenedChanged: {
    if (!opened) return
    // The first open builds the content, whose onLoaded prepares it.
    if (panelBuilt) prepareOpen()
    else panelBuilt = true
    if (service) service.ensureFresh()
  }

  function prepareOpen() {
    var panelItem = panelContent.item
    if (!panelItem) return
    panelItem.reset()
    if (overdueOnOpen) panelItem.focusOverdue()
    overdueOnOpen = false
  }

  function openOverdue() {
    button.hideOwnTooltip()
    if (root.opened) {
      if (panelContent.item) panelContent.item.focusOverdue()
      return
    }
    overdueOnOpen = true
    root.open()
  }

  // Like the clock's format: the whole entry, applied here first so the
  // popout switches on the key press, then written to shell.json, which
  // sends the same value back through `settings`.
  function setLayout(next) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.layout = Model.normalizeSettings({ layout: next }).layout
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Org text never goes through WidgetButton's own label.
    text: ""
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : content.implicitWidth + scaledHorizontalMargin * 2
    fixedHeight: root.vertical ? column.implicitHeight : -1
    tooltipText: root.view ? root.view.tooltip : ""
    dimmed: !!root.view && root.view.stale

    onPressed: function(b) {
      if (b === Qt.RightButton) { if (root.service) root.service.pull("manual") }
      else if (b === Qt.MiddleButton) { if (root.service) root.service.openAgenda() }
      else root.toggle()
    }

    Row {
      id: content
      visible: !root.vertical
      anchors.centerIn: parent
      spacing: Style.spaceReal(4)

      PlainText {
        anchors.verticalCenter: parent.verticalCenter
        text: root.glyph
        color: root.glyphColor
        opacity: root.glyphOpacity
        font.family: button.fontFamily
        font.pixelSize: Style.bar.iconFont
      }

      // Overdue marker for Icon mode, where the badge is off by design.
      Rectangle {
        visible: root.mode === "icon" && root.label.alert
        anchors.verticalCenter: parent.verticalCenter
        width: Math.round(button.fontSize * 0.4)
        height: width
        radius: 1
        color: root.urgentColor
      }

      // ◷ 0:23 / ● 13m: tabular digits, so the minute ticking by never
      // shifts what follows.
      PlainText {
        visible: root.timer !== null
        anchors.verticalCenter: parent.verticalCenter
        text: root.timer ? root.timer.glyph + " " + root.timer.time : ""
        color: root.timerColor
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        font.bold: true
        font.features: { "tnum": 1 }
      }

      PlainText {
        visible: root.mode === "now"
        anchors.verticalCenter: parent.verticalCenter
        text: "now"
        color: Commons.Color.accent
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
      }

      PlainText {
        visible: root.showsText && root.titleText !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: root.titleText
        color: root.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
      }

      Badge {
        visible: count > 0
        anchors.verticalCenter: parent.verticalCenter
        count: root.label.badge
        color: root.urgentColor
        fontFamily: button.fontFamily
        fontSize: button.fontSize
        onClicked: root.openOverdue()
      }
    }

    Column {
      id: column
      visible: root.vertical
      anchors.horizontalCenter: parent.horizontalCenter

      PlainText {
        width: button.width
        height: Style.bar.iconSlot
        horizontalAlignment: Text.AlignHCenter
        text: root.glyph
        color: root.glyphColor
        opacity: root.glyphOpacity
        font.family: button.fontFamily
        font.pixelSize: Style.bar.iconFont
      }

      // The count, or a running timer's time (no title: the column is narrow).
      PlainText {
        visible: (root.showsText || root.timer !== null) && root.view !== null
        width: button.width
        height: Style.bar.iconSlot
        horizontalAlignment: Text.AlignHCenter
        text: root.timer ? root.timer.time : root.view ? String(root.view.openToday) : ""
        color: root.timerColor
        font.bold: root.timer !== null
        font.features: { "tnum": 1 }
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
      }

      Item {
        visible: root.label.badge > 0
        width: button.width
        height: Style.bar.iconSlot

        Badge {
          anchors.centerIn: parent
          count: root.label.badge
          color: root.urgentColor
          fontFamily: button.fontFamily
          fontSize: button.fontSize
          onClicked: root.openOverdue()
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panelContent.item
    // Columns puts two panes side by side.
    contentWidth: panel.fittedContentWidth(Style.space(root.layout === "Columns" ? 980 : 500))
    contentHeight: panel.fittedContentHeight(
      panelContent.item ? panelContent.item.implicitHeight : Style.space(120),
      Math.round(panel.screenH * 0.7))

    Loader {
      id: panelContent
      anchors.fill: parent
      active: root.panelBuilt
      source: Qt.resolvedUrl("Panel.qml")
      onLoaded: {
        item.service = Qt.binding(function() { return root.service })
        item.view = Qt.binding(function() { return root.view })
        item.fontFamily = Qt.binding(function() { return button.fontFamily })
        item.layout = Qt.binding(function() { return root.layout })
        item.shown = Qt.binding(function() { return root.opened })
        if (root.opened) root.prepareOpen()
      }
    }
  }

  Connections {
    target: panelContent.item
    function onCloseRequested() { root.close() }
    function onLayoutRequested(next) { root.setLayout(next) }
  }

  // Overdue count: urgent pill with the number in the bar background colour.
  // Inline components don't see this file's ids, hence the bindings.
  // Its own left click opens the popout on Overdue; middle and right
  // clicks fall through to the widget.
  component Badge: Rectangle {
    id: badge
    property int count: 0
    property string fontFamily: Style.font.family
    property real fontSize: Style.font.body
    signal clicked()

    implicitHeight: Math.round(fontSize * 0.7 + Style.spaceReal(4))
    implicitWidth: Math.max(implicitHeight, badgeText.implicitWidth + Style.spaceReal(6))
    radius: implicitHeight / 2

    MouseArea {
      anchors.fill: parent
      anchors.margins: -Style.spaceReal(2)
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      onClicked: badge.clicked()
    }

    PlainText {
      id: badgeText
      anchors.centerIn: parent
      text: String(parent.count)
      color: Commons.Color.background
      font.family: parent.fontFamily
      font.pixelSize: Math.round(parent.fontSize * 0.75)
      font.bold: true
    }
  }
}
