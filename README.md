# Tomb Stone

A tablet companion for 2-in-1 / convertible laptops on [Omarchy](https://omarchy.org). It detects tablet mode from the IIO accelerometer, auto-rotates the display (and the touchscreen digitizer with it), and provides an always-on touch dock with dictation, launcher, workspace, rotate, rotate-lock, and battery controls.

## Features

- **Sensor-driven tablet detection** — uses the sysfs IIO inclinometer/accelerometer (no `iio-sensor-proxy` required) with debouncing to avoid flip-flopping on the hinge boundary.
- **Auto-rotation** — transforms the Hyprland monitor to match device orientation. Works in both landscape orientations; portrait is also auto-rotated when the device is held upright (see limitations).
- **Touchscreen sync** — rotates `input.touchdevice.transform` together with the monitor so absolute touch stays aligned with the image in every orientation.
- **Touch dock** (`PanelWindow`, bottom edge):
  - **✕ Close** (far left) — closes the focused window
  - **Voice** — toggles [Voxtype](https://omarchy.org) dictation (pulsing red dot while recording)
  - **Launcher** — summons the omarchy menu
  - **◀ ▶ Prev/Next** — switch workspaces (creates them on demand)
  - **Rotate** — force-cycles the display transform
  - **Lock** — freezes auto-rotation until unlocked
  - **Battery** — percent / charging state
  - **⌫ Back / ⏎ Enter** (far right) — sends those keys to the focused app via `wtype`
- The dock hides in laptop mode and reappears when folded into tablet mode.

## Requirements

- Omarchy (Quickshell + Hyprland)
- `wtype` (for the Back / Enter keys)
- Voxtype (optional, for dictation)
- A convertible with IIO accelerometer + inclinometer that exposes sysfs raw nodes (paths are configurable)

### Sensor support is hardware-specific

The plugin reads raw IIO sysfs nodes (e.g. `/sys/bus/iio/devices/iio:device3/in_accel_*_raw`). Depending on your machine, the sensors are provided by kernel drivers that must be present *for your specific hardware* — for example `hid-sensor-*`, `kxcjk-1013`, `bmg160`, or vendor-specific modules. If no sensors show up in `ls /sys/bus/iio/devices/`, find which module your device's accelerometer/inclinometer needs and load it (the Omarchy hardware mode can also pull in the right detection packages). The `*RawPath` config values must then point at the correct devices — the example paths above are from an IdeaPad and will differ on other hardware.

## Install

```sh
mkdir -p ~/.config/omarchy/plugins
cp -r djc.tomb-stone ~/.config/omarchy/plugins/
omarchy restart shell
```

## Removal

```sh
omarchy plugin remove djc.tomb-stone
# or, if installed manually:
rm -rf ~/.config/omarchy/plugins/djc.tomb-stone
```

After removal, clean up the touch-rotation integration so a reload won't reference the missing file:

- Remove the `require("hypr.tombstone-devices")` line you added to `~/.config/hypr/hyprland.lua`.
- Delete `~/.config/hypr/tombstone-devices.lua` (it is only written and reloaded by the plugin).
- Remove the `djc.tomb-stone` entry from the `plugins` list in `~/.config/omarchy/shell.json`.

Then `omarchy restart shell`.

### Touchscreen rotation sync

To keep the digitizer rotated with the display, add this line to `~/.config/hypr/hyprland.lua`:

```lua
require("hypr.tombstone-devices")
```

The plugin writes `~/.config/hypr/tombstone-devices.lua` on every rotation and reloads Hyprland, setting `input.touchdevice.transform` to match the monitor transform. This is global (applies to all touch devices), so no device-name configuration is needed.

## Configuration

Add a `djc.tomb-stone` entry under `plugins` in `~/.config/omarchy/shell.json`:

```json
{
  "id": "djc.tomb-stone",
  "detector": "auto",
  "pollSeconds": 1,
  "autoRotate": true,
  "landscapeOnly": false,
  "output": "eDP-1",
  "tabletModeOverride": "auto",
  "rotateDirection": -1,
  "incliRawPath": "/sys/bus/iio/devices/iio:device0/in_incli_x_raw",
  "accelXRawPath": "/sys/bus/iio/devices/iio:device3/in_accel_x_raw",
  "accelYRawPath": "/sys/bus/iio/devices/iio:device3/in_accel_y_raw",
  "accelZRawPath": "/sys/bus/iio/devices/iio:device3/in_accel_z_raw",
  "tabletEnterMG": 350,
  "tabletExitMG": -250,
  "tabletExitAZ": -400,
  "buttons": ["voice", "launcher", "workspaces", "rotate", "lock", "battery"]
}
```

| Option | Default | Description |
| --- | --- | --- |
| `detector` | `"auto"` | `auto`/`sysfs` read raw sysfs nodes; `iio` uses the D-Bus sensor proxy |
| `pollSeconds` | `1` | Sensor poll interval |
| `autoRotate` | `true` | Automatically transform the display to match orientation |
| `landscapeOnly` | `true` | Only ever use landscape transforms |
| `output` | `"eDP-1"` | Monitor / output name that gets transformed |
| `tabletModeOverride` | `"auto"` | `auto`, `on`, or `off` for tablet mode detection |
| `rotateDirection` | `-1` | Direction multiplier for the azimuth→transform mapping |
| `*RawPath` | … | sysfs paths for the inclinometer and accelerometer axes |
| `tabletEnterMG` | `350` | mg threshold to enter tablet mode |
| `tabletExitMG` | `-250` | mg threshold to leave tablet mode |
| `tabletExitAZ` | `-400` | z-axis ceiling that must hold while leaving tablet mode |
| `buttons` | `["voice","launcher","workspaces","rotate","battery"]` | Which middle dock tiles to show |

## Known limitations

- Auto-rotation for **portrait** requires the tablet to be held fairly upright — a flat, hand-held portrait pose has almost no in-plane gravity signal, so the Rotate button is the reliable way to reach portrait from there.
- On environments where the config keyword path is unavailable, `hyprctl reload` is used for the touch transfer — make sure nothing else relies on that reload being side-effect free.
- The physical rotation-lock key present on some Lenovo IdeaPads is not currently mapped to the Lock state.

## License

MIT