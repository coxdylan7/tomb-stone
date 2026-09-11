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

  readonly property var pluginEntry: T.pluginEntry(effectiveShell, pluginId)
  readonly property string detector: T.configStr(pluginEntry, "detector", "auto")
  readonly property int sensorPollSeconds: T.configInt(pluginEntry, "pollSeconds", 1)
  readonly property bool autoRotate: T.configBool(pluginEntry, "autoRotate", true)
  property bool autoRotateEnabled: autoRotate
  readonly property bool landscapeOnly: T.configBool(pluginEntry, "landscapeOnly", false)
  readonly property string output: T.configStr(pluginEntry, "output", "eDP-1")
  readonly property string tabletModeOverride: T.configStr(pluginEntry, "tabletModeOverride", "auto")
  readonly property string incliRawPath: T.configStr(pluginEntry, "incliRawPath", "/sys/bus/iio/devices/iio:device0/in_incli_x_raw")
  readonly property string accelYRawPath: T.configStr(pluginEntry, "accelYRawPath", "/sys/bus/iio/devices/iio:device3/in_accel_y_raw")
  readonly property string accelZRawPath: T.configStr(pluginEntry, "accelZRawPath", "/sys/bus/iio/devices/iio:device3/in_accel_z_raw")
  readonly property string accelXRawPath: T.configStr(pluginEntry, "accelXRawPath", "/sys/bus/iio/devices/iio:device3/in_accel_x_raw")
  property string resolvedIncliPath: ""
  property string resolvedAccelXPath: ""
  property string resolvedAccelYPath: ""
  property string resolvedAccelZPath: ""
  readonly property string effectiveIncliPath: resolvedIncliPath !== "" ? resolvedIncliPath : incliRawPath
  readonly property string effectiveAccelXPath: resolvedAccelXPath !== "" ? resolvedAccelXPath : accelXRawPath
  readonly property string effectiveAccelYPath: resolvedAccelYPath !== "" ? resolvedAccelYPath : accelYRawPath
  readonly property string effectiveAccelZPath: resolvedAccelZPath !== "" ? resolvedAccelZPath : accelZRawPath
  readonly property int tabletEnterMG: T.configInt(pluginEntry, "tabletEnterMG", 350)
  readonly property int tabletExitMG: T.configInt(pluginEntry, "tabletExitMG", -250)
  readonly property int tabletExitAZ: T.configInt(pluginEntry, "tabletExitAZ", -550)
  readonly property var buttons: T.configList(pluginEntry, "buttons", ["voice", "launcher", "workspaces", "rotate", "layout", "tablet", "lock", "battery"])

  readonly property string homeDir: Quickshell.env("HOME") || "~"
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string rotationFile: homeDir + "/.config/hypr/tombstone-devices.lua"
  readonly property string voxtypeStateFile: runtimeDir + "/voxtype/state"

  // Helper for secure rotation file writing - argv-based, validated, atomic nofollow replace
  readonly property string helperRotation: {
    var u = Qt.resolvedUrl("./helpers/write-rotation.py")
    var s = String(u)
    if (s.indexOf("file://") === 0) s = s.slice(7)
    return s
  }

  FileView {
    id: shellConfigFile
    path: homeDir + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
  }
  property var fileConfig: {
    try { var t = shellConfigFile.text(); return t ? JSON.parse(t) : null } catch(e) { return null }
  }
  readonly property var effectiveShell: shell && shell.shellConfig ? shell : (fileConfig ? { shellConfig: fileConfig } : null)

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
  property bool dockLocked: false

  property string voxtypeState: "stopped"
  property bool voxtypeInstalled: false
  property bool voiceBusy: false

  property int batteryPercent: -1
  property bool discharging: false

  property string workspaceLayout: "dwindle"
  readonly property bool isScrolling: workspaceLayout === "scrolling"

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
    if (root.autoRotateEnabled) root.applyTransform(root.targetTransform())
  }

  function toggleRotateLock() {
    // now locks dock visibility, not rotation (per request)
    root.dockLocked = !root.dockLocked
    root.notify("tomb-stone", root.dockLocked ? "Dock locked" : "Dock unlocked", "")
  }

  function toggleAutoRotate() {
    root.autoRotateEnabled = !root.autoRotateEnabled
    root.rotStreak = 0
    root.notify("tomb-stone", root.autoRotateEnabled ? "Auto-rotate on" : "Auto-rotate off", "")
  }

  function forceTablet(on) {
    root.runtimeOverride = on ? "on" : "off"
    root.applyState()
  }

  function sendKey(key) {
    keyProc.command = ["/usr/bin/wtype", "-k", key]
    keyProc.running = true
  }

  function closeActive() {
    closeProc.command = ["/usr/bin/hyprctl", "dispatch", "hl.dsp.window.close()"]
    closeProc.running = true
  }

  function foldedTablet() {
    var hingeEnter = root.hingeDeg > 160
    var hingeExit = root.hingeDeg < 145
    if (root.sensorTablet) {
      var wantExit = hingeExit
      root.exitStreak = wantExit ? root.exitStreak + 1 : 0
      return root.exitStreak < 3
    }
    root.exitStreak = 0
    var wantEnter = hingeEnter || root.accelY >= root.tabletEnterMG || root.accelZ <= -700
    root.enterStreak = wantEnter ? root.enterStreak + 1 : 0
    return root.enterStreak >= 2
  }

  function readSensors() {
    if (!root.sysfsInUse) return
    sensorProc.collected = ""
    sensorProc.command = ["cat", root.effectiveIncliPath, root.effectiveAccelYPath, root.effectiveAccelZPath, root.effectiveAccelXPath]
    sensorProc.running = true
  }

  function handleDiscover() {
    var lines = String(discoverProc.collected).split("\n")
    discoverProc.collected = ""
    for (var i = 0; i < lines.length; i++) {
      var line = String(lines[i]).trim()
      if (line.indexOf("incli=") === 0) {
        var p = line.slice(6)
        if (p) { root.resolvedIncliPath = p + "/in_incli_x_raw" }
      } else if (line.indexOf("accel=") === 0) {
        var q = line.slice(6)
        if (q) {
          root.resolvedAccelXPath = q + "/in_accel_x_raw"
          root.resolvedAccelYPath = q + "/in_accel_y_raw"
          root.resolvedAccelZPath = q + "/in_accel_z_raw"
        }
      }
    }
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
      if (root.autoRotateEnabled) {
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

  function refreshWorkspaceLayout() {
    if (layoutQueryProc.running) return
    layoutQueryProc.collected = ""
    layoutQueryProc.command = ["bash", "-c", "hyprctl activeworkspace -j 2>/dev/null | jq -r '.tiledLayout // \"dwindle\"' 2>/dev/null || echo dwindle"]
    layoutQueryProc.running = true
  }

  function toggleWorkspaceLayout() {
    if (layoutToggleProc.running) return
    layoutToggleProc.running = true
  }

  function sensorTick() {
    root.batteryPercent = T.batteryPercentage(UPower.displayDevice)
    root.discharging = T.isDischarging(UPower.displayDevice, UPower.onBattery, UPowerDeviceState.Discharging)
    root.readSensors()
    root.probeIio()
    root.refreshWorkspaceLayout()
  }

  function targetTransform() {
    if (!root.tabletMode) return 0
    if (!root.autoRotateEnabled) return root.screenTransform
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
    // Fixed argv helper: validates output name (alphanum._-), serializes for Lua via json.dumps,
    // stages with nofollow owner/type checks and atomically replaces randomized same-directory file.
    // No shell concatenation, no heredoc delimiter injection, no symlink following.
    rotProc.command = ["/usr/bin/python3", helperRotation, rotationFile, output, String(t)]
    rotProc.running = true
  }

  function cycleRotate() {
    // 4-position button incorporates auto: Auto -> 0 -> 1 -> 2 -> 3 -> Auto
    if (root.autoRotateEnabled) {
      // leave auto, go to current manual position (or 0)
      root.autoRotateEnabled = false
      root.rotationLocked = false
      root.rotStreak = 0
      root.notify("tomb-stone", "Auto-rotate off", "Manual " + root.screenTransform)
      return
    }
    var next = (root.screenTransform + 1) % 4
    // if we cycled through all 4, next would be 0 again - instead go to Auto after 3
    // detect full cycle: if next === 0 and we have been through 4, go to Auto
    // Use a simple counter: if current is 3, next Auto
    if (root.screenTransform === 3) {
      root.autoRotateEnabled = true
      root.rotationLocked = false
      root.rotStreak = 0
      root.notify("tomb-stone", "Auto-rotate on", "")
      // apply auto target
      root.applyTransform(root.targetTransform())
      return
    }
    root.rotationLocked = false
    root.rotStreak = 0
    root.applyTransform(next)
  }

  function toggleVoice() {
    if (root.voiceBusy) return
    if (!root.voxtypeInstalled) {
      root.notify("tomb-stone", "Voxtype is not installed", "Run: omarchy voxtype install")
      return
    }
    root.voiceBusy = true
    startDaemonProc.command = ["/usr/bin/systemctl", "--user", "start", "voxtype.service"]
    startDaemonProc.running = true
  }

  function launchMenu() {
    menuProc.command = ["/usr/share/omarchy/bin/omarchy-shell", "shell", "summon", "omarchy.menu"]
    menuProc.running = true
  }

  function nextWorkspace() {
    workspaceProc.command = ["/usr/bin/bash", "-c",
      "ws=$(/usr/bin/hyprctl activeworkspace -j | /usr/bin/jq -r .id); " +
      "/usr/bin/hyprctl dispatch 'hl.dsp.focus({ workspace = '$((ws+1))' })' > /dev/null 2>&1"]
    workspaceProc.running = true
  }

  function prevWorkspace() {
    workspaceProc.command = ["/usr/bin/bash", "-c",
      "ws=$(/usr/bin/hyprctl activeworkspace -j | /usr/bin/jq -r .id); ws=$((ws-1)); [ $ws -lt 1 ] && ws=1; " +
      "/usr/bin/hyprctl dispatch 'hl.dsp.focus({ workspace = '$ws' })' > /dev/null 2>&1"]
    workspaceProc.running = true
  }

  function notify(appName, summary, body) {
    notifyProc.command = ["/usr/bin/notify-send", "--app-name=" + appName, summary, body]
    notifyProc.running = true
  }

  function handleLayoutQuery() {
    var s = String(layoutQueryProc.collected || "").trim().toLowerCase()
    layoutQueryProc.collected = ""
    if (s === "scrolling" || s === "dwindle" || s === "master") {
      root.workspaceLayout = s
    }
  }

  Process {
    id: discoverProc
    property string collected: ""
    command: ["bash", "-c", "for d in /sys/bus/iio/devices/iio:device*; do n=$(cat \"$d/name\" 2>/dev/null); case \"$n\" in accel_3d) echo \"accel=$d\";; incli_3d) echo \"incli=$d\";; esac; done"]
    running: true
    stdout: SplitParser {
      onRead: function(data) { discoverProc.collected += data + "\n" }
    }
    onExited: function(code, exitStatus) { root.handleDiscover() }
  }

  Process {
    id: sensorProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { sensorProc.collected += data + "\n" }
    }
    onExited: function(code, exitStatus) {
      if (code !== 0 && root.resolvedIncliPath === "") {
        if (!discoverProc.running) discoverProc.running = true
      }
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
      if (code === 0 && root.pendingTransform >= 0) {
        // Secure write succeeded (validated output, nofollow atomic replace); now reload hyprland via fixed argv
        reloadProc.command = ["hyprctl", "reload"]
        reloadProc.running = true
      } else {
        if (code !== 0) console.log("tomb-stone: rotation write failed code " + code)
        root.pendingTransform = -1
      }
    }
  }

  Process {
    id: reloadProc
    onExited: function(code, exitStatus) {
      if (code === 0 && root.pendingTransform >= 0) root.screenTransform = root.pendingTransform
      else if (code !== 0) console.log("tomb-stone: hyprctl reload failed " + code)
      root.pendingTransform = -1
    }
  }

  Process {
    id: keyProc
  }

  Process {
    id: closeProc
  }

  Process {
    id: layoutQueryProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { layoutQueryProc.collected += data + "\n" }
    }
    onExited: function(code, exitStatus) { root.handleLayoutQuery() }
  }

  Process {
    id: layoutToggleProc
    command: ["omarchy-hyprland-workspace-layout-toggle"]
    onExited: function(code, exitStatus) {
      // script already sends a notification; just refresh state
      layoutRefreshTimer.restart()
    }
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

  Timer {
    id: layoutRefreshTimer
    interval: 400
    onTriggered: root.refreshWorkspaceLayout()
  }

  Connections {
    target: UPower
    function onOnBatteryChanged() {
      root.sensorTick()
    }
  }
}