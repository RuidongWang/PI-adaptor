import Foundation
import PIiOSCore

/// Local, non-secret projection of one server-side provider import.
struct StoredModelBinding: Codable, Equatable, Identifiable {
    var id: String
    var alias: String?
    var contextWindow: Int
    var maxTokens: Int
    var thinkingLevels: [String]
    var defaultThinkingLevel: String?
    var thinkingProtocol: String?
    var supportsReasoningEffort: Bool?
    var supportsImages: Bool?
    var supportsDocuments: Bool?

    init(spec: ProviderModelSpec) {
        id = spec.id
        alias = spec.alias
        contextWindow = spec.contextWindow
        maxTokens = spec.maxTokens
        thinkingLevels = spec.thinkingLevels
        defaultThinkingLevel = spec.defaultThinkingLevel
        thinkingProtocol = spec.thinkingProtocol
        supportsReasoningEffort = spec.supportsReasoningEffort
        supportsImages = spec.supportsImages
        supportsDocuments = spec.supportsDocuments
    }

    var displayName: String { alias ?? id }

    var providerSpec: ProviderModelSpec {
        ProviderModelSpec(
            id: id,
            contextWindow: contextWindow,
            maxTokens: maxTokens,
            thinkingLevels: thinkingLevels,
            defaultThinkingLevel: defaultThinkingLevel,
            alias: alias,
            thinkingProtocol: thinkingProtocol,
            supportsReasoningEffort: supportsReasoningEffort,
            supportsImages: supportsImages,
            supportsDocuments: supportsDocuments
        )
    }

}

/// The API key is deliberately absent: the server owns it after import.
struct StoredModelProvider: Codable, Equatable, Identifiable {
    var providerId: String
    /// The provider id the legacy SSH `provider-import` assigned, when this
    /// record was imported over SSH and mirrored into the v2 Host under a
    /// different id. Kept so deletion can still clean up the legacy store.
    var legacyProviderId: String?
    /// Whether this record has a mirror in the v2 Host provider store.
    ///
    /// `true` = v2 Host record (either created there directly or mirrored from a
    /// legacy import); `false` = legacy-only. `nil` for records persisted before
    /// this field existed — deletion then probes the v2 Host to decide, so an
    /// old record is never misclassified.
    var hostV2Mirror: Bool?
    var hostID: UUID
    var name: String
    var baseURL: String
    var apiStyle: String
    var models: [StoredModelBinding]
    var defaultModelId: String?
    var importedAt: Date

    var id: String { "\(hostID.uuidString):\(providerId)" }

    func records(defaultModelId: String?) -> [ModelRecord] {
        models.map { binding in
            ModelRecord(
                providerId: providerId,
                modelId: binding.id,
                alias: binding.alias,
                contextWindow: binding.contextWindow,
                maxTokens: binding.maxTokens,
                thinkingLevels: binding.thinkingLevels,
                defaultThinkingLevel: binding.defaultThinkingLevel,
                isDefault: binding.id == defaultModelId
            )
        }
    }
}
