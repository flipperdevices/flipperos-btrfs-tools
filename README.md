# flipperos-btrfs-tools

Profile and snapshot tooling for Flipper One: btrfs subvolumes as bootable roots, the snapshots and
streams that move them between devices, and the BLS boot entries that make them selectable.

The tree mirrors the paths these files install to, so the image build overlays each directory below
onto its counterpart in the target without rearranging anything.

```
usr/local/sbin/         the tools, all POSIX sh, all with -h/--help
usr/lib/                shared libraries, sourced by the tools and by kernel-install
etc/kernel/install.d/   kernel-install plugins, run when a kernel package is installed or removed
```

## The tools

| | |
|---|---|
| `create-profile`, `delete-profile`, `rename-profile`, `list-profiles` | bootable roots |
| `create-snapshot`, `delete-snapshot`, `list-snapshots` | restore points under `@snapshots` |
| `send-snapshot`, `receive-snapshot` | zstd-compressed streams between devices |
| `migrate-profile` | carry a profile's changes onto a newer base |
| `btrfs-maintenance`, `btrfs-show-space` | scrub, dedup, balance, usage |
| `add-dtbo` | per-profile device-tree overlay drop-ins |

Every tool takes `-d/--device DEV` to operate on a filesystem other than the booted one, which is how
they are used from a recovery boot.

## Relationship to flipperone-linux-build-scripts

The image build clones this repository and overlays it during the ospack stage. Two couplings run in
the other direction and are worth knowing before changing either side.

**The image depends on this package for boot entries.** `etc/kernel/install.d/90-loaderentry.install`
is what writes a BLS entry when a kernel is installed. Without this package a kernel upgrade produces
no entry, and the image build itself sources `usr/lib/flipper-bls.sh` to fan out per-profile entries.

**`flipper-profiles` stays in the image.** `flipper-bls.sh` reads `/etc/kernel/flipper-profiles` for
the menu bands and session of each profile. That file describes a particular image's profiles, so it
ships from flipperone-linux-build-scripts, not from here.

`booted_subvol` and `booted_fsuuid` live in `usr/lib/flipper-rootinfo.sh`, which both libs source.
Both need them and neither can source the other, so the pair has its own file; it must stay free of
any dependency on either lib.

## Runtime dependencies

`btrfs-progs` throughout; `zstd` for the snapshot streams; `rsync`, `git` and `mergiraf` for
`migrate-profile`'s three-way merges; `duperemove` 0.13 or newer for `btrfs-maintenance dedup`, which
deduplicates read-only subvolumes and needs a version that opens a dedup target read-only.
