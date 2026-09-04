# flipperos-btrfs-tools

Profile and snapshot tooling for Flipper One: btrfs subvolumes as bootable roots, the snapshots and
streams that move them between devices, and the BLS boot entries that make them selectable.

`scripts/` holds the tools, all POSIX sh, all with `-h/--help`. `libs/` holds the libraries they, the
hooks and the image build source, plus one awk helper that is read rather than sourced.
`hooks/` holds the kernel-install plugins that run when a kernel package is installed or removed.
`systemd/` holds the one unit that has to run inside a booted profile. `tests/` holds shell tests
that need no device.

## Where the files go on the device

This is a source layout, not the install layout. Every file refers to the others by absolute path
(the tools source `/usr/lib/flipper-btrfs.sh`), so whatever deploys them has to put each one here:

| repo | device | mode |
|---|---|---|
| `scripts/*` | `/usr/local/sbin/` | 0755 |
| `libs/*` | `/usr/lib/` | 0644 |
| `hooks/*` | `/etc/kernel/install.d/` | 0755 |
| `systemd/*` | `/usr/lib/systemd/system/` | 0644 |

`kernel-install` runs the hooks from `/etc/kernel/install.d` by name, so their `NN-` prefixes set the
order and have to survive the copy.

Two units have to be enabled for boot counting to close its loop:
`flipper-bless-boot.service`, which ships here, and Debian's own
`systemd-boot-check-no-failures.service`, which ships disabled. Without the first, an entry keeps
spending tries on boots that worked; without the second, "the boot worked" means only that the
system reached multi-user, not that nothing failed on the way.

## The tools

| | |
|---|---|
| `create-profile`, `delete-profile`, `rename-profile`, `list-profiles` | bootable roots |
| `create-snapshot`, `delete-snapshot`, `list-snapshots` | restore points under `@snapshots` |
| `send-snapshot`, `receive-snapshot` | zstd-compressed streams between devices |
| `migrate-profile` | carry a profile's changes onto a newer base |
| `btrfs-maintenance`, `btrfs-show-space` | scrub, dedup, balance, usage |
| `add-dtbo` | per-profile device-tree overlay drop-ins |
| `set-boot-order` | which profile boots by itself, and which kernel it boots |
| `boot-profile` | boot an entry now, by kexec or by pivot |
| `flipper-bless-boot` | run once per good boot, from the unit of the same name |
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

## The boot order is the state

There is no marker anywhere saying what boots. Entries are sorted, and **the first entry boots**:

    sort-key   debian-0100-Desktop-0
               │      │└┬┘ └──┬──┘ └── rank:     0 = the profile's chosen kernel, 1 = its others
               │      │ │     └─────── profile
               │      │ └───────────── band, ascending: 1000 - the filename band
               │      └─────────────── autoboot: 0 for the profile that boots by itself
               └────────────────────── the os-release id, which the BLS spec asks for and allows
                                        to carry "an additional suffix"

`set-boot-order --autoboot @Profile` moves the single 0 in the autoboot column; `--kernel <id>`
moves the single 0 in one profile's rank column; `--list` prints the order, first line first;
`--init` stamps a filesystem whose entries predate the scheme.

Installing a kernel makes it the one its profile boots: the hook writes the new entry at rank 0,
steps the profile's other entries down to rank 1, and gives it a full boot counter. If it cannot
boot three times running, it becomes 'bad', sorts last, and the kernel that was booting before
leads again with nothing to undo. Which profile boots by itself is untouched by an install.

Which entry a running system came from is the kernel it runs plus the subvolume it is on: a root
holds at most one entry per kernel, because installing one removes whatever that root already had
for that version, whatever token it was written under. `flipper-bless-boot` works it out from
those two, and reads `/run/flipper-boot-entry` first where a soft-reboot left it. Nothing of ours
goes on the kernel command line.

Attempts are counted the way the spec describes, in the entry's file name:
`…-7.2.0-ga0d2d145deeb+2-1.conf` has two tries left and one spent. `boot-profile` counts one at the
point of no return, `flipper-bless-boot` removes the counter after a boot that reached
`boot-complete.target`, and an entry at zero sorts after everything else -- so a kernel that will
not boot hands the device back to the one that did, with nothing recording that it happened.

`libs/flipper-blsname.sh` is that vocabulary, and nothing else: entry ids, counters, sort-keys,
the sort itself, and the kernel floor (`BLS_MIN_KERNEL`, 7.0) that keeps a tool from choosing a
kernel the boot menu hides. It is deliberately free of `die()` and `log()` so `boot-profile` and
`set-boot-order` can source it without inheriting a library's error style, and it is the only
place any of those formats are written down. `tests/entry-names.sh` checks it against names shaped
like the real ones and needs no device.

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
