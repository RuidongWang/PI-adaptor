#!/usr/bin/env bash
set -euo pipefail

readonly EXIT_USAGE=2
readonly EXIT_VERSION=3
readonly EXIT_MANIFEST=4
readonly EXIT_STATE=5
readonly EXIT_FILESYSTEM=6
readonly EXIT_VERIFY=7
readonly EXIT_ROLLBACK=8

ACTION=""
BUNDLE=""
HOME_DIR=""
VERSION=""
TARGET=""
ASSET_SHA256=""
MANIFEST_SHA256=""
INSTALL_DIR=""
PREVIOUS_CURRENT_TARGET=""
FAILED_INSTALL_DIR=""

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

fail() {
  code=$1
  status=$2
  detail=${3:-}
  printf '{"code":"%s","details":{"reason":"%s"}}\n' \
    "$(json_escape "$code")" "$(json_escape "$detail")" >&2
  exit "$status"
}

usage() {
  fail "usage-invalid" "$EXIT_USAGE" "expected --install, --verify, or --rollback"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print tolower($1)}'
  else
    fail "filesystem-failed" "$EXIT_FILESYSTEM" "sha256 tool unavailable"
  fi
}

is_absolute() {
  case "$1" in
    /*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_sha256() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

validate_version() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] &&
    [[ "$1" != "current" && "$1" != "current.next" && "$1" != "releases" ]]
}

validate_target() {
  [[ "$1" == "linux-x64" || "$1" == "linux-arm64" ]]
}

canonical_release_relative() {
  home=$1
  raw=$2
  case "$raw" in
    "$home"/releases/*) raw=${raw#"$home"/} ;;
  esac
  [[ "$raw" =~ ^releases/([A-Za-z0-9][A-Za-z0-9._+-]*-[0-9a-f]{64})$ ]] ||
    return 1
  release_name=${BASH_REMATCH[1]}
  [[ "$release_name" != "." && "$release_name" != ".." ]] || return 1
  releases_real=$(CDPATH= cd -- "$home/releases" 2>/dev/null && pwd -P) ||
    return 1
  [[ "$releases_real" == "$home/releases" ]] || return 1
  candidate="$releases_real/$release_name"
  [[ -d "$candidate" && ! -L "$candidate" ]] || return 1
  candidate_real=$(CDPATH= cd -- "$candidate" && pwd -P) || return 1
  [[ "$candidate_real" == "$candidate" ]] || return 1
  printf 'releases/%s' "$release_name"
}

require_value() {
  if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
    usage
  fi
}

parse_action() {
  [[ $# -gt 0 ]] || usage
  ACTION=$1
  shift
  SEEN=" "
  while [[ $# -gt 0 ]]; do
    key=$1
    case "$SEEN" in
      *" $key "*) usage ;;
    esac
    SEEN="$SEEN$key "
    case "$ACTION:$key" in
      --install:--bundle) require_value "$@"; BUNDLE=$2 ;;
      --install:--home) require_value "$@"; HOME_DIR=$2 ;;
      --install:--version) require_value "$@"; VERSION=$2 ;;
      --install:--target) require_value "$@"; TARGET=$2 ;;
      --install:--asset-sha256) require_value "$@"; ASSET_SHA256=$2 ;;
      --install:--manifest-sha256) require_value "$@"; MANIFEST_SHA256=$2 ;;
      --verify:--install-dir) require_value "$@"; INSTALL_DIR=$2 ;;
      --verify:--version) require_value "$@"; VERSION=$2 ;;
      --verify:--target) require_value "$@"; TARGET=$2 ;;
      --verify:--asset-sha256) require_value "$@"; ASSET_SHA256=$2 ;;
      --verify:--manifest-sha256) require_value "$@"; MANIFEST_SHA256=$2 ;;
      --rollback:--home) require_value "$@"; HOME_DIR=$2 ;;
      --rollback:--previous-current-target) require_value "$@"; PREVIOUS_CURRENT_TARGET=$2 ;;
      --rollback:--failed-install-dir) require_value "$@"; FAILED_INSTALL_DIR=$2 ;;
      *) usage ;;
    esac
    shift 2
  done
}

verify_tree() {
  tree=$1
  [[ -d "$tree" ]] || fail "verify-failed" "$EXIT_VERIFY" "install tree missing"
  [[ ! -L "$tree" ]] || fail "state-mismatch" "$EXIT_STATE" "install tree must not be a symbolic link"
  [[ -f "$tree/package.json" ]] || fail "verify-failed" "$EXIT_VERIFY" "package.json missing"
  [[ -f "$tree/dist/main.js" ]] || fail "version-mismatch" "$EXIT_VERSION" "dist/main.js missing"
  [[ -f "$tree/scripts/install.sh" ]] || fail "version-mismatch" "$EXIT_VERSION" "scripts/install.sh missing"
  [[ -f "$tree/SHA256SUMS" ]] || fail "manifest-integrity-failed" "$EXIT_MANIFEST" "SHA256SUMS missing"

  found_symlink=$(find "$tree" -type l -print -quit)
  if [[ -n "$found_symlink" ]]; then
    fail "manifest-integrity-failed" "$EXIT_MANIFEST" "bundle contains symbolic link: $found_symlink"
  fi

  actual_manifest_sha256=$(sha256_of "$tree/SHA256SUMS")
  [[ "$actual_manifest_sha256" == "$MANIFEST_SHA256" ]] ||
    fail "manifest-integrity-failed" "$EXIT_MANIFEST" "SHA256SUMS digest mismatch"

  node_path=$(command -v node) ||
    fail "version-mismatch" "$EXIT_VERSION" "Node executable unavailable"
  package_name=$("$node_path" -e '
    const fs = require("fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.stdout.write(String(value.name || "") + "\n" + String(value.version || ""));
  ' "$tree/package.json") ||
    fail "version-mismatch" "$EXIT_VERSION" "package.json is invalid"
  actual_name=$(printf '%s\n' "$package_name" | sed -n '1p')
  actual_version=$(printf '%s\n' "$package_name" | sed -n '2p')
  [[ "$actual_name" == "@pi-ios/pi-adaptor" ]] ||
    fail "version-mismatch" "$EXIT_VERSION" "package name mismatch"
  [[ "$actual_version" == "$VERSION" ]] ||
    fail "version-mismatch" "$EXIT_VERSION" "package version mismatch"

  node_minimum="22.19.0"
  "$node_path" -e '
    const parse = (value) => value.split(".").map((part) => Number(part));
    const current = parse(process.versions.node);
    const minimum = parse(process.argv[1]);
    for (let i = 0; i < 3; i += 1) {
      if (current[i] > minimum[i]) process.exit(0);
      if (current[i] < minimum[i]) process.exit(1);
    }
  ' "$node_minimum" || fail "version-mismatch" "$EXIT_VERSION" "Node version below $node_minimum"

  case "$(uname -m)" in
    x86_64|amd64) actual_target="linux-x64" ;;
    aarch64|arm64) actual_target="linux-arm64" ;;
    *) actual_target="unsupported" ;;
  esac
  [[ "$actual_target" == "$TARGET" ]] ||
    fail "version-mismatch" "$EXIT_VERSION" "target architecture mismatch"

  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$tree" && sha256sum -c SHA256SUMS >/dev/null) ||
      fail "manifest-integrity-failed" "$EXIT_MANIFEST" "installed files failed checksum verification"
  else
    (cd "$tree" && shasum -a 256 -c SHA256SUMS >/dev/null) ||
      fail "manifest-integrity-failed" "$EXIT_MANIFEST" "installed files failed checksum verification"
  fi
}

switch_current() {
  home=$1
  relative_target=$2
  next="$home/current.next"
  rm -f "$next" ||
    fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not clear current.next"
  ln -s "$relative_target" "$next" ||
    fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not create current.next"
  # rename(2) replaces the destination symlink itself. Portable `mv` follows
  # an existing symlink-to-directory on some systems and moves current.next
  # into the active release instead of atomically replacing `current`.
  node_path=$(command -v node) ||
    fail "version-mismatch" "$EXIT_VERSION" "Node executable unavailable"
  "$node_path" -e 'require("fs").renameSync(process.argv[1], process.argv[2])' \
    "$next" "$home/current" ||
    fail "state-mismatch" "$EXIT_STATE" "could not atomically switch current"
}

resolve_previous_current() {
  home=$1
  current="$home/current"
  [[ -e "$current" || -L "$current" ]] || {
    printf 'none'
    return
  }
  [[ -L "$current" ]] ||
    fail "state-mismatch" "$EXIT_STATE" "current is not a symbolic link"
  raw=$(readlink "$current")
  case "$raw" in
    releases/*|"$home"/releases/*) ;;
    *) fail "state-mismatch" "$EXIT_STATE" "current target is outside releases" ;;
  esac
  canonical_release_relative "$home" "$raw" ||
    fail "state-mismatch" "$EXIT_STATE" "current target is not a canonical release directory"
}

write_receipt() {
  home=$1
  install_directory=$2
  bundle_directory="pi-adaptor-$VERSION-$TARGET"
  bootstrap="$home/.bootstrap"
  mkdir -p "$bootstrap" ||
    fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not create bootstrap directory"
  chmod 700 "$bootstrap" ||
    fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not secure bootstrap directory"
  receipt="$bootstrap/install-receipt.json"
  tmp="$receipt.tmp.$$"
  {
    printf '{"schemaVersion":1,"version":"%s","target":"%s",' \
      "$(json_escape "$VERSION")" "$(json_escape "$TARGET")"
    printf '"assetSha256":"%s","installedManifestSha256":"%s",' \
      "$(json_escape "$ASSET_SHA256")" "$(json_escape "$MANIFEST_SHA256")"
    printf '"bundleDirectory":"%s","installDirectory":"%s",' \
      "$(json_escape "$bundle_directory")" "$(json_escape "$install_directory")"
    printf '"entrypoint":"dist/main.js","unitName":"pi-adaptor.service",'
    printf '"activatedAt":"%s"}\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } >"$tmp" || fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not write receipt"
  chmod 600 "$tmp" || fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not secure receipt"
  mv -f "$tmp" "$receipt" || fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not publish receipt"
}

install_action() {
  is_absolute "$BUNDLE" || usage
  is_absolute "$HOME_DIR" || usage
  validate_version "$VERSION" || usage
  validate_target "$TARGET" || usage
  validate_sha256 "$ASSET_SHA256" || usage
  validate_sha256 "$MANIFEST_SHA256" || usage
  [[ -d "$BUNDLE" ]] || fail "filesystem-failed" "$EXIT_FILESYSTEM" "bundle directory missing"

  BUNDLE=$(CDPATH= cd -- "$BUNDLE" && pwd -P) ||
    fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not resolve bundle directory"
  mkdir -p "$HOME_DIR" ||
    fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not create install home"
  chmod 700 "$HOME_DIR" ||
    fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not secure install home"
  HOME_DIR=$(CDPATH= cd -- "$HOME_DIR" && pwd -P) ||
    fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not resolve install home"
  releases="$HOME_DIR/releases"
  install_id="$VERSION-$ASSET_SHA256"
  destination="$releases/$install_id"
  mkdir -p "$releases" || fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not create releases directory"
  [[ ! -L "$releases" ]] ||
    fail "state-mismatch" "$EXIT_STATE" "releases directory must not be a symbolic link"
  releases_real=$(CDPATH= cd -- "$releases" && pwd -P) ||
    fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not resolve releases directory"
  [[ "$releases_real" == "$releases" ]] ||
    fail "state-mismatch" "$EXIT_STATE" "releases directory resolves outside install home"
  chmod 700 "$releases" ||
    fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not secure install directories"
  previous=$(resolve_previous_current "$HOME_DIR")

  STAGE=""
  cleanup_stage() {
    if [[ -n "${STAGE:-}" && -d "$STAGE" ]]; then
      rm -rf "$STAGE"
    fi
  }
  trap cleanup_stage EXIT

  if [[ -L "$destination" ]]; then
    fail "state-mismatch" "$EXIT_STATE" "release directory must not be a symbolic link"
  elif [[ -d "$destination" ]]; then
    verify_tree "$destination"
  else
    STAGE="$releases/.staging-$install_id-$$"
    rm -rf "$STAGE"
    mkdir -p "$STAGE" || fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not create staging directory"
    cp -R "$BUNDLE"/. "$STAGE"/ ||
      fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not stage bundle"
    verify_tree "$STAGE"
    if [[ -d "$destination" ]]; then
      verify_tree "$destination"
      rm -rf "$STAGE"
      STAGE=""
    else
      mv "$STAGE" "$destination" ||
        fail "filesystem-failed" "$EXIT_FILESYSTEM" "could not publish immutable release"
      STAGE=""
    fi
  fi

  current_relative="releases/$install_id"
  switch_current "$HOME_DIR" "$current_relative"
  write_receipt "$HOME_DIR" "$destination"

  previous_json=null
  [[ "$previous" == "none" ]] || previous_json="\"$(json_escape "$previous")\""
  printf '{"installDirectory":"%s","previousCurrentTarget":%s,"currentTarget":"%s"}\n' \
    "$(json_escape "$destination")" "$previous_json" "$(json_escape "$current_relative")"
}

verify_action() {
  is_absolute "$INSTALL_DIR" || usage
  validate_version "$VERSION" || usage
  validate_target "$TARGET" || usage
  validate_sha256 "$ASSET_SHA256" || usage
  validate_sha256 "$MANIFEST_SHA256" || usage
  INSTALL_DIR=$(CDPATH= cd -- "$INSTALL_DIR" && pwd -P) ||
    fail "verify-failed" "$EXIT_VERIFY" "install directory is unavailable"
  expected_name="$VERSION-$ASSET_SHA256"
  [[ "$(basename "$INSTALL_DIR")" == "$expected_name" ]] ||
    fail "version-mismatch" "$EXIT_VERSION" "install directory basename mismatch"
  verify_tree "$INSTALL_DIR"
  printf '{"verified":true,"version":"%s","target":"%s","installDirectory":"%s"}\n' \
    "$(json_escape "$VERSION")" "$(json_escape "$TARGET")" "$(json_escape "$INSTALL_DIR")"
}

rollback_action() {
  is_absolute "$HOME_DIR" || usage
  [[ -n "$PREVIOUS_CURRENT_TARGET" ]] || usage
  [[ -n "$FAILED_INSTALL_DIR" ]] || usage
  if [[ ! -d "$HOME_DIR" ]]; then
    [[ "$PREVIOUS_CURRENT_TARGET" == "none" && "$FAILED_INSTALL_DIR" == "none" ]] ||
      fail "rollback-failed" "$EXIT_ROLLBACK" "install home is missing"
    printf '{"rolledBack":true,"currentTarget":null}\n'
    return
  fi
  HOME_DIR=$(CDPATH= cd -- "$HOME_DIR" && pwd -P)
  releases="$HOME_DIR/releases"
  current_target=null

  if [[ "$PREVIOUS_CURRENT_TARGET" == "none" ]]; then
    rm -f "$HOME_DIR/current" "$HOME_DIR/current.next"
  else
    canonical_previous=$(canonical_release_relative "$HOME_DIR" "$PREVIOUS_CURRENT_TARGET") ||
      fail "rollback-failed" "$EXIT_ROLLBACK" "previous target is not a canonical release directory"
    switch_current "$HOME_DIR" "$canonical_previous"
    current_target="\"$(json_escape "$canonical_previous")\""
  fi

  if [[ "$FAILED_INSTALL_DIR" != "none" ]]; then
    is_absolute "$FAILED_INSTALL_DIR" ||
      fail "rollback-failed" "$EXIT_ROLLBACK" "failed install path is not absolute"
    failed_name=$(basename -- "$FAILED_INSTALL_DIR")
    [[ "$failed_name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*-[0-9a-f]{64}$ ]] ||
      fail "rollback-failed" "$EXIT_ROLLBACK" "failed install path has an invalid release name"
    failed_parent=$(CDPATH= cd -- "$(dirname -- "$FAILED_INSTALL_DIR")" 2>/dev/null && pwd -P || true)
    failed_canonical="$failed_parent/$failed_name"
    previous_canonical=""
    if [[ "$PREVIOUS_CURRENT_TARGET" != "none" && -d "$HOME_DIR/$PREVIOUS_CURRENT_TARGET" ]]; then
      previous_canonical=$(CDPATH= cd -- "$HOME_DIR/$PREVIOUS_CURRENT_TARGET" && pwd -P)
    fi
    if [[ "$failed_parent" == "$releases" &&
          ! -L "$failed_canonical" &&
          "$failed_canonical" != "$previous_canonical" &&
          ( -e "$failed_canonical" || -L "$failed_canonical" ) ]]; then
      rm -rf -- "$failed_canonical" ||
        fail "rollback-failed" "$EXIT_ROLLBACK" "could not remove failed install"
    fi
  fi

  printf '{"rolledBack":true,"currentTarget":%s}\n' "$current_target"
}

parse_action "$@"
case "$ACTION" in
  --install)
    [[ -n "$BUNDLE" && -n "$HOME_DIR" && -n "$VERSION" && -n "$TARGET" &&
       -n "$ASSET_SHA256" && -n "$MANIFEST_SHA256" ]] || usage
    install_action
    ;;
  --verify)
    [[ -n "$INSTALL_DIR" && -n "$VERSION" && -n "$TARGET" &&
       -n "$ASSET_SHA256" && -n "$MANIFEST_SHA256" ]] || usage
    verify_action
    ;;
  --rollback)
    [[ -n "$HOME_DIR" && -n "$PREVIOUS_CURRENT_TARGET" &&
       -n "$FAILED_INSTALL_DIR" ]] || usage
    rollback_action
    ;;
  *)
    usage
    ;;
esac
