#!/usr/bin/env python3
"""Exercise real snapshots and streams on an ALREADY MOUNTED disposable Btrfs FS.

Usage: python3 btrfs_scenarios.py --parent /lab
Creates and retains a fresh issue140-* directory, with only test credentials.
Never formats, mounts, deletes subvolumes, or operates on existing profiles.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

import credential_demo as demo
from test_credential_demo import fixture, SERVICE


def run(*args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True).stdout.strip()


def password_hash(password, salt):
    return subprocess.run(["openssl", "passwd", "-6", "-salt", salt, "-stdin"], input=password + "\n", text=True, capture_output=True, check=True).stdout.strip()


def shadow_hash(root):
    return demo.owner(demo.parse_db((root / "etc/shadow").read_bytes(), 9), "user")[1]


def accepts(root, password):
    stored = shadow_hash(root)
    return stored == password_hash(password, stored.split("$")[2])


def require(condition, explanation):
    if not condition:
        raise AssertionError(explanation)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parent", required=True, type=Path)
    args = parser.parse_args()
    # BusyBox stat reports UNKNOWN for the Btrfs name; the kernel magic is
    # stable and works with both BusyBox and GNU stat.
    if os.geteuid() != 0 or not args.parent.is_absolute() or run("stat", "-f", "-c", "%t", args.parent).lower() != "9123683e":
        parser.error("an absolute path on a disposable, mounted Btrfs filesystem and root are required")
    lab = Path(tempfile.mkdtemp(prefix="issue140-", dir=args.parent))
    (lab / ".issue140-lab").write_text(demo.MARKER)
    profiles = lab / "profiles"
    profiles.mkdir()
    run("btrfs", "subvolume", "create", lab / "identity")
    (lab / "identity").chmod(0o700)
    run("btrfs", "subvolume", "create", lab / "@home")
    (lab / "@home/owner-document").write_text("shared user data\n")

    def create(name, password, salt):
        dest = profiles / name
        run("btrfs", "subvolume", "create", dest)
        fixture(dest, password_hash(password, salt))
        return dest

    def snapshot(source, name, readonly=False):
        dest = profiles / name
        run("btrfs", "subvolume", "snapshot", *(["-r"] if readonly else []), source, dest)
        return dest

    def reconciled(name, current, previous):
        root = profiles / name
        require(demo.apply(lab, name) == "drift", "expected credential drift")
        require(demo.apply(lab, name, write=True) == "updated", "expected replacement")
        require(accepts(root, current) and not accepts(root, previous), "password verification failed")
        require(SERVICE in (root / "etc/shadow").read_text(), "service account changed")
        require(demo.apply(lab, name, write=True) == "current", "repeat was not idempotent")

    stock = create("stock", "user", "stockfixture")
    run("btrfs", "property", "set", "-ts", stock, "ro", "true")
    desktop = snapshot(stock, "desktop")
    minimal = snapshot(stock, "minimal")
    value = (desktop / "etc/shadow").read_text().replace(shadow_hash(desktop), password_hash("owner-v1-test-only", "ownerfixture1"))
    (desktop / "etc/shadow").write_text(value)
    require(accepts(minimal, "user") and not accepts(desktop, "user"), "baseline did not reproduce drift")
    print("PASS 1: changing Desktop password leaves Minimal accepting the stock password")

    demo.capture(lab, "desktop")
    reconciled("minimal", "owner-v1-test-only", "user")
    print("PASS 2: owner reconciliation rejects the old password and preserves service records")

    snapshot(desktop, "clone")
    require(demo.apply(lab, "clone") == "current", "configured clone should inherit current password")
    print("PASS 3: clone of a configured profile is already current")

    snapshot(stock, "stock-reset")
    require(accepts(profiles / "stock-reset", "user"), "stock reset did not restore stock credentials")
    reconciled("stock-reset", "owner-v1-test-only", "user")
    require(accepts(stock, "user"), "read-only stock source changed")
    print("PASS 4: stock reset initially restores defaults; reconciliation repairs its writable copy")

    (desktop / "etc/onboarding-complete").write_text("yes\n")
    old = snapshot(desktop, "desktop-v1-snapshot", readonly=True)
    value = (desktop / "etc/shadow").read_text().replace(shadow_hash(desktop), password_hash("owner-v2-test-only", "ownerfixture2"))
    (desktop / "etc/shadow").write_text(value)
    demo.capture(lab, "desktop")
    rollback = snapshot(old, "rollback")
    require(accepts(rollback, "owner-v1-test-only"), "rollback did not restore prior password")
    require((rollback / "etc/onboarding-complete").exists(), "stale onboarding marker missing")
    reconciled("rollback", "owner-v2-test-only", "owner-v1-test-only")
    print("PASS 5: old snapshot with an onboarding marker is reconciled to the latest shared state")

    foreign = create("foreign", "foreign-test-only", "foreignfixture")
    run("btrfs", "property", "set", "-ts", foreign, "ro", "true")
    imported = lab / "imports"
    imported.mkdir()
    stream = lab / "foreign.btrfs"
    with stream.open("wb") as out:
        subprocess.run(["btrfs", "send", str(foreign)], stdout=out, stderr=subprocess.PIPE, check=True)
    with stream.open("rb") as src:
        subprocess.run(["btrfs", "receive", str(imported)], stdin=src, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    snapshot(imported / "foreign", "imported")
    reconciled("imported", "owner-v2-test-only", "foreign-test-only")
    print("PASS 6: a real send/receive import gets local credentials in its writable profile")

    readonly_before = (stock / "etc/shadow").read_bytes()
    try:
        demo.apply(lab, "stock", write=True)
    except OSError:
        pass
    else:
        raise AssertionError("read-only stock should refuse mutation")
    require((stock / "etc/shadow").read_bytes() == readonly_before, "read-only stock was altered")
    print("PASS 7: read-only stock refuses mutation and retains its original content")

    collision = snapshot(stock, "different-uid")
    path = collision / "etc/passwd"
    path.write_text(path.read_text().replace("user:x:1000:", "user:x:1001:"))
    before = (collision / "etc/shadow").read_bytes()
    try:
        demo.apply(lab, "different-uid", write=True)
    except demo.Refused:
        pass
    else:
        raise AssertionError("mismatched UID was accepted")
    require((collision / "etc/shadow").read_bytes() == before, "mismatched-UID profile was changed")
    print("PASS 8: mismatched UID is refused before altering credentials")

    require((lab / "@home/owner-document").read_text() == "shared user data\n", "shared home changed")
    for name in ["desktop", "minimal", "clone", "stock-reset", "rollback", "imported"]:
        require((profiles / name / "etc/machine-id").read_text() == "profile-specific\n", "machine-id changed")
    state = json.loads((lab / "identity/owner.json").read_text())
    require(state["shadow_fields"][0] == shadow_hash(desktop), "shared identity rolled back with a profile")
    print("PASS 9: shared home and per-profile machine-id files are unchanged; identity state survives profile rollback")
    print("All 9 Btrfs scenarios passed.")
    print(f"Disposable fixtures retained at {lab}")


if __name__ == "__main__":
    main()
