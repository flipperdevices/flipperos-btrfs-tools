#!/bin/sh
# What sync-settings writes into a profile and the store, checked on plain directories.
#
# The store is read by every profile, so a bad line in it must be refused rather than applied, and
# a boot with nothing to change must change nothing. Run from anywhere: ./tests/sync-settings.sh
set -u
S="$(CDPATH= cd -- "$(dirname -- "$0")/../scripts" && pwd)/sync-settings"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/etc" "$W/sys/module"
# iw stands in for the kernel: it records what it was asked, and fails when told to.
cat > "$W/bin/iw" <<EOF
#!/bin/sh
echo "\$*" >> "$W/iw.log"
[ ! -e "$W/iw.fail" ]
EOF
chmod 0755 "$W/bin/iw"
export PATH="$W/bin:$PATH" FLIPPER_SETTINGS="$W/settings" FLIPPER_ETC="$W/etc" FLIPPER_SYS="$W/sys"
CONF="$W/etc/modprobe.d/flipper-wifi-country.conf"

fail=0
ck() { # ck <what> <got> <want>
    if [ "$2" = "$3" ]; then printf 'ok   %-34s %s\n' "$1" "$2"
    else printf 'FAIL %-34s got %-24s want %s\n' "$1" "$2" "$3"; fail=1; fi
}
run() { "$S" "$@" >/dev/null 2>&1; echo $?; }
iwlog() { cat "$W/iw.log" 2>/dev/null; rm -f "$W/iw.log"; }

ck "no store, exit"         "$(run)"                     "0"
ck "no store, no conf"      "$([ -e "$CONF" ] && echo yes || echo no)" "no"

ck "set, exit"              "$(run set wifi_country=de)" "0"
ck "set, stored upper"      "$(cat "$W/settings")"       "wifi_country=DE"
ck "set, conf"              "$(cat "$CONF")"             "options cfg80211 ieee80211_regdom=DE"
ck "set, no module, no iw"  "$(iwlog)"                   ""

mkdir "$W/sys/module/cfg80211"
ck "set again, exit"        "$(run set wifi_country=US)" "0"
ck "set again, one line"    "$(cat "$W/settings")"       "wifi_country=US"
ck "set again, iw"          "$(iwlog)"                   "reg set US"

ck "boot, same, exit"       "$(run)"                     "0"
ck "boot, same, no iw"      "$(iwlog)"                   ""

# Another profile wrote the store: this one follows it on its next boot.
printf 'other=1\nwifi_country=FR\n' > "$W/settings"
ck "boot, changed, exit"    "$(run)"                     "0"
ck "boot, changed, conf"    "$(cat "$CONF")"             "options cfg80211 ieee80211_regdom=FR"
ck "boot, changed, iw"      "$(iwlog)"                   "reg set FR"

ck "set world, exit"        "$(run set wifi_country=00)" "0"
ck "set keeps other lines"  "$(tr '\n' ' ' < "$W/settings")" "other=1 wifi_country=00 "
iwlog >/dev/null

ck "bad value, exit"        "$(run set wifi_country=DEU)" "1"
ck "bad value, store kept"  "$(grep wifi_country "$W/settings")" "wifi_country=00"
ck "unknown key, exit"      "$(run set colour=red)"      "1"
ck "no =, exit"             "$(run set wifi_country)"    "1"
ck "set nothing, exit"      "$(run set)"                 "1"

printf 'wifi_country=../x\n' > "$W/settings"
ck "bad store, exit"        "$(run)"                     "1"
ck "bad store, conf kept"   "$(cat "$CONF")"             "options cfg80211 ieee80211_regdom=00"
ck "bad store, no iw"       "$(iwlog)"                   ""

ck "unset, exit"            "$(run set wifi_country=)"   "0"
ck "unset, store empty"     "$(cat "$W/settings")"       ""
ck "unset, conf gone"       "$([ -e "$CONF" ] && echo yes || echo no)" "no"
ck "unset, iw world"        "$(iwlog)"                   "reg set 00"
ck "unset, boot, no iw"     "$(run; iwlog)"              "0"

touch "$W/iw.fail"
ck "iw fails, exit"         "$(run set wifi_country=DE)" "1"
ck "iw fails, conf written" "$(cat "$CONF")"             "options cfg80211 ieee80211_regdom=DE"
rm -f "$W/iw.fail"; iwlog >/dev/null

ck "no temp files left"     "$(find "$W/etc" "$W" -maxdepth 3 -name '*.sync.*' | wc -l | tr -d ' ')" "0"
ck "unknown argument, exit" "$(run --push)"              "1"
ck "help, exit"             "$(run --help)"              "0"

exit "$fail"
