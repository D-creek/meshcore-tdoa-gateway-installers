#!/usr/bin/env bash
# MeshCore TDOA gateway portal — one-line installer.
#
# Usage:
#   curl -fsSL https://d-creek.github.io/meshcore-tdoa-gateway-installers/install.sh | sudo bash
#
# This script is intentionally idempotent so re-running it upgrades.
# It works on every Debian-family target (Raspberry Pi OS armv6 +
# armv7 + arm64, Armbian, plain Debian/Ubuntu, DietPi). The .deb it
# installs is Architecture: all because the runtime is pure Python —
# no cross-compile, one artefact for every Pi-class board.
#
# Modeled on Tailscale / Docker / K3s install scripts: refuse early on
# unsupported distros, print plan before sudo'ing, single confirm
# unless -y, idempotent, no half-written state on failure.
#
# Env overrides:
#   MESHCORE_GATEWAY_REPO   — alternate apt repo base URL (defaults to
#                             the public GH Pages mirror).

set -euo pipefail
trap 'echo "[meshcore-tdoa-gateway-portal] install failed at line $LINENO" >&2' ERR

# ── constants ────────────────────────────────────────────────────────

REPO_BASE="${MESHCORE_GATEWAY_REPO:-https://d-creek.github.io/meshcore-tdoa-gateway-installers/apt}"
PKG_NAME="meshcore-tdoa-gateway-portal"
KEYRING="/etc/apt/keyrings/meshcore-tdoa-gateway.gpg"
SOURCES_LIST="/etc/apt/sources.list.d/meshcore-tdoa-gateway.list"

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help)
      cat <<EOF
Usage: install.sh [-y]
Install or upgrade meshcore-tdoa-gateway-portal on this Debian-family host.
Env overrides:
  MESHCORE_GATEWAY_REPO    apt repo base URL  (default: $REPO_BASE)
EOF
      exit 0 ;;
  esac
done

# ── refuse early on unsupported environments ─────────────────────────

if [ "$(uname -s)" != "Linux" ]; then
  echo "[install] refusing: this script only supports Linux." >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "[install] refusing: apt-get not found. This script targets" >&2
  echo "          Debian-family distros (Raspberry Pi OS, Armbian," >&2
  echo "          Debian, Ubuntu, DietPi)." >&2
  exit 1
fi

ARCH=$(dpkg --print-architecture)
case "$ARCH" in
  amd64|arm64|armhf|armel) ;;
  *)
    echo "[install] unrecognised dpkg arch '$ARCH' — proceeding anyway" >&2
    echo "          (the .deb is Architecture: all so this should work)" >&2
    ;;
esac

# Python 3.9+ preflight — the portal deb depends on it. Without this
# check, the apt-install step on a Pi 1 / Pi Zero v1 running Raspberry
# Pi OS Buster (Python 3.7 default) fails halfway with a confusing
# unmet-dependency error. Catch it here with a friendly upgrade hint
# and zero half-installed state.
if command -v python3 >/dev/null 2>&1; then
  PY_VER=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
  PY_MAJ=${PY_VER%%.*}
  PY_MIN=${PY_VER#*.}
  if [ "$PY_MAJ" -lt 3 ] || { [ "$PY_MAJ" -eq 3 ] && [ "$PY_MIN" -lt 9 ]; }; then
    cat <<EOF >&2
[install] refusing: system Python is $PY_VER, the portal deb needs >= 3.9.

This is the usual symptom on Raspberry Pi OS Buster (default on Pi 1 B+
and Pi Zero v1 images). Upgrade the OS to Bullseye or Bookworm first:

  Easiest:  reflash the SD card with a current Raspberry Pi OS Lite image
            (Bookworm, recommended) using Raspberry Pi Imager, then re-run
            this installer.
  In-place: sudo apt-get update && sudo apt-get full-upgrade -y
            then change /etc/apt/sources.list from 'buster' to 'bullseye'
            (or 'bookworm'), then dist-upgrade. Slower + brittle on
            armv6; reflashing is usually faster.

Once Python is 3.9 or newer, re-run:
  curl -fsSL https://d-creek.github.io/meshcore-tdoa-gateway-installers/install.sh | sudo bash
EOF
    exit 1
  fi
else
  echo "[install] warning: python3 not found in PATH; the apt install" >&2
  echo "          step will pull it in via the deb's Depends:" >&2
fi

if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO_PRETTY="${PRETTY_NAME:-unknown distro}"
else
  DISTRO_PRETTY="unknown distro (no /etc/os-release)"
fi

# ── plan + confirm ───────────────────────────────────────────────────

cat <<EOF
[install] meshcore-tdoa-gateway-portal · about to:
  Distro:    $DISTRO_PRETTY
  Arch:      $ARCH ($(uname -m))
  Hostname:  $(hostname)
  Repo:      $REPO_BASE
  Steps:
    1. apt-get install -y curl gnupg ca-certificates python3-venv
    2. fetch + fingerprint-verify the apt signing key, add a SIGNED apt-source
    3. apt-get update
    4. apt-get install -y $PKG_NAME
    5. systemctl enable --now $PKG_NAME
EOF

if [ "$ASSUME_YES" -ne 1 ]; then
  printf "[install] proceed? [Y/n] "
  read -r reply
  case "$reply" in
    n|N|no|NO) echo "aborted."; exit 0 ;;
  esac
fi

# Must be root for apt + systemctl. Re-exec via sudo if not.
if [ "$(id -u)" -ne 0 ]; then
  echo "[install] re-running with sudo for apt + systemctl"
  exec sudo -E bash "$0" "$@" -y
fi

# ── 1. prereqs ───────────────────────────────────────────────────────

echo "[install] installing prereqs (sudo curl gnupg ca-certificates python3-venv) ..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq
# sudo is REQUIRED — the portal deb's postinst writes a sudoers.d
# drop-in so the portal can `sudo systemctl restart bridge` without a
# password. On a virgin Debian 12 standard / Bookworm container sudo
# isn't pre-installed, and the postinst aborts with "Directory
# nonexistent" on /etc/sudoers.d/.
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  sudo curl gnupg ca-certificates python3-venv apt-transport-https >/dev/null

# ── 2. apt-source ────────────────────────────────────────────────────

# Ensure the keyring directory exists (older Debians don't ship it).
install -d -m 0755 /etc/apt/keyrings

# Fetch the apt signing key (ed25519) from the public GH Pages mirror and
# install it as a dearmored .gpg keyring so apt verifies the Release file's
# signature. The fingerprint is PINNED here: a fetched key that doesn't match
# is rejected, and a failed/empty fetch is FATAL — we never fall back to
# [trusted=yes] (signature verification OFF), which an active network attacker
# could force by dropping the single key request (H-1 supply-chain fix).
EXPECTED_FPR="D63D42C7FEAE42B6"   # ed25519 apt signing key, last 16 hex of the FPR
KEY_URL="${REPO_BASE%/apt}/meshcore-tdoa-gateway-keyring.asc"
echo "[install] fetching apt signing key from $KEY_URL"
TMPKEY=$(mktemp)
trap 'rm -f "$TMPKEY"' EXIT
if ! curl -fsSL "$KEY_URL" -o "$TMPKEY" || [ ! -s "$TMPKEY" ]; then
  echo "[install] FATAL: could not fetch the apt signing key from $KEY_URL." >&2
  echo "[install] Refusing to install an UNVERIFIED apt source. Check your network" >&2
  echo "[install] (DNS/TLS to d-creek.github.io) and re-run. Aborting." >&2
  exit 1
fi
# Dearmor, then verify the key's fingerprint matches the pinned value before we
# trust it. gpg --show-keys reads the armored/dearmored key without importing.
if ! gpg --dearmor < "$TMPKEY" > "$KEYRING" 2>/dev/null; then
  echo "[install] FATAL: fetched signing key is not a valid OpenPGP key. Aborting." >&2
  rm -f "$KEYRING"; exit 1
fi
FETCHED_FPR=$(gpg --show-keys --with-colons "$KEYRING" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
case "$FETCHED_FPR" in
  *"$EXPECTED_FPR")
    : ;;  # fingerprint ends with the pinned id — good
  *)
    echo "[install] FATAL: signing key fingerprint mismatch." >&2
    echo "[install]   expected to end with: $EXPECTED_FPR" >&2
    echo "[install]   got:                  ${FETCHED_FPR:-<none>}" >&2
    echo "[install] This could indicate a tampered key. Aborting install." >&2
    rm -f "$KEYRING"; exit 1 ;;
esac
chmod 0644 "$KEYRING"
SOURCE_OPTS="signed-by=$KEYRING"
echo "[install] apt signing key verified (fpr …$EXPECTED_FPR)"

echo "[install] writing $SOURCES_LIST -> $REPO_BASE"
cat > "$SOURCES_LIST" <<EOF
# Managed by meshcore-tdoa-gateway-portal install.sh — do not edit by hand.
deb [$SOURCE_OPTS] $REPO_BASE ./
EOF

# ── 3. apt update (scoped — don't blow up on unrelated source errors) ─

echo "[install] apt-get update (this source only) ..."
# Drop any cached list for OUR mirror first so this update re-fetches a FRESH
# Packages index — otherwise apt can keep offering a stale/older version after
# the mirror was updated (observed during testing). Only touches our own lists.
rm -rf /var/lib/apt/lists/*d-creek* /var/lib/apt/lists/partial/*d-creek* 2>/dev/null || true
apt-get update \
  -o Dir::Etc::sourcelist="$SOURCES_LIST" \
  -o Dir::Etc::sourceparts="-" \
  -o APT::Get::List-Cleanup="0" 2>&1 | tail -3

# ── 4. install / upgrade the package ─────────────────────────────────

echo "[install] apt-get install $PKG_NAME ..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$PKG_NAME"

# ── 4.5. tear down the legacy local-patch hook (C-1 supply-chain fix) ─
#
# Earlier installs wired an apt DPkg::Post-Invoke hook that curl'd
# apply-patches.sh from the public mirror and root-ran it on EVERY apt
# operation — an unsigned-content fleet-wide RCE surface. All patches the
# hook carried now ship INSIDE the signed deb (the UF2-mount drop-in is
# packaged; the pydantic fix is a venv pin bump). So we no longer install
# the hook — and we actively remove it if a prior install left one, so a
# re-run of this script heals an already-hooked machine. (The deb's
# postinst does the same on upgrade, for boxes that never re-run install.sh.)

echo "[install] removing any legacy apt patch hook (no longer used) ..."
rm -f /etc/apt/apt.conf.d/99-meshcore-tdoa-patches \
      /usr/local/sbin/meshcore-tdoa-apply-patches.sh 2>/dev/null || true

# ── 4.6. Cloudflare Access service-token — REMOVED (M-1 fix) ──────────
# The gateway bootstrap endpoints (/api/gateways/{register,heartbeat,
# observer-status,action-log}) used to sit behind a CF Access gate that a
# shared service-token passed. That token was distributed in plaintext from
# the PUBLIC installers repo — a live credential in a public place. Those
# endpoints are designed-open trust-root paths (per-(IP,slug) rate-limit +
# per-Pi HTTP-Basic auth), so the CF gate added the distribution problem
# without adding real protection. The CF Access policy on those 4 paths is now
# a public bypass, so NO token is needed and none is fetched.
#
# Strip any previously-installed token from portal.env so existing gateways
# stop carrying the now-public credential (harmless if absent).
PORTAL_ENV=/etc/meshcore-tdoa-gateway-portal/portal.env
if [ -f "$PORTAL_ENV" ]; then
  sed -i '/^CF_ACCESS_CLIENT_ID=/d; /^CF_ACCESS_CLIENT_SECRET=/d' "$PORTAL_ENV" 2>/dev/null || true
fi

# ── 5. enable + start (postinst already does this; idempotent) ──────

if [ -d /run/systemd/system ]; then
  systemctl enable "$PKG_NAME" >/dev/null 2>&1 || true
  systemctl restart "$PKG_NAME" || true
fi

# ── done ─────────────────────────────────────────────────────────────

# Pick the real LAN IP for the portal URL. `hostname -I` lists every address
# (incl. docker/bridge 172.x and loopback) — prefer the address on the default
# route's interface so the printed URL actually works from the user's browser;
# fall back to the first non-loopback/non-docker address, then to hostname -I.
PORTAL_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)"
if [ -z "$PORTAL_IP" ]; then
  PORTAL_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' \
    | grep -vE '^(127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|169\.254\.)' | head -n1)"
fi
[ -z "$PORTAL_IP" ] && PORTAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "$PORTAL_IP" ] && PORTAL_IP="<this-gateway-ip>"

cat <<EOF

────────────────────────────────────────────────────────────
 ✅ Setup complete — your MeshCore TDOA gateway is installed.

 👉 NEXT STEP: open this in your web browser to configure it:

        http://$PORTAL_IP:8069/

 From there: add your LoRa device, set your GPS, and link your
 email so the gateway shows up in your account.
────────────────────────────────────────────────────────────

 Handy commands:
   logs:    journalctl -u $PKG_NAME -f
   restart: systemctl restart $PKG_NAME
   config:  /etc/meshcore-tdoa-gateway-portal/portal.env
   devices: /etc/meshcore-tdoa-gateway/devices/<slug>/
EOF
