"""Run as root in a disposable Linux environment: python3 -m unittest -v."""

import contextlib
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

import credential_demo as demo

STOCK = "$6$fixture$stock-hash"
CURRENT = "$6$fixture$current-hash"
PASSWD = "root:x:0:0:root:/root:/bin/sh\nuser:x:1000:1000:Owner:/home/user:/bin/sh\nflipctl:x:998:998:Service:/var/lib/flipctl:/sbin/nologin\n"
SERVICE = "flipctl:!:20000:0:99999:7:::\n"


def fixture(root, password=STOCK):
    etc = root / "etc"
    etc.mkdir(parents=True)
    (etc / "passwd").write_text(PASSWD)
    (etc / "shadow").write_text("root:*:20000:0:99999:7:::\n" + f"user:{password}:20001:0:99999:7:::\n" + SERVICE)
    (etc / "shadow").chmod(0o640)
    for name, value in {"group": "root:x:0:\nuser:x:1000:\nflipctl:x:998:\n", "gshadow": "root:!::\nuser:!::\n", "machine-id": "profile-specific\n"}.items():
        (etc / name).write_text(value)
    return etc


class CredentialTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="issue140-unit-")
        self.addCleanup(self.temp.cleanup)
        self.lab = Path(self.temp.name)
        (self.lab / ".issue140-lab").write_text(demo.MARKER)
        self.source = fixture(self.lab / "profiles/desktop", CURRENT)
        self.target = fixture(self.lab / "profiles/minimal")
        demo.capture(self.lab, "desktop")
        self.state = self.lab / "identity/owner.json"

    def mutate_state(self, **changes):
        state = json.loads(self.state.read_text())
        state.update(changes)
        self.state.write_text(json.dumps(state))

    def refuse_unchanged(self):
        before = {p.name: p.read_bytes() for p in self.target.iterdir()}
        with self.assertRaises((demo.Refused, OSError)):
            demo.apply(self.lab, "minimal", write=True)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.target.iterdir()})

    def test_state_is_private(self):
        self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.state.parent.stat().st_mode), 0o700)

    def test_default_is_read_only_and_detects_drift(self):
        before = (self.target / "shadow").read_bytes()
        self.assertEqual(demo.apply(self.lab, "minimal"), "drift")
        self.assertEqual((self.target / "shadow").read_bytes(), before)

    def test_updates_only_owner_shadow_row(self):
        unchanged = {p.name: p.read_bytes() for p in self.target.iterdir() if p.name != "shadow"}
        self.assertEqual(demo.apply(self.lab, "minimal", write=True), "updated")
        result = (self.target / "shadow").read_text()
        self.assertIn(CURRENT, result)
        self.assertNotIn(STOCK, result)
        self.assertIn(SERVICE, result)
        self.assertIn("root:*:20000:0:99999:7:::\n", result)
        self.assertEqual(unchanged, {p.name: p.read_bytes() for p in self.target.iterdir() if p.name != "shadow"})

    def test_repeated_apply_does_not_replace_file(self):
        demo.apply(self.lab, "minimal", write=True)
        before = (self.target / "shadow").stat()
        self.assertEqual(demo.apply(self.lab, "minimal", write=True), "current")
        after = (self.target / "shadow").stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_preserves_shadow_owner_group_mode_and_xattrs(self):
        path = self.target / "shadow"
        os.chown(path, 0, 42)
        os.setxattr(path, "user.issue140", b"preserve-me")
        demo.apply(self.lab, "minimal", write=True)
        s = path.stat()
        self.assertEqual((s.st_uid, s.st_gid, stat.S_IMODE(s.st_mode)), (0, 42, 0o640))
        self.assertEqual(os.getxattr(path, "user.issue140"), b"preserve-me")

    def test_syncs_password_aging_and_expiry(self):
        fields = [CURRENT, "20050", "1", "90", "14", "7", "22000", ""]
        self.mutate_state(shadow_fields=fields)
        demo.apply(self.lab, "minimal", write=True)
        self.assertIn("user:" + ":".join(fields) + "\n", (self.target / "shadow").read_text())

    def test_locked_owner_remains_locked(self):
        self.mutate_state(shadow_fields=["!" + CURRENT, "20001", "0", "99999", "7", "", "", ""])
        demo.apply(self.lab, "minimal", write=True)
        self.assertIn("user:!" + CURRENT, (self.target / "shadow").read_text())

    def test_reapplies_after_password_rollback_even_with_stale_marker(self):
        original = (self.target / "shadow").read_bytes()
        demo.apply(self.lab, "minimal", write=True)
        (self.target / "identity-version").write_text("already-onboarded")
        (self.target / "shadow").write_bytes(original)
        self.assertEqual(demo.apply(self.lab, "minimal"), "drift")
        self.assertEqual(demo.apply(self.lab, "minimal", write=True), "updated")

    def test_refuses_uid_mismatch(self):
        self.mutate_state(uid=1001)
        self.refuse_unchanged()

    def test_refuses_gid_mismatch(self):
        self.mutate_state(gid=1001)
        self.refuse_unchanged()

    def test_refuses_missing_owner(self):
        path = self.target / "passwd"
        path.write_text(path.read_text().replace("user:x:", "other:x:"))
        self.refuse_unchanged()

    def test_refuses_duplicate_account_name(self):
        path = self.target / "shadow"
        path.write_text(path.read_text() + f"user:{STOCK}:20001:0:99999:7:::\n")
        self.refuse_unchanged()

    def test_refuses_uid_collision(self):
        path = self.target / "passwd"
        path.write_text(path.read_text() + "other:x:1000:1000:Other:/home/other:/bin/sh\n")
        self.refuse_unchanged()

    def test_refuses_malformed_shadow(self):
        (self.target / "shadow").write_text("user:missing-fields\n")
        self.refuse_unchanged()

    def test_refuses_empty_password(self):
        self.mutate_state(shadow_fields=["", "20001", "0", "99999", "7", "", "", ""])
        self.refuse_unchanged()

    def test_refuses_injected_record(self):
        self.mutate_state(shadow_fields=[CURRENT + "\nroot::", "20001", "0", "99999", "7", "", "", ""])
        self.refuse_unchanged()

    def test_refuses_unknown_state_version(self):
        self.mutate_state(version=2)
        self.refuse_unchanged()

    def test_refuses_boolean_version(self):
        self.mutate_state(version=True)
        self.refuse_unchanged()

    def test_refuses_world_readable_state(self):
        self.state.chmod(0o644)
        self.refuse_unchanged()

    def test_refuses_symlink_state(self):
        alternate = self.lab / "alternate"
        self.state.rename(alternate)
        self.state.symlink_to(alternate)
        self.refuse_unchanged()

    def test_refuses_symlink_profile(self):
        (self.lab / "profiles/alias").symlink_to(self.target.parent, target_is_directory=True)
        with self.assertRaises(demo.Refused):
            demo.apply(self.lab, "alias", write=True)

    def test_refuses_hardlinked_shadow(self):
        os.link(self.target / "shadow", self.lab / "shadow-alias")
        self.refuse_unchanged()

    def test_refuses_path_traversal(self):
        with self.assertRaises(demo.Refused):
            demo.apply(self.lab, "../desktop", write=True)

    def test_refuses_missing_lab_marker(self):
        (self.lab / ".issue140-lab").unlink()
        self.refuse_unchanged()

    def test_failed_replace_preserves_original_and_removes_temp(self):
        with patch.object(demo.os, "replace", side_effect=OSError("injected failure")):
            self.refuse_unchanged()
        self.assertFalse(list(self.target.glob(".issue140-*")))

    def test_failed_fsync_before_replace_preserves_original(self):
        with patch.object(demo.os, "fsync", side_effect=OSError("injected failure")):
            self.refuse_unchanged()
        self.assertFalse(list(self.target.glob(".issue140-*")))

    def test_cli_drift_exit_code_and_no_secret_output(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            result = demo.main(["--lab", str(self.lab), "apply", "minimal"])
        self.assertEqual(result, 2)
        self.assertEqual(out.getvalue(), "drift\n")
        self.assertEqual(err.getvalue(), "")

    def test_cli_failure_does_not_echo_input_secrets(self):
        self.state.write_text('{broken: "' + CURRENT + '"')
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            result = demo.main(["--lab", str(self.lab), "apply", "minimal", "--write"])
        self.assertEqual(result, 1)
        self.assertNotIn(CURRENT, out.getvalue() + err.getvalue())


if __name__ == "__main__":
    unittest.main()
