import CryptoKit
import Foundation
import XCTest

@testable import PIiOSCore

/// Runs the generated POSIX script against isolated fake curl/systemd. The
/// installed package uses the production installer from apps/host/scripts.
final class BootstrapScriptIntegrationTests: XCTestCase {
    private let pairingToken = "ppt2." + "integration-token"

    func testInstallsImmutablePIAdaptorReleaseAndStartsNewUnit() throws {
        let environment = try makeEnvironment()
        let legacyRoot = environment.home
            .appendingPathComponent(".pi-desktop/pi-host", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyRoot.appendingPathComponent("pi-host.js"))
        try Data("0.21.0  old  manifest\n".utf8)
            .write(to: legacyRoot.appendingPathComponent(".release.sha256"))

        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        defer { terminateIfNeeded(process) }
        try completePairingHandshake(environment: environment, process: process)

        let failureOutput = try capturedFailure(environment)
        XCTAssertEqual(process.terminationStatus, 0, failureOutput)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.step, .done)
        XCTAssertEqual(state.status, .ok)
        XCTAssertEqual(try permissions(environment.stateURL), 0o600)
        XCTAssertEqual(try permissions(environment.workDirectory), 0o700)

        let current = environment.installRoot.appendingPathComponent("current")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: current.path),
            "releases/2.0.1-\(environment.assetSha256)"
        )
        let package = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: current.appendingPathComponent("package.json"))
            ) as? [String: Any]
        )
        XCTAssertEqual(package["name"] as? String, "@pi-ios/pi-adaptor")
        XCTAssertEqual(package["version"] as? String, "2.0.1")

        let unit = try String(
            contentsOf: environment.home.appendingPathComponent(
                ".config/systemd/user/pi-adaptor.service"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(unit.contains("Description=PI-adaptor"))
        XCTAssertTrue(unit.contains("current/dist/main.js"))
        XCTAssertFalse(unit.contains(".pi-desktop/pi-host"))
        XCTAssertFalse(unit.contains("--pair"))

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-pi-adaptor-active").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacyRoot.appendingPathComponent("pi-host.js").path),
            "legacy data must remain isolated and untouched"
        )

        let pairURL = environment.workDirectory.appendingPathComponent("pair.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pairURL.path))
        for output in try persistedOutputs(environment) {
            XCTAssertFalse(output.contains(pairingToken), "pairing token must never be logged")
        }
    }

    func testDownloadFailureResumesAndDoesNotSwitchCurrent() throws {
        let environment = try makeEnvironment(downloadMode: "fail-once")
        let first = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try waitForExit(first, timeout: 10)
        XCTAssertNotEqual(first.terminationStatus, 0)
        let firstState = try decodeState(environment.stateURL)
        XCTAssertEqual(firstState.step, .download)
        XCTAssertEqual(firstState.failureCode, .downloadFailed)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.installRoot.appendingPathComponent("current").path
            )
        )

        let second = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        defer { terminateIfNeeded(second) }
        try completePairingHandshake(environment: environment, process: second)
        let secondFailureOutput = try capturedFailure(environment)
        XCTAssertEqual(second.terminationStatus, 0, secondFailureOutput)
        XCTAssertEqual(try decodeState(environment.stateURL).step, .done)
    }

    func testChecksumMismatchLeavesNoCurrentOrStage() throws {
        let environment = try makeEnvironment(validChecksum: false)
        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try waitForExit(process, timeout: 8)
        XCTAssertNotEqual(process.terminationStatus, 0)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.step, .resolve)
        XCTAssertEqual(state.failureCode, .checksumMismatch)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.installRoot.appendingPathComponent("current").path
            )
        )
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: environment.installRoot.path
        ).filter { $0.hasPrefix(".stage.") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testForceReinstallDownloadsAgainAndKeepsTargetVersion() throws {
        let environment = try makeEnvironment()
        let first = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try completePairingHandshake(environment: environment, process: first)
        let firstFailureOutput = try capturedFailure(environment)
        XCTAssertEqual(first.terminationStatus, 0, firstFailureOutput)
        XCTAssertEqual(try downloadCount(environment), 1)

        let second = try launch(
            script: generatedScript(environment, force: true),
            environment: environment
        )
        defer { terminateIfNeeded(second) }
        try completePairingHandshake(environment: environment, process: second)
        let secondFailureOutput = try capturedFailure(environment)
        XCTAssertEqual(second.terminationStatus, 0, secondFailureOutput)
        XCTAssertEqual(try downloadCount(environment), 2)

        let current = environment.installRoot.appendingPathComponent("current")
        let installedVersion = try String(
            contentsOf: current.appendingPathComponent("package.json"),
            encoding: .utf8
        )
        XCTAssertTrue(installedVersion.contains(#""version":"2.0.1""#))
    }

    func testVerifiedReceiptReusesImmutableReleaseWithoutDownloading() throws {
        let environment = try makeEnvironment()
        let first = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try completePairingHandshake(environment: environment, process: first)
        let firstFailure = try capturedFailure(environment)
        XCTAssertEqual(first.terminationStatus, 0, firstFailure)
        XCTAssertEqual(try downloadCount(environment), 1)

        let second = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        defer { terminateIfNeeded(second) }
        try completePairingHandshake(environment: environment, process: second)
        let secondFailure = try capturedFailure(environment)
        XCTAssertEqual(second.terminationStatus, 0, secondFailure)
        XCTAssertEqual(try downloadCount(environment), 1)

        let receiptData = try Data(
            contentsOf: environment.workDirectory.appendingPathComponent("install-receipt.json")
        )
        let receipt = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: receiptData) as? [String: Any]
        )
        XCTAssertEqual(receipt["bundleDirectory"] as? String, environment.release.bundleDirectoryName)
        XCTAssertEqual(receipt["version"] as? String, "2.0.1")
        XCTAssertEqual(receipt["target"] as? String, "linux-arm64")
    }

    func testLegacyPPT1IsRejectedAndTransactionRollsBack() throws {
        let environment = try makeEnvironment(tokenPrefix: "ppt1")
        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try waitForExit(process, timeout: 15)
        XCTAssertNotEqual(process.terminationStatus, 0)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.failureCode, .pairFailed)
        XCTAssertEqual(
            state.error?.value(at: ["details", "reason"])?.stringValue,
            "legacy-pairing-token"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.installRoot.appendingPathComponent("current").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.workDirectory.appendingPathComponent("transaction.active").path
            )
        )
    }

    func testLegacyUnitIsStoppedOnlyWhenItOccupiesTheTargetPort() throws {
        let environment = try makeEnvironment(legacyConflict: true)
        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        defer { terminateIfNeeded(process) }
        try completePairingHandshake(environment: environment, process: process)

        let failure = try capturedFailure(environment)
        XCTAssertEqual(process.terminationStatus, 0, failure)
        XCTAssertEqual(try decodeState(environment.stateURL).step, .done)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-legacy-active").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-legacy-enabled").path
            )
        )
    }

    func testLegacyConflictIsRestoredAfterFailedInstall() throws {
        let environment = try makeEnvironment(tokenPrefix: "ppt1", legacyConflict: true)
        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try waitForExit(process, timeout: 15)

        XCTAssertNotEqual(process.terminationStatus, 0)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.failureCode, .pairFailed)
        let legacyUnits = try XCTUnwrap(
            state.error?.value(at: ["details", "legacyUnits"])?.arrayValue
        )
        XCTAssertEqual(legacyUnits.first?.value(at: ["unit"])?.stringValue, "pi-host.service")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-legacy-active").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-legacy-enabled").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.installRoot.appendingPathComponent("current").path
            )
        )
    }

    func testLegacyEnabledRuntimeIsDisabledAndRestoredExactly() throws {
        let environment = try makeEnvironment(
            tokenPrefix: "ppt1",
            legacyConflict: true,
            legacyEnableState: "enabled-runtime"
        )
        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try waitForExit(process, timeout: 20)

        XCTAssertNotEqual(process.terminationStatus, 0)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.failureCode, .pairFailed)
        let legacyUnits = try XCTUnwrap(
            state.error?.value(at: ["details", "legacyUnits"])?.arrayValue
        )
        XCTAssertEqual(
            legacyUnits.first?.value(at: ["originalEnableState"])?.stringValue,
            "enabled-runtime"
        )
        XCTAssertEqual(
            legacyUnits.first?.value(at: ["originalEnabled"])?.boolValue,
            true
        )
        XCTAssertEqual(
            try String(
                contentsOf: environment.home.appendingPathComponent(".fake-legacy-enable-state"),
                encoding: .utf8
            ),
            "enabled-runtime\n"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-legacy-active").path
            )
        )
    }

    func testLinkedLegacyUnitIsStoppedWithoutChangingEnableState() throws {
        let environment = try makeEnvironment(
            tokenPrefix: "ppt1",
            legacyConflict: true,
            legacyEnableState: "linked"
        )
        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try waitForExit(process, timeout: 20)

        XCTAssertNotEqual(process.terminationStatus, 0)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.failureCode, .pairFailed)
        let legacyUnits = try XCTUnwrap(
            state.error?.value(at: ["details", "legacyUnits"])?.arrayValue
        )
        XCTAssertEqual(
            legacyUnits.first?.value(at: ["originalEnableState"])?.stringValue,
            "linked"
        )
        XCTAssertEqual(
            legacyUnits.first?.value(at: ["originalEnabled"])?.boolValue,
            false
        )
        XCTAssertEqual(
            try String(
                contentsOf: environment.home.appendingPathComponent(".fake-legacy-enable-state"),
                encoding: .utf8
            ),
            "linked\n"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-legacy-active").path
            )
        )
    }

    func testRollbackReportsFailureAndPreservesTransactionWhenServiceStopFails() throws {
        let environment = try makeEnvironment(
            tokenPrefix: "ppt1",
            failPiAdaptorStop: true,
            piAdaptorInitiallyActive: true
        )
        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try waitForExit(process, timeout: 20)

        XCTAssertNotEqual(process.terminationStatus, 0)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.failureCode, .unknown("rollback-failed"))
        XCTAssertEqual(
            state.error?.value(at: ["details", "rollback"])?.stringValue,
            "failed"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-pi-adaptor-active").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.workDirectory.appendingPathComponent("transaction.active").path
            )
        )
    }

    func testRollbackReportsFailureWhenLegacyRestoreCannotComplete() throws {
        let environment = try makeEnvironment(
            tokenPrefix: "ppt1",
            legacyConflict: true,
            failLegacyRestore: true
        )
        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try waitForExit(process, timeout: 20)

        XCTAssertNotEqual(process.terminationStatus, 0)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.failureCode, .unknown("rollback-failed"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-legacy-enabled").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.workDirectory.appendingPathComponent("transaction.active").path
            )
        )
    }

    func testInstallerRejectsPreviousTargetTraversalWithoutDeletingVictim() throws {
        let environment = try makeEnvironment()
        let releases = environment.installRoot.appendingPathComponent("releases", isDirectory: true)
        let victim = environment.installRoot.appendingPathComponent("victim", isDirectory: true)
        let marker = victim.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: releases, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(
            atPath: environment.installRoot.appendingPathComponent("current").path,
            withDestinationPath: "releases/../victim"
        )

        let bundle = environment.root
            .appendingPathComponent("source", isDirectory: true)
            .appendingPathComponent(environment.release.bundleDirectoryName, isDirectory: true)
        let manifestDigest = sha256(try Data(contentsOf: bundle.appendingPathComponent("SHA256SUMS")))
        let installer = repositoryRoot().appendingPathComponent("apps/host/scripts/install.sh")

        let install = try runProcess(
            "/bin/bash",
            arguments: [
                installer.path,
                "--install",
                "--bundle", bundle.path,
                "--home", environment.installRoot.path,
                "--version", "2.0.1",
                "--target", "linux-arm64",
                "--asset-sha256", environment.assetSha256,
                "--" + "manifest-sha256", manifestDigest,
            ],
            environment: environment.processEnvironment
        )
        XCTAssertEqual(install.status, 5, install.stderr)
        XCTAssertTrue(install.stderr.contains("canonical release directory"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: releases.path), [])

        let rollback = try runProcess(
            "/bin/bash",
            arguments: [
                installer.path,
                "--rollback",
                "--home", environment.installRoot.path,
                "--previous-current-target", "releases/../victim",
                "--failed-install-dir", "none",
            ],
            environment: environment.processEnvironment
        )
        XCTAssertEqual(rollback.status, 8, rollback.stderr)
        XCTAssertTrue(rollback.stderr.contains("canonical release directory"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: - Isolated environment

    private struct Environment {
        let root: URL
        let home: URL
        let installRoot: URL
        let workDirectory: URL
        let stateURL: URL
        let stdoutURL: URL
        let stderrURL: URL
        let release: PiHostRelease
        let assetSha256: String
        let artifactName: String
        let processEnvironment: [String: String]
    }

    private func makeEnvironment(
        validChecksum: Bool = true,
        downloadMode: String = "ok",
        tokenPrefix: String = "ppt2",
        legacyConflict: Bool = false,
        legacyEnableState: String = "enabled",
        failPiAdaptorStop: Bool = false,
        failLegacyRestore: Bool = false,
        piAdaptorInitiallyActive: Bool = false
    ) throws -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-ios-bootstrap-integration-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let fakeBin = root.appendingPathComponent("fake-bin", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let placeholder = try XCTUnwrap(
            PiHostRelease(
                version: "2.0.1",
                target: .linuxArm64,
                baseURL: "https://example.test/pi-adaptor-v2.0.1",
                pinnedChecksum: String(repeating: "0", count: 64)
            )
        )
        let bundle = source.appendingPathComponent(placeholder.bundleDirectoryName, isDirectory: true)
        let dist = bundle.appendingPathComponent("dist", isDirectory: true)
        let scripts = bundle.appendingPathComponent("scripts", isDirectory: true)
        let modules = bundle.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data(
            #"{"name":"@pi-ios/pi-adaptor","version":"2.0.1","private":true,"type":"module"}"#.utf8
        ).write(to: bundle.appendingPathComponent("package.json"))
        try Data("// fake PI-adaptor entry\n".utf8)
            .write(to: dist.appendingPathComponent("main.js"))
        try Data().write(to: modules.appendingPathComponent(".keep"))
        try FileManager.default.copyItem(
            at: repositoryRoot().appendingPathComponent("apps/host/scripts/install.sh"),
            to: scripts.appendingPathComponent("install.sh")
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scripts.appendingPathComponent("install.sh").path
        )
        try writeChecksumManifest(root: bundle)

        let artifactURL = source.appendingPathComponent(placeholder.artifactName)
        try runTool(
            "/usr/bin/tar",
            arguments: [
                "-czf", artifactURL.path,
                "-C", source.path,
                placeholder.bundleDirectoryName,
            ]
        )
        let digest = sha256(try Data(contentsOf: artifactURL))
        let release = try XCTUnwrap(
            PiHostRelease(
                version: "2.0.1",
                target: .linuxArm64,
                baseURL: "https://example.test/pi-adaptor-v2.0.1",
                pinnedChecksum: digest
            )
        )
        let checksum = validChecksum
            ? "\(digest)  \(release.artifactName)\n"
            : "\(String(repeating: "0", count: 64))  \(release.artifactName)\n"
        let checksumURL = source.appendingPathComponent(release.artifactName + ".sha256")
        try Data(checksum.utf8).write(to: checksumURL)

        let requestedToken = tokenPrefix == "ppt1"
            ? "ppt1." + "legacy-token"
            : pairingToken
        let realNode = try XCTUnwrap(findExecutable("node"))
        try writeExecutable(
            #"""
            #!/bin/sh
            set -eu
            case "${1:-}" in
              -e|-p) exec "$REAL_NODE" "$@" ;;
            esac
            case "$*" in
              *dist/main.js*)
                printf '%s\n' 'PI_HOST_READY {"hostId":"host_fake","host":"127.0.0.1","port":43871,"version":"2.0.1"}'
                printf '%s\n' 'PI_HOST_PAIRING_TOKEN {"token":"\#(requestedToken)","expiresAt":1893456000000}'
                trap 'exit 0' HUP INT TERM
                while :; do sleep 1; done
                ;;
              *) exec "$REAL_NODE" "$@" ;;
            esac
            """#,
            to: fakeBin.appendingPathComponent("node")
        )

        try writeExecutable(
            #"""
            #!/bin/sh
            set -eu
            destination=""
            url=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -o) shift; destination=$1 ;;
                http*) url=$1 ;;
              esac
              shift
            done
            [ -n "$destination" ]
            case "$url" in
              *.sha256) cp "$FAKE_CHECKSUM" "$destination" ;;
              *)
                source_bytes=$(wc -c <"$FAKE_ARTIFACT" | tr -d ' ')
                if [ "${FAKE_DOWNLOAD_MODE:-ok}" = "fail-once" ] &&
                   [ ! -f "$HOME/.fake-download-failed" ]; then
                  : >"$HOME/.fake-download-failed"
                  head -c $((source_bytes / 2)) "$FAKE_ARTIFACT" >"$destination"
                  exit 22
                fi
                if [ -f "$destination" ]; then
                  existing=$(wc -c <"$destination" | tr -d ' ')
                  if [ "$existing" -lt "$source_bytes" ]; then
                    tail -c +$((existing + 1)) "$FAKE_ARTIFACT" >>"$destination"
                  else
                    cp "$FAKE_ARTIFACT" "$destination"
                  fi
                else
                  cp "$FAKE_ARTIFACT" "$destination"
                fi
                printf '%s\n' ok >>"$FAKE_DOWNLOAD_COUNT"
                ;;
            esac
            """#,
            to: fakeBin.appendingPathComponent("curl")
        )
        try writeExecutable(
            #"""
            #!/bin/sh
            set -eu
            active="$HOME/.fake-pi-adaptor-active"
            legacy_active="$HOME/.fake-legacy-active"
            legacy_enabled="$HOME/.fake-legacy-enabled"
            legacy_enable_state="$HOME/.fake-legacy-enable-state"
            fail_stop=\#(failPiAdaptorStop ? "1" : "0")
            fail_legacy_restore=\#(failLegacyRestore ? "1" : "0")
            case "$*" in
              "--user daemon-reload") exit 0 ;;
              "--user stop pi-adaptor.service")
                [ "$fail_stop" = 0 ] || exit 1
                rm -f "$active"
                exit 0
                ;;
              "--user is-active --quiet pi-adaptor.service") [ -f "$active" ] ;;
              "--user start pi-adaptor.service") : >"$active"; exit 0 ;;
              "--user stop pi-host.service") rm -f "$legacy_active"; exit 0 ;;
              "--user disable pi-host.service")
                rm -f "$legacy_enabled"
                printf '%s\n' disabled >"$legacy_enable_state"
                exit 0
                ;;
              "--user disable --runtime pi-host.service")
                rm -f "$legacy_enabled"
                printf '%s\n' disabled >"$legacy_enable_state"
                exit 0
                ;;
              "--user enable pi-host.service")
                [ "$fail_legacy_restore" = 0 ] || exit 1
                : >"$legacy_enabled"
                printf '%s\n' enabled >"$legacy_enable_state"
                exit 0
                ;;
              "--user enable --runtime pi-host.service")
                [ "$fail_legacy_restore" = 0 ] || exit 1
                : >"$legacy_enabled"
                printf '%s\n' enabled-runtime >"$legacy_enable_state"
                exit 0
                ;;
              "--user start pi-host.service")
                [ "$fail_legacy_restore" = 0 ] || exit 1
                : >"$legacy_active"
                exit 0
                ;;
              "--user is-enabled pi-host.service")
                state=$(cat "$legacy_enable_state" 2>/dev/null || printf 'disabled')
                printf '%s\n' "$state"
                [ "$state" != disabled ]
                ;;
              "--user is-enabled pi-host-v2.service") exit 1 ;;
              "--user show pi-host.service --property=ActiveState")
                if [ -f "$legacy_active" ]; then
                  printf '%s\n' 'ActiveState=active'
                else
                  printf '%s\n' 'ActiveState=inactive'
                fi
                exit 0
                ;;
              "--user show pi-host-v2.service --property=ActiveState")
                printf '%s\n' 'ActiveState=inactive'
                exit 0
                ;;
              "--user show pi-host.service --property=ExecStart")
                printf '%s\n' 'ExecStart={ path=/usr/bin/node ; argv[]=/usr/bin/node pi-host.js --port 43871 }'
                exit 0
                ;;
              "--user show pi-host-v2.service --property=ExecStart")
                printf '%s\n' 'ExecStart='
                exit 0
                ;;
              *) exit 0 ;;
            esac
            """#,
            to: fakeBin.appendingPathComponent("systemctl")
        )
        if legacyConflict {
            try Data().write(to: home.appendingPathComponent(".fake-legacy-active"))
            if legacyEnableState == "enabled" {
                try Data().write(to: home.appendingPathComponent(".fake-legacy-enabled"))
            }
            try Data("\(legacyEnableState)\n".utf8).write(
                to: home.appendingPathComponent(".fake-legacy-enable-state")
            )
        }
        if piAdaptorInitiallyActive {
            try Data().write(to: home.appendingPathComponent(".fake-pi-adaptor-active"))
        }
        try writeExecutable(
            "#!/bin/sh\nexit 0\n",
            to: fakeBin.appendingPathComponent("loginctl")
        )

        let downloadCount = root.appendingPathComponent("download-count")
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["HOME"] = home.path
        processEnvironment["PATH"] = "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin"
        processEnvironment["FAKE_ARTIFACT"] = artifactURL.path
        processEnvironment["FAKE_CHECKSUM"] = checksumURL.path
        processEnvironment["FAKE_DOWNLOAD_MODE"] = downloadMode
        processEnvironment["FAKE_DOWNLOAD_COUNT"] = downloadCount.path
        processEnvironment["REAL_NODE"] = realNode.path

        let installRoot = home.appendingPathComponent(".pi-adaptor", isDirectory: true)
        let workDirectory = installRoot.appendingPathComponent(".bootstrap", isDirectory: true)
        return Environment(
            root: root,
            home: home,
            installRoot: installRoot,
            workDirectory: workDirectory,
            stateURL: workDirectory.appendingPathComponent("state.json"),
            stdoutURL: root.appendingPathComponent("script.stdout"),
            stderrURL: root.appendingPathComponent("script.stderr"),
            release: release,
            assetSha256: digest,
            artifactName: release.artifactName,
            processEnvironment: processEnvironment
        )
    }

    private func generatedScript(
        _ environment: Environment,
        force: Bool = false,
        allowLegacyPPT1: Bool = false
    ) throws -> URL {
        let configuration = try BootstrapScriptConfiguration(
            release: environment.release,
            attemptId: "boot_integration_\(UUID().uuidString)",
            hostArchitecture: "arm64",
            port: 43_871,
            readyTimeoutSeconds: 15,
            pairTimeoutSeconds: 15,
            stopTimeoutSeconds: 5,
            verifyTimeoutSeconds: 15,
            force: force,
            allowLegacyPPT1: allowLegacyPPT1
        )
        let url = environment.root.appendingPathComponent("bootstrap-\(UUID().uuidString).sh")
        try Data(BootstrapScriptBuilder.build(configuration).utf8).write(to: url)
        return url
    }

    private func launch(script: URL, environment: Environment) throws -> Process {
        let stdout = try FileHandle(forWritingTo: createEmptyFile(environment.stdoutURL))
        let stderr = try FileHandle(forWritingTo: createEmptyFile(environment.stderrURL))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = environment.processEnvironment
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        return process
    }

    private func createEmptyFile(_ url: URL) throws -> URL {
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    private func completePairingHandshake(
        environment: Environment,
        process: Process
    ) throws {
        let pairURL = environment.workDirectory.appendingPathComponent("pair.json")
        let pairData = try waitForFile(pairURL, timeout: 10)
        let material = try JSONDecoder().decode(BootstrapPairingMaterial.self, from: pairData)
        XCTAssertEqual(material.token, pairingToken)
        XCTAssertEqual(material.expiresAt, 1_893_456_000_000)
        XCTAssertEqual(material.host, "127.0.0.1")
        XCTAssertEqual(material.port, 43_871)
        XCTAssertEqual(try permissions(pairURL), 0o600)
        try writeMarker("ok", to: environment.workDirectory.appendingPathComponent("pair.result"))

        try waitForState(
            environment.stateURL,
            timeout: 10,
            matching: { $0.step == .verifyDevice }
        )
        try writeMarker("ok", to: environment.workDirectory.appendingPathComponent("verify.result"))
        try waitForExit(process, timeout: 10)
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return data
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw IntegrationError.timeout(url.lastPathComponent)
    }

    private func waitForState(
        _ url: URL,
        timeout: TimeInterval,
        matching predicate: (BootstrapStateFile) -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let state = try? decodeState(url), predicate(state) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw IntegrationError.timeout("state")
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            throw IntegrationError.timeout("script exit")
        }
    }

    private func decodeState(_ url: URL) throws -> BootstrapStateFile {
        try JSONDecoder().decode(BootstrapStateFile.self, from: Data(contentsOf: url))
    }

    private func writeMarker(_ value: String, to url: URL) throws {
        try Data("\(value)\n".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func downloadCount(_ environment: Environment) throws -> Int {
        let url = environment.root.appendingPathComponent("download-count")
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .count
    }

    private func persistedOutputs(_ environment: Environment) throws -> [String] {
        let stdout = (try? String(contentsOf: environment.stdoutURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: environment.stderrURL, encoding: .utf8)) ?? ""
        let pairErrorURL = environment.workDirectory.appendingPathComponent("pair.err")
        let pairError = (try? String(contentsOf: pairErrorURL, encoding: .utf8)) ?? ""
        return [stdout, stderr, pairError]
    }

    private func capturedFailure(_ environment: Environment) throws -> String {
        try persistedOutputs(environment).joined(separator: "\n")
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func writeChecksumManifest(root: URL) throws {
        var entries: [(String, String)] = []
        func visit(_ directory: URL, prefix: String) throws {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for url in children {
                let values = try url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                if values.isSymbolicLink == true {
                    throw IntegrationError.symlink(url.path)
                }
                let relative = prefix.isEmpty
                    ? url.lastPathComponent
                    : "\(prefix)/\(url.lastPathComponent)"
                if values.isDirectory == true {
                    try visit(url, prefix: relative)
                } else if relative != "SHA256SUMS" {
                    entries.append((relative, sha256(try Data(contentsOf: url))))
                }
            }
        }
        try visit(root, prefix: "")
        entries.sort { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
        let text = entries.map { "\($0.1)  \($0.0)\n" }.joined()
        try Data(text.utf8).write(to: root.appendingPathComponent("SHA256SUMS"))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }

    private func findExecutable(_ name: String) -> URL? {
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func runTool(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IntegrationError.toolFailed(executable, process.terminationStatus)
        }
    }

    private func runProcess(
        _ executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: errorData, encoding: .utf8) ?? ""
        )
    }

    private func terminateIfNeeded(_ process: Process) {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private enum IntegrationError: Error {
        case timeout(String)
        case toolFailed(String, Int32)
        case symlink(String)
    }
}
