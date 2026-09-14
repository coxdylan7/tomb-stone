#!/usr/bin/python3
"""Securely write Hyprland rotation Lua with validation, nofollow and atomic replace — descriptor-relative hardened per b2acb44 review."""
import sys
import os
import pathlib
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

def open_trusted_base(home_path):
    # Open HOME with O_DIRECTORY|O_NOFOLLOW and validate
    try:
        fd = os.open(home_path, os.O_DIRECTORY | os.O_NOFOLLOW)
    except Exception as e:
        fail(f"open HOME failed: {e}")
    try:
        st = os.fstat(fd)
    except Exception as e:
        try: os.close(fd)
        except: pass
        fail(f"fstat HOME failed: {e}")
    if not stat.S_ISDIR(st.st_mode):
        try: os.close(fd)
        except: pass
        fail(f"HOME not directory: {home_path}")
    if stat.S_ISLNK(st.st_mode):
        try: os.close(fd)
        except: pass
        fail(f"HOME is symlink: {home_path}")
    if st.st_uid != os.getuid():
        try: os.close(fd)
        except: pass
        fail(f"HOME not owned: {home_path}")
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        try: os.close(fd)
        except: pass
        fail(f"HOME writable by group/other: {home_path} mode {oct(st.st_mode)}")
    return fd

def ensure_parent_descriptor_relative(home_fd, home_path, parent_path):
    # parent_path is absolute, must be under home_path
    if not parent_path.startswith(home_path + os.sep):
        fail(f"parent not under HOME: {parent_path}")
    rel = os.path.relpath(parent_path, home_path)  # e.g. .config/hypr
    parts = rel.split(os.sep)
    cur_fd = home_fd
    cur_path = home_path
    # We will walk components, opening each descriptor-relatively, creating if needed via mkdirat
    # To avoid leaking fds, we keep current fd and open next, then close previous when moving deeper
    # But we need to keep home_fd open for caller? We'll duplicate.
    # Instead, we will use home_fd as base and walk with new fds, closing intermediate.
    # For simplicity, we dup home_fd to start
    try:
        cur_fd_dup = os.dup(home_fd)
    except Exception as e:
        fail(f"dup HOME fd failed: {e}")
    cur_fd = cur_fd_dup
    cur_path = home_path
    for comp in parts:
        if not comp or comp == ".":
            continue
        if comp == ".." or "/" in comp or "\n" in comp or "\0" in comp:
            try: os.close(cur_fd)
            except: pass
            fail(f"invalid component: {comp}")
        # Try to open next component with O_NOFOLLOW
        next_path = os.path.join(cur_path, comp)
        try:
            next_fd = os.open(comp, os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=cur_fd)
            # Validate opened dir
            try:
                st = os.fstat(next_fd)
            except Exception as e:
                try: os.close(next_fd)
                except: pass
                try: os.close(cur_fd)
                except: pass
                fail(f"fstat component failed {next_path}: {e}")
            if not stat.S_ISDIR(st.st_mode):
                try: os.close(next_fd)
                except: pass
                try: os.close(cur_fd)
                except: pass
                fail(f"component not directory: {next_path}")
            if stat.S_ISLNK(st.st_mode):
                try: os.close(next_fd)
                except: pass
                try: os.close(cur_fd)
                except: pass
                fail(f"component is symlink: {next_path}")
            if st.st_uid != os.getuid():
                try: os.close(next_fd)
                except: pass
                try: os.close(cur_fd)
                except: pass
                fail(f"component not owned: {next_path}")
            if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                try: os.close(next_fd)
                except: pass
                try: os.close(cur_fd)
                except: pass
                fail(f"component writable by group/other: {next_path} mode {oct(st.st_mode)}")
            # Success, move to next
            try: os.close(cur_fd)
            except: pass
            cur_fd = next_fd
            cur_path = next_path
        except FileNotFoundError:
            # Need to create directory descriptor-relatively via mkdirat
            try:
                os.mkdir(comp, 0o700, dir_fd=cur_fd)
            except FileExistsError:
                # Raced, try open again
                try:
                    next_fd = os.open(comp, os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=cur_fd)
                    st = os.fstat(next_fd)
                    if st.st_uid != os.getuid() or st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                        try: os.close(next_fd)
                        except: pass
                        try: os.close(cur_fd)
                        except: pass
                        fail(f"raced component not owned/writable: {next_path}")
                    try: os.close(cur_fd)
                    except: pass
                    cur_fd = next_fd
                    cur_path = next_path
                    continue
                except Exception as e:
                    try: os.close(cur_fd)
                    except: pass
                    fail(f"mkdir raced open failed {next_path}: {e}")
            except Exception as e:
                try: os.close(cur_fd)
                except: pass
                fail(f"mkdir component failed {next_path}: {e}")
            # After mkdir, open it
            try:
                next_fd = os.open(comp, os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=cur_fd)
            except Exception as e:
                try: os.close(cur_fd)
                except: pass
                fail(f"open after mkdir failed {next_path}: {e}")
            # Validate and chmod via fd (fchmod) to 0o700
            try:
                st = os.fstat(next_fd)
                if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
                    try: os.close(next_fd)
                    except: pass
                    try: os.close(cur_fd)
                    except: pass
                    fail(f"new component not owned/dir: {next_path}")
                # Ensure perms 0o700 via fchmod
                try:
                    os.fchmod(next_fd, 0o700)
                except Exception as e:
                    try: os.close(next_fd)
                    except: pass
                    try: os.close(cur_fd)
                    except: pass
                    fail(f"fchmod failed {next_path}: {e}")
            except Exception as e:
                try: os.close(next_fd)
                except: pass
                try: os.close(cur_fd)
                except: pass
                fail(f"fstat new component failed {next_path}: {e}")
            try: os.close(cur_fd)
            except: pass
            cur_fd = next_fd
            cur_path = next_path
        except OSError as e:
            # Any other error (e.g., symlink encountered, ELOOP)
            try: os.close(cur_fd)
            except: pass
            fail(f"open component failed {next_path}: {e}")
    # cur_fd is now the parent directory fd, pinned
    return cur_fd

def atomic_write(path, data_bytes):
    home = os.environ.get("HOME") or str(pathlib.Path.home())
    parent = os.path.dirname(path)
    base = os.path.basename(path)
    # Open trusted HOME base
    home_fd = open_trusted_base(home)
    try:
        # Ensure parent exists descriptor-relatively and get pinned fd
        # This walks HOME/.config and HOME/.config/hypr with O_NOFOLLOW and mkdirat/fchmod
        dir_fd = ensure_parent_descriptor_relative(home_fd, home, parent)
        # Ensure final parent perms 0o700 via retained fd (descriptor-relative, no pathname follow)
        try:
            os.fchmod(dir_fd, 0o700)
        except Exception as e:
            fail(f"fchmod parent failed: {e}")
        # At this point dir_fd is pinned parent fd, already validated and chmodded via fchmod
        # No pathname mkdir/chmod before open — all descriptor-relative
        try:
            uid = os.getuid()
            # Check destination via dir_fd with nofollow
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
            # Create temp file descriptor-relatively
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
                # Atomic rename via descriptor-relative renameat — fail closed, no pathname fallback
                try:
                    os.rename(tmp_name, base, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
                except TypeError as e:
                    fail(f"rename with dir_fd not supported, failing closed: {e}")
                except Exception as e:
                    fail(f"rename failed: {e}")
                tmp_name = None
            finally:
                if fd >= 0:
                    try: os.close(fd)
                    except: pass
                if tmp_name is not None:
                    try: os.unlink(tmp_name, dir_fd=dir_fd)
                    except: pass
        finally:
            try: os.close(dir_fd)
            except: pass
    finally:
        try: os.close(home_fd)
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
