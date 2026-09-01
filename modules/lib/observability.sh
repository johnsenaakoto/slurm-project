#!/usr/bin/env bash

# Shared logging and failure diagnostics for cluster modules.

log() {
  local level="$1"
  shift
  printf '%s [%s] [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$MODULE_NAME" "$level" "$*"
}

log_command() {
  local rendered=""
  local argument
  for argument in "$@"; do
    printf -v rendered '%s %q' "$rendered" "$argument"
  done
  log COMMAND "${rendered# }"
}

observability_error() {
  local exit_code="$1"
  local line_number="$2"
  local failed_command="$3"

  if [[ "${ERROR_REPORTED:-false}" == true ]]; then
    return
  fi
  ERROR_REPORTED=true
  log ERROR "Command failed with exit code $exit_code at line $line_number: $failed_command"
  log ERROR "Review the preceding output and full log: $LOG_FILE"
}

observability_exit() {
  local exit_code="$1"
  local elapsed=$((SECONDS - MODULE_START_SECONDS))

  if declare -F module_cleanup >/dev/null 2>&1; then
    if ! module_cleanup "$exit_code"; then
      log ERROR "Module cleanup reported a failure; manual recovery may be required"
    fi
  fi

  if ((exit_code == 0)); then
    log INFO "Completed successfully in ${elapsed}s. Log: $LOG_FILE"
  else
    log ERROR "Stopped after ${elapsed}s with exit code $exit_code. Log: $LOG_FILE"
  fi

  # Restore the original terminal streams, close the pipe writer, and allow
  # tee to flush the complete log before the script exits.
  exec 1>&3 2>&4
  wait "$LOG_TEE_PID" 2>/dev/null || true
  rm -f -- "$LOG_PIPE"
}

init_observability() {
  MODULE_NAME="$1"
  local requested_log_dir="$2"
  MODULE_START_SECONDS=$SECONDS
  ERROR_REPORTED=false

  mkdir -p "$requested_log_dir"
  LOG_FILE="${requested_log_dir}/${MODULE_NAME}-$(date '+%Y%m%d-%H%M%S')-$$.log"
  LOG_PIPE="${LOG_FILE}.pipe"
  touch "$LOG_FILE"
  mkfifo "$LOG_PIPE"

  exec 3>&1 4>&2
  tee -a "$LOG_FILE" <"$LOG_PIPE" >&3 &
  LOG_TEE_PID=$!
  exec >"$LOG_PIPE" 2>&1

  trap 'observability_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
  trap 'observability_exit "$?"' EXIT

  log INFO "Starting module"
  log INFO "Configuration: $CONFIG_FILE"
  log INFO "Dry run: $DRY_RUN"
}
