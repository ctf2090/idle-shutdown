#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
idle_script="$repo_dir/idle-shutdown.sh"

if [ ! -f "$idle_script" ]; then
  echo "[ERROR] Missing script: $idle_script" >&2
  exit 2
fi

tmp_root="$(mktemp -d)"
external_markers=()
cleanup() {
  if [ "${#external_markers[@]}" -gt 0 ]; then
    rm -f -- "${external_markers[@]}" 2>/dev/null || true
  fi
  rm -rf -- "$tmp_root" 2>/dev/null || true
}
trap cleanup EXIT

mock_bin="$tmp_root/mock-bin"
mkdir -p "$mock_bin"

cat >"$mock_bin/ss" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${IDLE_SMOKE_SS_MODE:-none}"
query="unknown"
args="$*"
if [[ "$args" == *"sport = :22"* ]]; then
  query="ssh"
elif [[ "$args" == *"sport = :3389"* ]]; then
  query="rdp"
fi
case "$mode" in
  none)
    exit 0
    ;;
  ssh)
    if [ "$query" = "ssh" ]; then
      echo "ESTAB 0 0 10.0.0.1:22 10.0.0.2:12345"
    fi
    ;;
  rdp)
    if [ "$query" = "rdp" ]; then
      echo "ESTAB 0 0 10.0.0.1:3389 10.0.0.2:12345"
    fi
    ;;
  both)
    if [ "$query" = "ssh" ]; then
      echo "ESTAB 0 0 10.0.0.1:22 10.0.0.2:12345"
    fi
    if [ "$query" = "rdp" ]; then
      echo "ESTAB 0 0 10.0.0.1:3389 10.0.0.2:12345"
    fi
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod 0755 "$mock_bin/ss"

cat >"$mock_bin/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${IDLE_SMOKE_PS_MODE:-none}"
case "$mode" in
  none)
    exit 0
    ;;
  ssh_one)
    # Output shape compatible with: ps -eo uid=,tty=
    echo "1000 pts/0"
    ;;
  ssh_two)
    echo "1000 pts/1"
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod 0755 "$mock_bin/ps"

cat >"$mock_bin/shutdown" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_file="${IDLE_SMOKE_SHUTDOWN_LOG:?}"
printf '%s\n' "$*" >>"$log_file"
exit 0
EOF
chmod 0755 "$mock_bin/shutdown"

cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "${IDLE_SMOKE_CURL_OUTPUT:-}"
exit 0
EOF
chmod 0755 "$mock_bin/curl"

assert_file_absent_or_empty() {
  local p="$1"
  if [ -s "$p" ]; then
    echo "[ERROR] Expected empty/absent file but got content: $p" >&2
    cat "$p" >&2
    exit 1
  fi
}

assert_file_contains() {
  local p="$1"
  local pattern="$2"
  if ! grep -q -- "$pattern" "$p"; then
    echo "[ERROR] Missing expected pattern '$pattern' in $p" >&2
    cat "$p" >&2
    exit 1
  fi
}

register_external_marker() {
  local p="$1"
  external_markers+=("$p")
}

set_marker_age_seconds() {
  local p="$1"
  local age_s="$2"
  local now ts
  now="$(date +%s)"
  ts="$((now - age_s))"
  touch -m -d "@$ts" "$p"
}

create_ssh_activity_marker() {
  local uid="$1"
  local tty_tag="$2"
  local age_s="${3:-0}"
  local marker="/tmp/idle-terminal-activity-${uid}-ssh-${tty_tag}"
  : >"$marker"
  if [ "$age_s" -gt 0 ]; then
    set_marker_age_seconds "$marker" "$age_s"
  fi
  register_external_marker "$marker"
  printf '%s\n' "$marker"
}

create_rdp_activity_marker() {
  local suffix="$1"
  local age_s="${2:-0}"
  local marker="/tmp/idle-rdp-input-activity-${suffix}"
  : >"$marker"
  if [ "$age_s" -gt 0 ]; then
    set_marker_age_seconds "$marker" "$age_s"
  fi
  register_external_marker "$marker"
  printf '%s\n' "$marker"
}

prepare_case_dir() {
  local case_name="$1"
  local case_dir="$tmp_root/$case_name"
  local state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  printf 'provisioning-complete-on-boot-1\n' >"$state_dir/provisioning_done_boot_id"
  cat /proc/sys/kernel/random/boot_id >"$state_dir/phase_boot2_logged_boot_id"
  printf '%s\n' "$case_dir"
}

run_idle() {
  local state_dir="$1"
  local shutdown_log="$2"
  local idle_minutes="$3"
  local idle_mode="$4"
  local ss_mode="$5"
  local ps_mode="$6"
  IDLE_SHUTDOWN_ENABLED=1 \
  IDLE_MODE="$idle_mode" \
  IDLE_MINUTES="$idle_minutes" \
  BOOT_GRACE_MINUTES=0 \
  STATUS_PERIOD_MINUTES=0 \
  IDLE_SHUTDOWN_STATE_DIR="$state_dir" \
  PROVISIONING_DONE_BOOT_ID_PATH="$state_dir/provisioning_done_boot_id" \
  IDLE_SMOKE_SHUTDOWN_LOG="$shutdown_log" \
  IDLE_SMOKE_SS_MODE="$ss_mode" \
  IDLE_SMOKE_PS_MODE="$ps_mode" \
  PATH="$mock_bin:$PATH" \
  bash "$idle_script"
}

test_connections_no_shutdown() {
  local case_dir state_dir shutdown_log
  case_dir="$(prepare_case_dir "connections_no_shutdown")"
  state_dir="$case_dir/state"
  shutdown_log="$case_dir/shutdown.log"

  run_idle "$state_dir" "$shutdown_log" 5 connections none none

  assert_file_absent_or_empty "$shutdown_log"
  if [ ! -f "$state_dir/last_active_epoch" ]; then
    echo "[ERROR] Missing state file: $state_dir/last_active_epoch" >&2
    exit 1
  fi
  echo "[OK] connections/no-conn does not shutdown"
}

test_idle_threshold_triggers_shutdown() {
  local case_dir state_dir shutdown_log now
  case_dir="$(prepare_case_dir "idle_threshold_triggers_shutdown")"
  state_dir="$case_dir/state"
  shutdown_log="$case_dir/shutdown.log"

  now="$(date +%s)"
  printf '%s\n' "$((now - 180))" >"$state_dir/last_active_epoch"

  run_idle "$state_dir" "$shutdown_log" 1 connections none none

  assert_file_contains "$shutdown_log" "idle-shutdown: idle"
  echo "[OK] idle threshold triggers shutdown"
}

test_connections_active_ssh_no_shutdown() {
  local case_dir state_dir shutdown_log
  case_dir="$(prepare_case_dir "connections_active_ssh_no_shutdown")"
  state_dir="$case_dir/state"
  shutdown_log="$case_dir/shutdown.log"

  run_idle "$state_dir" "$shutdown_log" 1 connections ssh none

  assert_file_absent_or_empty "$shutdown_log"
  echo "[OK] active ssh connection does not shutdown in connections mode"
}

test_activity_active_ssh_marker_no_shutdown() {
  local case_dir state_dir shutdown_log
  case_dir="$(prepare_case_dir "activity_active_ssh_marker_no_shutdown")"
  state_dir="$case_dir/state"
  shutdown_log="$case_dir/shutdown.log"

  create_ssh_activity_marker "1000" "pts_0" 0 >/dev/null
  run_idle "$state_dir" "$shutdown_log" 1 activity ssh ssh_one

  assert_file_absent_or_empty "$shutdown_log"
  echo "[OK] activity/ssh marker (fresh) does not shutdown"
}

test_activity_stale_ssh_marker_triggers_shutdown() {
  local case_dir state_dir shutdown_log
  case_dir="$(prepare_case_dir "activity_stale_ssh_marker_triggers_shutdown")"
  state_dir="$case_dir/state"
  shutdown_log="$case_dir/shutdown.log"

  create_ssh_activity_marker "1000" "pts_0" 180 >/dev/null
  run_idle "$state_dir" "$shutdown_log" 1 activity ssh ssh_one

  assert_file_contains "$shutdown_log" "idle-shutdown: idle"
  echo "[OK] activity/ssh marker (stale) triggers shutdown"
}

test_activity_active_rdp_marker_no_shutdown() {
  local case_dir state_dir shutdown_log
  case_dir="$(prepare_case_dir "activity_active_rdp_marker_no_shutdown")"
  state_dir="$case_dir/state"
  shutdown_log="$case_dir/shutdown.log"

  create_rdp_activity_marker "$$" 0 >/dev/null
  run_idle "$state_dir" "$shutdown_log" 1 activity rdp none

  assert_file_absent_or_empty "$shutdown_log"
  echo "[OK] activity/rdp marker (fresh) does not shutdown"
}

test_activity_no_marker_uses_state_file_idle_shutdown() {
  local case_dir state_dir shutdown_log now
  case_dir="$(prepare_case_dir "activity_no_marker_uses_state_file_idle_shutdown")"
  state_dir="$case_dir/state"
  shutdown_log="$case_dir/shutdown.log"

  now="$(date +%s)"
  printf '%s\n' "$((now - 180))" >"$state_dir/last_active_epoch"
  run_idle "$state_dir" "$shutdown_log" 1 activity none none

  assert_file_contains "$shutdown_log" "idle-shutdown: idle"
  echo "[OK] activity/no marker falls back to state file and shuts down"
}

test_connections_no_shutdown
test_idle_threshold_triggers_shutdown
test_connections_active_ssh_no_shutdown
test_activity_active_ssh_marker_no_shutdown
test_activity_stale_ssh_marker_triggers_shutdown
test_activity_active_rdp_marker_no_shutdown
test_activity_no_marker_uses_state_file_idle_shutdown

echo "[OK] idle-shutdown smoke tests passed"
