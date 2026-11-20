#!/bin/sh
# Sindoh model survey: a READ-ONLY look at a Sindoh 3D printer's hardware and
# firmware, saved as a text file on the USB stick.
#
# The stock /app/auto_update.sh runs it from the stick (packed by pack.py as
# <model folder>/unmistakable_model_survey.she, extracted to /tmp). It gets the
# model folder as $1, for example /mnt/sda1/_update_rodin.
#
# What it does NOT do, ever:
#   - write to NAND/eMMC, an mtd device, the U-Boot env (no fw_setenv),
#     karas.db (it reads a copy in /tmp) or the cartridge chip;
#   - read or copy a flash image (only the md5 of the first 256 KB of the
#     boot partitions, to tell boot loader builds apart);
#   - move a motor, heat, reboot, scan Wi-Fi or probe I2C;
#   - run a vendor script (it reads /snapshot_version.sh as text; the only
#     stock program it starts is /app/display.sh, the screen message every
#     stock update shows, and only after checking that it just draws text).
# Wi-Fi names and keys, passwords, e-mail settings, serial numbers, MAC and IP
# addresses are masked before the file is written (see mask_awk below).
#
# busybox ash safe (busybox 1.20 on the DP200); no "set -e": every command is
# wrapped so one failure never stops the rest, and slow ones get a time limit.
#
# SPDX-License-Identifier: GPL-3.0-or-later
SURVEY_VERSION=1.0

# SURVEY_ROOT: tests run this against a fake root; empty on a printer
R=${SURVEY_ROOT:-}
STICK=${1:-/mnt/sda1/_update_rodin}
if [ -z "$R" ]; then
    exec >/dev/console 2>&1
fi
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:$PATH
export PATH

# One survey at a time. Some printers' hotplug runs auto_update.sh twice for
# one stick (once for sda, once for sda1); the second copy does nothing.
LOCK=${SURVEY_TMP:-/tmp}/model_survey.lock
if ! mkdir "$LOCK" 2>/dev/null; then
    _o=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$_o" ] && kill -0 "$_o" 2>/dev/null; then
        echo "[survey] already running (pid $_o); this copy does nothing"
        exit 0
    fi
    # left over from a run that was cut off
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK/pid"

# Keep a file on the stick open until the report is written: the stock
# auto_update.sh unmounts the stick after each script it runs, and the open
# file makes that fail (busy) if another copy finishes first.
for _f in "$STICK"/unmistakable_model_survey.she; do
    [ -f "$_f" ] && exec 9< "$_f"
done

WORK=${SURVEY_TMP:-/tmp}/model_survey.$$
if ! mkdir -p "$WORK"; then
    rm -rf "$LOCK"
    echo "[survey] cannot make $WORK; nothing done"
    exit 0
fi
RAW=$WORK/raw.txt
PART=$WORK/part.txt
: > "$RAW"

log() { echo "[survey] $*"; }

# ------------------------------------------------------------- screen ----
# /app/display.sh is how every stock update writes to the screen (it starts
# /app/tinydebug with the text). Use it only if it looks like the known stock
# file: tinydebug and nothing that writes.
SCREEN=0
if [ -z "$R" ] && [ -f /app/display.sh ] && grep -q tinydebug /app/display.sh 2>/dev/null &&
   ! grep -qiE 'setenv|saveenv|nandwrite|flash_erase|ubiformat|ubiupdatevol|dd |sqlite|reboot|poweroff|halt|mtd|mmcblk|rm ' /app/display.sh 2>/dev/null; then
    SCREEN=1
fi
show() {
    log "$1 / $2 / $3"
    [ $SCREEN = 1 ] && /app/display.sh "$1" "$2" "$3" "" >/dev/null 2>&1 </dev/null
}

# ------------------------------------------------------------- helpers ----
# tmo SECONDS command args...: run a program (not a shell function) with a
# time limit; returns 124 if it had to be stopped.
# The watcher only kills if the command has not finished (no "done" flag)
# and the survey is still running ($FLAGS exists), so a late watcher can
# never hit a process that later got the same PID. Watchers are left to
# run out on their own: waiting for them would cost their whole time limit.
FLAGS=$WORK/flags
mkdir -p "$FLAGS"
_tn=0
tmo() {
    _s=$1
    shift
    _tn=$((_tn + 1))
    "$@" &
    _p=$!
    _flag=$FLAGS/$_p.$_tn
    ( sleep "$_s"; [ -d "$FLAGS" ] && [ ! -e "$_flag" ] && kill -9 "$_p" ) >/dev/null 2>&1 </dev/null &
    wait "$_p"
    _r=$?
    : > "$_flag"
    [ $_r = 137 ] && { echo "[stopped after ${_s}s]"; _r=124; }
    return $_r
}

# the program for an applet: the command itself, else "busybox NAME"
tool() {
    if command -v "$1" >/dev/null 2>&1; then
        echo "$1"
    elif command -v busybox >/dev/null 2>&1 && busybox 2>/dev/null | grep -qw "$1"; then
        echo "busybox $1"
    fi
}

sec() { printf '\n===== %s =====\n' "$*" >> "$RAW"; }

# run MAXLINES SECONDS LABEL command args...: one section of the report
run() {
    _max=$1
    _secs=$2
    _label=$3
    shift 3
    sec "$_label"
    if [ -z "$(tool "$1")" ]; then
        echo "(no $1 on this printer)" >> "$RAW"
        return 0
    fi
    _t=$(tool "$1")
    shift
    # $_t is "cmd" or "busybox cmd": split on purpose
    tmo "$_secs" $_t "$@" > "$PART" 2>&1 </dev/null
    _rc=$?
    head -n "$_max" "$PART" >> "$RAW"
    _n=$(wc -l < "$PART")
    [ "$_n" -gt "$_max" ] 2>/dev/null && echo "[... cut: $_n lines, first $_max kept]" >> "$RAW"
    [ $_rc = 0 ] || echo "[exit $_rc]" >> "$RAW"
    return 0
}

# show FILE...: whole small text files (one section each)
files() {
    for _f in "$@"; do
        [ -e "$R$_f" ] || continue
        run 3000 10 "file $_f" cat "$R$_f"
    done
}

# a file's first line, or nothing
first() { [ -r "$R$1" ] && head -n 1 "$R$1" 2>/dev/null; }

# ---------------------------------------------------------- privacy ----
# Applied to the whole report before it reaches the stick:
#   - after a word like ssid / psk / password / passkey / secret / token,
#     the rest of the line is replaced by <masked>;
#   - MAC addresses keep their first half (the maker), aa:bb:cc:xx:xx:xx;
#   - IPv4 addresses keep the first two numbers, 192.168.x.x
#     (127.x and 0.x are kept);
#   - "Serial" lines (cpuinfo, U-Boot serial#) keep the first half.
mask_awk='
function half(v) { return substr(v, 1, int(length(v) / 2)) "<masked>" }
{
    l = tolower($0)
    if (match(l, /ssid|psk|passphrase|passw|passkey|wep_key|secret|token|smtp/)) {
        $0 = substr($0, 1, RSTART + RLENGTH - 1) " <masked>"
        l = tolower($0)
    }
    if (match(l, /^serial[ \t]*:[ \t]*/) || match(l, /serial#=/)) {
        $0 = substr($0, 1, RSTART + RLENGTH - 1) half(substr($0, RSTART + RLENGTH))
    }
    h = "[0-9A-Fa-f][0-9A-Fa-f]"
    mac = h ":" h ":" h ":" h ":" h ":" h
    while (match($0, mac))
        $0 = substr($0, 1, RSTART + 8) "xx:xx:xx" substr($0, RSTART + 17)
    macd = h "-" h "-" h "-" h "-" h "-" h
    while (match($0, macd))
        $0 = substr($0, 1, RSTART + 8) "xx-xx-xx" substr($0, RSTART + 17)
    out = ""
    rest = $0
    while (match(rest, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
        ip = substr(rest, RSTART, RLENGTH)
        split(ip, o, ".")
        pre = substr(rest, 1, RSTART - 1)
        if (o[1] == "127" || o[1] == "0" || substr(pre, length(pre)) ~ /[0-9.]/)
            out = out pre ip
        else
            out = out pre o[1] "." o[2] ".x.x"
        rest = substr(rest, RSTART + RLENGTH)
    }
    print out rest
}'

# karas.db rows (sqlite3 -line: "  Column = value"): private columns are
# masked by name; serial numbers keep their first half; empty stays empty,
# so we still see whether a setting is used.
karas_awk='
{
    i = index($0, " = ")
    if (!i) { print; next }
    col = $0; sub(/^ +/, "", col); col = substr(col, 1, index(col, " = ") - 1)
    val = substr($0, i + 3)
    c = tolower(col)
    if (c ~ /serial/) {
        print substr($0, 1, i + 2) substr(val, 1, int(length(val) / 2)) (val == "" ? "" : "<masked>")
    } else if (c ~ /password|passwd|passkey|passphrase|pw$|pw[0-9_]|key|ssid|(^|_)mac($|_)|macaddr|macfilter|mail|smtp|login|userid|user_id|token|addr|server|url|file_list|location|account|phone|^ip$|_ip$|^ip_|ipaddr|gateway|dns|^desc$|filename|logfile|screenshot/) {
        print substr($0, 1, i + 2) (val == "" ? "" : "<masked>")
    } else print
}'

# ------------------------------------------------------------- start ----
show "Model survey" "Reading printer info" "Do not remove the stick"
log "version $SURVEY_VERSION, stick $STICK"

# --- identity
FW=
for _f in /snapshot_version.sh /app/snapshot_version.sh; do
    [ -r "$R$_f" ] || continue
    # text only, never run it (its first line writes the U-Boot env)
    FW=$(awk -F"[\"']" '/echo/ && $2 ~ /_[0-9]/ { print $2; exit }' "$R$_f" 2>/dev/null)
    [ -n "$FW" ] && break
done
SUB=$(sed -n 's/.*RODIN_SUB=["'\'']*\([^"'\'' ]*\).*/\1/p' "$R/etc/export_rodin_sub.sh" 2>/dev/null | head -n 1)
BOARD=$(first /sys/kernel/board_name)

DB=
for _f in /app/nvram/karas.db /data/karas.db /userdata/karas.db /app/karas.db; do
    [ -f "$R$_f" ] && { DB=$_f; break; }
done
SQL=$(tool sqlite3)
DBC=$WORK/karas_copy.db
TLI=
MODEL=
SERIAL=
if [ -n "$DB" ] && [ -n "$SQL" ]; then
    # query a copy: the printer's own database is never opened
    cp "$R$DB" "$DBC" 2>/dev/null
    TLI=$(tmo 10 $SQL "$DBC" 'select MachineTLI from INST_MACHINE limit 1' 2>/dev/null)
    MODEL=$(tmo 10 $SQL "$DBC" 'select ModelName from INST_MACHINE limit 1' 2>/dev/null)
    SERIAL=$(tmo 10 $SQL "$DBC" 'select MachineSerialNo from INST_MACHINE limit 1' 2>/dev/null)
    TLI=$(echo "$TLI" | tr -d '\r' | head -n 1)
    MODEL=$(echo "$MODEL" | tr -d '\r' | head -n 1)
    SERIAL=$(echo "$SERIAL" | tr -d '\r' | head -n 1)
fi
MAC=
for _n in eth0 mlan0 wlan0; do
    MAC=$(first /sys/class/net/$_n/address)
    [ -n "$MAC" ] && break
done
# a short id to tell reports from one printer apart (not reversible)
PID=$(printf '%s|%s' "$SERIAL" "$MAC" | md5sum 2>/dev/null | cut -c1-8)

sec "survey"
{
    echo "survey version: $SURVEY_VERSION"
    echo "date (printer clock): $(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"
    echo "firmware: ${FW:-unknown}"
    echo "RODIN_SUB: ${SUB:-unknown}"
    echo "board_name: ${BOARD:-none}"
    echo "TLI: ${TLI:-unknown}"
    echo "model name: ${MODEL:-unknown}"
    echo "printer id (md5 of serial+MAC, 8 chars): $PID"
    echo "stick folder: $STICK"
    echo "uname: $(uname -srvm 2>/dev/null)"
    echo "uptime: $(cat "$R/proc/uptime" 2>/dev/null)"
} >> "$RAW"

# --- firmware text and versions
for _f in /snapshot_version.sh /snapshot_version.sh~ /app/snapshot_version.sh; do
    [ -r "$R$_f" ] || continue
    sec "$_f (read as text, not run)"
    head -n 40 "$R$_f" >> "$RAW" 2>&1
done
files /etc/export_rodin_sub.sh /etc/os-release /etc/issue /etc/version /etc/fw_env.config
sec "auto_update.sh version"
grep 'SCRIPT_VERSION=' "$R/app/auto_update.sh" 2>&1 | head -n 1 >> "$RAW"
run 5 10 "busybox version" busybox
run 5 10 "openssl version" openssl version
[ -x "$R/usr/local/ssl/bin/openssl" ] && run 5 10 "openssl version (/usr/local/ssl)" "$R/usr/local/ssl/bin/openssl" version
run 5 10 "sqlite3 version" sqlite3 -version
run 400 10 "busybox applets" busybox --list

# --- karas.db: structure, machine info and config tables only
sec "karas.db"
echo "path: ${DB:-not found}" >> "$RAW"
if [ -n "$DB" ] && [ -n "$SQL" ] && [ -f "$DBC" ]; then
    ls -l "$R$DB" >> "$RAW" 2>&1
    run 2000 20 "karas.db schema" $SQL "$DBC" .schema
    _tabs=$(tmo 10 $SQL "$DBC" "select name from sqlite_master where type='table' order by name" 2>/dev/null)
    sec "karas.db table sizes"
    for _t in $_tabs; do
        echo "$_t $(tmo 10 $SQL "$DBC" "select count(*) from \"$_t\"" 2>&1)" >> "$RAW"
    done
    for _t in $_tabs; do
        case "$_t" in
            INST_MACHINE|CONF_*|MCONF_*)
                sec "karas.db $_t (private columns masked)"
                tmo 20 $SQL -line "$DBC" "select * from \"$_t\"" 2>&1 | awk "$karas_awk" | head -n 3000 >> "$RAW"
                ;;
        esac
    done
else
    echo "(no karas.db or no sqlite3)" >> "$RAW"
fi
rm -f "$DBC"

# --- CPU, memory, kernel
files /proc/cpuinfo /proc/meminfo /proc/version /proc/cmdline /proc/iomem \
    /proc/interrupts /proc/devices /proc/misc /proc/modules /proc/filesystems \
    /proc/cpu/alignment /sys/kernel/board_name
sec "device tree"
if [ -d "$R/proc/device-tree" ]; then
    for _f in model compatible; do
        [ -r "$R/proc/device-tree/$_f" ] && echo "$_f: $(tr '\0' ' ' < "$R/proc/device-tree/$_f")" >> "$RAW"
    done
    run 3000 20 "device tree nodes" find "$R/proc/device-tree" -type d
    sec "device tree compatible/status values"
    find "$R/proc/device-tree" -type f 2>/dev/null | grep -E '/(compatible|status|device_type)$' |
        head -n 1500 | while read -r _f; do
            echo "${_f#$R/proc/device-tree}: $(tr '\0' ' ' < "$_f" 2>/dev/null)"
        done >> "$RAW"
else
    echo "(no /proc/device-tree)" >> "$RAW"
fi
if [ -r "$R/proc/config.gz" ]; then
    run 8000 30 "kernel config (/proc/config.gz)" zcat "$R/proc/config.gz"
fi
run 500 10 "lsmod" lsmod
run 500 10 "kernel modules on disk" find "$R/lib/modules" "$R/app" -name '*.ko'

# --- storage
files /proc/mtd /proc/partitions /proc/mounts /proc/swaps
run 100 15 "df" df -k
run 300 20 "ubinfo -a" ubinfo -a
run 200 10 "storage device nodes" ls -l "$R"/dev/mtd* "$R"/dev/mtdblock* "$R"/dev/mmcblk* "$R"/dev/ubi* "$R"/dev/sd*
sec "block devices"
for _b in "$R"/sys/block/*; do
    [ -d "$_b" ] || continue
    _d=$_b/device
    echo "$(basename "$_b") size=$(first "${_b#$R}/size") ro=$(first "${_b#$R}/ro") name=$(first "${_d#$R}/name") type=$(first "${_d#$R}/type") manfid=$(first "${_d#$R}/manfid") oemid=$(first "${_d#$R}/oemid") date=$(first "${_d#$R}/date") model=$(first "${_d#$R}/model") vendor=$(first "${_d#$R}/vendor")" >> "$RAW"
done
# boot loader identity: md5 of the first 256 KB, never the bytes
sec "boot area md5 (first 256 KB, read-only)"
for _dev in /dev/mtd0 /dev/mmcblk0boot0 /dev/mmcblk0boot1 /dev/mmcblk0p1; do
    [ -e "$R$_dev" ] || continue
    _sum=$(dd if="$R$_dev" bs=1024 count=256 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1)
    echo "$_dev $_sum" >> "$RAW"
done

# --- U-Boot environment (read with fw_printenv; never written)
run 400 15 "fw_printenv" fw_printenv

# --- serial ports
for _f in "$R"/proc/tty/driver/*; do
    [ -f "$_f" ] && files "${_f#$R}"
done
files /proc/tty/drivers
sec "who has a tty open"
for _p in "$R"/proc/[0-9]*; do
    [ -d "$_p/fd" ] || continue
    _c=$(first "${_p#$R}/comm")
    [ -n "$_c" ] || _c=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null | cut -c1-60)
    for _fd in "$_p"/fd/*; do
        _l=$(readlink "$_fd" 2>/dev/null)
        case "$_l" in
            */tty*|*/console|*/upc*|*/ttyS*) echo "$(basename "$_p") $_c -> $_l" ;;
        esac
    done
done 2>/dev/null | sort -u >> "$RAW"

# --- devices and buses
run 1500 15 "ls -l /dev" ls -l "$R/dev"
sec "/sys/class"
for _c in "$R"/sys/class/*; do
    [ -d "$_c" ] && echo "$(basename "$_c"): $(ls "$_c" 2>/dev/null | tr '\n' ' ')" >> "$RAW"
done
sec "/sys/bus devices"
for _b in "$R"/sys/bus/*; do
    [ -d "$_b/devices" ] && echo "$(basename "$_b"): $(ls "$_b/devices" 2>/dev/null | tr '\n' ' ')" >> "$RAW"
done
sec "platform drivers"
for _d in "$R"/sys/bus/platform/drivers/*; do
    [ -d "$_d" ] && echo "$(basename "$_d"): $(ls "$_d" 2>/dev/null | grep -v -e bind -e uevent -e module | tr '\n' ' ')" >> "$RAW"
done
sec "USB devices"
for _u in "$R"/sys/bus/usb/devices/*; do
    [ -r "$_u/idVendor" ] || continue
    echo "$(basename "$_u") $(first "${_u#$R}/idVendor"):$(first "${_u#$R}/idProduct") speed=$(first "${_u#$R}/speed") $(first "${_u#$R}/manufacturer") / $(first "${_u#$R}/product")" >> "$RAW"
done
run 100 15 "lsusb" lsusb
run 50 10 "I2C adapters (i2cdetect -l, lists only, no probing)" i2cdetect -l
sec "/sys/class/gpio"
ls "$R/sys/class/gpio" >> "$RAW" 2>&1
files /sys/kernel/debug/gpio

# --- GPIO input/output/direction registers, 88PA6170 only (DP200, 3DWOX 1):
# 8 banks of 32 at 0xf8040000 + 0x1000 * bank; +0 input, +4 output,
# +8 direction. Plain reads of GPIO data registers; nothing else is touched.
# Skipped on other chips, whose register map we don't know yet.
DEVMEM=$(tool devmem)
sec "GPIO registers (devmem, 88PA6170 only)"
case "$(uname -r 2>/dev/null)" in
    3.2.*) SOC6170=1 ;;
    *) SOC6170=0 ;;
esac
grep -q '"boot-logo"' "$R/proc/mtd" 2>/dev/null || SOC6170=0
if [ -n "$R" ]; then
    echo "(skipped in a test run)" >> "$RAW"
elif [ -z "$DEVMEM" ]; then
    echo "(no devmem)" >> "$RAW"
elif [ $SOC6170 = 0 ]; then
    echo "(skipped: not the 88PA6170 kernel 3.2 / NAND layout)" >> "$RAW"
else
    for _bank in 0 1 2 3 4 5 6 7; do
        _line="bank $_bank:"
        for _off in 0 4 8; do
            # 0xf8040000 + 0x1000 * bank + off, as text (ash may be 32-bit)
            _a=0xf804${_bank}00${_off}
            _line="$_line $(tmo 5 $DEVMEM "$_a" 32 2>&1)"
        done
        echo "$_line  (in out dir)" >> "$RAW"
    done
fi

# --- processes and network (addresses masked)
run 300 10 "ps" ps
run 200 10 "ifconfig -a" ifconfig -a
files /proc/net/dev /proc/net/wireless
sec "network interfaces"
for _n in "$R"/sys/class/net/*; do
    [ -d "$_n" ] && echo "$(basename "$_n") driver=$(basename "$(readlink "$_n/device/driver" 2>/dev/null)" 2>/dev/null) address=$(first "${_n#$R}/address") operstate=$(first "${_n#$R}/operstate")" >> "$RAW"
done

# --- software layout (names, sizes and md5 only; no file contents)
run 3000 20 "programs" ls -l "$R/bin" "$R/sbin" "$R/usr/bin" "$R/usr/sbin" "$R/usr/local/bin"
run 3000 20 "libraries" ls -l "$R/lib" "$R/usr/lib"
run 500 10 "/etc (names)" ls -l "$R/etc"
run 200 10 "/etc/init.d (names)" ls -l "$R/etc/init.d"
run 300 10 "/boot (names)" ls -l "$R/boot"
run 8000 60 "ls -lR /app (names only)" ls -lR "$R/app"
sec "md5 of /app programs and modules"
for _f in "$R"/app/* "$R"/boot/*.dtb "$R"/boot/uImage* "$R"/boot/zImage*; do
    [ -f "$_f" ] || continue
    case "$_f" in *.db|*.db-*|*.log|*.txt|*.cfg|*.conf|*.ini|*.json|*.xml) continue ;; esac
    _sz=$(stat -c %s "$_f" 2>/dev/null)
    [ "${_sz:-0}" -gt 33554432 ] 2>/dev/null && { echo "${_f#$R} $_sz (too big, skipped)"; continue; }
    echo "${_f#$R} $_sz $(md5sum "$_f" 2>/dev/null | cut -d' ' -f1)"
done >> "$RAW" 2>&1
sec "du -sk"
for _d in /app /usr /lib /bin /sbin /etc /boot /opt /root /home /data /userdata /systemdata /var /tmp; do
    [ -d "$R$_d" ] && tmo 60 du -sk "$R$_d" >> "$RAW" 2>&1
done

# --- kernel log last (the longest part)
run 4000 15 "dmesg" dmesg

# ------------------------------------------------------------ write ----
sec "end"
echo "survey finished: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" >> "$RAW"

_name=$(printf '%s_%s_%s' "${FW:-unknown}" "${TLI:-x}" "$(date +%Y%m%d-%H%M%S 2>/dev/null)" | tr -c 'A-Za-z0-9_.-' '_')
ROOTDIR=$(dirname "$STICK")
OUT=$ROOTDIR/survey_$_name.txt
# Write only onto the stick itself: if it was unmounted meanwhile,
# /mnt/sda1 would be a plain folder on the printer's own flash.
STICK_OK=1
if [ -z "$R" ] && ! awk -v d="$ROOTDIR" '$2 == d { f = 1 } END { exit !f }' /proc/mounts 2>/dev/null; then
    STICK_OK=0
    OUT=
fi
if [ $STICK_OK = 1 ] && ! ( : > "$OUT" ) 2>/dev/null; then
    OUT=$STICK/survey_$_name.txt
fi
# print files people uploaded (in the /app listing): hide the name
[ $STICK_OK = 1 ] && awk "$mask_awk" "$RAW" |
    sed -e 's#[^ /]*\.[gG][cC][oO][dD][eE]$#<print file>#' -e 's#[^ /]*\.[gG][cC][oO]$#<print file>#' \
        -e 's#[^ /]*\.3[dD][wW]$#<print file>#' -e 's#[^ /]*\.[sS][tT][lL]$#<print file>#' > "$OUT" 2>/dev/null
sync
# let the stock update unmount the stick now
exec 9<&-
if [ $STICK_OK = 0 ]; then
    log "the stick is no longer mounted at $ROOTDIR; nothing written"
    show "Model survey" "The stick was unmounted" "Plug it in again to retry"
elif [ -s "$OUT" ]; then
    _kb=$(( $(wc -c < "$OUT") / 1024 ))
    log "wrote $OUT ($_kb KB)"
    show "Model survey done" "$(basename "$OUT")" "Remove the stick, then power off and on"
else
    log "could not write the report to the stick"
    show "Model survey" "Could not write to the stick" "Nothing on the printer was changed"
fi
rm -rf "$WORK" "$LOCK" 2>/dev/null
sleep 3
# always 0: the stock auto_update.sh stops on a failed script
exit 0
