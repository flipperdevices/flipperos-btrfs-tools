#!/bin/sh
# What the account merge keeps when a profile moves onto a newer build, checked with the files laid
# out the way migrate-profile passes them: the profile's old _stock, the new build's copy, the profile.
#
# These records decide who can log in after update-profile. The image runs `chpasswd` at build
# time, so the factory hash is salted anew in every build and the new base's record of an account
# nobody touched still differs from the old base's: the merge must tell that apart from a password
# the owner set. Every hash below is a placeholder string. Run from anywhere: ./tests/accountdb-merge.sh
# AWK=gawk ./tests/accountdb-merge.sh runs the same checks with another awk.
set -u
LC_ALL=C; export LC_ALL
A="$(CDPATH='' cd -- "$(dirname -- "$0")/../libs" && pwd)/flipper-accountdb.awk"
[ -r "$A" ] || { echo "FAIL $A not found"; exit 1; }
W="$(mktemp -d)" || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf "$W"' EXIT

fail=0
ck() { # ck <what> <got> <want>
    if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
    else printf 'FAIL %s\ngot:\n%s\nwant:\n%s\n' "$1" "$2" "$3"; fail=1; fi
}
# merge <list-fields> <base> <new base> <profile>: one record per argument line, as migrate-profile
# calls the script (base, then dst, then src).
merge() {
    printf '%s' "$2" > "$W/base"; printf '%s' "$3" > "$W/ours"; printf '%s' "$4" > "$W/theirs"
    "${AWK:-awk}" -v LF="$1" -f "$A" "$W/base" "$W/ours" "$W/theirs"
}
# The record for <key> in the merge's output, or nothing.
rec() { printf '%s\n' "$1" | grep "^$2:" ; }
members() { rec "$1" "$2" | cut -d: -f"$3" | tr ',' '\n' | sed '/^$/d' | sort | tr '\n' ' '; }

ROOT1='root:*:20300:0:99999:7:::'
ROOT2='root:*:20350:0:99999:7:::'
F1='user:FACTORY-BUILD-1:20300:0:99999:7:::'
F2='user:FACTORY-BUILD-2:20350:0:99999:7:::'
OWN='user:OWNER-SET:20310:0:99999:7:::'
nl='
'

out=$(merge "" "$ROOT1$nl$F1$nl" "$ROOT2$nl$F2$nl" "$ROOT1$nl$OWN$nl")
ck "owner password kept over a rebuilt factory one" "$(rec "$out" user)" "$OWN"
ck "untouched root follows the new base"            "$(rec "$out" root)" "$ROOT2"

out=$(merge "" "$ROOT1$nl$F1$nl" "$ROOT1$nl$F1$nl" "$ROOT1$nl$OWN$nl")
ck "owner password kept over the same factory one"  "$(rec "$out" user)" "$OWN"

# What the header documents today. #140 asks whether a profile nobody onboarded may keep the
# factory login at all; if that is decided otherwise, this check changes with it.
out=$(merge "" "$ROOT1$nl$F1$nl" "$ROOT2$nl$F2$nl" "$ROOT1$nl$F1$nl")
ck "factory account nobody set follows the new base" "$(rec "$out" user)" "$F2"

LOCK='user:!FACTORY-BUILD-1:20310:0:99999:7:::'
out=$(merge "" "$ROOT1$nl$F1$nl" "$ROOT2$nl$F2$nl" "$ROOT1$nl$LOCK$nl")
ck "locked account stays locked"                    "$(rec "$out" user)" "$LOCK"

ALICE='alice:OWNER-SET:20310:0:99999:7:::'
out=$(merge "" "$ROOT1$nl$F1$nl" "$ROOT2$nl$F2$nl" "$ROOT1$nl$F1$nl$ALICE$nl")
ck "account the owner added is carried"             "$(rec "$out" alice)" "$ALICE"
ck "no account twice" "$(printf '%s\n' "$out" | cut -d: -f1 | sort | uniq -d)" ""

PWROOT='root:x:0:0:root:/root:/bin/bash'
PWUSER='user:x:1000:1000::/home/user:/bin/bash'
SVC='flipctl:x:999:999::/var/lib/flipctl:/usr/sbin/nologin'
out=$(merge "" "$PWROOT$nl$PWUSER$nl" "$PWROOT$nl$PWUSER$nl$SVC$nl" "$PWROOT$nl$PWUSER$nl")
ck "account the new build added appears"            "$(rec "$out" flipctl)" "$SVC"

# Membership lists are merged three ways (merge_members): a member removed on either side stays
# removed, one added on either side is kept.
out=$(merge 4 "root:x:0:${nl}sudo:x:27:user$nl" "root:x:0:${nl}sudo:x:27:user$nl" "root:x:0:${nl}sudo:x:27:$nl")
ck "membership the owner removed stays removed"     "$(members "$out" sudo 4)" ""

out=$(merge 4 "root:x:0:${nl}video:x:44:user$nl" "root:x:0:${nl}video:x:44:user,flipctl$nl" "root:x:0:${nl}video:x:44:user,alice$nl")
ck "memberships added on both sides are united"     "$(members "$out" video 4)" "alice flipctl user "

out=$(merge 3,4 "root:*::${nl}netdev:!::user$nl" "root:*::${nl}netdev:!::user$nl" "root:*::${nl}netdev:!:alice:$nl")
ck "gshadow admins merged"                          "$(members "$out" netdev 3)" "alice "
ck "gshadow members merged"                         "$(members "$out" netdev 4)" ""

[ "$fail" = 0 ] && echo "all account merge checks ok"
exit "$fail"
