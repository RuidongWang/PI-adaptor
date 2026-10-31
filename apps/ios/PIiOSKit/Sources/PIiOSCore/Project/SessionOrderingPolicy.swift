import Foundation

public enum SessionOrderingPolicy {
    /// Pinned sessions first, in pin order; everything else by latest activity.
    public static func orderedIDs(
        _ ids: [String],
        pinnedOrders: [String: Int],
        lastActivity: [String: Date]
    ) -> [String] {
        ids.sorted { left, right in
            let leftPinned = pinnedOrders[left]
            let rightPinned = pinnedOrders[right]
            if leftPinned != nil, rightPinned == nil { return true }
            if rightPinned != nil, leftPinned == nil { return false }
            if let leftPinned, let rightPinned {
                if leftPinned != rightPinned { return leftPinned < rightPinned }
                return left < right
            }
            let leftDate = lastActivity[left] ?? .distantPast
            let rightDate = lastActivity[right] ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return left < right
        }
    }

    /// Reorders only pinned sessions. The returned dictionary is a contiguous
    /// zero-based order scoped to one project group.
    public static func movePinned(
        _ ids: [String],
        pinnedOrders: [String: Int],
        sourceID: String,
        before targetID: String
    ) -> [String: Int] {
        guard sourceID != targetID,
              pinnedOrders[sourceID] != nil,
              pinnedOrders[targetID] != nil
        else { return pinnedOrders }
        var pinned = ids
            .filter { pinnedOrders[$0] != nil }
            .sorted { (pinnedOrders[$0] ?? Int.max) < (pinnedOrders[$1] ?? Int.max) }
        guard let source = pinned.firstIndex(of: sourceID),
              let target = pinned.firstIndex(of: targetID)
        else { return pinnedOrders }
        let moved = pinned.remove(at: source)
        let insertionIndex = source < target ? target - 1 : target
        pinned.insert(moved, at: min(insertionIndex, pinned.count))
        var result = pinnedOrders
        for (index, id) in pinned.enumerated() {
            result[id] = index
        }
        return result
    }
}
