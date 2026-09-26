import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Screen-centered variant of the shell's Ui.KeyboardPanel.
//
// KeyboardPanel pins its card to the bar, under the widget's icon. This one
// ignores the bar entirely and floats the card in the middle of the output,
// spotlight style, over a dimmed backdrop. Everything else is deliberately
// kept compatible with KeyboardPanel — same properties (anchorItem, owner,
// bar, open, focusTarget, contentWidth/Height), same sizing helpers
// (fittedContentWidth/Height, cappedContentHeight, availableCardWidth/Height,
// verticalContentInset), same popout coordination and focus priming — so the
// panel content does not have to know which of the two it is living in.
//
// Nothing anchors it: the card lands on the output Hyprland has focused, so
// a keyboard summon opens it where the user is looking. `anchorItem` is
// optional and only used as a fallback when a host widget supplies one.
PanelWindow {
  id: root

  property Item anchorItem: null
  property QtObject bar: null
  property var owner: null
  property int margin: Style.gapsOut
  property int padding: Style.spacing.popupPadding
  property int contentWidth: Style.space(280)
  property int contentHeight: Style.space(200)
  property var borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
  property bool open: false
  property bool popoutSwitching: false
  property bool popoutSwitchClosing: false
  property bool focusPrimed: false

  // Item that takes keyboard focus once the panel maps. Layer-shell grants
  // focus to the surface during the Exclusive prime, but Qt still needs an
  // active-focus target inside it for Keys handlers to fire.
  property Item focusTarget: null

  default property alias contentItem: contentHolder.children

  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null

  // The output the card opens on. An anchor wins when there is one; otherwise
  // it is whichever output Hyprland has focused, resolved when the panel
  // opens so a card already on screen does not jump between monitors.
  property var focusedScreen: null

  function resolveFocusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    if (!name) return
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (String(screens[i].name) === name) { root.focusedScreen = screens[i]; return }
  }

  function close() {
    if (owner && "close" in owner) owner.close()
    else root.open = false
  }

  function beginFocusPrime() {
    if (open && backingWindowVisible) focusPrimeTimer.restart()
  }

  // --- screen + lifetime ---------------------------------------------------

  screen: anchorWindow ? anchorWindow.screen : focusedScreen
  visible: open || card.opacity > 0 || popoutSwitching
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore

  WlrLayershell.namespace: "anavarre-jira-search"
  WlrLayershell.layer: WlrLayer.Overlay
  // Focus follows `open`, not `visible`: the surface stays mapped through the
  // fade-out so the animation has something to animate, but keyboard and
  // pointer ownership have to be released the moment the logical close fires.
  // Prime with Exclusive (which takes focus even when the surface was already
  // mapped), then settle on OnDemand so clicks can reach other outputs.
  WlrLayershell.keyboardFocus: open
    ? (focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
    : WlrKeyboardFocus.None

  onBackingWindowVisibleChanged: beginFocusPrime()

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  // The whole output is ours, bar strip included: a centered panel is modal
  // in feel, so a click anywhere outside the card dismisses it rather than
  // being forwarded to whatever sits underneath.
  mask: Region {
    width: root.screenW
    height: root.screenH
  }

  readonly property real screenW: screen ? screen.width : 0
  readonly property real screenH: screen ? screen.height : 0
  readonly property real availableCardWidth: screenW > 0 ? Math.max(120, screenW - margin * 2) : 0
  readonly property real availableCardHeight: screenH > 0 ? Math.max(120, screenH - margin * 2) : 0
  readonly property real verticalContentInset: padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)

  function fittedContentWidth(width, cap) {
    var desired = Math.max(1, Number(width) || 1)
    var maxWidth = root.availableCardWidth > 0 ? root.availableCardWidth : desired
    if (cap !== undefined && Number(cap) > 0) maxWidth = Math.min(maxWidth, Number(cap))
    return Math.round(Math.min(desired, maxWidth))
  }

  function fittedContentHeight(implicitHeight, cap) {
    var desired = Math.max(root.verticalContentInset, (Number(implicitHeight) || 0) + root.verticalContentInset)
    var maxHeight = root.availableCardHeight > 0 ? root.availableCardHeight : desired
    if (cap !== undefined && Number(cap) > 0) maxHeight = Math.min(maxHeight, Number(cap))
    return Math.round(Math.min(desired, maxHeight))
  }

  function cappedContentHeight(height) {
    var desired = Math.max(root.padding * 2, Number(height) || root.padding * 2)
    var maxHeight = root.availableCardHeight > 0 ? root.availableCardHeight : desired
    return Math.round(Math.min(desired, maxHeight))
  }

  // --- popout coordination (same-bar single-popout model) -----------------

  onOpenChanged: {
    if (open) {
      resolveFocusedScreen()
      focusPrimed = false
      beginFocusPrime()
      if (focusTarget) Qt.callLater(function() {
        if (root.open && root.focusTarget) root.focusTarget.forceActiveFocus()
      })
    } else {
      focusPrimeTimer.stop()
      focusPrimed = false
    }
    if (!bar) return
    if (open) {
      popoutSwitchClosing = false
      popoutSwitching = bar.activePopout && bar.activePopout !== coordinatorKey
      bar.requestPopout(coordinatorKey)
      if (popoutSwitching) popoutSwitchTimer.restart()
    } else {
      popoutSwitchClosing = !!(owner && owner.popoutSwitchClosing)
      popoutSwitching = false
      if (bar.activePopout === coordinatorKey) bar.releasePopout(coordinatorKey)
      if (popoutSwitchClosing) closeSwitchTimer.restart()
    }
  }

  Component.onCompleted: resolveFocusedScreen()

  Timer {
    id: focusPrimeTimer
    interval: 75
    onTriggered: if (root.open) root.focusPrimed = true
  }

  Timer {
    id: popoutSwitchTimer
    interval: 150
    onTriggered: root.popoutSwitching = false
  }

  Timer {
    id: closeSwitchTimer
    interval: 1
    onTriggered: root.popoutSwitchClosing = false
  }

  // --- backdrop + outside-click dismissal ---------------------------------

  // The theme's scrim, as the scaffold's overlay and menu templates use, so
  // the dimming follows the theme instead of being black on every palette.
  Rectangle {
    anchors.fill: parent
    color: Color.menu.scrim
    opacity: card.opacity

    MouseArea {
      anchors.fill: parent
      enabled: root.open
      acceptedButtons: Qt.AllButtons
      onClicked: root.close()
    }
  }

  // The surface only spans the anchor's output and the compositor hit-tests
  // pointer input per output, so give every other output a transparent twin
  // whose only job is to catch a click there and dismiss. Keyboard focus is
  // None so merely crossing onto them doesn't steal focus from the card.
  Variants {
    model: root.open ? Quickshell.screens : []

    delegate: Component {
      PanelWindow {
        required property var modelData

        screen: modelData
        visible: root.open && !!root.screen && modelData.name !== root.screen.name
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.namespace: "anavarre-jira-search-dismiss"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
          top: true
          bottom: true
          left: true
          right: true
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onPressed: root.close()
        }
      }
    }
  }

  // --- card ----------------------------------------------------------------

  BorderSurface {
    id: card
    x: Math.round(Math.max(root.margin, (root.screenW - root.contentWidth) / 2))
    y: Math.round(Math.max(root.margin, (root.screenH - root.contentHeight) / 2))
    width: root.contentWidth
    height: root.contentHeight
    color: Color.popups.background
    borderSpec: root.borderSpec
    padding: root.padding
    radius: Style.cornerRadius
    opacity: root.open || root.popoutSwitching ? 1.0 : 0

    Behavior on opacity {
      enabled: !root.popoutSwitching && !root.popoutSwitchClosing
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    // Swallow clicks on the card so they don't reach the backdrop behind it.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
    }

    // BorderSurface does not inset its children, it only reports where its
    // content may start, so the holder has to take the padding and border
    // widths off itself.
    Item {
      id: contentHolder
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
      opacity: root.popoutSwitching ? (root.open ? 1.0 : 0) : 1.0

      Behavior on opacity {
        enabled: root.popoutSwitching
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
    }
  }
}
