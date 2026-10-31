#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_ROOT="${SCRIPT_DIR:h}"
PROJECT="$APP_ROOT/PI-IOS.xcodeproj"
SCHEME="${SCHEME:-PI-IOS}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_ROOT="${BUILD_ROOT:-$APP_ROOT/build/unsigned-ipa}"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
BUILD_LOG="$BUILD_ROOT/xcodebuild.log"
OUTPUT_IPA="${OUTPUT_IPA:-$APP_ROOT/build/ipa/PI-IOS.ipa}"
EXPECTED_BUNDLE_IDENTIFIER="${EXPECTED_BUNDLE_IDENTIFIER:-dev.piios.PI-IOS}"
APP_NAME="PI-IOS.app"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    print -u2 "错误：未找到 Xcode。请设置 DEVELOPER_DIR。"
    exit 2
  fi
fi

for tool in xcodebuild plutil ditto lipo otool unzip grep shasum stat; do
  command -v "$tool" >/dev/null || {
    print -u2 "错误：缺少构建或校验工具：$tool"
    exit 2
  }
done

mkdir -p "$BUILD_ROOT" "${OUTPUT_IPA:h}"
STAGING_DIR="$(mktemp -d "${OUTPUT_IPA:h}/.unsigned-ipa-staging.XXXXXX")"
TEMP_IPA="${OUTPUT_IPA:h}/.PI-IOS.ipa.$$"
cleanup() {
  rm -rf "$STAGING_DIR"
  rm -f "$TEMP_IPA"
}
trap cleanup EXIT INT TERM

print "==> 构建未签名 ${CONFIGURATION} App"
if ! xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build > "$BUILD_LOG" 2>&1; then
  print -u2 "错误：xcodebuild 失败，日志尾部如下："
  tail -n 200 "$BUILD_LOG" >&2
  exit 1
fi
print "构建日志：$BUILD_LOG"

BUILT_APP="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos/$APP_NAME"
if [[ ! -d "$BUILT_APP" ]]; then
  print -u2 "错误：未找到构建产物：$BUILT_APP"
  exit 1
fi

print "==> 组装 IPA"
mkdir -p "$STAGING_DIR/Payload"
STAGED_APP="$STAGING_DIR/Payload/$APP_NAME"
ditto "$BUILT_APP" "$STAGED_APP"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$STAGING_DIR/Payload" "$TEMP_IPA"

print "==> 校验 ZIP 完整性"
unzip -tqq "$TEMP_IPA"

VERIFY_DIR="$STAGING_DIR/verify"
mkdir -p "$VERIFY_DIR"
ditto -x -k "$TEMP_IPA" "$VERIFY_DIR"

IPA_BUNDLE="$VERIFY_DIR/Payload/$APP_NAME"
IPA_INFO="$IPA_BUNDLE/Info.plist"
unzip -Z1 "$TEMP_IPA" > "$STAGING_DIR/zip-content.txt"
grep -Fxq "Payload/$APP_NAME/Info.plist" "$STAGING_DIR/zip-content.txt"

if [[ ! -d "$IPA_BUNDLE" || ! -f "$IPA_INFO" ]]; then
  print -u2 "错误：IPA 缺少 Payload/$APP_NAME 或 Info.plist"
  exit 1
fi
if [[ -e "$IPA_BUNDLE/_CodeSignature" ]]; then
  print -u2 "错误：产物意外包含 _CodeSignature"
  exit 1
fi
if grep -Eq '(^|/)_CodeSignature(/|$)' "$STAGING_DIR/zip-content.txt"; then
  print -u2 "错误：ZIP 内存在嵌套 _CodeSignature"
  exit 1
fi
if grep -Fxq "Payload/$APP_NAME/embedded.mobileprovision" "$STAGING_DIR/zip-content.txt"; then
  print -u2 "错误：未签名 IPA 不得包含 embedded.mobileprovision"
  exit 1
fi
if grep -Eq '^__MACOSX/' "$STAGING_DIR/zip-content.txt"; then
  print -u2 "错误：IPA 包含 AppleDouble __MACOSX 条目"
  exit 1
fi

print "==> 校验 Info.plist"
plutil -lint "$IPA_INFO" >/dev/null
BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$IPA_INFO")"
BUNDLE_EXECUTABLE="$(plutil -extract CFBundleExecutable raw -o - "$IPA_INFO")"
BUNDLE_PACKAGE_TYPE="$(plutil -extract CFBundlePackageType raw -o - "$IPA_INFO")"
MINIMUM_OS="$(plutil -extract MinimumOSVersion raw -o - "$IPA_INFO")"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$IPA_INFO")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$IPA_INFO")"

if [[ "$BUNDLE_IDENTIFIER" != "$EXPECTED_BUNDLE_IDENTIFIER" ]]; then
  print -u2 "错误：Bundle ID 不匹配：$BUNDLE_IDENTIFIER"
  exit 1
fi
if [[ "$BUNDLE_PACKAGE_TYPE" != "APPL" ]]; then
  print -u2 "错误：CFBundlePackageType 不是 APPL：$BUNDLE_PACKAGE_TYPE"
  exit 1
fi
for value in "$BUNDLE_EXECUTABLE" "$MINIMUM_OS" "$VERSION" "$BUILD_NUMBER"; do
  if [[ -z "$value" ]]; then
    print -u2 "错误：Info.plist 必需字段为空"
    exit 1
  fi
done

APP_EXECUTABLE="$IPA_BUNDLE/$BUNDLE_EXECUTABLE"
if [[ ! -f "$APP_EXECUTABLE" ]]; then
  print -u2 "错误：Info.plist 指向的可执行文件不存在：$APP_EXECUTABLE"
  exit 1
fi

print "==> 校验 Mach-O 架构"
ARCHITECTURES="$(lipo -archs "$APP_EXECUTABLE")"
case " $ARCHITECTURES " in
  *" arm64 "*) ;;
  *)
    print -u2 "错误：主可执行文件不包含 arm64：$ARCHITECTURES"
    exit 1
    ;;
esac

if otool -l "$APP_EXECUTABLE" | grep -q 'LC_CODE_SIGNATURE'; then
  print -u2 "错误：Mach-O 包含 LC_CODE_SIGNATURE"
  exit 1
fi

print "==> 校验 Release 不含 UI fixture 标记"
fixture_markers=(
  PI_IOS_UI_FIXTURE_SCENARIO
  PI_IOS_INSTALL_FIXTURE_FAILURE
  offline-two-hosts
  offline-cache-205
  online-two-sessions
  online-reading-two-sessions
  online-large-tool-result
  online-project-lifecycle
  online-upstream-import
  online-model-config
  download-twice
  pair-expired
  sudo-failure
  "UI test fixtures are unavailable in release builds"
)
for marker in "${fixture_markers[@]}"; do
  if LC_ALL=C grep -aR -F -- "$marker" "$IPA_BUNDLE" >/dev/null 2>&1; then
    print -u2 "错误：Release 产物包含 UI fixture 标记：$marker"
    exit 1
  fi
done

mv -f "$TEMP_IPA" "$OUTPUT_IPA"
SHA256="$(shasum -a 256 "$OUTPUT_IPA" | awk '{print $1}')"
SIZE_BYTES="$(stat -f '%z' "$OUTPUT_IPA")"
SIZE_HUMAN="$(du -h "$OUTPUT_IPA" | awk '{print $1}')"

print ""
print "未签名 IPA 构建成功"
print "  路径：$OUTPUT_IPA"
print "  大小：$SIZE_BYTES 字节（$SIZE_HUMAN）"
print "  SHA-256：$SHA256"
print "  Bundle ID：$BUNDLE_IDENTIFIER"
print "  版本：$VERSION（$BUILD_NUMBER），最低 iOS $MINIMUM_OS"
print "  架构：$ARCHITECTURES"
print "  Info.plist：通过"
print "  ZIP：通过"
print "  Payload：Payload/$APP_NAME"
