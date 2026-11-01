import XCTest

@testable import PIiOSCore

final class BootstrapReleaseTests: XCTestCase {
    private let digest = String(repeating: "0123456789abcdef", count: 4)
    private let artifactName = "pi-adaptor-2.0.1-linux-x64.tar.gz"

    func testReleaseCoordinatesForBothPublishedLinuxTargets() throws {
        let x64 = try XCTUnwrap(
            PiHostRelease(version: "2.0.1", target: .linuxX64)
        )
        XCTAssertEqual(x64.repository, "RuidongWang/PI-adaptor")
        XCTAssertEqual(x64.version, "2.0.1")
        XCTAssertEqual(x64.releaseTag, "pi-adaptor-v2.0.1")
        XCTAssertEqual(x64.bundleDirectoryName, "pi-adaptor-2.0.1-linux-x64")
        XCTAssertEqual(x64.artifactName, artifactName)
        XCTAssertEqual(x64.serverName, "pi-adaptor")
        XCTAssertEqual(x64.unitName, "pi-adaptor.service")
        XCTAssertEqual(x64.minimumNodeVersion, "22.19.0")
        XCTAssertEqual(
            x64.artifactURL,
            "https://github.com/RuidongWang/PI-adaptor/releases/download/pi-adaptor-v2.0.1/\(artifactName)"
        )
        XCTAssertEqual(
            x64.checksumURL,
            "https://github.com/RuidongWang/PI-adaptor/releases/download/pi-adaptor-v2.0.1/\(artifactName).sha256"
        )

        let arm64 = try XCTUnwrap(
            PiHostRelease(version: "v2.0.1", target: .linuxArm64)
        )
        XCTAssertEqual(arm64.version, "2.0.1")
        XCTAssertEqual(arm64.bundleDirectoryName, "pi-adaptor-2.0.1-linux-arm64")
        XCTAssertEqual(arm64.artifactName, "pi-adaptor-2.0.1-linux-arm64.tar.gz")
    }

    func testReleaseRejectsUnsafeVersionAndRepository() {
        XCTAssertNil(PiHostRelease(version: "", target: .linuxX64))
        XCTAssertNil(PiHostRelease(version: "v", target: .linuxX64))
        XCTAssertNil(PiHostRelease(version: "2.0.1/other", target: .linuxX64))
        XCTAssertNil(PiHostRelease(version: "2.0.1 beta", target: .linuxX64))
        XCTAssertNil(PiHostRelease(version: "2.0.1", target: .linuxX64, repository: "vastsa"))
        XCTAssertNil(PiHostRelease(version: "2.0.1", target: .linuxX64, repository: "a/b/c"))
        XCTAssertNil(PiHostRelease(version: "2.0.1", target: .linuxX64, repository: "owner/repo?x=1"))
    }

    func testSelfHostedPatchedReleasePinsBothArchitectureChecksums() throws {
        XCTAssertEqual(
            PiHostRelease.defaultPatchedBaseURL,
            "https://github.com/RuidongWang/PI-adaptor/releases/download/pi-adaptor-v2.0.1"
        )
        let arm64 = try XCTUnwrap(PiHostRelease.patched(target: .linuxArm64))
        XCTAssertEqual(arm64.version, PiHostRelease.patchedReleaseVersion)
        XCTAssertEqual(arm64.pinnedChecksum, PiHostRelease.patchedChecksums[.linuxArm64])
        XCTAssertEqual(
            arm64.artifactURL,
            "\(PiHostRelease.defaultPatchedBaseURL)/pi-adaptor-2.0.1-linux-arm64.tar.gz"
        )
        XCTAssertEqual(
            arm64.checksumURL,
            arm64.artifactURL + ".sha256"
        )

        let x64 = try XCTUnwrap(PiHostRelease.patched(target: .linuxX64))
        XCTAssertEqual(x64.pinnedChecksum, PiHostRelease.patchedChecksums[.linuxX64])
        XCTAssertEqual(x64.target, .linuxX64)
    }

    func testSelfHostedReleaseRejectsUnsafeBaseURLAndChecksum() {
        XCTAssertNil(
            PiHostRelease(
                version: PiHostRelease.patchedReleaseVersion,
                target: .linuxArm64,
                baseURL: "http://user@example.test/releases",
                pinnedChecksum: digest
            )
        )
        XCTAssertNil(
            PiHostRelease(
                version: PiHostRelease.patchedReleaseVersion,
                target: .linuxArm64,
                baseURL: "file:///tmp/releases",
                pinnedChecksum: digest
            )
        )
        XCTAssertNil(
            PiHostRelease(
                version: PiHostRelease.patchedReleaseVersion,
                target: .linuxArm64,
                baseURL: "http://example.test/releases",
                pinnedChecksum: "not-a-digest"
            )
        )
    }

    func testChecksumNormalizationAcceptsOnlyFullSha256() {
        XCTAssertEqual(PiHostRelease.normalizeChecksum(" \(digest.uppercased())\n"), digest)
        XCTAssertNil(PiHostRelease.normalizeChecksum(String(digest.dropLast())))
        XCTAssertNil(PiHostRelease.normalizeChecksum(digest + "0"))
        XCTAssertNil(PiHostRelease.normalizeChecksum(String(digest.dropLast()) + "g"))
        XCTAssertNil(PiHostRelease.normalizeChecksum(""))
    }

    func testChecksumFileReadsOnlyTheMatchingArtifact() {
        XCTAssertEqual(
            PiHostRelease.parseChecksumFile("\(digest.uppercased())  \(artifactName)\n", artifactName: artifactName),
            digest
        )
        XCTAssertEqual(
            PiHostRelease.parseChecksumFile("\(digest) *\(artifactName)\n", artifactName: artifactName),
            digest
        )
        XCTAssertEqual(
            PiHostRelease.parseChecksumFile("\(digest)  /tmp/build/\(artifactName)\n", artifactName: artifactName),
            digest
        )
        XCTAssertEqual(
            PiHostRelease.parseChecksumFile("# generated by release.sh\n\n\(digest)  \(artifactName)\n", artifactName: artifactName),
            digest
        )
        XCTAssertNil(
            PiHostRelease.parseChecksumFile(
                "\(digest)  pi-host-0.21.0-linux-x64.tar.gz\n",
                artifactName: artifactName
            )
        )
    }

    func testChecksumComparisonAndVersionMatchingFailClosed() {
        let tampered = String(digest.dropLast()) + "e"
        XCTAssertTrue(PiHostRelease.checksumMatches(digest.uppercased(), digest))
        XCTAssertFalse(PiHostRelease.checksumMatches(tampered, digest))
        XCTAssertFalse(PiHostRelease.checksumMatches("", ""))

        XCTAssertTrue(PiHostRelease.versionsMatch("v2.0.1", "2.0.1"))
        XCTAssertTrue(PiHostRelease.versionsMatch(" 2.0.1 ", "v2.0.1"))
        XCTAssertFalse(PiHostRelease.versionsMatch("2.0.0", "2.0.1"))
        XCTAssertFalse(PiHostRelease.versionsMatch("", ""))
        XCTAssertFalse(PiHostRelease.versionsMatch("v", ""))
    }

    func testBootstrapOutputReadsStagesReadyPairingAndFailureCode() throws {
        let stdout = [
            "Warning: Permanently added host to known hosts.",
            "PI_HOST_BOOTSTRAP download",
            "PI_HOST_BOOTSTRAP   verify  ",
            #"PI_HOST_READY {"hostId":"host_x","host":"127.0.0.1","port":41234,"version":"0.21.0"}"#,
            #"PI_HOST_PAIRING_TOKEN {"token":"ppt1.test-only","expiresAt":123,"host":"127.0.0.1","port":41234}"#,
            "PI_HOST_BOOTSTRAP ok",
        ].joined(separator: "\n")

        let output = PiHostBootstrapOutputParser.parse(stdout)
        XCTAssertEqual(
            output.ready,
            PiHostReadyLine(hostId: "host_x", host: "127.0.0.1", port: 41_234, version: "0.21.0")
        )
        XCTAssertEqual(output.pairing, PiHostPairingLine(token: "ppt1.test-only", expiresAt: 123))
        XCTAssertEqual(output.stages, [.download, .verify, .ok])
        XCTAssertNil(output.failure)
    }

    func testBootstrapOutputPreservesFirstFailureAndUnknownCodes() {
        let first = PiHostBootstrapOutputParser.parse(
            [
                "PI_HOST_BOOTSTRAP_FAILED checksum-mismatch",
                "PI_HOST_BOOTSTRAP_FAILED download-failed",
            ].joined(separator: "\n")
        )
        XCTAssertEqual(first.failure, .checksumMismatch)

        let structured = PiHostBootstrapOutputParser.parse(
            #"PI_HOST_FAILED {"code":"HOST_BOOTSTRAP_FAILED","step":"future-code"}"#
        )
        XCTAssertEqual(structured.failure, .unknown("future-code"))
        XCTAssertEqual(structured.failure?.rawValue, "future-code")
    }

    func testBootstrapOutputRejectsMalformedOrNonLoopbackReadyLines() {
        let invalidPayloads = [
            #"{"hostId":"host_x","host":"127.0.0.1","port":0,"version":"0.21.0"}"#,
            #"{"hostId":"host_x","host":"127.0.0.1","port":65536,"version":"0.21.0"}"#,
            #"{"hostId":"host_x","host":"127.0.0.1","port":41234.5,"version":"0.21.0"}"#,
            #"{"hostId":"","host":"127.0.0.1","port":41234,"version":"0.21.0"}"#,
            #"{"hostId":"host_x","host":"0.0.0.0","port":41234,"version":"0.21.0"}"#,
            #"{"hostId":"host_x","host":"example.com","port":41234,"version":"0.21.0"}"#,
        ]
        for payload in invalidPayloads {
            XCTAssertNil(
                PiHostBootstrapOutputParser.parse("PI_HOST_READY \(payload)").ready,
                payload
            )
        }
        XCTAssertNil(PiHostBootstrapOutputParser.parse("PI_HOST_READY {not json").ready)
        XCTAssertNil(
            PiHostBootstrapOutputParser.parse(
                #"PI_HOST_FAILED {"code":"OTHER","step":"x"}"#
            ).failure
        )
        XCTAssertNil(PiHostBootstrapOutputParser.parse("PI_HOST_FAILED {not json").failure)
    }

    func testPairingLineRequiresTokenNumericExpiryAndLoopbackEndpoint() {
        XCTAssertNil(
            PiHostBootstrapOutputParser.parse(
                #"PI_HOST_PAIRING_TOKEN {"token":"ppt1.test-only","expiresAt":123}"#
            ).pairing
        )
        XCTAssertNil(
            PiHostBootstrapOutputParser.parse(
                #"PI_HOST_PAIRING_TOKEN {"token":"ppt1.test-only","host":"127.0.0.1","port":41234}"#
            ).pairing
        )
        XCTAssertEqual(
            PiHostBootstrapOutputParser.parse(
                #"PI_HOST_PAIRING_TOKEN {"token":"ppt1.test-only","expiresAt":123,"host":"127.0.0.1","port":41234}"#
            ).pairing,
            PiHostPairingLine(token: "ppt1.test-only", expiresAt: 123)
        )
    }

    func testBootstrapOutputRedactsPairingTokenBeforeLogging() {
        let token = "ppt1.test-only"
        let stdout = [
            #"PI_HOST_PAIRING_TOKEN {"token":"\#(token)","expiresAt":123}"#,
            "PI_HOST_BOOTSTRAP ok",
        ].joined(separator: "\n")

        let redacted = PiHostBootstrapOutputParser.redact(stdout)
        XCTAssertFalse(redacted.contains(token))
        XCTAssertTrue(redacted.contains("PI_HOST_PAIRING_TOKEN <redacted>"))
        XCTAssertTrue(redacted.contains("PI_HOST_BOOTSTRAP ok"))
    }

    func testBootstrapRedactionHandlesIndentedCRLFAndSSHNoiseLines() {
        let firstToken = "ppt1.test-only"
        let secondToken = "{{SECRET_second}}"
        let stdout = [
            #"  PI_HOST_PAIRING_TOKEN {"token":"\#(firstToken)","expiresAt":123}"# + "\r",
            #"debug1: remote output PI_HOST_PAIRING_TOKEN {"token":"\#(secondToken)"}"# + "\r",
            #"PI_HOST_BOOTSTRAP ready"#,
        ].joined(separator: "\r\n")

        let redacted = PiHostBootstrapOutputParser.redact(stdout)
        XCTAssertFalse(redacted.contains(firstToken))
        XCTAssertFalse(redacted.contains(secondToken))
        XCTAssertEqual(
            redacted.components(separatedBy: "PI_HOST_PAIRING_TOKEN <redacted>").count - 1,
            2
        )
        XCTAssertTrue(redacted.contains("PI_HOST_BOOTSTRAP ready"))
    }
}
