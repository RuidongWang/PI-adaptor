#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
# Single source of the release version: the `package.json` that ships inside the
# bundle. `src/config.ts` reports that same field at runtime, so the tarball
# name, the installed tree, and the version the host advertises cannot drift.
PKG_VERSION=$(node -p "require('$ROOT/package.json').version")
VERSION="${1:-$PKG_VERSION}"
if [[ ! "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
  printf 'invalid version: %s\n' "$VERSION" >&2
  exit 1
fi
OUT_ARG="${2:-$ROOT/release}"
mkdir -p "$OUT_ARG"
OUT=$(CDPATH= cd -- "$OUT_ARG" && pwd -P)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pi-adaptor-release.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

cd "$ROOT"
pnpm build

# Refuse to ship bytes whose declared version is not the version in the name.
BUILT_VERSION=$(node -e 'import("./dist/config.js").then((m) => process.stdout.write(m.HOST_VERSION))')
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
  printf 'built host reports version %s but release name is %s\n' "$BUILT_VERSION" "$VERSION" >&2
  exit 1
fi

mkdir -p "$STAGE/pi-adaptor-$VERSION"
cp -R dist node_modules package.json scripts "$STAGE/pi-adaptor-$VERSION/"
mkdir -p "$OUT"
tar -C "$STAGE" -czf "$OUT/pi-adaptor-$VERSION.tar.gz" "pi-adaptor-$VERSION"
# Hash the basename from inside the output directory: release assets must carry
# `sha256  <file>` (no absolute paths) so the checksum verifies after download.
(
  cd "$OUT"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "pi-adaptor-$VERSION.tar.gz" > "pi-adaptor-$VERSION.tar.gz.sha256"
  else
    shasum -a 256 "pi-adaptor-$VERSION.tar.gz" > "pi-adaptor-$VERSION.tar.gz.sha256"
  fi
)
printf '%s\n' "$OUT/pi-adaptor-$VERSION.tar.gz"
