#!/usr/bin/env bash
# meshcore-tdoa-gateway-portal — uninstaller.
#
# Reverses everything install.sh and the .deb set up, INCLUDING the apt repo
# source. Best-effort + idempotent: every step tolerates a partial install,
# so it cleans up cleanly whether the portal is fully or half-installed.
#
#   curl -fsSL https://d-creek.github.io/meshcore-tdoa-gateway-installers/uninstall.sh | sudo bash -s -- -y
#
# Flags:
#   -y, --yes      non-interactive (skip the confirmation prompt)
#   --keep-config  keep /etc + /var config & data; only remove the package,
#                  services, apt repo source, and helper scripts
set -u

UNIFIED_PKG="meshcore-tdoa-gateway"
PKG_NAME="meshcore-tdoa-gateway-portal"
# Since 0.4.0 the bridge is a SEPARATE package the portal Depends on. Purge it
# too so an uninstall doesn't leave the bridge venv/service orphaned. Purge the
# portal FIRST (it depends on the bridge), then the bridge.
BRIDGE_PKG="meshcore-tdoa-gateway-bridge"
KEYRING="/etc/apt/keyrings/meshcore-tdoa-gateway.gpg"
SOURCES_LIST="/etc/apt/sources.list.d/meshcore-tdoa-gateway.list"
APT_PATCH_HOOK="/etc/apt/apt.conf.d/99-meshcore-tdoa-patches"
SUDOERS="/etc/sudoers.d/meshcore-tdoa-gateway-portal-restart-bridge"
UDEV_RULE="/lib/udev/rules.d/99-meshcore-tdoa-stable-tty.rules"
USER_NAME="meshcore-tdoa-portal"

# /usr/local/sbin scripts are NOT dpkg-tracked (debian/rules overrides
# dh_usrlocal), so `apt purge` leaves them behind — remove explicitly.
LOCAL_SBIN_SCRIPTS="
/usr/local/sbin/meshcore-tdoa-auto-update.sh
/usr/local/sbin/meshcore-tdoa-gateway-heartbeat
/usr/local/sbin/meshcore-tdoa-gateway-register
/usr/local/sbin/meshcore-tdoa-portal-telegram-setup
/usr/local/sbin/meshcore-tdoa-udev-symlink
/usr/local/sbin/meshcore-tdoa-apply-patches.sh
"
CONFIG_DIRS="
/opt/meshcore-tdoa-gateway-portal
/opt/meshcore-tdoa-gateway-bridge
/usr/share/meshcore-tdoa-gateway-portal
/usr/share/meshcore-tdoa-gateway-bridge
/etc/meshcore-tdoa-gateway-portal
/etc/meshcore-tdoa-gateway
/var/lib/meshcore-tdoa-gateway-portal
/etc/meshcore-bridge
/var/lib/meshcore-bridge
"

ASSUME_YES=0
KEEP_CONFIG=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    --keep-config) KEEP_CONFIG=1 ;;
    *) echo "unknown arg: $arg"; echo "usage: uninstall.sh [-y] [--keep-config]"; exit 2 ;;
  esac
done

command -v apt-get >/dev/null 2>&1 || {
  echo "[uninstall] apt-get not found — this script targets Debian-family hosts."; exit 1; }

if [ "$KEEP_CONFIG" -eq 1 ]; then
  STEP6="6. (skipped, --keep-config) config + data dirs kept"
else
  STEP6="6. remove config + data dirs (/opt, /etc, /var/lib, /usr/share)"
fi
cat <<PLAN
[uninstall] meshcore-tdoa-gateway-portal — removal plan:
  1. stop + disable all meshcore-* systemd services and timers
  2. apt-get purge ${UNIFIED_PKG} plus legacy ${PKG_NAME} / ${BRIDGE_PKG}
  3. remove the apt repo source + keyring + apt patch hook   (the "repo")
  4. remove /usr/local/sbin helper scripts (not dpkg-tracked)
  5. remove the udev rule + /dev/meshcore symlinks + sudoers drop-in
  ${STEP6}
  7. remove the system user '${USER_NAME}'
  8. apt-get update + systemctl daemon-reload
PLAN

if [ "$ASSUME_YES" -ne 1 ]; then
  if [ -r /dev/tty ]; then
    printf "Proceed with removal? [y/N] "
    read -r ans </dev/tty || ans=""
  else
    echo "[uninstall] no terminal for confirmation — re-run with -y to proceed non-interactively."
    exit 1
  fi
  case "$ans" in y|Y|yes|YES) ;; *) echo "[uninstall] aborted — nothing changed."; exit 0 ;; esac
fi

# Need root for apt + systemctl. Re-exec via sudo when invoked from a file.
if [ "$(id -u)" -ne 0 ]; then
  if [ -f "$0" ]; then
    echo "[uninstall] re-running with sudo ..."
    KC=""; [ "$KEEP_CONFIG" -eq 1 ] && KC="--keep-config"
    exec sudo bash "$0" -y $KC
  fi
  echo "[uninstall] must run as root (pipe into 'sudo bash')."; exit 1
fi

echo "[uninstall] 1/8 stop + disable meshcore-* services + timers ..."
UNITS=$( { systemctl list-unit-files 2>/dev/null | awk '/^meshcore-/ {print $1}';
           systemctl list-units --all 2>/dev/null | awk '/meshcore-/ {print $1}'; } | sort -u )
for u in $UNITS; do
  systemctl stop "$u" >/dev/null 2>&1 || true
  systemctl disable "$u" >/dev/null 2>&1 || true
done

echo "[uninstall] 2/8 purge ${UNIFIED_PKG} + legacy ${PKG_NAME} + ${BRIDGE_PKG} ..."
# Purge ONLY our packages — the current unified package first, then the legacy
# split packages for older/partial installs. We deliberately do NOT run
# `apt-get autoremove`: our Depends
# (curl, python3-venv, python3-pip, stm32flash, adduser, …) are general-purpose
# packages that OTHER software on this Pi may rely on. autoremove would sweep
# them if it thinks nothing else needs them — which can break unrelated apps on
# a shared host. Removing only our own packages is the safe, surgical choice.
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "$UNIFIED_PKG" >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "$PKG_NAME" >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "$BRIDGE_PKG" >/dev/null 2>&1 || true

echo "[uninstall] 3/8 remove apt repo source + keyring + patch hook ..."
rm -f "$SOURCES_LIST" "$KEYRING" "$APT_PATCH_HOOK"

echo "[uninstall] 4/8 remove /usr/local/sbin helper scripts ..."
for f in $LOCAL_SBIN_SCRIPTS; do rm -f "$f"; done

echo "[uninstall] 5/8 remove udev rule + /dev/meshcore symlinks + sudoers ..."
rm -f "$UDEV_RULE" "$SUDOERS"
rm -rf /dev/meshcore 2>/dev/null || true
udevadm control --reload-rules >/dev/null 2>&1 || true

if [ "$KEEP_CONFIG" -eq 1 ]; then
  echo "[uninstall] 6/8 keeping config + data dirs (--keep-config)"
else
  echo "[uninstall] 6/8 remove config + data dirs ..."
  for d in $CONFIG_DIRS; do rm -rf "$d"; done
fi

echo "[uninstall] 7/8 remove system user '${USER_NAME}' ..."
if id "$USER_NAME" >/dev/null 2>&1; then
  deluser --system "$USER_NAME" >/dev/null 2>&1 || userdel "$USER_NAME" >/dev/null 2>&1 || true
fi

echo "[uninstall] 8/8 clear apt cache + update + daemon-reload ..."
# Drop apt's cached package lists + downloaded .debs so a later reinstall can't
# serve a stale Packages index / cached old .deb (we hit exactly this: apt kept
# offering an old version after the mirror was updated). `clean` removes
# downloaded archives; we also drop our mirror's cached lists so the next
# `apt-get update` re-fetches them fresh.
apt-get clean >/dev/null 2>&1 || true
rm -rf /var/lib/apt/lists/*d-creek* /var/lib/apt/lists/partial/*d-creek* 2>/dev/null || true
apt-get update -qq >/dev/null 2>&1 || true
systemctl daemon-reload >/dev/null 2>&1 || true

echo "[uninstall] done — meshcore-tdoa-gateway-portal fully removed (apt repo included)."
[ "$KEEP_CONFIG" -eq 1 ] && echo "[uninstall] config + data were preserved (--keep-config)."
exit 0
