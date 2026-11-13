#!/bin/sh
# What sync-identity does to a store and to ssh directories, on plain directories standing in for
# /boot, /etc/ssh and the btrfs top level.
#
# The store decides what every profile presents to an ssh client, and the ways it goes wrong are
# all quiet: a key of zero length, a store half written, a profile skipped. Run from anywhere:
# ./tests/sync-identity.sh
set -u
S="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
# The tool and the libraries find each other by their installed paths; point those at the tree
# under test.
mkdir "$W/lib" "$W/bin"
for f in "$S"/libs/*.sh; do sed "s|/usr/lib/flipper-|$W/lib/flipper-|g" "$f" > "$W/lib/${f##*/}"; done
sed "s|/usr/lib/flipper-|$W/lib/flipper-|g" "$S/scripts/sync-identity" > "$W/sync-identity"
# --push asks btrfs whether each root is a subvolume and whether it is read-only. Every directory
# here is one, and the root named @Locked is read-only.
cat > "$W/bin/btrfs" <<'EOF'
#!/bin/sh
case "$*" in *@Locked*) echo "	Flags:			readonly" ;; *) echo "	Flags:			-" ;; esac
EOF
chmod +x "$W/bin/btrfs"
PATH="$W/bin:$PATH"

fail=0
ck() { # ck <what> <got> <want>
    if [ "$2" = "$3" ]; then printf 'ok   %-36s %s\n' "$1" "$2"
    else printf 'FAIL %-36s got %-24s want %s\n' "$1" "$2" "$3"; fail=1; fi
}
# A key set in directory $1 whose contents are the word $2.
mkkeys() {
    mkdir -p "$1"
    for t in rsa ecdsa ed25519; do
        echo "$2 $t private" > "$1/ssh_host_${t}_key"
        echo "$2 $t public"  > "$1/ssh_host_${t}_key.pub"
    done
}
mode() { stat -c %a "$1"; }
# run <store> <sshdir> [args]: the boot mode against those two directories.
run() {
    _st=$1; _sd=$2; shift 2
    FLIPPER_IDENTITY_STORE="$_st" FLIPPER_SSH_DIR="$_sd" sh "$W/sync-identity" "$@"
}

# --- an empty store is seeded by the first profile that has keys ---
d="$W/seed"; mkdir -p "$d/boot"; mkkeys "$d/A" alpha
out=$(run "$d/boot/flipper-identity" "$d/A"); rc=$?
ck "seed exit"          "$rc" "0"
ck "seed says so"       "$out" "sync-identity: this profile's ssh host keys are now the device's"
ck "seed private key"   "$(cat "$d/boot/flipper-identity/ssh/ssh_host_ed25519_key")" "alpha ed25519 private"
ck "seed file count"    "$(ls "$d/boot/flipper-identity/ssh" | wc -l | tr -d ' ')" "6"
ck "seed store mode"    "$(mode "$d/boot/flipper-identity")" "700"
ck "seed private mode"  "$(mode "$d/boot/flipper-identity/ssh/ssh_host_rsa_key")" "600"
ck "seed public mode"   "$(mode "$d/boot/flipper-identity/ssh/ssh_host_rsa_key.pub")" "644"
ck "seed leaves no temp" "$(ls -A "$d/boot/flipper-identity")" "ssh"

# --- a store directory that already existed with loose permissions is tightened ---
d2="$W/loose"; mkdir -p "$d2/boot/flipper-identity"; chmod 755 "$d2/boot/flipper-identity"; mkkeys "$d2/A" alpha
run "$d2/boot/flipper-identity" "$d2/A" >/dev/null
ck "loose store tightened" "$(mode "$d2/boot/flipper-identity")" "700"

# --- the next profile takes the store's keys over its own ---
mkkeys "$d/B" bravo; chmod 644 "$d/B/ssh_host_ed25519_key"
out=$(run "$d/boot/flipper-identity" "$d/B"); rc=$?
ck "apply exit"         "$rc" "0"
ck "apply says so"      "$out" "sync-identity: 6 ssh host key file(s) replaced with the device's"
ck "apply private key"  "$(cat "$d/B/ssh_host_ed25519_key")" "alpha ed25519 private"
ck "apply public key"   "$(cat "$d/B/ssh_host_ecdsa_key.pub")" "alpha ecdsa public"
ck "apply private mode" "$(mode "$d/B/ssh_host_ed25519_key")" "600"
ck "apply public mode"  "$(mode "$d/B/ssh_host_ed25519_key.pub")" "644"
ck "apply leaves no temp" "$(ls -A "$d/B" | grep -c sync)" "0"
ck "store unchanged"    "$(cat "$d/boot/flipper-identity/ssh/ssh_host_ed25519_key")" "alpha ed25519 private"

# --- a profile that already matches is not written to ---
touch -d '2001-01-01' "$d/B"/ssh_host_*
out=$(run "$d/boot/flipper-identity" "$d/B"); rc=$?
ck "same exit"          "$rc" "0"
ck "same is silent"     "$out" ""
ck "same not rewritten" "$(date -r "$d/B/ssh_host_ed25519_key" +%Y)" "2001"

# --- a key type the store lacks is left alone, the rest still follow the store ---
echo "bravo dsa private" > "$d/B/ssh_host_dsa_key"
echo "drifted" > "$d/B/ssh_host_rsa_key"
out=$(run "$d/boot/flipper-identity" "$d/B")
ck "extra type kept"    "$(cat "$d/B/ssh_host_dsa_key")" "bravo dsa private"
ck "drift repaired"     "$(cat "$d/B/ssh_host_rsa_key")" "alpha rsa private"
ck "drift counted"      "$out" "sync-identity: 1 ssh host key file(s) replaced with the device's"

# --- a temporary key an interrupted copy left behind is cleared on the next run ---
echo "alpha rsa private" > "$d/B/.ssh_host_rsa_key.sync.4242"
run "$d/boot/flipper-identity" "$d/B" >/dev/null
ck "stray temp cleared" "$(ls -A "$d/B" | grep -c '\.sync\.')" "0"

# --- a key that cannot be copied leaves the profile as it was, not half replaced ---
if [ "$(id -u)" != 0 ]; then
    mkkeys "$d/E" echo; chmod 000 "$d/boot/flipper-identity/ssh/ssh_host_rsa_key.pub"
    run "$d/boot/flipper-identity" "$d/E" >/dev/null 2>&1; ck "failed copy exit" "$?" "1"
    ck "failed copy, keys kept" "$(cat "$d/E/ssh_host_ed25519_key")" "echo ed25519 private"
    ck "failed copy, no temp" "$(ls -A "$d/E" | grep -c '\.sync\.')" "0"
    chmod 644 "$d/boot/flipper-identity/ssh/ssh_host_rsa_key.pub"
fi

# --- a zero-length key is no key: it neither seeds a store nor counts as one ---
d="$W/empty"; mkdir -p "$d/boot"; mkkeys "$d/A" alpha; : > "$d/A/ssh_host_ed25519_key"
out=$(run "$d/boot/flipper-identity" "$d/A"); rc=$?
ck "empty key exit"     "$rc" "0"
ck "empty key no seed"  "$([ -e "$d/boot/flipper-identity/ssh" ] && echo seeded || echo none)" "none"
mkkeys "$d/boot/flipper-identity/ssh" stale; : > "$d/boot/flipper-identity/ssh/ssh_host_ed25519_key"
mkkeys "$d/C" charlie
out=$(run "$d/boot/flipper-identity" "$d/C")
ck "empty store reseeded" "$(cat "$d/boot/flipper-identity/ssh/ssh_host_ed25519_key")" "charlie ed25519 private"
ck "empty store, own kept" "$(cat "$d/C/ssh_host_rsa_key")" "charlie rsa private"
ck "stale store key gone" "$(cat "$d/boot/flipper-identity/ssh/ssh_host_rsa_key")" "charlie rsa private"

# --- a seed cut short leaves a directory the next boot clears rather than trusts ---
d="$W/partial"; mkdir -p "$d/boot/flipper-identity/ssh.new.123"; mkkeys "$d/A" alpha
echo "half" > "$d/boot/flipper-identity/ssh.new.123/ssh_host_ed25519_key"
out=$(run "$d/boot/flipper-identity" "$d/A")
ck "partial ignored"    "$(cat "$d/boot/flipper-identity/ssh/ssh_host_ed25519_key")" "alpha ed25519 private"
ck "partial cleared"    "$(ls -A "$d/boot/flipper-identity")" "ssh"

# --- nothing to work with is a quiet success, never a failed unit ---
d="$W/quiet"; mkdir -p "$d/boot" "$d/none"; mkkeys "$d/A" alpha
run "$d/boot/flipper-identity" "$d/none" >/dev/null; ck "no keys anywhere" "$?" "0"
run "$d/boot/flipper-identity" "$d/missing" >/dev/null; ck "no ssh directory" "$?" "0"
run "$d/noboot/flipper-identity" "$d/A" >/dev/null; ck "no boot mount" "$?" "0"
ck "no boot, no store"  "$([ -e "$d/noboot" ] && echo made || echo none)" "none"
if [ "$(id -u)" != 0 ]; then
    chmod 555 "$d/boot"
    run "$d/boot/flipper-identity" "$d/A" >/dev/null; ck "read-only boot" "$?" "0"
    chmod 755 "$d/boot"
    mkkeys "$d/boot/flipper-identity/ssh" alpha; mkkeys "$d/R" romeo; chmod 555 "$d/R"
    run "$d/boot/flipper-identity" "$d/R" >/dev/null; ck "read-only ssh dir" "$?" "0"
    ck "read-only untouched" "$(cat "$d/R/ssh_host_rsa_key")" "romeo rsa private"
    chmod 755 "$d/R"
fi

# --- options ---
run "$d/boot/flipper-identity" "$d/A" -h >/dev/null; ck "help exit" "$?" "0"
run "$d/boot/flipper-identity" "$d/A" --nope >/dev/null 2>&1; ck "unknown option exit" "$?" "1"
run "$d/boot/flipper-identity" "$d/A" -d >/dev/null 2>&1; ck "device without value" "$?" "1"

# --- --push: every profile root, and only those ---
T="$W/top"; mkkeys "$T/boot/flipper-identity/ssh" alpha
mkkeys "$T/@Desktop/etc/ssh" delta
mkkeys "$T/@Router/etc/ssh" alpha
mkkeys "$T/@Locked/etc/ssh" lima
mkkeys "$T/@home/etc/ssh" hotel
mkkeys "$T/@Desktop_old_2026-09-30_10-00-00/etc/ssh" oscar
mkdir -p "$T/@Bare"
out=$(FLIPPER_TOP="$T" sh "$W/sync-identity" --push 2>&1); rc=$?
ck "push exit"          "$rc" "0"
ck "push differing root" "$(cat "$T/@Desktop/etc/ssh/ssh_host_ed25519_key")" "alpha ed25519 private"
ck "push reports it"    "$(printf '%s\n' "$out" | grep -c "^'@Desktop': 6 ")" "1"
ck "push matching root silent" "$(printf '%s\n' "$out" | grep -c "@Router")" "0"
ck "push skips read-only" "$(cat "$T/@Locked/etc/ssh/ssh_host_ed25519_key")" "lima ed25519 private"
ck "push says read-only" "$(printf '%s\n' "$out" | grep -c "^Skipped '@Locked': read-only")" "1"
ck "push skips reserved" "$(cat "$T/@home/etc/ssh/ssh_host_ed25519_key")" "hotel ed25519 private"
ck "push skips leftovers" "$(cat "$T/@Desktop_old_2026-09-30_10-00-00/etc/ssh/ssh_host_ed25519_key")" "oscar ed25519 private"
ck "push skips no /etc/ssh" "$([ -e "$T/@Bare/etc" ] && echo made || echo none)" "none"
out=$(FLIPPER_TOP="$T" sh "$W/sync-identity" --push 2>&1); rc=$?
ck "push again exit"    "$rc" "0"
ck "push again writes nothing" "$(printf '%s\n' "$out" | grep -c "replaced")" "0"
# A read-only root was skipped, so "every profile" would not be true.
ck "push again, no all-done claim" "$(printf '%s\n' "$out" | grep -c "^Every profile already has")" "0"
rm -rf "$T/@Locked"
out=$(FLIPPER_TOP="$T" sh "$W/sync-identity" --push 2>&1)
ck "push idle says so"  "$(printf '%s\n' "$out" | grep -c "^Every profile already has")" "1"

# --- --push reports a profile it could not write, by status as well as by message ---
if [ "$(id -u)" != 0 ]; then
    mkkeys "$T/@Stuck/etc/ssh" sierra; chmod 555 "$T/@Stuck/etc/ssh"
    out=$(FLIPPER_TOP="$T" sh "$W/sync-identity" --push 2>&1); rc=$?
    ck "push failure exit"  "$rc" "1"
    ck "push failure named" "$(printf '%s\n' "$out" | grep -c "could not write the ssh host keys of '@Stuck'")" "1"
    ck "push failure, no all-done claim" "$(printf '%s\n' "$out" | grep -c "^Every profile already has")" "0"
    chmod 755 "$T/@Stuck/etc/ssh"; rm -rf "$T/@Stuck"
fi

# --- --push with nothing in the store and no booted profile to take keys from refuses ---
T="$W/top2"; mkdir -p "$T/boot"; mkkeys "$T/@Desktop/etc/ssh" delta
# Not a btrfs root here, so nothing counts as the booted profile: findmnt is made to say so.
printf '#!/bin/sh\nexit 1\n' > "$W/bin/findmnt"; chmod +x "$W/bin/findmnt"
FLIPPER_TOP="$T" sh "$W/sync-identity" --push >/dev/null 2>&1; ck "push empty store exit" "$?" "1"
ck "push empty store, no seed" "$([ -e "$T/boot/flipper-identity" ] && echo made || echo none)" "none"
ck "push empty store, keys kept" "$(cat "$T/@Desktop/etc/ssh/ssh_host_ed25519_key")" "delta ed25519 private"

# --- --reseed: new keys for the device, in the store and every profile ---
# Stands in for ssh-keygen -A -f DIR, which writes under DIR/etc/ssh and exits 0 even when it
# could not write a key, saying so on stderr. KEYGEN set to fail writes nothing, to partial only
# ed25519 and a complaint, to nopub every key but without the ed25519 public half.
cat > "$W/bin/ssh-keygen" <<'EOF'
#!/bin/sh
for t in rsa ecdsa ed25519; do
    case "${KEYGEN:-}:$t" in
        fail:*|partial:rsa|partial:ecdsa) echo "Could not save your private key in $3" >&2; continue ;;
    esac
    echo "fresh $t private" > "$3/etc/ssh/ssh_host_${t}_key"
    [ "${KEYGEN:-}:$t" = nopub:ed25519 ] || echo "fresh $t public" > "$3/etc/ssh/ssh_host_${t}_key.pub"
done
EOF
chmod +x "$W/bin/ssh-keygen"
T="$W/top3"; mkkeys "$T/boot/flipper-identity/ssh" alpha
mkkeys "$T/@Desktop/etc/ssh" alpha
mkkeys "$T/@Locked/etc/ssh" alpha
for k in fail partial nopub; do
    KEYGEN=$k FLIPPER_TOP="$T" sh "$W/sync-identity" --reseed >/dev/null 2>&1; ck "reseed keygen $k exit" "$?" "1"
    ck "reseed keygen $k, store kept" "$(cat "$T/boot/flipper-identity/ssh/ssh_host_ed25519_key")" "alpha ed25519 private"
    ck "reseed keygen $k, profile kept" "$(cat "$T/@Desktop/etc/ssh/ssh_host_rsa_key")" "alpha rsa private"
done
out=$(KEYGEN=partial FLIPPER_TOP="$T" sh "$W/sync-identity" --reseed 2>&1)
ck "reseed keygen error shown" "$(printf '%s\n' "$out" | grep -q "Could not save your private key" && echo yes)" "yes"
out=$(FLIPPER_TOP="$T" sh "$W/sync-identity" --reseed 2>&1); rc=$?
ck "reseed exit"        "$rc" "0"
ck "reseed store"       "$(cat "$T/boot/flipper-identity/ssh/ssh_host_ed25519_key")" "fresh ed25519 private"
ck "reseed store mode"  "$(mode "$T/boot/flipper-identity/ssh/ssh_host_rsa_key")" "600"
# The old set traded places with the new one, then went.
ck "reseed store clean" "$(ls -A "$T/boot/flipper-identity")" "ssh"
ck "reseed profile"     "$(cat "$T/@Desktop/etc/ssh/ssh_host_rsa_key")" "fresh rsa private"
ck "reseed skips read-only" "$(cat "$T/@Locked/etc/ssh/ssh_host_ed25519_key")" "alpha ed25519 private"
ck "reseed restart last" "$(printf '%s\n' "$out" | tail -n 1 | grep -c "restart ssh")" "1"
out=$(FLIPPER_TOP="$T" sh "$W/sync-identity" --reseed -d /dev/null 2>&1)
ck "reseed -d, no restart" "$(printf '%s\n' "$out" | grep -c "restart ssh")" "0"
# No booted profile here either (findmnt still fails): a reseed does not need one.
T="$W/top4"; mkdir -p "$T/boot"; mkkeys "$T/@Desktop/etc/ssh" delta
FLIPPER_TOP="$T" sh "$W/sync-identity" --reseed >/dev/null 2>&1; ck "reseed empty store exit" "$?" "0"
ck "reseed empty store" "$(cat "$T/@Desktop/etc/ssh/ssh_host_ed25519_key")" "fresh ed25519 private"

[ "$fail" = 0 ] && echo "all sync-identity checks ok" || echo "FAILURES"
exit "$fail"
