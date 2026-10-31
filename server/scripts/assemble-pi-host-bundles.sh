#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd -P)

# 版本与上游 pin 一律来自仓库根的 host-release.json（唯一权威源）。
# 不在这里写死版本号：写死就会出现「App 期望新版本、脚本仍产出旧包」这类漂移。
RELEASE_MANIFEST="$REPO_ROOT/host-release.json"
[ -f "$RELEASE_MANIFEST" ] || { echo "missing $RELEASE_MANIFEST" >&2; exit 1; }
manifest_field() {
  python3 -c 'import json,sys
m = json.load(open(sys.argv[1]))
value = m
for key in sys.argv[2].split("."):
    value = value[key]
print(value)' "$RELEASE_MANIFEST" "$1"
}
VERSION=$(manifest_field upstreamVersion)
BUNDLE_VERSION=$(manifest_field version)
BASE_COMMIT=$(manifest_field upstreamCommit)
RELEASE_TAG="v$VERSION"
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1792848890}
X64_SHA256=$(manifest_field upstreamAssets.linux-x64.sha256)
ARM64_SHA256=$(manifest_field upstreamAssets.linux-arm64.sha256)
PATCH_FILE="$REPO_ROOT/server/patches/pi-host-provider-remove.patch"
OUT_DIR="$REPO_ROOT/server/dist"
CACHE_DIR="${TMPDIR:-/tmp}/pi-host-v$VERSION-release-assets"
PI_HOST_JS=
X64_ARCHIVE=
ARM64_ARCHIVE=
QEMU_X86_64=

usage() {
  cat <<'USAGE'
Usage: assemble-pi-host-bundles.sh --pi-host-js <path> [options]

Builds the two linux release archives from the official v0.21.0 bundles by
replacing only pi-host.js and regenerating SHA256SUMS.

Options:
  --pi-host-js <path>       patched architecture-neutral JS bundle
  --out-dir <dir>           output directory (default: server/dist)
  --cache-dir <dir>         official archive cache/download directory
  --x64-archive <path>      existing official linux-x64 archive
  --arm64-archive <path>    existing official linux-arm64 archive
  --qemu-x86_64 <path>      optional qemu user binary for an x64 probe
  -h, --help                show this help

Outputs:
  pi-host-0.21.0+remove.1-linux-x64.tar.gz
  pi-host-0.21.0+remove.1-linux-arm64.tar.gz
  matching .sha256 files
  pi-host-0.21.0+remove.1-manifest.json

This script is Linux-only because it cross-checks GNU tar reproducibility and
ELF architectures. It never reads or changes ~/.pi-desktop/current.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pi-host-js)
      [ "$#" -ge 2 ] || die "--pi-host-js needs a value"
      PI_HOST_JS=$2
      shift 2
      ;;
    --out-dir)
      [ "$#" -ge 2 ] || die "--out-dir needs a value"
      OUT_DIR=$2
      shift 2
      ;;
    --cache-dir)
      [ "$#" -ge 2 ] || die "--cache-dir needs a value"
      CACHE_DIR=$2
      shift 2
      ;;
    --x64-archive)
      [ "$#" -ge 2 ] || die "--x64-archive needs a value"
      X64_ARCHIVE=$2
      shift 2
      ;;
    --arm64-archive)
      [ "$#" -ge 2 ] || die "--arm64-archive needs a value"
      ARM64_ARCHIVE=$2
      shift 2
      ;;
    --qemu-x86_64)
      [ "$#" -ge 2 ] || die "--qemu-x86_64 needs a value"
      QEMU_X86_64=$2
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

[ "$(uname -s)" = Linux ] || die "this assembly script must run on Linux"
tar --version 2>/dev/null | grep -q 'GNU tar' || die "GNU tar is required"
for command in curl gzip file install python3 sha256sum find sort; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done
[ -n "$PI_HOST_JS" ] || die "--pi-host-js is required"
[ -f "$PI_HOST_JS" ] || die "pi-host.js not found: $PI_HOST_JS"
[ -f "$PATCH_FILE" ] || die "patch not found: $PATCH_FILE"

ORIGINAL_OUT_DIR=$OUT_DIR
mkdir -p "$ORIGINAL_OUT_DIR"
OUT_DIR=$(CDPATH= cd -- "$ORIGINAL_OUT_DIR" && pwd -P)

case "$OUT_DIR/" in
  "$HOME/.pi-desktop/"*|"$HOME/.pi-desktop")
    die "refusing to write inside the formal ~/.pi-desktop tree"
    ;;
esac

mkdir -p "$CACHE_DIR"
CACHE_DIR=$(CDPATH= cd -- "$CACHE_DIR" && pwd -P)

ensure_archive() {
  arch=$1
  explicit_path=$2
  expected_sha=$3
  asset="pi-host-$VERSION-linux-$arch.tar.gz"
  url="https://github.com/vastsa/PI-Desktop/releases/download/$RELEASE_TAG/$asset"

  if [ -n "$explicit_path" ]; then
    [ -f "$explicit_path" ] || die "archive not found: $explicit_path"
    actual_sha=$(sha256_file "$explicit_path")
    [ "$actual_sha" = "$expected_sha" ] \
      || die "$explicit_path SHA-256 mismatch: $actual_sha"
    printf '%s\n' "$explicit_path"
    return
  fi

  cached="$CACHE_DIR/$asset"
  if [ ! -f "$cached" ]; then
    partial="$cached.part.$$"
    curl -fL --retry 4 --retry-delay 2 -o "$partial" "$url"
    actual_sha=$(sha256_file "$partial")
    [ "$actual_sha" = "$expected_sha" ] \
      || die "downloaded $asset SHA-256 mismatch: $actual_sha"
    mv "$partial" "$cached"
  fi

  actual_sha=$(sha256_file "$cached")
  [ "$actual_sha" = "$expected_sha" ] \
    || die "$cached SHA-256 mismatch: $actual_sha"
  printf '%s\n' "$cached"
}

X64_ARCHIVE=$(ensure_archive x64 "$X64_ARCHIVE" "$X64_SHA256")
ARM64_ARCHIVE=$(ensure_archive arm64 "$ARM64_ARCHIVE" "$ARM64_SHA256")

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pi-host-bundles.XXXXXX")
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

prepare_bundle() {
  arch=$1
  archive=$2
  extract="$WORK/$arch"
  mkdir -p "$extract"
  tar -xzf "$archive" -C "$extract"

  upstream_root="$extract/pi-host-$VERSION-linux-$arch"
  bundle_name="pi-host-$BUNDLE_VERSION-linux-$arch"
  [ -d "$upstream_root" ] || die "unexpected archive root for $arch"
  mv "$upstream_root" "$extract/$bundle_name"
  root="$extract/$bundle_name"

  install -m 0444 "$PI_HOST_JS" "$root/pi-host.js"
  (
    cd "$root"
    find . -type f ! -name SHA256SUMS -printf '%P\0' \
      | LC_ALL=C sort -z \
      | while IFS= read -r -d '' file; do
          sha256sum -- "$file"
        done > SHA256SUMS
    ./install.sh --verify >/dev/null
  )

  file_count=$(find "$root" -type f | wc -l | tr -d ' ')
  sum_count=$(wc -l < "$root/SHA256SUMS" | tr -d ' ')
  [ "$file_count" -eq $((sum_count + 1)) ] \
    || die "$arch file/checksum count mismatch: $file_count vs $sum_count"
  [ "$(sha256_file "$root/pi-host.js")" = "$(sha256_file "$PI_HOST_JS")" ] \
    || die "$arch pi-host.js replacement mismatch"

  case "$arch" in
    x64)
      node_pattern='x86-64'
      core_pattern='x86-64'
      pty_pattern='x86-64'
      ;;
    arm64)
      node_pattern='ARM aarch64'
      core_pattern='ARM aarch64'
      pty_pattern='ARM aarch64'
      ;;
  esac

  node_file=$(file -b "$root/bin/node")
  core_file=$(file -b "$root/bin/pi-desktop-host-core")
  pty_file=$(file -b "$root/node_modules/node-pty/build/Release/pty.node")
  printf '%s\n' "$node_file" | grep -Fq "$node_pattern" \
    || die "$arch bin/node architecture mismatch: $node_file"
  printf '%s\n' "$core_file" | grep -Fq "$core_pattern" \
    || die "$arch host-core architecture mismatch: $core_file"
  printf '%s\n' "$pty_file" | grep -Fq "$pty_pattern" \
    || die "$arch node-pty architecture mismatch: $pty_file"

  tar_base="$bundle_name"
  tar_tmp="$WORK/$arch.tar.gz"
  (
    cd "$extract"
    tar \
      --sort=name \
      --mtime="@$SOURCE_DATE_EPOCH" \
      --owner=0 \
      --group=0 \
      --numeric-owner \
      --format=gnu \
      -cf - "$tar_base" \
      | gzip -9n > "$tar_tmp"
  )
  artifact="$OUT_DIR/$tar_base.tar.gz"
  mv "$tar_tmp" "$artifact"
  artifact_sha=$(sha256_file "$artifact")
  printf '%s  %s\n' "$artifact_sha" "$(basename -- "$artifact")" \
    > "$artifact.sha256"

  printf '%s\n' "$root|$node_file|$core_file|$pty_file|$artifact|$artifact_sha|$file_count|$sum_count"
}

X64_INFO=$(prepare_bundle x64 "$X64_ARCHIVE")
ARM64_INFO=$(prepare_bundle arm64 "$ARM64_ARCHIVE")

IFS='|' read -r X64_ROOT X64_NODE_FILE X64_CORE_FILE X64_PTY_FILE \
  X64_ARTIFACT X64_ARTIFACT_SHA X64_FILE_COUNT X64_SUM_COUNT <<EOF
$X64_INFO
EOF
IFS='|' read -r ARM64_ROOT ARM64_NODE_FILE ARM64_CORE_FILE ARM64_PTY_FILE \
  ARM64_ARTIFACT ARM64_ARTIFACT_SHA ARM64_FILE_COUNT ARM64_SUM_COUNT <<EOF
$ARM64_INFO
EOF

probe_cli() {
  root=$1
  label=$2
  help_output=$("$root/bin/pi-host" --help)
  for command in \
    provider-remove \
    provider-binding-status \
    provider-remove-status \
    provider-sync-forget
  do
    printf '%s\n' "$help_output" | grep -Eq \
      "^[[:space:]]*$command[[:space:]]" \
      || die "$label capability probe is missing $command"
  done

  probe_data="$WORK/probe-$label"
  set +e
  unknown_output=$("$root/bin/pi-host" definitely-not-a-subcommand \
    --data-dir "$probe_data" 2>&1)
  unknown_status=$?
  set -e
  [ "$unknown_status" -eq 1 ] \
    || die "$label unknown subcommand exited $unknown_status"
  [ "$unknown_output" = 'PI_HOST_FAILED {"code":"INVALID_REQUEST"}' ] \
    || die "$label unknown subcommand output mismatch"
  [ ! -e "$probe_data" ] \
    || die "$label unknown subcommand created its data directory"
}

host_arch=$(uname -m)
if [ "$host_arch" = aarch64 ] || [ "$host_arch" = arm64 ]; then
  probe_cli "$ARM64_ROOT" linux-arm64
  ARM64_PROBE=passed-native
else
  ARM64_PROBE=skipped-non-native
fi

if [ "$host_arch" = x86_64 ] || [ "$host_arch" = amd64 ]; then
  probe_cli "$X64_ROOT" linux-x64
  X64_PROBE=passed-native
elif [ -n "$QEMU_X86_64" ]; then
  [ -x "$QEMU_X86_64" ] || die "qemu binary is not executable: $QEMU_X86_64"
  qemu_help=$("$QEMU_X86_64" "$X64_ROOT/bin/node" "$X64_ROOT/pi-host.js" --help 2>&1) \
    || die "qemu x64 capability probe failed: $qemu_help"
  for command in \
    provider-remove \
    provider-binding-status \
    provider-remove-status \
    provider-sync-forget
  do
    printf '%s\n' "$qemu_help" | grep -Eq \
      "^[[:space:]]*$command[[:space:]]" \
      || die "qemu x64 capability probe is missing $command"
  done
  qemu_data="$WORK/probe-qemu-x64"
  set +e
  qemu_unknown=$("$QEMU_X86_64" "$X64_ROOT/bin/node" \
    "$X64_ROOT/pi-host.js" definitely-not-a-subcommand \
    --data-dir "$qemu_data" 2>&1)
  qemu_status=$?
  set -e
  [ "$qemu_status" -eq 1 ] \
    || die "qemu x64 unknown subcommand exited $qemu_status"
  [ "$qemu_unknown" = 'PI_HOST_FAILED {"code":"INVALID_REQUEST"}' ] \
    || die "qemu x64 unknown subcommand output mismatch"
  [ ! -e "$qemu_data" ] \
    || die "qemu x64 unknown subcommand created its data directory"
  X64_PROBE=passed-qemu
else
  X64_PROBE=skipped-no-native-or-qemu
fi

MANIFEST="$OUT_DIR/pi-host-$BUNDLE_VERSION-manifest.json"
export MANIFEST
export BUNDLE_VERSION
export VERSION
export BASE_COMMIT
export RELEASE_TAG
export SOURCE_DATE_EPOCH
export PATCH_SHA256
PATCH_SHA256=$(sha256_file "$PATCH_FILE")
export PI_HOST_JS_SHA256
PI_HOST_JS_SHA256=$(sha256_file "$PI_HOST_JS")
export PI_HOST_JS_BYTES
PI_HOST_JS_BYTES=$(wc -c < "$PI_HOST_JS" | tr -d ' ')
export X64_SHA256 ARM64_SHA256
export X64_ARTIFACT X64_ARTIFACT_SHA X64_FILE_COUNT X64_SUM_COUNT
export ARM64_ARTIFACT ARM64_ARTIFACT_SHA ARM64_FILE_COUNT ARM64_SUM_COUNT
export X64_NODE_FILE X64_CORE_FILE X64_PTY_FILE X64_PROBE
export ARM64_NODE_FILE ARM64_CORE_FILE ARM64_PTY_FILE ARM64_PROBE

python3 <<'PY'
import json
import os
from pathlib import Path

def artifact(path_value, sha, files, sums):
    path = Path(path_value)
    return {
        "file": path.name,
        "sha256": sha,
        "bytes": path.stat().st_size,
        "topLevel": path.name[:-7],
        "files": int(files),
        "checksumEntries": int(sums),
    }

manifest = {
    "schemaVersion": 1,
    "product": "pi-host",
    "version": os.environ["BUNDLE_VERSION"],
    "upstreamVersion": os.environ["VERSION"],
    "releaseTag": os.environ["RELEASE_TAG"],
    "baseCommit": os.environ["BASE_COMMIT"],
    "patch": {
        "path": "server/patches/pi-host-provider-remove.patch",
        "sha256": os.environ["PATCH_SHA256"],
    },
    "piHostJs": {
        "sha256": os.environ["PI_HOST_JS_SHA256"],
        "bytes": int(os.environ["PI_HOST_JS_BYTES"]),
    },
    "baseAssets": {
        "linux-x64": {
            "name": "pi-host-0.21.0-linux-x64.tar.gz",
            "sha256": os.environ["X64_SHA256"],
        },
        "linux-arm64": {
            "name": "pi-host-0.21.0-linux-arm64.tar.gz",
            "sha256": os.environ["ARM64_SHA256"],
        },
    },
    "artifacts": {
        "linux-x64": artifact(
            os.environ["X64_ARTIFACT"],
            os.environ["X64_ARTIFACT_SHA"],
            os.environ["X64_FILE_COUNT"],
            os.environ["X64_SUM_COUNT"],
        ),
        "linux-arm64": artifact(
            os.environ["ARM64_ARTIFACT"],
            os.environ["ARM64_ARTIFACT_SHA"],
            os.environ["ARM64_FILE_COUNT"],
            os.environ["ARM64_SUM_COUNT"],
        ),
    },
    "verification": {
        "installerSelfVerify": "passed-for-both",
        "sourceDateEpoch": int(os.environ["SOURCE_DATE_EPOCH"]),
        "architectures": {
            "linux-x64": {
                "node": os.environ["X64_NODE_FILE"],
                "hostCore": os.environ["X64_CORE_FILE"],
                "nodePty": os.environ["X64_PTY_FILE"],
                "capabilityProbe": os.environ["X64_PROBE"],
            },
            "linux-arm64": {
                "node": os.environ["ARM64_NODE_FILE"],
                "hostCore": os.environ["ARM64_CORE_FILE"],
                "nodePty": os.environ["ARM64_PTY_FILE"],
                "capabilityProbe": os.environ["ARM64_PROBE"],
            },
        },
    },
}

with open(os.environ["MANIFEST"], "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, ensure_ascii=True, indent=2, sort_keys=True)
    handle.write("\n")

# 产物摘要必须与 host-release.json 一致：否则「发了包、App 仍按旧摘要下载旧字节」。
# 版本升级时先改 host-release.json 的 version，再跑一次本脚本；摘要用
# UPDATE_RELEASE_MANIFEST=1 写回同一份 JSON，避免手抄出漂移。
verify_release_manifest() {
  python3 - "$RELEASE_MANIFEST" "$X64_ARTIFACT" "$X64_ARTIFACT_SHA" "$ARM64_ARTIFACT" "$ARM64_ARTIFACT_SHA" <<'PYV'
import json, sys
manifest_path, x64_file, x64_sha, arm64_file, arm64_sha = sys.argv[1:6]
manifest = json.load(open(manifest_path, encoding="utf-8"))
import os
update = os.environ.get("UPDATE_RELEASE_MANIFEST") == "1"
problems = []
changed = False
for key, path, digest in (
    ("linux-x64", x64_file, x64_sha),
    ("linux-arm64", arm64_file, arm64_sha),
):
    entry = manifest["artifacts"][key]
    name = os.path.basename(path)
    if entry.get("file") != name:
        problems.append(f"{key}: host-release.json file={entry.get('file')} 与产物 {name} 不一致")
    if entry.get("sha256") != digest:
        if update:
            entry["sha256"] = digest
            changed = True
        else:
            problems.append(f"{key}: host-release.json sha256={entry.get('sha256')} 与产物 {digest} 不一致")
if update and changed:
    json.dump(manifest, open(manifest_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    open(manifest_path, "a", encoding="utf-8").write("\n")
    print("host-release.json 已写回新的产物摘要")
if problems:
    print("host-release 校验失败：", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    print("确认这是有意升级后，用 UPDATE_RELEASE_MANIFEST=1 重跑本脚本写回摘要", file=sys.stderr)
    sys.exit(1)
PYV
}
verify_release_manifest
PY

manifest_sha=$(sha256_file "$MANIFEST")
printf '%s  %s\n' "$manifest_sha" "$(basename -- "$MANIFEST")" \
  > "$MANIFEST.sha256"

printf 'X64_ARTIFACT=%s\n' "$X64_ARTIFACT"
printf 'X64_SHA256=%s\n' "$X64_ARTIFACT_SHA"
printf 'ARM64_ARTIFACT=%s\n' "$ARM64_ARTIFACT"
printf 'ARM64_SHA256=%s\n' "$ARM64_ARTIFACT_SHA"
printf 'MANIFEST=%s\n' "$MANIFEST"
printf 'MANIFEST_SHA256=%s\n' "$manifest_sha"
printf 'X64_PROBE=%s\n' "$X64_PROBE"
printf 'ARM64_PROBE=%s\n' "$ARM64_PROBE"
