import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import qs.Ui as Ui

// Bar label for today's Org agenda. One of these exists per monitor; all of
// them read the one Service, which does every pull. What to show comes from
// Model.view (via service.view), so this file only lays it out.
//
// Left click opens the popout, middle click opens the agenda in Emacs, and
// right click asks Emacs for a fresh export.
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
  readonly property bool showsText: ["next", "now", "today", "count"].indexOf(mode) >= 0
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

  // The popout's content is built on first open and kept from then on.
  property bool panelBuilt: false

  onOpenedChanged: {
    if (!opened) return
    panelBuilt = true
    if (panelContent.item) panelContent.item.reset()
    if (service) service.ensureFresh()
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

      PlainText {
        visible: root.showsText && root.view !== null
        width: button.width
        height: Style.bar.iconSlot
        horizontalAlignment: Text.AlignHCenter
        text: root.view ? String(root.view.openToday) : ""
        color: root.foreground
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
    contentWidth: panel.fittedContentWidth(Style.space(500))
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
      }
    }
  }

  Connections {
    target: panelContent.item
    function onCloseRequested() { root.close() }
  }

  // Overdue count: urgent pill with the number in the bar background colour.
  // Inline components don't see this file's ids, hence the bindings.
  component Badge: Rectangle {
    property int count: 0
    property string fontFamily: Style.font.family
    property real fontSize: Style.font.body

    implicitHeight: Math.round(fontSize * 0.7 + Style.spaceReal(4))
    implicitWidth: Math.max(implicitHeight, badgeText.implicitWidth + Style.spaceReal(6))
    radius: implicitHeight / 2

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
