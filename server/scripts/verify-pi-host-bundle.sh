#!/usr/bin/env bash
set -euo pipefail

ARCHIVE=
BUNDLE_ROOT=
KEEP_WORK=0

usage() {
  cat <<'USAGE'
Usage: verify-pi-host-bundle.sh (--archive <tar.gz> | --bundle-root <dir>) [options]

Verifies a pi-host bundle on a matching native architecture:
  - optional outer SHA-256 sidecar
  - installer self-verification
  - all five CLI command names
  - isolated Host startup (host-core + agent sidecar)
  - provider-import
  - provider-remove-status before deletion
  - provider-remove effect=deleted
  - repeat provider-remove effect=absent
  - provider-remove-status after deletion
  - graceful Host shutdown

Options:
  --keep-work    retain the temporary extraction/data directory
  -h, --help     show this help
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --archive)
      [ "$#" -ge 2 ] || die "--archive needs a value"
      ARCHIVE=$2
      shift 2
      ;;
    --bundle-root)
      [ "$#" -ge 2 ] || die "--bundle-root needs a value"
      BUNDLE_ROOT=$2
      shift 2
      ;;
    --keep-work)
      KEEP_WORK=1
      shift
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

[ "$(uname -s)" = Linux ] || die "this probe must run on Linux"
for command in find grep install mkdir mktemp sed sha256sum sleep tar; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done

if [ -n "$ARCHIVE" ] && [ -n "$BUNDLE_ROOT" ]; then
  die "use either --archive or --bundle-root, not both"
fi
if [ -z "$ARCHIVE" ] && [ -z "$BUNDLE_ROOT" ]; then
  die "--archive or --bundle-root is required"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pi-host-probe.XXXXXX")
HOST_PID=
SUCCESS=0

cleanup() {
  if [ -n "$HOST_PID" ] && kill -0 "$HOST_PID" 2>/dev/null; then
    kill -TERM "$HOST_PID" 2>/dev/null || true
    for _ in $(seq 1 40); do
      kill -0 "$HOST_PID" 2>/dev/null || break
      sleep 0.25
    done
    kill -KILL "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
  if [ "$SUCCESS" -eq 1 ] && [ "$KEEP_WORK" -eq 0 ]; then
    rm -rf "$WORK"
  else
    printf 'PROBE_WORK_DIR=%s\n' "$WORK" >&2
    [ ! -f "$WORK/host.stderr" ] || cat "$WORK/host.stderr" >&2
    [ ! -f "$WORK/host.stdout" ] || cat "$WORK/host.stdout" >&2
  fi
}
trap cleanup EXIT HUP INT TERM

if [ -n "$ARCHIVE" ]; then
  [ -f "$ARCHIVE" ] || die "archive not found: $ARCHIVE"
  if [ -f "$ARCHIVE.sha256" ]; then
    (
      cd "$(dirname -- "$ARCHIVE")"
      sha256sum -c "$(basename -- "$ARCHIVE").sha256"
    )
  fi
  tar -xzf "$ARCHIVE" -C "$WORK"
  ROOT_COUNT=$(find "$WORK" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$ROOT_COUNT" -eq 1 ] || die "archive must contain exactly one top-level directory"
  ROOT=$(find "$WORK" -mindepth 1 -maxdepth 1 -type d)
else
  [ -d "$BUNDLE_ROOT" ] || die "bundle root not found: $BUNDLE_ROOT"
  ROOT=$(CDPATH= cd -- "$BUNDLE_ROOT" && pwd -P)
fi

[ -x "$ROOT/bin/pi-host" ] || die "missing executable bin/pi-host"
[ -x "$ROOT/bin/node" ] || die "missing executable bin/node"
[ -x "$ROOT/bin/pi-desktop-host-core" ] || die "missing executable host-core"
[ -f "$ROOT/pi-host.js" ] || die "missing pi-host.js"

(
  cd "$ROOT"
  ./install.sh --verify >/dev/null
)
printf 'INSTALLER_SELF_VERIFY=passed\n'

HELP=$("$ROOT/bin/pi-host" --help)
for command in \
  provider-import \
  provider-remove \
  provider-binding-status \
  provider-remove-status \
  provider-sync-forget
do
  printf '%s\n' "$HELP" | grep -Eq "^[[:space:]]*$command[[:space:]]" \
    || die "help is missing command: $command"
done
printf 'CLI_COMMANDS=passed\n'

DATA="$WORK/data"
mkdir -m 700 "$DATA"
NODE_OPTIONS= NODE_PATH= \
  "$ROOT/bin/pi-host" --data-dir "$DATA" --port 0 \
  >"$WORK/host.stdout" 2>"$WORK/host.stderr" &
HOST_PID=$!

READY=
for _ in $(seq 1 120); do
  if grep -q '^PI_HOST_READY ' "$WORK/host.stdout"; then
    READY=$(grep '^PI_HOST_READY ' "$WORK/host.stdout" | tail -1)
    break
  fi
  kill -0 "$HOST_PID" 2>/dev/null || die "Host exited before PI_HOST_READY"
  sleep 0.25
done
[ -n "$READY" ] || die "Host did not become ready"
printf '%s\n' "$READY"

PAYLOAD='{"version":1,"providers":[{"sourceId":"bundle-smoke","input":{"name":"Bundle Smoke","vendorKey":"custom","type":"openai_compatible","protocol":"openai_compatible","baseUrl":"https://models.example/v1","authKind":"api_key","secretValue":"bundle-smoke-secret","models":[{"id":"bundle-smoke","contextWindow":8000,"maxTokens":1000,"thinkingLevels":["off"],"defaultThinkingLevel":null}]}}]}'
IMPORT=$(
  printf '%s\n' "$PAYLOAD" \
    | "$ROOT/bin/pi-host" provider-import --data-dir "$DATA"
)
printf '%s\n' "$IMPORT"
printf '%s\n' "$IMPORT" | grep -q '^PI_HOST_PROVIDERS ' \
  || die "provider-import did not return PI_HOST_PROVIDERS"
PROVIDER_ID=$(
  printf '%s\n' "$IMPORT" \
    | sed -n 's/.*"providerId":"\([0-9a-fA-F-]\{36\}\)".*/\1/p' \
    | head -1
)
[ -n "$PROVIDER_ID" ] || die "provider-import did not return a provider id"

REMOVE_PAYLOAD="{\"version\":1,\"providerId\":\"$PROVIDER_ID\"}"
STATUS_BEFORE=$(
  printf '%s\n' "$REMOVE_PAYLOAD" \
    | "$ROOT/bin/pi-host" provider-remove-status --data-dir "$DATA"
)
printf '%s\n' "$STATUS_BEFORE"
printf '%s\n' "$STATUS_BEFORE" | grep -q '"recordPresent":true' \
  || die "status before removal did not observe the provider"
printf '%s\n' "$STATUS_BEFORE" | grep -q '"secretPresent":true' \
  || die "status before removal did not observe the secret"

REMOVED=$(
  printf '%s\n' "$REMOVE_PAYLOAD" \
    | "$ROOT/bin/pi-host" provider-remove --data-dir "$DATA"
)
printf '%s\n' "$REMOVED"
printf '%s\n' "$REMOVED" | grep -q '^PI_HOST_REMOVED ' \
  || die "provider-remove did not return PI_HOST_REMOVED"
printf '%s\n' "$REMOVED" | grep -q '"effect":"deleted"' \
  || die "first provider-remove was not effect=deleted"
printf '%s\n' "$REMOVED" | grep -q '"secretCleared":true' \
  || die "first provider-remove did not clear the secret"

REMOVED_AGAIN=$(
  printf '%s\n' "$REMOVE_PAYLOAD" \
    | "$ROOT/bin/pi-host" provider-remove --data-dir "$DATA"
)
printf '%s\n' "$REMOVED_AGAIN"
printf '%s\n' "$REMOVED_AGAIN" | grep -q '"effect":"absent"' \
  || die "repeat provider-remove was not idempotent absent"

STATUS_AFTER=$(
  printf '%s\n' "$REMOVE_PAYLOAD" \
    | "$ROOT/bin/pi-host" provider-remove-status --data-dir "$DATA"
)
printf '%s\n' "$STATUS_AFTER"
printf '%s\n' "$STATUS_AFTER" | grep -q '"recordPresent":false' \
  || die "status after removal still observed the provider"
printf '%s\n' "$STATUS_AFTER" | grep -q '"secretPresent":false' \
  || die "status after removal still observed the secret"

kill -TERM "$HOST_PID"
wait "$HOST_PID"
HOST_PID=
printf 'HOST_SHUTDOWN=passed\n'

SUCCESS=1
printf 'PI_HOST_BUNDLE_VERIFY_OK\n'
