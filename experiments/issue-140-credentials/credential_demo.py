#!/usr/bin/env python3
"""Issue #140 experiment. Operates only inside a marked, disposable Linux lab.

Not an installed credential service: profiles must be offline, trusted, and have
no concurrent account writers. See README.md before running.
"""

import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

MARKER = "issue140-disposable-lab-v1\n"


class Refused(Exception):
    """A deliberately nonsensitive error suitable for console output."""


def checked(path, directory=False, private=False):
    """Reject symlinks and writable-by-others paths in this trusted offline lab."""
    for part in [*reversed(path.parents), path]:
        s = part.lstat()
        if stat.S_ISLNK(s.st_mode):
            raise Refused("symlink paths are unsupported")
    s = path.stat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o022:
        raise Refused("expected root-owned file/directory without group/other write access")
    if private and s.st_mode & 0o077:
        raise Refused("identity state must be accessible only to root")
    if not directory and s.st_nlink != 1:
        raise Refused("hard-linked files are unsupported")
    return s


def read_file(path, private=False):
    checked(path, private=private)
    data = path.read_bytes()
    if len(data) > 1024 * 1024:
        raise Refused("input exceeds the lab size limit")
    return data


def parse_db(data, count):
    try:
        value = data.decode("utf-8")
    except UnicodeError:
        raise Refused("account database is not UTF-8") from None
    if not value.endswith("\n") or any(c in value for c in "\r\0"):
        raise Refused("account database has invalid line endings")
    rows = [line.split(":") for line in value[:-1].split("\n")]
    names = set()
    for row in rows:
        if len(row) != count or not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_.-]*\$?", row[0]):
            raise Refused("account database has an invalid record")
        if row[0] in names:
            raise Refused("account database has duplicate names")
        names.add(row[0])
        if count == 7 and not all(x.isascii() and x.isdecimal() for x in row[2:4]):
            raise Refused("passwd has an invalid numeric identity")
        if count == 9 and not all(not x or (x.isascii() and x.isdecimal()) for x in row[2:8]):
            raise Refused("shadow has invalid password-aging fields")
    return rows


def owner(rows, name):
    matches = [row for row in rows if row[0] == name]
    if len(matches) != 1:
        raise Refused("owner account is missing")
    return matches[0]


def profile(lab, name):
    if name in (".", "..") or not re.fullmatch(r"[A-Za-z0-9_@.-]+", name):
        raise Refused("invalid profile label")
    for p in (lab / "profiles", lab / "profiles" / name, lab / "profiles" / name / "etc"):
        checked(p, directory=True)
    return lab / "profiles" / name / "etc"


def account(etc, name):
    passwd = parse_db(read_file(etc / "passwd"), 7)
    p = owner(passwd, name)
    uid, gid = int(p[2]), int(p[3])
    if uid < 1000 or gid < 1000 or p[1] != "x":
        raise Refused("prototype supports an existing non-system owner using shadow passwords")
    if sum(int(row[2]) == uid for row in passwd) != 1:
        raise Refused("owner UID is shared by another account")
    data = read_file(etc / "shadow")
    shadow = parse_db(data, 9)
    return uid, gid, data, shadow, owner(shadow, name)


def atomic_write(path, data, previous=None):
    """Replace one file; preserve target ownership, mode, and Linux xattrs."""
    fd, temporary = tempfile.mkstemp(prefix=".issue140-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as out:
            if previous is not None:
                os.fchown(out.fileno(), previous.st_uid, previous.st_gid)
                os.fchmod(out.fileno(), stat.S_IMODE(previous.st_mode))
                for name in os.listxattr(path):
                    os.setxattr(temporary, name, os.getxattr(path, name))
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def lab_lock(lab):
    if os.geteuid() != 0:
        raise Refused("run inside the disposable Linux VM as root")
    if not lab.is_absolute() or lab == Path("/"):
        raise Refused("an absolute disposable lab path is required")
    checked(lab, directory=True)
    if read_file(lab / ".issue140-lab").decode() != MARKER:
        raise Refused("disposable-lab marker is missing or invalid")
    fd = os.open(lab / ".issue140.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        checked(lab / ".issue140.lock", private=True)
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def validate_state(state):
    if not isinstance(state, dict) or set(state) != {"version", "owner", "uid", "gid", "shadow_fields"}:
        raise Refused("identity state has an invalid schema")
    if type(state["version"]) is not int or state["version"] != 1:
        raise Refused("unsupported identity-state version")
    if type(state["owner"]) is not str or not re.fullmatch(r"[a-z_][a-z0-9_.-]*", state["owner"]):
        raise Refused("invalid owner name")
    if any(type(state[k]) is not int or state[k] < 1000 for k in ("uid", "gid")):
        raise Refused("invalid owner numeric identity")
    fields = state["shadow_fields"]
    if not isinstance(fields, list) or len(fields) != 8 or any(type(x) is not str or any(c in x for c in ":\n\r\0") for x in fields):
        raise Refused("invalid owner shadow fields")
    # Empty passwords are never accepted. Locked accounts and modular crypt
    # strings are supported; this is not a password-strength/onboarding check.
    if not fields[0] or fields[0][0] not in "!*$":
        raise Refused("owner needs a locked account or a modular password hash")
    parse_db((state["owner"] + ":" + ":".join(fields) + "\n").encode(), 9)
    return state


def capture(lab, name, username="user"):
    with lab_lock(lab):
        uid, gid, _, _, row = account(profile(lab, name), username)
        state = validate_state(dict(version=1, owner=username, uid=uid, gid=gid, shadow_fields=row[1:]))
        directory = lab / "identity"
        directory.mkdir(mode=0o700, exist_ok=True)
        checked(directory, directory=True, private=True)
        path = directory / "owner.json"
        if path.exists() or path.is_symlink():
            checked(path, private=True)
        atomic_write(path, (json.dumps(state, sort_keys=True) + "\n").encode())
    return "captured"


def apply(lab, name, write=False):
    with lab_lock(lab):
        checked(lab / "identity", directory=True, private=True)
        try:
            state = validate_state(json.loads(read_file(lab / "identity/owner.json", private=True)))
        except (ValueError, UnicodeError):
            raise Refused("identity state is not valid JSON") from None
        etc = profile(lab, name)
        uid, gid, original, rows, row = account(etc, state["owner"])
        if (uid, gid) != (state["uid"], state["gid"]):
            raise Refused("owner UID/GID differs; account provisioning needs an explicit policy")
        if row[1:] == state["shadow_fields"]:
            return "current"
        if not write:
            return "drift"
        row[1:] = state["shadow_fields"]
        result = ("\n".join(":".join(r) for r in rows) + "\n").encode()
        previous = checked(etc / "shadow")
        if read_file(etc / "shadow") != original:
            raise Refused("shadow changed during preparation")
        atomic_write(etc / "shadow", result, previous)
        return "updated"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lab", required=True, type=Path)
    sub = parser.add_subparsers(dest="command", required=True)
    cap = sub.add_parser("capture", help="capture a configured offline lab owner's shadow policy")
    cap.add_argument("profile")
    cap.add_argument("--owner", default="user")
    sync = sub.add_parser("apply", help="check a profile; add --write to replace its owner shadow row")
    sync.add_argument("profile")
    sync.add_argument("--write", action="store_true")
    args = parser.parse_args(argv)
    try:
        result = capture(args.lab, args.profile, args.owner) if args.command == "capture" else apply(args.lab, args.profile, args.write)
        print(result)
        return 2 if result == "drift" else 0
    except (Refused, OSError, UnicodeError):
        # Do not print raw exceptions: paths, JSON parse text, or account input
        # may contain secrets. Detailed policy is described in README.md.
        print("refused: validate lab paths, permissions, owner identity, and input format", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
