# meshcore-tdoa-gateway-installers

Public distribution layer for the
[`meshcore-tdoa-gateway`](https://github.com/D-creek/meshcore-tdoa-gateway)
portal:

- apt repo under `apt/` (Pis pull updates from here hourly)
- one-line `install.sh` (Pis run it once on first boot)
- pre-built firmware bundle under `firmware/` (per-hardware, per-role)
- runtime `patches/` re-applied after every apt operation
- attribution (`NOTICE` + `LICENSE`)

The portal **source** code lives in a separate **private** repo. Only
release artefacts are mirrored here.

## One-line install

```bash
curl -fsSL https://d-creek.github.io/meshcore-tdoa-gateway-installers/install.sh | sudo bash
```

The script detects your distro + arch, registers the apt source, installs
the portal, and starts it on `http://<pi-ip>:8069/`. Re-run any time to
upgrade (idempotent).

> **Port:** the portal listens on **8069** by default (was 8080 before
> portal 0.3.72). Existing installs are migrated automatically on upgrade
> unless you set a custom `PORTAL_PORT` in
> `/etc/meshcore-tdoa-gateway-portal/portal.env`.

## Uninstall

```bash
curl -fsSL https://d-creek.github.io/meshcore-tdoa-gateway-installers/uninstall.sh | sudo bash -s -- -y
```

Reverses everything the installer + package set up — **including the apt
repo source**: stops & disables all `meshcore-*` services/timers, purges
the package, removes the apt source + keyring + apt patch hook, deletes the
`/usr/local/sbin` helper scripts (not dpkg-tracked), the udev rule +
`/dev/meshcore` symlinks + sudoers drop-in, the config/data dirs, and the
`meshcore-tdoa-portal` system user. Best-effort + idempotent. Omit `-y` for
an interactive confirmation; add `--keep-config` to keep `/etc` + `/var`
config & data and only remove the package, services, and repo.

## Supported hardware

The portal `.deb` is `Architecture: all` (pure Python) so the binary
itself runs on every dpkg arch. The constraint is Python 3.9+.

| Board                       | dpkg arch       | OS that works                       | Tested |
|-----------------------------|-----------------|-------------------------------------|--------|
| Raspberry Pi 5 / 4          | arm64           | Bookworm 64-bit                     | yes    |
| Raspberry Pi 3 (64-bit)     | arm64           | Bullseye / Bookworm 64-bit          | yes    |
| Raspberry Pi 3 (32-bit) / 2 | armhf           | Bullseye / Bookworm 32-bit          | yes    |
| Raspberry Pi Zero 2 W       | armhf / arm64   | Bullseye / Bookworm                 | yes    |
| Raspberry Pi 1 B+ / Zero v1 | armhf / armel   | **Bullseye / Bookworm** 32-bit (Buster's Python 3.7 is too old) | — |
| Orange Pi One               | armhf           | Armbian Bookworm                    | yes    |
| Orange Pi 5 / PC2           | arm64           | Armbian / Ubuntu 22.04+             | yes    |
| Plain Debian / Ubuntu amd64 | amd64           | Bullseye+ / 22.04+                  | yes    |

If you're on Buster (Pi 1 / Pi Zero v1 default image), upgrade the OS
to Bullseye or Bookworm first — the install script will refuse on
Python <3.9 with a friendly hint rather than half-install.

## Manual apt-source setup (alternative to the one-liner)

```bash
echo 'deb [trusted=yes] https://d-creek.github.io/meshcore-tdoa-gateway-installers/apt ./' \
  | sudo tee /etc/apt/sources.list.d/meshcore-tdoa-gateway.list
sudo apt-get update
sudo apt-get install meshcore-tdoa-gateway-portal
```

GPG signing of the apt `Release` file is on the roadmap; today the source
is marked `[trusted=yes]` so apt accepts the unsigned archive.

## What it installs

Two packages (installed together by the one-liner):

- **`meshcore-tdoa-gateway-portal`** — the local web UI + onboarding/registration.
- **`meshcore-tdoa-gateway-bridge`** — the core service that reads each USB LoRa
  receiver and publishes TDOA frames to the cloud over MQTT. Its source is
  private; only the built `.deb` ships here. Config is privilege-separated: the
  root-only `bridge.yaml` (0600) holds the MQTT secrets; the portal writes only a
  separate overrides file — it never reads the secrets.

Layout:

- `/opt/meshcore-tdoa-gateway-portal/` — app + Python venv (postinst-built)
- `/opt/meshcore-tdoa-gateway-bridge/` — bridge app + venv
- `/etc/meshcore-tdoa-gateway/devices/<slug>/` — per-USB-device config
- `/etc/meshcore-tdoa-gateway-portal/portal.env` — service environment
- `/lib/systemd/system/meshcore-tdoa-gateway-portal.service` — systemd unit
- system user `meshcore-tdoa-portal` (login shell `/usr/sbin/nologin`)
- systemd timer `meshcore-tdoa-auto-update.timer` (hourly cadence, runs
  `apt-get install --only-upgrade` automatically — no action needed)

After install, open `http://<host-ip>:8069/`.

## Architecture

A gateway (this package, on a Pi) bridges its USB LoRa receivers to an MQTT
stream; a cloud backend correlates the same packet heard by multiple gateways
and multilaterates the transmitter's position by time-difference-of-arrival; a
web frontend shows the fleet, map, and timing. Firmware updates flow back out
from tagged releases to each device.

See **[ARCHITECTURE.md](ARCHITECTURE.md)** for the full data path across
gateways, backend/frontend, and the firmware-update pipeline.

## Standalone firmware downloads

TDOA-RX firmware is published as **public GitHub Releases** on this repo — the
same images the gateway OTA flashes — so you can flash manually without the
portal. See the **[Releases page](../../releases)**; each release carries the
per-board images named by build environment (`.bin` / `.uf2` / `.zip` / `.hex`).

Both a **companion** and a **repeater** TDOA-RX image are provided where built
(full matrix in [ARCHITECTURE.md](ARCHITECTURE.md#tdoa-rx-firmware-per-board)):

| Board | Companion TDOA-RX | Repeater TDOA-RX |
|---|---|---|
| Heltec V4 | ✅ | ✅ |
| Wio-E5 | ✅ | ✅ |
| RAK4631 | ✅ | in progress |
| LilyGo T-Echo | ✅ | in progress |
| Xiao S3 Wio | ✅ | in progress |

Each asset has a sibling `.sha256` and `.meta.json` (hardware_id, role, source,
tag, original asset name) for provenance. Vanilla **upstream-MeshCore** images
(the one-click revert) are mirrored under [`firmware/<hw>/upstream/`](firmware/).

## How releases work

The private source repo's GitHub Actions workflow (`publish-deb.yml`,
self-hosted runner) builds a fresh deb + firmware bundle on every
`portal-vX.Y.Z` tag, then cross-pushes the artefacts here. GitHub
Pages rebuilds in ~1 minute and the new candidate is visible to apt
worldwide.

Backfilled history of every shipped release: see [`apt/`](apt/).

## Auto-update

The portal ships with a systemd timer that runs `apt-get install
--only-upgrade` hourly (with ±30 min jitter so a fleet doesn't
hammer the repo at the same minute). New releases land here, Pis pick
them up within the hour. Toggle per Pi via the portal UI under
Auto-update.

## Attribution

Built on [MeshCore](https://github.com/meshcore-dev/MeshCore), MIT-
licensed. The pre-compiled MeshCore binaries under `firmware/<hw>/upstream/`
are byte-for-byte the official upstream release artifacts. The TDOA-fork
firmware under `firmware/<hw>/<role>.<ext>` comes from the
[D-creek/MeshCore](https://github.com/D-creek/MeshCore) TDOA fork
(also MIT, inherits upstream). See `NOTICE` for the full attribution
and `LICENSE` for the MIT text.

## Issues / source code

Bug reports + PRs at the source repo:
[D-creek/meshcore-tdoa-gateway](https://github.com/D-creek/meshcore-tdoa-gateway).
