import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "Tombstone.js" as T

Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null

  readonly property bool ready: service !== null
  readonly property var buttons: ready ? service.buttons : []

  readonly property var dockScreen: {
    if (!ready) return null
    var want = service.output
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === want) return screens[i]
    }
    if (screens.length > 0) return screens[0]
    return null
  }

  readonly property int tileW: 64
  readonly property int tileH: 60
  readonly property int dockH: 78

  readonly property bool capturing: ready && (service.voxtypeState === "recording" || service.voxtypeState === "transcribing")

  component TileButton: Rectangle {
    id: tile
    signal clicked

    property string glyph: ""
    property string label: ""
    property bool active: false
    property color activeColor: Color.accent

    readonly property bool pressed: mouse.pressed

    width: root.tileW
    height: root.tileH
    radius: 14
    color: tile.pressed ? Util.alpha(Color.foreground, 0.16)
      : tile.active ? Util.alpha(tile.activeColor, 0.22)
      : Util.alpha(Color.foreground, 0.05)
    border.width: 1
    border.color: tile.active ? Util.alpha(tile.activeColor, 0.5) : Util.alpha(Color.foreground, 0.08)
    Behavior on color { ColorAnimation { duration: 120 } }

    Column {
      anchors.centerIn: parent
      spacing: 3

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: tile.glyph
        color: tile.active ? tile.activeColor : Color.foreground
        font.family: Style.font.family
        font.pixelSize: 22
        font.bold: true
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: tile.label
        color: tile.active ? tile.activeColor : Util.alpha(Color.foreground, 0.7)
        font.family: Style.font.family
        font.pixelSize: 10
      }
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      onClicked: tile.clicked()
    }
  }

  PanelWindow {
    id: panel
    visible: root.ready && service.tabletMode
    screen: root.dockScreen

    anchors { left: true; right: true; bottom: true }
    implicitHeight: root.dockH
    color: "transparent"
    WlrLayershell.namespace: "omarchy-tomb-stone"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors { fill: parent; topMargin: 2; leftMargin: 26; rightMargin: 26 }
      radius: 22
      color: Util.alpha(Color.background, 0.85)
      border.width: 1
      border.color: Util.alpha(Color.foreground, 0.12)

      TileButton {
        id: closeTile
        anchors.left: parent.left
        anchors.leftMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        glyph: "\u2715"
        label: "Close"
        activeColor: Color.urgent
        onClicked: service.closeActive()
      }

      Row {
        id: tray
        anchors.centerIn: parent
        spacing: 10

        TileButton {
          visible: root.buttons.indexOf("voice") >= 0
          glyph: root.capturing ? "\u25CF" : "\u25CB"
          label: "Voice"
          active: root.capturing
          activeColor: Color.urgent

          Text {
            anchors.centerIn: parent
            text: "\u25CF"
            color: Color.urgent
            font.pixelSize: 22
            visible: root.capturing
            opacity: 1
            SequentialAnimation on opacity {
              running: root.capturing
              loops: Animation.Infinite
              NumberAnimation { to: 0.3; duration: 450 }
              NumberAnimation { to: 1; duration: 450 }
            }
          }

          onClicked: service.toggleVoice()
        }

        TileButton {
          visible: root.buttons.indexOf("launcher") >= 0
          glyph: "\u2756"
          label: "Launcher"
          onClicked: service.launchMenu()
        }

        TileButton {
          visible: root.buttons.indexOf("workspaces") >= 0
          glyph: "\u25C0"
          label: "Prev"
          width: root.tileW - 10
          onClicked: service.prevWorkspace()
        }

        TileButton {
          visible: root.buttons.indexOf("workspaces") >= 0
          glyph: "\u25B6"
          label: "Next"
          width: root.tileW - 10
          onClicked: service.nextWorkspace()
        }

        TileButton {
          visible: root.buttons.indexOf("rotate") >= 0
          glyph: "\u27F2"
          label: service.screenTransform === 0 ? "Portrait" : "Landscape"
          active: service.screenTransform !== 0
          onClicked: service.cycleRotate()
        }

        TileButton {
          visible: root.buttons.indexOf("layout") >= 0
          glyph: "󱂬"
          label: service.isScrolling ? "Scrolling" : "Dwindle"
          active: service.isScrolling
          onClicked: service.toggleWorkspaceLayout()
        }

        TileButton {
          visible: root.buttons.indexOf("lock") >= 0
          glyph: service.rotationLocked ? "\uF023" : "\uF09C"
          label: "Lock"
          active: service.rotationLocked
          activeColor: Color.accent
          onClicked: service.toggleRotateLock()
        }

        TileButton {
          visible: root.buttons.indexOf("battery") >= 0
          width: root.tileW + 14
          glyph: service.batteryPercent >= 0 ? service.batteryPercent + "%" : "--%"
          label: service.discharging ? "Battery" : "Charging"
          active: service.discharging && service.batteryPercent <= 20
          activeColor: Color.urgent
          onClicked: {}
        }
      }

      Row {
        id: keys
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        spacing: 10
        layoutDirection: Qt.LeftToRight

        TileButton {
          id: backspaceTile
          glyph: "\u232B"
          label: "Back"
          onClicked: service.sendKey("BackSpace")
        }

        TileButton {
          id: enterTile
          glyph: "\u21B5"
          label: "Enter"
          activeColor: Color.accent
          onClicked: service.sendKey("Return")
        }
      }
    }
  }
}