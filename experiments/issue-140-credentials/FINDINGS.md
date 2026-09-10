# Findings for FlipperOS issue #140

Checked September 10, 2026. [Issue #140](https://github.com/flipperdevices/flipperone-linux-build-scripts/issues/140) remains open, with two comments and last update August 2. It is a design issue, not a pull request. Its timeline references [PR #141](https://github.com/flipperdevices/flipperone-linux-build-scripts/pull/141), which GitHub reports as closed and unmerged. No dedicated open implementation was found in the open-PR lists of the build and Btrfs-tools repositories at review time.

The remaining contribution is credible: independent profile roots can retain different owner passwords after onboarding, stock reset, or rollback. We reproduced this underlying filesystem behavior and prepared an opt-in experiment. The experiment does not implement the complete issue.

## Source versions reviewed

| Repository | Reviewed commit |
| --- | --- |
| `flipperone-linux-build-scripts` | `c8b8af87b2455e2d6b451927dc2cccb913616b8d` |
| `flipperos-btrfs-tools` | `3010f97222318418c1f91e72c5889017ece89bd8` |
| `flipperos-installer` | `bfc3b2b51bf5ee0a6210f69bdb69ffde1f3656ee` |

## What is already present

The image build now removes machine-id and SSH host keys. Its key-generation override retries based on missing host-key content, rather than only the first-boot flag. Therefore, the issue's old statement that every image ships identical SSH host keys no longer describes current source. Cross-profile host-key policy remains a separate question. [Build cleanup](https://github.com/flipperdevices/flipperone-linux-build-scripts/blob/c8b8af87b2455e2d6b451927dc2cccb913616b8d/debian-rk3576-ospack.yaml#L315), [key-generation override](https://github.com/flipperdevices/flipperone-linux-build-scripts/blob/c8b8af87b2455e2d6b451927dc2cccb913616b8d/overlays/configs/systemd/system/sshd-keygen.service.d/10-any-boot.conf#L1).

`migrate-profile` already merges account databases and explicitly carries SSH host keys during same-device migration. That is useful existing behavior, but migration merging does not establish an authoritative device-wide owner policy for every reset/import/boot. The prototype does not replace that merger. [Account merge](https://github.com/flipperdevices/flipperos-btrfs-tools/blob/3010f97222318418c1f91e72c5889017ece89bd8/scripts/migrate-profile#L365), [host-key carry](https://github.com/flipperdevices/flipperos-btrfs-tools/blob/3010f97222318418c1f91e72c5889017ece89bd8/scripts/migrate-profile#L531).

The installer creates shared Btrfs layout and receives profile images. A source search found no owner-password onboarding implementation in the reviewed installer revision. Its shared subvolume layout currently has no identity-state mount. This is a scoped source finding, not a claim that no unpublished onboarding work exists. [Installer layout](https://github.com/flipperdevices/flipperos-installer/blob/bfc3b2b51bf5ee0a6210f69bdb69ffde1f3656ee/config/flipperos-btrfs.toml).

## Why drift remains possible

The build creates `user` with password `user`. Profile roots keep their own account files while `/home` is mounted from shared `@home`. `create-profile` snapshots the chosen source and resets machine-id; the reviewed path does not reconcile owner credentials against shared state. A copy of an old or stock root consequently contains that source's credentials. This is an inference from the code, reproduced with the same underlying Btrfs operations in the lab. [Default account](https://github.com/flipperdevices/flipperone-linux-build-scripts/blob/c8b8af87b2455e2d6b451927dc2cccb913616b8d/debian-rk3576-ospack.yaml#L150), [shared home](https://github.com/flipperdevices/flipperone-linux-build-scripts/blob/c8b8af87b2455e2d6b451927dc2cccb913616b8d/debian-rk3576-img.yaml#L103), [snapshot and machine-id handling](https://github.com/flipperdevices/flipperos-btrfs-tools/blob/3010f97222318418c1f91e72c5889017ece89bd8/scripts/create-profile#L160).

Password synchronization alone cannot enforce an onboarding gate in the current image. KDE is configured for autologin, serial gettys use `agetty -a user`, and `user` has passwordless sudo. Those may be intentional development defaults; their post-onboarding behavior needs an explicit decision. [KDE](https://github.com/flipperdevices/flipperone-linux-build-scripts/blob/c8b8af87b2455e2d6b451927dc2cccb913616b8d/overlays/profile-kde/etc/sddm.conf.d/autologin.conf), [serial ttyS0](https://github.com/flipperdevices/flipperone-linux-build-scripts/blob/c8b8af87b2455e2d6b451927dc2cccb913616b8d/overlays/configs/systemd/system/serial-getty%40ttyS0.service.d/override.conf), [serial ttyFIQ0](https://github.com/flipperdevices/flipperone-linux-build-scripts/blob/c8b8af87b2455e2d6b451927dc2cccb913616b8d/overlays/configs/systemd/system/serial-getty%40ttyFIQ0.service.d/override.conf), [sudo policy](https://github.com/flipperdevices/flipperone-linux-build-scripts/blob/c8b8af87b2455e2d6b451927dc2cccb913616b8d/overlays/configs/sudoers.d/user).

## Demonstrated behavior

| Scenario | Before reconciliation | After reconciliation |
| --- | --- | --- |
| Onboarding changes only Desktop | Minimal's stored hash still accepts the factory password | Minimal accepts current owner password |
| Clone of configured Desktop | Inherits current owner credentials | Already current; no rewrite |
| Writable reset from read-only stock | Restores factory credentials | Current owner credentials; stock untouched |
| Rollback to an older configured snapshot | Restores previous password, including a stale onboarding marker | Latest state wins despite marker |
| Real Btrfs send/receive import | Foreign test password inherited by writable copy | Local owner password replaces it |
| Different numeric owner identity | UID mismatch | Refused before writing |

There were 28 passing unit tests and 9 passing Btrfs scenarios. Checks include service-account preservation, password aging, permissions and an xattr, idempotence, rejected malformed inputs, and injected failures before replacement. See `test-results.txt`. The upstream device-free `tests/entry-names.sh` suite also passed under Git Bash; it is a baseline check, not evidence about credentials or device boot.

## Proposed production design to discuss

1. **Establish authority.** Maintain root-only owner state outside profile snapshots, in a dedicated shared subvolume mounted before reconciliation. This is a proposed addition. Persist password changes and onboarding updates there through one controlled path. Keep machine-id per profile. Agree whether the owner name and UID are fixed or provisioned, and how secondary users and privileges work.
2. **Reconcile on every boot, before access.** Check actual owner state, not just a first-boot/completion marker. Handle stock reset, imports, and older snapshots. A systemd ordering relationship alone is insufficient: every applicable login/service path must depend on successful reconciliation, and failure must not fall through to factory credentials. Define a usable recovery/onboarding route for missing or corrupt state.
3. **Update existing profiles immediately where practical.** Reconcile writable offline profiles after a password change/onboarding, with the boot check as the catch-up path. Coordinate with live account updates and the profile-management lock. Do not try to mutate read-only stock snapshots. Profiles too old to implement the gate need an explicit boot-eligibility or external reconciliation policy.
4. **Define remaining identity scope.** Address owner groups/sudo policy, root authorized keys, SSH host identity, network credentials, and Wi-Fi country separately. A maintainer comment specifically asks that Wi-Fi country be shared and applied on boot. Do not copy whole account databases across profiles with different service accounts. Export policy must account for owner hashes and private keys already present inside configured roots; a separate shared subvolume does not remove those secrets from exported profile snapshots.
5. **Validate on the real platform.** Exercise Debian/PAM, SDDM, both serial gettys, SSH/socket activation, recovery boot, profile switching, and failure/power-loss behavior. Include old-profile and imported-image compatibility. If local autologin remains enabled by policy, explain that changing the owner password does not gate that path.

This design addresses accidental inconsistency among trusted profiles. Root in one profile can already access shared storage; this is not isolation from a malicious profile, disk encryption, or protection against physical access. The prototype intentionally stops at a single offline shadow-file replacement so these broader decisions remain reviewable.
