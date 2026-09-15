# Ansible deployment for the mbdeploy fleet

Repeatable, offline-capable deployment of `mbdeploy serve` as a systemd
service across the fleet. The targets have **no internet access**, so all
Python dependencies travel as per-architecture wheel bundles built on the
control machine (your laptop).

## One-time setup

1. Install prerequisites on the control machine: `ansible`, `uv`, and
   `sshpass` (only needed for hosts that use password auth).
2. Copy `inventory.example.yml` to `inventory.local.yml` and fill in the
   real hosts. **`inventory.local.yml` is gitignored** — this repo is
   public, and hostnames/credentials belong on the internal wiki, not here.
   The internal wiki's mbdeploy page records the real fleet.

## Deploying

```bash
./build-bundles.sh                      # rebuild bundles after any dep/code change
ansible-playbook deploy.yml             # whole fleet
ansible-playbook deploy.yml --limit zilch,nada
```

The playbook is idempotent: rerunning it on an up-to-date node changes
nothing. When `build-bundles.sh` has produced a newer mbdeploy wheel, the
role upgrades the venv and restarts the service.

## What the role does per node

1. Gives the `jtl` user passwordless sudo via
   `/etc/sudoers.d/010_jtl-nopasswd` (checked with `visudo` before it is
   installed). Change the account with `mbdeploy_sudo_user`, or set it to
   `""` to skip. The first run on a node that still asks for a sudo password
   needs `--ask-become-pass` (or `ansible_become_pass`); later runs don't.
2. Creates the standard layout: `~/mbdeploy`, `~/mbdeploy/config`,
   staging dir `~/wheels`.
3. Copies the wheel bundle matching the node's architecture
   (`aarch64` or `armv6l`).
4. Creates `~/mbdeploy/.venv` and installs everything with
   `pip --no-index --find-links` — no network needed on the target.
   On armv6l, zeroconf compiles from sdist on the node (a few minutes on
   a Pi Zero W, first install only).
5. Installs the systemd **system** unit using mbdeploy's own
   `serve --install-service --system`, then enables and starts it.
6. Verifies the daemon is active.

A missing `devices.json` is fine — the daemon starts with an empty registry
and learns boards as they are plugged in.

## Notes

- Architectures are auto-detected (`ansible_architecture`); a node with no
  matching bundle under `bundles/` fails fast with a clear message.
- `bundles/` is a build artifact and gitignored; rebuild it any time with
  `./build-bundles.sh`.
- Don't use `--token` here: the remote clients don't send AUTH yet (see the
  known-gaps list in `docs/wiki/start-here.md`).
