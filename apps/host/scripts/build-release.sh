#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
MANIFEST="$ROOT/../../host-release.json"
PKG_VERSION=$(node -p "require('$ROOT/package.json').version")
VERSION="${1:-$PKG_VERSION}"
TARGET_ARG="${2:-all}"
OUT_ARG="${3:-$ROOT/release}"

if [[ ! "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
  printf 'invalid version: %s\n' "$VERSION" >&2
  exit 1
fi
RELEASE_VERSION=$(node -p "require('$MANIFEST').version")
RELEASE_TAG=$(node -p "require('$MANIFEST').releaseTag")
if [[ "$VERSION" != "$RELEASE_VERSION" ]]; then
  printf 'release version %s does not match host-release.json %s\n' "$VERSION" "$RELEASE_VERSION" >&2
  exit 1
fi
if [[ "$RELEASE_TAG" != "pi-adaptor-v$VERSION" ]]; then
  printf 'host-release.json tag %s does not match pi-adaptor-v%s\n' "$RELEASE_TAG" "$VERSION" >&2
  exit 1
fi
case "$TARGET_ARG" in
  all) TARGETS=(linux-arm64 linux-x64) ;;
  linux-arm64|linux-x64) TARGETS=("$TARGET_ARG") ;;
  *)
    printf 'invalid target: %s\n' "$TARGET_ARG" >&2
    exit 1
    ;;
esac

mkdir -p "$OUT_ARG"
OUT=$(CDPATH= cd -- "$OUT_ARG" && pwd -P)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pi-adaptor-release.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

cd "$ROOT"
pnpm build

# The package manifest is the runtime version source. A release name must never
# disagree with the bytes that report HOST_VERSION.
BUILT_VERSION=$(node -e 'import("./dist/config.js").then((m) => process.stdout.write(m.HOST_VERSION))')
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
  printf 'built host reports version %s but release name is %s\n' "$BUILT_VERSION" "$VERSION" >&2
  exit 1
fi

target_cpu() {
  case "$1" in
    linux-arm64) printf 'arm64' ;;
    linux-x64) printf 'x64' ;;
  esac
}

make_production_tree() {
  target=$1
  destination=$2
  cpu=$(target_cpu "$target")
  mkdir -p "$destination"
  cp package.json pnpm-lock.yaml "$destination/"
  (
    cd "$destination"
    pnpm install \
      --prod \
      --ignore-scripts \
      --force \
      --config.node-linker=hoisted \
      --cpu="$cpu" \
      --os=linux \
      --libc=glibc
  )
  rm -rf "$destination/node_modules/.bin"
}

prune_target_native_dependencies() {
  target=$1
  bundle=$2
  cpu=$(target_cpu "$target")
  native="$bundle/node_modules/@earendil-works/pi-tui/native"
  required="$native/linux/prebuilds/linux-$cpu/linux-platform-x11.node"

  [[ -d "$native" ]] || {
    printf 'target dependency tree is missing pi-tui native files\n' >&2
    exit 1
  }
  rm -rf "$native/darwin" "$native/win32"
  find "$native/linux/prebuilds" -mindepth 1 -maxdepth 1 -type d \
    ! -name "linux-$cpu" -exec rm -rf {} +
  [[ -f "$required" ]] || {
    printf 'target dependency tree is missing %s\n' "$required" >&2
    exit 1
  }
}

write_manifest() {
  bundle=$1
  python3 - "$bundle" <<'PY'
import hashlib
import os
import stat
import sys

root = os.path.abspath(sys.argv[1])
entries = []
for directory, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(filenames):
        path = os.path.join(directory, name)
        mode = os.lstat(path).st_mode
        if stat.S_ISLNK(mode):
            raise SystemExit(f"bundle contains symlink: {path}")
        if not stat.S_ISREG(mode):
            raise SystemExit(f"bundle contains non-regular file: {path}")
        relative = os.path.relpath(path, root).replace(os.sep, "/")
        if relative == "SHA256SUMS":
            continue
        if relative.startswith("/") or "../" in relative.split("/"):
            raise SystemExit(f"unsafe bundle path: {relative}")
        with open(path, "rb") as handle:
            digest = hashlib.sha256()
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        entries.append((relative, digest.hexdigest()))
entries.sort(key=lambda item: item[0].encode("utf-8"))
with open(os.path.join(root, "SHA256SUMS"), "w", encoding="utf-8", newline="\n") as handle:
    for relative, digest in entries:
        handle.write(f"{digest}  {relative}\n")
PY
}

for target in "${TARGETS[@]}"; do
  bundle_name="pi-adaptor-$VERSION-$target"
  bundle="$STAGE/$bundle_name"
  prod="$STAGE/prod-$target"
  mkdir -p "$bundle"
  mkdir -p "$bundle/scripts"
  cp -R dist package.json "$bundle/"
  cp scripts/install.sh "$bundle/scripts/install.sh"
  make_production_tree "$target" "$prod"
  cp -R "$prod/node_modules" "$bundle/node_modules"
  prune_target_native_dependencies "$target" "$bundle"
  chmod 755 "$bundle/scripts/install.sh"

  # Remove volatile metadata before manifest generation and archive creation.
  find "$bundle" -exec touch -t 200001010000 {} +
  write_manifest "$bundle"
  find "$bundle/SHA256SUMS" -exec touch -t 200001010000 {} +

  archive="$OUT/$bundle_name.tar.gz"
  rm -f "$archive" "$archive.sha256"
  COPYFILE_DISABLE=1 tar \
    --format=ustar \
    --uid=0 \
    --gid=0 \
    --uname=root \
    --gname=root \
    -C "$STAGE" \
    -czf "$archive" \
    "$bundle_name"
  python3 - "$archive" "$bundle_name" "$target" <<'PY'
import posixpath
import sys
import tarfile

archive, bundle, target = sys.argv[1:]
required = (
    f"{bundle}/node_modules/@earendil-works/pi-tui/native/"
    f"linux/prebuilds/linux-{'x64' if target == 'linux-x64' else 'arm64'}/"
    "linux-platform-x11.node"
)
with tarfile.open(archive, "r:gz") as handle:
    members = handle.getmembers()
    names = [member.name.rstrip("/") for member in members]
    if not names or {name.split("/", 1)[0] for name in names} != {bundle}:
        raise SystemExit(f"archive must contain only top-level bundle {bundle}")
    for member in members:
        normalized = posixpath.normpath(member.name)
        if normalized.startswith("../") or normalized.startswith("/"):
            raise SystemExit(f"unsafe archive path: {member.name}")
        if member.issym() or member.islnk():
            raise SystemExit(f"archive contains a link: {member.name}")
    if required not in names:
        raise SystemExit(f"archive is missing target native dependency: {required}")
    foreign = [
        name for name in names
        if "/@earendil-works/pi-tui/native/" in name and name.endswith(".node") and name != required
    ]
    if foreign:
        raise SystemExit(f"archive contains foreign native dependencies: {foreign[:3]}")
PY
  (
    cd "$OUT"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$bundle_name.tar.gz" >"$bundle_name.tar.gz.sha256"
    else
      shasum -a 256 "$bundle_name.tar.gz" >"$bundle_name.tar.gz.sha256"
    fi
  )
  printf '%s\n' "$archive"
done
