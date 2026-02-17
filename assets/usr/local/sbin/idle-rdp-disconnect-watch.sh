#!/usr/bin/env bash
set -u

if [ -f /etc/default/idle-shutdown ]; then
  # shellcheck disable=SC1091
  . /etc/default/idle-shutdown
fi

: "${XRDP_SESMAN_LOG_PATH:=/var/log/xrdp-sesman.log}"
: "${RDP_TCP_PORT:=3389}"
case "$RDP_TCP_PORT" in ''|*[!0-9]*) RDP_TCP_PORT=3389 ;; esac

lock_path=/run/idle-rdp-disconnect-watch.lock
mkdir -p /run 2>/dev/null || true
exec 9>"$lock_path" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || exit 0
fi

log() {
  printf 'idle-rdp-disconnect-watch: %s\n' "$*"
}

count_rdp_tcp() {
  local lines=""
  local count=0
  lines="$(ss -Htn state established sport = :$RDP_TCP_PORT 2>/dev/null || true)"
  count="$(printf '%s\n' "$lines" | sed '/^$/d' | awk 'END{print NR}' || true)"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  printf '%s\n' "$count"
}

cleanup_markers_for_uid() {
  local uid="$1"
  local removed=0
  local marker=""
  for marker in "/run/user/$uid/idle-rdp-input-activity" "/tmp/idle-rdp-input-activity-$uid"; do
    [ -e "$marker" ] || continue
    rm -f -- "$marker" 2>/dev/null || true
    removed="$((removed + 1))"
  done
  printf '%s\n' "$removed"
}

cleanup_all_markers_if_no_tcp() {
  local tcp_count=0
  local removed=0
  local marker=""
  tcp_count="$(count_rdp_tcp)"
  if [ "$tcp_count" -gt 0 ]; then
    return 0
  fi
  for marker in /run/user/*/idle-rdp-input-activity /tmp/idle-rdp-input-activity-*; do
    [ -e "$marker" ] || continue
    rm -f -- "$marker" 2>/dev/null || true
    removed="$((removed + 1))"
  done
  if [ "$removed" -gt 0 ]; then
    log "event=disconnect cleanup=all removed=$removed reason=no_rdp_tcp port=$RDP_TCP_PORT"
  fi
}

handle_disconnect_line() {
  local line="$1"
  local user=""
  local uid=""
  local removed=0

  user="$(printf '%s\n' "$line" | sed -nE 's/.*username[[:space:]]+([^,[:space:]]+).*/\1/p' | head -n 1)"
  if [ -n "$user" ]; then
    uid="$(id -u "$user" 2>/dev/null || true)"
    case "$uid" in
      ''|*[!0-9]*) uid="" ;;
    esac
  fi

  if [ -n "$uid" ]; then
    removed="$(cleanup_markers_for_uid "$uid")"
    log "event=disconnect user=$user uid=$uid removed=$removed"
    if [ "$(count_rdp_tcp)" -eq 0 ]; then
      cleanup_all_markers_if_no_tcp
    fi
    return 0
  fi

  cleanup_all_markers_if_no_tcp
}

log "watching xrdp disconnect events log=$XRDP_SESMAN_LOG_PATH port=$RDP_TCP_PORT"
while true; do
  if [ ! -f "$XRDP_SESMAN_LOG_PATH" ]; then
    sleep 2
    continue
  fi

  tail -n 0 -F "$XRDP_SESMAN_LOG_PATH" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *"terminated session"*|*"connection problem"*|*"Closed socket"*|*"closed socket"*)
        handle_disconnect_line "$line"
        ;;
      *)
        ;;
    esac
  done
  sleep 1
done
