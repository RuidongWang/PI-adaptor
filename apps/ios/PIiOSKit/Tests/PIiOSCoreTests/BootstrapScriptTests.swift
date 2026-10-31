import Foundation
import XCTest

@testable import PIiOSCore

final class BootstrapScriptTests: XCTestCase {
    private let digest = String(repeating: "0123456789abcdef", count: 4)

    private func configuration(
        target: BootstrapArtifactTarget = .linuxArm64,
        port: Int = 43_871
    ) throws -> BootstrapScriptConfiguration {
        let release = try XCTUnwrap(
            PiHostRelease(version: "0.21.0+remove.1", target: target)
        )
        return try BootstrapScriptConfiguration(
            release: release,
            attemptId: "boot_20261029T120000Z_a1b2",
            hostArchitecture: target == .linuxArm64 ? "arm64" : "x86_64",
            port: port,
            readyTimeoutSeconds: 90,
            pairTimeoutSeconds: 600,
            stopTimeoutSeconds: 20,
            verifyTimeoutSeconds: 90
        )
    }

    func testGeneratedScriptIsPOSIXSyntaxAndEncodesFullWorkflow() throws {
        let script = BootstrapScriptBuilder.build(try configuration())
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("set -eu"))
        XCTAssertTrue(script.contains("umask 077"))
        XCTAssertTrue(script.contains(#"ARTIFACT_URL='https://github.com/vastsa/PI-Desktop/releases/download/v0.21.0+remove.1/pi-host-0.21.0+remove.1-linux-arm64.tar.gz'"#))
        XCTAssertTrue(script.contains(#"CHECKSUM_URL='https://github.com/vastsa/PI-Desktop/releases/download/v0.21.0+remove.1/pi-host-0.21.0+remove.1-linux-arm64.tar.gz.sha256'"#))
        XCTAssertTrue(script.contains(#"PART="$WORK/$ARTIFACT_NAME.part""#))
        XCTAssertTrue(script.contains("curl -fL -C -"))
        XCTAssertTrue(script.contains("wget -c"))
        XCTAssertTrue(script.contains(#"chmod 600 "$tmp""#))
        XCTAssertTrue(script.contains(#"chmod 700 "$BASE" "$WORK""#))
        XCTAssertTrue(script.contains(#"pair_tmp="$PAIR_JSON.tmp.$$""#))
        XCTAssertTrue(script.contains(#"chmod 600 "$pair_tmp""#))
        XCTAssertTrue(script.contains(#">"$WORK/pair.fifo""#))
        XCTAssertFalse(script.contains(#">"$log" 2>"$err""#), "令牌 stdout 不得写入持久日志")
        XCTAssertTrue(script.contains(#"setsid"#) == false, "后台脱离由 runner 的 launch 命令负责")

        let expectedOrder = [
            #"step "probe""#,
            #"progress "resolve""#,
            #"progress "download""#,
            #"progress "verify""#,
            #"progress "extract""#,
            #"progress "activate""#,
            #"progress "write-unit""#,
            #"progress "start-pair""#,
            #"step "pair""#,
            #"progress "stop-manual""#,
            #"progress "start-unit""#,
            #"progress "verify-device""#,
            #"step "done""#,
        ]
        let positions = expectedOrder.map { script.range(of: $0)?.lowerBound }
        for position in positions {
            XCTAssertNotNil(position)
        }
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())

        let verifyHash = try XCTUnwrap(script.range(of: #"actual_sha256=$(sha256_of "$PART")"#)?.lowerBound)
        let install = try XCTUnwrap(script.range(of: #"sh "$unpack/$BUNDLE_DIR/install.sh""#)?.lowerBound)
        XCTAssertLessThan(verifyHash, install, "sha256 验证必须先于 current 切换")

        let execStartLine = script.components(separatedBy: .newlines)
            .first(where: { $0.contains("ExecStart=") })
        XCTAssertNotNil(execStartLine)
        XCTAssertFalse(execStartLine?.contains("--pair") ?? true)
        XCTAssertTrue(script.contains("--pair \\\n"))

        try assertShellParses(script)
    }

    func testStateFilePathPermissionsAndUnitContractAreExplicit() throws {
        let script = BootstrapScriptBuilder.build(try configuration(target: .linuxX64))
        XCTAssertTrue(script.contains(#"STATE="$WORK/state.json""#))
        XCTAssertTrue(script.contains(#"printf '{"version":1,"attemptId":"%s","step":"%s","status":"%s",' "$ATTEMPT_ID" "$next_step" "$status""#))
        XCTAssertTrue(script.contains(#"chmod 600 "$tmp""#))
        XCTAssertTrue(script.contains(#"unit_path="$unit_dir/pi-host.service""#))
        XCTAssertTrue(script.contains(#"systemctl --user daemon-reload"#))
        XCTAssertTrue(script.contains(#"loginctl enable-linger"#))
        XCTAssertTrue(script.contains(#"ExecStart="%s" "%s/current/pi-host.js" --port %s"#))
        XCTAssertTrue(script.contains(#"systemctl --user start pi-host.service"#))
        XCTAssertTrue(script.contains(#"systemctl --user is-active --quiet pi-host.service"#))
    }

    func testArtifactResumeAndFailurePrecisionArePresent() throws {
        let script = BootstrapScriptBuilder.build(try configuration())
        let download = try XCTUnwrap(script.range(of: #"resume_download "$ARTIFACT_URL" "$PART" &"#)?.lowerBound)
        let checksum = try XCTUnwrap(script.range(of: #"actual_sha256=$(sha256_of "$PART")"#)?.lowerBound)
        let currentSwitch = try XCTUnwrap(script.range(of: #"sh "$unpack/$BUNDLE_DIR/install.sh""#)?.lowerBound)
        XCTAssertLessThan(download, checksum)
        XCTAssertLessThan(checksum, currentSwitch)
        for code in [
            "missing-tar", "missing-sha256-tool", "bootstrap-permissions",
            "stage-failed", "download-failed", "checksum-mismatch", "extract-failed",
            "unexpected-archive-layout", "install-failed", "installed-verification-failed",
            "missing-node", "node-too-old", "host-stop-timeout", "host-start-failed",
            "host-exited", "ready-timeout", "receipt-failed", "artifact-permissions",
            "pair-failed", "unit-failed", "verify-device-failed",
        ] {
            XCTAssertTrue(script.contains(#"die "\#(code)""#), code)
        }
        XCTAssertTrue(script.contains(#"PI_HOST_BOOTSTRAP_FAILED no-home"#))
    }

    func testAttemptIdPortAndTimeoutsRejectUnsafeValues() throws {
        let release = try XCTUnwrap(
            PiHostRelease(version: "0.21.0", target: .linuxX64)
        )
        for attempt in ["", "has space", "quote'bad", "../escape", String(repeating: "a", count: 97)] {
            XCTAssertThrowsError(
                try BootstrapScriptConfiguration(
                    release: release,
                    attemptId: attempt,
                    hostArchitecture: "x86_64",
                    port: 43_871
                )
            ) {
                XCTAssertEqual($0 as? BootstrapScriptError, .invalidAttemptId)
            }
        }
        for port in [0, -1, 65_536] {
            XCTAssertThrowsError(
                try BootstrapScriptConfiguration(
                    release: release,
                    attemptId: "attempt",
                    hostArchitecture: "x86_64",
                    port: port
                )
            ) {
                XCTAssertEqual($0 as? BootstrapScriptError, .invalidPort)
            }
        }
        XCTAssertThrowsError(
            try BootstrapScriptConfiguration(
                release: release,
                attemptId: "attempt",
                hostArchitecture: "x86_64",
                port: 43_871,
                pairingLifetimeMilliseconds: 10_000
            )
        ) {
            XCTAssertEqual($0 as? BootstrapScriptError, .invalidPairingLifetime)
        }
        XCTAssertThrowsError(
            try BootstrapScriptConfiguration(
                release: release,
                attemptId: "attempt",
                hostArchitecture: "x86_64",
                port: 43_871,
                readyTimeoutSeconds: 0
            )
        ) {
            XCTAssertEqual($0 as? BootstrapScriptError, .invalidTimeout)
        }
    }

    func testRemoteCommandsUseSingleProbeBackgroundLaunchAndOwnerOnlyFiles() {
        XCTAssertTrue(BootstrapRemoteCommand.probe.contains("uname -s"))
        XCTAssertTrue(BootstrapRemoteCommand.probe.contains("uname -m"))
        XCTAssertEqual(BootstrapRemoteCommand.probe.components(separatedBy: "uname").count - 1, 2)
        XCTAssertTrue(BootstrapRemoteCommand.launch.contains("setsid nohup"))
        XCTAssertTrue(BootstrapRemoteCommand.launch.contains("command -v setsid"))
        XCTAssertTrue(BootstrapRemoteCommand.launch.contains("cd \"$work\" || exit 1"))
        XCTAssertTrue(BootstrapRemoteCommand.installScript.contains("umask 077"))
        XCTAssertTrue(BootstrapRemoteCommand.writePairingOK.contains("chmod 600"))
        XCTAssertTrue(BootstrapRemoteCommand.writeVerificationOK.contains("chmod 600"))
    }

    func testPairingMaterialValidationAndRedaction() throws {
        let material = try BootstrapPairingMaterial(
            token: "ppt1.valid_token",
            expiresAt: 1_234,
            host: "127.0.0.1",
            port: 43_871
        )
        XCTAssertFalse(material.redactedDescription.contains(material.token))

        for token in ["", "ppt1.", "pdt1.bad", "ppt1.has space", "ppt1.quote\""] {
            XCTAssertThrowsError(
                try BootstrapPairingMaterial(
                    token: token,
                    expiresAt: 0,
                    host: "127.0.0.1",
                    port: 43_871
                )
            )
        }
        XCTAssertThrowsError(
            try BootstrapPairingMaterial(
                token: "ppt1.valid",
                expiresAt: 0,
                host: "0.0.0.0",
                port: 43_871
            )
        )
    }

    private func assertShellParses(_ script: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-ios-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("bootstrap.sh")
        try Data(script.utf8).write(to: file)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", file.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "POSIX 语法检查失败：\(message)")
    }
}
