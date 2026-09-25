# Exploration: mbdeploy owns the boards, mbrelay becomes a role plugin

Status: exploration, not yet a plan. Written 2026-09-23 as input to sprint
planning. Covers both `mbdeploy` (this repo) and `mbrelay`
(`microbit-radio-relay/server`).

## The problem

Today mbdeploy and mbrelay each discover, probe and open every micro:bit on
the host independently. Run both on one machine and they compete:

- **mbrelay probes every micro:bit, not just relays.** It opens with DTR at
  the pyserial default (which resets the board) and sends a serial BREAK to
  any board that stays silent, so robots get rebooted.
- **Neither lock sees the other.** mbrelay takes an advisory `flock`
  (`exclusive=True`); mbdeploy takes none. Both can hold the tty and split
  the incoming bytes, and nobody reports "busy".
- **mbdeploy's arrival probe writes `HELLO` into a live relay session.**
- **`mbrelay flash` finishes with `rescan force=True`**, which re-probes, and
  so resets, every idle board on the host.
- **Neither daemon's flash path checks the other.** mbrelay's admin-socket
  quiesce swallows a failed `disable` after a `kick`.

## The idea

**One process owns the boards: `mbdeploy serve`.** It enumerates boards,
probes each one once on arrival (DTR and RTS low, no BREAK), keeps the
registry, holds the only per-board lock (`Board.claim_*`), and flashes.

**The announcement picks a role plugin.** The arrival probe already stores
`role` on `board.entry` before any listener exists
([server.py:842-846](../../src/mbdeploy/server.py)). If a plugin has
registered for that role, `serve` hands it the board. mbrelay registers
for `RADIOBRIDGE`.

**What is left of mbrelay is the protocol on top of an open port:**
command-plane setup, normalization, the pool, the name registry, and the
client CLI. It no longer finds, lists, probes, locks or flashes boards.

The dispatch happens when the board is **identified**, not when a client
connects. The pool ("give me any free relay") needs to know every relay on
the host before anyone connects, so the plugin must hear about boards as
they arrive and leave.

## Two levels of plugin

Separating what a relay needs *per board* from what it needs *per host*
answers the "mbdeploy already connects to the serial port, so maybe
that's enough" question.

### Level 1: per-board session hooks (applies to mbdeploy's own `_mbserial`)

`serve_serial` is claim → `open_port` → raw pump → close
([server.py:480-525](../../src/mbdeploy/server.py)). A role can wrap that
with two hooks:

- `on_acquire(lease)`: before the pump starts. For a relay this means:
  reset, `HELLO`, `!VER?`, normalize (`!MODE RAW250`, `!FRAG OFF`,
  `!ECHO OFF`, `!P 7`, `!C 0`, then verify with `?`), then send the banner
  line as a preamble.
- `on_release(lease)`: after the client goes. For a relay this means:
  reset, normalize, and `!DEFAULTS`.

Level 1 alone gives something mbrelay cannot do today: **connect to a
specific relay by name**, over mbdeploy's existing per-board service.
`mbdeploy connect zavaz --remote` would land in a freshly reset relay in
the command plane, and the next client would find it clean. mbrelay's pool
only hands out *any* free relay.

Level 1 is generic. A robot role could add hooks too, for example a
reset-on-connect.

### Level 2: host-wide services

Some relay features span boards, so they cannot live in a per-board
session:

- **The pool port** (`_mbrelay._tcp`, 8760): allocation across all free
  relays, affinity per client IP, least-used first, and the
  `# ERROR: no relay available (...)` reject line.
- **The name registry**: `names.json`, and HTTP 8761 with
  `GET/PUT/DELETE /names/<n>`, `/names`, `/status`.
- **Telemetry**: sniffing `!C`/`!CG` to record channels, and
  channel-collision warnings.

A Level 2 plugin gets host services from `serve`: register a listener on
the shared accept loop, advertise an mDNS service, a config section, a
state directory. Its pool sessions **claim boards through the same
`Board.claim_*` path** as `_mbserial` and flash. Three consequences:

- A pool session and a raw `mbdeploy connect` to the same relay exclude
  each other, with `ERR busy` or pool-skip.
- A flash of a relay preempts a pool session exactly as it preempts a
  serial session today, with no admin-socket quiesce.
- USB departure tears the session down through the existing
  `take_occupant` path.

## Sketch of the interface

Illustrative only; names are not final.

```python
class RoleHandler:                      # entry point group: mbdeploy.roles
    roles = {"RADIOBRIDGE"}

    # Level 2 (optional)
    def start(self, host: Host) -> None: ...     # host.listen(), host.advertise(),
    def stop(self) -> None: ...                  # host.config, host.state_dir, host.log
    def board_added(self, board: BoardHandle) -> None: ...
    def board_removed(self, board: BoardHandle) -> None: ...

    # Level 1 (optional)
    def on_acquire(self, lease: Lease) -> bytes | None: ...   # returns preamble
    def on_release(self, lease: Lease) -> None: ...

    # listing (optional), see "Display" below
    def describe(self, board: BoardHandle) -> dict: ...       # firmware, state detail

class BoardHandle:
    uid, name, role, entry
    def lease(self, kind: str) -> Lease | None: ...           # None = busy

class Lease:                            # context manager; releases on exit
    serial                              # opened by mbdeploy: DTR/RTS low, flock
    announcement                        # the banner from the arrival probe
    preempted: threading.Event          # set when a flash or unplug takes the board
    def reset(self) -> None: ...        # see open question 2
```

Plugins are found through a Python entry point group (`mbdeploy.roles`), so
installing the `mbrelay` package next to `mbdeploy` in the node's venv is
what switches relay support on. The dependency reverses: today mbrelay
shells out to `mbdeploy`; afterwards mbrelay imports it.

## Where the plugin runs: options

| | In-process plugin (recommended) | Separate daemon, fd hand-off | mbrelay as a TCP client of `_mbserial` |
|---|---|---|---|
| How | Entry-point plugin loaded by `serve` | `serve` passes the open tty fd over a Unix socket (`SCM_RIGHTS`) | mbrelay connects to each relay's `_mbserial` port |
| Board lock | One lock, in one process | Split again: needs a lease/return protocol and a preempt message for flash | One lock, but mbrelay can't reset: BREAK and DTR don't cross TCP (RFC 2217 could carry them) |
| Crash isolation | Plugin bug can take down `serve` | Good | Good |
| Services on node | One | Two, coordinated | Two |
| Code change | Port mbrelay's asyncio session code to run beside a thread server | Same as left, plus the lease protocol | Rewrite mbrelay transport onto sockets; add a reset side-channel to mbdeploy |

The in-process plugin is the only option where "nothing competes" holds by
construction. The concurrency mismatch is manageable: the plugin can run
its own asyncio loop in one thread. mbrelay's `SerialChannel` already
drives a raw fd with `add_reader`, which works with the fd of a pyserial
object mbdeploy opened.

## What moves, what stays, what goes

Rough line counts from `server/src/mbrelay` (6,386 total).

**Moves to mbdeploy (or is already there):**
- Discovery and probing: `inventory.py` (410), `transport.scan_ports`, and
  `relay.probe`/`robot_version`.
- The device listing: the `devices` command, local and remote.
- Board admin: reset, disable, enable.
- Flashing: `firmware.py` (230) and `mbrelay flash`. mbdeploy's `deploy`
  already does the work.
- Port locking.

**Stays in mbrelay, as the plugin:**
- `session.py`: pool, acquire and release, sniffing. It loses its
  inventory dependency and gains `BoardHandle` and `Lease`.
- `relay.py`: `HELLO`, normalize, `!VER?`.
- `transport.SerialChannel`.
- `registry.py`, `naming.py`, and `httpapi.py` minus `/devices`.
- The client CLI: `mbrelay connect robot@host`, `names`, `discover`.
- The firmware source (`source/relay/`).

**Goes away:**
- The `mbrelay` daemon and `mbrelay.service`.
- The admin socket: most commands become mbdeploy's. Sessions and names
  could stay as plugin-contributed commands.
- The advertiser half of `mdns.py`: `host.advertise()` replaces
  `avahi-publish`. The browser half stays for the client CLI.
- The identity cache, and the `mbdeploy-registry.json` workaround.

## robot-console's contract must survive

robot-console (`league-projects/microbit/robot-console`) depends on these
four things, and on nothing else in mbrelay:

1. **An `_mbrelay._tcp` advertisement whose SRV record points at the pool
   port.** The port number is not hard-coded, only the SRV.
2. **TXT `registry=<port>` on the same host.** If this goes missing,
   moved robots get mistuned *silently*, because robot-console falls back
   to derived addresses.
3. **`GET /names/<name>`** returning `{channel:int, group:int, source}`.
4. **Reset by reconnect.** Each new connection must get a board reset into
   the command plane, answering `?` with `# channel: ...`. robot-console
   ignores the banner and `# ERROR` lines, so the preamble may change.

Keep the mDNS **instance name as the hostname** (for example `torture`).
robot-console keys its relay device row on it.

## Display features worth porting from mbrelay to `mbdeploy list`

Ranked by value:

1. **`short_uid = uid[16:24]`.** This directly fixes the open issue
   `mdns-fallback-instance-name-is-identical-for-every-microbit`:
   mbdeploy's `mb-<uid[-8:]>` is the shared DAPLink suffix; the middle
   field is per-board. It also works as a typing target.
2. **A STATE column instead of CONN**: `free`, `busy` (with what: serial,
   relay pool, flash), `no-firmware`, `gone`. For a local list with no
   daemon, **name the holder of a busy port** (`lsof` + `ps`:
   `port held by node scripts/dev.mjs (pid 56603)`), rather than today's
   generic "in use by another program".
3. **A FIRMWARE column.** Relays: `!VER?`, shown as `<0.20260913.2` when
   the board answered but predates `!VER?`. Robots: the version in their
   `id`/`VER` reply. A role plugin's `describe()` can supply this.
4. **Error notes under the table**: one `  <name>: <why>` line per row
   that needs one. Also mark provenance: say when name and role came from
   the registry rather than a live answer ("last known" vs "confirmed").
5. **Target matching** across uid, label, device name and `short_uid`,
   case-insensitive. **`[labels]` config** (uid → label) for boards with
   no firmware name. `--remote` targeting currently accepts only the exact
   instance name.
6. **`--json` on every listing, and stable exit codes**: 0 ok,
   2 usage, 4 no such device, 5 none free, 6 hardware. mbrelay's
   `errors.py` is a ready model.
7. **Remote list**: query hosts concurrently. Report a host that failed on
   stderr and still print the others; exit non-zero only if no host
   answered.

Not worth porting: mbrelay's table helper (no width handling either),
`status --watch`, and features that are documented but not implemented
(`idle_timeout_s`, `preamble = raw`, `events --follow`, serial→TCP
backpressure).

**A structural point for the remote list.** mbrelay's remote listing
asks each host over HTTP (`GET /devices`); mbdeploy reads per-board mDNS
TXT. TXT cannot show live state (busy, which session, firmware) and is
the source of the stale-role issue. Showing STATE and SESSION remotely
needs a per-host query to `serve`: a host-level service, or an `INFO`
that lists all boards.

## Open questions

1. **In-process plugin or separate daemon?** Recommendation: in-process.
   This is the decision everything else depends on.
2. **How does a lease reset a relay?** BREAK works on Linux and is fast;
   SWD reset through pyOCD works everywhere and mbdeploy already has it,
   but a subprocess call costs about a second per release. Option: BREAK
   first, SWD as the fallback.
3. **Is raw `_mbserial` still offered for relays when the plugin is
   loaded?** Suggestion: yes, with the Level 1 hooks applied. It is the
   debugging path for relay firmware, and the shared lock makes it safe.
4. **Remote listing transport**: per-board mDNS TXT as now, or a
   host-level query that can show live state?
5. **Plugin API versioning.** mbrelay would import mbdeploy, so it needs
   a declared plugin API version and a check at load.
6. **Cross-repo tracking.** The sprint lives in mbdeploy's CLASI, but half
   the work is in `microbit-radio-relay`. Track mbrelay tickets here, or
   in a paired sprint there?
7. **Fleet migration.** The relay host (`torture`) runs mbrelay alone
   today, and the farm nodes run mbdeploy alone. Afterwards every node
   runs `mbdeploy serve`; the ones with relays also have the plugin
   installed. `mbrelay.service` is retired.

## Suggested order, if this becomes a sprint

1. **mbdeploy takes an exclusive lock** (`exclusive=True`) on every open.
   This is independent and worth doing now.
2. **mbdeploy list improvements**: `short_uid`, STATE, holder name, error
   notes, `--json`, exit codes.
3. **Plugin mechanism in `serve`**: entry-point loading, `BoardHandle`,
   `Lease`, Level 1 hooks. Test with a trivial in-repo role.
4. **mbrelay Level 1 plugin**: relay acquire and release hooks on
   `_mbserial`. This is the first moment a relay works through mbdeploy.
5. **mbrelay Level 2 plugin**: pool port, registry HTTP, `_mbrelay._tcp`
   advertisement. Check against robot-console's four-point contract.
6. **Strip mbrelay**: inventory, daemon, admin socket, flash. Retire
   `mbrelay.service`, update Ansible and imaging, and update both wikis.
