import Foundation

/// Pure release coordinates for a `pi-host` artifact.
///
/// Mirrors the relevant rules in PI-Desktop's `pi-host-release.ts`: the app
/// version selects both the downloaded bundle and the checksum, and only the
/// two published Linux targets are valid.
public struct PiHostRelease: Equatable, Sendable {
    public static let defaultRepository = "vastsa/PI-Desktop"
    /// 本项目自托管发布（provider-remove 增量包）的唯一来源。
    /// 版本号、发布标签与各目标 sha256 必须与仓库根的 `host-release.json` 一致；
    /// `HostReleaseManifestTests` 会在漂移时直接失败，避免「版本号改了、包还是旧的」。
    public static let patchedRepository = "RuidongWang/PI-IOS-host"
    public static let patchedReleaseVersion = "0.21.0+remove.1"
    /// 发布标签由版本派生（`v<version>`），不再单独写死，避免标签与版本号各改一半。
    public static var patchedReleaseTag: String { "v\(patchedReleaseVersion)" }
    public static var defaultPatchedBaseURL: String {
        "https://github.com/\(patchedRepository)/releases/download/\(patchedReleaseTag)"
    }
    public static let patchedChecksums: [BootstrapArtifactTarget: String] = [
        .linuxX64: "53b25d752258fb4d02c7092c54b9daf6c649aade8c4899959a7cb00b1c44c856",
        .linuxArm64: "d4c77cadf9bcf5f9364176ed6e72bcd3d4557ad10d79bb6796cc7398b206737a",
    ]

    public let repository: String
    public let version: String
    public let target: BootstrapArtifactTarget
    public let bundleDirectoryName: String
    public let artifactName: String
    public let artifactURL: String
    public let checksumURL: String
    /// A release may pin the expected digest in the app so an HTTP mirror cannot
    /// substitute both the bundle and its adjacent checksum file.
    public let pinnedChecksum: String?

    public init?(
        version: String,
        target: BootstrapArtifactTarget,
        repository: String = PiHostRelease.defaultRepository
    ) {
        let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = Self.canonicalVersion(version),
              Self.isValidRepository(repository) else {
            return nil
        }

        let artifactName = BootstrapPlatformProbe.artifactName(version: version, target: target)
        let baseURL = "https://github.com/\(repository)/releases/download/v\(version)"

        self.repository = repository
        self.version = version
        self.target = target
        self.bundleDirectoryName = String(artifactName.dropLast(".tar.gz".count))
        self.artifactName = artifactName
        self.artifactURL = "\(baseURL)/\(artifactName)"
        self.checksumURL = "\(baseURL)/\(artifactName).sha256"
        self.pinnedChecksum = nil
    }

    public init?(
        version: String,
        target: BootstrapArtifactTarget,
        baseURL rawBaseURL: String,
        pinnedChecksum rawPinnedChecksum: String
    ) {
        guard let version = Self.canonicalVersion(version),
              let baseURL = Self.normalizedBaseURL(rawBaseURL),
              let pinnedChecksum = Self.normalizeChecksum(rawPinnedChecksum) else {
            return nil
        }
        let artifactName = BootstrapPlatformProbe.artifactName(version: version, target: target)
        self.repository = "self-hosted"
        self.version = version
        self.target = target
        self.bundleDirectoryName = String(artifactName.dropLast(".tar.gz".count))
        self.artifactName = artifactName
        self.artifactURL = "\(baseURL)/\(artifactName)"
        self.checksumURL = "\(baseURL)/\(artifactName).sha256"
        self.pinnedChecksum = pinnedChecksum
    }

    /// The project release contains the provider-remove increment. It is
    /// self-hosted with a digest pinned in the app.
    public static func patched(
        target: BootstrapArtifactTarget,
        baseURL: String = defaultPatchedBaseURL
    ) -> PiHostRelease? {
        guard let checksum = patchedChecksums[target] else { return nil }
        return PiHostRelease(
            version: patchedReleaseVersion,
            target: target,
            baseURL: baseURL,
            pinnedChecksum: checksum
        )
    }

    /// Trims surrounding whitespace, tolerates one release-tag `v`, and rejects
    /// values that cannot safely appear in an artifact name or URL path.
    public static func canonicalVersion(_ value: String) -> String? {
        var version = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("v") {
            version.removeFirst()
        }
        guard !version.isEmpty,
              version.unicodeScalars.allSatisfy(isVersionScalar) else {
            return nil
        }
        return version
    }

    /// Accepts a trimmed 64-character ASCII hexadecimal SHA-256 digest and
    /// returns it in the lower-case form used by the release script.
    public static func normalizeChecksum(_ value: String) -> String? {
        let digest = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digest.utf8.count == 64,
              digest.unicodeScalars.allSatisfy(isHexScalar) else {
            return nil
        }
        return digest.lowercased()
    }

    /// Extracts the digest belonging to `artifactName` from a `sha256sum` file.
    ///
    /// Supports the bare name, binary-mode `*name`, and an absolute path. A
    /// digest for a different artifact is never accepted.
    public static func parseChecksumFile(_ text: String, artifactName: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let rawDigest = fields.first,
                  let digest = normalizeChecksum(String(rawDigest)) else {
                continue
            }

            var named = fields.dropFirst().joined(separator: " ")
            if named.hasPrefix("*") {
                named.removeFirst()
            }
            let basename = named.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            if !basename.isEmpty && basename != artifactName {
                continue
            }
            return digest
        }
        return nil
    }

    /// Compares two checksums without treating malformed values as a match.
    public static func checksumMatches(_ actual: String, _ expected: String) -> Bool {
        guard let actual = normalizeChecksum(actual),
              let expected = normalizeChecksum(expected) else {
            return false
        }

        var difference: UInt8 = 0
        for (left, right) in zip(actual.utf8, expected.utf8) {
            difference |= left ^ right
        }
        return difference == 0
    }

    /// The release tag carries a `v` while `APP_VERSION` does not.
    public static func versionsMatch(_ remote: String, _ local: String) -> Bool {
        func canonical(_ value: String) -> String {
            var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("v") {
                value.removeFirst()
            }
            return value
        }

        let remote = canonical(remote)
        let local = canonical(local)
        return !remote.isEmpty && remote == local
    }

    private static func isValidRepository(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components.allSatisfy({ !$0.isEmpty }) else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-")
        return value.unicodeScalars.allSatisfy { scalar in
            scalar == "/" || allowed.contains(scalar)
        }
    }

    private static func normalizedBaseURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        var normalized = components
        while normalized.percentEncodedPath.count > 1 && normalized.percentEncodedPath.hasSuffix("/") {
            normalized.percentEncodedPath.removeLast()
        }
        return normalized.string
    }

    private static func isVersionScalar(_ scalar: UnicodeScalar) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-")
        return allowed.contains(scalar)
    }

    private static func isHexScalar(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...70).contains(scalar.value)
            || (97...102).contains(scalar.value)
    }
}
