#!/usr/bin/env bash
set -euo pipefail

# Idle shutdown helper.
#
# This script is installed to /usr/local/sbin/idle-shutdown.sh and executed by
# idle-shutdown.service (systemd timer).
#
# Optional runtime config:
# - /etc/default/idle-shutdown (also loaded by systemd via EnvironmentFile)

if [ -f /etc/default/idle-shutdown ]; then
  # shellcheck disable=SC1091
  . /etc/default/idle-shutdown
fi

# Best-effort build provenance (git short SHA).
# cloud-init writes /etc/idle-shutdown-git-rev from instance metadata
# `idle_shutdown_git_rev`.
IDLE_SHUTDOWN_REV="unknown"
rev_file="/etc/idle-shutdown-git-rev"
if [ -f "$rev_file" ]; then
  IDLE_SHUTDOWN_REV="$(tr -d '\r\n' <"$rev_file" 2>/dev/null | awk '{print $1}' | head -c 64 || true)"
fi
if [ -z "${IDLE_SHUTDOWN_REV:-}" ] || [ "$IDLE_SHUTDOWN_REV" = "unknown" ]; then
  rev="$(curl -fsS -H 'Metadata-Flavor: Google' \
    http://metadata.google.internal/computeMetadata/v1/instance/attributes/idle_shutdown_git_rev \
    2>/dev/null || true)"
  rev="$(printf '%s' "$rev" | tr -d '\r\n' | awk '{print $1}' | head -c 64 || true)"
  if [ -n "$rev" ]; then
    IDLE_SHUTDOWN_REV="$rev"
    printf '%s\n' "$IDLE_SHUTDOWN_REV" >"$rev_file" 2>/dev/null || true
    chmod 0644 "$rev_file" 2>/dev/null || true
  fi
fi
if [ -z "${IDLE_SHUTDOWN_REV:-}" ]; then IDLE_SHUTDOWN_REV="unknown"; fi

: "${IDLE_MINUTES:=20}"
: "${BOOT_GRACE_MINUTES:=20}"
: "${IDLE_MODE:=connections}" # connections|activity
: "${STATUS_PERIOD_MINUTES:=3}"
: "${IDLE_SHUTDOWN_ENABLED:=1}"
: "${RDP_TCP_PORT:=3389}"
: "${RDP_DISCONNECT_GRACE_SECONDS:=90}"
: "${IDLE_SHUTDOWN_STATE_DIR:=/var/lib/idle-shutdown}"
state_dir="$IDLE_SHUTDOWN_STATE_DIR"
: "${PROVISIONING_DONE_BOOT_ID_PATH:=$state_dir/provisioning_done_boot_id}"

state_file="$state_dir/last_active_epoch"
phase_boot2_logged_boot_id_file="$state_dir/phase_boot2_logged_boot_id"
conn_signature_file="$state_dir/last_conn_signature"

log_status() {
  # Use systemd's configured stdout routing (journal+console).
  # Keep the "idle-shutdown:" prefix so serial-follow can filter reliably.
  # Do not also write to syslog (logger), to avoid duplicate lines in serial output.
  printf 'idle-shutdown: rev=%s %s\n' "$IDLE_SHUTDOWN_REV" "$*"
}

get_file_mtime_epoch() {
  local p="$1"
  stat -c %Y "$p" 2>/dev/null || true
}

format_conn_activity() {
  local count="$1"
  local idle_s="${2:-}"
  if [[ "$idle_s" =~ ^[0-9]+$ ]]; then
    printf '%s(%sm)' "$count" "$((idle_s / 60))"
  else
    printf '%s' "$count"
  fi
}

enabled_raw="${IDLE_SHUTDOWN_ENABLED:-1}"
enabled_normalized="$(printf '%s' "$enabled_raw" | tr '[:upper:]' '[:lower:]')"
case "$enabled_normalized" in
  0|false|no|off|disabled)
    log_status "disabled via IDLE_SHUTDOWN_ENABLED=${enabled_raw} (skip)"
    exit 0
    ;;
  *)
    ;;
esac

# Phase gate: only enable idle-shutdown on the 2nd boot after VM creation.
#
# On the 1st boot, cloud-init writes PROVISIONING_DONE_BOOT_ID_PATH at the end of provisioning,
# then performs an intentional reboot. We only proceed once the current boot_id differs from the
# marker boot_id (i.e. after that reboot has happened).
if [ ! -f "$PROVISIONING_DONE_BOOT_ID_PATH" ]; then
  log_status "phase=boot1 marker_missing path=$PROVISIONING_DONE_BOOT_ID_PATH (skip)"
  exit 0
fi
prov_boot_id="$(tr -d '\r\n[:space:]' <"$PROVISIONING_DONE_BOOT_ID_PATH" 2>/dev/null | head -c 64 || true)"
cur_boot_id="$(tr -d '\r\n[:space:]' </proc/sys/kernel/random/boot_id 2>/dev/null | head -c 64 || true)"
if [ -n "$prov_boot_id" ] && [ -n "$cur_boot_id" ] && [ "$prov_boot_id" = "$cur_boot_id" ]; then
  log_status "phase=boot1 provisioning_done_pending_reboot (skip)"
  exit 0
fi

mkdir -p "$state_dir"
chmod 0700 "$state_dir"

phase_boot2_key="$cur_boot_id"
if [ -z "$phase_boot2_key" ]; then
  phase_boot2_key="unknown-boot-id"
fi
phase_boot2_last_key=""
if [ -f "$phase_boot2_logged_boot_id_file" ]; then
  phase_boot2_last_key="$(tr -d '\r\n[:space:]' <"$phase_boot2_logged_boot_id_file" | head -c 128 || true)"
fi
if [ "$phase_boot2_last_key" != "$phase_boot2_key" ]; then
  now_boot="$(date +%s)"
  log_status "phase=boot2 enabled"
  printf '%s\n' "$phase_boot2_key" >"$phase_boot2_logged_boot_id_file" 2>/dev/null || true
  chmod 0644 "$phase_boot2_logged_boot_id_file" 2>/dev/null || true
  # New boot: reset activity baseline so pre-reboot idle time does not carry over.
  printf '%s\n' "$now_boot" >"$state_file" 2>/dev/null || true
  chmod 0644 "$state_file" 2>/dev/null || true
fi

now="$(date +%s)"
uptime_s="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"

case "$BOOT_GRACE_MINUTES" in ''|*[!0-9]*) BOOT_GRACE_MINUTES=0 ;; esac
grace_s="$((BOOT_GRACE_MINUTES * 60))"

case "$STATUS_PERIOD_MINUTES" in ''|*[!0-9]*|0) STATUS_PERIOD_MINUTES=0 ;; esac
case "$RDP_TCP_PORT" in ''|*[!0-9]*) RDP_TCP_PORT=3389 ;; esac
case "$RDP_DISCONNECT_GRACE_SECONDS" in ''|*[!0-9]*) RDP_DISCONNECT_GRACE_SECONDS=90 ;; esac

uptime_m="$((uptime_s / 60))"
if [ "$grace_s" -gt 0 ] && [ "$uptime_s" -lt "$grace_s" ]; then
  if [ "$STATUS_PERIOD_MINUTES" -gt 0 ] && [ "$uptime_m" -gt 0 ] && [ $((uptime_m % STATUS_PERIOD_MINUTES)) -eq 0 ]; then
    remain_m="$(((grace_s - uptime_s + 59) / 60))"
    log_status "boot_grace remaining=${remain_m}m grace=${BOOT_GRACE_MINUTES}m"
  fi
  exit 0
fi

# Detect inbound connections (used by "connections" mode and for status logging).
ssh_lines="$(ss -Htn state established sport = :22 2>/dev/null || true)"
rdp_lines="$(ss -Htn state established sport = :$RDP_TCP_PORT 2>/dev/null || true)"
ssh_conn="$(printf '%s\n' "$ssh_lines" | sed '/^$/d' | awk 'END{print NR}' || true)"
rdp_conn="$(printf '%s\n' "$rdp_lines" | sed '/^$/d' | awk 'END{print NR}' || true)"
case "$ssh_conn" in ''|*[!0-9]*) ssh_conn=0 ;; esac
case "$rdp_conn" in ''|*[!0-9]*) rdp_conn=0 ;; esac
total="$((ssh_conn + rdp_conn))"
has_conn=0
if [ "$total" -gt 0 ]; then
  has_conn=1
fi
ssh_conn_for_log="$ssh_conn"
rdp_conn_for_log="$rdp_conn"
total_for_log="$total"
ssh_idle_s=""
rdp_idle_s=""

if [ "$IDLE_MODE" = "connections" ]; then
  # In "connections" mode, connection state changes are treated as activity.
  prev_conn_sig=""
  if [ -f "$conn_signature_file" ]; then
    prev_conn_sig="$(tr -d '\r\n[:space:]' <"$conn_signature_file" 2>/dev/null | head -c 128 || true)"
  fi
  current_conn_sig=""
  if [ "$has_conn" -eq 1 ]; then
    current_conn_sig="$(
      {
        printf '%s\n' "$ssh_lines" | sed '/^$/d; s/^/ssh|/' || true
        printf '%s\n' "$rdp_lines" | sed '/^$/d; s/^/rdp|/' || true
      } | LC_ALL=C sort | sha256sum | awk '{print $1}' || true
    )"
  fi

  if [ "$current_conn_sig" != "$prev_conn_sig" ]; then
    if [ -n "$current_conn_sig" ]; then
      printf '%s\n' "$current_conn_sig" >"$conn_signature_file" 2>/dev/null || true
      chmod 0644 "$conn_signature_file" 2>/dev/null || true
    else
      rm -f -- "$conn_signature_file" 2>/dev/null || true
    fi
    printf '%s\n' "$now" >"$state_file" 2>/dev/null || true
    chmod 0644 "$state_file" 2>/dev/null || true
    log_status "mode=$IDLE_MODE conn_change_reset ssh=${ssh_conn_for_log} rdp=${rdp_conn} total=${total}"
    exit 0
  fi
fi

# Most recent activity (epoch seconds).
# If set, we prefer it over reading the last_active_epoch state file.
last_epoch=""

if [ "$IDLE_MODE" = "connections" ]; then
  if [ "$has_conn" -eq 1 ]; then
    log_status "mode=$IDLE_MODE active_conn ssh=${ssh_conn_for_log} rdp=${rdp_conn} total=${total}"
    last_epoch="$now"
    echo "$last_epoch" >"$state_file"
    exit 0
  fi
else
  best_idle_s=""
  ssh_marker_count=0
  rdp_marker_count=0
  update_best_idle() {
    local v="$1"
    case "$v" in ''|*[!0-9]*) return 0 ;; esac
    if [ -z "$best_idle_s" ] || [ "$v" -lt "$best_idle_s" ]; then
      best_idle_s="$v"
    fi
  }
  update_ssh_idle() {
    local v="$1"
    case "$v" in ''|*[!0-9]*) return 0 ;; esac
    if [ -z "$ssh_idle_s" ] || [ "$v" -lt "$ssh_idle_s" ]; then
      ssh_idle_s="$v"
    fi
  }
  update_rdp_idle() {
    local v="$1"
    case "$v" in ''|*[!0-9]*) return 0 ;; esac
    if [ -z "$rdp_idle_s" ] || [ "$v" -lt "$rdp_idle_s" ]; then
      rdp_idle_s="$v"
    fi
  }
  get_marker_idle_seconds() {
    local marker_path="$1"
    local marker_epoch=""
    local idle_from_marker=""
    marker_epoch="$(get_file_mtime_epoch "$marker_path")"
    case "$marker_epoch" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$marker_epoch" -le "$now" ]; then
      idle_from_marker="$((now - marker_epoch))"
      printf '%s\n' "$idle_from_marker"
      return 0
    fi
    return 1
  }

  # 1) SSH terminal activity marker
  # (written by /etc/profile.d/idle-terminal-activity.sh via PROMPT_COMMAND).
  # We treat real SSH user keystrokes as activity by reading marker file mtimes.
  if [ "$ssh_conn" -eq 0 ]; then
    ssh_marker_cleanup_count=0
    for marker in /run/user/*/idle-terminal-activity-ssh-* /tmp/idle-terminal-activity-*-ssh-*; do
      [ -e "$marker" ] || continue
      rm -f -- "$marker" 2>/dev/null || true
      ssh_marker_cleanup_count="$((ssh_marker_cleanup_count + 1))"
    done
    if [ "$ssh_marker_cleanup_count" -gt 0 ]; then
      log_status "mode=$IDLE_MODE ssh_marker_cleanup removed=${ssh_marker_cleanup_count} reason=tcp_disconnected port=22"
    fi
  fi

  active_ssh_tty_keys=$'\n'
  while IFS='|' read -r uid tty; do
    case "$uid" in ''|*[!0-9]*) continue ;; esac
    case "$tty" in
      pts/*)
        # Keep tty tag format aligned with /etc/profile.d/idle-terminal-activity.sh
        # (e.g. "pts/0" -> "pts_0").
        tty_tag="$(printf '%s' "$tty" | tr '/[:space:]' '__')"
        active_ssh_tty_keys="${active_ssh_tty_keys}${uid}:${tty_tag}"$'\n'
        marker_epoch=""
        marker_ssh_primary="/run/user/$uid/idle-terminal-activity-ssh-${tty_tag}"
        marker_ssh_fallback="/tmp/idle-terminal-activity-${uid}-ssh-${tty_tag}"

        for marker in "$marker_ssh_primary" "$marker_ssh_fallback"; do
          marker_epoch="$(get_file_mtime_epoch "$marker")"
          case "$marker_epoch" in
            ''|*[!0-9]*) marker_epoch="" ;;
          esac
          if [ -n "$marker_epoch" ]; then
            break
          fi
        done
        [ -n "$marker_epoch" ] || continue
        if [ "$marker_epoch" -le "$now" ]; then
          ssh_idle_session="$((now - marker_epoch))"
          update_best_idle "$ssh_idle_session"
          ssh_marker_count="$((ssh_marker_count + 1))"
          update_ssh_idle "$ssh_idle_session"
        fi
        ;;
      *)
        ;;
    esac
  done < <(ps -eo uid=,tty= 2>/dev/null | awk '$2 ~ /^pts\// {print $1 "|" $2}' | LC_ALL=C sort -u || true)

  # Cleanup stale SSH markers whose uid:tty are no longer active.
  ssh_marker_cleanup_count=0
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
    case "$active_ssh_tty_keys" in
      *$'\n'"$marker_key"$'\n'*) ;;
      *)
        rm -f -- "$marker" 2>/dev/null || true
        ssh_marker_cleanup_count="$((ssh_marker_cleanup_count + 1))"
        ;;
    esac
  done
  if [ "$ssh_marker_cleanup_count" -gt 0 ]; then
    log_status "mode=$IDLE_MODE ssh_marker_cleanup removed=${ssh_marker_cleanup_count} reason=stale_tty"
  fi

  # 2) RDP input marker from xinput watcher
  # (written by /usr/local/sbin/idle-rdp-input-watch.sh).
  rdp_has_tcp=0
  rdp_marker_cleanup_count=0
  if [ "$rdp_conn" -gt 0 ]; then
    rdp_has_tcp=1
  else
    for marker in /run/user/*/idle-rdp-input-activity /tmp/idle-rdp-input-activity-*; do
      [ -e "$marker" ] || continue
      rm -f -- "$marker" 2>/dev/null || true
      rdp_marker_cleanup_count="$((rdp_marker_cleanup_count + 1))"
    done
    if [ "$rdp_marker_cleanup_count" -gt 0 ]; then
      log_status "mode=$IDLE_MODE rdp_marker_cleanup removed=${rdp_marker_cleanup_count} reason=tcp_disconnected port=${RDP_TCP_PORT}"
    fi
  fi
  for marker in /run/user/*/idle-rdp-input-activity /tmp/idle-rdp-input-activity-*; do
    [ -e "$marker" ] || continue
    rdp_marker_idle_s="$(get_marker_idle_seconds "$marker" || true)"
    case "$rdp_marker_idle_s" in ''|*[!0-9]*) continue ;; esac
    if [ "$rdp_has_tcp" -eq 0 ] && [ "$rdp_marker_idle_s" -gt "$RDP_DISCONNECT_GRACE_SECONDS" ]; then
      continue
    fi
    update_best_idle "$rdp_marker_idle_s"
    update_rdp_idle "$rdp_marker_idle_s"
    rdp_marker_count="$((rdp_marker_count + 1))"
  done

  ssh_conn_for_log="$ssh_marker_count"
  rdp_conn_for_log="$rdp_marker_count"
  total_for_log="$((ssh_conn_for_log + rdp_conn_for_log))"

  if [ -n "$best_idle_s" ]; then
    last_epoch="$((now - best_idle_s))"
  fi

  # Activity mode only treats real user input as activity:
  # - SSH terminal keystrokes via PROMPT_COMMAND marker files
  # - GUI keyboard/mouse via xinput marker files
fi

if [ -n "$last_epoch" ]; then
  # Keep baseline monotonic: do not move last_active_epoch backwards.
  # This prevents a fresh reset (e.g., new SSH/RDP activity) from being
  # overwritten by an older sampled idle source on the next timer run.
  prev_last=""
  if [ -f "$state_file" ]; then
    prev_last="$(cat "$state_file" 2>/dev/null || true)"
  fi
  if [[ "$prev_last" =~ ^[0-9]+$ ]] && [ "$prev_last" -gt "$last_epoch" ]; then
    last_epoch="$prev_last"
  fi
  echo "$last_epoch" >"$state_file"
else
  if [ ! -f "$state_file" ]; then
    echo "$now" >"$state_file"
    exit 0
  fi
fi

last="$last_epoch"
if [ -z "$last" ]; then
  last="$(cat "$state_file" 2>/dev/null || echo "$now")"
fi
if ! [[ "$last" =~ ^[0-9]+$ ]]; then
  echo "$now" >"$state_file"
  exit 0
fi

idle_s="$((now - last))"
if [ "$idle_s" -lt 0 ]; then idle_s=0; fi
idle_m="$((idle_s / 60))"
ssh_status="$(format_conn_activity "$ssh_conn_for_log" "$ssh_idle_s")"
rdp_status="$(format_conn_activity "$rdp_conn_for_log" "$rdp_idle_s")"

case "$IDLE_MINUTES" in ''|*[!0-9]*) IDLE_MINUTES=20 ;; esac

if [ "$idle_m" -ge "$IDLE_MINUTES" ]; then
  log_status "mode=$IDLE_MODE idle=${idle_m}m/${IDLE_MINUTES}m shutting_down ssh=${ssh_status} rdp=${rdp_status} total=${total_for_log}"
  shutdown -h now "idle-shutdown: idle ${idle_m} minutes"
else
  remain_m="$((IDLE_MINUTES - idle_m))"
  log_status "mode=$IDLE_MODE idle=${idle_m}m/${IDLE_MINUTES}m shutdown_in=${remain_m}m ssh=${ssh_status} rdp=${rdp_status} total=${total_for_log}"
fi
