# project: fuji-sync
# code generator: ChatGPT
# author: kodweis@gmail.com
Fuji Auto-Sync 1.0 (gphotofs edition)
- Uses gphotofs to mount the camera (no GVFS, no local staging)
- Copy-only rsync from $FUJI_MOUNT/$SOURCE_GLOB -> NAS
- Unmounts after each sync cycle to avoid FUSE 'transport endpoint' errors
- One sync per camera connection
- Simple IPv4 ping host check
- Consolidated notifications (one at start, one at end)
- Camera poll interval configurable via CAM_CHECK_INTERVAL (default 10s)

Config policy
- Reference (overwritten):  ~/.local/etc/fuji-auto-sync/fuji-sync.conf.ref
- Editable (runtime):       ~/.local/etc/fuji-auto-sync/fuji-sync.conf  (preserved)
- On install, missing keys in the editable are appended from the reference.
