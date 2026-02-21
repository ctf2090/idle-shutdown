#!/usr/bin/env bash
set -u

if [ -f /etc/default/idle-shutdown ]; then
  # shellcheck disable=SC1091
  . /etc/default/idle-shutdown
fi

: "${SSH_TTY_AUDIT_ENABLED:=1}"
: "${SSH_TTY_AUDIT_LOG_PASSWD:=0}"

pam_file=/etc/pam.d/sshd
marker="# idle-shutdown-tty-audit"

is_enabled() {
  local raw="$1"
  local v=""
  v="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    0|false|no|off|disabled) return 1 ;;
    *) return 0 ;;
  esac
}

if [ ! -f "$pam_file" ]; then
  exit 0
fi

line_opts="enable=* open_only"
if is_enabled "$SSH_TTY_AUDIT_LOG_PASSWD"; then
  line_opts="$line_opts log_passwd"
fi
line="session required pam_tty_audit.so $line_opts $marker"

tmp="$(mktemp)"
cleanup() { rm -f -- "$tmp" 2>/dev/null || true; }
trap cleanup EXIT

awk -v marker="$marker" '
  index($0, marker) == 0 { print }
' "$pam_file" >"$tmp"

if is_enabled "$SSH_TTY_AUDIT_ENABLED"; then
  printf '%s\n' "$line" >>"$tmp"
fi

if ! cmp -s "$tmp" "$pam_file"; then
  cat "$tmp" >"$pam_file"
fi

exit 0
