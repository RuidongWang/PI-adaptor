#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd -P)
PATCH_FILE="$REPO_ROOT/server/patches/pi-host-provider-remove.patch"
BASE_COMMIT=d2c9fc44087f24260521c66530c4f92c04790105

usage() {
  cat <<'USAGE'
Usage: build-pi-host-js.sh --source <PI-Desktop-git-checkout> --out <pi-host.js>

Builds the architecture-neutral pi-host.js from the pinned upstream base
commit, applies the provider-remove patch in an isolated temporary tree, and
checks that all four added CLI commands are present.

Environment:
  PNPM              pnpm executable (default: pnpm)
  TMPDIR            temporary directory root

The source checkout is only read with git archive. It is never modified.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

SOURCE=
OUT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      [ "$#" -ge 2 ] || die "--source needs a value"
      SOURCE=$2
      shift 2
      ;;
    --out)
      [ "$#" -ge 2 ] || die "--out needs a value"
      OUT=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$SOURCE" ] || die "--source is required"
[ -n "$OUT" ] || die "--out is required"
[ -d "$SOURCE" ] || die "source checkout not found: $SOURCE"
[ -f "$PATCH_FILE" ] || die "patch not found: $PATCH_FILE"

PNPM=${PNPM:-pnpm}
command -v "$PNPM" >/dev/null 2>&1 || die "pnpm not found: $PNPM"
command -v git >/dev/null 2>&1 || die "git is required"
command -v node >/dev/null 2>&1 || die "node is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

git -C "$SOURCE" cat-file -e "$BASE_COMMIT^{commit}" \
  || die "base commit not found in source checkout: $BASE_COMMIT"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pi-host-js.XXXXXX")
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

SRC="$WORK/src"
mkdir -p "$SRC"
git -C "$SOURCE" archive "$BASE_COMMIT" | tar -x -C "$SRC"

(
  cd "$SRC"
  git apply --check "$PATCH_FILE"
  git apply "$PATCH_FILE"

  "$PNPM" install \
    --filter "@pi-desktop/pi-host..." \
    --filter "@pi-desktop/host-runtime..." \
    --filter "@pi-desktop/shared..." \
    --ignore-scripts \
    --frozen-lockfile

  "$PNPM" -r --filter "@pi-desktop/pi-host..." build

  mkdir -p "$WORK/out"
  "$PNPM" --filter @pi-desktop/pi-host exec esbuild src/cli.ts \
    --bundle \
    --platform=node \
    --format=esm \
    --target=node22 \
    --external:node-pty \
    --external:bufferutil \
    --external:utf-8-validate \
    --outfile="$WORK/out/pi-host.js" \
    "--banner:js=import { createRequire as __piCreateRequire } from 'node:module'; const require = __piCreateRequire(import.meta.url);"
)

HELP=$(node "$WORK/out/pi-host.js" --help)
for command in \
  provider-remove \
  provider-binding-status \
  provider-remove-status \
  provider-sync-forget
do
  printf '%s\n' "$HELP" | grep -Eq "^[[:space:]]*$command[[:space:]]" \
    || die "generated pi-host.js is missing command: $command"
done

SIDE_EFFECT_DIR="$WORK/must-not-exist"
set +e
UNKNOWN_OUTPUT=$(node "$WORK/out/pi-host.js" definitely-not-a-subcommand \
  --data-dir "$SIDE_EFFECT_DIR" 2>&1)
UNKNOWN_STATUS=$?
set -e
[ "$UNKNOWN_STATUS" -eq 1 ] \
  || die "unknown subcommand exited $UNKNOWN_STATUS instead of 1"
[ "$UNKNOWN_OUTPUT" = 'PI_HOST_FAILED {"code":"INVALID_REQUEST"}' ] \
  || die "unexpected unknown-subcommand output: $UNKNOWN_OUTPUT"
[ ! -e "$SIDE_EFFECT_DIR" ] \
  || die "unknown subcommand created its data directory"

OUT_DIR=$(dirname -- "$OUT")
mkdir -p "$OUT_DIR"
TMP_OUT=$(mktemp "$OUT_DIR/.$(basename -- "$OUT").XXXXXX")
install -m 0444 "$WORK/out/pi-host.js" "$TMP_OUT"
mv "$TMP_OUT" "$OUT"

printf 'PI_HOST_JS=%s\n' "$OUT"
printf 'SHA256=%s\n' "$(sha256_file "$OUT")"
printf 'BYTES=%s\n' "$(wc -c < "$OUT" | tr -d ' ')"
printf 'BASE_COMMIT=%s\n' "$BASE_COMMIT"
printf 'PATCH_SHA256=%s\n' "$(sha256_file "$PATCH_FILE")"
printf 'CAPABILITY_PROBE=passed\n'
