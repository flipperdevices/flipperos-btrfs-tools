#!/bin/sh
# What the account merge keeps when a profile moves onto a newer build, including a database the
# factory base never had: migrate-profile passes an empty file as the base then, and awk reads no
# line of it. Run from anywhere: ./tests/accountdb.sh
set -u
A="$(CDPATH= cd -- "$(dirname -- "$0")/../libs" && pwd)/flipper-accountdb.awk"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

fail=0
ck() { # ck <what> <got> <want>
    if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
    else printf 'FAIL %s\ngot:\n%s\nwant:\n%s\n' "$1" "$2" "$3"; fail=1; fi
}

: > "$W/base"
printf '%s\n' 'root:x:0:0::/root:/bin/bash' 'daemon:x:1:1::/:/bin/false' 'flipper:x:1000:1000::/home/flipper:/bin/bash' > "$W/ours"
printf '%s\n' 'root:x:0:0::/root:/bin/bash' 'flipper:x:1000:1000::/home/flipper:/bin/zsh' 'alice:x:1001:1001::/home/alice:/bin/bash' > "$W/theirs"
# With nothing to compare against, every account is kept and theirs wins where both changed it.
ck "empty base" "$(awk -v LF= -f "$A" "$W/base" "$W/ours" "$W/theirs")" \
"root:x:0:0::/root:/bin/bash
daemon:x:1:1::/:/bin/false
flipper:x:1000:1000::/home/flipper:/bin/zsh
alice:x:1001:1001::/home/alice:/bin/bash"

# A deleted account stays deleted, although every build re-salts its factory hash.
printf '%s\n' 'root:*:1::::::' 'user:HASH-OLD:1::::::' > "$W/base"
printf '%s\n' 'root:*:1::::::' 'user:HASH-NEW:2::::::' > "$W/ours"
printf '%s\n' 'root:*:1::::::' > "$W/theirs"
ck "deleted account" "$(awk -v LF= -f "$A" "$W/base" "$W/ours" "$W/theirs")" "root:*:1::::::"

# A group field set in theirs survives where ours left it alone; one ours changed follows ours.
printf '%s\n' 'root:*::' 'wheel:!::user' 'audio:!::' > "$W/base"
printf '%s\n' 'root:*::' 'wheel:!::user' 'audio:*::' > "$W/ours"
printf '%s\n' 'root:*::' 'wheel:GROUP-PW::user' 'audio:!::' > "$W/theirs"
ck "group fields" "$(awk -v LF=3,4 -f "$A" "$W/base" "$W/ours" "$W/theirs")" \
'root:*::
wheel:GROUP-PW::user
audio:*::'

[ "$fail" = 0 ] && echo "all accountdb checks ok"
exit "$fail"
