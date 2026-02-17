# idle-shutdown

[English](README.md) | [繁體中文](README.zh-TW.md)

Idle-based VM auto-shutdown helper for Linux VMs, focused on SSH and RDP usage.

This project ships as a Debian package (`Architecture: all`) and includes:
- `idle-shutdown.sh` decision engine
- systemd timer/service units
- SSH/RDP activity marker helpers
- packaging, smoke tests, and release automation

## What It Does

`idle-shutdown` decides whether to shut down a VM based on idle policy:
- `connections` mode: any established SSH/RDP TCP connection is treated as active.
- `activity` mode: shutdown is based on user activity markers, even if a session stays connected.

It is designed for cloud VM workflows where we want automatic cost control without killing actively used sessions.

## How It Works

Main runtime components:
- `idle-shutdown.timer`: periodically runs `idle-shutdown.service`.
- `idle-shutdown.service`: executes `/usr/local/sbin/idle-shutdown.sh`.
- `idle-rdp-disconnect-watch.service`: clears stale RDP markers on disconnect.
- `idle-ssh-disconnect-watch.service`: clears stale SSH markers on disconnect.
- `/etc/profile.d/idle-terminal-activity.sh`: updates SSH marker mtime from shell activity.
- `/usr/local/sbin/idle-rdp-input-watch.sh`: updates RDP marker mtime from desktop input.

Second-boot gate:
- Script execution is intentionally gated by `PROVISIONING_DONE_BOOT_ID_PATH`.
- If that marker file is missing, the script exits without shutdown logic.
- This prevents shutdown during first-boot provisioning flows.

## SSH/RDP Input Hooks

`idle-shutdown` uses marker files to represent recent user input activity.

SSH keystroke hook:
- File: `/etc/profile.d/idle-terminal-activity.sh`
- Trigger model: injected `PROMPT_COMMAND` in interactive SSH `pts/*` shells.
- Behavior: touches marker mtime at each prompt cycle (typically after Enter), not on every raw key event.
- Marker path:
  - preferred: `/run/user/<uid>/idle-terminal-activity-ssh-<tty_tag>`
  - fallback: `/tmp/idle-terminal-activity-<uid>-ssh-<tty_tag>`

RDP keyboard/mouse hook:
- File: `/usr/local/sbin/idle-rdp-input-watch.sh` (started by desktop autostart file).
- Trigger model: `xinput test-xi2 --root` event stream in GUI session.
- Behavior: touches marker mtime on XI2 key/button/motion events.
- Marker path:
  - preferred: `/run/user/<uid>/idle-rdp-input-activity`
  - fallback: `/tmp/idle-rdp-input-activity-<uid>`

Marker cleanup hooks:
- SSH disconnect watcher (`idle-ssh-disconnect-watch.service`) tails journal/auth logs and removes stale SSH markers for closed sessions.
- RDP disconnect watcher (`idle-rdp-disconnect-watch.service`) tails `xrdp-sesman` logs and removes user/all RDP markers when TCP disconnect is confirmed.

How decision uses hooks (`IDLE_MODE=activity`):
- `idle-shutdown.sh` reads marker mtimes and computes idle seconds from `now - mtime`.
- Most recent activity across valid markers is treated as current user activity.
- If markers are missing/stale past `IDLE_MINUTES`, shutdown is triggered.

## Repository Layout

- `idle-shutdown.sh`: main decision logic.
- `systemd/`: source of systemd unit files.
- `assets/`: packaged runtime config/scripts (default env, profile/autostart/watch scripts).
- `debian/`: Debian packaging metadata.
- `test/idle-shutdown-smoke.sh`: functional smoke test with mocked commands.
- `export-idle-shutdown-assets.py`: exports local assets into packaging staging tree.
- `.github/workflows/deb-package.yml`: package CI workflow.

## Runtime Configuration

Default config file: `assets/etc/default/idle-shutdown` (installed to `/etc/default/idle-shutdown`).

Key variables:
- `IDLE_SHUTDOWN_ENABLED` (default `1`): global on/off switch.
- `IDLE_MINUTES` (default `15` in config; script fallback `20`): idle threshold.
- `IDLE_MODE` (`connections` or `activity`, default `activity` in config).
- `BOOT_GRACE_MINUTES` (default `0` in config): additional uptime grace period.
- `STATUS_PERIOD_MINUTES` (default `3`): periodic status log cadence.
- `RDP_TCP_PORT` (default `3389`): RDP port checked for established sessions.
- `RDP_DISCONNECT_GRACE_SECONDS` (default `90`): stale RDP marker cleanup grace.
- `XRDP_SESMAN_LOG_PATH`, `SSH_LOG_UNIT`, `SSH_AUTH_LOG_PATH`: watcher log sources.
- `IDLE_SHUTDOWN_STATE_DIR` (script fallback `/var/lib/idle-shutdown`).
- `PROVISIONING_DONE_BOOT_ID_PATH` (script fallback `$IDLE_SHUTDOWN_STATE_DIR/provisioning_done_boot_id`).

## Local Development

Prerequisites (Ubuntu/Debian):

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential debhelper devscripts dh-python dpkg-dev python3
```

Run checks:

```bash
make check
```

Run functional smoke only:

```bash
make idle-smoke
```

Build package:

```bash
make DEB_ARCH=all deb-build
```

Build + package smoke test:

```bash
make DEB_ARCH=all deb-smoke
```

Build artifacts are moved to `release/`.

## Release Flow

Run full local release flow:

```bash
make release
```

`make release` does:
1. resolve/reuse/create release tag (`idle-shutdown-v*`)
2. run `make check`
3. run `make DEB_ARCH=all deb-smoke`
4. create/update annotated tag metadata

Tag and version behavior:
- Debian package version is synced from release tag as `<tag-version>-1`.
- If a tag exists on a different commit, tag auto-increments.

## Install On Target VM

Install from a built or downloaded package:

```bash
sudo apt-get install -y ./idle-shutdown_<version>_all.deb
```

Post-install scripts enable/start:
- `idle-shutdown.timer`
- `idle-rdp-disconnect-watch.service`
- `idle-ssh-disconnect-watch.service`

Verify:

```bash
systemctl status idle-shutdown.timer
systemctl status idle-rdp-disconnect-watch.service
systemctl status idle-ssh-disconnect-watch.service
journalctl -u idle-shutdown.service -n 100 --no-pager
```

Note for manual installs outside cloud-init:
- Ensure `PROVISIONING_DONE_BOOT_ID_PATH` exists with a value different from current `/proc/sys/kernel/random/boot_id`, or the script will keep skipping by design.

## CI/CD

`idle-shutdown` has its own GitHub Actions workflow in this repo:
- Workflow: `.github/workflows/deb-package.yml`
- Runs checks + `deb-smoke` on push/PR/manual trigger.
- Uploads `.deb/.changes/.buildinfo` as artifacts.
- On tag push (`idle-shutdown-v*`), attaches package files to GitHub Release.
