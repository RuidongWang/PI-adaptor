import Foundation

/// Inputs for the POSIX bootstrap script that runs on the target Linux host.
///
/// The script is generated entirely on the client. Every value that can reach a
/// shell is validated here and then emitted as a single-quoted shell literal.
public struct BootstrapScriptConfiguration: Equatable, Sendable {
    public static let defaultPairingLifetimeMilliseconds = 10 * 60 * 1_000
    public static let defaultReadyTimeoutSeconds = 90
    public static let defaultPairTimeoutSeconds = 12 * 60
    public static let defaultStopTimeoutSeconds = 20
    public static let defaultVerifyTimeoutSeconds = 90

    public let release: PiHostRelease
    public let attemptId: String
    public let hostPlatform: String
    public let hostArchitecture: String
    public let port: Int
    public let pairingLifetimeMilliseconds: Int
    public let readyTimeoutSeconds: Int
    public let pairTimeoutSeconds: Int
    public let stopTimeoutSeconds: Int
    public let verifyTimeoutSeconds: Int
    /// 强制重装：命中本地 receipt 也重新下载并激活，用于「版本没变但字节变了」的场景。
    public let force: Bool

    public init(
        release: PiHostRelease,
        attemptId: String,
        hostPlatform: String = "linux",
        hostArchitecture: String,
        port: Int,
        pairingLifetimeMilliseconds: Int = BootstrapScriptConfiguration.defaultPairingLifetimeMilliseconds,
        readyTimeoutSeconds: Int = BootstrapScriptConfiguration.defaultReadyTimeoutSeconds,
        pairTimeoutSeconds: Int = BootstrapScriptConfiguration.defaultPairTimeoutSeconds,
        stopTimeoutSeconds: Int = BootstrapScriptConfiguration.defaultStopTimeoutSeconds,
        verifyTimeoutSeconds: Int = BootstrapScriptConfiguration.defaultVerifyTimeoutSeconds,
        force: Bool = false
    ) throws {
        guard BootstrapScriptValidation.isAttemptId(attemptId) else {
            throw BootstrapScriptError.invalidAttemptId
        }
        guard (1...65_535).contains(port) else {
            throw BootstrapScriptError.invalidPort
        }
        guard hostPlatform.lowercased() == BootstrapPlatformProbe.supportedPlatform,
              BootstrapScriptValidation.isSafeLabel(hostPlatform),
              BootstrapScriptValidation.isSafeLabel(hostArchitecture) else {
            throw BootstrapScriptError.invalidHostIdentity
        }
        guard (60_000...15 * 60 * 1_000).contains(pairingLifetimeMilliseconds) else {
            throw BootstrapScriptError.invalidPairingLifetime
        }
        for timeout in [
            readyTimeoutSeconds,
            pairTimeoutSeconds,
            stopTimeoutSeconds,
            verifyTimeoutSeconds,
        ] {
            guard (1...3_600).contains(timeout) else {
                throw BootstrapScriptError.invalidTimeout
            }
        }

        self.release = release
        self.attemptId = attemptId
        self.hostPlatform = hostPlatform.lowercased()
        self.hostArchitecture = hostArchitecture
        self.port = port
        self.pairingLifetimeMilliseconds = pairingLifetimeMilliseconds
        self.readyTimeoutSeconds = readyTimeoutSeconds
        self.pairTimeoutSeconds = pairTimeoutSeconds
        self.stopTimeoutSeconds = stopTimeoutSeconds
        self.verifyTimeoutSeconds = verifyTimeoutSeconds
        self.force = force
    }
}

public enum BootstrapScriptError: Error, Equatable, CustomStringConvertible {
    case invalidAttemptId
    case invalidPort
    case invalidHostIdentity
    case invalidPairingLifetime
    case invalidTimeout

    public var description: String {
        switch self {
        case .invalidAttemptId:
            return "attemptId 只能包含 ASCII 字母、数字、点、下划线和短横线"
        case .invalidPort:
            return "pi-host 端口必须在 1...65535 之间；不能使用随机端口 0，否则常驻 unit 会与配对端口不一致"
        case .invalidHostIdentity:
            return "Host 平台或架构包含不安全字符"
        case .invalidPairingLifetime:
            return "配对令牌有效期必须在 1 到 15 分钟之间"
        case .invalidTimeout:
            return "bootstrap 超时必须是 1...3600 秒"
        }
    }
}

enum BootstrapScriptValidation {
    private static let attemptCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    )
    private static let labelCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    )

    static func isAttemptId(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 96 && value.unicodeScalars.allSatisfy {
            $0.isASCII && attemptCharacters.contains($0)
        }
    }

    static func isSafeLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && value.unicodeScalars.allSatisfy {
            $0.isASCII && labelCharacters.contains($0)
        }
    }
}

/// Generates the only script executed on the remote host.
///
/// Pairing-token stdout is consumed through an owner-only FIFO. It is never
/// redirected into a persistent log. The script pauses at `pair` and
/// `verify-device`; the runner performs those client-side callbacks and writes
/// a non-secret result marker so the script can advance.
public enum BootstrapScriptBuilder {
    public static func build(_ configuration: BootstrapScriptConfiguration) -> String {
        let release = configuration.release
        let assignments = [
            shellQuote(release.version),
            shellQuote(release.artifactURL),
            shellQuote(release.checksumURL),
            shellQuote(release.pinnedChecksum ?? ""),
            shellQuote(release.artifactName),
            shellQuote(release.bundleDirectoryName),
            "'0.21.0'",
            String(configuration.port),
            String(configuration.pairingLifetimeMilliseconds),
            String(configuration.readyTimeoutSeconds),
            String(configuration.pairTimeoutSeconds),
            String(configuration.stopTimeoutSeconds),
            String(configuration.verifyTimeoutSeconds),
            "'22'",
            shellQuote(configuration.attemptId),
            shellQuote(configuration.hostPlatform),
            shellQuote(configuration.hostArchitecture),
            configuration.force ? "1" : "0",
        ]
        let variableNames = [
            "VERSION",
            "ARTIFACT_URL",
            "CHECKSUM_URL",
            "PINNED_SHA256",
            "ARTIFACT_NAME",
            "BUNDLE_DIR",
            "MIN_HOST_VERSION",
            "PORT",
            "PAIRING_LIFETIME_MS",
            "READY_TIMEOUT_SEC",
            "PAIR_TIMEOUT_SEC",
            "STOP_TIMEOUT_SEC",
            "VERIFY_TIMEOUT_SEC",
            "MIN_NODE_MAJOR",
            "ATTEMPT_ID",
            "HOST_PLATFORM",
            "HOST_ARCH",
            "FORCE_INSTALL",
        ]
        let assignmentBlock = zip(variableNames, assignments)
            .map { "\($0)=\($1)" }
            .joined(separator: "\n")

        return #"""
#!/bin/sh
# Generated by PI-IOS. Implements docs/api/ios-client.md section 5.
set -eu
umask 077

\#(assignmentBlock)

BASE="$HOME/.pi-desktop/pi-host"
WORK="$BASE/.bootstrap"
STATE="$WORK/state.json"
PAIR_JSON="$WORK/pair.json"
PAIR_RESULT="$WORK/pair.result"
VERIFY_RESULT="$WORK/verify.result"
CANCEL="$WORK/cancel"
LOCK="$WORK/active.lock"
PART="$WORK/$ARTIFACT_NAME.part"
CHECKSUM_FILE="$WORK/$ARTIFACT_NAME.sha256"

CURRENT_STEP="probe"
ARTIFACT_BYTES=0
DOWNLOADED_BYTES=0
EXPECTED_SHA256=""
SERVICE_STATE="absent"
MANUAL_PID=""
PAIR_READER_PID=""
STAGE=""

step() {
  printf '%s\n' "PI_HOST_BOOTSTRAP $1"
}

write_state() {
  next_step=$1
  status=$2
  error_code=${3:-}
  service_value=${4:-$SERVICE_STATE}
  case "$next_step$status$error_code$service_value$ATTEMPT_ID$ARTIFACT_NAME$EXPECTED_SHA256" in
    *'"'*|*'\'*) return 1 ;;
  esac
  [ -d "$WORK" ] || return 1
  error_json='null'
  if [ -n "$error_code" ]; then
    error_json="{\"code\":\"$error_code\"}"
  fi
  tmp="$STATE.tmp.$$"
  {
    printf '{"version":1,"attemptId":"%s","step":"%s","status":"%s",' "$ATTEMPT_ID" "$next_step" "$status"
    printf '"host":{"platform":"%s","arch":"%s"},' "$HOST_PLATFORM" "$HOST_ARCH"
    printf '"artifact":{"name":"%s","sha256":"%s","bytes":%s,"downloadedBytes":%s},' \
      "$ARTIFACT_NAME" "$EXPECTED_SHA256" "$ARTIFACT_BYTES" "$DOWNLOADED_BYTES"
    printf '"service":{"unitPath":"%s","state":"%s"},' "$HOME/.config/systemd/user/pi-host.service" "$service_value"
    printf '"error":%s,"updatedAt":"%s"}\n' "$error_json" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$STATE"
}

progress() {
  CURRENT_STEP=$1
  step "$1"
  write_state "$1" running || die "bootstrap-permissions"
}

cleanup_manual() {
  if [ -n "$PAIR_READER_PID" ]; then
    kill "$PAIR_READER_PID" 2>/dev/null || true
    wait "$PAIR_READER_PID" 2>/dev/null || true
    PAIR_READER_PID=""
  fi
  if [ -n "$MANUAL_PID" ] && kill -0 "$MANUAL_PID" 2>/dev/null; then
    kill "$MANUAL_PID" 2>/dev/null || true
    waited=0
    while kill -0 "$MANUAL_PID" 2>/dev/null && [ "$waited" -lt "$STOP_TIMEOUT_SEC" ]; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$MANUAL_PID" 2>/dev/null; then
      kill -KILL "$MANUAL_PID" 2>/dev/null || true
    fi
    wait "$MANUAL_PID" 2>/dev/null || true
  fi
  MANUAL_PID=""
}

redact_pair_stderr() {
  [ -f "$WORK/pair.err" ] || return 0
  token=""
  if [ -f "$PAIR_JSON" ]; then
    token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PAIR_JSON" 2>/dev/null || true)
  fi
  if [ -n "$token" ]; then
    redacted="$WORK/pair.err.redacted.$$"
    sed "s/$token/<redacted>/g" "$WORK/pair.err" >"$redacted" 2>/dev/null || return 1
    chmod 600 "$redacted" 2>/dev/null || return 1
    mv -f "$redacted" "$WORK/pair.err" || return 1
  fi
}

cleanup() {
  cleanup_manual
  redact_pair_stderr || true
  rm -f "$PAIR_JSON" "$PAIR_JSON".tmp.* "$WORK/pair.fifo" "$WORK/manual.pid"
  [ -z "$STAGE" ] || rm -rf "$STAGE"
  rm -rf "$LOCK"
}

die() {
  failure_code=$1
  trap - HUP INT TERM
  cleanup_manual
  redact_pair_stderr || true
  rm -f "$PAIR_JSON" "$PAIR_JSON".tmp.* "$WORK/pair.fifo" "$WORK/pair.result" "$WORK/verify.result"
  write_state "$CURRENT_STEP" failed "$failure_code" || true
  printf '%s\n' "PI_HOST_BOOTSTRAP_FAILED $failure_code" >&2
  printf '%s\n' "PI_HOST_FAILED {\"code\":\"HOST_BOOTSTRAP_FAILED\",\"step\":\"$failure_code\"}"
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

sha256_of() {
  if need sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif need shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 127
  fi
}

fetch() {
  url=$1
  destination=$2
  if need curl; then
    curl -fsSL --connect-timeout 20 --max-time 900 -o "$destination" "$url"
  elif need wget; then
    wget -q --timeout=900 -O "$destination" "$url"
  else
    return 127
  fi
}

resume_download() {
  url=$1
  destination=$2
  if need curl; then
    curl -fL -C - --connect-timeout 20 --max-time 900 -o "$destination" "$url"
  elif need wget; then
    wget -c -q --timeout=900 -O "$destination" "$url"
  else
    return 127
  fi
}

download_artifact() {
  resume_download "$ARTIFACT_URL" "$PART" &
  download_pid=$!
  while kill -0 "$download_pid" 2>/dev/null; do
    if [ -f "$PART" ]; then
      DOWNLOADED_BYTES=$(wc -c <"$PART" | tr -d ' ')
      write_state download running || true
    fi
    sleep 1
  done
  status=0
  wait "$download_pid" || status=$?
  DOWNLOADED_BYTES=0
  [ ! -f "$PART" ] || DOWNLOADED_BYTES=$(wc -c <"$PART" | tr -d ' ')
  if [ "$status" -ne 0 ] && [ -f "$PART" ] && [ -n "$EXPECTED_SHA256" ]; then
    # curl reports HTTP 416 when a resumed file is already complete. Accept it
    # only when the pinned digest proves that the bytes are exact.
    completed_sha256=$(sha256_of "$PART" 2>/dev/null || true)
    if [ "$completed_sha256" = "$EXPECTED_SHA256" ]; then
      status=0
    fi
  fi
  return "$status"
}

stop_manual_process() {
  requested_pid=$1
  [ -n "$requested_pid" ] || return 0
  kill -0 "$requested_pid" 2>/dev/null || return 0
  command_line=$(ps -p "$requested_pid" -o command= 2>/dev/null || true)
  case "$command_line" in
    *pi-host.js*) ;;
    *) return 0 ;;
  esac
  kill -TERM "$requested_pid" 2>/dev/null || true
  waited=0
  while kill -0 "$requested_pid" 2>/dev/null && [ "$waited" -lt "$STOP_TIMEOUT_SEC" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$requested_pid" 2>/dev/null; then
    kill -KILL "$requested_pid" 2>/dev/null || true
  fi
  sleep 1
  ! kill -0 "$requested_pid" 2>/dev/null
}

if [ -z "${HOME:-}" ]; then
  printf '%s\n' "PI_HOST_BOOTSTRAP_FAILED no-home" >&2
  printf '%s\n' "PI_HOST_FAILED {\"code\":\"HOST_BOOTSTRAP_FAILED\",\"step\":\"no-home\"}"
  exit 1
fi
mkdir -p "$BASE" "$WORK" || die "bootstrap-permissions"
chmod 700 "$BASE" "$WORK" 2>/dev/null || die "bootstrap-permissions"
rm -f "$CANCEL" "$PAIR_RESULT" "$VERIFY_RESULT"

if ! mkdir "$LOCK" 2>/dev/null; then
  old_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    old_command=$(ps -p "$old_pid" -o command= 2>/dev/null || true)
    case "$old_command" in
      *bootstrap.sh*)
        printf '%s\n' "PI_HOST_BOOTSTRAP_FAILED stage-failed" >&2
        exit 1
        ;;
    esac
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || die "stage-failed"
fi
printf '%s\n' "$$" >"$LOCK/pid"
chmod 600 "$LOCK/pid" 2>/dev/null || die "bootstrap-permissions"
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

step "probe"
ARTIFACT_BYTES=0
DOWNLOADED_BYTES=0
write_state probe running || die "bootstrap-permissions"

need tar || die "missing-tar"
need mkfifo || die "missing-tar"
sha256_of /dev/null >/dev/null 2>&1 || die "missing-sha256-tool"

progress "resolve"
rm -f "$CHECKSUM_FILE"
fetch "$CHECKSUM_URL" "$CHECKSUM_FILE" || die "download-failed"
chmod 600 "$CHECKSUM_FILE" 2>/dev/null || die "artifact-permissions"
EXPECTED_SHA256=$(
  awk -v expected="$ARTIFACT_NAME" '
    length($1) == 64 && $1 !~ /[^0-9a-fA-F]/ {
      name = $2
      sub(/^\*/, "", name)
      count = split(name, parts, "/")
      if (parts[count] == expected) {
        print tolower($1)
        exit
      }
    }
  ' "$CHECKSUM_FILE"
)
printf '%s\n' "$EXPECTED_SHA256" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || die "checksum-mismatch"
if [ -n "$PINNED_SHA256" ] && [ "$EXPECTED_SHA256" != "$PINNED_SHA256" ]; then
  die "checksum-mismatch"
fi
write_state resolve running || die "bootstrap-permissions"

reuse=0
receipt="$BASE/.release.sha256"
if [ "$FORCE_INSTALL" = 1 ]; then
  # 强制重装：不信任任何本地 receipt，重新下载并激活（用户点「重新安装」时走这里）。
  progress "force"
elif [ -x "$BASE/current/bin/node" ] && [ -f "$BASE/current/SHA256SUMS" ] && [ -f "$receipt" ]; then
  manifest_sha256=$(sha256_of "$BASE/current/SHA256SUMS") || die "missing-sha256-tool"
  expected_receipt="$VERSION $EXPECTED_SHA256 $manifest_sha256"
  if [ "$(cat "$receipt" 2>/dev/null || true)" = "$expected_receipt" ] && \
     sh "$BASE/current/install.sh" --verify >/dev/null 2>&1; then
    reuse=1
    step "reuse"
  fi
fi

if [ "$reuse" = 0 ]; then
  progress "download"
  download_artifact || die "download-failed"
  [ -f "$PART" ] || die "download-failed"
  chmod 600 "$PART" 2>/dev/null || die "artifact-permissions"
  ARTIFACT_BYTES=$DOWNLOADED_BYTES
  write_state download running || die "bootstrap-permissions"

  progress "verify"
  actual_sha256=$(sha256_of "$PART") || die "missing-sha256-tool"
  if [ "$actual_sha256" != "$EXPECTED_SHA256" ]; then
    rm -f "$PART"
    die "checksum-mismatch"
  fi

  progress "extract"
  STAGE=$(mktemp -d "$BASE/.stage.XXXXXX") || die "stage-failed"
  unpack="$STAGE/unpack"
  mkdir -p "$unpack" || die "extract-failed"
  tar -xzf "$PART" -C "$unpack" || die "extract-failed"
  [ -d "$unpack/$BUNDLE_DIR" ] || die "unexpected-archive-layout"
  [ -x "$unpack/$BUNDLE_DIR/install.sh" ] || die "unexpected-archive-layout"
  [ -f "$unpack/$BUNDLE_DIR/pi-host.js" ] || die "unexpected-archive-layout"

  progress "activate"
  sh "$unpack/$BUNDLE_DIR/install.sh" >/dev/null || die "install-failed"
  sh "$BASE/current/install.sh" --verify >/dev/null 2>&1 || die "installed-verification-failed"
  artifact_manifest_sha256=$(sha256_of "$unpack/$BUNDLE_DIR/SHA256SUMS") || die "missing-sha256-tool"
  manifest_sha256=$(sha256_of "$BASE/current/SHA256SUMS") || die "missing-sha256-tool"
  # 激活出来的树必须就是这次下载的包：否则「装完还是旧版本」会被静默当成成功
  # （旧 receipt 会让我们下次直接复用旧树）。复用既有的 installed-verification-failed，
  # 不新增客户端侧失败码（契约里的码表不变）。
  if [ "$artifact_manifest_sha256" != "$manifest_sha256" ]; then
    die "installed-verification-failed"
  fi
  printf '%s\n' "$VERSION $EXPECTED_SHA256 $manifest_sha256" >"$STAGE/receipt" || die "receipt-failed"
  mv -f "$STAGE/receipt" "$receipt" || die "receipt-failed"
  rm -rf "$STAGE"
  STAGE=""
  rm -f "$PART"
else
  progress "activate"
fi

node="$BASE/current/bin/node"
if [ ! -x "$node" ]; then
  need node || die "missing-node"
  node=$(command -v node)
fi
node_major=$("$node" -p 'process.versions.node.split(".")[0]' 2>/dev/null || printf '0')
case "$node_major" in
  ''|*[!0-9]*) die "node-too-old" ;;
esac
[ "$node_major" -ge "$MIN_NODE_MAJOR" ] 2>/dev/null || die "node-too-old"

progress "write-unit"
unit_dir="$HOME/.config/systemd/user"
mkdir -p "$unit_dir" || die "unit-failed"
unit_path="$unit_dir/pi-host.service"
unit_tmp="$unit_dir/.pi-host.service.$$"
{
  printf '%s\n' '[Unit]'
  printf '%s\n' 'Description=PI Desktop Host'
  printf '%s\n' 'After=network-online.target'
  printf '%s\n' 'Wants=network-online.target'
  printf '%s\n' ''
  printf '%s\n' '[Service]'
  printf '%s\n' 'Type=simple'
  printf 'ExecStart="%s" "%s/current/pi-host.js" --port %s\n' "$node" "$BASE" "$PORT"
  printf 'WorkingDirectory=%s\n' "$BASE"
  printf '%s\n' 'Restart=always'
  printf '%s\n' 'RestartSec=2'
  printf '%s\n' 'NoNewPrivileges=yes'
  printf 'Environment="PI_DESKTOP_DATA_DIR=%s/.pi-desktop"\n' "$HOME"
  printf '%s\n' ''
  printf '%s\n' '[Install]'
  printf '%s\n' 'WantedBy=default.target'
} >"$unit_tmp" || die "unit-failed"
chmod 644 "$unit_tmp" 2>/dev/null || die "unit-failed"
mv -f "$unit_tmp" "$unit_path" || die "unit-failed"
SERVICE_STATE="written"
write_state "write-unit" running "" "written" || die "bootstrap-permissions"
systemctl --user daemon-reload >/dev/null 2>&1 || die "unit-failed"
loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || die "unit-failed"

progress "start-pair"
systemctl --user stop pi-host.service >/dev/null 2>&1 || true
systemctl --user is-active --quiet pi-host.service >/dev/null 2>&1 && die "unit-failed"
previous_pid=$(cat "$WORK/manual.pid" 2>/dev/null || true)
stop_manual_process "$previous_pid" || die "host-stop-timeout"
rm -f "$PAIR_JSON" "$PAIR_RESULT" "$VERIFY_RESULT" "$WORK/pair.fifo"

mkfifo "$WORK/pair.fifo" || die "host-start-failed"
chmod 600 "$WORK/pair.fifo" 2>/dev/null || die "bootstrap-permissions"
: >"$WORK/pair.err"
chmod 600 "$WORK/pair.err" 2>/dev/null || die "bootstrap-permissions"

# 与 unit 用同一个 dataDir：unit 里显式设了 PI_DESKTOP_DATA_DIR，
# 这里必须显式对齐，否则一旦 SSH exec 会话导出了不同的 PI_DESKTOP_DATA_DIR，
# 手动 --pair 进程与常驻 unit 会各写一份 dataDir，配对签发的设备令牌落在 A 而 unit 读 B，
# AC-01.8 终态永远达不到，也违反「禁止两个进程共用同一 dataDir」的前提。
PI_DESKTOP_DATA_DIR="$HOME/.pi-desktop" \
"$node" "$BASE/current/pi-host.js" \
  --port "$PORT" \
  --pair \
  --pairing-lifetime-ms "$PAIRING_LIFETIME_MS" \
  >"$WORK/pair.fifo" 2>"$WORK/pair.err" </dev/null &
MANUAL_PID=$!
printf '%s\n' "$MANUAL_PID" >"$WORK/manual.pid"
chmod 600 "$WORK/manual.pid" 2>/dev/null || die "bootstrap-permissions"

(
  ready_host=""
  ready_port=""
  token=""
  expires_at=0
  while IFS= read -r line; do
    case "$line" in
      'PI_HOST_READY '*)
        ready_json=${line#PI_HOST_READY }
        candidate_host=$(printf '%s\n' "$ready_json" | sed -n 's/.*"host"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        candidate_port=$(printf '%s\n' "$ready_json" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
        if { [ "$candidate_host" = "127.0.0.1" ] || [ "$candidate_host" = "::1" ]; } && \
           [ -n "$candidate_port" ] && [ "$candidate_port" -ge 1 ] && [ "$candidate_port" -le 65535 ]; then
          ready_host=$candidate_host
          ready_port=$candidate_port
        fi
        ;;
      'PI_HOST_PAIRING_TOKEN '*)
        token_json=${line#PI_HOST_PAIRING_TOKEN }
        candidate=$(printf '%s\n' "$token_json" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        case "$candidate" in
          ppt1.*) ;;
          *) candidate="" ;;
        esac
        case "$candidate" in
          '') ;;
          *[!A-Za-z0-9._-]*) candidate="" ;;
        esac
        candidate_expires=$(printf '%s\n' "$token_json" | sed -n 's/.*"expiresAt"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
        case "$candidate_expires" in
          ''|*[!0-9]*) candidate_expires=0 ;;
        esac
        if [ -n "$candidate" ]; then
          token=$candidate
          expires_at=$candidate_expires
        fi
        ;;
    esac
    if [ -n "$ready_host" ] && [ -n "$ready_port" ] && [ -n "$token" ] && [ ! -f "$PAIR_JSON" ]; then
      pair_tmp="$PAIR_JSON.tmp.$$"
      printf '{"token":"%s","expiresAt":%s,"host":"%s","port":%s}\n' \
        "$token" "$expires_at" "$ready_host" "$ready_port" >"$pair_tmp" || exit 1
      chmod 600 "$pair_tmp" 2>/dev/null || exit 1
      mv -f "$pair_tmp" "$PAIR_JSON" || exit 1
    fi
  done <"$WORK/pair.fifo"
) &
PAIR_READER_PID=$!

waited=0
while [ ! -s "$PAIR_JSON" ]; do
  [ -f "$CANCEL" ] && die "pair-failed"
  if ! kill -0 "$MANUAL_PID" 2>/dev/null; then
    if grep -q '^PI_HOST_FAILED ' "$WORK/pair.err" 2>/dev/null; then
      die "host-start-failed"
    fi
    die "host-exited"
  fi
  [ "$waited" -lt "$READY_TIMEOUT_SEC" ] || die "ready-timeout"
  sleep 1
  waited=$((waited + 1))
done

CURRENT_STEP="pair"
step "pair"
write_state "pair" running || die "bootstrap-permissions"

waited=0
while [ ! -s "$PAIR_RESULT" ]; do
  [ -f "$CANCEL" ] && die "pair-failed"
  if ! kill -0 "$MANUAL_PID" 2>/dev/null; then
    die "host-exited"
  fi
  [ "$waited" -lt "$PAIR_TIMEOUT_SEC" ] || die "pair-failed"
  sleep 1
  waited=$((waited + 1))
done
pair_result=$(cat "$PAIR_RESULT" 2>/dev/null || true)
redact_pair_stderr || die "bootstrap-permissions"
rm -f "$PAIR_JSON" "$PAIR_RESULT"
[ "$pair_result" = "ok" ] || die "pair-failed"

progress "stop-manual"
manual_to_stop=$MANUAL_PID
cleanup_manual
kill -0 "$manual_to_stop" 2>/dev/null && die "host-stop-timeout"
rm -f "$WORK/pair.fifo" "$WORK/manual.pid"

progress "start-unit"
systemctl --user start pi-host.service >/dev/null 2>&1 || die "unit-failed"
systemctl --user is-active --quiet pi-host.service >/dev/null 2>&1 || die "unit-failed"
SERVICE_STATE="active"
write_state "start-unit" running "" "active" || die "bootstrap-permissions"

progress "verify-device"
waited=0
while [ ! -s "$VERIFY_RESULT" ]; do
  [ -f "$CANCEL" ] && die "verify-device-failed"
  [ "$waited" -lt "$VERIFY_TIMEOUT_SEC" ] || die "verify-device-failed"
  sleep 1
  waited=$((waited + 1))
done
verify_result=$(cat "$VERIFY_RESULT" 2>/dev/null || true)
rm -f "$VERIFY_RESULT"
[ "$verify_result" = "ok" ] || die "verify-device-failed"

step "done"
write_state "done" ok "" "active" || die "receipt-failed"
"""#
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The non-secret progress commands used between polling reads.
public enum BootstrapRemoteCommand {
    public static let workDirectory = #"$HOME/.pi-desktop/pi-host/.bootstrap"#
    public static let statePath = #"$HOME/.pi-desktop/pi-host/.bootstrap/state.json"#
    public static let pairPath = #"$HOME/.pi-desktop/pi-host/.bootstrap/pair.json"#
    public static let scriptPath = #"$HOME/.pi-desktop/pi-host/.bootstrap/bootstrap.sh"#

    /// One exec performs the only platform probe used by the whole run.
    public static let probe = #"printf 'platform=%s\narch=%s\n' "$(uname -s)" "$(uname -m)""#

    public static let installScript = #"umask 077; mkdir -p "$HOME/.pi-desktop/pi-host/.bootstrap" && chmod 700 "$HOME/.pi-desktop/pi-host/.bootstrap" && cat > "$HOME/.pi-desktop/pi-host/.bootstrap/bootstrap.sh" && chmod 700 "$HOME/.pi-desktop/pi-host/.bootstrap/bootstrap.sh""#

    public static let launch = #"work="$HOME/.pi-desktop/pi-host/.bootstrap"; command -v setsid >/dev/null 2>&1 || exit 1; command -v nohup >/dev/null 2>&1 || exit 1; cd "$work" || exit 1; setsid nohup /bin/sh ./bootstrap.sh >bootstrap.log 2>&1 </dev/null & printf 'pid=%s\n' "$!""#

    public static let readState = #"cat "$HOME/.pi-desktop/pi-host/.bootstrap/state.json" 2>/dev/null || true"#

    public static let readPairing = #"cat "$HOME/.pi-desktop/pi-host/.bootstrap/pair.json" 2>/dev/null || true"#

    public static let writePairingOK = #"umask 077; printf '%s\n' ok > "$HOME/.pi-desktop/pi-host/.bootstrap/pair.result" && chmod 600 "$HOME/.pi-desktop/pi-host/.bootstrap/pair.result""#

    public static let writePairingFailed = #"umask 077; printf '%s\n' failed > "$HOME/.pi-desktop/pi-host/.bootstrap/pair.result" && chmod 600 "$HOME/.pi-desktop/pi-host/.bootstrap/pair.result""#

    public static let writeVerificationOK = #"umask 077; printf '%s\n' ok > "$HOME/.pi-desktop/pi-host/.bootstrap/verify.result" && chmod 600 "$HOME/.pi-desktop/pi-host/.bootstrap/verify.result""#

    public static let writeVerificationFailed = #"umask 077; printf '%s\n' failed > "$HOME/.pi-desktop/pi-host/.bootstrap/verify.result" && chmod 600 "$HOME/.pi-desktop/pi-host/.bootstrap/verify.result""#

    public static let cancel = #"umask 077; printf '%s\n' cancel > "$HOME/.pi-desktop/pi-host/.bootstrap/cancel" && chmod 600 "$HOME/.pi-desktop/pi-host/.bootstrap/cancel""#
}

/// Token material handed from the owner-only remote file to the pairing
/// callback. This value must never be logged or persisted on the client.
public struct BootstrapPairingMaterial: Codable, Equatable, Sendable {
    public let token: String
    public let expiresAt: Int64
    public let host: String
    public let port: Int

    public init(token: String, expiresAt: Int64, host: String, port: Int) throws {
        guard token.hasPrefix("ppt1."),
              token.utf8.count > "ppt1.".count,
              token.unicodeScalars.allSatisfy({
                  $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
              }),
              host == "127.0.0.1" || host == "::1",
              (1...65_535).contains(port) else {
            throw BootstrapPairingMaterialError.invalid
        }
        self.token = token
        self.expiresAt = expiresAt
        self.host = host
        self.port = port
    }

    public var redactedDescription: String {
        "配对令牌（已隐藏），目标 \(host):\(port)"
    }
}

public enum BootstrapPairingMaterialError: Error, Equatable {
    case invalid
}
