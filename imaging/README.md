# Golden SD-card images for Pi Zero nodes

Build a new `mbdeploy` node by flashing a card instead of installing one by
hand. You copy a working node's card once into a **golden image**. For each new
node you stamp a copy with its hostname and static IP, flash it, and boot.

The image is 32-bit Raspberry Pi OS (armhf), so it boots on both the Pi Zero W
and the Pi Zero 2 W. The `mbdeploy` virtualenv and its systemd service come
with it, so the daemon starts on first boot.

## How it works

Raspberry Pi Imager writes cloud-init seed files to the FAT boot partition:
`user-data` (hostname, user), `network-config` (Wi-Fi) and `meta-data`
(instance id). macOS can edit that partition directly, so per-node stamping
needs no root and no ext4 tools. Changing `instance_id` makes cloud-init treat
the card as a new machine on first boot. It then applies the hostname and the
network config again.

`prepare-golden.sh` also resets the donor so its clones don't share an identity:

| Donor state | Why it is removed or reset |
|---|---|
| `/etc/netplan/90-NM-*.yaml` | the donor's static IP; every clone would claim it |
| `/etc/machine-id` (emptied) | shared identity; an empty file also makes systemd run its first-boot units |
| SSH host keys | regenerated on first boot |
| `var/lib/cloud/*` | cloud-init state |
| `~/mbdeploy/config/devices.json` | the donor's board registry |

It then re-enables `rpi-resize.service` and `regenerate_ssh_host_keys.service`
(both disable themselves after their first run). It adds ` resize` to
`cmdline.txt`, so the initramfs grows the root partition to fill the card and
gives it a new disk ID. It shrinks the filesystem to just above its used space,
so the image fits any card.

## Requirements

- macOS with Docker (the ext4 work runs in a privileged `ubuntu:24.04` container)
- a USB SD card reader
- your admin password for `dd`, which reads and writes raw cards

## 1. Capture a donor (once)

Shut the donor node down cleanly, put its card in the reader, and find it with
`diskutil list external`. Then:

```bash
diskutil unmountDisk /dev/diskN
sudo dd if=/dev/rdiskN bs=4m status=progress > /path/to/images/donor.img
```

Keep images **outside this repo**. They contain the Wi-Fi password and a
password hash.

## 2. Make the golden image (once per donor)

```bash
imaging/prepare-golden.sh /path/to/images/donor.img /path/to/images/golden.img ~/.ssh/id_ed25519.pub
```

The third argument is optional: a file of SSH public keys to authorize for the
node's user.

## 3. Stamp and flash a node

```bash
cp imaging/site.env.example imaging/site.env   # first time; values are on the internal wiki
imaging/make-card.sh /path/to/images/golden.img NEWHOST 10.0.0.42
diskutil unmountDisk /dev/diskN
sudo dd if=/path/to/images/NEWHOST.img of=/dev/rdiskN bs=4m status=progress && sync
```

Boot it. The first boot grows the card and applies the hostname and address,
so give it a few minutes. Then confirm with `mbdeploy list --remote`. To bring
the node's `mbdeploy` up to date, run the Ansible playbook in `../ansible/`.
