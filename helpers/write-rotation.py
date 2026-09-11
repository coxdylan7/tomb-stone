#!/usr/bin/env python3
"""Securely write Hyprland rotation Lua with validation, nofollow and atomic replace."""
import sys
import os
import pathlib
import tempfile
import stat
import re
import json

def fail(msg):
    print(f"write-rotation: {msg}", file=sys.stderr)
    sys.exit(1)

# Allowed output names: Hyprland monitor names like eDP-1, HDMI-A-1, DP-1, etc.
# Strict: alphanum, dash, underscore, dot
OUTPUT_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")

def validate_output(name):
    if not isinstance(name, str):
        fail("output not string")
    if not OUTPUT_RE.match(name):
        fail(f"output invalid: {name!r} must match {OUTPUT_RE.pattern}")
    if "\n" in name or "\r" in name or "\0" in name:
        fail("output contains control char")
    return name

def validate_transform(t):
    try:
        iv = int(t)
    except:
        fail(f"transform not int: {t!r}")
    if iv not in (0, 1, 2, 3):
        fail(f"transform must be 0-3: {iv}")
    return iv

def validate_rotation_path(p):
    if not isinstance(p, str) or not p:
        fail("rotation path invalid")
    if "\n" in p or "\r" in p or "\0" in p:
        fail("rotation path invalid chars")
    home = os.environ.get("HOME") or str(pathlib.Path.home())
    expected = os.path.join(home, ".config", "hypr", "tombstone-devices.lua")
    # Strict: must be exactly expected (no alternative)
    if p != expected:
        # Also allow if HOME is ~ expansion? but we require exact
        fail(f"rotation path must be {expected!r}, got {p!r}")
    if ".." in pathlib.Path(p).parts:
        fail("rotation path contains ..")
    return p

def ensure_parent_secure(path):
    parent = os.path.dirname(path)
    try:
        pathlib.Path(parent).mkdir(parents=True, exist_ok=True)
    except Exception as e:
        fail(f"mkdir parent failed: {e}")
    uid = os.getuid()
    home = os.environ.get("HOME") or str(pathlib.Path.home())
    p = pathlib.Path(parent)
    # Walk from parent up to home, ensure no symlink, dir, owned
    for cur in [p] + list(p.parents):
        cur_str = str(cur)
        # Only check under HOME/.config
        if cur_str == home or cur_str.startswith(os.path.join(home, ".config")):
            try:
                st = os.lstat(cur_str)
                if stat.S_ISLNK(st.st_mode):
                    fail(f"parent component is symlink: {cur_str}")
                if not stat.S_ISDIR(st.st_mode):
                    fail(f"parent component not directory: {cur_str}")
                if st.st_uid != uid:
                    fail(f"parent component not owned by user: {cur_str}")
            except FileNotFoundError:
                continue
            except SystemExit:
                raise
            except Exception as e:
                fail(f"parent check failed {cur}: {e}")
        if cur_str == home:
            break

def atomic_write(path, data_bytes):
    ensure_parent_secure(path)
    uid = os.getuid()
    # Check destination if exists
    try:
        st = os.lstat(path)
        if stat.S_ISLNK(st.st_mode):
            fail(f"destination is symlink: {path}")
        if not stat.S_ISREG(st.st_mode):
            # If exists and not regular file, fail (could be fifo, dir)
            fail(f"destination not regular file: {path}")
        if st.st_uid != uid:
            fail(f"destination not owned by user: {path}")
    except FileNotFoundError:
        pass
    parent = os.path.dirname(path)
    fd = -1
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=parent, prefix=".tombstone-tmp-")
        os.fchmod(fd, 0o600)
        # Write bytes
        n = os.write(fd, data_bytes)
        if n != len(data_bytes):
            fail("short write")
        os.fsync(fd)
        os.close(fd)
        fd = -1
        st_tmp = os.lstat(tmp)
        if not stat.S_ISREG(st_tmp.st_mode) or stat.S_ISLNK(st_tmp.st_mode):
            fail("tmp not regular file")
        if st_tmp.st_uid != uid:
            fail("tmp not owned")
        os.rename(tmp, path)
        tmp = None
        os.chmod(path, 0o600)
    finally:
        if fd >= 0:
            try: os.close(fd)
            except: pass
        if tmp is not None:
            try: os.unlink(tmp)
            except: pass

def main():
    if len(sys.argv) != 4:
        fail(f"usage: {sys.argv[0]} <rotationFile> <output> <transform>")
    rotation_file = sys.argv[1]
    output = sys.argv[2]
    transform = sys.argv[3]

    validate_rotation_path(rotation_file)
    validate_output(output)
    t = validate_transform(transform)

    # Serialize output safely for Lua: use json.dumps to get double-quoted string
    # json.dumps handles escaping for quotes, backslashes, control chars
    # Since we validated output has no quotes/control, this is safe, but we still use json.dumps
    lua_output = json.dumps(output)  # e.g., "\"eDP-1\""

    # Generate Lua content - static template, no shell
    # Use validated lua_output directly (includes quotes)
    content = (
        "-- Managed by djc.tomb-stone: syncs touchscreen digitizer + monitor.\n"
        "hl.config({\n"
        f"  input = {{ touchdevice = {{ output = {lua_output}, transform = {t} }} }},\n"
        "})\n"
        f"hl.monitor({{ output = {lua_output}, transform = {t} }})\n"
    )
    data = content.encode('utf-8')
    if len(data) > 4096:
        fail("generated lua too large")
    atomic_write(rotation_file, data)
    print(f"wrote {rotation_file} output={output} transform={t}")

if __name__ == "__main__":
    main()
