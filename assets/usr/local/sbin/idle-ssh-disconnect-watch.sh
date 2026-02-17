#!/usr/bin/env bash
set -u

if [ -f /etc/default/idle-shutdown ]; then
  # shellcheck disable=SC1091
  . /etc/default/idle-shutdown
fi

: "${SSH_LOG_UNIT:=ssh}"
: "${SSH_AUTH_LOG_PATH:=/var/log/auth.log}"

lock_path=/run/idle-ssh-disconnect-watch.lock
mkdir -p /run 2>/dev/null || true
exec 9>"$lock_path" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || exit 0
fi

log() {
  printf 'idle-ssh-disconnect-watch: %s\n' "$*"
}

gather_active_ssh_keys() {
  local keys=$'\n'
  while IFS='|' read -r uid tty; do
    case "$uid" in ''|*[!0-9]*) continue ;; esac
    case "$tty" in pts/*) ;; *) continue ;; esac
    tty_tag="$(printf '%s' "$tty" | tr '/[:space:]' '__')"
    keys="${keys}${uid}:${tty_tag}"$'\n'
  done < <(ps -eo uid=,tty= 2>/dev/null | awk '$2 ~ /^pts\// {print $1 "|" $2}' | LC_ALL=C sort -u || true)
  printf '%s' "$keys"
}

cleanup_stale_ssh_markers() {
  local active_keys=""
  local marker=""
  local marker_uid=""
  local marker_tty_tag=""
  local marker_key=""
  local removed=0
  active_keys="$(gather_active_ssh_keys)"
  for marker in /run/user/*/idle-terminal-activity-ssh-* /tmp/idle-terminal-activity-*-ssh-*; do
    [ -e "$marker" ] || continue
    marker_uid=""
    marker_tty_tag=""
    case "$marker" in
      /run/user/*/idle-terminal-activity-ssh-*)
        marker_uid="${marker#/run/user/}"
        marker_uid="${marker_uid%%/*}"
        marker_tty_tag="${marker##*/idle-terminal-activity-ssh-}"
        ;;
      /tmp/idle-terminal-activity-*-ssh-*)
        marker_uid="$(printf '%s\n' "$marker" | sed -nE 's#^/tmp/idle-terminal-activity-([0-9]+)-ssh-.*#\1#p')"
        marker_tty_tag="$(printf '%s\n' "$marker" | sed -nE 's#^/tmp/idle-terminal-activity-[0-9]+-ssh-(.*)#\1#p')"
        ;;
      *)
        ;;
    esac
    case "$marker_uid" in ''|*[!0-9]*) continue ;; esac
    [ -n "$marker_tty_tag" ] || continue
    marker_key="${marker_uid}:${marker_tty_tag}"
    case "$active_keys" in
      *$'\n'"$marker_key"$'\n'*) ;;
      *)
        rm -f -- "$marker" 2>/dev/null || true
        removed="$((removed + 1))"
        ;;
    esac
  done
  if [ "$removed" -gt 0 ]; then
    log "event=disconnect cleanup=stale_markers removed=$removed"
  fi
}

should_handle_line() {
  case "$1" in
    *"Disconnected from "*|*"Connection closed by "*|*"session closed for user "*|*"pam_unix(sshd:session): session closed for user "*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

watch_journal() {
  journalctl -f -n 0 -u "$SSH_LOG_UNIT" -o cat 2>/dev/null | while IFS= read -r line; do
    should_handle_line "$line" || continue
    cleanup_stale_ssh_markers
  done
}

watch_auth_log() {
  tail -n 0 -F "$SSH_AUTH_LOG_PATH" 2>/dev/null | while IFS= read -r line; do
    should_handle_line "$line" || continue
    cleanup_stale_ssh_markers
  done
}

log "watching ssh disconnect events unit=$SSH_LOG_UNIT auth_log=$SSH_AUTH_LOG_PATH"
while true; do
  if command -v journalctl >/dev/null 2>&1; then
    if watch_journal; then
      sleep 1
      continue
    fi
  fi
  if [ -f "$SSH_AUTH_LOG_PATH" ]; then
    watch_auth_log || true
  else
    sleep 2
  fi
done
