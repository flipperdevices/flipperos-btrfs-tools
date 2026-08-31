# flipperos-btrfs-tools

Profile and snapshot tooling for Flipper One: btrfs subvolumes as bootable roots, the snapshots and
streams that move them between devices, and the BLS boot entries that make them selectable.

`scripts/` holds the tools, all POSIX sh, all with `-h/--help`. `libs/` holds the libraries they, the
hooks and the image build source, plus one awk helper that is read rather than sourced.
`hooks/` holds the kernel-install plugins that run when a kernel package is installed or removed.

## Where the files go on the device

This is a source layout, not the install layout. Every file refers to the others by absolute path
(the tools source `/usr/lib/flipper-btrfs.sh`), so whatever deploys them has to put each one here:

| repo | device | mode |
|---|---|---|
| `scripts/*` | `/usr/local/sbin/` | 0755 |
| `libs/*` | `/usr/lib/` | 0644 |
| `hooks/*` | `/etc/kernel/install.d/` | 0755 |

`kernel-install` runs the hooks from `/etc/kernel/install.d` by name, so their `NN-` prefixes set the
order and have to survive the copy.

## The tools

| | |
|---|---|
| `create-profile`, `delete-profile`, `rename-profile`, `list-profiles` | bootable roots |
| `create-snapshot`, `delete-snapshot`, `list-snapshots` | restore points under `@snapshots` |
| `send-snapshot`, `receive-snapshot` | zstd-compressed streams between devices |
| `migrate-profile` | carry a profile's changes onto a newer base |
| `btrfs-maintenance`, `btrfs-show-space` | scrub, dedup, balance, usage |
| `add-dtbo` | per-profile device-tree overlay drop-ins |
| `apt-backup-profile` | the backup apt offers before it changes packages |

Every tool takes `-d/--device DEV` to operate on a filesystem other than the booted one, which is how
they are used from a recovery boot. `apt-backup-profile` is the exception: it backs up the profile
the running apt is about to change, which is always the booted one.

## Relationship to flipperone-linux-build-scripts

The image build clones this repository and overlays it during the ospack stage. Two couplings run in
the other direction and are worth knowing before changing either side.

**The image depends on this package for boot entries.** `hooks/90-loaderentry.install` is what
writes a BLS entry when a kernel is installed. Without this package a kernel upgrade produces no
entry, and the image build itself sources `libs/flipper-bls.sh` to fan out per-profile entries.

**The apt hook ships from the image.** `apt-backup-profile` is what
`/etc/apt/apt.conf.d/80-flipper-apt-backup` calls, and that drop-in belongs to
flipperone-linux-build-scripts. Either half alone is inert: the drop-in tests that the script is
executable before calling it, and the script asks nothing unless apt is about to change packages.

**`flipper-profiles` stays in the image.** `flipper-bls.sh` reads `/etc/kernel/flipper-profiles` for
the menu bands and session of each profile. That file describes a particular image's profiles, so it
ships from flipperone-linux-build-scripts, not from here.

`booted_subvol` and `booted_fsuuid` live in `libs/flipper-rootinfo.sh`, which both libs source.
Both need them and neither can source the other, so the pair has its own file; it must stay free of
any dependency on either lib. Anything that deploys the libraries one by one rather than as a
directory has to include it: both libs exit if it is missing.

`libs/flipper-accountdb.awk` is `migrate-profile`'s per-entry merge of `passwd`, `shadow`, `group`
and `gshadow`, run with `awk -f` rather than sourced. Without it, or whenever its result does not
look like an account database, `migrate-profile` keeps the target's copy and leaves the user's as a
`.migrate-theirs` sidecar.

## Runtime dependencies

`btrfs-progs` throughout; `zstd` for the snapshot streams; `rsync`, `git` and `mergiraf` for
`migrate-profile`'s three-way merges; `duperemove` 0.13 or newer for `btrfs-maintenance dedup`, which
deduplicates read-only subvolumes and needs a version that opens a dedup target read-only.
