#!/bin/sh
# project: fuji-sync
# code generator: ChatGPT
# author: kodweis@gmail.com
# merge_conf.sh REF_FILE EDITABLE_FILE
set -eu
REF="$1"
OUT="$2"

# Create editable from reference if missing
if [ ! -f "$OUT" ]; then
  cp -f "$REF" "$OUT"
  exit 0
fi

KEYS="FUJI_MOUNT NAS_TARGET CAMERA_PORT SOURCE_GLOB BACKOFF_BASE BACKOFF_MAX RSYNC_RETRIES DEBUG NOTIFY CAM_CHECK_INTERVAL"
for K in $KEYS; do
  if ! grep -Eq "^[#[:space:]]*${K}=" "$OUT"; then
    LINE="$(grep -E "^[#[:space:]]*${K}=" "$REF" | head -n1 || true)"
    if [ -n "$LINE" ]; then
      printf "\n%s\n" "$LINE" >> "$OUT"
    fi
  fi
done
