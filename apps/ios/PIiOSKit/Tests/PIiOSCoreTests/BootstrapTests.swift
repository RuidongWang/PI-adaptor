import XCTest

@testable import PIiOSCore

/// 契约 §5.1 / §5.2 / §5.3；spec AC-01.1 / AC-01.2 / AC-01.3 / AC-01.5 / AC-01.6 / AC-01.9。
final class BootstrapTests: XCTestCase {
    // MARK: - 步骤严格顺序（AC-01.1）

    func testAC01_1_stepOrderMatchesContract() {
        XCTAssertEqual(
            BootstrapStep.ordered.map(\.rawValue),
            [
                "probe", "resolve", "download", "verify", "extract", "activate", "write-unit",
                "start-pair", "pair", "stop-manual", "start-unit", "verify-device", "done",
            ]
        )
        for (index, step) in BootstrapStep.ordered.enumerated() {
            XCTAssertEqual(step.order, index)
            XCTAssertTrue(step.isKnown)
        }
    }

    func testAC01_1_detectsStepRegressionWithUnchangedAttemptId() {
        let previous = state(step: .activate, attemptId: "boot_1")
        let regressed = state(step: .download, attemptId: "boot_1")
        let issues = BootstrapStateValidator.issues(previous: previous, current: regressed)
        XCTAssertTrue(issues.contains(.stepRegression(from: .activate, to: .download)))
        XCTAssertTrue(issues.contains(.attemptIdUnchanged("boot_1")), "重新安装必须换 attemptId（§5.2）")

        let newAttempt = state(step: .download, attemptId: "boot_2")
        let forwardOnly = BootstrapStateValidator.issues(previous: previous, current: newAttempt)
        XCTAssertTrue(
            forwardOnly.contains(.stepRegression(from: .activate, to: .download)),
            "步骤倒退本身仍要报告"
        )
        XCTAssertFalse(forwardOnly.contains(.attemptIdUnchanged("boot_2")))
    }

    func testAC01_2_shortCircuitForInstalledVersionIsNotARegression() {
        let issues = BootstrapStateValidator.issues(
            previous: state(step: .resolve, attemptId: "boot_1"),
            current: state(step: .activate, attemptId: "boot_1")
        )
        XCTAssertTrue(issues.isEmpty, "已安装同版本可 probe → resolve → activate，跳过 download/verify/extract：\(issues)")
        XCTAssertEqual(BootstrapStep.shortCircuitableSteps, [.download, .verify, .extract])
    }

    func testAC01_1_unknownStepIsPreserved() {
        let issues = BootstrapStateValidator.issues(previous: nil, current: state(step: .unknown("frobnicate"), attemptId: "boot_1"))
        XCTAssertTrue(issues.contains(.unknownStep("frobnicate")))
        XCTAssertEqual(BootstrapStep(raw: "frobnicate"), .unknown("frobnicate"))
        XCTAssertNil(BootstrapStep(raw: "frobnicate").order)
    }

    // MARK: - 状态文件（AC-01.1）

    func testAC01_1_decodesStateFileShape() throws {
        let json = """
        {
          "version": 1,
          "attemptId": "boot_20260101T101500Z_a1b2",
          "step": "probe",
          "status": "running",
          "host": { "platform": "linux", "arch": "arm64" },
          "artifact": {
            "name": "pi-host-0.21.0-linux-arm64.tar.gz",
            "sha256": "abc",
            "bytes": 72584207,
            "downloadedBytes": 0
          },
          "service": { "unitPath": "/etc/systemd/system/pi-host.service", "state": "absent" },
          "error": null,
          "updatedAt": "2026-01-01T10:15:00Z"
        }
        """
        let file = try JSONDecoder().decode(BootstrapStateFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.version, 1)
        XCTAssertEqual(file.attemptId, "boot_20260101T101500Z_a1b2")
        XCTAssertEqual(file.step, .probe)
        XCTAssertEqual(file.status, .running)
        XCTAssertEqual(file.host, BootstrapHostInfo(platform: "linux", arch: "arm64"))
        XCTAssertEqual(file.artifact?.name, "pi-host-0.21.0-linux-arm64.tar.gz")
        XCTAssertEqual(file.artifact?.bytes, 72_584_207)
        XCTAssertEqual(file.artifact?.downloadedBytes, 0)
        XCTAssertEqual(file.service?.unitPath, "/etc/systemd/system/pi-host.service")
        XCTAssertEqual(file.service?.state, "absent")
        XCTAssertEqual(file.updatedAt, "2026-01-01T10:15:00Z")
        XCTAssertEqual(file.outcome, .running)
        XCTAssertNil(file.failureCode)
    }

    func testAC01_2_failedStateCarriesClientSideCode() throws {
        let file = try decode(step: "verify", status: "failed", error: #"{"code":"checksum-mismatch"}"#)
        XCTAssertEqual(file.outcome, .failed(.checksumMismatch))
        XCTAssertTrue(file.outcome.isFailed)
        XCTAssertEqual(file.failureCode, .checksumMismatch)
        XCTAssertFalse(file.failureCode?.displayMessage.isEmpty ?? true)
    }

    func testAC01_3_unknownFailureCodeIsPreservedAndClassifiedAsFailed() throws {
        let file = try decode(step: "extract", status: "failed", error: #"{"code":"brand-new-die"}"#)
        XCTAssertEqual(file.outcome, .failed(.unknown("brand-new-die")))
        XCTAssertTrue(file.outcome.isFailed, "未知码一律归类为 failed，不得吞掉")
        XCTAssertEqual(file.failureCode?.rawValue, "brand-new-die")
        XCTAssertTrue(file.failureCode?.isUnknown ?? false)
        XCTAssertTrue(file.failureCode?.displayMessage.contains("brand-new-die") ?? false)
    }

    func testAC01_9_clientSideFailureCodesAreDistinctFromUpstream() {
        XCTAssertEqual(BootstrapFailureCode.upstreamCodes.count, 19, "上游 19 个真实 die 码")
        XCTAssertEqual(BootstrapFailureCode.clientSideCodes.count, 4)
        XCTAssertEqual(
            BootstrapFailureCode.clientSideCodes.map(\.rawValue),
            ["platform-unsupported", "pair-failed", "unit-failed", "verify-device-failed"]
        )
        for code in BootstrapFailureCode.upstreamCodes {
            XCTAssertFalse(code.isClientSide, "\(code.rawValue) 不应被标成客户端侧码")
            XCTAssertEqual(BootstrapFailureCode(raw: code.rawValue), code)
        }
        for code in BootstrapFailureCode.clientSideCodes {
            XCTAssertTrue(code.isClientSide)
            XCTAssertEqual(BootstrapFailureCode(raw: code.rawValue), code)
        }
        // 每个已知码都有中文说明
        for code in BootstrapFailureCode.upstreamCodes + BootstrapFailureCode.clientSideCodes {
            XCTAssertTrue(
                code.displayMessage.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
                "失败码需要中文说明：\(code.rawValue)"
            )
        }
    }

    // MARK: - 架构映射与产物名（AC-01.5 / AC-01.6）

    func testAC01_5_mapsX86_64AndAmd64ToLinuxX64() {
        for machine in ["x86_64", "amd64", "X86_64"] {
            XCTAssertEqual(
                BootstrapPlatformProbe.decide(unameSystem: "Linux", unameMachine: machine),
                .supported(.linuxX64),
                "uname -m=\(machine)"
            )
        }
        XCTAssertEqual(
            BootstrapPlatformProbe.artifactName(version: "0.21.0", target: .linuxX64),
            "pi-host-0.21.0-linux-x64.tar.gz"
        )
    }

    func testAC01_5_mapsAarch64AndArm64ToLinuxArm64() {
        for machine in ["aarch64", "arm64", "AARCH64"] {
            XCTAssertEqual(
                BootstrapPlatformProbe.decide(unameSystem: "Linux", unameMachine: machine),
                .supported(.linuxArm64),
                "uname -m=\(machine)"
            )
        }
        XCTAssertEqual(
            BootstrapPlatformProbe.artifactName(version: "0.21.0", target: .linuxArm64),
            "pi-host-0.21.0-linux-arm64.tar.gz"
        )
    }

    func testAC01_6_rejectsUnpublishedArchitectures() {
        for machine in ["armv7l", "i686", "armv6l", ""] {
            let decision = BootstrapPlatformProbe.decide(unameSystem: "Linux", unameMachine: machine)
            XCTAssertFalse(decision.shouldDownload, "未发布架构不得下载：\(machine)")
            XCTAssertEqual(decision.failureCode, .platformUnsupported)
            guard case let .unsupported(reason) = decision else {
                return XCTFail("应判定为不支持：\(machine)")
            }
            XCTAssertTrue(reason.message.contains("x86_64 / arm64"), "需说明只支持两种架构：\(reason.message)")
        }
    }

    func testAC01_3_rejectsNonLinuxPlatformWithoutDownload() {
        let decision = BootstrapPlatformProbe.decide(unameSystem: "Darwin", unameMachine: "arm64")
        XCTAssertFalse(decision.shouldDownload)
        XCTAssertEqual(decision.failureCode, .platformUnsupported)
        guard case let .unsupported(reason) = decision else {
            return XCTFail("macOS 应被判定为不支持")
        }
        XCTAssertTrue(reason.message.contains("仅支持 Linux"), "AC-01.3 要求明确提示仅支持 Linux：\(reason.message)")
    }

    // MARK: - 停滞判定（AC-01.1、契约 §5.3 第 2 条）

    func testAC01_1_stallIsDetectedAfterFiveMinutes() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var detector = BootstrapStallDetector()
        XCTAssertEqual(detector.observe(sample(step: .download, bytes: 0, at: start)), .progressing)
        XCTAssertEqual(detector.observe(sample(step: .download, bytes: 0, at: start.addingTimeInterval(299))), .progressing)

        let stalled = detector.observe(sample(step: .download, bytes: 0, at: start.addingTimeInterval(300)))
        guard case let .stalled(unchangedSince, message) = stalled else {
            return XCTFail("连续 5 分钟无变化应判定为停滞")
        }
        XCTAssertEqual(unchangedSince, start)
        XCTAssertTrue(message.contains("可恢复点"), "提示文案需给出可恢复点：\(message)")
    }

    func testAC01_1_stallResetsWhenProgressResumes() {
        let start = Date(timeIntervalSince1970: 2_000_000)
        var detector = BootstrapStallDetector()
        detector.observe(sample(step: .download, bytes: 0, at: start))
        // 4 分钟后 downloadedBytes 前进 → 基线刷新
        XCTAssertEqual(
            detector.observe(sample(step: .download, bytes: 1_024, at: start.addingTimeInterval(240))),
            .progressing
        )
        // 再过 1 分钟（总 5 分钟，但距基线仅 60 秒）不算停滞
        XCTAssertEqual(
            detector.observe(sample(step: .download, bytes: 1_024, at: start.addingTimeInterval(300))),
            .progressing
        )
        // 步骤变化同样刷新基线
        XCTAssertEqual(
            detector.observe(sample(step: .verify, bytes: 1_024, at: start.addingTimeInterval(360))),
            .progressing
        )
        guard case .stalled = detector.observe(sample(step: .verify, bytes: 1_024, at: start.addingTimeInterval(660))) else {
            return XCTFail("步骤停在 verify 且字节数未变，5 分钟后应判定停滞")
        }
    }

    func testAC01_1_stallThresholdIsFiveMinutes() {
        XCTAssertEqual(BootstrapStallDetector.defaultThreshold, 300)
        let since = Date(timeIntervalSince1970: 0)
        XCTAssertNil(BootstrapStallDetector.stallMessage(unchangedSince: since, now: since.addingTimeInterval(299)))
        XCTAssertNotNil(BootstrapStallDetector.stallMessage(unchangedSince: since, now: since.addingTimeInterval(300)))
    }

    func testAC01_1_progressSampleUsesStepAndDownloadedBytesOnly() {
        let file = BootstrapStateFile(
            attemptId: "boot_1",
            step: .download,
            status: .running,
            artifact: BootstrapArtifactInfo(downloadedBytes: 4_096)
        )
        let sample = file.progressSample(at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(sample.step, .download)
        XCTAssertEqual(sample.downloadedBytes, 4_096)
    }

    // MARK: - 工具

    private func state(step: BootstrapStep, attemptId: String, status: BootstrapStatus = .running) -> BootstrapStateFile {
        BootstrapStateFile(attemptId: attemptId, step: step, status: status)
    }

    private func sample(step: BootstrapStep, bytes: Int, at date: Date) -> BootstrapProgressSample {
        BootstrapProgressSample(step: step, downloadedBytes: bytes, observedAt: date)
    }

    private func decode(step: String, status: String, error: String) throws -> BootstrapStateFile {
        let json = """
        {"version":1,"attemptId":"boot_1","step":"\(step)","status":"\(status)","error":\(error),"updatedAt":"2026-01-01T10:15:00Z"}
        """
        return try JSONDecoder().decode(BootstrapStateFile.self, from: Data(json.utf8))
    }
}
