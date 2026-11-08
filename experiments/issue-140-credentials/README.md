# FlipperOS issue #140: credential propagation experiment

This package reproduces owner-password drift across independent profile roots and demonstrates a narrow reconciliation rule. It is a reviewable prototype for [issue #140](https://github.com/flipperdevices/flipperone-linux-build-scripts/issues/140), not a complete fix or an installed FlipperOS service.

The experiment passed **28 unit tests and 9 real Btrfs scenarios** on September 10, 2026. A stock reset and an old snapshot restore old credentials; applying current shared owner state repairs the writable profile. A read-only stock source remains unchanged. See [the findings](FINDINGS.md) and [recorded test results](test-results.txt).

## Contents

| File | Purpose |
| --- | --- |
| `credential_demo.py` | Explicit capture and reconciliation for offline lab profiles |
| `test_credential_demo.py` | Validation, preservation, failure, permission, and output tests |
| `btrfs_scenarios.py` | Real snapshot, stock-reset, rollback, and send/receive scenarios |
| `FINDINGS.md` | Current upstream evidence and remaining integration decisions |
| `test-results.txt` | Test output, with terminal control characters and prompts removed |

## What the prototype does

The lab has a `profiles/` directory, a separate `identity/` directory, and a `.issue140-lab` marker. In the Btrfs experiment, `identity/` is a sibling subvolume outside the profile snapshots. All credentials in the provided tests are artificial.

`capture` explicitly reads an already configured profile's existing owner account into root-only JSON state. That state contains the account name, UID/GID, password hash, and shadow aging/expiry fields. It does not decide whether onboarding was completed, assess password strength, or detect that someone captured a factory password.

`apply` checks one offline profile against that state. It reports `drift` without writing unless `--write` is supplied. A write replaces only the owner's shadow row. It preserves the other shadow records and the target file's ownership, mode, and Linux extended attributes. Passwd, groups, gshadow, machine-id, home contents, and SSH files are not written.

The supported owner already exists, has UID and primary GID at least 1000, uses shadow passwords, and has matching numeric identity in source and destination. Missing accounts, UID collisions, mismatches, unsupported input, and unsafe file permissions are refused. Empty passwords are refused; locked accounts are supported. Account creation and supplementary-group policy are outside this experiment.

The current shadow fields are compared on every invocation. There is no per-profile completion marker that could incorrectly survive alongside a rolled-back password. A later password change requires an explicit new capture in this demo.

## Run in a disposable Linux environment

Requirements: Linux, root inside the disposable environment, Python 3, and a filesystem supporting extended attributes. The Btrfs scenarios also require `btrfs-progs`, OpenSSL, and an **already mounted disposable Btrfs filesystem**. The scripts do not install services or modify the running environment's `/etc`.

From the extracted package directory, inside that environment:

```sh
python3 -m unittest -v
python3 btrfs_scenarios.py --parent /lab
```

Replace `/lab` with the disposable Btrfs mount. The scenario runner creates a fresh `issue140-*` directory, prints its location, and retains it for inspection. It does not format disks, mount filesystems, or delete existing profiles. It requires no downloaded Flipper image.

To inspect a retained fixture, use the absolute lab path printed by the runner:

```sh
# Substitute the printed path for /lab/issue140-EXAMPLE.
python3 credential_demo.py --lab /lab/issue140-EXAMPLE apply minimal
python3 credential_demo.py --lab /lab/issue140-EXAMPLE apply minimal --write
python3 credential_demo.py --lab /lab/issue140-EXAMPLE capture desktop
```

Exit codes: `0` for captured/current/updated; `2` for drift detected without writing; `1` for refusal or an operational error. Output never includes password hashes. The lab marker is an accidental-use guard, not a security boundary.

## Limits of the evidence

Tests ran under QEMU 11.1.0 with software emulation, Alpine 3.23.5 x86_64, Linux 6.18.36, Python 3.12.14, and btrfs-progs 6.17.1. Unit tests used a disposable temporary filesystem; the snapshot scenarios used a separate 1 GiB virtual Btrfs disk. The Btrfs runner uses synthetic account files and real snapshot/send/receive commands. Password checks compare actual SHA-512 crypt hashes using OpenSSL; they do not exercise PAM or an interactive login.

We did not boot a FlipperOS image, invoke its complete `create-profile`/`migrate-profile` wrappers, test an ARM device, or exercise SDDM, SSH, serial login, systemd failure ordering, ACL/SELinux policy, or real power loss. Mocked failures cover errors before replacement; they do not establish power-loss safety. A directory-fsync failure after replacement can leave the new file installed despite an error; rerunning reconciles against actual contents.

Profiles must be offline and trusted, with no concurrent account writers. The demo lock coordinates only its own invocations. Production use would need coordination with passwd/usermod, boot and recovery tools, mount lifetimes, and the profile-management lock. Its pathname checks are not a defense against a hostile concurrent root process.

The next contribution should establish maintainer agreement on owner-account scope, authority of shared state, recovery behavior, and the login gate described in [FINDINGS.md](FINDINGS.md). This prototype does not install services or alter the running environment's account databases.
