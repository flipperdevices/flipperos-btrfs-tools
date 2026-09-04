#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# flipper-bls.sh - shared library for Flipper One BLS boot-entry generation.
#
# SOURCED, never executed. Defines the helpers used by the kernel-install plugin
# (90-loaderentry.install) and the btrfs snapshot tooling (create-profile/rename-profile).
# Functions read globals lazily (at call time), so callers set what they need first.
# The kernel/initrd staging and devicetree(dir) handling are derived from systemd's
# 90-loaderentry.install (LGPL-2.1-or-later).

[ -r /usr/lib/flipper-rootinfo.sh ] || { echo "flipper-bls: /usr/lib/flipper-rootinfo.sh not found" >&2; exit 1; }
. /usr/lib/flipper-rootinfo.sh
# Entry names, boot counters and sort-keys: shared with boot-profile and set-boot-order, which read
# and write the same two names without wanting the rest of this library.
[ -r /usr/lib/flipper-blsname.sh ] || { echo "flipper-bls: /usr/lib/flipper-blsname.sh not found" >&2; exit 1; }
. /usr/lib/flipper-blsname.sh

VENDOR=rockchip
TITLE_MAX="${FLIPPER_TITLE_MAX:-26}"

log() { [ "${KERNEL_INSTALL_VERBOSE:-0}" -gt 0 ] && echo "flipper-bls: $*" >&2; return 0; }
die() { echo "flipper-bls: $*" >&2; exit 1; }
trim() { printf '%s' "$1" | sed 's/^ *//; s/ *$//'; }
# copy a file into the entry dir as root:root 0644
stage_file() { install -m 0644 -o root -g root "$1" "$2" || die "could not copy '$1'"; }

# absolute path under BOOT_ROOT -> path as it must appear inside a BLS entry (relative to the
# boot partition; identical to the absolute path while /boot is on the rootfs). On Flipper One
# BOOT_MNT=/ (/boot is a subvol on the root partition, never a separate boot partition).
boot_rel() { if [ "${BOOT_MNT:-/}" = "/" ]; then printf '%s\n' "$1"; else printf '%s\n' "${1#"${BOOT_MNT}"}"; fi; }

has_config() { [ -f "$KCONFIG" ] && grep -q "^CONFIG_$1=[ym]" "$KCONFIG"; }

# Last rootflags=subvol= value in a cmdline/options string (empty if none).
subvol_of() { printf '%s' "$1" | tr ' ' '\n' | sed -n 's/^rootflags=subvol=//p' | tail -n1; }

# ── Where a new entry lands in the order ───────────────────────────────────────────────────────
#
# See flipper-blsname.sh for what the sort-key and the boot counter mean. What is here is the half
# that has to read the filesystem: which digit a profile's existing entries carry, and whether it
# has a chosen kernel already.

# The autoboot digit a profile's entries already carry, or 1 for a profile with none yet.
#
# A kernel install joins the order rather than changing it: whatever boots by itself keeps booting
# by itself. The invariant that exactly one profile holds the 0 is set-boot-order's business, not
# this one's -- here a profile with no entries is simply not the one that boots.
profile_auto_digit() {  # $1 = subvol
    for _c in "${ENTRIES:-/boot/loader/entries}"/*.conf; do
        [ -f "$_c" ] || continue
        [ "$(entry_subvol_of "$_c")" = "$1" ] || continue
        _a="$(sort_key_field "$_c" auto)"
        case "$_a" in 0|1) printf '%s' "$_a"; return 0 ;; esac
    done
    printf '1'
}

# Step every other entry of $1 down to rank 1, leaving $2 the profile's chosen kernel.
#
# A kernel you have just installed is the kernel you meant to boot, so a new entry leads its
# profile. What makes that safe rather than reckless is the boot counter it is written with: three
# attempts, and if it cannot reach boot-complete.target in three it becomes 'bad', sorts last, and
# the kernel that was booting before -- still blessed, still rank 1 -- leads again on its own.
demote_others() {  # $1 = subvol, $2 = the id that keeps rank 0
    for _c in "${ENTRIES:-/boot/loader/entries}"/*.conf; do
        [ -f "$_c" ] || continue
        [ "$(entry_subvol_of "$_c")" = "$1" ] || continue
        [ "$(entry_id_of "$_c")" = "$2" ] && continue
        [ "$(sort_key_field "$_c" rank)" = 1 ] && continue
        restamp_entry "$_c" '-' 1 '-' "${OVERLAY_USER_ROOT:-}"
        log "stepped $(entry_id_of "$_c") down: $2 is newer"
    done
    return 0
}

# The sort-key for an entry of $1 (subvol) in band $2 (a filename band NN, may be empty).
#
# The autoboot digit is whatever this profile's entries already carry: installing a kernel changes
# which kernel a profile boots, never which profile the machine boots by itself.
#
# An unmappable root gets band 999, which sorts last: a profile the band scheme cannot place must
# not become the thing that boots by itself just because its key came out short.
entry_sort_key() {  # $1 = subvol, $2 = filename band NN
    _b="$(sort_band "${2:-}")"; [ -n "$_b" ] || _b=999
    # Rank 0: the entry being written is the one its profile is to boot. demote_others puts the
    # profile's older entries behind it once this one exists.
    make_sort_key "$(profile_auto_digit "$1")" "$_b" "$1" "0"
}

# Set DTB_DIR + DTB_DIRS (primary dir + modules fallback) for the current $KERNEL_VERSION.
set_dtb_dirs() { DTB_DIR="/usr/lib/linux-image-$KERNEL_VERSION"; DTB_DIRS="$DTB_DIR /usr/lib/modules/$KERNEL_VERSION/dtb"; }

# Kernel entry-token for a root: <NN>-flipperos-<subvol sans @>, carrying the menu band + root id.
# Empty NN -> plain flipperos-<name> (sorts above the numbered bands, like an unmappable root).
make_token() {  # $1 = NN (may be empty)  $2 = subvol
    _n="$(printf '%s' "$2" | tr -d '@')"
    [ -n "$1" ] && printf '%s-flipperos-%s' "$1" "$_n" || printf 'flipperos-%s' "$_n"
}

# Set KERNEL_ENTRY + INITRD_ENTRIES for $KERNEL_VERSION, preferring the profile's own copies in
# /usr/lib/modules/<ver>/ (referenced as /@<subvol>/..., which U-Boot resolves from subvolid 5),
# else the shared /boot copies (BSP/pre-deb-pkg kernels). $1 = subvol; $2 = its mounted root (def /).
resolve_kernel_paths() {
    _rk_root="${2:-/}"; [ "$_rk_root" = / ] && _rk_root=""
    _rk_um="/usr/lib/modules/$KERNEL_VERSION"
    _rk_pfx="$(fdt_prefix "rootflags=subvol=$1")"
    if   [ -f "$_rk_root$_rk_um/vmlinuz" ];        then KERNEL_ENTRY="$_rk_pfx$_rk_um/vmlinuz"
    elif [ -f "/boot/vmlinuz-$KERNEL_VERSION" ];   then KERNEL_ENTRY="$(boot_rel "/boot/vmlinuz-$KERNEL_VERSION")"
    else echo "flipper-bls: no kernel image for $KERNEL_VERSION (looked in $_rk_um and /boot)" >&2; return 1; fi
    if   [ -f "$_rk_root$_rk_um/initrd" ];         then INITRD_ENTRIES="$_rk_pfx$_rk_um/initrd"
    elif [ -f "/boot/initrd.img-$KERNEL_VERSION" ];then INITRD_ENTRIES="$(boot_rel "/boot/initrd.img-$KERNEL_VERSION")"
    else INITRD_ENTRIES=""; fi
}

# KCONFIG for the has_config gates: profile's config first, /boot fallback. $1 = mounted root (def /).
resolve_kconfig() {
    _kc_root="${1:-/}"; [ "$_kc_root" = / ] && _kc_root=""
    if [ -f "$_kc_root/usr/lib/modules/$KERNEL_VERSION/config" ]; then KCONFIG="$_kc_root/usr/lib/modules/$KERNEL_VERSION/config"
    else KCONFIG="/boot/config-$KERNEL_VERSION"; fi
}

# U-Boot reads the btrfs TOP LEVEL (subvolid 5), so in-entry devicetreedir/overlay paths need the
# entry's own root subvol prefixed (/@<subvol>/usr/lib/...), taken from its rootflags=subvol=.
# Set FDT_SUBVOL_PREFIX to override (e.g. "" if the root isn't a subvol).
fdt_prefix() {  # $1 = options string -> "/<rootflags-subvol>" (or $FDT_SUBVOL_PREFIX if set)
    if [ "${FDT_SUBVOL_PREFIX+x}" = x ]; then printf '%s' "$FDT_SUBVOL_PREFIX"; return 0; fi
    _sv=$(subvol_of "$1")
    [ -n "$_sv" ] && printf '/%s' "$_sv"
    return 0
}

# Remove loader entries whose options select SUBVOL and whose version == VERSION. Content-based
# (token/filename-agnostic), so it leaves every other root's entries untouched. Uses $ENTRIES.
remove_entries() {  # $1 = subvol  $2 = version
    [ -n "$1" ] && [ -n "$2" ] || return 0
    for _c in "${ENTRIES:-/boot/loader/entries}"/*.conf; do
        [ -f "$_c" ] || continue
        [ "$(awk '$1=="version"{print $2; exit}' "$_c")" = "$2" ] || continue
        [ "$(entry_subvol_of "$_c")" = "$1" ] || continue
        rm -f "$_c"
    done
    return 0   # a non-matching last entry must not fail the loop under set -e
}

# Tear down a whole root: remove EVERY entry that selects SUBVOL (all versions) and each one's
# /boot/<token>/ staging tree. The staging dir is derived from the entry's own 'linux' line, so it
# works no matter how the token was computed. For delete-profile/rename-profile (whole-profile ops).
# Uses $ENTRIES. Prints what it removes to stderr.
remove_root_entries() {  # $1 = subvol
    [ -n "$1" ] || return 0
    for _c in "${ENTRIES:-/boot/loader/entries}"/*.conf; do
        [ -f "$_c" ] || continue
        [ "$(entry_subvol_of "$_c")" = "$1" ] || continue
        _lx="$(awk '$1=="linux"{print $2; exit}' "$_c")"
        rm -f "$_c"; echo "removed boot entry $_c" >&2
        case "$_lx" in /boot/*/*/linux)
            _td="${_lx%/*/linux}"; [ "$_td" != /boot ] && rm -rf "$_td" ;;
        esac
    done
    return 0
}

# Base menu slot (900,800,700,... by flipper-profiles position) for the profile $1 belongs to.
# Which profile list to read bands from: the target's own copy when it has one, else the running
# root's. flipper_write_entry can be pointed at a filesystem we did not boot from, whose bands are
# defined by its own list.
target_profiles() {
    if [ -f "${1:-}/etc/kernel/flipper-profiles" ]; then printf '%s' "$1/etc/kernel/flipper-profiles"
    else printf '%s' "${PROFILES:-/etc/kernel/flipper-profiles}"; fi
}

# $1 is a btrfs-PARENT name. It anchors on an ACTUAL profile: the exact name (@Desktop) or its
# golden base / snapshot (@Desktop_stock, @Desktop_<stamp>: profile name followed by '_'). A
# hyphen-suffixed clone (@Desktop-2) must NOT match here, so origin_base_depth can walk THROUGH
# it to count clone depth. Empty if none. Steps of 100 leave room for ~99 variants per band.
profile_base_nn() {
    _want="$1"; _pf="${PROFILES:-/etc/kernel/flipper-profiles}"; [ -f "$_pf" ] || return 0
    _j=0
    while IFS='|' read -r _t _s _e _g _d _l; do
        _t="$(echo "$_t" | tr -d '[:space:]')"; case "$_t" in ''|\#*) continue ;; esac
        _sv="$(subvol_of "$_e" | tr -d '[:space:]')"
        [ -n "$_sv" ] && case "$_want" in "$_sv"|"$_sv"_*) printf '%03d' "$((900 - _j * 100))"; return 0 ;; esac
        _j=$((_j + 1))
    done <"$_pf"
    return 0
}

# Origin-profile base slot AND clone depth for a derived root. Clone/snapshot names are arbitrary
# and can chain (a snapshot of a snapshot), so instead of matching the name we WALK the btrfs
# parent_uuid chain up from the subvol at $1, counting hops, until an ancestor is a listed profile
# or its golden base (profile_base_nn). Prints "BASE DEPTH" (e.g. "900 2" = desktop, grandparent);
# depth is the hop count (1 = direct clone, 2 = clone of a clone, ...). Empty if none maps or no
# btrfs. One `subvolume list` covers the whole fs (ancestors need not be mounted).
origin_base_depth() {  # $1 = mounted path (default /)
    command -v btrfs >/dev/null 2>&1 || return 0
    _mp="${1:-/}"
    _cur="$(btrfs subvolume show "$_mp" 2>/dev/null | sed -n 's/.*[Pp]arent UUID:[[:space:]]*//p' | head -n1)"
    [ -n "$_cur" ] && [ "$_cur" != "-" ] || return 0
    # fs-wide table: one row "uuid parent_uuid name" per subvolume
    _tbl="$(btrfs subvolume list -qu "$_mp" 2>/dev/null | awk '{ u="-"; p="-"; for(i=1;i<NF;i++){ if($i=="uuid")u=$(i+1); else if($i=="parent_uuid")p=$(i+1) } print u, p, $NF }')"
    _seen=" "; _depth=0
    while [ -n "$_cur" ] && [ "$_cur" != "-" ]; do
        case "$_seen" in *" $_cur "*) break ;; esac        # cycle guard
        _seen="$_seen$_cur "
        _row="$(printf '%s\n' "$_tbl" | awk -v u="$_cur" '$1==u{print $2, $3; exit}')"
        [ -n "$_row" ] || break
        _depth=$((_depth + 1))
        _pn="${_row#* }"; _pn="${_pn##*/}"                 # this ancestor's name (basename)
        _bn="$(profile_base_nn "$_pn")"
        [ -n "$_bn" ] && { printf '%s %s' "$_bn" "$_depth"; return 0; }
        _cur="${_row%% *}"                                 # follow parent_uuid to the grandparent
    done
    return 0
}

# Clone menu slot for a derived root: origin base + clone-depth (direct clone -> base+1,
# clone of a clone -> base+2, ...), so clones sit just above the profile (whose factory and
# in-profile-install entries share the base slot). $1 = mounted path; $2 = optional origin hint
# (the name it was restored FROM). Prefers the parent-chain walk (true depth); if that yields
# nothing (e.g. parent_uuid left dangling by a move/receive) it falls back to the hint as a direct
# clone (depth 1 -> base+1). Prints a 3-digit NN, or empty if unresolved.
clone_slot() {  # $1 = mounted path (default /); $2 = origin hint (optional)
    _cs_bd="$(origin_base_depth "${1:-/}")"
    if [ -n "$_cs_bd" ]; then
        printf '%03d' "$(( ${_cs_bd%% *} + ${_cs_bd#* } ))"; return 0
    fi
    if [ -n "${2:-}" ]; then
        _cs_b="$(profile_base_nn "${2##*/}")"
        [ -n "$_cs_b" ] && printf '%03d' "$(( _cs_b + 1 ))"
    fi
    return 0
}

# Menu titles must fit the small screen: cap total at TITLE_MAX by trimming the (long) version
# while keeping the label intact. Label leads, the (possibly trimmed) version follows.
# (Filenames + the 'version' field keep the full version.)
make_title() {
    _suf="$1"
    _avail=$(( TITLE_MAX - ${#_suf} - 1 ))
    if [ "$_avail" -ge 1 ]; then
        printf '%s %s' "$_suf" "$(printf '%s' "$KERNEL_VERSION" | cut -c"1-$_avail")"
    else
        printf '%s' "$_suf" | cut -c"1-$TITLE_MAX"
    fi
}

# write_entry FILE TITLE OPTIONS FDTOVERLAYS
#
# Nothing of ours goes on the command line. What booted is worked out from the kernel a system is
# running and the subvolume it is on, which name one entry between them now that a root holds at
# most one entry per kernel (see emit_entry). An id on the command line said the same thing less
# well: a pivot boots no kernel, so it inherits the line of whatever ran before and the id there
# belongs to the wrong entry.
write_entry() {
    _f="$1"; _title="$2"; _opts="$3"; _fdtov="$4"
    # devicetreedir is prefixed with THIS entry's root subvol (U-Boot reads subvolid 5)
    _dtdir=""; [ -n "$DEVICETREEDIR_REL" ] && _dtdir="$(fdt_prefix "$_opts")$DEVICETREEDIR_REL"
    {
        echo "# Boot Loader Specification type#1 entry (Flipper One)"
        echo "title      $_title"
        echo "version    $KERNEL_VERSION"
        [ -n "$MACHINE_ID" ] && [ "$ENTRY_TOKEN" = "$MACHINE_ID" ] && echo "machine-id $MACHINE_ID"
        [ -n "$SORT_KEY" ] && echo "sort-key   $SORT_KEY"
        [ -n "$_opts" ]  && echo "options    $_opts"
        echo "linux      $KERNEL_ENTRY"
        [ -n "$DEVICETREE_ENTRY" ] && echo "devicetree    $DEVICETREE_ENTRY"
        [ -n "$_dtdir" ]           && echo "devicetreedir $_dtdir"
        [ -n "$_fdtov" ]           && echo "devicetree-overlay $_fdtov"
        for _ird in $INITRD_ENTRIES; do echo "initrd     $_ird"; done
    } >"$_f"
    return 0   # don't let a trailing empty conditional's status abort `set -e`
}

# Echo the space-separated paths of the named DT overlays (flat, next to the DTBs).
# Returns non-zero with no output if any one is missing.
overlay_paths() {  # $1 = subvol prefix (e.g. /@Desktop); remaining args = overlay names
    _pfx="$1"; shift
    _paths=""
    for _n in "$@"; do
        [ -f "$OVERLAY_DIR/$_n.dtbo" ] || return 1   # check the real on-disk path
        _paths="$_paths${_paths:+ }$_pfx$OVERLAY_DIR/$_n.dtbo"
    done
    printf '%s' "$_paths"
}

# Per-profile user drop-in overlays: every *.dtbo under this root's /etc/kernel/dtbo, applied to
# each of the profile's entries. One layout, two views: OVERLAY_USER_ROOT picks whose drop-ins to
# scan ("" = the running root, a mountpoint for any other), while the in-entry path is always the
# same subvol-prefixed /etc/kernel/dtbo, since that is where the file sits inside the profile.
# Silent no-op when the dir is absent or empty.
OVERLAY_USER_PATH=/etc/kernel/dtbo
user_overlay_paths() {  # $1 = subvol prefix (e.g. /@Desktop)
    _udir="${OVERLAY_USER_ROOT:-}$OVERLAY_USER_PATH"
    [ -d "$_udir" ] || return 0
    _upaths=""
    for _uf in "$_udir"/*.dtbo; do
        [ -f "$_uf" ] || continue                     # unmatched glob -> skip
        _upaths="$_upaths${_upaths:+ }$1$OVERLAY_USER_PATH/${_uf##*/}"
    done
    printf '%s' "$_upaths"
}

# Set BASE_OPTS from CONF_ROOT/cmdline (root=UUID + policy) + this kernel's console layout.
# FIQ kernel -> console=ttyFIQ0 ; mainline -> console=ttyS0 + ttyS4 + fbcon=map:1.
compute_base_opts() {
    # -G is the default and \s is a GNU extension: BusyBox grep has neither, and it fails
    # loudly enough to print its whole usage while the caller carries on with an empty
    # cmdline. A character class costs nothing and works in both.
    if [ -f "$CONF_ROOT/cmdline" ]; then
        BASE_OPTS="$(grep -v '^[[:space:]]*#' "$CONF_ROOT/cmdline" | tr -s '[:space:]' ' ')"
    elif [ -f /usr/lib/kernel/cmdline ]; then
        BASE_OPTS="$(grep -v '^[[:space:]]*#' /usr/lib/kernel/cmdline | tr -s '[:space:]' ' ')"
    else
        BASE_OPTS=""
    fi
    BASE_OPTS="$(trim "$BASE_OPTS")"
    # A cmdline that exists and reads as nothing is not a configuration, it is a broken
    # read: an entry written from it gets no options line at all, so the profile has no
    # root and cannot boot, and nothing would have said why.
    if [ -z "$BASE_OPTS" ] && { [ -f "$CONF_ROOT/cmdline" ] || [ -f /usr/lib/kernel/cmdline ]; }; then
        echo "flipper-bls: the kernel cmdline file is present but read as empty" >&2
    fi
    # rewrite the shipped cmdline's build-time root=UUID to the fs we install onto, so a _stock
    # received onto a device with a different btrfs UUID still boots.
    # the filesystem the entry will boot from, which under -d is not the one we are running
    _fsuuid="${TARGET_FSUUID:-$(booted_fsuuid)}"
    [ -n "$_fsuuid" ] && BASE_OPTS="$(printf '%s' " $BASE_OPTS " | sed "s/ root=UUID=[^ ]*/ root=UUID=$_fsuuid/")"
    BASE_OPTS="$(trim "$BASE_OPTS")"
    # Pin systemd.machine_id= only when entries are named after the machine-id (no-op otherwise).
    if [ -n "$MACHINE_ID" ] && [ "$ENTRY_TOKEN" = "$MACHINE_ID" ] && ! echo "$BASE_OPTS" | grep -q "systemd.machine_id="; then
        BASE_OPTS="$BASE_OPTS systemd.machine_id=$MACHINE_ID"
    fi
    if has_config FIQ_DEBUGGER_CONSOLE; then
        BASE_OPTS="$(echo " $BASE_OPTS " | sed 's/ console=ttyS0,1500000n8 / /g')"
        BASE_OPTS="$(trim "$BASE_OPTS") console=ttyFIQ0,1500000n8"
    else
        BASE_OPTS="$(echo " $BASE_OPTS " | sed 's/ console=ttyS0,1500000n8 / /g')"
        BASE_OPTS="$(trim "$BASE_OPTS") console=ttyS0,1500000n8"
        BASE_OPTS="$(echo " $BASE_OPTS " | sed 's/ console=ttyS4,1500000n8 / /g')"
        BASE_OPTS="$(trim "$BASE_OPTS") console=ttyS4,1500000n8"
        BASE_OPTS="$(echo " $BASE_OPTS " | sed 's/ console=ttyFIQ0,1500000n8 / /g')"
        BASE_OPTS="$(trim "$BASE_OPTS") fbcon=map:1"
    fi
}

# Set DEVICETREEDIR_REL + OVERLAY_DIR for $KERNEL_VERSION (needs DTB_DIR/DTB_DIRS set). Opt-in via a
# /etc/kernel/devicetreedir boolean, only when no single 'devicetree' is configured. Always the
# kernel's own installed DTB dir (first existing of DTB_DIRS), never inspected or borrowed; if it
# ships none, no devicetreedir is written and U-Boot falls back to its control FDT.
discover_devicetreedir() {
    DEVICETREEDIR_SRC=""; DEVICETREEDIR_REL=""
    if [ -z "${DEVICETREE:-}" ] && [ -f "$CONF_ROOT/devicetreedir" ]; then
        _v=""; read -r _v <"$CONF_ROOT/devicetreedir" || :
        case "$_v" in
            1|[Yy]|[Yy][Ee][Ss]|[Tt]|[Tt][Rr][Uu][Ee]|[Oo][Nn])
                for p in $DTB_DIRS; do
                    [ -d "$p" ] && { DEVICETREEDIR_SRC="$p"; break; }
                done
                if [ -n "$DEVICETREEDIR_SRC" ]; then
                    DEVICETREEDIR_REL="$(boot_rel "$DEVICETREEDIR_SRC")"   # /usr/lib/...; prefixed per entry
                else
                    log "$KERNEL_VERSION ships no DTB dir; omitting devicetreedir (U-Boot control FDT)"
                fi
                ;;
        esac
    fi
    # DT overlays sit flat next to the .dtb files (upstream layout), in the same vendor dir.
    OVERLAY_DIR="${DEVICETREEDIR_SRC:-$DTB_DIR}/$VENDOR"
}

# devicetree-overlay value for an entry: profile overlays ($2 = dtbos names) + user drop-ins,
# subvol-prefixed from $1 (options). Empty if none. Shared by emit_entry and flipper_rewrite_overlay.
dt_overlay_line() {
    _p="$(fdt_prefix "$1")"
    _o="$(overlay_paths "$_p" $2 2>/dev/null)" || _o=""
    _u="$(user_overlay_paths "$_p")"
    printf '%s' "$_o${_o:+${_u:+ }}$_u"
}

# Base profile subvol for a derived root, from its /etc/profile_origin marker
# (origin_stock_name=@Desktop_959_stock -> @Desktop). Empty if unmarked.
origin_base_of() {  # $1 = mounted path
    _po="${1:-/}/etc/profile_origin"; [ -r "$_po" ] || return 0
    sed -n 's/^origin_stock_name=//p' "$_po" | head -n1 | sed 's/_[0-9]*_stock$//'
}

# Factory dtbos (overlay names, leading '!' stripped) for the listed profile whose rootflags
# select subvol $1. Empty if the subvol is not a listed profile.
profile_dtbos_for() {  # $1 = base subvol (e.g. @Desktop)
    _want="$1"; _pf="${PROFILES:-/etc/kernel/flipper-profiles}"; [ -f "$_pf" ] || return 0
    while IFS='|' read -r _t _s _e _g _d _l; do
        case "$_t" in ''|\#*) continue ;; esac
        if [ "$(subvol_of "$_e")" = "$_want" ]; then _d="$(trim "$_d")"; printf '%s' "${_d#\!}"; return 0; fi
    done <"$_pf"
    return 0
}

# devicetree-overlay value for a NEW derived entry ($1 options, $2 source subvol, $3 dest mounted
# path). SYSTEM overlays are copied from the source profile's own BLS entry, re-pointed to THIS
# entry's subvol, so a clone inherits exactly what its source applies (including any future custom
# ones); when the source has no entry (a stock, e.g. factory reset) they come from the base
# profile's flipper-profiles dtbos. USER drop-ins are scanned from the dest's /etc/kernel/dtbo as
# usual (they ride along in the snapshot). Empty if none.
clone_overlay_line() {
    _clp="$(fdt_prefix "$1")"; _clsrc="$2"; _clsnap="$3"
    _clsys=""
    _clentry="$(grep -lE "rootflags=subvol=$_clsrc( |\$)" "$ENTRIES"/*.conf 2>/dev/null | sort | tail -n1)"
    if [ -n "$_clsrc" ] && [ -n "$_clentry" ]; then
        for _clo in $(sed -n 's/^devicetree-overlay[[:space:]]\{1,\}//p' "$_clentry" | head -n1); do
            case "$_clo" in *"$OVERLAY_USER_PATH/"*) continue ;; esac   # user drop-in: rescanned below
            _clsys="$_clsys${_clsys:+ }$_clp/${_clo#/*/}"               # swap /@Source/ for this subvol
        done
    else
        _clbase="$(origin_base_of "$_clsnap")"
        if [ -n "$_clbase" ]; then
            _clsys="$(overlay_paths "$_clp" $(profile_dtbos_for "$_clbase") 2>/dev/null)" || _clsys=""
        fi
    fi
    _clusr="$(user_overlay_paths "$_clp")"
    printf '%s' "$_clsys${_clsys:+${_clusr:+ }}$_clusr"
}

# emit_entry SUF EXTRA GATE DTBOS [OVERLAY_LINE] -> write one BLS entry for the current $ENTRY_TOKEN.
# With a 5th argument the overlay line is used verbatim (already-resolved paths, e.g. a clone that
# copies its source's overlays); otherwise it is derived from DTBOS names + user drop-ins.
# The filename is $ENTRY_TOKEN-$KERNEL_VERSION.conf. The token is <NN>-flipperos-<subvol>, so it
# LEADS with the 3-digit menu band and U-Boot's bls (filename sort, descending) orders entries by
# band then version. EXTRA carries this entry's rootflags=subvol=; BASE_OPTS has none, so there is
# exactly one per entry. Honours gate (skip if a CONFIG_ symbol is missing) + overlays.
emit_entry() {
    _suf="$1"; _extra="$2"; _gate="$3"; _dtbos="$4"
    _ovl_override=0; [ $# -ge 5 ] && _ovl_override=1

    # gate may list several config symbols; all must be present in this kernel.
    for _g in $_gate; do
        has_config "$_g" || { log "skip $ENTRY_TOKEN (CONFIG_$_g not set for $KERNEL_VERSION)"; return 0; }
    done

    _opts="$BASE_OPTS"
    [ -n "$_extra" ] && _opts="$_opts $_extra"
    # A new entry is untried, so it is written with a full counter. Whatever this root already has
    # for this kernel goes first, by CONTENT rather than by id: a token can change under a profile
    # (a rename, a re-band), and an id-scoped delete would leave the old token's file behind. Two
    # entries naming one kernel in one subvolume are indistinguishable from a booted system, which
    # is what stops a good boot from being blessed.
    _id="$ENTRY_TOKEN-$KERNEL_VERSION"
    remove_entries "$(subvol_of "$_opts")" "$KERNEL_VERSION"
    _fn="$ENTRIES/$_id$(new_counter).conf"
    if [ "$_ovl_override" = 1 ]; then
        _line="$5"
    else
        # a leading '!' on the list = required: skip the whole entry if those profile overlays are absent
        _required=0
        case "$_dtbos" in '!'*) _required=1; _dtbos="$(trim "${_dtbos#\!}")" ;; esac
        if [ "$_required" = 1 ] && [ -z "$(overlay_paths "$(fdt_prefix "$_opts")" $_dtbos 2>/dev/null)" ]; then
            log "skip $ENTRY_TOKEN (required overlays not found for $KERNEL_VERSION)"
            return 0
        fi
        _line="$(dt_overlay_line "$_opts" "$_dtbos")"
    fi
    write_entry "$_fn" "$(make_title "$_suf")" "$_opts" "$_line"
    # This entry is the profile's chosen kernel now, so the rest of its entries are not.
    demote_others "$(subvol_of "$_opts")" "$_id"
}

# flipper_write_entry <subvol> <mounted-path> [<origin-hint>]: write a BLS entry for an EXISTING
# writable top-level subvol (a restored snapshot/clone). Token = <NN>-flipperos-<name>, NN from
# clone_slot (origin base + depth; the origin hint is the dangling-parent fallback). Points the
# entry at the root's OWN kernel+initrd in /usr/lib/modules/<ver>/ (resolve_kernel_paths), so no
# /boot staging. Sourced by create-profile / rename-profile. Returns non-zero on a recoverable problem.
flipper_write_entry() {
    _name="$1"; _snap="$2"; _origin="${3:-}"
    { [ -n "$_name" ] && [ -d "$_snap" ]; } || { echo "flipper-bls: usage: flipper_write_entry <name> <mounted-path>" >&2; return 1; }
    ENTRIES="${ENTRIES:-/boot/loader/entries}"
    # The base cmdline (root=UUID and policy) belongs to the root being written, not to whatever
    # is running. kernel-install still wins when it sets its own conf root. Without this, an entry
    # written from a recovery boot came out with no root= at all, and so could not boot.
    if [ -n "${KERNEL_INSTALL_CONF_ROOT:-}" ]; then CONF_ROOT="$KERNEL_INSTALL_CONF_ROOT"
    elif [ -f "$_snap/etc/kernel/cmdline" ]; then CONF_ROOT="$_snap/etc/kernel"
    else CONF_ROOT=/etc/kernel; fi
    MACHINE_ID=""; DEVICETREE=""; DEVICETREE_ENTRY=""
    # version from the target's OWN tree, so modules + dtbs are self-consistent
    KERNEL_VERSION="$(ls -1d "$_snap"/usr/lib/linux-image-* 2>/dev/null | sed 's,.*/linux-image-,,' | sort -V | tail -n1)"
    [ -n "$KERNEL_VERSION" ] || { echo "flipper-bls: no /usr/lib/linux-image-* inside $_name" >&2; return 1; }
    resolve_kconfig "$_snap"
    set_dtb_dirs
    SORT_KEY_OS="$(os_sort_key "$_snap")"
    # The band comes from the profile list, which lives INSIDE a profile, not in the /etc of
    # whatever is running. Under -d the running root may have no list at all (recovery), and an
    # empty band silently drops the sort prefix from the entry filename.
    PROFILES="${PROFILES:-$(target_profiles "$_snap")}"
    _nn="$(clone_slot "$_snap" "$_origin")"
    ENTRY_TOKEN="$(make_token "$_nn" "$_name")"
    SORT_KEY="$(entry_sort_key "$_name" "$_nn")"
    mkdir -p "$ENTRIES" || { echo "flipper-bls: cannot create $ENTRIES" >&2; return 1; }
    compute_base_opts
    resolve_kernel_paths "$_name" "$_snap" || return 1
    # devicetreedir is the target root's OWN kernel dir (KERNEL_VERSION came from it, so it exists).
    DEVICETREEDIR_REL="/usr/lib/linux-image-$KERNEL_VERSION"
    OVERLAY_DIR="$DTB_DIR/$VENDOR"
    OVERLAY_USER_ROOT="$_snap"                  # scan the TARGET root's drop-ins, not the running one
    # pin the root's own entry-token so a later runtime apt install in it lands in the same band
    mkdir -p "$_snap/etc/kernel" && printf '%s\n' "$ENTRY_TOKEN" > "$_snap/etc/kernel/entry-token"
    # No removal here: emit_entry below clears whatever this root has for this kernel, whatever
    # token it carries, which is what a re-created profile needs -- its snapshot depth moves the
    # sort number in the filename, so a new entry would land beside the old one instead of over
    # it.
    # Inherit overlays: copy the source profile's system overlays (re-pointed to this subvol) plus
    # this root's own user drop-ins, so a clone matches its source and a factory reset gets the
    # base profile's factory overlays.
    _ovl="$(clone_overlay_line "$BASE_OPTS rootflags=subvol=$_name" "$_origin" "$_snap")"
    emit_entry "$(printf '%s' "$_name" | tr -d '@')" "rootflags=subvol=$_name" "" "" "$_ovl"
    echo "flipper-bls: wrote entry for $_name (kernel $KERNEL_VERSION, token $ENTRY_TOKEN)"
}

# Rewrite the devicetree-overlay line of the booted profile's BLS entries in place from the current
# profile overlays + /etc/kernel/dtbo drop-ins, so changes take effect next boot without a full
# kernel-install (no re-staging, no initrd rebuild).
#   $1 scope: ""=the RUNNING kernel's entry only, "all"=every installed kernel of this profile
# Root only; reboot afterwards.
flipper_rewrite_overlay() {
    _scope="${1:-}"
    [ "$(id -u)" -eq 0 ] || { echo "flipper-bls: must run as root (use sudo)" >&2; return 1; }
    # Defaults describe the running root. A caller working on a mounted target sets TARGET_SUBVOL
    # and the three roots first (add-dtbo -d does, through with_bls).
    ENTRIES="${ENTRIES:-${KERNEL_INSTALL_BOOT_ROOT:-/boot}/loader/entries}"
    CONF_ROOT="${CONF_ROOT:-${KERNEL_INSTALL_CONF_ROOT:-/etc/kernel}}"
    OVERLAY_USER_ROOT="${OVERLAY_USER_ROOT:-}"
    _sv="${TARGET_SUBVOL:-$(booted_subvol)}"
    [ -n "$_sv" ] || { echo "flipper-bls: cannot determine the booted subvol" >&2; return 1; }
    if [ -n "${TARGET_SUBVOL:-}" ]; then
        # no running kernel over there, so the default scope is the newest it has, the one it boots
        _run="$(ls -1d "$OVERLAY_USER_ROOT"/usr/lib/linux-image-* 2>/dev/null | sed 's,.*/linux-image-,,' | sort -V | tail -n1)"
        [ -n "$_run" ] || { echo "flipper-bls: no kernel found in $_sv" >&2; return 1; }
    else
        _run="$(uname -r)"
    fi

    _dtbos=""
    _pf="${FLIPPER_PROFILES:-$CONF_ROOT/flipper-profiles}"
    if [ -f "$_pf" ]; then
        while IFS='|' read -r _t _s _e _g _d _r; do
            case "$_t" in ''|\#*) continue ;; esac
            if [ "$(subvol_of "$(trim "$_e")")" = "$_sv" ]; then _dtbos="$(trim "${_d#\!}")"; break; fi
        done <"$_pf"
    fi

    _n=0
    for _f in "$ENTRIES"/*.conf; do
        [ -f "$_f" ] || continue
        _opts="$(sed -n 's/^options[[:space:]]*//p' "$_f")"
        [ "$(entry_subvol_of "$_f")" = "$_sv" ] || continue
        KERNEL_VERSION="$(sed -n 's/^version[[:space:]]*//p' "$_f")"
        [ -n "$KERNEL_VERSION" ] || continue
        [ "$_scope" = all ] || [ "$KERNEL_VERSION" = "$_run" ] || continue
        set_dtb_dirs; OVERLAY_DIR="$DTB_DIR/$VENDOR"
        _line="$(dt_overlay_line "$_opts" "$_dtbos")"
        sed -i '/^devicetree-overlay[[:space:]]/d' "$_f"
        [ -n "$_line" ] && printf 'devicetree-overlay %s\n' "$_line" >>"$_f"
        # The device tree this entry boots with just changed, so the boot is on trial again.
        _f="$(rearm_entry "$_f")"
        _n=$((_n + 1)); echo "flipper-bls: updated ${_f##*/}"
    done
    [ "$_n" -gt 0 ] || { echo "flipper-bls: no matching entries for $_sv" >&2; return 1; }
    # The device tree these entries boot with has changed, which is a change to what the
    # next boot does; btrfs would otherwise hold it in memory for up to `commit=` seconds,
    # and somebody who adds an overlay and pulls the power gets the old one back.
    sync
}
