import CryptoKit
import Foundation
import XCTest

@testable import PIiOSCore

/// Executes the generated POSIX script against isolated fake systemd, curl and
/// pi-host binaries. It never touches a real Host and never uses the network.
final class BootstrapScriptIntegrationTests: XCTestCase {
    private let pairingToken = "ppt1.integrationtoken"

    func testScriptCompletesPairingSystemdHandoffAndDeviceVerification() throws {
        let environment = try makeEnvironment(validChecksum: true)
        let script = try generatedScript(environment: environment)
        let process = try launch(script: script, environment: environment)
        defer { terminateIfNeeded(process) }
        let pairURL = environment.workDirectory.appendingPathComponent("pair.json")

        try completePairingHandshake(environment: environment, process: process)
        let failureOutput = try capturedFailure(environment)
        XCTAssertEqual(process.terminationStatus, 0, failureOutput)

        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.step, .done)
        XCTAssertEqual(state.status, .ok)
        XCTAssertNil(state.failureCode)
        XCTAssertEqual(try permissions(environment.stateURL), 0o600)
        XCTAssertEqual(try permissions(environment.workDirectory), 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pairURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.workDirectory.appendingPathComponent("active.lock").path
            )
        )

        let unit = try String(
            contentsOf: environment.home
                .appendingPathComponent(".config/systemd/user/pi-host.service"),
            encoding: .utf8
        )
        let execStart = try XCTUnwrap(
            unit.components(separatedBy: .newlines).first(where: { $0.hasPrefix("ExecStart=") })
        )
        XCTAssertFalse(execStart.contains("--pair"))
        XCTAssertTrue(unit.contains("Restart=always"))
        XCTAssertTrue(
            unit.contains("WorkingDirectory=\(environment.installRoot.path)\n"),
            "WorkingDirectory must be an unquoted absolute path accepted by systemd"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-systemd-active").path
            )
        )

        let stdout = try String(contentsOf: environment.stdoutURL, encoding: .utf8)
        let stderr = try String(contentsOf: environment.stderrURL, encoding: .utf8)
        let pairStderrURL = environment.workDirectory.appendingPathComponent("pair.err")
        let pairStderr = (try? String(contentsOf: pairStderrURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(pairStderr.contains("<redacted>"))
        for output in [stdout, stderr, pairStderr] {
            XCTAssertFalse(output.contains(pairingToken), "配对令牌不得进入持久输出")
        }
    }

    func testDownloadFailureKeepsPartAndNextAttemptResumesIt() throws {
        let environment = try makeEnvironment(
            validChecksum: true,
            downloadMode: "fail-once"
        )
        let script = try generatedScript(environment: environment)
        let firstProcess = try launch(script: script, environment: environment)
        defer { terminateIfNeeded(firstProcess) }

        try waitForExit(firstProcess, timeout: 10)
        XCTAssertNotEqual(firstProcess.terminationStatus, 0)
        let firstState = try decodeState(environment.stateURL)
        XCTAssertEqual(firstState.step, .download)
        XCTAssertEqual(firstState.failureCode, .downloadFailed)

        let partURL = environment.workDirectory
            .appendingPathComponent("\(environment.artifactName).part")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partURL.path))
        let partialBytes = try Data(contentsOf: partURL).count
        XCTAssertGreaterThan(partialBytes, 0)

        let secondProcess = try launch(script: script, environment: environment)
        defer { terminateIfNeeded(secondProcess) }
        try completePairingHandshake(environment: environment, process: secondProcess)
        let failureOutput = try capturedFailure(environment)
        XCTAssertEqual(secondProcess.terminationStatus, 0, failureOutput)
        let finalState = try decodeState(environment.stateURL)
        XCTAssertEqual(finalState.step, .done)
        XCTAssertEqual(finalState.status, .ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
    }

    func testChecksumMismatchLeavesCurrentUntouchedAndNoStageBehind() throws {
        let environment = try makeEnvironment(validChecksum: false)
        let script = try generatedScript(environment: environment)
        let process = try launch(script: script, environment: environment)
        defer { terminateIfNeeded(process) }

        try waitForExit(process, timeout: 8)
        XCTAssertNotEqual(process.terminationStatus, 0)

        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.step, .verify)
        XCTAssertEqual(state.status, .failed)
        XCTAssertEqual(state.failureCode, .checksumMismatch)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.installRoot.appendingPathComponent("current").path
            )
        )
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: environment.installRoot.path
        ).filter { $0.hasPrefix(".stage.") }
        XCTAssertTrue(leftovers.isEmpty, "失败不得留下半安装 stage：\(leftovers)")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.workDirectory
                    .appendingPathComponent("\(environment.artifactName).part")
                    .path
            ),
            "校验失败必须丢弃损坏分片"
        )
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
        let artifactName: String
        let processEnvironment: [String: String]
    }

    private func makeEnvironment(
        validChecksum: Bool,
        downloadMode: String = "ok"
    ) throws -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-ios-bootstrap-integration-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let fakeBin = root.appendingPathComponent("fake-bin", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let release = try XCTUnwrap(
            PiHostRelease(version: "0.21.0", target: .linuxArm64)
        )
        let bundle = source.appendingPathComponent(release.bundleDirectoryName, isDirectory: true)
        let bundleBin = bundle.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleBin, withIntermediateDirectories: true)

        try writeExecutable(
            """
            #!/bin/sh
            set -eu
            if [ "${1:-}" = "-p" ]; then
              printf '%s\n' 22
              exit 0
            fi
            printf '%s\n' 'PI_HOST_READY {"hostId":"host_fake","host":"127.0.0.1","port":43871,"version":"0.21.0"}'
            printf '%s\n' 'PI_HOST_PAIRING_TOKEN {"token":"\(pairingToken)","expiresAt":1893456000000}'
            printf '%s\n' 'PI_HOST_PAIRING_TOKEN {"token":"\(pairingToken)","expiresAt":1893456000000}' >&2
            trap 'exit 0' HUP INT TERM
            while :; do sleep 1; done
            """,
            to: bundleBin.appendingPathComponent("node")
        )
        try Data("// fake pi-host entry\n".utf8)
            .write(to: bundle.appendingPathComponent("pi-host.js"))
        try Data().write(to: bundle.appendingPathComponent("SHA256SUMS"))
        try writeExecutable(
            #"""
            #!/bin/sh
            set -eu
            source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
            root=${PI_HOST_INSTALL_DIR:-$HOME/.pi-desktop/pi-host}
            if [ "${1:-}" = "--verify" ]; then
              [ -x "$root/current/bin/node" ]
              [ -f "$root/current/pi-host.js" ]
              exit 0
            fi
            mkdir -p "$root"
            version="$root/fake-version"
            rm -rf "$version"
            mkdir -p "$version"
            cp -R "$source_dir"/. "$version"/
            ln -sfn "$version" "$root/current"
            """#,
            to: bundle.appendingPathComponent("install.sh")
        )

        let artifactURL = source.appendingPathComponent(release.artifactName)
        try runTool(
            "/usr/bin/tar",
            arguments: [
                "-czf", artifactURL.path,
                "-C", source.path,
                release.bundleDirectoryName,
            ]
        )
        let artifactBytes = try Data(contentsOf: artifactURL)
        let digest = SHA256.hash(data: artifactBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let checksumText: String
        if validChecksum {
            checksumText = "\(digest)  \(release.artifactName)\n"
        } else {
            checksumText = "\(String(repeating: "0", count: 64))  \(release.artifactName)\n"
        }
        let checksumURL = source.appendingPathComponent(release.artifactName + ".sha256")
        try Data(checksumText.utf8).write(to: checksumURL)

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
                if [ "${FAKE_DOWNLOAD_MODE:-ok}" = "fail-once" ] && [ ! -f "$HOME/.fake-download-failed" ]; then
                  : >"$HOME/.fake-download-failed"
                  head -c $((source_bytes / 2)) "$FAKE_ARTIFACT" >"$destination"
                  exit 22
                fi
                if [ -f "$destination" ]; then
                  existing_bytes=$(wc -c <"$destination" | tr -d ' ')
                  if [ "$existing_bytes" -lt "$source_bytes" ]; then
                    tail -c +$((existing_bytes + 1)) "$FAKE_ARTIFACT" >>"$destination"
                  else
                    cp "$FAKE_ARTIFACT" "$destination"
                  fi
                else
                  cp "$FAKE_ARTIFACT" "$destination"
                fi
                ;;
            esac
            """#,
            to: fakeBin.appendingPathComponent("curl")
        )
        try writeExecutable(
            #"""
            #!/bin/sh
            set -eu
            active="$HOME/.fake-systemd-active"
            case "$*" in
              "--user daemon-reload") exit 0 ;;
              "--user stop pi-host.service") rm -f "$active"; exit 0 ;;
              "--user is-active --quiet pi-host.service") [ -f "$active" ] ;;
              "--user start pi-host.service") : >"$active"; exit 0 ;;
              *) exit 0 ;;
            esac
            """#,
            to: fakeBin.appendingPathComponent("systemctl")
        )
        try writeExecutable(
            "#!/bin/sh\nexit 0\n",
            to: fakeBin.appendingPathComponent("loginctl")
        )

        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["HOME"] = home.path
        processEnvironment["PATH"] = "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin"
        processEnvironment["FAKE_ARTIFACT"] = artifactURL.path
        processEnvironment["FAKE_CHECKSUM"] = checksumURL.path
        processEnvironment["FAKE_DOWNLOAD_MODE"] = downloadMode

        let installRoot = home.appendingPathComponent(".pi-desktop/pi-host", isDirectory: true)
        let workDirectory = installRoot.appendingPathComponent(".bootstrap", isDirectory: true)
        return Environment(
            root: root,
            home: home,
            installRoot: installRoot,
            workDirectory: workDirectory,
            stateURL: workDirectory.appendingPathComponent("state.json"),
            stdoutURL: root.appendingPathComponent("script.stdout"),
            stderrURL: root.appendingPathComponent("script.stderr"),
            artifactName: release.artifactName,
            processEnvironment: processEnvironment
        )
    }

    private func generatedScript(environment: Environment) throws -> URL {
        let release = try XCTUnwrap(
            PiHostRelease(version: "0.21.0", target: .linuxArm64)
        )
        let configuration = try BootstrapScriptConfiguration(
            release: release,
            attemptId: "boot_integration",
            hostArchitecture: "arm64",
            port: 43_871,
            readyTimeoutSeconds: 15,
            pairTimeoutSeconds: 15,
            stopTimeoutSeconds: 5,
            verifyTimeoutSeconds: 15
        )
        let url = environment.root.appendingPathComponent("bootstrap.sh")
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
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
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

    private func completePairingHandshake(
        environment: Environment,
        process: Process
    ) throws {
        let pairURL = environment.workDirectory.appendingPathComponent("pair.json")
        let pairData = try waitForFile(pairURL, timeout: 10)
        let material = try JSONDecoder().decode(BootstrapPairingMaterial.self, from: pairData)
        XCTAssertEqual(material.token, pairingToken)
        XCTAssertEqual(material.port, 43_871)
        XCTAssertEqual(try permissions(pairURL), 0o600)

        let pairResult = environment.workDirectory.appendingPathComponent("pair.result")
        try writeMarker("ok", to: pairResult)

        try waitForState(
            environment.stateURL,
            timeout: 10,
            matching: { $0.step == .verifyDevice }
        )
        let verifyResult = environment.workDirectory.appendingPathComponent("verify.result")
        try writeMarker("ok", to: verifyResult)

        try waitForExit(process, timeout: 10)
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

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func capturedFailure(_ environment: Environment) throws -> String {
        let stdout = (try? String(contentsOf: environment.stdoutURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: environment.stderrURL, encoding: .utf8)) ?? ""
        return "stdout:\n\(stdout)\nstderr:\n\(stderr)"
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

    private func terminateIfNeeded(_ process: Process) {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private enum IntegrationError: Error {
        case timeout(String)
        case toolFailed(String, Int32)
    }
}
