# flipper-blsname.sh - what a BLS entry's name and sort-key mean, for everything that reads or
# writes one. Sourced by flipper-bls.sh (which writes entries), by set-boot-order (which writes
# the order) and by boot-profile (which reads an entry and counts an attempt against it). No die(),
# no log(), no dependencies: this is shared vocabulary, not a tool.
#
# WHAT BOOTS IS THE FIRST ENTRY. The order is not recorded anywhere else -- no marker, no pin -- so
# these two names carry all of it:
#
#   sort-key   debian-0100-Desktop-0
#              │      │└┬┘ └──┬──┘ └── rank:     0 = the profile's chosen kernel, 1 = its others
#              │      │ │     └─────── profile, as the entry token spells it
#              │      │ └───────────── band, ascending: 1000 - the filename band, so this order is
#              │      │                 the one the filenames already produce
#              │      └─────────────── autoboot: 0 for the profile that boots by itself, 1 for the
#              │                        rest; exactly one profile holds the 0
#              └────────────────────── the os-release id, which the BLS spec asks for and which it
#                                       allows to carry "an additional suffix"
#
#   file name  900-flipperos-Desktop-7.2.0-ga0d2d145deeb+2-1.conf
#              └──────────────┬──────────────────────┘ └┬┘
#                             │                         └── boot counter: tries left, tries done.
#                             │                              Absent = blessed, 0 left = bad.
#                             └──────────────────────────── the entry id: what boot-profile takes,
#                                                            unchanged by the counter
#
# The rank exists because the spec's own order inside one key is by `version` descending, and our
# releases are git-describe strings that do not compare: 7.2.0-00249-g26619ffca0bd against
# 7.2.0-ga0d2d145deeb has no answer in either direction.

# How many attempts a newly armed entry gets: systemd's own default. U-Boot's bls bootmeth does no
# counting, so the counter is read and spent by our tools alone.
BLS_TRIES="${FLIPPER_BLS_TRIES:-3}"

# The oldest kernel worth choosing, as major.minor. The same floor the boot menu hides entries
# below: this board runs mainline, and the 6.1 BSP entries an older image left on disk boot nothing
# anybody wants. Nothing here refuses to boot one -- an entry named outright is booted -- but a
# tool deciding FOR somebody must not land on a kernel the menu will not even show.
BLS_MIN_KERNEL="${FLIPPER_BLS_MIN_KERNEL:-7.0}"

# A kernel release as a sortable number: major, minor and patch, five digits each, so a plain
# string comparison ranks 7.10.0 above 7.9.0 and 7.2.0 above 6.16.0.
#
# Only the numbers before the first dash go in, because what follows them is a git-describe suffix
# that does not compare: 7.2.0-00249-g26619ffca0bd against 7.2.0-ga0d2d145deeb has no answer either
# way. Two releases whose numbers tie are separated by when they arrived, not by this.
#
# A release with no numbers at all ranks 0, behind every real one, and is still bootable by name.
version_rank() {  # $1 = version
    _v="${1%%-*}"
    case "$_v" in
        *.*.*) _a="${_v%%.*}"; _r="${_v#*.}"; _b="${_r%%.*}"; _c="${_r#*.}"; _c="${_c%%.*}" ;;
        *.*)   _a="${_v%%.*}"; _b="${_v#*.}"; _b="${_b%%.*}"; _c=0 ;;
        *)     _a="$_v"; _b=0; _c=0 ;;
    esac
    case "$_a" in ''|*[!0-9]*) _a=0 ;; esac
    case "$_b" in ''|*[!0-9]*) _b=0 ;; esac
    case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
    printf '%05d%05d%05d' "$_a" "$_b" "$_c"
}

# Whether a kernel release is $2 (major.minor, default $BLS_MIN_KERNEL) or newer. True for a
# release that cannot be parsed: the menu shows those too, on the grounds that a hidden entry
# cannot be booted and showing one kernel too many is the safer mistake.
#
# Only the numbers before the first dash compare, because ours are git-describe strings:
# 7.2.0-00249-g26619ffca0bd against 7.2.0-ga0d2d145deeb has no answer in either direction. Major
# and minor are enough for the question being asked, which is BSP or mainline.
version_at_least() {  # $1 = version, $2 = min (optional)
    _v="${1%%-*}"; _m="${2:-$BLS_MIN_KERNEL}"
    _vmaj="${_v%%.*}"; _vrest="${_v#*.}"; _vmin="${_vrest%%.*}"
    case "$_vmaj" in ''|*[!0-9]*) return 0 ;; esac
    case "$_vmin" in ''|*[!0-9]*) _vmin=0 ;; esac
    _mmaj="${_m%%.*}"; _mmin="${_m#*.}"; _mmin="${_mmin%%.*}"
    case "$_mmin" in ''|*[!0-9]*) _mmin=0 ;; esac
    [ "$_vmaj" -gt "$_mmaj" ] && return 0
    [ "$_vmaj" -lt "$_mmaj" ] && return 1
    [ "$_vmin" -ge "$_mmin" ]
}

# ── Names ──────────────────────────────────────────────────────────────────────────────────────

# The entry id: the file name without its counter or suffix. Stable across attempts, which is why
# it is what the tools name an entry by.
entry_id_of() {  # $1 = a path or file name
    _e="${1##*/}"; _e="${_e%.conf}"; printf '%s' "${_e%%+*}"
}

# The boot counter as it appears in the name ("+2-1"), or empty for a blessed entry.
entry_counter_of() {  # $1 = a path or file name
    _e="${1##*/}"; _e="${_e%.conf}"
    case "$_e" in *+*) printf '%s' "+${_e#*+}" ;; esac
    return 0
}

# Tries left, or empty when the entry carries no counter. Zero means 'bad': it has spent every
# attempt, sorts after everything else, and is still bootable if someone picks it.
entry_tries_of() {  # $1 = a path or file name
    _c="$(entry_counter_of "$1")"; [ -n "$_c" ] || return 0
    _c="${_c#+}"; printf '%s' "${_c%%-*}"
}

# The counter a freshly written or re-armed entry carries: every try, none done. The 'tries done'
# half is written out rather than left off, as the spec asks, so the width never changes.
new_counter() { printf '+%s-0' "$BLS_TRIES"; }

# Every file belonging to an id, whatever counter it carries. Needs $ENTRIES.
entry_files_for() {  # $1 = id
    for _f in "${ENTRIES:-/boot/loader/entries}/$1.conf" "${ENTRIES:-/boot/loader/entries}/$1"+*.conf; do
        [ -f "$_f" ] && printf '%s\n' "$_f"
    done
    return 0
}

# The subvolume an entry mounts, from its own options line. The one fact that ties an entry to a
# profile: names and ids both repeat across filesystems, this does not.
entry_subvol_of() {  # $1 = entry file
    awk '$1=="options"{for(i=2;i<=NF;i++) if($i ~ /^rootflags=subvol=/) s=$i}
         END{sub(/^rootflags=subvol=/,"",s); print s}' "$1" 2>/dev/null
}

# Put an entry back on trial with a full counter, whatever it had. Prints the resulting path.
#
# Called when what the entry boots has changed -- a kernel chosen, a device tree overlay added --
# because a kernel proven with one device tree is not proven with another.
rearm_entry() {  # $1 = entry file
    _id="$(entry_id_of "$1")"; _dir="${1%/*}"
    _new="$_dir/$_id$(new_counter).conf"
    [ "$1" = "$_new" ] || mv -f "$1" "$_new"
    printf '%s' "$_new"
}

# Count one attempt against an entry: tries left down, tries done up. Prints the resulting path.
#
# A blessed entry (no counter) is left alone -- the spec's model is that a good boot stops being
# counted -- and so is one already at zero, which is bad and boots anyway when asked for.
decrement_entry() {  # $1 = entry file
    _c="$(entry_counter_of "$1")"
    if [ -z "$_c" ]; then printf '%s' "$1"; return 0; fi
    _c="${_c#+}"; _left="${_c%%-*}"; _done="${_c#*-}"
    case "$_done" in "$_left") _done=0 ;; esac     # "+3" with no second number
    if [ "$_left" -le 0 ] 2>/dev/null; then printf '%s' "$1"; return 0; fi
    _id="$(entry_id_of "$1")"; _dir="${1%/*}"
    _new="$_dir/$_id+$((_left - 1))-$((_done + 1)).conf"
    mv -f "$1" "$_new" || { printf '%s' "$1"; return 1; }
    printf '%s' "$_new"
}

# The boot order: every entry in $ENTRIES, first to last, one path per line. The first line is
# what boots when nobody presses anything.
#
# The rule, which flipctl implements in Rust against the same fields:
#
#   1. an entry with no tries left sorts after everything else            (the spec's own rule)
#   2. then by sort-key, ascending                                        (the spec's own rule)
#   3. then by kernel version, descending, as far as it compares          (the spec's own rule)
#   4. then newest file first, which separates two builds of one version
#   5. then by file name, descending                                      (the spec's last resort)
sorted_entries() {
    for _f in "${ENTRIES:-/boot/loader/entries}"/*.conf; do
        [ -f "$_f" ] || continue
        _bad=0; [ "$(entry_tries_of "$_f")" = 0 ] && _bad=1
        printf '%s|%s|%s|%s|%s\n' \
            "$_bad" \
            "$(sed -n 's/^sort-key[[:space:]]\{1,\}//p' "$_f" | head -n1)" \
            "$(version_rank "$(sed -n 's/^version[[:space:]]\{1,\}//p' "$_f" | head -n1)")" \
            "$(stat -c %Y "$_f" 2>/dev/null || echo 0)" \
            "$_f"
    done | sort -t'|' -k1,1n -k2,2 -k3,3r -k4,4nr -k5,5r | cut -d'|' -f5-
    return 0
}

# ── Keys ───────────────────────────────────────────────────────────────────────────────────────

# BLS sort-key prefix from os-release (IMAGE_ID, else ID); empty if the root has no os-release.
# $1 = mounted root to describe (default /). Reads the TARGET's os-release and nothing else: under
# -d the running root is a different image entirely, and in a recovery boot its ID is the recovery
# system's, so borrowing it would put the wrong name on the entry rather than no name at all.
os_sort_key() {
    _osr="${1:-}/etc/os-release"
    [ -r "$_osr" ] || return 0
    ( . "$_osr"; printf '%s' "${IMAGE_ID:-$ID}" ) || :
}

# Sort band from a filename band: the profile's own slot inverted, with its clone depth added
# back on.
#
# The filename bands run the other way (900-Desktop, 800-TV, ...) because U-Boot lists them
# descending, so ours is 1000 minus the profile slot. Clone depth is NOT inverted with it: a clone
# sits just AFTER the profile it came from, where inverting would put it just before and make a
# clone of @Desktop the thing the machine boots by itself. Bands step by 100 and depth is what a
# filename band carries below that, so the two split cleanly:
#
#     900 -> 100    Desktop            901 -> 101    a clone of Desktop
#     800 -> 200    TV Media Box       802 -> 202    a clone of a clone of TV Media Box
sort_band() {
    [ -n "${1:-}" ] || return 0
    _slot=$(( $1 - $1 % 100 )); _depth=$(( $1 % 100 ))
    printf '%03d' "$(( 1000 - _slot + _depth ))"
}

# The band digits leading an entry token or id (900-flipperos-Desktop -> 900), or empty.
token_band() {  # $1 = entry token or id
    case "${1%%-*}" in ''|*[!0-9]*) ;; *) printf '%s' "${1%%-*}" ;; esac
    return 0
}

# Compose a sort-key. $1 = autoboot digit, $2 = sort band, $3 = profile name (any @ stripped),
# $4 = rank digit. $SORT_KEY_OS leads it where the root states an os-release id.
make_sort_key() {
    _n="$(printf '%s' "$3" | tr -d '@')"
    [ -n "${SORT_KEY_OS:-}" ] && printf '%s-' "$SORT_KEY_OS"
    printf '%s%s-%s-%s' "$1" "$2" "$_n" "$4"
}

# Edit an entry file in place without moving its timestamp.
#
# The timestamp is load-bearing: the order breaks an otherwise-tied comparison by newest file
# first, which is how "the kernel I just installed" is known at all. An edit that let the mtime
# move would make every entry look installed at the moment somebody pressed a button, so the file
# is put back to the second it had. Kept by reference through a copy, because `touch -d @sec` is a
# GNU extension and this also runs under BusyBox.
edit_entry() {  # $1 = entry file, rest = sed expressions
    _f=$1; shift
    _ref="$_f.order-ref"
    cp -p "$_f" "$_ref" 2>/dev/null || _ref=""
    for _x in "$@"; do sed -i "$_x" "$_f"; done
    [ -n "$_ref" ] && { touch -r "$_ref" "$_f"; rm -f "$_ref"; }
    return 0
}

# Write one entry's sort-key, in place. Nothing else in the file changes.
set_sort_key() {  # $1 = entry file, $2 = key
    if grep -q '^sort-key[[:space:]]' "$1"; then
        edit_entry "$1" "s|^sort-key[[:space:]].*|sort-key   $2|"
    else
        edit_entry "$1" "1a sort-key   $2"
    fi
}

# Rewrite one entry's key, keeping every field the caller passes '-' for. An entry whose key
# carries no suffix of ours is stamped from scratch, band and all, so this is also how an entry
# written before the order was in them gets repaired.
#
# The band can be given as well as the digits, because the band a key carries is not always the
# band it should carry: it comes from the profile list, and a stamp made under an older rule (or on
# another image's list) has to be recomputed rather than believed.
#
# $5 is the mounted root whose os-release names the key; without it the key gets no os prefix,
# which is what an entry for a root we cannot read should have.
restamp_entry() {  # $1 = file, $2 = auto or '-', $3 = rank or '-', $4 = band or '-', $5 = os root
    _f=$1
    _a="$(sort_key_field "$_f" auto)"; _b="$(sort_key_field "$_f" band)"; _r="$(sort_key_field "$_f" rank)"
    _sv="$(entry_subvol_of "$_f")"
    [ "${4:--}" = '-' ] || _b=$4
    [ -n "$_b" ] || _b="$(sort_band "$(token_band "$(entry_id_of "$_f")")")"
    [ -n "$_b" ] || _b=999
    [ -n "$_a" ] || _a=1
    [ -n "$_r" ] || _r=1
    [ "$2" = '-' ] || _a=$2
    [ "$3" = '-' ] || _r=$3
    SORT_KEY_OS="$(os_sort_key "${5:-}")"
    set_sort_key "$_f" "$(make_sort_key "$_a" "$_b" "$_sv" "$_r")"
}

# One field of an entry file's sort-key suffix, or empty: 'auto', 'band', 'rank'.
#
# The rank is the last dash-separated field, since it is appended last. The autoboot digit and the
# band are found by shape rather than by position -- the first field that is one digit of 0 or 1
# followed by three more -- because a profile name carries dashes of its own (TV-Media-Box) and so
# may an os id, and counting fields from either end would land in the middle of one.
sort_key_field() {  # $1 = entry file, $2 = field
    _k="$(sed -n 's/^sort-key[[:space:]]\{1,\}//p' "$1" 2>/dev/null | head -n1)"
    [ -n "$_k" ] || return 0
    case "$2" in
        rank) printf '%s' "${_k##*-}" ;;
        auto|band)
            _ab="$(printf '%s' "$_k" | awk -F- '{ for (i = 1; i <= NF; i++)
                       if ($i ~ /^[01][0-9][0-9][0-9]$/) { print $i; exit } }')"
            [ -n "$_ab" ] || return 0
            case "$2" in
                auto) printf '%s' "$_ab" | cut -c1 ;;
                band) printf '%s' "$_ab" | cut -c2-4 ;;
            esac
            ;;
    esac
    return 0
}
