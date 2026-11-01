import Foundation

/// Pure release coordinates for a PI-adaptor artifact.
///
/// The app version selects the bundle, checksum, install root and systemd unit.
/// Production callers use `patched`/`production`, which always pin a checksum.
public struct PiHostRelease: Equatable, Sendable {
    public static let defaultRepository = "RuidongWang/PI-adaptor"
    public static let releaseRepository = "RuidongWang/PI-adaptor"
    public static let releaseVersion = "2.0.1"
    public static let releaseTag = "pi-adaptor-v2.0.1"
    public static let runtimeServerName = "pi-adaptor"
    public static let installHomeName = ".pi-adaptor"
    public static let unitName = "pi-adaptor.service"
    public static let entrypoint = "dist/main.js"
    public static let minimumNodeVersion = "22.19.0"

    // Source-compatible aliases. New callers should prefer the non-patched names.
    public static let patchedRepository = releaseRepository
    public static let patchedReleaseVersion = releaseVersion
    public static var patchedReleaseTag: String { releaseTag }
    public static var defaultPatchedBaseURL: String {
        "https://github.com/\(patchedRepository)/releases/download/\(patchedReleaseTag)"
    }
    public static let patchedChecksums: [BootstrapArtifactTarget: String] = [
        .linuxX64: "c7e49db8aecc097c478417f3b16e572b6fa6fc41e3cba61229ae4ae62ff31080",
        .linuxArm64: "bb52c1fe06c3d421ed5483b8eac1da3376ba7594a1e880a5ee1ead5da182eb31",
    ]

    public let repository: String
    public let version: String
    public let releaseTag: String
    public let target: BootstrapArtifactTarget
    public let bundleDirectoryName: String
    public let artifactName: String
    public let artifactURL: String
    public let checksumURL: String
    public let serverName: String
    public let unitName: String
    public let minimumNodeVersion: String
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
        let tag = "pi-adaptor-v\(version)"
        let baseURL = "https://github.com/\(repository)/releases/download/\(tag)"

        self.repository = repository
        self.version = version
        self.releaseTag = tag
        self.target = target
        self.bundleDirectoryName = String(artifactName.dropLast(".tar.gz".count))
        self.artifactName = artifactName
        self.artifactURL = "\(baseURL)/\(artifactName)"
        self.checksumURL = "\(baseURL)/\(artifactName).sha256"
        self.serverName = Self.runtimeServerName
        self.unitName = Self.unitName
        self.minimumNodeVersion = Self.minimumNodeVersion
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
        self.releaseTag = "pi-adaptor-v\(version)"
        self.target = target
        self.bundleDirectoryName = String(artifactName.dropLast(".tar.gz".count))
        self.artifactName = artifactName
        self.artifactURL = "\(baseURL)/\(artifactName)"
        self.checksumURL = "\(baseURL)/\(artifactName).sha256"
        self.serverName = Self.runtimeServerName
        self.unitName = Self.unitName
        self.minimumNodeVersion = Self.minimumNodeVersion
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

    public static func production(
        target: BootstrapArtifactTarget,
        baseURL: String = defaultPatchedBaseURL
    ) -> PiHostRelease? {
        patched(target: target, baseURL: baseURL)
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
