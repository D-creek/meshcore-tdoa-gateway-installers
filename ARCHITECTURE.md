# MeshCore TDOA — System Architecture

How the whole stack fits together: the **gateways** at the edge, the **backend
+ frontend** in the cloud, and the **firmware-update** path that keeps the
field devices current.

> This page is an operator/contributor overview. It names the real components,
> protocols, and data flow but not the private hosting details.

## Data path at a glance

```
 LoRa mesh ──RF──►  [ USB LoRa receiver ]  ┐
                                           ├─ Gateway  (Raspberry Pi / SBC)
            GPS + 1PPS ───────────────────┘     • bridge:  USB serial → parse → publish
                                                 • portal web UI  (:8069)
                                                       │  MQTT  (per-gateway topics)
                                                       ▼
                                                [ MQTT broker ]
                                                       │
                                                       ▼
                                  [ Collector ] ──►  [ PostgreSQL + PostGIS ]
                                                       │
                                       [ Correlator + TDOA solver ]
                                                       │   position estimates
                                                       ▼
                                            [ API ]  ──►  [ Web frontend ]

   Firmware updates flow the other way:
   tagged release ──► firmware catalog ──► portal/UI job ──► gateway ──► device
```

The system locates a LoRa transmitter by **time difference of arrival (TDOA)**:
several gateways hear the same packet, each stamps its arrival against GPS time,
and the differences between those timestamps place the transmitter on a set of
hyperbolae that intersect at its position.

---

## 1. Gateways (the edge node)

A **gateway** is a small Linux host (Raspberry Pi, Orange Pi, or any
Debian-family machine — see the install page for supported hardware) running the
`meshcore-tdoa-gateway-portal` package, with one or more **USB-attached MeshCore
LoRa receivers** (RAK4631, Heltec V4, or LilyGo T-Echo).

- **Bridge** — the core service. It reads each receiver's USB serial stream,
  parses the MeshCore *TDOA-extended* frames, and publishes them to MQTT under
  per-gateway topics. The main frame types are:
  - **packet reception** — one record per LoRa packet heard, carrying the
    hardware-captured arrival timestamp (the raw TDOA signal), RSSI/SNR, and
    frequency error;
  - **gateway info / capabilities** — board, firmware, GPS chip, and the
    hardware-timestamping capability flags;
  - **GPS sky-quality** — fix type, satellite count, HDOP;
  - **host / device telemetry** — uptime, temperatures, PPS jitter.
- **Timing** — a GPS module plus its **1 PPS** pulse discipline the receiver's
  per-packet arrival timestamp to GPS time. This is the precision the whole
  system rests on: the firmware latches the LoRa radio's interrupt (DIO) edge in
  a hardware timer rather than in software, and reports how well that path is
  working via the capability flags.
- **Portal web UI** (`http://<host>:8069/`) — local, per-gateway: device
  configuration, GPS state, firmware management, and diagnostics.
- **Firmware management** — the portal flashes attached boards itself and
  **triggers flash/DFU mode for you** (esptool DTR/RTS reset on ESP32;
  1200-baud USB touch on nRF52 such as RAK4631 / T-Echo); the manual
  BOOT-hold / RESET-double-tap is only a fallback. A board the bundle
  doesn't cover — including one the portal never detected — has a one-click
  "request a build" path that messages the operator with the board details.
- **Lifecycle** — a gateway auto-registers with the cloud on first boot and
  sends a periodic heartbeat so it appears in the fleet view (reporting its
  make/model, OS, and kernel so the fleet view shows what each gateway
  physically is). Helper services handle metrics sampling and re-publishing
  mesh traffic to companion networks.

A gateway can run fully standalone for local monitoring, or join the fleet to
contribute its receptions to position solving.

---

## 2. Cloud backend + frontend

The cloud side turns raw per-gateway receptions into positions and serves them.

- **MQTT broker** — ingests every gateway's published stream.
- **Collector** — subscribes to the broker, applies per-packet validity gates
  (GPS fix, PPS lock, drift sanity), and writes receptions plus current gateway
  state into **PostgreSQL / PostGIS**.
- **Correlator** — groups receptions of the *same* packet heard by multiple
  gateways within a short (~500 ms) window. A packet needs to be heard by enough
  distinct gateways before it can be solved.
- **TDOA solver** — for each correlated group it computes the inter-gateway time
  differences (applying per-gateway calibration offsets and rejecting timing
  outliers), then runs **Foy linearised multilateration** to estimate the
  transmitter's position, along with a GDOP / uncertainty figure.
- **API** — a FastAPI service exposing gateways, packets, timing scatter, and
  position results.
- **Frontend** — a React + Mantine single-page app: fleet / observer view, a
  live map, packet and timing-scatter diagnostics, firmware management, and a
  system-info page.

Clean cross-gateway timing on co-located receivers lands within a few
microseconds of agreement; gross outliers (a small fraction, from known
firmware edge cases) are filtered before solving so they can't move a fix.

---

## 3. Firmware-update functions

Firmware for the field devices comes from two sources and reaches them through a
managed pipeline plus a manual fallback.

- **Two firmware sources**
  - the **TDOA fork** — MeshCore plus the receive / hardware-timestamping path
    that makes a node usable as a TDOA receiver;
  - **upstream vanilla MeshCore** — the unmodified official build, offered as a
    one-click revert. Both are MIT-licensed.
- **Build → release** — tagging a firmware version triggers CI to build the
  per-board / per-role environment matrix and publish the TDOA-RX images as a
  **public GitHub Release on this installers repo** (assets named per build
  environment: `.bin` / `.hex` / `.zip` / `.uf2`). Only the compiled binaries are
  published this way — the fork's source stays private.
- **Catalog** — the backend polls this repo's public Releases and imports the
  available images into a catalog, matched to each gateway's detected hardware,
  so the UI can surface an "upgrade available" badge per device. Because the
  Releases are public, each catalog entry carries an anonymous download URL, so a
  gateway fetches its firmware **with no credential** — there is no per-device
  token.
- **Operator-initiated OTA** — from the portal or frontend, an operator picks a
  release; a job is queued and delivered to the target gateway over MQTT, and the
  gateway's **firmware-update dispatcher** flashes the attached device in place.
- **Per-board flash mechanism**
  - **ESP32** (Heltec V4) — `esptool` reset + write;
  - **nRF52** — serial DFU for RAK4631 (CDC-ACM) and UF2 for LilyGo T-Echo.
  - DFU is triggered automatically (1200-baud touch / DTR-RTS toggling) — no
    physical button press on the device.
- **Capability self-test** — on boot the firmware self-tests its hardware
  timestamp-capture path. The result is reported in the capability flags and
  shown in the UI as a badge:
  - **proven** — capture path confirmed good;
  - **accumulating** — self-test still gathering samples after a (re)boot;
  - **failed** — ran but didn't meet the bound (falls back to software timing);
  - **not started** — capable, but no captures latched yet.
- **Standalone path** — the [`firmware/`](firmware/) mirror on the install site
  provides per-hardware, per-role images (with `.sha256` + `.meta.json`
  provenance) for operators who prefer to flash manually, without the portal.
- **Auto-update scope** — the package's 6-hour apt timer keeps the **portal
  software** current automatically; **device firmware** updates are always
  operator-initiated, never automatic.

### TDOA-RX firmware per board

Each receiver board has a **companion** TDOA-RX image (a dedicated receiver) and,
where built, a **repeater** TDOA-RX image (a repeater node that *also* timestamps
packets for TDOA). All are published as public Releases on this repo and offered
in the portal/UI, alongside a one-click **upstream-vanilla** revert per board.

| Board | Companion TDOA-RX | Repeater TDOA-RX |
|---|---|---|
| Heltec V4 (ESP32) | ✅ | ✅ |
| Wio-E5 (STM32WL) | ✅ | ✅ |
| RAK4631 (nRF52) | ✅ | in progress |
| LilyGo T-Echo (nRF52) | ✅ | in progress |
| Xiao S3 Wio (ESP32-S3) | ✅ | in progress |

---

## Where things live

| Layer | Repository | Visibility |
|---|---|---|
| Public distribution (apt, firmware mirror, installer) | `meshcore-tdoa-gateway-installers` (this repo) | public |
| Gateway bridge + portal | `meshcore-tdoa-gateway` | private source |
| Device firmware (TDOA fork) | `D-creek/MeshCore` | fork of upstream |
| Backend (collector, solver, API) + web frontend | backend repo | private source |
| Upstream firmware | [`meshcore-dev/MeshCore`](https://github.com/meshcore-dev/MeshCore) | public, MIT |

For install instructions and supported hardware, see the
[README](README.md).
