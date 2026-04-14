#!/bin/bash

MOUNT_POINT="/mnt/error"
ERROR_LOG="${MOUNT_POINT}/ERROR.log"

if [ $# -lt 1 ]; then
    exit 1
fi

if mountpoint -q "$MOUNT_POINT"; then
    echo "[$(date '+%Y.%m.%d %H:%M:%S')] $1" >> "$ERROR_LOG"
    exit 0
else
    exit 1
fi