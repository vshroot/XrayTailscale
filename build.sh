#!/bin/bash
# build.sh — build the single-file xraytailscale from src/*.sh modules
#
# Modules are concatenated in name-sort order (00-... -> 99-...).
# Runtime and deploy are UNCHANGED: install.sh/update.sh still
# download the single built xraytailscale file from the repo root.
#
# Usage:
#   ./build.sh              # rebuild ./xraytailscale
#   ./build.sh /tmp/xt      # build to the given path (for checks)
set -euo pipefail
cd "$(dirname "$0")"

OUT="${1:-xraytailscale}"
TMP=$(mktemp /tmp/xraytailscale-build.XXXXXX)
trap 'rm -f "$TMP"' EXIT

cat src/*.sh > "$TMP"
bash -n "$TMP"
chmod +x "$TMP"
cp "$TMP" "$OUT"
chmod +x "$OUT"
echo "✓ Built $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"
