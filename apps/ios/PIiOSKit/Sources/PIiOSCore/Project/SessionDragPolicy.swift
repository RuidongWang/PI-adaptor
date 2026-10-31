import CoreGraphics
import Foundation

/// One session that participates in sidebar ordering.
public struct SessionDragCandidate: Equatable {
    public let sessionID: String
    public let projectID: String?
    public let isPinned: Bool

    public init(sessionID: String, projectID: String?, isPinned: Bool) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.isPinned = isPinned
    }
}

public enum SessionDropEdge: Equatable {
    case before
    case after
}

public struct SessionDropResolution: Equatable {
    public let targetID: String
    public let edge: SessionDropEdge

    public init(targetID: String, edge: SessionDropEdge) {
        self.targetID = targetID
        self.edge = edge
    }
}

/// Pure rules behind the sidebar long-press reorder gesture.
public enum SessionDragPolicy {
    /// The row must stay still for this long before dragging can begin.
    public static let longPressDuration: TimeInterval = 0.5

    /// Moving farther than this before activation belongs to the scroll view.
    public static let scrollCancellationDistance: CGFloat = 8

    public static func movementCancelsActivation(
        from start: CGPoint,
        to current: CGPoint
    ) -> Bool {
        let deltaX = current.x - start.x
        let deltaY = current.y - start.y
        return deltaX * deltaX + deltaY * deltaY
            > scrollCancellationDistance * scrollCancellationDistance
    }

    /// Only pinned sessions in the requested project form one reorder scope.
    public static func reorderableSessionIDs(
        from candidates: [SessionDragCandidate],
        projectID: String
    ) -> [String] {
        candidates
            .filter { $0.projectID == projectID && $0.isPinned }
            .map(\.sessionID)
    }

    public static func canStartDrag(
        sessionID: String,
        candidates: [SessionDragCandidate],
        projectID: String
    ) -> Bool {
        reorderableSessionIDs(from: candidates, projectID: projectID)
            .contains(sessionID)
    }

    /// Resolves the highlighted insertion edge without ever leaving the
    /// project's pinned-session scope or targeting the dragged row itself.
    public static func resolveDrop(
        at location: CGPoint,
        sourceID: String,
        projectID: String,
        candidates: [SessionDragCandidate],
        frames: [String: CGRect]
    ) -> SessionDropResolution? {
        let eligibleIDs = reorderableSessionIDs(from: candidates, projectID: projectID)
        guard eligibleIDs.contains(sourceID) else { return nil }

        for targetID in eligibleIDs where targetID != sourceID {
            guard let frame = frames[targetID], frame.contains(location) else { continue }
            return SessionDropResolution(
                targetID: targetID,
                edge: location.y < frame.midY ? .before : .after
            )
        }
        return nil
    }
}
