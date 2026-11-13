#!/bin/sh
# What the account merge makes of a database the factory base never had. migrate-profile passes an
# empty file as the base then, and awk reads no line of it. Run from anywhere: ./tests/accountdb.sh
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
# With nothing to compare against, every account is kept and ours wins where both changed it.
ck "empty base" "$(awk -v LF= -f "$A" "$W/base" "$W/ours" "$W/theirs")" \
"root:x:0:0::/root:/bin/bash
daemon:x:1:1::/:/bin/false
flipper:x:1000:1000::/home/flipper:/bin/bash
alice:x:1001:1001::/home/alice:/bin/bash"

[ "$fail" = 0 ] && echo "all accountdb checks ok"
exit "$fail"
