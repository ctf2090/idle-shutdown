#!/usr/bin/env bash
set -u

uid="$(id -u 2>/dev/null || true)"
case "$uid" in
  ''|*[!0-9]*) exit 0 ;;
esac

runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$uid}"
marker_primary="${runtime_dir}/idle-rdp-input-activity"
marker_fallback="/tmp/idle-rdp-input-activity-${uid}"
lock_path="${runtime_dir}/idle-rdp-input-watch.lock"

touch_marker() {
  if [ -d "$runtime_dir" ] && [ -w "$runtime_dir" ]; then
    : >"$marker_primary" 2>/dev/null || true
  else
    : >"$marker_fallback" 2>/dev/null || true
  fi
}

if [ -n "${DISPLAY:-}" ] && command -v xinput >/dev/null 2>&1; then
  mkdir -p "$runtime_dir" 2>/dev/null || true
  exec 9>"$lock_path" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    flock -n 9 || exit 0
  fi
fi

while true; do
  if [ -z "${DISPLAY:-}" ] || ! command -v xinput >/dev/null 2>&1; then
    sleep 2
    continue
  fi

  touch_marker
  xinput test-xi2 --root 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *"EVENT type 2 ("*|*"EVENT type 4 ("*|*"EVENT type 6 ("*)
        touch_marker
        ;;
    esac
  done
  sleep 1
done
