#!/bin/sh
# What an entry name and a sort-key mean, checked against names shaped like the real ones.
#
# The order the boot menu boots by is carried in these two strings, and every part of it is a
# substring operation on a name that contains dashes, plus signs and profile labels -- exactly the
# shape that breaks quietly. Run from anywhere: ./tests/entry-names.sh
set -u
R="$(CDPATH= cd -- "$(dirname -- "$0")/../libs" && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
# The libraries source each other by their installed paths; point those at the tree under test.
for f in "$R"/*.sh; do sed "s|/usr/lib/flipper-|$R/flipper-|g" "$f" > "$W/${f##*/}"; done
. "$W/flipper-bls.sh"

fail=0
ck() { # ck <what> <got> <want>
    if [ "$2" = "$3" ]; then printf 'ok   %-34s %s\n' "$1" "$2"
    else printf 'FAIL %-34s got %-24s want %s\n' "$1" "$2" "$3"; fail=1; fi
}

ck "id of plain"      "$(entry_id_of /boot/loader/entries/900-flipperos-Desktop-7.2.0-ga0d2.conf)" "900-flipperos-Desktop-7.2.0-ga0d2"
ck "id of armed"      "$(entry_id_of 900-flipperos-Desktop-7.2.0-ga0d2+3-0.conf)"                  "900-flipperos-Desktop-7.2.0-ga0d2"
ck "id of tried"      "$(entry_id_of 900-flipperos-Desktop-7.2.0-ga0d2+1-2.conf)"                  "900-flipperos-Desktop-7.2.0-ga0d2"
ck "counter of armed" "$(entry_counter_of 900-x+3-0.conf)"                                          "+3-0"
ck "counter of plain" "$(entry_counter_of 900-x.conf)"                                              ""
ck "tries of armed"   "$(entry_tries_of 900-x+3-0.conf)"                                            "3"
ck "tries of spent"   "$(entry_tries_of 900-x+0-3.conf)"                                            "0"
ck "tries of blessed" "$(entry_tries_of 900-x.conf)"                                                ""
ck "new counter"      "$(new_counter)"                                                              "+3-0"

ck "band 900"  "$(sort_band 900)" "100"
ck "band 901"  "$(sort_band 901)" "101"
ck "band 802"  "$(sort_band 802)" "202"
ck "band 500"  "$(sort_band 500)" "500"
ck "band none" "$(sort_band '')"  ""

SORT_KEY_OS=debian
ck "key desktop" "$(make_sort_key 0 100 @Desktop 0)"        "debian-0100-Desktop-0"
ck "key tv"      "$(make_sort_key 1 200 @TV-Media-Box 1)"   "debian-1200-TV-Media-Box-1"
SORT_KEY_OS=
ck "key no os"   "$(make_sort_key 1 500 @No-Graphics 1)"    "1500-No-Graphics-1"

# Reading the fields back out of a real entry file, including the dashed names that broke
# field-counting.
d=$(mktemp -d); ENTRIES="$d"
mk() { printf 'title x\nsort-key   %s\noptions    root=UUID=y rootflags=subvol=%s ro\nlinux /x\n' "$2" "$3" > "$d/$1"; }
mk "900-flipperos-Desktop-7.2.0-a+3-0.conf"      "debian-0100-Desktop-0"          "@Desktop"
mk "900-flipperos-Desktop-7.2.0-b+3-0.conf"      "debian-0100-Desktop-1"          "@Desktop"
mk "800-flipperos-TV-Media-Box-7.2.0-a.conf"     "debian-1200-TV-Media-Box-0"     "@TV-Media-Box"
mk "901-flipperos-Desktop__Before-up__-7.2.0.conf" "debian-1101-Desktop__Before-up__-0" "@Desktop__Before-up__"

ck "field rank"      "$(sort_key_field "$d/900-flipperos-Desktop-7.2.0-a+3-0.conf" rank)" "0"
ck "field auto"      "$(sort_key_field "$d/900-flipperos-Desktop-7.2.0-a+3-0.conf" auto)" "0"
ck "field band"      "$(sort_key_field "$d/900-flipperos-Desktop-7.2.0-a+3-0.conf" band)" "100"
ck "dashed rank"     "$(sort_key_field "$d/800-flipperos-TV-Media-Box-7.2.0-a.conf" rank)" "0"
ck "dashed auto"     "$(sort_key_field "$d/800-flipperos-TV-Media-Box-7.2.0-a.conf" auto)" "1"
ck "dashed band"     "$(sort_key_field "$d/800-flipperos-TV-Media-Box-7.2.0-a.conf" band)" "200"
ck "derived band"    "$(sort_key_field "$d/901-flipperos-Desktop__Before-up__-7.2.0.conf" band)" "101"
ck "subvol of entry" "$(entry_subvol_of "$d/800-flipperos-TV-Media-Box-7.2.0-a.conf")" "@TV-Media-Box"

ck "auto digit inherited" "$(profile_auto_digit @Desktop)"       "0"
ck "auto digit other"     "$(profile_auto_digit @TV-Media-Box)"  "1"
ck "auto digit unknown"   "$(profile_auto_digit @Router)"        "1"
# A new entry always leads its profile, and the profile's other entries step down to
# rank 1: installing a kernel is asking to boot it.
SORT_KEY_OS=debian
demote_others @Desktop 900-flipperos-Desktop-7.2.0-b >/dev/null
ck "demoted the other"    "$(sort_key_field "$d/900-flipperos-Desktop-7.2.0-a+3-0.conf" rank)" "1"
ck "left the named one"   "$(sort_key_field "$d/900-flipperos-Desktop-7.2.0-b+3-0.conf" rank)" "1"

ck "files for id" "$(ENTRIES=$d entry_files_for 900-flipperos-Desktop-7.2.0-a | wc -l | tr -d ' ')" "1"

# A version as a sortable number, which is the third thing the order compares.
ck "rank 7.2.0"     "$(version_rank 7.2.0-00249-g26619ffca0bd)" "000070000200000"
ck "rank 7.10.0"    "$(version_rank 7.10.0)"                    "000070001000000"
ck "rank 6.1.172"   "$(version_rank 6.1.172)"                   "000060000100172"
ck "rank 7.2"       "$(version_rank 7.2)"                       "000070000200000"
ck "rank 7"         "$(version_rank 7)"                         "000070000000000"
ck "rank unreadable" "$(version_rank mainline)"                 "000000000000000"
# 7.10 above 7.9 is the whole reason these are numbers and not strings.
[ "$(version_rank 7.10.0)" \> "$(version_rank 7.9.0)" ] && r=yes || r=no
ck "7.10 beats 7.9" "$r" "yes"

# The kernel floor, which decides what a migration may choose for somebody.
for v in 7.0 7.2.0-00249-g26619ffca0bd 7.2.0-ga0d2d145deeb 8.1.0 mainline ""; do
    version_at_least "$v" && r=yes || r=no
    ck "at least 7.0: ${v:-(empty)}" "$r" "yes"
done
for v in 6.1.172 6.16.0-rc1 0.1 5.10; do
    version_at_least "$v" && r=yes || r=no
    ck "at least 7.0: $v" "$r" "no"
done

ck "token band"      "$(token_band 900-flipperos-Desktop)" "900"
ck "token band none" "$(token_band flipperos-Desktop)"     ""

SORT_KEY_OS=debian
ck "entry key existing" "$(entry_sort_key @Desktop 900)" "debian-0100-Desktop-0"
ck "entry key fresh"    "$(entry_sort_key @Router 700)"  "debian-1300-Router-0"
ck "entry key unmapped" "$(entry_sort_key @Odd '')"      "debian-1999-Odd-0"

# A key rewrite must not move the file's timestamp: the order breaks ties by newest file, so
# stamping keys would otherwise reshuffle every entry it touched.
touch -t 202001010000 "$d/600-x.conf"
printf 'sort-key   debian-1400-Minimal-1\noptions rootflags=subvol=@Minimal\n' > "$d/600-x.conf"
touch -t 202001010000 "$d/600-x.conf"
_before="$(stat -c %Y "$d/600-x.conf")"
set_sort_key "$d/600-x.conf" "debian-1400-Minimal-0"
ck "key rewritten"       "$(sort_key_field "$d/600-x.conf" rank)" "0"
ck "timestamp kept"      "$(stat -c %Y "$d/600-x.conf")" "$_before"
ck "no leftover ref"     "$(ls "$d" | grep -c order-ref || true)" "0"

# What identifies a booted entry is its subvolume and its kernel version, so removing by content
# has to catch an entry written under a different token for the same pair.
mk "600-flipperos-Minimal-7.2.0-a+3-0.conf"     "debian-1400-Minimal-0" "@Minimal"
printf 'version 7.2.0-a\n' >> "$d/600-flipperos-Minimal-7.2.0-a+3-0.conf"
mk "601-flipperos-Minimal-7.2.0-a+3-0.conf"     "debian-1401-Minimal-0" "@Minimal"
printf 'version 7.2.0-a\n' >> "$d/601-flipperos-Minimal-7.2.0-a+3-0.conf"
ENTRIES="$d" remove_entries "@Minimal" "7.2.0-a"
ck "both tokens removed" "$(ls "$d" | grep -c 'flipperos-Minimal-7.2.0-a' || true)" "0"

# Re-arming a blessed entry, and one already on trial.
ck "rearm blessed" "$(basename "$(rearm_entry "$d/800-flipperos-TV-Media-Box-7.2.0-a.conf")")" "800-flipperos-TV-Media-Box-7.2.0-a+3-0.conf"
ck "rearm tried"   "$(basename "$(rearm_entry "$d/900-flipperos-Desktop-7.2.0-a+3-0.conf")")"  "900-flipperos-Desktop-7.2.0-a+3-0.conf"

rm -rf "$d"
[ "$fail" = 0 ] && echo "all key helpers ok" || echo "FAILURES"
exit "$fail"
