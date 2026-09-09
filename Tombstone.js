function pluginEntry(shell, pluginId) {
  var cfg = shell ? shell.shellConfig : null
  var list = cfg && Array.isArray(cfg.plugins) ? cfg.plugins : []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && String(list[i].id || "") === pluginId) return list[i]
  }
  return {}
}

function configStr(entry, key, fallback) {
  var v = entry[key]
  return typeof v === "string" && v.length > 0 ? v : fallback
}

function configInt(entry, key, fallback) {
  var v = entry[key]
  var n = Number(v)
  return isFinite(n) && n >= 0 ? Math.round(n) : fallback
}

function configBool(entry, key, fallback) {
  var v = entry[key]
  return v === undefined ? fallback : !!v
}

function configList(entry, key, fallback) {
  var v = entry[key]
  return Array.isArray(v) && v.length > 0 ? v.slice() : fallback.slice()
}

function batteryPercentage(device) {
  if (!device || !device.isPresent) return -1
  return Math.round(Number(device.percentage || 0) * 100)
}

function isDischarging(device, onBattery, dischargingState) {
  return !!(device && device.isPresent && onBattery && device.state === dischargingState)
}

function parseDBusGetAll(text) {
  var obj = {}
  if (!text) return obj
  var m = String(text).match(/\{([\s\S]*)\}/)
  if (!m) return obj
  var re = /['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?:\s*<([^>]*)>/g
  var r
  while ((r = re.exec(m[1]))) {
    var k = r[1]
    var v = String(r[2]).trim()
    if (v === "true") v = true
    else if (v === "false") v = false
    else if (v.length >= 2 && v.charAt(0) === "'") v = v.slice(1, -1)
    else {
      var n = Number(v)
      if (isFinite(n)) v = n
    }
    obj[k] = v
  }
  return obj
}

function parseFloats(text) {
  var parts = String(text || "").trim().split(/\s+/)
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var n = Number(parts[i])
    out.push(isFinite(n) ? n : NaN)
  }
  return out
}

function clamp(n, lo, hi) {
  return Math.max(lo, Math.min(hi, n))
}

if (typeof module !== "undefined") {
  module.exports = {
    pluginEntry: pluginEntry,
    configStr: configStr,
    configInt: configInt,
    configBool: configBool,
    configList: configList,
    batteryPercentage: batteryPercentage,
    isDischarging: isDischarging,
    parseDBusGetAll: parseDBusGetAll,
    parseFloats: parseFloats,
    clamp: clamp
  }
}