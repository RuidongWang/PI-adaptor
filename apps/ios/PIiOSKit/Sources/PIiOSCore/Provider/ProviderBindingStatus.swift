import Foundation

public struct ProviderBindingStatus: Equatable, Sendable {
    public var sessionId: String
    public var pinnedProviderId: String?
    public var pinnedModelId: String?
    public var pinnedThinkingLevel: String?
    public var effectiveProviderId: String?
    public var effectiveModelId: String?
    public var available: Bool?
    public var unavailableReason: String?
    public var unknownInputs: [String]
    public var observedAt: String

    public init(
        sessionId: String,
        pinnedProviderId: String?,
        pinnedModelId: String?,
        pinnedThinkingLevel: String?,
        effectiveProviderId: String?,
        effectiveModelId: String?,
        available: Bool?,
        unavailableReason: String?,
        unknownInputs: [String],
        observedAt: String
    ) {
        self.sessionId = sessionId
        self.pinnedProviderId = pinnedProviderId
        self.pinnedModelId = pinnedModelId
        self.pinnedThinkingLevel = pinnedThinkingLevel
        self.effectiveProviderId = effectiveProviderId
        self.effectiveModelId = effectiveModelId
        self.available = available
        self.unavailableReason = unavailableReason
        self.unknownInputs = unknownInputs
        self.observedAt = observedAt
    }
}

public enum ProviderBindingStatusParser {
    private static let reasons: Set<String> = [
        "provider_missing", "provider_disabled", "models_empty", "model_removed",
        "secret_missing", "oauth_unsupported", "no_candidate", "unknown",
    ]

    public static func parse(_ data: Data) throws -> ProviderBindingStatus {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { throw ProviderRemoveParseError.invalidJSON }
        let required = Set([
            "sessionId", "pinned", "effective", "available", "unavailableReason", "checks",
            "unknownInputs", "consistency", "isDefault", "revision", "sessionUpdatedAt",
            "maxAgeMs", "observedAt",
        ])
        guard Set(root.keys) == required,
              let sessionId = root["sessionId"] as? String,
              !sessionId.isEmpty,
              let pinned = root["pinned"] as? [String: Any],
              Set(pinned.keys) == Set(["providerId", "modelId", "thinkingLevel"]),
              root["available"] is NSNull || root["available"] is Bool,
              root["unavailableReason"] is NSNull || root["unavailableReason"] is String,
              let unknownInputs = root["unknownInputs"] as? [String],
              unknownInputs.allSatisfy({
                  ["providers.list", "providers.get", "settings.get", "session.get", "providers.getSecret"]
                      .contains($0)
              }),
              let observedAt = root["observedAt"] as? String,
              !observedAt.isEmpty
        else { throw ProviderRemoveParseError.invalidShape }
        let available = root["available"] as? Bool
        let reason = root["unavailableReason"] as? String
        guard reason == nil || reasons.contains(reason!) else {
            throw ProviderRemoveParseError.invalidShape
        }

        var effectiveProviderId: String?
        var effectiveModelId: String?
        if !(root["effective"] is NSNull) {
            guard let effective = root["effective"] as? [String: Any],
                  Set(effective.keys) == Set(["providerId", "modelId", "providerSource", "modelSource"]),
                  let providerId = effective["providerId"] as? String,
                  let modelId = effective["modelId"] as? String
            else { throw ProviderRemoveParseError.invalidShape }
            effectiveProviderId = providerId
            effectiveModelId = modelId
        }

        guard let checks = root["checks"] as? [String: Any],
              Set(checks.keys) == Set([
                  "providerKnown", "providerEnabled", "modelsEmpty", "modelPresent",
                  "secretPresent", "oauth", "pluginOwned", "secretMismatch",
              ]),
              let consistency = root["consistency"] as? [String: Any],
              Set(consistency.keys) == Set(["reads", "snapshotStable"]),
              consistency["snapshotStable"] is Bool
        else { throw ProviderRemoveParseError.invalidShape }

        return ProviderBindingStatus(
            sessionId: sessionId,
            pinnedProviderId: nullableString(pinned["providerId"]),
            pinnedModelId: nullableString(pinned["modelId"]),
            pinnedThinkingLevel: nullableString(pinned["thinkingLevel"]),
            effectiveProviderId: effectiveProviderId,
            effectiveModelId: effectiveModelId,
            available: available,
            unavailableReason: reason,
            unknownInputs: unknownInputs,
            observedAt: observedAt
        )
    }

    private static func nullableBool(_ value: Any?) -> Bool? {
        if value is NSNull { return nil }
        guard let value = value as? Bool else { return nil }
        return value
    }

    private static func nullableString(_ value: Any?) -> String? {
        if value is NSNull { return nil }
        return value as? String
    }
}

public enum ProviderBindingReceipt: Equatable, Sendable {
    case success(ProviderBindingStatus)
    case failure(ProviderImportFailureCode)
    case unparseable(reason: String)
}

public enum ProviderBindingReceiptParser {
    public static let successPrefix = "PI_HOST_BINDING"
    public static let failurePrefix = "PI_HOST_FAILED"

    public static func parse(stdout: String, exitCode: Int32? = nil) -> ProviderBindingReceipt {
        let lines = stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix(failurePrefix) {
                let payload = text.dropFirst(failurePrefix.count).trimmingCharacters(in: .whitespaces)
                guard let data = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let root = object as? [String: Any],
                      let code = root["code"] as? String
                else { return .unparseable(reason: "PI_HOST_FAILED 的 JSON 无法解析") }
                return .failure(ProviderImportFailureCode(raw: code))
            }
            if text.hasPrefix(successPrefix) {
                if let exitCode, exitCode != 0 {
                    return .unparseable(reason: "成功标记出现在非零退出码 \(exitCode) 的输出里")
                }
                let payload = text.dropFirst(successPrefix.count).trimmingCharacters(in: .whitespaces)
                guard let data = payload.data(using: .utf8) else {
                    return .unparseable(reason: "PI_HOST_BINDING 不是 UTF-8")
                }
                do {
                    return .success(try ProviderBindingStatusParser.parse(data))
                } catch {
                    return .unparseable(reason: "PI_HOST_BINDING 的 JSON 无法解析：\(error)")
                }
            }
        }
        return .unparseable(reason: "输出里没有 PI_HOST_BINDING / PI_HOST_FAILED 标记")
    }
}
