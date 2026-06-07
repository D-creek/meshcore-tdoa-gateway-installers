#!/usr/bin/env bash
# meshcore-tdoa-apply-patches.sh — re-apply our local patches.
#
# Installed by install.sh (one-shot at install time + apt
# Post-Invoke hook for every subsequent apt operation). Each
# step is idempotent — re-running this is always safe and is
# the contract apt-hooks rely on.
#
# What it fixes (all carried out-of-band of the upstream deb until
# the equivalent patches land in the deb source itself):
#
#   1. pydantic 1.10.13 + Python 3.13 incompatibility (the deb pins
#      a pre-3.13 pydantic that crashes at import on modern Pi OS).
#   2. fwota_dispatcher.py's default fw-cache path falls outside
#      the bridge service's ReadWritePaths sandbox, so OTA flashes
#      silently fail with [Errno 30] Read-only file system.
#   3. The bridge service unit doesn't whitelist the TECHOBOOT mass-
#      storage mount path or block-device access, so the T-Echo
#      UF2 OTA path fails with "Can't open blockdev".
# (Patch 4 — the portal main.py overwrite — was REMOVED 2026-06-05. It
#  downloaded a months-old patches/main.py over the deb's correct main.py on
#  EVERY install + auto-update, so users ran stale code while version.txt said
#  the new version → every newer /api route 404'd ("not found" on observer-email,
#  registration/diagnostic, auto-update, etc.). The MQTT-cache health endpoint it
#  carried is long since merged into the deb's own main.py. NEVER overwrite the
#  packaged main.py from a patch again — ship code changes in the deb instead.)
#
# These fixes are documented in the install.sh README. This script is the safety
# net for the remaining out-of-band bits while they work their way upstream.

set -e

# Only fire when the package we patch is actually installed. apt
# hooks trigger on every apt operation; refusing fast on absence
# keeps unrelated upgrades cheap.
if ! dpkg -s meshcore-tdoa-gateway-portal >/dev/null 2>&1; then
    exit 0
fi

VENV=/opt/meshcore-tdoa-gateway-portal/venv
APP_DIR=/opt/meshcore-tdoa-gateway-portal/app
BRIDGE_SRC=/opt/meshcore-tdoa-gateway-portal/bridge/src/meshcore_bridge
DROPIN_BRIDGE=/etc/systemd/system/meshcore-tdoa-gateway-bridge.service.d
DROPIN_PORTAL=/etc/systemd/system/meshcore-tdoa-gateway-portal.service.d
PATCH_BASE="${MESHCORE_TDOA_PATCH_BASE:-https://raw.githubusercontent.com/D-creek/meshcore-tdoa-gateway/main/patches}"

# 1) pydantic + matching deps for the patched main.py.
"$VENV/bin/pip" install --quiet --disable-pip-version-check \
    'pydantic>=1.10.18,<2' \
    'paho-mqtt>=2,<3' \
    'pyyaml>=6,<7'

# 2) fwota_dispatcher.py: rewrite legacy /var/lib/meshcore-bridge
# default path to the gateway-bridge-owned dir that systemd whitelists.
if grep -q '/var/lib/meshcore-bridge/fw-cache' "$BRIDGE_SRC/fwota_dispatcher.py" 2>/dev/null; then
    sed -i 's|/var/lib/meshcore-bridge/fw-cache|/var/lib/meshcore-tdoa-gateway-bridge/fw-cache|g' \
        "$BRIDGE_SRC/fwota_dispatcher.py"
    rm -rf "$BRIDGE_SRC/__pycache__"
fi
install -d -m755 /var/lib/meshcore-tdoa-gateway-bridge/fw-cache
install -d -m755 /mnt/techoboot

# 3) systemd drop-ins. Cumulative on ReadWritePaths / DeviceAllow /
# ExecStartPre, so installing them as drop-ins doesn't fight the
# packaged unit.
install -d -m755 "$DROPIN_BRIDGE" "$DROPIN_PORTAL"
curl -fsSL "$PATCH_BASE/bridge.uf2-mount.conf" -o "$DROPIN_BRIDGE/uf2-mount.conf"
curl -fsSL "$PATCH_BASE/portal.pydantic-py313.conf" -o "$DROPIN_PORTAL/pydantic-py313.conf"

# (Patch 4 removed — see header. The deb's own main.py is the source of truth;
#  a patch must NEVER overwrite it.) Self-heal: if a previously-installed hook
#  left a stale patched main.py, the deb's postinst/upgrade restores the correct
#  one — nothing to undo here.

systemctl daemon-reload || true
systemctl restart meshcore-tdoa-gateway-portal 2>/dev/null || true
systemctl restart meshcore-tdoa-gateway-bridge 2>/dev/null || true
