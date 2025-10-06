#!/bin/bash
# project: fuji-sync
# code generator: ChatGPT
# author: kodweis@gmail.com
# Fuji Auto-Sync Watcher (gphotofs edition)
# Version: 1.0 build-38 2025-10-06

# Robust, but do NOT use 'set -e' or '-u' so transient errors don't kill the loop.
set -E -o pipefail
IFS=$' \t\n'

VERSION="1.0 build-38 2025-10-06"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"  # for consistency

# --- Defaults (overridden by ~/.local/etc/fuji-auto-sync/fuji-sync.conf) ---
FUJI_MOUNT="${FUJI_MOUNT:-$HOME/fuji}"
NAS_TARGET="${NAS_TARGET:-user@nas:/volume1/fujifilm/DCIM}"
CAMERA_PORT="${CAMERA_PORT:-}"            # unused in gphotofs mode; kept for future
SOURCE_GLOB="${SOURCE_GLOB:-store_*/DCIM}"# where DCIM usually lives under gphotofs
BACKOFF_BASE="${BACKOFF_BASE:-15}"
BACKOFF_MAX="${BACKOFF_MAX:-120}"
RSYNC_RETRIES="${RSYNC_RETRIES:-3}"
DEBUG="${DEBUG:-0}"
NOTIFY="${NOTIFY:-0}"                     # 0=quiet (default), 1=desktop notifications
CAM_CHECK_INTERVAL="${CAM_CHECK_INTERVAL:-10}"

CONF_DEFAULT="$HOME/.local/etc/fuji-auto-sync/fuji-sync.conf"
[ -f "$CONF_DEFAULT" ] && . "$CONF_DEFAULT"

[ "$DEBUG" = "1" ] && set -x

FUSERMOUNT="$(command -v fusermount3 || command -v fusermount || echo umount)"

_log() {
  local msg="$1"
  printf "%s %s\n" "$(date +'%F %T')" "$msg"
}

_notify() {
  [ "$NOTIFY" = "1" ] || return 0
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "Fuji Auto-Sync" "$1" >/dev/null 2>&1 || true
  fi
}

check_dependencies() {
  local req="gphotofs gphoto2 rsync"
  local opt="notify-send lsusb"
  local miss=""
  for c in $req; do
    command -v "$c" >/dev/null 2>&1 || miss="$miss $c"
  done
  if [ -n "$miss" ]; then
    _log "⚠ [v$VERSION] Missing required: $miss"
    _log "   Install: sudo apt-get install -y gphotofs gphoto2 rsync"
    _notify "Missing required tools:$miss"
  fi
  local miss_opt=""
  for c in $opt; do
    command -v "$c" >/dev/null 2>&1 || miss_opt="$miss_opt $c"
  done
  [ -n "$miss_opt" ] && _log "ℹ [v$VERSION] Optional not found:$miss_opt"
}

detect_camera_port() {
  # Return first 'usb:x,y' seen by gphoto2
  gphoto2 --auto-detect 2>/dev/null | awk '/usb:[0-9]+,[0-9]+/ {print $NF; exit}'
}

nas_host() {
  # Parse host from NAS_TARGET like user@host:/path or host:/path or just host
  local userhost="${NAS_TARGET%%:*}"
  local host="${userhost##*@}"
  host="${host#[}"; host="${host%]}"
  echo "$host"
}

nas_reachable() {
  local host; host="$(nas_host)"
  [ -n "$host" ] || return 1
  ping -4 -c1 -W1 "$host" >/dev/null 2>&1
}

cleanup_mounts() {
  # Try to unmount even if stale "Transport endpoint is not connected"
  if mountpoint -q "$FUJI_MOUNT"; then
    $FUSERMOUNT -u "$FUJI_MOUNT" 2>/dev/null || umount -l "$FUJI_MOUNT" 2>/dev/null || true
  else
    $FUSERMOUNT -u "$FUJI_MOUNT" 2>/dev/null || umount -l "$FUJI_MOUNT" 2>/dev/null || true
  fi
}

trap ' _log "🛑 [v$VERSION] SIGTERM/SIGINT caught; cleaning up"; cleanup_mounts; _notify "Service stopped"; _log "⏹ [v$VERSION] Service stopped"; exit 0 ' SIGTERM SIGINT
trap ' _log "⚠ [v$VERSION] EXIT trap; cleaning up"; cleanup_mounts; ' EXIT

mkdir -p "$FUJI_MOUNT" 2>/dev/null || true

_log "🚀 [v$VERSION] Starting Fuji Auto-Sync (gphotofs)"
_log "ℹ [v$VERSION] Config: FUJI_MOUNT=$FUJI_MOUNT, NAS_TARGET=$NAS_TARGET, CAM_CHECK_INTERVAL=$CAM_CHECK_INTERVAL, NOTIFY=$NOTIFY, DEBUG=$DEBUG"

check_dependencies

# Once-per-connection state
LAST_PORT=""
SYNC_DONE_FOR_PORT=0
START_NOTIFY_DONE=0

mount_gphotofs() {
  mkdir -p "$FUJI_MOUNT" 2>/dev/null || true

  # Clean any stale mount first
  $FUSERMOUNT -u "$FUJI_MOUNT" 2>/dev/null || umount -l "$FUJI_MOUNT" 2>/dev/null || true

  if mountpoint -q "$FUJI_MOUNT"; then
    return 0
  fi

  # Kill any volume monitors that might hold the device
  pkill -f gvfs-gphoto2-volume-monitor 2>/dev/null || true
  pkill -f gphoto2-volume-monitor 2>/dev/null || true

  _log "🔌 [v$VERSION] Mounting camera (gphotofs $FUJI_MOUNT)"
  if [ "$DEBUG" = "1" ]; then
    gphotofs "$FUJI_MOUNT" &
  else
    gphotofs "$FUJI_MOUNT" >/dev/null 2>&1 &
  fi
  GPID=$!

  # Wait up to ~10s for mount to appear, fail early if gphotofs exits
  for _ in $(seq 1 40); do
    mountpoint -q "$FUJI_MOUNT" && return 0
    if ! kill -0 "$GPID" 2>/dev/null; then
      _log "⚠ [v$VERSION] gphotofs exited before mount appeared"
      return 1
    fi
    sleep 0.25
  done

  _log "⚠ [v$VERSION] gphotofs mount did not appear within timeout"
  return 1
}

# Sync sources under the gphotofs mount
sync_sources() {
  local any=0
  local transferred_total=0
  local had_error=0
  for SRC in "$FUJI_MOUNT"/$SOURCE_GLOB/; do
    [ -d "$SRC" ] || continue
    any=1
    _log "🔄 [v$VERSION] rsync from $SRC -> $NAS_TARGET"
    local attempt=1
    local transferred=""
    local rc=1
    while [ "$attempt" -le "$RSYNC_RETRIES" ]; do
      RSYNC_LOG="$(mktemp)"
      rsync -avh --stats --ignore-existing --inplace "$SRC" "$NAS_TARGET"/ | tee "$RSYNC_LOG"; rc=$?
      transferred="$(awk '/Number of regular files transferred:/{print $6}' "$RSYNC_LOG" 2>/dev/null || true)"
      rm -f "$RSYNC_LOG"
      [ "$rc" -eq 0 ] && break
      _log "⚠ [v$VERSION] rsync attempt $attempt failed (rc=$rc); retrying..."
      attempt=$(( attempt+1 ))
      sleep 2
    done
    [ "$rc" -ne 0 ] && had_error=1
    if [ -n "$transferred" ] && [ "$transferred" -gt 0 ] 2>/dev/null; then
      transferred_total=$(( transferred_total + transferred ))
    fi
  done

  SYNC_TRANSFERRED="$transferred_total"
  if [ "$any" -eq 0 ]; then
    _log "ℹ [v$VERSION] No matching sources under $FUJI_MOUNT/$SOURCE_GLOB yet"
    SYNC_RESULT="ok"
    return 2
  fi

  if [ "$had_error" -eq 0 ]; then
    if [ "$transferred_total" -gt 0 ] 2>/dev/null; then
      _log "✅ [v$VERSION] Sync complete: $transferred_total files copied"
    else
      _log "✅ [v$VERSION] No new files"
    fi
    SYNC_RESULT="ok"
    return 0
  else
    _log "🛑 [v$VERSION] Sync encountered errors"
    SYNC_RESULT="error"
    return 1
  fi
}

while true; do
  # Poll camera presence (no udev available in Crostini)
  port="$(detect_camera_port)"
  if [ -z "$port" ]; then
    # Suppressed chatty "Camera not detected..." log; just reset state silently
    if [ -n "$LAST_PORT" ] || [ "$SYNC_DONE_FOR_PORT" -ne 0 ]; then
      _log "🔌 [v$VERSION] Camera disconnected; reset sync state"
    fi
    LAST_PORT=""
    SYNC_DONE_FOR_PORT=0
    START_NOTIFY_DONE=0
    sleep "$CAM_CHECK_INTERVAL"
    continue
  fi

  # New connection (port changed) → reset once-per-connection state
  if [ "$port" != "$LAST_PORT" ]; then
    _log "📸 [v$VERSION] New connection detected at port $port"
    LAST_PORT="$port"
    SYNC_DONE_FOR_PORT=0
    START_NOTIFY_DONE=0
  fi

  # If we've already synced for this connection, just wait until disconnect
  if [ "$SYNC_DONE_FOR_PORT" -eq 1 ]; then
    if [ "$START_NOTIFY_DONE" -eq 0 ] && [ "$NOTIFY" = "1" ]; then
      _notify "Camera detected — sync already completed for this connection"
      START_NOTIFY_DONE=1
    fi
    _log "🕒 [v$VERSION] Already synced for current connection ($port); waiting for disconnect..."
    sleep "$BACKOFF_BASE"
    continue
  fi

  # One-time start notification per connection
  if [ "$START_NOTIFY_DONE" -eq 0 ] && [ "$NOTIFY" = "1" ]; then
    if nas_reachable; then
      _notify "Camera detected — starting sync"
    else
      _notify "Camera detected — waiting for NAS"
    fi
    START_NOTIFY_DONE=1
  fi

  # Ensure NAS reachable before doing any work
  if ! nas_reachable; then
    _log "⚠ [v$VERSION] NAS not reachable; sleeping ${BACKOFF_BASE}s..."
    sleep "$BACKOFF_BASE"
    continue
  fi

  # Mount via gphotofs
  if ! mount_gphotofs; then
    _log "⚠ [v$VERSION] Could not mount camera; sleeping ${BACKOFF_BASE}s..."
    sleep "$BACKOFF_BASE"
    continue
  fi

  # Attempt sync once for this connection
  SYNC_RESULT="error"; SYNC_TRANSFERRED=0
  sync_sources || true

  # Unmount and mark done
  _log "⏏️  [v$VERSION] Unmounting camera"
  cleanup_mounts
  SYNC_DONE_FOR_PORT=1

  # Final one-shot notification per connection
  if [ "$NOTIFY" = "1" ]; then
    if [ "$SYNC_RESULT" = "ok" ]; then
      if [ "$SYNC_TRANSFERRED" -gt 0 ] 2>/dev/null; then
        _notify "Sync complete — $SYNC_TRANSFERRED files copied"
      else
        _notify "Sync complete — no new files"
      fi
    else
      _notify "Sync failed — check logs"
    fi
  fi

  sleep "$BACKOFF_BASE"
done
