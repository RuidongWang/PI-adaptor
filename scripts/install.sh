#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
# Install root defaults to the isolated host home — the SAME root the systemd
# unit uses (`PI_ADAPTOR_HOME=%h/.pi-adaptor`) — so `current/dist/main.js`
# resolves to what this script published.
TARGET="${PI_ADAPTOR_INSTALL_DIR:-${PI_ADAPTOR_HOME:-$HOME/.pi-adaptor}}"
# Version defaults to the manifest inside this bundle, so `current` always
# points at a directory whose name matches the version the host reports.
VERSION="${1:-$(node -p "require('$ROOT/package.json').version")}"
if [[ ! "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ || "$VERSION" == "current" || "$VERSION" == "current.tmp" ]]; then
  printf 'invalid version: %s\n' "$VERSION" >&2
  exit 1
fi
DEST="$TARGET/$VERSION"

mkdir -p "$TARGET"

# Any abort after staging starts — notably `cp` failing under `set -e`, which
# skips the explicit cleanup below — must not leave a `.staging-*` directory
# behind. The trap also guarantees the existing `$DEST` is untouched until the
# atomic `mv` replaces it, so a failed run never corrupts a published version.
STAGE=""
cleanup_staging() { if [[ -n "$STAGE" ]]; then rm -rf "$STAGE"; fi; }
trap cleanup_staging EXIT

if [[ ! -f "$DEST/dist/main.js" ]]; then
  STAGE="$TARGET/.staging-$VERSION-$$"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  cp -R "$ROOT/dist" "$ROOT/node_modules" "$ROOT/package.json" "$STAGE/"
  if [[ ! -f "$STAGE/dist/main.js" ]]; then
    printf 'staging verification failed: dist/main.js not found\n' >&2
    exit 1
  fi
  rm -rf "$DEST"
  mv "$STAGE" "$DEST"
  STAGE=""
fi

# `current` is a symlink to the version directory, matching the unit's
# `ExecStart=.../current/dist/main.js`. Repoint it atomically via a temp link so
# a running service never observes a dangling target mid-swap.
ln -sfn "$VERSION" "$TARGET/current.new"
mv -f "$TARGET/current.new" "$TARGET/current"
printf 'installed %s (current -> %s)\n' "$DEST" "$VERSION"
