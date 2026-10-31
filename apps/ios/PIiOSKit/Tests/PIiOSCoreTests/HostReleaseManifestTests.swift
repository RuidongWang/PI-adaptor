import XCTest

@testable import PIiOSCore

/// 发布坐标漂移守卫：仓库根的 `host-release.json` 是唯一权威源，
/// 这里的常量必须与它逐项一致——不一致就让测试失败，而不是静默装回旧包。
///
/// 典型事故：只改了 `patchedReleaseVersion` 没重发资产，或重发了同版本号的资产却没改
/// `patchedChecksums`，结果「重新安装」永远装回旧字节。
final class HostReleaseManifestTests: XCTestCase {
    private static func manifest() throws -> [String: Any] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        url.appendPathComponent("host-release.json")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "host-release.json 顶层必须是对象")
    }

    func testManifestVersionAndTagMatchAppConstants() throws {
        let manifest = try Self.manifest()
        let version = try XCTUnwrap(manifest["version"] as? String)
        let tag = try XCTUnwrap(manifest["releaseTag"] as? String)
        let repository = try XCTUnwrap(manifest["repository"] as? String)

        XCTAssertEqual(version, PiHostRelease.patchedReleaseVersion, "版本号必须在 host-release.json 与 PiHostRelease 之间一致")
        XCTAssertEqual(tag, PiHostRelease.patchedReleaseTag, "发布标签必须由版本派生，且与 manifest 一致")
        XCTAssertEqual(repository, PiHostRelease.patchedRepository, "发布仓库必须一致")
        XCTAssertEqual(
            PiHostRelease.defaultPatchedBaseURL,
            "https://github.com/\(repository)/releases/download/\(tag)",
            "下载地址必须由仓库 + 标签派生"
        )
    }

    func testManifestArtifactsMatchPinnedChecksumsAndNames() throws {
        let manifest = try Self.manifest()
        let artifacts = try XCTUnwrap(manifest["artifacts"] as? [String: [String: Any]])
        let expectedKeys = ["linux-x64", "linux-arm64"]
        XCTAssertEqual(Set(artifacts.keys), Set(expectedKeys), "只允许两个已发布的 Linux 目标")

        let mapping: [String: BootstrapArtifactTarget] = ["linux-x64": .linuxX64, "linux-arm64": .linuxArm64]
        for (key, target) in mapping {
            let entry = try XCTUnwrap(artifacts[key])
            let sha = try XCTUnwrap(entry["sha256"] as? String)
            let file = try XCTUnwrap(entry["file"] as? String)
            let bundle = try XCTUnwrap(entry["bundleDirectory"] as? String)
            XCTAssertEqual(sha, PiHostRelease.patchedChecksums[target], "\(key) 的 pinned sha256 必须与 manifest 一致")
            XCTAssertEqual(file, "\(bundle).tar.gz", "\(key) 的资产名必须是 <bundleDirectory>.tar.gz")

            let release = try XCTUnwrap(PiHostRelease.patched(target: target))
            XCTAssertEqual(release.artifactName, file)
            XCTAssertEqual(release.bundleDirectoryName, bundle)
            XCTAssertEqual(release.pinnedChecksum, sha)
            XCTAssertEqual(release.artifactURL, "\(PiHostRelease.defaultPatchedBaseURL)/\(file)")
        }
    }

    func testManifestVersionHasNoStrayWhitespaceAndCarriesUpstreamBase() throws {
        let manifest = try Self.manifest()
        let version = try XCTUnwrap(manifest["version"] as? String)
        XCTAssertEqual(version, version.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertNotNil(PiHostRelease.canonicalVersion(version), "版本必须能安全出现在资产名与 URL 里")
        let upstream = try XCTUnwrap(manifest["upstreamVersion"] as? String)
        let minHost = try XCTUnwrap(manifest["minHostVersion"] as? String)
        XCTAssertTrue(version.hasPrefix(upstream), "增量包版本必须以官版为前缀（\(upstream)）")
        XCTAssertEqual(minHost, upstream, "bootstrap 的 MIN_HOST_VERSION 必须与 upstreamVersion 一致")
    }
}
