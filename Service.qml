import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.UPower
import "Tombstone.js" as T

Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "djc.tomb-stone"

  readonly property var pluginEntry: T.pluginEntry(shell, pluginId)
  readonly property string detector: T.configStr(pluginEntry, "detector", "auto")
  readonly property int sensorPollSeconds: T.configInt(pluginEntry, "pollSeconds", 1)
  readonly property bool autoRotate: T.configBool(pluginEntry, "autoRotate", true)
  readonly property bool landscapeOnly: T.configBool(pluginEntry, "landscapeOnly", true)
  readonly property string output: T.configStr(pluginEntry, "output", "eDP-1")
  readonly property string tabletModeOverride: T.configStr(pluginEntry, "tabletModeOverride", "auto")
  readonly property string incliRawPath: T.configStr(pluginEntry, "incliRawPath", "/sys/bus/iio/devices/iio:device0/in_incli_x_raw")
  readonly property string accelYRawPath: T.configStr(pluginEntry, "accelYRawPath", "/sys/bus/iio/devices/iio:device3/in_accel_y_raw")
  readonly property string accelZRawPath: T.configStr(pluginEntry, "accelZRawPath", "/sys/bus/iio/devices/iio:device3/in_accel_z_raw")
  readonly property string accelXRawPath: T.configStr(pluginEntry, "accelXRawPath", "/sys/bus/iio/devices/iio:device3/in_accel_x_raw")
  readonly property int tabletEnterMG: T.configInt(pluginEntry, "tabletEnterMG", 350)
  readonly property int tabletExitMG: T.configInt(pluginEntry, "tabletExitMG", -250)
  readonly property int tabletExitAZ: T.configInt(pluginEntry, "tabletExitAZ", -550)
  readonly property var buttons: T.configList(pluginEntry, "buttons", ["voice", "launcher", "workspaces", "rotate", "tablet", "lock", "battery"])

  readonly property string homeDir: Quickshell.env("HOME") || "~"
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string rotationFile: homeDir + "/.config/hypr/tombstone-devices.lua"
  readonly property string voxtypeStateFile: runtimeDir + "/voxtype/state"

  property bool sensorTablet: false
  property bool tabletMode: false
  property string detectorUsed: "off"
  property real hingeDeg: -1
  property int accelX: 0
  property int accelY: 0
  property int accelZ: 0
  property int exitStreak: 0
  property int enterStreak: 0
  property int rotStreak: 0
  property real lastAzimuth: -1
  property string orientation: "normal"
  property int rotateDirection: T.configInt(pluginEntry, "rotateDirection", -1)
  property bool rotationLocked: false
  property string runtimeOverride: ""
  property bool iioSucceeding: false
  property bool iioStartTried: false
  property int screenTransform: 0
  property int pendingTransform: -1

  property string voxtypeState: "stopped"
  property bool voxtypeInstalled: false
  property bool voiceBusy: false

  property int batteryPercent: -1
  property bool discharging: false

  readonly property bool sysfsInUse: root.detector !== "iio"

  function effectiveOverride() {
    return root.runtimeOverride !== "" ? root.runtimeOverride : root.tabletModeOverride
  }

  function applyState() {
    var ov = root.effectiveOverride()
    var v = ov === "on" ? true
      : ov === "off" ? false
      : root.sensorTablet
    if (v === root.tabletMode) return
    root.tabletMode = v
    console.log("tomb-stone: tablet " + (v ? "on" : "off")
      + " (hinge " + Math.round(root.hingeDeg) + " deg, accelY " + root.accelY + ", "
      + root.detectorUsed + ")")
    if (root.autoRotate) root.applyTransform(root.targetTransform())
  }

  function toggleRotateLock() {
    root.rotationLocked = !root.rotationLocked
    root.rotStreak = 0
    root.notify("tomb-stone", root.rotationLocked ? "Rotation locked" : "Rotation unlocked", "")
  }

  function forceTablet(on) {
    root.runtimeOverride = on ? "on" : "off"
    root.applyState()
  }

  function sendKey(key) {
    keyProc.command = ["wtype", "-k", key]
    keyProc.running = true
  }

  function closeActive() {
    closeProc.command = ["hyprctl", "dispatch", "hl.dsp.window.close()"]
    closeProc.running = true
  }

  function foldedTablet() {
    if (root.sensorTablet) {
      var wantExit = root.accelY < root.tabletExitMG && root.accelZ > root.tabletExitAZ
      root.exitStreak = wantExit ? root.exitStreak + 1 : 0
      return root.exitStreak < 3
    }
    root.exitStreak = 0
    var wantEnter = root.accelY >= root.tabletEnterMG || root.accelZ <= -700
    root.enterStreak = wantEnter ? root.enterStreak + 1 : 0
    return root.enterStreak >= 2
  }

  function readSensors() {
    if (!root.sysfsInUse) return
    sensorProc.collected = ""
    sensorProc.command = ["cat", root.incliRawPath, root.accelYRawPath, root.accelZRawPath, root.accelXRawPath]
    sensorProc.running = true
  }

  function handleSensorRead() {
    var nums = T.parseFloats(sensorProc.collected)
    sensorProc.collected = ""
    if (nums.length >= 4) {
      var ix = nums[0]
      var ay = nums[1]
      var az = nums[2]
      var ax = nums[3]
      if (isFinite(ix)) root.hingeDeg = T.clamp(180 - ix * 0.1, 0, 360)
      if (isFinite(ay)) root.accelY = Math.round(ay)
      if (isFinite(az)) root.accelZ = Math.round(az)
      if (isFinite(ax)) root.accelX = Math.round(ax)
      root.detectorUsed = "sysfs"
      root.sensorTablet = root.foldedTablet()
      if (root.autoRotate) {
        var target = root.targetTransform()
        if (target >= 0) {
          var az = root.azimuthDeg()
          if (az >= 0 && root.lastAzimuth >= 0) {
            var dd = Math.abs(az - root.lastAzimuth)
            if (dd > 180) dd = 360 - dd
            if (dd < 45) target = root.screenTransform
          }
          if (target !== root.screenTransform) {
            root.rotStreak = root.rotStreak + 1
            if (root.rotStreak >= 1) root.applyTransform(target)
          } else {
            root.rotStreak = 0
          }
        }
      }
      if (root.rotationLocked) root.lastAzimuth = -1
    }
    root.applyState()
  }

  function accelTransform() {
    if (Math.abs(root.accelX) < 25 && Math.abs(root.accelY) < 25) return -1
    var theta = Math.atan2(-root.accelX, -root.accelY) * 180 / Math.PI
    var steps = Math.round(root.rotateDirection * theta / 90)
    var t = ((steps) % 4 + 4) % 4
    return t
  }

  function azimuthDeg() {
    if (Math.abs(root.accelX) < 25 && Math.abs(root.accelY) < 25) return -1
    var theta = Math.atan2(-root.accelX, -root.accelY) * 180 / Math.PI
    if (theta < 0) theta += 360
    return theta
  }

  function refreshVoxtypeState() {
    var s = String(voxtypeStateView.text() || "").trim()
    if (s.length > 0) root.voxtypeState = s
  }

  function probeIio() {
    if (root.detector === "sysfs") return
    if (!root.iioStartTried) {
      root.iioStartTried = true
      claimAccelProc.running = true
    }
    gdbusProc.collected = ""
    gdbusProc.command = [
      "gdbus", "call", "--system", "--dest", "net.hadess.SensorProxy",
      "--object-path", "/net/hadess/SensorProxy",
      "--method", "org.freedesktop.DBus.Properties.GetAll", "net.hadess.SensorProxy"
    ]
    gdbusProc.running = true
  }

  function sensorTick() {
    root.batteryPercent = T.batteryPercentage(UPower.displayDevice)
    root.discharging = T.isDischarging(UPower.displayDevice, UPower.onBattery, UPowerDeviceState.Discharging)
    root.readSensors()
    root.probeIio()
  }

  function targetTransform() {
    if (!root.tabletMode) return 0
    if (!root.autoRotate) return root.screenTransform
    if (root.rotationLocked) return root.screenTransform
    var t
    if (root.sysfsInUse) {
      t = root.accelTransform()
      if (t < 0) return root.screenTransform
    } else {
      t = 0
      if (root.orientation === "bottom-up") t = 2
      else if (root.orientation === "right-up") t = 3
      else if (root.orientation === "left-up") t = 1
    }
    if (root.landscapeOnly && t !== 0 && t !== 2) t = 0
    return t
  }

  function applyTransform(t) {
    if (t === root.screenTransform || t < 0 || t > 3) return
    root.lastAzimuth = root.azimuthDeg()
    root.pendingTransform = t
    rotProc.command = ["bash", "-c",
      "cat > " + root.rotationFile + " <<'EOF'\n" +
      "-- Managed by djc.tomb-stone: syncs touchscreen digitizer + monitor.\n" +
      "hl.config({\n" +
      "  input = { touchdevice = { output = \"" + root.output + "\", transform = " + t + " } },\n" +
      "})\n" +
      "hl.monitor({ output = \"" + root.output + "\", transform = " + t + " })\n" +
      "EOF\n" +
      "hyprctl reload > /dev/null 2>&1 < /dev/null"]
    rotProc.running = true
  }

  function cycleRotate() {
    root.applyTransform((root.screenTransform + 1) % 4)
  }

  function toggleVoice() {
    if (root.voiceBusy) return
    if (!root.voxtypeInstalled) {
      root.notify("tomb-stone", "Voxtype is not installed", "Run: omarchy voxtype install")
      return
    }
    root.voiceBusy = true
    startDaemonProc.command = ["systemctl", "--user", "start", "voxtype.service"]
    startDaemonProc.running = true
  }

  function launchMenu() {
    menuProc.command = ["omarchy-shell", "shell", "summon", "omarchy.menu"]
    menuProc.running = true
  }

  function nextWorkspace() {
    workspaceProc.command = ["bash", "-c",
      "ws=$(hyprctl activeworkspace -j | jq -r .id); " +
      "hyprctl dispatch 'hl.dsp.focus({ workspace = '$((ws+1))' })' > /dev/null 2>&1"]
    workspaceProc.running = true
  }

  function prevWorkspace() {
    workspaceProc.command = ["bash", "-c",
      "ws=$(hyprctl activeworkspace -j | jq -r .id); ws=$((ws-1)); [ $ws -lt 1 ] && ws=1; " +
      "hyprctl dispatch 'hl.dsp.focus({ workspace = '$ws' })' > /dev/null 2>&1"]
    workspaceProc.running = true
  }

  function notify(appName, summary, body) {
    notifyProc.command = ["notify-send", "--app-name=" + appName, summary, body]
    notifyProc.running = true
  }

  Process {
    id: sensorProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { sensorProc.collected += data + "\n" }
    }
    onExited: function(code, exitStatus) {
      root.handleSensorRead()
    }
  }

  FileView {
    id: voxtypeStateView
    path: root.voxtypeStateFile
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshVoxtypeState()
  }

  Process {
    id: gdbusProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { gdbusProc.collected += data + "\n" }
    }
    onExited: function(code, exitStatus) {
      var props = T.parseDBusGetAll(gdbusProc.collected)
      gdbusProc.collected = ""
      if (props && props.HasAccelerometer) {
        root.iioSucceeding = true
        var o = String(props.AccelerometerOrientation || "undefined")
        if (["normal", "right-up", "bottom-up", "left-up"].indexOf(o) >= 0) root.orientation = o
      } else {
        root.iioSucceeding = false
      }
      root.applyState()
    }
  }

  Process {
    id: claimAccelProc
    command: [
      "gdbus", "call", "--system", "--dest", "net.hadess.SensorProxy",
      "--object-path", "/net/hadess/SensorProxy",
      "--method", "net.hadess.SensorProxy.ClaimAccelerometer"
    ]
  }

  Process {
    id: voxtypeCheck
    command: ["sh", "-c", "command -v voxtype >/dev/null 2>&1 && echo yes || echo no"]
    running: true
    stdout: SplitParser {
      onRead: function(data) {
        if (String(data).trim() === "yes") root.voxtypeInstalled = true
      }
    }
  }

  Process {
    id: startDaemonProc
    onExited: function(code, exitStatus) {
      if (code !== 0) {
        root.voiceBusy = false
        root.notify("tomb-stone", "Voxtype daemon failed", "Run: voxtype setup --download")
        return
      }
      voiceDelayTimer.restart()
    }
  }

  Process {
    id: toggleProc
    onExited: function(code, exitStatus) {
      root.voiceBusy = false
      if (code !== 0) root.notify("tomb-stone", "Voxtype is not available", "Run: voxtype setup")
    }
  }

  Process {
    id: notifyProc
  }

  Process {
    id: menuProc
  }

  Process {
    id: workspaceProc
  }

  Process {
    id: rotProc
    onExited: function(code, exitStatus) {
      if (code === 0 && root.pendingTransform >= 0) root.screenTransform = root.pendingTransform
      root.pendingTransform = -1
    }
  }

  Process {
    id: keyProc
  }

  Process {
    id: closeProc
  }

  Timer {
    id: sensorTimer
    interval: root.sensorPollSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.sensorTick()
  }

  Timer {
    id: voiceDelayTimer
    interval: 600
    onTriggered: {
      toggleProc.command = ["voxtype", "record", "toggle"]
      toggleProc.running = true
    }
  }

  Connections {
    target: UPower
    function onOnBatteryChanged() {
      root.sensorTick()
    }
  }
}