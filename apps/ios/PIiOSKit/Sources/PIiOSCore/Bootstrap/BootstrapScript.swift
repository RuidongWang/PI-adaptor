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
    /// PI-adaptor installations default to PPT2 only. A separate legacy path may
    /// opt into PPT1; the normal install UI never exposes that override.
    public let allowLegacyPPT1: Bool

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
        force: Bool = false,
        allowLegacyPPT1: Bool = false
    ) throws {
        guard BootstrapScriptValidation.isAttemptId(attemptId) else {
            throw BootstrapScriptError.invalidAttemptId
        }
        guard (1...65_535).contains(port) else {
            throw BootstrapScriptError.invalidPort
        }
        let architecture = hostArchitecture.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hostPlatform.lowercased() == BootstrapPlatformProbe.supportedPlatform,
              BootstrapScriptValidation.isSafeLabel(hostPlatform),
              BootstrapScriptValidation.isSafeLabel(architecture),
              BootstrapPlatformProbe.target(forUnameMachine: architecture) == release.target else {
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
        self.hostArchitecture = architecture
        self.port = port
        self.pairingLifetimeMilliseconds = pairingLifetimeMilliseconds
        self.readyTimeoutSeconds = readyTimeoutSeconds
        self.pairTimeoutSeconds = pairTimeoutSeconds
        self.stopTimeoutSeconds = stopTimeoutSeconds
        self.verifyTimeoutSeconds = verifyTimeoutSeconds
        self.force = force
        self.allowLegacyPPT1 = allowLegacyPPT1
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
            return "PI-adaptor 端口必须在 1...65535 之间；不能使用随机端口 0，否则常驻 unit 会与配对端口不一致"
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
            shellQuote(release.target.rawValue),
            shellQuote(release.serverName),
            shellQuote(release.unitName),
            shellQuote(release.minimumNodeVersion),
            String(configuration.port),
            String(configuration.pairingLifetimeMilliseconds),
            String(configuration.readyTimeoutSeconds),
            String(configuration.pairTimeoutSeconds),
            String(configuration.stopTimeoutSeconds),
            String(configuration.verifyTimeoutSeconds),
            shellQuote(configuration.attemptId),
            shellQuote(configuration.hostPlatform),
            shellQuote(configuration.hostArchitecture),
            configuration.force ? "1" : "0",
            configuration.allowLegacyPPT1 ? "1" : "0",
        ]
        let variableNames = [
            "VERSION",
            "ARTIFACT_URL",
            "CHECKSUM_URL",
            "PINNED_SHA256",
            "ARTIFACT_NAME",
            "BUNDLE_DIR",
            "TARGET",
            "SERVER_NAME",
            "UNIT_NAME",
            "MIN_NODE_VERSION",
            "PORT",
            "PAIRING_LIFETIME_MS",
            "READY_TIMEOUT_SEC",
            "PAIR_TIMEOUT_SEC",
            "STOP_TIMEOUT_SEC",
            "VERIFY_TIMEOUT_SEC",
            "ATTEMPT_ID",
            "HOST_PLATFORM",
            "HOST_ARCH",
            "FORCE_INSTALL",
            "ALLOW_LEGACY_PPT1",
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

BASE="$HOME/.pi-adaptor"
RELEASES="$BASE/releases"
WORK="$BASE/.bootstrap"
STATE="$WORK/state.json"
RECEIPT="$WORK/install-receipt.json"
PAIR_JSON="$WORK/pair.json"
PAIR_RESULT="$WORK/pair.result"
PAIR_REJECT="$WORK/pair.reject"
VERIFY_RESULT="$WORK/verify.result"
CANCEL="$WORK/cancel"
LOCK="$WORK/active.lock"
PART="$WORK/$ARTIFACT_NAME.part"
CHECKSUM_FILE="$WORK/$ARTIFACT_NAME.sha256"
TRANSACTION_ACTIVE="$WORK/transaction.active"
TRANSACTION_PREVIOUS="$WORK/transaction.previous"
TRANSACTION_SERVICE="$WORK/transaction.service-active"
TRANSACTION_INSTALL_DIR="$WORK/transaction.install-dir"
TRANSACTION_ROLLBACK_SCRIPT="$WORK/transaction.rollback-install.sh"
TRANSACTION_RECEIPT_BACKUP="$WORK/transaction.receipt.previous"
TRANSACTION_LEGACY="$WORK/transaction.legacy-units"
ROLLBACK_SCRIPT="$WORK/install.sh"

CURRENT_STEP="probe"
ARTIFACT_BYTES=0
DOWNLOADED_BYTES=0
EXPECTED_SHA256=""
SERVICE_STATE="absent"
MANUAL_PID=""
PAIR_READER_PID=""
STAGE=""
INSTALL_DIR=""
PREVIOUS_CURRENT_TARGET="none"
PREVIOUS_SERVICE_ACTIVE=0
CURRENT_SERVICE_STOPPED=0
LEGACY_UNITS_STOPPED=""
LEGACY_UNITS_JSON="[]"
FAILURE_REASON=""
ROLLBACK_RESULT="not-needed"
TRANSACTION_STARTED=0

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
    details_reason=${FAILURE_REASON:-$error_code}
    error_json="{\"code\":\"$error_code\",\"details\":{\"reason\":\"$details_reason\",\"phase\":\"$next_step\",\"expectedName\":\"$SERVER_NAME\",\"expectedVersion\":\"$VERSION\",\"installDirectory\":\"$INSTALL_DIR\",\"unitName\":\"$UNIT_NAME\",\"port\":$PORT,\"legacyUnits\":$LEGACY_UNITS_JSON,\"rollback\":\"$ROLLBACK_RESULT\"}}"
  fi
  tmp="$STATE.tmp.$$"
  {
    printf '{"version":1,"attemptId":"%s","step":"%s","status":"%s",' "$ATTEMPT_ID" "$next_step" "$status"
    printf '"host":{"platform":"%s","arch":"%s"},' "$HOST_PLATFORM" "$HOST_ARCH"
    printf '"artifact":{"name":"%s","sha256":"%s","bytes":%s,"downloadedBytes":%s},' \
      "$ARTIFACT_NAME" "$EXPECTED_SHA256" "$ARTIFACT_BYTES" "$DOWNLOADED_BYTES"
    printf '"service":{"unitPath":"%s","state":"%s"},' "$HOME/.config/systemd/user/$UNIT_NAME" "$service_value"
    printf '"error":%s,"updatedAt":"%s"}\n' "$error_json" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$STATE"
}

refresh_legacy_units_json() {
  LEGACY_UNITS_JSON='[]'
  [ -f "$TRANSACTION_LEGACY" ] || return 0
  LEGACY_UNITS_JSON='['
  legacy_separator=''
  while IFS='|' read -r legacy_unit was_active was_enabled; do
    case "$legacy_unit" in
      pi-host.service|pi-host-v2.service) ;;
      *) continue ;;
    esac
    enabled_json=false
    case "$was_enabled" in
      enabled|enabled-runtime) enabled_json=true ;;
    esac
    LEGACY_UNITS_JSON="$LEGACY_UNITS_JSON$legacy_separator{\"unit\":\"$legacy_unit\",\"originalActive\":true,\"originalEnabled\":$enabled_json,\"originalEnableState\":\"$was_enabled\",\"portOccupied\":true}"
    legacy_separator=','
  done <"$TRANSACTION_LEGACY"
  LEGACY_UNITS_JSON="$LEGACY_UNITS_JSON]"
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

record_transaction() {
  current_link="$BASE/current"
  if [ -L "$current_link" ]; then
    previous=$(readlink "$current_link" 2>/dev/null || true)
    case "$previous" in
      releases/*) PREVIOUS_CURRENT_TARGET=$previous ;;
      *) PREVIOUS_CURRENT_TARGET="invalid" ;;
    esac
  elif [ -e "$current_link" ]; then
    PREVIOUS_CURRENT_TARGET="invalid"
  else
    PREVIOUS_CURRENT_TARGET="none"
  fi
  printf '%s\n' "$PREVIOUS_CURRENT_TARGET" >"$TRANSACTION_PREVIOUS"
  chmod 600 "$TRANSACTION_PREVIOUS"

  if systemctl --user is-active --quiet "$UNIT_NAME" >/dev/null 2>&1; then
    PREVIOUS_SERVICE_ACTIVE=1
  else
    PREVIOUS_SERVICE_ACTIVE=0
  fi
  printf '%s\n' "$PREVIOUS_SERVICE_ACTIVE" >"$TRANSACTION_SERVICE"
  chmod 600 "$TRANSACTION_SERVICE"

  printf '%s\n' "$INSTALL_DIR" >"$TRANSACTION_INSTALL_DIR"
  chmod 600 "$TRANSACTION_INSTALL_DIR"
  cp "$ROLLBACK_SCRIPT" "$TRANSACTION_ROLLBACK_SCRIPT" 2>/dev/null || {
    printf '%s\n' "PI_HOST_BOOTSTRAP_FAILED install-failed" >&2
    exit 1
  }
  chmod 700 "$TRANSACTION_ROLLBACK_SCRIPT"

  rm -f "$TRANSACTION_RECEIPT_BACKUP"
  rm -f "$TRANSACTION_LEGACY"
  LEGACY_UNITS_JSON='[]'
  if [ -f "$RECEIPT" ]; then
    cp "$RECEIPT" "$TRANSACTION_RECEIPT_BACKUP"
    chmod 600 "$TRANSACTION_RECEIPT_BACKUP"
  fi
  : >"$TRANSACTION_ACTIVE"
  chmod 600 "$TRANSACTION_ACTIVE"
  TRANSACTION_STARTED=1
}

restore_legacy_units() {
  [ -f "$TRANSACTION_LEGACY" ] || return 0
  restore_ok=1
  while IFS='|' read -r unit was_active was_enabled; do
    case "$unit" in
      pi-host.service|pi-host-v2.service) ;;
      *) continue ;;
    esac
    case "$was_enabled" in
      enabled)
        systemctl --user enable "$unit" >/dev/null 2>&1 || restore_ok=0
        ;;
      enabled-runtime)
        systemctl --user enable --runtime "$unit" >/dev/null 2>&1 || restore_ok=0
        ;;
      linked|linked-runtime)
        # The link itself was never removed; stopping the service is sufficient.
        ;;
      *)
        # Other transient/static states are not persistent enablement and were
        # neither disabled during activation nor re-enabled during rollback.
        ;;
    esac
    if [ "$was_active" = "active" ]; then
      if ! systemctl --user start "$unit" >/dev/null 2>&1 ||
         ! systemctl --user is-active --quiet "$unit" >/dev/null 2>&1; then
        restore_ok=0
      fi
    fi
    restored_enabled=$(systemctl --user is-enabled "$unit" 2>/dev/null || true)
    [ "$restored_enabled" = "$was_enabled" ] || restore_ok=0
  done <"$TRANSACTION_LEGACY"
  [ "$restore_ok" = 1 ]
}

rollback_transaction() {
  [ "$TRANSACTION_STARTED" = 1 ] || [ -f "$TRANSACTION_ACTIVE" ] || return 0
  ROLLBACK_RESULT="attempted"
  rollback_ok=1
  if systemctl --user is-active --quiet "$UNIT_NAME" >/dev/null 2>&1; then
    if ! systemctl --user stop "$UNIT_NAME" >/dev/null 2>&1; then
      rollback_ok=0
    fi
    if systemctl --user is-active --quiet "$UNIT_NAME" >/dev/null 2>&1; then
      rollback_ok=0
    fi
  fi

  previous=$PREVIOUS_CURRENT_TARGET
  failed_install=$INSTALL_DIR
  [ ! -f "$TRANSACTION_PREVIOUS" ] || previous=$(cat "$TRANSACTION_PREVIOUS" 2>/dev/null || printf 'none')
  [ ! -f "$TRANSACTION_INSTALL_DIR" ] || failed_install=$(cat "$TRANSACTION_INSTALL_DIR" 2>/dev/null || true)
  [ -n "$failed_install" ] || failed_install="none"

  if [ -x "$TRANSACTION_ROLLBACK_SCRIPT" ] &&
     "$TRANSACTION_ROLLBACK_SCRIPT" --rollback \
       --home "$BASE" \
       --previous-current-target "$previous" \
       --failed-install-dir "$failed_install" >/dev/null 2>&1; then
    :
  else
    rollback_ok=0
  fi

  if [ -f "$TRANSACTION_RECEIPT_BACKUP" ]; then
    cp "$TRANSACTION_RECEIPT_BACKUP" "$RECEIPT" 2>/dev/null || true
    chmod 600 "$RECEIPT" 2>/dev/null || true
  else
    rm -f "$RECEIPT"
  fi

  if [ "$PREVIOUS_SERVICE_ACTIVE" = 1 ]; then
    if ! systemctl --user start "$UNIT_NAME" >/dev/null 2>&1 ||
       ! systemctl --user is-active --quiet "$UNIT_NAME" >/dev/null 2>&1; then
      rollback_ok=0
    fi
  fi

  # Legacy units are recovery for the pre-install environment, never evidence
  # of PI-adaptor success. Restore them only when there was no previous
  # PI-adaptor target or the PI-adaptor rollback itself failed.
  if [ "$previous" = "none" ] || [ "$rollback_ok" = 0 ]; then
    restore_legacy_units || rollback_ok=0
  fi

  if [ "$rollback_ok" = 1 ]; then
    ROLLBACK_RESULT="succeeded"
    rm -f "$TRANSACTION_ACTIVE" "$TRANSACTION_PREVIOUS" "$TRANSACTION_SERVICE" \
      "$TRANSACTION_INSTALL_DIR" "$TRANSACTION_ROLLBACK_SCRIPT" \
      "$TRANSACTION_RECEIPT_BACKUP" "$TRANSACTION_LEGACY"
    TRANSACTION_STARTED=0
    return 0
  fi

  ROLLBACK_RESULT="failed"
  return 1
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
  FAILURE_REASON=${2:-$failure_code}
  trap - HUP INT TERM
  cleanup_manual
  redact_pair_stderr || true
  rm -f "$PAIR_JSON" "$PAIR_JSON".tmp.* "$WORK/pair.fifo" "$WORK/pair.result" "$WORK/verify.result"
  refresh_legacy_units_json
  rollback_transaction || ROLLBACK_RESULT="failed"
  if [ "$ROLLBACK_RESULT" = "failed" ]; then
    FAILURE_REASON="rollback-failed"
    write_state "$CURRENT_STEP" failed "rollback-failed" || true
    printf '%s\n' "PI_HOST_BOOTSTRAP_FAILED rollback-failed" >&2
    printf '%s\n' "PI_HOST_FAILED {\"code\":\"HOST_BOOTSTRAP_FAILED\",\"step\":\"rollback-failed\"}"
    exit 1
  fi
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
    *"$BASE/current/dist/main.js"*"--pair"*) ;;
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
rm -f "$PAIR_REJECT"

if [ -f "$TRANSACTION_ACTIVE" ]; then
  TRANSACTION_STARTED=1
  PREVIOUS_CURRENT_TARGET=$(cat "$TRANSACTION_PREVIOUS" 2>/dev/null || printf 'none')
  PREVIOUS_SERVICE_ACTIVE=$(cat "$TRANSACTION_SERVICE" 2>/dev/null || printf '0')
  INSTALL_DIR=$(cat "$TRANSACTION_INSTALL_DIR" 2>/dev/null || true)
  refresh_legacy_units_json
  if ! rollback_transaction; then
    FAILURE_REASON="rollback-failed"
    write_state probe failed "rollback-failed" || true
    printf '%s\n' "PI_HOST_BOOTSTRAP_FAILED rollback-failed" >&2
    printf '%s\n' "PI_HOST_FAILED {\"code\":\"HOST_BOOTSTRAP_FAILED\",\"step\":\"rollback-failed\"}"
    exit 1
  fi
fi

step "probe"
ARTIFACT_BYTES=0
DOWNLOADED_BYTES=0
write_state probe running || die "bootstrap-permissions"

need tar || die "missing-tar"
need mkfifo || die "missing-tar"
need node || die "missing-node"
need bash || die "missing-bash"
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
printf '%s\n' "$PINNED_SHA256" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || die "checksum-mismatch"
if [ "$EXPECTED_SHA256" != "$PINNED_SHA256" ]; then
  die "checksum-mismatch"
fi
write_state resolve running || die "bootstrap-permissions"

reuse=0
manifest_sha256=""
if [ "$FORCE_INSTALL" = 1 ]; then
  # 强制重装：不信任任何本地 receipt，重新下载并激活（用户点「重新安装」时走这里）。
  progress "force"
elif [ -f "$RECEIPT" ] && [ -L "$BASE/current" ] && [ -f "$BASE/current/SHA256SUMS" ]; then
  receipt_fields=$(node -e '
    const fs = require("fs");
    try {
      const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      process.stdout.write([
        value.schemaVersion,
        value.version,
        value.target,
        value.assetSha256,
        value.installedManifestSha256,
        value.bundleDirectory,
        value.installDirectory,
        value.entrypoint,
        value.unitName,
      ].map((item) => item == null ? "" : String(item)).join("\n"));
    } catch {
      process.exit(1);
    }
  ' "$RECEIPT" 2>/dev/null || true)
  receipt_schema=$(printf '%s\n' "$receipt_fields" | sed -n '1p')
  receipt_version=$(printf '%s\n' "$receipt_fields" | sed -n '2p')
  receipt_target=$(printf '%s\n' "$receipt_fields" | sed -n '3p')
  receipt_asset=$(printf '%s\n' "$receipt_fields" | sed -n '4p')
  receipt_manifest=$(printf '%s\n' "$receipt_fields" | sed -n '5p')
  receipt_bundle=$(printf '%s\n' "$receipt_fields" | sed -n '6p')
  receipt_install=$(printf '%s\n' "$receipt_fields" | sed -n '7p')
  receipt_entrypoint=$(printf '%s\n' "$receipt_fields" | sed -n '8p')
  receipt_unit=$(printf '%s\n' "$receipt_fields" | sed -n '9p')
  manifest_sha256=$(sha256_of "$BASE/current/SHA256SUMS") || die "missing-sha256-tool"
  expected_target="releases/$VERSION-$EXPECTED_SHA256"
  receipt_install_matches=0
  if [ -n "$receipt_install" ] && [ -d "$receipt_install" ] && [ -d "$BASE/$expected_target" ]; then
    receipt_install_matches=$(node -e '
      const fs = require("fs");
      try {
        const actual = fs.realpathSync(process.argv[1]);
        const expected = fs.realpathSync(process.argv[2]);
        process.stdout.write(actual === expected ? "1" : "0");
      } catch {
        process.stdout.write("0");
      }
    ' "$receipt_install" "$BASE/$expected_target")
  fi
  if [ "$receipt_schema" = "1" ] &&
     [ "$receipt_version" = "$VERSION" ] &&
     [ "$receipt_target" = "$TARGET" ] &&
     [ "$receipt_asset" = "$EXPECTED_SHA256" ] &&
     [ "$receipt_manifest" = "$manifest_sha256" ] &&
     [ "$receipt_bundle" = "pi-adaptor-$VERSION-$TARGET" ] &&
     [ "$receipt_install_matches" = "1" ] &&
     [ "$receipt_entrypoint" = "dist/main.js" ] &&
     [ "$receipt_unit" = "$UNIT_NAME" ] &&
     [ "$(readlink "$BASE/current" 2>/dev/null || true)" = "$expected_target" ] &&
     "$BASE/current/scripts/install.sh" --verify \
       --install-dir "$BASE/current" \
       --version "$VERSION" \
       --target "$TARGET" \
       --asset-sha256 "$EXPECTED_SHA256" \
       --manifest-sha256 "$manifest_sha256" >/dev/null 2>&1; then
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
  [ -f "$unpack/$BUNDLE_DIR/dist/main.js" ] || die "unexpected-archive-layout"
  [ -f "$unpack/$BUNDLE_DIR/scripts/install.sh" ] || die "unexpected-archive-layout"
  [ -f "$unpack/$BUNDLE_DIR/SHA256SUMS" ] || die "unexpected-archive-layout"
  manifest_sha256=$(sha256_of "$unpack/$BUNDLE_DIR/SHA256SUMS") || die "missing-sha256-tool"
  cp "$unpack/$BUNDLE_DIR/scripts/install.sh" "$ROLLBACK_SCRIPT" || die "install-failed"
  chmod 700 "$ROLLBACK_SCRIPT"
  INSTALL_DIR="$RELEASES/$VERSION-$EXPECTED_SHA256"
  record_transaction
  progress "activate"
  "$unpack/$BUNDLE_DIR/scripts/install.sh" --install \
    --bundle "$unpack/$BUNDLE_DIR" \
    --home "$BASE" \
    --version "$VERSION" \
    --target "$TARGET" \
    --asset-sha256 "$EXPECTED_SHA256" \
    --manifest-sha256 "$manifest_sha256" >/dev/null || die "install-failed"
  rm -f "$PART"
else
  cp "$BASE/current/scripts/install.sh" "$ROLLBACK_SCRIPT" || die "install-failed"
  chmod 700 "$ROLLBACK_SCRIPT"
  INSTALL_DIR="$RELEASES/$VERSION-$EXPECTED_SHA256"
  record_transaction
  progress "activate"
  "$ROLLBACK_SCRIPT" --install \
    --bundle "$BASE/current" \
    --home "$BASE" \
    --version "$VERSION" \
    --target "$TARGET" \
    --asset-sha256 "$EXPECTED_SHA256" \
    --manifest-sha256 "$manifest_sha256" >/dev/null || die "install-failed"
fi

"$ROLLBACK_SCRIPT" --verify \
  --install-dir "$BASE/current" \
  --version "$VERSION" \
  --target "$TARGET" \
  --asset-sha256 "$EXPECTED_SHA256" \
  --manifest-sha256 "$manifest_sha256" >/dev/null || die "installed-verification-failed"
installed_version=$(node -e '
  const fs = require("fs");
  process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version || ""));
' "$BASE/current/package.json" 2>/dev/null || true)
[ "$installed_version" = "$VERSION" ] || die "installed-verification-failed"

need node || die "missing-node"
node=$(command -v node)
"$node" -e '
  const parse = (value) => value.split(".").map((part) => Number(part));
  const current = parse(process.versions.node);
  const minimum = parse(process.argv[1]);
  for (let i = 0; i < 3; i += 1) {
    if (current[i] > minimum[i]) process.exit(0);
    if (current[i] < minimum[i]) process.exit(1);
  }
' "$MIN_NODE_VERSION" 2>/dev/null || die "node-too-old"

progress "write-unit"
unit_dir="$HOME/.config/systemd/user"
mkdir -p "$unit_dir" || die "unit-failed"
unit_path="$unit_dir/$UNIT_NAME"
unit_tmp="$unit_dir/.$UNIT_NAME.$$"
{
  printf '%s\n' '[Unit]'
  printf '%s\n' 'Description=PI-adaptor'
  printf '%s\n' 'After=network.target'
  printf '%s\n' ''
  printf '%s\n' '[Service]'
  printf '%s\n' 'Type=simple'
  printf 'Environment="PI_ADAPTOR_HOME=%s"\n' "$BASE"
  printf 'Environment="PI_ADAPTOR_PORT=%s"\n' "$PORT"
  printf 'Environment="PI_ADAPTOR_HOST_ID=pi-adaptor-%s"\n' "$HOST_ARCH"
  printf 'ExecStart="%s" "%s/current/dist/main.js" --home "%s" --port %s\n' \
    "$node" "$BASE" "$BASE" "$PORT"
  printf 'WorkingDirectory=%s\n' "$BASE"
  printf '%s\n' 'Restart=on-failure'
  printf '%s\n' 'RestartSec=2'
  printf '%s\n' 'NoNewPrivileges=yes'
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
systemctl --user stop "$UNIT_NAME" >/dev/null 2>&1 || true
if systemctl --user is-active --quiet "$UNIT_NAME" >/dev/null 2>&1; then
  die "unit-failed"
fi

for legacy_unit in pi-host.service pi-host-v2.service; do
  legacy_active=$(systemctl --user show "$legacy_unit" \
    --property=ActiveState 2>/dev/null | sed -n 's/^ActiveState=//p' | head -n 1)
  if [ "$legacy_active" = "active" ]; then
    legacy_exec=$(systemctl --user show "$legacy_unit" \
      --property=ExecStart 2>/dev/null | sed -n 's/^ExecStart=//p' | head -n 1)
    if printf '%s\n' "$legacy_exec" |
       grep -Eq -- "(^|[[:space:]])--port(=|[[:space:]])$PORT([[:space:];}]|$)"; then
      legacy_enabled=$(systemctl --user is-enabled "$legacy_unit" 2>/dev/null || printf 'disabled')
      case "$legacy_enabled" in
        ''|*[!A-Za-z0-9-]*) legacy_enabled="unknown" ;;
      esac
      printf '%s|active|%s\n' "$legacy_unit" "$legacy_enabled" >>"$TRANSACTION_LEGACY"
      chmod 600 "$TRANSACTION_LEGACY" 2>/dev/null || die "bootstrap-permissions"
      LEGACY_UNITS_STOPPED="$LEGACY_UNITS_STOPPED $legacy_unit"
      systemctl --user stop "$legacy_unit" >/dev/null 2>&1 ||
        die "unit-failed" "legacy-service-conflict"
      case "$legacy_enabled" in
        enabled)
          systemctl --user disable "$legacy_unit" >/dev/null 2>&1 ||
            die "unit-failed" "legacy-service-conflict"
          ;;
        enabled-runtime)
          systemctl --user disable --runtime "$legacy_unit" >/dev/null 2>&1 ||
            die "unit-failed" "legacy-service-conflict"
          ;;
        linked|linked-runtime)
          # Stopping the process must not unlink a user-managed unit.
          ;;
        *)
          # Static, generated, transient and other non-persistent states cannot
          # be disabled without changing user-managed enablement.
          ;;
      esac
    fi
  fi
done
if ps -eo pid=,args= 2>/dev/null |
   grep -E 'pi-host\.js' | grep -E -- "--port[ =]$PORT([[:space:]]|$)" >/dev/null 2>&1; then
  die "unit-failed" "legacy-service-conflict"
fi
if need ss && ss -H -ltn "sport = :$PORT" 2>/dev/null | grep -q .; then
  die "unit-failed" "legacy-service-conflict"
fi
if ! need ss && need lsof &&
   lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  die "unit-failed" "legacy-service-conflict"
fi

previous_pid=$(cat "$WORK/manual.pid" 2>/dev/null || true)
stop_manual_process "$previous_pid" || die "host-stop-timeout"
rm -f "$PAIR_JSON" "$PAIR_RESULT" "$PAIR_REJECT" "$VERIFY_RESULT" "$WORK/pair.fifo"

mkfifo "$WORK/pair.fifo" || die "host-start-failed"
chmod 600 "$WORK/pair.fifo" 2>/dev/null || die "bootstrap-permissions"
: >"$WORK/pair.err"
chmod 600 "$WORK/pair.err" 2>/dev/null || die "bootstrap-permissions"

# The manual and systemd processes must use the same isolated root.
PI_ADAPTOR_HOME="$BASE" \
"$node" "$BASE/current/dist/main.js" \
  --home "$BASE" \
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
          ppt2.*) ;;
          ppt1.*)
            if [ "$ALLOW_LEGACY_PPT1" != 1 ]; then
              printf '%s\n' legacy-pairing-token >"$PAIR_REJECT"
              continue
            fi
            ;;
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
  [ -f "$CANCEL" ] && die "pair-failed" "cancelled"
  if [ -s "$PAIR_REJECT" ]; then
    reason=$(cat "$PAIR_REJECT" 2>/dev/null || printf 'pair-failed')
    die "pair-failed" "$reason"
  fi
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
  [ -f "$CANCEL" ] && die "pair-failed" "cancelled"
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
systemctl --user start "$UNIT_NAME" >/dev/null 2>&1 || die "unit-failed"
systemctl --user is-active --quiet "$UNIT_NAME" >/dev/null 2>&1 || die "unit-failed"
SERVICE_STATE="active"
CURRENT_SERVICE_STOPPED=0
write_state "start-unit" running "" "active" || die "bootstrap-permissions"

progress "verify-device"
waited=0
while [ ! -s "$VERIFY_RESULT" ]; do
  [ -f "$CANCEL" ] && die "verify-device-failed" "cancelled"
  [ "$waited" -lt "$VERIFY_TIMEOUT_SEC" ] || die "verify-device-failed"
  sleep 1
  waited=$((waited + 1))
done
verify_result=$(cat "$VERIFY_RESULT" 2>/dev/null || true)
rm -f "$VERIFY_RESULT"
[ "$verify_result" = "ok" ] || die "verify-device-failed"

step "done"
write_state "done" ok "" "active" || die "receipt-failed"
ROLLBACK_RESULT="not-needed"
TRANSACTION_STARTED=0
rm -f "$TRANSACTION_ACTIVE" "$TRANSACTION_PREVIOUS" "$TRANSACTION_SERVICE" \
  "$TRANSACTION_INSTALL_DIR" "$TRANSACTION_ROLLBACK_SCRIPT" \
  "$TRANSACTION_RECEIPT_BACKUP" "$TRANSACTION_LEGACY"
"""#
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The non-secret progress commands used between polling reads.
public enum BootstrapRemoteCommand {
    public static let workDirectory = #"$HOME/.pi-adaptor/.bootstrap"#
    public static let statePath = #"$HOME/.pi-adaptor/.bootstrap/state.json"#
    public static let pairPath = #"$HOME/.pi-adaptor/.bootstrap/pair.json"#
    public static let scriptPath = #"$HOME/.pi-adaptor/.bootstrap/bootstrap.sh"#

    /// One exec performs the only platform probe used by the whole run.
    public static let probe = #"printf 'platform=%s\narch=%s\n' "$(uname -s)" "$(uname -m)""#

    public static let installScript = #"umask 077; mkdir -p "$HOME/.pi-adaptor/.bootstrap" && chmod 700 "$HOME/.pi-adaptor/.bootstrap" && cat > "$HOME/.pi-adaptor/.bootstrap/bootstrap.sh" && chmod 700 "$HOME/.pi-adaptor/.bootstrap/bootstrap.sh""#

    public static let launch = #"work="$HOME/.pi-adaptor/.bootstrap"; command -v setsid >/dev/null 2>&1 || exit 1; command -v nohup >/dev/null 2>&1 || exit 1; cd "$work" || exit 1; setsid nohup /bin/sh ./bootstrap.sh >bootstrap.log 2>&1 </dev/null & printf 'pid=%s\n' "$!""#

    public static let readState = #"cat "$HOME/.pi-adaptor/.bootstrap/state.json" 2>/dev/null || true"#

    public static let readPairing = #"cat "$HOME/.pi-adaptor/.bootstrap/pair.json" 2>/dev/null || true"#

    public static let writePairingOK = #"umask 077; printf '%s\n' ok > "$HOME/.pi-adaptor/.bootstrap/pair.result" && chmod 600 "$HOME/.pi-adaptor/.bootstrap/pair.result""#

    public static let writePairingFailed = #"umask 077; printf '%s\n' failed > "$HOME/.pi-adaptor/.bootstrap/pair.result" && chmod 600 "$HOME/.pi-adaptor/.bootstrap/pair.result""#

    public static let writeVerificationOK = #"umask 077; printf '%s\n' ok > "$HOME/.pi-adaptor/.bootstrap/verify.result" && chmod 600 "$HOME/.pi-adaptor/.bootstrap/verify.result""#

    public static let writeVerificationFailed = #"umask 077; printf '%s\n' failed > "$HOME/.pi-adaptor/.bootstrap/verify.result" && chmod 600 "$HOME/.pi-adaptor/.bootstrap/verify.result""#

    public static let cancel = #"umask 077; printf '%s\n' cancel > "$HOME/.pi-adaptor/.bootstrap/cancel" && chmod 600 "$HOME/.pi-adaptor/.bootstrap/cancel""#
}

/// Token material handed from the owner-only remote file to the pairing
/// callback. This value must never be logged or persisted on the client.
public struct BootstrapPairingMaterial: Codable, Equatable, Sendable {
    public let token: String
    public let expiresAt: Int64
    public let host: String
    public let port: Int

    public init(
        token: String,
        expiresAt: Int64,
        host: String,
        port: Int,
        allowLegacyPPT1: Bool = false
    ) throws {
        let isPPT2 = token.hasPrefix("ppt2.")
        let isPPT1 = allowLegacyPPT1 && token.hasPrefix("ppt1.")
        guard isPPT2 || isPPT1,
              token.utf8.count > "ppt2.".count,
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
