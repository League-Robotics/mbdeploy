#!/usr/bin/env bash
# Turn a raw copy of a working Pi Zero card into a golden image.
#
#   imaging/prepare-golden.sh DONOR.img GOLDEN.img [AUTHORIZED_KEYS_FILE]
#
# DONOR.img is never modified. The golden image is scrubbed of everything that
# identifies the donor, shrunk to just above its used space, and primed so the
# first boot of every clone behaves like a fresh Raspberry Pi OS install:
#   - ' resize' on cmdline.txt: the initramfs grows partition 2 to fill the card
#     and gives the disk a new random ID
#   - empty /etc/machine-id: systemd's first-boot units run again (filesystem
#     growth, new SSH host keys)
# Stamp per-node copies with make-card.sh.
#
# Needs Docker (for ext4 work); runs as a normal user on macOS.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

DONOR=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
GOLDEN=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
KEYS=${3:-}
MARGIN_MB=${MARGIN_MB:-256}

[[ -f $DONOR ]] || { echo "no such image: $DONOR" >&2; exit 1; }
[[ -e $GOLDEN ]] && { echo "refusing to overwrite $GOLDEN" >&2; exit 1; }
[[ -z $KEYS || -f $KEYS ]] || { echo "no such keys file: $KEYS" >&2; exit 1; }
[[ $(dirname "$DONOR") == "$(dirname "$GOLDEN")" ]] || {
  echo "keep DONOR and GOLDEN in the same directory (it is shared into Docker)" >&2; exit 1; }

echo "==> Copying donor"
cp -c "$DONOR" "$GOLDEN" 2>/dev/null || cp "$DONOR" "$GOLDEN"

# MBR partition table: entry N at 446 + 16*(N-1); start LBA at +8, sectors at +12.
read -r P2_START P2_SECTORS < <(python3 - "$GOLDEN" <<'EOF'
import struct, sys
mbr = open(sys.argv[1], 'rb').read(512)
assert mbr[510:512] == b'\x55\xaa', 'no MBR signature'
ptype = mbr[446 + 16 + 4]
start, sectors = struct.unpack_from('<II', mbr, 446 + 16 + 8)
assert ptype == 0x83, f'partition 2 is type {ptype:#x}, expected Linux (0x83)'
print(start, sectors)
EOF
)
echo "    root partition: start sector $P2_START, $P2_SECTORS sectors"

echo "==> Scrubbing and shrinking the root filesystem (Docker)"
NEW_BYTES=$(docker run --rm --privileged --platform linux/amd64 \
  -v "$(dirname "$GOLDEN")":/work ubuntu:24.04 bash -s \
  "/work/$(basename "$GOLDEN")" "$((P2_START * 512))" "$((P2_SECTORS * 512))" "$MARGIN_MB" <<'EOF'
set -euo pipefail
IMG=$1 OFFSET=$2 SIZE=$3 MARGIN_MB=$4
LOOP=$(losetup -f --show -o "$OFFSET" --sizelimit "$SIZE" "$IMG")
trap 'umount /mnt 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true' EXIT
e2fsck -fy "$LOOP" >&2 || [ $? -le 1 ]
mount "$LOOP" /mnt
cd /mnt

# Donor identity and state.
rm -f  etc/netplan/90-NM-*.yaml etc/netplan/50-cloud-init.yaml
rm -f  etc/NetworkManager/system-connections/*
rm -f  var/lib/NetworkManager/*.lease var/lib/NetworkManager/timestamps
: > etc/machine-id
[ -L var/lib/dbus/machine-id ] || rm -f var/lib/dbus/machine-id
rm -f  etc/ssh/ssh_host_*
rm -rf var/lib/cloud/*
rm -f  var/lib/systemd/random-seed
rm -f  home/jtl/mbdeploy/config/devices.json
rm -f  home/jtl/.bash_history root/.bash_history
rm -rf var/log/journal/* tmp/* var/tmp/*

# These first-boot units disable themselves after running once on the donor.
for unit in rpi-resize.service regenerate_ssh_host_keys.service; do
  if [ -f "usr/lib/systemd/system/$unit" ]; then
    mkdir -p etc/systemd/system/sysinit.target.wants
    ln -sfn "/usr/lib/systemd/system/$unit" "etc/systemd/system/sysinit.target.wants/$unit"
  else
    echo "warning: $unit not found in image" >&2
  fi
done

cd / && umount /mnt
e2fsck -fy "$LOOP" >&2 || [ $? -le 1 ]
BLOCK=$(dumpe2fs -h "$LOOP" 2>/dev/null | awk -F: '/^Block size/ {gsub(/ /,"",$2); print $2}')
MIN=$(resize2fs -P "$LOOP" 2>/dev/null | awk -F': ' '/Estimated minimum/ {print $2}')
TARGET=$((MIN + MARGIN_MB * 1024 * 1024 / BLOCK))
resize2fs "$LOOP" "$TARGET" >&2
echo $((TARGET * BLOCK))
EOF
)
NEW_SECTORS=$(( (NEW_BYTES + 511) / 512 ))
echo "    filesystem now $((NEW_BYTES / 1024 / 1024)) MB"

echo "==> Rewriting partition table and truncating image"
python3 - "$GOLDEN" "$NEW_SECTORS" <<'EOF'
import struct, sys
path, sectors = sys.argv[1], int(sys.argv[2])
with open(path, 'r+b') as f:
    f.seek(446 + 16 + 12)
    f.write(struct.pack('<I', sectors))
EOF
truncate -s $(( (P2_START + NEW_SECTORS) * 512 )) "$GOLDEN"

echo "==> Priming the boot partition"
DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$GOLDEN" | awk 'NR==1 {print $1}')
MNT=$(mktemp -d /tmp/bootfs.XXXXXX)
cleanup() {
  diskutil unmount "$MNT" >/dev/null 2>&1 || true
  hdiutil detach "$DEV" >/dev/null 2>&1 || true
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT
diskutil mount -mountPoint "$MNT" "${DEV}s1" >/dev/null

BOOT=$MNT KEYS=$KEYS python3 - <<'EOF'
import os, re, time
from pathlib import Path

boot = Path(os.environ['BOOT'])

cmdline = boot / 'cmdline.txt'
line = cmdline.read_text().strip()
if ' resize' not in f' {line}':
    cmdline.write_text(line + ' resize\n')

def edit(name, pattern, replacement):
    path = boot / name
    text, n = re.subn(pattern, replacement, path.read_text(), flags=re.M)
    if n != 1:
        raise SystemExit(f"{name}: expected one match for {pattern!r}, found {n}")
    path.write_text(text)

# An unstamped golden card is obviously not a real node.
edit('user-data', r'^hostname:.*$', 'hostname: zero-golden')
edit('meta-data', r'^instance_id:.*$', f'instance_id: golden-{time.strftime("%Y%m%d%H%M%S")}')

keys_file = os.environ.get('KEYS')
if keys_file:
    keys = [k.strip() for k in Path(keys_file).read_text().splitlines()
            if k.strip() and not k.startswith('#')]
    block = ''.join(f'\n  - {k}' for k in keys)
    edit('user-data', r'^(  shell: .*)$', lambda m: f'{m[1]}\n  ssh_authorized_keys:{block}')
EOF

rm -rf "$MNT/.fseventsd" "$MNT/.Spotlight-V100"
sync
echo "Golden image ready: $GOLDEN ($(du -h "$GOLDEN" | cut -f1))"
