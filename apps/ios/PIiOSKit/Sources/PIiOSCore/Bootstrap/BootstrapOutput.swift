import CoreFoundation
import Foundation

/// A bootstrap progress label printed on stdout.
///
/// The value is kept open for forward compatibility, while common upstream
/// script labels are available as typed constants.
public struct PiHostBootstrapStage: RawRepresentable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public static let probe = PiHostBootstrapStage(rawValue: "probe")
    public static let resolveRelease = PiHostBootstrapStage(rawValue: "resolve-release")
    public static let downloadChecksum = PiHostBootstrapStage(rawValue: "download-checksum")
    public static let download = PiHostBootstrapStage(rawValue: "download")
    public static let verify = PiHostBootstrapStage(rawValue: "verify")
    public static let install = PiHostBootstrapStage(rawValue: "install")
    public static let start = PiHostBootstrapStage(rawValue: "start")
    public static let awaitReady = PiHostBootstrapStage(rawValue: "await-ready")
    public static let reuse = PiHostBootstrapStage(rawValue: "reuse")
    public static let upload = PiHostBootstrapStage(rawValue: "upload")
    public static let forward = PiHostBootstrapStage(rawValue: "forward")
    public static let pair = PiHostBootstrapStage(rawValue: "pair")
    public static let ok = PiHostBootstrapStage(rawValue: "ok")

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct PiHostReadyLine: Equatable, Sendable {
    public let hostId: String
    public let host: String
    public let port: Int
    public let version: String

    public init(hostId: String, host: String, port: Int, version: String) {
        self.hostId = hostId
        self.host = host
        self.port = port
        self.version = version
    }
}

public struct PiHostPairingLine: Equatable, Sendable {
    public let token: String
    public let expiresAt: Int64

    public init(token: String, expiresAt: Int64) {
        self.token = token
        self.expiresAt = expiresAt
    }
}

public struct PiHostBootstrapOutput: Equatable, Sendable {
    public let ready: PiHostReadyLine?
    public let pairing: PiHostPairingLine?
    public let stages: [PiHostBootstrapStage]
    public let failure: BootstrapFailureCode?

    public init(
        ready: PiHostReadyLine? = nil,
        pairing: PiHostPairingLine? = nil,
        stages: [PiHostBootstrapStage] = [],
        failure: BootstrapFailureCode? = nil
    ) {
        self.ready = ready
        self.pairing = pairing
        self.stages = stages
        self.failure = failure
    }
}

/// Tolerant stdout parser for the bootstrap script contract.
///
/// Interleaved SSH noise is ignored. Invalid ready lines are rejected rather
/// than producing a half-valid endpoint, and the first failure line wins.
public enum PiHostBootstrapOutputParser {
    public static func parse(_ stdout: String) -> PiHostBootstrapOutput {
        var ready: PiHostReadyLine?
        var pairing: PiHostPairingLine?
        var stages: [PiHostBootstrapStage] = []
        var failure: BootstrapFailureCode?

        for rawLine in stdout.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("PI_HOST_BOOTSTRAP_FAILED ") {
                if failure == nil {
                    let code = String(line.dropFirst("PI_HOST_BOOTSTRAP_FAILED ".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    failure = BootstrapFailureCode(raw: code)
                }
                continue
            }

            if line.hasPrefix("PI_HOST_BOOTSTRAP ") {
                let stage = String(line.dropFirst("PI_HOST_BOOTSTRAP ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !stage.isEmpty {
                    stages.append(PiHostBootstrapStage(rawValue: stage))
                }
                continue
            }

            if line.hasPrefix("PI_HOST_FAILED "),
               let payload = jsonObject(in: line, prefix: "PI_HOST_FAILED "),
               payload["code"] as? String == "HOST_BOOTSTRAP_FAILED",
               let step = payload["step"] as? String,
               !step.isEmpty {
                if failure == nil {
                    failure = BootstrapFailureCode(raw: step)
                }
                continue
            }

            if let payload = jsonObject(in: line, prefix: "PI_HOST_READY ") {
                if ready == nil {
                    ready = parseReady(payload)
                }
                continue
            }

            if let payload = jsonObject(in: line, prefix: "PI_HOST_PAIRING_TOKEN ") {
                if pairing == nil {
                    pairing = parsePairing(payload)
                }
            }
        }

        return PiHostBootstrapOutput(
            ready: ready,
            pairing: pairing,
            stages: stages,
            failure: failure
        )
    }

    /// Removes a live pairing token before output is retained in logs or an
    /// error payload.
    public static func redact(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            line.contains("PI_HOST_PAIRING_TOKEN")
                ? "PI_HOST_PAIRING_TOKEN <redacted>"
                : line
        }.joined(separator: "\n")
    }

    private static func parseReady(_ payload: [String: Any]) -> PiHostReadyLine? {
        guard let hostId = payload["hostId"] as? String,
              !hostId.isEmpty,
              let host = payload["host"] as? String,
              host == "127.0.0.1" || host == "::1",
              let portNumber = numericValue(payload["port"]),
              let port = validPort(portNumber),
              let version = payload["version"] as? String else {
            return nil
        }
        return PiHostReadyLine(hostId: hostId, host: host, port: port, version: version)
    }

    private static func parsePairing(_ payload: [String: Any]) -> PiHostPairingLine? {
        guard let token = payload["token"] as? String,
              !token.isEmpty else {
            return nil
        }
        let expiresAt = numericValue(payload["expiresAt"])?.int64Value ?? 0
        return PiHostPairingLine(token: token, expiresAt: expiresAt)
    }

    private static func jsonObject(in line: String, prefix: String) -> [String: Any]? {
        guard line.hasPrefix(prefix) else { return nil }
        let payload = String(line.dropFirst(prefix.count))
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return object as? [String: Any]
    }

    private static func numericValue(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number
    }

    private static func validPort(_ number: NSNumber) -> Int? {
        let value = number.doubleValue
        guard value.isFinite,
              value.rounded() == value,
              value >= 1,
              value <= 65_535 else {
            return nil
        }
        return Int(value)
    }
}
