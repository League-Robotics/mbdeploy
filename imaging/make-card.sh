#!/usr/bin/env bash
# Stamp a per-node copy of the golden Pi Zero image: hostname + static IP.
#
#   imaging/make-card.sh GOLDEN.img HOSTNAME IP [OUT.img]
#
# Only the FAT boot partition is touched, so this runs on macOS without root:
#   user-data       hostname
#   network-config  static address instead of DHCP (Wi-Fi credentials untouched)
#   meta-data       a fresh instance_id, so cloud-init treats the card as a new
#                   machine on first boot (new hostname, new SSH host keys)
#
# PREFIX, GATEWAY and DNS come from imaging/site.env (gitignored — this repo is
# public; the real values are on the internal wiki), or from the environment.
set -euo pipefail

if [[ $# -lt 3 ]]; then
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

SITE_ENV=${SITE_ENV:-"$(dirname "$0")/site.env"}
# shellcheck source=/dev/null
[[ -f $SITE_ENV ]] && source "$SITE_ENV"
: "${PREFIX:?set PREFIX in $SITE_ENV (see site.env.example)}"
: "${GATEWAY:?set GATEWAY in $SITE_ENV (see site.env.example)}"
: "${DNS:?set DNS in $SITE_ENV (see site.env.example)}"

GOLDEN=$1
HOST=$2
IP=$3
OUT=${4:-"$(dirname "$GOLDEN")/$HOST.img"}

[[ -f $GOLDEN ]] || { echo "no such image: $GOLDEN" >&2; exit 1; }
[[ $HOST =~ ^[a-z][a-z0-9-]{0,62}$ ]] || { echo "bad hostname: $HOST" >&2; exit 1; }
[[ $IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "bad IP: $IP" >&2; exit 1; }
[[ -e $OUT ]] && { echo "refusing to overwrite $OUT" >&2; exit 1; }

if ping -c 1 -t 2 "$IP" >/dev/null 2>&1; then
  echo "warning: $IP answers ping — is it already in use?" >&2
fi

# APFS clone when possible (instant, no extra space), plain copy otherwise.
cp -c "$GOLDEN" "$OUT" 2>/dev/null || cp "$GOLDEN" "$OUT"

DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$OUT" | awk 'NR==1 {print $1}')
MNT=$(mktemp -d /tmp/bootfs.XXXXXX)
cleanup() {
  diskutil unmount "$MNT" >/dev/null 2>&1 || true
  hdiutil detach "$DEV" >/dev/null 2>&1 || true
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

diskutil mount -mountPoint "$MNT" "${DEV}s1" >/dev/null

HOST=$HOST IP=$IP PREFIX=$PREFIX GATEWAY=$GATEWAY DNS=$DNS BOOT=$MNT python3 - <<'EOF'
import os, re, time
from pathlib import Path

boot = Path(os.environ['BOOT'])
host, ip = os.environ['HOST'], os.environ['IP']

def edit(name, pattern, replacement):
    path = boot / name
    text, n = re.subn(pattern, replacement, path.read_text(), flags=re.M)
    if n != 1:
        raise SystemExit(f"{name}: expected one match for {pattern!r}, found {n}")
    path.write_text(text)

edit('user-data', r'^hostname:.*$', f'hostname: {host}')
edit('meta-data', r'^instance_id:.*$', f'instance_id: {host}-{time.strftime("%Y%m%d%H%M%S")}')
edit('network-config', r'^(\s+)dhcp4: true$',
     lambda m: (f"{m[1]}dhcp4: false\n"
                f"{m[1]}addresses: [{ip}/{os.environ['PREFIX']}]\n"
                f"{m[1]}routes:\n"
                f"{m[1]}  - to: default\n"
                f"{m[1]}    via: {os.environ['GATEWAY']}\n"
                f"{m[1]}nameservers:\n"
                f"{m[1]}  addresses: [{os.environ['DNS']}]"))
EOF

# Keep macOS from littering the card with index files.
rm -rf "$MNT/.fseventsd" "$MNT/.Spotlight-V100"
sync

echo "Wrote $OUT  ($HOST, $IP/$PREFIX via $GATEWAY)"
echo "Flash it (replace diskN — check with: diskutil list external):"
echo "  diskutil unmountDisk /dev/diskN && sudo dd if=\"$OUT\" of=/dev/rdiskN bs=4m status=progress && sync"
