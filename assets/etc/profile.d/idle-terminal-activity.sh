#!/bin/sh
# Touch an SSH terminal activity marker before each interactive prompt.
# This treats real SSH user keystrokes (including Enter) as activity.
case "$-" in
  *i*) ;;
  *) return 0 ;;
esac
tty_path="$(tty 2>/dev/null || true)"
case "$tty_path" in
  /dev/pts/*) ;;
  *) return 0 ;;
esac
if [ -z "${SSH_TTY:-}" ] || [ -z "${SSH_CONNECTION:-}" ] || [ "${SSH_TTY#/dev/}" != "${tty_path#/dev/}" ]; then
  return 0
fi

idle_touch_terminal_activity() {
  tty_tag="$(printf '%s' "${tty_path#/dev/}" | tr '/[:space:]' '__')"
  marker=""
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR:-}" ] && [ -w "${XDG_RUNTIME_DIR:-}" ]; then
    marker="${XDG_RUNTIME_DIR}/idle-terminal-activity-ssh-${tty_tag}"
  else
    uid="$(id -u 2>/dev/null || true)"
    case "$uid" in
      ''|*[!0-9]*) return 0 ;;
    esac
    marker="/tmp/idle-terminal-activity-${uid}-ssh-${tty_tag}"
  fi
  : >"$marker" 2>/dev/null || true
}

# Do not touch on shell startup. Touch only when PROMPT_COMMAND runs,
# so "activity" means actual prompt interaction.
case "${PROMPT_COMMAND:-}" in
  *idle_touch_terminal_activity*) ;;
  '') PROMPT_COMMAND='idle_touch_terminal_activity' ;;
  *) PROMPT_COMMAND="idle_touch_terminal_activity; ${PROMPT_COMMAND}" ;;
esac
export PROMPT_COMMAND
