import Foundation

enum StoredEntitySource: String, Codable, Equatable {
    case local
    case upstream
}

/// Local metadata for a server project.
///
/// `project/list` only guarantees an id and label. The directory path comes from
/// the client's `project/browse` selection, while the display name is a local
/// presentation choice as required by the project naming flow.
struct StoredProjectBinding: Codable, Equatable, Identifiable {
    var hostID: UUID
    var projectID: String
    var path: String?
    var name: String
    var source: StoredEntitySource
    var isArchived: Bool
    var isDeleted: Bool
    var createdAt: Date
    var updatedAt: Date

    var id: String { "\(hostID.uuidString):\(projectID)" }

    init(
        hostID: UUID,
        projectID: String,
        path: String?,
        name: String,
        source: StoredEntitySource = .local,
        isArchived: Bool = false,
        isDeleted: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.hostID = hostID
        self.projectID = projectID
        self.path = path
        self.name = name
        self.source = source
        self.isArchived = isArchived
        self.isDeleted = isDeleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case hostID
        case projectID
        case path
        case name
        case source
        case isArchived
        case isDeleted
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decode(UUID.self, forKey: .hostID)
        projectID = try container.decode(String.self, forKey: .projectID)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decodeIfPresent(StoredEntitySource.self, forKey: .source) ?? .local
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? updatedAt
    }
}

struct StoredSessionBinding: Codable, Equatable, Identifiable {
    var hostID: UUID
    var sessionID: String
    var projectID: String?
    var titleOverride: String?
    var messageCount: Int?
    var source: StoredEntitySource
    var isArchived: Bool
    var isPinned: Bool
    var pinOrder: Int?
    var lastOpenedAt: Date?
    var lastActivityAt: Date
    var lastKnownRevision: Int?
    var isUnread: Bool
    var isDeleted: Bool
    var updatedAt: Date

    var id: String { "\(hostID.uuidString):\(sessionID)" }

    init(
        hostID: UUID,
        sessionID: String,
        projectID: String?,
        titleOverride: String? = nil,
        messageCount: Int? = nil,
        source: StoredEntitySource = .local,
        isArchived: Bool = false,
        isPinned: Bool = false,
        pinOrder: Int? = nil,
        lastOpenedAt: Date? = nil,
        lastActivityAt: Date = Date(),
        lastKnownRevision: Int? = nil,
        isUnread: Bool = false,
        isDeleted: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.hostID = hostID
        self.sessionID = sessionID
        self.projectID = projectID
        self.titleOverride = titleOverride
        self.messageCount = messageCount
        self.source = source
        self.isArchived = isArchived
        self.isPinned = isPinned
        self.pinOrder = pinOrder
        self.lastOpenedAt = lastOpenedAt
        self.lastActivityAt = lastActivityAt
        self.lastKnownRevision = lastKnownRevision
        self.isUnread = isUnread
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
    }
}
