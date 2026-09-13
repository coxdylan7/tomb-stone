import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Services.UPower
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

  // battery helpers - flash % + status together vs time together every 2.6s
  readonly property int batteryPercent: ready ? service.batteryPercent : -1
  readonly property bool discharging: ready ? service.discharging : false
  property bool batteryShowTime: false
  Timer {
    id: batteryFlashTimer
    interval: 2600
    running: true
    repeat: true
    onTriggered: root.batteryShowTime = !root.batteryShowTime
  }
  property var batteryInfo: ({})
  readonly property string batteryPctStatus: {
    var pct = batteryPercent < 0 ? "--%" : batteryPercent + "%"
    return pct + " battery"
  }
  readonly property string batteryTimeStr: {
    // primary: omarchy-battery-status time (most accurate, already formatted like "2h 15m")
    if (batteryInfo && batteryInfo.time && String(batteryInfo.time).trim().length > 0) return String(batteryInfo.time).trim()
    var d = UPower.displayDevice
    var tEmpty = d && d.isPresent ? d.timeToEmpty : -1
    var tFull = d && d.isPresent ? d.timeToFull : -1
    var m = -1
    if (discharging && isFinite(tEmpty) && tEmpty > 60) m = Math.round(tEmpty/60)
    else if (!discharging && isFinite(tFull) && tFull > 60) m = Math.round(tFull/60)
    if (m > 0) {
      if (m < 60) return m + "m"
      var h = Math.floor(m/60); var mm = m % 60
      return mm === 0 ? h + "h" : h + "h " + mm + "m"
    }
    // no time available - don't show dash, return empty to stay on pctStatus
    return ""
  }
  readonly property string batteryUnderText: {
    var time = batteryTimeStr
    if (time === "") return batteryPctStatus
    return batteryShowTime ? time : batteryPctStatus
  }

  property var powerProfiles: ["power-saver", "balanced", "performance"]
  property string activeProfile: ""
  property bool powerPopupVisible: false

  function refreshPowerProfile() { profileProc.running = true }
  function setPowerProfile(p) {
    powerSetProc.command = ["/usr/bin/omarchy-powerprofiles-set", UPower.onBattery ? "battery" : "ac", p]
    powerSetProc.running = true
  }

  property real logoPhase: 0
  property var logoLines: []
  readonly property int logoFontSize: 4
  readonly property real logoLineHeight: logoFontSize * 1.1
  readonly property string fallbackLogo: [
    "                 \u2584\u2584\u2584",
    " \u2584\u2588\u2588\u2588\u2588\u2588\u2584    \u2584\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2584    \u2584\u2588\u2588\u2588\u2588\u2588\u2588\u2588   \u2584\u2588\u2588\u2588\u2588\u2588\u2588\u2588   \u2584\u2588\u2588\u2588\u2588\u2588\u2588\u2588   \u2584\u2588   \u2588\u2584    \u2584\u2588   \u2588\u2584",
    "\u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2580   \u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2588",
    "\u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2580   \u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2588",
    "\u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2588   \u2588\u2588\u2588 \u2584\u2588\u2588\u2588\u2584\u2584\u2584\u2588\u2588\u2588 \u2584\u2588\u2588\u2588\u2584\u2584\u2584\u2588\u2588\u25C0  \u2588\u2588\u2588       \u2584\u2588\u2588\u2588\u2584\u2584\u2584\u2588\u2588\u2588\u2584 \u2588\u2588\u2588\u2584\u2584\u2584\u2588\u2588\u2588",
    "\u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2588   \u2588\u2588\u2588 \u25C0\u2588\u2588\u2588\u25C0\u25C0\u25C0\u2588\u2588\u2588 \u25C0\u2588\u2588\u2588\u25C0\u25C0\u25C0\u25C0    \u2588\u2588\u2588      \u25C0\u25C0\u2588\u2588\u2588\u25C0\u25C0\u25C0\u2588\u2588\u2588  \u25C0\u25C0\u25C0\u25C0\u25C0\u25C0\u2588\u2588\u2588",
    "\u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2588 \u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2584   \u2588\u2588\u2588   \u2588\u2588\u2588  \u2584\u2588\u2588   \u2588\u2588\u2588",
    "\u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588   \u2588\u2588\u2588",
    " \u25C0\u2588\u2588\u2588\u2588\u2588\u25C0    \u25C0\u2588   \u2588\u2588\u2588   \u2588\u2580   \u2588\u2588\u2588   \u2588\u2580   \u2588\u2588\u2588   \u2588\u2588\u2588  \u2588\u2588\u2588\u2588\u2588\u2588\u2588\u25C0   \u2588\u2588\u2588   \u2588\u2580    \u25C0\u2588\u2588\u2588\u2588\u2588\u25C0"
  ].join("\n")
  function sealLogo(raw) {
    var lines = String(raw).split("\n")
    for (var i = lines.length - 1; i >= 0; i--) if (String(lines[i].trim()).length === 0) lines.splice(i, 1)
    if (lines.length > 0) root.logoLines = lines
  }
  FileView {
    id: brandingFile
    path: Quickshell.env("HOME") + "/.config/omarchy/branding/screensaver.txt"
    printErrors: false
    onLoaded: root.sealLogo(text())
    onLoadFailed: root.sealLogo(root.fallbackLogo)
  }
  NumberAnimation {
    id: logoPhaseAnim
    target: root
    property: "logoPhase"
    from: 0; to: 360
    duration: 2200
    running: true
    loops: Animation.Infinite
  }
  Component.onCompleted: { root.sealLogo(root.fallbackLogo); profileProc.running = true }

  // Shadow button - only for close/back/enter
  component TileButton: Rectangle {
    id: tile
    signal clicked
    property string glyph: ""
    property string label: ""
    property bool active: false
    property color activeColor: Color.accent
    property bool holdToActivate: false
    property int holdMs: 650
    readonly property bool pressed: mouse.pressed
    property real holdProgress: 0
    width: root.tileW
    height: root.tileH
    radius: 14
    color: tile.pressed ? Util.alpha(Color.foreground, 0.16)
      : tile.active ? Util.alpha(tile.activeColor, 0.22)
      : Util.alpha(Color.foreground, 0.05)
    border.width: 1
    border.color: tile.active ? Util.alpha(tile.activeColor, 0.5) : Util.alpha(Color.foreground, 0.08)
    Behavior on color { ColorAnimation { duration: 120 } }
    Rectangle {
      visible: tile.holdToActivate && tile.pressed
      anchors.fill: parent
      radius: parent.radius
      color: "transparent"
      border.width: 2
      border.color: Util.alpha(Color.urgent, 0.6)
      Rectangle {
        anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
        width: parent.width * tile.holdProgress
        radius: parent.radius
        color: Util.alpha(Color.urgent, 0.18)
      }
    }
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
      pressAndHoldInterval: tile.holdMs
      onClicked: if (!tile.holdToActivate) tile.clicked()
      onPressAndHold: if (tile.holdToActivate) tile.clicked()
      onPressed: if (tile.holdToActivate) holdAnim.restart()
      onReleased: holdAnim.stop()
      onCanceled: holdAnim.stop()
    }
    NumberAnimation {
      id: holdAnim
      target: tile
      property: "holdProgress"
      from: 0; to: 1
      duration: tile.holdMs
      easing.type: Easing.Linear
      onStopped: tile.holdProgress = 0
    }
  }

  // Plain button - no shadow/background, just glyph+label
  component PlainButton: Item {
    id: plain
    signal clicked
    property string glyph: ""
    property string label: ""
    property bool active: false
    property color activeColor: Color.accent
    width: 56
    height: 60
    opacity: plainMa.pressed ? 0.6 : 1.0
    Behavior on opacity { NumberAnimation { duration: 100 } }
    Column {
      anchors.centerIn: parent
      spacing: 2
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: plain.glyph
        color: plain.active ? plain.activeColor : Color.foreground
        font.family: Style.font.family
        font.pixelSize: 20
        font.bold: true
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: plain.label
        color: plain.active ? plain.activeColor : Util.alpha(Color.foreground, 0.7)
        font.family: Style.font.family
        font.pixelSize: 9
      }
    }
    MouseArea { id: plainMa; anchors.fill: parent; onClicked: plain.clicked() }
  }

  component ArrowButton: Item {
    id: arrow
    signal clicked
    property string glyph: ""
    width: 36
    height: 60
    opacity: arrowMa.pressed ? 0.6 : 1.0
    Behavior on opacity { NumberAnimation { duration: 100 } }
    Text {
      anchors.centerIn: parent
      text: arrow.glyph
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: 24
      font.bold: true
    }
    MouseArea { id: arrowMa; anchors.fill: parent; onClicked: arrow.clicked() }
  }

  component WavySprite: Item {
    id: spriteRoot
    width: 68
    height: 40
    property real scaleFactor: 0.32
    // clickable to launch menu
    MouseArea {
      anchors.fill: parent
      onClicked: { console.log("tomb-stone: logo launchMenu"); service.launchMenu() }
    }
    Item {
      id: logoLayer
      anchors.centerIn: parent
      width: 180
      height: 36
      scale: spriteRoot.scaleFactor
      Repeater {
        model: root.logoLines
        delegate: Text {
          required property string modelData
          required property int index
          x: (logoLayer.width - implicitWidth)/2 + Math.sin(root.logoPhase * 0.05 + index * 0.55) * 4
          y: index * root.logoLineHeight * 0.9 + Math.cos(root.logoPhase * 0.05 + index * 0.4) * 1.5
          text: modelData
          color: Util.alpha(Color.foreground, 0.92)
          font.family: "monospace"
          font.pixelSize: 6
        }
      }
    }
  }

  PanelWindow {
    id: panel
    visible: root.ready && (service.tabletMode || service.dockLocked)
    screen: root.dockScreen
    anchors { left: true; right: true; bottom: true }
    implicitHeight: root.dockH + 4
    color: "transparent"
    WlrLayershell.namespace: "omarchy-tomb-stone"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Item {
      id: popupContainer
      anchors.fill: parent
      visible: root.powerPopupVisible
      z: 10
      // no full-panel MouseArea - batteryUnderLogo click toggles, popup itself handles close
      Rectangle {
        id: powerPopup
        width: 320
        height: 84
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.dockH + 12
        radius: 16
        color: Util.alpha(Color.background, 0.96)
        border.width: 1
        border.color: Util.alpha(Color.foreground, 0.14)
        Row {
          anchors.centerIn: parent
          spacing: 8
          Repeater {
            model: root.powerProfiles
            Rectangle {
              required property var modelData
              width: 96; height: 56; radius: 12
              color: root.activeProfile === modelData ? Util.alpha(Color.accent, 0.22) : Util.alpha(Color.foreground, 0.06)
              border.width: 1
              border.color: root.activeProfile === modelData ? Util.alpha(Color.accent, 0.5) : Util.alpha(Color.foreground, 0.08)
              Column {
                anchors.centerIn: parent
                spacing: 2
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: modelData === "power-saver" ? "󰌪" : modelData === "balanced" ? "󰾅" : "󰓅"
                  font.pixelSize: 18
                  color: root.activeProfile === modelData ? Color.accent : Color.foreground
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: modelData === "power-saver" ? "Saver" : modelData === "balanced" ? "Balanced" : "Performance"
                  font.family: Style.font.family
                  font.pixelSize: 10
                  color: root.activeProfile === modelData ? Color.accent : Util.alpha(Color.foreground, 0.8)
                }
              }
              MouseArea {
                anchors.fill: parent
                onClicked: {
                  console.log("tomb-stone: set power profile " + modelData)
                  root.setPowerProfile(modelData)
                  root.activeProfile = modelData
                }
              }
            }
          }
        }
      }
    }

    Rectangle {
      id: dockBg
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 26; rightMargin: 26; bottomMargin: 2; topMargin: 2 }
      height: root.dockH - 4
      radius: 22
      color: Util.alpha(Color.background, 0.85)
      border.width: 1
      border.color: Util.alpha(Color.foreground, 0.12)

      // LEFT: only Close (shadow)
      Row {
        id: leftRow
        anchors.left: parent.left
        anchors.leftMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        spacing: 10
        TileButton {
          id: closeTile
          glyph: "✕"; label: "Close"
          activeColor: Color.urgent
          holdToActivate: true; holdMs: 650
          onClicked: { console.log("tomb-stone: close long-press"); service.closeActive() }
        }
      }

      // CENTER: Voice, Prev, Logo+Battery stacked, Next, Layout, Rotate, Lock - all plain, centered
      Row {
        id: centerRow
        anchors.centerIn: parent
        spacing: 8

        PlainButton {
          visible: root.buttons.indexOf("voice") >= 0
          glyph: root.capturing ? "●" : "○"
          label: root.capturing ? "STOP" : "Voice"
          active: root.capturing
          activeColor: Color.urgent
          // solid circle + color when recording, no shadow/background
          SequentialAnimation on opacity {
            running: root.capturing
            loops: Animation.Infinite
            NumberAnimation { to: 0.6; duration: 450; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1.0; duration: 450; easing.type: Easing.InOutSine }
          }
          onClicked: {
            console.log("tomb-stone: voice toggle capturing=" + root.capturing)
            service.toggleVoice()
          }
        }

        PlainButton {
          visible: root.buttons.indexOf("layout") >= 0
          glyph: "󱂬"; label: service.isScrolling ? "Scrolling" : "Dwindle"
          active: service.isScrolling
          onClicked: service.toggleWorkspaceLayout()
        }

        ArrowButton {
          visible: root.buttons.indexOf("workspaces") >= 0
          glyph: "◀"
          onClicked: service.prevWorkspace()
        }

        // Logo up, battery under, recentered
        Column {
          id: logoColumn
          spacing: 2
          anchors.verticalCenter: parent.verticalCenter
          WavySprite { id: centerLogo; anchors.horizontalCenter: parent.horizontalCenter }
          // Battery under logo, no shadow, plain - shows charging + time
          Item {
            id: batteryUnderLogo
            width: 130
            height: 16
            anchors.horizontalCenter: parent.horizontalCenter
            Text {
              id: batteryText
              anchors.centerIn: parent
              text: root.batteryUnderText
              color: root.discharging && root.batteryPercent <= 20 ? Color.urgent : Util.alpha(Color.foreground, 0.85)
              font.family: Style.font.family
              font.pixelSize: 9
              font.bold: root.discharging && root.batteryPercent <= 20
              elide: Text.ElideRight
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              onTextChanged: batteryFlashAnim.restart()
              SequentialAnimation {
                id: batteryFlashAnim
                NumberAnimation { target: batteryText; property: "opacity"; to: 0.15; duration: 120; easing.type: Easing.InQuad }
                NumberAnimation { target: batteryText; property: "opacity"; to: 1.0; duration: 180; easing.type: Easing.OutQuad }
              }
            }
            MouseArea {
              anchors.fill: parent
              onClicked: {
                console.log("tomb-stone: battery under logo click " + !root.powerPopupVisible + " text=" + root.batteryUnderText + " pct=" + root.batteryPercent + " time=" + root.batteryTimeStr)
                root.powerPopupVisible = !root.powerPopupVisible
                if (root.powerPopupVisible) root.refreshPowerProfile()
              }
            }
          }
        }

        ArrowButton {
          visible: root.buttons.indexOf("workspaces") >= 0
          glyph: "▶"
          onClicked: service.nextWorkspace()
        }

        PlainButton {
          visible: root.buttons.indexOf("rotate") >= 0
          glyph: service.autoRotateEnabled ? "󰑦" : "⟲"
          label: {
            if (service.autoRotateEnabled) return "Auto"
            if (service.screenTransform === 0) return "Landscape"
            if (service.screenTransform === 1) return "Portrait"
            if (service.screenTransform === 2) return "Landscape ↕"
            if (service.screenTransform === 3) return "Portrait ↕"
            return "Rotate"
          }
          active: service.autoRotateEnabled || service.screenTransform !== 0
          activeColor: service.autoRotateEnabled ? Color.accent : Color.foreground
          onClicked: service.cycleRotate()
        }

        PlainButton {
          visible: root.buttons.indexOf("lock") >= 0
          glyph: service.dockLocked ? "" : ""; label: service.dockLocked ? "Dock locked" : "Dock"
          active: service.dockLocked; activeColor: Color.accent
          onClicked: service.toggleRotateLock()
        }
      }

      // RIGHT: Back / Enter only (shadow)
      Row {
        id: rightRow
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        spacing: 10
        TileButton { id: backspaceTile; glyph: "⌫"; label: "Back"; onClicked: service.sendKey("BackSpace") }
        TileButton { id: enterTile; glyph: "⏎"; label: "Enter"; activeColor: Color.accent; onClicked: service.sendKey("Return") }
      }
    }
  }

  Process {
    id: profileProc
    command: ["/usr/bin/omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector {
      onStreamFinished: {
        var lines = String(text).trim().split("\n")
        var found = ""
        for (var i = 0; i < lines.length; i++) {
          var parts = lines[i].split("\t")
          if (parts.length >= 2 && parts[1] === "1") { found = parts[0].trim(); break }
        }
        if (found !== "") root.activeProfile = found
        else if (lines.length > 0) root.activeProfile = lines[0].split("\t")[0].trim()
        console.log("tomb-stone: power profile active " + root.activeProfile)
      }
    }
    onExited: function(code){ if (code!==0) console.log("tomb-stone: profileProc failed " + code) }
  }
  Process {
    id: powerSetProc
    stdout: StdioCollector { onStreamFinished: console.log("tomb-stone: power set out " + text) }
    stderr: StdioCollector { onStreamFinished: console.log("tomb-stone: power set err " + text) }
    onExited: function(code){
      console.log("tomb-stone: power set exit " + code)
      if (code===0) root.refreshPowerProfile()
    }
  }
  Process {
    id: batteryProc
    command: ["/usr/bin/omarchy-battery-status", "--shell"]
    stdout: StdioCollector {
      onStreamFinished: {
        var info = {}
        var lines = String(text).trim().split("\n")
        for (var i = 0; i < lines.length; i++) {
          var parts = String(lines[i]).split("\t")
          if (parts.length >= 2) info[parts[0].trim()] = parts[1].trim()
        }
        root.batteryInfo = info
        // also update time text if needed
        // console.log("tomb-stone: batteryInfo " + JSON.stringify(info))
      }
    }
  }
  Timer {
    id: batteryPollTimer
    interval: 8000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: batteryProc.running = true
  }
  Connections { target: UPower; function onOnBatteryChanged(){ if (root.powerPopupVisible) root.refreshPowerProfile(); batteryProc.running = true } }
}
