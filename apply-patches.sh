#!/usr/bin/env bash
# Apply tracked Buildroot patches to the (otherwise pristine) BR checkout.
# Idempotent: skips patches already applied. Run before every build.
# Usage: apply-patches.sh <buildroot-2026.08 dir>   (or set BR=...)
set -e
BR=${1:-${BR:?usage: $0 <buildroot dir>}}
P=$(cd "$(dirname "$0")" && pwd)/patches/buildroot
for patch in "$P"/*.patch; do
  [ -e "$patch" ] || continue
  if patch -d "$BR" -p1 --dry-run -R -f <"$patch" >/dev/null 2>&1; then
    echo "already applied: $(basename "$patch")"
  else
    patch -d "$BR" -p1 <"$patch"
    echo "applied: $(basename "$patch")"
  fi
done
