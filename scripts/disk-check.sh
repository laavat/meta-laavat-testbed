#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
# Disk usage of the Yocto build. On btrfs with compression `du` shows apparent
# (uncompressed) size; `df` of the volume is what actually matters.
# Exit 1 when less than 10 GB is free so it can gate a build.
cd "$(dirname "$0")/.." || exit 2
echo "== volume"
df -h . | awk 'NR==2 {print "free: "$4"  used: "$3" ("$5") of "$2}'
echo "== build dirs (apparent size)"
for d in build/downloads build/sstate-cache build/tmp build/tmp/work build/tmp/deploy; do
    [ -d "$d" ] && printf '%-22s %s\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
done
if [ -d build/tmp/work ]; then
    echo "== largest work dirs"
    du -sh build/tmp/work/*/* 2>/dev/null | sort -h | tail -5
fi
echo "== docker"
docker system df 2>/dev/null | tail -n +2
avail_kb=$(df -k . | awk 'NR==2 {print $4}')
if [ "$avail_kb" -lt 10485760 ]; then
    echo "WARN: less than 10 GB free"
    exit 1
fi
