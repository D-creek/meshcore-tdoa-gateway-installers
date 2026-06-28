# AGENTS.md — meshcore-tdoa-gateway-installers working rules for Codex

> Enforceable subset that PRs are checked against.
> Public apt repo + `install.sh` / `uninstall.sh` bootstrap (a `curl | sudo bash` flow), served from
> GitHub Pages. Safety matters: this code runs as root on strangers' machines.

## Global rules

1. **One focused change per PR** — single commit off `main`, conventional-commit title.
2. **Keep both scripts shellcheck-clean** (the CI gate — see below).
3. **Ship a real check, not a `grep`** — a test/CI step must actually fail on a regression.
4. **Never break the documented install/uninstall flow** while hardening it.
5. **Don't commit/push unless asked**; never force-push.

## CI gate (`.github/workflows/supply-chain-guard.yml`)

```bash
bash -n install.sh uninstall.sh
shellcheck --shell=bash -e SC1091,SC2086 install.sh uninstall.sh
```
`SC1091` (unfollowable `. /etc/os-release`) and `SC2086` (deliberate word-splitting of `$UNITS`/`$KC`
etc.) are the **only** allowed suppressions — don't add more; fix the finding instead.

## Shell-safety constraints

- `install.sh` runs `set -euo pipefail`. `uninstall.sh` is intentionally best-effort (`set -u` + every
  step `|| true`) so a partial system still cleans up — **preserve both models**.
- **apt key handling:** dearmor to a **temp** keyring, verify the pinned fingerprint
  (`D63D42C7FEAE42B6`) on the temp, then atomically `install -m 0644 "$TMPKEYRING" "$KEYRING"`. **Never**
  write an unverified/partial key to the live apt keyring path. Clean temps with `trap '…' EXIT`. No
  `[trusted=yes]` fallback.
- **No `rm -rf $VAR` where `$VAR` could be empty.** Quote every expansion. Only remove literal or
  pinned-name paths.
- The non-root → root **re-exec** must self-identify the script (`grep -q '<header marker>' "$0"`) and
  check `command -v sudo` before `exec sudo bash "$0"` — apply this symmetrically to **both**
  `install.sh` and `uninstall.sh`.
- `curl | sudo bash` prompts must read from **`/dev/tty`** (not stdin); honour `CONFIRM=yes`/`-y` for CI.

## Repo-content constraints

- **`apt/` and `firmware/` are generated release outputs** — don't hand-edit; they're published from
  source pipelines (the firmware mirror comes from the firmware repo's release CI).
- The package the installer installs is the **unified `meshcore-tdoa-gateway`**. The split
  `meshcore-tdoa-gateway-portal` / `…-bridge` names are **legacy compatibility only** — keep README and
  uninstall purge lists consistent with the unified name (and verify any `Replaces:`/`Provides:` claim
  against the actual `debian/control`).

## Pre-PR checklist

- [ ] `bash -n` + `shellcheck --shell=bash -e SC1091,SC2086` clean on both scripts.
- [ ] `set -euo pipefail` kept in install.sh; best-effort `|| true` model kept in uninstall.sh.
- [ ] apt key verified on a temp keyring before atomic install; temps trapped; no unverified key at live path.
- [ ] No `rm -rf` on a possibly-empty var; all expansions quoted.
- [ ] Documented install/uninstall flow still works; prompts read from `/dev/tty`.
- [ ] README / package names consistent with the unified `meshcore-tdoa-gateway`.
