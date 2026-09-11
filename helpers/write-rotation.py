#!/usr/bin/env python3
"""Securely write Hyprland rotation Lua with validation, nofollow and atomic replace."""
import sys
import os
import pathlib
import tempfile
import stat
import re
import json
import secrets

def fail(msg):
    print(f"write-rotation: {msg}", file=sys.stderr)
    sys.exit(1)

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
    if p != expected:
        fail(f"rotation path must be {expected!r}, got {p!r}")
    if ".." in pathlib.Path(p).parts:
        fail("rotation path contains ..")
    return p

def ensure_parent_secure_pinned(parent_fd, parent_path):
    # Check parent dir via fd: not symlink, owned, not group/other writable
    try:
        st = os.fstat(parent_fd)
    except Exception as e:
        fail(f"fstat parent failed: {e}")
    if not stat.S_ISDIR(st.st_mode):
        fail(f"parent not directory: {parent_path}")
    if stat.S_ISLNK(st.st_mode):
        fail(f"parent is symlink: {parent_path}")
    if st.st_uid != os.getuid():
        fail(f"parent not owned: {parent_path}")
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        fail(f"parent writable by group/other: {parent_path} mode {oct(st.st_mode)}")
    # Walk parents via lstat for each component under HOME/.config
    uid = os.getuid()
    home = os.environ.get("HOME") or str(pathlib.Path.home())
    p = pathlib.Path(parent_path)
    for cur in [p] + list(p.parents):
        cur_str = str(cur)
        if cur_str == home or cur_str.startswith(os.path.join(home, ".config")):
            try:
                st2 = os.lstat(cur_str)
                if stat.S_ISLNK(st2.st_mode):
                    fail(f"parent component is symlink: {cur_str}")
                if not stat.S_ISDIR(st2.st_mode):
                    fail(f"parent component not directory: {cur_str}")
                if st2.st_uid != uid:
                    fail(f"parent component not owned: {cur_str}")
                if st2.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                    fail(f"parent component writable by group/other: {cur_str} mode {oct(st2.st_mode)}")
            except FileNotFoundError:
                continue
            except SystemExit:
                raise
            except Exception as e:
                fail(f"parent check failed {cur}: {e}")
        if cur_str == home:
            break

def atomic_write(path, data_bytes):
    parent = os.path.dirname(path)
    base = os.path.basename(path)
    # Ensure parent exists with secure perms
    try:
        pathlib.Path(parent).mkdir(parents=True, exist_ok=True)
        # ensure parent perms 0o700
        os.chmod(parent, 0o700)
    except Exception as e:
        fail(f"mkdir parent failed: {e}")
    # Open parent dir with O_DIRECTORY|O_NOFOLLOW to pin
    try:
        dir_fd = os.open(parent, os.O_DIRECTORY | os.O_NOFOLLOW)
    except Exception as e:
        fail(f"open parent dir failed: {e}")
    try:
        ensure_parent_secure_pinned(dir_fd, parent)
        uid = os.getuid()
        # Check destination via dir_fd + base with nofollow
        try:
            st = os.stat(base, dir_fd=dir_fd, follow_symlinks=False)
            if stat.S_ISLNK(st.st_mode):
                fail(f"destination is symlink: {path}")
            if not stat.S_ISREG(st.st_mode):
                fail(f"destination not regular file: {path}")
            if st.st_uid != uid:
                fail(f"destination not owned: {path}")
            if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                fail(f"destination writable by group/other: {path}")
        except FileNotFoundError:
            pass
        # Create temp file with O_CREAT|O_EXCL|O_NOFOLLOW via dir_fd
        tmp_name = f".tombstone-tmp-{secrets.token_hex(8)}"
        try:
            fd = os.open(tmp_name, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=dir_fd)
        except Exception as e:
            fail(f"create tmp failed: {e}")
        try:
            n = os.write(fd, data_bytes)
            if n != len(data_bytes):
                fail("short write")
            os.fsync(fd)
            os.close(fd)
            fd = -1
            # Verify tmp is regular file not symlink, owned, not writable
            try:
                st_tmp = os.stat(tmp_name, dir_fd=dir_fd, follow_symlinks=False)
                if not stat.S_ISREG(st_tmp.st_mode) or stat.S_ISLNK(st_tmp.st_mode):
                    fail("tmp not regular file")
                if st_tmp.st_uid != uid:
                    fail("tmp not owned")
                if st_tmp.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                    fail("tmp writable by group/other")
            except Exception as e:
                fail(f"tmp check failed: {e}")
            # Atomic rename via renameat with dir_fd for both src and dst
            try:
                # Use os.rename with dir_fd via low-level: os.renameat not directly exposed, use os.rename with absolute fallback but keep dir_fd open
                # Python 3.8+ supports src_dir_fd and dst_dir_fd for os.rename
                os.rename(tmp_name, base, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
            except TypeError:
                # fallback to absolute rename if rename with dir_fd not supported
                # Keep dir_fd open to prevent parent replacement during rename
                tmp_abs = os.path.join(parent, tmp_name)
                os.rename(tmp_abs, path)
            tmp_name = None
            # Ensure final perms 0o600 via dir_fd
            try:
                os.chmod(base, 0o600, dir_fd=dir_fd)
            except:
                os.chmod(path, 0o600)
        finally:
            if fd >= 0:
                try: os.close(fd)
                except: pass
            if tmp_name is not None:
                try: os.unlink(tmp_name, dir_fd=dir_fd)
                except: pass
                try: os.unlink(os.path.join(parent, tmp_name))
                except: pass
    finally:
        try: os.close(dir_fd)
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

    lua_output = json.dumps(output)
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
