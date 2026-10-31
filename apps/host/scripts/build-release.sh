#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
VERSION="${1:-0.1.0}"
if [[ ! "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
  printf 'invalid version: %s\n' "$VERSION" >&2
  exit 1
fi
OUT_ARG="${2:-$ROOT/release}"
mkdir -p "$OUT_ARG"
OUT=$(CDPATH= cd -- "$OUT_ARG" && pwd -P)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pi-host-v2-release.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

cd "$ROOT"
pnpm build
mkdir -p "$STAGE/pi-host-v2-$VERSION"
cp -R dist node_modules package.json scripts "$STAGE/pi-host-v2-$VERSION/"
mkdir -p "$OUT"
tar -C "$STAGE" -czf "$OUT/pi-host-v2-$VERSION.tar.gz" "pi-host-v2-$VERSION"
sha256sum "$OUT/pi-host-v2-$VERSION.tar.gz" > "$OUT/pi-host-v2-$VERSION.tar.gz.sha256"
printf '%s\n' "$OUT/pi-host-v2-$VERSION.tar.gz"
