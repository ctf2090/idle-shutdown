#!/usr/bin/env bash
set -u

if [ -f /etc/default/idle-shutdown ]; then
  # shellcheck disable=SC1091
  . /etc/default/idle-shutdown
fi

: "${SSH_TTY_AUDIT_ENABLED:=1}"
: "${SSH_TTY_AUDIT_LOG_PATH:=/var/log/audit/audit.log}"
: "${SSH_TTY_AUDIT_MIN_TOUCH_INTERVAL_SEC:=1}"
case "$SSH_TTY_AUDIT_MIN_TOUCH_INTERVAL_SEC" in
  ''|*[!0-9]*) SSH_TTY_AUDIT_MIN_TOUCH_INTERVAL_SEC=1 ;;
esac

is_enabled() {
  local raw="$1"
  local v=""
  v="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    0|false|no|off|disabled) return 1 ;;
    *) return 0 ;;
  esac
}

if ! is_enabled "$SSH_TTY_AUDIT_ENABLED"; then
  exit 0
fi

lock_path=/run/idle-ssh-tty-audit-watch.lock
mkdir -p /run 2>/dev/null || true
exec 9>"$lock_path" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || exit 0
fi

log() {
  printf 'idle-ssh-tty-audit-watch: %s\n' "$*"
}

normalize_tty() {
  local raw="$1"
  case "$raw" in
    /dev/pts/*) printf '%s\n' "${raw#/dev/}" ;;
    pts/*) printf '%s\n' "$raw" ;;
    pts[0-9]*) printf 'pts/%s\n' "${raw#pts}" ;;
    *) printf '%s\n' "" ;;
  esac
}

resolve_uid() {
  local ses="$1"
  local tty="$2"
  local uid=""

  case "$ses" in
    ''|*[!0-9]*) ;;
    *)
      if command -v loginctl >/dev/null 2>&1; then
        uid="$(loginctl show-session "$ses" -p User --value 2>/dev/null || true)"
        case "$uid" in ''|*[!0-9]*) uid="" ;; esac
      fi
      ;;
  esac

  if [ -z "$uid" ] && [ -n "$tty" ]; then
    uid="$(
      ps -eo uid=,tty= 2>/dev/null \
        | awk -v tty="$tty" '$2 == tty && $1 ~ /^[0-9]+$/ { print $1; exit }'
    )"
    case "$uid" in ''|*[!0-9]*) uid="" ;; esac
  fi

  printf '%s\n' "$uid"
}

touch_marker() {
  local uid="$1"
  local tty="$2"
  local tty_tag=""
  local marker=""

  tty_tag="$(printf '%s' "$tty" | tr '/[:space:]' '__')"
  if [ -d "/run/user/$uid" ] && [ -w "/run/user/$uid" ]; then
    marker="/run/user/$uid/idle-terminal-activity-ssh-${tty_tag}"
  else
    marker="/tmp/idle-terminal-activity-${uid}-ssh-${tty_tag}"
  fi

  : >"$marker" 2>/dev/null || true
}

declare -A last_touch_epoch

handle_line() {
  local line="$1"
  local tty_raw=""
  local tty=""
  local ses=""
  local uid=""
  local now=0
  local key=""
  local last=0

  case "$line" in
    *"type=TTY "*|*"type=TTY msg="*) ;;
    *) return 0 ;;
  esac

  tty_raw="$(printf '%s\n' "$line" | sed -nE 's/.*[[:space:]]tty=([^[:space:]]+).*/\1/p' | head -n 1)"
  case "$tty_raw" in
    ''|'?'|'(none)') return 0 ;;
  esac
  tty="$(normalize_tty "$tty_raw")"
  [ -n "$tty" ] || return 0

  ses="$(printf '%s\n' "$line" | sed -nE 's/.*[[:space:]]ses=([0-9]+).*/\1/p' | head -n 1)"
  uid="$(resolve_uid "$ses" "$tty")"
  [ -n "$uid" ] || return 0

  now="$(date +%s)"
  key="${uid}:${tty}"
  last="${last_touch_epoch[$key]:-0}"
  if [ "$SSH_TTY_AUDIT_MIN_TOUCH_INTERVAL_SEC" -gt 0 ] && [ $((now - last)) -lt "$SSH_TTY_AUDIT_MIN_TOUCH_INTERVAL_SEC" ]; then
    return 0
  fi

  touch_marker "$uid" "$tty"
  last_touch_epoch[$key]="$now"
}

watch_audit_log() {
  tail -n 0 -F "$SSH_TTY_AUDIT_LOG_PATH" 2>/dev/null | while IFS= read -r line; do
    handle_line "$line"
  done
}

log "watching tty audit events log=$SSH_TTY_AUDIT_LOG_PATH"
while true; do
  if [ ! -f "$SSH_TTY_AUDIT_LOG_PATH" ]; then
    sleep 2
    continue
  fi
  watch_audit_log || true
  sleep 1
done
